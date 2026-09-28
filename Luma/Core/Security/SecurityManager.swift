import Foundation
import CryptoKit
import LocalAuthentication
import Observation
import SwiftData

enum AuthenticationError: LocalizedError {
    case invalidCredentials, incorrectPIN, noSession, biometricsUnavailable, pinNotConfigured
    var errorDescription: String? {
        switch self {
        case .invalidCredentials: "UserID 或密码错误"
        case .incorrectPIN: "PIN 不正确"
        case .noSession: "请使用 UserID 和密码登录"
        case .biometricsUnavailable: "此设备暂不可使用 Face ID"
        case .pinNotConfigured: "请先设置 PIN"
        }
    }
}

@MainActor @Observable
final class SecurityManager {
    enum Phase { case loading, registration, login, setupPIN, locked, unlocked }
    private(set) var phase: Phase = .loading
    private(set) var activeUserID: String?
    private(set) var preferences = PrivacyPreferences()
    var startupError: String?
    private let keychain: KeychainManager
    private let keys: KeyManager
    private let lifecycle: KeyLifecycleManager
    @ObservationIgnored private var unlockedKey: SymmetricKey?
    private let sessionAccount = "active-user-id"

    init(keychain: KeychainManager = KeychainManager()) {
        self.keychain = keychain
        self.keys = KeyManager(keychain: keychain)
        self.lifecycle = KeyLifecycleManager(keychain: keychain)
    }

    func restore(users: [User], context: ModelContext) {
        unlockedKey = nil
        do {
            try resumeAccountCleanup(context: context)
            let users = try context.fetch(FetchDescriptor<User>())
            if let data = try keychain.read(sessionAccount),
               let id = String(data: data, encoding: .utf8), users.contains(where: { $0.userID == id }) {
                activeUserID = id
                phase = try keychain.read(pinAccount(id)) == nil ? .login : .locked
            } else {
                phase = users.isEmpty ? .registration : .login
            }
        } catch {
            startupError = error.localizedDescription
            phase = users.isEmpty ? .registration : .login
        }
    }

    func showRegistration() { unlockedKey = nil; preferences = PrivacyPreferences(); phase = .registration }
    func showLogin() { unlockedKey = nil; preferences = PrivacyPreferences(); phase = .login }

    func register(userID: String, nickname: String, password: String, context: ModelContext) throws {
        let hash = try PasswordHasher.hash(password)
        let user = try LocalRepository(context: context).createUser(userID: userID, nickname: nickname, passwordHash: hash, persist: false)
        do { try lifecycle.provisionNewAccount(user, context: context) }
        catch {
            try? lifecycle.deleteKeys(for: user, context: context)
            context.delete(user)
            try? context.save()
            throw error
        }
        try establishSession(for: user.userID)
        phase = .setupPIN
    }

    func login(userID: String, password: String, context: ModelContext) throws {
        let id = try LocalRepository.normalizedUserID(userID)
        guard let user = try LocalRepository(context: context).user(id), PasswordHasher.verify(password, against: user.passwordHash) else {
            throw AuthenticationError.invalidCredentials
        }
        let key = try keys.read(for: id)
        try establishSession(for: id)
        if try keychain.read(pinAccount(id)) == nil {
            phase = .setupPIN
        } else {
            try unlock(user: user, key: key, context: context)
        }
    }

    func setPIN(_ pin: String, context: ModelContext) throws {
        guard let id = activeUserID else { throw AuthenticationError.noSession }
        guard pin.count == 6, pin.allSatisfy(\.isNumber) else { throw AuthenticationError.incorrectPIN }
        try keychain.save(Data(try PasswordHasher.hash(pin).utf8), account: pinAccount(id))
        guard let user = try LocalRepository(context: context).user(id) else { throw AuthenticationError.noSession }
        try unlock(user: user, key: try keys.read(for: id), context: context)
    }

    func verifyPIN(_ pin: String, context: ModelContext) throws {
        guard let id = activeUserID, let data = try keychain.read(pinAccount(id)),
              let hash = String(data: data, encoding: .utf8) else { throw AuthenticationError.pinNotConfigured }
        guard PasswordHasher.verify(pin, against: hash) else { throw AuthenticationError.incorrectPIN }
        guard let user = try LocalRepository(context: context).user(id) else { throw AuthenticationError.noSession }
        try unlock(user: user, key: try keys.read(for: id), context: context)
    }

    func unlockWithBiometrics(context: ModelContext) async throws {
        guard let id = activeUserID else { throw AuthenticationError.noSession }
        let auth = LAContext()
        var error: NSError?
        guard auth.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error), auth.biometryType == .faceID else {
            throw AuthenticationError.biometricsUnavailable
        }
        try await auth.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "解锁 Luma")
        guard let user = try LocalRepository(context: context).user(id) else { throw AuthenticationError.noSession }
        try unlock(user: user, key: try keys.read(for: id), context: context)
    }

    func canUseBiometrics() -> Bool {
        let auth = LAContext()
        return auth.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) && auth.biometryType == .faceID
    }

    /// A second, per-conversation gate. Does not create or persist another key.
    func verifyChatPIN(_ pin: String) throws {
        guard phase == .unlocked, let id = activeUserID,
              let data = try keychain.read(pinAccount(id)),
              let hash = String(data: data, encoding: .utf8) else { throw AuthenticationError.pinNotConfigured }
        guard PasswordHasher.verify(pin, against: hash) else { throw AuthenticationError.incorrectPIN }
    }

    func verifyChatBiometrics() async throws {
        guard phase == .unlocked else { throw MessageStoreError.locked }
        let auth = LAContext()
        guard auth.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil), auth.biometryType == .faceID else {
            throw AuthenticationError.biometricsUnavailable
        }
        try await auth.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "查看此聊天")
    }

    func lock() {
        if phase == .unlocked { unlockedKey = nil; preferences = PrivacyPreferences(); phase = .locked }
    }

    func logout() throws {
        try keychain.delete(sessionAccount)
        unlockedKey = nil
        preferences = PrivacyPreferences()
        activeUserID = nil
        phase = .login
    }

    func changePassword(old: String, new: String, user: User, context: ModelContext) throws {
        guard PasswordHasher.verify(old, against: user.passwordHash) else { throw AuthenticationError.invalidCredentials }
        user.passwordHash = try PasswordHasher.hash(new)
        try context.save()
    }

    private func establishSession(for id: String) throws {
        try keychain.save(Data(id.utf8), account: sessionAccount)
        activeUserID = id
    }

    func currentUserID() throws -> String {
        guard phase == .unlocked, unlockedKey != nil, let activeUserID else { throw MessageStoreError.locked }
        return activeUserID
    }

    func encryptionService() throws -> EncryptionService {
        guard phase == .unlocked, let unlockedKey else { throw MessageStoreError.locked }
        return EncryptionService(key: unlockedKey)
    }

    func sessionManager(context: ModelContext) throws -> SessionManager {
        _ = try encryptionService()
        return SessionManager(context: context, keychain: keychain)
    }

    func privateStore(context: ModelContext) throws -> PrivateMetadataStore {
        PrivateMetadataStore(context: context, encryption: try encryptionService())
    }

    func deleteLocalAttachment(_ attachmentID: UUID, ownerID: UUID) throws {
        try FileTransferService(ownerID: ownerID, encryption: encryptionService())
            .delete(attachmentID: attachmentID)
    }

    func preferences(for user: User, context: ModelContext) throws -> PrivacyPreferences {
        try privateStore(context: context).preferences(for: user)
    }

    func storedFaceIDPreference(for user: User?) throws -> Bool {
        guard let user else { return false }
        guard let bytes = user.encryptedPreferences else { return user.faceIDEnabled }
        let data = try EncryptionService(key: keys.read(for: user.userID))
            .decrypt(EncryptedData(bytes: bytes), authenticatedData: Data("luma-preferences-v1|\(user.id.uuidString)".utf8))
        return try JSONDecoder().decode(PrivacyPreferences.self, from: data).faceIDEnabled
    }

    func updatePreferences(for user: User, context: ModelContext, _ change: (inout PrivacyPreferences) -> Void) throws {
        guard activeUserID == user.userID, phase == .unlocked else { throw MessageStoreError.locked }
        var updated = preferences
        change(&updated)
        try privateStore(context: context).save(updated, for: user)
        preferences = updated
    }

    func reloadPreferences(for user: User, context: ModelContext) throws {
        guard activeUserID == user.userID, phase == .unlocked else { throw MessageStoreError.locked }
        try lifecycle.ensureExistingAccount(user, context: context)
        preferences = try privateStore(context: context).preferences(for: user)
    }

    func friendDisplayName(_ friend: Friend, context: ModelContext) -> String {
        (try? privateStore(context: context).displayName(for: friend)) ?? "资料不可读取"
    }

    func userProfile(_ user: User, context: ModelContext) throws -> UserPrivateProfile {
        try privateStore(context: context).profile(for: user)
    }

    func friendProfile(_ friend: Friend, context: ModelContext) throws -> FriendPrivateProfile {
        try privateStore(context: context).profile(for: friend)
    }

    func friendAvatar(_ friend: Friend, context: ModelContext) -> Data? {
        try? friendProfile(friend, context: context).avatar
    }

    func keychainStatus() -> String {
        guard let activeUserID else { return "未登录" }
        do { return try keys.isStored(for: activeUserID) ? "可读取" : "密钥不存在" }
        catch { return error.localizedDescription }
    }

    func identityKeyStatus(for user: User) -> String { lifecycle.identityStatus(for: user) }

    func deviceKeyStatus(for user: User, context: ModelContext) -> String {
        lifecycle.deviceStatus(for: user, context: context)
    }

    func localSessionStatus(for user: User, friend: Friend, context: ModelContext) -> String {
        guard phase == .unlocked, activeUserID == user.userID else { return "应用已锁定" }
        do {
            let manager = SessionManager(context: context, keychain: keychain)
            guard let record = try manager.session(ownerID: user.id, friendID: friend.id) else { return "未建立" }
            _ = try manager.key(for: record)
            return "已建立 · 本机模拟"
        } catch { return error.localizedDescription }
    }

    func createLocalSession(for user: User, friend: Friend, context: ModelContext) throws {
        guard phase == .unlocked, activeUserID == user.userID else { throw MessageStoreError.locked }
        guard friend.ownerID == user.id,
              let peer = try LocalRepository(context: context).user(friend.userID),
              let publicKey = peer.identityPublicKey else { throw SessionError.localPeerUnavailable }
        guard try IdentityKeyManager(keychain: keychain).readPublicKey(for: peer.userID) == publicKey else {
            throw AsymmetricKeyError.publicKeyMismatch
        }
        let sessionManager = SessionManager(context: context, keychain: keychain)
        if try sessionManager.session(ownerID: user.id, friendID: friend.id) != nil {
            _ = try sessionManager.create(owner: user, friend: friend, peerPublicKey: publicKey)
            return
        }
        _ = try sessionManager.create(owner: user, friend: friend, peerPublicKey: publicKey)
    }

    func deleteAccount(password: String, user: User, context: ModelContext) throws {
        guard phase == .unlocked, activeUserID == user.userID,
              PasswordHasher.verify(password, against: user.passwordHash) else {
            throw AuthenticationError.invalidCredentials
        }
        let marker: CleanupState
        if let existing = try context.fetch(FetchDescriptor<CleanupState>()).first(where: {
            $0.ownerID == user.id && $0.operation == "accountDeletion" && $0.state != "completed"
        }) { marker = existing }
        else {
            marker = CleanupState(ownerID: user.id, userID: user.userID, operation: "accountDeletion")
            context.insert(marker)
            try context.save()
        }
        try continueAccountDeletion(user: user, marker: marker, context: context)
    }

    func resumeAccountCleanup(context: ModelContext) throws {
        let markers = try context.fetch(FetchDescriptor<CleanupState>()).filter { $0.operation == "accountDeletion" && $0.state != "completed" }
        for marker in markers {
            if let user = try context.fetch(FetchDescriptor<User>()).first(where: { $0.id == marker.ownerID }) {
                try continueAccountDeletion(user: user, marker: marker, context: context)
            } else {
                try V4SessionVault(keychain: keychain).purgeAccount(userID: marker.userID)
                try RemoteSessionStore(keychain: keychain).clearAll(for: marker.userID)
                try keychain.delete(sessionAccount)
                marker.state = "completed"
                try context.save()
                context.delete(marker)
                try context.save()
            }
        }
    }

    private func continueAccountDeletion(user: User, marker: CleanupState, context: ModelContext) throws {
        marker.state = "processing"
        try context.save()
        do { try finishAccountDeletion(user: user, marker: marker, context: context) }
        catch {
            context.rollback()
            marker.state = "failed"
            try? context.save()
            unlockedKey = nil
            activeUserID = nil
            phase = .login
            throw error
        }
    }

    private func finishAccountDeletion(user: User, marker: CleanupState, context: ModelContext) throws {
        let committedRestores = try context.fetch(FetchDescriptor<CleanupState>()).filter {
            $0.ownerID == user.id && $0.operation == "backupRestore" && $0.dataCommitted && $0.state != "completed"
        }
        if !committedRestores.isEmpty {
            try BackupManager.resumeRestoreCleanup(for: user, context: context,
                encryption: EncryptionService(key: keys.read(for: user.userID)), keychain: keychain)
        }
        let conversations = try context.fetch(FetchDescriptor<Conversation>()).filter { $0.ownerID == user.id }
        let conversationIDs = Set(conversations.map(\.id))
        let friends = try context.fetch(FetchDescriptor<Friend>()).filter { $0.ownerID == user.id }
        let friendIDs = Set(friends.map(\.id))
        let messages = try context.fetch(FetchDescriptor<Message>()).filter { conversationIDs.contains($0.conversationID) }
        let messageIDs = Set(messages.map(\.id))
        let attachments = try context.fetch(FetchDescriptor<Attachment>()).filter { messageIDs.contains($0.messageID) }
        let presences = try context.fetch(FetchDescriptor<UserPresence>()).filter { friendIDs.contains($0.friendID) }
        let devices = try context.fetch(FetchDescriptor<Device>()).filter { $0.ownerID == user.id }
        let reactions = try context.fetch(FetchDescriptor<Reaction>()).filter { messageIDs.contains($0.messageID) }
        let indexes = try context.fetch(FetchDescriptor<SearchIndexEntry>()).filter { $0.ownerID == user.id }
        let sessionKeys = try context.fetch(FetchDescriptor<SessionKey>()).filter { $0.ownerID == user.id || friendIDs.contains($0.friendID) }
        let prekeys = try context.fetch(FetchDescriptor<PreKeyMetadata>()).filter { $0.ownerID == user.id }
        let remoteCheckpoints = try context.fetch(FetchDescriptor<RemoteSyncCheckpoint>()).filter { $0.ownerID == user.id }
        let remoteDeviceTrust = try context.fetch(FetchDescriptor<RemoteDeviceTrust>()).filter { $0.ownerID == user.id }
        let v4Sessions = try context.fetch(FetchDescriptor<V4SessionMetadata>()).filter { $0.ownerID == user.id }
        let v4Devices = try context.fetch(FetchDescriptor<V4DeviceMetadata>()).filter { $0.ownerID == user.id }
        let outgoing = try context.fetch(FetchDescriptor<OutgoingMessageQueueItem>()).filter { $0.ownerID == user.id }
        let v4Events = try context.fetch(FetchDescriptor<V4PendingEvent>()).filter { $0.ownerID == user.id }
        let cleanupMarkers = try context.fetch(FetchDescriptor<CleanupState>()).filter { $0.ownerID == user.id && $0.id != marker.id }

        try FileTransferService.purgeAccount(ownerID: user.id)
        try BackupManager.deleteTemporaryExports(for: user.userID)
        // Clear Keychain first: deletion cannot leave an account with readable encrypted data.
        try lifecycle.deleteKeys(for: user, context: context)
        try RemoteSessionStore(keychain: keychain).clearAll(for: user.userID)
        for item in attachments { context.delete(item) }
        for item in reactions { context.delete(item) }
        for item in indexes { context.delete(item) }
        for item in sessionKeys { context.delete(item) }
        for item in prekeys { context.delete(item) }
        for item in remoteCheckpoints { context.delete(item) }
        for item in remoteDeviceTrust { context.delete(item) }
        for item in v4Sessions { context.delete(item) }
        for item in v4Devices { context.delete(item) }
        for item in outgoing { context.delete(item) }
        for item in v4Events { context.delete(item) }
        for item in cleanupMarkers { context.delete(item) }
        for item in messages { context.delete(item) }
        for item in conversations { context.delete(item) }
        for item in presences { context.delete(item) }
        for item in friends { context.delete(item) }
        for item in devices { context.delete(item) }
        context.delete(user)
        try context.save()
        try keychain.delete(sessionAccount)
        marker.state = "completed"
        try context.save()
        context.delete(marker)
        try context.save()
        unlockedKey = nil
        preferences = PrivacyPreferences()
        activeUserID = nil
        phase = .registration
    }

    private func unlock(user: User, key: SymmetricKey, context: ModelContext) throws {
        do {
            try MessageStore(context: context, encryption: EncryptionService(key: key)).migrateLegacyMessages(owner: user)
            try PrivateMetadataStore(context: context, encryption: EncryptionService(key: key)).migrate(owner: user)
            try lifecycle.ensureExistingAccount(user, context: context)
            try BackupManager.resumeRestoreCleanup(for: user, context: context,
                encryption: EncryptionService(key: key), keychain: keychain)
        } catch {
            context.rollback()
            throw error
        }
        preferences = try PrivateMetadataStore(context: context, encryption: EncryptionService(key: key)).preferences(for: user)
        unlockedKey = key
        phase = .unlocked
    }

    private func pinAccount(_ id: String) -> String { "pin.\(id)" }
}
