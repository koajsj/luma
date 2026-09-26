import Foundation
import SwiftData

struct LocalSearchResult: Identifiable {
    let id: UUID
    let sourceID: UUID
    let kind: String
    let preview: String
    let conversationID: UUID?
}

/// An encrypted, rebuildable local index. Search scans decrypted index entries only while unlocked.
@MainActor
struct SearchIndexService {
    let context: ModelContext
    let encryption: EncryptionService
    var sessions: SessionManager? = nil

    func rebuild(for user: User, lockAllChats: Bool = false) throws {
        let store = MessageStore(context: context, encryption: encryption, sessions: sessions)
        let metadata = PrivateMetadataStore(context: context, encryption: encryption)
        let conversations = try context.fetch(FetchDescriptor<Conversation>()).filter { $0.ownerID == user.id }
        let conversationIDs = Set(conversations.filter { !($0.requiresUnlock ?? false) && !($0.requiresPrivacyShield ?? false) && !lockAllChats }.map(\.id))
        let messages = try context.fetch(FetchDescriptor<Message>()).filter { conversationIDs.contains($0.conversationID) && !$0.deleted }
        let messageIDs = Set(messages.map(\.id))
        let attachments = try context.fetch(FetchDescriptor<Attachment>()).filter { messageIDs.contains($0.messageID) }
        let friends = try context.fetch(FetchDescriptor<Friend>()).filter { $0.ownerID == user.id }
        let existing = try context.fetch(FetchDescriptor<SearchIndexEntry>()).filter { $0.ownerID == user.id }

        var entries: [SearchIndexEntry] = []
        func add(_ text: String, sourceID: UUID, kind: String) throws {
            guard !text.isEmpty else { return }
            let binding = Data("luma-index-v1|\(user.id.uuidString)|\(sourceID.uuidString)|\(kind)".utf8)
            let bytes = try encryption.encrypt(Data(text.utf8), authenticatedData: binding).bytes
            entries.append(SearchIndexEntry(ownerID: user.id, sourceID: sourceID, kind: kind, encryptedText: bytes))
        }
        for message in messages where message.type == .text || message.type == .file {
            try add(try store.displayContent(for: message), sourceID: message.id, kind: "message")
        }
        for attachment in attachments {
            try add(try metadata.attachmentMetadata(for: attachment).name, sourceID: attachment.id, kind: "file")
        }
        let shieldedFriendIDs = Set(conversations.filter { $0.requiresPrivacyShield == true }.map(\.friendID))
        for friend in friends where !shieldedFriendIDs.contains(friend.id) {
            let remark = try metadata.remark(for: friend)
            try add("\(friend.userID) \(friend.nickname) \(remark)", sourceID: friend.id, kind: "friend")
        }
        for item in existing { context.delete(item) }
        for item in entries { context.insert(item) }
        try context.save()
    }

    func search(_ rawQuery: String, for user: User) throws -> [LocalSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !query.isEmpty else { return [] }
        let entries = try context.fetch(FetchDescriptor<SearchIndexEntry>()).filter { $0.ownerID == user.id }
        let messages = try context.fetch(FetchDescriptor<Message>())
        let attachments = try context.fetch(FetchDescriptor<Attachment>())
        let conversations = try context.fetch(FetchDescriptor<Conversation>()).filter { $0.ownerID == user.id }
        let hiddenConversationIDs = Set(conversations.filter { $0.requiresPrivacyShield == true || $0.requiresUnlock == true }.map(\.id))
        let hiddenFriendIDs = Set(conversations.filter { $0.requiresPrivacyShield == true }.map(\.friendID))
        return try entries.compactMap { entry in
            if entry.kind == "friend" && hiddenFriendIDs.contains(entry.sourceID) { return nil }
            let binding = Data("luma-index-v1|\(user.id.uuidString)|\(entry.sourceID.uuidString)|\(entry.kind)".utf8)
            let data = try encryption.decrypt(EncryptedData(bytes: entry.encryptedText), authenticatedData: binding)
            guard let text = String(data: data, encoding: .utf8) else { throw EncryptionError.invalidText }
            guard text.localizedLowercase.contains(query) else { return nil }
            let conversationID: UUID?
            if entry.kind == "message" { conversationID = messages.first { $0.id == entry.sourceID }?.conversationID }
            else if entry.kind == "file", let attachment = attachments.first(where: { $0.id == entry.sourceID }) {
                conversationID = messages.first { $0.id == attachment.messageID }?.conversationID
            } else { conversationID = nil }
            if let conversationID, hiddenConversationIDs.contains(conversationID) { return nil }
            return LocalSearchResult(id: entry.id, sourceID: entry.sourceID, kind: entry.kind, preview: text, conversationID: conversationID)
        }
    }
}
