import Foundation

/// Explicit local simulator. A future remote provider must authenticate peers and events first.
@MainActor
struct SyncCoordinator {
    let repository: any MessageRepository
    let provider: any MessageSyncProvider
    let endpoint: String
    let peerEndpoint: String

    @discardableResult
    func send(conversationID: UUID, senderID: String, content: String) throws -> MessageEvent {
        let event = try repository.send(conversationID: conversationID, senderID: senderID,
                                        type: .text, content: content, replyToID: nil)
        try provider.publish(event, to: peerEndpoint)
        return event
    }

    @discardableResult
    func sync(readReceiptsEnabled: Bool = true) throws -> [MessageEvent] {
        var applied: [MessageEvent] = []
        for event in try provider.pending(for: endpoint) {
            if event.kind == .messageRead && !readReceiptsEnabled {
                try provider.complete(event.id, for: endpoint)
                continue
            }
            try repository.apply(event)
            if event.kind == .newMessage {
                try provider.publish(MessageEvent(kind: .messageDelivered, messageID: event.messageID), to: peerEndpoint)
            }
            try provider.complete(event.id, for: endpoint)
            applied.append(event)
        }
        return applied
    }

    func acknowledgeRead(_ conversation: Conversation, preferences: PrivacyPreferences) throws {
        let events = try repository.markConversationRead(conversation, preferences: preferences)
        for event in events { try provider.publish(event, to: peerEndpoint) }
    }

    func delete(_ message: Message, forEveryone: Bool) throws {
        let event = try repository.delete(message, forEveryone: forEveryone)
        if forEveryone { try provider.publish(event, to: peerEndpoint) }
    }

    func edit(_ message: Message, content: String) throws {
        try provider.publish(repository.edit(message, content: content), to: peerEndpoint)
    }

    func react(_ emoji: String, to message: Message, reactorID: String) throws {
        if let event = try repository.react(emoji, to: message, reactorID: reactorID) {
            try provider.publish(event, to: peerEndpoint)
        }
    }
}
