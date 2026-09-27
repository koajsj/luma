#if DEBUG
import Foundation
import SwiftData

/// Debug-only metadata snapshot. Never reads message bodies or key material.
struct E2EEDiagnosticsSnapshot {
    let encryptionVersion: String
    let sessionStatus: String
    let eventID: String
    let syncCursor: String
    let pendingCount: Int
    let cryptoTransaction: String
}

@MainActor
struct E2EEDiagnosticsService {
    let context: ModelContext
    let user: User

    func snapshot() throws -> E2EEDiagnosticsSnapshot {
        let sessions = try context.fetch(FetchDescriptor<V4SessionMetadata>())
            .filter { $0.ownerID == user.id }
        let checkpoints = try context.fetch(FetchDescriptor<RemoteSyncCheckpoint>())
            .filter { $0.ownerID == user.id }
        let outbox = try context.fetch(FetchDescriptor<OutgoingMessageQueueItem>())
            .filter { $0.ownerID == user.id && $0.state != "sent" }
        let events = try context.fetch(FetchDescriptor<V4PendingEvent>())
            .filter { $0.ownerID == user.id }
        let conversationIDs = Set(try context.fetch(FetchDescriptor<Conversation>())
            .filter { $0.ownerID == user.id }.map(\.id))
        let messages = try context.fetch(FetchDescriptor<Message>())
            .filter { conversationIDs.contains($0.conversationID) &&
                $0.transportEncryptionVersion == 4 && $0.lastEventID != nil }
        let deviceID = checkpoints.first?.backendDeviceID
        let vault = V4SessionVault()
        let outgoing = try deviceID.flatMap { try vault.outgoingPending(userID: user.userID, deviceID: $0) }
        let incoming = try deviceID.flatMap { try vault.incomingPending(userID: user.userID, deviceID: $0) }
        let phases = [outgoing.map { "发送 \($0.phase.rawValue)" },
                      incoming.map { "接收 \($0.phase.rawValue)" }].compactMap { $0 }
        return .init(encryptionVersion: "v4（历史 v1/v2/v3 可读）",
            sessionStatus: sessions.isEmpty ? "无会话" : "\(sessions.filter { $0.status == "active" }.count) 个活跃会话",
            eventID: messages.max(by: { $0.timestamp < $1.timestamp })?.lastEventID?.uuidString ?? "无",
            syncCursor: checkpoints.map { String($0.cursor) }.joined(separator: ", ").isEmpty ? "未同步" :
                checkpoints.map { String($0.cursor) }.joined(separator: ", "),
            pendingCount: outbox.count + events.count,
            cryptoTransaction: phases.isEmpty ? "无待恢复事务" : phases.joined(separator: "、"))
    }
}
#endif
