import Foundation

/// User-facing error boundary. Domain errors keep their precise types for retry
/// decisions; views do not expose raw transport, database or Keychain diagnostics.
enum LumaError: LocalizedError {
    case crypto, network, storage, sync, auth, backup

    var errorDescription: String? {
        switch self {
        case .crypto: "加密数据无法验证，请检查密钥或重新获取消息"
        case .network: "连接暂不可用，请稍后重试；本地数据仍可使用"
        case .storage: "本地数据无法保存或读取，请检查可用空间后重试"
        case .sync: "同步暂未完成，未确认的事件会在下次重试"
        case .auth: "身份验证失败，请重新登录或核对设备状态"
        case .backup: "备份恢复未完成，重新解锁后会继续处理"
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? DeviceSessionError {
            switch error {
            case .identityKeyChanged, .untrustedIdentity:
                return "好友身份需要重新核对，核对前请暂停在线发送。"
            case .wrongDevice:
                return "这条消息无法在当前设备打开。"
            case .missingPreKey:
                return "暂时无法建立安全连接，请稍后重试。"
            default:
                return "这条消息无法验证，请稍后重试。"
            }
        }
        if let error = error as? BackupError { return error.localizedDescription }
        if let error = error as? AuthenticationError { return error.localizedDescription }
        if let error = error as? OutgoingQueueError { return error.localizedDescription }
        if let error = error as? MessageStoreError { return error.localizedDescription }
        if let error = error as? V4AttachmentError { return error.localizedDescription }
        if let error = error as? SessionError {
            switch error {
            case .identityMismatch: return "好友身份已变化，请重新核对。"
            case .localPeerUnavailable: return "本机没有这位好友的账号，无法建立演示会话。"
            default: return "聊天保护信息暂不可用，请稍后重试。"
            }
        }
        if let error = error as? RemoteError {
            if case .server = error { return LumaError.network.localizedDescription }
            if case .invalidResponse = error { return LumaError.network.localizedDescription }
            if case .onlineMessagesUnavailable = error { return "暂时无法发送在线消息，请稍后重试。" }
            return error.localizedDescription
        }
        if error is KeychainError { return LumaError.auth.localizedDescription }
        if error is EncryptionError || error is AsymmetricKeyError || error is MasterKeyError ||
           error is SessionError || error is DeviceSessionError { return LumaError.crypto.localizedDescription }
        if error is URLError { return LumaError.network.localizedDescription }
        if error is MessageRepositoryError { return LumaError.sync.localizedDescription }
        if error is FileTransferError { return LumaError.storage.localizedDescription }
        return LumaError.storage.localizedDescription
    }
}
