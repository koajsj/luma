import CryptoKit
import Foundation

struct DeviceKeyManager {
    private let keychain: KeychainManager
    init(keychain: KeychainManager = KeychainManager()) { self.keychain = keychain }

    func create(for deviceID: UUID) throws -> Data {
        if let existing = try keychain.read(account(for: deviceID)) {
            return try publicKey(from: existing)
        }
        let privateKey = P256.KeyAgreement.PrivateKey()
        try keychain.save(privateKey.rawRepresentation, account: account(for: deviceID))
        return privateKey.publicKey.x963Representation
    }

    func readPublicKey(for deviceID: UUID) throws -> Data {
        guard let bytes = try keychain.read(account(for: deviceID)) else { throw AsymmetricKeyError.missing }
        return try publicKey(from: bytes)
    }

    func delete(for deviceID: UUID) throws { try keychain.delete(account(for: deviceID)) }

    private func publicKey(from bytes: Data) throws -> Data {
        guard let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: bytes) else { throw AsymmetricKeyError.invalid }
        return key.publicKey.x963Representation
    }

    private func account(for deviceID: UUID) -> String { "device-private.\(deviceID.uuidString)" }
}
