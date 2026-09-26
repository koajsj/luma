import Foundation
import SwiftData

@MainActor
struct FriendsViewModel {
    let context: ModelContext

    func searchableUser(for rawID: String, among users: [User], excluding owner: User) -> User? {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return users.first { $0.userID == id && $0.searchable && $0.id != owner.id }
    }

    func addLocalContact(owner: User, userID: String, nickname: String) throws {
        _ = try LocalRepository(context: context).addFriend(owner: owner, userID: userID, nickname: nickname)
    }

    func setMockOnline(_ online: Bool, for friend: Friend) throws {
        try PresenceService(context: context).setMockOnline(online, for: friend.id)
    }

    func removeRemoteFriendIfNeeded(_ friend: Friend, security: SecurityManager) async throws {
        guard let remoteUserID = friend.remoteUserID,
              let userID = try? security.currentUserID(),
              let registration = try RemoteSessionStore().registration(for: userID) else { return }
        let client = try RemoteAPIClient(baseURL: registration.baseURL, userID: userID)
        do { try await RemoteAccountRepository(client: client).removeFriend(backendUserID: remoteUserID) }
        catch RemoteError.server(404, _) { /* Already removed remotely. */ }
    }
}
