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

                VStack(alignment: .leading, spacing: 26) {
                    statement("Luma极度重视您的隐私安全。", symbol: "lock.shield.fill", prominent: true)
                    statement("服务器位于欧盟及美国，受欧盟及美国隐私法保护。", symbol: "globe.europe.africa.fill")
                    statement("服务器及数据传输链路均受AES-256加密算法保护。", symbol: "lock.fill")
                    statement("即使是Luma也无法解密您的数据。", symbol: "shield.lefthalf.filled")
                    statement("Luma承诺绝不会向任何第三方提供解密金钥及用户数据。", symbol: "person.2.fill")
                }

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

    private func statement(_ value: String, symbol: String, prominent: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            Text(value)
                .font(prominent ? .title.bold() : .body)
                .foregroundStyle(prominent ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

}

#Preview {
    PrivacyOnboardingView(onContinue: {})
}
