import CommonCrypto
import Foundation
import Security

enum PasswordHashError: Error { case randomFailure, derivationFailure, invalidFormat }

/// Versioned verifier. A future Argon2id or scrypt implementation can add a new prefix here.
enum PasswordHasher {
    private static let iterations: UInt32 = 210_000
    private static let saltLength = 16
    private static let hashLength = 32

    static func hash(_ secret: String) throws -> String {
        var salt = Data(count: saltLength)
        let result = salt.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, saltLength, bytes.baseAddress!)
        }
        guard result == errSecSuccess else { throw PasswordHashError.randomFailure }
        let digest = try derive(secret, salt: salt, iterations: iterations)
        return "pbkdf2-sha256$\(iterations)$\(salt.base64EncodedString())$\(digest.base64EncodedString())"
    }

    static func verify(_ secret: String, against stored: String) -> Bool {
        let parts = stored.split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "pbkdf2-sha256",
              let rounds = UInt32(parts[1]), rounds >= 100_000,
              let salt = Data(base64Encoded: String(parts[2])), salt.count == saltLength,
              let expected = Data(base64Encoded: String(parts[3])), expected.count == hashLength,
              let actual = try? derive(secret, salt: salt, iterations: rounds) else { return false }
        return zip(actual, expected).reduce(0) { $0 | Int($1.0 ^ $1.1) } == 0
    }

    private static func derive(_ secret: String, salt: Data, iterations: UInt32) throws -> Data {
        var output = Data(count: hashLength)
        let password = Array(secret.utf8CString)
        let status = output.withUnsafeMutableBytes { outputBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.count - 1,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     outputBytes.bindMemory(to: UInt8.self).baseAddress!, hashLength)
            }
        }
        guard status == kCCSuccess else { throw PasswordHashError.derivationFailure }
        return output
    }
}
