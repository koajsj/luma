import Foundation
import Observation
import SwiftData

@MainActor @Observable
final class AuthenticationViewModel {
    var userID = ""
    var nickname = ""
    var password = ""
    var confirmation = ""
    var errorMessage: String?

    func submit(isRegistering: Bool, security: SecurityManager, context: ModelContext) {
        do {
            if isRegistering {
                guard password.count >= 8 else { errorMessage = "密码至少需要 8 位"; return }
                guard password == confirmation else { errorMessage = "两次输入的密码不一致"; return }
                try security.register(userID: userID, nickname: nickname, password: password, context: context)
            } else {
                try security.login(userID: userID, password: password, context: context)
            }
            password = ""
            confirmation = ""
            errorMessage = nil
        } catch { errorMessage = LumaError.message(for: error) }
    }
}
