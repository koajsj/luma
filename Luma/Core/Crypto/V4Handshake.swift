import CryptoKit
import Foundation

/// Experimental v4 handshake core. It is not connected to the online repository.
/// Agreement and signing identities have separate keys; private material stays with the caller.
struct V4IdentityKeys {
    let agreement: Curve25519.KeyAgreement.PrivateKey
    let signing: Curve25519.Signing.PrivateKey

    init() {
        agreement = Curve25519.KeyAgreement.PrivateKey()
        signing = Curve25519.Signing.PrivateKey()
    }
}

struct V4PreKeyBundle: Codable {
    let deviceID: UUID
    let keyVersion: Int
    let identityAgreementPublicKey: Data
    let identitySigningPublicKey: Data
    let signedPreKeyPublicKey: Data
    let signedPreKeySignature: Data
    let oneTimePreKeyPublicKey: Data?

    var identityFingerprint: String {
        V4Handshake.fingerprint(signing: identitySigningPublicKey, agreement: identityAgreementPublicKey)
    }
}

struct V4InitialHeader: Codable {
    let senderDeviceID: UUID
    let receiverDeviceID: UUID
    let recipientKeyVersion: Int
    let senderIdentityAgreementPublicKey: Data
    let senderIdentitySigningPublicKey: Data
    let senderEphemeralPublicKey: Data
    let recipientIdentityAgreementPublicKey: Data
    let recipientIdentitySigningPublicKey: Data
    let recipientSignedPreKeyPublicKey: Data
    let recipientOneTimePreKeyPublicKey: Data?
    let signature: Data

    func transcript() -> Data {
        V4Handshake.fields("luma.v4.initial", [
            Data(senderDeviceID.uuidString.lowercased().utf8),
            Data(receiverDeviceID.uuidString.lowercased().utf8),
            Data(String(recipientKeyVersion).utf8),
            senderIdentityAgreementPublicKey, senderIdentitySigningPublicKey, senderEphemeralPublicKey,
            recipientIdentityAgreementPublicKey, recipientIdentitySigningPublicKey,
            recipientSignedPreKeyPublicKey, recipientOneTimePreKeyPublicKey ?? Data()
        ])
    }
}

struct V4Initiation {
    let header: V4InitialHeader
    let sharedSecret: SymmetricKey
    let ratchetPrivateKey: Curve25519.KeyAgreement.PrivateKey
}

enum V4ProtocolError: LocalizedError {
    case untrustedIdentity, invalidPreKey, wrongDevice, invalidHandshake, invalidMessage, replay, tooManySkipped

    var errorDescription: String? {
        switch self {
        case .untrustedIdentity: "对方身份密钥未通过核对，已暂停建立加密会话"
        case .invalidPreKey: "预密钥签名或版本无效"
        case .wrongDevice: "消息并非发给当前设备"
        case .invalidHandshake: "会话建立信息无效或已损坏"
        case .invalidMessage: "消息认证失败或密文已损坏"
        case .replay: "消息已处理，不能重复应用"
        case .tooManySkipped: "消息间隔超出安全处理上限，需重新同步会话"
        }
    }
}

enum V4Handshake {
    static func fingerprint(signing: Data, agreement: Data) -> String {
        let digest = SHA256.hash(data: fields("luma.v4.identity", [signing, agreement]))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    static func bundle(deviceID: UUID, version: Int, identity: V4IdentityKeys,
                       signedPreKey: Curve25519.KeyAgreement.PrivateKey,
                       oneTimePreKey: Curve25519.KeyAgreement.PrivateKey?) throws -> V4PreKeyBundle {
        guard version > 0 else { throw V4ProtocolError.invalidPreKey }
        let agreement = identity.agreement.publicKey.rawRepresentation
        let signing = identity.signing.publicKey.rawRepresentation
        let signed = signedPreKey.publicKey.rawRepresentation
        let proof = try identity.signing.signature(for: preKeyTranscript(deviceID: deviceID,
            version: version, agreement: agreement, signing: signing, signedPreKey: signed))
        return V4PreKeyBundle(deviceID: deviceID, keyVersion: version,
            identityAgreementPublicKey: agreement, identitySigningPublicKey: signing,
            signedPreKeyPublicKey: signed, signedPreKeySignature: proof,
            oneTimePreKeyPublicKey: oneTimePreKey?.publicKey.rawRepresentation)
    }

    static func verify(_ bundle: V4PreKeyBundle, expectedFingerprint: String) throws {
        let validOneTimeKey: Bool
        if let oneTime = bundle.oneTimePreKeyPublicKey {
            validOneTimeKey = (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: oneTime)) != nil
        } else {
            validOneTimeKey = true
        }
        guard bundle.keyVersion > 0, bundle.identityFingerprint == expectedFingerprint,
              let signer = try? Curve25519.Signing.PublicKey(rawRepresentation: bundle.identitySigningPublicKey),
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.identityAgreementPublicKey)) != nil,
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.signedPreKeyPublicKey)) != nil,
              validOneTimeKey,
              signer.isValidSignature(bundle.signedPreKeySignature, for: preKeyTranscript(
                deviceID: bundle.deviceID, version: bundle.keyVersion,
                agreement: bundle.identityAgreementPublicKey, signing: bundle.identitySigningPublicKey,
                signedPreKey: bundle.signedPreKeyPublicKey)) else { throw V4ProtocolError.invalidPreKey }
    }

    static func initiate(senderDeviceID: UUID, identity: V4IdentityKeys,
                         recipient: V4PreKeyBundle, expectedFingerprint: String) throws -> V4Initiation {
        guard recipient.identityFingerprint == expectedFingerprint else { throw V4ProtocolError.untrustedIdentity }
        try verify(recipient, expectedFingerprint: expectedFingerprint)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let headerUnsigned = V4InitialHeader(senderDeviceID: senderDeviceID,
            receiverDeviceID: recipient.deviceID, recipientKeyVersion: recipient.keyVersion,
            senderIdentityAgreementPublicKey: identity.agreement.publicKey.rawRepresentation,
            senderIdentitySigningPublicKey: identity.signing.publicKey.rawRepresentation,
            senderEphemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            recipientIdentityAgreementPublicKey: recipient.identityAgreementPublicKey,
            recipientIdentitySigningPublicKey: recipient.identitySigningPublicKey,
            recipientSignedPreKeyPublicKey: recipient.signedPreKeyPublicKey,
            recipientOneTimePreKeyPublicKey: recipient.oneTimePreKeyPublicKey, signature: Data())
        let signature = try identity.signing.signature(for: headerUnsigned.transcript())
        let header = V4InitialHeader(senderDeviceID: headerUnsigned.senderDeviceID,
            receiverDeviceID: headerUnsigned.receiverDeviceID,
            recipientKeyVersion: headerUnsigned.recipientKeyVersion,
            senderIdentityAgreementPublicKey: headerUnsigned.senderIdentityAgreementPublicKey,
            senderIdentitySigningPublicKey: headerUnsigned.senderIdentitySigningPublicKey,
            senderEphemeralPublicKey: headerUnsigned.senderEphemeralPublicKey,
            recipientIdentityAgreementPublicKey: headerUnsigned.recipientIdentityAgreementPublicKey,
            recipientIdentitySigningPublicKey: headerUnsigned.recipientIdentitySigningPublicKey,
            recipientSignedPreKeyPublicKey: headerUnsigned.recipientSignedPreKeyPublicKey,
            recipientOneTimePreKeyPublicKey: headerUnsigned.recipientOneTimePreKeyPublicKey,
            signature: signature)
        let peerIdentity = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.identityAgreementPublicKey)
        let peerSigned = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.signedPreKeyPublicKey)
        var secrets = try [identity.agreement.sharedSecretFromKeyAgreement(with: peerSigned),
                           ephemeral.sharedSecretFromKeyAgreement(with: peerIdentity),
                           ephemeral.sharedSecretFromKeyAgreement(with: peerSigned)]
        if let oneTime = recipient.oneTimePreKeyPublicKey {
            secrets.append(try ephemeral.sharedSecretFromKeyAgreement(with:
                Curve25519.KeyAgreement.PublicKey(rawRepresentation: oneTime)))
        }
        return V4Initiation(header: header, sharedSecret: derive(secrets, transcript: header.transcript()),
                            ratchetPrivateKey: ephemeral)
    }

    static func accept(_ header: V4InitialHeader, expectedDeviceID: UUID, expectedKeyVersion: Int,
                       expectedSenderFingerprint: String, identity: V4IdentityKeys,
                       signedPreKey: Curve25519.KeyAgreement.PrivateKey,
                       oneTimePreKey: Curve25519.KeyAgreement.PrivateKey?) throws -> SymmetricKey {
        guard header.receiverDeviceID == expectedDeviceID else { throw V4ProtocolError.wrongDevice }
        guard fingerprint(signing: header.senderIdentitySigningPublicKey,
                          agreement: header.senderIdentityAgreementPublicKey) == expectedSenderFingerprint else {
            throw V4ProtocolError.untrustedIdentity
        }
        guard expectedKeyVersion > 0, header.recipientKeyVersion == expectedKeyVersion,
              header.recipientIdentityAgreementPublicKey == identity.agreement.publicKey.rawRepresentation,
              header.recipientIdentitySigningPublicKey == identity.signing.publicKey.rawRepresentation,
              header.recipientSignedPreKeyPublicKey == signedPreKey.publicKey.rawRepresentation,
              header.recipientOneTimePreKeyPublicKey == oneTimePreKey?.publicKey.rawRepresentation,
              let signer = try? Curve25519.Signing.PublicKey(rawRepresentation: header.senderIdentitySigningPublicKey),
              signer.isValidSignature(header.signature, for: header.transcript()) else {
            throw V4ProtocolError.invalidHandshake
        }
        let senderIdentity = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: header.senderIdentityAgreementPublicKey)
        let senderEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: header.senderEphemeralPublicKey)
        var secrets = try [signedPreKey.sharedSecretFromKeyAgreement(with: senderIdentity),
                           identity.agreement.sharedSecretFromKeyAgreement(with: senderEphemeral),
                           signedPreKey.sharedSecretFromKeyAgreement(with: senderEphemeral)]
        if let oneTimePreKey {
            secrets.append(try oneTimePreKey.sharedSecretFromKeyAgreement(with: senderEphemeral))
        }
        return derive(secrets, transcript: header.transcript())
    }

    private static func derive(_ secrets: [SharedSecret], transcript: Data) -> SymmetricKey {
        var input = Data(repeating: 0xFF, count: 32)
        for secret in secrets { secret.withUnsafeBytes { input.append(contentsOf: $0) } }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: input),
            salt: Data(repeating: 0, count: 32), info: fields("luma.v4.x3dh", [transcript]), outputByteCount: 32)
    }

    private static func preKeyTranscript(deviceID: UUID, version: Int, agreement: Data,
                                         signing: Data, signedPreKey: Data) -> Data {
        fields("luma.v4.signed-prekey", [Data(deviceID.uuidString.lowercased().utf8),
            Data(String(version).utf8), agreement, signing, signedPreKey])
    }

    static func fields(_ domain: String, _ values: [Data]) -> Data {
        var result = Data(domain.utf8)
        for value in values {
            var count = UInt32(value.count).bigEndian
            withUnsafeBytes(of: &count) { result.append(contentsOf: $0) }
            result.append(value)
        }
        return result
    }
}
