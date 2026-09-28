import Foundation
import SwiftData

enum LocalDataError: LocalizedError {
    case duplicateUserID, invalidUserID, selfFriend, friendAlreadyExists, friendNotFound
    var errorDescription: String? {
        switch self {
        case .duplicateUserID: "此 UserID 已在本设备使用"
        case .invalidUserID: "UserID 需为 3–24 位英文字母、数字或下划线"
        case .selfFriend: "不能添加自己为好友"
        case .friendAlreadyExists: "好友已存在"
        case .friendNotFound: "本设备未找到此用户"
        }
    }
}

@MainActor
struct LocalRepository {
    let context: ModelContext

    static func normalizedUserID(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (3...24).contains(value.count), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw LocalDataError.invalidUserID
        }
        return value
    }

    static func userIDHMAC(_ normalizedID: String) throws -> String {
        try UserIDIndex().digest(normalizedID)
    }

    func user(_ userID: String) throws -> User? {
        let id = try Self.normalizedUserID(userID)
        let hash = try Self.userIDHMAC(id)
        if let match = try context.fetch(FetchDescriptor<User>(predicate: #Predicate { $0.userIDHMAC == hash })).first {
            return match
        }
        // Legacy records still carry the canonical ID until unlock migration.
        return try context.fetch(FetchDescriptor<User>(predicate: #Predicate { $0.userID == id })).first
    }

    func createUser(userID: String, nickname: String, passwordHash: String, persist: Bool = false) throws -> User {
        let id = try Self.normalizedUserID(userID)
        guard try user(id) == nil else { throw LocalDataError.duplicateUserID }
        let user = User(userID: id, nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? id : nickname.trimmingCharacters(in: .whitespacesAndNewlines), passwordHash: passwordHash)
        user.userIDHMAC = try Self.userIDHMAC(id)
        context.insert(user)
        if persist { try context.save() }
        return user
    }

    func addFriend(owner: User, userID: String, nickname: String, encryption: EncryptionService) throws -> Friend {
        let id = try Self.normalizedUserID(userID)
        guard id != owner.userID else { throw LocalDataError.selfFriend }
        let ownerID = owner.id
        let matches = try context.fetch(FetchDescriptor<Friend>(predicate: #Predicate { $0.ownerID == ownerID && $0.userID == id }))
        guard matches.isEmpty else { throw LocalDataError.friendAlreadyExists }
        let trimmedName = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let friend = Friend(ownerID: owner.id, userID: id, nickname: trimmedName.isEmpty ? id : trimmedName)
        context.insert(friend)
        context.insert(Conversation(ownerID: owner.id, friendID: friend.id))
        context.insert(UserPresence(friendID: friend.id))
        try PrivateMetadataStore(context: context, encryption: encryption).saveProfile(
            FriendPrivateProfile(nickname: friend.nickname, avatar: nil, remark: "", privateNote: nil,
                                 privacyRestricted: false), for: friend, persist: false)
        try context.save()
        return friend
    }

    func conversation(ownerID: UUID, friendID: UUID) throws -> Conversation? {
        try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.ownerID == ownerID && $0.friendID == friendID })).first
    }

    func delete(_ message: Message, forEveryone: Bool) throws {
        message.deleted = true
        message.deletedForEveryone = forEveryone
        try context.save()
    }
}
