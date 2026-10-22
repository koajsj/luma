import Foundation

/// Retries the already encrypted bytes. Neither HTTP success nor server routing is a
/// cryptographic confirmation; only authenticated controls may advance coordination.
struct RemoteSessionControlProvider {
    let client: RemoteAPIClient

    func send(_ item: V4RecoveryControlOutbox) async throws {
        struct Request: Encodable {
            let controlID: UUID
            let conversationID: UUID
            let receiverDeviceID: UUID
            let encryptionVersion: Int
            let envelope: String
        }
        _ = try await client.request("POST", path: "/sessions/controls", body: JSONEncoder().encode(
            Request(controlID: item.id, conversationID: item.conversationID,
                receiverDeviceID: item.receiverDeviceID, encryptionVersion: 4,
                envelope: item.wire.base64URLEncodedString())))
    }
}
