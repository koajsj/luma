import SwiftUI
import SwiftData

struct AuthenticationView: View {
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    @State private var viewModel = AuthenticationViewModel()

    private var isRegistering: Bool { security.phase == .registration }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("UserID", text: $viewModel.userID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    if isRegistering { TextField("昵称", text: $viewModel.nickname).textContentType(.nickname) }
                    SecureField("密码", text: $viewModel.password).textContentType(isRegistering ? .newPassword : .password)
                    if isRegistering { SecureField("确认密码", text: $viewModel.confirmation).textContentType(.newPassword) }
                } footer: {
                    if isRegistering { Text("UserID 创建后不可修改，仅在本设备保证唯一。密码至少 8 位。") }
                }
                Section {
                    Button(isRegistering ? "创建本地账号" : "登录") { viewModel.submit(isRegistering: isRegistering, security: security, context: context) }
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                        .disabled(viewModel.userID.isEmpty || viewModel.password.isEmpty)
                    Button(isRegistering ? "已有账号？登录" : "创建本地账号") {
                        viewModel.errorMessage = nil
                        if isRegistering { security.showLogin() } else { security.showRegistration() }
                    }
                    .frame(maxWidth: .infinity)
                }
                Section { Text("此处创建本机账号，密码不会发送到服务器。在线服务需在设置中另行登记设备。") }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(isRegistering ? "创建 Luma 账号" : "欢迎回来")
            .alert("无法继续", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button("好", role: .cancel) { viewModel.errorMessage = nil }
            } message: { Text(viewModel.errorMessage ?? "") }
        }
    }

}

struct PINView: View {
    @Environment(SecurityManager.self) private var security
    @Environment(\.modelContext) private var context
    var isSetup: Bool
    var faceIDEnabled = false
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("6 位数字 PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    if isSetup {
                        SecureField("确认 PIN", text: $confirmation)
                            .keyboardType(.numberPad)
                    }
                } footer: { Text(isSetup ? "PIN 验证值保存在本机钥匙串。" : "使用本机 PIN 快速解锁。") }
                Section {
                    Button(isSetup ? "设置 PIN" : "解锁") { submit() }
                        .frame(maxWidth: .infinity)
                        .disabled(pin.count != 6)
                    if !isSetup && faceIDEnabled {
                        Button { Task { await unlockWithFaceID() } } label: {
                            Label("使用 Face ID", systemImage: "faceid")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    if !isSetup {
                        Button("使用账号密码登录") { security.showLogin() }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(isSetup ? "设置 PIN" : "解锁 Luma")
            .alert("无法解锁", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func submit() {
        do {
            if isSetup {
                guard pin == confirmation else { errorMessage = "两次输入的 PIN 不一致"; return }
                try security.setPIN(pin, context: context)
            } else { try security.verifyPIN(pin, context: context) }
            pin = ""; confirmation = ""
        } catch { pin = ""; errorMessage = error.localizedDescription }
    }

    private func unlockWithFaceID() async {
        do { try await security.unlockWithBiometrics(context: context) }
        catch { errorMessage = error.localizedDescription }
    }
}
