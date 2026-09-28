import SwiftData
import SwiftUI

struct FriendsView: View {
    let user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @Query private var allFriends: [Friend]
    @Query private var presences: [UserPresence]
    @Query private var conversations: [Conversation]
    @State private var showingAdd = false
    @State private var selectedFriend: Friend?
    @State private var searchText = ""

    private var friends: [Friend] { allFriends.filter { $0.ownerID == user.id }.sorted { security.friendDisplayName($0, context: context).localizedStandardCompare(security.friendDisplayName($1, context: context)) == .orderedAscending } }
    private var visibleFriends: [Friend] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return friends }
        return friends.filter {
            security.friendDisplayName($0, context: context).localizedStandardContains(searchText) ||
                $0.userID.localizedStandardContains(searchText)
        }
    }
    private func isProtected(_ friend: Friend) -> Bool {
        guard let conversation = conversations.first(where: { $0.ownerID == user.id && $0.friendID == friend.id }) else { return false }
        return conversation.requiresUnlock == true || conversation.requiresPrivacyShield == true ||
            (security.preferences.privacyModeEnabled && security.preferences.privacyModeLockChats)
    }

    var body: some View {
        NavigationStack {
            List {
                if friends.isEmpty {
                    ContentUnavailableView {
                        Label("还没有好友", systemImage: "person.2")
                    } description: {
                        Text("添加好友，开始一段新的聊天。")
                    } actions: {
                        Button("添加好友") { showingAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if visibleFriends.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ForEach(visibleFriends) { friend in
                        NavigationLink {
                            ChatDetailView(user: user, friend: friend)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: security.friendDisplayName(friend, context: context), imageData: security.friendAvatar(friend, context: context))
                                    .overlay(alignment: .bottomTrailing) {
                                        if !isProtected(friend), presences.first(where: { $0.friendID == friend.id })?.onlineStatus == .online {
                                            Circle().fill(.green).frame(width: 11, height: 11)
                                                .overlay(Circle().stroke(.background, lineWidth: 2))
                                                .accessibilityLabel("在线 · 本地模拟")
                                        }
                                    }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(security.friendDisplayName(friend, context: context)).font(.headline).lineLimit(1)
                                    Text("@\(friend.userID)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    if !isProtected(friend), presences.first(where: { $0.friendID == friend.id })?.onlineStatus == .online {
                                        Text("在线 · 本地模拟").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .swipeActions { Button { selectedFriend = friend } label: { Label("资料", systemImage: "person.crop.circle") } }
                    }
                }
            }
            .navigationTitle("好友")
            .searchable(text: $searchText, prompt: "搜索好友")
            .toolbar { Button { showingAdd = true } label: { Label("添加好友", systemImage: "person.badge.plus") } }
            .sheet(isPresented: $showingAdd) { AddFriendView(user: user) }
            .sheet(item: $selectedFriend) { friend in
                NavigationStack {
                    FriendProfileView(friend: friend)
                        .toolbar { Button("完成") { selectedFriend = nil } }
                }
            }
        }
    }
}

struct AddFriendView: View {
    let user: User
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(SecurityManager.self) private var security
    @Query private var users: [User]
    @State private var searchID = ""
    @State private var nickname = ""
    @State private var errorMessage: String?
    @State private var showingScanner = false

    private var viewModel: FriendsViewModel { FriendsViewModel(context: context) }

    private var foundUser: User? {
        viewModel.searchableUser(for: searchID, among: users, excluding: user)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("通过 UserID 搜索") {
                    TextField("UserID", text: $searchID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let foundUser {
                        let name = (try? security.userProfile(foundUser, context: context).nickname) ?? foundUser.userID
                        HStack(spacing: 12) {
                            AvatarView(name: name, imageData: try? security.userProfile(foundUser, context: context).avatar)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name).font(.headline)
                                Text("@\(foundUser.userID)").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Button("添加好友") { add(id: foundUser.userID, name: name) }
                    } else if !searchID.isEmpty {
                        Label("未找到可搜索的本机账号", systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("显示昵称", text: $nickname)
                    Button("添加本地联系人") { add(id: searchID, name: nickname) }
                        .disabled(searchID.isEmpty)
                } header: {
                    Text("本地聊天联系人")
                } footer: {
                    Text("本地联系人仅用于本机聊天交互。UserID 未经服务器验证，也不会向对方发送好友请求。")
                }
                Section("其他方式") {
                    Button { showingScanner = true } label: { Label("扫描二维码", systemImage: "qrcode.viewfinder") }
                    ShareLink(item: "Luma 本地邀请预览：UserID @\(user.userID)。当前尚未接入邀请服务。") {
                        Label("邀请链接（预留）", systemImage: "link")
                    }
                }
            }
            .navigationTitle("添加好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .alert("无法添加", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .alert("扫码功能预留", isPresented: $showingScanner) {
                Button("好", role: .cancel) { }
            } message: { Text("接入好友服务和二维码身份验证后启用。") }
        }
    }

    private func add(id: String, name: String) {
        do {
            try viewModel.addLocalContact(owner: user, userID: id, nickname: name, security: security)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct AvatarView: View {
    let name: String
    var imageData: Data? = nil
    var size: CGFloat = 44
    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Color.accentColor)
            }
        }
        .frame(width: size, height: size).clipShape(Circle()).accessibilityLabel(name)
    }
}

struct ProfileHeaderView: View {
    let name: String
    let subtitle: String
    let imageData: Data?

    var body: some View {
        VStack(spacing: 8) {
            AvatarView(name: name, imageData: imageData, size: 80)
            Text(name).font(.title2.weight(.semibold)).lineLimit(2)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
