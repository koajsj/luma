import SwiftData
import SwiftUI

@main
struct LumaApp: App {
    @State private var security = SecurityManager()
    @State private var privacyShield = PrivacyShieldManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(security)
                .environment(privacyShield)
        }
        .modelContainer(for: [User.self, Device.self, Friend.self, Conversation.self, Message.self, Attachment.self, UserPresence.self, Reaction.self, SearchIndexEntry.self, V4PendingEvent.self, SessionKey.self, PreKeyMetadata.self, ChainState.self, V4SessionMetadata.self, V4DeviceMetadata.self, RemoteSyncCheckpoint.self, RemoteDeviceTrust.self, OutgoingMessageQueueItem.self, CleanupState.self])
    }
}

struct RootView: View {
    @AppStorage("privacyOnboardingCompleted") private var privacyOnboardingCompleted = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(SecurityManager.self) private var security
    @Environment(PrivacyShieldManager.self) private var privacyShield
    @Query private var users: [User]
    @State private var privacyNotice: String?

    private var activeUser: User? { users.first { $0.userID == security.activeUserID } }

    var body: some View {
        ZStack {
        Group {
            if !privacyOnboardingCompleted {
                PrivacyOnboardingView {
                    privacyOnboardingCompleted = true
                }
            } else {
            switch security.phase {
            case .loading: ProgressView("正在打开 Luma")
            case .registration, .login: AuthenticationView()
            case .setupPIN: PINView(isSetup: true)
            case .locked: PINView(isSetup: false, faceIDEnabled: (try? security.storedFaceIDPreference(for: activeUser)) ?? false)
            case .unlocked:
                if let activeUser { MainTabsView(user: activeUser) }
                else { AuthenticationView() }
            }
            }
        }
        .accessibilityHidden(shouldMask)
        .allowsHitTesting(!shouldMask)
        if shouldMask {
            ContentUnavailableView("内容已隐藏", systemImage: "eye.slash", description: Text("返回应用后可继续查看"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        }
        }
        .task {
            privacyShield.refreshCaptureState()
            if security.phase == .loading { security.restore(users: users, context: modelContext) }
        }
        .onChange(of: scenePhase) { _, phase in
            privacyShield.setScenePhase(phase)
            if phase != .active && security.preferences.effectiveBackgroundHide { security.lock() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            privacyShield.screenshotObserved(enabled: security.phase == .unlocked && security.preferences.screenshotAlerts)
            if privacyShield.latestEvent != nil {
                privacyNotice = "检测到应用内截图。当前仅在本机提醒；通知对方需等待通信服务接入。"
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            privacyShield.refreshCaptureState()
            if privacyShield.isCaptured && security.phase == .unlocked && security.preferences.recordingAlerts {
                privacyNotice = "检测到录屏。当前仅在本机提醒。"
            }
        }
        .alert("隐私提醒", isPresented: Binding(get: { privacyNotice != nil }, set: { if !$0 { privacyNotice = nil } })) {
            Button("确认", role: .cancel) { privacyNotice = nil }
        } message: { Text(privacyNotice ?? "") }
        .alert("暂时无法打开 Luma", isPresented: Binding(get: { security.startupError != nil }, set: { if !$0 { security.startupError = nil } })) {
            Button("确认", role: .cancel) { security.startupError = nil }
        } message: { Text("请重新打开应用。如果问题持续，请保留本机数据以便恢复。") }
    }

    private var shouldMask: Bool {
        privacyShield.shouldMask(captureProtection: security.preferences.effectiveScreenCaptureProtection ||
            privacyShield.visibleSensitiveConversationID != nil,
            backgroundEnabled: security.preferences.effectiveBackgroundHide)
    }
}

struct MainTabsView: View {
    let user: User
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SecurityManager.self) private var security
    var body: some View {
        TabView {
            ChatListView(user: user)
                .tabItem { Label("聊天", systemImage: "message.fill") }
            FriendsView(user: user)
                .tabItem { Label("好友", systemImage: "person.2.fill") }
            SettingsView(user: user)
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            try? ChatViewModel(context: context, security: security).cleanAttachmentFiles(for: user)
            while !Task.isCancelled && security.phase == .unlocked {
                if let registration = try? RemoteSessionStore().registration(for: user.userID),
                   (try? RemoteSessionStore().tokens(for: user.userID)) != nil,
                   let client = try? RemoteAPIClient(baseURL: registration.baseURL, userID: user.userID),
                   (try? security.encryptionService()) != nil {
                    let repository = RemoteMessageRepository(context: context, user: user,
                        security: security, client: client, registration: registration)
                    try? await repository.retryOutgoing()
                    // Resume inbound cursor sync after unlock/restart even if no chat is open.
                    _ = try? await repository.sync()
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}

#Preview {
    RootView()
        .environment(SecurityManager())
        .environment(PrivacyShieldManager())
        .modelContainer(for: [User.self, Device.self, Friend.self, Conversation.self, Message.self, Attachment.self, UserPresence.self, Reaction.self, SearchIndexEntry.self, V4PendingEvent.self, SessionKey.self, PreKeyMetadata.self, ChainState.self, V4SessionMetadata.self, V4DeviceMetadata.self, RemoteSyncCheckpoint.self, RemoteDeviceTrust.self, OutgoingMessageQueueItem.self, CleanupState.self], inMemory: true)
}
