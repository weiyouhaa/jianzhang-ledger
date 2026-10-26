// 账单导入 / 规则 / 周期 自检（Linux 与 macOS 均可运行；GBK 解码仅 macOS 支持）：
// swiftc Ledger/OCR/ReceiptParser.swift Ledger/Import/{BillParser,Inflate,XLSXReader}.swift Ledger/Rules/RuleMatcher.swift \
//        Ledger/Recurring/RecurrenceSchedule.swift Tools/ImportCheck/main.swift -o /tmp/importcheck && /tmp/importcheck Tests/Fixtures/import
import Foundation

var failures = 0
func expect(_ cond: Bool, _ msg: String) {
    if cond { print("✅ \(msg)") } else { failures += 1; print("❌ \(msg)") }
}

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
func fmt(_ d: Date?) -> String {
    guard let d else { return "nil" }
    let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: d)
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/Fixtures/import"
func load(_ name: String) -> Data? { try? Data(contentsOf: URL(fileURLWithPath: dir + "/" + name)) }

func dump(_ r: BillParseResult) {
    for e in r.entries {
        let hint = e.accountHint.map { "\($0.type ?? "-")\($0.cardTail.map { " " + $0 } ?? "")" } ?? "-"
        let to = e.toAccountHint.map { " → \($0.type ?? "-")\($0.cardTail.map { " " + $0 } ?? "")" } ?? ""
        print("    \(fmt(e.date)) \(e.kind.rawValue) ¥\(e.amount) \(e.merchant) [\(e.suggestedCategoryName ?? "-")] \(hint)\(to) \(e.skipReason ?? "")")
    }
}

// MARK: 支付宝（UTF-8 版本，在 Linux 上也能跑）

func checkAlipay(_ r: BillParseResult, label: String) {
    expect(r.source == .alipay, "\(label) 识别为支付宝")
    expect(r.entries.count == 11, "\(label) 共 11 行（实际 \(r.entries.count)）")
    let byMerchant = Dictionary(r.entries.map { ($0.merchant + "|" + $0.product, $0) }, uniquingKeysWith: { a, _ in a })
    func find(_ m: String) -> BillEntry? { r.entries.first { $0.merchant == m } }
    if let e = find("华南畅行高速科技有限公司") {
        expect(e.kind == .expense && e.amount == 46 && fmt(e.date) == "2026-10-17 20:12", "\(label) 高速 支出 46 时间正确")
        expect(e.accountHint?.type == "credit" && e.accountHint?.cardTail == "7316", "\(label) 高速 付款方式 → 信用卡 7316")
        expect(e.suggestedCategoryName == "交通", "\(label) 高速 分类 交通")
        expect(e.orderID == "2026101722001400000001", "\(label) 订单号去掉制表符")
    } else { expect(false, "\(label) 找到高速") }
    expect(find("星巴克")?.accountHint?.type == "consumerCredit", "\(label) 花呗 → 消费信贷")
    expect(find("星巴克")?.suggestedCategoryName == "餐饮", "\(label) 星巴克 餐饮")
    expect(find("星巴克")?.memo == "星巴克咖啡(国贸店)", "\(label) 商品说明作为备注")
    let uq = r.entries.filter { $0.merchant == "优衣库官方旗舰店" }
    expect(uq.count == 2 && uq.allSatisfy { $0.kind == .skip }, "\(label) 全额退款的原交易与退款都跳过")
    expect(r.entries.first { $0.product.hasPrefix("余额宝") }?.kind == .transfer, "\(label) 余额宝收益 → 不计收支（转账候选）")
    expect(find("张三")?.kind == .income && find("张三")?.accountHint?.type == "alipay", "\(label) 转账收入 → 收入，账户 支付宝")
    expect(find("美团")?.kind == .skip && find("美团")?.skipReason?.contains("关闭") == true, "\(label) 交易关闭跳过")
    if let e = find("招商银行") {
        expect(e.kind == .transfer && e.accountHint?.cardTail == "6688" && e.toAccountHint?.type == "credit"
               && e.toAccountHint?.cardTail == "1024", "\(label) 信用卡还款 → 转账 储蓄卡6688 → 信用卡1024")
    } else { expect(false, "\(label) 找到信用卡还款") }
    expect(find("中国移动")?.suggestedCategoryName == "通讯", "\(label) 话费 → 通讯（关键词优先于宽泛的充值缴费）")
    expect(find("猫眼电影")?.suggestedCategoryName == "娱乐", "\(label) 猫眼 → 娱乐")
    _ = byMerchant
    dump(r)
}

if let d = load("alipay-utf8.csv") {
    do { checkAlipay(try BillParser.parse(data: d, fileName: "alipay-utf8.csv"), label: "支付宝UTF8") }
    catch { expect(false, "支付宝UTF8 解析失败 \(error)") }
}

if let d = load("alipay-gbk.csv") {
    expect(String(data: d, encoding: .utf8) == nil, "GBK 文件不是有效 UTF-8")
    if let text = BillParser.decodeText(d) {
        expect(text.contains("交易时间"), "GBK 解码成功")
        do { checkAlipay(try BillParser.parse(data: d), label: "支付宝GBK") } catch { expect(false, "支付宝GBK 解析失败 \(error)") }
    } else {
        #if os(Linux)
        print("⚠️ 当前平台不支持 GB18030 解码（Linux），GBK 用例在 macOS CI 上运行")
        #else
        expect(false, "GBK 解码失败")
        #endif
    }
}

// MARK: 微信 CSV / XLSX

func checkWechat(_ r: BillParseResult, label: String) {
    expect(r.source == .wechat, "\(label) 识别为微信")
    expect(r.entries.count == 9, "\(label) 共 9 行（实际 \(r.entries.count)）")
    func find(_ m: String) -> BillEntry? { r.entries.first { $0.merchant == m } }
    expect(find("阿芳")?.kind == .expense && find("阿芳")?.amount == 18 && find("阿芳")?.accountHint?.type == "wechat",
           "\(label) 零钱支付 12 → 支出 微信")
    expect(fmt(find("阿芳")?.date) == "2026-10-17 15:25", "\(label) 时间")
    expect(find("华南畅行高速科技有限公司")?.accountHint?.cardTail == "7316", "\(label) 信用卡尾号")
    let mt = r.entries.filter { $0.merchant == "美团" }
    expect(mt.first { $0.direction == "支出" }?.amount == 25, "\(label) 部分退款后净额 25")
    expect(mt.first { $0.direction == "收入" }?.kind == .skip, "\(label) 已抵扣的退款跳过")
    expect(find("李四")?.kind == .income && find("李四")?.suggestedCategoryName == "红包", "\(label) 红包收入")
    expect(r.entries.first { $0.product.contains("零钱通") }?.kind == .transfer, "\(label) 零钱通 → 转账候选")
    expect(find("招商银行")?.toAccountHint?.type == "credit" && find("招商银行")?.toAccountHint?.bankName == "招商银行",
           "\(label) 信用卡还款 → 招商银行信用卡")
    expect(find("早餐店")?.kind == .skip, "\(label) 支付失败跳过")
    expect(find("王五")?.kind == .expense, "\(label) 转账（对方已收钱）→ 支出")
    expect(find("阿芳")?.orderID == "4200000001202610170001", "\(label) 交易单号去空格")
    dump(r)
}

for name in ["wechat.csv", "wechat.xlsx", "wechat-shared.xlsx"] {
    guard let d = load(name) else { expect(false, "缺少 \(name)"); continue }
    do { checkWechat(try BillParser.parse(data: d, fileName: name), label: name) }
    catch { expect(false, "\(name) 解析失败 \(error)") }
}

// MARK: Inflate（stored + 压缩数据）
do {
    let rows = try XLSXReader.rows(from: load("wechat-shared.xlsx") ?? Data())
    expect(rows.count == 26, "xlsx 行数 26（实际 \(rows.count)）")
    expect(XLSXReader.columnIndex("AB12") == 27, "列号 AB → 27")
} catch { expect(false, "xlsx 读取 \(error)") }

// MARK: 规则匹配

let catFood = UUID(), catTraffic = UUID(), catShop = UUID(), catSalary = UUID()
let rules = [
    RuleSnapshot(id: UUID(), keyword: MerchantNormalizer.normalize("星巴克咖啡(国贸店)"), isLearned: true, kindRaw: "expense", categoryID: catFood),
    RuleSnapshot(id: UUID(), keyword: MerchantNormalizer.normalize("盒马鲜生"), isLearned: true, kindRaw: "expense", categoryID: catShop),
    RuleSnapshot(id: UUID(), keyword: "高速", isLearned: false, kindRaw: "expense", categoryID: catTraffic),
    RuleSnapshot(id: UUID(), keyword: "工资", isLearned: false, kindRaw: "income", categoryID: catSalary),
    RuleSnapshot(id: UUID(), keyword: "禁用", isLearned: false, categoryID: catShop, isEnabled: false),
]
expect(MerchantNormalizer.normalize("星巴克咖啡(北京国贸店)") == "星巴克咖啡", "规整：去分店括号")
expect(MerchantNormalizer.normalize("华南畅行高速科技有限公司") == "华南畅行高速科技", "规整：去公司后缀")
expect(RuleMatcher.match(merchant: "星巴克咖啡（三里屯店）", rules: rules)?.categoryID == catFood, "学习规则：同商户不同分店")
expect(RuleMatcher.match(merchant: "星巴克", rules: rules)?.categoryID == catFood, "学习规则：模糊包含")
expect(RuleMatcher.match(merchant: "华南畅行高速科技有限公司", rules: rules)?.categoryID == catTraffic, "手动关键词：高速")
expect(RuleMatcher.match(merchant: "某公司", text: "10月工资", rules: rules)?.categoryID == catSalary, "手动关键词匹配备注文字")
expect(RuleMatcher.match(merchant: "某公司", text: "10月工资", kind: "expense", rules: rules) == nil, "收支类型不符不匹配")
expect(RuleMatcher.match(merchant: "禁用商户", rules: rules) == nil, "停用规则不生效")
expect(RuleMatcher.match(merchant: "盒马鲜生(望京店)", rules: rules)?.categoryID == catShop, "学习规则：精确优先")
expect(RuleMatcher.match(merchant: "", rules: rules) == nil, "空商户不匹配")

// MARK: 周期

func d(_ s: String) -> Date {
    let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
}
let monthly = RecurrenceSpec(frequency: .monthly, monthDay: 31, start: d("2026-01-15 09:00"))
let occ = monthly.occurrences(through: d("2026-05-31 23:00"), calendar: cal).map(fmt)
expect(occ == ["2026-01-31 09:00", "2026-02-28 09:00", "2026-03-31 09:00", "2026-04-30 09:00", "2026-05-31 09:00"],
       "每月31日 → 月末自动收缩 \(occ)")
let lastDay = RecurrenceSpec(frequency: .monthly, lastDayOfMonth: true, start: d("2026-02-01 08:00"), maxCount: 2)
expect(lastDay.occurrences(through: d("2026-12-31 00:00"), calendar: cal).map(fmt) == ["2026-02-28 08:00", "2026-03-31 08:00"],
       "每月最后一天 + 次数限制")
let weekly = RecurrenceSpec(frequency: .weekly, interval: 2, weekday: 2, start: d("2026-10-01 20:00"))
expect(weekly.occurrences(through: d("2026-10-31 23:00"), calendar: cal).map(fmt) == ["2026-10-05 20:00", "2026-10-19 20:00"],
       "每 2 周周一")
let yearly = RecurrenceSpec(frequency: .yearly, start: d("2024-02-29 10:00"), end: d("2027-12-31 00:00"))
expect(yearly.occurrences(through: d("2030-01-01 00:00"), calendar: cal).map(fmt)
       == ["2024-02-29 10:00", "2025-02-28 10:00", "2026-02-28 10:00", "2027-02-28 10:00"], "每年 2/29 → 平年 2/28，截止日期")
expect(fmt(monthly.next(after: d("2026-10-18 12:00"), calendar: cal)) == "2026-10-31 09:00", "下次发生日期")
let daily = RecurrenceSpec(frequency: .daily, interval: 3, start: d("2026-10-01 07:30"))
expect(daily.occurrences(through: d("2026-10-10 00:00"), calendar: cal).count == 3, "每 3 天（10/1、4、7）")
expect(monthly.description(calendar: cal) == "每月 31 日", "描述文字")

// MARK: 文件类型识别（2.0 (11)：.xls / 账单压缩包 / XLSX）

/// 构造仅存储（method 0）的最小 ZIP，用于合成测试
func makeZip(_ files: [(String, Data)], encrypted: Bool = false) -> Data {
    var out = [UInt8](), central = [UInt8]()
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF) }
    let flag = encrypted ? 1 : 0
    for (name, data) in files {
        let n = [UInt8](name.utf8), d = [UInt8](data)
        let offset = out.count
        out += le32(0x04034B50) + le16(20) + le16(flag) + le16(0) + le16(0) + le16(0) + le32(0)
        out += le32(d.count) + le32(d.count) + le16(n.count) + le16(0) + n + d
        central += le32(0x02014B50) + le16(20) + le16(20) + le16(flag) + le16(0) + le16(0) + le16(0) + le32(0)
        central += le32(d.count) + le32(d.count) + le16(n.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + n
    }
    let cdOffset = out.count
    out += central
    out += le32(0x06054B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(central.count) + le32(cdOffset) + le16(0)
    return Data(out)
}
func parseError(_ data: Data, _ name: String) -> BillParseError? {
    do { _ = try BillParser.parse(data: data, fileName: name); return nil } catch let e as BillParseError { return e } catch { return nil }
}

let oleHeader = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + [UInt8](repeating: 0, count: 504))
expect(BillFileKind.detect(oleHeader) == .legacyExcel, "OLE 魔数 → 旧版 Excel")
if case .legacyExcel? = parseError(oleHeader, "示例账单.xls") { expect(true, ".xls 抛出明确提示（导出 CSV / XLSX）") }
else { expect(false, ".xls 抛出明确提示") }
expect(BillParseError.legacyExcel.errorDescription?.contains("CSV") == true, ".xls 提示文字含 CSV 建议")
if let x = load("wechat.xlsx") { expect(BillFileKind.detect(x) == .xlsx, "wechat.xlsx 识别为 XLSX") }
if let c = load("wechat.csv") {
    expect(BillFileKind.detect(c) == .text, "wechat.csv 识别为文本")
    let plain = makeZip([("__MACOSX/._x.csv", Data([1, 2])), ("微信支付账单(示例).csv", c)])
    expect(BillFileKind.detect(plain) == .zip, "普通 ZIP 识别为压缩包")
    if let r = try? BillParser.parse(data: plain, fileName: "示例.zip") {
        expect(r.source == .wechat && !r.entries.isEmpty, "未加密压缩包内的 CSV 直接读取（\(r.entries.count) 笔）")
    } else { expect(false, "未加密压缩包内的 CSV 直接读取") }
    if case .encryptedArchive? = parseError(makeZip([("示例.csv", c)], encrypted: true), "示例.zip") { expect(true, "加密压缩包 → 提示先解压") }
    else { expect(false, "加密压缩包 → 提示先解压") }
}
if case .archiveWithoutBill? = parseError(makeZip([("readme.txt", Data("hi".utf8))]), "a.zip") { expect(true, "压缩包无账单 → 明确提示") }
else { expect(false, "压缩包无账单 → 明确提示") }
expect(BillFileKind.detect(Data()) == .text, "空文件不崩溃")

// Info.plist：简账出现在「共享 / 用其他应用打开」里（XLSX / XLS / CSV，Alternate），且保留 jianzhang:// 与 .jzbackup
if let plistData = try? Data(contentsOf: URL(fileURLWithPath: "Config/Info.plist")),
   let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
    let docs = plist["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
    let types = Set(docs.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
    expect(types.isSuperset(of: ["org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls", "public.comma-separated-values-text"]),
           "CFBundleDocumentTypes 含 XLSX / XLS / CSV")
    expect(!docs.isEmpty && docs.allSatisfy { ($0["LSHandlerRank"] as? String) == "Alternate" }, "文档类型均为 Alternate（不抢默认打开方式）")
    let schemes = (plist["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    expect(schemes.contains("jianzhang"), "保留 jianzhang:// URL Scheme")
    let exported = (plist["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []).compactMap { $0["UTTypeIdentifier"] as? String }
    expect(exported.contains("com.fve.ledger.jzbackup"), "保留 .jzbackup 类型声明")
} else {
    print("（未找到 Config/Info.plist，跳过文档类型检查）")
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
