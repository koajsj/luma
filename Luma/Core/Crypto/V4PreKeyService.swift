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
    var recoveryProtocolVersion: Int? = nil
    var recoveryCapabilitySignature: String? = nil
}

private struct V4PreKeyStatus: Decodable {
    let availableOneTimePreKeys: Int
    let recoveryProtocolVersion: Int?
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
    var recoveryProtocolVersion: Int? = nil
    var recoveryCapabilitySignature: String? = nil

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
        var bundle = V4PreKeyBundle(deviceID: deviceID, keyVersion: keyVersion,
            identityAgreementPublicKey: agreement, identitySigningPublicKey: signing,
            signedPreKeyPublicKey: prekey, signedPreKeySignature: prekeySignature,
            oneTimePreKeyPublicKey: oneTime)
        if let version = recoveryProtocolVersion, version != 0 {
            guard version == 2, let wire = recoveryCapabilitySignature,
                  let proof = Data(base64URL: wire) else { throw V4ProtocolError.invalidPreKey }
            bundle.recoveryProtocolVersion = version
            bundle.recoveryCapabilitySignature = proof
        } else if recoveryCapabilitySignature?.isEmpty == false { throw V4ProtocolError.invalidPreKey }
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
    let recoveryConfiguration: V4RecoveryConfiguration

    init(context: ModelContext, user: User, registration: RemoteRegistration,
         client: RemoteAPIClient, vault: V4SessionVault = V4SessionVault(),
         recoveryConfiguration: V4RecoveryConfiguration = .init()) {
        self.context = context; self.user = user; self.registration = registration
        self.client = client; self.vault = vault; self.recoveryConfiguration = recoveryConfiguration
    }

    private static var publishing: [UUID: Task<Void, Error>] = [:]

    func ensurePublished() async throws {
        let id = registration.backendDeviceID
        if let task = Self.publishing[id] { return try await task.value }
        let task = Task { try await publishCurrentKeys() }
        Self.publishing[id] = task
        defer { Self.publishing.removeValue(forKey: id) }
        try await task.value
    }

    private func publishCurrentKeys() async throws {
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
        let supportsRecovery = try recoveryConfiguration.enabled ||
            !(try V4HandshakeRecoveryVault(keychain: vault.keychain, userID: user.userID,
                localDevice: registration.backendDeviceID).pairs()).isEmpty
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
            if status.availableOneTimePreKeys >= 20 && (!supportsRecovery || status.recoveryProtocolVersion == 2) { return }
            // Receiving can consume a private key while status is in flight.
            secrets = try reloadCurrentSecrets(matching: secrets)
            for _ in 0..<max(0, 100 - status.availableOneTimePreKeys) {
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
        var upload = V4PreKeyUpload(
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
        if supportsRecovery {
            let supported = try V4Handshake.enableRecovery(bundle, identity: identity)
            upload.recoveryProtocolVersion = 2
            upload.recoveryCapabilitySignature = supported.recoveryCapabilitySignature?.base64URLEncodedString()
        }
        let uploadedKeys = Set(secrets.pendingOneTimePreKeys)
        _ = try await client.request("PUT", path: "/devices/\(registration.backendDeviceID.uuidString.lowercased())/v4-prekeys",
            body: JSONEncoder().encode(upload))
        // Do not resurrect consumed keys or clear keys added by a newer state.
        secrets = try reloadCurrentSecrets(matching: secrets)
        secrets.pendingOneTimePreKeys.removeAll { uploadedKeys.contains($0) }
        try vault.saveDevice(secrets, userID: user.userID)
        let record = metadata ?? V4DeviceMetadata(ownerID: user.id,
            backendDeviceID: registration.backendDeviceID, keyVersion: secrets.keyVersion,
            identityFingerprint: fingerprint)
        if metadata == nil { context.insert(record) }
        record.publishedAt = .now
        try context.save()
    }

    private func reloadCurrentSecrets(matching expected: V4SessionVault.DeviceSecrets) throws -> V4SessionVault.DeviceSecrets {
        guard let current = try vault.loadDevice(userID: user.userID, deviceID: registration.backendDeviceID) else {
            throw V4VaultError.missing
        }
        guard current.keyVersion == expected.keyVersion,
              current.identityAgreement == expected.identityAgreement,
              current.identitySigning == expected.identitySigning,
              current.signedPreKey == expected.signedPreKey else { throw V4VaultError.damaged }
        return current
    }

    func bundles(for remoteUserID: UUID, expectedAccountFingerprint: String,
                 claim: Bool) async throws -> [V4PreKeyBundle] {
        let suffix = claim ? "" : "?claim=false"
        let wire: [V4RemoteBundle] = try await client.json([V4RemoteBundle].self,
            path: "/users/\(remoteUserID.uuidString.lowercased())/v4-prekey-bundle\(suffix)")
        guard !wire.isEmpty, wire.count <= 32, Set(wire.map(\.deviceID)).count == wire.count else {
            throw V4ProtocolError.invalidPreKey
        }
        return try wire.map {
            var bundle = try $0.verified(expectedAccountFingerprint: expectedAccountFingerprint)
            bundle.recoveryParticipant = .init(accountID: remoteUserID, deviceID: bundle.deviceID,
                accountFingerprint: expectedAccountFingerprint,
                agreementPublicKey: bundle.identityAgreementPublicKey, signingPublicKey: bundle.identitySigningPublicKey)
            return bundle
        }
    }

    /// Historical, public verification material for a message already accepted by
    /// the server. This never makes the revoked device a target for a new send.
    func senderBundle(for remoteUserID: UUID, deviceID: UUID,
                      expectedAccountFingerprint: String) async throws -> V4PreKeyBundle {
        let wire: [V4RemoteBundle] = try await client.json([V4RemoteBundle].self,
            path: "/users/\(remoteUserID.uuidString.lowercased())/v4-prekey-bundle?claim=false&includeRevoked=true&deviceID=\(deviceID.uuidString.lowercased())")
        guard wire.count == 1, wire[0].deviceID == deviceID else { throw V4ProtocolError.untrustedIdentity }
        var bundle = try wire[0].verified(expectedAccountFingerprint: expectedAccountFingerprint)
        bundle.recoveryParticipant = .init(accountID: remoteUserID, deviceID: bundle.deviceID,
            accountFingerprint: expectedAccountFingerprint,
            agreementPublicKey: bundle.identityAgreementPublicKey, signingPublicKey: bundle.identitySigningPublicKey)
        return bundle
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
