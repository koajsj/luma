import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct StorageManagementView: View {
    let user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @Query private var friends: [Friend]
    @Query private var conversations: [Conversation]
    @Query private var messages: [Message]
    @Query private var cleanupStates: [CleanupState]
    @State private var backupPassword = ""
    @State private var backupURL: URL?
    @State private var pendingRestore: Data?
    @State private var showingImporter = false
    @State private var confirmingRestore = false
    @State private var busy = false
    @State private var notice: String?

    private var ownedConversations: [Conversation] { conversations.filter { $0.ownerID == user.id } }
    private var ownedMessages: [Message] {
        let ids = Set(ownedConversations.map(\.id))
        return messages.filter { ids.contains($0.conversationID) }
    }
    private var imageBytes: Int {
        ((try? security.userProfile(user, context: context).avatar?.count) ?? 0) +
            friends.filter { $0.ownerID == user.id }.reduce(0) { $0 + ((try? security.friendProfile($1, context: context).avatar?.count) ?? 0) }
    }
    private var cacheDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("LumaBackups", isDirectory: true) }
    private var cacheBytes: Int {
        (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]))?
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? 0
    }

    var body: some View {
        Form {
            Section("本机用量") {
                LabeledContent("消息", value: "\(ownedMessages.count) 条")
                LabeledContent("图片", value: ByteCountFormatter.string(fromByteCount: Int64(imageBytes), countStyle: .file))
                LabeledContent("文件", value: "0 B · 尚无真实附件")
                LabeledContent("缓存", value: ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file))
            }
            Section("加密备份") {
                SecureField("备份密码（至少 8 位）", text: $backupPassword)
                Button("生成加密备份") { createBackup() }
                    .disabled(backupPassword.count < 8 || busy)
                if let backupURL {
                    ShareLink(item: backupURL) { Label("导出 Luma Backup", systemImage: "square.and.arrow.up") }
                }
                Button("从备份恢复") { showingImporter = true }
                    .disabled(backupPassword.isEmpty || busy)
                Text("备份使用独立密码加密，不含账号密码验证值、PIN、登录状态或 Keychain 私钥。恢复仅支持当前 UserID；含在线消息、未发送队列或在线同步进度时暂不允许恢复，以免丢失远端事件。")
                    .font(.footnote).foregroundStyle(.secondary)
                if cleanupStates.contains(where: { $0.ownerID == user.id && $0.operation == "backupRestore" && $0.dataCommitted && $0.state != "completed" }) {
                    Button("继续完成恢复清理") {
                        do {
                            try BackupManager.resumeRestoreCleanup(for: user, context: context,
                                encryption: security.encryptionService(),
                                keychain: security.sessionManager(context: context).keychain)
                            try security.reloadPreferences(for: user, context: context)
                            notice = "恢复清理已完成"
                        } catch { notice = LumaError.message(for: error) }
                    }
                }
            }
            Section("缓存") {
                Button("清理缓存") { clearCache() }
                Text("仅清理由本页生成的临时加密备份文件；不会删除聊天、索引或密钥。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if busy { ProgressView("正在处理") }
        }
        .navigationTitle("存储管理")
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                pendingRestore = try Data(contentsOf: url)
                confirmingRestore = true
            } catch { notice = LumaError.message(for: error) }
        }
        .confirmationDialog("替换当前账号本机数据？", isPresented: $confirmingRestore) {
            Button("验证并恢复", role: .destructive) { restoreBackup() }
            Button("取消", role: .cancel) { pendingRestore = nil }
        } message: { Text("将验证备份密码和 UserID，再替换本机好友、会话和消息。当前数据可以先导出备份。") }
        .alert("存储管理", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private func createBackup() {
        busy = true
        defer { busy = false }
        do {
            let manager = BackupManager(context: context, encryption: try security.encryptionService(),
                                        sessions: try security.sessionManager(context: context))
            let data = try manager.export(user: user, password: backupPassword)
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let url = cacheDirectory.appendingPathComponent("Luma-\(user.userID)-\(UUID().uuidString).lumabackup")
            try data.write(to: url, options: .atomic)
            backupURL = url
            notice = "加密备份已生成。请使用导出按钮保存文件，并妥善保管备份密码。"
        } catch { notice = LumaError.message(for: error) }
    }

    private func restoreBackup() {
        guard let pendingRestore else { return }
        busy = true
        defer { busy = false; self.pendingRestore = nil }
        do {
            try BackupManager(context: context, encryption: security.encryptionService(),
                              sessions: security.sessionManager(context: context))
                .restore(pendingRestore, password: backupPassword, into: user)
            try security.reloadPreferences(for: user, context: context)
            notice = "恢复完成。好友、会话和消息已重新使用本机主密钥加密。"
        } catch { notice = LumaError.message(for: error) }
    }

    private func clearCache() {
        do {
            if FileManager.default.fileExists(atPath: cacheDirectory.path) { try FileManager.default.removeItem(at: cacheDirectory) }
            backupURL = nil
            notice = "缓存已清理"
        } catch { notice = LumaError.message(for: error) }
    }
}
