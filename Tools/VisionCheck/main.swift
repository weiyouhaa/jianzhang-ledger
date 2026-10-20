// macOS 上用合成截图（Tools/make_wechat_fixture.py 渲染，虚构数据）跑一遍 Vision OCR + 解析器（CI 中执行）：
// swiftc Ledger/OCR/ReceiptParser.swift Ledger/OCR/TextRecognizer.swift Tools/VisionCheck/main.swift -o /tmp/visioncheck
// /tmp/visioncheck Tests/Fixtures/wechat-two-payments.png
import Foundation

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
// 截图状态栏时间设定为 2026-10-18 08:50（北京时间）
let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 8, minute: 50))!

func fmt(_ d: Date?) -> String {
    guard let d else { return "nil" }
    let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: d)
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/Fixtures/wechat-two-payments.png"
let data = try Data(contentsOf: URL(fileURLWithPath: path))
let lines = try await TextRecognizer.recognizeOCRLines(in: data)
print("== Vision OCR 行（\(lines.count)）==")
for l in lines {
    print(String(format: "  y=%.3f h=%.3f  ", l.midY, l.height) + l.text)
}
let results = ReceiptParser.parseAll(lines: lines, now: now, calendar: cal)
print("== 解析结果（\(results.count) 笔）==")
for (i, r) in results.enumerated() {
    let hint = r.accountHint.map { "\($0.type ?? "-") \($0.bankName ?? "") \($0.cardTail ?? "")" } ?? "-"
    print("  \(i + 1). \(r.isIncome ? "收入" : "支出") ¥\(r.amount ?? -1) 商户=\(r.merchant ?? "-") 分类=\(r.categoryName ?? "-") 时间=\(fmt(r.date)) 账户线索=\(hint)")
}

// 期望（仅针对 wechat-two-payments.png）
if path.hasSuffix("wechat-two-payments.png") {
    var ok = results.count == 2
    if ok {
        let a = results[0], b = results[1]
        ok = a.amount == 18 && !a.isIncome && a.merchant == "阿芳" && fmt(a.date) == "2026-10-17 15:25" && a.accountHint?.type == "wechat"
            && b.amount == 46 && !b.isIncome && b.merchant == "华南畅行高速科技有限公司" && b.categoryName == "交通"
            && fmt(b.date) == "2026-10-17 20:12" && b.accountHint?.type == "credit" && b.accountHint?.cardTail == "7316"
    }
    print(ok ? "VISION CHECK PASSED" : "VISION CHECK FAILED")
    exit(ok ? 0 : 1)
}
