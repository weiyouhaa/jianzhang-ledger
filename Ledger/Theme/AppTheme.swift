import SwiftUI
import UIKit

/// 外观皮肤（3.0）：「默认」保留现有青绿风格；「小票」为 Receipt Atlas 暖纸 + 打字机 + 虚线 + 暗红。
/// 存在 UserDefaults.standard（设备级），真实 / 防窥共用，不会暴露当前模式。
enum AppSkin: String, CaseIterable, Identifiable {
    case `default` = "default"
    case receipt = "receipt"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .default: return "默认"
        case .receipt: return "小票"
        }
    }

    var detail: String {
        switch self {
        case .default: return "青绿渐变卡片，圆角系统风格"
        case .receipt: return "暖白纸色 · 打字机字体 · 虚线分隔 · 暗红点缀"
        }
    }

    static func stored(_ raw: String) -> AppSkin { AppSkin(rawValue: raw) ?? .default }
}

struct AppTheme: Equatable {
    let skin: AppSkin
    let scheme: ColorScheme

    var isReceipt: Bool { skin == .receipt }

    // MARK: 色板
    let accent: Color
    let income: Color
    let ink: Color
    let faint: Color
    let rule: Color
    let paper: Color
    let backdrop: Color
    /// 汇总 / 净资产大卡片：默认是渐变，小票是单色纸面
    let heroFill: [Color]
    let heroInk: Color
    let heroFaint: Color
    let cardFill: Color
    let cardCorner: CGFloat
    let usesDashedRules: Bool
    let usesTypewriter: Bool

    static func resolve(skin: AppSkin, scheme: ColorScheme) -> AppTheme {
        switch skin {
        case .default:
            let accent = scheme == .dark ? Color(hex: "#3FC780") : Color(hex: "#219F66")
            return AppTheme(
                skin: .default, scheme: scheme,
                accent: accent,
                income: .green,
                ink: Color.primary,
                faint: Color.secondary,
                rule: Color.primary.opacity(0.12),
                paper: Color(.secondarySystemGroupedBackground),
                backdrop: Color(.systemGroupedBackground),
                heroFill: [Color(hex: "#1FA67A"), Color(hex: "#1673A8")],
                heroInk: .white,
                heroFaint: Color.white.opacity(0.8),
                cardFill: Color(.secondarySystemGroupedBackground),
                cardCorner: 20,
                usesDashedRules: false,
                usesTypewriter: false
            )
        case .receipt:
            if scheme == .dark {
                return AppTheme(
                    skin: .receipt, scheme: .dark,
                    accent: Color(hex: "#E58A7C"),
                    income: Color(hex: "#8CC9A0"),
                    ink: Color(hex: "#EFE7DA"),
                    faint: Color(hex: "#A79E90"),
                    rule: Color(hex: "#5A5248"),
                    paper: Color(hex: "#2B2722"),
                    backdrop: Color(hex: "#1C1A17"),
                    heroFill: [Color(hex: "#2B2722")],
                    heroInk: Color(hex: "#EFE7DA"),
                    heroFaint: Color(hex: "#A79E90"),
                    cardFill: Color(hex: "#2B2722"),
                    cardCorner: 4,
                    usesDashedRules: true,
                    usesTypewriter: true
                )
            }
            return AppTheme(
                skin: .receipt, scheme: .light,
                accent: Color(hex: "#9E2B25"),
                income: Color(hex: "#2F7D4F"),
                ink: Color(hex: "#26221E"),
                faint: Color(hex: "#857C70"),
                rule: Color(hex: "#CFC6B6"),
                paper: Color(hex: "#FBF7EE"),
                backdrop: Color(hex: "#EDE7DB"),
                heroFill: [Color(hex: "#FBF7EE")],
                heroInk: Color(hex: "#26221E"),
                heroFaint: Color(hex: "#857C70"),
                cardFill: Color(hex: "#FBF7EE"),
                cardCorner: 4,
                usesDashedRules: true,
                usesTypewriter: true
            )
        }
    }

    // MARK: 字体（3.2 (23)：小票皮肤用打包的 Special Elite / Courier Prime，中文回落宋体）

    func title(_ style: Font.TextStyle = .headline, weight: Font.Weight = .bold) -> Font {
        if usesTypewriter {
            return ReceiptTypeface.scaled(ReceiptTypeface.name(for: style, weight: weight), pointSize(style), relativeTo: style)
        }
        return .system(style, design: .default).weight(weight)
    }

    func amount(_ style: Font.TextStyle = .title, weight: Font.Weight = .bold) -> Font {
        if usesTypewriter {
            return ReceiptTypeface.scaled(ReceiptTypeface.monoBold, pointSize(style), relativeTo: style)
        }
        return .system(style, design: .rounded).weight(weight)
    }

    func amountSize(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        if usesTypewriter {
            return ReceiptTypeface.scaled(ReceiptTypeface.monoBold, size, relativeTo: .largeTitle)
        }
        return .system(size: size, weight: weight, design: .rounded)
    }

    func mono(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        if usesTypewriter {
            let bold = weight == .semibold || weight == .bold || weight == .heavy || weight == .black
            return ReceiptTypeface.scaled(bold ? ReceiptTypeface.monoBold : ReceiptTypeface.mono, pointSize(style), relativeTo: style)
        }
        return .system(style, design: .monospaced).weight(weight)
    }

    /// 大标题（做旧打字机 Special Elite）；默认皮肤同 title
    func display(_ style: Font.TextStyle = .title2) -> Font {
        if usesTypewriter {
            return ReceiptTypeface.scaled(ReceiptTypeface.display, pointSize(style), relativeTo: style)
        }
        return .system(style, design: .default).weight(.bold)
    }

    func body(_ style: Font.TextStyle = .body) -> Font {
        usesTypewriter ? mono(style) : .system(style)
    }

    private func pointSize(_ style: Font.TextStyle) -> CGFloat { ReceiptTypeface.baseSize(style) }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.resolve(skin: .default, scheme: .light)
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

// MARK: - 修饰器

struct ThemedScreenBackground: ViewModifier {
    @Environment(\.appTheme) private var theme
    func body(content: Content) -> some View {
        if theme.isReceipt {
            content
                .scrollContentBackground(.hidden)
                .background(theme.backdrop.ignoresSafeArea())
                .modifier(ThemedChrome())
        } else {
            content
        }
    }
}

struct ThemedCardBackground: ViewModifier {
    @Environment(\.appTheme) private var theme
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: theme.cardCorner, style: theme.isReceipt ? .circular : .continuous)
                    .fill(theme.cardFill)
            )
            .overlay {
                if theme.usesDashedRules {
                    RoundedRectangle(cornerRadius: theme.cardCorner, style: .circular)
                        .strokeBorder(theme.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
    }
}

struct ThemedDashedRule: View {
    @Environment(\.appTheme) private var theme
    var body: some View {
        if theme.usesDashedRules {
            DashedRule(color: theme.rule)
        } else {
            Divider()
        }
    }
}

extension View {
    func themedScreenBackground() -> some View { modifier(ThemedScreenBackground()) }
    func themedCard(padding: CGFloat = 16) -> some View { modifier(ThemedCardBackground(padding: padding)) }
}

// MARK: - 设置页实时预览（合成数据）

struct SkinLivePreview: View {
    let skin: AppSkin
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = AppTheme.resolve(skin: skin, scheme: scheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(skin == .receipt ? "RECEIPT" : "简账")
                    .font(theme.title(.caption, weight: .bold))
                    .foregroundStyle(theme.faint)
                    .tracking(skin == .receipt ? 2 : 0)
                Spacer()
                Text("示例")
                    .font(theme.mono(.caption2))
                    .foregroundStyle(theme.faint)
            }
            ThemedDashedRule().environment(\.appTheme, theme)
            Text("示例咖啡店")
                .font(theme.title(.headline))
                .foregroundStyle(theme.ink)
            HStack(alignment: .firstTextBaseline) {
                Text("支出")
                    .font(theme.mono(.caption))
                    .foregroundStyle(theme.faint)
                Spacer()
                Text("-¥28.00")
                    .font(theme.amountSize(26))
                    .foregroundStyle(theme.ink)
            }
            ThemedDashedRule().environment(\.appTheme, theme)
            HStack {
                Text("分类")
                    .font(theme.mono(.caption))
                    .foregroundStyle(theme.faint)
                Spacer()
                Text("餐饮")
                    .font(theme.mono(.caption))
                    .foregroundStyle(theme.ink)
            }
            HStack {
                Text("账户")
                    .font(theme.mono(.caption))
                    .foregroundStyle(theme.faint)
                Spacer()
                Text("示例银行卡")
                    .font(theme.mono(.caption))
                    .foregroundStyle(theme.ink)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: theme.cardCorner, style: theme.isReceipt ? .circular : .continuous)
                .fill(theme.paper)
        )
        .overlay {
            if theme.usesDashedRules {
                RoundedRectangle(cornerRadius: theme.cardCorner)
                    .strokeBorder(theme.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .environment(\.appTheme, theme)
        .tint(theme.accent)
    }
}

#if DEBUG
struct SkinLivePreview_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            SkinLivePreview(skin: .default)
            SkinLivePreview(skin: .receipt)
        }
        .padding()
        .background(Color(hex: "#EDE7DB"))
        .previewLayout(.sizeThatFits)
    }
}
#endif
