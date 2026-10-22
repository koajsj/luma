import CryptoKit
import Foundation

/// Explicit opt-in for validation. Existing installations and legacy sessions remain unchanged.
struct V4RecoveryConfiguration {
    let enabled: Bool
    init(enabled: Bool = false) { self.enabled = enabled }
    static var current: Self {
        .init(enabled: Bundle.main.object(forInfoDictionaryKey: "LumaV4HandshakeRecoveryEnabled") as? Bool ?? false)
    }
}

struct V4RecoveryParticipant: Codable, Equatable {
    let accountID: UUID
    let deviceID: UUID
    let accountFingerprint: String
    let agreementPublicKey: Data
    let signingPublicKey: Data

    func encoded() throws -> Data {
        guard accountFingerprint.count == 64,
              accountFingerprint.allSatisfy({ $0.isHexDigit }),
              agreementPublicKey.count == 32, signingPublicKey.count == 32 else {
            throw V4ProtocolError.untrustedIdentity
        }
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreementPublicKey)
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey)
        return V4Handshake.fields("luma.v4.participant.v2", [
            V4HandshakeRecovery.uuidBytes(accountID), V4HandshakeRecovery.uuidBytes(deviceID),
            Data(accountFingerprint.uppercased().utf8), agreementPublicKey, signingPublicKey])
    }
}

struct V4RecoveryPair: Codable, Equatable {
    let participants: [V4RecoveryParticipant]
    let id: Data

    init(_ first: V4RecoveryParticipant, _ second: V4RecoveryParticipant) throws {
        guard first.deviceID != second.deviceID else { throw V4ProtocolError.wrongDevice }
        participants = [first, second].sorted {
            V4HandshakeRecovery.uuidBytes($0.deviceID).lexicographicallyPrecedes(V4HandshakeRecovery.uuidBytes($1.deviceID))
        }
        id = Data(SHA256.hash(data: try V4Handshake.fields("luma.v4.pair.v2", participants.map { try $0.encoded() })))
    }

    func validate() throws {
        guard participants.count == 2, try V4RecoveryPair(participants[0], participants[1]) == self else {
            throw V4ProtocolError.invalidHandshake
        }
    }
}

struct V4ProposalID: Codable, Hashable {
    let bytes: Data
    init(_ bytes: Data) throws {
        guard bytes.count == 32 else { throw V4ProtocolError.invalidHandshake }
        self.bytes = bytes
    }
}

struct V4ConflictID: Codable, Equatable {
    let bytes: Data
    init(pair: Data, proposals: [V4ProposalID]) throws {
        guard pair.count == 32, proposals.count == 2, Set(proposals).count == 2 else {
            throw V4ProtocolError.invalidHandshake
        }
        let sorted = proposals.map(\.bytes).sorted { $0.lexicographicallyPrecedes($1) }
        bytes = Data(SHA256.hash(data: V4Handshake.fields("luma.v4.conflict.v2", [pair] + sorted)))
    }
}

/// An immutable, signed proposal. Its ID is derived, never chosen by the server.
struct V4RecoveryProposal: Codable {
    let protocolVersion: Int
    let pairID: Data
    let header: V4InitialHeader
    var signature: Data

    var transcript: Data {
        V4Handshake.fields("luma.v4.proposal.v2", [V4HandshakeRecovery.integer(protocolVersion),
            pairID, header.transcript(), header.signature])
    }
    var id: V4ProposalID { // fixed SHA-256 size; malformed values never enter the digest initializer
        V4ProposalID.digest(transcript)
    }

    init(pair: V4RecoveryPair, header: V4InitialHeader, identity: V4IdentityKeys) throws {
        protocolVersion = 2; pairID = pair.id; self.header = header; signature = Data()
        signature = try identity.signing.signature(for: transcript)
        try verify(in: pair)
    }

    func verify(in pair: V4RecoveryPair) throws {
        try pair.validate()
        guard protocolVersion == 2, pairID == pair.id, header.protocolVersion == 2,
              header.pairID == pair.id, header.recipientOneTimePreKeyPublicKey?.count == 32,
              let sender = pair.participants.first(where: { $0.deviceID == header.senderDeviceID }),
              let receiver = pair.participants.first(where: { $0.deviceID == header.receiverDeviceID }),
              header.recipientKeyVersion > 0,
              sender.deviceID != receiver.deviceID,
              sender.signingPublicKey == header.senderIdentitySigningPublicKey,
              sender.agreementPublicKey == header.senderIdentityAgreementPublicKey,
              receiver.signingPublicKey == header.recipientIdentitySigningPublicKey,
              receiver.agreementPublicKey == header.recipientIdentityAgreementPublicKey,
              let signer = try? Curve25519.Signing.PublicKey(rawRepresentation: sender.signingPublicKey),
              signer.isValidSignature(header.signature, for: header.transcript()),
              signer.isValidSignature(signature, for: transcript) else { throw V4ProtocolError.invalidHandshake }
    }
}

private extension V4ProposalID {
    static func digest(_ transcript: Data) -> Self { Self(bytes: Data(SHA256.hash(data: transcript))) }
    init(bytes: Data) { self.bytes = bytes }
}

enum V4RecoveryPhase: String, Codable {
    case none, initialCreated, initialSent, initialReceived, conflictDetected, negotiating, established, suspended
}

struct V4RecoveryCoordinator: Codable {
    let pair: V4RecoveryPair
    private(set) var phase: V4RecoveryPhase = .none
    private(set) var revision: UInt64 = 0
    private(set) var proposals: [V4RecoveryProposal] = []
    private(set) var activeProposal: V4ProposalID?
    private(set) var transitions: [V4RecoveryPhase] = []

    mutating func add(_ proposal: V4RecoveryProposal, localDevice: UUID) throws {
        try proposal.verify(in: pair)
        guard pair.participants.contains(where: { $0.deviceID == localDevice }),
              phase != .established, phase != .suspended, proposals.count < 2,
              !proposals.contains(where: { $0.header.senderDeviceID == proposal.header.senderDeviceID }) else {
            throw V4ProtocolError.replay
        }
        if proposals.isEmpty {
            guard phase == .none else { throw V4ProtocolError.invalidHandshake }
            try transition(to: proposal.header.senderDeviceID == localDevice ? .initialCreated : .initialReceived,
                           expectedRevision: revision)
            activeProposal = proposal.id
        } else {
            guard phase == .initialCreated || phase == .initialSent else {
                throw V4ProtocolError.invalidHandshake
            }
            let winner = try V4HandshakeRecovery.winner(proposals[0], proposal)
            try transition(to: .conflictDetected, expectedRevision: revision)
            activeProposal = winner
        }
        proposals.append(proposal)
    }

    func validate(localDevice: UUID) throws {
        try pair.validate()
        guard revision == UInt64(transitions.count), proposals.count <= 2 else { throw V4VaultError.damaged }
        var replay = V4RecoveryCoordinator(pair: pair)
        if let first = proposals.first { try replay.add(first, localDevice: localDevice) }
        while replay.transitions.count < transitions.count {
            let next = transitions[replay.transitions.count]
            if next == .conflictDetected {
                guard proposals.count == 2 else { throw V4VaultError.damaged }
                try replay.add(proposals[1], localDevice: localDevice)
            } else { try replay.transition(to: next, expectedRevision: replay.revision) }
        }
        guard replay.phase == phase, replay.activeProposal == activeProposal,
              replay.transitions == transitions, replay.proposals.map(\.id) == proposals.map(\.id) else {
            throw V4VaultError.damaged
        }
    }

    mutating func transition(to next: V4RecoveryPhase, expectedRevision: UInt64) throws {
        guard revision == expectedRevision, revision < UInt64.max else { throw V4VaultError.rollback }
        let allowed: Bool
        switch (phase, next) {
        case (.none, .initialCreated), (.none, .initialReceived),
             (.initialCreated, .initialSent), (.initialCreated, .conflictDetected),
             (.initialSent, .conflictDetected), (.initialSent, .established),
             (.initialReceived, .established), (.conflictDetected, .negotiating),
             (.negotiating, .established): allowed = true
        case (_, .suspended): allowed = phase != .suspended && phase != .none
        default: allowed = false
        }
        guard allowed else { throw V4ProtocolError.invalidHandshake }
        // Calling code must first validate confirmation/decision proofs. Raw transitions are
        // internal to the Crypto module; they are not network event authority.
        phase = next; revision += 1; transitions.append(next)
    }
}

enum V4HandshakeRecovery {
    static func uuidBytes(_ value: UUID) -> Data {
        var tuple = value.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }
    static func integer(_ value: Int) -> Data {
        var number = UInt64(bitPattern: Int64(value)).bigEndian
        return withUnsafeBytes(of: &number) { Data($0) }
    }
    static func winner(_ first: V4RecoveryProposal, _ second: V4RecoveryProposal) throws -> V4ProposalID {
        guard first.pairID == second.pairID, first.protocolVersion == 2, second.protocolVersion == 2,
              first.header.senderDeviceID != second.header.senderDeviceID,
              first.header.senderDeviceID == second.header.receiverDeviceID,
              second.header.senderDeviceID == first.header.receiverDeviceID else {
            throw V4ProtocolError.invalidHandshake
        }
        return uuidBytes(first.header.senderDeviceID).lexicographicallyPrecedes(uuidBytes(second.header.senderDeviceID))
            ? first.id : second.id
    }
}
