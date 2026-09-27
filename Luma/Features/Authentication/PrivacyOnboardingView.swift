import SwiftUI
import UIKit

struct PrivacyOnboardingView: View {
    let onContinue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 60)

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 54, weight: .regular))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                    .padding(.bottom, 34)

                Text("Luma，极度重视您的隐私安全。")
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 18)

                VStack(alignment: .leading, spacing: 22) {
                    Text("服务器位于欧盟及美国，受欧盟及美国隐私保护法规约束。")
                    Text("服务器全盘存储及数据传输链路均采用 AES-256 加密技术保护。")
                    Text("通过端到端加密机制，您的数据仅可由授权设备进行解密访问。即使是 Luma，也无法获取您的解密密钥或读取受保护的数据内容。")
                    Text("Luma 承诺，绝不会向任何第三方提供您的解密密钥及用户数据。")
                }
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 48)

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onContinue()
                } label: {
                    Text("继续使用 Luma")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("privacyOnboardingContinue")
                .padding(.bottom, 24)
            }
            .frame(maxWidth: 520, minHeight: 650, alignment: .topLeading)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear {
            if reduceMotion { appeared = true }
            else { withAnimation(.easeOut(duration: 0.45)) { appeared = true } }
        }
    }

}

#Preview {
    PrivacyOnboardingView(onContinue: {})
}
