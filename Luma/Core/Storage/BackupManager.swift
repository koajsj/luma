import CommonCrypto
import CryptoKit
import Foundation
import Security
import SwiftData

enum BackupError: LocalizedError {
    case invalidFile, wrongAccount, invalidPassword, incompleteData
    var errorDescription: String? {
        switch self {
        case .invalidFile: "备份文件格式无效或已损坏"
        case .wrongAccount: "此备份属于另一个 UserID"
        case .invalidPassword: "备份密码错误或文件已损坏"
        case .incompleteData: "备份引用不完整，未恢复任何数据"
        }
    }
}

/// Portable, password-encrypted export. Keychain keys and password verifiers never enter the archive.
@MainActor
struct BackupManager {
    let context: ModelContext
    let encryption: EncryptionService
    var sessions: SessionManager? = nil

    static func deleteTemporaryExports(for userID: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumaBackups", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.lastPathComponent.hasPrefix("Luma-\(userID)-") && file.pathExtension == "lumabackup" {
            try FileManager.default.removeItem(at: file)
        }
    }

    private struct Archive: Codable {
        var version: Int
        var userID: String
        var nickname: String
        var bio: String?
        var avatar: Data?
        var preferences: PrivacyPreferences
        var friends: [FriendRecord]
        var conversations: [ConversationRecord]
        var messages: [MessageRecord]
        var attachments: [AttachmentRecord]
        var reactions: [ReactionRecord]
    }
    private struct FriendRecord: Codable {
        var id: UUID; var userID: String; var nickname: String; var remark: String
        var avatar: Data?; var privacyRestricted: Bool
        var remoteUserID: UUID?; var identityFingerprint: String?
    }
    private struct ConversationRecord: Codable {
        var id: UUID; var friendID: UUID; var draft: String; var requiresUnlock: Bool
        var isPinned: Bool; var unreadCount: Int
        var remoteID: UUID?
        var requiresPrivacyShield: Bool?
    }
    private struct MessageRecord: Codable {
        var id: UUID; var conversationID: UUID; var type: MessageType; var text: String
        var senderID: String?; var timestamp: Date; var deleted: Bool; var deletedForEveryone: Bool
        var isMine: Bool; var replyToID: UUID?; var editedAt: Date?; var readAt: Date?
        var status: String?; var deliveredAt: Date?; var expiresAt: Date?
        var isFavorite: Bool; var forwardedFrom: String?
        var deletedAt: Date?; var deviceID: UUID?; var lastEventID: UUID?
        var transportEncryptionVersion: Int?; var remoteRevision: Int?
    }
    private struct AttachmentRecord: Codable { var id: UUID; var messageID: UUID; var type: MessageType; var metadata: AttachmentMetadata }
    private struct ReactionRecord: Codable { var id: UUID; var messageID: UUID; var emoji: String; var reactorID: String }
    private struct Envelope: Codable { var format: String; var rounds: UInt32; var salt: Data; var ciphertext: Data }

    func export(user: User, password: String) throws -> Data {
        guard password.count >= 8 else { throw BackupError.invalidPassword }
        let metadata = PrivateMetadataStore(context: context, encryption: encryption)
        let messageStore = MessageStore(context: context, encryption: encryption, sessions: sessions)
        let friends = try context.fetch(FetchDescriptor<Friend>()).filter { $0.ownerID == user.id }
        let friendIDs = Set(friends.map(\.id))
        let conversations = try context.fetch(FetchDescriptor<Conversation>()).filter { $0.ownerID == user.id && friendIDs.contains($0.friendID) }
        let conversationIDs = Set(conversations.map(\.id))
        let messages = try context.fetch(FetchDescriptor<Message>()).filter { conversationIDs.contains($0.conversationID) }
        let messageIDs = Set(messages.map(\.id))
        let attachments = try context.fetch(FetchDescriptor<Attachment>()).filter { messageIDs.contains($0.messageID) }
        let reactions = try context.fetch(FetchDescriptor<Reaction>()).filter { messageIDs.contains($0.messageID) }
        let archive = Archive(version: 1, userID: user.userID, nickname: user.nickname, bio: user.bio, avatar: user.avatar,
                              preferences: try metadata.preferences(for: user),
                              friends: try friends.map { FriendRecord(id: $0.id, userID: $0.userID, nickname: $0.nickname,
                                                                      remark: try metadata.remark(for: $0), avatar: $0.avatar,
                                                                      privacyRestricted: $0.privacyRestricted ?? false,
                                                                      remoteUserID: $0.remoteUserID,
                                                                      identityFingerprint: $0.identityFingerprint) },
                              conversations: try conversations.map { ConversationRecord(id: $0.id, friendID: $0.friendID,
                                                                                         draft: try messageStore.draft(in: $0), requiresUnlock: $0.requiresUnlock ?? false,
                                                                                         isPinned: $0.isPinned ?? false, unreadCount: $0.unreadCount ?? 0,
                                                                                         remoteID: $0.remoteID, requiresPrivacyShield: $0.requiresPrivacyShield) },
                              messages: try messages.map { MessageRecord(id: $0.id, conversationID: $0.conversationID,
                                                                          type: $0.type, text: try messageStore.displayContent(for: $0),
                                                                          senderID: $0.senderID, timestamp: $0.timestamp, deleted: $0.deleted,
                                                                          deletedForEveryone: $0.deletedForEveryone, isMine: $0.isMine,
                                                                          replyToID: $0.replyToID, editedAt: $0.editedAt, readAt: $0.readAt,
                                                                          status: $0.status, deliveredAt: $0.deliveredAt, expiresAt: $0.expiresAt,
                                                                          isFavorite: $0.isFavorite ?? false, forwardedFrom: $0.forwardedFrom,
                                                                          deletedAt: $0.deletedAt, deviceID: $0.deviceID, lastEventID: $0.lastEventID,
                                                                          transportEncryptionVersion: $0.transportEncryptionVersion,
                                                                          remoteRevision: $0.remoteRevision) },
                              attachments: try attachments.map { AttachmentRecord(id: $0.id, messageID: $0.messageID, type: $0.type,
                                                                                   metadata: try metadata.attachmentMetadata(for: $0)) },
                              reactions: reactions.map { ReactionRecord(id: $0.id, messageID: $0.messageID, emoji: $0.emoji, reactorID: $0.reactorID) })
        let salt = try randomSalt()
        let rounds: UInt32 = 310_000
        let key = try backupKey(password: password, salt: salt, rounds: rounds)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(archive), using: key, authenticating: Data("luma-backup-v1".utf8))
        guard let combined = sealed.combined else { throw BackupError.invalidFile }
        return try JSONEncoder().encode(Envelope(format: "luma-backup-v1", rounds: rounds, salt: salt, ciphertext: combined))
    }

    /// Replaces only this unlocked account's local content, after decoding and validating the complete archive.
    func restore(_ file: Data, password: String, into user: User) throws {
        guard file.count <= 100_000_000,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: file),
              envelope.format == "luma-backup-v1", envelope.rounds == 310_000,
              envelope.salt.count == 16 else { throw BackupError.invalidFile }
        let key = try backupKey(password: password, salt: envelope.salt, rounds: envelope.rounds)
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.ciphertext)
            plain = try AES.GCM.open(box, using: key, authenticating: Data("luma-backup-v1".utf8))
        } catch { throw BackupError.invalidPassword }
        guard let archive = try? JSONDecoder().decode(Archive.self, from: plain), archive.version == 1 else { throw BackupError.invalidFile }
        guard archive.userID == user.userID else { throw BackupError.wrongAccount }
        let friendIDs = Set(archive.friends.map(\.id)), conversationIDs = Set(archive.conversations.map(\.id))
        let messageIDs = Set(archive.messages.map(\.id))
        guard friendIDs.count == archive.friends.count, conversationIDs.count == archive.conversations.count,
              messageIDs.count == archive.messages.count,
              archive.conversations.allSatisfy({ friendIDs.contains($0.friendID) }),
              archive.messages.allSatisfy({ conversationIDs.contains($0.conversationID) }),
              archive.attachments.allSatisfy({ messageIDs.contains($0.messageID) }),
              archive.reactions.allSatisfy({ messageIDs.contains($0.messageID) }) else { throw BackupError.incompleteData }

        let marker = CleanupState(ownerID: user.id, userID: user.userID, operation: "backupRestore")
        let oldSessions = try context.fetch(FetchDescriptor<SessionKey>()).filter { $0.ownerID == user.id }
        let oldSessionIDs = Set(oldSessions.map(\.id))
        let oldChains = try context.fetch(FetchDescriptor<ChainState>()).filter { oldSessionIDs.contains($0.sessionID) }
        var obsoleteAccounts = oldChains.map { "chain.\($0.sessionID.uuidString).\($0.id.uuidString)" }
        for session in oldSessions {
            guard (1...1000).contains(session.keyVersion) else { throw SessionError.unsupportedVersion }
            for version in 1...session.keyVersion {
                obsoleteAccounts.append("session-key.\(session.ownerID?.uuidString ?? "legacy").\(session.id.uuidString).\(version)")
            }
        }
        marker.encryptedPayload = try encryption.encrypt(JSONEncoder().encode(obsoleteAccounts),
            authenticatedData: Self.cleanupBinding(marker)).bytes
        context.insert(marker)
        try context.save()
        do {
            try context.transaction {
                let oldFriends = try context.fetch(FetchDescriptor<Friend>()).filter { $0.ownerID == user.id }
                let oldFriendIDs = Set(oldFriends.map(\.id))
                let oldConversations = try context.fetch(FetchDescriptor<Conversation>()).filter { $0.ownerID == user.id }
                let oldConversationIDs = Set(oldConversations.map(\.id))
                let oldMessages = try context.fetch(FetchDescriptor<Message>()).filter { oldConversationIDs.contains($0.conversationID) }
                let oldMessageIDs = Set(oldMessages.map(\.id))
                for item in try context.fetch(FetchDescriptor<Attachment>()).filter({ oldMessageIDs.contains($0.messageID) }) { context.delete(item) }
                for item in try context.fetch(FetchDescriptor<Reaction>()).filter({ oldMessageIDs.contains($0.messageID) }) { context.delete(item) }
                for item in try context.fetch(FetchDescriptor<UserPresence>()).filter({ oldFriendIDs.contains($0.friendID) }) { context.delete(item) }
                for item in try context.fetch(FetchDescriptor<SearchIndexEntry>()).filter({ $0.ownerID == user.id }) { context.delete(item) }
                for item in oldSessions { context.delete(item) }
                for item in oldChains { context.delete(item) }
                for item in try context.fetch(FetchDescriptor<OutgoingMessageQueueItem>()).filter({ $0.ownerID == user.id }) { context.delete(item) }
                for item in oldMessages { context.delete(item) }
                for item in oldConversations { context.delete(item) }
                for item in oldFriends { context.delete(item) }

                let metadata = PrivateMetadataStore(context: context, encryption: encryption)
                let messageStore = MessageStore(context: context, encryption: encryption)
                user.nickname = archive.nickname; user.bio = archive.bio; user.avatar = archive.avatar
                try metadata.save(archive.preferences, for: user, persist: false)
                for record in archive.friends {
                    let friend = Friend(ownerID: user.id, userID: record.userID, nickname: record.nickname)
                    friend.id = record.id; friend.avatar = record.avatar; friend.privacyRestricted = record.privacyRestricted
                    friend.remoteUserID = record.remoteUserID; friend.identityFingerprint = record.identityFingerprint
                    context.insert(friend)
                    try metadata.saveRemark(record.remark, for: friend, persist: false)
                    context.insert(UserPresence(friendID: friend.id))
                }
                for record in archive.conversations {
                    let conversation = Conversation(ownerID: user.id, friendID: record.friendID)
                    conversation.id = record.id; conversation.requiresUnlock = record.requiresUnlock
                    conversation.isPinned = record.isPinned; conversation.unreadCount = record.unreadCount
                    conversation.remoteID = record.remoteID
                    conversation.requiresPrivacyShield = record.requiresPrivacyShield ?? false
                    context.insert(conversation)
                    try messageStore.saveDraft(record.draft, in: conversation, persist: false)
                }
                for record in archive.messages {
                    let message = Message(conversationID: record.conversationID, type: record.type, isMine: record.isMine,
                                          senderID: record.senderID, timestamp: record.timestamp, replyToID: record.replyToID)
                    message.id = record.id; message.deleted = record.deleted; message.deletedForEveryone = record.deletedForEveryone
                    message.editedAt = record.editedAt; message.readAt = record.readAt
                    message.status = record.transportEncryptionVersion == 3 && record.status == "sending" ? "failed" : record.status
                    message.deliveredAt = record.deliveredAt; message.expiresAt = record.expiresAt
                    message.deletedAt = record.deletedAt; message.deviceID = record.deviceID; message.lastEventID = record.lastEventID
                    message.transportEncryptionVersion = record.transportEncryptionVersion
                    message.remoteRevision = record.remoteRevision
                    message.isFavorite = record.isFavorite; message.forwardedFrom = record.forwardedFrom
                    message.ciphertext = try encryption.encrypt(Data(record.text.utf8), authenticatedData: Data("luma-message-v1|\(message.id.uuidString)|\(message.conversationID.uuidString)".utf8)).bytes
                    context.insert(message)
                }
                for record in archive.attachments {
                    let item = Attachment(messageID: record.messageID, type: record.type, path: "")
                    item.id = record.id
                    item.encryptedMetadata = try encryption.encrypt(JSONEncoder().encode(record.metadata),
                                                                    authenticatedData: Data("luma-attachment-v1|\(item.id.uuidString)".utf8)).bytes
                    context.insert(item)
                }
                for record in archive.reactions {
                    let item = Reaction(messageID: record.messageID, emoji: record.emoji, reactorID: record.reactorID)
                    item.id = record.id; context.insert(item)
                }
                marker.dataCommitted = true
                marker.state = "processing"
                try context.save()
            }
        } catch {
            context.rollback()
            marker.state = "failed"
            try? context.save()
            throw error
        }
        do { try Self.finishRestoreCleanup(marker, context: context, encryption: encryption,
                                           keychain: sessions?.keychain ?? KeychainManager()) }
        catch { marker.state = "failed"; try? context.save(); throw error }
    }

    static func resumeRestoreCleanup(for user: User, context: ModelContext, encryption: EncryptionService,
                                     keychain: KeychainManager = KeychainManager()) throws {
        for marker in try context.fetch(FetchDescriptor<CleanupState>()).filter({
            $0.ownerID == user.id && $0.operation == "backupRestore" && $0.state != "completed"
        }) {
            if marker.dataCommitted {
                do { try finishRestoreCleanup(marker, context: context, encryption: encryption, keychain: keychain) }
                catch { marker.state = "failed"; try? context.save(); throw error }
            }
            else { marker.state = "failed"; try context.save() }
        }
    }

    private static func finishRestoreCleanup(_ marker: CleanupState, context: ModelContext,
                                             encryption: EncryptionService, keychain: KeychainManager) throws {
        guard let payload = marker.encryptedPayload else { throw BackupError.incompleteData }
        let plain = try encryption.decrypt(EncryptedData(bytes: payload), authenticatedData: cleanupBinding(marker))
        let accounts = try JSONDecoder().decode([String].self, from: plain)
        for account in accounts { try keychain.delete(account) }
        try FileTransferService.purgeAccount(ownerID: marker.ownerID)
        marker.state = "completed"
        marker.encryptedPayload = nil
        try context.save()
        context.delete(marker)
        try context.save()
    }

    private static func cleanupBinding(_ marker: CleanupState) -> Data {
        Data("luma-restore-cleanup-v1|\(marker.ownerID.uuidString)|\(marker.id.uuidString)".utf8)
    }

    private func randomSalt() throws -> Data {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PasswordHashError.randomFailure }
        return salt
    }

    private func backupKey(password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        var bytes = Data(count: 32)
        let secret = Array(password.utf8CString)
        let status = bytes.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { input in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret, secret.count - 1,
                                     input.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                     output.bindMemory(to: UInt8.self).baseAddress!, 32)
            }
        }
        guard status == kCCSuccess else { throw PasswordHashError.derivationFailure }
        return SymmetricKey(data: bytes)
    }
}
