import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 4.3 (57) Apple HIG 触觉反馈辅助：轻量选择、轻点与成功反馈
@MainActor
enum ReceiptHaptics {
    static func selection() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    static func lightImpact() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func success() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func warning() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}

/// 4.3 (57) Apple HIG 标准按压微交互样式：只做视觉缩放与明度过渡，不挂载任何手势识别器
struct ReceiptPressButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

// 4.0 (31) 小票皮肤设计系统 · 精致拟物小票 V3.0（Aesop / Le Labo 热敏纸质感）。
// 只依赖 SwiftUI，CI 在 macOS 上渲染预览（Tools/RenderPreview）时也会编译这个文件。
// 规则：
// - 色板：棉浆白纸 / 暖象牙墨 / 朱砂 vermilion / 森绿收入 / 琥珀警示；分类图标降饱和，不用系统高饱和色
// - 字号：5 档（hero 34 / title 20 / body 16 / meta 13 / label 11），数字等宽；中文宋体 + 拉丁打字机
// - 间距：8pt 网格（4 只用于同一组内的紧密行距）
// - 卡片：纸面 + 大圆角；锯齿 / 齿孔边用在顶部汇总卡（hero）与欠款走势卡
// - 分隔：细虚线（0.75pt，2-3 点距）；坐标纸网格仅用于走势图底
enum ReceiptStyle {
    // MARK: 间距（8pt 网格）
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    // MARK: 形状
    /// 热敏纸几乎直角，只留一点裁切圆角（设计稿 3px）
    static let corner: CGFloat = 3.5
    static let ruleWidth: CGFloat = 0.85
    static let ruleDash: [CGFloat] = [3, 3]
    /// 小号标签字距（Receipt Atlas 里的 HOME / SPENT / DATE）
    static let labelTracking: CGFloat = 1.4
    static let barHeight: CGFloat = 3
    /// iPhone 15 Pro Max (430pt 宽) 纸卷外边距：留出宽裕的桌面底衬呼吸感
    static let pageHorizontalMargin: CGFloat = 18

    // MARK: 字号（5 档）
    enum Size {
        /// 参考图大号金额（首页结余 32 / 净资产 30 / 收银台 26）
        static let hero: CGFloat = 32
        static let title: CGFloat = 20
        /// 卡片标题（支出构成 / 预算）
        static let cardTitle: CGFloat = 15
        /// 列表行标题（商户 / 今天）
        static let rowTitle: CGFloat = 15
        /// 列表行金额 / 数值
        static let rowAmount: CGFloat = 14
        /// 票面说明文字
        static let meta: CGFloat = 12
        /// 小号字距标签
        static let label: CGFloat = 10.5
        @available(*, deprecated, renamed: "rowAmount")
        static let body: CGFloat = 14
    }

    // MARK: 色板（浅色 / 深色）
    struct Pair { let light: String; let dark: String
        func hex(dark isDark: Bool) -> String { isDark ? dark : light }
    }
    // 棉浆白纸（浅）/ 黑金炭票（深）——对齐设计稿 V4 token
    static let paper = Pair(light: "#FAF7F0", dark: "#24201D")
    static let paperElevated = Pair(light: "#FFFDF9", dark: "#2D2824")
    static let backdrop = Pair(light: "#E3DAC9", dark: "#110F0D")
    static let ink = Pair(light: "#1F1B18", dark: "#EFE8DE")
    static let faint = Pair(light: "#655D55", dark: "#A3988C")
    static let muted = Pair(light: "#968C82", dark: "#6E655B")
    static let rule = Pair(light: "#D8CFC0", dark: "#37322D")
    static let ruleDashed = Pair(light: "#C2B7A4", dark: "#4A433C")
    /// 朱砂 vermilion（主强调 / 超支 / 印章）
    static let accent = Pair(light: "#A63628", dark: "#E06250")
    /// 森绿（收入）
    static let income = Pair(light: "#295A3F", dark: "#59A17A")
    /// 琥珀警示（时间未识别、接近预算上限）
    static let caution = Pair(light: "#9A5F17", dark: "#E2A450")
    /// 信用卡 STATEMENT 卡面（朱砂底上的暖象牙文字）
    static let statementFill = Pair(light: "#8F2A22", dark: "#5C241E")
    static let statementInk = Pair(light: "#FFF8F0", dark: "#F5E6D8")
    static let slot = Pair(light: "#9C9283", dark: "#050404")

    static func color(_ pair: Pair, dark: Bool) -> Color { rgbColor(rgb(pair.hex(dark: dark))) }

    // MARK: 分类 / 账户图标色：降饱和 + 统一明度 + 略带暖褐，和纸面协调
    static func mutedRGB(_ hex: String, dark: Bool) -> (Double, Double, Double) {
        let (r, g, b) = rgb(hex)
        let (h, _, s) = rgbToHLS(r, g, b)
        let (mr, mg, mb) = hlsToRGB(h, dark ? 0.70 : 0.44, s * 0.48)
        let warm: (Double, Double, Double) = dark ? (0.80, 0.74, 0.66) : (0.55, 0.47, 0.38)
        let k = 0.18
        return (mr * (1 - k) + warm.0 * k, mg * (1 - k) + warm.1 * k, mb * (1 - k) + warm.2 * k)
    }

    static func muted(_ hex: String, dark: Bool) -> Color { rgbColor(mutedRGB(hex, dark: dark)) }

    // MARK: 工具
    static func rgb(_ hex: String) -> (Double, Double, Double) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s.prefix(6), radix: 16) ?? 0x8E8E93
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    static func rgbColor(_ c: (Double, Double, Double)) -> Color {
        Color(.sRGB, red: c.0, green: c.1, blue: c.2, opacity: 1)
    }

    private static func rgbToHLS(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxc = max(r, g, b), minc = min(r, g, b)
        let l = (maxc + minc) / 2
        if maxc == minc { return (0, l, 0) }
        let d = maxc - minc
        let s = l <= 0.5 ? d / (maxc + minc) : d / (2 - maxc - minc)
        var h: Double
        if maxc == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if maxc == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h /= 6
        return (h, l, s)
    }

    private static func hlsToRGB(_ h: Double, _ l: Double, _ s: Double) -> (Double, Double, Double) {
        if s == 0 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (hue(h + 1.0 / 3), hue(h), hue(h - 1.0 / 3))
    }
}

// MARK: - 共用形状 / 组件

/// 连续纸卷的收尾：平顶 + 下沿锯齿撕口（贴在列表末尾，作为纸面的一部分）
struct ReceiptTornEdge: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        TornEdgeShape()
            .fill(theme.paper)
            .frame(height: 14)
            .accessibilityHidden(true)
    }
}

struct TornEdgeShape: Shape {
    var tooth: CGFloat = 11
    var depth: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))
        let count = max(1, Int((rect.width / tooth).rounded()))
        let w = rect.width / CGFloat(count)
        for i in 0..<count {
            let x = rect.maxX - CGFloat(i) * w
            p.addLine(to: CGPoint(x: x - w / 2, y: rect.maxY))
            p.addLine(to: CGPoint(x: x - w, y: rect.maxY - depth))
        }
        p.closeSubpath()
        return p
    }
}


/// 顶部汇总卡（hero）专用：上方圆角、下沿一排齿孔（撕下的小票），其它卡片不用
struct PerforatedCardShape: Shape {
    var corner: CGFloat = ReceiptStyle.corner
    var tooth: CGFloat = 11
    var depth: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(corner, rect.height / 3)
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY - depth))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))
        let count = max(1, Int((rect.width / tooth).rounded()))
        let w = rect.width / CGFloat(count)
        for i in 0..<count {
            let x = rect.maxX - CGFloat(i) * w
            p.addLine(to: CGPoint(x: x - w / 2, y: rect.maxY))
            p.addLine(to: CGPoint(x: x - w, y: rect.maxY - depth))
        }
        p.closeSubpath()
        return p
    }
}

/// 统一的细虚线
struct ReceiptRule: View {
    var color: Color
    var body: some View {
        RuleLine()
            .stroke(color, style: StrokeStyle(lineWidth: ReceiptStyle.ruleWidth, dash: ReceiptStyle.ruleDash))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
    private struct RuleLine: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
}

/// 点引线（标签 ········ 数值）
struct DotLeader: View {
    var color: Color
    var body: some View {
        Leader()
            .stroke(color, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [0.1, 4]))
            .frame(height: 2)
            .frame(minWidth: 12)
            .accessibilityHidden(true)
    }
    private struct Leader: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
}

/// 小号字距标签（本月结余 / 支出 / 收入 …）
struct ReceiptLabelText: View {
    let text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(ReceiptTypeface.scaled(ReceiptTypeface.mono, ReceiptStyle.Size.label, relativeTo: .caption2))
            .tracking(ReceiptStyle.labelTracking)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// 细进度条（预算 / 负债率 / 当天支出占比）：3pt 高，方头，轨道是虚线色，支持数值变化平滑过渡
struct ReceiptBar: View {
    let ratio: Double
    var fill: Color
    var track: Color
    var body: some View {
        let clamped = min(max(ratio, 0), 1)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(track)
                Rectangle().fill(fill)
                    .frame(width: max(ratio > 0 ? 2 : 0, g.size.width * clamped))
                    .animation(.spring(response: 0.38, dampingFraction: 0.84), value: clamped)
            }
        }
        .frame(height: ReceiptStyle.barHeight)
        .clipShape(RoundedRectangle(cornerRadius: 1))
        .accessibilityHidden(true)
    }
}

/// 设计稿预算细条：纸槽 + 1pt 描边 + 内嵌朱砂条（首页汇总卡），支持宽度与警示色平滑插值
struct ReceiptBudgetMeter: View {
    let ratio: Double
    var fill: Color
    @Environment(\.appTheme) private var theme

    var body: some View {
        let clamped = min(max(ratio, 0), 1)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(theme.rule.opacity(0.28))
                Rectangle().fill(fill)
                    .frame(width: max(ratio > 0 ? 3 : 0, (g.size.width - 2) * clamped))
                    .animation(.spring(response: 0.42, dampingFraction: 0.84), value: clamped)
            }
            .padding(1)
        }
        .frame(height: 6)
        .background(theme.rule.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: 1).strokeBorder(theme.rule, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

extension View {
    /// 小票皮肤的等宽数字（默认皮肤不变）
    @ViewBuilder
    func receiptDigits(_ on: Bool) -> some View {
        if on { self.monospacedDigit() } else { self }
    }
}

/// 机械出纸口：深槽压在票据上沿，带金属压纸唇高光与内部暗槽阴影
struct PrinterSlot: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        let dark = theme.scheme == .dark
        let slot = ReceiptStyle.color(
            ReceiptStyle.palette(paper: ReceiptPaper.current, dark: dark).slot,
            dark: dark
        )
        let lip = dark
            ? Color(red: 0.145, green: 0.133, blue: 0.122)
            : Color(red: 0.38, green: 0.34, blue: 0.29)
        ZStack {
            Capsule()
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.07, blue: 0.06),
                        slot,
                        lip
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(height: 11)
                .shadow(color: .black.opacity(dark ? 0.72 : 0.32), radius: 1.5, y: 1)
                .overlay(Capsule().strokeBorder(Color.white.opacity(dark ? 0.10 : 0.50), lineWidth: 0.7))
        }
        .padding(.horizontal, -4)
        .accessibilityHidden(true)
    }
}

/// 连续热敏纸中间的 3D 压痕与打孔：凹谷阴影 + 虚线裁切线 + 左右两侧真实咬破纸边的半圆孔
struct FoldCrease: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        let dark = theme.scheme == .dark
        ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(0),
                    Color.black.opacity(dark ? 0.45 : 0.08),
                    Color.white.opacity(dark ? 0.09 : 0.78),
                    Color.white.opacity(0)
                ],
                startPoint: .top, endPoint: .bottom
            )
            HStack(spacing: 0) {
                hole.offset(x: -8)
                ReceiptRule(color: theme.rule)
                    .padding(.horizontal, 4)
                hole.offset(x: 8)
            }
        }
        .frame(height: 22)
        .clipped(antialiased: false)
        .accessibilityHidden(true)
    }

    private var hole: some View {
        Circle()
            .fill(theme.backdrop)
            .frame(width: 16, height: 16)
            .overlay(
                Circle().strokeBorder(theme.rule.opacity(0.65), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(theme.scheme == .dark ? 0.50 : 0.16), radius: 1, y: 1)
    }
}

/// 朱砂倾斜印章（超支、FOLIO、已核对），带轻盈盖章落下微动画
struct VermilionStamp: View {
    let text: String
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stamped = false

    var body: some View {
        Text(text)
            .font(theme.labelFont)
            .foregroundStyle(theme.accent)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(theme.accent.opacity(theme.scheme == .dark ? 0.16 : 0.10))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(theme.accent.opacity(0.48), lineWidth: 1.4))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.accent.opacity(0.18), lineWidth: 1).padding(-1.5))
            .scaleEffect(stamped ? 1.0 : 1.12)
            .rotationEffect(.degrees(stamped ? -2.5 : -6.0))
            .opacity(stamped ? 1.0 : 0.72)
            .fixedSize(horizontal: true, vertical: true)
            .onAppear {
                guard !stamped else { return }
                if reduceMotion {
                    stamped = true
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                        stamped = true
                    }
                }
            }
    }
}

/// 小票皮肤专属：纸质拨片分段切换器（支持 matchedGeometryEffect 滑块与触觉反馈）
struct ReceiptSegmentedControl<T: Hashable>: View {
    struct Option: Identifiable {
        let value: T
        let title: String
        var id: T { value }
    }

    let options: [Option]
    @Binding var selection: T
    @Environment(\.appTheme) private var theme
    @Namespace private var thumbNamespace

    init(options: [Option], selection: Binding<T>) {
        self.options = options
        self._selection = selection
    }

    init(selection: Binding<T>, options: [(T, String)]) {
        self.options = options.map { Option(value: $0.0, title: $0.1) }
        self._selection = selection
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { opt in
                let isSelected = selection == opt.value
                Button {
                    guard selection != opt.value else { return }
                    ReceiptHaptics.selection()
                    withAnimation(.snappy(duration: 0.22, extraBounce: 0.04)) {
                        selection = opt.value
                    }
                } label: {
                    Text(opt.title)
                        .font(isSelected ? theme.serifTitleFont : theme.serifLabelFont)
                        .foregroundStyle(isSelected ? theme.accent : theme.faint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(theme.cardFill)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3)
                                            .strokeBorder(theme.rule, lineWidth: 1)
                                    )
                                    .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "segmentThumb", in: thumbNamespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(theme.rule.opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(theme.rule, lineWidth: 1)
        )
    }
}

/// 小票皮肤专属：复古汉字方印（[餐] [行] [购] [住] [入] [转]），支持选中态弹性缩放
struct ReceiptSquareStamp: View {
    let character: String
    var tint: Color? = nil
    var size: CGFloat = 34
    var highlighted: Bool = false
    @Environment(\.appTheme) private var theme

    init(character: String, tint: Color? = nil, size: CGFloat = 34, highlighted: Bool = false) {
        self.character = character
        self.tint = tint
        self.size = size
        self.highlighted = highlighted
    }

    init(char: String, size: CGFloat = 34, tint: Color? = nil, highlighted: Bool = false) {
        self.character = char
        self.size = size
        self.tint = tint
        self.highlighted = highlighted
    }

    var body: some View {
        let inkColor = tint ?? (highlighted ? theme.accent : theme.ink)
        let borderColor = tint?.opacity(0.45) ?? (highlighted ? theme.accent.opacity(0.55) : theme.rule)
        let fillColor = tint?.opacity(0.10) ?? (highlighted ? theme.accent.opacity(0.12) : theme.rule.opacity(0.26))
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(fillColor)
            Text(character)
                .font(ReceiptTypeface.scaled(ReceiptTypeface.cjkSerifBold, size * 0.42, relativeTo: .footnote))
                .foregroundStyle(inkColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(borderColor.opacity(0.35), lineWidth: 0.5)
                .padding(2)
        )
        .scaleEffect(highlighted ? 1.04 : 1.0)
        .animation(.snappy(duration: 0.18), value: highlighted)
    }

    /// 根据分类名称或 SF Symbol 自动推导一枚汉字印章字
    static func sealCharacter(name: String? = nil, icon: String = "", kindRaw: String? = nil) -> String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            if name.contains("招行") || name.contains("招商") { return "招" }
            if name.contains("工行") || name.contains("工商") { return "工" }
            if name.contains("建行") || name.contains("建设") { return "建" }
            if name.contains("农行") || name.contains("农业") { return "农" }
            if name.contains("中行") || name.contains("中国银行") { return "中" }
            if name.contains("浦发") { return "浦" }
            if name.contains("支付宝") || name.contains("花呗") { return "支" }
            if name.contains("微信") { return "微" }
            if name.contains("公积金") { return "公" }
            if name.contains("养老") { return "养" }
            if name.contains("医保") || name.contains("医疗") { return "医" }
            if name.contains("社保") { return "社" }
            if name.contains("信用卡") { return "信" }
            if name.contains("储蓄") { return "储" }
            if name.contains("现金") { return "现" }
            if name.contains("餐") || name.contains("食") || name.contains("外") || name.contains("咖啡") || name.contains("早") { return "餐" }
            if name.contains("行") || name.contains("交") || name.contains("车") || name.contains("铁") { return "行" }
            if name.contains("购") || name.contains("买") || name.contains("百货") || name.contains("日用") { return "购" }
            if name.contains("住") || name.contains("房") || name.contains("租") || name.contains("水电") || name.contains("居") { return "住" }
            if name.contains("娱") || name.contains("玩") || name.contains("影") || name.contains("游") { return "娱" }
            if name.contains("医") || name.contains("药") || name.contains("病") { return "医" }
            if name.contains("还款") { return "还" }
            if name.contains("工资") || name.contains("薪") || name.contains("奖金") { return "薪" }
            if name.contains("转账") { return "转" }
            if let first = name.first { return String(first) }
        }
        if kindRaw == "income" { return "入" }
        if kindRaw == "transfer" { return "转" }
        if kindRaw == "contribution" { return "缴" }
        switch icon {
        case let s where s.contains("fork") || s.contains("cup"): return "餐"
        case let s where s.contains("car") || s.contains("tram") || s.contains("bus") || s.contains("airplane"): return "行"
        case let s where s.contains("bag") || s.contains("cart"): return "购"
        case let s where s.contains("house") || s.contains("bed"): return "住"
        case let s where s.contains("game") || s.contains("tv") || s.contains("film"): return "娱"
        case let s where s.contains("cross") || s.contains("heart") || s.contains("pills"): return "医"
        case let s where s.contains("book") || s.contains("graduation"): return "学"
        case let s where s.contains("gift"): return "礼"
        case let s where s.contains("creditcard"): return "还"
        case let s where s.contains("banknote") || s.contains("yensign"): return "入"
        case let s where s.contains("arrow.left.arrow.right"): return "转"
        case let s where s.contains("building.columns"): return "储"
        default: return "账"
        }
    }
}
