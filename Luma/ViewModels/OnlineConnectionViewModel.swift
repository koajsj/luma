import Foundation
import SwiftData

struct RemoteDeviceInfo: Decodable, Identifiable {
    let id: UUID
    let deviceName: String
    let createdAt: String
    let lastActiveAt: String?
    let revokedAt: String?
}

@MainActor
struct OnlineConnectionViewModel {
    let user: User
    let context: ModelContext
    private var store: RemoteSessionStore { RemoteSessionStore() }

    func localState() throws -> (RemoteRegistration?, Bool) {
        (try store.registration(for: user.userID), try store.tokens(for: user.userID) != nil)
    }

    func register(address: String) async throws -> RemoteRegistration {
        guard let url = URL(string: address) else { throw RemoteError.invalidURL }
        return try await RemoteAuthProvider(context: context).register(user: user, baseURL: url)
    }

    func login() async throws {
        try await RemoteAuthProvider(context: context).login(userID: user.userID)
    }

    func signOut() async throws {
        try await RemoteAuthProvider(context: context).signOut(userID: user.userID)
    }

    func devices() async throws -> [RemoteDeviceInfo] {
        let data = try await client().request("GET", path: "/devices")
        return try JSONDecoder().decode([RemoteDeviceInfo].self, from: data)
    }

    func revoke(deviceID: UUID) async throws {
        guard deviceID != (try store.registration(for: user.userID))?.backendDeviceID else {
            throw RemoteError.server(409, "cannot_revoke_current_device")
        }
        _ = try await client().request("DELETE", path: "/devices/\(deviceID.uuidString.lowercased())")
        // Other devices receive device.revoked through their cursor; this device drops stale trust now.
        for trust in try context.fetch(FetchDescriptor<RemoteDeviceTrust>()).filter({
            $0.ownerID == user.id && $0.backendDeviceID == deviceID
        }) { context.delete(trust) }
        try context.save()
    }

    func profile() async throws -> RemoteProfile {
        try await RemoteAccountRepository(client: client()).profile()
    }

    func pushNickname() async throws -> RemoteProfile {
        try await RemoteAccountRepository(client: client()).updateProfile(nickname: user.nickname)
    }

    func search(_ userID: String) async throws -> RemoteUserResult {
        try await RemoteAccountRepository(client: client()).search(userID: userID)
    }

    func requestFriend(_ userID: String) async throws {
        try await RemoteAccountRepository(client: client()).requestFriend(userID: userID)
        let normalized = try LocalRepository.normalizedUserID(userID)
        if try context.fetch(FetchDescriptor<Friend>()).contains(where: {
            $0.ownerID == user.id && $0.userID == normalized
        }) == false {
            _ = try LocalRepository(context: context).addFriend(owner: user, userID: normalized,
                                                                nickname: normalized)
        }
    }

    func pendingRequests() async throws -> [RemoteFriendRequest] {
        try await RemoteAccountRepository(client: client()).pendingRequests()
    }

    func decide(_ item: RemoteFriendRequest, accept: Bool) async throws {
        let repository = RemoteAccountRepository(client: try client())
        if accept {
            try await repository.accept(item.requestID)
            _ = try? LocalRepository(context: context).addFriend(owner: user, userID: item.fromUserID,
                                                                   nickname: item.fromUserID)
            _ = try await syncConfirmedContacts()
        } else {
            try await repository.reject(item.requestID)
        }
    }

    func inspectSync() async throws -> Int {
        let registration = try store.registration(for: user.userID)
        let cursor = try context.fetch(FetchDescriptor<RemoteSyncCheckpoint>()).first(where: {
            $0.ownerID == user.id && $0.backendDeviceID == registration?.backendDeviceID
        })?.cursor ?? 0
        let page = try await RemoteMessageSyncProvider(client: client()).fetch(after: cursor, limit: 200)
        return page.events.count
    }

    func syncConfirmedContacts() async throws -> Int {
        let contacts = try await RemoteAccountRepository(client: client()).confirmedFriends()
        let current = try context.fetch(FetchDescriptor<Friend>()).filter { $0.ownerID == user.id }
        var added = 0
        for contact in contacts {
            if let existing = current.first(where: { $0.userID == contact.userID }) {
                existing.remoteUserID = contact.id
            } else {
                let friend = try LocalRepository(context: context).addFriend(owner: user,
                    userID: contact.userID, nickname: contact.nickname)
                friend.remoteUserID = contact.id
                added += 1
            }
        }
        try context.save()
        return added
    }

    func presence(for userID: String) async throws -> PresenceSnapshot {
        try await RemotePresenceProvider(client: client()).snapshot(for: userID)
    }

    func watchHints(onHint: @escaping @Sendable () async -> Void) async {
        while !Task.isCancelled {
            do {
                try await WebSocketTransport(client: client()).connect(onHint: onHint)
            } catch RemoteError.authenticationExpired {
                return
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func client() throws -> RemoteAPIClient {
        guard let registration = try store.registration(for: user.userID) else { throw RemoteError.unregistered }
        return try RemoteAPIClient(baseURL: registration.baseURL, userID: user.userID)
    }
}
