import Foundation
import SwiftData
import CryptoKit

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

struct UserPrivateProfile: Codable {
    var nickname: String
    var avatar: Data?
    var bio: String?
}

struct FriendPrivateProfile: Codable {
    var nickname: String
    var avatar: Data?
    var remark: String
    var privateNote: String?
    var privacyRestricted: Bool
}

/// Encrypts private SwiftData metadata with the existing account master key.
@MainActor
struct PrivateMetadataStore {
    let context: ModelContext
    let encryption: EncryptionService

    func profile(for user: User) throws -> UserPrivateProfile {
        guard let bytes = user.encryptedProfile else {
            return UserPrivateProfile(nickname: user.nickname, avatar: user.avatar, bio: user.bio)
        }
        return try JSONDecoder().decode(UserPrivateProfile.self, from:
            encryption.decryptField(bytes, authenticatedData: binding("user-profile", user.id)))
    }

    func saveProfile(_ profile: UserPrivateProfile, for user: User, persist: Bool = true) throws {
        let bytes = try encryption.encryptField(JSONEncoder().encode(profile),
            authenticatedData: binding("user-profile", user.id))
        user.encryptedProfile = bytes
        user.nickname = ""; user.avatar = nil; user.bio = nil
        if persist { try context.save() }
    }

    func profile(for friend: Friend) throws -> FriendPrivateProfile {
        if let bytes = friend.encryptedProfile {
            return try JSONDecoder().decode(FriendPrivateProfile.self, from:
                encryption.decryptField(bytes, authenticatedData: binding("friend-profile", friend.id)))
        }
        let legacyRemark: String
        if let bytes = friend.encryptedRemark {
            let data = try encryption.decrypt(EncryptedData(bytes: bytes), authenticatedData: binding("remark", friend.id))
            guard let value = String(data: data, encoding: .utf8) else { throw EncryptionError.invalidText }
            legacyRemark = value
        } else { legacyRemark = friend.remark ?? "" }
        return FriendPrivateProfile(nickname: friend.nickname, avatar: friend.avatar,
                                    remark: legacyRemark, privateNote: nil,
                                    privacyRestricted: friend.privacyRestricted ?? false)
    }

    func saveProfile(_ profile: FriendPrivateProfile, for friend: Friend, persist: Bool = true) throws {
        let bytes = try encryption.encryptField(JSONEncoder().encode(profile),
            authenticatedData: binding("friend-profile", friend.id))
        friend.encryptedProfile = bytes
        friend.nickname = ""; friend.avatar = nil; friend.remark = nil
        friend.encryptedRemark = nil; friend.privacyRestricted = nil
        if persist { try context.save() }
    }

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
        try profile(for: friend).remark
    }

    func displayName(for friend: Friend) throws -> String {
        let profile = try profile(for: friend)
        let value = profile.remark.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? profile.nickname : value
    }

    func saveRemark(_ value: String, for friend: Friend, persist: Bool = true) throws {
        var profile = try profile(for: friend)
        profile.remark = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try saveProfile(profile, for: friend, persist: persist)
    }

    func savePrivateNote(_ value: String?, for friend: Friend) throws {
        var profile = try profile(for: friend)
        profile.privateNote = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        try saveProfile(profile, for: friend)
    }

    func savePrivacyRestricted(_ value: Bool, for friend: Friend) throws {
        var profile = try profile(for: friend)
        profile.privacyRestricted = value
        try saveProfile(profile, for: friend)
    }

    func migrate(owner: User) throws {
        let normalizedID = try LocalRepository.normalizedUserID(owner.userID)
        let expectedHMAC = try LocalRepository.userIDHMAC(normalizedID)
        if let storedHMAC = owner.userIDHMAC, storedHMAC != expectedHMAC { throw LocalDataError.invalidUserID }
        if let legacyHash = owner.userIDHash {
            let expectedLegacy = SHA256.hash(data: Data(normalizedID.utf8))
                .map { String(format: "%02x", $0) }.joined()
            guard legacyHash == expectedLegacy else { throw LocalDataError.invalidUserID }
        }
        owner.userIDHMAC = expectedHMAC
        owner.userIDHash = nil
        if owner.encryptedProfile == nil {
            try saveProfile(profile(for: owner), for: owner, persist: false)
        } else if !owner.nickname.isEmpty || owner.avatar != nil || owner.bio != nil {
            _ = try profile(for: owner)
            owner.nickname = ""; owner.avatar = nil; owner.bio = nil
        }
        let friends = try context.fetch(FetchDescriptor<Friend>()).filter { $0.ownerID == owner.id }
        for friend in friends {
            if friend.encryptedProfile == nil {
                try saveProfile(profile(for: friend), for: friend, persist: false)
            } else if !friend.nickname.isEmpty || friend.avatar != nil || friend.remark != nil ||
                        friend.encryptedRemark != nil || friend.privacyRestricted != nil {
                _ = try profile(for: friend)
                friend.nickname = ""; friend.avatar = nil; friend.remark = nil
                friend.encryptedRemark = nil; friend.privacyRestricted = nil
            }
        }
        if owner.encryptedPreferences == nil { try save(legacyPreferences(for: owner), for: owner, persist: false) }
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

    func saveAttachmentMetadata(_ metadata: AttachmentMetadata, for attachment: Attachment) throws {
        attachment.encryptedMetadata = try encryption.encrypt(JSONEncoder().encode(metadata),
            authenticatedData: binding("attachment", attachment.id)).bytes
        attachment.path = ""
        attachment.encryptedPath = nil
        attachment.encryptionMetadata = nil
        try context.save()
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
