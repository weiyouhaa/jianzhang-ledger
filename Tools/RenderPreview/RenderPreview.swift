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
        func panel(_ scheme: ColorScheme) -> some View {
            let p = ReceiptPalette.paper(scheme)
            return VStack(alignment: .leading, spacing: 18) {
                Text(scheme == .dark ? "深色模式" : "浅色模式").font(.caption.bold()).foregroundStyle(p.faint)
                ReceiptStackView(title: "识别结果", rows: [s[0]], engineLine: "识别引擎：Apple 智能 · 模型 6.9 秒", countText: "共 1 笔")
                ReceiptStackView(title: "识别结果", rows: [s[1], s[4]], engineLine: "识别引擎：规则", countText: "共 2 笔",
                                 totals: [("支出", "¥23.50"), ("还款", "¥1,000.00")])
                ReceiptStackView(title: "识别结果", rows: s, engineLine: "识别引擎：Apple 智能", countText: "保存 4 笔 · 跳过 1 笔",
                                 totals: [("支出", "¥63.30"), ("收入", "¥200.00"), ("还款", "¥1,000.00")])
            }
            .padding(16)
            .frame(width: 390)
            .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.95))
            .environment(\.colorScheme, scheme)
        }
        let view = HStack(alignment: .top, spacing: 0) { panel(.light); panel(.dark) }
        write(view, to: "\(out)/preview-receipt-card", ext: imageExt)
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
