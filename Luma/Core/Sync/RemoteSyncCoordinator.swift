import Foundation
import SwiftData

/// Persists each authenticated remote event before advancing this device's cursor.
@MainActor
struct RemoteSyncCoordinator {
    let repository: RemoteMessageRepository
    private static var inFlightDevices = Set<UUID>()

    @discardableResult
    func sync(limit: Int = 100) async throws -> Int {
        guard try repository.security.currentUserID() == repository.user.userID else {
            throw MessageStoreError.locked
        }
        let deviceID = repository.registration.backendDeviceID
        guard !Self.inFlightDevices.contains(deviceID) else { return 0 }
        Self.inFlightDevices.insert(deviceID)
        defer { Self.inFlightDevices.remove(deviceID) }
        let context = repository.context
        let checkpoint: RemoteSyncCheckpoint
        if let existing = try context.fetch(FetchDescriptor<RemoteSyncCheckpoint>()).first(where: {
            $0.ownerID == repository.user.id &&
            $0.backendDeviceID == repository.registration.backendDeviceID
        }) { checkpoint = existing }
        else {
            checkpoint = RemoteSyncCheckpoint(ownerID: repository.user.id,
                backendDeviceID: repository.registration.backendDeviceID)
            context.insert(checkpoint)
            try context.save()
        }
        let provider = RemoteMessageSyncProvider(client: repository.client)
        if checkpoint.cursor > 0 { try await provider.acknowledge(checkpoint.cursor) }
        let page = try await provider.fetch(after: checkpoint.cursor, limit: limit)
        var applied = 0
        for event in page.events {
            guard event.deviceSeq == checkpoint.cursor + 1 else { throw DeviceSessionError.invalidEnvelope }
            do {
                if event.type == "device.revoked" {
                    try applyDeviceRevoked(event)
                } else {
                    try repository.apply(event)
                }
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
            if event.type == "message.created", let messageID = event.routing.messageID,
               try context.fetch(FetchDescriptor<Message>()).contains(where: { $0.id == messageID && !$0.isMine }) {
                // A failed receipt leaves the event unacked; replay is safe after local persistence.
                _ = try await repository.client.request("POST", path: "/messages/delivered",
                    body: JSONEncoder().encode(["messageID": messageID.uuidString.lowercased()]))
            }
            checkpoint.cursor = event.deviceSeq
            do { try context.save() }
            catch { context.rollback(); throw error }
            try await provider.acknowledge(checkpoint.cursor)
            applied += 1
        }
        return applied
    }

    private func applyDeviceRevoked(_ event: RemoteSyncEvent) throws {
        guard let revoked = event.routing.revokedDeviceID,
              revoked != repository.registration.backendDeviceID else { throw DeviceSessionError.invalidEnvelope }
        let context = repository.context
        for trust in try context.fetch(FetchDescriptor<RemoteDeviceTrust>()).filter({
            $0.ownerID == repository.user.id && $0.backendDeviceID == revoked
        }) { context.delete(trust) }
        // Pending envelopes can contain the revoked recipient; stop replay until recomposed.
        for item in try context.fetch(FetchDescriptor<OutgoingMessageQueueItem>()).filter({
            $0.ownerID == repository.user.id && $0.state != "sent"
        }) { item.state = "failed"; item.attempts = 5 }
    }
}
