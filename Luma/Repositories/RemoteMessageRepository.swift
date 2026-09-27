import CryptoKit
import Foundation
import SwiftData

private struct V3TextPayload: Codable {
    let kind: String
    let senderUserID: String
    let targetUserID: String
    let text: String
    let revision: Int?

    init(kind: String, senderUserID: String, targetUserID: String, text: String, revision: Int? = nil) {
        self.kind = kind
        self.senderUserID = senderUserID
        self.targetUserID = targetUserID
        self.text = text
        self.revision = revision
    }
}

@MainActor
private enum V4EventDrain {
    static var inFlight = Set<UUID>()
}

@MainActor
private extension RemoteMessageRepository {
    func eventBinding(_ item: V4PendingEvent) -> Data {
        Data("luma-v4-event-outbox|\(user.id.uuidString)|\(item.backendDeviceID.uuidString)|\(item.eventID.uuidString)".utf8)
    }

    func submitV4Event(_ event: V4EventEnvelope, friend: Friend,
                       sendImmediately: Bool = true) async throws {
        guard try security.currentUserID() == user.userID,
              friend.ownerID == user.id, friend.sessionStatus != "identityKeyChanged",
              friend.identityFingerprint != nil else { throw V4ProtocolError.untrustedIdentity }
        let item = V4PendingEvent(eventID: event.eventID, ownerID: user.id,
            backendDeviceID: registration.backendDeviceID, messageID: event.messageID,
            encryptedRequest: Data())
        item.encryptedRequest = try security.encryptionService().encrypt(
            JSONEncoder().encode(event), authenticatedData: eventBinding(item)).bytes
        item.encryptedPayload = item.encryptedRequest
        context.insert(item)
        try context.save()
        if sendImmediately { try await retryV4Events() }
    }

    func retryV4Events() async throws {
        guard !V4EventDrain.inFlight.contains(registration.backendDeviceID) else { return }
        V4EventDrain.inFlight.insert(registration.backendDeviceID)
        defer { V4EventDrain.inFlight.remove(registration.backendDeviceID) }
        while true {
            let items = try context.fetch(FetchDescriptor<V4PendingEvent>()).filter {
                $0.ownerID == user.id && $0.backendDeviceID == registration.backendDeviceID
            }.sorted { $0.createdAt < $1.createdAt }
            guard let item = items.first else { return }
            // A later revision cannot overtake an earlier offline event.
            guard item.nextAttemptAt <= .now else { return }
            do {
                guard try security.currentUserID() == user.userID else { throw MessageStoreError.locked }
                let original = try localEvent(from: item)
                if original.kind == .read && !security.preferences.readReceipts {
                    try v4Vault.cancelOutgoing(userID: user.userID,
                        deviceID: registration.backendDeviceID, messageID: item.eventID)
                    context.delete(item)
                    try context.save()
                    continue
                }
                guard let queuedMessage = try context.fetch(FetchDescriptor<Message>()).first(where: {
                    $0.id == item.messageID && $0.transportEncryptionVersion == 4
                }), let queuedConversation = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
                    $0.id == queuedMessage.conversationID && $0.ownerID == user.id
                }), let queuedFriend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                    $0.id == queuedConversation.friendID && $0.ownerID == user.id
                }), let pinned = queuedFriend.identityFingerprint,
                    queuedFriend.sessionStatus != "identityKeyChanged",
                    pinned == (try await identityFingerprint(for: queuedFriend)) else {
                    throw V4ProtocolError.untrustedIdentity
                }
                let encrypted = EncryptedData(bytes: item.encryptedRequest)
                var bytes = try security.encryptionService().decrypt(encrypted,
                    authenticatedData: eventBinding(item))
                var event: V4EventEnvelope? = original
                if !item.prepared {
                    let decoded = original
                    guard decoded.eventID == item.eventID, decoded.messageID == item.messageID,
                          decoded.actorDeviceID == registration.backendDeviceID,
                          decoded.actorUserID == registration.backendUserID else { throw V4ProtocolError.invalidMessage }
                    event = decoded
                    let targets: [V4SendTarget]
                    if let pending = try v4Vault.outgoingPending(userID: user.userID,
                        deviceID: registration.backendDeviceID), pending.messageID == decoded.eventID {
                        targets = []
                    } else {
                        guard let message = try context.fetch(FetchDescriptor<Message>()).first(where: { $0.id == decoded.messageID }),
                              let conversation = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
                                  $0.id == message.conversationID && $0.ownerID == user.id && $0.remoteID == decoded.conversationID
                              }), let friend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                                  $0.id == conversation.friendID && $0.ownerID == user.id
                              }), let pinned = friend.identityFingerprint,
                              friend.sessionStatus != "identityKeyChanged",
                              let remoteUserID = friend.remoteUserID else { throw V4ProtocolError.untrustedIdentity }
                        let current = try await identityFingerprint(for: friend)
                        guard current == pinned else { throw V4ProtocolError.untrustedIdentity }
                        try await v4Prekeys.ensurePublished()
                        let peer = try await v4Bundles(for: remoteUserID, fingerprint: pinned)
                        let own = try await v4Bundles(for: registration.backendUserID,
                            fingerprint: requiredOwnFingerprint())
                        targets = peer.map { .init(remoteUserID: remoteUserID, bundle: $0) } +
                            own.filter { $0.deviceID != registration.backendDeviceID }
                                .map { .init(remoteUserID: registration.backendUserID, bundle: $0) }
                    }
                    bytes = try v4Sessions.prepareEvent(decoded, targets: targets)
                    item.encryptedRequest = try security.encryptionService().encrypt(bytes,
                        authenticatedData: eventBinding(item)).bytes
                    item.prepared = true
                    try context.save()
                }
                try v4Sessions.commitPreparedSend(messageID: item.eventID)
                _ = try await client.request("POST", path: "/messages/v4/events", body: bytes,
                    extraHeaders: ["Idempotency-Key": item.eventID.uuidString.lowercased()])
                // Local state is applied only after an acknowledged request.
                if let event { try applyOwnV4Event(event) }
                context.delete(item)
                try context.save()
            } catch {
                if error is CancellationError { throw error }
                // A long outage must not permanently block this event and every later
                // revision. Keep a bounded delay while preserving the exact request.
                item.attempts = min(5, item.attempts + 1)
                item.nextAttemptAt = Date().addingTimeInterval(min(300, pow(2, Double(item.attempts)) * 3))
                try context.save()
                throw error
            }
        }
    }

    func localEvent(from item: V4PendingEvent) throws -> V4EventEnvelope {
        let bytes = try security.encryptionService().decrypt(
            EncryptedData(bytes: item.encryptedPayload), authenticatedData: eventBinding(item))
        return try JSONDecoder().decode(V4EventEnvelope.self, from: bytes)
    }

    func applyOwnV4Event(_ event: V4EventEnvelope) throws {
        guard let message = try context.fetch(FetchDescriptor<Message>()).first(where: { $0.id == event.messageID }),
              message.transportEncryptionVersion == 4 else { throw V4ProtocolError.invalidMessage }
        switch event.kind {
        case .edit:
            guard let text = event.text, let revision = event.revision else { throw V4ProtocolError.invalidMessage }
            try MessageStore(context: context, encryption: security.encryptionService())
                .applyVerifiedRemoteEdit(messageID: message.id, plaintext: Data(text.utf8),
                    revision: revision, at: event.occurredAt, eventID: event.eventID)
        case .delete:
            guard let revision = event.revision else { throw V4ProtocolError.invalidMessage }
            if revision == (message.remoteRevision ?? 1) + 1 {
                message.deleted = true; message.deletedForEveryone = true
                message.deletedAt = event.occurredAt; message.remoteRevision = revision
                try purgeAttachment(for: message)
            } else if revision != message.remoteRevision { throw V4ProtocolError.invalidMessage }
        case .read:
            // The local reader's state is handled by markConversationRead.
            break
        case .reaction:
            try applyV4Reaction(event)
        }
        try context.save()
    }

    func applyV4Reaction(_ event: V4EventEnvelope) throws {
        guard let emoji = event.text, ["👍", "❤️", "😂", "‼️"].contains(emoji),
              ["add", "remove"].contains(event.reactionAction ?? "") else { throw V4ProtocolError.invalidMessage }
        let reactorID = event.actorUserID == registration.backendUserID ? user.userID :
            try context.fetch(FetchDescriptor<Friend>()).first(where: {
                $0.ownerID == user.id && $0.remoteUserID == event.actorUserID
            })?.userID
        guard let reactorID else { throw V4ProtocolError.untrustedIdentity }
        let existing = try context.fetch(FetchDescriptor<Reaction>()).first(where: {
            $0.messageID == event.messageID && $0.reactorID == reactorID
        })
        if event.reactionAction == "remove" {
            if let existing { context.delete(existing) }
        } else if let existing { existing.emoji = emoji }
        else { context.insert(Reaction(messageID: event.messageID, emoji: emoji, reactorID: reactorID)) }
    }

    func applyV4Control(_ event: RemoteSyncEvent) async throws {
        guard let messageID = event.routing.messageID,
              let mutationID = event.routing.mutationEventID,
              let sourceUser = event.routing.senderUserID,
              let sourceDevice = event.routing.senderDeviceID,
              let wire = Data(base64URL: event.payloadCiphertext),
              let envelope = try? JSONDecoder().decode(V4RatchetMessage.self, from: wire),
              let message = try context.fetch(FetchDescriptor<Message>()).first(where: { $0.id == messageID }),
              message.transportEncryptionVersion == 4,
              let conversation = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
                  $0.id == message.conversationID && $0.ownerID == user.id &&
                  $0.remoteID == envelope.conversationID
              }), let friend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                  $0.id == conversation.friendID && $0.ownerID == user.id &&
                  $0.sessionStatus != "identityKeyChanged"
              }) else { throw V4ProtocolError.invalidMessage }
        let verifier = V4EventVerifier()
        let kind = try verifier.verifyRouting(event, envelope: envelope,
            localDeviceID: registration.backendDeviceID)
        let isMine = sourceUser == registration.backendUserID
        let expectedUser = isMine ? registration.backendUserID : friend.remoteUserID
        guard sourceUser == expectedUser else { throw V4ProtocolError.untrustedIdentity }
        let fingerprint = try isMine ? requiredOwnFingerprint() :
            (friend.identityFingerprint ?? { throw V4ProtocolError.untrustedIdentity }())
        let sender = try await v4Prekeys.senderBundle(for: sourceUser,
            deviceID: sourceDevice, expectedAccountFingerprint: fingerprint)
        let plaintext = try v4Sessions.decrypt(envelope, wire: wire, eventID: event.eventID,
            deviceSeq: event.deviceSeq, senderUserID: sourceUser, senderBundle: sender)
        let body = try JSONDecoder().decode(V4EventEnvelope.self, from: plaintext)
        try verifier.verifyAuthenticated(body, routing: event.routing, kind: kind, envelope: envelope)
        guard !message.deleted || kind == .delete else { throw V4ProtocolError.invalidMessage }
        if let pending = try v4Vault.incomingPending(userID: user.userID,
            deviceID: registration.backendDeviceID) {
            try ensureV4Metadata(pending.session, friendID: isMine ? nil : friend.id)
        }
        switch kind {
        case .edit:
            guard sourceUser == (message.isMine ? registration.backendUserID : friend.remoteUserID),
                  let text = body.text, !text.isEmpty, text.utf8.count <= 16_384,
                  let revision = body.revision else { throw V4ProtocolError.invalidMessage }
            try MessageStore(context: context, encryption: security.encryptionService())
                .applyVerifiedRemoteEdit(messageID: messageID, plaintext: Data(text.utf8),
                    revision: revision, at: body.occurredAt, eventID: mutationID)
        case .delete:
            guard sourceUser == (message.isMine ? registration.backendUserID : friend.remoteUserID),
                  let revision = body.revision else { throw V4ProtocolError.invalidMessage }
            if revision == (message.remoteRevision ?? 1) + 1 {
                message.deleted = true; message.deletedForEveryone = true
                message.deletedAt = body.occurredAt; message.remoteRevision = revision
                message.lastEventID = mutationID
                try purgeAttachment(for: message)
            } else if revision != message.remoteRevision { throw V4ProtocolError.replay }
        case .read:
            guard sourceUser != (message.isMine ? registration.backendUserID : friend.remoteUserID),
                  body.text == nil, let eventRevision = body.revision,
                  eventRevision >= 1,
                  eventRevision <= (message.remoteRevision ?? 1) else { throw V4ProtocolError.invalidMessage }
            if message.isMine {
                guard security.preferences.readReceipts else { break }
                message.readAt = message.readAt ?? body.occurredAt
                message.deliveredAt = message.deliveredAt ?? body.occurredAt
                message.deliveryStatus = .read
            } else {
                if message.readAt == nil {
                    conversation.unreadCount = max(0, (conversation.unreadCount ?? 0) - 1)
                }
                message.readAt = message.readAt ?? body.occurredAt
                message.deliveryStatus = .read
            }
        case .reaction:
            guard let eventRevision = body.revision,
                  eventRevision >= 1,
                  eventRevision <= (message.remoteRevision ?? 1) else { throw V4ProtocolError.invalidMessage }
            try applyV4Reaction(body)
        }
        try context.save()
    }
}

private struct V3RecipientEnvelope: Encodable {
    let recipientDeviceID: String
    let ciphertext: String
    let keyVersion: Int
    let messageKeyIndex: Int64
}

private struct V3SendRequest: Encodable {
    let messageID: UUID
    let conversationID: UUID
    let encryptionVersion: Int
    let recipientEnvelopes: [V3RecipientEnvelope]
}

private struct V3ConversationResponse: Decodable { let id: UUID }
private struct V3EditResponse: Decodable { let revision: Int }

/// Online message boundary. Transport envelopes never become SwiftData ciphertext;
/// verified plaintext is re-encrypted by MessageStore with the local Master Key.
@MainActor
struct RemoteMessageRepository {
    let context: ModelContext
    let user: User
    let security: SecurityManager
    let client: RemoteAPIClient
    let registration: RemoteRegistration
    private let keychain = KeychainManager()
    private var v4Vault: V4SessionVault { V4SessionVault(keychain: keychain) }
    private var v4Sessions: V4MessageSessionService {
        V4MessageSessionService(vault: v4Vault, userID: user.userID,
            localDeviceID: registration.backendDeviceID)
    }
    private var v4Prekeys: V4PreKeyService {
        V4PreKeyService(context: context, user: user, registration: registration,
            client: client, vault: v4Vault)
    }

    func sendText(_ text: String, to friend: Friend, in conversation: Conversation) async throws {
        guard try security.currentUserID() == user.userID, friend.ownerID == user.id,
              conversation.ownerID == user.id, conversation.friendID == friend.id else { throw MessageStoreError.locked }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 16_384 else { throw DeviceSessionError.invalidEnvelope }
        guard friend.identityFingerprint?.isEmpty == false else { throw DeviceSessionError.untrustedIdentity }
        guard friend.sessionStatus != "identityKeyChanged" else { throw DeviceSessionError.identityKeyChanged }
        let message = Message(conversationID: conversation.id, type: .text, isMine: true, senderID: user.userID)
        message.deliveryStatus = .sending
        message.transportEncryptionVersion = 4
        message.remoteRevision = 1
        message.deviceID = registration.backendDeviceID
        message.ciphertext = try security.encryptionService().encrypt(Data(value.utf8),
            authenticatedData: Data("luma-message-v1|\(message.id.uuidString)|\(conversation.id.uuidString)".utf8)).bytes
        _ = try outgoingQueue().enqueue(messageID: message.id, request: Data(value.utf8))
        context.insert(message)
        do { try context.save() } catch { context.rollback(); throw error }
        // A queued message survives network loss and retains the same message ID on retry.
        try? await retryOutgoing()
    }

    func sendAttachment(_ data: Data, name: String, type: MessageType,
                        to friend: Friend, in conversation: Conversation) async throws {
        guard try security.currentUserID() == user.userID, friend.ownerID == user.id,
              conversation.ownerID == user.id, conversation.friendID == friend.id,
              friend.identityFingerprint?.isEmpty == false,
              friend.sessionStatus != "identityKeyChanged", type != .text,
              !name.isEmpty, name.utf8.count <= 255, data.count <= 20 << 20 else {
            throw V4AttachmentError.invalidDescriptor
        }
        let message = Message(conversationID: conversation.id, type: type, isMine: true,
                              senderID: user.userID)
        message.deliveryStatus = .sending
        message.transportEncryptionVersion = 4
        message.remoteRevision = 1
        message.deviceID = registration.backendDeviceID
        let attachment = Attachment(messageID: message.id, type: type, path: "")
        let descriptor = V4AttachmentCrypto.makeDescriptor(attachmentID: attachment.id,
            messageID: message.id, conversationID: conversation.id, type: type,
            name: URL(fileURLWithPath: name).lastPathComponent)
        let metadata = AttachmentMetadata(name: descriptor.name, encryptedPath: nil,
                                          metadata: try JSONEncoder().encode(descriptor))
        attachment.encryptedMetadata = try security.encryptionService().encrypt(
            JSONEncoder().encode(metadata),
            authenticatedData: Data("luma-attachment-v1|\(attachment.id.uuidString)".utf8)).bytes
        message.ciphertext = try security.encryptionService().encrypt(Data("[\(type.rawValue)]".utf8),
            authenticatedData: Data("luma-message-v1|\(message.id.uuidString)|\(conversation.id.uuidString)".utf8)).bytes
        do {
            try FileTransferService(ownerID: user.id, encryption: security.encryptionService())
                .upload(data, attachmentID: attachment.id)
            _ = try outgoingQueue().enqueue(messageID: message.id,
                request: JSONEncoder().encode(V4AttachmentIntent(kind: "attachment", attachmentID: attachment.id)))
            context.insert(message)
            context.insert(attachment)
            try context.save()
        } catch {
            context.rollback()
            try? FileTransferService(ownerID: user.id, encryption: security.encryptionService())
                .delete(attachmentID: attachment.id)
            throw error
        }
        try? await retryOutgoing()
    }

    private func prepareOutgoing(_ item: OutgoingMessageQueueItem, text: Data) async throws -> Data {
        if let pending = try v4Vault.outgoingPending(userID: user.userID,
            deviceID: registration.backendDeviceID) {
            guard pending.messageID == item.messageID else { throw V4VaultError.pendingOperation }
            return pending.request
        }
        guard let message = try context.fetch(FetchDescriptor<Message>()).first(where: { $0.id == item.messageID }),
              let conversation = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
                  $0.id == message.conversationID && $0.ownerID == user.id
              }),
              let friend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                  $0.id == conversation.friendID && $0.ownerID == user.id
              }),
              let pinned = friend.identityFingerprint, !pinned.isEmpty else { throw DeviceSessionError.untrustedIdentity }
        guard friend.sessionStatus != "identityKeyChanged" else { throw DeviceSessionError.identityKeyChanged }
        let contacts = try await RemoteAccountRepository(client: client).confirmedFriends()
        guard let contact = contacts.first(where: { $0.userID == friend.userID }) else { throw RemoteError.server(403, "friendship_required") }
        friend.remoteUserID = contact.id
        let remoteConversationID: UUID
        if let existing = conversation.remoteID { remoteConversationID = existing }
        else {
            let body = try JSONEncoder().encode(["friendID": contact.id.uuidString.lowercased()])
            let created = try await client.json(V3ConversationResponse.self, method: "POST", path: "/conversations", body: body)
            conversation.remoteID = created.id
            try context.save()
            remoteConversationID = created.id
        }
        try await v4Prekeys.ensurePublished()
        let peerBundles = try await v4Bundles(for: contact.id, fingerprint: pinned)
        let ownBundles = try await v4Bundles(for: registration.backendUserID,
            fingerprint: requiredOwnFingerprint())
        let recipients = peerBundles.map { V4SendTarget(remoteUserID: contact.id, bundle: $0) } +
            ownBundles.filter { $0.deviceID != registration.backendDeviceID }
                .map { V4SendTarget(remoteUserID: registration.backendUserID, bundle: $0) }
        guard !recipients.isEmpty, recipients.count <= 32 else { throw DeviceSessionError.invalidEnvelope }
        var attachmentIDs: [UUID]?
        let payload: Data
        if message.type == .text {
            guard let value = String(data: text, encoding: .utf8) else { throw V4ProtocolError.invalidMessage }
            payload = try JSONEncoder().encode(V3TextPayload(kind: "text", senderUserID: user.userID,
                targetUserID: friend.userID, text: value))
        } else {
            let intent = try JSONDecoder().decode(V4AttachmentIntent.self, from: text)
            guard intent.kind == "attachment",
                  let attachment = try context.fetch(FetchDescriptor<Attachment>()).first(where: {
                      $0.id == intent.attachmentID && $0.messageID == message.id && $0.type == message.type
                  }) else { throw V4AttachmentError.invalidDescriptor }
            let privateStore = PrivateMetadataStore(context: context, encryption: try security.encryptionService())
            let metadata = try privateStore.attachmentMetadata(for: attachment)
            guard let bytes = metadata.metadata else { throw V4AttachmentError.invalidDescriptor }
            var descriptor = try JSONDecoder().decode(V4AttachmentDescriptor.self, from: bytes)
            guard descriptor.messageID == message.id,
                  [conversation.id, remoteConversationID].contains(descriptor.conversationID),
                  descriptor.attachmentID == attachment.id else { throw V4AttachmentError.invalidDescriptor }
            let localFiles = FileTransferService(ownerID: user.id,
                encryption: try security.encryptionService())
            let remoteFiles = RemoteFileTransferService(client: client)
            if descriptor.remoteObjectID == nil || metadata.encryptedPath == "v4.upload.pending" {
                descriptor = descriptor.withConversation(remoteConversationID)
                var encrypted: EncryptedData
                if metadata.encryptedPath == "v4.upload.pending" {
                    do {
                        encrypted = try localFiles.pendingUpload(attachmentID: attachment.id)
                        guard Data(SHA256.hash(data: encrypted.bytes)) == descriptor.ciphertextHash else {
                            throw V4AttachmentError.invalidDescriptor
                        }
                    } catch FileTransferError.missing {
                        // A missing local upload journal cannot safely reuse its old ticket.
                        if let stale = descriptor.remoteObjectID {
                            try? await remoteFiles.delete(attachmentID: stale)
                        }
                        descriptor = descriptor.withoutUpload()
                        let original = try localFiles.download(attachmentID: attachment.id)
                        encrypted = try V4AttachmentCrypto.encrypt(original, descriptor: descriptor)
                        try localFiles.savePendingUpload(encrypted, attachmentID: attachment.id)
                    }
                } else {
                    let original = try localFiles.download(attachmentID: attachment.id)
                    encrypted = try V4AttachmentCrypto.encrypt(original, descriptor: descriptor)
                    try localFiles.savePendingUpload(encrypted, attachmentID: attachment.id)
                }
                if descriptor.remoteObjectID == nil {
                    let remoteID = try await remoteFiles.beginUpload(encrypted)
                    descriptor = descriptor.withUpload(id: remoteID,
                        hash: Data(SHA256.hash(data: encrypted.bytes)))
                    try privateStore.saveAttachmentMetadata(.init(name: descriptor.name,
                        encryptedPath: "v4.upload.pending", metadata: try JSONEncoder().encode(descriptor)),
                        for: attachment)
                }
                guard var remoteID = descriptor.remoteObjectID else { throw V4AttachmentError.invalidDescriptor }
                do { try await remoteFiles.finishUpload(encrypted, attachmentID: remoteID) }
                catch RemoteError.server(let code, _) where code == 404 || code == 409 {
                    // The previous upload ticket expired; the server reconciles its old object.
                    try? await remoteFiles.delete(attachmentID: remoteID)
                    remoteID = try await remoteFiles.beginUpload(encrypted)
                    descriptor = descriptor.withUpload(id: remoteID,
                        hash: Data(SHA256.hash(data: encrypted.bytes)))
                    try privateStore.saveAttachmentMetadata(.init(name: descriptor.name,
                        encryptedPath: "v4.upload.pending", metadata: try JSONEncoder().encode(descriptor)),
                        for: attachment)
                    try await remoteFiles.finishUpload(encrypted, attachmentID: remoteID)
                }
                try privateStore.saveAttachmentMetadata(.init(name: descriptor.name,
                    encryptedPath: nil, metadata: try JSONEncoder().encode(descriptor)), for: attachment)
                try? localFiles.clearPendingUpload(attachmentID: attachment.id)
            }
            guard let remoteID = descriptor.remoteObjectID else { throw V4AttachmentError.invalidDescriptor }
            attachmentIDs = [remoteID]
            payload = try JSONEncoder().encode(V4AttachmentPayload(kind: "attachment",
                senderUserID: user.userID, targetUserID: friend.userID, attachment: descriptor))
        }
        return try v4Sessions.prepare(payload, messageID: item.messageID,
            conversationID: remoteConversationID, targets: recipients, attachmentIDs: attachmentIDs)
    }

    func downloadAttachment(for message: Message) async throws -> (Data, String, MessageType) {
        guard try security.currentUserID() == user.userID,
              message.transportEncryptionVersion == 4, !message.deleted,
              let conversation = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
                  $0.id == message.conversationID && $0.ownerID == user.id
              }), let attachment = try context.fetch(FetchDescriptor<Attachment>()).first(where: {
                  $0.messageID == message.id && $0.type == message.type
              }) else { throw V4AttachmentError.invalidDescriptor }
        let metadata = try PrivateMetadataStore(context: context,
            encryption: security.encryptionService()).attachmentMetadata(for: attachment)
        guard let bytes = metadata.metadata else { throw V4AttachmentError.invalidDescriptor }
        let descriptor = try JSONDecoder().decode(V4AttachmentDescriptor.self, from: bytes)
        guard descriptor.attachmentID == attachment.id,
              descriptor.messageID == message.id,
              descriptor.type == message.type,
              [conversation.id, conversation.remoteID].compactMap({ $0 }).contains(descriptor.conversationID) else {
            throw V4AttachmentError.invalidDescriptor
        }
        let local = FileTransferService(ownerID: user.id, encryption: try security.encryptionService())
        // A cached sender copy must not bypass descriptor validation.
        if descriptor.remoteObjectID != nil {
            try V4AttachmentCrypto.validate(descriptor, messageID: message.id,
                conversationID: descriptor.conversationID)
        }
        if message.isMine, let cached = try? local.download(attachmentID: attachment.id) {
            return (cached, descriptor.name, descriptor.type)
        }
        try V4AttachmentCrypto.validate(descriptor, messageID: message.id,
            conversationID: conversation.remoteID ?? conversation.id)
        if let cached = try? local.download(attachmentID: attachment.id) {
            return (cached, descriptor.name, descriptor.type)
        }
        guard let remoteID = descriptor.remoteObjectID,
              let expectedHash = descriptor.ciphertextHash else { throw V4AttachmentError.invalidDescriptor }
        let encrypted = try await RemoteFileTransferService(client: client)
            .download(attachmentID: remoteID, expectedHash: expectedHash)
        let data = try V4AttachmentCrypto.decrypt(encrypted, descriptor: descriptor)
        try local.upload(data, attachmentID: attachment.id)
        return (data, descriptor.name, descriptor.type)
    }

    private func purgeAttachment(for message: Message) throws {
        for attachment in try context.fetch(FetchDescriptor<Attachment>()).filter({ $0.messageID == message.id }) {
            try FileTransferService(ownerID: user.id, encryption: security.encryptionService())
                .delete(attachmentID: attachment.id)
            context.delete(attachment)
        }
    }

    private func v4Bundles(for remoteID: UUID, fingerprint: String) async throws -> [V4PreKeyBundle] {
        let publicBundles = try await v4Prekeys.bundles(for: remoteID,
            expectedAccountFingerprint: fingerprint, claim: false)
        let missing = try publicBundles.contains { bundle in
            try v4Vault.loadSession(userID: user.userID,
                local: registration.backendDeviceID, remote: bundle.deviceID) == nil
        }
        if missing {
            return try await v4Prekeys.bundles(for: remoteID,
                expectedAccountFingerprint: fingerprint, claim: true)
        }
        return publicBundles
    }

    func editText(_ text: String, message: Message, friend: Friend, conversation: Conversation) async throws {
        if message.transportEncryptionVersion == 4 {
            guard message.isMine, message.conversationID == conversation.id,
                  !message.deleted, conversation.remoteID != nil else { throw MessageStoreError.editNotAllowed }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 16_384 else { throw MessageStoreError.editNotAllowed }
            try await submitV4Event(.init(eventID: UUID(), messageID: message.id,
                conversationID: conversation.remoteID!, actorUserID: registration.backendUserID,
                actorDeviceID: registration.backendDeviceID, kind: .edit,
                revision: (message.remoteRevision ?? 1) + 1, text: value,
                reactionAction: nil, occurredAt: .now), friend: friend)
            return
        }
        guard message.isMine, message.transportEncryptionVersion == 3,
              message.conversationID == conversation.id,
              let remoteID = conversation.remoteID else { throw MessageStoreError.editNotAllowed }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 16_384 else { throw MessageStoreError.editNotAllowed }
        let currentRevision = message.remoteRevision ?? 1
        let envelopes = try await makeEnvelopes(messageID: message.id, conversationID: remoteID,
                                                 friend: friend, kind: "text", text: value,
                                                 revision: currentRevision + 1)
        struct EditRequest: Encodable {
            let messageID: UUID
            let revision: Int
            let recipientEnvelopes: [V3RecipientEnvelope]
        }
        let response = try await client.json(V3EditResponse.self, method: "POST", path: "/messages/edit",
            body: JSONEncoder().encode(EditRequest(messageID: message.id,
                revision: currentRevision, recipientEnvelopes: envelopes)))
        guard response.revision == currentRevision + 1 else { throw DeviceSessionError.invalidEnvelope }
        try MessageStore(context: context, encryption: security.encryptionService())
            .applyVerifiedRemoteEdit(messageID: message.id, plaintext: Data(value.utf8),
                                     revision: response.revision, at: .now, eventID: UUID())
    }

    func deleteForEveryone(_ message: Message) async throws {
        guard message.isMine, [3, 4].contains(message.transportEncryptionVersion ?? 0) else {
            throw MessageRepositoryError.invalidEvent
        }
        if message.transportEncryptionVersion == 4 {
            guard let conversation = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
                $0.id == message.conversationID && $0.ownerID == user.id
            }), let friend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                $0.id == conversation.friendID && $0.ownerID == user.id
            }), let remote = conversation.remoteID, !message.deleted else { throw MessageRepositoryError.invalidEvent }
            try await submitV4Event(.init(eventID: UUID(), messageID: message.id,
                conversationID: remote, actorUserID: registration.backendUserID,
                actorDeviceID: registration.backendDeviceID, kind: .delete,
                revision: (message.remoteRevision ?? 1) + 1, text: nil,
                reactionAction: nil, occurredAt: .now), friend: friend)
            return
        }
        _ = try await client.request("DELETE", path: "/messages/\(message.id.uuidString.lowercased())")
        message.deleted = true; message.deletedForEveryone = true
        message.deletedAt = .now
        message.remoteRevision = (message.remoteRevision ?? 1) + 1
        try context.save()
    }

    func react(_ emoji: String, to message: Message, friend: Friend, conversation: Conversation) async throws {
        if message.transportEncryptionVersion == 4 {
            guard message.conversationID == conversation.id, let remote = conversation.remoteID,
                  !message.deleted, ["👍", "❤️", "😂", "‼️"].contains(emoji) else { throw MessageRepositoryError.invalidEvent }
            let existing = try context.fetch(FetchDescriptor<Reaction>()).first(where: {
                $0.messageID == message.id && $0.reactorID == user.userID
            })
            let remove = existing?.emoji == emoji
            try await submitV4Event(.init(eventID: UUID(), messageID: message.id,
                conversationID: remote, actorUserID: registration.backendUserID,
                actorDeviceID: registration.backendDeviceID, kind: .reaction,
                revision: message.remoteRevision ?? 1, text: emoji,
                reactionAction: remove ? "remove" : "add", occurredAt: .now), friend: friend)
            return
        }
        guard message.transportEncryptionVersion == 3, message.conversationID == conversation.id,
              let remoteID = conversation.remoteID,
              ["👍", "❤️", "😂", "‼️"].contains(emoji) else { throw MessageRepositoryError.invalidEvent }
        let envelopes = try await makeEnvelopes(messageID: message.id, conversationID: remoteID,
                                                 friend: friend, kind: "reaction", text: emoji)
        struct ReactionRequest: Encodable {
            let messageID: UUID
            let recipientEnvelopes: [V3RecipientEnvelope]
        }
        _ = try await client.request("POST", path: "/messages/reaction",
            body: JSONEncoder().encode(ReactionRequest(messageID: message.id, recipientEnvelopes: envelopes)))
        _ = try LocalMessageRepository(context: context, encryption: security.encryptionService())
            .react(emoji, to: message, reactorID: user.userID)
    }

    func markRead(_ conversation: Conversation) async throws {
        let unread = try context.fetch(FetchDescriptor<Message>()).filter {
            $0.conversationID == conversation.id && !$0.isMine && !$0.deleted && $0.readAt == nil &&
            [3, 4].contains($0.transportEncryptionVersion ?? 0)
        }
        if security.preferences.readReceipts {
            for message in unread {
                if message.transportEncryptionVersion == 4 {
                    guard let remote = conversation.remoteID,
                          let friend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                              $0.id == conversation.friendID && $0.ownerID == user.id
                          }) else { throw V4ProtocolError.invalidMessage }
                    try await submitV4Event(.init(eventID: UUID(), messageID: message.id,
                        conversationID: remote, actorUserID: registration.backendUserID,
                        actorDeviceID: registration.backendDeviceID, kind: .read,
                        revision: message.remoteRevision ?? 1, text: nil,
                        reactionAction: nil, occurredAt: .now), friend: friend,
                        sendImmediately: false)
                    continue
                }
                _ = try await client.request("POST", path: "/messages/read",
                    body: JSONEncoder().encode(["messageID": message.id.uuidString.lowercased()]))
            }
        }
        _ = try LocalMessageRepository(context: context, encryption: security.encryptionService())
            .markConversationRead(conversation, preferences: security.preferences)
        if security.preferences.readReceipts { try await retryV4Events() }
    }

    private func makeEnvelopes(messageID: UUID, conversationID: UUID, friend: Friend,
                               kind: String, text: String, revision: Int? = nil) async throws -> [V3RecipientEnvelope] {
        guard friend.sessionStatus != "identityKeyChanged" else { throw DeviceSessionError.identityKeyChanged }
        guard let pinned = friend.identityFingerprint,
              let contact = try await RemoteAccountRepository(client: client).confirmedFriends()
                .first(where: { $0.userID == friend.userID }) else { throw DeviceSessionError.untrustedIdentity }
        let peer = try await bundles(for: contact.id, fingerprint: pinned)
        let own = try await bundles(for: registration.backendUserID, fingerprint: requiredOwnFingerprint())
        let targets = (peer + own).filter { $0.deviceID != registration.backendDeviceID }
        guard !targets.isEmpty, targets.count <= 32,
              Set(targets.map(\.deviceID)).count == targets.count else { throw DeviceSessionError.invalidEnvelope }
        let identity = try P256.Signing.PrivateKey(rawRepresentation:
            keychain.readRequired("identity-private.\(user.userID)"))
        guard identity.publicKey.x963Representation == user.identityPublicKey else { throw AsymmetricKeyError.publicKeyMismatch }
        let payload = try JSONEncoder().encode(V3TextPayload(kind: kind, senderUserID: user.userID,
                                                               targetUserID: friend.userID, text: text,
                                                               revision: revision))
        return try targets.map { target in
            let envelope = try MessageEncryptor.encryptV3(payload, messageID: messageID,
                conversationID: conversationID, senderDeviceID: registration.backendDeviceID,
                identity: identity, recipient: target)
            return V3RecipientEnvelope(recipientDeviceID: target.deviceID.uuidString.lowercased(),
                ciphertext: try JSONEncoder().encode(envelope).base64URLEncodedString(),
                keyVersion: target.keyVersion, messageKeyIndex: envelope.messageKeyIndex)
        }
    }

    /// Identity pinning is an explicit user action. A server-supplied first key is not silently trusted.
    func identityFingerprint(for friend: Friend) async throws -> String {
        guard let contact = try await RemoteAccountRepository(client: client).confirmedFriends()
            .first(where: { $0.userID == friend.userID }) else { throw RemoteError.server(403, "friendship_required") }
        friend.remoteUserID = contact.id
        try context.save()
        let raw: [RemoteDevicePreKeyBundle] = try await client.json([RemoteDevicePreKeyBundle].self,
            path: "/users/\(contact.id.uuidString.lowercased())/prekey-bundle?claim=false")
        guard let first = raw.first, let identity = Data(base64URL: first.identityPublicKey) else {
            throw DeviceSessionError.invalidEnvelope
        }
        let fingerprint = IdentityFingerprint.make(publicKey: identity)
        for item in raw { _ = try item.verified(expectedFingerprint: fingerprint) }
        if let saved = friend.identityFingerprint, saved != fingerprint {
            try markIdentityChanged(friend, candidate: fingerprint)
        } else if friend.identityFingerprint == nil {
            friend.pendingIdentityFingerprint = fingerprint
            try context.save()
        }
        return fingerprint
    }

    func identityVerification(for friend: Friend) async throws -> (String, String) {
        let fingerprint = try await identityFingerprint(for: friend)
        guard let remoteID = friend.remoteUserID,
              let own = user.identityPublicKey else { throw V4ProtocolError.untrustedIdentity }
        let raw: [RemoteDevicePreKeyBundle] = try await client.json([RemoteDevicePreKeyBundle].self,
            path: "/users/\(remoteID.uuidString.lowercased())/prekey-bundle?claim=false")
        guard let first = raw.first, let peer = Data(base64URL: first.identityPublicKey),
              IdentityFingerprint.make(publicKey: peer) == fingerprint else {
            throw V4ProtocolError.untrustedIdentity
        }
        return (fingerprint, IdentitySafetyCode.make(own, peer))
    }

    func trustIdentity(_ fingerprint: String, for friend: Friend) throws {
        guard friend.ownerID == user.id else { throw DeviceSessionError.untrustedIdentity }
        guard friend.pendingIdentityFingerprint == fingerprint ||
              friend.identityFingerprint == fingerprint else { throw DeviceSessionError.untrustedIdentity }
        if friend.sessionStatus == "identityKeyChanged" {
            guard friend.pendingIdentityFingerprint == fingerprint else { throw DeviceSessionError.identityKeyChanged }
        } else if friend.identityFingerprint != nil && friend.identityFingerprint != fingerprint {
            throw DeviceSessionError.untrustedIdentity
        }
        let changed = friend.identityFingerprint != nil && friend.identityFingerprint != fingerprint
        let wasBlocked = friend.sessionStatus == "identityKeyChanged"
        friend.identityFingerprint = fingerprint
        friend.pendingIdentityFingerprint = nil
        if changed || wasBlocked {
            friend.sessionStatus = changed ? "identityReverified" : "none"
            let conversations = try context.fetch(FetchDescriptor<Conversation>()).filter {
                $0.ownerID == user.id && $0.friendID == friend.id
            }
            let ids = Set(conversations.map(\.id))
            let messageIDs = Set(try context.fetch(FetchDescriptor<Message>()).filter({
                ids.contains($0.conversationID)
            }).map(\.id))
            for item in try context.fetch(FetchDescriptor<OutgoingMessageQueueItem>()).filter({
                $0.ownerID == user.id && messageIDs.contains($0.messageID) && $0.state == "identityChanged"
            }) { context.delete(item) }
        }
        try context.save()
    }

    @discardableResult
    func sync(limit: Int = 100) async throws -> Int {
        do { return try await RemoteSyncCoordinator(repository: self).sync(limit: limit) }
        catch RemoteError.deviceRevoked { try clearRevokedAccess(); throw RemoteError.deviceRevoked }
    }

    func retryOutgoing() async throws {
        do {
            try await outgoingQueue().drain(validate: { item in
                guard let message = try context.fetch(FetchDescriptor<Message>()).first(where: { $0.id == item.messageID }),
                      let conversation = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
                          $0.id == message.conversationID && $0.ownerID == user.id
                      }),
                      let friend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                          $0.id == conversation.friendID && $0.ownerID == user.id
                      }), let saved = friend.identityFingerprint else { throw DeviceSessionError.untrustedIdentity }
                let current = try await identityFingerprint(for: friend)
                guard saved == current, friend.sessionStatus != "identityKeyChanged" else {
                    throw DeviceSessionError.identityKeyChanged
                }
            }, prepare: { item, plaintext in
                try await prepareOutgoing(item, text: plaintext)
            }, afterPrepared: { item, body in
                if let pending = try v4Vault.outgoingPending(userID: user.userID,
                    deviceID: registration.backendDeviceID), pending.messageID == item.messageID {
                    guard pending.request == body else { throw V4VaultError.damaged }
                    for session in pending.sessions {
                        let friendID = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                            $0.ownerID == user.id && $0.remoteUserID == session.remoteUserID
                        })?.id
                        try ensureV4Metadata(session, friendID: friendID)
                    }
                    try context.save()
                }
                try v4Sessions.commitPreparedSend(messageID: item.messageID)
            })
            try await retryV4Events()
        } catch RemoteError.deviceRevoked {
            try clearRevokedAccess(); throw RemoteError.deviceRevoked
        }
    }

    func retryFailed(_ messageID: UUID) async throws {
        try outgoingQueue().retryFailed(messageID: messageID)
        try await retryOutgoing()
    }

    private func clearRevokedAccess() throws {
        try v4Vault.purgeAccount(userID: user.userID)
        for session in try context.fetch(FetchDescriptor<V4SessionMetadata>()).filter({ $0.ownerID == user.id }) {
            context.delete(session)
        }
        for device in try context.fetch(FetchDescriptor<V4DeviceMetadata>()).filter({ $0.ownerID == user.id }) {
            context.delete(device)
        }
        for trust in try context.fetch(FetchDescriptor<RemoteDeviceTrust>()).filter({ $0.ownerID == user.id }) {
            context.delete(trust)
        }
        for item in try context.fetch(FetchDescriptor<OutgoingMessageQueueItem>()).filter({ $0.ownerID == user.id }) {
            if let message = try context.fetch(FetchDescriptor<Message>()).first(where: { $0.id == item.messageID }) {
                message.deliveryStatus = .failed
                for attachment in try context.fetch(FetchDescriptor<Attachment>()).filter({ $0.messageID == message.id }) {
                    try FileTransferService(ownerID: user.id, encryption: try security.encryptionService())
                        .clearPendingUpload(attachmentID: attachment.id)
                }
            }
            context.delete(item)
        }
        for item in try context.fetch(FetchDescriptor<V4PendingEvent>()).filter({ $0.ownerID == user.id }) {
            context.delete(item)
        }
        try context.save()
        try RemoteSessionStore().clearAll(for: user.userID)
    }

    private func outgoingQueue() throws -> OutgoingMessageQueue {
        OutgoingMessageQueue(context: context, ownerID: user.id,
            backendDeviceID: registration.backendDeviceID, encryption: try security.encryptionService(), client: client)
    }

    func apply(_ event: RemoteSyncEvent) throws {
        guard let messageID = event.routing.messageID else { throw DeviceSessionError.invalidEnvelope }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let time = parser.date(from: event.createdAt) ?? ISO8601DateFormatter().date(from: event.createdAt)
        guard let time else { throw DeviceSessionError.invalidEnvelope }
        switch event.type {
        case "message.created", "message.edited", "reaction.added":
            guard let wire = Data(base64URL: event.payloadCiphertext),
                  let envelope = try? JSONDecoder().decode(DeviceMessageEnvelope.self, from: wire),
                  envelope.messageID == messageID,
                  envelope.receiverDeviceID == registration.backendDeviceID,
                  envelope.encryptionVersion == 3,
                  event.routing.encryptionVersion == nil || event.routing.encryptionVersion == 3,
                  event.routing.senderDeviceID == nil || event.routing.senderDeviceID == envelope.senderDeviceID,
                  event.routing.conversationID == nil || event.routing.conversationID == envelope.conversationID,
                  event.routing.keyVersion == nil || event.routing.keyVersion == envelope.keyVersion,
                  event.routing.messageKeyIndex == nil || event.routing.messageKeyIndex == envelope.messageKeyIndex else {
                throw DeviceSessionError.invalidEnvelope
            }
            if event.type == "message.created",
               let existing = try context.fetch(FetchDescriptor<Message>()).first(where: { $0.id == messageID }) {
                guard existing.transportEncryptionVersion == 3,
                      existing.lastEventID == event.eventID else { throw DeviceSessionError.invalidEnvelope }
                return
            }
            let senderFingerprint = IdentityFingerprint.make(publicKey: envelope.senderIdentityPublicKey)
            let isMine = senderFingerprint == (try requiredOwnFingerprint())
            let friend: Friend?
            if isMine { friend = nil }
            else {
                let matches = try context.fetch(FetchDescriptor<Friend>()).filter {
                    $0.ownerID == user.id && $0.identityFingerprint == senderFingerprint
                }
                guard matches.count == 1 else { throw DeviceSessionError.untrustedIdentity }
                guard matches[0].sessionStatus != "identityKeyChanged" else { throw DeviceSessionError.identityKeyChanged }
                friend = matches[0]
            }
            guard let localDevice = try context.fetch(FetchDescriptor<Device>()).first(where: { $0.ownerID == user.id }) else {
                throw AsymmetricKeyError.missing
            }
            let device = try P256.KeyAgreement.PrivateKey(rawRepresentation:
                keychain.readRequired("device-private.\(localDevice.id.uuidString)"))
            let prekeys = PreKeyManager(context: context, keychain: keychain)
            guard let signedRecord = try prekeys.records(for: user.id).first(where: {
                $0.type == "signed" && $0.publicKey == envelope.recipientSignedPreKey
            }) else { throw DeviceSessionError.missingPreKey }
            let oneTimeRecord: PreKeyMetadata?
            if let oneTime = envelope.recipientOneTimePreKey {
                oneTimeRecord = try prekeys.records(for: user.id).first(where: {
                    $0.type == "oneTime" && $0.publicKey == oneTime && $0.usedAt == nil
                })
                guard oneTimeRecord != nil else { throw DeviceSessionError.missingPreKey }
            } else { oneTimeRecord = nil }
            let plaintext = try MessageEncryptor.decryptV3(envelope,
                expectedDeviceID: registration.backendDeviceID, expectedFingerprint: senderFingerprint,
                device: device, signedPreKey: try prekeys.privateKey(for: signedRecord),
                oneTimePreKey: try oneTimeRecord.map { try prekeys.privateKey(for: $0) })
            let signedTime = Date(timeIntervalSince1970: TimeInterval(envelope.createdAtMilliseconds) / 1_000)
            let body = try JSONDecoder().decode(V3TextPayload.self, from: plaintext)
            guard body.kind == (event.type == "reaction.added" ? "reaction" : "text"),
                  body.senderUserID == (isMine ? user.userID : friend?.userID),
                  !body.targetUserID.isEmpty, body.text.utf8.count <= 16_384 else {
                throw DeviceSessionError.invalidEnvelope
            }
            if !isMine, body.targetUserID != user.userID { throw DeviceSessionError.invalidEnvelope }
            let localFriend: Friend
            if isMine {
                guard let match = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                    $0.ownerID == user.id && $0.userID == body.targetUserID
                }) else { throw DeviceSessionError.untrustedIdentity }
                localFriend = match
            } else {
                guard let friend else { throw DeviceSessionError.untrustedIdentity }
                localFriend = friend
            }
            let remoteConversationID = envelope.conversationID
            let conversation = try localConversation(remoteID: remoteConversationID, friend: localFriend)
            let store = MessageStore(context: context, encryption: try security.encryptionService())
            if event.type == "message.created" {
                try store.receiveVerifiedRemote(messageID: messageID, plaintext: Data(body.text.utf8),
                    from: body.senderUserID, in: conversation, at: signedTime,
                    senderDeviceID: envelope.senderDeviceID, eventID: event.eventID, isMine: isMine)
            } else if event.type == "message.edited" {
                guard let revision = event.routing.revision, body.revision == revision else {
                    throw DeviceSessionError.invalidEnvelope
                }
                guard try context.fetch(FetchDescriptor<Message>()).contains(where: {
                    $0.id == messageID && $0.conversationID == conversation.id &&
                    $0.senderID == body.senderUserID && $0.transportEncryptionVersion == 3 && !$0.deleted
                }) else { throw DeviceSessionError.invalidEnvelope }
                try store.applyVerifiedRemoteEdit(messageID: messageID, plaintext: Data(body.text.utf8),
                    revision: revision, at: time, eventID: event.eventID)
            } else {
                guard ["👍", "❤️", "😂", "‼️"].contains(body.text) else { throw DeviceSessionError.invalidEnvelope }
                guard try context.fetch(FetchDescriptor<Message>()).contains(where: {
                    $0.id == messageID && $0.conversationID == conversation.id
                }) else { throw DeviceSessionError.invalidEnvelope }
                let existing = try context.fetch(FetchDescriptor<Reaction>()).first(where: {
                    $0.messageID == messageID && $0.reactorID == body.senderUserID
                })
                if let existing { existing.emoji = body.text }
                else { context.insert(Reaction(messageID: messageID, emoji: body.text, reactorID: body.senderUserID)) }
                try context.save()
            }
        case "message.delivered", "message.read":
            guard let receiptDevice = event.routing.recipientDeviceID,
                  receiptDevice != registration.backendDeviceID else { throw DeviceSessionError.invalidEnvelope }
            guard let message = try context.fetch(FetchDescriptor<Message>()).first(where: { $0.id == messageID && $0.isMine }) else {
                // A message may have expired locally before its receipt arrives.
                return
            }
            guard [3, 4].contains(message.transportEncryptionVersion ?? 0),
                  let conversation = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
                      $0.id == message.conversationID && $0.ownerID == user.id && $0.remoteID != nil
                  }),
                  let friend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                      $0.id == conversation.friendID && $0.ownerID == user.id
                  }), friend.sessionStatus != "identityKeyChanged",
                  let peerID = friend.remoteUserID else { throw DeviceSessionError.invalidEnvelope }
            if message.transportEncryptionVersion == 4 {
                guard event.routing.senderUserID == peerID,
                      event.routing.senderDeviceID == receiptDevice,
                      try context.fetch(FetchDescriptor<V4SessionMetadata>()).contains(where: {
                          $0.ownerID == user.id && $0.friendID == friend.id &&
                          $0.remoteDeviceID == receiptDevice && $0.status == "active"
                      }) else { throw DeviceSessionError.invalidEnvelope }
            } else {
                guard try context.fetch(FetchDescriptor<RemoteDeviceTrust>()).contains(where: {
                    $0.ownerID == user.id && $0.peerUserID == peerID && $0.backendDeviceID == receiptDevice
                }) else { throw DeviceSessionError.invalidEnvelope }
            }
            if event.type == "message.delivered", message.deliveryStatus == .sent {
                message.deliveryStatus = .delivered; message.deliveredAt = time
            } else if event.type == "message.read", security.preferences.readReceipts,
                      message.deliveryStatus != .read {
                message.deliveryStatus = .read
                message.deliveredAt = message.deliveredAt ?? time
                message.readAt = time
            }
            try context.save()
        case "message.deleted":
            guard let message = try context.fetch(FetchDescriptor<Message>()).first(where: { $0.id == messageID }) else {
                return
            }
            guard [3, 4].contains(message.transportEncryptionVersion ?? 0),
                  let conversation = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
                      $0.id == message.conversationID && $0.ownerID == user.id && $0.remoteID != nil
                  }),
                  let friend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                      $0.id == conversation.friendID && $0.ownerID == user.id
                  }), friend.sessionStatus != "identityKeyChanged",
                  let revision = event.routing.revision else { throw DeviceSessionError.invalidEnvelope }
            if message.transportEncryptionVersion == 4 {
                let expectedSender = message.isMine ? registration.backendUserID : friend.remoteUserID
                guard event.routing.senderUserID == expectedSender,
                      let sourceDevice = event.routing.senderDeviceID,
                      try context.fetch(FetchDescriptor<V4SessionMetadata>()).contains(where: {
                          $0.ownerID == user.id && $0.friendID == (message.isMine ? nil : friend.id) &&
                          $0.remoteDeviceID == sourceDevice && $0.status == "active"
                      }) else { throw DeviceSessionError.invalidEnvelope }
            }
            if revision == (message.remoteRevision ?? 1) + 1 {
                message.deleted = true; message.deletedForEveryone = true
                message.deletedAt = time; message.remoteRevision = revision
                try context.save()
            } else if revision > (message.remoteRevision ?? 1) {
                throw DeviceSessionError.invalidEnvelope
            }
        default: throw DeviceSessionError.unsupportedVersion
        }
    }

    /// v4 events are authenticated against the pinned account identity and the
    /// authenticated device bundle before any plaintext reaches MessageStore.
    func applyV4(_ event: RemoteSyncEvent) async throws {
        if event.type != "message.created" {
            try await applyV4Control(event)
            return
        }
        guard ["message.created", "message.edited", "reaction.added"].contains(event.type),
              let messageID = event.routing.messageID,
              let senderUserID = event.routing.senderUserID,
              let senderDeviceID = event.routing.senderDeviceID,
              let wire = Data(base64URL: event.payloadCiphertext),
              let envelope = try? JSONDecoder().decode(V4RatchetMessage.self, from: wire),
              envelope.messageID == messageID,
              envelope.senderDeviceID == senderDeviceID,
              envelope.receiverDeviceID == registration.backendDeviceID,
              event.routing.conversationID == nil || event.routing.conversationID == envelope.conversationID,
              event.routing.encryptionVersion == nil || event.routing.encryptionVersion == 4,
              event.routing.messageKeyIndex.map({ $0 == envelope.messageIndex }) ?? true else {
            throw V4ProtocolError.invalidMessage
        }
        if event.type == "message.created",
           let existing = try context.fetch(FetchDescriptor<Message>()).first(where: { $0.id == messageID }) {
            guard existing.transportEncryptionVersion == 4,
                  existing.lastEventID == event.eventID,
                  try v4Vault.incomingPending(userID: user.userID,
                      deviceID: registration.backendDeviceID)?.eventID == event.eventID else {
                throw V4ProtocolError.replay
            }
            return
        }
        let isMine = senderUserID == registration.backendUserID
        let senderFriend: Friend?
        let fingerprint: String
        if isMine {
            senderFriend = nil
            fingerprint = try requiredOwnFingerprint()
        } else {
            guard let friend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                $0.ownerID == user.id && $0.remoteUserID == senderUserID
            }), let pinned = friend.identityFingerprint,
                  friend.sessionStatus != "identityKeyChanged" else { throw V4ProtocolError.untrustedIdentity }
            senderFriend = friend
            fingerprint = pinned
        }
        let senderBundle = try await v4Prekeys.senderBundle(for: senderUserID,
            deviceID: senderDeviceID, expectedAccountFingerprint: fingerprint)
        let plaintext = try v4Sessions.decrypt(envelope, wire: wire, eventID: event.eventID,
            deviceSeq: event.deviceSeq, senderUserID: senderUserID, senderBundle: senderBundle)
        struct PayloadKind: Decodable { let kind: String }
        let kind = try JSONDecoder().decode(PayloadKind.self, from: plaintext).kind
        let body: V3TextPayload?
        let attachmentBody: V4AttachmentPayload?
        if kind == "attachment" {
            attachmentBody = try JSONDecoder().decode(V4AttachmentPayload.self, from: plaintext)
            body = nil
        } else {
            body = try JSONDecoder().decode(V3TextPayload.self, from: plaintext)
            attachmentBody = nil
        }
        let payloadSender = body?.senderUserID ?? attachmentBody?.senderUserID
        let payloadTarget = body?.targetUserID ?? attachmentBody?.targetUserID
        guard ["text", "attachment"].contains(kind),
              payloadSender == (isMine ? user.userID : senderFriend?.userID),
              body.map({ $0.text.utf8.count <= 16_384 }) ?? true,
              isMine || payloadTarget == user.userID else { throw V4ProtocolError.invalidMessage }
        let friend: Friend
        if let senderFriend { friend = senderFriend }
        else {
            guard let ownTarget = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                $0.ownerID == user.id && $0.userID == payloadTarget
            }) else { throw V4ProtocolError.untrustedIdentity }
            friend = ownTarget
        }
        if let pending = try v4Vault.incomingPending(userID: user.userID,
            deviceID: registration.backendDeviceID) {
            try ensureV4Metadata(pending.session, friendID: friend.id)
        }
        let conversation = try localConversation(remoteID: envelope.conversationID, friend: friend)
        let store = MessageStore(context: context, encryption: try security.encryptionService())
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let time = parser.date(from: event.createdAt) ?? ISO8601DateFormatter().date(from: event.createdAt) else {
            throw V4ProtocolError.invalidMessage
        }
        if event.type == "message.created" {
            if let descriptor = attachmentBody?.attachment {
                try V4AttachmentCrypto.validate(descriptor, messageID: messageID,
                    conversationID: envelope.conversationID)
            }
            let display = body.map { Data($0.text.utf8) } ??
                Data("[\(attachmentBody?.attachment.type.rawValue ?? "file")]".utf8)
            try store.receiveVerifiedRemote(messageID: messageID, plaintext: display,
                from: payloadSender ?? "", in: conversation, at: time,
                senderDeviceID: senderDeviceID, eventID: event.eventID,
                isMine: isMine, transportVersion: 4,
                attachmentDescriptor: attachmentBody?.attachment)
        } else if event.type == "message.edited" {
            guard let body else { throw V4ProtocolError.invalidMessage }
            guard let revision = event.routing.revision, body.revision == revision,
                  try context.fetch(FetchDescriptor<Message>()).contains(where: {
                      $0.id == messageID && $0.conversationID == conversation.id &&
                      $0.senderID == body.senderUserID && $0.transportEncryptionVersion == 4 && !$0.deleted
                  }) else { throw V4ProtocolError.invalidMessage }
            try store.applyVerifiedRemoteEdit(messageID: messageID, plaintext: Data(body.text.utf8),
                revision: revision, at: time, eventID: event.eventID)
        } else {
            guard let body else { throw V4ProtocolError.invalidMessage }
            guard ["👍", "❤️", "😂", "‼️"].contains(body.text),
                  try context.fetch(FetchDescriptor<Message>()).contains(where: {
                      $0.id == messageID && $0.conversationID == conversation.id
                  }) else { throw V4ProtocolError.invalidMessage }
            let existing = try context.fetch(FetchDescriptor<Reaction>()).first(where: {
                $0.messageID == messageID && $0.reactorID == body.senderUserID
            })
            if let existing { existing.emoji = body.text }
            else { context.insert(Reaction(messageID: messageID, emoji: body.text, reactorID: body.senderUserID)) }
            try context.save()
        }
    }

    private func ensureV4Metadata(_ session: V4SessionVault.Session, friendID: UUID?) throws {
        if let existing = try context.fetch(FetchDescriptor<V4SessionMetadata>()).first(where: {
            $0.ownerID == user.id && $0.localDeviceID == session.localDeviceID &&
            $0.remoteDeviceID == session.remoteDeviceID
        }) {
            guard existing.friendID == friendID else { throw V4ProtocolError.untrustedIdentity }
            existing.updatedAt = .now
            return
        }
        context.insert(V4SessionMetadata(ownerID: user.id, friendID: friendID,
            localDeviceID: session.localDeviceID, remoteDeviceID: session.remoteDeviceID,
            sessionVersion: session.sessionVersion))
    }

    /// Called only after the corresponding event and local cursor have been saved.
    func finalizeOneTimePreKey(for event: RemoteSyncEvent) throws {
        guard ["message.created", "message.edited", "reaction.added"].contains(event.type),
              let wire = Data(base64URL: event.payloadCiphertext),
              let envelope = try? JSONDecoder().decode(DeviceMessageEnvelope.self, from: wire),
              let oneTime = envelope.recipientOneTimePreKey else { return }
        let manager = PreKeyManager(context: context, keychain: keychain)
        guard let record = try manager.records(for: user.id).first(where: {
            $0.type == "oneTime" && $0.publicKey == oneTime
        }) else { return }
        try manager.consumeOneTime(record)
    }

    private func localConversation(remoteID: UUID, friend: Friend) throws -> Conversation {
        if let existing = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
            $0.ownerID == user.id && $0.remoteID == remoteID
        }) {
            guard existing.friendID == friend.id else { throw DeviceSessionError.invalidEnvelope }
            return existing
        }
        if let existing = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
            $0.ownerID == user.id && $0.friendID == friend.id
        }) {
            guard existing.remoteID == nil else { throw DeviceSessionError.invalidEnvelope }
            existing.remoteID = remoteID
            try context.save()
            return existing
        }
        let conversation = Conversation(ownerID: user.id, friendID: friend.id)
        conversation.remoteID = remoteID
        context.insert(conversation)
        try context.save()
        return conversation
    }

    private func bundles(for id: UUID, fingerprint: String) async throws -> [VerifiedDeviceBundle] {
        let raw: [RemoteDevicePreKeyBundle] = try await client.json([RemoteDevicePreKeyBundle].self,
            path: "/users/\(id.uuidString.lowercased())/prekey-bundle")
        guard !raw.isEmpty else { throw DeviceSessionError.missingPreKey }
        guard let first = raw.first, let identity = Data(base64URL: first.identityPublicKey) else {
            throw DeviceSessionError.invalidEnvelope
        }
        let candidate = IdentityFingerprint.make(publicKey: identity)
        let verified = try raw.map { try $0.verified(expectedFingerprint: candidate) }
        if candidate != fingerprint {
            if let friend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                $0.ownerID == user.id && $0.remoteUserID == id
            }) { try markIdentityChanged(friend, candidate: candidate) }
            throw DeviceSessionError.identityKeyChanged
        }
        guard verified.allSatisfy({ $0.deviceID == registration.backendDeviceID || $0.oneTimePreKey != nil }) else {
            throw DeviceSessionError.missingPreKey
        }
        for bundle in verified {
            if let trusted = try context.fetch(FetchDescriptor<RemoteDeviceTrust>()).first(where: {
                $0.ownerID == user.id && $0.peerUserID == id && $0.backendDeviceID == bundle.deviceID
            }) {
                guard trusted.devicePublicKey == bundle.devicePublicKey,
                      bundle.keyVersion >= trusted.keyVersion,
                      bundle.keyVersion != trusted.keyVersion || trusted.signedPreKey == bundle.signedPreKey else {
                    throw DeviceSessionError.untrustedIdentity
                }
                if bundle.keyVersion > trusted.keyVersion {
                    trusted.keyVersion = bundle.keyVersion
                    trusted.signedPreKey = bundle.signedPreKey
                }
            } else {
                context.insert(RemoteDeviceTrust(ownerID: user.id, peerUserID: id, bundle: bundle))
            }
        }
        try context.save()
        return verified
    }

    func markIdentityChanged(_ friend: Friend, candidate: String) throws {
        friend.pendingIdentityFingerprint = candidate
        friend.sessionStatus = "identityKeyChanged"
        if let remoteID = friend.remoteUserID {
            try v4Vault.discardPendingForRemoteUser(userID: user.userID,
                localDeviceID: registration.backendDeviceID, remoteUserID: remoteID)
            for session in try context.fetch(FetchDescriptor<V4SessionMetadata>()).filter({
                $0.ownerID == user.id && $0.friendID == friend.id
            }) {
                try v4Vault.deletePeer(userID: user.userID,
                    localDeviceID: session.localDeviceID, remoteDeviceID: session.remoteDeviceID)
                context.delete(session)
            }
            for trust in try context.fetch(FetchDescriptor<RemoteDeviceTrust>()).filter({
                $0.ownerID == user.id && $0.peerUserID == remoteID
            }) { context.delete(trust) }
        }
        let conversations = try context.fetch(FetchDescriptor<Conversation>()).filter {
            $0.ownerID == user.id && $0.friendID == friend.id
        }
        let ids = Set(conversations.map(\.id))
        let messages = try context.fetch(FetchDescriptor<Message>()).filter { ids.contains($0.conversationID) }
        let messageIDs = Set(messages.map(\.id))
        for item in try context.fetch(FetchDescriptor<OutgoingMessageQueueItem>()).filter({
            $0.ownerID == user.id && messageIDs.contains($0.messageID)
        }) { item.state = "identityChanged"; item.attempts = 5 }
        for item in try context.fetch(FetchDescriptor<V4PendingEvent>()).filter({
            $0.ownerID == user.id && messageIDs.contains($0.messageID)
        }) { context.delete(item) }
        for message in messages where message.deliveryStatus == .sending { message.deliveryStatus = .failed }
        try context.save()
    }

    private func requiredOwnFingerprint() throws -> String {
        guard let identity = user.identityPublicKey,
              let fingerprint = user.identityFingerprint,
              IdentityFingerprint.make(publicKey: identity) == fingerprint else {
            throw AsymmetricKeyError.publicKeyMismatch
        }
        return fingerprint
    }
}
