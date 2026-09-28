import CryptoKit
import Foundation

struct EncryptedData {
    let bytes: Data
}

/// Versioned AES-GCM field persisted as encoded data. No key material is included.
struct EncryptedField: Codable {
    let version: UInt8
    let nonce: Data
    let ciphertext: Data
    let authenticationTag: Data
}

enum EncryptionError: LocalizedError {
    case invalidEnvelope, authenticationFailed, invalidText

    var errorDescription: String? {
        switch self {
        case .invalidEnvelope: "加密数据格式无效或已损坏"
        case .authenticationFailed: "消息无法解密，数据可能已损坏"
        case .invalidText: "消息解密后不是有效文本"
        }
    }
}

/// Versioned local-data envelope. The nonce and authentication tag are in `combined`.
struct EncryptionService {
    private let key: SymmetricKey
    private static let version: UInt8 = 1

    init(key: SymmetricKey) { self.key = key }

    func encrypt(_ plaintext: Data, authenticatedData: Data = Data()) throws -> EncryptedData {
        // CryptoKit generates a fresh random nonce for every seal operation.
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: authenticatedData)
        guard let combined = box.combined else { throw EncryptionError.invalidEnvelope }
        return EncryptedData(bytes: Data([Self.version]) + combined)
    }

    func decrypt(_ encrypted: EncryptedData, authenticatedData: Data = Data()) throws -> Data {
        guard encrypted.bytes.first == Self.version else { throw EncryptionError.invalidEnvelope }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(encrypted.bytes.dropFirst()))
            return try AES.GCM.open(box, using: key, authenticating: authenticatedData)
        } catch {
            throw EncryptionError.authenticationFailed
        }
    }

    func encryptField(_ plaintext: Data, authenticatedData: Data) throws -> Data {
        let envelope = try encrypt(plaintext, authenticatedData: authenticatedData).bytes
        let combined = envelope.dropFirst()
        guard combined.count >= 28 else { throw EncryptionError.invalidEnvelope }
        let field = EncryptedField(version: Self.version,
                                   nonce: Data(combined.prefix(12)),
                                   ciphertext: Data(combined.dropFirst(12).dropLast(16)),
                                   authenticationTag: Data(combined.suffix(16)))
        return try JSONEncoder().encode(field)
    }

    func decryptField(_ stored: Data, authenticatedData: Data) throws -> Data {
        let field = try JSONDecoder().decode(EncryptedField.self, from: stored)
        guard field.version == Self.version, field.nonce.count == 12,
              field.authenticationTag.count == 16 else { throw EncryptionError.invalidEnvelope }
        return try decrypt(EncryptedData(bytes: Data([field.version]) + field.nonce +
                                         field.ciphertext + field.authenticationTag),
                           authenticatedData: authenticatedData)
    }
}
