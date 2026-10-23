import SwiftData
import CryptoKit
import XCTest
@testable import Luma

@MainActor
final class LocalFoundationTests: XCTestCase {
    func testConcurrentRequestsShareTokenRefresh() async throws {
        let keychain = KeychainManager(service: "app.luma.refresh.\(UUID().uuidString)")
        let store = RemoteSessionStore(keychain: keychain)
        let signer = RemoteDeviceSigner(keychain: keychain)
        let userID = "refresh-test"
        defer { try? store.clearAll(for: userID) }
        _ = try signer.publicKey(for: userID)
        try keychain.save(JSONEncoder().encode(RemoteTokens(accessToken: "expired-test-token",
            refreshToken: "refresh-test-token", expiresAt: .distantPast)), account: "remote.tokens.\(userID)")
        TokenRefreshURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenRefreshURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://refresh.example.invalid")!
        let firstClient = try RemoteAPIClient(baseURL: url, userID: userID, store: store, signer: signer, session: session)
        let secondClient = try RemoteAPIClient(baseURL: url, userID: userID, store: store, signer: signer, session: session)
        async let first = firstClient.request("GET", path: "/users/me")
        async let second = secondClient.request("GET", path: "/users/me")
        _ = try await (first, second)
        XCTAssertEqual(TokenRefreshURLProtocol.refreshCount, 1,
            "Concurrent clients must not reuse the same rotating refresh token")
    }

    func testLogoutDuringRefreshDoesNotRestoreTokens() async throws {
        let keychain = KeychainManager(service: "app.luma.logout-refresh.\(UUID().uuidString)")
        let store = RemoteSessionStore(keychain: keychain)
        let signer = RemoteDeviceSigner(keychain: keychain)
        let userID = "logout-refresh-test"
        defer { try? store.clearAll(for: userID) }
        _ = try signer.publicKey(for: userID)
        try keychain.save(JSONEncoder().encode(RemoteTokens(accessToken: "expired-test-token",
            refreshToken: "logout-test-token", expiresAt: .distantPast)), account: "remote.tokens.\(userID)")
        TokenRefreshURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenRefreshURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = try RemoteAPIClient(baseURL: URL(string: "https://refresh.example.invalid")!,
            userID: userID, store: store, signer: signer, session: session)
        let request = Task { try await client.request("GET", path: "/users/me") }
        for _ in 0..<100 where TokenRefreshURLProtocol.refreshCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(TokenRefreshURLProtocol.refreshCount, 1)
        try store.clearTokens(for: userID)
        do { _ = try await request.value; XCTFail("Logged-out request should fail") }
        catch RemoteError.authenticationExpired { }
        XCTAssertNil(try store.tokens(for: userID))

        let registration = RemoteRegistration(backendUserID: UUID(), backendDeviceID: UUID(), baseURL: client.baseURL)
        try store.save(registration, for: userID)
        let heldConfig = URLSessionConfiguration.ephemeral
        heldConfig.protocolClasses = [HeldResponseURLProtocol.self]
        let heldSession = URLSession(configuration: heldConfig)
        defer { heldSession.invalidateAndCancel() }
        HeldResponseURLProtocol.reset(Data("{\"accessToken\":\"late-access\",\"refreshToken\":\"late-refresh\",\"expiresIn\":900}".utf8),
            suffix: "/auth/token", responses: ["/v1/auth/challenge": try JSONSerialization.data(withJSONObject: [
                "challengeID": UUID().uuidString, "nonce": "test-nonce"])])
        let auth = RemoteAuthProvider(context: try makeContext(), store: store, signer: signer, session: heldSession)
        let login = Task { try await auth.login(userID: userID) }
        for _ in 0..<100 where !HeldResponseURLProtocol.isWaiting { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(HeldResponseURLProtocol.isWaiting)
        // No tokens need to exist: logout must invalidate an in-flight fresh login too.
        try store.clearTokens(for: userID)
        HeldResponseURLProtocol.complete()
        do { try await login.value; XCTFail("A late device login must not recreate logged-out credentials") }
        catch RemoteError.authenticationExpired { }
        XCTAssertNil(try store.tokens(for: userID))

        try store.save(.init(accessToken: "old-access", refreshToken: "old-refresh", expiresIn: 900), for: userID)
        HeldResponseURLProtocol.reset(Data("{\"code\":\"device_revoked\"}".utf8), suffix: "/users/me", statusCode: 401)
        let heldClient = try RemoteAPIClient(baseURL: client.baseURL, userID: userID,
            store: store, signer: signer, session: heldSession)
        let staleRequest = Task { try await heldClient.request("GET", path: "/users/me") }
        for _ in 0..<100 where !HeldResponseURLProtocol.isWaiting { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(HeldResponseURLProtocol.isWaiting)
        try store.save(.init(accessToken: "current-access", refreshToken: "current-refresh", expiresIn: 900), for: userID)
        HeldResponseURLProtocol.complete()
        do { _ = try await staleRequest.value; XCTFail("A revoked stale request cannot succeed") }
        catch RemoteError.authenticationExpired { }
        XCTAssertEqual(try store.tokens(for: userID)?.accessToken, "current-access",
            "A stale revocation response must not clear the replacement session or trigger its key cleanup")
    }

    func testTransmissionGateRechecksTrustAfterTokenRefresh() async throws {
        let keychain = KeychainManager(service: "app.luma.send-gate.\(UUID())")
        let store = RemoteSessionStore(keychain: keychain), signer = RemoteDeviceSigner(keychain: keychain)
        let userID = "send-gate"
        defer { try? store.clearAll(for: userID) }
        _ = try signer.publicKey(for: userID)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenRefreshURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = try RemoteAPIClient(baseURL: URL(string: "https://send-gate.example.invalid")!,
            userID: userID, store: store, signer: signer, session: session)
        for scenario in ["identityChanged", "cancelled", "available"] {
            try keychain.save(JSONEncoder().encode(RemoteTokens(accessToken: "expired-test-token",
                refreshToken: UUID().uuidString, expiresAt: .distantPast)), account: "remote.tokens.\(userID)")
            TokenRefreshURLProtocol.reset()
            var trusted = true
            let send = Task {
                try await client.json([String: String].self, method: "POST", path: "/messages", body: Data("opaque envelope".utf8),
                    beforeTransmission: {
                        guard trusted else { throw V4ProtocolError.untrustedIdentity }
                    })
            }
            for _ in 0..<100 where TokenRefreshURLProtocol.refreshCount == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(TokenRefreshURLProtocol.refreshCount, 1)
            if scenario == "identityChanged" { trusted = false }
            if scenario == "cancelled" { send.cancel() }
            if scenario == "available" { _ = try await send.value }
            else {
                do { _ = try await send.value; XCTFail("Transmission must stop after \(scenario)") }
                catch {
                    if scenario == "identityChanged" { XCTAssertEqual(error as? V4ProtocolError, .untrustedIdentity) }
                    else { XCTAssertTrue(error is CancellationError) }
                }
            }
            XCTAssertEqual(TokenRefreshURLProtocol.requestCount, scenario == "available" ? 2 : 1,
                "A rejected request must not reach the message endpoint")
        }
    }

    func testOfflineSignOutRetriesWithDeviceSignatureWithoutKeepingTokens() async throws {
        let userID = "revoke-test"
        let keychain = KeychainManager(service: "app.luma.revoke.\(UUID().uuidString)")
        let store = RemoteSessionStore(keychain: keychain)
        let signer = RemoteDeviceSigner(keychain: keychain)
        defer { try? store.clearAll(for: userID) }
        _ = try signer.publicKey(for: userID)
        try store.save(RemoteRegistration(backendUserID: UUID(), backendDeviceID: UUID(),
            baseURL: URL(string: "https://revoke.example.invalid")!), for: userID)
        try store.save(RemoteTokenResponse(accessToken: "old-test-access", refreshToken: "old-test-refresh",
                                            expiresIn: 900), for: userID)
        RevocationURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RevocationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = RemoteAuthProvider(context: try makeContext(), store: store, signer: signer, session: session)
        do { try await provider.signOut(userID: userID); XCTFail("First revoke must fail") }
        catch RemoteError.server(503, _) { }
        XCTAssertNil(try store.tokens(for: userID))
        XCTAssertTrue(try store.revocationPending(for: userID))
        try await provider.revokePending(userID: userID)
        XCTAssertNil(try store.tokens(for: userID))
        XCTAssertFalse(try store.revocationPending(for: userID))
        XCTAssertEqual(RevocationURLProtocol.paths, ["/v1/auth/challenge", "/v1/auth/token",
                                                       "/v1/auth/revoke", "/v1/auth/challenge",
                                                       "/v1/auth/token", "/v1/auth/revoke"])
        XCTAssertTrue(RevocationURLProtocol.revokeHadDeviceProof)
    }

    func testPreKeyPublicationDoesNotRestoreConsumedPrivateKey() async throws {
        let context = try makeContext()
        let user = User(userID: "prekey-race", nickname: "Alice", passwordHash: "verifier")
        context.insert(user)
        let keychain = KeychainManager(service: "app.luma.prekey-race.\(UUID().uuidString)")
        let vault = V4SessionVault(keychain: keychain)
        let store = RemoteSessionStore(keychain: keychain)
        let signer = RemoteDeviceSigner(keychain: keychain)
        let identity = P256.Signing.PrivateKey()
        user.identityPublicKey = identity.publicKey.x963Representation
        try keychain.save(identity.rawRepresentation, account: "identity-private.\(user.userID)")
        _ = try signer.publicKey(for: user.userID)
        try store.save(RemoteTokenResponse(accessToken: "test-token", refreshToken: "test-refresh", expiresIn: 900), for: user.userID)
        let deviceID = UUID()
        defer {
            try? vault.purgeAccount(userID: user.userID)
            try? store.clearAll(for: user.userID)
            try? keychain.delete("identity-private.\(user.userID)")
        }
        let registration = RemoteRegistration(backendUserID: UUID(), backendDeviceID: deviceID,
            baseURL: URL(string: "https://prekey.example.invalid")!)
        TokenRefreshURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenRefreshURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = try RemoteAPIClient(baseURL: registration.baseURL, userID: user.userID,
            store: store, signer: signer, session: session)
        let publication = Task { try await V4PreKeyService(context: context, user: user,
            registration: registration, client: client, vault: vault).ensurePublished() }
        for _ in 0..<100 where TokenRefreshURLProtocol.requestCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(TokenRefreshURLProtocol.requestCount, 1)
        var current = try XCTUnwrap(vault.loadDevice(userID: user.userID, deviceID: deviceID))
        let consumed = try XCTUnwrap(current.oneTimePreKeys.keys.first)
        current.oneTimePreKeys.removeValue(forKey: consumed)
        current.pendingOneTimePreKeys.removeAll { $0 == consumed }
        try vault.saveDevice(current, userID: user.userID)
        try await publication.value
        XCTAssertNil(try vault.loadDevice(userID: user.userID, deviceID: deviceID)?.oneTimePreKeys[consumed])
    }

    func testSearchRejectsStaleDeletedAndOrphanedEntries() throws {
        let context = try makeContext()
        let user = User(userID: "search-test", nickname: "Alice", passwordHash: "verifier")
        let friend = Friend(ownerID: user.id, userID: "bob", nickname: "Bob")
        let conversation = Conversation(ownerID: user.id, friendID: friend.id)
        context.insert(user); context.insert(friend); context.insert(conversation)
        let encryption = EncryptionService(key: SymmetricKey(size: .bits256))
        let message = try MessageStore(context: context, encryption: encryption).send(
            conversationID: conversation.id, senderID: user.userID, type: .text, content: "private needle")
        let index = SearchIndexService(context: context, encryption: encryption)
        try index.rebuild(for: user)
        XCTAssertEqual(try index.search("needle", for: user).count, 1)
        message.deleted = true
        try context.save()
        XCTAssertTrue(try index.search("needle", for: user).isEmpty)
        context.delete(message)
        try context.save()
        XCTAssertTrue(try index.search("needle", for: user).isEmpty)
    }

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
        let container = try ModelContainer(for: User.self, Device.self, Friend.self, Conversation.self, Message.self, Attachment.self, UserPresence.self, Reaction.self, SearchIndexEntry.self, SessionKey.self, PreKeyMetadata.self, ChainState.self, RemoteSyncCheckpoint.self, RemoteDeviceTrust.self, OutgoingMessageQueueItem.self, CleanupState.self, V4DeviceMetadata.self, V4SessionMetadata.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    func testPrivateProfileMigrationAndEncryptedPersistence() throws {
        let context = try makeContext()
        let user = User(userID: "alice", nickname: "Alice", passwordHash: "legacy")
        user.userIDHash = SHA256.hash(data: Data("alice".utf8))
            .map { String(format: "%02x", $0) }.joined()
        user.bio = "private bio"
        let friend = Friend(ownerID: user.id, userID: "bob", nickname: "Bob")
        friend.remark = "private remark"
        friend.privacyRestricted = true
        context.insert(user); context.insert(friend)
        try context.save()
        let metadata = PrivateMetadataStore(context: context,
            encryption: EncryptionService(key: SymmetricKey(size: .bits256)))
        let conversation = Conversation(ownerID: user.id, friendID: friend.id)
        let message = Message(conversationID: conversation.id, type: .file, isMine: true)
        let attachment = Attachment(messageID: message.id, type: .file, path: "private.pdf")
        context.insert(conversation); context.insert(message); context.insert(attachment)
        try metadata.saveAttachmentMetadata(.init(name: "private.pdf", encryptedPath: nil, metadata: nil), for: attachment)
        // Interrupted older migrations may leave both a valid ciphertext and plaintext columns.
        attachment.path = "private.pdf"
        attachment.encryptedPath = "legacy-private-path"
        attachment.encryptionMetadata = Data("legacy metadata".utf8)
        try metadata.migrate(owner: user)
        XCTAssertEqual(attachment.path, "")
        XCTAssertNil(attachment.encryptedPath)
        XCTAssertNil(attachment.encryptionMetadata)
        XCTAssertEqual(try metadata.attachmentMetadata(for: attachment).name, "private.pdf")
        attachment.encryptedMetadata = Data([0])
        attachment.path = "retain-on-failure.pdf"
        XCTAssertThrowsError(try metadata.migrate(owner: user))
        XCTAssertEqual(attachment.path, "retain-on-failure.pdf")
        XCTAssertEqual(user.userIDHMAC, try LocalRepository.userIDHMAC("alice"))
        XCTAssertNil(user.userIDHash)
        XCTAssertNotEqual(user.userIDHMAC, SHA256.hash(data: Data("alice".utf8))
            .map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try LocalRepository(context: context).user("ALICE")?.id, user.id)
        XCTAssertEqual(user.nickname, "")
        XCTAssertNil(user.bio)
        XCTAssertEqual(friend.nickname, "")
        XCTAssertNil(friend.remark)
        XCTAssertNil(friend.privacyRestricted)
        XCTAssertEqual(try metadata.profile(for: user).bio, "private bio")
        XCTAssertEqual(try metadata.profile(for: friend).remark, "private remark")
        XCTAssertTrue(try metadata.profile(for: friend).privacyRestricted)
        try metadata.savePrivateNote("only me", for: friend)
        XCTAssertEqual(try metadata.profile(for: friend).privateNote, "only me")
        XCTAssertNil(user.encryptedProfile?.range(of: Data("private bio".utf8)))
        XCTAssertNil(friend.encryptedProfile?.range(of: Data("private remark".utf8)))
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
        let owner = try LocalRepository(context: context).createUser(userID: "alice", nickname: "Alice", passwordHash: "verifier", persist: true)
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
        let keychain = KeychainManager(service: "app.luma.flow.\(UUID().uuidString)")
        let security = SecurityManager(keychain: keychain)
        try security.register(userID: "alice", nickname: "Alice", password: "password123", context: context)
        try security.setPIN("123456", context: context)
        let user = try XCTUnwrap(try LocalRepository(context: context).user("alice"))
        XCTAssertEqual(user.nickname, "")
        XCTAssertEqual(user.userIDHMAC, try LocalRepository.userIDHMAC("alice"))
        let searchableUser = User(userID: "bob", nickname: "Bob", passwordHash: "verifier")
        searchableUser.userIDHMAC = try LocalRepository.userIDHMAC("bob")
        let friends = FriendsViewModel(context: context)
        XCTAssertNil(friends.searchableUser(for: " BOB ", among: [user, searchableUser], excluding: user))
        searchableUser.searchable = true
        XCTAssertEqual(friends.searchableUser(for: " BOB ", among: [user, searchableUser], excluding: user)?.id,
                       searchableUser.id)
        XCTAssertNotNil(user.encryptedProfile)
        XCTAssertEqual(try security.userProfile(user, context: context).nickname, "Alice")
        security.lock()
        XCTAssertThrowsError(try security.verifyPIN("000000", context: context))
        try security.verifyPIN("123456", context: context)
        let remoteSessions = RemoteSessionStore(keychain: keychain)
        try remoteSessions.save(RemoteRegistration(backendUserID: UUID(), backendDeviceID: UUID(),
            baseURL: URL(string: "https://logout.example.invalid")!), for: "alice")
        try remoteSessions.save(RemoteTokenResponse(accessToken: "test-access", refreshToken: "test-refresh", expiresIn: 900), for: "alice")
        try security.logout()
        XCTAssertNil(try remoteSessions.tokens(for: "alice"))
        XCTAssertTrue(try remoteSessions.revocationPending(for: "alice"))
        try security.login(userID: "alice", password: "password123", context: context)

        let friend = try LocalRepository(context: context).addFriend(owner: user, userID: "bob", nickname: "Bob",
                                                                     encryption: try security.encryptionService())
        XCTAssertEqual(friend.nickname, "")
        XCTAssertNotNil(friend.encryptedProfile)
        XCTAssertEqual(try security.friendProfile(friend, context: context).nickname, "Bob")
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
        let friend = try LocalRepository(context: context).addFriend(owner: user, userID: "bob", nickname: "Bob",
                                                                     encryption: try security.encryptionService())
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
        XCTAssertFalse(String(data: backup, encoding: .utf8)?.contains("Alice") ?? false)
        XCTAssertFalse(String(data: backup, encoding: .utf8)?.contains("Bob") ?? false)
        XCTAssertThrowsError(try manager.restore(backup, password: "wrong-secret", into: user))
        let original = try XCTUnwrap(context.fetch(FetchDescriptor<Message>()).first)
        try chat.edit(original, text: "已修改")
        try manager.restore(backup, password: "backup-secret", into: user)
        XCTAssertEqual(user.userIDHMAC, try LocalRepository.userIDHMAC("alice"))
        XCTAssertEqual(try security.userProfile(user, context: context).nickname, "Alice")
        XCTAssertEqual(user.nickname, "")
        let restoredFriend = try XCTUnwrap(context.fetch(FetchDescriptor<Friend>()).first)
        XCTAssertEqual(try security.friendProfile(restoredFriend, context: context).nickname, "Bob")
        XCTAssertEqual(restoredFriend.nickname, "")
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
        do {
            try await queue.drain(prepare: { _, _ in throw V4VaultError.pendingOperation },
                send: { _, _ in XCTFail("An incomplete receiving transaction must block transmission") })
            XCTFail("Expected receiving transaction to block preparation")
        } catch V4VaultError.pendingOperation { }
        XCTAssertEqual(item.attempts, 0, "Local crypto contention must not exhaust network retries")
        XCTAssertEqual(item.state, "pending")
        XCTAssertFalse(item.prepared)
        item.nextAttemptAt = .distantPast
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
        item.attempts = 5; item.state = "failed"; item.nextAttemptAt = .distantPast
        try context.save()
        try await queue.drain(prepare: { _, _ in XCTFail("Failed initial message must preserve order"); return Data() },
                              send: { _, _ in XCTFail("Later message bypassed the failed initial envelope") })
        item.attempts = 1; item.state = "pending"
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

        // Cleanup can run while the upload response is in flight. Its completion
        // must not recreate queue state or overwrite an identity-change failure.
        for outcome in ["identityChanged", "deleted", "revoked", "read"] {
            let late = Message(conversationID: UUID(), type: .text, isMine: true)
            late.deliveryStatus = .sending
            context.insert(late)
            let queued = try queue.enqueue(messageID: late.id, request: Data("pending".utf8))
            try context.save()
            do {
                try await queue.drain(prepare: { _, data in data }, send: { _, _ in
                    switch outcome {
                    case "deleted": context.delete(queued)
                    case "read": late.deliveryStatus = .read
                    case "revoked": queued.state = "failed"; queued.attempts = 5; late.deliveryStatus = .failed
                    default: queued.state = "identityChanged"; late.deliveryStatus = .failed
                    }
                    try context.save()
                })
                XCTAssertEqual(outcome, "read", "Late success must preserve cleanup and trust revocation")
            } catch { XCTAssertNotEqual(outcome, "read") }
            XCTAssertEqual(late.deliveryStatus, outcome == "read" ? .read : outcome == "deleted" ? .sending : .failed)
            if outcome == "identityChanged" || outcome == "revoked" {
                XCTAssertEqual(queued.state, outcome == "revoked" ? "failed" : "identityChanged")
                context.delete(queued)
                try context.save()
            }
        }
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
        let keychain = KeychainManager(service: "app.luma.identity-trust.\(UUID())")
        defer { try? keychain.deleteAccounts(prefix: "") }
        let security = SecurityManager(keychain: keychain)
        let name = "identity_" + UUID().uuidString.prefix(8).lowercased()
        try security.register(userID: name, nickname: "Alice", password: "password123", context: context)
        try security.setPIN("123456", context: context)
        let user = try XCTUnwrap(LocalRepository(context: context).user(name))
        let friend = Friend(ownerID: user.id, userID: "bob", nickname: "Bob")
        let old = P256.Signing.PrivateKey().publicKey.x963Representation
        let replacement = P256.Signing.PrivateKey().publicKey.x963Representation
        friend.identityFingerprint = IdentityFingerprint.make(publicKey: old)
        let remoteID = UUID()
        friend.remoteUserID = remoteID
        context.insert(friend)
        context.insert(SessionKey(friendID: friend.id, keyVersion: 1, ownerID: user.id))
        let conversation = Conversation(ownerID: user.id, friendID: friend.id)
        let message = Message(conversationID: conversation.id, type: .text, isMine: true, senderID: user.userID)
        message.deliveryStatus = .sending
        message.ciphertext = try security.encryptionService().encrypt(Data("pending".utf8), authenticatedData:
            Data("luma-message-v1|\(message.id.uuidString)|\(conversation.id.uuidString)".utf8)).bytes
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
        let repository = RemoteMessageRepository(context: context, user: user, security: security,
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
        security.lock()
        XCTAssertThrowsError(try repository.trustIdentity(IdentityFingerprint.make(publicKey: replacement), for: friend))
        XCTAssertEqual(friend.identityFingerprint, IdentityFingerprint.make(publicKey: old))
        try security.verifyPIN("123456", context: context)
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

    func testLegacyRoutingCannotMutateV4Messages() throws {
        let context = try makeContext()
        let user = User(userID: "alice", nickname: "Alice", passwordHash: "verifier")
        let friend = Friend(ownerID: user.id, userID: "bob", nickname: "Bob")
        friend.remoteUserID = UUID()
        let conversation = Conversation(ownerID: user.id, friendID: friend.id)
        conversation.remoteID = UUID()
        let message = Message(conversationID: conversation.id, type: .text, isMine: true, senderID: user.userID)
        message.transportEncryptionVersion = 4; message.remoteRevision = 1
        message.deliveryStatus = .sent
        let registration = RemoteRegistration(backendUserID: UUID(), backendDeviceID: UUID(),
            baseURL: URL(string: "https://example.invalid")!)
        let peerDevice = UUID(), ownOtherDevice = UUID()
        context.insert(user); context.insert(friend); context.insert(conversation); context.insert(message)
        context.insert(V4SessionMetadata(ownerID: user.id, friendID: friend.id,
            localDeviceID: registration.backendDeviceID, remoteDeviceID: peerDevice))
        context.insert(V4SessionMetadata(ownerID: user.id, friendID: nil,
            localDeviceID: registration.backendDeviceID, remoteDeviceID: ownOtherDevice))
        try context.save()
        let repository = RemoteMessageRepository(context: context, user: user, security: SecurityManager(),
            client: try RemoteAPIClient(baseURL: registration.baseURL, userID: user.userID), registration: registration)
        for kind in ["message.read", "message.deleted"] {
            let isRead = kind == "message.read"
            let event = RemoteSyncEvent(eventID: UUID(), deviceSeq: 1, type: kind, payloadCiphertext: "",
                routing: RemoteEventRouting(messageID: message.id, conversationID: conversation.remoteID,
                    senderDeviceID: isRead ? peerDevice : ownOtherDevice,
                    senderUserID: isRead ? friend.remoteUserID : registration.backendUserID,
                    encryptionVersion: nil, keyVersion: nil, messageKeyIndex: nil,
                    revision: isRead ? nil : 2, recipientDeviceID: peerDevice,
                    revokedDeviceID: nil, mutationEventID: nil), createdAt: "2026-10-23T00:00:00Z")
            XCTAssertThrowsError(try repository.apply(event), "Unauthenticated routing cannot apply \(kind) to v4")
            XCTAssertFalse(message.deleted)
            XCTAssertNil(message.readAt)
            XCTAssertEqual(message.deliveryStatus, .sent)
            XCTAssertEqual(message.remoteRevision, 1)
        }
        let delivered = RemoteSyncEvent(eventID: UUID(), deviceSeq: 1, type: "message.delivered", payloadCiphertext: "",
            routing: RemoteEventRouting(messageID: message.id, conversationID: conversation.remoteID,
                senderDeviceID: peerDevice, senderUserID: friend.remoteUserID, encryptionVersion: nil,
                keyVersion: nil, messageKeyIndex: nil, revision: nil, recipientDeviceID: peerDevice,
                revokedDeviceID: nil, mutationEventID: nil), createdAt: "2026-10-23T00:00:00Z")
        try repository.apply(delivered)
        XCTAssertEqual(message.deliveryStatus, .delivered)
        XCTAssertNil(message.readAt, "Server delivery hints must not become authenticated read receipts")
        message.transportEncryptionVersion = 3
        let legacyDelete = RemoteSyncEvent(eventID: UUID(), deviceSeq: 2, type: "message.deleted", payloadCiphertext: "",
            routing: RemoteEventRouting(messageID: message.id, conversationID: conversation.remoteID,
                senderDeviceID: ownOtherDevice, senderUserID: registration.backendUserID, encryptionVersion: nil,
                keyVersion: nil, messageKeyIndex: nil, revision: 2, recipientDeviceID: nil,
                revokedDeviceID: nil, mutationEventID: nil), createdAt: "2026-10-23T00:00:00Z")
        try repository.apply(legacyDelete)
        try repository.apply(legacyDelete)
        XCTAssertFalse(message.deleted, "Unsigned legacy routing cannot authorize deletion")
        XCTAssertEqual(message.remoteRevision, 1)
        let legacyRead = RemoteSyncEvent(eventID: UUID(), deviceSeq: 3, type: "message.read", payloadCiphertext: "",
            routing: delivered.routing, createdAt: "2026-10-23T00:00:00Z")
        try repository.apply(legacyRead)
        XCTAssertNil(message.readAt, "Unsigned legacy routing cannot prove that a peer read a message")
    }

    func testAttachmentDownloadRechecksLockAndDeletionBeforeCaching() async throws {
        let context = try makeContext()
        let keychain = KeychainManager(service: "app.luma.attachment-race.\(UUID())")
        let security = SecurityManager(keychain: keychain)
        try security.register(userID: "attachment_test", nickname: "Alice", password: "password123", context: context)
        try security.setPIN("123456", context: context)
        let user = try XCTUnwrap(LocalRepository(context: context).user("attachment_test"))
        let friend = Friend(ownerID: user.id, userID: "bob", nickname: "Bob")
        let conversation = Conversation(ownerID: user.id, friendID: friend.id)
        conversation.remoteID = UUID()
        context.insert(friend); context.insert(conversation)
        let registration = RemoteRegistration(backendUserID: UUID(), backendDeviceID: UUID(),
            baseURL: URL(string: "https://attachment.example.invalid")!)
        let store = RemoteSessionStore(keychain: keychain)
        let signer = RemoteDeviceSigner(keychain: keychain)
        _ = try signer.publicKey(for: user.userID)
        try store.save(RemoteTokenResponse(accessToken: "test-access", refreshToken: "test-refresh", expiresIn: 900), for: user.userID)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            try? FileTransferService.purgeAccount(ownerID: user.id)
            try? keychain.deleteAccounts(prefix: "")
        }
        let client = try RemoteAPIClient(baseURL: registration.baseURL, userID: user.userID,
            store: store, signer: signer, session: session)
        let repository = RemoteMessageRepository(context: context, user: user, security: security,
            client: client, registration: registration)
        for scenario in ["locked", "deleted", "available"] {
            let encryption = try security.encryptionService()
            let message = Message(conversationID: conversation.id, type: .file, isMine: false)
            message.transportEncryptionVersion = 4
            message.ciphertext = try encryption.encrypt(Data("[file]".utf8), authenticatedData:
                Data("luma-message-v1|\(message.id.uuidString)|\(conversation.id.uuidString)".utf8)).bytes
            let attachment = Attachment(messageID: message.id, type: .file, path: "")
            let descriptor = V4AttachmentCrypto.makeDescriptor(attachmentID: attachment.id,
                messageID: message.id, conversationID: conversation.remoteID!, type: .file, name: "private.pdf")
            let content = Data("confidential attachment".utf8)
            let sealed = try V4AttachmentCrypto.encrypt(content, descriptor: descriptor)
            let uploaded = descriptor.withUpload(id: UUID(), hash: Data(SHA256.hash(data: sealed.bytes)))
            context.insert(message); context.insert(attachment)
            try PrivateMetadataStore(context: context, encryption: encryption).saveAttachmentMetadata(
                .init(name: descriptor.name, encryptedPath: nil, metadata: JSONEncoder().encode(uploaded)), for: attachment)
            HeldResponseURLProtocol.reset(sealed.bytes)
            let download = Task { try await repository.downloadAttachment(for: message) }
            for _ in 0..<100 where !HeldResponseURLProtocol.isWaiting {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(HeldResponseURLProtocol.isWaiting)
            if scenario == "locked" { security.lock() }
            if scenario == "deleted" {
                message.deleted = true
                context.delete(attachment)
                try context.save()
            }
            HeldResponseURLProtocol.complete()
            let files = FileTransferService(ownerID: user.id, encryption: encryption)
            if scenario == "available" {
                let result = try await download.value
                XCTAssertEqual(result.0, content)
                XCTAssertEqual(try files.download(attachmentID: attachment.id), content)
            } else {
                do { _ = try await download.value; XCTFail("Late download must fail when \(scenario)") }
                catch { }
                XCTAssertThrowsError(try files.download(attachmentID: attachment.id))
            }
            if scenario == "locked" { try security.verifyPIN("123456", context: context) }
        }
    }
    func testV4ReceiveRechecksTrustAfterDirectoryLookup() async throws {
        struct Request: Decodable {
            struct Recipient: Decodable { let ciphertext: String }
            let recipientEnvelopes: [Recipient]
        }
        let context = try makeContext()
        let keychain = KeychainManager(service: "app.luma.directory-race.\(UUID())")
        let security = SecurityManager(keychain: keychain)
        let name = "directory_" + UUID().uuidString.prefix(8).lowercased()
        try security.register(userID: name, nickname: "Alice", password: "password123", context: context)
        try security.setPIN("123456", context: context)
        let user = try XCTUnwrap(LocalRepository(context: context).user(name))
        let otherName = "other_" + UUID().uuidString.prefix(8).lowercased()
        let peerAccount = P256.Signing.PrivateKey(), peerUser = UUID()
        let fingerprint = IdentityFingerprint.make(publicKey: peerAccount.publicKey.x963Representation)
        let friend = Friend(ownerID: user.id, userID: "bob", nickname: "Bob")
        friend.remoteUserID = peerUser; friend.identityFingerprint = fingerprint
        let conversation = Conversation(ownerID: user.id, friendID: friend.id)
        conversation.remoteID = UUID()
        context.insert(friend); context.insert(conversation)
        let registration = RemoteRegistration(backendUserID: UUID(), backendDeviceID: UUID(),
            baseURL: URL(string: "https://directory.example.invalid")!)
        let store = RemoteSessionStore(keychain: keychain), signer = RemoteDeviceSigner(keychain: keychain)
        _ = try signer.publicKey(for: name)
        try store.save(RemoteTokenResponse(accessToken: "test-access", refreshToken: "test-refresh", expiresIn: 900), for: name)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let vault = V4SessionVault()
        let senderVault = V4SessionVault(keychain: keychain)
        defer {
            session.invalidateAndCancel()
            try? vault.purgeAccount(userID: name)
            try? keychain.deleteAccounts(prefix: "")
        }
        let client = try RemoteAPIClient(baseURL: registration.baseURL, userID: name,
            store: store, signer: signer, session: session)
        let repository = RemoteMessageRepository(context: context, user: user, security: security,
            client: client, registration: registration)
        let ownIdentity = V4IdentityKeys(), ownSigned = Curve25519.KeyAgreement.PrivateKey()
        let ownBundle = try V4Handshake.bundle(deviceID: registration.backendDeviceID, version: 1,
            identity: ownIdentity, signedPreKey: ownSigned, oneTimePreKey: nil)
        // A distinct initial session per scenario avoids replacing any committed ratchet.
        for kind in ["message.created", "message.edited"] {
            for scenario in ["identityChanged", "fingerprintChanged", "locked", "accountChanged", "available", "relabeledEdit"] {
                if scenario == "relabeledEdit" && kind != "message.created" { continue }
                try vault.saveDevice(.init(formatVersion: 1, deviceID: registration.backendDeviceID, keyVersion: 1,
                    identityAgreement: ownIdentity.agreement.rawRepresentation,
                    identitySigning: ownIdentity.signing.rawRepresentation,
                    signedPreKey: ownSigned.rawRepresentation, oneTimePreKeys: [:]), userID: name)
                let peerDevice = UUID(), peerIdentity = V4IdentityKeys(), peerSigned = Curve25519.KeyAgreement.PrivateKey()
                let bundle = try V4Handshake.bundle(deviceID: peerDevice, version: 1,
                    identity: peerIdentity, signedPreKey: peerSigned, oneTimePreKey: nil)
                try senderVault.saveDevice(.init(formatVersion: 1, deviceID: peerDevice, keyVersion: 1,
                    identityAgreement: peerIdentity.agreement.rawRepresentation,
                    identitySigning: peerIdentity.signing.rawRepresentation,
                    signedPreKey: peerSigned.rawRepresentation, oneTimePreKeys: [:]), userID: "sender")
                let binding = V4Handshake.fields("luma.v4.binding", [Data(peerDevice.uuidString.lowercased().utf8),
                    Data("1".utf8), bundle.identityAgreementPublicKey, bundle.identitySigningPublicKey])
                let directory: [[String: Any]] = [["accountIdentityPublicKey": peerAccount.publicKey.x963Representation.base64URLEncodedString(),
                    "deviceID": peerDevice.uuidString, "keyVersion": 1,
                    "identityAgreementPublicKey": bundle.identityAgreementPublicKey.base64URLEncodedString(),
                    "identitySigningPublicKey": bundle.identitySigningPublicKey.base64URLEncodedString(),
                    "identityBindingSignature": try peerAccount.signature(for: binding).derRepresentation.base64URLEncodedString(),
                    "signedPreKeyPublicKey": bundle.signedPreKeyPublicKey.base64URLEncodedString(),
                    "signedPreKeySignature": bundle.signedPreKeySignature.base64URLEncodedString(), "oneTimePreKeyPublicKey": ""]]
                let message = Message(conversationID: conversation.id, type: .text, isMine: false, senderID: friend.userID)
                message.transportEncryptionVersion = 4; message.remoteRevision = 1
                message.ciphertext = try security.encryptionService().encrypt(Data("original".utf8), authenticatedData:
                    Data("luma-message-v1|\(message.id.uuidString)|\(conversation.id.uuidString)".utf8)).bytes
                let eventID = UUID(), mutationID = UUID()
                let payload: Data
                if kind == "message.edited" {
                    context.insert(message)
                    payload = try JSONEncoder().encode(V4EventEnvelope(eventID: mutationID, messageID: message.id,
                        conversationID: conversation.remoteID!, actorUserID: peerUser, actorDeviceID: peerDevice,
                        kind: .edit, revision: 2, text: "changed", reactionAction: nil, occurredAt: .now))
                } else {
                    var body: [String: Any] = ["kind": "text", "senderUserID": friend.userID,
                        "targetUserID": name, "text": "received"]
                    if scenario == "relabeledEdit" { body["revision"] = 2 }
                    payload = try JSONSerialization.data(withJSONObject: body)
                }
                try context.save()
                let sender = V4MessageSessionService(vault: senderVault, userID: "sender", localDeviceID: peerDevice)
                let request = try sender.prepare(payload, messageID: kind == "message.created" ? message.id : mutationID,
                    conversationID: conversation.remoteID!, targets: [.init(remoteUserID: registration.backendUserID, bundle: ownBundle)])
                try sender.commitPreparedSend(messageID: kind == "message.created" ? message.id : mutationID)
                let wire = try XCTUnwrap(JSONDecoder().decode(Request.self, from: request).recipientEnvelopes.first).ciphertext
                let envelope = try JSONDecoder().decode(V4RatchetMessage.self, from: XCTUnwrap(Data(base64URL: wire)))
                let event = RemoteSyncEvent(eventID: eventID, deviceSeq: 1, type: kind, payloadCiphertext: wire,
                    routing: .init(messageID: message.id, conversationID: conversation.remoteID, senderDeviceID: peerDevice,
                        senderUserID: peerUser, encryptionVersion: 4, keyVersion: 1, messageKeyIndex: Int64(envelope.messageIndex),
                        revision: kind == "message.created" ? 1 : 2, recipientDeviceID: registration.backendDeviceID,
                        revokedDeviceID: nil, mutationEventID: kind == "message.created" ? nil : mutationID), createdAt: "2026-10-23T00:00:00Z")
                HeldResponseURLProtocol.reset(try JSONSerialization.data(withJSONObject: directory), suffix: "/v4-prekey-bundle")
                let receive = Task { try await repository.applyV4(event) }
                for _ in 0..<100 where !HeldResponseURLProtocol.isWaiting { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertTrue(HeldResponseURLProtocol.isWaiting)
                if scenario == "identityChanged" { friend.sessionStatus = "identityKeyChanged" }
                if scenario == "fingerprintChanged" { friend.identityFingerprint = "replacement" }
                if scenario == "locked" { security.lock() }
                if scenario == "accountChanged" {
                    if try LocalRepository(context: context).user(otherName) == nil {
                        try security.register(userID: otherName, nickname: "Other", password: "password123", context: context)
                        try security.setPIN("654321", context: context)
                    } else { try security.login(userID: otherName, password: "password123", context: context) }
                }
                HeldResponseURLProtocol.complete()
                if scenario == "available" {
                    try await receive.value
                    if kind == "message.created" {
                        try await repository.applyV4(event)
                        var altered = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64URL: wire))) as? [String: Any])
                        altered["ciphertext"] = Data(repeating: 0, count: 32).base64EncodedString()
                        let alteredWire = try JSONSerialization.data(withJSONObject: altered).base64URLEncodedString()
                        for (bytes, seq) in [(alteredWire, event.deviceSeq), (wire, event.deviceSeq + 1)] {
                            let replay = RemoteSyncEvent(eventID: event.eventID, deviceSeq: seq,
                                type: event.type, payloadCiphertext: bytes, routing: event.routing, createdAt: event.createdAt)
                            do { try await repository.applyV4(replay); XCTFail("Pending replay must bind bytes and sequence") }
                            catch { XCTAssertEqual(error as? V4ProtocolError, .replay) }
                        }
                        XCTAssertEqual(try vault.incomingPending(userID: name,
                            deviceID: registration.backendDeviceID)?.eventID, eventID)
                    }
                    try repository.context.save()
                    try V4MessageSessionService(vault: vault, userID: name, localDeviceID: registration.backendDeviceID)
                        .finishReceived(eventID: eventID)
                    let saved = try XCTUnwrap(context.fetch(FetchDescriptor<Message>()).first { $0.id == message.id })
                    XCTAssertEqual(try MessageStore(context: context, encryption: security.encryptionService()).displayContent(for: saved),
                        kind == "message.created" ? "received" : "changed")
                    if kind == "message.created" {
                        let prekeys = V4PreKeyService(context: context, user: user, registration: registration,
                            client: client, vault: vault)
                        for hasOneTimeKey in [false, true] {
                            var claimedDirectory = directory
                            if hasOneTimeKey {
                                claimedDirectory[0]["oneTimePreKeyPublicKey"] = Curve25519.KeyAgreement.PrivateKey()
                                    .publicKey.rawRepresentation.base64URLEncodedString()
                            }
                            HeldResponseURLProtocol.reset(try JSONSerialization.data(withJSONObject: claimedDirectory),
                                suffix: "/v4-prekey-bundle")
                            let claimed = Task { try await prekeys.bundles(for: peerUser,
                                expectedAccountFingerprint: fingerprint, claim: true) }
                            for _ in 0..<100 where !HeldResponseURLProtocol.isWaiting { try await Task.sleep(for: .milliseconds(10)) }
                            XCTAssertTrue(HeldResponseURLProtocol.isWaiting)
                            HeldResponseURLProtocol.complete()
                            if hasOneTimeKey {
                                let bundles = try await claimed.value
                                XCTAssertEqual(bundles.count, 1)
                            }
                            else {
                                do { _ = try await claimed.value; XCTFail("New remote sessions require an OTP") }
                                catch { XCTAssertEqual(error as? V4ProtocolError, .invalidPreKey) }
                            }
                        }
                    }
                } else if scenario == "relabeledEdit" {
                    do { try await receive.value; XCTFail("An authenticated legacy edit is not a creation") }
                    catch { XCTAssertEqual(error as? V4ProtocolError, .invalidMessage) }
                    XCTAssertFalse(try context.fetch(FetchDescriptor<Message>()).contains { $0.id == message.id })
                    XCTAssertEqual(try vault.incomingPending(userID: name,
                        deviceID: registration.backendDeviceID)?.eventID, eventID,
                        "Rejecting invalid content must retain its recovery journal")
                } else {
                    do { try await receive.value; XCTFail("Late \(kind) must reject \(scenario)") } catch { }
                    XCTAssertTrue(try vault.incomingPending(userID: name, deviceID: registration.backendDeviceID) == nil)
                    XCTAssertTrue(try vault.loadSession(userID: name, local: registration.backendDeviceID, remote: peerDevice) == nil)
                    if kind == "message.created" {
                        XCTAssertFalse(try context.fetch(FetchDescriptor<Message>()).contains { $0.id == message.id })
                    } else { XCTAssertEqual(message.remoteRevision, 1) }
                }
                friend.sessionStatus = "none"
                friend.identityFingerprint = fingerprint
                if scenario == "locked" { try security.verifyPIN("123456", context: context) }
                if scenario == "accountChanged" { try security.login(userID: name, password: "password123", context: context) }
                try vault.purgeAccount(userID: name)
            }
        }
    }

    // MARK: - v3 device envelope
    func testV3SignedRevisionCannotBeRelabeledAsCreation() async throws {
        let context = try makeContext()
        let keychain = KeychainManager(service: "app.luma.v3-routing.\(UUID())")
        let security = SecurityManager(keychain: keychain)
        let name = "v3_" + UUID().uuidString.prefix(8).lowercased()
        try security.register(userID: name, nickname: "Alice", password: "password123", context: context)
        try security.setPIN("123456", context: context)
        let user = try XCTUnwrap(LocalRepository(context: context).user(name))
        let device = try XCTUnwrap(context.fetch(FetchDescriptor<Device>()).first { $0.ownerID == user.id })
        let wireKeychain = KeychainManager()
        let deviceKey = P256.KeyAgreement.PrivateKey(), signedKey = P256.KeyAgreement.PrivateKey()
        let signed = PreKeyMetadata(ownerID: user.id, type: "signed", publicKey: signedKey.publicKey.x963Representation,
            fingerprint: IdentityFingerprint.make(publicKey: signedKey.publicKey.x963Representation))
        try wireKeychain.save(deviceKey.rawRepresentation, account: "device-private.\(device.id.uuidString)")
        try wireKeychain.save(signedKey.rawRepresentation, account: "prekey.\(user.id.uuidString).\(signed.id.uuidString)")
        context.insert(signed)
        defer {
            try? keychain.deleteAccounts(prefix: "")
            try? wireKeychain.delete("device-private.\(device.id.uuidString)")
            try? wireKeychain.deleteAccounts(prefix: "prekey.\(user.id.uuidString).")
            try? wireKeychain.delete("identity-private.\(name)")
        }
        let peer = P256.Signing.PrivateKey()
        let friend = Friend(ownerID: user.id, userID: "bob", nickname: "Bob")
        friend.identityFingerprint = IdentityFingerprint.make(publicKey: peer.publicKey.x963Representation)
        let conversation = Conversation(ownerID: user.id, friendID: friend.id)
        conversation.remoteID = UUID()
        context.insert(friend); context.insert(conversation); try context.save()
        let registration = RemoteRegistration(backendUserID: UUID(), backendDeviceID: UUID(),
            baseURL: URL(string: "https://example.invalid")!)
        let repository = RemoteMessageRepository(context: context, user: user, security: security,
            client: try RemoteAPIClient(baseURL: registration.baseURL, userID: name), registration: registration)
        let target = VerifiedDeviceBundle(deviceID: registration.backendDeviceID, identityPublicKey: user.identityPublicKey!,
            devicePublicKey: deviceKey.publicKey.x963Representation, signedPreKey: signed.publicKey,
            oneTimePreKey: nil, keyVersion: 1)
        let messageID = UUID(), senderDevice = UUID()
        func event(_ type: String, signedRevision: Int?, routingRevision: Int?) throws -> RemoteSyncEvent {
            var body: [String: Any] = ["kind": "text", "senderUserID": "bob", "targetUserID": name, "text": "content"]
            if let signedRevision { body["revision"] = signedRevision }
            let envelope = try DeviceSessionManager().encrypt(JSONSerialization.data(withJSONObject: body),
                messageID: messageID, conversationID: conversation.remoteID!, senderDeviceID: senderDevice,
                senderIdentityPrivateKey: peer, recipient: target)
            return RemoteSyncEvent(eventID: UUID(), deviceSeq: 1, type: type,
                payloadCiphertext: try JSONEncoder().encode(envelope).base64URLEncodedString(),
                routing: .init(messageID: messageID, conversationID: conversation.remoteID, senderDeviceID: senderDevice,
                    senderUserID: nil, encryptionVersion: 3, keyVersion: 1, messageKeyIndex: envelope.messageKeyIndex,
                    revision: routingRevision, recipientDeviceID: nil, revokedDeviceID: nil, mutationEventID: nil),
                createdAt: "2026-10-23T00:00:00Z")
        }
        XCTAssertThrowsError(try repository.apply(event("message.created", signedRevision: 2, routingRevision: 1)))
        XCTAssertFalse(try context.fetch(FetchDescriptor<Message>()).contains { $0.id == messageID })
        let creation = try event("message.created", signedRevision: nil, routingRevision: 1)
        try repository.apply(creation)
        var forgedEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with:
            XCTUnwrap(Data(base64URL: creation.payloadCiphertext))) as? [String: Any])
        forgedEnvelope["recipientOneTimePreKey"] = Data(repeating: 7, count: 65).base64EncodedString()
        let forgedReplay = RemoteSyncEvent(eventID: creation.eventID, deviceSeq: creation.deviceSeq,
            type: creation.type, payloadCiphertext: try JSONSerialization.data(withJSONObject: forgedEnvelope).base64URLEncodedString(),
            routing: creation.routing, createdAt: creation.createdAt)
        XCTAssertThrowsError(try repository.apply(forgedReplay),
            "A duplicate event ID must not skip verification of altered prekey material")
        try repository.apply(event("message.edited", signedRevision: 2, routingRevision: 2))
        let saved = try XCTUnwrap(context.fetch(FetchDescriptor<Message>()).first { $0.id == messageID })
        XCTAssertEqual(saved.remoteRevision, 2)
        XCTAssertNotNil(saved.editedAt)

        // Exercise both remaining legacy send operations while the directory is
        // suspended. Reuse the same network fixture and real account/key material.
        let peerUser = UUID()
        friend.remoteUserID = peerUser
        try wireKeychain.save(keychain.readRequired("identity-private.\(name)"), account: "identity-private.\(name)")
        let own = Message(conversationID: conversation.id, type: .text, isMine: true, senderID: name)
        own.transportEncryptionVersion = 3; own.remoteRevision = 1
        own.ciphertext = try security.encryptionService().encrypt(Data("original".utf8),
            authenticatedData: Data("luma-message-v1|\(own.id.uuidString)|\(conversation.id.uuidString)".utf8)).bytes
        context.insert(own); try context.save()
        let sessionStore = RemoteSessionStore(keychain: keychain), signer = RemoteDeviceSigner(keychain: keychain)
        _ = try signer.publicKey(for: name)
        try sessionStore.save(.init(accessToken: "test-access", refreshToken: "test-refresh", expiresIn: 900), for: name)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldResponseURLProtocol.self]
        let network = URLSession(configuration: config)
        defer { network.invalidateAndCancel() }
        let online = RemoteMessageRepository(context: context, user: user, security: security,
            client: try RemoteAPIClient(baseURL: registration.baseURL, userID: name,
                store: sessionStore, signer: signer, session: network), registration: registration)
        func directory(_ account: P256.Signing.PrivateKey, deviceID: UUID) throws -> Data {
            let prekey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
            return try JSONSerialization.data(withJSONObject: [[
                "identityPublicKey": account.publicKey.x963Representation.base64URLEncodedString(),
                "identityKeyVersion": 1, "deviceID": deviceID.uuidString,
                "devicePublicKey": deviceKey.publicKey.x963Representation.base64URLEncodedString(),
                "signedPreKey": prekey.base64URLEncodedString(), "signature": try account.signature(for: prekey).derRepresentation.base64URLEncodedString(),
                "keyVersion": 1, "oneTimePreKey": signedKey.publicKey.x963Representation.base64URLEncodedString()
            ]])
        }
        let peerPath = "/v1/users/\(peerUser.uuidString.lowercased())/prekey-bundle"
        let peerDirectory = try directory(peer, deviceID: senderDevice)
        let responses = ["/v1/friends": try JSONSerialization.data(withJSONObject: [[
            "id": peerUser.uuidString, "userID": friend.userID, "nickname": "Bob"]]),
            "/v1/users/\(registration.backendUserID.uuidString.lowercased())/prekey-bundle":
                try directory(P256.Signing.PrivateKey(rawRepresentation: keychain.readRequired("identity-private.\(name)")),
                    deviceID: registration.backendDeviceID),
            "/v1/messages/edit": Data("{\"revision\":2}".utf8), "/v1/messages/reaction": Data("{}".utf8)]
        for operation in ["edit", "reaction"] {
            for scenario in ["identityChanged", "locked", "available"] {
                HeldResponseURLProtocol.reset(peerDirectory, suffix: peerPath,
                    responses: responses)
                let mutation = Task {
                    if operation == "edit" { try await online.editText("updated", message: own, friend: friend, conversation: conversation) }
                    else { try await online.react("👍", to: own, friend: friend, conversation: conversation) }
                }
                for _ in 0..<100 where !HeldResponseURLProtocol.isWaiting { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertTrue(HeldResponseURLProtocol.isWaiting)
                if scenario == "identityChanged" { friend.sessionStatus = "identityKeyChanged" }
                if scenario == "locked" { security.lock() }
                HeldResponseURLProtocol.complete()
                if scenario == "available" { try await mutation.value }
                else { do { try await mutation.value; XCTFail("Legacy send accepted stale authorization") } catch { } }
                XCTAssertEqual(HeldResponseURLProtocol.paths.contains("/v1/messages/\(operation)"), scenario == "available")
                friend.sessionStatus = "none"
                if scenario == "locked" { try security.verifyPIN("123456", context: context) }
            }
        }
    }

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

    func testV4DeviceDirectoryPinsSurviveReopenAndRejectRollback() throws {
        let keychain = KeychainManager(service: "app.luma.v4-directory-pin.\(UUID())")
        defer { try? keychain.deleteAccounts(prefix: "") }
        let local = UUID(), remote = UUID(), remoteUser = UUID(), identity = V4IdentityKeys()
        let old = try V4Handshake.bundle(deviceID: remote, version: 1, identity: identity,
            signedPreKey: Curve25519.KeyAgreement.PrivateKey(), oneTimePreKey: nil)
        let current = try V4Handshake.bundle(deviceID: remote, version: 2, identity: identity,
            signedPreKey: Curve25519.KeyAgreement.PrivateKey(), oneTimePreKey: nil)
        let vault = V4SessionVault(keychain: keychain)
        try vault.observePeerBundle(old, remoteUserID: remoteUser, userID: "alice", local: local)
        try vault.observePeerBundle(current, remoteUserID: remoteUser, userID: "alice", local: local)
        let reopened = V4SessionVault(keychain: keychain)
        try reopened.observePeerBundle(current, remoteUserID: remoteUser, userID: "alice", local: local)
        let sameVersionReplacement = try V4Handshake.bundle(deviceID: remote, version: 2, identity: identity,
            signedPreKey: Curve25519.KeyAgreement.PrivateKey(), oneTimePreKey: nil)
        let changedIdentity = try V4Handshake.bundle(deviceID: remote, version: 3, identity: V4IdentityKeys(),
            signedPreKey: Curve25519.KeyAgreement.PrivateKey(), oneTimePreKey: nil)
        for invalid in [old, sameVersionReplacement, changedIdentity] {
            XCTAssertThrowsError(try reopened.observePeerBundle(invalid, remoteUserID: remoteUser,
                userID: "alice", local: local))
        }
        XCTAssertNil(try reopened.loadSession(userID: "alice", local: local, remote: remote))
        // An explicitly reverified account may use a different device identity;
        // cleanup must not make unrelated device/account pins disappear.
        try reopened.discardPendingForRemoteUser(userID: "alice", localDeviceID: local, remoteUserID: remoteUser)
        try reopened.observePeerBundle(changedIdentity, remoteUserID: remoteUser, userID: "alice", local: local)
        XCTAssertThrowsError(try reopened.observePeerBundle(current, remoteUserID: remoteUser,
            userID: "alice", local: local))
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
        let blockedID = UUID()
        XCTAssertThrowsError(try restartedBob.prepare(Data("too early".utf8), messageID: blockedID,
            conversationID: conversationID, targets: [.init(remoteUserID: aliceUserID, bundle: aliceBundle)])) {
            XCTAssertEqual($0 as? V4VaultError, .pendingOperation)
        }
        XCTAssertEqual(try reopenedVault.incomingPending(userID: "bob", deviceID: bobID)?.eventID, firstEvent)
        XCTAssertNil(try reopenedVault.outgoingPending(userID: "bob", deviceID: bobID))
        try restartedBob.recoverReceived(committedCursor: 1)
        XCTAssertNil(try reopenedVault.incomingPending(userID: "bob", deviceID: bobID))
        XCTAssertNotNil(try vault.loadSession(userID: "bob", local: bobID, remote: aliceID))
        let replyID = UUID()
        let replyRequest = try V4MessageSessionService(vault: reopenedVault,
            userID: "bob", localDeviceID: bobID).prepare(Data("reply".utf8), messageID: replyID,
            conversationID: conversationID, targets: [.init(remoteUserID: aliceUserID, bundle: aliceBundle)])
        let followupID = UUID(), followupEvent = UUID()
        let followupRequest = try alice.prepare(Data("followup".utf8), messageID: followupID,
            conversationID: conversationID, targets: [.init(remoteUserID: bobUserID, bundle: bobBundle)])
        try alice.commitPreparedSend(messageID: followupID)
        let followupData = try XCTUnwrap(Data(base64URL: JSONDecoder().decode(Request.self, from: followupRequest)
            .recipientEnvelopes[0].ciphertext))
        let followup = try JSONDecoder().decode(V4RatchetMessage.self, from: followupData)
        XCTAssertThrowsError(try restartedBob.decrypt(followup, wire: followupData, eventID: followupEvent,
            deviceSeq: 2, senderUserID: aliceUserID, senderBundle: aliceBundle)) {
            XCTAssertEqual($0 as? V4VaultError, .pendingOperation)
        }
        XCTAssertNil(try reopenedVault.incomingPending(userID: "bob", deviceID: bobID))
        XCTAssertEqual(try reopenedVault.outgoingPending(userID: "bob", deviceID: bobID)?.messageID, replyID)
        try bob.commitPreparedSend(messageID: replyID)
        XCTAssertEqual(try restartedBob.decrypt(followup, wire: followupData, eventID: followupEvent,
            deviceSeq: 2, senderUserID: aliceUserID, senderBundle: aliceBundle), Data("followup".utf8))
        try restartedBob.recoverReceived(committedCursor: 2)
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

    /// Documents a release blocker: simultaneous first handshakes are rejected
    /// rather than silently replacing either established sending ratchet.
    func testSimultaneousInitialSessionsFailClosed() throws {
        struct Wire: Decodable {
            struct Recipient: Decodable { let ciphertext: String }
            let recipientEnvelopes: [Recipient]
        }
        let vault = V4SessionVault(keychain: KeychainManager(service: "app.luma.collision.\(UUID().uuidString)"))
        defer { try? vault.purgeAccount(userID: "alice"); try? vault.purgeAccount(userID: "bob") }
        let aliceID = UUID(), bobID = UUID(), aliceUser = UUID(), bobUser = UUID(), conversation = UUID()
        let aliceIdentity = V4IdentityKeys(), bobIdentity = V4IdentityKeys()
        let aliceSigned = Curve25519.KeyAgreement.PrivateKey(), bobSigned = Curve25519.KeyAgreement.PrivateKey()
        for (name, id, identity, signed) in [("alice", aliceID, aliceIdentity, aliceSigned), ("bob", bobID, bobIdentity, bobSigned)] {
            try vault.saveDevice(.init(formatVersion: 1, deviceID: id, keyVersion: 1,
                identityAgreement: identity.agreement.rawRepresentation,
                identitySigning: identity.signing.rawRepresentation, signedPreKey: signed.rawRepresentation,
                oneTimePreKeys: [:]), userID: name)
        }
        let aliceBundle = try V4Handshake.bundle(deviceID: aliceID, version: 1, identity: aliceIdentity, signedPreKey: aliceSigned, oneTimePreKey: nil)
        let bobBundle = try V4Handshake.bundle(deviceID: bobID, version: 1, identity: bobIdentity, signedPreKey: bobSigned, oneTimePreKey: nil)
        let alice = V4MessageSessionService(vault: vault, userID: "alice", localDeviceID: aliceID)
        let bob = V4MessageSessionService(vault: vault, userID: "bob", localDeviceID: bobID)
        let first = UUID(), second = UUID()
        let a = try alice.prepare(Data("first".utf8), messageID: first, conversationID: conversation,
            targets: [.init(remoteUserID: bobUser, bundle: bobBundle)])
        let b = try bob.prepare(Data("second".utf8), messageID: second, conversationID: conversation,
            targets: [.init(remoteUserID: aliceUser, bundle: aliceBundle)])
        try alice.commitPreparedSend(messageID: first); try bob.commitPreparedSend(messageID: second)
        let aBytes = try XCTUnwrap(Data(base64URL: JSONDecoder().decode(Wire.self, from: a).recipientEnvelopes[0].ciphertext))
        let bBytes = try XCTUnwrap(Data(base64URL: JSONDecoder().decode(Wire.self, from: b).recipientEnvelopes[0].ciphertext))
        XCTAssertThrowsError(try bob.decrypt(JSONDecoder().decode(V4RatchetMessage.self, from: aBytes),
            wire: aBytes, eventID: UUID(), deviceSeq: 1, senderUserID: aliceUser, senderBundle: aliceBundle))
        XCTAssertThrowsError(try alice.decrypt(JSONDecoder().decode(V4RatchetMessage.self, from: bBytes),
            wire: bBytes, eventID: UUID(), deviceSeq: 1, senderUserID: bobUser, senderBundle: bobBundle))
        XCTAssertEqual(try vault.loadSession(userID: "alice", local: aliceID, remote: bobID)?.stateVersion, 1)
        XCTAssertEqual(try vault.loadSession(userID: "bob", local: bobID, remote: aliceID)?.stateVersion, 1)
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

/// Returns synthetic tokens only; no external HTTP request leaves the test process.
private final class TokenRefreshURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var count = 0
    private static var requests = 0
    static var refreshCount: Int { lock.withLock { count } }
    static var requestCount: Int { lock.withLock { requests } }
    static func reset() { lock.withLock { count = 0; requests = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let refresh = request.url?.path == "/v1/auth/refresh"
        Self.lock.withLock { Self.requests += 1; if refresh { Self.count += 1 } }
        DispatchQueue.global().asyncAfter(deadline: .now() + (refresh || request.httpMethod == "PUT" ? 0.2 : 0)) { [self] in
            let body = refresh ? "{\"accessToken\":\"new-test-token\",\"refreshToken\":\"rotated-test-token\",\"expiresIn\":900}" : "{}"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// Holds a response until the test changes local security state.
private final class HeldResponseURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var payload = Data()
    private static var pending: HeldResponseURLProtocol?
    private static var suffix = "/content"
    private static var statusCode = 200
    private static var responses: [String: Data] = [:]
    private static var requestedPaths: [String] = []
    static var paths: [String] { lock.withLock { requestedPaths } }
    static var isWaiting: Bool { lock.withLock { pending != nil } }
    static func reset(_ bytes: Data, suffix: String = "/content", responses: [String: Data] = [:], statusCode: Int = 200) {
        lock.withLock {
            payload = bytes; pending = nil; Self.suffix = suffix
            Self.responses = responses; requestedPaths = []
            Self.statusCode = statusCode
        }
    }
    static func complete() {
        let response = lock.withLock { () -> (HeldResponseURLProtocol?, Data, Int) in
            let value = (pending, payload, statusCode)
            pending = nil
            return value
        }
        response.0?.respond(response.1, statusCode: response.2)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.requestedPaths.append(request.url!.path) }
        if Self.lock.withLock({ request.url!.path.hasSuffix(Self.suffix) }) {
            Self.lock.withLock { Self.pending = self }
        } else {
            let path = request.url!.path.replacingOccurrences(of: "/download", with: "/content")
            respond(Self.lock.withLock { Self.responses[request.url!.path] } ?? Data("{\"downloadPath\":\"\(path)\"}".utf8))
        }
    }
    private func respond(_ data: Data, statusCode: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode,
            httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.withLock { if Self.pending === self { Self.pending = nil } }
    }
}

private final class RevocationURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var seenPaths: [String] = []
    private static var revocations = 0
    private static var proofSeen = false
    static var paths: [String] { lock.withLock { seenPaths } }
    static var revokeHadDeviceProof: Bool { lock.withLock { proofSeen } }
    static func reset() { lock.withLock { seenPaths = []; revocations = 0; proofSeen = false } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let attempt = Self.lock.withLock { () -> Int in
            Self.seenPaths.append(path)
            if path == "/v1/auth/revoke" {
                Self.revocations += 1
                Self.proofSeen = Self.proofSeen || request.value(forHTTPHeaderField: "X-Device-Signature") != nil
            }
            return Self.revocations
        }
        let status: Int
        let body: String
        switch path {
        case "/v1/auth/challenge":
            status = 200
            body = "{\"challengeID\":\"\(UUID())\",\"nonce\":\"test-nonce\"}"
        case "/v1/auth/token":
            status = 200
            body = "{\"accessToken\":\"temporary-test-access\",\"refreshToken\":\"temporary-test-refresh\",\"expiresIn\":900}"
        case "/v1/auth/revoke" where attempt == 1:
            status = 503
            body = "{\"code\":\"storage_unavailable\"}"
        case "/v1/auth/revoke":
            status = 204
            body = ""
        default:
            status = 404
            body = "{}"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: Data(body.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
