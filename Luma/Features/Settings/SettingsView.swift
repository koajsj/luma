import SwiftData
import SwiftUI

struct SettingsView: View {
    @Bindable var user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @State private var showingNickname = false
    @State private var showingPassword = false
    @State private var showingPIN = false
    @State private var showingDevices = false
    @State private var showingProfile = false
    @State private var showingPrivacy = false
    @State private var showingStorage = false
    @State private var showingOnline = false
    @State private var showingDeleteAccount = false
    @State private var deletionPassword = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("账号") {
                    Button { showingProfile = true } label: {
                        HStack { AvatarView(name: user.nickname, imageData: user.avatar); VStack(alignment: .leading) { Text(user.nickname); Text("@\(user.userID)").font(.caption).foregroundStyle(.secondary) } }
                    }
                    LabeledContent("UserID", value: user.userID)
                    Button { showingNickname = true } label: { LabeledContent("昵称", value: user.nickname) }
                    Button("修改密码") { showingPassword = true }
                    Button("服务器连接") { showingOnline = true }
                }
                Section("安全") {
                    Button("修改 PIN") { showingPIN = true }
                    Toggle("Face ID", isOn: preference(\.faceIDEnabled))
                    Button("设备管理") { showingDevices = true }
                    Button("存储管理与加密备份") { showingStorage = true }
                }
                Section {
                    Button { showingPrivacy = true } label: { Label("隐私中心", systemImage: "hand.raised.shield") }
                    Toggle("隐私模式", isOn: preference(\.privacyModeEnabled))
                    Toggle("隐私模式锁定所有聊天", isOn: preference(\.privacyModeLockChats))
                    Toggle("允许其他用户通过 UserID 搜索我", isOn: preference(\.searchable))
                    Toggle("检测截图行为", isOn: preference(\.screenshotAlerts))
                    Toggle("录屏提醒", isOn: preference(\.recordingAlerts))
                    Toggle("后台隐藏", isOn: preference(\.hideInBackground))
                    Toggle("已读回执", isOn: preference(\.readReceipts))
                } header: {
                    Text("隐私")
                } footer: {
                    Text("目前只进行本机检测和提醒，尚不能通知对方，也无法完全阻止截图。后台隐藏会在离开应用时锁定界面。")
                }
                Section {
                    Picker("阅读后自动销毁", selection: Binding(get: { security.preferences.autoDestroyHours }, set: { value in
                        do { try security.updatePreferences(for: user, context: context) { $0.autoDestroyHours = value } }
                        catch { errorMessage = error.localizedDescription }
                    })) {
                        Text("关闭").tag(0)
                        Text("24 小时").tag(24)
                        Text("7 天").tag(168)
                    }
                    Toggle("阅后即焚（阅读后 1 分钟）", isOn: preference(\.disappearingMessages))
                } header: { Text("聊天") }
                  footer: { Text("仅对本机收到且首次打开的消息计时，到期后删除本地记录；不会删除对方设备上的消息。") }
                Section {
                    Button("锁定应用") { security.lock() }
                    Button("退出登录", role: .destructive) {
                        do { try security.logout() } catch { errorMessage = error.localizedDescription }
                    }
                    Button("删除本地账号", role: .destructive) { showingDeleteAccount = true }
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showingNickname) { NicknameEditor(user: user) }
            .sheet(isPresented: $showingPassword) { PasswordEditor(user: user) }
            .sheet(isPresented: $showingPIN) { PINEditor() }
            .sheet(isPresented: $showingProfile) { NavigationStack { UserProfileView(user: user) } }
            .sheet(isPresented: $showingPrivacy) { NavigationStack { PrivacyCenterView(user: user) } }
            .sheet(isPresented: $showingDevices) { NavigationStack { DeviceManagerView(user: user) } }
            .sheet(isPresented: $showingStorage) { NavigationStack { StorageManagementView(user: user) } }
            .sheet(isPresented: $showingOnline) { NavigationStack { OnlineConnectionView(user: user) } }
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
            }
            .alert("设置失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        do { try context.save() } catch { errorMessage = error.localizedDescription }
    }

    private func preference(_ keyPath: WritableKeyPath<PrivacyPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { security.preferences[keyPath: keyPath] }, set: { value in
            if keyPath == \.faceIDEnabled && value && !security.canUseBiometrics() {
                errorMessage = "此设备暂不可使用 Face ID"; return
            }
            do { try security.updatePreferences(for: user, context: context) { $0[keyPath: keyPath] = value } }
            catch { errorMessage = error.localizedDescription }
        })
    }
}

private struct NicknameEditor: View {
    @Bindable var user: User
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            Form { TextField("昵称", text: $nickname) }
                .navigationTitle("修改昵称")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) { Button("保存") {
                        let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { errorMessage = "昵称不能为空"; return }
                        user.nickname = value
                        do { try context.save(); dismiss() } catch { errorMessage = error.localizedDescription }
                    } }
                }
                .onAppear { nickname = user.nickname }
                .alert("无法保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("好", role: .cancel) { errorMessage = nil }
                } message: { Text(errorMessage ?? "") }
        }
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
