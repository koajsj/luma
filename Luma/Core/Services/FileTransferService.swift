import Foundation

enum FileTransferError: LocalizedError {
    case missing
    var errorDescription: String? { "本机加密附件不存在或已被清理" }
}

/// Local encrypted object store. The file name is an opaque attachment ID; metadata stays in SwiftData.
@MainActor
struct FileTransferService: FileProvider {
    let ownerID: UUID
    let encryption: EncryptionService
    var root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LumaAttachments", isDirectory: true)

    func upload(_ data: Data, attachmentID: UUID) throws {
        let directory = accountDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        let sealed = try encryption.encrypt(data, authenticatedData: associatedData(attachmentID)).bytes
        try sealed.write(to: url(for: attachmentID), options: [.atomic, .completeFileProtection])
    }

    func download(attachmentID: UUID) throws -> Data {
        let url = url(for: attachmentID)
        guard FileManager.default.fileExists(atPath: url.path) else { throw FileTransferError.missing }
        return try encryption.decrypt(EncryptedData(bytes: Data(contentsOf: url)),
                                      authenticatedData: associatedData(attachmentID))
    }

    func delete(attachmentID: UUID) throws {
        let file = url(for: attachmentID)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    func purgeAccount() throws {
        try Self.purgeAccount(ownerID: ownerID, root: root)
    }

    static func purgeAccount(ownerID: UUID, root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LumaAttachments", isDirectory: true)) throws {
        let accountDirectory = root.appendingPathComponent(ownerID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: accountDirectory.path) {
            try FileManager.default.removeItem(at: accountDirectory)
        }
    }

    private var accountDirectory: URL { root.appendingPathComponent(ownerID.uuidString, isDirectory: true) }
    private func url(for id: UUID) -> URL { accountDirectory.appendingPathComponent(id.uuidString + ".luma") }
    private func associatedData(_ id: UUID) -> Data { Data("luma-attachment-file-v1|\(ownerID.uuidString)|\(id.uuidString)".utf8) }
}
