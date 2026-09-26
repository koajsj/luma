import Foundation

// These boundaries keep local phase-one behavior explicit. Implementations must be added
// before any UI can describe remote delivery or cryptographic protection as active.
// MessageTransport now lives in Core/Transport with an event-based API.

protocol EndToEndCryptography {
    func encrypt(_ plaintext: Data, for recipientID: String) throws -> Data
    func decrypt(_ ciphertext: Data, from senderID: String) throws -> Data
}

protocol AttachmentCryptography {
    func encryptFile(at source: URL) throws -> URL
    func decryptFile(at source: URL) throws -> URL
}

protocol DeviceSynchronizing {
    func synchronize() async throws
}
