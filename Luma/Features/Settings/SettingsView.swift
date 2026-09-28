import SwiftData
import SwiftUI

struct SettingsView: View {
    let user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @State private var showingDeleteAccount = false
    @State private var deletionPassword = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("账号") {
                    NavigationLink {
                        UserProfileView(user: user)
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: (try? security.userProfile(user, context: context).nickname) ?? user.userID,
                                       imageData: try? security.userProfile(user, context: context).avatar)
                            VStack(alignment: .leading) {
                                Text("个人资料")
                                Text((try? security.userProfile(user, context: context).nickname) ?? "资料不可读取").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    LabeledContent("UserID", value: user.userID)
                    NavigationLink { DeviceManagerView(user: user) } label: { Label("设备管理", systemImage: "iphone.gen3") }
                    NavigationLink { AccountAccessSettingsView(user: user) } label: { Label("登录与解锁", systemImage: "lock") }
                }
                Section("隐私与安全") {
                    NavigationLink { PrivacyCenterView(user: user) } label: { Label("安全中心", systemImage: "checkmark.shield") }
                    NavigationLink { PrivacyShieldView(user: user) } label: { Label("隐私护盾", systemImage: "hand.raised") }
                    NavigationLink { PrivacyReportView(user: user) } label: { Label("安全与隐私报告", systemImage: "doc.text.magnifyingglass") }
                    NavigationLink { IdentitySettingsView(user: user) } label: { Label("身份验证", systemImage: "person.crop.circle.badge.checkmark") }
                }
                Section("聊天设置") {
                    NavigationLink { ChatPrivacySettingsView(user: user) } label: { Label("聊天偏好", systemImage: "bubble.left.and.text.bubble.right") }
                }
                Section("存储与数据") {
                    NavigationLink { StorageManagementView(user: user) } label: { Label("备份与存储", systemImage: "externaldrive") }
                }
                Section("关于") {
                    NavigationLink { AboutLumaView() } label: { Label("Luma 信息与隐私说明", systemImage: "info.circle") }
                    NavigationLink { OnlineConnectionView(user: user) } label: { Label("开发服务器连接", systemImage: "network") }
                }
                Section {
                    Button("锁定应用") { security.lock() }
                    Button("退出登录", role: .destructive) {
                        do { try security.logout() } catch { errorMessage = error.localizedDescription }
                    }
                    Button("删除本地账号", role: .destructive) { showingDeleteAccount = true }
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showingDeleteAccount) {
                NavigationStack {
                    Form {
                        Section {
                            Text("删除此设备上的账号、聊天记录和本地密钥。若已登记服务器，远端账号不会自动删除；本机认证密钥删除后可能无法再次登录。此操作无法撤销。")
                            SecureField("当前密码", text: $deletionPassword)
                        }
                        Button("永久删除本地账号", role: .destructive) {
                            do {
                                try security.deleteAccount(password: deletionPassword, user: user, context: context)
                                deletionPassword = ""
                                showingDeleteAccount = false
                            } catch { errorMessage = error.localizedDescription }
                        }.disabled(deletionPassword.isEmpty)
                    }
                    .navigationTitle("删除账号")
                    .toolbar { Button("取消") { deletionPassword = ""; showingDeleteAccount = false } }
                }
                .interactiveDismissDisabled()
            }
            .alert("设置失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
}

private struct AccountAccessSettingsView: View {
    let user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @State private var showingPassword = false
    @State private var showingPIN = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("登录") {
                Button("修改密码") { showingPassword = true }
                Button("修改 PIN") { showingPIN = true }
                Toggle("Face ID 解锁", isOn: Binding(
                    get: { security.preferences.faceIDEnabled },
                    set: { value in
                        if value && !security.canUseBiometrics() {
                            errorMessage = "此设备暂不可使用 Face ID"
                            return
                        }
                        do { try security.updatePreferences(for: user, context: context) { $0.faceIDEnabled = value } }
                        catch { errorMessage = LumaError.message(for: error) }
                    }
                ))
            }
        }
        .navigationTitle("登录与解锁")
        .sheet(isPresented: $showingPassword) { PasswordEditor(user: user).interactiveDismissDisabled() }
        .sheet(isPresented: $showingPIN) { PINEditor().interactiveDismissDisabled() }
        .alert("设置失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct ChatPrivacySettingsView: View {
    let user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("消息状态") {
                Toggle("已读回执", isOn: preference(\.readReceipts))
            }
            Section {
                Picker("阅读后自动销毁", selection: Binding(
                    get: { security.preferences.autoDestroyHours },
                    set: { value in
                        do { try security.updatePreferences(for: user, context: context) { $0.autoDestroyHours = value } }
                        catch { errorMessage = LumaError.message(for: error) }
                    }
                )) {
                    Text("关闭").tag(0)
                    Text("24 小时").tag(24)
                    Text("7 天").tag(168)
                }
                Toggle("阅后即焚（阅读后 1 分钟）", isOn: preference(\.disappearingMessages))
            } header: { Text("消息保留") } footer: {
                Text("计时仅影响本机消息记录，无法删除对方设备上已有的副本。")
            }
            Section("聊天保护") {
                NavigationLink("聊天锁") { ChatLockSettingsView(user: user) }
            }
        }
        .navigationTitle("聊天偏好")
        .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func preference(_ keyPath: WritableKeyPath<PrivacyPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { security.preferences[keyPath: keyPath] }, set: { value in
            do { try security.updatePreferences(for: user, context: context) { $0[keyPath: keyPath] = value } }
            catch { errorMessage = LumaError.message(for: error) }
        })
    }
}

private struct ChatLockSettingsView: View {
    let user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @Query private var conversations: [Conversation]
    @Query private var friends: [Friend]
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                let owned = conversations.filter { $0.ownerID == user.id }
                if owned.isEmpty {
                    ContentUnavailableView("还没有聊天", systemImage: "message")
                }
                ForEach(owned) { conversation in
                    if let friend = friends.first(where: { $0.id == conversation.friendID }) {
                        Toggle(security.friendDisplayName(friend, context: context), isOn: Binding(
                            get: { conversation.requiresUnlock == true },
                            set: { value in
                                conversation.requiresUnlock = value
                                do { try context.save() } catch { errorMessage = LumaError.message(for: error) }
                            }
                        ))
                    }
                }
            } footer: { Text("开启后进入该聊天需要再次验证 PIN 或 Face ID。") }
        }
        .navigationTitle("聊天锁")
        .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct IdentitySettingsView: View {
    let user: User
    @Query private var friends: [Friend]
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context

    var body: some View {
        List {
            Section {
                let candidates = friends.filter { $0.ownerID == user.id && $0.remoteUserID != nil }
                if candidates.isEmpty {
                    ContentUnavailableView("暂无可核对的在线好友", systemImage: "person.crop.circle.badge.questionmark")
                }
                ForEach(candidates) { friend in
                    NavigationLink(security.friendDisplayName(friend, context: context)) { IdentityVerificationView(user: user, friend: friend) }
                }
            } footer: {
                Text("与好友通过独立可信渠道比较安全码。身份密钥变化后需要重新核对。")
            }
        }
        .navigationTitle("身份验证")
    }
}

private struct AboutLumaView: View {
    var body: some View {
        Form {
            Section("Luma") {
                Label("本地优先的隐私聊天", systemImage: "message.fill")
                Text("当前在线通信能力仍在验证中。")
                    .foregroundStyle(.secondary)
            }
            Section("隐私说明") {
                Text("本地消息内容加密保存；在线服务可见通信所需的关系、时间和密文大小等信息。")
                Text("截图检测在截图之后发生，无法阻止截图。完整端到端加密尚未通过最终验收。")
            }
        }
        .navigationTitle("关于 Luma")
    }
}

private struct PasswordEditor: View {
    let user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            Form {
                SecureField("当前密码", text: $oldPassword)
                SecureField("新密码", text: $newPassword)
                SecureField("确认新密码", text: $confirmation)
            }
            .navigationTitle("修改密码")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("保存") {
                    guard newPassword.count >= 8 else { errorMessage = "新密码至少需要 8 位"; return }
                    guard newPassword == confirmation else { errorMessage = "两次输入的新密码不一致"; return }
                    do { try security.changePassword(old: oldPassword, new: newPassword, user: user, context: context); dismiss() }
                    catch { errorMessage = error.localizedDescription }
                } }
            }
            .alert("无法修改", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
}

private struct PINEditor: View {
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var oldPIN = ""
    @State private var newPIN = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            Form {
                SecureField("当前 PIN", text: $oldPIN).keyboardType(.numberPad)
                SecureField("新 PIN（6 位数字）", text: $newPIN).keyboardType(.numberPad)
                SecureField("确认新 PIN", text: $confirmation).keyboardType(.numberPad)
            }
            .navigationTitle("修改 PIN")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("保存") {
                    guard newPIN == confirmation else { errorMessage = "两次输入的新 PIN 不一致"; return }
                    do { try security.verifyPIN(oldPIN, context: context); try security.setPIN(newPIN, context: context); dismiss() }
                    catch { errorMessage = error.localizedDescription }
                } }
            }
            .alert("无法修改", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
}
