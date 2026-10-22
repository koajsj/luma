import CryptoKit
import Foundation

struct V4RecoverySealedEntry: Codable, Equatable {
    let messageID: UUID
    let conversationID: UUID
    let ratchetPublicKey: Data
    let index: Int
    let digest: Data
    var cancelled: Bool = false
}

struct V4RecoveryCandidate: Codable {
    let proposal: V4RecoveryProposal
    var ratchet: V4RatchetState?
    var version: UInt64
    var frozen: Bool = false
    var sent: [V4RecoverySealedEntry] = []
    var received: [V4RecoverySealedEntry] = []
    var retired: Bool = false
    var cancelled: [UUID] = []
}

struct V4RecoveryControlOutbox: Codable {
    let id: UUID
    let conversationID: UUID
    let receiverDeviceID: UUID
    let wire: Data
}

struct V4RecoveryApplicationOutbox: Codable {
    let id: UUID
    let conversationID: UUID
    let receiverDeviceID: UUID
    let wire: Data
    var wasSubmitted: Bool = false
}

struct V4RecoverySnapshot: Codable {
    var version: UInt64 = 0
    var coordinator: V4RecoveryCoordinator
    var candidates: [V4RecoveryCandidate] = []
    var outbox: [V4RecoveryControlOutbox] = []
    var applicationOutbox: [V4RecoveryApplicationOutbox] = []
    var processedControls: [String: Data] = [:]
    var decisionDigest: Data?
    var frozenManifest: Data?
    var drainAcknowledged: Bool = false
    var offered: Bool = false
    var acknowledged: Bool = false
    var committed: Bool = false
    var lastOperationID: UUID?
}

struct V4RecoveryPreKeyConsumption: Codable, Equatable {
    let publicKey: Data
    let proposal: V4ProposalID
}

struct V4RecoveryOperation: Codable {
    let id: UUID
    let expectedVersion: UInt64
    var next: V4RecoverySnapshot
    let output: Data
    let incomingSequence: Int64?
    var envelopeDigest: Data?
    var consumedPreKeys: [V4RecoveryPreKeyConsumption] = []
    var phase: V4SessionVault.TransactionPhase = .prepared
}

/// Recovery candidates never use the legacy session account. A journal precedes all
/// writes; immutable snapshot revisions plus a digest high-water prevent stale records
/// from becoming authoritative. No network await is performed in this storage layer.
struct V4HandshakeRecoveryVault {
    let keychain: KeychainManager
    let userID: String
    let localDevice: UUID
    #if DEBUG
    /// Test-only persistence interruption hook. No secret or account path is exposed.
    var onPersistence: (() throws -> Void)? = nil
    #endif
    private struct Floor: Codable { let version: UInt64; let digest: Data }
    private struct CandidateReference: Codable {
        let proposal: V4ProposalID
        let version: UInt64
        let digest: Data
    }
    private struct StoredSnapshot: Codable {
        let metadata: V4RecoverySnapshot
        let candidates: [CandidateReference]
    }
    private func candidateAccount(_ pair: Data, _ proposal: V4ProposalID, _ version: UInt64) -> String {
        account(pair, "candidate.\(hex(proposal.bytes)).\(version)")
    }
    private func decodeSnapshot(_ bytes: Data, pairID: Data) throws -> V4RecoverySnapshot {
        let record = try JSONDecoder().decode(StoredSnapshot.self, from: bytes)
        guard record.metadata.candidates.isEmpty else { throw V4VaultError.damaged }
        var value = record.metadata
        value.candidates = try record.candidates.map { reference in
            guard let data = try keychain.read(candidateAccount(pairID, reference.proposal, reference.version)),
                  Data(SHA256.hash(data: data)) == reference.digest else { throw V4VaultError.rollback }
            let candidate = try JSONDecoder().decode(V4RecoveryCandidate.self, from: data)
            guard candidate.proposal.id == reference.proposal, candidate.version == reference.version else { throw V4VaultError.rollback }
            return candidate
        }
        return value
    }
    private var prefix: String { "v4.recovery.\(userID).\(localDevice.uuidString)." }

    // A shared synchronous lock covers all Keychain services (including test namespaces).
    // Deliberately no await in the critical section: callers re-read after network work.
    private static let lock = NSRecursiveLock()
    static func serial<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }

    private func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    private func account(_ pair: Data, _ suffix: String) -> String { prefix + hex(pair) + "." + suffix }
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    private func persist(_ bytes: Data, account: String) throws {
        try keychain.save(bytes, account: account)
        #if DEBUG
        try onPersistence?()
        #endif
    }
    private func erase(_ account: String) throws {
        try keychain.delete(account)
        #if DEBUG
        try onPersistence?()
        #endif
    }

    func load(_ pairID: Data) throws -> V4RecoverySnapshot? {
        try Self.serial {
            guard pairID.count == 32 else { throw V4VaultError.damaged }
            guard let floorBytes = try keychain.read(account(pairID, "floor")) else {
                // An interrupted initial journal is recovered explicitly; never invent an empty state.
                if try pairs().contains(pairID) {
                    guard let op = try pending(pairID), op.expectedVersion == 0 else { throw V4VaultError.damaged }
                }
                return nil
            }
            guard let floor = try? JSONDecoder().decode(Floor.self, from: floorBytes), floor.version > 0,
                  let bytes = try keychain.read(account(pairID, "state.\(floor.version)")),
                  Data(SHA256.hash(data: bytes)) == floor.digest,
                  let state = try? decodeSnapshot(bytes, pairID: pairID),
                  state.version == floor.version, state.coordinator.pair.id == pairID else { throw V4VaultError.rollback }
            try validate(state)
            return state
        }
    }

    func find(remoteDevice: UUID) throws -> V4RecoverySnapshot? {
        guard let bytes = try keychain.read(prefix + "peer.\(remoteDevice.uuidString)") else { return nil }
        let state = try load(bytes) ?? pending(bytes)?.next
        guard state?.coordinator.pair.participants.contains(where: { $0.deviceID == remoteDevice }) == true else {
            throw V4VaultError.damaged
        }
        return state
    }

    func pending(_ pairID: Data) throws -> V4RecoveryOperation? {
        guard let bytes = try keychain.read(account(pairID, "journal")) else { return nil }
        guard let op = try? JSONDecoder().decode(V4RecoveryOperation.self, from: bytes),
              op.next.coordinator.pair.id == pairID else { throw V4VaultError.damaged }
        return op
    }

    func stage(_ operation: V4RecoveryOperation) throws {
        try Self.serial {
            let pair = operation.next.coordinator.pair.id
            if let old = try pending(pair) {
                guard old.id == operation.id, old.expectedVersion == operation.expectedVersion,
                      try encoded(old.next) == encoded(operation.next), old.output == operation.output,
                      old.incomingSequence == operation.incomingSequence,
                      old.envelopeDigest == operation.envelopeDigest,
                      old.consumedPreKeys == operation.consumedPreKeys else { throw V4VaultError.pendingOperation }
                for key in old.consumedPreKeys { try reserve(key.publicKey, proposal: key.proposal) }
                try register(pair, snapshot: old.next)
                return
            }
            let current = try load(pair)
            guard (current?.version ?? 0) == operation.expectedVersion,
                  operation.expectedVersion < UInt64.max,
                  operation.consumedPreKeys.count <= 1 else { throw V4VaultError.rollback }
            try validateSuccessor(operation.next, current: current)
            for key in operation.consumedPreKeys { try verifyReservation(key.publicKey, proposal: key.proposal) }
            // The protocol consumes at most one local OTP per inbound proposal. Its
            // proposal-bound tombstone must be durable first so a crash cannot let a
            // competing proposal reuse the private key. The exact journal then
            // precedes secondary discovery indexes and repairs them on retry.
            for key in operation.consumedPreKeys { try reserve(key.publicKey, proposal: key.proposal) }
            try persist(encoded(operation), account: account(pair, "journal"))
            try register(pair, snapshot: operation.next)
        }
    }

    func finish(_ pairID: Data, operationID: UUID) throws {
        try Self.serial {
            guard var op = try pending(pairID) else {
                guard try load(pairID)?.lastOperationID == operationID else { throw V4VaultError.pendingOperation }
                return
            }
            guard op.id == operationID else { throw V4VaultError.pendingOperation }
            try register(pairID, snapshot: op.next)
            for key in op.consumedPreKeys { try reserve(key.publicKey, proposal: key.proposal) }
            let current = try load(pairID)
            if current?.lastOperationID != operationID {
                guard (current?.version ?? 0) == op.expectedVersion else { throw V4VaultError.rollback }
                try validateSuccessor(op.next, current: current)
                op.phase = .applying
                try persist(encoded(op), account: account(pairID, "journal"))
                var next = op.next
                next.version = op.expectedVersion + 1; next.lastOperationID = operationID
                var references: [CandidateReference] = []
                for candidate in next.candidates {
                    let bytes = try encoded(candidate)
                    let key = candidateAccount(pairID, candidate.proposal.id, candidate.version)
                    if let existing = try keychain.read(key), existing != bytes { throw V4VaultError.rollback }
                    try persist(bytes, account: key)
                    references.append(.init(proposal: candidate.proposal.id, version: candidate.version,
                        digest: Data(SHA256.hash(data: bytes))))
                }
                var metadata = next; metadata.candidates = []
                let bytes = try encoded(StoredSnapshot(metadata: metadata, candidates: references))
                let slot = account(pairID, "state.\(next.version)")
                if let existing = try keychain.read(slot), existing != bytes { throw V4VaultError.rollback }
                try persist(bytes, account: slot)
                try persist(encoded(Floor(version: next.version, digest: Data(SHA256.hash(data: bytes)))),
                                  account: account(pairID, "floor"))
            }
            // Reservation tombstones are durable before removing private OTP material.
            for key in op.consumedPreKeys { try reserve(key.publicKey, proposal: key.proposal) }
            if !op.consumedPreKeys.isEmpty {
                let devices = V4SessionVault(keychain: keychain)
                guard var device = try devices.loadDevice(userID: userID, deviceID: localDevice) else { throw V4VaultError.missing }
                for key in op.consumedPreKeys {
                    let encoded = key.publicKey.base64EncodedString()
                    device.oneTimePreKeys.removeValue(forKey: encoded)
                    device.pendingOneTimePreKeys.removeAll { $0 == encoded }
                }
                try devices.saveDevice(device, userID: userID)
                #if DEBUG
                try onPersistence?()
                #endif
            }
            try persist(pairID, account: prefix + "peer.\(try remoteDevice(op.next).uuidString)")
            op.phase = .committed
            try persist(encoded(op), account: account(pairID, "journal"))
            // Remove obsolete secret snapshots only AFTER the new authoritative floor is durable.
            if op.expectedVersion > 0 {
                if let oldBytes = try keychain.read(account(pairID, "state.\(op.expectedVersion)")) {
                    let old = try JSONDecoder().decode(StoredSnapshot.self, from: oldBytes)
                    for reference in old.candidates where !op.next.candidates.contains(where: {
                        $0.proposal.id == reference.proposal && $0.version == reference.version
                    }) {
                        try erase(candidateAccount(pairID, reference.proposal, reference.version))
                    }
                }
                try erase(account(pairID, "state.\(op.expectedVersion)"))
            }
            try erase(account(pairID, "journal"))
        }
    }

    func reserve(_ publicKey: Data, proposal: V4ProposalID) throws {
        try Self.serial {
            guard publicKey.count == 32 else { throw V4ProtocolError.invalidPreKey }
            let key = prefix + "otp." + hex(publicKey)
            if let old = try keychain.read(key) {
                guard old == proposal.bytes else { throw V4ProtocolError.replay }
            } else { try persist(proposal.bytes, account: key) }
        }
    }

    func verifyReservation(_ publicKey: Data, proposal: V4ProposalID) throws {
        if let old = try keychain.read(prefix + "otp." + hex(publicKey)), old != proposal.bytes {
            throw V4ProtocolError.replay
        }
    }

    func pairs() throws -> [Data] {
        guard let bytes = try keychain.read(prefix + "pairs") else { return [] }
        guard let values = try? JSONDecoder().decode([Data].self, from: bytes),
              values.allSatisfy({ $0.count == 32 }) else { throw V4VaultError.damaged }
        return values
    }

    func pendingForOperation(_ id: UUID) throws -> [(Data, V4RecoveryOperation)] {
        try pairs().compactMap { pair in
            guard let op = try pending(pair), op.id == id else { return nil }
            return (pair, op)
        }
    }

    func recoverIncoming(cursor: Int64) throws {
        for pair in try pairs() {
            if let op = try pending(pair), let sequence = op.incomingSequence, sequence <= cursor {
                try finish(pair, operationID: op.id)
            }
        }
    }

    func removePeer(_ remote: UUID) throws {
        try Self.serial {
            var removed = Set<Data>()
            if let indexed = try keychain.read(prefix + "peer.\(remote.uuidString)") { removed.insert(indexed) }
            // Discovery can be missing after a journal write interruption. Recover ownership
            // from the authenticated journal/committed record, not only the secondary index.
            for pair in try pairs() {
                let state = try pending(pair)?.next ?? (try? load(pair))
                if state?.coordinator.pair.participants.contains(where: { $0.deviceID == remote }) == true {
                    removed.insert(pair)
                }
            }
            let operations = try removed.compactMap { pair -> (Data, V4RecoveryOperation)? in
                guard let operation = try pending(pair) else { return nil }
                return (pair, operation)
            }
            // The vault cannot know whether the decrypted application object and
            // sync cursor committed. Preserve inbound recovery journals for the
            // coordinator to finish from its durable cursor.
            guard operations.allSatisfy({ $0.1.incomingSequence == nil }) else {
                throw V4VaultError.pendingOperation
            }
            for (pair, operation) in operations where operation.phase != .prepared {
                try finish(pair, operationID: operation.id)
            }
            for pair in removed { try keychain.deleteAccounts(prefix: prefix + hex(pair) + ".") }
            try erase(prefix + "peer.\(remote.uuidString)")
            try persist(encoded(try pairs().filter { !removed.contains($0) }), account: prefix + "pairs")
            // OTP tombstones are deliberately retained until account/device deletion.
        }
    }
    func purge() throws { try keychain.deleteAccounts(prefix: prefix) }

    private func register(_ pairID: Data, snapshot: V4RecoverySnapshot) throws {
        var registered = try pairs()
        if !registered.contains(pairID) {
            registered.append(pairID)
            try persist(encoded(registered), account: prefix + "pairs")
        }
        // Indexes are discovery aids. Authentication and authorization remain
        // bound to the signed snapshot and its monotonic floor.
        let remote = try remoteDevice(snapshot)
        let peerAccount = prefix + "peer.\(remote.uuidString)"
        if try keychain.read(peerAccount) != pairID {
            try persist(pairID, account: peerAccount)
        }
    }

    private func remoteDevice(_ snapshot: V4RecoverySnapshot) throws -> UUID {
        guard let remote = snapshot.coordinator.pair.participants.first(where: { $0.deviceID != localDevice }),
              snapshot.coordinator.pair.participants.contains(where: { $0.deviceID == localDevice }) else {
            throw V4ProtocolError.wrongDevice
        }
        return remote.deviceID
    }

    private func validate(_ next: V4RecoverySnapshot) throws {
        try next.coordinator.validate(localDevice: localDevice)
        _ = try remoteDevice(next)
        guard next.candidates.count <= 2,
              Set(next.candidates.map { $0.proposal.id }).count == next.candidates.count,
              next.outbox.count <= 32, next.applicationOutbox.count <= 2_000,
              Set(next.candidates.map { $0.proposal.id }) == Set(next.coordinator.proposals.map(\.id)) else { throw V4VaultError.damaged }
        for candidate in next.candidates {
            try candidate.proposal.verify(in: next.coordinator.pair)
            guard candidate.retired == (candidate.ratchet == nil) else { throw V4VaultError.damaged }
            try candidate.ratchet?.validate()
            guard candidate.sent.count <= 2_000, candidate.received.count <= 2_000,
                  candidate.version > 0 else { throw V4VaultError.damaged }
        }
    }

    private func validateSuccessor(_ next: V4RecoverySnapshot, current: V4RecoverySnapshot?) throws {
        try validate(next)
        guard next.version == (current?.version ?? 0) else { throw V4VaultError.rollback }
        if let current {
            guard next.coordinator.pair == current.coordinator.pair,
                  next.coordinator.revision >= current.coordinator.revision,
                  next.coordinator.transitions.starts(with: current.coordinator.transitions),
                  next.coordinator.revision == UInt64(next.coordinator.transitions.count) else { throw V4VaultError.rollback }
            if next.coordinator.revision == current.coordinator.revision {
                guard try encoded(next.coordinator) == encoded(current.coordinator) else { throw V4VaultError.rollback }
            }
            for old in current.candidates {
                guard let new = next.candidates.first(where: { $0.proposal.id == old.proposal.id }),
                      new.version >= old.version, new.version <= old.version + 1,
                      !old.frozen || new.frozen, new.cancelled.starts(with: old.cancelled),
                      new.sent.starts(with: old.sent), new.received.starts(with: old.received) else {
                    throw V4VaultError.rollback
                }
                if old.retired { guard new.retired else { throw V4VaultError.rollback } }
                if new.retired && !old.retired {
                    guard new.frozen, new.proposal.id != next.coordinator.activeProposal,
                          next.coordinator.phase == .established, next.committed,
                          next.drainAcknowledged, new.version == old.version + 1 else { throw V4VaultError.rollback }
                }
                if new.ratchet?.ownRatchetPrivateKey == old.ratchet?.ownRatchetPrivateKey &&
                    new.ratchet?.remoteRatchetPublicKey == old.ratchet?.remoteRatchetPublicKey {
                    guard new.ratchet?.rootKey == old.ratchet?.rootKey else { throw V4VaultError.rollback }
                }
                if new.ratchet?.ownRatchetPrivateKey == old.ratchet?.ownRatchetPrivateKey {
                    guard (new.ratchet?.sendingIndex ?? 0) >= (old.ratchet?.sendingIndex ?? 0) else { throw V4VaultError.rollback }
                }
                if new.ratchet?.remoteRatchetPublicKey == old.ratchet?.remoteRatchetPublicKey {
                    guard (new.ratchet?.receivingIndex ?? 0) >= (old.ratchet?.receivingIndex ?? 0) else { throw V4VaultError.rollback }
                }
                for (key, bytes) in new.ratchet?.skippedKeys ?? [:] {
                    if let previous = old.ratchet?.skippedKeys[key], previous != bytes { throw V4VaultError.rollback }
                }
                if old.frozen {
                    guard new.sent == old.sent else { throw V4VaultError.rollback }
                }
                if new.version == old.version {
                    guard try encoded(new.ratchet) == encoded(old.ratchet) else { throw V4VaultError.rollback }
                }
            }
        }
    }
}
