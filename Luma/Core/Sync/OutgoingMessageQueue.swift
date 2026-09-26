import Foundation
import SwiftData

enum OutgoingQueueError: LocalizedError {
    case missing, identityChanged
    var errorDescription: String? {
        switch self {
        case .missing: "待发请求已不存在，请复制消息内容后重新发送"
        case .identityChanged: "好友身份密钥已变化，请重新核对后重新发送消息"
        }
    }
}

/// Persists the exact v3 request before transmission. Retries reuse its message ID and envelopes.
@MainActor
struct OutgoingMessageQueue {
    let context: ModelContext
    let ownerID: UUID
    let backendDeviceID: UUID
    let encryption: EncryptionService
    let client: RemoteAPIClient
    private static var draining = Set<UUID>()
    private let maxAttempts = 5

    func enqueue(messageID: UUID, request: Data) throws -> OutgoingMessageQueueItem {
        let item = OutgoingMessageQueueItem(ownerID: ownerID, backendDeviceID: backendDeviceID,
                                             messageID: messageID, encryptedRequest: Data())
        item.encryptedRequest = try encryption.encrypt(request, authenticatedData: binding(item)).bytes
        context.insert(item)
        return item
    }

    func drain(validate: ((OutgoingMessageQueueItem) async throws -> Void)? = nil,
               prepare: (OutgoingMessageQueueItem, Data) async throws -> Data,
               send: ((Data, UUID) async throws -> Void)? = nil) async throws {
        guard !Self.draining.contains(backendDeviceID) else { return }
        Self.draining.insert(backendDeviceID)
        defer { Self.draining.remove(backendDeviceID) }
        let items = try context.fetch(FetchDescriptor<OutgoingMessageQueueItem>()).filter {
            $0.ownerID == ownerID && $0.backendDeviceID == backendDeviceID &&
            $0.state != "sent" && $0.attempts < maxAttempts && $0.nextAttemptAt <= .now
        }.sorted { $0.createdAt < $1.createdAt }
        for item in items {
            guard let message = try context.fetch(FetchDescriptor<Message>()).first(where: { $0.id == item.messageID }) else {
                // Never transmit an orphaned queue item.
                context.delete(item); try context.save(); continue
            }
            do {
                var body: Data
                do {
                    body = try encryption.decrypt(EncryptedData(bytes: item.encryptedRequest), authenticatedData: binding(item))
                } catch {
                    // A damaged request cannot become valid through network retries.
                    item.attempts = maxAttempts
                    item.state = "failed"
                    message.deliveryStatus = .failed
                    try context.save()
                    throw error
                }
                try await validate?(item)
                item.state = "sending"
                try context.save()
                if !item.prepared {
                    body = try await prepare(item, body)
                    item.encryptedRequest = try encryption.encrypt(body, authenticatedData: binding(item)).bytes
                    item.prepared = true
                    try context.save()
                }
                if let send { try await send(body, item.messageID) }
                else {
                    _ = try await client.request("POST", path: "/messages", body: body,
                        extraHeaders: ["Idempotency-Key": item.messageID.uuidString.lowercased()])
                }
                message.deliveryStatus = .sent
                item.state = "sent"
                try context.save()
                context.delete(item)
                try context.save()
            } catch {
                if item.state == "failed" || item.state == "identityChanged" { throw error }
                if case DeviceSessionError.identityKeyChanged = error {
                    item.attempts = maxAttempts
                    item.state = "identityChanged"
                    message.deliveryStatus = .failed
                    try context.save()
                    throw error
                }
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    item.state = "pending"
                    item.nextAttemptAt = .now
                    try context.save()
                    throw error
                }
                item.attempts += 1
                item.state = item.attempts >= maxAttempts ? "failed" : "pending"
                if item.state == "failed" { message.deliveryStatus = .failed }
                item.nextAttemptAt = Date().addingTimeInterval(min(300, pow(2, Double(item.attempts)) * 3))
                try context.save()
                throw error
            }
        }
    }

    func retryFailed(messageID: UUID) throws {
        if try context.fetch(FetchDescriptor<OutgoingMessageQueueItem>()).contains(where: {
            $0.ownerID == ownerID && $0.backendDeviceID == backendDeviceID &&
            $0.messageID == messageID && $0.state == "identityChanged"
        }) { throw OutgoingQueueError.identityChanged }
        guard let item = try context.fetch(FetchDescriptor<OutgoingMessageQueueItem>()).first(where: {
            $0.ownerID == ownerID && $0.backendDeviceID == backendDeviceID && $0.messageID == messageID && $0.state == "failed"
        }) else { throw OutgoingQueueError.missing }
        item.attempts = 0; item.state = "pending"; item.nextAttemptAt = .now
        if let message = try context.fetch(FetchDescriptor<Message>()).first(where: { $0.id == messageID }) {
            message.deliveryStatus = .sending
        }
        try context.save()
    }

    private func binding(_ item: OutgoingMessageQueueItem) -> Data {
        Data("luma-outbox-v1|\(ownerID.uuidString)|\(item.id.uuidString)|\(item.messageID.uuidString)".utf8)
    }
}
