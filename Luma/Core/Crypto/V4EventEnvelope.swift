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
              body.revision == routing.revision else { throw V4ProtocolError.invalidMessage }
    }
}
