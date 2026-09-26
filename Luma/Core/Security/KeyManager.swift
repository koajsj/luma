import CryptoKit
import Foundation
import Security

enum MasterKeyError: LocalizedError {
    case missing, invalid, randomFailure

    var errorDescription: String? {
        switch self {
        case .missing: "本地加密密钥不存在，无法读取聊天数据"
        case .invalid: "本地加密密钥已损坏，无法读取聊天数据"
        case .randomFailure: "无法生成安全随机密钥"
        }
    }
}

struct KeyManager {
    private let keychain: KeychainManager

    init(keychain: KeychainManager = KeychainManager()) { self.keychain = keychain }

    func create(for userID: String) throws -> SymmetricKey {
        if let existing = try keychain.read(account(for: userID)) {
            guard existing.count == 32 else { throw MasterKeyError.invalid }
            return SymmetricKey(data: existing)
        }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw MasterKeyError.randomFailure }
        try keychain.save(bytes, account: account(for: userID))
        return SymmetricKey(data: bytes)
    }

    func read(for userID: String) throws -> SymmetricKey {
        guard let bytes = try keychain.read(account(for: userID)) else { throw MasterKeyError.missing }
        guard bytes.count == 32 else { throw MasterKeyError.invalid }
        return SymmetricKey(data: bytes)
    }

    func delete(for userID: String) throws { try keychain.delete(account(for: userID)) }

    func isStored(for userID: String) throws -> Bool {
        guard let bytes = try keychain.read(account(for: userID)) else { return false }
        guard bytes.count == 32 else { throw MasterKeyError.invalid }
        return true
    }

    private func account(for userID: String) -> String { "local-key.\(userID)" }
}
