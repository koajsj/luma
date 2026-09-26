import Foundation

/// Server visibility policy is enforced by the backend; callers also gate heartbeats locally.
struct RemotePresenceProvider {
    let client: RemoteAPIClient

    func snapshot(for userID: String) async throws -> PresenceSnapshot {
        struct Response: Decodable { let online: Bool; let lastSeenAt: String? }
        let id = userID.lowercased()
        guard id.range(of: "^[a-z0-9_]{3,32}$", options: .regularExpression) != nil else {
            throw RemoteError.invalidURL
        }
        let data = try await client.request("GET", path: "/presence/\(id)")
        let value = try JSONDecoder().decode(Response.self, from: data)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        let lastSeen = value.lastSeenAt.flatMap { fractional.date(from: $0) ?? fallback.date(from: $0) }
        return PresenceSnapshot(onlineStatus: value.online ? .online : .offline,
                                lastSeenAt: lastSeen, typingStatus: .idle, isMock: false)
    }

    func heartbeat(allowedByPrivacy: Bool) async throws {
        guard allowedByPrivacy else { return }
        _ = try await client.request("PUT", path: "/presence/heartbeat")
    }
}
