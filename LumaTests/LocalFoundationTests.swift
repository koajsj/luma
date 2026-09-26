import SwiftData
import CryptoKit
import XCTest
@testable import Luma

@MainActor
final class LocalFoundationTests: XCTestCase {
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
        item.nextAttemptAt = .distantPast
        try context.save()
        try await queue.drain(prepare: { _, _ in XCTFail("Prepared request must be reused"); return Data() },
                              send: { body, _ in sentBodies.append(body) })
        XCTAssertEqual(sentBodies, [Data("stable-envelope".utf8), Data("stable-envelope".utf8)])
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

}
