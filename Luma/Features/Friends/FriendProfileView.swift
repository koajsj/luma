import SwiftData
import SwiftUI

struct FriendProfileView: View {
    @Bindable var friend: Friend
    @Environment(\.modelContext) private var context
    @Environment(SecurityManager.self) private var security
    @Environment(\.dismiss) private var dismiss
    @Query private var conversations: [Conversation]
    @Query private var allMessages: [Message]
    @Query private var attachments: [Attachment]
    @Query private var reactions: [Reaction]
    @Query private var indexes: [SearchIndexEntry]
    @Query private var sessionKeys: [SessionKey]
    @Query private var presences: [UserPresence]
    @State private var remark = ""
    @State private var editingRemark = false
    @State private var confirmingDelete = false
    @State private var errorMessage: String?

    private var presence: UserPresence? { presences.first { $0.friendID == friend.id } }

    var body: some View {
        Form {
            Section {
                HStack { Spacer(); AvatarView(name: security.friendDisplayName(friend, context: context), imageData: friend.avatar, size: 72); Spacer() }
                LabeledContent("昵称", value: friend.nickname)
                LabeledContent("UserID", value: friend.userID)
                LabeledContent("备注", value: (try? security.privateStore(context: context).remark(for: friend)).flatMap { $0.isEmpty ? nil : $0 } ?? "未设置")
                Button("修改备注") {
                    do { remark = try security.privateStore(context: context).remark(for: friend); editingRemark = true }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            Section("在线状态 · 本地模型") {
                LabeledContent("状态", value: presence?.onlineStatus == .online ? "在线（本地模拟）" :
                               presence?.onlineStatus == .offline ? "离线（本地模拟）" : "未知")
                if let date = presence?.lastSeenAt { LabeledContent("最后在线") { Text(date, style: .relative) } }
                Button(presence?.onlineStatus == .online ? "模拟离线" : "模拟在线") {
                    do { try FriendsViewModel(context: context).setMockOnline(presence?.onlineStatus != .online, for: friend) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            Section("隐私设置") {
                Toggle("限制此好友的本地资料展示", isOn: Binding(get: { friend.privacyRestricted ?? false }, set: { friend.privacyRestricted = $0; save() }))
                Text("仅保存在本机；不会通知对方或改变服务器权限。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section { Button("删除好友及本地聊天", role: .destructive) { confirmingDelete = true } }
        }
        .navigationTitle("好友资料")
        .alert("修改备注", isPresented: $editingRemark) {
            TextField("备注", text: $remark)
            Button("保存") {
                do { try security.privateStore(context: context).saveRemark(remark, for: friend) }
                catch { errorMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("备注仅自己可见。") }
        .confirmationDialog("删除好友及本机聊天记录？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) { deleteFriend() }
        } message: { Text("此操作会删除这位好友的本地会话与消息，无法撤销。") }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func save() { do { try context.save() } catch { errorMessage = error.localizedDescription } }
    private func deleteFriend() {
        Task {
            do {
                try await FriendsViewModel(context: context).removeRemoteFriendIfNeeded(friend, security: security)
                try deleteLocalFriend()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func deleteLocalFriend() throws {
        do {
            let conversationIDs = Set(conversations.filter { $0.friendID == friend.id && $0.ownerID == friend.ownerID }.map(\.id))
            let messageIDs = Set(allMessages.filter { conversationIDs.contains($0.conversationID) }.map(\.id))
            for item in try context.fetch(FetchDescriptor<OutgoingMessageQueueItem>()).filter({
                $0.ownerID == friend.ownerID && messageIDs.contains($0.messageID)
            }) { context.delete(item) }
            for conversation in conversations where conversation.friendID == friend.id {
                for message in allMessages where message.conversationID == conversation.id {
                    for attachment in attachments where attachment.messageID == message.id {
                        for index in indexes where index.sourceID == attachment.id { context.delete(index) }
                        try security.deleteLocalAttachment(attachment.id, ownerID: friend.ownerID)
                        context.delete(attachment)
                    }
                    for reaction in reactions where reaction.messageID == message.id { context.delete(reaction) }
                    for index in indexes where index.sourceID == message.id { context.delete(index) }
                    context.delete(message)
                }
                context.delete(conversation)
            }
            for index in indexes where index.sourceID == friend.id { context.delete(index) }
            let sessions = try security.sessionManager(context: context)
            for key in sessionKeys where key.friendID == friend.id {
                try sessions.deleteKeyMaterial(for: key)
                context.delete(key)
            }
            for presence in presences where presence.friendID == friend.id { context.delete(presence) }
            if let remoteUserID = friend.remoteUserID {
                for trust in try context.fetch(FetchDescriptor<RemoteDeviceTrust>()).filter({
                    $0.ownerID == friend.ownerID && $0.peerUserID == remoteUserID
                }) { context.delete(trust) }
            }
            context.delete(friend)
            try context.save()
            dismiss()
        } catch { context.rollback(); throw error }
    }
}
