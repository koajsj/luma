import SwiftData
import CryptoKit
import XCTest
@testable import Luma

@MainActor
final class LocalFoundationTests: XCTestCase {
    func testV4AttachmentSealingAndIdentitySafetyCode() throws {
        let message = UUID(), conversation = UUID()
        for type in [MessageType.image, .file, .voice] {
            let descriptor = V4AttachmentCrypto.makeDescriptor(attachmentID: UUID(),
                messageID: message, conversationID: conversation, type: type, name: "private.bin")
            let content = Data("private attachment \(type.rawValue)".utf8)
            let sealed = try V4AttachmentCrypto.encrypt(content, descriptor: descriptor)
            XCTAssertNil(sealed.bytes.range(of: content))
            let uploaded = descriptor.withUpload(id: UUID(), hash: Data(SHA256.hash(data: sealed.bytes)))
            try V4AttachmentCrypto.validate(uploaded, messageID: message, conversationID: conversation)
            XCTAssertEqual(try V4AttachmentCrypto.decrypt(sealed, descriptor: uploaded), content)
            var damaged = sealed.bytes
            damaged[damaged.index(before: damaged.endIndex)] ^= 1
            XCTAssertThrowsError(try V4AttachmentCrypto.decrypt(.init(bytes: damaged), descriptor: uploaded))
            let wrong = V4AttachmentCrypto.makeDescriptor(attachmentID: descriptor.attachmentID,
                messageID: message, conversationID: conversation, type: type, name: "private.bin")
                .withUpload(id: uploaded.remoteObjectID!, hash: uploaded.ciphertextHash!)
            XCTAssertThrowsError(try V4AttachmentCrypto.decrypt(sealed, descriptor: wrong))
        }
        let alice = P256.Signing.PrivateKey().publicKey.x963Representation
        let bob = P256.Signing.PrivateKey().publicKey.x963Representation
        let mallory = P256.Signing.PrivateKey().publicKey.x963Representation
        let code = IdentitySafetyCode.make(alice, bob)
        XCTAssertEqual(code, IdentitySafetyCode.make(bob, alice))
        XCTAssertNotEqual(code, IdentitySafetyCode.make(alice, mallory))
        XCTAssertTrue(IdentitySafetyCode.matches(IdentitySafetyCode.grouped(code), code: code))
        XCTAssertFalse(IdentitySafetyCode.matches(IdentitySafetyCode.make(alice, mallory), code: code))
    }
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: User.self, Device.self, Friend.self, Conversation.self, Message.self, Attachment.self, UserPresence.self, Reaction.self, SearchIndexEntry.self, SessionKey.self, PreKeyMetadata.self, ChainState.self, RemoteSyncCheckpoint.self, RemoteDeviceTrust.self, OutgoingMessageQueueItem.self, CleanupState.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    func testPrivacyShieldEventAndBackgroundPolicy() throws {
        let manager = PrivacyShieldManager()
        manager.screenshotObserved(enabled: false)
        XCTAssertNil(manager.latestEvent)
        let conversationID = UUID()
        manager.setVisibleConversation(conversationID, protected: true)
        manager.screenshotObserved(enabled: true)
        XCTAssertEqual(manager.latestEvent?.kind, .screenshotDetected)
        XCTAssertEqual(manager.latestEvent?.conversationID, conversationID)
        manager.setScenePhase(.inactive)
        XCTAssertTrue(manager.shouldMask(captureProtection: false, backgroundEnabled: false))
        manager.setVisibleConversation(nil, protected: false)
        XCTAssertFalse(manager.shouldMask(captureProtection: false, backgroundEnabled: false))
    }

    func testPrivacyPreferencesDecodePreviousVersion() throws {
        let old = Data("{\"searchable\":false,\"faceIDEnabled\":false,\"screenshotAlerts\":false,\"recordingAlerts\":false,\"hideInBackground\":true,\"autoDestroyHours\":0,\"disappearingMessages\":false,\"readReceipts\":true,\"messagePreviews\":true,\"showOnlineStatus\":true,\"showLastSeen\":true,\"privacyModeEnabled\":false,\"privacyModeLockChats\":false}".utf8)
        let decoded = try JSONDecoder().decode(PrivacyPreferences.self, from: old)
        XCTAssertTrue(decoded.effectiveScreenCaptureProtection)
    }

    func testLegacyMessageIsEncryptedAndTamperingFails() throws {
        let context = try makeContext()
        let owner = try LocalRepository(context: context).createUser(userID: "alice", nickname: "Alice", passwordHash: "verifier")
        let conversation = Conversation(ownerID: owner.id, friendID: UUID())
        let oldMessage = Message(conversationID: conversation.id, type: .text, isMine: true)
        oldMessage.content = "旧版明文"
        context.insert(conversation)
        context.insert(oldMessage)
        try context.save()

        let service = "app.luma.test.\(UUID().uuidString)"
        let keychain = KeychainManager(service: service)
        defer { try? KeyManager(keychain: keychain).delete(for: owner.userID) }
        let store = MessageStore(context: context, encryption: EncryptionService(key: try KeyManager(keychain: keychain).create(for: owner.userID)))
        try store.migrateLegacyMessages(owner: owner)
        XCTAssertEqual(oldMessage.content, "")
        XCTAssertEqual(try store.displayContent(for: oldMessage), "旧版明文")
        var damaged = try XCTUnwrap(oldMessage.ciphertext)
        damaged[damaged.index(before: damaged.endIndex)] ^= 1
        oldMessage.ciphertext = damaged
        XCTAssertThrowsError(try store.displayContent(for: oldMessage))
    }

    func testLocalAccountAndChatUserFlow() throws {
        let context = try makeContext()
        let security = SecurityManager(keychain: KeychainManager(service: "app.luma.flow.\(UUID().uuidString)"))
        try security.register(userID: "alice", nickname: "Alice", password: "password123", context: context)
        try security.setPIN("123456", context: context)
        let user = try XCTUnwrap(try LocalRepository(context: context).user("alice"))
        security.lock()
        XCTAssertThrowsError(try security.verifyPIN("000000", context: context))
        try security.verifyPIN("123456", context: context)
        try security.logout()
        try security.login(userID: "alice", password: "password123", context: context)

        let friend = try LocalRepository(context: context).addFriend(owner: user, userID: "bob", nickname: "Bob")
        let conversation = try XCTUnwrap(try LocalRepository(context: context).conversation(ownerID: user.id, friendID: friend.id))
        let chat = ChatViewModel(context: context, security: security)
        XCTAssertTrue(try chat.sendText("你好", in: conversation, replyingTo: nil))
        let first = try XCTUnwrap(context.fetch(FetchDescriptor<Message>()).first)
        XCTAssertEqual(try chat.displayContent(for: first), "你好")
        XCTAssertTrue(try chat.sendText("引用回复", in: conversation, replyingTo: first))
        let reply = try XCTUnwrap(context.fetch(FetchDescriptor<Message>()).first { $0.replyToID == first.id })
        try chat.edit(reply, text: "修改后的回复")
        XCTAssertEqual(try chat.displayContent(for: reply), "修改后的回复")
        try chat.react("👍", to: first)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Reaction>()).count, 1)

        let store = MessageStore(context: context, encryption: try security.encryptionService())
        try store.receiveLocal("收到", from: "bob", in: conversation)
        XCTAssertEqual(conversation.unreadCount, 1)
        try security.updatePreferences(for: user, context: context) { $0.disappearingMessages = true }
        try chat.markRead(conversation)
        let received = try XCTUnwrap(context.fetch(FetchDescriptor<Message>()).first { !$0.isMine })
        XCTAssertEqual(conversation.unreadCount, 0)
        XCTAssertNotNil(received.readAt)
        XCTAssertNotNil(received.expiresAt)
        try chat.delete(reply, forEveryone: false)
        XCTAssertTrue(reply.deleted)
        try security.deleteAccount(password: "password123", user: user, context: context)
    }

    func testPasswordEncryptedBackupRestoresWithExistingMasterKey() throws {
        let context = try makeContext()
        let keychain = KeychainManager(service: "app.luma.test.\(UUID().uuidString)")
        let security = SecurityManager(keychain: keychain)
        try security.register(userID: "alice", nickname: "Alice", password: "password123", context: context)
        try security.setPIN("123456", context: context)
        let user = try XCTUnwrap(try LocalRepository(context: context).user("alice"))
        let friend = try LocalRepository(context: context).addFriend(owner: user, userID: "bob", nickname: "Bob")
        let conversation = try XCTUnwrap(try LocalRepository(context: context).conversation(ownerID: user.id, friendID: friend.id))
        let chat = ChatViewModel(context: context, security: security)
        try chat.saveDraft("待发", in: conversation)
        XCTAssertTrue(try chat.sendText("备份消息", in: conversation, replyingTo: nil))
        let oldSession = SessionKey(friendID: friend.id, keyVersion: 1, ownerID: user.id)
        let oldSessionAccount = "session-key.\(user.id.uuidString).\(oldSession.id.uuidString).1"
        try keychain.save(Data(repeating: 7, count: 32), account: oldSessionAccount)
        context.insert(oldSession)
        try context.save()
        let manager = BackupManager(context: context, encryption: try security.encryptionService(),
                                    sessions: try security.sessionManager(context: context))
        let backup = try manager.export(user: user, password: "backup-secret")
        XCTAssertFalse(String(data: backup, encoding: .utf8)?.contains("备份消息") ?? false)
        XCTAssertThrowsError(try manager.restore(backup, password: "wrong-secret", into: user))
        let original = try XCTUnwrap(context.fetch(FetchDescriptor<Message>()).first)
        try chat.edit(original, text: "已修改")
        try manager.restore(backup, password: "backup-secret", into: user)
        let restored = try XCTUnwrap(context.fetch(FetchDescriptor<Message>()).first)
        XCTAssertEqual(try chat.displayContent(for: restored), "备份消息")
        let restoredConversation = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(try chat.draft(in: restoredConversation), "待发")
        XCTAssertNil(try keychain.read(oldSessionAccount))
        restored.transportEncryptionVersion = 3
        try context.save()
        XCTAssertThrowsError(try manager.export(user: user, password: "backup-secret")) { error in
            guard case BackupError.onlineHistoryCannotExport = error else {
                return XCTFail("Online history must not enter a portable backup")
            }
        }
        XCTAssertThrowsError(try manager.restore(backup, password: "backup-secret", into: user))
        XCTAssertEqual(try chat.displayContent(for: restored), "备份消息")
        let interrupted = CleanupState(ownerID: user.id, userID: user.userID, operation: "backupRestore")
        interrupted.dataCommitted = true; interrupted.state = RecoveryState.failed.rawValue
        let obsolete = "session-key.obsolete.\(UUID().uuidString)"
        try keychain.save(Data(repeating: 1, count: 32), account: obsolete)
        let binding = Data("luma-restore-cleanup-v1|\(user.id.uuidString)|\(interrupted.id.uuidString)".utf8)
        interrupted.encryptedPayload = try security.encryptionService().encrypt(
            JSONEncoder().encode([obsolete]), authenticatedData: binding).bytes
        context.insert(interrupted)
        try context.save()
        try BackupManager.resumeRestoreCleanup(for: user, context: context,
            encryption: try security.encryptionService(), keychain: keychain)
        XCTAssertNil(try keychain.read(obsolete))
        XCTAssertTrue(try context.fetch(FetchDescriptor<CleanupState>()).isEmpty)
        try security.deleteAccount(password: "password123", user: user, context: context)
    }

    func testEncryptedOutboxRetriesSameRequestAfterOfflineFailure() async throws {
        let context = try makeContext()
        let owner = UUID(), device = UUID()
        let encryption = EncryptionService(key: SymmetricKey(size: .bits256))
        let client = try RemoteAPIClient(baseURL: URL(string: "https://example.invalid")!, userID: "outbox")
        let queue = OutgoingMessageQueue(context: context, ownerID: owner, backendDeviceID: device,
                                         encryption: encryption, client: client)
        let message = Message(conversationID: UUID(), type: .text, isMine: true)
        message.deliveryStatus = .sending
        context.insert(message)
        let item = try queue.enqueue(messageID: message.id, request: Data("secret".utf8))
        try context.save()
        XCTAssertFalse(item.encryptedRequest.contains(Data("secret".utf8)))
        var sentBodies: [Data] = []
        do {
            try await queue.drain(prepare: { _, plaintext in
                XCTAssertEqual(plaintext, Data("secret".utf8))
                return Data("stable-envelope".utf8)
            }, send: { body, id in
                XCTAssertEqual(id, message.id)
                sentBodies.append(body)
                throw URLError(.notConnectedToInternet)
            })
            XCTFail("Expected offline failure")
        } catch is URLError { }
        XCTAssertTrue(item.prepared)
        XCTAssertEqual(item.state, "pending")
        let later = Message(conversationID: UUID(), type: .text, isMine: true)
        context.insert(later)
        _ = try queue.enqueue(messageID: later.id, request: Data("later".utf8))
        try context.save()
        try await queue.drain(prepare: { _, _ in XCTFail("Retry delay must preserve order"); return Data() },
                              send: { _, _ in XCTFail("Later message overtook the retry") })
        XCTAssertEqual(sentBodies.count, 1)
        item.nextAttemptAt = .distantPast
        try context.save()
        try await queue.drain(prepare: { queued, body in
            XCTAssertEqual(queued.messageID, later.id)
            return body
        },
                              send: { body, _ in sentBodies.append(body) })
        XCTAssertEqual(sentBodies, [Data("stable-envelope".utf8), Data("stable-envelope".utf8), Data("later".utf8)])
        XCTAssertEqual(message.deliveryStatus, .sent)
        XCTAssertTrue(try context.fetch(FetchDescriptor<OutgoingMessageQueueItem>()).isEmpty)
    }

    func testInterruptedAccountDeletionResumesCleanup() throws {
        let keychain = KeychainManager(service: "app.luma.cleanup.\(UUID().uuidString)")
        let context = try makeContext()
        let security = SecurityManager(keychain: keychain)
        try security.register(userID: "cleanup", nickname: "Cleanup", password: "password123", context: context)
        let user = try XCTUnwrap(context.fetch(FetchDescriptor<User>()).first)
        context.insert(CleanupState(ownerID: user.id, userID: user.userID, operation: "accountDeletion"))
        try context.save()
        try security.resumeAccountCleanup(context: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<User>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CleanupState>()).isEmpty)
        XCTAssertFalse(try KeyManager(keychain: keychain).isStored(for: "cleanup"))
    }

    func testIdentityReplacementNeedsExplicitVerificationAndPausesOldSession() throws {
        let context = try makeContext()
        let user = User(userID: "alice", nickname: "Alice", passwordHash: "verifier")
        let friend = Friend(ownerID: user.id, userID: "bob", nickname: "Bob")
        let old = P256.Signing.PrivateKey().publicKey.x963Representation
        let replacement = P256.Signing.PrivateKey().publicKey.x963Representation
        friend.identityFingerprint = IdentityFingerprint.make(publicKey: old)
        let remoteID = UUID()
        friend.remoteUserID = remoteID
        context.insert(user); context.insert(friend)
        context.insert(SessionKey(friendID: friend.id, keyVersion: 1, ownerID: user.id))
        let conversation = Conversation(ownerID: user.id, friendID: friend.id)
        let message = Message(conversationID: conversation.id, type: .text, isMine: true, senderID: user.userID)
        message.deliveryStatus = .sending
        let deviceID = UUID()
        let item = OutgoingMessageQueueItem(ownerID: user.id, backendDeviceID: deviceID,
                                            messageID: message.id, encryptedRequest: Data([1]))
        context.insert(conversation); context.insert(message); context.insert(item)
        context.insert(RemoteDeviceTrust(ownerID: user.id, peerUserID: remoteID,
            bundle: VerifiedDeviceBundle(deviceID: deviceID, identityPublicKey: old,
                                         devicePublicKey: Data([1]), signedPreKey: Data([2]),
                                         oneTimePreKey: nil, keyVersion: 1)))
        try context.save()
        let client = try RemoteAPIClient(baseURL: URL(string: "https://example.invalid")!, userID: user.userID)
        let repository = RemoteMessageRepository(context: context, user: user, security: SecurityManager(),
            client: client, registration: RemoteRegistration(backendUserID: UUID(), backendDeviceID: UUID(),
                                                               baseURL: URL(string: "https://example.invalid")!))
        try repository.markIdentityChanged(friend, candidate: IdentityFingerprint.make(publicKey: replacement))
        XCTAssertEqual(friend.sessionStatus, "identityKeyChanged")
        XCTAssertEqual(item.state, "identityChanged")
        XCTAssertEqual(message.deliveryStatus, .failed)
        XCTAssertTrue(try context.fetch(FetchDescriptor<RemoteDeviceTrust>()).isEmpty)
        XCTAssertThrowsError(try repository.trustIdentity("unverified", for: friend))
        XCTAssertThrowsError(try repository.trustIdentity(IdentityFingerprint.make(publicKey: old), for: friend))
        XCTAssertEqual(friend.identityFingerprint, IdentityFingerprint.make(publicKey: old))
        try repository.trustIdentity(IdentityFingerprint.make(publicKey: replacement), for: friend)
        XCTAssertEqual(friend.sessionStatus, "identityReverified")
        XCTAssertNil(friend.pendingIdentityFingerprint)
        XCTAssertTrue(try context.fetch(FetchDescriptor<OutgoingMessageQueueItem>()).isEmpty)
        let oldSession = try XCTUnwrap(context.fetch(FetchDescriptor<SessionKey>()).first)
        XCTAssertThrowsError(try MessageStore(context: context,
            encryption: EncryptionService(key: SymmetricKey(size: .bits256))).sendSession(
                conversation: conversation, session: oldSession, senderID: user.userID, content: "blocked"))
    }

    func testControlEventsRejectWrongActorAndVersion() throws {
        let context = try makeContext()
        let user = User(userID: "alice", nickname: "Alice", passwordHash: "verifier")
        let friend = Friend(ownerID: user.id, userID: "bob", nickname: "Bob")
        let conversation = Conversation(ownerID: user.id, friendID: friend.id)
        let message = Message(conversationID: conversation.id, type: .text, isMine: true, senderID: user.userID)
        context.insert(user); context.insert(friend); context.insert(conversation); context.insert(message)
        try context.save()
        let verifier = EventVerifier(context: context)
        XCTAssertThrowsError(try verifier.verify(MessageEvent(kind: .messageDeleted, messageID: message.id,
            payload: Data([1]), actorID: friend.userID), message: message))
        XCTAssertNoThrow(try verifier.verify(MessageEvent(kind: .messageDeleted, messageID: message.id,
            payload: Data([1]), actorID: user.userID), message: message))
        let receipt = ReadReceiptEvent(messageID: message.id, readerID: user.userID, timestamp: .now)
        XCTAssertThrowsError(try verifier.verify(MessageEvent(kind: .messageRead, messageID: message.id,
            timestamp: receipt.timestamp, payload: try JSONEncoder().encode(receipt), actorID: user.userID),
            message: message))
        let payload = NewMessagePayload(conversationID: conversation.id, senderID: friend.userID, type: .text,
                                        ciphertext: Data([1]), encryptionVersion: 3,
                                        sessionKeyVersion: nil, messageKeyIndex: nil, replyToID: nil)
        XCTAssertThrowsError(try verifier.verify(MessageEvent(kind: .newMessage, messageID: UUID(),
            payload: try JSONEncoder().encode(payload), actorID: friend.userID), message: nil))
    }
    // MARK: - v3 device envelope
    func testV3DistinctDeviceEnvelopesAndTamperRejection() throws {
        let sender = P256.Signing.PrivateKey()
        let identity = P256.Signing.PrivateKey()
        let fingerprint = IdentityFingerprint.make(publicKey: identity.publicKey.x963Representation)
        let messageID = UUID(), conversationID = UUID(), senderDeviceID = UUID()
        let manager = DeviceSessionManager()
        var ciphertexts: [Data] = []
        for _ in 0..<2 {
            let device = P256.KeyAgreement.PrivateKey()
            let signed = P256.KeyAgreement.PrivateKey()
            let oneTime = P256.KeyAgreement.PrivateKey()
            let bundle = VerifiedDeviceBundle(deviceID: UUID(), identityPublicKey: identity.publicKey.x963Representation,
                devicePublicKey: device.publicKey.x963Representation,
                signedPreKey: signed.publicKey.x963Representation,
                oneTimePreKey: oneTime.publicKey.x963Representation, keyVersion: 1)
            let envelope = try manager.encrypt(Data("跨设备消息".utf8), messageID: messageID,
                conversationID: conversationID, senderDeviceID: senderDeviceID,
                senderIdentityPrivateKey: sender, recipient: bundle)
            XCTAssertEqual(try manager.decrypt(envelope, expectedDeviceID: bundle.deviceID,
                expectedFingerprint: IdentityFingerprint.make(publicKey: sender.publicKey.x963Representation),
                devicePrivateKey: device, signedPreKeyPrivate: signed,
                oneTimePrivateKey: oneTime), Data("跨设备消息".utf8))
            XCTAssertThrowsError(try manager.decrypt(envelope, expectedDeviceID: UUID(),
                expectedFingerprint: IdentityFingerprint.make(publicKey: sender.publicKey.x963Representation),
                devicePrivateKey: device, signedPreKeyPrivate: signed, oneTimePrivateKey: oneTime))
            XCTAssertThrowsError(try manager.decrypt(envelope, expectedDeviceID: bundle.deviceID,
                expectedFingerprint: fingerprint, devicePrivateKey: device,
                signedPreKeyPrivate: signed, oneTimePrivateKey: oneTime))
            let encoded = try JSONEncoder().encode(envelope)
            let restored = try JSONDecoder().decode(DeviceMessageEnvelope.self, from: encoded)
            XCTAssertEqual(try manager.decrypt(restored, expectedDeviceID: bundle.deviceID,
                expectedFingerprint: IdentityFingerprint.make(publicKey: sender.publicKey.x963Representation),
                devicePrivateKey: device, signedPreKeyPrivate: signed, oneTimePrivateKey: oneTime),
                Data("跨设备消息".utf8))
            var tamperedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            tamperedJSON["ciphertext"] = Data("篡改".utf8).base64EncodedString()
            let tampered = try JSONDecoder().decode(DeviceMessageEnvelope.self,
                from: JSONSerialization.data(withJSONObject: tamperedJSON))
            XCTAssertThrowsError(try manager.decrypt(tampered, expectedDeviceID: bundle.deviceID,
                expectedFingerprint: IdentityFingerprint.make(publicKey: sender.publicKey.x963Representation),
                devicePrivateKey: device, signedPreKeyPrivate: signed, oneTimePrivateKey: oneTime))
            ciphertexts.append(envelope.ciphertext)
        }
        XCTAssertNotEqual(ciphertexts[0], ciphertexts[1])
    }

    func testV4HandshakeAndTwoWayRatchetCore() throws {
        let aliceID = UUID(), bobID = UUID(), conversationID = UUID()
        let aliceIdentity = V4IdentityKeys(), bobIdentity = V4IdentityKeys()
        let bobSigned = Curve25519.KeyAgreement.PrivateKey()
        let bobOneTime = Curve25519.KeyAgreement.PrivateKey()
        let bundle = try V4Handshake.bundle(deviceID: bobID, version: 1, identity: bobIdentity,
            signedPreKey: bobSigned, oneTimePreKey: bobOneTime)
        let initiated = try V4Handshake.initiate(senderDeviceID: aliceID, identity: aliceIdentity,
            recipient: bundle, expectedFingerprint: bundle.identityFingerprint)
        let aliceFingerprint = V4Handshake.fingerprint(
            signing: aliceIdentity.signing.publicKey.rawRepresentation,
            agreement: aliceIdentity.agreement.publicKey.rawRepresentation)
        let accepted = try V4Handshake.accept(initiated.header, expectedDeviceID: bobID, expectedKeyVersion: 1,
            expectedSenderFingerprint: aliceFingerprint, identity: bobIdentity,
            signedPreKey: bobSigned, oneTimePreKey: bobOneTime)
        XCTAssertEqual(initiated.sharedSecret.withUnsafeBytes { Data($0) },
                       accepted.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try V4Handshake.accept(initiated.header, expectedDeviceID: UUID(), expectedKeyVersion: 1,
            expectedSenderFingerprint: aliceFingerprint, identity: bobIdentity,
            signedPreKey: bobSigned, oneTimePreKey: bobOneTime))
        XCTAssertThrowsError(try V4Handshake.initiate(senderDeviceID: aliceID, identity: aliceIdentity,
            recipient: bundle, expectedFingerprint: "unverified"))

        var alice = try V4RatchetState.initiator(sharedSecret: initiated.sharedSecret,
            ownEphemeral: initiated.ratchetPrivateKey, remoteSignedPreKey: bundle.signedPreKeyPublicKey)
        var bob = V4RatchetState.responder(sharedSecret: accepted, ownSignedPreKey: bobSigned)
        let first = try alice.encrypt(Data("first".utf8), messageID: UUID(),
            conversationID: conversationID, senderDeviceID: aliceID, receiverDeviceID: bobID)
        let second = try alice.encrypt(Data("second".utf8), messageID: UUID(),
            conversationID: conversationID, senderDeviceID: aliceID, receiverDeviceID: bobID)
        XCTAssertNotEqual(first.ciphertext, second.ciphertext)
        XCTAssertEqual(try bob.decrypt(second, expectedReceiver: bobID, expectedSender: aliceID,
            expectedConversation: conversationID), Data("second".utf8))
        XCTAssertEqual(try bob.decrypt(first, expectedReceiver: bobID, expectedSender: aliceID,
            expectedConversation: conversationID), Data("first".utf8))
        XCTAssertThrowsError(try bob.decrypt(first, expectedReceiver: bobID, expectedSender: aliceID,
            expectedConversation: conversationID))
        let reply = try bob.encrypt(Data("reply".utf8), messageID: UUID(),
            conversationID: conversationID, senderDeviceID: bobID, receiverDeviceID: aliceID)
        XCTAssertEqual(try alice.decrypt(reply, expectedReceiver: aliceID, expectedSender: bobID,
            expectedConversation: conversationID), Data("reply".utf8))
        let previousRoot = bob.rootKey
        let third = try alice.encrypt(Data("new chain".utf8), messageID: UUID(),
            conversationID: conversationID, senderDeviceID: aliceID, receiverDeviceID: bobID)
        XCTAssertEqual(try bob.decrypt(third, expectedReceiver: bobID, expectedSender: aliceID,
            expectedConversation: conversationID), Data("new chain".utf8))
        XCTAssertNotEqual(previousRoot, bob.rootKey)
        let before = bob.receivingIndex
        let forged = V4RatchetMessage(messageID: UUID(), conversationID: third.conversationID,
            senderDeviceID: third.senderDeviceID, receiverDeviceID: third.receiverDeviceID,
            encryptionVersion: third.encryptionVersion, ratchetPublicKey: third.ratchetPublicKey,
            previousChainLength: third.previousChainLength, messageIndex: third.messageIndex,
            sessionVersion: third.sessionVersion, initialHeader: third.initialHeader,
            nonce: third.nonce, ciphertext: third.ciphertext, authenticationTag: third.authenticationTag)
        XCTAssertThrowsError(try bob.decrypt(forged, expectedReceiver: bobID, expectedSender: aliceID,
            expectedConversation: conversationID))
        XCTAssertEqual(bob.receivingIndex, before)
    }

    func testV4TwoDeviceSessionSurvivesVaultReopen() throws {
        struct Request: Decodable {
            struct Recipient: Decodable { let recipientDeviceID: String; let ciphertext: String }
            let recipientEnvelopes: [Recipient]
        }
        let service = "app.luma.v4-test.\(UUID().uuidString)"
        let vault = V4SessionVault(keychain: KeychainManager(service: service))
        defer { try? vault.purgeAccount(userID: "alice"); try? vault.purgeAccount(userID: "bob") }
        let aliceID = UUID(), bobID = UUID(), aliceUserID = UUID(), bobUserID = UUID()
        let conversationID = UUID()
        let aliceIdentity = V4IdentityKeys(), bobIdentity = V4IdentityKeys()
        let aliceSigned = Curve25519.KeyAgreement.PrivateKey()
        let bobSigned = Curve25519.KeyAgreement.PrivateKey()
        for (name, id, identity, signed) in [
            ("alice", aliceID, aliceIdentity, aliceSigned),
            ("bob", bobID, bobIdentity, bobSigned)
        ] {
            try vault.saveDevice(.init(formatVersion: 1, deviceID: id, keyVersion: 1,
                identityAgreement: identity.agreement.rawRepresentation,
                identitySigning: identity.signing.rawRepresentation,
                signedPreKey: signed.rawRepresentation, oneTimePreKeys: [:]), userID: name)
        }
        let aliceBundle = try V4Handshake.bundle(deviceID: aliceID, version: 1,
            identity: aliceIdentity, signedPreKey: aliceSigned, oneTimePreKey: nil)
        let bobBundle = try V4Handshake.bundle(deviceID: bobID, version: 1,
            identity: bobIdentity, signedPreKey: bobSigned, oneTimePreKey: nil)
        let alice = V4MessageSessionService(vault: vault, userID: "alice", localDeviceID: aliceID)
        let bob = V4MessageSessionService(vault: vault, userID: "bob", localDeviceID: bobID)
        let firstID = UUID()
        let firstRequest = try alice.prepare(Data("hello".utf8), messageID: firstID,
            conversationID: conversationID, targets: [.init(remoteUserID: bobUserID, bundle: bobBundle)])
        XCTAssertEqual(try vault.outgoingPending(userID: "alice", deviceID: aliceID)?.phase, .prepared)
        let reopenedVault = V4SessionVault(keychain: KeychainManager(service: service))
        try V4MessageSessionService(vault: reopenedVault, userID: "alice", localDeviceID: aliceID)
            .commitPreparedSend(messageID: firstID)
        XCTAssertNil(try reopenedVault.outgoingPending(userID: "alice", deviceID: aliceID))
        let oldAlice = try XCTUnwrap(vault.loadSession(userID: "alice", local: aliceID, remote: bobID))
        let firstWire = try XCTUnwrap(JSONDecoder().decode(Request.self, from: firstRequest)
            .recipientEnvelopes.first?.ciphertext)
        let firstData = try XCTUnwrap(Data(base64URL: firstWire))
        let first = try JSONDecoder().decode(V4RatchetMessage.self, from: firstData)
        let firstEvent = UUID()
        XCTAssertEqual(try bob.decrypt(first, wire: firstData, eventID: firstEvent, deviceSeq: 1,
            senderUserID: aliceUserID, senderBundle: aliceBundle), Data("hello".utf8))
        let restartedBob = V4MessageSessionService(vault: reopenedVault,
            userID: "bob", localDeviceID: bobID)
        try restartedBob.recoverReceived(committedCursor: 0)
        XCTAssertEqual(try reopenedVault.incomingPending(userID: "bob", deviceID: bobID)?.phase, .prepared)
        try restartedBob.recoverReceived(committedCursor: 1)
        XCTAssertNil(try reopenedVault.incomingPending(userID: "bob", deviceID: bobID))
        XCTAssertNotNil(try vault.loadSession(userID: "bob", local: bobID, remote: aliceID))
        let replyID = UUID()
        let replyRequest = try V4MessageSessionService(vault: reopenedVault,
            userID: "bob", localDeviceID: bobID).prepare(Data("reply".utf8), messageID: replyID,
            conversationID: conversationID, targets: [.init(remoteUserID: aliceUserID, bundle: aliceBundle)])
        try bob.commitPreparedSend(messageID: replyID)
        let replyWire = try XCTUnwrap(JSONDecoder().decode(Request.self, from: replyRequest)
            .recipientEnvelopes.first?.ciphertext)
        let replyData = try XCTUnwrap(Data(base64URL: replyWire))
        let reply = try JSONDecoder().decode(V4RatchetMessage.self, from: replyData)
        let replyEvent = UUID()
        let restartedAlice = V4MessageSessionService(vault: reopenedVault,
            userID: "alice", localDeviceID: aliceID)
        XCTAssertEqual(try restartedAlice.decrypt(reply, wire: replyData, eventID: replyEvent, deviceSeq: 1,
            senderUserID: bobUserID, senderBundle: bobBundle), Data("reply".utf8))
        try restartedAlice.finishReceived(eventID: replyEvent)
        let latestAlice = try XCTUnwrap(vault.loadSession(userID: "alice", local: aliceID, remote: bobID))
        XCTAssertGreaterThan(latestAlice.stateVersion, oldAlice.stateVersion)
        XCTAssertThrowsError(try vault.saveSession(oldAlice, userID: "alice"))
        let account = "v4.session.alice.\(aliceID.uuidString).\(bobID.uuidString)"
        try vault.keychain.save(JSONEncoder().encode(oldAlice), account: account)
        XCTAssertThrowsError(try vault.loadSession(userID: "alice", local: aliceID, remote: bobID))
        try vault.keychain.save(JSONEncoder().encode(latestAlice), account: account)
        XCTAssertThrowsError(try restartedAlice.decrypt(reply, wire: replyData, eventID: UUID(), deviceSeq: 2,
            senderUserID: bobUserID, senderBundle: bobBundle))
    }

    func testV4ControlEventsUseFreshKeysAndRejectReplayOrTampering() throws {
        struct Request: Decodable {
            struct Recipient: Decodable { let ciphertext: String }
            let recipientEnvelopes: [Recipient]
        }
        let service = "app.luma.v4-events.\(UUID().uuidString)"
        let aliceVault = V4SessionVault(keychain: KeychainManager(service: service + ".a"))
        let bobVault = V4SessionVault(keychain: KeychainManager(service: service + ".b"))
        defer { try? aliceVault.purgeAccount(userID: "alice"); try? bobVault.purgeAccount(userID: "bob") }
        let aliceID = UUID(), bobID = UUID(), aliceUser = UUID(), bobUser = UUID()
        let conversationID = UUID(), messageID = UUID()
        let aliceKeys = V4IdentityKeys(), bobKeys = V4IdentityKeys()
        let aliceSigned = Curve25519.KeyAgreement.PrivateKey(), bobSigned = Curve25519.KeyAgreement.PrivateKey()
        try aliceVault.saveDevice(.init(formatVersion: 1, deviceID: aliceID, keyVersion: 1,
            identityAgreement: aliceKeys.agreement.rawRepresentation,
            identitySigning: aliceKeys.signing.rawRepresentation,
            signedPreKey: aliceSigned.rawRepresentation, oneTimePreKeys: [:]), userID: "alice")
        try bobVault.saveDevice(.init(formatVersion: 1, deviceID: bobID, keyVersion: 1,
            identityAgreement: bobKeys.agreement.rawRepresentation,
            identitySigning: bobKeys.signing.rawRepresentation,
            signedPreKey: bobSigned.rawRepresentation, oneTimePreKeys: [:]), userID: "bob")
        let aliceBundle = try V4Handshake.bundle(deviceID: aliceID, version: 1,
            identity: aliceKeys, signedPreKey: aliceSigned, oneTimePreKey: nil)
        let bobBundle = try V4Handshake.bundle(deviceID: bobID, version: 1,
            identity: bobKeys, signedPreKey: bobSigned, oneTimePreKey: nil)
        let alice = V4MessageSessionService(vault: aliceVault, userID: "alice", localDeviceID: aliceID)
        let bob = V4MessageSessionService(vault: bobVault, userID: "bob", localDeviceID: bobID)
        let first = try alice.prepare(Data("hello".utf8), messageID: messageID,
            conversationID: conversationID, targets: [.init(remoteUserID: bobUser, bundle: bobBundle)])
        try alice.commitPreparedSend(messageID: messageID)
        let firstWire = try XCTUnwrap(Data(base64URL: XCTUnwrap(JSONDecoder().decode(Request.self, from: first)
            .recipientEnvelopes.first).ciphertext))
        let firstEnvelope = try JSONDecoder().decode(V4RatchetMessage.self, from: firstWire)
        let firstSyncID = UUID()
        XCTAssertEqual(try bob.decrypt(firstEnvelope, wire: firstWire, eventID: firstSyncID,
            deviceSeq: 1, senderUserID: aliceUser, senderBundle: aliceBundle), Data("hello".utf8))
        try bob.finishReceived(eventID: firstSyncID)
        var ciphertexts: [Data] = []
        for (index, kind, text, action) in [
            (2, V4EventEnvelope.Kind.edit, "changed", nil),
            (2, .reaction, "👍", "add"),
            (2, .reaction, "👍", "remove"),
            (3, .delete, nil, nil)
        ] {
            let event = V4EventEnvelope(eventID: UUID(), messageID: messageID,
                conversationID: conversationID, actorUserID: aliceUser,
                actorDeviceID: aliceID, kind: kind, revision: index,
                text: text, reactionAction: action, occurredAt: .now)
            let request = try alice.prepareEvent(event, targets: [.init(remoteUserID: bobUser, bundle: bobBundle)])
            try alice.commitPreparedSend(messageID: event.eventID)
            let wire = try XCTUnwrap(Data(base64URL: XCTUnwrap(JSONDecoder().decode(Request.self, from: request)
                .recipientEnvelopes.first).ciphertext))
            ciphertexts.append(wire)
            let envelope = try JSONDecoder().decode(V4RatchetMessage.self, from: wire)
            XCTAssertEqual(envelope.messageID, event.eventID)
            let syncID = UUID()
            let decoded = try bob.decrypt(envelope, wire: wire, eventID: syncID,
                deviceSeq: Int64(ciphertexts.count + 1), senderUserID: aliceUser,
                senderBundle: aliceBundle)
            XCTAssertEqual(try JSONDecoder().decode(V4EventEnvelope.self, from: decoded).eventID, event.eventID)
            try bob.finishReceived(eventID: syncID)
            XCTAssertThrowsError(try bob.decrypt(envelope, wire: wire, eventID: UUID(),
                deviceSeq: 99, senderUserID: aliceUser, senderBundle: aliceBundle))
        }
        XCTAssertEqual(Set(ciphertexts).count, ciphertexts.count)
        let read = V4EventEnvelope(eventID: UUID(), messageID: messageID,
            conversationID: conversationID, actorUserID: bobUser,
            actorDeviceID: bobID, kind: .read, revision: 3,
            text: nil, reactionAction: nil, occurredAt: .now)
        let readRequest = try bob.prepareEvent(read, targets: [.init(remoteUserID: aliceUser, bundle: aliceBundle)])
        try bob.commitPreparedSend(messageID: read.eventID)
        let readWire = try XCTUnwrap(Data(base64URL: XCTUnwrap(JSONDecoder().decode(Request.self, from: readRequest)
            .recipientEnvelopes.first).ciphertext))
        let readEnvelope = try JSONDecoder().decode(V4RatchetMessage.self, from: readWire)
        let tampered = V4RatchetMessage(messageID: UUID(), conversationID: readEnvelope.conversationID,
            senderDeviceID: readEnvelope.senderDeviceID, receiverDeviceID: readEnvelope.receiverDeviceID,
            encryptionVersion: 4, ratchetPublicKey: readEnvelope.ratchetPublicKey,
            previousChainLength: readEnvelope.previousChainLength, messageIndex: readEnvelope.messageIndex,
            sessionVersion: readEnvelope.sessionVersion, initialHeader: readEnvelope.initialHeader,
            nonce: readEnvelope.nonce, ciphertext: readEnvelope.ciphertext,
            authenticationTag: readEnvelope.authenticationTag)
        XCTAssertThrowsError(try alice.decrypt(tampered, wire: try JSONEncoder().encode(tampered),
            eventID: UUID(), deviceSeq: 1, senderUserID: bobUser, senderBundle: bobBundle))
        let readSyncID = UUID()
        let decrypted = try alice.decrypt(readEnvelope, wire: readWire, eventID: readSyncID,
            deviceSeq: 1, senderUserID: bobUser, senderBundle: bobBundle)
        XCTAssertEqual(try JSONDecoder().decode(V4EventEnvelope.self, from: decrypted).kind, .read)
        try alice.finishReceived(eventID: readSyncID)

        // A file key and name travel inside a fresh per-device ratchet message.
        let attachmentMessageID = UUID()
        let descriptor = V4AttachmentCrypto.makeDescriptor(attachmentID: UUID(),
            messageID: attachmentMessageID, conversationID: conversationID,
            type: .file, name: "private.pdf")
        let attachmentBytes = Data("file bytes".utf8)
        let sealedFile = try V4AttachmentCrypto.encrypt(attachmentBytes, descriptor: descriptor)
        let uploaded = descriptor.withUpload(id: UUID(), hash: Data(SHA256.hash(data: sealedFile.bytes)))
        let attachmentPayload = V4AttachmentPayload(kind: "attachment", senderUserID: "bob",
            targetUserID: "alice", attachment: uploaded)
        let attachmentRequest = try bob.prepare(JSONEncoder().encode(attachmentPayload),
            messageID: attachmentMessageID, conversationID: conversationID,
            targets: [.init(remoteUserID: aliceUser, bundle: aliceBundle)],
            attachmentIDs: [uploaded.remoteObjectID!])
        try bob.commitPreparedSend(messageID: attachmentMessageID)
        let attachmentWire = try XCTUnwrap(Data(base64URL: XCTUnwrap(
            JSONDecoder().decode(Request.self, from: attachmentRequest).recipientEnvelopes.first).ciphertext))
        let attachmentEnvelope = try JSONDecoder().decode(V4RatchetMessage.self, from: attachmentWire)
        let attachmentSyncID = UUID()
        let opened = try alice.decrypt(attachmentEnvelope, wire: attachmentWire,
            eventID: attachmentSyncID, deviceSeq: 2, senderUserID: bobUser, senderBundle: bobBundle)
        let received = try JSONDecoder().decode(V4AttachmentPayload.self, from: opened)
        XCTAssertEqual(received.attachment.name, "private.pdf")
        XCTAssertEqual(try V4AttachmentCrypto.decrypt(sealedFile, descriptor: received.attachment), attachmentBytes)
        try alice.finishReceived(eventID: attachmentSyncID)
    }

}
