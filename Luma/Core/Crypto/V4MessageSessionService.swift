import CryptoKit
import Foundation

struct V4SendTarget {
    let remoteUserID: UUID
    let bundle: V4PreKeyBundle
}

private struct V4WireRecipient: Codable {
    let recipientDeviceID: String
    let ciphertext: String
    let keyVersion: Int
    let messageKeyIndex: Int64
}

private struct V4WireRequest: Codable {
    let messageID: UUID
    let conversationID: UUID
    let encryptionVersion: Int
    let recipientEnvelopes: [V4WireRecipient]
    let attachmentIDs: [UUID]?
}

private struct V4EventWireRequest: Encodable {
    let eventID: UUID
    let messageID: UUID
    let conversationID: UUID
    let type: String
    let revision: Int
    let recipientEnvelopes: [V4WireRecipient]
}

/// Produces backend-compatible opaque envelopes while journaling every ratchet advance
/// in Keychain. The repository commits the prepared outbox before finalizing this journal.
struct V4MessageSessionService {
    let vault: V4SessionVault
    let userID: String
    let localDeviceID: UUID

    init(vault: V4SessionVault = V4SessionVault(), userID: String, localDeviceID: UUID) {
        self.vault = vault; self.userID = userID; self.localDeviceID = localDeviceID
    }

    func prepare(_ plaintext: Data, messageID: UUID, conversationID: UUID,
                 targets: [V4SendTarget], attachmentIDs: [UUID]? = nil) throws -> Data {
        if let pending = try vault.outgoingPending(userID: userID, deviceID: localDeviceID) {
            guard pending.messageID == messageID else { throw V4VaultError.pendingOperation }
            return pending.request
        }
        guard !targets.isEmpty, targets.count <= 32,
              Set(targets.map(\.bundle.deviceID)).count == targets.count,
              let device = try vault.loadDevice(userID: userID, deviceID: localDeviceID) else {
            throw V4VaultError.missing
        }
        let identity = try device.identity()
        var candidates: [V4SessionVault.Session] = []
        var envelopes: [V4WireRecipient] = []
        for target in targets {
            let bundle = target.bundle
            guard bundle.deviceID != localDeviceID else { throw V4ProtocolError.wrongDevice }
            try V4Handshake.verify(bundle, expectedFingerprint: bundle.identityFingerprint)
            var session: V4SessionVault.Session
            if let existing = try vault.loadSession(userID: userID, local: localDeviceID,
                                                    remote: bundle.deviceID) {
                guard existing.remoteUserID == target.remoteUserID,
                      existing.remoteIdentityFingerprint == bundle.identityFingerprint,
                      bundle.keyVersion >= existing.recipientKeyVersion else {
                    throw V4ProtocolError.untrustedIdentity
                }
                session = existing
            } else {
                let initiated = try V4Handshake.initiate(senderDeviceID: localDeviceID,
                    identity: identity, recipient: bundle,
                    expectedFingerprint: bundle.identityFingerprint)
                let ratchet = try V4RatchetState.initiator(sharedSecret: initiated.sharedSecret,
                    ownEphemeral: initiated.ratchetPrivateKey,
                    remoteSignedPreKey: bundle.signedPreKeyPublicKey)
                session = V4SessionVault.Session(formatVersion: 1, localDeviceID: localDeviceID,
                    remoteDeviceID: bundle.deviceID, remoteUserID: target.remoteUserID,
                    remoteIdentityFingerprint: bundle.identityFingerprint, sessionVersion: 1,
                    recipientKeyVersion: bundle.keyVersion, ratchet: ratchet,
                    initialHeader: initiated.header)
            }
            let sealed = try session.ratchet.encrypt(plaintext, messageID: messageID,
                conversationID: conversationID, senderDeviceID: localDeviceID,
                receiverDeviceID: bundle.deviceID, initialHeader: session.initialHeader,
                sessionVersion: session.sessionVersion)
            session.initialHeader = nil
            guard session.stateVersion < UInt64.max else { throw V4VaultError.rollback }
            session.stateVersion += 1
            candidates.append(session)
            envelopes.append(V4WireRecipient(recipientDeviceID: bundle.deviceID.uuidString.lowercased(),
                ciphertext: try JSONEncoder().encode(sealed).base64URLEncodedString(),
                keyVersion: session.recipientKeyVersion, messageKeyIndex: Int64(sealed.messageIndex)))
        }
        let request = try JSONEncoder().encode(V4WireRequest(messageID: messageID,
            conversationID: conversationID, encryptionVersion: 4,
            recipientEnvelopes: envelopes, attachmentIDs: attachmentIDs))
        try vault.stageOutgoing(.init(messageID: messageID, request: request, sessions: candidates),
            userID: userID, deviceID: localDeviceID)
        return request
    }

    func commitPreparedSend(messageID: UUID) throws {
        try vault.finishOutgoing(userID: userID, deviceID: localDeviceID, messageID: messageID)
    }

    /// The inner ratchet message ID is the mutation event ID. It is part of AES-GCM
    /// authenticated data, so changing the outer routing metadata cannot relabel it.
    func prepareEvent(_ event: V4EventEnvelope, targets: [V4SendTarget]) throws -> Data {
        let inner = try prepare(JSONEncoder().encode(event), messageID: event.eventID,
            conversationID: event.conversationID, targets: targets)
        let wire = try JSONDecoder().decode(V4WireRequest.self, from: inner)
        guard wire.messageID == event.eventID, wire.conversationID == event.conversationID,
              wire.encryptionVersion == 4 else { throw V4ProtocolError.invalidMessage }
        return try JSONEncoder().encode(V4EventWireRequest(eventID: event.eventID,
            messageID: event.messageID, conversationID: event.conversationID,
            type: event.kind.rawValue, revision: event.revision ?? 0,
            recipientEnvelopes: wire.recipientEnvelopes))
    }

    func decrypt(_ envelope: V4RatchetMessage, wire: Data, eventID: UUID, deviceSeq: Int64,
                 senderUserID: UUID, senderBundle: V4PreKeyBundle) throws -> Data {
        guard envelope.encryptionVersion == 4, envelope.receiverDeviceID == localDeviceID,
              envelope.senderDeviceID == senderBundle.deviceID else { throw V4ProtocolError.invalidMessage }
        let digest = Data(SHA256.hash(data: wire))
        if let pending = try vault.incomingPending(userID: userID, deviceID: localDeviceID) {
            guard pending.eventID == eventID, pending.deviceSeq == deviceSeq,
                  pending.envelopeDigest == digest else { throw V4VaultError.pendingOperation }
            return pending.plaintext
        }
        guard let device = try vault.loadDevice(userID: userID, deviceID: localDeviceID) else {
            throw V4VaultError.missing
        }
        var session: V4SessionVault.Session
        var oneTimePublicKey: Data?
        if let existing = try vault.loadSession(userID: userID, local: localDeviceID,
                                                remote: envelope.senderDeviceID) {
            guard existing.remoteUserID == senderUserID,
                  existing.remoteIdentityFingerprint == senderBundle.identityFingerprint,
                  senderBundle.keyVersion >= existing.recipientKeyVersion,
                  existing.sessionVersion == envelope.sessionVersion,
                  envelope.initialHeader == nil else { throw V4ProtocolError.untrustedIdentity }
            session = existing
        } else {
            guard let header = envelope.initialHeader,
                  header.senderDeviceID == envelope.senderDeviceID,
                  header.receiverDeviceID == localDeviceID,
                  header.senderIdentityAgreementPublicKey == senderBundle.identityAgreementPublicKey,
                  header.senderIdentitySigningPublicKey == senderBundle.identitySigningPublicKey,
                  header.recipientKeyVersion == device.keyVersion,
                  envelope.sessionVersion == 1 else { throw V4ProtocolError.invalidHandshake }
            let signed = try device.signedKey()
            let oneTime = try header.recipientOneTimePreKeyPublicKey.map { try device.oneTimeKey(publicKey: $0) }
            let secret = try V4Handshake.accept(header, expectedDeviceID: localDeviceID,
                expectedKeyVersion: device.keyVersion,
                expectedSenderFingerprint: senderBundle.identityFingerprint,
                identity: try device.identity(), signedPreKey: signed,
                oneTimePreKey: oneTime)
            session = V4SessionVault.Session(formatVersion: 1, localDeviceID: localDeviceID,
                remoteDeviceID: envelope.senderDeviceID, remoteUserID: senderUserID,
                remoteIdentityFingerprint: senderBundle.identityFingerprint, sessionVersion: 1,
                recipientKeyVersion: senderBundle.keyVersion,
                ratchet: V4RatchetState.responder(sharedSecret: secret, ownSignedPreKey: signed),
                initialHeader: nil)
            oneTimePublicKey = header.recipientOneTimePreKeyPublicKey
        }
        let plaintext = try session.ratchet.decrypt(envelope, expectedReceiver: localDeviceID,
            expectedSender: envelope.senderDeviceID, expectedConversation: envelope.conversationID)
        guard session.stateVersion < UInt64.max else { throw V4VaultError.rollback }
        session.stateVersion += 1
        try vault.stageIncoming(.init(eventID: eventID, deviceSeq: deviceSeq,
            plaintext: plaintext, envelopeDigest: digest, session: session,
            consumedOneTimePublicKey: oneTimePublicKey), userID: userID, deviceID: localDeviceID)
        return plaintext
    }

    func finishReceived(eventID: UUID) throws {
        try vault.finishIncoming(userID: userID, deviceID: localDeviceID, eventID: eventID)
    }

    func recoverReceived(committedCursor: Int64) throws {
        try vault.recoverIncoming(userID: userID, deviceID: localDeviceID,
            committedCursor: committedCursor)
    }
}
