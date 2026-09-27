import CryptoKit
import Foundation

/// Both parties derive the same code from their long-term account public keys.
/// Comparing it out of band detects a directory that substitutes either identity.
enum IdentitySafetyCode {
    static func make(_ first: Data, _ second: Data) -> String {
        let ordered = [first, second].sorted { $0.lexicographicallyPrecedes($1) }
        var input = Data("luma.identity-safety-code.v1".utf8)
        for key in ordered {
            var count = UInt32(key.count).bigEndian
            withUnsafeBytes(of: &count) { input.append(contentsOf: $0) }
            input.append(key)
        }
        let digest = SHA256.hash(data: input)
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    static func grouped(_ code: String) -> String {
        IdentityFingerprint.grouped(code)
    }

    static func qrPayload(_ code: String) -> String { "luma-safety-code-v1:\(code)" }

    static func matches(_ candidate: String, code: String) -> Bool {
        candidate.uppercased().filter { $0.isHexDigit } == code
    }
}
