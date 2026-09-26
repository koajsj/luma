import Foundation

struct RemoteSyncEvent: Decodable, Identifiable {
    let eventID: UUID
    let deviceSeq: Int64
    let type: String
    let payloadCiphertext: String
    let routing: RemoteEventRouting
    let createdAt: String
    var id: UUID { eventID }
}

struct RemoteEventRouting: Decodable {
    let messageID: UUID?
    let conversationID: UUID?
    let senderDeviceID: UUID?
    let encryptionVersion: Int?
    let keyVersion: Int?
    let messageKeyIndex: Int64?
    let revision: Int?
    let recipientDeviceID: UUID?
    let revokedDeviceID: UUID?
}

struct RemoteSyncPage: Decodable {
    let events: [RemoteSyncEvent]
    let nextCursor: Int64
}

/// Fetches server events without applying them as local MessageEvent values.
/// Ack is deliberately separate: an unknown v3 envelope must not advance the cursor.
struct RemoteMessageSyncProvider {
    let client: RemoteAPIClient

    func fetch(after cursor: Int64, limit: Int = 100) async throws -> RemoteSyncPage {
        try await client.json(RemoteSyncPage.self, path: "/sync/events?cursor=\(cursor)&limit=\(limit)")
    }

    func acknowledge(_ cursor: Int64) async throws {
        _ = try await client.request("POST", path: "/sync/ack",
                                     body: JSONEncoder().encode(["cursor": cursor]))
    }
}

/// A WebSocket frame is only a hint to call cursor sync; it is never applied as a message.
final class WebSocketTransport {
    private let client: RemoteAPIClient
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    init(client: RemoteAPIClient, session: URLSession = RemoteAPIClient.ephemeralSession) {
        self.client = client
        self.session = session
    }

    func connect(onHint: @escaping @Sendable () async -> Void) async throws {
        let request = try await client.authenticatedWebSocketRequest()
        let socket = session.webSocketTask(with: request)
        task = socket
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil); task = nil }
        try await withTaskCancellationHandler {
            while !Task.isCancelled {
                let frame = try await socket.receive()
                switch frame {
                case .string, .data: await onHint()
                @unknown default: break
                }
            }
        } onCancel: {
            socket.cancel(with: .normalClosure, reason: nil)
        }
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}

/// Existing local v1/v2 ciphertext is bound to local UUIDs and unavailable to peers.
/// A future audited v3 envelope encoder must be injected before this can send.
struct RemoteTransport {
    func sendLocalMessage(_ event: MessageEvent) async throws {
        throw RemoteError.onlineMessagesUnavailable
    }
}
