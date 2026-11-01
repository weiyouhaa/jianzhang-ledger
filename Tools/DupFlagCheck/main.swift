// 识图「可能重复」提示自检（3.3 (24)；纯合成数据，Linux 与 macOS 均可运行）：
// swiftc Ledger/OCR/ReceiptParser.swift Ledger/OCR/CaptureTime.swift Ledger/Dedupe/DuplicateHint.swift Tools/DupFlagCheck/main.swift -o /tmp/dupflagcheck && /tmp/dupflagcheck
//
// 回归：2.0 (19) 起找不到交易时间时以截图时间为账单时间，旧代码只对「识别到时间」的笔查重，
// 这些笔不再显示「可能重复」。这里确保截图时间 / 状态栏 / 现在 也会查重，并且提示里带上相似记录的时间与金额。
import Foundation

var failures = 0
func expect(_ cond: Bool, _ msg: String) {
    if cond { print("✅ \(msg)") } else { failures += 1; print("❌ \(msg)") }
}

let tz = TimeZone(identifier: "Asia/Shanghai")!
var cal = Calendar(identifier: .gregorian)
cal.timeZone = tz
func t(_ day: Int, _ h: Int, _ m: Int) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
}
typealias E = DuplicateMatcher.Entry

// 账本里已有的合成记录
let ledger: [E] = [
    E(amount: 39.80, merchant: "示例烧腊饭店（示例大厦店）", date: t(31, 14, 3), account: "acc-debit"),
    E(amount: 12.00, merchant: "示例便利店", date: t(31, 9, 0), account: "acc-wallet"),
]

// 1. 每一种时间来源都查重（旧代码只查 .recognized）
for source in TimeSource.allCases {
    expect(DuplicateHint.window(for: source) >= DuplicateMatcher.window, "时间来源 \(source.rawValue) 也查重（窗口 \(Int(DuplicateHint.window(for: source)))s）")
}

// 2. 识别到的时间：5 分钟内同商户同金额 → 重复
let rec = E(amount: 39.80, merchant: "示例烧腊饭店", date: t(31, 14, 5), account: "acc-debit")
expect(DuplicateHint.firstMatch(rec, among: ledger, window: DuplicateHint.window(for: .recognized)) == 0, "识别到时间：2 分钟后同商户同金额 → 与第 1 条重复")

// 3. 截图时间（比交易晚 18 分钟）：旧窗口找不到，新窗口找到
let shot = E(amount: 39.80, merchant: "示例烧腊饭店", date: t(31, 14, 21), account: nil)
expect(DuplicateHint.firstMatch(shot, among: ledger, window: DuplicateMatcher.window) == nil, "截图时间晚 18 分钟：5 分钟窗口找不到（回归原因）")
expect(DuplicateHint.firstMatch(shot, among: ledger, window: DuplicateHint.window(for: .screenshot)) == 0, "截图时间晚 18 分钟：30 分钟窗口 → 重复")

// 4. 宽窗口不误报：金额相同但商户不同 / 只有金额相同 / 账户冲突
let otherMerchant = E(amount: 39.80, merchant: "另一家示例面馆", date: t(31, 14, 20), account: nil)
expect(DuplicateHint.firstMatch(otherMerchant, among: ledger, window: 1800) == nil, "宽窗口：商户不同不算重复")
let amountOnly = E(amount: 39.80, merchant: "", date: t(31, 14, 25), account: nil)
expect(DuplicateHint.firstMatch(amountOnly, among: ledger, window: 1800) == nil, "宽窗口：只有金额相同不算重复")
let accountConflict = E(amount: 39.80, merchant: "示例烧腊饭店", date: t(31, 14, 25), account: "acc-credit")
expect(DuplicateHint.firstMatch(accountConflict, among: ledger, window: 1800) == nil, "宽窗口：账户不同不算重复")
let tooLate = E(amount: 39.80, merchant: "示例烧腊饭店", date: t(31, 14, 40), account: nil)
expect(DuplicateHint.firstMatch(tooLate, among: ledger, window: 1800) == nil, "超过 30 分钟不算重复")
let sameAccount = E(amount: 12.00, merchant: "", date: t(31, 9, 20), account: "acc-wallet")
expect(DuplicateHint.firstMatch(sameAccount, among: ledger, window: 1800) == 1, "宽窗口：同账户同金额（无商户）→ 重复")

// 5. 提示文字：红字里带相似记录的日期、时间、金额、标题
let hit = DuplicateHit(date: t(31, 14, 3), amount: 39.80, title: "示例烧腊饭店")
let banner = DuplicateHint.banner(hit, skip: true, timeZone: tz)
print("   → \(banner)")
expect(banner == "⚠︎ 可能重复：与 10月31日 14:03 ¥39.80 · 示例烧腊饭店 的记录相似（默认跳过）", "片段提示包含日期、时间、金额、标题和默认跳过")
expect(DuplicateHint.banner(hit, skip: false, timeZone: tz).hasSuffix("（仍保存）"), "选择仍保存时提示改为「仍保存」")
expect(!DuplicateHint.banner(hit, skip: nil, timeZone: tz).contains("（"), "编辑页提示不带跳过 / 保存说明")
let big = DuplicateHit(date: t(1, 8, 5), amount: 1234.5, title: "")
expect(DuplicateHint.banner(big, skip: nil, symbol: "$", timeZone: tz) == "⚠︎ 可能重复：与 10月1日 08:05 $1,234.50 的记录相似", "千分位、自定义货币符号、空标题")
let batch = DuplicateHit(date: t(31, 14, 3), amount: 39.80, title: "", batchIndex: 2)
expect(DuplicateHint.banner(batch, skip: true, timeZone: tz) == "⚠︎ 可能重复：与本批第 2 笔是同一笔（默认跳过）", "本批内重复：指出第几笔")

if failures > 0 { print("\(failures) 项失败"); exit(1) }
print("全部通过")
