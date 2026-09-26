import CryptoKit
import Foundation
import SwiftData

enum RatchetError: LocalizedError {
    case invalidIndex, missingState
    var errorDescription: String? {
        switch self {
        case .invalidIndex: "消息密钥序号无效或超出本机支持范围"
        case .missingState: "链式密钥状态丢失，无法继续发送"
        }
    }
}

/// Basic symmetric chain for local simulation. Retained session roots permit old-message reads,
/// so this does not provide forward secrecy or a Double Ratchet.
@MainActor
struct RatchetManager {
    let context: ModelContext
    let keychain: KeychainManager
    let sessions: SessionManager

    func nextKey(session: SessionKey, senderID: String) throws -> (key: SymmetricKey, index: Int) {
        let version = session.keyVersion
        let state = try stateFor(session: session, senderID: senderID, version: version)
        let current: SymmetricKey
        if let state {
            guard let bytes = try keychain.read(account(for: state)), bytes.count == 32 else { throw RatchetError.missingState }
            current = SymmetricKey(data: bytes)
        } else {
            current = try initialKey(session: session, senderID: senderID, version: version)
        }
        let index = (state?.messageIndex ?? 0) + 1
        guard index <= 100_000 else { throw RatchetError.invalidIndex }
        let messageKey = derive(current, label: "message")
        let next = derive(current, label: "next")
        let record = state ?? ChainState(sessionID: session.id, senderID: senderID, chainVersion: version)
        try keychain.save(next.withUnsafeBytes { Data($0) }, account: account(for: record))
        if state == nil { context.insert(record) }
        record.messageIndex = index
        try context.save()
        return (messageKey, index)
    }

    func key(session: SessionKey, senderID: String, version: Int, index: Int) throws -> SymmetricKey {
        guard (1...100_000).contains(index), (1...session.keyVersion).contains(version) else { throw RatchetError.invalidIndex }
        var chain = try initialKey(session: session, senderID: senderID, version: version)
        for _ in 1..<index { chain = derive(chain, label: "next") }
        return derive(chain, label: "message")
    }

    func advanceReceived(session: SessionKey, senderID: String, version: Int, index: Int) throws {
        let state = try stateFor(session: session, senderID: senderID, version: version)
        guard index > (state?.messageIndex ?? 0) else { return }
        // The receiver can recover from its retained root in this local-only phase.
        var chain = try initialKey(session: session, senderID: senderID, version: version)
        for _ in 0..<index { chain = derive(chain, label: "next") }
        let record = state ?? ChainState(sessionID: session.id, senderID: senderID, chainVersion: version)
        try keychain.save(chain.withUnsafeBytes { Data($0) }, account: account(for: record))
        if state == nil { context.insert(record) }
        record.messageIndex = index
        try context.save()
    }

    func deleteStates(for sessionID: UUID) throws {
        for state in try context.fetch(FetchDescriptor<ChainState>()).filter({ $0.sessionID == sessionID }) {
            try keychain.delete(account(for: state))
            context.delete(state)
        }
        try context.save()
    }

    private func stateFor(session: SessionKey, senderID: String, version: Int) throws -> ChainState? {
        try context.fetch(FetchDescriptor<ChainState>()).first {
            $0.sessionID == session.id && $0.senderID == senderID && $0.chainVersion == version
        }
    }

    private func initialKey(session: SessionKey, senderID: String, version: Int) throws -> SymmetricKey {
        let root = try sessions.key(for: session, version: version)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: root, salt: Data("luma-chain-v1".utf8),
                                      info: Data(senderID.utf8), outputByteCount: 32)
    }

    private func derive(_ key: SymmetricKey, label: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(),
                               info: Data("luma-chain-\(label)-v1".utf8), outputByteCount: 32)
    }

    private func account(for state: ChainState) -> String { "chain.\(state.sessionID.uuidString).\(state.id.uuidString)" }
}
