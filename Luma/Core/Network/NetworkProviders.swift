import Foundation
import SwiftData

enum NetworkBoundaryError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Luma 当前仅支持本机使用，尚未连接通信服务" }
}

/// The local simulator remains available when no backend account is configured.
struct APIRequest { let path: String; let body: Data? }
struct APIResponse { let body: Data; let statusCode: Int }
protocol APIClient { func perform(_ request: APIRequest) throws -> APIResponse }
struct MockAPIClient: APIClient {
    func perform(_ request: APIRequest) throws -> APIResponse { throw NetworkBoundaryError.unavailable }
}

struct AuthIdentity { let userID: String; let deviceID: UUID }
protocol AuthProvider {
    func authenticate(userID: String, proof: Data) throws -> AuthIdentity
    func signOut() throws
}
struct MockAuthProvider: AuthProvider {
    func authenticate(userID: String, proof: Data) throws -> AuthIdentity { throw NetworkBoundaryError.unavailable }
    func signOut() throws { }
}

/// Events stay in memory until the coordinator applies them successfully.
@MainActor
protocol MessageSyncProvider {
    func publish(_ event: MessageEvent, to endpoint: String) throws
    func pending(for endpoint: String) throws -> [MessageEvent]
    func complete(_ eventID: UUID, for endpoint: String) throws
}

@MainActor
struct MockMessageSyncProvider: MessageSyncProvider {
    let transport: any MessageTransport
    func publish(_ event: MessageEvent, to endpoint: String) throws {
        try transport.sendMessage(event, to: endpoint)
    }
    func pending(for endpoint: String) throws -> [MessageEvent] {
        try transport.pendingMessages(for: endpoint)
    }
    func complete(_ eventID: UUID, for endpoint: String) throws {
        try transport.completeMessage(eventID, for: endpoint)
    }
}

struct PresenceSnapshot {
    let onlineStatus: OnlineStatus
    let lastSeenAt: Date?
    let typingStatus: TypingStatus
    let isMock: Bool
}

@MainActor
protocol PresenceProvider {
    func snapshot(for friendID: UUID) throws -> PresenceSnapshot
    func setMockOnline(_ online: Bool, for friendID: UUID) throws
    func setMockTyping(_ typing: TypingStatus, for friendID: UUID) throws
}

/// File payloads are encrypted locally by FileTransferService. No upload URL exists here.
@MainActor
protocol FileProvider {
    func upload(_ data: Data, attachmentID: UUID) throws
    func download(attachmentID: UUID) throws -> Data
    func delete(attachmentID: UUID) throws
}
