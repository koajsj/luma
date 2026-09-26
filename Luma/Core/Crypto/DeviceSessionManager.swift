import CryptoKit
import Foundation

/// Wire format v3. The whole JSON object is stored as opaque bytes in a backend envelope.
/// Header fields are visible to the server; `ciphertext` alone contains the private payload.
struct DeviceMessageEnvelope: Codable {
    let messageID: UUID
    let conversationID: UUID
    let senderDeviceID: UUID
    let receiverDeviceID: UUID
    let encryptionVersion: Int
    let keyVersion: Int
    let messageKeyIndex: Int64
    let ephemeralPublicKey: Data
    let senderIdentityPublicKey: Data
    let recipientSignedPreKey: Data
    let recipientOneTimePreKey: Data?
    let nonce: Data
    let ciphertext: Data
    let authenticationTag: Data
    let createdAtMilliseconds: Int64
    let signature: Data

    func authenticatedHeader() -> Data {
        var data = Data("luma.device-envelope.v3".utf8)
        for value in [messageID.uuidString.lowercased(), conversationID.uuidString.lowercased(),
                      senderDeviceID.uuidString.lowercased(), receiverDeviceID.uuidString.lowercased(),
                      String(encryptionVersion), String(keyVersion), String(messageKeyIndex),
                      String(createdAtMilliseconds)] {
            Self.append(Data(value.utf8), to: &data)
        }
        for value in [ephemeralPublicKey, senderIdentityPublicKey, recipientSignedPreKey,
                      recipientOneTimePreKey ?? Data()] { Self.append(value, to: &data) }
        return data
    }

    func signedBytes() -> Data {
        var data = authenticatedHeader()
        for value in [nonce, ciphertext, authenticationTag] { Self.append(value, to: &data) }
        return data
    }

    private static func append(_ value: Data, to data: inout Data) {
        var length = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }
}

struct RemoteDevicePreKeyBundle: Decodable {
    let identityPublicKey: String
    let identityKeyVersion: Int
    let deviceID: UUID
    let devicePublicKey: String
    let signedPreKey: String
    let signature: String
    let keyVersion: Int
    let oneTimePreKey: String

    func verified(expectedFingerprint: String) throws -> VerifiedDeviceBundle {
        guard identityKeyVersion > 0, keyVersion > 0,
              let identity = Data(base64URL: identityPublicKey),
              let device = Data(base64URL: devicePublicKey),
              let prekey = Data(base64URL: signedPreKey),
              let signature = Data(base64URL: signature),
              let identityVerifier = try? P256.Signing.PublicKey(x963Representation: identity),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              identityVerifier.isValidSignature(parsed, for: prekey),
              (try? P256.KeyAgreement.PublicKey(x963Representation: device)) != nil,
              (try? P256.KeyAgreement.PublicKey(x963Representation: prekey)) != nil,
              IdentityFingerprint.make(publicKey: identity) == expectedFingerprint else {
            throw DeviceSessionError.untrustedIdentity
        }
        let oneTime = oneTimePreKey.isEmpty ? nil : Data(base64URL: oneTimePreKey)
        if !oneTimePreKey.isEmpty && (oneTime.flatMap { try? P256.KeyAgreement.PublicKey(x963Representation: $0) } == nil) {
            throw DeviceSessionError.invalidEnvelope
        }
        return VerifiedDeviceBundle(deviceID: deviceID, identityPublicKey: identity,
                                    devicePublicKey: device, signedPreKey: prekey,
                                    oneTimePreKey: oneTime, keyVersion: keyVersion)
    }
}

struct VerifiedDeviceBundle {
    let deviceID: UUID
    let identityPublicKey: Data
    let devicePublicKey: Data
    let signedPreKey: Data
    let oneTimePreKey: Data?
    let keyVersion: Int
}

enum DeviceSessionError: LocalizedError {
    case untrustedIdentity, invalidEnvelope, wrongDevice, missingPreKey, authenticationFailed, unsupportedVersion
    var errorDescription: String? {
        switch self {
        case .untrustedIdentity: "对方身份指纹或预密钥签名未通过验证"
        case .invalidEnvelope: "设备消息信封无效"
        case .wrongDevice: "消息并非发给当前设备"
        case .missingPreKey: "接收预密钥不可用，暂不能确认此事件"
        case .authenticationFailed: "设备消息验证或解密失败"
        case .unsupportedVersion: "不支持此设备消息加密版本"
        }
    }
}

extension Data {
    init?(base64URL: String) {
        let value = base64URL.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
}

/// A fresh one-message device session per recipient. No persistent root key or Double Ratchet is claimed.
/// The signed prekey and optional claimed one-time prekey bind the recipient's key material.
struct DeviceSessionManager {
    func encrypt(_ plaintext: Data, messageID: UUID, conversationID: UUID, senderDeviceID: UUID,
                 senderIdentityPrivateKey: P256.Signing.PrivateKey, recipient: VerifiedDeviceBundle,
                 createdAt: Date = .now) throws -> DeviceMessageEnvelope {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let index = Int64.random(in: 0...Int64.max)
        let header = DeviceMessageEnvelope(messageID: messageID, conversationID: conversationID,
            senderDeviceID: senderDeviceID, receiverDeviceID: recipient.deviceID,
            encryptionVersion: 3, keyVersion: recipient.keyVersion, messageKeyIndex: index,
            ephemeralPublicKey: ephemeral.publicKey.x963Representation,
            senderIdentityPublicKey: senderIdentityPrivateKey.publicKey.x963Representation,
            recipientSignedPreKey: recipient.signedPreKey,
            recipientOneTimePreKey: recipient.oneTimePreKey,
            nonce: Data(), ciphertext: Data(), authenticationTag: Data(), createdAtMilliseconds: Int64(createdAt.timeIntervalSince1970 * 1_000), signature: Data())
        let key = try derive(ephemeral: ephemeral, recipient: recipient, header: header.authenticatedHeader())
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: header.authenticatedHeader())
        let unsigned = DeviceMessageEnvelope(messageID: header.messageID, conversationID: header.conversationID,
            senderDeviceID: header.senderDeviceID, receiverDeviceID: header.receiverDeviceID,
            encryptionVersion: 3, keyVersion: header.keyVersion, messageKeyIndex: index,
            ephemeralPublicKey: header.ephemeralPublicKey, senderIdentityPublicKey: header.senderIdentityPublicKey,
            recipientSignedPreKey: header.recipientSignedPreKey, recipientOneTimePreKey: header.recipientOneTimePreKey,
            nonce: sealed.nonce.withUnsafeBytes { Data($0) }, ciphertext: sealed.ciphertext,
            authenticationTag: sealed.tag, createdAtMilliseconds: Int64(createdAt.timeIntervalSince1970 * 1_000), signature: Data())
        let signature = try senderIdentityPrivateKey.signature(for: unsigned.signedBytes()).derRepresentation
        return DeviceMessageEnvelope(messageID: unsigned.messageID, conversationID: unsigned.conversationID,
            senderDeviceID: unsigned.senderDeviceID, receiverDeviceID: unsigned.receiverDeviceID,
            encryptionVersion: 3, keyVersion: unsigned.keyVersion, messageKeyIndex: unsigned.messageKeyIndex,
            ephemeralPublicKey: unsigned.ephemeralPublicKey, senderIdentityPublicKey: unsigned.senderIdentityPublicKey,
            recipientSignedPreKey: unsigned.recipientSignedPreKey, recipientOneTimePreKey: unsigned.recipientOneTimePreKey,
            nonce: unsigned.nonce, ciphertext: unsigned.ciphertext,
            authenticationTag: unsigned.authenticationTag, createdAtMilliseconds: unsigned.createdAtMilliseconds, signature: signature)
    }

    func decrypt(_ envelope: DeviceMessageEnvelope, expectedDeviceID: UUID, expectedFingerprint: String,
                 devicePrivateKey: P256.KeyAgreement.PrivateKey,
                 signedPreKeyPrivate: P256.KeyAgreement.PrivateKey,
                 oneTimePrivateKey: P256.KeyAgreement.PrivateKey?) throws -> Data {
        guard envelope.encryptionVersion == 3 else { throw DeviceSessionError.unsupportedVersion }
        guard envelope.receiverDeviceID == expectedDeviceID else { throw DeviceSessionError.wrongDevice }
        guard envelope.keyVersion > 0, envelope.messageKeyIndex >= 0,
              envelope.nonce.count == 12, envelope.authenticationTag.count == 16,
              envelope.ciphertext.count <= 1_048_576,
              envelope.recipientSignedPreKey == signedPreKeyPrivate.publicKey.x963Representation,
              (envelope.recipientOneTimePreKey == nil && oneTimePrivateKey == nil) ||
                envelope.recipientOneTimePreKey == oneTimePrivateKey?.publicKey.x963Representation,
              IdentityFingerprint.make(publicKey: envelope.senderIdentityPublicKey) == expectedFingerprint,
              let verifier = try? P256.Signing.PublicKey(x963Representation: envelope.senderIdentityPublicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: envelope.signature),
              verifier.isValidSignature(signature, for: envelope.signedBytes()) else {
            throw DeviceSessionError.authenticationFailed
        }
        do {
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: envelope.ephemeralPublicKey)
            let root = Self.material([
                try devicePrivateKey.sharedSecretFromKeyAgreement(with: peer),
                try signedPreKeyPrivate.sharedSecretFromKeyAgreement(with: peer)
            ] + (try oneTimePrivateKey.map { [try $0.sharedSecretFromKeyAgreement(with: peer)] } ?? []))
            let key = Self.messageKey(root: root, header: envelope.authenticatedHeader())
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: envelope.nonce),
                                             ciphertext: envelope.ciphertext, tag: envelope.authenticationTag)
            return try AES.GCM.open(box, using: key, authenticating: envelope.authenticatedHeader())
        } catch { throw DeviceSessionError.authenticationFailed }
    }

    private func derive(ephemeral: P256.KeyAgreement.PrivateKey, recipient: VerifiedDeviceBundle,
                        header: Data) throws -> SymmetricKey {
        let device = try P256.KeyAgreement.PublicKey(x963Representation: recipient.devicePublicKey)
        let signed = try P256.KeyAgreement.PublicKey(x963Representation: recipient.signedPreKey)
        var secrets = try [ephemeral.sharedSecretFromKeyAgreement(with: device),
                           ephemeral.sharedSecretFromKeyAgreement(with: signed)]
        if let oneTime = recipient.oneTimePreKey {
            secrets.append(try ephemeral.sharedSecretFromKeyAgreement(with:
                P256.KeyAgreement.PublicKey(x963Representation: oneTime)))
        }
        return Self.messageKey(root: Self.material(secrets), header: header)
    }

    private static func material(_ secrets: [SharedSecret]) -> SymmetricKey {
        var bytes = Data()
        for secret in secrets { secret.withUnsafeBytes { bytes.append(contentsOf: $0) } }
        return SymmetricKey(data: bytes)
    }

    private static func messageKey(root: SymmetricKey, header: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: root,
                               salt: Data(SHA256.hash(data: header)),
                               info: Data("luma-device-message-key.v3".utf8), outputByteCount: 32)
    }
}
