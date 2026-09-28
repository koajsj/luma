import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct PrivacyCenterView: View {
    let user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Luma 安全状态", systemImage: "checkmark.shield.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    statusRow("本地数据保护", available: true)
                    statusRow("密钥安全管理", available: security.keychainStatus() == "可读取")
                    statusRow("设备身份保护", available: security.deviceKeyStatus(for: user, context: context) == "Keychain 已保护")
                    statusRow("隐私护盾", available: security.preferences.effectiveScreenCaptureProtection || security.preferences.effectiveBackgroundHide)
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .contain)
            } footer: {
                Text("状态仅反映本机功能和设置；在线通信尚未通过完整端到端加密验收。")
            }
            Section("隐私与安全") {
                NavigationLink("隐私选项") { PrivacyOptionsView(user: user) }
                NavigationLink("隐私护盾") { PrivacyShieldView(user: user) }
                NavigationLink("安全与隐私报告") { PrivacyReportView(user: user) }
            }
            Section("更多信息") {
                NavigationLink("技术详情") { SecurityTechnicalDetailsView(user: user) }
#if DEBUG
                NavigationLink("E2EE Diagnostics（Debug）") { E2EEDiagnosticsView(user: user) }
#endif
            }
        }
        .navigationTitle("安全中心")
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

private struct PrivacyOptionsView: View {
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
                Toggle("已读回执", isOn: preference(\.readReceipts))
            }
            Section { Text("本机隐私偏好不会自动同步到开发服务器；在线状态演示不代表好友真实在线。") }
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("隐私选项")
        .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func preference(_ keyPath: WritableKeyPath<PrivacyPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { security.preferences[keyPath: keyPath] }, set: { value in
            do { try security.updatePreferences(for: user, context: context) { $0[keyPath: keyPath] = value } }
            catch { errorMessage = error.localizedDescription }
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
            }
            Section("在线协议") {
                Text("在线 v4 采用逐设备密文信封及独立收发链。历史 v1/v2/v3 消息保持兼容读取。")
                Text("真实双设备完整链路、安全审计与公钥目录透明性尚未完成。")
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
                status("系统密钥存储", security.keychainStatus(), "key.horizontal")
            }
            Section("身份") {
                status("身份保护", security.identityKeyStatus(for: user), "person.crop.circle.badge.checkmark")
                status("设备保护", security.deviceKeyStatus(for: user, context: context), "iphone.gen3")
            }
            Section("通信") {
                status("密文消息传输", "在线模式可用；真机验收未完成", "lock.bubble")
                status("设备身份验证", "在线登记后使用设备签名", "checkmark.shield")
                Text("服务器可见通信关系、时间及密文大小；本地聊天不会自动上传。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("隐私保护") {
                status("隐私护盾", "可配置录屏遮罩与敏感聊天", "hand.raised")
                status("聊天锁", "可按聊天启用 PIN / Face ID", "lock")
                status("截图检测", security.preferences.screenshotAlerts ? "已开启 · 本机检测" : "已关闭", "camera.viewfinder")
                status("后台隐藏", security.preferences.hideInBackground ? "已开启" : "已关闭", "rectangle.on.rectangle.slash")
            }
            Section("当前限制") {
                Text("设备间文字、附件和聊天操作已有加密实现，但尚未完成双真实设备验收及独立安全审查。当前不能宣称完整端到端加密。")
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
    @Query private var conversations: [Conversation]
    @Query private var friends: [Friend]
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("检测截图行为", isOn: preference(\.screenshotAlerts))
                Toggle("录屏时隐藏内容", isOn: Binding(
                    get: { security.preferences.effectiveScreenCaptureProtection },
                    set: { value in update { $0.screenCaptureProtection = value } }
                ))
                Toggle("后台隐藏隐私信息", isOn: preference(\.hideInBackground))
            } header: { Text("系统检测") } footer: {
                Text("截图发生后才能检测，无法阻止截图；录屏时隐藏内容仅对系统报告的录屏、镜像和 AirPlay 捕获生效。")
            }
            Section {
                let owned = conversations.filter { $0.ownerID == user.id }
                if owned.isEmpty {
                    Text("还没有聊天").foregroundStyle(.secondary)
                }
                ForEach(owned) { conversation in
                    if let friend = friends.first(where: { $0.id == conversation.friendID }) {
                        Toggle(security.friendDisplayName(friend, context: context), isOn: Binding(
                            get: { conversation.requiresPrivacyShield == true },
                            set: { value in
                                conversation.requiresPrivacyShield = value
                                do { try context.save() } catch { errorMessage = error.localizedDescription }
                            }
                        ))
                    }
                }
            } header: { Text("敏感聊天保护") } footer: {
                Text("开启后需要再次解锁，不进入本地搜索与收藏摘要。通知预览控制待通知服务接入后生效。")
            }
        }
        .navigationTitle("隐私护盾")
        .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func preference(_ keyPath: WritableKeyPath<PrivacyPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { security.preferences[keyPath: keyPath] },
                set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func update(_ change: (inout PrivacyPreferences) -> Void) {
        do { try security.updatePreferences(for: user, context: context, change) }
        catch { errorMessage = error.localizedDescription }
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
                LabeledContent("名称", value: current?.deviceName ?? current?.name ?? UIDevice.current.name)
                LabeledContent("系统", value: current?.systemVersion ?? "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                LabeledContent("设备密钥", value: security.deviceKeyStatus(for: user, context: context))
                if let date = current?.createdAt { LabeledContent("创建时间") { Text(date, style: .date) } }
                if let date = current?.lastActiveAt { LabeledContent("最后活动") { Text(date, style: .relative) } }
            }
            Section { Text("仅显示当前设备。本地没有其他设备的可信记录；多设备管理将在同步服务接入后启用。") }
                .font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("设备管理")
            .onAppear {
                guard let device = current else { errorMessage = "当前设备记录不存在，请重新登录以检查密钥"; return }
                device.name = UIDevice.current.name
                device.deviceName = UIDevice.current.name
                device.systemVersion = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
                device.lastActiveAt = .now
                do { try context.save() } catch { errorMessage = error.localizedDescription }
            }
            .alert("设备记录保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
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
                HStack { Spacer(); AvatarView(name: nickname, imageData: avatar, size: 80); Spacer() }
                PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("从相册选择头像", systemImage: "photo") }
                    .disabled(!profileLoaded)
                if avatar != nil { Button("删除头像", role: .destructive) { avatar = nil; save() }.disabled(!profileLoaded) }
            }
            Section("资料") {
                LabeledContent("UserID", value: user.userID)
                TextField("昵称", text: $nickname)
                TextField("简介", text: $bio, axis: .vertical).lineLimit(2...4)
                Button("保存资料") {
                    let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { errorMessage = "昵称不能为空"; return }
                    nickname = value
                    save(); if errorMessage == nil { dismiss() }
                }.disabled(!profileLoaded)
            }
            Section("身份指纹") {
                if let fingerprint = user.identityFingerprint {
                    Text(IdentityFingerprint.grouped(fingerprint))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel("身份指纹 \(fingerprint)")
                } else {
                    Text("尚未生成").foregroundStyle(.secondary)
                }
                Text("此指纹仅来自本机身份公钥。好友身份验证将在后续版本实现。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("我的资料")
        .onAppear {
            do {
                let profile = try security.userProfile(user, context: context)
                nickname = profile.nickname; bio = profile.bio ?? ""; avatar = profile.avatar
                profileLoaded = true
            } catch { errorMessage = error.localizedDescription }
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
                } catch { errorMessage = error.localizedDescription }
            }
        }
        .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
    private func save() {
        do {
            try security.privateStore(context: context).saveProfile(
                UserPrivateProfile(nickname: nickname, avatar: avatar,
                                   bio: bio.trimmingCharacters(in: .whitespacesAndNewlines)), for: user)
        } catch { errorMessage = error.localizedDescription }
    }
}
