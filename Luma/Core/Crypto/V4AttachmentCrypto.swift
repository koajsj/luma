import CryptoKit
import Foundation

enum V4AttachmentError: LocalizedError {
    case invalidDescriptor, tooLarge, missingLocalFile

    var errorDescription: String? {
        switch self {
        case .invalidDescriptor: "附件信息无效或文件已被篡改"
        case .tooLarge: "附件不能超过 20 MB"
        case .missingLocalFile: "附件本地副本不存在，请重新选择文件"
        }
    }
}

/// This value is serialized only inside a v4 ratchet message or Master Key encrypted metadata.
struct V4AttachmentDescriptor: Codable {
    let attachmentID: UUID
    let remoteObjectID: UUID?
    let messageID: UUID
    let conversationID: UUID
    let type: MessageType
    let name: String
    let key: Data
    let ciphertextHash: Data?

    func withUpload(id: UUID, hash: Data) -> Self {
        .init(attachmentID: attachmentID, remoteObjectID: id, messageID: messageID,
              conversationID: conversationID, type: type, name: name, key: key,
              ciphertextHash: hash)
    }

    func withoutUpload() -> Self {
        .init(attachmentID: attachmentID, remoteObjectID: nil, messageID: messageID,
              conversationID: conversationID, type: type, name: name, key: key,
              ciphertextHash: nil)
    }

    func withConversation(_ id: UUID) -> Self {
        .init(attachmentID: attachmentID, remoteObjectID: remoteObjectID, messageID: messageID,
              conversationID: id, type: type, name: name, key: key,
              ciphertextHash: ciphertextHash)
    }
}

struct V4AttachmentPayload: Codable {
    let kind: String
    let senderUserID: String
    let targetUserID: String
    let attachment: V4AttachmentDescriptor
}

struct V4AttachmentIntent: Codable {
    let kind: String
    let attachmentID: UUID
}

/// A fresh random 256-bit key is carried only within the per-device v4 message.
/// The server stores the AES-GCM combined ciphertext and SHA-256 of that ciphertext.
enum V4AttachmentCrypto {
    static func makeDescriptor(attachmentID: UUID, messageID: UUID, conversationID: UUID,
                               type: MessageType, name: String) -> V4AttachmentDescriptor {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return .init(attachmentID: attachmentID, remoteObjectID: nil, messageID: messageID,
                     conversationID: conversationID, type: type, name: name, key: key,
                     ciphertextHash: nil)
    }

    static func encrypt(_ data: Data, descriptor: V4AttachmentDescriptor) throws -> EncryptedData {
        guard data.count <= 20 << 20, descriptor.key.count == 32 else { throw V4AttachmentError.tooLarge }
        let box = try AES.GCM.seal(data, using: SymmetricKey(data: descriptor.key),
                                   authenticating: binding(descriptor))
        guard let combined = box.combined else { throw V4AttachmentError.invalidDescriptor }
        return EncryptedData(bytes: combined)
    }

    static func decrypt(_ encrypted: EncryptedData, descriptor: V4AttachmentDescriptor) throws -> Data {
        guard descriptor.key.count == 32, let expected = descriptor.ciphertextHash,
              expected.count == 32, descriptor.remoteObjectID != nil,
              Data(SHA256.hash(data: encrypted.bytes)) == expected else { throw V4AttachmentError.invalidDescriptor }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted.bytes),
                                    using: SymmetricKey(data: descriptor.key),
                                    authenticating: binding(descriptor))
        } catch { throw V4AttachmentError.invalidDescriptor }
    }

    static func validate(_ descriptor: V4AttachmentDescriptor, messageID: UUID,
                         conversationID: UUID) throws {
        guard descriptor.messageID == messageID, descriptor.conversationID == conversationID,
              descriptor.type != .text, descriptor.key.count == 32,
              descriptor.remoteObjectID != nil, descriptor.ciphertextHash?.count == 32,
              !descriptor.name.isEmpty, descriptor.name.utf8.count <= 255,
              !descriptor.name.contains("/") && !descriptor.name.contains("\\") else {
            throw V4AttachmentError.invalidDescriptor
        }
    }

    private static func binding(_ value: V4AttachmentDescriptor) -> Data {
        Data("luma.v4.attachment|\(value.attachmentID.uuidString.lowercased())|\(value.messageID.uuidString.lowercased())|\(value.conversationID.uuidString.lowercased())|\(value.type.rawValue)".utf8)
    }
}
