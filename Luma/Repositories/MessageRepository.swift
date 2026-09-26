import Foundation
import SwiftData

enum MessageRepositoryError: LocalizedError {
    case missingConversation, invalidEvent
    var errorDescription: String? {
        switch self {
        case .missingConversation: "聊天不存在，无法处理消息事件"
        case .invalidEvent: "消息事件无效或数据已损坏"
        }
    }
}

/// The chat ViewModel depends on this boundary; storage and transport remain separate.
@MainActor
protocol MessageRepository {
    func send(conversationID: UUID, senderID: String, type: MessageType, content: String, replyToID: UUID?) throws -> MessageEvent
    func sendSession(conversation: Conversation, senderID: String, content: String) throws -> MessageEvent
    func displayContent(for message: Message) throws -> String
    func edit(_ message: Message, content: String) throws -> MessageEvent
    func delete(_ message: Message, forEveryone: Bool) throws -> MessageEvent
    func react(_ emoji: String, to message: Message, reactorID: String) throws -> MessageEvent?
    func forward(_ message: Message, to conversation: Conversation, senderID: String) throws -> MessageEvent
    func saveDraft(_ text: String, in conversation: Conversation) throws
    func draft(in conversation: Conversation) throws -> String
    func markConversationRead(_ conversation: Conversation, preferences: PrivacyPreferences) throws -> [MessageEvent]
    func purgeExpired(in conversation: Conversation) throws
    func apply(_ event: MessageEvent) throws
}

@MainActor
struct LocalMessageRepository: MessageRepository {
    let context: ModelContext
    let encryption: EncryptionService
    var sessions: SessionManager? = nil

    private var store: MessageStore { MessageStore(context: context, encryption: encryption, sessions: sessions) }

    func send(conversationID: UUID, senderID: String, type: MessageType, content: String, replyToID: UUID? = nil) throws -> MessageEvent {
        let message = try store.send(conversationID: conversationID, senderID: senderID, type: type,
                                     content: content, replyToID: replyToID, completeLocally: false)
        message.deviceID = try localDeviceID(for: senderID)
        try apply(MessageEvent(kind: .messageSent, messageID: message.id))
        return try newMessageEvent(for: message)
    }

    func sendSession(conversation: Conversation, senderID: String, content: String) throws -> MessageEvent {
        let manager = sessions ?? SessionManager(context: context)
        guard let session = try manager.session(ownerID: conversation.ownerID, friendID: conversation.friendID) else {
            throw SessionError.missing
        }
        let message = try store.sendSession(conversation: conversation, session: session,
                                             senderID: senderID, content: content)
        message.deviceID = try localDeviceID(for: senderID)
        return try newMessageEvent(for: message)
    }

    func displayContent(for message: Message) throws -> String { try store.displayContent(for: message) }

    func edit(_ message: Message, content: String) throws -> MessageEvent {
        try store.edit(message, content: content)
        let payload: Data?
        if message.encryptionVersion == 2, let ciphertext = message.ciphertext,
           let version = message.sessionKeyVersion, let index = message.messageKeyIndex {
            payload = try JSONEncoder().encode(EditedMessagePayload(ciphertext: ciphertext,
                                                                      sessionKeyVersion: version, messageKeyIndex: index))
        } else { payload = message.ciphertext }
        let event = MessageEvent(kind: .messageEdited, messageID: message.id, payload: payload,
                                 actorID: message.senderID, deviceID: message.deviceID)
        message.lastEventID = event.id
        try context.save()
        return event
    }

    func delete(_ message: Message, forEveryone: Bool) throws -> MessageEvent {
        let conversation = try context.fetch(FetchDescriptor<Conversation>()).first { $0.id == message.conversationID }
        let ownerID = try context.fetch(FetchDescriptor<User>()).first { $0.id == conversation?.ownerID }?.userID
        let event = MessageEvent(kind: .messageDeleted, messageID: message.id,
                                 payload: Data([forEveryone ? 1 : 0]), actorID: ownerID,
                                 deviceID: try ownerID.flatMap { try localDeviceID(for: $0) })
        try apply(event)
        return event
    }

    func react(_ emoji: String, to message: Message, reactorID: String) throws -> MessageEvent? {
        guard ["👍", "❤️", "😂", "‼️"].contains(emoji) else { return nil }
        let existing = try context.fetch(FetchDescriptor<Reaction>()).first {
            $0.messageID == message.id && $0.reactorID == reactorID
        }
        // A second tap removes the local reaction; only additions are transport-ready in this phase.
        if existing?.emoji == emoji {
            context.delete(existing!)
            try context.save()
            return nil
        }
        let payload = try JSONEncoder().encode(ReactionEventPayload(emoji: emoji, reactorID: reactorID))
        let event = MessageEvent(kind: .reactionAdded, messageID: message.id, payload: payload, actorID: reactorID)
        try apply(event)
        return event
    }

    func forward(_ message: Message, to conversation: Conversation, senderID: String) throws -> MessageEvent {
        let copy = try store.forward(message, to: conversation, senderID: senderID, completeLocally: false)
        copy.deviceID = try localDeviceID(for: senderID)
        try apply(MessageEvent(kind: .messageSent, messageID: copy.id))
        return try newMessageEvent(for: copy)
    }

    func saveDraft(_ text: String, in conversation: Conversation) throws { try store.saveDraft(text, in: conversation) }
    func draft(in conversation: Conversation) throws -> String { try store.draft(in: conversation) }
    func purgeExpired(in conversation: Conversation) throws { try store.purgeExpired(in: conversation) }

    func markConversationRead(_ conversation: Conversation, preferences: PrivacyPreferences) throws -> [MessageEvent] {
        let unread = try context.fetch(FetchDescriptor<Message>()).filter {
            $0.conversationID == conversation.id && !$0.isMine && !$0.deleted && $0.readAt == nil
        }
        let readerID = try context.fetch(FetchDescriptor<User>()).first { $0.id == conversation.ownerID }?.userID ?? "local"
        try store.markConversationRead(conversation, preferences: preferences)
        guard preferences.readReceipts else { return [] }
        let events = try unread.map { message in
            let receipt = ReadReceiptEvent(messageID: message.id, readerID: readerID, timestamp: message.readAt ?? .now)
            let payload = try JSONEncoder().encode(receipt)
            let event = MessageEvent(kind: .messageRead, messageID: message.id, timestamp: receipt.timestamp,
                                     payload: payload, actorID: readerID,
                                     deviceID: try localDeviceID(for: readerID))
            message.lastEventID = event.id
            return event
        }
        if !events.isEmpty { try context.save() }
        return events
    }

    func apply(_ event: MessageEvent) throws {
        let message = try context.fetch(FetchDescriptor<Message>()).first { $0.id == event.messageID }
        if let message, message.lastEventID == event.id { return }
        try EventVerifier(context: context).verify(event, message: message)
        if event.kind == .newMessage {
            guard message == nil, let payload = event.payload,
                  let data = try? JSONDecoder().decode(NewMessagePayload.self, from: payload),
                  let conversation = try context.fetch(FetchDescriptor<Conversation>()).first(where: { $0.id == data.conversationID })
            else { if message != nil { return }; throw MessageRepositoryError.invalidEvent }
            let incoming = Message(conversationID: data.conversationID, type: data.type, isMine: false,
                                   senderID: data.senderID, timestamp: event.timestamp, replyToID: data.replyToID)
            incoming.id = event.messageID
            incoming.ciphertext = data.ciphertext
            incoming.encryptionVersion = data.encryptionVersion
            incoming.sessionKeyVersion = data.sessionKeyVersion
            incoming.messageKeyIndex = data.messageKeyIndex
            _ = try store.displayContent(for: incoming) // Check AES-GCM tag before persisting.
            if let index = incoming.messageKeyIndex, let version = incoming.sessionKeyVersion,
               let session = try (sessions ?? SessionManager(context: context))
                   .session(ownerID: conversation.ownerID, friendID: conversation.friendID) {
                let manager = sessions ?? SessionManager(context: context)
                try RatchetManager(context: context, keychain: manager.keychain, sessions: manager)
                    .advanceReceived(session: session, senderID: data.senderID, version: version, index: index)
            }
            incoming.deliveryStatus = .delivered
            incoming.deliveredAt = event.timestamp
            incoming.deviceID = event.deviceID
            incoming.lastEventID = event.id
            context.insert(incoming)
            conversation.unreadCount = (conversation.unreadCount ?? 0) + 1
            try context.save()
            return
        }
        guard let message else { throw MessageRepositoryError.invalidEvent }
        switch event.kind {
        case .newMessage: break
        case .messageSent:
            guard message.isMine, message.deliveryStatus == .sending else { return }
            message.deliveryStatus = .sent
        case .messageDelivered:
            guard message.isMine, message.deliveryStatus == .sent else { return }
            message.deliveryStatus = .delivered; message.deliveredAt = event.timestamp
        case .messageRead:
            guard message.isMine, message.deliveryStatus == .delivered,
                  let payload = event.payload,
                  let receipt = try? JSONDecoder().decode(ReadReceiptEvent.self, from: payload),
                  receipt.messageID == message.id else { return }
            message.deliveryStatus = .read; message.readAt = receipt.timestamp
        case .messageDeleted:
            if let deletedAt = message.deletedAt, deletedAt >= event.timestamp { return }
            message.deleted = true
            message.deletedForEveryone = event.payload?.first == 1
            message.deletedAt = event.timestamp
        case .reactionAdded:
            guard let payload = event.payload,
                  let reaction = try? JSONDecoder().decode(ReactionEventPayload.self, from: payload),
                  ["👍", "❤️", "😂", "‼️"].contains(reaction.emoji) else { throw MessageRepositoryError.invalidEvent }
            let existing = try context.fetch(FetchDescriptor<Reaction>()).first {
                $0.messageID == message.id && $0.reactorID == reaction.reactorID
            }
            if let existing { existing.emoji = reaction.emoji }
            else { context.insert(Reaction(messageID: message.id, emoji: reaction.emoji, reactorID: reaction.reactorID)) }
        case .messageEdited:
            guard let bytes = event.payload, message.type == .text else { throw MessageRepositoryError.invalidEvent }
            if let editedAt = message.editedAt, editedAt >= event.timestamp { return }
            let candidate = Message(conversationID: message.conversationID, type: .text, isMine: message.isMine)
            let edited = message.encryptionVersion == 2 ? try? JSONDecoder().decode(EditedMessagePayload.self, from: bytes) : nil
            candidate.id = message.id; candidate.ciphertext = edited?.ciphertext ?? bytes
            candidate.encryptionVersion = message.encryptionVersion
            candidate.senderID = message.senderID
            candidate.sessionKeyVersion = edited?.sessionKeyVersion ?? message.sessionKeyVersion
            candidate.messageKeyIndex = edited?.messageKeyIndex ?? message.messageKeyIndex
            _ = try store.displayContent(for: candidate)
            message.ciphertext = candidate.ciphertext
            message.sessionKeyVersion = candidate.sessionKeyVersion
            message.messageKeyIndex = candidate.messageKeyIndex
            message.editedAt = event.timestamp
        }
        message.lastEventID = event.id
        try context.save()
    }

    private func newMessageEvent(for message: Message) throws -> MessageEvent {
        guard let ciphertext = message.ciphertext, let senderID = message.senderID else { throw MessageRepositoryError.invalidEvent }
        let payload = try JSONEncoder().encode(NewMessagePayload(conversationID: message.conversationID,
            senderID: senderID, type: message.type, ciphertext: ciphertext,
            encryptionVersion: message.encryptionVersion ?? 1,
            sessionKeyVersion: message.sessionKeyVersion, messageKeyIndex: message.messageKeyIndex,
            replyToID: message.replyToID))
        let event = MessageEvent(kind: .newMessage, messageID: message.id, timestamp: message.timestamp,
                                 payload: payload, actorID: senderID, deviceID: message.deviceID)
        message.lastEventID = event.id
        try context.save()
        return event
    }

    private func localDeviceID(for senderID: String) throws -> UUID? {
        guard let owner = try context.fetch(FetchDescriptor<User>()).first(where: { $0.userID == senderID }) else { return nil }
        return try context.fetch(FetchDescriptor<Device>()).first(where: { $0.ownerID == owner.id })?.id
    }
}
