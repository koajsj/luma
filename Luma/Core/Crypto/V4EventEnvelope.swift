import CryptoKit
import Foundation

/// This entire value is encrypted inside a fresh v4 ratchet message. The server only
/// sees the event ID, routing device IDs and opaque per-device ciphertext.
struct V4EventEnvelope: Codable {
    enum Kind: String, Codable {
        case edit = "message.edited"
        case delete = "message.deleted"
        case read = "message.read"
        case reaction = "reaction.added"
    }

    let eventID: UUID
    let messageID: UUID
    let conversationID: UUID
    let actorUserID: UUID
    let actorDeviceID: UUID
    let kind: Kind
    let revision: Int?
    let text: String?
    let reactionAction: String?
    let occurredAt: Date
    /// Authenticated inside the ratchet payload; absent only in legacy reaction events.
    var reactionOrder: V4ReactionOrder? = nil
}

/// Checks untrusted routing before decrypt and authenticated content afterwards.
/// A future device signature check belongs here; backend authorization alone is insufficient.
struct V4EventVerifier {
    func verifyRouting(_ event: RemoteSyncEvent, envelope: V4RatchetMessage,
                       localDeviceID: UUID) throws -> V4EventEnvelope.Kind {
        guard let kind = V4EventEnvelope.Kind(rawValue: event.type),
              let mutationID = event.routing.mutationEventID,
              event.routing.messageID != nil,
              event.routing.senderUserID != nil,
              event.routing.senderDeviceID == envelope.senderDeviceID,
              event.routing.recipientDeviceID == nil || event.routing.recipientDeviceID == localDeviceID,
              event.routing.conversationID == envelope.conversationID,
              event.routing.encryptionVersion == 4,
              event.routing.messageKeyIndex == Int64(envelope.messageIndex),
              envelope.encryptionVersion == 4,
              envelope.messageID == mutationID,
              envelope.receiverDeviceID == localDeviceID else { throw V4ProtocolError.invalidMessage }
        return kind
    }

    func verifyAuthenticated(_ body: V4EventEnvelope, routing: RemoteEventRouting,
                             kind: V4EventEnvelope.Kind, envelope: V4RatchetMessage) throws {
        guard body.eventID == routing.mutationEventID,
              body.messageID == routing.messageID,
              body.conversationID == envelope.conversationID,
              body.actorUserID == routing.senderUserID,
              body.actorDeviceID == envelope.senderDeviceID,
              body.kind == kind,
              body.revision == routing.revision,
              body.kind == .reaction || body.reactionOrder == nil else { throw V4ProtocolError.invalidMessage }
    }
}

/// A Lamport register scoped to (conversation, message, actor user). Concurrent
/// device operations use UUID bytes as a stable tie-break, never server/time/DH indices.
struct V4ReactionOrder: Codable, Equatable {
    let version: Int
    let counter: UInt64

    init(version: Int = 1, counter: UInt64) { self.version = version; self.counter = counter }

    func validate() throws {
        guard version == 1, counter > 0, counter < UInt64.max else {
            throw V4ProtocolError.invalidMessage
        }
    }
}

/// Master-Key encrypted on Message. Receipts retain digests, not old emoji content;
/// removal keeps the winning stamp even when the visible Reaction row is deleted.
struct V4ReactionLedger: Codable {
    struct Stamp: Codable, Equatable {
        let counter: UInt64
        let deviceID: UUID
        let eventID: UUID

        func precedes(_ other: Stamp) -> Bool {
            if counter != other.counter { return counter < other.counter }
            if deviceID != other.deviceID { return Self.bytes(deviceID).lexicographicallyPrecedes(Self.bytes(other.deviceID)) }
            return Self.bytes(eventID).lexicographicallyPrecedes(Self.bytes(other.eventID))
        }

        private static func bytes(_ id: UUID) -> [UInt8] {
            withUnsafeBytes(of: id.uuid) { Array($0) }
        }
    }

    var version = 1
    var winners: [UUID: Stamp] = [:]
    var receipts: [UUID: Data] = [:]

    /// Returns true only when this authenticated operation replaces the register.
    /// Stale valid operations still get a receipt and must commit their ratchet.
    mutating func accept(_ event: V4EventEnvelope) throws -> Bool {
        guard version == 1, event.kind == .reaction, let order = event.reactionOrder else {
            throw V4ProtocolError.invalidMessage
        }
        try order.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = Data(SHA256.hash(data: try encoder.encode(event)))
        if let prior = receipts[event.eventID] {
            guard prior == digest else { throw V4ProtocolError.invalidMessage }
            return false
        }
        let stamp = Stamp(counter: order.counter, deviceID: event.actorDeviceID, eventID: event.eventID)
        receipts[event.eventID] = digest
        if let prior = winners[event.actorUserID], !prior.precedes(stamp) { return false }
        winners[event.actorUserID] = stamp
        return true
    }
}
