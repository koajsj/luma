import CryptoKit
import Foundation

/// P-256 ECDH + HKDF for local simulation. Peer key authentication is a future protocol concern.
struct KeyAgreementService {
    let keychain: KeychainManager

    func derive(ownerUserID: String, peerPublicKey: Data, version: Int) throws -> SymmetricKey {
        guard version > 0, let peer = try? P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey) else {
            throw SessionError.invalidPeer
        }
        let privateBytes = try keychain.readRequired("identity-private.\(ownerUserID)")
        guard let own = try? P256.KeyAgreement.PrivateKey(rawRepresentation: privateBytes) else {
            throw AsymmetricKeyError.invalid
        }
        let secret = try own.sharedSecretFromKeyAgreement(with: peer)
        let publicKeys = [own.publicKey.x963Representation, peerPublicKey].sorted { $0.lexicographicallyPrecedes($1) }
        let context = publicKeys[0] + publicKeys[1] + Data("|\(version)".utf8)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("luma-session-local-v1".utf8),
                                              sharedInfo: context, outputByteCount: 32)
    }
}
