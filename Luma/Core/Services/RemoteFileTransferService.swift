import CryptoKit
import Foundation

/// Accepts only an already sealed payload. No plaintext Data entry point is exposed.
struct RemoteFileTransferService {
    let client: RemoteAPIClient

    func beginUpload(_ encrypted: EncryptedData) async throws -> UUID {
        let bytes = encrypted.bytes
        let digest = Data(SHA256.hash(data: bytes)).base64URLEncodedString()
        struct Init: Encodable { let ciphertextSize: Int; let ciphertextHash: String }
        struct Ticket: Decodable { let attachmentID: UUID; let uploadPath: String }
        let ticket: Ticket = try await client.json(Ticket.self, method: "POST", path: "/files/upload/init",
            body: JSONEncoder().encode(Init(ciphertextSize: bytes.count, ciphertextHash: digest)))
        guard ticket.uploadPath == "/v1/files/\(ticket.attachmentID.uuidString.lowercased())/upload" else {
            throw RemoteError.invalidResponse
        }
        return ticket.attachmentID
    }

    func finishUpload(_ encrypted: EncryptedData, attachmentID: UUID) async throws {
        _ = try await client.request("PUT", path: "/files/\(attachmentID.uuidString.lowercased())/upload",
                                     body: encrypted.bytes, contentType: "application/octet-stream")
        _ = try await client.request("POST", path: "/files/upload/complete",
                                     body: JSONEncoder().encode(["attachmentID": attachmentID.uuidString.lowercased()]))
    }

    func download(attachmentID: UUID, expectedHash: Data) async throws -> EncryptedData {
        let id = attachmentID.uuidString.lowercased()
        struct Ticket: Decodable { let downloadPath: String }
        let ticket: Ticket = try await client.json(Ticket.self, path: "/files/\(id)/download")
        guard ticket.downloadPath == "/v1/files/\(id)/content" else { throw RemoteError.invalidResponse }
        let bytes = try await client.request("GET", path: "/files/\(id)/content")
        guard Data(SHA256.hash(data: bytes)) == expectedHash else { throw RemoteError.invalidResponse }
        return EncryptedData(bytes: bytes)
    }

    func delete(attachmentID: UUID) async throws {
        _ = try await client.request("DELETE", path: "/files/\(attachmentID.uuidString.lowercased())")
    }
}
