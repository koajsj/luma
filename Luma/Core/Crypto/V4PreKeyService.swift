import CryptoKit
import Foundation
import SwiftData

private struct V4PreKeyUpload: Encodable {
    let identityAgreementPublicKey: String
    let identitySigningPublicKey: String
    let identityBindingSignature: String
    let signedPreKeyPublicKey: String
    let signedPreKeySignature: String
    let keyVersion: Int
    let oneTimePreKeys: [String]
}

private struct V4PreKeyStatus: Decodable {
    let availableOneTimePreKeys: Int
}

struct V4RemoteBundle: Decodable {
    let accountIdentityPublicKey: String
    let deviceID: UUID
    let keyVersion: Int
    let identityAgreementPublicKey: String
    let identitySigningPublicKey: String
    let identityBindingSignature: String
    let signedPreKeyPublicKey: String
    let signedPreKeySignature: String
    let oneTimePreKeyPublicKey: String

    func verified(expectedAccountFingerprint: String) throws -> V4PreKeyBundle {
        guard keyVersion > 0,
              let account = Data(base64URL: accountIdentityPublicKey),
              IdentityFingerprint.make(publicKey: account) == expectedAccountFingerprint,
              let signer = try? P256.Signing.PublicKey(x963Representation: account),
              let agreement = Data(base64URL: identityAgreementPublicKey),
              let signing = Data(base64URL: identitySigningPublicKey),
              let binding = Data(base64URL: identityBindingSignature),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: binding),
              signer.isValidSignature(signature, for: V4Handshake.fields("luma.v4.binding", [
                  Data(deviceID.uuidString.lowercased().utf8), Data(String(keyVersion).utf8),
                  agreement, signing])),
              let prekey = Data(base64URL: signedPreKeyPublicKey),
              let prekeySignature = Data(base64URL: signedPreKeySignature) else {
            throw V4ProtocolError.untrustedIdentity
        }
        let oneTime = oneTimePreKeyPublicKey.isEmpty ? nil : Data(base64URL: oneTimePreKeyPublicKey)
        if !oneTimePreKeyPublicKey.isEmpty && oneTime == nil { throw V4ProtocolError.invalidPreKey }
        let bundle = V4PreKeyBundle(deviceID: deviceID, keyVersion: keyVersion,
            identityAgreementPublicKey: agreement, identitySigningPublicKey: signing,
            signedPreKeyPublicKey: prekey, signedPreKeySignature: prekeySignature,
            oneTimePreKeyPublicKey: oneTime)
        try V4Handshake.verify(bundle, expectedFingerprint: bundle.identityFingerprint)
        return bundle
    }
}

/// Only public keys cross this boundary. A P-256 account identity signature binds
/// the v4 Curve25519 identity to the identity fingerprint already pinned by the user.
@MainActor
struct V4PreKeyService {
    let context: ModelContext
    let user: User
    let registration: RemoteRegistration
    let client: RemoteAPIClient
    let vault: V4SessionVault

    init(context: ModelContext, user: User, registration: RemoteRegistration,
         client: RemoteAPIClient, vault: V4SessionVault = V4SessionVault()) {
        self.context = context; self.user = user; self.registration = registration
        self.client = client; self.vault = vault
    }

    func ensurePublished() async throws {
        let metadata = try context.fetch(FetchDescriptor<V4DeviceMetadata>()).first {
            $0.ownerID == user.id && $0.backendDeviceID == registration.backendDeviceID
        }
        var secrets: V4SessionVault.DeviceSecrets
        if let existing = try vault.loadDevice(userID: user.userID, deviceID: registration.backendDeviceID) {
            secrets = existing
        } else {
            guard metadata == nil else { throw V4VaultError.missing }
            let identity = V4IdentityKeys()
            let signed = Curve25519.KeyAgreement.PrivateKey()
            var oneTime: [String: Data] = [:]
            for _ in 0..<100 {
                let key = Curve25519.KeyAgreement.PrivateKey()
                oneTime[key.publicKey.rawRepresentation.base64EncodedString()] = key.rawRepresentation
            }
            secrets = V4SessionVault.DeviceSecrets(formatVersion: 1,
                deviceID: registration.backendDeviceID, keyVersion: 1,
                identityAgreement: identity.agreement.rawRepresentation,
                identitySigning: identity.signing.rawRepresentation,
                signedPreKey: signed.rawRepresentation, oneTimePreKeys: oneTime,
                pendingOneTimePreKeys: Array(oneTime.keys))
            try vault.saveDevice(secrets, userID: user.userID)
        }
        let identity = try secrets.identity()
        let signed = try secrets.signedKey()
        let fingerprint = V4Handshake.fingerprint(
            signing: identity.signing.publicKey.rawRepresentation,
            agreement: identity.agreement.publicKey.rawRepresentation)
        if let metadata, metadata.identityFingerprint != fingerprint { throw V4VaultError.damaged }
        if metadata?.publishedAt != nil && secrets.pendingOneTimePreKeys.isEmpty {
            let status: V4PreKeyStatus = try await client.json(V4PreKeyStatus.self,
                path: "/devices/\(registration.backendDeviceID.uuidString.lowercased())/v4-prekeys/status")
            guard (0...100_000).contains(status.availableOneTimePreKeys) else { throw V4VaultError.damaged }
            if status.availableOneTimePreKeys >= 20 { return }
            for _ in 0..<(100 - status.availableOneTimePreKeys) {
                let key = Curve25519.KeyAgreement.PrivateKey()
                let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
                secrets.oneTimePreKeys[publicKey] = key.rawRepresentation
                secrets.pendingOneTimePreKeys.append(publicKey)
            }
            try vault.saveDevice(secrets, userID: user.userID)
        }
        // A previous upload may have completed before its local metadata commit.
        // Re-publishing these public keys is idempotent on the server.
        if metadata?.publishedAt == nil && secrets.pendingOneTimePreKeys.isEmpty {
            secrets.pendingOneTimePreKeys = Array(secrets.oneTimePreKeys.keys.prefix(100))
            guard !secrets.pendingOneTimePreKeys.isEmpty else { throw V4VaultError.missing }
            try vault.saveDevice(secrets, userID: user.userID)
        }
        guard let accountPublic = user.identityPublicKey,
              let accountSigner = try? P256.Signing.PrivateKey(rawRepresentation:
                  vault.keychain.readRequired("identity-private.\(user.userID)")),
              accountSigner.publicKey.x963Representation == accountPublic else {
            throw AsymmetricKeyError.publicKeyMismatch
        }
        let bundle = try V4Handshake.bundle(deviceID: registration.backendDeviceID,
            version: secrets.keyVersion, identity: identity, signedPreKey: signed, oneTimePreKey: nil)
        let binding = V4Handshake.fields("luma.v4.binding", [
            Data(registration.backendDeviceID.uuidString.lowercased().utf8),
            Data(String(secrets.keyVersion).utf8), bundle.identityAgreementPublicKey,
            bundle.identitySigningPublicKey])
        let upload = V4PreKeyUpload(
            identityAgreementPublicKey: bundle.identityAgreementPublicKey.base64URLEncodedString(),
            identitySigningPublicKey: bundle.identitySigningPublicKey.base64URLEncodedString(),
            identityBindingSignature: try accountSigner.signature(for: binding).derRepresentation.base64URLEncodedString(),
            signedPreKeyPublicKey: bundle.signedPreKeyPublicKey.base64URLEncodedString(),
            signedPreKeySignature: bundle.signedPreKeySignature.base64URLEncodedString(),
            keyVersion: secrets.keyVersion,
            oneTimePreKeys: try secrets.pendingOneTimePreKeys.map {
                guard let bytes = Data(base64Encoded: $0) else { throw V4VaultError.damaged }
                return bytes.base64URLEncodedString()
            })
        _ = try await client.request("PUT", path: "/devices/\(registration.backendDeviceID.uuidString.lowercased())/v4-prekeys",
            body: JSONEncoder().encode(upload))
        secrets.pendingOneTimePreKeys.removeAll()
        try vault.saveDevice(secrets, userID: user.userID)
        let record = metadata ?? V4DeviceMetadata(ownerID: user.id,
            backendDeviceID: registration.backendDeviceID, keyVersion: secrets.keyVersion,
            identityFingerprint: fingerprint)
        if metadata == nil { context.insert(record) }
        record.publishedAt = .now
        try context.save()
    }

    func bundles(for remoteUserID: UUID, expectedAccountFingerprint: String,
                 claim: Bool) async throws -> [V4PreKeyBundle] {
        let suffix = claim ? "" : "?claim=false"
        let wire: [V4RemoteBundle] = try await client.json([V4RemoteBundle].self,
            path: "/users/\(remoteUserID.uuidString.lowercased())/v4-prekey-bundle\(suffix)")
        guard !wire.isEmpty, wire.count <= 32, Set(wire.map(\.deviceID)).count == wire.count else {
            throw V4ProtocolError.invalidPreKey
        }
        return try wire.map { try $0.verified(expectedAccountFingerprint: expectedAccountFingerprint) }
    }

    /// Historical, public verification material for a message already accepted by
    /// the server. This never makes the revoked device a target for a new send.
    func senderBundle(for remoteUserID: UUID, deviceID: UUID,
                      expectedAccountFingerprint: String) async throws -> V4PreKeyBundle {
        let wire: [V4RemoteBundle] = try await client.json([V4RemoteBundle].self,
            path: "/users/\(remoteUserID.uuidString.lowercased())/v4-prekey-bundle?claim=false&includeRevoked=true&deviceID=\(deviceID.uuidString.lowercased())")
        guard wire.count == 1, wire[0].deviceID == deviceID else { throw V4ProtocolError.untrustedIdentity }
        return try wire[0].verified(expectedAccountFingerprint: expectedAccountFingerprint)
    }

    func consumeOneTime(_ publicKey: Data) throws {
        guard var secrets = try vault.loadDevice(userID: user.userID,
            deviceID: registration.backendDeviceID) else { throw V4VaultError.missing }
        guard secrets.oneTimePreKeys.removeValue(forKey: publicKey.base64EncodedString()) != nil else {
            throw V4VaultError.missing
        }
        secrets.pendingOneTimePreKeys.removeAll { $0 == publicKey.base64EncodedString() }
        try vault.saveDevice(secrets, userID: user.userID)
    }
}
