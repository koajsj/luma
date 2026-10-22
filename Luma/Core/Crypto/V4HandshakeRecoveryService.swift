import CryptoKit
import Foundation

/// Device-pair executor. All mutations and exact ciphertext retries are journaled under
/// the same synchronous lock. Network and SwiftData commits happen outside this lock.
struct V4HandshakeRecoveryService {
    let deviceVault: V4SessionVault
    let userID: String
    let localDevice: UUID
    var vault: V4HandshakeRecoveryVault {
        V4HandshakeRecoveryVault(keychain: deviceVault.keychain, userID: userID, localDevice: localDevice)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    private func device() throws -> V4SessionVault.DeviceSecrets {
        guard let value = try deviceVault.loadDevice(userID: userID, deviceID: localDevice) else {
            throw V4VaultError.missing
        }
        return value
    }

    private func validate(_ pair: V4RecoveryPair) throws {
        try pair.validate()
        let identity = try device().identity()
        guard let own = pair.participants.first(where: { $0.deviceID == localDevice }),
              own.agreementPublicKey == identity.agreement.publicKey.rawRepresentation,
              own.signingPublicKey == identity.signing.publicKey.rawRepresentation,
              let remote = pair.participants.first(where: { $0.deviceID != localDevice }),
              try deviceVault.loadSession(userID: userID, local: localDevice, remote: remote.deviceID) == nil else {
            throw V4ProtocolError.untrustedIdentity
        }
        // Existing peer state is identity-pinned; a new fingerprint is never a new pair automatically.
        for id in try vault.pairs() where id != pair.id {
            let existing = try vault.pending(id)?.next ?? vault.load(id)
            if existing?.coordinator.pair.participants.contains(where: { $0.deviceID == remote.deviceID }) == true {
                throw V4ProtocolError.untrustedIdentity
            }
        }
    }

    func prepare(_ plaintext: Data, messageID: UUID, conversationID: UUID,
                 pair: V4RecoveryPair, recipient: V4PreKeyBundle) throws -> Data {
        try V4HandshakeRecoveryVault.serial {
            try validate(pair)
            try resumePrepared(pair.id)
            if let pending = try vault.pending(pair.id) {
                guard pending.id == messageID, pending.incomingSequence == nil else { throw V4VaultError.pendingOperation }
                return pending.output
            }
            var state = try vault.load(pair.id) ?? V4RecoverySnapshot(coordinator: V4RecoveryCoordinator(pair: pair))
            if let sealed = state.applicationOutbox.first(where: { $0.id == messageID }) {
                guard sealed.conversationID == conversationID, sealed.receiverDeviceID == recipient.deviceID else { throw V4ProtocolError.invalidMessage }
                return sealed.wire
            }
            guard state.applicationOutbox.count < 2_000 else { throw V4VaultError.pendingOperation }
            guard state.coordinator.phase != .suspended,
                  state.coordinator.phase != .conflictDetected,
                  state.coordinator.phase != .negotiating else { throw V4VaultError.pendingOperation }
            if state.candidates.isEmpty {
                guard recipient.recoveryProtocolVersion == 2,
                      pair.participants.contains(where: { $0.deviceID == recipient.deviceID &&
                          $0.agreementPublicKey == recipient.identityAgreementPublicKey &&
                          $0.signingPublicKey == recipient.identitySigningPublicKey }) else { throw V4ProtocolError.untrustedIdentity }
                let identity = try device().identity()
                let result = try V4Handshake.initiate(senderDeviceID: localDevice, identity: identity,
                    recipient: recipient, expectedFingerprint: recipient.identityFingerprint, recoveryPair: pair)
                let proposal = try V4RecoveryProposal(pair: pair, header: result.header, identity: identity)
                try state.coordinator.add(proposal, localDevice: localDevice)
                state.candidates.append(V4RecoveryCandidate(proposal: proposal,
                    ratchet: try .initiator(sharedSecret: result.sharedSecret, ownEphemeral: result.ratchetPrivateKey,
                        remoteSignedPreKey: recipient.signedPreKeyPublicKey), version: 1))
            }
            let wire = try seal(plaintext, id: messageID, conversation: conversationID, state: &state)
            state.applicationOutbox.append(.init(id: messageID, conversationID: conversationID,
                receiverDeviceID: recipient.deviceID, wire: wire))
            if state.coordinator.phase == .initialCreated {
                try state.coordinator.transition(to: .initialSent, expectedRevision: state.coordinator.revision)
            }
            try vault.stage(.init(id: messageID, expectedVersion: state.version, next: state,
                output: wire, incomingSequence: nil))
            return wire
        }
    }

    private func resumePrepared(_ pairID: Data) throws {
        // The per-device encrypted outbox is durable inside the journal itself. It owns the
        // exact envelope even when another target or SwiftData aggregate preparation failed.
        if let pending = try vault.pending(pairID), pending.incomingSequence == nil {
            try vault.finish(pairID, operationID: pending.id)
        }
    }

    func markSubmitted(_ id: UUID) throws {
        try updateApplication(id) { state, index in state.applicationOutbox[index].wasSubmitted = true }
    }

    func acknowledgeApplication(_ id: UUID) throws {
        try updateApplication(id) { state, index in state.applicationOutbox.remove(at: index) }
    }

    /// Only envelopes that provably never entered HTTP may become signed burn entries.
    /// Ambiguous network outcomes retain exact ciphertext and are not mislabelled cancelled.
    func cancelUnsubmitted(_ id: UUID) throws -> Bool {
        try V4HandshakeRecoveryVault.serial {
            for pair in try vault.pairs() { try resumePrepared(pair) }
            let states = try vault.pairs().compactMap { try vault.load($0) }
            guard !states.contains(where: { $0.applicationOutbox.contains(where: { $0.id == id && $0.wasSubmitted }) }) else { return false }
            try updateApplication(id) { state, index in
                for candidate in state.candidates.indices where state.candidates[candidate].sent.contains(where: { $0.messageID == id }) {
                    guard !state.candidates[candidate].frozen else { throw V4VaultError.pendingOperation }
                    state.candidates[candidate].cancelled.append(id)
                    try bump(candidate, state: &state)
                }
                state.applicationOutbox.remove(at: index)
            }
            return true
        }
    }

    private func updateApplication(_ id: UUID, change: (inout V4RecoverySnapshot, Int) throws -> Void) throws {
        try V4HandshakeRecoveryVault.serial {
            for pair in try vault.pairs() {
                try resumePrepared(pair)
                guard var state = try vault.load(pair), let index = state.applicationOutbox.firstIndex(where: { $0.id == id }) else { continue }
                guard try vault.pending(pair) == nil else { throw V4VaultError.pendingOperation }
                try change(&state, index)
                let operation = UUID()
                try vault.stage(.init(id: operation, expectedVersion: state.version, next: state, output: Data(), incomingSequence: nil))
                try vault.finish(pair, operationID: operation)
            }
        }
    }

    func commit(_ id: UUID) throws {
        try V4HandshakeRecoveryVault.serial {
            for (pair, _) in try vault.pendingForOperation(id) { try vault.finish(pair, operationID: id) }
        }
    }
    func finish(_ eventID: UUID) throws { try commit(eventID) }

    func controls() throws -> [V4RecoveryControlOutbox] {
        try V4HandshakeRecoveryVault.serial {
            try vault.pairs().flatMap { try vault.load($0)?.outbox ?? [] }
        }
    }

    func acknowledgeControl(_ id: UUID, pairID: Data) throws {
        try V4HandshakeRecoveryVault.serial {
            guard try vault.pending(pairID) == nil else { throw V4VaultError.pendingOperation }
            guard var state = try vault.load(pairID), state.outbox.contains(where: { $0.id == id }) else { return }
            state.outbox.removeAll { $0.id == id }
            let operation = UUID()
            try vault.stage(.init(id: operation, expectedVersion: state.version, next: state,
                output: Data(), incomingSequence: nil))
            try vault.finish(pairID, operationID: operation)
        }
    }

    func receive(_ wire: Data, eventID: UUID, deviceSeq: Int64, pair: V4RecoveryPair, control: Bool) throws -> Data {
        try V4HandshakeRecoveryVault.serial {
            try validate(pair)
            guard deviceSeq > 0, wire.count <= 1_048_576 else { throw V4ProtocolError.invalidMessage }
            let digest = Data(SHA256.hash(data: wire))
            try resumePrepared(pair.id)
            if let pending = try vault.pending(pair.id) {
                guard pending.id == eventID, pending.incomingSequence == deviceSeq,
                      pending.envelopeDigest == digest else { throw V4VaultError.pendingOperation }
                return pending.output
            }
            let message = try JSONDecoder().decode(V4RatchetMessage.self, from: wire)
            guard let proposal = message.recoveryProposal, message.sessionVersion == 1,
                  message.receiverDeviceID == localDevice,
                  pair.participants.contains(where: { $0.deviceID == message.senderDeviceID }),
                  message.senderDeviceID != localDevice else { throw V4ProtocolError.invalidHandshake }
            try proposal.verify(in: pair)
            if let header = message.initialHeader {
                guard header.transcript() == proposal.header.transcript(), header.signature == proposal.header.signature else {
                    throw V4ProtocolError.invalidHandshake
                }
            }
            var state = try vault.load(pair.id) ?? V4RecoverySnapshot(coordinator: V4RecoveryCoordinator(pair: pair))
            guard state.coordinator.phase != .suspended else { throw V4ProtocolError.untrustedIdentity }
            // Strict event-ID/inner-ID binding for control routing; retries cannot relabel a control.
            if control { guard eventID == message.messageID else { throw V4ProtocolError.invalidMessage } }
            var consumed: [V4RecoveryPreKeyConsumption] = []
            if !state.candidates.contains(where: { $0.proposal.id == proposal.id }) {
                guard message.initialHeader != nil, state.coordinator.phase != .established else {
                    throw V4ProtocolError.invalidHandshake
                }
                try importCandidate(proposal, state: &state, consumed: &consumed)
            }
            guard let index = state.candidates.firstIndex(where: { $0.proposal.id == proposal.id }),
                  !state.candidates[index].retired else { throw V4ProtocolError.invalidHandshake }
            let entry = sealedEntry(message, wire: wire)
            if state.candidates[index].frozen && proposal.id != state.coordinator.activeProposal {
                if let bytes = state.frozenManifest {
                    let manifest = try JSONDecoder().decode(V4FrozenManifest.self, from: bytes)
                    guard manifest.permits(entry) else { throw V4ProtocolError.invalidMessage }
                } else {
                    // Before the authenticated offer only the original, bounded initiator chain is receivable.
                    guard message.ratchetPublicKey == proposal.header.senderEphemeralPublicKey,
                          message.messageIndex < 2_000 else { throw V4ProtocolError.invalidMessage }
                }
            }
            guard var ratchet = state.candidates[index].ratchet else { throw V4ProtocolError.replay }
            let plaintext = try ratchet.decrypt(message, expectedReceiver: localDevice,
                expectedSender: message.senderDeviceID, expectedConversation: message.conversationID)
            state.candidates[index].ratchet = ratchet
            try bump(index, state: &state)
            if !control && (state.coordinator.phase != .established || proposal.id != state.coordinator.activeProposal) {
                state.candidates[index].received.append(entry)
            }
            if control {
                let value = try JSONDecoder().decode(V4SessionControl.self, from: plaintext)
                try value.verify(pair: pair, expectedActor: message.senderDeviceID, conversation: message.conversationID)
                guard value.controlID == message.messageID, value.winner == proposal.id,
                      state.processedControls[value.controlID.uuidString] == nil,
                      state.processedControls.count < 32 else { throw V4ProtocolError.replay }
                // The encrypted, identity-signed control can authenticate the peer proposal before its application message.
                for candidate in value.proposals where !state.candidates.contains(where: { $0.proposal.id == candidate.id }) {
                    try importCandidate(candidate, state: &state, consumed: &consumed)
                }
                try apply(value, state: &state)
                state.processedControls[value.controlID.uuidString] = digest
            }
            try negotiate(conversation: message.conversationID, state: &state)
            if !control && state.coordinator.phase == .initialReceived && !state.offered {
                try queue(.confirm, conversation: message.conversationID, state: &state)
                state.offered = true
            }
            try queueDrainIfComplete(conversation: message.conversationID, state: &state)
            if state.coordinator.phase == .established, state.committed, state.drainAcknowledged,
               let loser = state.candidates.firstIndex(where: { $0.proposal.id != state.coordinator.activeProposal }),
               !state.candidates[loser].retired {
                state.candidates[loser].ratchet = nil
                state.candidates[loser].retired = true
                try bump(loser, state: &state)
            }
            // Reservations are written only after all AEAD/signature/decision checks succeed.
            let operation = V4RecoveryOperation(id: eventID, expectedVersion: state.version, next: state,
                output: control ? Data() : plaintext, incomingSequence: deviceSeq,
                envelopeDigest: digest, consumedPreKeys: consumed)
            try vault.stage(operation)
            return operation.output
        }
    }

    private func importCandidate(_ proposal: V4RecoveryProposal, state: inout V4RecoverySnapshot,
                                 consumed: inout [V4RecoveryPreKeyConsumption]) throws {
        let header = proposal.header
        guard header.senderDeviceID != localDevice, header.receiverDeviceID == localDevice,
              let otp = header.recipientOneTimePreKeyPublicKey else { throw V4ProtocolError.invalidHandshake }
        try proposal.verify(in: state.coordinator.pair)
        try vault.verifyReservation(otp, proposal: proposal.id)
        let own = try device(), identity = try own.identity(), signed = try own.signedKey()
        let secret = try V4Handshake.accept(header, expectedDeviceID: localDevice,
            expectedKeyVersion: own.keyVersion,
            expectedSenderFingerprint: V4Handshake.fingerprint(signing: header.senderIdentitySigningPublicKey,
                agreement: header.senderIdentityAgreementPublicKey),
            identity: identity, signedPreKey: signed, oneTimePreKey: own.oneTimeKey(publicKey: otp))
        try state.coordinator.add(proposal, localDevice: localDevice)
        state.candidates.append(.init(proposal: proposal,
            ratchet: .responder(sharedSecret: secret, ownSignedPreKey: signed), version: 1))
        consumed.append(.init(publicKey: otp, proposal: proposal.id))
    }

    private func seal(_ plaintext: Data, id: UUID, conversation: UUID, control: Bool = false, state: inout V4RecoverySnapshot) throws -> Data {
        guard let index = state.candidates.firstIndex(where: { $0.proposal.id == state.coordinator.activeProposal }),
              !state.candidates[index].frozen, !state.candidates[index].retired,
              (control || state.coordinator.phase == .established || state.candidates[index].sent.count < 2_000) else { throw V4VaultError.pendingOperation }
        let proposal = state.candidates[index].proposal
        let remote = try peer(state.coordinator.pair)
        guard var ratchet = state.candidates[index].ratchet else { throw V4ProtocolError.invalidHandshake }
        let message = try ratchet.encrypt(plaintext, messageID: id, conversationID: conversation,
            senderDeviceID: localDevice, receiverDeviceID: remote,
            initialHeader: state.coordinator.phase == .established ? nil : proposal.header,
            recoveryProposal: proposal)
        state.candidates[index].ratchet = ratchet
        try bump(index, state: &state)
        let bytes = try encode(message)
        if !control && state.coordinator.phase != .established {
            state.candidates[index].sent.append(sealedEntry(message, wire: bytes))
        }
        return bytes
    }

    private func bump(_ index: Int, state: inout V4RecoverySnapshot) throws {
        guard state.candidates[index].version < UInt64.max else { throw V4VaultError.rollback }
        // Version is the next durable transaction, not the number of encrypt/decrypt steps inside it.
        let previous = try vault.load(state.coordinator.pair.id)?.candidates.first(where: {
            $0.proposal.id == state.candidates[index].proposal.id
        })?.version ?? 0
        guard previous < UInt64.max else { throw V4VaultError.rollback }
        state.candidates[index].version = previous + 1
    }

    private func peer(_ pair: V4RecoveryPair) throws -> UUID {
        guard let value = pair.participants.first(where: { $0.deviceID != localDevice }) else { throw V4ProtocolError.wrongDevice }
        return value.deviceID
    }

    private func sealedEntry(_ message: V4RatchetMessage, wire: Data) -> V4RecoverySealedEntry {
        .init(messageID: message.messageID, conversationID: message.conversationID,
            ratchetPublicKey: message.ratchetPublicKey, index: message.messageIndex, digest: Data(SHA256.hash(data: wire)))
    }

    private func queue(_ kind: V4SessionControl.Kind, conversation: UUID,
                       manifest: V4FrozenManifest? = nil, state: inout V4RecoverySnapshot) throws {
        let value = try V4SessionControl(kind: kind, conversationID: conversation, actor: localDevice,
            pair: state.coordinator.pair, proposals: state.coordinator.proposals,
            manifest: manifest, identity: device().identity())
        let wire = try seal(encode(value), id: value.controlID, conversation: conversation, control: true, state: &state)
        state.outbox.append(.init(id: value.controlID, conversationID: conversation,
            receiverDeviceID: try peer(state.coordinator.pair), wire: wire))
    }

    private func negotiate(conversation: UUID, state: inout V4RecoverySnapshot) throws {
        guard state.coordinator.phase == .conflictDetected else { return }
        guard let loser = state.candidates.firstIndex(where: { $0.proposal.id != state.coordinator.activeProposal }) else {
            throw V4ProtocolError.invalidHandshake
        }
        state.candidates[loser].frozen = true
        try bump(loser, state: &state)
        try state.coordinator.transition(to: .negotiating, expectedRevision: state.coordinator.revision)
        if state.candidates[loser].proposal.header.senderDeviceID == localDevice {
            let manifest = try V4FrozenManifest(pair: state.coordinator.pair, proposals: state.coordinator.proposals,
                loser: state.candidates[loser].proposal.id, entries: state.candidates[loser].sent.map {
                    var entry = $0; entry.cancelled = state.candidates[loser].cancelled.contains(entry.messageID); return entry
                },
                cutoff: state.candidates[loser].ratchet?.sendingIndex ?? -1, identity: device().identity())
            state.frozenManifest = try encode(manifest); state.decisionDigest = manifest.digest
            try queue(.resolveOffer, conversation: conversation, manifest: manifest, state: &state)
            state.offered = true
        } else if state.frozenManifest == nil {
            try queue(.resolveRequest, conversation: conversation, state: &state)
        }
    }

    private func apply(_ control: V4SessionControl, state: inout V4RecoverySnapshot) throws {
        guard Set(control.proposals.map(\.id)) == Set(state.coordinator.proposals.map(\.id)),
              control.winner == state.coordinator.activeProposal else { throw V4ProtocolError.invalidHandshake }
        let winnerInitiator = state.coordinator.proposals.first(where: { $0.id == control.winner })?.header.senderDeviceID
        switch control.kind {
        case .confirm:
            guard state.coordinator.phase == .initialSent, winnerInitiator == localDevice else { throw V4ProtocolError.invalidHandshake }
            try queue(.confirmAck, conversation: control.conversationID, state: &state)
            try state.coordinator.transition(to: .established, expectedRevision: state.coordinator.revision)
        case .confirmAck:
            guard state.coordinator.phase == .initialReceived, state.offered,
                  winnerInitiator == control.actorDeviceID else { throw V4ProtocolError.invalidHandshake }
            try state.coordinator.transition(to: .established, expectedRevision: state.coordinator.revision)
        case .resolveRequest:
            guard winnerInitiator == control.actorDeviceID else { throw V4ProtocolError.invalidHandshake }
            if state.coordinator.phase == .established {
                // A genuinely signed request can arrive after its offer/ack/commit exchange.
                // Consume its authenticated skipped key and record its ID, but never change
                // the committed decision or reopen either candidate's sending authority.
                guard state.committed, state.decisionDigest != nil, state.frozenManifest != nil else {
                    throw V4ProtocolError.invalidHandshake
                }
            } else {
                guard state.coordinator.phase == .conflictDetected || state.coordinator.phase == .negotiating else {
                    throw V4ProtocolError.invalidHandshake
                }
            }
        case .resolveOffer:
            guard winnerInitiator == localDevice, !state.acknowledged,
                  state.coordinator.phase == .conflictDetected || state.coordinator.phase == .negotiating,
                  let manifest = control.manifest else { throw V4ProtocolError.invalidHandshake }
            guard let loser = state.candidates.first(where: { $0.proposal.id == manifest.loser }),
                  loser.received.allSatisfy({ manifest.permits($0) }) else { throw V4ProtocolError.invalidHandshake }
            state.frozenManifest = try encode(manifest); state.decisionDigest = manifest.digest
            // Freeze/select before creating any response on the winner chain.
            try negotiate(conversation: control.conversationID, state: &state)
            try queue(.resolveAck, conversation: control.conversationID, manifest: manifest, state: &state)
            state.acknowledged = true
        case .resolveAck:
            guard winnerInitiator == control.actorDeviceID, state.offered, !state.committed,
                  state.coordinator.phase == .negotiating, let manifest = control.manifest,
                  state.decisionDigest == manifest.digest else { throw V4ProtocolError.invalidHandshake }
            try queue(.resolveCommit, conversation: control.conversationID, manifest: manifest, state: &state)
            state.committed = true
            try state.coordinator.transition(to: .established, expectedRevision: state.coordinator.revision)
        case .resolveCommit:
            guard winnerInitiator == localDevice, state.acknowledged, !state.committed,
                  state.coordinator.phase == .negotiating, let manifest = control.manifest,
                  state.decisionDigest == manifest.digest else { throw V4ProtocolError.invalidHandshake }
            state.committed = true
            try state.coordinator.transition(to: .established, expectedRevision: state.coordinator.revision)
        case .drainAck:
            guard winnerInitiator == control.actorDeviceID, let manifest = control.manifest,
                  state.decisionDigest == manifest.digest, state.offered else { throw V4ProtocolError.invalidHandshake }
            state.drainAcknowledged = true
        }
    }

    private func queueDrainIfComplete(conversation: UUID, state: inout V4RecoverySnapshot) throws {
        guard state.acknowledged, !state.drainAcknowledged, let bytes = state.frozenManifest else { return }
        let manifest = try JSONDecoder().decode(V4FrozenManifest.self, from: bytes)
        guard let loser = state.candidates.first(where: { $0.proposal.id == manifest.loser }),
              manifest.entries.allSatisfy({ $0.cancelled || loser.received.contains($0) }) else { return }
        try queue(.drainAck, conversation: conversation, manifest: manifest, state: &state)
        state.drainAcknowledged = true
    }
}
