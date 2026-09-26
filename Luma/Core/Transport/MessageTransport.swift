import Foundation

/// Transport boundary for a future authenticated server connection.
@MainActor
protocol MessageTransport {
    func sendMessage(_ event: MessageEvent, to endpoint: String) throws
    func receiveMessage(for endpoint: String) throws -> MessageEvent?
    func syncMessages(for endpoint: String) throws -> [MessageEvent]
    func acknowledgeMessage(_ event: MessageEvent, to endpoint: String) throws
    func deleteMessage(_ event: MessageEvent, to endpoint: String) throws
    func pendingMessages(for endpoint: String) throws -> [MessageEvent]
    func completeMessage(_ eventID: UUID, for endpoint: String) throws
}

/// In-memory two-endpoint simulator. It does not report real delivery or network state.
@MainActor
final class MockMessageTransport: MessageTransport {
    private var mailboxes: [String: [MessageEvent]] = [:]

    func sendMessage(_ event: MessageEvent, to endpoint: String) throws {
        mailboxes[endpoint, default: []].append(event)
    }

    func receiveMessage(for endpoint: String) throws -> MessageEvent? {
        guard mailboxes[endpoint]?.isEmpty == false else { return nil }
        return mailboxes[endpoint]?.removeFirst()
    }

    func syncMessages(for endpoint: String) throws -> [MessageEvent] {
        let events = mailboxes[endpoint] ?? []
        mailboxes[endpoint] = []
        return events
    }

    func acknowledgeMessage(_ event: MessageEvent, to endpoint: String) throws {
        try sendMessage(event, to: endpoint)
    }

    func deleteMessage(_ event: MessageEvent, to endpoint: String) throws {
        try sendMessage(event, to: endpoint)
    }

    func pendingMessages(for endpoint: String) throws -> [MessageEvent] { mailboxes[endpoint] ?? [] }

    func completeMessage(_ eventID: UUID, for endpoint: String) throws {
        mailboxes[endpoint]?.removeAll { $0.id == eventID }
    }
}
