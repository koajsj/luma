import Foundation
import SwiftData

@Model
final class User {
    @Attribute(.unique) var userID: String
    var id: UUID
    var nickname: String
    var passwordHash: String
    var searchable: Bool
    var faceIDEnabled: Bool
    var screenshotAlerts: Bool
    var recordingAlerts: Bool
    var hideInBackground: Bool
    var autoDestroyHours: Int
    var disappearingMessages: Bool
    var avatar: Data?
    var bio: String?
    var readReceipts: Bool?
    var messagePreviews: Bool?
    var showOnlineStatus: Bool?
    var showLastSeen: Bool?
    var privacyModeEnabled: Bool?
    var privacyModeLockChats: Bool?
    var identityPublicKey: Data?
    var identityFingerprint: String?
    var encryptedPreferences: Data?

    var effectiveOnlineStatus: Bool { !(privacyModeEnabled ?? false) && (showOnlineStatus ?? true) }
    var effectiveLastSeen: Bool { !(privacyModeEnabled ?? false) && (showLastSeen ?? true) }
    var effectiveMessagePreviews: Bool { !(privacyModeEnabled ?? false) && (messagePreviews ?? true) }
    var effectiveBackgroundHide: Bool { (privacyModeEnabled ?? false) || hideInBackground }

    init(userID: String, nickname: String, passwordHash: String) {
        self.id = UUID()
        self.userID = userID
        self.nickname = nickname
        self.passwordHash = passwordHash
        self.searchable = false
        self.faceIDEnabled = false
        self.screenshotAlerts = false
        self.recordingAlerts = false
        self.hideInBackground = true
        self.autoDestroyHours = 0
        self.disappearingMessages = false
        self.avatar = nil; self.bio = nil
        self.readReceipts = true; self.messagePreviews = true
        self.showOnlineStatus = true; self.showLastSeen = true
        self.privacyModeEnabled = false; self.privacyModeLockChats = false
        self.identityPublicKey = nil; self.identityFingerprint = nil
        self.encryptedPreferences = nil
    }
}

@Model
final class Device {
    @Attribute(.unique) var id: UUID
    var ownerID: UUID?
    var name: String
    var deviceName: String?
    var systemVersion: String?
    var lastActiveAt: Date?
    var publicKey: Data?
    var createdAt: Date?
    init(name: String, ownerID: UUID? = nil) {
        self.id = UUID(); self.ownerID = ownerID; self.name = name
        self.deviceName = name
        self.systemVersion = nil; self.lastActiveAt = nil
        self.publicKey = nil; self.createdAt = .now
    }
}

@Model
final class Friend {
    @Attribute(.unique) var id: UUID
    var ownerID: UUID
    var userID: String
    var nickname: String
    var remark: String?
    var avatar: Data?
    var privacyRestricted: Bool?
    var encryptedRemark: Data?
    var identityFingerprint: String?
    var sessionStatus: String?
    /// A server-advertised replacement remains untrusted until explicitly verified.
    var pendingIdentityFingerprint: String?
    /// Server UUID is routing metadata; local Friend.id remains stable.
    var remoteUserID: UUID?
    var displayName: String { let value = remark?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; return value.isEmpty ? nickname : value }
    init(ownerID: UUID, userID: String, nickname: String) {
        self.id = UUID(); self.ownerID = ownerID; self.userID = userID; self.nickname = nickname
        self.remark = nil; self.avatar = nil; self.privacyRestricted = false; self.encryptedRemark = nil
        self.identityFingerprint = nil; self.sessionStatus = "none"; self.pendingIdentityFingerprint = nil
        self.remoteUserID = nil
    }
}

@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var ownerID: UUID
    var friendID: UUID
    /// Encrypted draft bytes; never persist draft text in SwiftData.
    var draft: Data?
    var requiresUnlock: Bool?
    var requiresPrivacyShield: Bool?
    var isPinned: Bool?
    var unreadCount: Int?
    var remoteID: UUID?
    init(ownerID: UUID, friendID: UUID) {
        self.id = UUID(); self.ownerID = ownerID; self.friendID = friendID
        self.draft = nil; self.requiresUnlock = false; self.requiresPrivacyShield = false; self.isPinned = false; self.unreadCount = 0
        self.remoteID = nil
    }
}

enum MessageType: String, Codable, CaseIterable {
    case text, image, file, voice
}

enum MessageDeliveryStatus: String, Codable {
    case sending, sent, delivered, read, failed
}

@Model
final class Message {
    @Attribute(.unique) var id: UUID
    var conversationID: UUID
    var type: MessageType
    /// Legacy phase-one field. Cleared during authenticated migration; new rows are always empty.
    var content: String
    var ciphertext: Data?
    var senderID: String?
    var status: String?
    var timestamp: Date
    var deletedLocally: Bool
    var deleted: Bool {
        get { deletedLocally }
        set { deletedLocally = newValue }
    }
    var deletedForEveryone: Bool
    var isMine: Bool
    var replyToID: UUID?
    var editedAt: Date?
    var readAt: Date?
    var deliveredAt: Date?
    var deletedAt: Date?
    var deviceID: UUID?
    var lastEventID: UUID?
    var expiresAt: Date?
    var encryptionVersion: Int?
    var sessionKeyVersion: Int?
    var messageKeyIndex: Int?
    /// At-rest encryption remains v1 for messages delivered over the v3 wire protocol.
    var transportEncryptionVersion: Int?
    var remoteRevision: Int?
    var isFavorite: Bool?
    var forwardedFrom: String?

    var messageType: MessageType { type }
    var createdAt: Date { timestamp }
    var deliveryStatus: MessageDeliveryStatus {
        get { MessageDeliveryStatus(rawValue: status ?? "") ?? .sent }
        set { status = newValue.rawValue }
    }

    init(conversationID: UUID, type: MessageType, isMine: Bool, senderID: String? = nil, timestamp: Date = .now, replyToID: UUID? = nil) {
        self.id = UUID(); self.conversationID = conversationID; self.type = type
        self.content = ""; self.ciphertext = nil; self.senderID = senderID; self.status = "local"
        self.timestamp = timestamp; self.deletedLocally = false
        self.deletedForEveryone = false; self.isMine = isMine; self.replyToID = replyToID
        self.editedAt = nil; self.readAt = nil; self.deliveredAt = nil; self.deletedAt = nil
        self.deviceID = nil; self.lastEventID = nil; self.expiresAt = nil
        self.encryptionVersion = 1
        self.sessionKeyVersion = nil
        self.messageKeyIndex = nil
        self.transportEncryptionVersion = nil; self.remoteRevision = nil
        self.isFavorite = false; self.forwardedFrom = nil
    }
}

enum OnlineStatus: String, Codable { case unknown, online, offline }

@Model
final class UserPresence {
    @Attribute(.unique) var id: UUID
    var friendID: UUID
    var onlineStatus: OnlineStatus
    var lastSeenAt: Date?
    init(friendID: UUID) {
        self.id = UUID(); self.friendID = friendID
        self.onlineStatus = .unknown; self.lastSeenAt = nil
    }
}

enum TypingStatus { case idle, typing }

@Model
final class Attachment {
    @Attribute(.unique) var id: UUID
    var messageID: UUID
    var type: MessageType
    var path: String
    var encryptedPath: String?
    var encryptionMetadata: Data?
    var encryptedMetadata: Data?
    init(messageID: UUID, type: MessageType, path: String) {
        self.id = UUID(); self.messageID = messageID; self.type = type; self.path = path
        self.encryptedPath = nil; self.encryptionMetadata = nil; self.encryptedMetadata = nil
    }
}

@Model
final class Reaction {
    @Attribute(.unique) var id: UUID
    var messageID: UUID
    var emoji: String
    var reactorID: String
    init(messageID: UUID, emoji: String, reactorID: String) {
        self.id = UUID(); self.messageID = messageID; self.emoji = emoji; self.reactorID = reactorID
    }
}

@Model
final class SearchIndexEntry {
    @Attribute(.unique) var id: UUID
    var ownerID: UUID
    var sourceID: UUID
    var kind: String
    var encryptedText: Data
    init(ownerID: UUID, sourceID: UUID, kind: String, encryptedText: Data) {
        self.id = UUID(); self.ownerID = ownerID; self.sourceID = sourceID
        self.kind = kind; self.encryptedText = encryptedText
    }
}

@Model
final class SessionKey {
    @Attribute(.unique) var id: UUID
    var ownerID: UUID?
    var friendID: UUID
    var keyVersion: Int
    var createdAt: Date
    var updatedAt: Date?
    init(friendID: UUID, keyVersion: Int, ownerID: UUID) {
        self.id = UUID(); self.ownerID = ownerID; self.friendID = friendID
        self.keyVersion = keyVersion; self.createdAt = .now; self.updatedAt = .now
    }
}

@Model
final class PreKeyMetadata {
    @Attribute(.unique) var id: UUID
    var ownerID: UUID
    var type: String
    var createdAt: Date
    var usedAt: Date?
    var publicKeyFingerprint: String
    var publicKey: Data
    var signature: Data?

    init(ownerID: UUID, type: String, publicKey: Data, fingerprint: String, signature: Data? = nil) {
        self.id = UUID(); self.ownerID = ownerID; self.type = type; self.createdAt = .now
        self.usedAt = nil; self.publicKeyFingerprint = fingerprint
        self.publicKey = publicKey; self.signature = signature
    }
}

@Model
final class ChainState {
    @Attribute(.unique) var id: UUID
    var sessionID: UUID
    var senderID: String
    var chainVersion: Int
    var messageIndex: Int

    init(sessionID: UUID, senderID: String, chainVersion: Int) {
        self.id = UUID(); self.sessionID = sessionID; self.senderID = senderID
        self.chainVersion = chainVersion; self.messageIndex = 0
    }
}

@Model
final class RemoteSyncCheckpoint {
    @Attribute(.unique) var id: UUID
    var ownerID: UUID
    var backendDeviceID: UUID
    var cursor: Int64

    init(ownerID: UUID, backendDeviceID: UUID) {
        id = UUID(); self.ownerID = ownerID; self.backendDeviceID = backendDeviceID; cursor = 0
    }
}

@Model
final class RemoteDeviceTrust {
    @Attribute(.unique) var id: UUID
    var ownerID: UUID
    var peerUserID: UUID
    var backendDeviceID: UUID
    var keyVersion: Int
    var devicePublicKey: Data
    var signedPreKey: Data

    init(ownerID: UUID, peerUserID: UUID, bundle: VerifiedDeviceBundle) {
        id = UUID(); self.ownerID = ownerID; self.peerUserID = peerUserID
        backendDeviceID = bundle.deviceID; keyVersion = bundle.keyVersion
        devicePublicKey = bundle.devicePublicKey; signedPreKey = bundle.signedPreKey
    }
}

@Model
final class OutgoingMessageQueueItem {
    @Attribute(.unique) var id: UUID
    var ownerID: UUID
    var backendDeviceID: UUID
    var messageID: UUID
    /// AES-GCM protected request body, bound to id and messageID.
    var encryptedRequest: Data
    var prepared: Bool
    var state: String
    var attempts: Int
    var nextAttemptAt: Date
    var createdAt: Date

    init(ownerID: UUID, backendDeviceID: UUID, messageID: UUID, encryptedRequest: Data) {
        self.id = UUID(); self.ownerID = ownerID; self.backendDeviceID = backendDeviceID
        self.messageID = messageID; self.encryptedRequest = encryptedRequest
        self.prepared = false
        self.state = "pending"; self.attempts = 0; self.nextAttemptAt = .now; self.createdAt = .now
    }
}

@Model
final class CleanupState {
    @Attribute(.unique) var id: UUID
    var ownerID: UUID
    var userID: String
    var operation: String
    var state: String
    /// Optional encrypted list of obsolete session/attachment IDs for restore compensation.
    var encryptedPayload: Data?
    var dataCommitted: Bool

    init(ownerID: UUID, userID: String, operation: String) {
        self.id = UUID(); self.ownerID = ownerID; self.userID = userID
        self.operation = operation; self.state = "started"; self.encryptedPayload = nil
        self.dataCommitted = false
    }
}
