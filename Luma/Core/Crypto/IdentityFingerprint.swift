import CryptoKit
import Foundation

enum IdentityFingerprint {
    /// SHA-256 of the canonical P-256 X9.63 public-key representation.
    static func make(publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    static func grouped(_ fingerprint: String) -> String {
        stride(from: 0, to: fingerprint.count, by: 4).map { offset in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
            let end = fingerprint.index(start, offsetBy: min(4, fingerprint.count - offset))
            return String(fingerprint[start..<end])
        }.joined(separator: " ")
    }
}
