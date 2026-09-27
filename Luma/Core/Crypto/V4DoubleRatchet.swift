import CryptoKit
import Foundation

/// Non-header-encrypted Double Ratchet state. Persist only in device-only Keychain records.
struct V4RatchetState: Codable {
    var rootKey: Data
    var sendingChainKey: Data?
    var receivingChainKey: Data?
    var ownRatchetPrivateKey: Data
    var remoteRatchetPublicKey: Data?
    var sendingIndex: Int
    var receivingIndex: Int
    var previousSendingLength: Int
    var skippedKeys: [String: Data]

    func validate() throws {
        guard rootKey.count == 32, ownRatchetPrivateKey.count == 32,
              sendingChainKey == nil || sendingChainKey?.count == 32,
              receivingChainKey == nil || receivingChainKey?.count == 32,
              remoteRatchetPublicKey == nil || remoteRatchetPublicKey?.count == 32,
              sendingIndex >= 0, receivingIndex >= 0, previousSendingLength >= 0,
              skippedKeys.count <= 2_000, skippedKeys.values.allSatisfy({ $0.count == 32 }),
              (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ownRatchetPrivateKey)) != nil else {
            throw V4ProtocolError.invalidHandshake
        }
    }

    static func initiator(sharedSecret: SymmetricKey,
                          ownEphemeral: Curve25519.KeyAgreement.PrivateKey,
                          remoteSignedPreKey: Data) throws -> V4RatchetState {
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteSignedPreKey)
        let (root, sending) = try advanceRoot(keyData(sharedSecret),
            dh: ownEphemeral.sharedSecretFromKeyAgreement(with: remote))
        return V4RatchetState(rootKey: root, sendingChainKey: sending,
            receivingChainKey: nil, ownRatchetPrivateKey: ownEphemeral.rawRepresentation,
            remoteRatchetPublicKey: remoteSignedPreKey, sendingIndex: 0, receivingIndex: 0,
            previousSendingLength: 0, skippedKeys: [:])
    }

    static func responder(sharedSecret: SymmetricKey,
                          ownSignedPreKey: Curve25519.KeyAgreement.PrivateKey) -> V4RatchetState {
        V4RatchetState(rootKey: keyData(sharedSecret), sendingChainKey: nil,
            receivingChainKey: nil, ownRatchetPrivateKey: ownSignedPreKey.rawRepresentation,
            remoteRatchetPublicKey: nil, sendingIndex: 0, receivingIndex: 0,
            previousSendingLength: 0, skippedKeys: [:])
    }

    mutating func encrypt(_ plaintext: Data, messageID: UUID, conversationID: UUID,
                          senderDeviceID: UUID, receiverDeviceID: UUID,
                          initialHeader: V4InitialHeader? = nil, sessionVersion: Int = 1) throws -> V4RatchetMessage {
        guard let chain = sendingChainKey, sendingIndex < Int.max else { throw V4ProtocolError.invalidHandshake }
        let (next, messageKey) = Self.advanceChain(chain)
        let keyPair = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ownRatchetPrivateKey)
        let header = V4RatchetMessage(messageID: messageID, conversationID: conversationID,
            senderDeviceID: senderDeviceID, receiverDeviceID: receiverDeviceID,
            encryptionVersion: 4, ratchetPublicKey: keyPair.publicKey.rawRepresentation,
            previousChainLength: previousSendingLength, messageIndex: sendingIndex,
            sessionVersion: sessionVersion, initialHeader: initialHeader,
            nonce: Data(), ciphertext: Data(), authenticationTag: Data())
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: messageKey),
                                      authenticating: header.authenticatedHeader())
        let result = V4RatchetMessage(messageID: header.messageID, conversationID: header.conversationID,
            senderDeviceID: header.senderDeviceID, receiverDeviceID: header.receiverDeviceID,
            encryptionVersion: 4, ratchetPublicKey: header.ratchetPublicKey,
            previousChainLength: header.previousChainLength, messageIndex: header.messageIndex,
            sessionVersion: header.sessionVersion, initialHeader: header.initialHeader,
            nonce: sealed.nonce.withUnsafeBytes { Data($0) }, ciphertext: sealed.ciphertext,
            authenticationTag: sealed.tag)
        sendingChainKey = next
        sendingIndex += 1
        return result
    }

    mutating func decrypt(_ message: V4RatchetMessage, expectedReceiver: UUID,
                          expectedSender: UUID, expectedConversation: UUID) throws -> Data {
        guard message.encryptionVersion == 4, message.receiverDeviceID == expectedReceiver,
              message.senderDeviceID == expectedSender,
              message.conversationID == expectedConversation,
              message.messageIndex >= 0, message.previousChainLength >= 0, message.sessionVersion > 0,
              message.nonce.count == 12, message.authenticationTag.count == 16,
              message.ciphertext.count <= 1_048_576,
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.ratchetPublicKey)) != nil else {
            throw V4ProtocolError.invalidMessage
        }
        let id = Self.skippedID(publicKey: message.ratchetPublicKey, index: message.messageIndex)
        if let key = skippedKeys[id] {
            let plaintext = try Self.open(message, key: key)
            skippedKeys.removeValue(forKey: id)
            return plaintext
        }
        var candidate = self
        if candidate.remoteRatchetPublicKey != message.ratchetPublicKey {
            try candidate.skipKeys(until: message.previousChainLength)
            try candidate.ratchet(to: message.ratchetPublicKey)
        }
        guard message.messageIndex >= candidate.receivingIndex else { throw V4ProtocolError.replay }
        try candidate.skipKeys(until: message.messageIndex)
        guard let chain = candidate.receivingChainKey else { throw V4ProtocolError.invalidHandshake }
        let (next, key) = Self.advanceChain(chain)
        let plaintext = try Self.open(message, key: key)
        candidate.receivingChainKey = next
        candidate.receivingIndex += 1
        self = candidate
        return plaintext
    }

    private mutating func skipKeys(until target: Int) throws {
        guard target >= receivingIndex, target - receivingIndex <= 2_000,
              skippedKeys.count + target - receivingIndex <= 2_000 else {
            throw V4ProtocolError.tooManySkipped
        }
        guard target == receivingIndex || receivingChainKey != nil else { throw V4ProtocolError.invalidHandshake }
        while receivingIndex < target {
            guard let chain = receivingChainKey, let remote = remoteRatchetPublicKey else {
                throw V4ProtocolError.invalidHandshake
            }
            let (next, key) = Self.advanceChain(chain)
            skippedKeys[Self.skippedID(publicKey: remote, index: receivingIndex)] = key
            receivingChainKey = next
            receivingIndex += 1
        }
    }

    private mutating func ratchet(to publicKey: Data) throws {
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        let oldPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ownRatchetPrivateKey)
        previousSendingLength = sendingIndex
        sendingIndex = 0
        receivingIndex = 0
        remoteRatchetPublicKey = publicKey
        let (receiveRoot, receiveChain) = try Self.advanceRoot(rootKey,
            dh: oldPrivate.sharedSecretFromKeyAgreement(with: remote))
        let newPrivate = Curve25519.KeyAgreement.PrivateKey()
        let (sendRoot, sendChain) = try Self.advanceRoot(receiveRoot,
            dh: newPrivate.sharedSecretFromKeyAgreement(with: remote))
        rootKey = sendRoot
        receivingChainKey = receiveChain
        sendingChainKey = sendChain
        ownRatchetPrivateKey = newPrivate.rawRepresentation
    }

    private static func open(_ message: V4RatchetMessage, key: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: message.nonce),
                ciphertext: message.ciphertext, tag: message.authenticationTag)
            return try AES.GCM.open(box, using: SymmetricKey(data: key),
                                    authenticating: message.authenticatedHeader())
        } catch { throw V4ProtocolError.invalidMessage }
    }

    private static func advanceRoot(_ root: Data, dh: SharedSecret) throws -> (Data, Data) {
        let material = dh.withUnsafeBytes { Data($0) }
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material),
            salt: root, info: Data("luma.v4.double-ratchet.root".utf8), outputByteCount: 64)
        let bytes = keyData(derived)
        return (Data(bytes.prefix(32)), Data(bytes.suffix(32)))
    }

    private static func advanceChain(_ chain: Data) -> (Data, Data) {
        let key = SymmetricKey(data: chain)
        let next = Data(HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: key))
        let message = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: key))
        return (next, message)
    }

    private static func skippedID(publicKey: Data, index: Int) -> String {
        publicKey.base64EncodedString() + ":" + String(index)
    }

    private static func keyData(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
}

struct V4RatchetMessage: Codable {
    let messageID: UUID
    let conversationID: UUID
    let senderDeviceID: UUID
    let receiverDeviceID: UUID
    let encryptionVersion: Int
    let ratchetPublicKey: Data
    let previousChainLength: Int
    let messageIndex: Int
    let sessionVersion: Int
    let initialHeader: V4InitialHeader?
    let nonce: Data
    let ciphertext: Data
    let authenticationTag: Data

    func authenticatedHeader() -> Data {
        V4Handshake.fields("luma.v4.message", [Data(messageID.uuidString.lowercased().utf8),
            Data(conversationID.uuidString.lowercased().utf8),
            Data(senderDeviceID.uuidString.lowercased().utf8),
            Data(receiverDeviceID.uuidString.lowercased().utf8),
            Data(String(encryptionVersion).utf8), ratchetPublicKey,
            Data(String(previousChainLength).utf8), Data(String(messageIndex).utf8),
            Data(String(sessionVersion).utf8), initialHeader?.transcript() ?? Data(),
            initialHeader?.signature ?? Data()])
    }
}
