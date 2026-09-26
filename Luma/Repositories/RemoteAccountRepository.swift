import Foundation

struct RemoteProfile: Decodable {
    let id: UUID
    let userID: String
    let nickname: String
    let searchable: Bool
    let showPresence: Bool
    let readReceipts: Bool
}

struct RemoteUserResult: Decodable {
    let id: UUID
    let userID: String
    let nickname: String
}

struct RemoteFriendRequest: Decodable, Identifiable {
    let requestID: UUID
    let fromUserID: String
    var id: UUID { requestID }
}

struct RemoteConfirmedFriend: Decodable, Identifiable {
    let id: UUID
    let userID: String
    let nickname: String
}

/// Only public account data and friendship actions cross this repository boundary.
struct RemoteAccountRepository {
    let client: RemoteAPIClient

    func profile() async throws -> RemoteProfile {
        try await client.json(RemoteProfile.self, path: "/users/me")
    }

    func updateProfile(nickname: String? = nil, searchable: Bool? = nil,
                       showPresence: Bool? = nil, readReceipts: Bool? = nil) async throws -> RemoteProfile {
        struct Patch: Encodable {
            let nickname: String?
            let searchable: Bool?
            let showPresence: Bool?
            let readReceipts: Bool?
        }
        let body = try JSONEncoder().encode(Patch(nickname: nickname, searchable: searchable,
                                                   showPresence: showPresence, readReceipts: readReceipts))
        return try await client.json(RemoteProfile.self, method: "PATCH", path: "/users/me", body: body)
    }

    func search(userID: String) async throws -> RemoteUserResult {
        let id = userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { throw RemoteError.invalidURL }
        var parts = URLComponents()
        parts.queryItems = [URLQueryItem(name: "userID", value: id)]
        return try await client.json(RemoteUserResult.self, path: "/users/search?" + (parts.percentEncodedQuery ?? ""))
    }

    func requestFriend(userID: String) async throws {
        _ = try await client.request("POST", path: "/friend/request",
                                     body: JSONEncoder().encode(["userID": userID.lowercased()]))
    }

    func pendingRequests() async throws -> [RemoteFriendRequest] {
        try await client.json([RemoteFriendRequest].self, path: "/friend/requests")
    }

    func confirmedFriends() async throws -> [RemoteConfirmedFriend] {
        try await client.json([RemoteConfirmedFriend].self, path: "/friends")
    }

    func accept(_ requestID: UUID) async throws {
        _ = try await client.request("POST", path: "/friend/accept",
                                     body: JSONEncoder().encode(["requestID": requestID.uuidString.lowercased()]))
    }

    func reject(_ requestID: UUID) async throws {
        _ = try await client.request("POST", path: "/friend/reject",
                                     body: JSONEncoder().encode(["requestID": requestID.uuidString.lowercased()]))
    }

    func removeFriend(backendUserID: UUID) async throws {
        _ = try await client.request("DELETE", path: "/friend/\(backendUserID.uuidString.lowercased())")
    }

    func block(backendUserID: UUID) async throws {
        _ = try await client.request("POST", path: "/friend/block",
                                     body: JSONEncoder().encode(["userID": backendUserID.uuidString.lowercased()]))
    }
}
