import Foundation
import Security

enum KeychainError: LocalizedError {
    case status(OSStatus), missing, invalidData
    var errorDescription: String? {
        switch self {
        case let .status(code): "钥匙串操作失败（\(code)）"
        case .missing: "钥匙串中的密钥不存在"
        case .invalidData: "钥匙串中的密钥数据已损坏"
        }
    }
}

struct KeychainManager {
    private let service: String

    init(service: String = "app.luma.local") { self.service = service }

    func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = value as? Data else { throw KeychainError.invalidData }
        return data
    }

    func readRequired(_ account: String) throws -> Data {
        guard let data = try read(account) else { throw KeychainError.missing }
        return data
    }

    func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status: OSStatus
        if try read(account) != nil {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func delete(_ account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
