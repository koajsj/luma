import Foundation
import SwiftData

@MainActor
struct ChatViewModel {
    let context: ModelContext
    let security: SecurityManager

    private var repository: any MessageRepository {
        get throws { LocalMessageRepository(context: context, encryption: try security.encryptionService(),
                                            sessions: try security.sessionManager(context: context)) }
    }

    func onlineAvailable(for user: User) -> Bool {
        guard (try? security.currentUserID()) == user.userID else { return false }
        let store = RemoteSessionStore()
        return (try? store.registration(for: user.userID)) != nil &&
               (try? store.tokens(for: user.userID)) != nil
    }

    private func remoteRepository(for user: User) throws -> RemoteMessageRepository {
        guard try security.currentUserID() == user.userID,
              let registration = try RemoteSessionStore().registration(for: user.userID) else {
            throw RemoteError.unregistered
        }
        return RemoteMessageRepository(context: context, user: user, security: security,
            client: try RemoteAPIClient(baseURL: registration.baseURL, userID: user.userID),
            registration: registration)
    }

    func sendOnlineText(_ text: String, user: User, friend: Friend, conversation: Conversation) async throws {
        try await remoteRepository(for: user).sendText(text, to: friend, in: conversation)
    }

    func syncOnline(user: User) async throws -> Int {
        let repository = try remoteRepository(for: user)
        try? await repository.retryOutgoing()
        return try await repository.sync()
    }

    func retryFailedOnline(_ messageID: UUID, user: User) async throws {
        try await remoteRepository(for: user).retryFailed(messageID)
    }

    func onlineIdentityFingerprint(user: User, friend: Friend) async throws -> String {
        try await remoteRepository(for: user).identityFingerprint(for: friend)
    }

    func trustOnlineIdentity(_ fingerprint: String, user: User, friend: Friend) throws {
        try remoteRepository(for: user).trustIdentity(fingerprint, for: friend)
    }

    func editOnlineText(_ text: String, message: Message, user: User,
                        friend: Friend, conversation: Conversation) async throws {
        try await remoteRepository(for: user).editText(text, message: message, friend: friend,
                                                        conversation: conversation)
    }

    func deleteOnline(_ message: Message, user: User) async throws {
        try await remoteRepository(for: user).deleteForEveryone(message)
    }

    func markOnlineRead(_ conversation: Conversation, user: User) async throws {
        try await remoteRepository(for: user).markRead(conversation)
    }

    func reactOnline(_ emoji: String, to message: Message, user: User,
                     friend: Friend, conversation: Conversation) async throws {
        try await remoteRepository(for: user).react(emoji, to: message, friend: friend,
                                                    conversation: conversation)
    }

    func sendText(_ rawText: String, in conversation: Conversation?, replyingTo message: Message?) throws -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let conversation else { return false }
        _ = try repository.send(conversationID: conversation.id, senderID: try security.currentUserID(), type: .text, content: text, replyToID: message?.id)
        return true
    }

    func sendPlaceholder(_ type: MessageType, in conversation: Conversation?) throws {
        guard let conversation else { return }
        let labels: [MessageType: String] = [.image: "模拟图片", .file: "模拟文件", .voice: "模拟语音"]
        _ = try repository.send(conversationID: conversation.id, senderID: try security.currentUserID(), type: type, content: labels[type] ?? "模拟内容", replyToID: nil)
    }

    func displayContent(for message: Message) throws -> String { try repository.displayContent(for: message) }

    func edit(_ message: Message, text: String) throws { _ = try repository.edit(message, content: text) }
    func saveDraft(_ text: String, in conversation: Conversation) throws { try repository.saveDraft(text, in: conversation) }
    func draft(in conversation: Conversation) throws -> String { try repository.draft(in: conversation) }

    func visibleContent(for message: Message) -> String {
        do { return try displayContent(for: message) }
        catch { return error.localizedDescription }
    }

    func delete(_ message: Message, forEveryone: Bool) throws {
        _ = try repository.delete(message, forEveryone: forEveryone)
    }

    func setFavorite(_ value: Bool, for message: Message) throws {
        message.isFavorite = value
        try context.save()
    }

    func react(_ emoji: String, to message: Message) throws {
        _ = try repository.react(emoji, to: message, reactorID: security.currentUserID())
    }

    func forward(_ message: Message, to conversation: Conversation) throws {
        _ = try repository.forward(message, to: conversation, senderID: security.currentUserID())
    }

    func setPinned(_ value: Bool, for conversation: Conversation) throws {
        conversation.isPinned = value
        try context.save()
    }

    func markUnread(_ conversation: Conversation) throws {
        conversation.unreadCount = max(1, conversation.unreadCount ?? 0)
        try context.save()
    }

    func markRead(_ conversation: Conversation) throws {
        _ = try repository.markConversationRead(conversation, preferences: security.preferences)
    }

    func purgeExpired(_ conversation: Conversation) throws {
        try repository.purgeExpired(in: conversation)
    }

    func search(_ query: String, for user: User) throws -> [LocalSearchResult] {
        let service = SearchIndexService(context: context, encryption: try security.encryptionService(),
                                         sessions: try security.sessionManager(context: context))
        try service.rebuild(for: user, lockAllChats: security.preferences.privacyModeEnabled && security.preferences.privacyModeLockChats)
        return try service.search(query, for: user)
    }
}
