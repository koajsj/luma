import Foundation

/// A local event envelope. Payloads may contain ciphertext, never message plaintext.
/// Future network code must authenticate the sender and use a shared session key before applying events.
struct MessageEvent: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case newMessage, messageSent, messageDelivered, messageRead, messageDeleted, reactionAdded, messageEdited
    }

    let id: UUID
    let messageID: UUID
    let timestamp: Date
    let kind: Kind
    let payload: Data?
    let actorID: String?
    let deviceID: UUID?

    var eventID: UUID { id }

    init(kind: Kind, messageID: UUID, timestamp: Date = .now, payload: Data? = nil,
         actorID: String? = nil, deviceID: UUID? = nil, eventID: UUID = UUID()) {
        self.id = eventID; self.messageID = messageID; self.timestamp = timestamp
        self.kind = kind; self.payload = payload; self.actorID = actorID; self.deviceID = deviceID
    }
}

struct ReadReceiptEvent: Codable, Equatable {
    let messageID: UUID
    let readerID: String
    let timestamp: Date
}

/// Only ciphertext and routing metadata are carried in the mock envelope.
struct NewMessagePayload: Codable {
    let conversationID: UUID
    let senderID: String
    let type: MessageType
    let ciphertext: Data
    let encryptionVersion: Int
    let sessionKeyVersion: Int?
    let messageKeyIndex: Int?
    let replyToID: UUID?
}

struct EditedMessagePayload: Codable {
    let ciphertext: Data
    let sessionKeyVersion: Int
    let messageKeyIndex: Int
}

struct ReactionEventPayload: Codable {
    let emoji: String
    let reactorID: String
}
