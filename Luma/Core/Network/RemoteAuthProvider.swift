import CryptoKit
import Foundation
import SwiftData

/// Enrolment is explicit. Local password and PIN never leave the device.
@MainActor
struct RemoteAuthProvider {
    let context: ModelContext
    let store = RemoteSessionStore()
    let signer = RemoteDeviceSigner()

    func register(user: User, baseURL: URL) async throws -> RemoteRegistration {
        guard try store.registration(for: user.userID) == nil else { throw RemoteError.server(409, "device_already_registered") }
        guard let device = try localDevice(for: user),
              let identity = user.identityPublicKey,
              let devicePublic = device.publicKey else { throw AsymmetricKeyError.missing }
        let client = try RemoteAPIClient(baseURL: baseURL, userID: user.userID)
        let challengeBody = try JSONEncoder().encode(["userID": user.userID])
        let challenge: RemoteChallenge = try await client.json(RemoteChallenge.self, method: "POST",
                                                               path: "/auth/register/challenge", body: challengeBody,
                                                               authenticated: false)
        let prekeys = PreKeyManager(context: context, keychain: KeychainManager())
        let signed = try prekeys.signedKey(for: user)
        let authPublic = try signer.publicKey(for: user.userID)
        // The backend signs SHA-256(raw prekey bytes), while the existing local prekey
        // signature has a domain prefix. Publish a separate signature over raw bytes.
        let identityBytes = try KeychainManager().readRequired("identity-private.\(user.userID)")
        let identitySigner = try P256.Signing.PrivateKey(rawRepresentation: identityBytes)
        guard identitySigner.publicKey.x963Representation == identity else { throw AsymmetricKeyError.publicKeyMismatch }
        let signedPrekeySignature = try identitySigner.signature(for: signed.publicKey).derRepresentation
        let identityText = identity.base64URLEncodedString()
        let deviceText = devicePublic.base64URLEncodedString()
        let authText = authPublic.base64URLEncodedString()
        let prekeyText = signed.publicKey.base64URLEncodedString()
        let canonical = "luma.register.v1\n\(challenge.nonce)\n\(user.userID)\n\(identityText)\n\(deviceText)\n\(authText)\n\(prekeyText)"
        let body = try JSONEncoder().encode(RegisterRequest(challengeID: challenge.challengeID,
            nonce: challenge.nonce, userID: user.userID, nickname: user.nickname,
            identityPublicKey: identityText, devicePublicKey: deviceText, authPublicKey: authText,
            deviceName: device.deviceName ?? device.name, signedPreKey: prekeyText,
            signedPreKeySignature: signedPrekeySignature.base64URLEncodedString(),
            signedPreKeyVersion: 1, signature: try signer.sign(canonical, userID: user.userID)))
        let result: RegisterResponse = try await client.json(RegisterResponse.self, method: "POST",
                                                              path: "/auth/register", body: body, authenticated: false)
        let registration = RemoteRegistration(backendUserID: result.userID,
                                              backendDeviceID: result.deviceID, baseURL: baseURL)
        try store.save(registration, for: user.userID)
        try await login(userID: user.userID)
        let oneTime = try prekeys.records(for: user.id).filter { $0.type == "oneTime" && $0.usedAt == nil }
            .prefix(100).map { $0.publicKey.base64URLEncodedString() }
        struct PreKeyUpload: Encodable {
            let signedPreKey: String
            let signature: String
            let keyVersion: Int
            let oneTimePreKeys: [String]
        }
        let upload = try JSONEncoder().encode(PreKeyUpload(signedPreKey: prekeyText,
            signature: signedPrekeySignature.base64URLEncodedString(), keyVersion: 1,
            oneTimePreKeys: oneTime))
        _ = try await client.request("PUT", path: "/devices/\(result.deviceID.uuidString.lowercased())/prekeys",
                                     body: upload)
        return registration
    }

    func login(userID: String) async throws {
        guard let registration = try store.registration(for: userID) else { throw RemoteError.unregistered }
        let client = try RemoteAPIClient(baseURL: registration.baseURL, userID: userID)
        let deviceID = registration.backendDeviceID.uuidString.lowercased()
        let challenge: RemoteChallenge = try await client.json(RemoteChallenge.self, method: "POST",
            path: "/auth/challenge", body: JSONEncoder().encode(["deviceID": deviceID]), authenticated: false)
        let signature = try signer.sign("luma.login.v1\n\(challenge.nonce)\n\(deviceID)", userID: userID)
        let body = try JSONEncoder().encode(LoginRequest(challengeID: challenge.challengeID,
                                                          nonce: challenge.nonce, deviceID: deviceID, signature: signature))
        let response: RemoteTokenResponse = try await client.json(RemoteTokenResponse.self, method: "POST",
                                                                  path: "/auth/token", body: body, authenticated: false)
        try store.save(response, for: userID)
    }

    func signOut(userID: String) async throws {
        if let registration = try store.registration(for: userID), try store.tokens(for: userID) != nil {
            let client = try RemoteAPIClient(baseURL: registration.baseURL, userID: userID)
            _ = try await client.request("POST", path: "/auth/revoke")
        }
        try store.clearTokens(for: userID)
    }

    private func localDevice(for user: User) throws -> Device? {
        try context.fetch(FetchDescriptor<Device>()).first { $0.ownerID == user.id }
    }
}

private struct RegisterRequest: Encodable {
    let challengeID: UUID
    let nonce: String
    let userID: String
    let nickname: String
    let identityPublicKey: String
    let devicePublicKey: String
    let authPublicKey: String
    let deviceName: String
    let signedPreKey: String
    let signedPreKeySignature: String
    let signedPreKeyVersion: Int
    let signature: String
}

private struct RegisterResponse: Decodable {
    let userID: UUID
    let deviceID: UUID
}

private struct LoginRequest: Encodable {
    let challengeID: UUID
    let nonce: String
    let deviceID: String
    let signature: String
}
