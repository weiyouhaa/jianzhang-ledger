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
        case .receipt: return "棉浆白/原浆暖黄 · IBM Plex Mono · 朱砂印章 · 立体纸感"
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
            // 4.1：按纸张方案（棉浆白 / 原浆暖黄）+ 明暗解析；深色统一炭票
            let dark = scheme == .dark
            let pal = ReceiptStyle.palette(paper: ReceiptPaper.current, dark: dark)
            let c = { (p: ReceiptStyle.Pair) in ReceiptStyle.color(p, dark: dark) }
            return AppTheme(
                skin: .receipt, scheme: dark ? .dark : .light,
                accent: c(pal.accent),
                income: c(pal.income),
                ink: c(pal.ink),
                faint: c(pal.faint),
                rule: c(pal.rule),
                paper: c(pal.paper),
                backdrop: c(pal.backdrop),
                heroFill: [c(pal.paper)],
                heroInk: c(pal.ink),
                heroFaint: c(pal.faint),
                cardFill: c(pal.elevated),
                cardCorner: ReceiptStyle.corner,
                usesDashedRules: true,
                usesTypewriter: true
            )
        }
    }

    /// 预算接近上限的提示色：默认皮肤 = 系统橙；小票皮肤 = 赭石
    var caution: Color {
        isReceipt ? ReceiptStyle.color(ReceiptStyle.caution, dark: scheme == .dark) : .orange
    }

    /// 预算超支 / 进度条颜色（默认皮肤保持原来的红 / 橙 / 绿）
    func budgetColor(_ ratio: Double, threshold: Double = 0.8) -> Color {
        if ratio > 1 { return isReceipt ? accent : .red }
        if ratio >= threshold { return caution }
        return isReceipt ? ink.opacity(0.72) : income
    }

    /// 3.5 (26) 小票皮肤字号档位（hero 34 / title 20 / body 16 / meta 13 / label 11）
    var heroAmountFont: Font { ReceiptTypeface.scaled(ReceiptTypeface.monoBold, ReceiptStyle.Size.hero, relativeTo: .largeTitle) }
    var sectionTitleFont: Font { ReceiptTypeface.scaled(ReceiptTypeface.display, ReceiptStyle.Size.title, relativeTo: .title3) }
    var rowTitleFont: Font { ReceiptTypeface.scaled(ReceiptTypeface.mono, ReceiptStyle.Size.body, relativeTo: .body) }
    var rowAmountFont: Font { ReceiptTypeface.scaled(ReceiptTypeface.monoBold, ReceiptStyle.Size.body, relativeTo: .body) }
    var metaFont: Font { ReceiptTypeface.scaled(ReceiptTypeface.mono, ReceiptStyle.Size.meta, relativeTo: .footnote) }

    /// 小票皮肤的小号字距标签字体
    var labelFont: Font {
        ReceiptTypeface.scaled(ReceiptTypeface.mono, ReceiptStyle.Size.label, relativeTo: .caption2)
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
        if theme.isReceipt {
            // 3.5 (26)：小票皮肤只有一种卡片——纸面 + 与分组列表一致的大圆角，无描边、无虚线框
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .receiptSurface(theme)
        } else {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: theme.cardCorner, style: .continuous)
                        .fill(theme.cardFill)
                )
        }
    }
}

extension View {
    /// 3.5 (26) 小票皮肤卡片底：普通卡片 = 纸面圆角；hero = 上圆角 + 下沿齿孔 + 极淡投影
    @ViewBuilder
    func receiptSurface(_ theme: AppTheme, hero: Bool = false) -> some View {
        // 4.1 V4：多层纸感阴影（近距 + 中距 + 远距），模拟设计稿 drop-shadow 叠层
        let dark = theme.scheme == .dark
        let near = Color.black.opacity(dark ? 0.55 : 0.10)
        let mid = Color.black.opacity(dark ? 0.35 : 0.08)
        let far = Color.black.opacity(dark ? 0.22 : 0.05)
        if hero {
            self
                .padding(.bottom, 4)
                .background(
                    PerforatedCardShape()
                        .fill(theme.paper)
                        .shadow(color: near, radius: 1.2, y: 1)
                        .shadow(color: mid, radius: 8, y: 5)
                        .shadow(color: far, radius: 18, y: 12)
                )
                .overlay(alignment: .top) {
                    // 顶部卷纸高光
                    LinearGradient(
                        colors: [
                            Color.white.opacity(dark ? 0.08 : 0.55),
                            Color.clear
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 18)
                    .clipShape(PerforatedCardShape())
                    .allowsHitTesting(false)
                }
        } else {
            self.background(
                RoundedRectangle(cornerRadius: ReceiptStyle.corner, style: .continuous)
                    .fill(theme.cardFill)
                    .shadow(color: near, radius: 1.0, y: 1)
                    .shadow(color: mid, radius: 6, y: 4)
            )
        }
    }
}

struct ThemedDashedRule: View {
    @Environment(\.appTheme) private var theme
    var body: some View {
        if theme.usesDashedRules {
            ReceiptRule(color: theme.rule)
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
                    .receiptDigits(theme.isReceipt)
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
            RoundedRectangle(cornerRadius: theme.cardCorner, style: .continuous)
                .fill(theme.paper)
        )
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

// MARK: - 3.5 (26) 表单分组标题 / 脚注

/// Form / List 分组标题。小票皮肤：小号打字机字距标签 + 柔灰（与首页卡片标签同级）；
/// 默认皮肤原样输出，不改变任何外观。
struct ThemedSectionHeader<Content: View>: View {
    @Environment(\.appTheme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        if theme.isReceipt {
            content
                .font(theme.labelFont)
                .tracking(ReceiptStyle.labelTracking)
                .foregroundStyle(theme.faint)
                .textCase(nil)
        } else {
            content
        }
    }
}

/// Form / List 分组脚注。小票皮肤：说明文字回到 13pt 柔灰（之前继承全局正文字号，过大过黑）；
/// 默认皮肤原样输出。
struct ThemedSectionFooter<Content: View>: View {
    @Environment(\.appTheme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        if theme.isReceipt {
            content
                .font(theme.metaFont)
                .foregroundStyle(theme.faint)
                .lineSpacing(2)
        } else {
            content
        }
    }
}
