import Foundation
import SwiftData

enum MessageStoreError: LocalizedError {
    case locked, missingCiphertext, editNotAllowed, unsupportedEncryptionVersion, historyEvidenceMissing

    var errorDescription: String? {
        switch self {
        case .locked: "应用已锁定，请先解锁后读取消息"
        case .missingCiphertext: "消息数据不完整，无法显示"
        case .editNotAllowed: "只能编辑自己发送的文字消息"
        case .unsupportedEncryptionVersion: "此消息使用当前版本不支持的加密格式"
        case .historyEvidenceMissing: "缺少可验证的历史消息记录，已暂停同步并保留恢复数据。请勿清除本地数据。"
        }
    }
}

/// Owns the plaintext boundary. SwiftUI receives only a display value.
@MainActor
struct MessageStore {
    let context: ModelContext
    let encryption: EncryptionService
    let sessions: SessionManager

    init(context: ModelContext, encryption: EncryptionService, sessions: SessionManager? = nil) {
        self.context = context
        self.encryption = encryption
        self.sessions = sessions ?? SessionManager(context: context)
    }

    private var encryptor: MessageEncryptor { MessageEncryptor(local: encryption, sessions: sessions) }

    private struct TombstoneRecord: Codable {
        let version: Int
        let evidenceSource: String
        let messageID: UUID
        let conversationID: UUID
        let remoteConversationID: UUID
        let friendID: UUID
        let friendFingerprint: String
        let senderID: String
        let isMine: Bool
        let type: MessageType
        let timestamp: Date
        let deviceID: UUID?
        let lastEventID: UUID?
        let revision: Int
        let deletedForEveryone: Bool
        let deletedAt: Date?
        let encryptedReactionState: Data?
    }

    private static func tombstoneBinding(_ item: MessageTombstone) -> Data {
        Data("luma-message-tombstone-v1|\(item.ownerID.uuidString)|\(item.messageID.uuidString)".utf8)
    }

    private func tombstoneRecord(_ item: MessageTombstone) throws -> TombstoneRecord {
        let data = try encryption.decrypt(EncryptedData(bytes: item.encryptedRecord),
            authenticatedData: Self.tombstoneBinding(item))
        let record = try JSONDecoder().decode(TombstoneRecord.self, from: data)
        guard record.version == 1, record.evidenceSource == "retained-local-message",
              record.messageID == item.messageID, record.revision >= 1 else {
            throw MessageStoreError.historyEvidenceMissing
        }
        return record
    }

    /// Called within the same local save as deletion/revision updates. It attests
    /// only to this device's retained record, never to an inferred remote delete.
    func retainV4Tombstone(for message: Message, eraseContent: Bool = true) throws {
        guard message.transportEncryptionVersion == 4, message.deleted else { return }
        guard let conversation = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
            $0.id == message.conversationID
        }) else { throw MessageStoreError.historyEvidenceMissing }
        // An unsent local row has no authenticated remote route to preserve yet.
        // Removing it must not invent a remote deletion fact or block offline use.
        if conversation.remoteID == nil, message.isMine,
           [.sending, .failed].contains(message.deliveryStatus) { return }
        guard let remoteID = conversation.remoteID,
              let owner = try context.fetch(FetchDescriptor<User>()).first(where: { $0.id == conversation.ownerID }),
              let friend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                  $0.id == conversation.friendID && $0.ownerID == owner.id
              }), let fingerprint = friend.identityFingerprint,
              let sender = message.senderID, sender == (message.isMine ? owner.userID : friend.userID),
              let revision = message.remoteRevision, revision >= 1,
              message.encryptionVersion == 1 else { throw MessageStoreError.historyEvidenceMissing }
        _ = try displayContent(for: message) // Validate existing local ciphertext before migration.
        let existing = try context.fetch(FetchDescriptor<MessageTombstone>()).first { $0.messageID == message.id }
        if let existing {
            let prior = try tombstoneRecord(existing)
            guard existing.ownerID == owner.id, prior.conversationID == conversation.id,
                  prior.remoteConversationID == remoteID, prior.friendID == friend.id,
                  prior.friendFingerprint == fingerprint, prior.senderID == sender,
                  prior.isMine == message.isMine, revision >= prior.revision else {
                throw MessageStoreError.historyEvidenceMissing
            }
        }
        let record = TombstoneRecord(version: 1, evidenceSource: "retained-local-message",
            messageID: message.id, conversationID: conversation.id,
            remoteConversationID: remoteID, friendID: friend.id, friendFingerprint: fingerprint,
            senderID: sender, isMine: message.isMine, type: message.type, timestamp: message.timestamp,
            deviceID: message.deviceID, lastEventID: message.lastEventID, revision: revision,
            deletedForEveryone: message.deletedForEveryone, deletedAt: message.deletedAt,
            encryptedReactionState: message.encryptedReactionState)
        let item = existing ?? MessageTombstone(messageID: message.id, ownerID: owner.id, encryptedRecord: Data())
        item.encryptedRecord = try encryption.encrypt(JSONEncoder().encode(record),
            authenticatedData: Self.tombstoneBinding(item)).bytes
        if existing == nil { context.insert(item) }
        // Unlock migration is a database-only evidence copy. Preserve old protected
        // content/files if any later row fails; do not fake a cross-store transaction.
        guard eraseContent else { return }
        message.ciphertext = try encryption.encrypt(Data(), authenticatedData: Self.binding(for: message)).bytes
        message.content = ""; message.isFavorite = false; message.replyToID = nil
        message.forwardedFrom = nil; message.expiresAt = nil
        let attachments = try context.fetch(FetchDescriptor<Attachment>()).filter { $0.messageID == message.id }
        let sourceIDs = Set(attachments.map(\.id)).union([message.id])
        for attachment in attachments {
            try FileTransferService(ownerID: owner.id, encryption: encryption).delete(attachmentID: attachment.id)
            context.delete(attachment)
        }
        for reaction in try context.fetch(FetchDescriptor<Reaction>()).filter({ $0.messageID == message.id }) {
            context.delete(reaction)
        }
        for entry in try context.fetch(FetchDescriptor<SearchIndexEntry>()).filter({
            $0.ownerID == owner.id && sourceIDs.contains($0.sourceID)
        }) { context.delete(entry) }
    }

    /// Reconstructs only an empty hidden row from authenticated local evidence.
    /// Missing evidence is not evidence of deletion and must never be fabricated.
    func restoreV4Tombstone(messageID: UUID, remoteConversationID: UUID, owner: User) throws -> Message? {
        guard let item = try context.fetch(FetchDescriptor<MessageTombstone>()).first(where: {
            $0.messageID == messageID && $0.ownerID == owner.id
        }) else { return nil }
        let record = try tombstoneRecord(item)
        guard record.remoteConversationID == remoteConversationID,
              let conversation = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
                  $0.id == record.conversationID && $0.ownerID == owner.id && $0.remoteID == remoteConversationID
              }), let friend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                  $0.id == record.friendID && $0.id == conversation.friendID && $0.ownerID == owner.id &&
                  $0.identityFingerprint == record.friendFingerprint && $0.sessionStatus != "identityKeyChanged"
              }), record.senderID == (record.isMine ? owner.userID : friend.userID) else {
            throw MessageStoreError.historyEvidenceMissing
        }
        let message = Message(conversationID: conversation.id, type: record.type, isMine: record.isMine,
            senderID: record.senderID, timestamp: record.timestamp)
        message.id = messageID; message.transportEncryptionVersion = 4
        message.deleted = true; message.deletedForEveryone = record.deletedForEveryone
        message.deletedAt = record.deletedAt; message.remoteRevision = record.revision
        message.encryptedReactionState = record.encryptedReactionState
        message.deviceID = record.deviceID; message.lastEventID = record.lastEventID
        message.ciphertext = try encryption.encrypt(Data(), authenticatedData: Self.binding(for: message)).bytes
        context.insert(message)
        return message
    }

    @discardableResult
    func send(conversationID: UUID, senderID: String, type: MessageType, content: String, replyToID: UUID? = nil,
              completeLocally: Bool = true) throws -> Message {
        let message = Message(conversationID: conversationID, type: type, isMine: true, senderID: senderID, replyToID: replyToID)
        message.deliveryStatus = .sending
        message.encryptionVersion = EncryptionVersion.localAESGCM.rawValue
        message.ciphertext = try encryptor.encrypt(Data(content.utf8), for: message).bytes
        context.insert(message)
        try context.save()
        if completeLocally {
            message.deliveryStatus = .sent
            try context.save()
        }
        return message
    }

    /// Explicit local simulation path. Existing chat sends continue using v1.
    @discardableResult
    func sendSession(conversation: Conversation, session: SessionKey, senderID: String, content: String) throws -> Message {
        guard session.ownerID == conversation.ownerID, session.friendID == conversation.friendID else {
            throw SessionError.missing
        }
        guard let friend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
            $0.id == conversation.friendID && $0.ownerID == conversation.ownerID
        }), friend.sessionStatus != "identityKeyChanged", friend.sessionStatus != "identityReverified" else {
            throw SessionError.identityMismatch
        }
        let message = Message(conversationID: conversation.id, type: .text, isMine: true, senderID: senderID)
        message.encryptionVersion = EncryptionVersion.sessionAESGCM.rawValue
        message.sessionKeyVersion = session.keyVersion
        message.messageKeyIndex = try RatchetManager(context: context, keychain: sessions.keychain, sessions: sessions)
            .nextKey(session: session, senderID: senderID).index
        message.deliveryStatus = .sent
        message.ciphertext = try encryptor.encrypt(Data(content.utf8), for: message, session: session).bytes
        context.insert(message)
        try context.save()
        return message
    }

    func displayContent(for message: Message) throws -> String {
        guard let bytes = message.ciphertext else { throw MessageStoreError.missingCiphertext }
        let session = try session(for: message)
        let data = try encryptor.decrypt(EncryptedData(bytes: bytes), for: message, session: session)
        guard let text = String(data: data, encoding: .utf8) else { throw EncryptionError.invalidText }
        return text
    }

    func receiveLocal(_ content: String, from senderID: String, in conversation: Conversation, at date: Date = .now) throws {
        let message = Message(conversationID: conversation.id, type: .text, isMine: false, senderID: senderID, timestamp: date)
        message.deliveryStatus = .delivered
        message.deliveredAt = date
        message.ciphertext = try encryption.encrypt(Data(content.utf8), authenticatedData: Self.binding(for: message)).bytes
        context.insert(message)
        conversation.unreadCount = (conversation.unreadCount ?? 0) + 1
        try context.save()
    }

    /// Persist a verified v3 payload under the local v1 Master Key. The wire key is never stored here.
    func receiveVerifiedRemote(messageID: UUID, plaintext: Data, from senderID: String,
                               in conversation: Conversation, at date: Date, senderDeviceID: UUID,
                               eventID: UUID, isMine: Bool, transportVersion: Int = 3,
                               attachmentDescriptor: V4AttachmentDescriptor? = nil) throws {
        guard try !context.fetch(FetchDescriptor<MessageTombstone>()).contains(where: { $0.messageID == messageID }) else {
            throw MessageStoreError.historyEvidenceMissing
        }
        if try context.fetch(FetchDescriptor<Message>()).contains(where: { $0.id == messageID }) { return }
        let message = Message(conversationID: conversation.id, type: attachmentDescriptor?.type ?? .text, isMine: isMine,
                              senderID: senderID, timestamp: date)
        message.id = messageID
        message.encryptionVersion = EncryptionVersion.localAESGCM.rawValue
        message.transportEncryptionVersion = transportVersion
        message.remoteRevision = 1
        message.deviceID = senderDeviceID
        message.lastEventID = eventID
        message.deliveryStatus = isMine ? .sent : .delivered
        if !isMine { message.deliveredAt = date }
        message.ciphertext = try encryption.encrypt(plaintext, authenticatedData: Self.binding(for: message)).bytes
        context.insert(message)
        if let descriptor = attachmentDescriptor {
            guard transportVersion == 4, let remoteConversationID = conversation.remoteID else {
                throw V4AttachmentError.invalidDescriptor
            }
            try V4AttachmentCrypto.validate(descriptor, messageID: messageID,
                                             conversationID: remoteConversationID)
            let attachment = Attachment(messageID: messageID, type: descriptor.type, path: "")
            attachment.id = descriptor.attachmentID
            let metadata = AttachmentMetadata(name: descriptor.name, encryptedPath: nil,
                                              metadata: try JSONEncoder().encode(descriptor))
            attachment.encryptedMetadata = try encryption.encrypt(JSONEncoder().encode(metadata),
                authenticatedData: Data("luma-attachment-v1|\(attachment.id.uuidString)".utf8)).bytes
            context.insert(attachment)
        }
        if !isMine { conversation.unreadCount = (conversation.unreadCount ?? 0) + 1 }
        try context.save()
    }

    func applyVerifiedRemoteEdit(messageID: UUID, plaintext: Data, revision: Int, at date: Date,
                                 eventID: UUID) throws {
        guard let message = try context.fetch(FetchDescriptor<Message>()).first(where: { $0.id == messageID }),
              [3, 4].contains(message.transportEncryptionVersion ?? 0) else { throw MessageRepositoryError.invalidEvent }
        if (message.remoteRevision ?? 1) >= revision { return }
        guard revision == (message.remoteRevision ?? 1) + 1 else { throw MessageRepositoryError.invalidEvent }
        // An authenticated late edit advances only the routing revision of a local
        // tombstone. Never restore content the user already removed or expired.
        if !message.deleted {
            message.ciphertext = try encryption.encrypt(plaintext, authenticatedData: Self.binding(for: message)).bytes
        }
        message.editedAt = date
        message.remoteRevision = revision
        message.lastEventID = eventID
        try retainV4Tombstone(for: message)
        try context.save()
    }

    /// Future server policy may supply an edit deadline; nil means no local deadline.
    func edit(_ message: Message, content: String, deadline: Date? = nil) throws {
        guard message.isMine, message.type == .text, !message.deleted,
              deadline.map({ Date.now <= $0 }) ?? true else { throw MessageStoreError.editNotAllowed }
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw MessageStoreError.editNotAllowed }
        if message.encryptionVersion == EncryptionVersion.sessionAESGCM.rawValue {
            guard let session = try session(for: message), let senderID = message.senderID else { throw SessionError.missing }
            message.sessionKeyVersion = session.keyVersion
            message.messageKeyIndex = try RatchetManager(context: context, keychain: sessions.keychain, sessions: sessions)
                .nextKey(session: session, senderID: senderID).index
        }
        message.ciphertext = try encryptor.encrypt(Data(value.utf8), for: message,
                                                   session: try session(for: message)).bytes
        message.editedAt = .now
        try context.save()
    }

    func saveDraft(_ text: String, in conversation: Conversation, persist: Bool = true) throws {
        conversation.draft = text.isEmpty ? nil : try encryption.encrypt(Data(text.utf8), authenticatedData: Self.draftBinding(for: conversation)).bytes
        if persist { try context.save() }
    }

    @discardableResult
    func forward(_ source: Message, to conversation: Conversation, senderID: String, completeLocally: Bool = true) throws -> Message {
        let text = try displayContent(for: source)
        let message = Message(conversationID: conversation.id, type: source.type, isMine: true, senderID: senderID)
        message.forwardedFrom = "来自其他聊天"
        message.deliveryStatus = completeLocally ? .sent : .sending
        message.ciphertext = try encryption.encrypt(Data(text.utf8), authenticatedData: Self.binding(for: message)).bytes
        context.insert(message)
        try context.save()
        return message
    }

    /// Local receipt state only. A future transport must authenticate remote acknowledgements before calling these.
    func recordDelivered(_ message: Message, at date: Date = .now) throws {
        guard message.isMine, message.deliveryStatus == .sent else { return }
        message.deliveredAt = date; message.deliveryStatus = .delivered
        try context.save()
    }

    func recordRemoteRead(_ message: Message, at date: Date = .now, receiptsEnabled: Bool) throws {
        guard receiptsEnabled, message.isMine, message.deliveryStatus == .delivered else { return }
        message.readAt = date; message.deliveryStatus = .read
        try context.save()
    }

    /// Opening a local conversation records local read time before any expiration deadline.
    func markConversationRead(_ conversation: Conversation, preferences: PrivacyPreferences, at date: Date = .now) throws {
        let messages = try context.fetch(FetchDescriptor<Message>()).filter {
            $0.conversationID == conversation.id && !$0.isMine && !$0.deleted && $0.readAt == nil
        }
        for message in messages {
            message.readAt = date
            message.deliveryStatus = .read
            if preferences.disappearingMessages { message.expiresAt = date.addingTimeInterval(60) }
            else if preferences.autoDestroyHours > 0 {
                message.expiresAt = date.addingTimeInterval(TimeInterval(preferences.autoDestroyHours) * 3600)
            }
        }
        conversation.unreadCount = 0
        try context.save()
    }

    func purgeExpired(in conversation: Conversation, at date: Date = .now) throws {
        let expired = try context.fetch(FetchDescriptor<Message>()).filter {
            $0.conversationID == conversation.id && $0.expiresAt.map { $0 <= date } == true
        }
        let ids = Set(expired.map(\.id))
        for item in try context.fetch(FetchDescriptor<Attachment>()).filter({ ids.contains($0.messageID) }) {
            try FileTransferService(ownerID: conversation.ownerID, encryption: encryption)
                .delete(attachmentID: item.id)
            for entry in try context.fetch(FetchDescriptor<SearchIndexEntry>()).filter({
                $0.ownerID == conversation.ownerID && $0.sourceID == item.id
            }) { context.delete(entry) }
            context.delete(item)
        }
        for item in try context.fetch(FetchDescriptor<Reaction>()).filter({ ids.contains($0.messageID) }) { context.delete(item) }
        for message in expired {
            if message.transportEncryptionVersion == 4 {
                // Keep only the author/routing/revision needed to authenticate late
                // controls and advance the existing receiving chain, not the content.
                message.deleted = true
                message.deletedAt = date
                message.expiresAt = nil
                message.isFavorite = false
                message.replyToID = nil
                try retainV4Tombstone(for: message)
            } else { context.delete(message) }
        }
        if !expired.isEmpty { try context.save() }
    }

    func draft(in conversation: Conversation) throws -> String {
        guard let bytes = conversation.draft else { return "" }
        let data = try encryption.decrypt(EncryptedData(bytes: bytes), authenticatedData: Self.draftBinding(for: conversation))
        guard let text = String(data: data, encoding: .utf8) else { throw EncryptionError.invalidText }
        return text
    }

    /// Existing phase-one rows are encrypted on the first authenticated unlock.
    func migrateLegacyMessages(owner: User) throws {
        let conversations = try context.fetch(FetchDescriptor<Conversation>()).filter { $0.ownerID == owner.id }
        let friends = try context.fetch(FetchDescriptor<Friend>())
        let conversationByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        let friendByID = Dictionary(uniqueKeysWithValues: friends.map { ($0.id, $0) })
        let messages = try context.fetch(FetchDescriptor<Message>())
        for message in messages where conversationByID[message.conversationID] != nil {
            if message.ciphertext == nil {
                guard !message.content.isEmpty else { throw MessageStoreError.missingCiphertext }
                let conversation = conversationByID[message.conversationID]!
                message.senderID = message.isMine ? owner.userID : (friendByID[conversation.friendID]?.userID ?? "unknown")
                message.ciphertext = try encryption.encrypt(Data(message.content.utf8), authenticatedData: Self.binding(for: message)).bytes
                message.encryptionVersion = 1
                message.content = ""
            } else if !message.content.isEmpty {
                // Clear any leftover legacy plaintext only after validating the ciphertext.
                _ = try displayContent(for: message)
                message.content = ""
            }
            if message.encryptionVersion == nil { message.encryptionVersion = 1 }
            if message.status == nil || message.status == "local" { message.deliveryStatus = .sent }
            try retainV4Tombstone(for: message, eraseContent: false)
        }
        try context.save()
    }

    private static func binding(for message: Message) -> Data {
        Data("luma-message-v1|\(message.id.uuidString)|\(message.conversationID.uuidString)".utf8)
    }

    private func session(for message: Message) throws -> SessionKey? {
        guard message.encryptionVersion == EncryptionVersion.sessionAESGCM.rawValue else { return nil }
        guard let conversation = try context.fetch(FetchDescriptor<Conversation>()).first(where: { $0.id == message.conversationID }),
              let session = try sessions.session(ownerID: conversation.ownerID, friendID: conversation.friendID) else {
            throw SessionError.missing
        }
        return session
    }

    private static func draftBinding(for conversation: Conversation) -> Data {
        Data("luma-draft-v1|\(conversation.id.uuidString)".utf8)
    }
}
