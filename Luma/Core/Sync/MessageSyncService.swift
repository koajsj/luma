import Foundation

/// Explicit opt-in simulator for two local endpoints sharing a test encryption key.
/// It is not wired to the production chat UI and cannot represent real remote delivery.
@MainActor
struct MessageSyncService {
    let repository: any MessageRepository
    let transport: any MessageTransport
    let endpoint: String
    let peerEndpoint: String

    private var coordinator: SyncCoordinator {
        SyncCoordinator(repository: repository, provider: MockMessageSyncProvider(transport: transport),
                        endpoint: endpoint, peerEndpoint: peerEndpoint)
    }

    @discardableResult
    func send(conversationID: UUID, senderID: String, content: String) throws -> MessageEvent {
        try coordinator.send(conversationID: conversationID, senderID: senderID, content: content)
    }

    @discardableResult
    func sync(readReceiptsEnabled: Bool = true) throws -> [MessageEvent] {
        try coordinator.sync(readReceiptsEnabled: readReceiptsEnabled)
    }

    func acknowledgeRead(_ conversation: Conversation, preferences: PrivacyPreferences) throws {
        try coordinator.acknowledgeRead(conversation, preferences: preferences)
    }

    func delete(_ message: Message, forEveryone: Bool) throws {
        try coordinator.delete(message, forEveryone: forEveryone)
    }

    func edit(_ message: Message, content: String) throws {
        try coordinator.edit(message, content: content)
    }

    func react(_ emoji: String, to message: Message, reactorID: String) throws {
        try coordinator.react(emoji, to: message, reactorID: reactorID)
    }
}
