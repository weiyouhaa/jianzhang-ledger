import SwiftUI

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
    /// 与 iOS 26 分组列表的圆角接近，列表分组和自绘卡片看起来是同一种纸片
    static let corner: CGFloat = 22
    static let ruleWidth: CGFloat = 0.75
    static let ruleDash: [CGFloat] = [2, 3]
    /// 小号标签字距（Receipt Atlas 里的 HOME / SPENT / DATE）
    static let labelTracking: CGFloat = 1.4
    static let barHeight: CGFloat = 3

    // MARK: 字号（5 档）
    enum Size {
        static let hero: CGFloat = 34
        static let title: CGFloat = 20
        static let body: CGFloat = 16
        static let meta: CGFloat = 13
        static let label: CGFloat = 11
    }

    // MARK: 色板（浅色 / 深色）
    struct Pair { let light: String; let dark: String
        func hex(dark isDark: Bool) -> String { isDark ? dark : light }
    }
    // 棉浆白纸（浅）/ 黑金炭票（深）——对齐 3.9 UI/UX 设计稿 token
    static let paper = Pair(light: "#FAF7F0", dark: "#23201D")
    static let paperElevated = Pair(light: "#FFFDF9", dark: "#2B2723")
    static let backdrop = Pair(light: "#EAE3D5", dark: "#12100E")
    static let ink = Pair(light: "#221E1C", dark: "#EDE6DC")
    static let faint = Pair(light: "#6B635B", dark: "#A0968A")
    static let muted = Pair(light: "#9A9086", dark: "#6C6359")
    static let rule = Pair(light: "#DCD4C6", dark: "#36312C")
    static let ruleDashed = Pair(light: "#C9BFAE", dark: "#453F38")
    /// 朱砂 vermilion（主强调 / 超支 / 印章）
    static let accent = Pair(light: "#A63628", dark: "#DF6250")
    /// 森绿（收入）
    static let income = Pair(light: "#2C5E43", dark: "#579E78")
    /// 琥珀警示（时间未识别、接近预算上限）
    static let caution = Pair(light: "#9E631B", dark: "#E0A24E")
    /// 信用卡 STATEMENT 卡面（朱砂底上的暖象牙文字）
    static let statementFill = Pair(light: "#8F2A22", dark: "#5C241E")
    static let statementInk = Pair(light: "#FFF8F0", dark: "#F5E6D8")
    static let slot = Pair(light: "#BEB5A6", dark: "#070605")

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

/// 顶部汇总卡（hero）专用：上方圆角、下沿一排齿孔（撕下的小票），其它卡片不用
struct PerforatedCardShape: Shape {
    var corner: CGFloat = ReceiptStyle.corner
    var tooth: CGFloat = 10
    var depth: CGFloat = 3

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

/// 细进度条（预算 / 负债率 / 当天支出占比）：3pt 高，方头，轨道是虚线色
struct ReceiptBar: View {
    let ratio: Double
    var fill: Color
    var track: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(track)
                Rectangle().fill(fill)
                    .frame(width: max(ratio > 0 ? 2 : 0, g.size.width * min(max(ratio, 0), 1)))
            }
        }
        .frame(height: ReceiptStyle.barHeight)
        .clipShape(RoundedRectangle(cornerRadius: 1))
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
