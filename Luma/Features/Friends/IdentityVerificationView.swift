import CoreImage.CIFilterBuiltins
import PhotosUI
import SwiftData
import SwiftUI
import Vision

struct IdentityVerificationView: View {
    let user: User
    let friend: Friend
    @Environment(\.modelContext) private var context
    @Environment(SecurityManager.self) private var security
    @State private var fingerprint: String?
    @State private var safetyCode: String?
    @State private var comparison = ""
    @State private var scannedPhoto: PhotosPickerItem?
    @State private var verifiedOutOfBand = false
    @State private var showingSafetyCode = false
    @State private var errorMessage: String?
    @State private var loading = false

    private var viewModel: ChatViewModel { ChatViewModel(context: context, security: security) }

    var body: some View {
        Form {
            Section("安全状态") {
                LabeledContent("UserID", value: friend.userID)
                if friend.sessionStatus == "identityKeyChanged" {
                    Label("需要重新验证", systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                    Text("好友身份已变化，旧会话已暂停。请通过独立渠道重新核对。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if friend.identityFingerprint != nil {
                    Label("身份已记录", systemImage: "checkmark.shield")
                        .foregroundStyle(.secondary)
                    Text("请通过独立可信渠道核对安全码；已记录的指纹不代表完成了人工验证。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Label("需要验证", systemImage: "shield.lefthalf.filled")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button("查看安全码") { showingSafetyCode = true }
                    .disabled(safetyCode == nil)
                PhotosPicker(selection: $scannedPhoto, matching: .images) {
                    Label("扫描照片中的二维码", systemImage: "qrcode.viewfinder")
                }
                .disabled(safetyCode == nil)
                if loading { ProgressView("读取安全信息…") }
                else if safetyCode == nil { Button("重新读取安全码") { Task { await load() } } }
            } header: {
                Text("核对身份")
            } footer: {
                Text("请与好友当面或通过独立可信渠道核对。")
            }
            if showingSafetyCode {
                Section("双方安全码") {
                    if let safetyCode {
                    Text(IdentitySafetyCode.grouped(safetyCode))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel("双方安全码 \(IdentitySafetyCode.grouped(safetyCode))")
                    if let image = qrImage(for: safetyCode) {
                        HStack { Spacer(); Image(uiImage: image).interpolation(.none)
                            .resizable().scaledToFit().frame(width: 220, height: 220)
                            .accessibilityLabel("双方安全码二维码"); Spacer() }
                    }
                    Text("请与对方当面或经独立可信渠道比较双方屏幕上的安全码。二维码只编码这串安全码。")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("输入对方提供的安全码", text: $comparison)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    if verifiedOutOfBand {
                        Button("确认身份并启用在线会话") {
                            do {
                                try viewModel.trustOnlineIdentity(fingerprint ?? "", user: user, friend: friend)
                                verifiedOutOfBand = false
                            } catch { errorMessage = LumaError.message(for: error) }
                        }
                    } else {
                        Button("比较安全码") {
                            guard IdentitySafetyCode.matches(comparison, code: safetyCode) else {
                                errorMessage = "安全码不一致，请停止发送并通过独立渠道核对身份。"
                                return
                            }
                            verifiedOutOfBand = true
                        }.disabled(comparison.isEmpty)
                    }
                    }
                }
            }
            Section {
                Text("通过服务器之外的渠道核对，可帮助发现好友身份变化。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("安全验证")
        .task { await load() }
        .onChange(of: scannedPhoto) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let bytes = try await item.loadTransferable(type: Data.self),
                          let code = safetyCode else { throw V4AttachmentError.invalidDescriptor }
                    guard try matchesQRCode(bytes, code: code) else {
                        throw V4ProtocolError.untrustedIdentity
                    }
                    verifiedOutOfBand = true
                    showingSafetyCode = true
                } catch { errorMessage = "二维码不匹配或无法识别，请停止发送并重新核对。" }
            }
        }
        .alert("安全验证", isPresented: Binding(get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })) {
                Button("确认", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await viewModel.identityVerification(user: user, friend: friend)
            fingerprint = result.fingerprint
            safetyCode = result.safetyCode
            verifiedOutOfBand = false
        } catch { errorMessage = LumaError.message(for: error) }
    }

    private func matchesQRCode(_ bytes: Data, code: String) throws -> Bool {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(data: bytes).perform([request])
        let observations = request.results ?? []
        let payload = observations.first { $0.symbology == .qr }?.payloadStringValue
        return payload == IdentitySafetyCode.qrPayload(code)
    }

    private func qrImage(for code: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(IdentitySafetyCode.qrPayload(code).utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
