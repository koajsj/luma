import SwiftData
import SwiftUI

struct OnlineConnectionView: View {
    let user: User
    @Environment(\.modelContext) private var context
    @Environment(SecurityManager.self) private var security
    @State private var address = ""
    @State private var registration: RemoteRegistration?
    @State private var hasTokens = false
    @State private var profile: RemoteProfile?
    @State private var searchID = ""
    @State private var found: RemoteUserResult?
    @State private var pending: [RemoteFriendRequest] = []
    @State private var remoteDevices: [RemoteDeviceInfo] = []
    @State private var revokingDevice: RemoteDeviceInfo?
    @State private var eventCount = 0
    @State private var remotePresence: PresenceSnapshot?
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var working = false

    private var viewModel: OnlineConnectionViewModel { OnlineConnectionViewModel(user: user, context: context, security: security) }

    var body: some View {
        Form {
            Section {
                if let registration {
                    LabeledContent("服务器", value: registration.baseURL.absoluteString)
                    LabeledContent("设备", value: registration.backendDeviceID.uuidString)
                    LabeledContent("状态", value: hasTokens ? "已登录 · 可在聊天中选择在线模式" : "需要设备登录")
                    if !hasTokens { Button("设备签名登录") { run { try await login() } } }
                    else { Button("退出服务器会话") { run { try await signOut() } } }
                } else {
                    TextField("HTTPS 服务器地址", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("登记此设备并登录") { run { try await register() } }
                        .disabled(address.isEmpty || working)
                }
            } header: { Text("连接") } footer: {
                Text("默认使用本地聊天；进入聊天后可显式切换在线开发模式。调试地址可在 Xcode Run Scheme 设置 LUMA_DEV_API_URL，也可在此输入。仅接受设备信任的 HTTPS，本地密码、PIN 和 Master Key 不会上传。")
            }

            if hasTokens {
                Section("服务器设备") {
                    Button("刷新设备") { run { remoteDevices = try await viewModel.devices() } }
                    ForEach(remoteDevices.filter { $0.revokedAt == nil }) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.deviceName)
                                Text(device.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.id == registration?.backendDeviceID { Text("当前设备").foregroundStyle(.secondary) }
                            else { Button("撤销设备", role: .destructive) { revokingDevice = device } }
                        }
                    }
                }
                Section("公开资料与隐私") {
                    if let profile {
                        LabeledContent("UserID", value: profile.userID)
                        LabeledContent("昵称", value: profile.nickname)
                        LabeledContent("可被搜索", value: profile.searchable ? "开启" : "关闭")
                        LabeledContent("展示在线状态", value: profile.showPresence ? "开启" : "关闭")
                    }
                    Button("同步本机昵称") { run { try await pushProfile() } }
                    Button("刷新服务器资料") { run { try await refresh() } }
                    Text("服务器搜索和在线展示维持默认关闭；本机隐私开关尚未与服务器自动同步。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    TextField("精确 UserID", text: $searchID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("搜索服务器用户") { run { try await search() } }
                        .disabled(searchID.isEmpty)
                    if let found {
                        LabeledContent("找到", value: "\(found.nickname) (@\(found.userID))")
                        Button("发送好友请求") { run { try await requestFriend() } }
                        Button("查询在线状态") { run {
                            remotePresence = try await viewModel.presence(for: found.userID)
                        } }
                        if let remotePresence {
                            LabeledContent("服务器在线状态", value: remotePresence.onlineStatus == .online ? "在线" :
                                           remotePresence.onlineStatus == .offline ? "离线" : "未知")
                        }
                    }
                    Button("刷新收到的请求") { run { try await refreshRequests() } }
                    Button("同步已确认好友到本机") { run {
                        let count = try await viewModel.syncConfirmedContacts()
                        notice = "已新增 \(count) 位本地联系人；请分别核对身份指纹。"
                    } }
                    ForEach(pending) { item in
                        HStack {
                            Text("@\(item.fromUserID)")
                            Spacer()
                            Button("接受") { run { try await decide(item, accept: true) } }
                            Button("拒绝") { run { try await decide(item, accept: false) } }
                        }
                    }
                } header: { Text("好友请求") } footer: {
                    Text("好友关系需要双方确认。默认聊天仍在本地；在线文字模式需先核对身份指纹。")
                }
                Section {
                    Button("检查服务器待处理事件") { run { try await inspectSync() } }
                    LabeledContent("待处理事件", value: "\(eventCount)")
                } header: { Text("同步状态") } footer: {
                    Text("此处只检查待处理数量。聊天页显式切换在线模式后才验证信封、保存本地密文并确认游标。")
                }
            }
            if working { ProgressView("正在连接") }
            if let notice { Text(notice).foregroundStyle(.secondary) }
        }
        .navigationTitle("服务器连接")
        .confirmationDialog("撤销设备？", isPresented: Binding(get: { revokingDevice != nil }, set: { if !$0 { revokingDevice = nil } })) {
            Button("撤销设备", role: .destructive) {
                guard let device = revokingDevice else { return }
                revokingDevice = nil
                run {
                    try await viewModel.revoke(deviceID: device.id)
                    remoteDevices = try await viewModel.devices()
                }
            }
            Button("取消", role: .cancel) { revokingDevice = nil }
        } message: {
            Text("此设备的服务器令牌会失效，连接将断开。其本机离线数据不会被远程擦除。")
        }
        .task { loadState() }
        .task(id: hasTokens) {
            guard hasTokens else { return }
            await viewModel.watchHints {
                if let count = try? await viewModel.inspectSync() {
                    await MainActor.run { eventCount = count }
                }
            }
        }
        .alert("在线操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确认", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func loadState() {
        do {
            (registration, hasTokens) = try viewModel.localState()
            address = registration?.baseURL.absoluteString ?? ProcessInfo.processInfo.environment["LUMA_DEV_API_URL"] ?? ""
        } catch { errorMessage = LumaError.message(for: error) }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do { try await operation(); errorMessage = nil }
            catch { loadState(); errorMessage = LumaError.message(for: error) }
        }
    }

    private func register() async throws {
        registration = try await viewModel.register(address: address)
        hasTokens = true
        try await refresh()
        notice = "此设备已登记。聊天默认保持本地模式。"
    }

    private func login() async throws {
        try await viewModel.login()
        hasTokens = true
        try await refresh()
    }

    private func signOut() async throws {
        try await viewModel.signOut()
        hasTokens = false
        profile = nil
        pending = []
    }

    private func refresh() async throws {
        profile = try await viewModel.profile()
        try await refreshRequests()
    }

    private func pushProfile() async throws {
        profile = try await viewModel.pushNickname()
        notice = "服务器资料已更新"
    }

    private func search() async throws {
        remotePresence = nil
        found = try await viewModel.search(searchID)
    }

    private func requestFriend() async throws {
        guard let found else { return }
        try await viewModel.requestFriend(found.userID)
        notice = "好友请求已发送"
    }

    private func refreshRequests() async throws {
        pending = try await viewModel.pendingRequests()
    }

    private func decide(_ item: RemoteFriendRequest, accept: Bool) async throws {
        try await viewModel.decide(item, accept: accept)
        try await refreshRequests()
    }

    private func inspectSync() async throws {
        eventCount = try await viewModel.inspectSync()
        notice = "已检查待处理事件数量；此操作不解密或确认消息。"
    }
}
