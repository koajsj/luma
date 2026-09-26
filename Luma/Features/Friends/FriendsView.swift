import SwiftData
import SwiftUI

struct FriendsView: View {
    let user: User
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @Query private var allFriends: [Friend]
    @State private var showingAdd = false
    @State private var selectedFriend: Friend?

    private var friends: [Friend] { allFriends.filter { $0.ownerID == user.id }.sorted { security.friendDisplayName($0, context: context).localizedStandardCompare(security.friendDisplayName($1, context: context)) == .orderedAscending } }

    var body: some View {
        NavigationStack {
            List {
                if friends.isEmpty {
                    ContentUnavailableView("还没有好友", systemImage: "person.2", description: Text("可以搜索本机账号，或添加用于聊天框架的本地联系人。"))
                } else {
                    ForEach(friends) { friend in
                        NavigationLink {
                            ChatDetailView(user: user, friend: friend)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: security.friendDisplayName(friend, context: context), imageData: friend.avatar)
                                VStack(alignment: .leading) {
                                    Text(security.friendDisplayName(friend, context: context)).font(.headline)
                                    Text("@\(friend.userID)").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions { Button { selectedFriend = friend } label: { Label("资料", systemImage: "person.crop.circle") } }
                    }
                }
            }
            .navigationTitle("好友")
            .toolbar { Button { showingAdd = true } label: { Label("添加好友", systemImage: "person.badge.plus") } }
            .sheet(isPresented: $showingAdd) { AddFriendView(user: user) }
            .sheet(item: $selectedFriend) { friend in NavigationStack { FriendProfileView(friend: friend) } }
        }
    }
}

struct AddFriendView: View {
    let user: User
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
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
                        Label("找到本机账号：\(foundUser.nickname)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("添加 \(foundUser.nickname)") { add(id: foundUser.userID, name: foundUser.nickname) }
                    } else if !searchID.isEmpty {
                        Text("本机没有可搜索的匹配账号。")
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
            try viewModel.addLocalContact(owner: user, userID: id, nickname: name)
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
                    .font(.headline).foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(.blue.gradient)
            }
        }
        .frame(width: size, height: size).clipShape(Circle()).accessibilityLabel(name)
    }
}
