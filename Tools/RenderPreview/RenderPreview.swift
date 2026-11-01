// CI（macOS）上用 ImageRenderer 把识图小票卡片渲染成 PNG（只用合成示例数据），方便不装 App 也能看效果。
// 用法：renderpreview <输出目录>
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct RenderPreview {
    @MainActor
    static func main() {
        let out = CommandLine.arguments.dropFirst().first ?? "."
        let s = ReviewRow.samples
        // 3.1 (22)：片段为紧凑小票，带高度预算；最后两张模拟弹窗空间更小时的降级（精简 / 极简）
        func budgetBox<V: View>(_ label: String, _ view: V, _ p: ReceiptPalette) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption2).foregroundStyle(p.faint)
                view.background(RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.05)))
            }
        }
        func panel(_ scheme: ColorScheme) -> some View {
            let p = ReceiptPalette.paper(scheme)
            return VStack(alignment: .leading, spacing: 14) {
                Text(scheme == .dark ? "深色模式" : "浅色模式").font(.caption.bold()).foregroundStyle(p.faint)
                budgetBox("1 笔 · 紧凑", ReceiptStackView(title: "识别结果", rows: [s[1]], engineLine: "识别引擎：Apple 智能 · 模型 6.9 秒",
                                                      countText: "共 1 笔"), p)
                budgetBox("2 笔 · 紧凑", ReceiptStackView(title: "识别结果", rows: [s[0], s[4]], engineLine: "识别引擎：规则", countText: "共 2 笔",
                                                      totals: [("支出", "¥39.80"), ("还款", "¥1,000.00")]), p)
                budgetBox("5 笔 · 紧凑", ReceiptStackView(title: "识别结果", rows: s, engineLine: "识别引擎：Apple 智能",
                                                      countText: "保存 4 笔 · 跳过 1 笔",
                                                      totals: [("支出", "¥63.30"), ("收入", "¥200.00"), ("还款", "¥1,000.00")]), p)
                budgetBox("5 笔 · 空间只有 200pt → 精简", ReceiptStackView(title: "识别结果", rows: s, countText: "保存 4 笔 · 跳过 1 笔",
                                                                   totals: [("支出", "¥63.30"), ("收入", "¥200.00")], heightBudget: 200), p)
                budgetBox("5 笔 · 空间只有 110pt → 极简", ReceiptStackView(title: "识别结果", rows: s, countText: "保存 4 笔 · 跳过 1 笔",
                                                                   totals: [("支出", "¥63.30"), ("收入", "¥200.00")], heightBudget: 110), p)
            }
            .padding(16)
            .frame(width: 390)
            .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.95))
            .environment(\.colorScheme, scheme)
        }
        let view = HStack(alignment: .top, spacing: 0) { panel(.light); panel(.dark) }
        write(view, to: "\(out)/preview-receipt-card", ext: imageExt)
        write(SkinChromeDemo(), to: "\(out)/preview-skins", ext: imageExt)
        write(EditorCardDemo(), to: "\(out)/preview-editor-card", ext: imageExt)
        write(DayCardDemo(), to: "\(out)/preview-day-card", ext: imageExt)
    }

    static let imageExt = "png"

    @MainActor
    static func write<V: View>(_ view: V, to stem: String, ext: String) {
        let path = stem + "." + ext
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage,
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.\(ext)" as CFString, 1, nil)
        else { print("render failed: \(path)"); exit(1) }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { print("write failed: \(path)"); exit(1) }
        print("wrote \(path) \(cg.width)x\(cg.height)")
    }
}
