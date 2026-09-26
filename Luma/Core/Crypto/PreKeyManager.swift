import CryptoKit
import Foundation
import SwiftData

enum PreKeyError: LocalizedError {
    case missing, invalid, signatureFailed, poolEmpty
    var errorDescription: String? {
        switch self {
        case .missing: "预密钥不存在"
        case .invalid: "预密钥已损坏"
        case .signatureFailed: "签名预密钥验证失败"
        case .poolEmpty: "一次性预密钥池已用尽"
        }
    }
}

@MainActor
struct PreKeyManager {
    let context: ModelContext
    let keychain: KeychainManager

    func signedKey(for user: User) throws -> PreKeyMetadata {
        if let record = try records(for: user.id).first(where: { $0.type == "signed" }) {
            try verify(record, identityPublicKey: try IdentityKeyManager(keychain: keychain).readPublicKey(for: user.userID))
            _ = try privateKey(for: record)
            return record
        }
        let privateKey = P256.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.x963Representation
        let identityBytes = try keychain.readRequired("identity-private.\(user.userID)")
        guard let signer = try? P256.Signing.PrivateKey(rawRepresentation: identityBytes),
              signer.publicKey.x963Representation == user.identityPublicKey else { throw AsymmetricKeyError.invalid }
        let signature = try signer.signature(for: signingData(publicKey)).derRepresentation
        let record = PreKeyMetadata(ownerID: user.id, type: "signed", publicKey: publicKey,
                                    fingerprint: IdentityFingerprint.make(publicKey: publicKey), signature: signature)
        try persist(privateKey, record: record)
        return record
    }

    func verify(_ record: PreKeyMetadata, identityPublicKey: Data) throws {
        guard record.type == "signed", record.publicKeyFingerprint == IdentityFingerprint.make(publicKey: record.publicKey),
              let signature = record.signature,
              let verifier = try? P256.Signing.PublicKey(x963Representation: identityPublicKey),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              verifier.isValidSignature(parsed, for: signingData(record.publicKey)) else { throw PreKeyError.signatureFailed }
    }

    func generateOneTimePool(for user: User, count: Int = 100) throws -> [PreKeyMetadata] {
        guard (1...1000).contains(count) else { throw PreKeyError.invalid }
        var created: [PreKeyMetadata] = []
        for _ in 0..<count {
            let key = P256.KeyAgreement.PrivateKey()
            let publicKey = key.publicKey.x963Representation
            let record = PreKeyMetadata(ownerID: user.id, type: "oneTime", publicKey: publicKey,
                                        fingerprint: IdentityFingerprint.make(publicKey: publicKey))
            try persist(key, record: record)
            created.append(record)
        }
        return created
    }

    func consumeOneTime(for user: User) throws -> PreKeyMetadata {
        guard let record = try records(for: user.id).first(where: { $0.type == "oneTime" && $0.usedAt == nil }) else {
            throw PreKeyError.poolEmpty
        }
        _ = try privateKey(for: record)
        record.usedAt = .now
        try context.save()
        try keychain.delete(account(for: record))
        return record
    }

    func consumeOneTime(_ record: PreKeyMetadata) throws {
        guard record.type == "oneTime" else { throw PreKeyError.invalid }
        if record.usedAt == nil {
            record.usedAt = .now
            try context.save()
        }
        try keychain.delete(account(for: record))
    }

    func privateKey(for record: PreKeyMetadata) throws -> P256.KeyAgreement.PrivateKey {
        let data = try keychain.readRequired(account(for: record))
        guard let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data),
              key.publicKey.x963Representation == record.publicKey else { throw PreKeyError.invalid }
        return key
    }

    func records(for ownerID: UUID) throws -> [PreKeyMetadata] {
        try context.fetch(FetchDescriptor<PreKeyMetadata>()).filter { $0.ownerID == ownerID }
    }

    func deleteAll(for ownerID: UUID) throws {
        for record in try records(for: ownerID) {
            try keychain.delete(account(for: record))
            context.delete(record)
        }
        try context.save()
    }

    private func persist(_ key: P256.KeyAgreement.PrivateKey, record: PreKeyMetadata) throws {
        try keychain.save(key.rawRepresentation, account: account(for: record))
        context.insert(record)
        do { try context.save() }
        catch { try? keychain.delete(account(for: record)); context.rollback(); throw error }
    }

    private func signingData(_ publicKey: Data) -> Data { Data("luma-signed-prekey-v1|".utf8) + publicKey }
    private func account(for record: PreKeyMetadata) -> String { "prekey.\(record.ownerID.uuidString).\(record.id.uuidString)" }
}

@MainActor
struct OneTimePreKeyPool {
    let manager: PreKeyManager
    func generate(for user: User, count: Int = 100) throws -> [PreKeyMetadata] {
        try manager.generateOneTimePool(for: user, count: count)
    }
    func consume(for user: User) throws -> PreKeyMetadata { try manager.consumeOneTime(for: user) }
}
