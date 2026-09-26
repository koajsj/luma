import Foundation
import SwiftData

@MainActor
final class PresenceService: PresenceProvider {
    let context: ModelContext
    private var typing: [UUID: TypingStatus] = [:]

    init(context: ModelContext) { self.context = context }

    func snapshot(for friendID: UUID) throws -> PresenceSnapshot {
        let record = try context.fetch(FetchDescriptor<UserPresence>()).first { $0.friendID == friendID }
        return PresenceSnapshot(onlineStatus: record?.onlineStatus ?? .unknown,
                                lastSeenAt: record?.lastSeenAt, typingStatus: typing[friendID] ?? .idle,
                                isMock: true)
    }

    func setMockOnline(_ online: Bool, for friendID: UUID) throws {
        let record = try context.fetch(FetchDescriptor<UserPresence>()).first { $0.friendID == friendID }
            ?? UserPresence(friendID: friendID)
        if record.modelContext == nil { context.insert(record) }
        record.onlineStatus = online ? .online : .offline
        record.lastSeenAt = .now
        try context.save()
    }

    func setMockTyping(_ value: TypingStatus, for friendID: UUID) throws { typing[friendID] = value }
}
