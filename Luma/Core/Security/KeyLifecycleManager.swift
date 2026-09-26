import Foundation
import SwiftData
import UIKit

/// Coordinates local key records. Existing master keys are never silently replaced.
@MainActor
struct KeyLifecycleManager {
    let keychain: KeychainManager
    private var masters: KeyManager { KeyManager(keychain: keychain) }
    private var identities: IdentityKeyManager { IdentityKeyManager(keychain: keychain) }
    private var devices: DeviceKeyManager { DeviceKeyManager(keychain: keychain) }

    init(keychain: KeychainManager = KeychainManager()) { self.keychain = keychain }

    func provisionNewAccount(_ user: User, context: ModelContext) throws {
        _ = try masters.create(for: user.userID)
        try ensureIdentityAndDevice(for: user, context: context)
        let prekeys = PreKeyManager(context: context, keychain: keychain)
        _ = try prekeys.signedKey(for: user)
        _ = try prekeys.generateOneTimePool(for: user)
    }

    func ensureExistingAccount(_ user: User, context: ModelContext) throws {
        _ = try masters.read(for: user.userID)
        try ensureIdentityAndDevice(for: user, context: context)
        _ = try PreKeyManager(context: context, keychain: keychain).signedKey(for: user)
    }

    func identityStatus(for user: User) -> String {
        do {
            let publicKey = try identities.readPublicKey(for: user.userID)
            guard user.identityPublicKey == publicKey,
                  user.identityFingerprint == IdentityFingerprint.make(publicKey: publicKey) else {
                return "身份记录不一致"
            }
            return "已生成"
        } catch { return error.localizedDescription }
    }

    func deviceStatus(for user: User, context: ModelContext) -> String {
        do {
            guard let device = try currentDevice(for: user, context: context) else { return "设备密钥不存在" }
            let publicKey = try devices.readPublicKey(for: device.id)
            return device.publicKey == publicKey ? "Keychain 已保护" : "设备记录不一致"
        } catch { return error.localizedDescription }
    }

    func deleteKeys(for user: User, context: ModelContext) throws {
        let ownedFriends = try context.fetch(FetchDescriptor<Friend>()).filter { $0.ownerID == user.id }
        let friendIDs = Set(ownedFriends.map(\.id))
        let sessions = SessionManager(context: context, keychain: keychain)
        for record in try context.fetch(FetchDescriptor<SessionKey>()).filter({ $0.ownerID == user.id || friendIDs.contains($0.friendID) }) {
            try sessions.deleteKeyMaterial(for: record)
        }
        try PreKeyManager(context: context, keychain: keychain).deleteAll(for: user.id)
        let ownedDevices = try context.fetch(FetchDescriptor<Device>()).filter { $0.ownerID == user.id }
        for device in ownedDevices { try devices.delete(for: device.id) }
        try identities.delete(for: user.userID)
        try masters.delete(for: user.userID)
        try keychain.delete("pin.\(user.userID)")
    }

    private func ensureIdentityAndDevice(for user: User, context: ModelContext) throws {
        let identityPublic: Data
        if user.identityPublicKey == nil {
            identityPublic = try identities.create(for: user.userID)
        } else {
            identityPublic = try identities.readPublicKey(for: user.userID)
            guard user.identityPublicKey == identityPublic else { throw AsymmetricKeyError.publicKeyMismatch }
        }
        let fingerprint = IdentityFingerprint.make(publicKey: identityPublic)
        if let stored = user.identityFingerprint, stored != fingerprint { throw AsymmetricKeyError.publicKeyMismatch }

        let device = try currentDevice(for: user, context: context)
            ?? Device(name: UIDevice.current.name, ownerID: user.id)
        let devicePublic: Data
        if device.publicKey == nil {
            devicePublic = try devices.create(for: device.id)
        } else {
            devicePublic = try devices.readPublicKey(for: device.id)
            guard device.publicKey == devicePublic else { throw AsymmetricKeyError.publicKeyMismatch }
        }
        if device.modelContext == nil { context.insert(device) }
        user.identityPublicKey = identityPublic
        user.identityFingerprint = fingerprint
        device.publicKey = devicePublic
        device.deviceName = device.deviceName ?? device.name
        device.createdAt = device.createdAt ?? .now
        device.lastActiveAt = .now
        device.systemVersion = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        try context.save()
    }

    private func currentDevice(for user: User, context: ModelContext) throws -> Device? {
        try context.fetch(FetchDescriptor<Device>()).first { $0.ownerID == user.id }
    }
}
