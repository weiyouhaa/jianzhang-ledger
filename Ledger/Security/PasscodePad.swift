import SwiftUI
import UIKit

/// 数字密码键盘 + 圆点指示
struct PasscodePad: View {
    let title: String
    var subtitle: String? = nil
    let length: Int
    var message: String? = nil
    var disabled: Bool = false
    var biometricIcon: String? = nil
    var onBiometric: (() -> Void)? = nil
    /// 输入满 length 位时回调；返回 false 表示错误（抖动并清空）
    let onComplete: (String) -> Bool

    @State private var input = ""
    @State private var shakes: CGFloat = 0

    private let keys: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["bio", "0", "del"]]

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }

            HStack(spacing: 18) {
                ForEach(0..<length, id: \.self) { i in
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.6), lineWidth: 1.5)
                        .background(Circle().fill(i < input.count ? Color.primary : Color.clear))
                        .frame(width: 14, height: 14)
                }
            }
            .modifier(ShakeEffect(animatableData: shakes))

            Text(message ?? " ")
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(height: 18)

            VStack(spacing: 16) {
                ForEach(keys, id: \.self) { row in
                    HStack(spacing: 28) {
                        ForEach(row, id: \.self) { key in
                            keyView(key)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .onChange(of: length) { _, _ in input = "" }
    }

    @ViewBuilder
    private func keyView(_ key: String) -> some View {
        switch key {
        case "bio":
            if let biometricIcon, let onBiometric {
                Button(action: onBiometric) {
                    Image(systemName: biometricIcon).font(.title)
                        .frame(width: 76, height: 76)
                }
                .buttonStyle(.plain)
                .disabled(disabled)
            } else {
                Color.clear.frame(width: 76, height: 76)
            }
        case "del":
            Button {
                if !input.isEmpty { input.removeLast() }
            } label: {
                Image(systemName: "delete.left").font(.title2)
                    .frame(width: 76, height: 76)
            }
            .buttonStyle(.plain)
            .disabled(input.isEmpty)
        default:
            Button { tap(key) } label: {
                Text(key)
                    .font(.system(size: 32, weight: .regular, design: .rounded))
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(PadButtonStyle())
            .disabled(disabled)
        }
    }

    private func tap(_ digit: String) {
        guard input.count < length else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        input.append(digit)
        if input.count == length {
            let code = input
            // 稍等一下让最后一个圆点显示出来
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                let ok = onComplete(code)
                input = ""
                if !ok {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    withAnimation(.linear(duration: 0.4)) { shakes += 1 }
                }
            }
        }
    }
}

private struct PadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}
