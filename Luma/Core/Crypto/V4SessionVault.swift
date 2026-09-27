import CryptoKit
import Foundation

enum V4VaultError: LocalizedError {
    case missing, damaged, incompatible, pendingOperation, rollback

    var errorDescription: String? {
        switch self {
        case .missing: "加密会话密钥不存在，已暂停此会话"
        case .damaged: "加密会话状态已损坏，已暂停收发"
        case .incompatible: "加密会话版本不受支持，请更新应用"
        case .pendingOperation: "上一条加密消息尚未完成保存，请先恢复同步"
        case .rollback: "加密会话状态出现回退，已暂停收发，请重新验证设备"
        }
    }
}

/// All private v4 material stays in this-device-only Keychain records. No recovery key is copied
/// to SwiftData, backup exports, or the server.
struct V4SessionVault {
    /// A Keychain journal records intent across the SwiftData/Keychain boundary.
    /// Missing phase decodes as prepared for journals written by older builds.
    enum TransactionPhase: String, Codable { case prepared, applying, committed, failed }

    struct OutgoingPending: Codable {
        let messageID: UUID
        let request: Data
        let sessions: [Session]
        var phase: TransactionPhase = .prepared

        private enum CodingKeys: String, CodingKey { case messageID, request, sessions, phase }
        init(messageID: UUID, request: Data, sessions: [Session]) {
            self.messageID = messageID; self.request = request; self.sessions = sessions
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            messageID = try values.decode(UUID.self, forKey: .messageID)
            request = try values.decode(Data.self, forKey: .request)
            sessions = try values.decode([Session].self, forKey: .sessions)
            phase = try values.decodeIfPresent(TransactionPhase.self, forKey: .phase) ?? .prepared
        }
    }

    struct IncomingPending: Codable {
        let eventID: UUID
        let deviceSeq: Int64
        let plaintext: Data
        let envelopeDigest: Data
        let session: Session
        let consumedOneTimePublicKey: Data?
        var phase: TransactionPhase = .prepared

        private enum CodingKeys: String, CodingKey {
            case eventID, deviceSeq, plaintext, envelopeDigest, session, consumedOneTimePublicKey, phase
        }
        init(eventID: UUID, deviceSeq: Int64, plaintext: Data, envelopeDigest: Data,
             session: Session, consumedOneTimePublicKey: Data?) {
            self.eventID = eventID; self.deviceSeq = deviceSeq; self.plaintext = plaintext
            self.envelopeDigest = envelopeDigest; self.session = session
            self.consumedOneTimePublicKey = consumedOneTimePublicKey
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            eventID = try values.decode(UUID.self, forKey: .eventID)
            deviceSeq = try values.decode(Int64.self, forKey: .deviceSeq)
            plaintext = try values.decode(Data.self, forKey: .plaintext)
            envelopeDigest = try values.decode(Data.self, forKey: .envelopeDigest)
            session = try values.decode(Session.self, forKey: .session)
            consumedOneTimePublicKey = try values.decodeIfPresent(Data.self, forKey: .consumedOneTimePublicKey)
            phase = try values.decodeIfPresent(TransactionPhase.self, forKey: .phase) ?? .prepared
        }
    }

    struct Session: Codable {
        let formatVersion: Int
        let localDeviceID: UUID
        let remoteDeviceID: UUID
        let remoteUserID: UUID
        let remoteIdentityFingerprint: String
        let sessionVersion: Int
        let recipientKeyVersion: Int
        var ratchet: V4RatchetState
        var initialHeader: V4InitialHeader?
        var stateVersion: UInt64 = 0

        private enum CodingKeys: String, CodingKey {
            case formatVersion, localDeviceID, remoteDeviceID, remoteUserID,
                 remoteIdentityFingerprint, sessionVersion, recipientKeyVersion,
                 ratchet, initialHeader, stateVersion
        }

        init(formatVersion: Int, localDeviceID: UUID, remoteDeviceID: UUID,
             remoteUserID: UUID, remoteIdentityFingerprint: String, sessionVersion: Int,
             recipientKeyVersion: Int, ratchet: V4RatchetState, initialHeader: V4InitialHeader?,
             stateVersion: UInt64 = 0) {
            self.formatVersion = formatVersion; self.localDeviceID = localDeviceID
            self.remoteDeviceID = remoteDeviceID; self.remoteUserID = remoteUserID
            self.remoteIdentityFingerprint = remoteIdentityFingerprint
            self.sessionVersion = sessionVersion; self.recipientKeyVersion = recipientKeyVersion
            self.ratchet = ratchet; self.initialHeader = initialHeader
            self.stateVersion = stateVersion
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try values.decode(Int.self, forKey: .formatVersion)
            localDeviceID = try values.decode(UUID.self, forKey: .localDeviceID)
            remoteDeviceID = try values.decode(UUID.self, forKey: .remoteDeviceID)
            remoteUserID = try values.decode(UUID.self, forKey: .remoteUserID)
            remoteIdentityFingerprint = try values.decode(String.self, forKey: .remoteIdentityFingerprint)
            sessionVersion = try values.decode(Int.self, forKey: .sessionVersion)
            recipientKeyVersion = try values.decode(Int.self, forKey: .recipientKeyVersion)
            ratchet = try values.decode(V4RatchetState.self, forKey: .ratchet)
            initialHeader = try values.decodeIfPresent(V4InitialHeader.self, forKey: .initialHeader)
            stateVersion = try values.decodeIfPresent(UInt64.self, forKey: .stateVersion) ?? 0
        }

        func validate(local: UUID, remote: UUID) throws {
            guard formatVersion == 1 else { throw V4VaultError.incompatible }
            guard localDeviceID == local, remoteDeviceID == remote, sessionVersion > 0,
                  recipientKeyVersion > 0,
                  remoteIdentityFingerprint.count == 64 else {
                throw V4VaultError.damaged
            }
            try ratchet.validate()
        }
    }

    struct DeviceSecrets: Codable {
        let formatVersion: Int
        let deviceID: UUID
        let keyVersion: Int
        let identityAgreement: Data
        let identitySigning: Data
        let signedPreKey: Data
        var oneTimePreKeys: [String: Data]
        var pendingOneTimePreKeys: [String] = []

        private enum CodingKeys: String, CodingKey {
            case formatVersion, deviceID, keyVersion, identityAgreement,
                 identitySigning, signedPreKey, oneTimePreKeys, pendingOneTimePreKeys
        }

        init(formatVersion: Int, deviceID: UUID, keyVersion: Int,
             identityAgreement: Data, identitySigning: Data, signedPreKey: Data,
             oneTimePreKeys: [String: Data], pendingOneTimePreKeys: [String] = []) {
            self.formatVersion = formatVersion; self.deviceID = deviceID
            self.keyVersion = keyVersion; self.identityAgreement = identityAgreement
            self.identitySigning = identitySigning; self.signedPreKey = signedPreKey
            self.oneTimePreKeys = oneTimePreKeys
            self.pendingOneTimePreKeys = pendingOneTimePreKeys
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try values.decode(Int.self, forKey: .formatVersion)
            deviceID = try values.decode(UUID.self, forKey: .deviceID)
            keyVersion = try values.decode(Int.self, forKey: .keyVersion)
            identityAgreement = try values.decode(Data.self, forKey: .identityAgreement)
            identitySigning = try values.decode(Data.self, forKey: .identitySigning)
            signedPreKey = try values.decode(Data.self, forKey: .signedPreKey)
            oneTimePreKeys = try values.decode([String: Data].self, forKey: .oneTimePreKeys)
            pendingOneTimePreKeys = try values.decodeIfPresent([String].self,
                forKey: .pendingOneTimePreKeys) ?? []
        }

        func identity() throws -> V4IdentityKeys {
            guard formatVersion == 1, keyVersion > 0,
                  let agreement = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identityAgreement),
                  let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: identitySigning),
                  (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: signedPreKey)) != nil,
                  pendingOneTimePreKeys.allSatisfy({ oneTimePreKeys[$0] != nil }),
                  oneTimePreKeys.values.allSatisfy({
                      (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0)) != nil
                  }) else { throw V4VaultError.damaged }
            return V4IdentityKeys(agreement: agreement, signing: signing)
        }

        func signedKey() throws -> Curve25519.KeyAgreement.PrivateKey {
            _ = try identity()
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: signedPreKey)
        }

        func oneTimeKey(publicKey: Data) throws -> Curve25519.KeyAgreement.PrivateKey {
            guard let bytes = oneTimePreKeys[publicKey.base64EncodedString()],
                  let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes),
                  key.publicKey.rawRepresentation == publicKey else { throw V4VaultError.missing }
            return key
        }
    }

    let keychain: KeychainManager
    init(keychain: KeychainManager = KeychainManager()) { self.keychain = keychain }

    func loadSession(userID: String, local: UUID, remote: UUID) throws -> Session? {
        guard let bytes = try keychain.read(sessionAccount(userID, local, remote)) else { return nil }
        guard let session = try? JSONDecoder().decode(Session.self, from: bytes) else { throw V4VaultError.damaged }
        try session.validate(local: local, remote: remote)
        if let floor = try readVersion(userID: userID, local: local, remote: remote),
           session.stateVersion < floor { throw V4VaultError.rollback }
        return session
    }

    func saveSession(_ session: Session, userID: String) throws {
        try session.validate(local: session.localDeviceID, remote: session.remoteDeviceID)
        let account = sessionAccount(userID, session.localDeviceID, session.remoteDeviceID)
        let bytes = try JSONEncoder().encode(session)
        let floor = try readVersion(userID: userID, local: session.localDeviceID,
                                     remote: session.remoteDeviceID)
        if let floor, session.stateVersion < floor { throw V4VaultError.rollback }
        if let current = try loadSession(userID: userID, local: session.localDeviceID,
                                          remote: session.remoteDeviceID) {
            if session.stateVersion < current.stateVersion { throw V4VaultError.rollback }
            if session.stateVersion == current.stateVersion {
                let candidate = try JSONSerialization.jsonObject(with: bytes) as? NSDictionary
                let stored = try JSONSerialization.jsonObject(
                    with: keychain.readRequired(account)) as? NSDictionary
                guard candidate == stored else { throw V4VaultError.rollback }
                // Retrying after session write but before the high-water write
                // must finish the guard record as well.
                if (floor ?? 0) < session.stateVersion {
                    try keychain.save(JSONEncoder().encode(session.stateVersion),
                        account: versionAccount(userID, session.localDeviceID, session.remoteDeviceID))
                }
                return
            }
            guard session.stateVersion == current.stateVersion + 1,
                  session.remoteUserID == current.remoteUserID,
                  session.remoteIdentityFingerprint == current.remoteIdentityFingerprint,
                  session.sessionVersion == current.sessionVersion else { throw V4VaultError.rollback }
        } else if floor != nil || session.stateVersion != 1 { throw V4VaultError.rollback }
        try keychain.save(bytes, account: account)
        try keychain.save(JSONEncoder().encode(session.stateVersion),
            account: versionAccount(userID, session.localDeviceID, session.remoteDeviceID))
    }

    func deleteSession(userID: String, local: UUID, remote: UUID) throws {
        try keychain.delete(sessionAccount(userID, local, remote))
        try keychain.delete(versionAccount(userID, local, remote))
    }

    func loadDevice(userID: String, deviceID: UUID) throws -> DeviceSecrets? {
        guard let bytes = try keychain.read(deviceAccount(userID, deviceID)) else { return nil }
        guard let secrets = try? JSONDecoder().decode(DeviceSecrets.self, from: bytes),
              secrets.deviceID == deviceID else { throw V4VaultError.damaged }
        _ = try secrets.identity()
        return secrets
    }

    func saveDevice(_ secrets: DeviceSecrets, userID: String) throws {
        _ = try secrets.identity()
        try keychain.save(JSONEncoder().encode(secrets), account: deviceAccount(userID, secrets.deviceID))
    }

    func deleteDevice(userID: String, deviceID: UUID) throws {
        try keychain.delete(deviceAccount(userID, deviceID))
    }

    func outgoingPending(userID: String, deviceID: UUID) throws -> OutgoingPending? {
        guard let bytes = try keychain.read(outgoingAccount(userID, deviceID)) else { return nil }
        guard let value = try? JSONDecoder().decode(OutgoingPending.self, from: bytes) else { throw V4VaultError.damaged }
        return value
    }

    func stageOutgoing(_ pending: OutgoingPending, userID: String, deviceID: UUID) throws {
        if let current = try outgoingPending(userID: userID, deviceID: deviceID),
           current.messageID != pending.messageID { throw V4VaultError.pendingOperation }
        try keychain.save(JSONEncoder().encode(pending), account: outgoingAccount(userID, deviceID))
    }

    func finishOutgoing(userID: String, deviceID: UUID, messageID: UUID) throws {
        guard var pending = try outgoingPending(userID: userID, deviceID: deviceID) else { return }
        guard pending.messageID == messageID else { throw V4VaultError.pendingOperation }
        pending.phase = .applying
        try keychain.save(JSONEncoder().encode(pending), account: outgoingAccount(userID, deviceID))
        do {
            for var session in pending.sessions {
                if session.stateVersion == 0 { session.stateVersion = 1 } // older pending journal
                try saveSession(session, userID: userID)
            }
            pending.phase = .committed
            try keychain.save(JSONEncoder().encode(pending), account: outgoingAccount(userID, deviceID))
            try keychain.delete(outgoingAccount(userID, deviceID))
        } catch {
            pending.phase = .failed
            try? keychain.save(JSONEncoder().encode(pending), account: outgoingAccount(userID, deviceID))
            throw error
        }
    }

    func cancelOutgoing(userID: String, deviceID: UUID, messageID: UUID) throws {
        guard let pending = try outgoingPending(userID: userID, deviceID: deviceID) else { return }
        guard pending.messageID == messageID else { throw V4VaultError.pendingOperation }
        if pending.phase != .prepared {
            // A partially saved multi-recipient ratchet cannot be rolled back.
            // Complete every candidate chain before discarding an unsent event.
            try finishOutgoing(userID: userID, deviceID: deviceID, messageID: messageID)
            return
        }
        try keychain.delete(outgoingAccount(userID, deviceID))
    }

    func incomingPending(userID: String, deviceID: UUID) throws -> IncomingPending? {
        guard let bytes = try keychain.read(incomingAccount(userID, deviceID)) else { return nil }
        guard let value = try? JSONDecoder().decode(IncomingPending.self, from: bytes) else { throw V4VaultError.damaged }
        return value
    }

    func stageIncoming(_ pending: IncomingPending, userID: String, deviceID: UUID) throws {
        if let current = try incomingPending(userID: userID, deviceID: deviceID),
           current.eventID != pending.eventID { throw V4VaultError.pendingOperation }
        try keychain.save(JSONEncoder().encode(pending), account: incomingAccount(userID, deviceID))
    }

    func finishIncoming(userID: String, deviceID: UUID, eventID: UUID) throws {
        guard var pending = try incomingPending(userID: userID, deviceID: deviceID) else { return }
        guard pending.eventID == eventID else { throw V4VaultError.pendingOperation }
        pending.phase = .applying
        try keychain.save(JSONEncoder().encode(pending), account: incomingAccount(userID, deviceID))
        do {
            var session = pending.session
            if session.stateVersion == 0 { session.stateVersion = 1 } // older pending journal
            try saveSession(session, userID: userID)
            if let oneTime = pending.consumedOneTimePublicKey {
                guard var device = try loadDevice(userID: userID, deviceID: deviceID) else { throw V4VaultError.missing }
                let publicKey = oneTime.base64EncodedString()
                device.oneTimePreKeys.removeValue(forKey: publicKey)
                device.pendingOneTimePreKeys.removeAll { $0 == publicKey }
                try saveDevice(device, userID: userID)
            }
            pending.phase = .committed
            try keychain.save(JSONEncoder().encode(pending), account: incomingAccount(userID, deviceID))
            try keychain.delete(incomingAccount(userID, deviceID))
        } catch {
            pending.phase = .failed
            try? keychain.save(JSONEncoder().encode(pending), account: incomingAccount(userID, deviceID))
            throw error
        }
    }

    func recoverIncoming(userID: String, deviceID: UUID, committedCursor: Int64) throws {
        guard let pending = try incomingPending(userID: userID, deviceID: deviceID),
              pending.deviceSeq <= committedCursor else { return }
        try finishIncoming(userID: userID, deviceID: deviceID, eventID: pending.eventID)
    }

    func deleteAll(userID: String, deviceID: UUID, peers: [UUID]) throws {
        try keychain.delete(outgoingAccount(userID, deviceID))
        try keychain.delete(incomingAccount(userID, deviceID))
        for peer in peers { try deleteSession(userID: userID, local: deviceID, remote: peer) }
        try deleteDevice(userID: userID, deviceID: deviceID)
    }

    /// Removes material for a revoked device or an identity that must be reverified.
    /// Pending journals referencing that peer cannot be replayed with stale trust.
    func deletePeer(userID: String, localDeviceID: UUID, remoteDeviceID: UUID) throws {
        try deleteSession(userID: userID, local: localDeviceID, remote: remoteDeviceID)
        if let pending = try outgoingPending(userID: userID, deviceID: localDeviceID),
           pending.sessions.contains(where: { $0.remoteDeviceID == remoteDeviceID }) {
            try keychain.delete(outgoingAccount(userID, localDeviceID))
        }
        if let pending = try incomingPending(userID: userID, deviceID: localDeviceID),
           pending.session.remoteDeviceID == remoteDeviceID {
            try keychain.delete(incomingAccount(userID, localDeviceID))
        }
    }

    func discardPendingForRemoteUser(userID: String, localDeviceID: UUID,
                                     remoteUserID: UUID) throws {
        if let pending = try outgoingPending(userID: userID, deviceID: localDeviceID),
           pending.sessions.contains(where: { $0.remoteUserID == remoteUserID }) {
            try keychain.delete(outgoingAccount(userID, localDeviceID))
        }
        if let pending = try incomingPending(userID: userID, deviceID: localDeviceID),
           pending.session.remoteUserID == remoteUserID {
            try keychain.delete(incomingAccount(userID, localDeviceID))
        }
    }

    func purgeAccount(userID: String) throws {
        for category in ["session", "version", "device", "outgoing", "incoming"] {
            try keychain.deleteAccounts(prefix: "v4.\(category).\(userID).")
        }
    }

    private func sessionAccount(_ userID: String, _ local: UUID, _ remote: UUID) -> String {
        "v4.session.\(userID).\(local.uuidString).\(remote.uuidString)"
    }

    private func versionAccount(_ userID: String, _ local: UUID, _ remote: UUID) -> String {
        "v4.version.\(userID).\(local.uuidString).\(remote.uuidString)"
    }

    private func readVersion(userID: String, local: UUID, remote: UUID) throws -> UInt64? {
        guard let bytes = try keychain.read(versionAccount(userID, local, remote)) else { return nil }
        guard let version = try? JSONDecoder().decode(UInt64.self, from: bytes) else {
            throw V4VaultError.damaged
        }
        return version
    }

    private func deviceAccount(_ userID: String, _ device: UUID) -> String {
        "v4.device.\(userID).\(device.uuidString)"
    }

    private func outgoingAccount(_ userID: String, _ device: UUID) -> String {
        "v4.outgoing.\(userID).\(device.uuidString)"
    }

    private func incomingAccount(_ userID: String, _ device: UUID) -> String {
        "v4.incoming.\(userID).\(device.uuidString)"
    }
}
