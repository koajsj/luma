import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum StorageManagementMode {
    case overview, backup, cache
}

struct StorageManagementView: View {
    let user: User
    var mode: StorageManagementMode = .overview
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
    @State private var confirmingCacheClear = false
    @State private var busy = false
    @State private var notice: String?
    @State private var noticeIsError = false

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
            if mode != .backup {
                Section("本机用量") {
                    LabeledContent("消息", value: "\(ownedMessages.count) 条")
                    LabeledContent("头像图片", value: ByteCountFormatter.string(fromByteCount: Int64(imageBytes), countStyle: .file))
                    LabeledContent("临时备份", value: ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file))
                }
            }
            if mode == .overview {
                Section("管理") {
                    NavigationLink { StorageManagementView(user: user, mode: .backup) } label: {
                        Label("备份与恢复", systemImage: "arrow.clockwise.icloud")
                    }
                    NavigationLink { StorageManagementView(user: user, mode: .cache) } label: {
                        Label("缓存管理", systemImage: "trash")
                    }
                }
            }
            if mode == .backup {
                Section {
                    Label("备份你的 Luma 数据", systemImage: "externaldrive.badge.timemachine")
                    Text("设置备份密码后，可创建或恢复本机数据。")
                        .foregroundStyle(.secondary)
                }
                Section("加密备份") {
                    SecureField("备份密码（至少 8 位）", text: $backupPassword)
                    if backupURL == nil {
                        ContentUnavailableView {
                            Label("本次还没有生成备份", systemImage: "externaldrive.badge.plus")
                        } description: {
                            Text("输入备份密码后创建加密备份。")
                        } actions: {
                            Button("创建备份") { createBackup() }
                                .disabled(backupPassword.count < 8 || busy)
                        }
                    } else if let backupURL {
                        Button("重新创建备份") { createBackup() }
                            .disabled(backupPassword.count < 8 || busy)
                        ShareLink(item: backupURL) { Label("导出 Luma 备份", systemImage: "square.and.arrow.up") }
                    }
                    Button("恢复备份") { showingImporter = true }
                        .disabled(backupPassword.isEmpty || busy)
                    NavigationLink("备份说明") { BackupDetailsView() }
                    if cleanupStates.contains(where: { $0.ownerID == user.id && $0.operation == "backupRestore" && $0.dataCommitted && $0.state != "completed" }) {
                        Button("继续完成恢复清理") {
                            do {
                                try BackupManager.resumeRestoreCleanup(for: user, context: context,
                                    encryption: security.encryptionService(),
                                    keychain: security.sessionManager(context: context).keychain)
                                try security.reloadPreferences(for: user, context: context)
                                noticeIsError = false; notice = "恢复清理已完成"
                            } catch { noticeIsError = true; notice = LumaError.message(for: error) }
                        }
                    }
                }
            }
            if mode == .cache {
                Section("缓存") {
                    Button("清理缓存", role: .destructive) { confirmingCacheClear = true }
                    Text("仅清理由本页生成的临时加密备份文件；不会删除聊天、索引或密钥。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if busy { ProgressView("正在处理") }
        }
        .navigationTitle(mode == .overview ? "数据管理" : mode == .backup ? "备份与恢复" : "缓存管理")
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                pendingRestore = try Data(contentsOf: url)
                confirmingRestore = true
            } catch { noticeIsError = true; notice = LumaError.message(for: error) }
        }
        .confirmationDialog("替换当前账号本机数据？", isPresented: $confirmingRestore) {
            Button("验证并恢复", role: .destructive) { restoreBackup() }
            Button("取消", role: .cancel) { pendingRestore = nil }
        } message: { Text("将验证备份密码和 UserID，再替换本机好友、会话和消息。当前数据可以先导出备份。") }
        .confirmationDialog("清理临时备份文件？", isPresented: $confirmingCacheClear) {
            Button("清理缓存", role: .destructive) { clearCache() }
            Button("取消", role: .cancel) { }
        } message: { Text("将删除本机临时生成的加密备份。如果还未导出，请先保存备份文件。聊天记录和密钥不会受影响。") }
        .alert(noticeIsError ? "操作失败" : "操作完成", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("确认", role: .cancel) { notice = nil }
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
            noticeIsError = false
            notice = "加密备份已生成。请使用导出按钮保存文件，并妥善保管备份密码。"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { noticeIsError = true; notice = LumaError.message(for: error) }
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
            noticeIsError = false
            notice = "恢复完成。好友、会话和消息已重新使用本机主密钥加密。"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { noticeIsError = true; notice = LumaError.message(for: error) }
    }

    private func clearCache() {
        do {
            if FileManager.default.fileExists(atPath: cacheDirectory.path) { try FileManager.default.removeItem(at: cacheDirectory) }
            backupURL = nil
            noticeIsError = false
            notice = "缓存已清理"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { noticeIsError = true; notice = LumaError.message(for: error) }
    }
}

private struct BackupDetailsView: View {
    var body: some View {
        Form {
            Section("保护方式") {
                Text("备份使用独立密码加密，不含账号密码验证值、PIN、登录状态或 Keychain 私钥。")
            }
            Section("恢复范围") {
                Text("仅支持恢复当前 UserID。含在线消息、未发送队列或在线同步进度时暂不允许恢复，以免丢失远端事件。")
            }
        }
        .navigationTitle("备份说明")
    }
}
