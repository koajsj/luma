import Foundation
import SwiftData

struct PrivacyPreferences: Codable {
    var searchable = false
    var faceIDEnabled = false
    var screenshotAlerts = false
    var recordingAlerts = false
    var screenCaptureProtection: Bool? = true
    var hideInBackground = true
    var autoDestroyHours = 0
    var disappearingMessages = false
    var readReceipts = true
    var messagePreviews = true
    var showOnlineStatus = true
    var showLastSeen = true
    var privacyModeEnabled = false
    var privacyModeLockChats = false

    var effectiveMessagePreviews: Bool { !privacyModeEnabled && messagePreviews }
    var effectiveBackgroundHide: Bool { privacyModeEnabled || hideInBackground }
    var effectiveScreenCaptureProtection: Bool { screenCaptureProtection ?? true }
}

/// Encrypts private SwiftData metadata with the existing account master key.
@MainActor
struct PrivateMetadataStore {
    let context: ModelContext
    let encryption: EncryptionService

    func preferences(for user: User) throws -> PrivacyPreferences {
        guard let bytes = user.encryptedPreferences else { return legacyPreferences(for: user) }
        let data = try encryption.decrypt(EncryptedData(bytes: bytes), authenticatedData: binding("preferences", user.id))
        return try JSONDecoder().decode(PrivacyPreferences.self, from: data)
    }

    func save(_ value: PrivacyPreferences, for user: User, persist: Bool = true) throws {
        let data = try JSONEncoder().encode(value)
        user.encryptedPreferences = try encryption.encrypt(data, authenticatedData: binding("preferences", user.id)).bytes
        clearLegacyPreferences(user, searchable: value.searchable)
        if persist { try context.save() }
    }

    func remark(for friend: Friend) throws -> String {
        guard let bytes = friend.encryptedRemark else { return friend.remark ?? "" }
        let data = try encryption.decrypt(EncryptedData(bytes: bytes), authenticatedData: binding("remark", friend.id))
        guard let value = String(data: data, encoding: .utf8) else { throw EncryptionError.invalidText }
        return value
    }

    func displayName(for friend: Friend) throws -> String {
        let value = try remark(for: friend).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? friend.nickname : value
    }

    func saveRemark(_ value: String, for friend: Friend, persist: Bool = true) throws {
        friend.encryptedRemark = try encryption.encrypt(Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
                                                         authenticatedData: binding("remark", friend.id)).bytes
        friend.remark = nil
        if persist { try context.save() }
    }

    func migrate(owner: User) throws {
        if owner.encryptedPreferences == nil { try save(legacyPreferences(for: owner), for: owner) }
        let friends = try context.fetch(FetchDescriptor<Friend>()).filter { $0.ownerID == owner.id }
        for friend in friends {
            if friend.encryptedRemark == nil, let remark = friend.remark {
                try saveRemark(remark, for: friend)
            } else if friend.encryptedRemark != nil, friend.remark != nil {
                _ = try self.remark(for: friend)
                friend.remark = nil
            }
        }
        let conversationIDs = Set(try context.fetch(FetchDescriptor<Conversation>())
            .filter { $0.ownerID == owner.id }.map(\.id))
        let messageIDs = Set(try context.fetch(FetchDescriptor<Message>())
            .filter { conversationIDs.contains($0.conversationID) }.map(\.id))
        let attachments = try context.fetch(FetchDescriptor<Attachment>())
            .filter { messageIDs.contains($0.messageID) }
        for attachment in attachments {
            // Legacy attachments contain only a path label; never copy an arbitrary path into an export.
            if attachment.encryptedMetadata == nil {
                let data = try JSONEncoder().encode(AttachmentMetadata(name: attachment.path, encryptedPath: attachment.encryptedPath,
                                                                        metadata: attachment.encryptionMetadata))
                attachment.encryptedMetadata = try encryption.encrypt(data, authenticatedData: binding("attachment", attachment.id)).bytes
                attachment.path = ""; attachment.encryptedPath = nil; attachment.encryptionMetadata = nil
            }
        }
        try context.save()
    }

    func attachmentMetadata(for attachment: Attachment) throws -> AttachmentMetadata {
        guard let bytes = attachment.encryptedMetadata else {
            return AttachmentMetadata(name: attachment.path, encryptedPath: attachment.encryptedPath, metadata: attachment.encryptionMetadata)
        }
        let data = try encryption.decrypt(EncryptedData(bytes: bytes), authenticatedData: binding("attachment", attachment.id))
        return try JSONDecoder().decode(AttachmentMetadata.self, from: data)
    }

    private func legacyPreferences(for user: User) -> PrivacyPreferences {
        var value = PrivacyPreferences()
        value.searchable = user.searchable; value.faceIDEnabled = user.faceIDEnabled
        value.screenshotAlerts = user.screenshotAlerts; value.recordingAlerts = user.recordingAlerts
        value.hideInBackground = user.hideInBackground; value.autoDestroyHours = user.autoDestroyHours
        value.disappearingMessages = user.disappearingMessages; value.readReceipts = user.readReceipts ?? true
        value.messagePreviews = user.messagePreviews ?? true; value.showOnlineStatus = user.showOnlineStatus ?? true
        value.showLastSeen = user.showLastSeen ?? true; value.privacyModeEnabled = user.privacyModeEnabled ?? false
        value.privacyModeLockChats = user.privacyModeLockChats ?? false
        return value
    }

    private func clearLegacyPreferences(_ user: User, searchable: Bool) {
        // Public discovery requires a minimal local flag until a server owns discovery.
        user.searchable = searchable; user.faceIDEnabled = false
        user.screenshotAlerts = false; user.recordingAlerts = false; user.hideInBackground = true
        user.autoDestroyHours = 0; user.disappearingMessages = false
        user.readReceipts = nil; user.messagePreviews = nil; user.showOnlineStatus = nil
        user.showLastSeen = nil; user.privacyModeEnabled = nil; user.privacyModeLockChats = nil
    }

    private func binding(_ kind: String, _ id: UUID) -> Data { Data("luma-\(kind)-v1|\(id.uuidString)".utf8) }
}

struct AttachmentMetadata: Codable {
    var name: String
    var encryptedPath: String?
    var metadata: Data?
}
