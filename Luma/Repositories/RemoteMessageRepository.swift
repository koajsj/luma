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

    func sendText(_ text: String, to friend: Friend, in conversation: Conversation) async throws {
        guard try security.currentUserID() == user.userID, friend.ownerID == user.id,
              conversation.ownerID == user.id, conversation.friendID == friend.id else { throw MessageStoreError.locked }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 16_384 else { throw DeviceSessionError.invalidEnvelope }
        guard friend.identityFingerprint?.isEmpty == false else { throw DeviceSessionError.untrustedIdentity }
        let message = Message(conversationID: conversation.id, type: .text, isMine: true, senderID: user.userID)
        message.deliveryStatus = .sending
        message.transportEncryptionVersion = 3
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

    private func prepareOutgoing(_ item: OutgoingMessageQueueItem, text: Data) async throws -> Data {
        guard let value = String(data: text, encoding: .utf8),
              let message = try context.fetch(FetchDescriptor<Message>()).first(where: { $0.id == item.messageID }),
              let conversation = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
                  $0.id == message.conversationID && $0.ownerID == user.id
              }),
              let friend = try context.fetch(FetchDescriptor<Friend>()).first(where: {
                  $0.id == conversation.friendID && $0.ownerID == user.id
              }),
              let pinned = friend.identityFingerprint, !pinned.isEmpty else { throw DeviceSessionError.untrustedIdentity }
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
        let peerBundles = try await bundles(for: contact.id, fingerprint: pinned)
        let ownFingerprint = try requiredOwnFingerprint()
        let ownBundles = try await bundles(for: registration.backendUserID, fingerprint: ownFingerprint)
        let recipients = (peerBundles + ownBundles).filter { $0.deviceID != registration.backendDeviceID }
        guard !recipients.isEmpty, recipients.count <= 32,
              Set(recipients.map(\.deviceID)).count == recipients.count else { throw DeviceSessionError.invalidEnvelope }
        let identityBytes = try keychain.readRequired("identity-private.\(user.userID)")
        let identity = try P256.Signing.PrivateKey(rawRepresentation: identityBytes)
        guard identity.publicKey.x963Representation == user.identityPublicKey else { throw AsymmetricKeyError.publicKeyMismatch }
        let payload = try JSONEncoder().encode(V3TextPayload(kind: "text", senderUserID: user.userID,
                                                               targetUserID: friend.userID, text: value))
        let envelopes = try recipients.map { bundle -> V3RecipientEnvelope in
            let envelope = try MessageEncryptor.encryptV3(payload, messageID: item.messageID,
                conversationID: remoteConversationID, senderDeviceID: registration.backendDeviceID,
                identity: identity, recipient: bundle)
            return V3RecipientEnvelope(recipientDeviceID: bundle.deviceID.uuidString.lowercased(),
                ciphertext: try JSONEncoder().encode(envelope).base64URLEncodedString(),
                keyVersion: bundle.keyVersion, messageKeyIndex: envelope.messageKeyIndex)
        }
        return try JSONEncoder().encode(V3SendRequest(messageID: item.messageID,
            conversationID: remoteConversationID, encryptionVersion: 3, recipientEnvelopes: envelopes))
    }

    func editText(_ text: String, message: Message, friend: Friend, conversation: Conversation) async throws {
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
        guard message.isMine, message.transportEncryptionVersion == 3 else { throw MessageRepositoryError.invalidEvent }
        _ = try await client.request("DELETE", path: "/messages/\(message.id.uuidString.lowercased())")
        message.deleted = true; message.deletedForEveryone = true
        message.deletedAt = .now
        message.remoteRevision = (message.remoteRevision ?? 1) + 1
        try context.save()
    }

    func react(_ emoji: String, to message: Message, friend: Friend, conversation: Conversation) async throws {
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
            $0.transportEncryptionVersion == 3
        }
        if security.preferences.readReceipts {
            for message in unread {
                _ = try await client.request("POST", path: "/messages/read",
                    body: JSONEncoder().encode(["messageID": message.id.uuidString.lowercased()]))
            }
        }
        _ = try LocalMessageRepository(context: context, encryption: security.encryptionService())
            .markConversationRead(conversation, preferences: security.preferences)
    }

    private func makeEnvelopes(messageID: UUID, conversationID: UUID, friend: Friend,
                               kind: String, text: String, revision: Int? = nil) async throws -> [V3RecipientEnvelope] {
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
        if let saved = friend.identityFingerprint, saved != fingerprint { throw DeviceSessionError.untrustedIdentity }
        return fingerprint
    }

    func trustIdentity(_ fingerprint: String, for friend: Friend) throws {
        guard friend.ownerID == user.id,
              friend.identityFingerprint == nil || friend.identityFingerprint == fingerprint else {
            throw DeviceSessionError.untrustedIdentity
        }
        friend.identityFingerprint = fingerprint
        try context.save()
    }

    @discardableResult
    func sync(limit: Int = 100) async throws -> Int {
        do { return try await RemoteSyncCoordinator(repository: self).sync(limit: limit) }
        catch RemoteError.deviceRevoked { try clearRevokedAccess(); throw RemoteError.deviceRevoked }
    }

    func retryOutgoing() async throws {
        do {
            try await outgoingQueue().drain { item, plaintext in
                try await prepareOutgoing(item, text: plaintext)
            }
        } catch RemoteError.deviceRevoked {
            try clearRevokedAccess(); throw RemoteError.deviceRevoked
        }
    }

    func retryFailed(_ messageID: UUID) async throws {
        try outgoingQueue().retryFailed(messageID: messageID)
        try await retryOutgoing()
    }

    private func clearRevokedAccess() throws {
        for trust in try context.fetch(FetchDescriptor<RemoteDeviceTrust>()).filter({ $0.ownerID == user.id }) {
            context.delete(trust)
        }
        for item in try context.fetch(FetchDescriptor<OutgoingMessageQueueItem>()).filter({ $0.ownerID == user.id }) {
            item.state = "failed"; item.attempts = 5
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
                if let oneTime = envelope.recipientOneTimePreKey {
                    let manager = PreKeyManager(context: context, keychain: keychain)
                    if let record = try manager.records(for: user.id).first(where: {
                        $0.type == "oneTime" && $0.publicKey == oneTime
                    }) { try manager.consumeOneTime(record) }
                }
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
                    $0.senderID == body.senderUserID
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
            if let oneTimeRecord { try prekeys.consumeOneTime(oneTimeRecord) }
        case "message.delivered", "message.read":
            guard let message = try context.fetch(FetchDescriptor<Message>()).first(where: { $0.id == messageID && $0.isMine }) else {
                // A message may have expired locally before its receipt arrives.
                return
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
            if let revision = event.routing.revision, revision > (message.remoteRevision ?? 1) {
                message.deleted = true; message.deletedForEveryone = true
                message.deletedAt = time; message.remoteRevision = revision
                try context.save()
            }
        default: throw DeviceSessionError.unsupportedVersion
        }
    }

    private func localConversation(remoteID: UUID, friend: Friend) throws -> Conversation {
        if let existing = try context.fetch(FetchDescriptor<Conversation>()).first(where: {
            $0.ownerID == user.id && $0.remoteID == remoteID
        }) { return existing }
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
        let verified = try raw.map { try $0.verified(expectedFingerprint: fingerprint) }
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

    private func requiredOwnFingerprint() throws -> String {
        guard let identity = user.identityPublicKey,
              let fingerprint = user.identityFingerprint,
              IdentityFingerprint.make(publicKey: identity) == fingerprint else {
            throw AsymmetricKeyError.publicKeyMismatch
        }
        return fingerprint
    }
}
