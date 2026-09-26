import CryptoKit
import Foundation

/// Selects a local master key or a locally simulated session key. Both use AES-GCM.
@MainActor
struct MessageEncryptor {
    let local: EncryptionService
    let sessions: SessionManager?

    /// v3 needs a verified recipient device bundle; it is a transport envelope, not a SwiftData blob.
    static func encryptV3(_ plaintext: Data, messageID: UUID, conversationID: UUID,
                          senderDeviceID: UUID, identity: P256.Signing.PrivateKey,
                          recipient: VerifiedDeviceBundle) throws -> DeviceMessageEnvelope {
        try DeviceSessionManager().encrypt(plaintext, messageID: messageID,
            conversationID: conversationID, senderDeviceID: senderDeviceID,
            senderIdentityPrivateKey: identity, recipient: recipient)
    }

    static func decryptV3(_ envelope: DeviceMessageEnvelope, expectedDeviceID: UUID,
                          expectedFingerprint: String, device: P256.KeyAgreement.PrivateKey,
                          signedPreKey: P256.KeyAgreement.PrivateKey,
                          oneTimePreKey: P256.KeyAgreement.PrivateKey?) throws -> Data {
        try DeviceSessionManager().decrypt(envelope, expectedDeviceID: expectedDeviceID,
            expectedFingerprint: expectedFingerprint, devicePrivateKey: device,
            signedPreKeyPrivate: signedPreKey, oneTimePrivateKey: oneTimePreKey)
    }

    func encrypt(_ plaintext: Data, for message: Message, session: SessionKey? = nil) throws -> EncryptedData {
        switch EncryptionVersion(rawValue: message.encryptionVersion ?? 1) {
        case .localAESGCM: return try local.encrypt(plaintext, authenticatedData: binding(for: message))
        case .sessionAESGCM:
            guard let session, let sessions else { throw SessionError.missing }
            let key: SymmetricKey
            if let index = message.messageKeyIndex {
                guard let senderID = message.senderID, let version = message.sessionKeyVersion else { throw RatchetError.invalidIndex }
                key = try RatchetManager(context: sessions.context, keychain: sessions.keychain, sessions: sessions)
                    .key(session: session, senderID: senderID, version: version, index: index)
            } else {
                key = try sessions.key(for: session, version: message.sessionKeyVersion)
            }
            return try EncryptionService(key: key)
                .encrypt(plaintext, authenticatedData: binding(for: message))
        case .deviceEnvelope:
            // v3 is a wire format. RemoteMessageRepository re-encrypts received data as v1 at rest.
            throw MessageStoreError.unsupportedEncryptionVersion
        case nil: throw MessageStoreError.unsupportedEncryptionVersion
        }
    }

    func decrypt(_ encrypted: EncryptedData, for message: Message, session: SessionKey? = nil) throws -> Data {
        switch EncryptionVersion(rawValue: message.encryptionVersion ?? 1) {
        case .localAESGCM: return try local.decrypt(encrypted, authenticatedData: binding(for: message))
        case .sessionAESGCM:
            guard let session, let sessions else { throw SessionError.missing }
            let key: SymmetricKey
            if let index = message.messageKeyIndex {
                guard let senderID = message.senderID, let version = message.sessionKeyVersion else { throw RatchetError.invalidIndex }
                key = try RatchetManager(context: sessions.context, keychain: sessions.keychain, sessions: sessions)
                    .key(session: session, senderID: senderID, version: version, index: index)
            } else {
                key = try sessions.key(for: session, version: message.sessionKeyVersion)
            }
            return try EncryptionService(key: key)
                .decrypt(encrypted, authenticatedData: binding(for: message))
        case .deviceEnvelope:
            throw MessageStoreError.unsupportedEncryptionVersion
        case nil: throw MessageStoreError.unsupportedEncryptionVersion
        }
    }

    private func binding(for message: Message) -> Data {
        let label = message.encryptionVersion == EncryptionVersion.sessionAESGCM.rawValue ? "luma-message-v2" : "luma-message-v1"
        let suffix = message.messageKeyIndex.map { "|\(message.sessionKeyVersion ?? 1)|\($0)" } ?? ""
        return Data("\(label)|\(message.id.uuidString)|\(message.conversationID.uuidString)\(suffix)".utf8)
    }
}
