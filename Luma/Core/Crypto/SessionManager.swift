import CryptoKit
import Foundation
import SwiftData

enum EncryptionVersion: Int, Codable {
    case localAESGCM = 1
    case sessionAESGCM = 2
    case deviceEnvelope = 3
}

enum SessionError: LocalizedError {
    case missing, invalidKey, invalidPeer, identityMismatch, unsupportedVersion, localPeerUnavailable

    var errorDescription: String? {
        switch self {
        case .missing: "本机会话密钥不存在，请重新建立会话"
        case .invalidKey: "本机会话密钥已损坏"
        case .invalidPeer: "好友身份公钥无效"
        case .identityMismatch: "好友身份公钥与已保存的指纹不一致"
        case .unsupportedVersion: "此会话密钥版本暂不支持"
        case .localPeerUnavailable: "本机没有此好友的账号，无法模拟建立会话"
        }
    }
}

/// Local-only session metadata. This is not an authenticated remote E2EE protocol.
@MainActor
struct SessionManager {
    let context: ModelContext
    let keychain: KeychainManager
    private let agreement: KeyAgreementService

    init(context: ModelContext, keychain: KeychainManager = KeychainManager()) {
        self.context = context
        self.keychain = keychain
        self.agreement = KeyAgreementService(keychain: keychain)
    }

    func session(ownerID: UUID, friendID: UUID) throws -> SessionKey? {
        try context.fetch(FetchDescriptor<SessionKey>()).first {
            $0.ownerID == ownerID && $0.friendID == friendID
        }
    }

    /// The caller must supply a trusted peer public key. Local simulation may use another local account.
    func create(owner: User, friend: Friend, peerPublicKey: Data) throws -> SessionKey {
        guard friend.ownerID == owner.id else { throw SessionError.identityMismatch }
        if let existing = try session(ownerID: owner.id, friendID: friend.id) {
            guard friend.identityFingerprint == IdentityFingerprint.make(publicKey: peerPublicKey) else {
                throw SessionError.identityMismatch
            }
            _ = try key(for: existing)
            return existing
        }
        let fingerprint = IdentityFingerprint.make(publicKey: peerPublicKey)
        if let saved = friend.identityFingerprint, saved != fingerprint { throw SessionError.identityMismatch }
        let prekeys = PreKeyManager(context: context, keychain: keychain)
        if try prekeys.records(for: owner.id).allSatisfy({ $0.type != "oneTime" }) {
            _ = try prekeys.generateOneTimePool(for: owner)
        }
        guard try prekeys.records(for: owner.id).contains(where: { $0.type == "oneTime" && $0.usedAt == nil }) else {
            throw PreKeyError.poolEmpty
        }
        let key = try agreement.derive(ownerUserID: owner.userID, peerPublicKey: peerPublicKey, version: 1)
        let record = SessionKey(friendID: friend.id, keyVersion: 1, ownerID: owner.id)
        try keychain.save(key.withUnsafeBytes { Data($0) }, account: account(for: record))
        context.insert(record)
        friend.identityFingerprint = fingerprint
        friend.sessionStatus = "active"
        do { try context.save() }
        catch { try? keychain.delete(account(for: record)); context.rollback(); throw error }
        // Pool accounting for the local simulation; PreKey is not yet part of the ECDH root.
        _ = try prekeys.consumeOneTime(for: owner)
        return record
    }

    func update(_ record: SessionKey, owner: User, friend: Friend, peerPublicKey: Data) throws {
        guard record.ownerID == owner.id, record.friendID == friend.id,
              friend.identityFingerprint == IdentityFingerprint.make(publicKey: peerPublicKey) else {
            throw SessionError.identityMismatch
        }
        guard (1...999).contains(record.keyVersion) else { throw SessionError.unsupportedVersion }
        _ = try key(for: record)
        let nextVersion = record.keyVersion + 1
        let newKey = try agreement.derive(ownerUserID: owner.userID, peerPublicKey: peerPublicKey, version: nextVersion)
        try keychain.save(newKey.withUnsafeBytes { Data($0) }, account: account(for: record, version: nextVersion))
        record.keyVersion = nextVersion
        record.updatedAt = .now
        do { try context.save() }
        catch { try? keychain.delete(account(for: record, version: nextVersion)); context.rollback(); throw error }
    }

    func key(for record: SessionKey, version: Int? = nil) throws -> SymmetricKey {
        let selected = version ?? record.keyVersion
        guard (1...1000).contains(selected), selected <= record.keyVersion else { throw SessionError.unsupportedVersion }
        guard let bytes = try keychain.read(account(for: record, version: selected)) else { throw SessionError.missing }
        guard bytes.count == 32 else { throw SessionError.invalidKey }
        return SymmetricKey(data: bytes)
    }

    func delete(_ record: SessionKey, friend: Friend? = nil) throws {
        try deleteKeyMaterial(for: record)
        if let friend { friend.sessionStatus = "none" }
        context.delete(record)
        try context.save()
    }

    /// Use before deleting account records or restoring a backup.
    func deleteKeyMaterial(for record: SessionKey) throws {
        guard (1...1000).contains(record.keyVersion) else { throw SessionError.unsupportedVersion }
        try RatchetManager(context: context, keychain: keychain, sessions: self).deleteStates(for: record.id)
        for version in 1...record.keyVersion {
            try keychain.delete(account(for: record, version: version))
        }
    }

    private func account(for record: SessionKey, version: Int? = nil) -> String {
        "session-key.\(record.ownerID?.uuidString ?? "legacy").\(record.id.uuidString).\(version ?? record.keyVersion)"
    }
}
