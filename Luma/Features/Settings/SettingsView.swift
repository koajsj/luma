import SwiftData
import SwiftUI

struct SettingsView: View {
    let user: User

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { AccountSettingsView(user: user) } label: {
                        Label("账号", systemImage: "person.crop.circle")
                    }
                    NavigationLink { PrivacyCenterView(user: user) } label: {
                        Label("隐私与安全", systemImage: "hand.raised")
                    }
                    NavigationLink { ChatSettingsHomeView(user: user) } label: {
                        Label("聊天", systemImage: "bubble.left.and.bubble.right")
                    }
                    NavigationLink { AboutLumaView() } label: {
                        Label("关于", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
}

private struct AccountSettingsView: View {
    let user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @State private var showingDeleteAccount = false
    @State private var deletionPassword = ""
    @State private var errorMessage: String?
    @State private var deletionError: String?

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    UserProfileView(user: user)
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: (try? security.userProfile(user, context: context).nickname) ?? user.userID,
                                   imageData: try? security.userProfile(user, context: context).avatar)
                        VStack(alignment: .leading) {
                            Text("个人资料")
                            Text((try? security.userProfile(user, context: context).nickname) ?? "资料不可读取")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink { UserIDDetailsView(userID: user.userID) } label: {
                    Label("我的 UserID", systemImage: "at")
                }
                NavigationLink { AccountAccessSettingsView(user: user) } label: { Label("登录与解锁", systemImage: "lock") }
            }
            Section("账号操作") {
                Button("锁定应用") { security.lock() }
                Button("退出登录", role: .destructive) {
                    do { try security.logout() } catch { errorMessage = LumaError.message(for: error) }
                }
                Button("删除本地账号", role: .destructive) { showingDeleteAccount = true }
            }
        }
        .navigationTitle("账号")
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
                        } catch { deletionError = LumaError.message(for: error) }
                    }.disabled(deletionPassword.isEmpty)
                }
                .navigationTitle("删除本地账号")
                .toolbar { Button("取消") { deletionPassword = ""; showingDeleteAccount = false } }
                .alert("删除失败", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
                    Button("确认", role: .cancel) { deletionError = nil }
                } message: { Text(deletionError ?? "") }
            }
            .interactiveDismissDisabled()
        }
        .alert("设置失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确认", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct UserIDDetailsView: View {
    let userID: String

    var body: some View {
        Form {
            Section {
                LabeledContent("UserID", value: userID)
                    .textSelection(.enabled)
            } footer: {
                Text("UserID 是你的固定身份标识，可用于添加好友。")
            }
        }
        .navigationTitle("我的 UserID")
    }
}

private struct ChatSettingsHomeView: View {
    let user: User

    var body: some View {
        Form {
            Section {
                NavigationLink { ChatPrivacySettingsView(user: user, section: .receipts) } label: { Label("已读回执", systemImage: "checkmark.message") }
                NavigationLink { ChatPrivacySettingsView(user: user, section: .retention) } label: { Label("自动销毁", systemImage: "timer") }
            }
            Section { Text("单个聊天的锁定与敏感保护，请在该聊天的详情中设置。") }
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("聊天")
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
            Button("确认", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private enum ChatSettingsSection {
    case receipts, retention
}

private struct ChatPrivacySettingsView: View {
    let user: User
    var section: ChatSettingsSection
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if section == .receipts {
                Section("消息状态") {
                    Toggle("已读回执", isOn: preference(\.readReceipts))
                }
            }
            if section == .retention {
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
            }
        }
        .navigationTitle(section == .receipts ? "已读回执" : "自动销毁")
        .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确认", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func preference(_ keyPath: WritableKeyPath<PrivacyPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { security.preferences[keyPath: keyPath] }, set: { value in
            do { try security.updatePreferences(for: user, context: context) { $0[keyPath: keyPath] = value } }
            catch { errorMessage = LumaError.message(for: error) }
        })
    }
}

private struct AboutLumaView: View {
    var body: some View {
        Form {
            Section("Luma") {
                Label("本地优先的隐私聊天", systemImage: "message.fill")
                Text("聊天、好友与隐私设置，尽量由你掌控。")
                    .foregroundStyle(.secondary)
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
                    catch { errorMessage = LumaError.message(for: error) }
                } }
            }
            .alert("无法修改", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("确认", role: .cancel) { errorMessage = nil }
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
                    catch { errorMessage = LumaError.message(for: error) }
                } }
            }
            .alert("无法修改", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("确认", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
}
