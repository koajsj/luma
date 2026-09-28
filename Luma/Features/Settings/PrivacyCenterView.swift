import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct PrivacyCenterView: View {
    let user: User

    var body: some View {
        Form {
            Section("安全") {
                NavigationLink { SecurityCenterView(user: user) } label: {
                    Label("安全中心", systemImage: "checkmark.shield")
                }
                NavigationLink { PrivacyShieldView(user: user) } label: {
                    Label("隐私护盾", systemImage: "hand.raised")
                }
                NavigationLink { PrivacyOptionsView(user: user) } label: {
                    Label("隐私选项", systemImage: "slider.horizontal.3")
                }
            }
            Section("账号与数据") {
                NavigationLink { DeviceManagerView(user: user) } label: {
                    Label("设备管理", systemImage: "iphone.gen3")
                }
                NavigationLink { StorageManagementView(user: user) } label: {
                    Label("数据管理", systemImage: "externaldrive")
                }
            }
        }
        .navigationTitle("隐私与安全")
    }
}

private struct SecurityCenterView: View {
    let user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(keyProtectionReady ? "本机保护状态良好" : "部分保护需要检查")
                            .font(.headline)
                        Text("查看你的本机保护与隐私设置")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: keyProtectionReady ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(keyProtectionReady ? Color.green : Color.orange)
                }
                .padding(.vertical, 8)
                statusRow("本地数据保护", available: true)
                statusRow("密钥安全管理", available: security.keychainStatus() == "可读取")
                statusRow("设备身份保护", available: security.deviceKeyStatus(for: user, context: context) == "Keychain 已保护")
                statusRow("隐私护盾", available: security.preferences.effectiveScreenCaptureProtection || security.preferences.effectiveBackgroundHide)
            } header: {
                Text("安全状态")
            } footer: {
                Text("仅反映本机状态；通信保护范围请查看安全报告。")
            }
            Section {
                NavigationLink("安全与隐私报告") { PrivacyReportView(user: user) }
            }
        }
        .navigationTitle("安全中心")
    }

    private var keyProtectionReady: Bool {
        security.keychainStatus() == "可读取" &&
            security.deviceKeyStatus(for: user, context: context) == "Keychain 已保护"
    }

    private func statusRow(_ title: String, available: Bool) -> some View {
        Label(title, systemImage: available ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(available ? Color.green : Color.secondary)
    }
}

#if DEBUG
private struct E2EEDiagnosticsView: View {
    let user: User
    @Environment(\.modelContext) private var context
    @State private var snapshot: E2EEDiagnosticsSnapshot?
    @State private var error: String?

    var body: some View {
        Form {
            if let snapshot {
                Section("本机状态 · Debug") {
                    LabeledContent("加密版本", value: snapshot.encryptionVersion)
                    LabeledContent("Session", value: snapshot.sessionStatus)
                    LabeledContent("Event ID", value: snapshot.eventID)
                    LabeledContent("Sync Cursor", value: snapshot.syncCursor)
                    LabeledContent("Pending", value: String(snapshot.pendingCount))
                    LabeledContent("Crypto Transaction", value: snapshot.cryptoTransaction)
                }
            } else if let error {
                ContentUnavailableView("无法读取诊断状态", systemImage: "exclamationmark.shield",
                    description: Text(error))
            } else {
                ProgressView("读取本机状态")
            }
            Section { Text("仅显示路由与状态元数据，不展示消息正文或任何密钥。") }
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("E2EE Diagnostics")
        .task {
            do { snapshot = try E2EEDiagnosticsService(context: context, user: user).snapshot() }
            catch { self.error = "本机状态暂不可读取" }
        }
    }
}
#endif

struct PrivacyOptionsView: View {
    let user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("隐私模式", isOn: preference(\.privacyModeEnabled))
                Toggle("同时锁定所有聊天", isOn: preference(\.privacyModeLockChats))
            } footer: { Text("隐私模式会隐藏在线展示和消息预览，并在后台锁定应用。") }
            Section("资料与消息") {
                Toggle("允许通过 UserID 搜索我", isOn: preference(\.searchable))
                Toggle("消息预览", isOn: preference(\.messagePreviews))
                Toggle("显示在线状态", isOn: preference(\.showOnlineStatus))
                Toggle("显示最后上线时间", isOn: preference(\.showLastSeen))
            }
            Section { Text("设置仅保存在本机。当前在线状态仅供本机查看，不能代表好友的实时状态。") }
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("隐私选项")
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

private struct SecurityTechnicalDetailsView: View {
    let user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context

    var body: some View {
        Form {
            Section("本机保护") {
                LabeledContent("消息加密", value: "AES-GCM")
                LabeledContent("Keychain", value: security.keychainStatus())
                LabeledContent("Identity Key", value: security.identityKeyStatus(for: user))
                LabeledContent("Device Key", value: security.deviceKeyStatus(for: user, context: context))
                if let fingerprint = user.identityFingerprint {
                    LabeledContent("身份指纹") {
                        Text(IdentityFingerprint.grouped(fingerprint))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            Section("在线协议") {
                Text("在线 v4 采用逐设备密文信封及独立收发链。历史 v1/v2/v3 消息保持兼容读取。")
                Text("真实双设备完整链路、安全审计与公钥目录透明性尚未完成。")
            }
            Section("开发与诊断") {
                NavigationLink("开发服务器连接") { OnlineConnectionView(user: user) }
#if DEBUG
                NavigationLink("E2EE Diagnostics（Debug）") { E2EEDiagnosticsView(user: user) }
#endif
            }
        }
        .navigationTitle("技术详情")
    }
}

struct PrivacyReportView: View {
    let user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context

    var body: some View {
        Form {
            Section("数据保护") {
                status("本地消息保护", "已启用", "lock.doc")
                status("系统密钥存储", security.keychainStatus() == "可读取" ? "已保护" : "需要检查", "key.horizontal")
            }
            Section("身份") {
                status("身份保护", security.identityKeyStatus(for: user) == "已生成" ? "已启用" : "需要检查", "person.crop.circle.badge.checkmark")
                status("设备保护", security.deviceKeyStatus(for: user, context: context) == "Keychain 已保护" ? "已启用" : "需要检查", "iphone.gen3")
            }
            Section("通信") {
                status("密文消息传输", "在线模式可使用", "lock.bubble")
                status("设备身份验证", "在线登记后使用设备签名", "checkmark.shield")
                Text("服务器可见通信关系、时间及密文大小；本地聊天不会自动上传。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("隐私保护") {
                status("聊天锁", "可按聊天启用 PIN / Face ID", "lock")
                status("截图检测", security.preferences.screenshotAlerts ? "已开启 · 本机检测" : "已关闭", "camera.viewfinder")
                status("录屏保护", security.preferences.effectiveScreenCaptureProtection ? "已开启" : "已关闭", "record.circle")
                status("后台隐藏", security.preferences.hideInBackground ? "已开启" : "已关闭", "rectangle.on.rectangle.slash")
            }
            Section("当前限制") {
                Text("当前提供设备间加密通信基础；完整端到端加密仍待验收。")
                Text("截图检测发生在截图之后；无法禁止截图或保证遮罩覆盖所有采集方式。")
                Text("本页展示本机能力与设置状态，不代表对远端设备或服务器的实时安全审计。")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Section("深入了解") {
                NavigationLink("技术详情") { SecurityTechnicalDetailsView(user: user) }
            }
        }
        .navigationTitle("安全与隐私报告")
    }

    private func status(_ title: String, _ detail: String, _ symbol: String) -> some View {
        LabeledContent {
            Text(detail).foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

struct PrivacyShieldView: View {
    let user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: preference(\.screenshotAlerts)) {
                    settingLabel("截图提醒", detail: "检测截图行为", symbol: "camera.viewfinder")
                }
                Toggle(isOn: Binding(
                    get: { security.preferences.effectiveScreenCaptureProtection },
                    set: { value in update { $0.screenCaptureProtection = value } }
                )) {
                    settingLabel("录屏保护", detail: "录屏时隐藏内容", symbol: "record.circle")
                }
                Toggle(isOn: preference(\.hideInBackground)) {
                    settingLabel("后台隐藏", detail: "保护 App 切后台预览", symbol: "eye.slash")
                }
            } header: {
                Text("隐私保护")
            } footer: {
                Text("截图只能在发生后检测，无法阻止截图。")
            }
        }
        .navigationTitle("隐私护盾")
        .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确认", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func settingLabel(_ title: String, detail: String, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: symbol).foregroundStyle(.tint) }
    }

    private func preference(_ keyPath: WritableKeyPath<PrivacyPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { security.preferences[keyPath: keyPath] },
                set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func update(_ change: (inout PrivacyPreferences) -> Void) {
        do { try security.updatePreferences(for: user, context: context, change) }
        catch { errorMessage = LumaError.message(for: error) }
    }
}

struct DeviceManagerView: View {
    let user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @Query private var devices: [Device]
    @State private var errorMessage: String?
    private var current: Device? { devices.first { $0.ownerID == user.id } }
    var body: some View {
        Form {
            Section("当前设备") {
                Label(current?.deviceName ?? current?.name ?? UIDevice.current.name, systemImage: "iphone.gen3")
                LabeledContent("最近活动") {
                    if let date = current?.lastActiveAt { Text(date, style: .relative) }
                    else { Text("暂无记录") }
                }
                LabeledContent("安全状态", value: security.deviceKeyStatus(for: user, context: context) == "Keychain 已保护" ? "已保护" : "需要检查")
                LabeledContent("系统", value: current?.systemVersion ?? "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
            }
            Section("其他设备") {
                NavigationLink("已登记设备与撤销") { RegisteredDevicesView(user: user) }
            }
        }.navigationTitle("设备管理")
            .onAppear {
                guard let device = current else { errorMessage = "当前设备记录不存在，请重新登录以检查密钥"; return }
                device.name = UIDevice.current.name
                device.deviceName = UIDevice.current.name
                device.systemVersion = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
                device.lastActiveAt = .now
                do { try context.save() } catch { errorMessage = LumaError.message(for: error) }
            }
            .alert("设备记录保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("确认", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
    }
}

private struct RegisteredDevicesView: View {
    let user: User
    @Environment(\.modelContext) private var context
    @Environment(SecurityManager.self) private var security
    @State private var devices: [RemoteDeviceInfo] = []
    @State private var currentID: UUID?
    @State private var connected = false
    @State private var loading = true
    @State private var revoking: RemoteDeviceInfo?
    @State private var errorMessage: String?

    private var viewModel: OnlineConnectionViewModel {
        OnlineConnectionViewModel(user: user, context: context, security: security)
    }

    var body: some View {
        Form {
            Section {
                if loading {
                    ProgressView("正在读取设备")
                } else if !connected {
                    ContentUnavailableView {
                        Label("设备列表不可用", systemImage: "iphone.slash")
                    } description: {
                        Text("在线登录后可查看和撤销已登记设备。")
                    } actions: {
                        NavigationLink("前往在线连接") { OnlineConnectionView(user: user) }
                    }
                } else if devices.allSatisfy({ $0.revokedAt != nil }) {
                    ContentUnavailableView {
                        Label("暂无已登记设备", systemImage: "iphone")
                    } description: {
                        Text("刷新列表，查看新登记的设备。")
                    } actions: {
                        Button("刷新设备") { Task { await load() } }
                    }
                } else {
                    ForEach(devices.filter { $0.revokedAt == nil }) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.deviceName)
                                Text(device.id == currentID ? "当前设备" : "已登记")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.id != currentID {
                                Button("撤销设备", role: .destructive) { revoking = device }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            } footer: {
                Text("撤销后，该设备将无法继续使用服务器会话；其本机离线数据不会被远程擦除。")
            }
        }
        .navigationTitle("已登记设备")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新") { Task { await load() } }
                    .disabled(loading || !connected)
            }
        }
        .task { await load() }
        .confirmationDialog("撤销这台设备？", isPresented: Binding(
            get: { revoking != nil }, set: { if !$0 { revoking = nil } }
        )) {
            Button("撤销设备", role: .destructive) {
                guard let device = revoking else { return }
                revoking = nil
                Task {
                    do {
                        try await viewModel.revoke(deviceID: device.id)
                        await load()
                    } catch { errorMessage = LumaError.message(for: error) }
                }
            }
            Button("取消", role: .cancel) { revoking = nil }
        } message: {
            Text("撤销后将断开这台设备的在线连接，操作不可自动撤销。")
        }
        .alert("设备操作失败", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("确认", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let (registration, hasTokens) = try viewModel.localState()
            currentID = registration?.backendDeviceID
            connected = registration != nil && hasTokens
            devices = connected ? try await viewModel.devices() : []
        } catch { errorMessage = LumaError.message(for: error) }
    }
}

struct UserProfileView: View {
    @Bindable var user: User
    @Environment(\.modelContext) private var context
    @Environment(SecurityManager.self) private var security
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var nickname = ""
    @State private var bio = ""
    @State private var avatar: Data?
    @State private var profileLoaded = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                ProfileHeaderView(name: profileLoaded ? nickname : "我的资料",
                                  subtitle: "@\(user.userID)", imageData: avatar)
                if !bio.isEmpty { Text(bio).font(.subheadline).foregroundStyle(.secondary) }
            }
            Section("编辑资料") {
                PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("更换头像", systemImage: "photo") }
                    .disabled(!profileLoaded)
                if avatar != nil { Button("删除头像", role: .destructive) { avatar = nil; save() }.disabled(!profileLoaded) }
                TextField("昵称", text: $nickname)
                TextField("简介", text: $bio, axis: .vertical).lineLimit(2...4)
                Button("保存资料") {
                    let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { errorMessage = "昵称不能为空"; return }
                    nickname = value
                    save(); if errorMessage == nil { dismiss() }
                }.disabled(!profileLoaded)
            }
            Section("账号") {
                LabeledContent("UserID", value: user.userID)
            }
        }
        .navigationTitle("我的资料")
        .onAppear {
            do {
                let profile = try security.userProfile(user, context: context)
                nickname = profile.nickname; bio = profile.bio ?? ""; avatar = profile.avatar
                profileLoaded = true
            } catch { errorMessage = LumaError.message(for: error) }
        }
        .onChange(of: selectedPhoto) { _, item in
            Task {
                do {
                    guard profileLoaded else { return }
                    guard let data = try await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                    let maxSide: CGFloat = 512
                    let scale = min(1, maxSide / max(image.size.width, image.size.height))
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    let renderer = UIGraphicsImageRenderer(size: size)
                    avatar = renderer.jpegData(withCompressionQuality: 0.75) { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                    save()
                } catch { errorMessage = LumaError.message(for: error) }
            }
        }
        .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确认", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
    private func save() {
        do {
            try security.privateStore(context: context).saveProfile(
                UserPrivateProfile(nickname: nickname, avatar: avatar,
                                   bio: bio.trimmingCharacters(in: .whitespacesAndNewlines)), for: user)
            errorMessage = nil
        } catch { errorMessage = LumaError.message(for: error) }
    }
}
