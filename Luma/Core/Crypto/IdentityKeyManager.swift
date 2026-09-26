import CryptoKit
import Foundation

enum AsymmetricKeyError: LocalizedError {
    case missing, invalid, publicKeyMismatch
    var errorDescription: String? {
        switch self {
        case .missing: "身份或设备私钥不存在，请勿重新生成覆盖原有身份"
        case .invalid: "身份或设备私钥已损坏"
        case .publicKeyMismatch: "公开密钥与钥匙串中的私钥不匹配"
        }
    }
}

struct IdentityKeyManager {
    private let keychain: KeychainManager
    init(keychain: KeychainManager = KeychainManager()) { self.keychain = keychain }

    func create(for userID: String) throws -> Data {
        if let existing = try keychain.read(account(for: userID)) {
            return try publicKey(from: existing)
        }
        let privateKey = P256.KeyAgreement.PrivateKey()
        try keychain.save(privateKey.rawRepresentation, account: account(for: userID))
        return privateKey.publicKey.x963Representation
    }

    func readPublicKey(for userID: String) throws -> Data {
        guard let bytes = try keychain.read(account(for: userID)) else { throw AsymmetricKeyError.missing }
        return try publicKey(from: bytes)
    }

    func delete(for userID: String) throws { try keychain.delete(account(for: userID)) }

    private func publicKey(from bytes: Data) throws -> Data {
        guard let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: bytes) else { throw AsymmetricKeyError.invalid }
        return key.publicKey.x963Representation
    }

    private func account(for userID: String) -> String { "identity-private.\(userID)" }
}
