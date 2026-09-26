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
        if let error = error as? DeviceSessionError { return error.localizedDescription }
        if let error = error as? BackupError { return error.localizedDescription }
        if let error = error as? AuthenticationError { return error.localizedDescription }
        if let error = error as? OutgoingQueueError { return error.localizedDescription }
        if let error = error as? MessageStoreError { return error.localizedDescription }
        if let error = error as? SessionError { return error.localizedDescription }
        if let error = error as? RemoteError {
            if case .server = error { return LumaError.network.localizedDescription }
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
