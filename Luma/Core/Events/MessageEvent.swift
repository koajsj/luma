import Foundation
import SwiftData

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

/// Local mock event gate. A remote provider must additionally authenticate the
/// device and event origin before using the repository's apply method.
@MainActor
struct EventVerifier {
    let context: ModelContext

    func verify(_ event: MessageEvent, message: Message?) throws {
        if event.kind == .newMessage {
            guard let payload = event.payload,
                  let body = try? JSONDecoder().decode(NewMessagePayload.self, from: payload),
                  (1...2).contains(body.encryptionVersion),
                  body.senderID == event.actorID,
                  let conversation = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
                      $0.id == body.conversationID
                  }),
                  let owner = try context.fetch(FetchDescriptor<User>()).first(where: { $0.id == conversation.ownerID }),
                  let friend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                      $0.id == conversation.friendID && $0.ownerID == owner.id
                  }),
                  [owner.userID, friend.userID].contains(body.senderID) else {
                throw MessageRepositoryError.invalidEvent
            }
            return
        }
        guard let message,
              let conversation = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
                  $0.id == message.conversationID
              }),
              let owner = try context.fetch(FetchDescriptor<User>()).first(where: { $0.id == conversation.ownerID }),
              let friend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                  $0.id == conversation.friendID && $0.ownerID == owner.id
              }),
              message.senderID == (message.isMine ? owner.userID : friend.userID) else {
            throw MessageRepositoryError.invalidEvent
        }
        switch event.kind {
        case .messageEdited:
            guard event.actorID == message.senderID, !message.deleted else { throw MessageRepositoryError.invalidEvent }
        case .messageDeleted:
            guard let flag = event.payload?.first, event.payload?.count == 1, flag <= 1,
                  event.actorID == (flag == 1 ? message.senderID : owner.userID) else {
                throw MessageRepositoryError.invalidEvent
            }
        case .messageRead:
            guard message.isMine, event.actorID == friend.userID,
                  let bytes = event.payload,
                  let receipt = try? JSONDecoder().decode(ReadReceiptEvent.self, from: bytes),
                  receipt.messageID == message.id, receipt.readerID == event.actorID,
                  receipt.timestamp == event.timestamp else { throw MessageRepositoryError.invalidEvent }
        default: break
        }
        if let deviceID = event.deviceID, let known = try context.fetch(FetchDescriptor<Device>()).first(where: {
            $0.id == deviceID
        }) {
            let actor = event.actorID
            let knownOwner = try context.fetch(FetchDescriptor<User>()).first(where: {
                $0.id == known.ownerID
            })?.userID
            guard actor == nil || knownOwner == actor else { throw MessageRepositoryError.invalidEvent }
        }
    }
}
