import Foundation
import SwiftData

enum MessageStoreError: LocalizedError {
    case locked, missingCiphertext, editNotAllowed, unsupportedEncryptionVersion

    var errorDescription: String? {
        switch self {
        case .locked: "应用已锁定，请先解锁后读取消息"
        case .missingCiphertext: "消息数据不完整，无法显示"
        case .editNotAllowed: "只能编辑自己发送的文字消息"
        case .unsupportedEncryptionVersion: "此消息使用当前版本不支持的加密格式"
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
                               eventID: UUID, isMine: Bool) throws {
        if try context.fetch(FetchDescriptor<Message>()).contains(where: { $0.id == messageID }) { return }
        let message = Message(conversationID: conversation.id, type: .text, isMine: isMine,
                              senderID: senderID, timestamp: date)
        message.id = messageID
        message.encryptionVersion = EncryptionVersion.localAESGCM.rawValue
        message.transportEncryptionVersion = 3
        message.remoteRevision = 1
        message.deviceID = senderDeviceID
        message.lastEventID = eventID
        message.deliveryStatus = isMine ? .sent : .delivered
        if !isMine { message.deliveredAt = date }
        message.ciphertext = try encryption.encrypt(plaintext, authenticatedData: Self.binding(for: message)).bytes
        context.insert(message)
        if !isMine { conversation.unreadCount = (conversation.unreadCount ?? 0) + 1 }
        try context.save()
    }

    func applyVerifiedRemoteEdit(messageID: UUID, plaintext: Data, revision: Int, at date: Date,
                                 eventID: UUID) throws {
        guard let message = try context.fetch(FetchDescriptor<Message>()).first(where: { $0.id == messageID }),
              message.transportEncryptionVersion == 3 else { throw MessageRepositoryError.invalidEvent }
        if (message.remoteRevision ?? 1) >= revision { return }
        guard revision == (message.remoteRevision ?? 1) + 1 else { throw MessageRepositoryError.invalidEvent }
        message.ciphertext = try encryption.encrypt(plaintext, authenticatedData: Self.binding(for: message)).bytes
        message.editedAt = date
        message.remoteRevision = revision
        message.lastEventID = eventID
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
        for item in try context.fetch(FetchDescriptor<Attachment>()).filter({ ids.contains($0.messageID) }) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<Reaction>()).filter({ ids.contains($0.messageID) }) { context.delete(item) }
        for message in expired { context.delete(message) }
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
