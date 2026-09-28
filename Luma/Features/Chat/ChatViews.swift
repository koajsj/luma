import SwiftData
import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

struct ChatListView: View {
    let user: User
    @Environment(\.modelContext) private var context
    @Environment(SecurityManager.self) private var security
    @Query private var allFriends: [Friend]
    @Query private var allConversations: [Conversation]
    @Query private var presences: [UserPresence]
    @Query(sort: \Message.timestamp, order: .reverse) private var allMessages: [Message]
    @State private var showingAdd = false
    @State private var showingSearch = false
    @State private var showingFavorites = false
    @State private var chatQuery = ""
    @State private var errorMessage: String?

    private var friends: [Friend] { allFriends.filter { $0.ownerID == user.id } }
    private var sortedFriends: [Friend] {
        friends.sorted { left, right in
            let a = allConversations.first { $0.ownerID == user.id && $0.friendID == left.id }
            let b = allConversations.first { $0.ownerID == user.id && $0.friendID == right.id }
            if (a?.isPinned ?? false) != (b?.isPinned ?? false) { return a?.isPinned ?? false }
            return (lastMessage(for: left)?.timestamp ?? .distantPast) > (lastMessage(for: right)?.timestamp ?? .distantPast)
        }
    }
    private var visibleFriends: [Friend] {
        guard !chatQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return sortedFriends }
        return sortedFriends.filter { friend in
            !isProtected(friend) && (security.friendDisplayName(friend, context: context)
                .localizedStandardContains(chatQuery) || friend.userID.localizedStandardContains(chatQuery))
        }
    }
    private var viewModel: ChatViewModel { ChatViewModel(context: context, security: security) }

    var body: some View {
        NavigationStack {
            List {
                if friends.isEmpty {
                    ContentUnavailableView {
                        Label("开始聊天", systemImage: "message")
                    } description: {
                        Text("添加好友，发送第一条消息。")
                    } actions: {
                        Button("添加好友") { showingAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if visibleFriends.isEmpty {
                    ContentUnavailableView {
                        Label("没有找到聊天", systemImage: "magnifyingglass")
                    } description: {
                        Text("试试其他昵称或 UserID。")
                    } actions: {
                        Button("清除搜索") { chatQuery = "" }
                    }
                } else {
                    ForEach(visibleFriends) { friend in
                        NavigationLink {
                            ChatDetailView(user: user, friend: friend)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                AvatarView(name: security.friendDisplayName(friend, context: context), imageData: security.friendAvatar(friend, context: context))
                                    .overlay(alignment: .bottomTrailing) {
                                        if !isProtected(friend) && presences.first(where: { $0.friendID == friend.id })?.onlineStatus == .online {
                                            Circle().fill(.green).frame(width: 11, height: 11).overlay(Circle().stroke(.background, lineWidth: 2))
                                                .accessibilityLabel("在线 · 本地模拟")
                                        }
                                    }
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 5) {
                                        Text(security.friendDisplayName(friend, context: context))
                                            .font(.headline).lineLimit(1)
                                        if conversation(for: friend)?.isPinned == true {
                                            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
                                                .accessibilityLabel("已置顶")
                                        }
                                    }
                                    Text(preview(for: friend))
                                        .font(.subheadline)
                                        .foregroundStyle(conversation(for: friend)?.draft != nil && !isProtected(friend) ? .blue : .secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                VStack(alignment: .trailing, spacing: 7) {
                                    if let date = lastMessage(for: friend)?.timestamp {
                                        Text(chatListTime(for: date))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if let count = conversation(for: friend)?.unreadCount, count > 0 {
                                        Text("\(count)").font(.caption2.bold()).foregroundStyle(.white)
                                            .padding(.horizontal, 7).padding(.vertical, 3).background(.blue, in: Capsule())
                                            .accessibilityLabel("\(count) 条未读")
                                    }
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .swipeActions(edge: .leading) {
                            if let conversation = allConversations.first(where: { $0.ownerID == user.id && $0.friendID == friend.id }) {
                                Button(conversation.isPinned == true ? "取消置顶" : "置顶") {
                                    do { try viewModel.setPinned(conversation.isPinned != true, for: conversation) }
                                    catch { errorMessage = LumaError.message(for: error) }
                                }.tint(.orange)
                                Button("标记未读") {
                                    do { try viewModel.markUnread(conversation) }
                                    catch { errorMessage = LumaError.message(for: error) }
                                }.tint(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("聊天")
            .searchable(text: $chatQuery, prompt: "搜索聊天")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        UserProfileView(user: user)
                    } label: {
                        AvatarView(name: (try? security.userProfile(user, context: context).nickname) ?? user.userID,
                                   imageData: try? security.userProfile(user, context: context).avatar, size: 30)
                    }
                    .accessibilityLabel("个人资料")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button { showingSearch = true } label: { Label("搜索消息与文件", systemImage: "magnifyingglass") }
                        Button { showingFavorites = true } label: { Label("收藏消息", systemImage: "star") }
                    } label: { Label("更多", systemImage: "ellipsis.circle") }
                    Button { showingAdd = true } label: { Label("新聊天", systemImage: "square.and.pencil") }
                }
            }
            .sheet(isPresented: $showingAdd) { AddFriendView(user: user) }
            .sheet(isPresented: $showingSearch) { NavigationStack { LocalSearchView(user: user) } }
            .sheet(isPresented: $showingFavorites) { NavigationStack { FavoriteMessagesView(user: user) } }
            .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("确认", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func lastMessage(for friend: Friend) -> Message? {
        guard let conversation = conversation(for: friend) else { return nil }
        return allMessages.first { $0.conversationID == conversation.id && !$0.deleted }
    }

    private func conversation(for friend: Friend) -> Conversation? {
        allConversations.first { $0.ownerID == user.id && $0.friendID == friend.id }
    }

    private func isProtected(_ friend: Friend) -> Bool {
        guard let conversation = conversation(for: friend) else { return false }
        return conversation.requiresUnlock == true || conversation.requiresPrivacyShield == true ||
            (security.preferences.privacyModeEnabled && security.preferences.privacyModeLockChats)
    }

    private func chatListTime(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func preview(for friend: Friend) -> String {
        guard let conversation = conversation(for: friend) else { return "暂无消息" }
        if isProtected(friend) { return "已保护的聊天" }
        if !security.preferences.effectiveMessagePreviews { return "消息预览已关闭" }
        if conversation.draft != nil { return "草稿 · 已保存" }
        guard let message = lastMessage(for: friend) else { return "暂无消息" }
        switch message.type {
        case .text: return viewModel.visibleContent(for: message)
        case .image: return "[图片]"
        case .file: return "[文件]"
        case .voice: return "[语音]"
        }
    }
}

struct ChatDetailView: View {
    private struct ExpirationTaskID: Hashable { let date: Date?; let canView: Bool }
    let user: User
    let friend: Friend
    @Environment(\.modelContext) private var context
    @Environment(SecurityManager.self) private var security
    @Environment(PrivacyShieldManager.self) private var privacyShield
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var conversations: [Conversation]
    @Query private var allFriends: [Friend]
    @Query private var presences: [UserPresence]
    @Query(sort: \Message.timestamp) private var allMessages: [Message]
    @Query private var allReactions: [Reaction]
    @Query private var outgoingItems: [OutgoingMessageQueueItem]
    @Query private var pendingEvents: [V4PendingEvent]
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var replyTo: Message?
    @State private var deleting: Message?
    @State private var confirmingClear = false
    @State private var clearRequested = false
    @State private var showingActions = false
    @State private var showingInfo = false
    @State private var showingSecurity = false
    @State private var featureNote: String?
    @State private var editing: Message?
    @State private var forwarding: Message?
    @State private var editText = ""
    @State private var chatUnlocked = false
    @State private var chatPIN = ""
    @State private var typingStatus: TypingStatus = .idle
    @State private var draftLoaded = false
    @State private var onlineMode = false
    @State private var sendingOnline = false
    @State private var syncingOnline = false
    @State private var selectedAttachmentPhoto: PhotosPickerItem?
    @State private var showingPhotoPicker = false
    @State private var importingAttachment: MessageType = .file
    @State private var showingFileImporter = false
    @State private var attachmentPreview: AttachmentPreview?
    @State private var sendingAttachment = false
    @Environment(\.scenePhase) private var scenePhase

    private var viewModel: ChatViewModel { ChatViewModel(context: context, security: security) }

    private var conversation: Conversation? { conversations.first { $0.ownerID == user.id && $0.friendID == friend.id } }
    private var messages: [Message] {
        guard let conversation else { return [] }
        return allMessages.filter { $0.conversationID == conversation.id && (!$0.deleted || $0.deletedForEveryone) }
    }
    private var messageIDs: [UUID] { messages.map(\.id) }
    private var needsChatUnlock: Bool { conversation?.requiresUnlock == true || conversation?.requiresPrivacyShield == true || (security.preferences.privacyModeEnabled && security.preferences.privacyModeLockChats) }
    private var canViewChat: Bool { !needsChatUnlock || chatUnlocked }
    private var presence: UserPresence? { presences.first { $0.friendID == friend.id } }
    private var nextExpiration: Date? { messages.compactMap(\.expiresAt).min() }

    var body: some View {
        Group {
            if canViewChat { chatContent }
            else { chatUnlockView }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { if canViewChat { showingInfo = true } } label: {
                    HStack(spacing: 8) {
                        AvatarView(name: security.friendDisplayName(friend, context: context), imageData: security.friendAvatar(friend, context: context), size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(security.friendDisplayName(friend, context: context)).font(.headline).lineLimit(1)
                            if typingStatus == .typing && canViewChat { Text("正在输入 · 本地演示").font(.caption2).foregroundStyle(.secondary) }
                            else if canViewChat && presence?.onlineStatus == .online { Text("在线 · 本地模拟").font(.caption2).foregroundStyle(.green) }
                            else if canViewChat && presence?.onlineStatus == .offline, let lastSeen = presence?.lastSeenAt { Text("最后在线 \(lastSeen, style: .relative) · 本地模拟").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看\(security.friendDisplayName(friend, context: context))的聊天详情")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if canViewChat {
                    Menu {
                        Button { showingInfo = true } label: { Label("聊天信息", systemImage: "info.circle") }
                        if viewModel.onlineAvailable(for: user) {
                            Button { onlineMode.toggle() } label: {
                                Label(onlineMode ? "切换到本地聊天" : "切换到在线密文聊天",
                                      systemImage: onlineMode ? "iphone" : "network.badge.shield.half.filled")
                            }
                            Button { Task { await syncOnline() } } label: {
                                Label("同步线上消息", systemImage: "arrow.clockwise")
                            }.disabled(syncingOnline)
                        }
                    } label: { Image(systemName: "info.circle") }
                }
            }
        }
        .sheet(isPresented: $showingActions) { AttachmentActionsView(onlineMode: onlineMode, onSimulate: { type in
            showingActions = false
            addSimulated(type)
        }, onPick: { type in
            showingActions = false
            if type == .image { showingPhotoPicker = true }
            else { importingAttachment = type; showingFileImporter = true }
        }, onUnavailable: { note in
            showingActions = false
            featureNote = note
        }) }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedAttachmentPhoto, matching: .images)
        .onChange(of: selectedAttachmentPhoto) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw V4AttachmentError.invalidDescriptor
                    }
                    try await sendAttachment(data, name: "image", type: .image)
                } catch { featureNote = LumaError.message(for: error) }
                selectedAttachmentPhoto = nil
            }
        }
        .fileImporter(isPresented: $showingFileImporter,
            allowedContentTypes: importingAttachment == .voice ? [.audio] : [.item]) { result in
            let type = importingAttachment
            switch result {
            case .failure(let error): featureNote = LumaError.message(for: error)
            case .success(let url):
                Task {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 20 << 20 else { throw V4AttachmentError.tooLarge }
                        try await sendAttachment(Data(contentsOf: url), name: url.lastPathComponent, type: type)
                    } catch { featureNote = LumaError.message(for: error) }
                }
            }
        }
        .sheet(item: $attachmentPreview) { AttachmentPreviewView(preview: $0) }
        .sheet(isPresented: $showingInfo, onDismiss: {
            if clearRequested { clearRequested = false; confirmingClear = true }
        }) { ChatInfoView(user: user, friend: friend, conversation: conversation,
                         typingStatus: $typingStatus, onClear: { clearRequested = true }) }
        .sheet(isPresented: $showingSecurity) {
            ChatSecurityView(user: user, friend: friend, conversation: conversation, onlineMode: onlineMode)
        }
        .sheet(item: $editing) { message in
            NavigationStack {
                Form { TextField("编辑消息", text: $editText, axis: .vertical).lineLimit(3...8) }
                    .navigationTitle("编辑消息")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = nil } }
                        ToolbarItem(placement: .confirmationAction) { Button("保存") {
                            if [3, 4].contains(message.transportEncryptionVersion ?? 0), let conversation {
                                Task {
                                    do { try await viewModel.editOnlineText(editText, message: message, user: user,
                                        friend: friend, conversation: conversation); editing = nil }
                                    catch { featureNote = LumaError.message(for: error) }
                                }
                            } else {
                                do { try viewModel.edit(message, text: editText); editing = nil }
                                catch { featureNote = LumaError.message(for: error) }
                            }
                        }.disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                    }
            }
        }
        .sheet(item: $forwarding) { message in
            NavigationStack {
                List {
                    ForEach(conversations.filter { $0.ownerID == user.id && $0.id != conversation?.id }) { target in
                        if let recipient = allFriends.first(where: { $0.id == target.friendID }) {
                            Button(security.friendDisplayName(recipient, context: context)) {
                                do { try viewModel.forward(message, to: target); forwarding = nil }
                                catch { featureNote = LumaError.message(for: error) }
                            }
                        }
                    }
                }
                .navigationTitle("转发到本地聊天")
                .toolbar { Button("取消") { forwarding = nil } }
            }
        }
        .confirmationDialog("删除消息", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("仅从本机删除", role: .destructive) { delete(forEveryone: false) }
            if deleting?.isMine == true {
                Button([3, 4].contains(deleting?.transportEncryptionVersion ?? 0) ? "通知其他设备删除" : "在本机标记为已删除",
                       role: .destructive) { delete(forEveryone: true) }
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { Text([3, 4].contains(deleting?.transportEncryptionVersion ?? 0) ?
                          "服务器将发送删除事件；已下载副本不能保证物理擦除。" : "当前仅清理此设备的数据，不会影响其他设备。") }
        .confirmationDialog("清空此设备上的聊天记录？", isPresented: $confirmingClear) {
            Button("清空聊天记录", role: .destructive) { clearLocalChat() }
            Button("取消", role: .cancel) { }
        } message: { Text("不会撤回其他设备已收到的消息。此操作无法撤销。") }
        .alert("提示", isPresented: Binding(get: { featureNote != nil }, set: { if !$0 { featureNote = nil } })) {
            Button("确认", role: .cancel) { featureNote = nil }
        } message: { Text(featureNote ?? "") }
        .onAppear {
            updateVisiblePrivacyShield()
            if viewModel.onlineAvailable(for: user) && messages.contains(where: {
                [3, 4].contains($0.transportEncryptionVersion ?? 0)
            }) {
                onlineMode = true
            }
            loadDraftIfAllowed(); markVisibleRead()
        }
        .onDisappear { privacyShield.setVisibleConversation(nil, protected: false) }
        .onChange(of: conversation?.requiresPrivacyShield) { _, _ in
            chatUnlocked = false; draftLoaded = false; draft = ""; showingInfo = false
            attachmentPreview = nil; updateVisiblePrivacyShield()
        }
        .onChange(of: messages.count) { _, _ in markVisibleRead() }
        .task(id: ExpirationTaskID(date: nextExpiration, canView: canViewChat)) {
            guard canViewChat, let nextExpiration, let conversation else { return }
            let delay = max(0, nextExpiration.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            do { try viewModel.purgeExpired(conversation) }
            catch { featureNote = LumaError.message(for: error) }
        }
        .onChange(of: draft) { _, value in
            guard canViewChat, draftLoaded, let conversation else { return }
            do { try viewModel.saveDraft(value, in: conversation) } catch { featureNote = LumaError.message(for: error) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                chatUnlocked = false; draftLoaded = false; draft = ""
                if needsChatUnlock { showingInfo = false; showingSecurity = false; attachmentPreview = nil }
            }
        }
        .onChange(of: conversation?.requiresUnlock) { _, _ in chatUnlocked = false; draftLoaded = false; draft = ""; closePrivateContent() }
        .onChange(of: security.preferences.privacyModeEnabled) { _, _ in chatUnlocked = false; draftLoaded = false; draft = ""; closePrivateContent() }
        .onChange(of: security.preferences.privacyModeLockChats) { _, _ in chatUnlocked = false; draftLoaded = false; draft = ""; closePrivateContent() }
        .task(id: onlineMode) {
            guard onlineMode else { return }
            while !Task.isCancelled {
                await syncOnline()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func updateVisiblePrivacyShield() {
        privacyShield.setVisibleConversation(conversation?.id, protected: conversation?.requiresPrivacyShield == true)
    }

    private func closePrivateContent() {
        if needsChatUnlock { showingInfo = false; showingSecurity = false; attachmentPreview = nil }
    }

    private var chatUnlockView: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.bubble").font(.largeTitle)
            Text("此聊天已锁定").font(.title3.bold())
            SecureField("6 位 PIN", text: $chatPIN).keyboardType(.numberPad).textContentType(.oneTimeCode)
                .frame(maxWidth: 220).textFieldStyle(.roundedBorder)
            Button("使用 PIN 查看") {
                do { try security.verifyChatPIN(chatPIN); chatPIN = ""; chatUnlocked = true; loadDraftIfAllowed(); markVisibleRead() }
                catch { featureNote = LumaError.message(for: error) }
            }.buttonStyle(.borderedProminent)
            if security.canUseBiometrics() {
                Button("使用 Face ID") {
                    Task { do { try await security.verifyChatBiometrics(); chatUnlocked = true; loadDraftIfAllowed(); markVisibleRead() }
                           catch { featureNote = LumaError.message(for: error) } }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            Button { showingSecurity = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                    Text("隐私保护已开启")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .accessibilityHint("查看此聊天的安全详情")

            if friend.sessionStatus == "identityKeyChanged" {
                Label("好友身份已变化，请前往好友资料重新核对", systemImage: "exclamationmark.shield")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            if syncingOnline {
                ProgressView("正在同步消息")
                    .font(.footnote)
                    .padding(.horizontal)
            }

            ScrollViewReader { proxy in ScrollView {
                LazyVStack(spacing: 12) {
                    if messages.isEmpty {
                        ContentUnavailableView {
                            Label("还没有消息", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text("发送一条消息，开始聊天。")
                        } actions: {
                            Button("输入消息") { composerFocused = true }
                        }
                            .padding(.top, 72)
                    }
                    ForEach(messages) { message in
                        MessageRow(message: message,
                                   content: message.deleted ? "消息已删除" : viewModel.visibleContent(for: message),
                                   reactions: allReactions.filter { $0.messageID == message.id }.map(\.emoji),
                                   showReadReceipts: security.preferences.readReceipts,
                                   replyPreview: message.replyToID.map { id in
                                       guard let original = messages.first(where: { $0.id == id }) else { return "原消息不可用" }
                                       return original.deleted ? "原消息已删除" : viewModel.visibleContent(for: original)
                                   },
                                   onReplyTap: { if let id = message.replyToID { withAnimation { proxy.scrollTo(id, anchor: .center) } } },
                                   onOpen: { Task {
                                       do {
                                           let result = try await viewModel.downloadOnlineAttachment(message, user: user)
                                           attachmentPreview = AttachmentPreview(data: result.0, name: result.1, type: result.2)
                                       } catch { featureNote = LumaError.message(for: error) }
                                   } },
                                   onRetry: { Task {
                                       do { try await viewModel.retryFailedOnline(message.id, user: user) }
                                       catch { featureNote = LumaError.message(for: error) }
                                   } })
                            .contextMenu {
                                if !message.deleted {
                                ForEach(["👍", "❤️", "😂", "‼️"], id: \.self) { emoji in
                                    Button(emoji) {
                                        if [3, 4].contains(message.transportEncryptionVersion ?? 0), let conversation {
                                            Task {
                                                do { try await viewModel.reactOnline(emoji, to: message, user: user,
                                                    friend: friend, conversation: conversation) }
                                                catch { featureNote = LumaError.message(for: error) }
                                            }
                                        } else {
                                            do { try viewModel.react(emoji, to: message) }
                                            catch { featureNote = LumaError.message(for: error) }
                                        }
                                    }
                                }
                                Button { replyTo = message; UIImpactFeedbackGenerator(style: .light).impactOccurred() } label: { Label("回复", systemImage: "arrowshape.turn.up.left") }
                                if message.type == .text {
                                    Button {
                                        do { UIPasteboard.general.string = try viewModel.displayContent(for: message) }
                                        catch { featureNote = LumaError.message(for: error) }
                                    } label: { Label("复制", systemImage: "doc.on.doc") }
                                }
                                if message.type == .text && message.isMine {
                                    Button { editing = message; editText = viewModel.visibleContent(for: message) } label: { Label("编辑", systemImage: "pencil") }
                                }
                                Button {
                                    do { try viewModel.setFavorite(message.isFavorite != true, for: message) }
                                    catch { featureNote = LumaError.message(for: error) }
                                } label: { Label(message.isFavorite == true ? "取消收藏" : "收藏", systemImage: message.isFavorite == true ? "star.slash" : "star") }
                                Button(role: .destructive) { deleting = message } label: { Label("删除", systemImage: "trash") }
                                Menu { Button { forwarding = message } label: { Label("转发到本地聊天", systemImage: "arrowshape.turn.up.right") } }
                                    label: { Label("更多", systemImage: "ellipsis") }
                                }
                            }
                            .id(message.id)
                            .transition(.opacity.combined(with: .move(edge: message.isMine ? .trailing : .leading)))
                    }
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: messageIDs)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)

            if let replyTo {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left")
                    Text("回复：\(replyTo.deleted ? "原消息已删除" : viewModel.visibleContent(for: replyTo))").lineLimit(1)
                    Spacer()
                    Button { self.replyTo = nil } label: { Image(systemName: "xmark.circle.fill") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button { showingActions = true } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                    .accessibilityLabel("添加内容")
                TextField("信息", text: $draft, axis: .vertical)
                    .focused($composerFocused)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                if sendingAttachment {
                    ProgressView().accessibilityLabel("正在处理附件")
                } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { featureNote = "语音录制接口将在后续阶段接入。" } label: { Image(systemName: "waveform").font(.title3) }
                        .accessibilityLabel("语音")
                } else {
                    Button { sendText() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(sendingOnline)
                        .accessibilityLabel("发送")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func loadDraftIfAllowed() {
        guard canViewChat, let conversation, !draftLoaded else { return }
        do { draft = try viewModel.draft(in: conversation); draftLoaded = true }
        catch { featureNote = LumaError.message(for: error) }
    }

    private func sendText() {
        if onlineMode {
            guard let conversation else { featureNote = "请先建立本地聊天"; return }
            let text = draft
            sendingOnline = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task {
                defer { sendingOnline = false }
                do {
                    try await viewModel.sendOnlineText(text, user: user, friend: friend, conversation: conversation)
                    if draft == text { draft = ""; replyTo = nil }
                } catch { featureNote = LumaError.message(for: error) }
            }
            return
        }
        do {
            if try viewModel.sendText(draft, in: conversation, replyingTo: replyTo) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                draft = ""; replyTo = nil
            }
        } catch { featureNote = LumaError.message(for: error) }
    }

    private func syncOnline() async {
        guard onlineMode, canViewChat, !syncingOnline else { return }
        syncingOnline = true
        defer { syncingOnline = false }
        do { _ = try await viewModel.syncOnline(user: user) }
        catch { featureNote = LumaError.message(for: error); onlineMode = false }
    }

    private func addSimulated(_ type: MessageType) {
        if onlineMode { featureNote = "在线附件尚未支持，未向服务器发送文件。"; return }
        do {
            try viewModel.sendPlaceholder(type, in: conversation)
        } catch { featureNote = LumaError.message(for: error) }
    }

    private func sendAttachment(_ data: Data, name: String, type: MessageType) async throws {
        guard onlineMode, canViewChat, let conversation else { throw V4AttachmentError.invalidDescriptor }
        sendingAttachment = true
        defer { sendingAttachment = false }
        try await viewModel.sendOnlineAttachment(data, name: name, type: type,
            user: user, friend: friend, conversation: conversation)
    }

    private func clearLocalChat() {
        let messageIDs = Set(messages.map(\.id))
        guard !outgoingItems.contains(where: { messageIDs.contains($0.messageID) }),
              !pendingEvents.contains(where: { messageIDs.contains($0.messageID) }) else {
            featureNote = "仍有待同步内容，请等待发送完成后再清空本机记录。"
            return
        }
        do {
            for message in messages {
                if message.deleted {
                    // A remote deletion tombstone remains for sync, but clearing this device hides it.
                    message.deletedForEveryone = false
                } else {
                    try viewModel.delete(message, forEveryone: false)
                }
            }
            try context.save()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { featureNote = LumaError.message(for: error) }
    }

    private func delete(forEveryone: Bool) {
        guard let deleting else { return }
        if forEveryone && [3, 4].contains(deleting.transportEncryptionVersion ?? 0) {
            Task {
                do { try await viewModel.deleteOnline(deleting, user: user) }
                catch { featureNote = LumaError.message(for: error) }
            }
            self.deleting = nil
            return
        }
        do { try viewModel.delete(deleting, forEveryone: forEveryone) }
        catch { featureNote = LumaError.message(for: error) }
        self.deleting = nil
    }

    private func markVisibleRead() {
        guard canViewChat, let conversation else { return }
        if onlineMode {
            Task {
                do { try await viewModel.markOnlineRead(conversation, user: user) }
                catch { featureNote = LumaError.message(for: error) }
            }
            return
        }
        do {
            try viewModel.purgeExpired(conversation)
            try viewModel.markRead(conversation)
        } catch { featureNote = LumaError.message(for: error) }
    }
}

private struct MessageRow: View {
    let message: Message
    let content: String
    let reactions: [String]
    let showReadReceipts: Bool
    let replyPreview: String?
    let onReplyTap: () -> Void
    let onOpen: () -> Void
    let onRetry: () -> Void
    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 50) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 4) {
              VStack(alignment: .leading, spacing: 5) {
                if !message.deleted, let origin = message.forwardedFrom { Text(origin).font(.caption2).opacity(0.8) }
                if !message.deleted, let replyPreview {
                    Button(action: onReplyTap) {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).frame(width: 3)
                            Text("回复：\(replyPreview)").lineLimit(2).multilineTextAlignment(.leading)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .opacity(0.8)
                }
                if message.deleted {
                    Label("消息已删除", systemImage: "trash")
                } else {
                switch message.type {
                case .text: Text(content)
                case .image:
                    if message.transportEncryptionVersion == 4 { Button(action: onOpen) { Label("打开图片", systemImage: "photo") } }
                    else { Label(content, systemImage: "photo") }
                case .file:
                    if message.transportEncryptionVersion == 4 { Button(action: onOpen) { Label("打开文件", systemImage: "doc") } }
                    else { Label(content, systemImage: "doc") }
                case .voice:
                    if message.transportEncryptionVersion == 4 { Button(action: onOpen) { Label("播放语音", systemImage: "waveform") } }
                    else { Label(content, systemImage: "waveform") }
                }
                }
                if !message.deleted && message.editedAt != nil { Text("已编辑").font(.caption2).opacity(0.75) }
              }
              .font(.body)
              .padding(.horizontal, 14).padding(.vertical, 9)
              .foregroundStyle(message.isMine ? Color.white : Color.primary)
              .background(message.isMine ? Color.blue : Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 18))
              if !message.deleted && !reactions.isEmpty {
                  Text(reactions.joined(separator: " "))
                      .font(.caption)
                      .padding(.horizontal, 8).padding(.vertical, 3)
                      .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                      .accessibilityLabel("回应：\(reactions.joined(separator: "、"))")
              }
              HStack(spacing: 5) {
                  Text(message.timestamp, format: .dateTime.hour().minute())
                  if message.isMine && !message.deleted {
                      switch message.deliveryStatus {
                      case .sending: Text("发送中")
                      case .failed: Button("发送失败 · 重试", action: onRetry)
                      case .sent: Text("已发送")
                      case .delivered: Text("已送达")
                      case .read:
                          if showReadReceipts, let date = message.readAt {
                              Text("已读"); Text(date, format: .dateTime.hour().minute())
                          } else { Text("已发送") }
                      }
                  }
              }
              .font(.caption2).foregroundStyle(.secondary)
            }
            if !message.isMine { Spacer(minLength: 50) }
        }
    }
}

private struct AttachmentActionsView: View {
    let onlineMode: Bool
    let onSimulate: (MessageType) -> Void
    let onPick: (MessageType) -> Void
    let onUnavailable: (String) -> Void
    var body: some View {
        NavigationStack {
            List {
                Button { onlineMode ? onPick(.image) : onSimulate(.image) } label: { Label("图片", systemImage: "photo") }
                Button { onlineMode ? onPick(.file) : onSimulate(.file) } label: { Label("文件", systemImage: "doc") }
                Button { onUnavailable("相机接口将在后续阶段接入。") } label: { Label("相机", systemImage: "camera") }
                Button { onlineMode ? onPick(.voice) : onSimulate(.voice) } label: { Label("语音", systemImage: "waveform") }
                Button { onUnavailable("可在设置中开启本机阅后即焚；当前不向其他设备发送销毁指令。") } label: { Label("阅后即焚", systemImage: "flame") }
            }
            .navigationTitle("添加内容")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium])
            .safeAreaInset(edge: .bottom) { Text(onlineMode ? "先在本机加密，再上传密文附件。语音可从文件中选择。" : "图片、文件和语音当前创建本地模拟消息。")
                .font(.caption).foregroundStyle(.secondary).padding() }
        }
    }
}

private struct AttachmentPreview: Identifiable {
    let id = UUID()
    let data: Data
    let name: String
    let type: MessageType
}

private struct AttachmentDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw V4AttachmentError.invalidDescriptor }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct AttachmentPreviewView: View {
    let preview: AttachmentPreview
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var imageZoomed = false
    @State private var player: AVAudioPlayer?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                switch preview.type {
                case .image:
                    if let image = UIImage(data: preview.data) {
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: image)
                                .resizable().scaledToFit()
                                .scaleEffect(imageZoomed ? 1.6 : 1)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .onTapGesture { withAnimation(.smooth(duration: 0.25)) { imageZoomed.toggle() } }
                                .accessibilityHint("轻点放大或缩小图片")
                        }
                    } else { ContentUnavailableView("图片无法显示", systemImage: "photo.badge.exclamationmark") }
                case .voice:
                    VStack(spacing: 16) {
                        Image(systemName: "waveform").font(.largeTitle)
                        Button("播放语音") {
                            do {
                                player = try AVAudioPlayer(data: preview.data)
                                player?.play()
                            } catch { errorMessage = "语音文件无法播放。" }
                        }
                    }
                case .file:
                    VStack(spacing: 12) {
                        Image(systemName: "doc").font(.largeTitle)
                        Text(preview.name)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(preview.data.count),
                                                       countStyle: .file)).foregroundStyle(.secondary)
                        Button("导出解密文件") { exporting = true }
                    }
                case .text: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(preview.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
        .fileExporter(isPresented: $exporting, document: AttachmentDocument(data: preview.data),
                      contentType: UTType(filenameExtension: URL(fileURLWithPath: preview.name).pathExtension) ?? .data,
                      defaultFilename: preview.name) { result in
            if case .failure = result { errorMessage = "导出失败。" }
        }
        .onDisappear { player?.stop(); player = nil; imageZoomed = false }
        .alert("附件", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确认", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct ChatInfoView: View {
    let user: User
    let friend: Friend
    let conversation: Conversation?
    @Binding var typingStatus: TypingStatus
    let onClear: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(SecurityManager.self) private var security
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ProfileHeaderView(name: security.friendDisplayName(friend, context: context),
                                      subtitle: "@\(friend.userID)",
                                      imageData: security.friendAvatar(friend, context: context))
                }
                Section {
                    NavigationLink { FriendProfileView(friend: friend) } label: { Label("好友资料", systemImage: "person.crop.circle") }
                    if let conversation {
                        NavigationLink { LocalSearchView(user: user, conversationID: conversation.id) } label: {
                            Label("搜索聊天内容", systemImage: "magnifyingglass")
                        }
                        NavigationLink { ChatAttachmentsView(user: user, conversation: conversation) } label: {
                            Label("媒体与文件", systemImage: "photo.on.rectangle")
                        }
                    }
                }
                if let conversation {
                    Section("聊天") {
                        Toggle("置顶聊天", isOn: Binding(get: { conversation.isPinned == true }, set: { value in
                            let previous = conversation.isPinned
                            conversation.isPinned = value
                            do { try context.save() } catch {
                                conversation.isPinned = previous
                                errorMessage = LumaError.message(for: error)
                            }
                        }))
                        Button {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        } label: { Label("系统通知设置", systemImage: "bell") }
                        Toggle("聊天锁", isOn: Binding(get: { conversation.requiresUnlock ?? false }, set: { value in
                            let previous = conversation.requiresUnlock
                            conversation.requiresUnlock = value
                            save(orRestore: { conversation.requiresUnlock = previous })
                        }))
                        Toggle("敏感聊天保护", isOn: Binding(get: { conversation.requiresPrivacyShield ?? false }, set: { value in
                            let previous = conversation.requiresPrivacyShield
                            conversation.requiresPrivacyShield = value
                            save(orRestore: { conversation.requiresPrivacyShield = previous })
                        }))
                    }
                    Section {
                        Button("清空聊天记录", role: .destructive) { onClear(); dismiss() }
                    } footer: {
                        Text("清空仅作用于本机，不会撤回其他设备已收到的消息。")
                    }
                }
                Section("本地演示") {
                    Toggle("正在输入状态", isOn: Binding(get: { typingStatus == .typing }, set: { typingStatus = $0 ? .typing : .idle }))
                }
            }
            .navigationTitle("聊天详情")
            .toolbar { Button("完成") { dismiss() } }
            .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("确认", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
    private func save(orRestore restore: () -> Void) {
        do { try context.save() }
        catch { restore(); errorMessage = LumaError.message(for: error) }
    }
}

private struct ChatAttachmentsView: View {
    let user: User
    let conversation: Conversation
    @Environment(\.modelContext) private var context
    @Environment(SecurityManager.self) private var security
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Message.timestamp, order: .reverse) private var allMessages: [Message]
    @State private var preview: AttachmentPreview?
    @State private var loadingID: UUID?
    @State private var errorMessage: String?

    private var attachments: [Message] {
        allMessages.filter { $0.conversationID == conversation.id && !$0.deleted && $0.type != .text }
    }

    var body: some View {
        List {
            if attachments.isEmpty {
                ContentUnavailableView {
                    Label("还没有媒体或文件", systemImage: "photo.on.rectangle")
                } description: {
                    Text("此聊天的图片、语音和文件会显示在这里。")
                } actions: {
                    Button("返回聊天") { dismiss() }
                }
            }
            ForEach(attachments) { message in
                Button {
                    guard message.transportEncryptionVersion == 4 else { return }
                    loadingID = message.id
                    Task {
                        defer { loadingID = nil }
                        do {
                            let result = try await ChatViewModel(context: context, security: security)
                                .downloadOnlineAttachment(message, user: user)
                            preview = AttachmentPreview(data: result.0, name: result.1, type: result.2)
                        } catch { errorMessage = LumaError.message(for: error) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: message.type == .image ? "photo" : message.type == .voice ? "waveform" : "doc")
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(message.type == .image ? "图片" : message.type == .voice ? "语音" : "文件")
                            Text(message.timestamp, format: .dateTime.year().month().day())
                                .font(.caption).foregroundStyle(.secondary)
                            if message.transportEncryptionVersion != 4 {
                                Text("本地模拟附件不可预览").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if loadingID == message.id { ProgressView() }
                    }
                }
                .disabled(message.transportEncryptionVersion != 4 || loadingID != nil)
            }
        }
        .navigationTitle("媒体与文件")
        .sheet(item: $preview) { AttachmentPreviewView(preview: $0) }
        .alert("附件无法打开", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确认", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct ChatSecurityView: View {
    let user: User
    let friend: Friend
    let conversation: Conversation?
    let onlineMode: Bool
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var statusRefresh = false

    var body: some View {
        NavigationStack {
            Form {
                Section("当前聊天") {
                    LabeledContent("消息保护", value: onlineMode ? "在线密文传输基础" : "本机加密保存")
                    LabeledContent("聊天锁", value: conversation?.requiresUnlock == true ? "已开启" : "未开启")
                    LabeledContent("敏感聊天保护", value: conversation?.requiresPrivacyShield == true ? "已开启" : "未开启")
                }
                Section("本机模拟会话") {
                    LabeledContent("状态", value: friend.sessionStatus == "identityKeyChanged" ||
                                   friend.sessionStatus == "identityReverified" ? "旧会话已暂停" :
                                   security.localSessionStatus(for: user, friend: friend, context: context))
                        .id(statusRefresh)
                    if friend.sessionStatus != "identityKeyChanged" &&
                        (security.localSessionStatus(for: user, friend: friend, context: context) == "未建立" ||
                         friend.sessionStatus == "identityReverified") {
                        Button("建立本机模拟会话") {
                            do { try security.createLocalSession(for: user, friend: friend, context: context); statusRefresh.toggle() }
                            catch { errorMessage = LumaError.message(for: error) }
                        }
                    }
                }
                Section("好友身份") {
                    LabeledContent("验证状态", value: friend.sessionStatus == "identityKeyChanged" ? "身份已变化 · 需要重新验证" :
                                   friend.identityFingerprint == nil ? "尚未核对" : "身份已记录 · 尚需人工核对")
                }
                Section { Text("核对安全码请前往好友资料。整体保护与技术说明位于设置的隐私与安全页面。") }
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("当前聊天安全")
            .toolbar { Button("完成") { dismiss() } }
            .alert("建立会话失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("确认", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
}

private struct LocalSearchView: View {
    let user: User
    var conversationID: UUID? = nil
    @Environment(\.modelContext) private var context
    @Environment(SecurityManager.self) private var security
    @Query private var friends: [Friend]
    @Query private var conversations: [Conversation]
    @State private var query = ""
    @State private var results: [LocalSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if query.isEmpty {
                ContentUnavailableView("本地搜索", systemImage: "magnifyingglass", description:
                    Text(conversationID == nil ? "搜索消息、文件名和好友备注。索引仅加密保存在本机。" : "搜索这段聊天的消息与文件。"))
            } else if isSearching {
                ProgressView("正在搜索")
            } else if results.isEmpty {
                ContentUnavailableView {
                    Label("没有找到结果", systemImage: "magnifyingglass")
                } description: {
                    Text("试试其他关键词。受保护的聊天不会出现在结果中。")
                } actions: {
                    Button("清除搜索") { query = ""; results = [] }
                }
            } else {
                ForEach(results) { result in
                    if let friend = friend(for: result) {
                        NavigationLink {
                            ChatDetailView(user: user, friend: friend)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(result.preview).lineLimit(2)
                                Text(result.kind == "friend" ? "好友备注" : result.kind == "file" ? "文件名" : "消息")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "搜索本机内容")
        .onChange(of: query) { _, _ in results = [] }
        .onSubmit(of: .search) { performSearch() }
        .navigationTitle(conversationID == nil ? "本地搜索" : "搜索聊天")
        .alert("搜索失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确认", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func friend(for result: LocalSearchResult) -> Friend? {
        if result.kind == "friend" { return friends.first { $0.id == result.sourceID && $0.ownerID == user.id } }
        guard let conversationID = result.conversationID,
              let conversation = conversations.first(where: { $0.id == conversationID && $0.ownerID == user.id }) else { return nil }
        return friends.first { $0.id == conversation.friendID }
    }

    private func performSearch() {
        let submittedQuery = query
        isSearching = true
        Task { @MainActor in
            await Task.yield()
            guard query == submittedQuery else { isSearching = false; return }
            defer { isSearching = false }
            do {
                let found = try ChatViewModel(context: context, security: security).search(submittedQuery, for: user)
                results = conversationID.map { id in found.filter { $0.conversationID == id } } ?? found
            } catch { errorMessage = LumaError.message(for: error) }
        }
    }
}

private struct FavoriteMessagesView: View {
    let user: User
    @Environment(\.modelContext) private var context
    @Environment(SecurityManager.self) private var security
    @Environment(\.dismiss) private var dismiss
    @Query private var friends: [Friend]
    @Query private var conversations: [Conversation]
    @Query(sort: \Message.timestamp, order: .reverse) private var messages: [Message]
    private var favorites: [Message] {
        let lockAll = security.preferences.privacyModeEnabled && security.preferences.privacyModeLockChats
        let ids = Set(conversations.filter {
            $0.ownerID == user.id && $0.requiresPrivacyShield != true && $0.requiresUnlock != true && !lockAll
        }.map(\.id))
        return messages.filter { ids.contains($0.conversationID) && $0.isFavorite == true && !$0.deleted }
    }
    var body: some View {
        List {
            if favorites.isEmpty {
                ContentUnavailableView {
                    Label("还没有收藏消息", systemImage: "star")
                } description: {
                    Text("长按消息即可收藏。受保护聊天的收藏不会在此显示。")
                } actions: {
                    Button("返回聊天") { dismiss() }
                }
            }
            ForEach(favorites) { message in
                if let conversation = conversations.first(where: { $0.id == message.conversationID }),
                   let friend = friends.first(where: { $0.id == conversation.friendID }) {
                    NavigationLink {
                        ChatDetailView(user: user, friend: friend)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(security.friendDisplayName(friend, context: context)).font(.caption).foregroundStyle(.secondary)
                            Text(conversation.requiresUnlock == true ||
                                 (security.preferences.privacyModeEnabled && security.preferences.privacyModeLockChats)
                                 ? "已锁定的聊天" : ChatViewModel(context: context, security: security).visibleContent(for: message))
                                .lineLimit(2)
                        }
                    }
                }
            }
        }.navigationTitle("收藏消息")
    }
}

#Preview("聊天 · 深色与大字体") {
    let container = try! ModelContainer(for: User.self, Device.self, Friend.self, Conversation.self, Message.self, Attachment.self, UserPresence.self, Reaction.self, SearchIndexEntry.self, V4PendingEvent.self, SessionKey.self, PreKeyMetadata.self, ChainState.self, V4SessionMetadata.self, V4DeviceMetadata.self, OutgoingMessageQueueItem.self, CleanupState.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let user = User(userID: "alice", nickname: "Alice", passwordHash: "preview")
    let friend = Friend(ownerID: user.id, userID: "bob", nickname: "Bob")
    let conversation = Conversation(ownerID: user.id, friendID: friend.id)
    container.mainContext.insert(user)
    container.mainContext.insert(friend)
    container.mainContext.insert(conversation)
    return NavigationStack { ChatDetailView(user: user, friend: friend) }
        .modelContainer(container)
        .environment(SecurityManager())
        .preferredColorScheme(.dark)
        .environment(\.dynamicTypeSize, .accessibility1)
}
