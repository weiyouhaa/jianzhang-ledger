#if DEBUG
import SwiftUI
import UIKit

/// UI 测试探针（启动参数 `-UITestOCRMemoryProbe`，仅 Debug 构建）：
/// 生成一张 1290×2796 的合成支付截图（全部是虚构内容），走快捷指令同一条识别路径
/// （ReceiptRecognizer.recognizeDetailed，context = .shortcut，含分类 / 账户词表），
/// 后台线程每 2 ms 采样 phys_footprint，记录峰值；再用不缩小的整图尺寸跑一遍做对比。
struct OCRMemoryProbe: View {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-UITestOCRMemoryProbe") }
    @State private var result = "running"

    var body: some View {
        Text(result)
            .font(.system(size: 6))
            .opacity(0.05)
            .accessibilityLabel(result)
            .accessibilityIdentifier("debug-ocr-memory")
            .task { result = await Self.run() }
    }

    final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: Double = 0
        private var running = true
        func start() {
            peak = RunLog.footprintMB()
            Thread.detachNewThread { [self] in
                while true {
                    let v = RunLog.footprintMB()
                    lock.lock()
                    if v > peak { peak = v }
                    let go = running
                    lock.unlock()
                    if !go { break }
                    usleep(2000)
                }
            }
        }
        func stop() -> Double {
            lock.lock(); running = false; let p = peak; lock.unlock()
            return p
        }
    }

    @MainActor
    static func syntheticScreenshot() -> Data {
        let size = CGSize(width: 1290, height: 2796)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.96, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 380, width: 1290, height: 1500))
            func draw(_ text: String, y: CGFloat, size: CGFloat, weight: UIFont.Weight = .regular,
                      color: UIColor = .black, x: CGFloat = 90, center: Bool = false) {
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: weight),
                                                            .foregroundColor: color]
                let s = NSAttributedString(string: text, attributes: attrs)
                let w = s.size().width
                s.draw(at: CGPoint(x: center ? (1290 - w) / 2 : x, y: y))
            }
            draw("9:41", y: 50, size: 50, weight: .semibold, x: 110)
            draw("账单详情", y: 230, size: 54, weight: .medium, center: true)
            draw("示例便利店", y: 470, size: 54, center: true)
            draw("-128.50", y: 580, size: 130, weight: .semibold, center: true)
            draw("交易成功", y: 780, size: 46, color: .darkGray, center: true)
            let rows = [("支付时间", "2026-10-20 15:25:01"), ("付款方式", "招商银行信用卡(1234)"),
                        ("商品说明", "零售商品"), ("收单机构", "示例支付有限公司"),
                        ("订单号", "2026102000000000000000000001")]
            for (i, r) in rows.enumerated() {
                let y = 960 + CGFloat(i) * 150
                draw(r.0, y: y, size: 44, color: .gray)
                draw(r.1, y: y, size: 44, x: 420)
            }
            draw("账单分类  日用百货", y: 1960, size: 44, color: .gray)
            draw("对此订单有疑问", y: 2100, size: 44, color: .systemBlue)
        }
        return image.pngData() ?? Data()
    }

    @MainActor
    static func run() async -> String {
        let data = syntheticScreenshot()
        let vocab = IntentRecorder.ocrVocabulary()
        // 让 Vision 模型先加载一次以外的开销不计入：先跑一遍预热，再测
        try? await Task.sleep(nanoseconds: 300_000_000)

        let base1 = RunLog.footprintMB()
        let s1 = Sampler(); s1.start()
        let t0 = Date()
        let r = try? await ReceiptRecognizer.recognizeDetailed(imageData: data, vocabulary: vocab, context: .shortcut)
        let ms1 = Int(Date().timeIntervalSince(t0) * 1000)
        let peak1 = s1.stop()

        try? await Task.sleep(nanoseconds: 500_000_000)
        let base2 = RunLog.footprintMB()
        let s2 = Sampler(); s2.start()
        let t1 = Date()
        let full = try? await TextRecognizer.recognizeOCRLines(in: data, maxPixel: 2796)
        let ms2 = Int(Date().timeIntervalSince(t1) * 1000)
        let peak2 = s2.stop()

        // 第二次 2000 px（模型 / Vision 已加载，看稳态）
        try? await Task.sleep(nanoseconds: 500_000_000)
        let base3 = RunLog.footprintMB()
        let s3 = Sampler(); s3.start()
        _ = try? await ReceiptRecognizer.recognizeDetailed(imageData: data, vocabulary: vocab, context: .shortcut)
        let peak3 = s3.stop()

        let found = r?.receipts.filter { ($0.amount ?? 0) > 0 }.count ?? -1
        let amountOK = r?.receipts.contains { abs(($0.amount ?? 0) - 128.5) < 0.001 } ?? false
        let line = String(format: "done png=%dKB intent2000: base=%.1fMB peak=%.1fMB delta=%.1fMB %dms receipts=%d amountOK=%@ engine=%@ | full2796: base=%.1fMB peak=%.1fMB delta=%.1fMB %dms lines=%d | intent2000-warm: base=%.1fMB peak=%.1fMB delta=%.1fMB",
                          data.count / 1024, base1, peak1, peak1 - base1, ms1, found, amountOK ? "yes" : "no",
                          r?.engine.title ?? "?", base2, peak2, peak2 - base2, ms2, full?.count ?? -1,
                          base3, peak3, peak3 - base3)
        RunLog.shared.log(.info, "memory-probe", line)
        return line
    }
}
#endif
