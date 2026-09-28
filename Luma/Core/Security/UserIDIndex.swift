import CryptoKit
import Foundation
import Security

/// Local exact-match index only. This device-only key is separate from the
/// backend environment secret and is never exported in Luma Backup.
struct UserIDIndex {
    private static let account = "user-id-index-hmac-v1"
    private let keychain: KeychainManager

    init(keychain: KeychainManager = KeychainManager()) { self.keychain = keychain }

    func digest(_ normalizedUserID: String) throws -> String {
        let material: Data
        if let saved = try keychain.read(Self.account) {
            guard saved.count == 32 else { throw KeychainError.invalidData }
            material = saved
        } else {
            var generated = Data(count: 32)
            let status = generated.withUnsafeMutableBytes { bytes in
                SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
            }
            guard status == errSecSuccess else { throw KeychainError.status(status) }
            try keychain.save(generated, account: Self.account)
            material = generated
        }
        let value = HMAC<SHA256>.authenticationCode(for: Data(normalizedUserID.utf8),
                                                     using: SymmetricKey(data: material))
        return value.map { String(format: "%02x", $0) }.joined()
    }
}
