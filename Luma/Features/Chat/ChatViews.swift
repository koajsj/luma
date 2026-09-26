import SwiftData
import SwiftUI
import UIKit

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
    private var viewModel: ChatViewModel { ChatViewModel(context: context, security: security) }

    var body: some View {
        NavigationStack {
            List {
                if friends.isEmpty {
                    ContentUnavailableView("开始聊天", systemImage: "message", description: Text("添加本地联系人后即可试用聊天界面。"))
                } else {
                    ForEach(sortedFriends) { friend in
                        NavigationLink {
                            ChatDetailView(user: user, friend: friend)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: security.friendDisplayName(friend, context: context), imageData: friend.avatar)
                                    .overlay(alignment: .bottomTrailing) {
                                        if presences.first(where: { $0.friendID == friend.id })?.onlineStatus == .online {
                                            Circle().fill(.green).frame(width: 11, height: 11).overlay(Circle().stroke(.background, lineWidth: 2))
                                                .accessibilityLabel("在线 · 本地模拟")
                                        }
                                    }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(security.friendDisplayName(friend, context: context)).font(.headline)
                                    Text(preview(for: friend)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if let count = allConversations.first(where: { $0.ownerID == user.id && $0.friendID == friend.id })?.unreadCount,
                                   count > 0 {
                                    Text("\(count)").font(.caption.bold()).foregroundStyle(.white)
                                        .padding(.horizontal, 7).padding(.vertical, 3).background(.blue, in: Capsule())
                                        .accessibilityLabel("\(count) 条未读")
                                }
                                if allConversations.first(where: { $0.ownerID == user.id && $0.friendID == friend.id })?.isPinned == true {
                                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                                }
                                if let date = lastMessage(for: friend)?.timestamp {
                                    Text(date, style: .time).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if let conversation = allConversations.first(where: { $0.ownerID == user.id && $0.friendID == friend.id }) {
                                Button(conversation.isPinned == true ? "取消置顶" : "置顶") {
                                    do { try viewModel.setPinned(conversation.isPinned != true, for: conversation) }
                                    catch { errorMessage = error.localizedDescription }
                                }.tint(.orange)
                                Button("标记未读") {
                                    do { try viewModel.markUnread(conversation) }
                                    catch { errorMessage = error.localizedDescription }
                                }.tint(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("聊天")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingSearch = true } label: { Label("搜索", systemImage: "magnifyingglass") }
                    Button { showingFavorites = true } label: { Label("收藏", systemImage: "star") }
                    Button { showingAdd = true } label: { Label("新聊天", systemImage: "square.and.pencil") }
                }
            }
            .sheet(isPresented: $showingAdd) { AddFriendView(user: user) }
            .sheet(isPresented: $showingSearch) { NavigationStack { LocalSearchView(user: user) } }
            .sheet(isPresented: $showingFavorites) { NavigationStack { FavoriteMessagesView(user: user) } }
            .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func lastMessage(for friend: Friend) -> Message? {
        guard let conversation = allConversations.first(where: { $0.ownerID == user.id && $0.friendID == friend.id }) else { return nil }
        return allMessages.first { $0.conversationID == conversation.id && !$0.deleted }
    }

    private func preview(for friend: Friend) -> String {
        guard let conversation = allConversations.first(where: { $0.ownerID == user.id && $0.friendID == friend.id }) else { return "暂无消息" }
        if conversation.requiresUnlock == true || conversation.requiresPrivacyShield == true || (security.preferences.privacyModeEnabled && security.preferences.privacyModeLockChats) { return "已锁定的聊天" }
        if !security.preferences.effectiveMessagePreviews { return "消息预览已关闭" }
        if conversation.draft != nil { return "草稿：已保存" }
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
    @Query private var conversations: [Conversation]
    @Query private var allFriends: [Friend]
    @Query private var presences: [UserPresence]
    @Query(sort: \Message.timestamp) private var allMessages: [Message]
    @Query private var allReactions: [Reaction]
    @State private var draft = ""
    @State private var replyTo: Message?
    @State private var deleting: Message?
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
    @State private var identityCandidate: String?
    @Environment(\.scenePhase) private var scenePhase

    private var viewModel: ChatViewModel { ChatViewModel(context: context, security: security) }

    private var conversation: Conversation? { conversations.first { $0.ownerID == user.id && $0.friendID == friend.id } }
    private var messages: [Message] {
        guard let conversation else { return [] }
        return allMessages.filter { $0.conversationID == conversation.id && !$0.deleted }
    }
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
                HStack(spacing: 8) {
                    AvatarView(name: security.friendDisplayName(friend, context: context), imageData: friend.avatar, size: 30)
                    VStack(alignment: .leading) {
                        Text(security.friendDisplayName(friend, context: context)).font(.headline).lineLimit(1)
                        if typingStatus == .typing && canViewChat { Text("\(security.friendDisplayName(friend, context: context)) 正在输入…（本地演示）").font(.caption2).foregroundStyle(.secondary) }
                        else if presence?.onlineStatus == .online { Text("● 在线 · 本地模拟").font(.caption2).foregroundStyle(.green) }
                        else if presence?.onlineStatus == .offline, let lastSeen = presence?.lastSeenAt { Text("最后在线 \(lastSeen, style: .relative) · 本地模拟").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
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
                            Button { verifyOnlineIdentity() } label: {
                                Label("核对好友身份指纹", systemImage: "person.crop.circle.badge.checkmark")
                            }
                            Button { Task { await syncOnline() } } label: {
                                Label("同步线上消息", systemImage: "arrow.clockwise")
                            }
                        }
                    } label: { Image(systemName: "info.circle") }
                }
            }
        }
        .sheet(isPresented: $showingActions) { AttachmentActionsView { type in
            showingActions = false
            addSimulated(type)
        } onUnavailable: { note in
            showingActions = false
            featureNote = note
        } }
        .sheet(isPresented: $showingInfo) { ChatInfoView(user: user, friend: friend, conversation: conversation,
                                                        onlineMode: onlineMode, typingStatus: $typingStatus) }
        .sheet(isPresented: $showingSecurity) { ChatSecurityView(user: user, friend: friend, onlineMode: onlineMode) }
        .sheet(item: $editing) { message in
            NavigationStack {
                Form { TextField("编辑消息", text: $editText, axis: .vertical).lineLimit(3...8) }
                    .navigationTitle("编辑消息")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = nil } }
                        ToolbarItem(placement: .confirmationAction) { Button("保存") {
                            if onlineMode && message.transportEncryptionVersion == 3, let conversation {
                                Task {
                                    do { try await viewModel.editOnlineText(editText, message: message, user: user,
                                        friend: friend, conversation: conversation); editing = nil }
                                    catch { featureNote = error.localizedDescription }
                                }
                            } else {
                                do { try viewModel.edit(message, text: editText); editing = nil }
                                catch { featureNote = error.localizedDescription }
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
                                catch { featureNote = error.localizedDescription }
                            }
                        }
                    }
                }
                .navigationTitle("转发到本地聊天")
                .toolbar { Button("取消") { forwarding = nil } }
            }
        }
        .confirmationDialog("删除消息", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除自己", role: .destructive) { delete(forEveryone: false) }
            if deleting?.isMine == true {
                Button(onlineMode && deleting?.transportEncryptionVersion == 3 ? "通知其他设备删除" : "删除双方（仅本地）",
                       role: .destructive) { delete(forEveryone: true) }
            }
        } message: { Text(onlineMode && deleting?.transportEncryptionVersion == 3 ?
                          "服务器将发送删除事件；已下载副本不能保证物理擦除。" : "当前仅清理此设备的数据，不会影响其他设备。") }
        .alert("提示", isPresented: Binding(get: { featureNote != nil }, set: { if !$0 { featureNote = nil } })) {
            Button("好", role: .cancel) { featureNote = nil }
        } message: { Text(featureNote ?? "") }
        .alert("核对身份指纹", isPresented: Binding(get: { identityCandidate != nil },
                                                 set: { if !$0 { identityCandidate = nil } })) {
            Button("取消", role: .cancel) { identityCandidate = nil }
            Button("已通过可信渠道核对") {
                if let identityCandidate {
                    do { try viewModel.trustOnlineIdentity(identityCandidate, user: user, friend: friend) }
                    catch { featureNote = error.localizedDescription }
                }
                identityCandidate = nil
            }
        } message: {
            Text("请与对方当面或通过可信渠道核对完整指纹。仅点击此处不能证明服务器提供的密钥真实属于对方。\n\n\(identityCandidate ?? "")")
        }
        .onAppear {
            updateVisiblePrivacyShield()
            if viewModel.onlineAvailable(for: user) && messages.contains(where: { $0.transportEncryptionVersion == 3 }) {
                onlineMode = true
            }
            loadDraftIfAllowed(); markVisibleRead()
        }
        .onDisappear { privacyShield.setVisibleConversation(nil, protected: false) }
        .onChange(of: conversation?.requiresPrivacyShield) { _, _ in
            chatUnlocked = false; draftLoaded = false; draft = ""; updateVisiblePrivacyShield()
        }
        .onChange(of: messages.count) { _, _ in markVisibleRead() }
        .task(id: ExpirationTaskID(date: nextExpiration, canView: canViewChat)) {
            guard canViewChat, let nextExpiration, let conversation else { return }
            let delay = max(0, nextExpiration.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            do { try viewModel.purgeExpired(conversation) }
            catch { featureNote = error.localizedDescription }
        }
        .onChange(of: draft) { _, value in
            guard canViewChat, draftLoaded, let conversation else { return }
            do { try viewModel.saveDraft(value, in: conversation) } catch { featureNote = error.localizedDescription }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { chatUnlocked = false; draftLoaded = false; draft = "" }
        }
        .onChange(of: conversation?.requiresUnlock) { _, _ in chatUnlocked = false; draftLoaded = false; draft = "" }
        .onChange(of: security.preferences.privacyModeEnabled) { _, _ in chatUnlocked = false; draftLoaded = false; draft = "" }
        .onChange(of: security.preferences.privacyModeLockChats) { _, _ in chatUnlocked = false; draftLoaded = false; draft = "" }
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

    private var chatUnlockView: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.bubble").font(.largeTitle)
            Text("此聊天已锁定").font(.title3.bold())
            SecureField("6 位 PIN", text: $chatPIN).keyboardType(.numberPad).textContentType(.oneTimeCode)
                .frame(maxWidth: 220).textFieldStyle(.roundedBorder)
            Button("使用 PIN 查看") {
                do { try security.verifyChatPIN(chatPIN); chatPIN = ""; chatUnlocked = true; loadDraftIfAllowed(); markVisibleRead() }
                catch { featureNote = error.localizedDescription }
            }.buttonStyle(.borderedProminent)
            if security.canUseBiometrics() {
                Button("使用 Face ID") {
                    Task { do { try await security.verifyChatBiometrics(); chatUnlocked = true; loadDraftIfAllowed(); markVisibleRead() }
                           catch { featureNote = error.localizedDescription } }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            Button { showingSecurity = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                    Text(onlineMode ? "设备间密文传输基础 · 非完整 E2EE 协议" : "本地加密保护已开启 · 端到端加密尚未启用")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)

            ScrollViewReader { proxy in ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(messages) { message in
                        MessageRow(message: message,
                                   content: viewModel.visibleContent(for: message),
                                   reactions: allReactions.filter { $0.messageID == message.id }.map(\.emoji),
                                   showReadReceipts: security.preferences.readReceipts,
                                   replyPreview: message.replyToID.map { id in messages.first(where: { $0.id == id }).map { viewModel.visibleContent(for: $0) } ?? "原消息不可用" },
                                   onReplyTap: { if let id = message.replyToID { withAnimation { proxy.scrollTo(id, anchor: .center) } } },
                                   onRetry: { Task {
                                       do { try await viewModel.retryFailedOnline(message.id, user: user) }
                                       catch { featureNote = error.localizedDescription }
                                   } })
                            .contextMenu {
                                ForEach(["👍", "❤️", "😂", "‼️"], id: \.self) { emoji in
                                    Button(emoji) {
                                        if onlineMode && message.transportEncryptionVersion == 3, let conversation {
                                            Task {
                                                do { try await viewModel.reactOnline(emoji, to: message, user: user,
                                                    friend: friend, conversation: conversation) }
                                                catch { featureNote = error.localizedDescription }
                                            }
                                        } else {
                                            do { try viewModel.react(emoji, to: message) }
                                            catch { featureNote = error.localizedDescription }
                                        }
                                    }
                                }
                                if message.type == .text && message.isMine {
                                    Button { editing = message; editText = viewModel.visibleContent(for: message) } label: { Label("编辑", systemImage: "pencil") }
                                }
                                if message.type == .text {
                                    Button {
                                        do { UIPasteboard.general.string = try viewModel.displayContent(for: message) }
                                        catch { featureNote = error.localizedDescription }
                                    } label: { Label("复制", systemImage: "doc.on.doc") }
                                }
                                Button { replyTo = message } label: { Label("回复", systemImage: "arrowshape.turn.up.left") }
                                Button { forwarding = message } label: { Label("转发", systemImage: "arrowshape.turn.up.right") }
                                Button {
                                    do { try viewModel.setFavorite(message.isFavorite != true, for: message) }
                                    catch { featureNote = error.localizedDescription }
                                } label: { Label(message.isFavorite == true ? "取消收藏" : "收藏", systemImage: message.isFavorite == true ? "star.slash" : "star") }
                                Button(role: .destructive) { deleting = message } label: { Label("删除", systemImage: "trash") }
                            }
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)

            if let replyTo {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left")
                    Text("回复：\(viewModel.visibleContent(for: replyTo))").lineLimit(1)
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
                    .lineLimit(1...5)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        catch { featureNote = error.localizedDescription }
    }

    private func sendText() {
        if onlineMode {
            guard let conversation else { featureNote = "请先建立本地聊天"; return }
            let text = draft
            sendingOnline = true
            Task {
                defer { sendingOnline = false }
                do {
                    try await viewModel.sendOnlineText(text, user: user, friend: friend, conversation: conversation)
                    if draft == text { draft = ""; replyTo = nil }
                } catch { featureNote = error.localizedDescription }
            }
            return
        }
        do {
            if try viewModel.sendText(draft, in: conversation, replyingTo: replyTo) {
                draft = ""; replyTo = nil
            }
        } catch { featureNote = error.localizedDescription }
    }

    private func verifyOnlineIdentity() {
        Task {
            do { identityCandidate = try await viewModel.onlineIdentityFingerprint(user: user, friend: friend) }
            catch { featureNote = error.localizedDescription }
        }
    }

    private func syncOnline() async {
        guard onlineMode, canViewChat else { return }
        do { _ = try await viewModel.syncOnline(user: user) }
        catch { featureNote = error.localizedDescription; onlineMode = false }
    }

    private func addSimulated(_ type: MessageType) {
        if onlineMode { featureNote = "在线附件尚未支持，未向服务器发送文件。"; return }
        do {
            try viewModel.sendPlaceholder(type, in: conversation)
        } catch { featureNote = error.localizedDescription }
    }

    private func delete(forEveryone: Bool) {
        guard let deleting else { return }
        if onlineMode && forEveryone && deleting.transportEncryptionVersion == 3 {
            Task {
                do { try await viewModel.deleteOnline(deleting, user: user) }
                catch { featureNote = error.localizedDescription }
            }
            self.deleting = nil
            return
        }
        do { try viewModel.delete(deleting, forEveryone: forEveryone) }
        catch { featureNote = error.localizedDescription }
        self.deleting = nil
    }

    private func markVisibleRead() {
        guard canViewChat, let conversation else { return }
        if onlineMode {
            Task {
                do { try await viewModel.markOnlineRead(conversation, user: user) }
                catch { featureNote = error.localizedDescription }
            }
            return
        }
        do {
            try viewModel.purgeExpired(conversation)
            try viewModel.markRead(conversation)
        } catch { featureNote = error.localizedDescription }
    }
}

private struct MessageRow: View {
    let message: Message
    let content: String
    let reactions: [String]
    let showReadReceipts: Bool
    let replyPreview: String?
    let onReplyTap: () -> Void
    let onRetry: () -> Void
    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 50) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 3) {
              VStack(alignment: .leading, spacing: 4) {
                if let origin = message.forwardedFrom { Text(origin).font(.caption2).opacity(0.7) }
                if let replyPreview {
                    Button(action: onReplyTap) { Label("回复：\(replyPreview)", systemImage: "arrowshape.turn.up.left") }
                        .font(.caption)
                        .lineLimit(1)
                        .opacity(0.75)
                }
                switch message.type {
                case .text: Text(content)
                case .image: Label(content, systemImage: "photo")
                case .file: Label(content, systemImage: "doc")
                case .voice: Label(content, systemImage: "waveform")
                }
                if message.editedAt != nil { Text("（已编辑）").font(.caption2).opacity(0.7) }
                if !reactions.isEmpty { Text(reactions.joined(separator: " ")).font(.caption) }
              }
              .font(.body)
              .padding(.horizontal, 14).padding(.vertical, 9)
              .foregroundStyle(message.isMine ? Color.white : Color.primary)
              .background(message.isMine ? Color.blue : Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 18))
              HStack(spacing: 5) {
                  if message.isMine {
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
                  } else { Text(message.timestamp, style: .time) }
              }
              .font(.caption2).foregroundStyle(.secondary)
            }
            if !message.isMine { Spacer(minLength: 50) }
        }
    }
}

private struct AttachmentActionsView: View {
    let onSimulate: (MessageType) -> Void
    let onUnavailable: (String) -> Void
    var body: some View {
        NavigationStack {
            List {
                Button { onSimulate(.image) } label: { Label("图片", systemImage: "photo") }
                Button { onSimulate(.file) } label: { Label("文件", systemImage: "doc") }
                Button { onUnavailable("相机接口将在后续阶段接入。") } label: { Label("相机", systemImage: "camera") }
                Button { onSimulate(.voice) } label: { Label("语音", systemImage: "waveform") }
                Button { onUnavailable("可在设置中开启本机阅后即焚；当前不向其他设备发送销毁指令。") } label: { Label("阅后即焚", systemImage: "flame") }
            }
            .navigationTitle("添加内容")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium])
            .safeAreaInset(edge: .bottom) { Text("图片、文件和语音当前创建本地模拟消息。").font(.caption).foregroundStyle(.secondary).padding() }
        }
    }
}

private struct ChatInfoView: View {
    let user: User
    let friend: Friend
    let conversation: Conversation?
    let onlineMode: Bool
    @Binding var typingStatus: TypingStatus
    @Environment(\.modelContext) private var context
    @Environment(SecurityManager.self) private var security
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack { Spacer(); AvatarView(name: security.friendDisplayName(friend, context: context), imageData: friend.avatar); Spacer() }
                    LabeledContent("昵称", value: friend.nickname)
                    LabeledContent("UserID", value: friend.userID)
                }
                Section("聊天") {
                    if let conversation {
                        Toggle("聊天锁", isOn: Binding(get: { conversation.requiresUnlock ?? false }, set: { conversation.requiresUnlock = $0; save() }))
                        Toggle("敏感聊天保护", isOn: Binding(get: { conversation.requiresPrivacyShield ?? false }, set: { conversation.requiresPrivacyShield = $0; save() }))
                    }
                    Toggle("演示正在输入状态", isOn: Binding(get: { typingStatus == .typing }, set: { typingStatus = $0 ? .typing : .idle }))
                    Toggle("已读回执", isOn: Binding(get: { security.preferences.readReceipts }, set: { value in
                        do { try security.updatePreferences(for: user, context: context) { $0.readReceipts = value } }
                        catch { errorMessage = error.localizedDescription }
                    }))
                }
                Section { NavigationLink("好友资料与备注") { FriendProfileView(friend: friend) } }
                Section { Text(onlineMode ?
                    "在线文字以逐设备密文信封发送；本机继续加密保存。当前不是完整端到端加密协议。" :
                    "消息内容在本机加密保存。此模式不会发送到其他设备。") }
            }
            .navigationTitle("聊天信息")
            .toolbar { Button("完成") { dismiss() } }
            .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
    private func save() { do { try context.save() } catch { errorMessage = error.localizedDescription } }
}

private struct ChatSecurityView: View {
    let user: User
    let friend: Friend
    let onlineMode: Bool
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var statusRefresh = false

    var body: some View {
        NavigationStack {
            Form {
                Section("本地保护") {
                    LabeledContent("本地加密", value: "已开启 · AES-GCM v1")
                    LabeledContent("Master Key", value: "256 位 · Keychain")
                    LabeledContent("Keychain", value: security.keychainStatus())
                    LabeledContent("身份密钥", value: security.identityKeyStatus(for: user))
                    LabeledContent("设备密钥", value: security.deviceKeyStatus(for: user, context: context))
                }
                Section("会话 · 本机模拟") {
                    LabeledContent("Session", value: security.localSessionStatus(for: user, friend: friend, context: context))
                        .id(statusRefresh)
                    if security.localSessionStatus(for: user, friend: friend, context: context) == "未建立" {
                        Button("建立本机模拟会话") {
                            do { try security.createLocalSession(for: user, friend: friend, context: context); statusRefresh.toggle() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    LabeledContent("协议", value: "v2 会话加密基础")
                    LabeledContent("端到端通信", value: onlineMode ? "v3 设备信封基础 · 未审计" : "本地模式未连接服务器")
                }
                Section {
                    Text(onlineMode ?
                        "在线文字对每个目标设备分别加密；身份指纹需要线下核对。尚无完整 Double Ratchet 或独立安全审计。" :
                        "本地聊天继续使用 v1 加密。v2 是本机模拟会话；未启用线上端到端通信。")
                }
            }
            .navigationTitle("安全详情")
            .toolbar { Button("完成") { dismiss() } }
            .alert("建立会话失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
}

private struct LocalSearchView: View {
    let user: User
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
                ContentUnavailableView("本地搜索", systemImage: "magnifyingglass", description: Text("搜索消息、文件名和好友备注。索引仅加密保存在本机。"))
            } else if isSearching {
                ProgressView("正在搜索")
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
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
        .onSubmit(of: .search) { performSearch() }
        .navigationTitle("本地搜索")
        .alert("搜索失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func friend(for result: LocalSearchResult) -> Friend? {
        if result.kind == "friend" { return friends.first { $0.id == result.sourceID && $0.ownerID == user.id } }
        guard let conversationID = result.conversationID,
              let conversation = conversations.first(where: { $0.id == conversationID && $0.ownerID == user.id }) else { return nil }
        return friends.first { $0.id == conversation.friendID }
    }

    private func performSearch() {
        isSearching = true
        defer { isSearching = false }
        do {
            results = try ChatViewModel(context: context, security: security).search(query, for: user)
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct FavoriteMessagesView: View {
    let user: User
    @Environment(\.modelContext) private var context
    @Environment(SecurityManager.self) private var security
    @Query private var friends: [Friend]
    @Query private var conversations: [Conversation]
    @Query(sort: \Message.timestamp, order: .reverse) private var messages: [Message]
    private var favorites: [Message] {
        let ids = Set(conversations.filter { $0.ownerID == user.id && $0.requiresPrivacyShield != true }.map(\.id))
        return messages.filter { ids.contains($0.conversationID) && $0.isFavorite == true && !$0.deleted }
    }
    var body: some View {
        List {
            if favorites.isEmpty { ContentUnavailableView("没有收藏消息", systemImage: "star") }
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
    let container = try! ModelContainer(for: User.self, Device.self, Friend.self, Conversation.self, Message.self, Attachment.self, UserPresence.self, Reaction.self, SearchIndexEntry.self, SessionKey.self, PreKeyMetadata.self, ChainState.self, OutgoingMessageQueueItem.self, CleanupState.self,
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
