import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct PrivacyCenterView: View {
    @Bindable var user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("安全状态") {
                Label("本地消息内容已加密", systemImage: "checkmark.shield")
                Label("Master Key 受 Keychain 保护", systemImage: "key.horizontal")
                Label(security.preferences.faceIDEnabled ? "Face ID 应用解锁已开启" : "Face ID 应用解锁未开启", systemImage: "faceid")
                LabeledContent("Keychain", value: security.keychainStatus())
                LabeledContent("身份密钥", value: security.identityKeyStatus(for: user))
                LabeledContent("设备密钥", value: security.deviceKeyStatus(for: user, context: context))
                LabeledContent("端到端加密", value: "未启用")
            }
            Section("隐私模式") {
                Toggle("一键开启", isOn: preference(\.privacyModeEnabled))
                Toggle("同时锁定所有聊天", isOn: preference(\.privacyModeLockChats))
                Text("开启时隐藏在线及最后上线状态、关闭消息预览，并在后台锁定应用。关闭后恢复原有偏好。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("隐私设置") {
                NavigationLink("隐私护盾") { PrivacyShieldView(user: user) }
                Toggle("截图提醒", isOn: preference(\.screenshotAlerts))
                Toggle("录屏提醒", isOn: preference(\.recordingAlerts))
                Toggle("消息预览", isOn: preference(\.messagePreviews))
                Toggle("显示在线状态", isOn: preference(\.showOnlineStatus))
                Toggle("显示最后上线时间", isOn: preference(\.showLastSeen))
                Toggle("已读回执", isOn: preference(\.readReceipts))
            }
            Section("设备") {
                LabeledContent("当前设备", value: UIDevice.current.name)
                NavigationLink("设备管理") { DeviceManagerView(user: user) }
            }
            Section("存储") {
                NavigationLink("加密备份与清理缓存") { StorageManagementView(user: user) }
            }
            Section { Text("在线状态、最后上线、已读回执和对方通知目前仅有本地模型与界面。截图与录屏提醒仅在本机生效。端到端加密尚未启用。") }
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("隐私中心")
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
    private func save() { do { try context.save() } catch { errorMessage = error.localizedDescription } }
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
            Section("系统检测") {
                Toggle("检测截图行为", isOn: preference(\.screenshotAlerts))
                Toggle("录屏时隐藏内容", isOn: Binding(
                    get: { security.preferences.effectiveScreenCaptureProtection },
                    set: { value in update { $0.screenCaptureProtection = value } }
                ))
                Toggle("后台隐藏隐私信息", isOn: preference(\.hideInBackground))
                Text("截图通知在截图发生后由系统提供，仅在本机生成隐私事件。录屏、镜像或 AirPlay 捕获时可隐藏应用内容。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("敏感聊天保护") {
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
                Text("受保护聊天需要 PIN 或 Face ID，且不进入本地搜索与收藏摘要；录屏和后台时隐藏内容。通知内容预览策略为未来通知接入预留。")
                    .font(.footnote).foregroundStyle(.secondary)
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
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var nickname = ""
    @State private var bio = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                HStack { Spacer(); AvatarView(name: user.nickname, imageData: user.avatar, size: 80); Spacer() }
                PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("从相册选择头像", systemImage: "photo") }
                if user.avatar != nil { Button("删除头像", role: .destructive) { user.avatar = nil; save() } }
            }
            Section("资料") {
                LabeledContent("UserID", value: user.userID)
                TextField("昵称", text: $nickname)
                TextField("简介", text: $bio, axis: .vertical).lineLimit(2...4)
                Button("保存资料") {
                    let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { errorMessage = "昵称不能为空"; return }
                    user.nickname = value; user.bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(); if errorMessage == nil { dismiss() }
                }
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
        .onAppear { nickname = user.nickname; bio = user.bio ?? "" }
        .onChange(of: selectedPhoto) { _, item in
            Task {
                do {
                    guard let data = try await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                    let maxSide: CGFloat = 512
                    let scale = min(1, maxSide / max(image.size.width, image.size.height))
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    let renderer = UIGraphicsImageRenderer(size: size)
                    user.avatar = renderer.jpegData(withCompressionQuality: 0.75) { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                    save()
                } catch { errorMessage = error.localizedDescription }
            }
        }
        .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
    private func save() { do { try context.save() } catch { errorMessage = error.localizedDescription } }
}
