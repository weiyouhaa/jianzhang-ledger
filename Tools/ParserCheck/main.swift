// Linux 上的解析器自检：swiftc Ledger/OCR/ReceiptParser.swift Tools/ParserCheck/main.swift -o parsercheck && ./parsercheck
import Foundation

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 9))!
var failures = 0

func fmt(_ d: Date?) -> String {
    guard let d else { return "nil" }
    let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: d)
}

func check(_ name: String, _ lines: [String], amount: Double?, income: Bool = false, merchant: String? = nil,
           category: String? = nil, date: String? = nil) {
    let r = ReceiptParser.parse(lines: lines, now: now, calendar: cal)
    var errs: [String] = []
    if r.amount != amount { errs.append("amount \(String(describing: r.amount)) != \(String(describing: amount))") }
    if r.isIncome != income { errs.append("income \(r.isIncome) != \(income)") }
    if let merchant, r.merchant != merchant { errs.append("merchant \(r.merchant ?? "nil") != \(merchant)") }
    if let category, r.categoryName != category { errs.append("category \(r.categoryName ?? "nil") != \(category)") }
    if let date, fmt(r.date) != date { errs.append("date \(fmt(r.date)) != \(date)") }
    if errs.isEmpty { print("✅ \(name): ¥\(r.amount ?? -1) \(r.merchant ?? "-") \(r.categoryName ?? "-") \(fmt(r.date))") }
    else { failures += 1; print("❌ \(name): " + errs.joined(separator: "; ")) }
}

check("微信支付成功", ["14:32", "支付成功", "星巴克", "¥35.00", "收款方 星巴克咖啡(北京国贸店)", "支付方式 零钱", "完成"],
      amount: 35, merchant: "星巴克咖啡(北京国贸店)", category: "餐饮")
check("支付宝账单详情", ["账单详情", "滴滴出行", "-23.50", "交易成功", "支付时间 2026-10-17 08:45:12",
                    "付款方式 招商银行信用卡(1234)", "商品说明 滴滴快车-张师傅", "订单号 2026101722001412345678901234"],
      amount: 23.5, merchant: "滴滴快车-张师傅", category: "交通", date: "2026-10-17 08:45")
check("超市小票", ["永辉超市", "商品 数量 金额", "苹果 x2 12.80", "牛奶 1 25.00", "合计: 37.80", "优惠: 5.00",
               "实付: ￥32.80", "2026年10月16日 19:20"],
      amount: 32.8, merchant: "永辉超市", category: "购物", date: "2026-10-16 19:20")
check("收款到账", ["收款到账", "+200.00", "转账", "2026-10-15 10:00"], amount: 200, income: true, date: "2026-10-15 10:00")
check("银行短信", ["【招商银行】您账户1234于10月12日12:30在美团支付交易人民币45.60元，可用余额1234.56元"],
      amount: 45.6, category: "餐饮", date: "2026-10-12 12:30")
check("外卖订单", ["订单详情", "肯德基(人民广场店)", "香辣鸡腿堡 x1 ¥22.00", "配送费 ¥3.00", "红包抵扣 -¥5.00", "实付款 ¥20.00"],
      amount: 20, merchant: "肯德基(人民广场店)", category: "餐饮")
check("分行标签", ["付款金额", "￥128.00", "商户名称:中国石化加油站", "昨天 18:05"],
      amount: 128, merchant: "中国石化加油站", category: "交通", date: "2026-10-17 18:05")
check("千分位", ["订单金额 ¥1,299.00", "京东商城", "共1件商品"], amount: 1299, merchant: "京东商城", category: "购物")
check("全角", ["实付款：￥１８．５０", "瑞幸咖啡"], amount: 18.5, merchant: "瑞幸咖啡", category: "餐饮")
check("无金额", ["你好", "欢迎光临"], amount: nil)

func checkHint(_ name: String, _ lines: [String], type: String?, tail: String? = nil, bank: String? = nil) {
    let h = ReceiptParser.parse(lines: lines, now: now, calendar: cal).accountHint
    if h?.type == type && h?.cardTail == tail && h?.bankName == bank {
        print("✅ 账户 \(name): \(type ?? "nil") \(tail ?? "-") \(bank ?? "-")")
    } else {
        failures += 1
        print("❌ 账户 \(name): got \(String(describing: h))")
    }
}
checkHint("支付宝信用卡", ["账单详情", "滴滴出行", "-23.50", "付款方式 招商银行信用卡(1234)"], type: "credit", tail: "1234", bank: "招商银行")
checkHint("微信零钱", ["支付成功", "星巴克", "¥35.00", "支付方式 零钱"], type: "wechat")
checkHint("花呗", ["交易成功", "-99.00", "付款方式 花呗"], type: "consumerCredit")
checkHint("银行短信", ["【招商银行】您账户1234于10月12日12:30在美团支付交易人民币45.60元"], type: "debit", tail: "1234", bank: "招商银行")
checkHint("余额宝", ["-18.00", "付款方式 余额宝"], type: "alipay")
checkHint("无线索", ["合计 18.00"], type: nil)
let aliases = AccountHint.aliases(forBank: "招商银行")
if aliases == ["招商银行", "招商", "招行"] { print("✅ 银行别名 \(aliases)") } else { failures += 1; print("❌ 银行别名 \(aliases)") }
let icbc = AccountHint.aliases(forBank: "中国工商银行")
if icbc.contains("工行") { print("✅ 银行别名 \(icbc)") } else { failures += 1; print("❌ 银行别名 \(icbc)") }

// MARK: - 多笔拆分 / 收支 / 时间（真实截图 OCR 样例）

struct Expect {
    var amount: Double
    var income = false
    var merchant: String? = nil
    var category: String? = nil
    var date: String? = nil
    var accountType: String? = nil
    var tail: String? = nil
}

func checkAll(_ name: String, _ lines: [OCRLine], _ expected: [Expect]) {
    let rs = ReceiptParser.parseAll(lines: lines, now: now, calendar: cal)
    var errs: [String] = []
    if rs.count != expected.count { errs.append("count \(rs.count) != \(expected.count)") }
    for (i, (r, e)) in zip(rs, expected).enumerated() {
        var p: [String] = []
        if r.amount != e.amount { p.append("amount \(String(describing: r.amount))") }
        if r.isIncome != e.income { p.append("income \(r.isIncome)") }
        if let m = e.merchant, r.merchant != m { p.append("merchant \(r.merchant ?? "nil")") }
        if let c = e.category, r.categoryName != c { p.append("category \(r.categoryName ?? "nil")") }
        if let d = e.date, fmt(r.date) != d { p.append("date \(fmt(r.date))") }
        if let t = e.accountType, r.accountHint?.type != t { p.append("account \(r.accountHint?.type ?? "nil")") }
        if let t = e.tail, r.accountHint?.cardTail != t { p.append("tail \(r.accountHint?.cardTail ?? "nil")") }
        if !p.isEmpty { errs.append("#\(i + 1): " + p.joined(separator: ", ")) }
    }
    if errs.isEmpty {
        print("✅ \(name): \(rs.count) 笔")
        for r in rs {
            print("    \(r.isIncome ? "收入" : "支出") ¥\(r.amount ?? -1) \(r.merchant ?? "-") \(r.categoryName ?? "-") \(fmt(r.date)) \(r.accountHint?.type ?? "-") \(r.accountHint?.cardTail ?? "")")
        }
    } else {
        failures += 1
        print("❌ \(name): " + errs.joined(separator: "; "))
        for r in rs { print("    got: \(r.isIncome ? "收入" : "支出") \(String(describing: r.amount)) \(r.merchant ?? "-") \(r.categoryName ?? "-") \(fmt(r.date))") }
    }
}

// 微信支付通知列表：两笔（Vision 行输出，含头像误识别「C」「é」与行高）
let wechatTwo: [OCRLine] = [
    OCRLine("8:50", midY: 0.031, height: 0.020),
    OCRLine("99", midY: 0.031, height: 0.014),
    OCRLine("微信支付", midY: 0.081, height: 0.018),
    OCRLine("昨天 下午3:25", midY: 0.136, height: 0.015),
    OCRLine("C 阿芳", midY: 0.191, height: 0.018),
    OCRLine("使用零钱支付", midY: 0.280, height: 0.017),
    OCRLine("¥ 18.00", midY: 0.333, height: 0.040),
    OCRLine("交易状态 支付成功，对方已收款", midY: 0.410, height: 0.017),
    OCRLine("查看交易详情", midY: 0.478, height: 0.017),
    OCRLine("留言 可给对方留言复购、咨询", midY: 0.540, height: 0.017),
    OCRLine("昨天 晚上8:12", midY: 0.607, height: 0.015),
    OCRLine("é 华南畅行高速科技有限公司", midY: 0.664, height: 0.018),
    OCRLine("使用交通银行信用卡（7316）支付", midY: 0.750, height: 0.017),
    OCRLine("¥46.00", midY: 0.802, height: 0.040),
    OCRLine("账单详情 >", midY: 0.856, height: 0.016),
    OCRLine("我的账单 支付服务 优惠", midY: 0.955, height: 0.016),
]
let wechatExpect = [
    Expect(amount: 18, merchant: "阿芳", date: "2026-10-17 15:25", accountType: "wechat"),
    Expect(amount: 46, merchant: "华南畅行高速科技有限公司", category: "交通", date: "2026-10-17 20:12",
           accountType: "credit", tail: "7316"),
]
checkAll("微信通知两笔（含位置）", wechatTwo, wechatExpect)
checkAll("微信通知两笔（纯文本）", wechatTwo.map { OCRLine($0.text) }, wechatExpect)
let wechatHint = ReceiptParser.parseAll(lines: wechatTwo, now: now, calendar: cal).last?.accountHint
if wechatHint?.bankName == "交通银行" { print("✅ 银行名 交通银行") } else { failures += 1; print("❌ 银行名 \(String(describing: wechatHint))") }

// 头像在单独一行、没有日期标题，只靠两个大字金额拆分
checkAll("无日期标题两笔", [
    OCRLine("C", midY: 0.19, height: 0.018), OCRLine("阿芳", midY: 0.192, height: 0.018),
    OCRLine("使用零钱支付", midY: 0.28, height: 0.017), OCRLine("￥18.00", midY: 0.33, height: 0.04),
    OCRLine("交易状态 支付成功,对方已收款", midY: 0.41, height: 0.017),
    OCRLine("华南畅行高速科技有限公司", midY: 0.66, height: 0.018),
    OCRLine("使用交通银行信用卡 (7316) 支付", midY: 0.75, height: 0.017), OCRLine("￥46.00", midY: 0.80, height: 0.04),
], [Expect(amount: 18, merchant: "阿芳"), Expect(amount: 46, merchant: "华南畅行高速科技有限公司", category: "交通")])

// 支付宝账单列表
checkAll("支付宝账单列表", [
    OCRLine("账单"), OCRLine("全部 支出 收入"), OCRLine("10月 支出¥2,345.60 收入¥1.32"),
    OCRLine("滴滴出行 -23.50"), OCRLine("交通出行 今天 08:45"),
    OCRLine("盒马鲜生 -286.40"), OCRLine("日用百货 昨天 19:20"),
    OCRLine("余额宝收益 +1.32"), OCRLine("理财 10-16 15:00"),
], [
    Expect(amount: 23.5, merchant: "滴滴出行", category: "交通", date: "2026-10-18 08:45"),
    Expect(amount: 286.4, merchant: "盒马鲜生", category: "购物", date: "2026-10-17 19:20"),
    Expect(amount: 1.32, income: true, merchant: "余额宝收益", category: "理财", date: "2026-10-16 15:00"),
])

// 两条银行短信
checkAll("银行短信两条", [
    OCRLine("【招商银行】您账户1234于10月17日20:12在美团支付交易人民币45.60元，可用余额1234.56元。"),
    OCRLine("【交通银行】您尾号7316的信用卡于10月17日12:05消费人民币46.00元。"),
    OCRLine("【工商银行】您尾号6688卡10月15日10:00工资收入人民币16800.00元，余额20000.00元。"),
], [
    Expect(amount: 45.6, merchant: "美团", category: "餐饮", date: "2026-10-17 20:12", accountType: "debit", tail: "1234"),
    Expect(amount: 46, date: "2026-10-17 12:05", accountType: "credit", tail: "7316"),
    Expect(amount: 16800, income: true, category: "工资", date: "2026-10-15 10:00", tail: "6688"),
])

// 微信收款到账（收入）、退款（收入）、普通支付（支出）
checkAll("微信收款", [OCRLine("微信支付"), OCRLine("今天 上午10:02"), OCRLine("二维码收款到账"), OCRLine("+¥58.00"),
                    OCRLine("付款方 张三")],
         [Expect(amount: 58, income: true, merchant: "张三", date: "2026-10-18 10:02")])
checkAll("退款", [OCRLine("退款成功"), OCRLine("¥99.00"), OCRLine("退款方式 原路退回 花呗")],
         [Expect(amount: 99, income: true, category: "退款")])
checkAll("对方已收款=支出", [OCRLine("支付成功,对方已收款"), OCRLine("¥8.00"), OCRLine("收款方 李记早点")],
         [Expect(amount: 8, income: false, merchant: "李记早点", category: "餐饮")])

// 信用卡还款：识别为还款，拆出被还款的卡与付款账户
func checkRepay(_ name: String, _ lines: [String], amount: Double, cardType: String, cardTail: String?, cardBank: String?,
                payerType: String?, payerTail: String?) {
    let r = ReceiptParser.parse(lines: lines, now: now, calendar: cal)
    var errs: [String] = []
    if !r.isCardRepayment { errs.append("not repayment") }
    if r.amount != amount { errs.append("amount \(String(describing: r.amount))") }
    if r.isIncome { errs.append("income") }
    if r.categoryName != "信用卡还款" { errs.append("category \(String(describing: r.categoryName))") }
    if r.repaymentCard?.type != cardType { errs.append("card type \(String(describing: r.repaymentCard?.type))") }
    if r.repaymentCard?.cardTail != cardTail { errs.append("card tail \(String(describing: r.repaymentCard?.cardTail))") }
    if r.repaymentCard?.bankName != cardBank { errs.append("card bank \(String(describing: r.repaymentCard?.bankName))") }
    if r.accountHint?.type != payerType { errs.append("payer type \(String(describing: r.accountHint?.type))") }
    if r.accountHint?.cardTail != payerTail { errs.append("payer tail \(String(describing: r.accountHint?.cardTail))") }
    if errs.isEmpty { print("✅ \(name)") } else { failures += 1; print("❌ \(name): " + errs.joined(separator: ", ")) }
}
// 合成样例（非用户数据）
checkRepay("支付宝信用卡还款", ["信用卡还款", "-3,000.00", "交易成功", "还款到 招商银行信用卡(1024)", "付款方式 招商银行储蓄卡(6688)"],
           amount: 3000, cardType: "credit", cardTail: "1024", cardBank: "招商银行", payerType: "debit", payerTail: "6688")
checkRepay("微信还信用卡", ["还信用卡", "¥1,200.00", "交通银行信用卡 尾号7316", "零钱支付"],
           amount: 1200, cardType: "credit", cardTail: "7316", cardBank: "交通银行", payerType: "wechat", payerTail: nil)
checkRepay("花呗还款", ["花呗还款成功", "¥860.00", "付款方式 余额宝"],
           amount: 860, cardType: "consumerCredit", cardTail: nil, cardBank: nil, payerType: "alipay", payerTail: nil)
// 英文界面 / 云闪付（合成样例）
checkRepay("英文 Repay:CMB Credit card", ["Repay:CMB Credit card(1024)", "-¥144.43", "Payment card CMB Debit card(6688)", "Successful"],
           amount: 144.43, cardType: "credit", cardTail: "1024", cardBank: "招商银行", payerType: "debit", payerTail: "6688")
checkRepay("英文 Credit Card Repayment ICBC", ["Credit Card Repayment", "ICBC Credit Card ending in 5566", "CNY 2,000.00", "Paid with CCB Savings Card **8899"],
           amount: 2000, cardType: "credit", cardTail: "5566", cardBank: "工商银行", payerType: "debit", payerTail: "8899")
checkRepay("英文 CMBC 不误判为 CMB", ["Repayment", "CMBC Credit Card(3344)", "¥500.00"],
           amount: 500, cardType: "credit", cardTail: "3344", cardBank: "民生银行", payerType: nil, payerTail: nil)
checkRepay("云闪付 还款成功", ["还款成功", "¥1,088.00", "还款卡 招商银行(1024)", "付款卡 建设银行储蓄卡(8899)"],
           amount: 1088, cardType: "credit", cardTail: "1024", cardBank: "招商银行", payerType: "debit", payerTail: "8899")
for (abbr, zh) in [("BOCOM", "交通银行"), ("SPDB", "浦发银行"), ("CITIC", "中信银行"), ("CEB", "光大银行"), ("CIB", "兴业银行"),
                   ("PAB", "平安银行"), ("GDB", "广发银行"), ("CGB", "广发银行"), ("PSBC", "邮储银行"), ("HXB", "华夏银行"),
                   ("ABC", "农业银行"), ("BOC", "中国银行")] {
    let got = EnglishBankTerms.localize("Repay \(abbr) Credit card")
    if got.contains(zh + "信用卡") { print("✅ 缩写 \(abbr) → \(zh)") } else { failures += 1; print("❌ 缩写 \(abbr) → \(got)") }
}
do {
    let r = ReceiptParser.parse(lines: ["Payment successful", "¥38.00", "Starbucks", "CMB Credit card(1024)"], now: now, calendar: cal)
    if r.isCardRepayment { failures += 1; print("❌ 英文信用卡消费误判为还款") } else { print("✅ 英文信用卡消费不是还款（账户线索 \(r.accountHint?.type ?? "nil") \(r.accountHint?.bankName ?? "")）") }
}
do {
    let r = ReceiptParser.parse(lines: ["支付成功", "¥46.00", "付款方式 交通银行信用卡(7316)", "收款方 华南畅行高速科技有限公司"], now: now, calendar: cal)
    if r.isCardRepayment { failures += 1; print("❌ 信用卡消费误判为还款") } else { print("✅ 信用卡消费不是还款") }
}

// 时段与星期
checkAll("凌晨", [OCRLine("前天 凌晨12:30"), OCRLine("付款金额"), OCRLine("¥30.00")], [Expect(amount: 30, date: "2026-10-16 00:30")])
checkAll("中午", [OCRLine("昨天 中午12:15"), OCRLine("付款金额"), OCRLine("¥30.00")], [Expect(amount: 30, date: "2026-10-17 12:15")])
checkAll("星期", [OCRLine("星期四 晚上9:05"), OCRLine("使用零钱支付"), OCRLine("¥30.00")], [Expect(amount: 30, date: "2026-10-15 21:05")])
checkAll("月日+下午", [OCRLine("10月12日 下午3:20"), OCRLine("付款金额"), OCRLine("¥30.00")], [Expect(amount: 30, date: "2026-10-12 15:20")])

// 商户清理
for (raw, want) in [("C 阿芳", "阿芳"), ("é阿芳", "阿芳"), ("© 美团外卖", "美团外卖"), ("KFC肯德基", "KFC肯德基"), ("T3出行", "T3出行")] {
    let got = ReceiptParser.cleanMerchant(raw)
    if got == want { print("✅ 商户清理 \(raw) → \(got)") } else { failures += 1; print("❌ 商户清理 \(raw) → \(got)") }
}


// ===== 2.0 (5)：微信 / 支付宝中英文界面（全部为自造的合成数据：示例商户、虚构金额与尾号）=====

struct W {
    var amount: Double
    var income = false
    var merchant: String? = nil
    var category: String? = nil
    var date: String? = nil
    var accountType: String? = nil
    var tail: String? = nil
    var bank: String? = nil
    /// 自己账户间转账：(转出类型, 转入类型)，nil 表示不是转账；"?" 表示该端不确定
    var transfer: (String, String)? = nil
    var transferTail: String? = nil
    var toName: String? = nil
    var repay = false
}

func describeT(_ r: ParsedReceipt) -> String {
    r.isSelfTransfer ? " 转账 \(r.transferFrom?.type ?? r.transferFromName ?? "?")→\(r.transferTo?.type ?? r.transferToName ?? "?")" : ""
}

func verify(_ r: ParsedReceipt, _ e: W) -> [String] {
    var p: [String] = []
    if r.amount != e.amount { p.append("amount \(String(describing: r.amount))") }
    if e.transfer == nil, !e.repay, r.isIncome != e.income { p.append("income \(r.isIncome)") }
    if let m = e.merchant, r.merchant != m { p.append("merchant \(r.merchant ?? "nil")") }
    if let c = e.category, r.categoryName != c { p.append("category \(r.categoryName ?? "nil")") }
    if let d = e.date, fmt(r.date) != d { p.append("date \(fmt(r.date))") }
    if let t = e.accountType, r.accountHint?.type != t { p.append("account \(r.accountHint?.type ?? "nil")") }
    if let t = e.tail, r.accountHint?.cardTail != t { p.append("tail \(r.accountHint?.cardTail ?? "nil")") }
    if let b = e.bank, r.accountHint?.bankName != b { p.append("bank \(r.accountHint?.bankName ?? "nil")") }
    if e.repay != r.isCardRepayment { p.append("repay \(r.isCardRepayment)") }
    if let (from, to) = e.transfer {
        if !r.isSelfTransfer { p.append("不是转账") }
        let f = r.transferFrom?.type ?? "?", t = r.transferTo?.type ?? "?"
        if f != from { p.append("from \(f)") }
        if t != to { p.append("to \(t)") }
        if let tt = e.transferTail, (r.transferFrom?.cardTail ?? r.transferTo?.cardTail) != tt { p.append("transferTail") }
        if let n = e.toName, r.transferToName != n { p.append("toName \(r.transferToName ?? "nil")") }
    } else if r.isSelfTransfer { p.append("误判为转账") }
    return p
}

func checkW(_ name: String, _ lines: [String], _ e: W) {
    let r = ReceiptParser.parse(lines: lines, now: now, calendar: cal)
    let errs = verify(r, e)
    if errs.isEmpty { print("✅ \(name): ¥\(r.amount ?? -1) \(r.isIncome ? "收入" : "支出") \(r.merchant ?? "-") \(r.categoryName ?? "-") \(fmt(r.date)) \(r.accountHint?.type ?? "-")\(describeT(r))") }
    else { failures += 1; print("❌ \(name): " + errs.joined(separator: "; ")) }
}

func checkList(_ name: String, _ lines: [String], _ es: [W]) {
    let rs = ReceiptParser.parseAll(lines: lines, now: now, calendar: cal)
    var errs: [String] = []
    if rs.count != es.count { errs.append("count \(rs.count) != \(es.count)") }
    for (i, (r, e)) in zip(rs, es).enumerated() {
        let p = verify(r, e)
        if !p.isEmpty { errs.append("#\(i + 1): " + p.joined(separator: ", ")) }
    }
    if errs.isEmpty { print("✅ \(name): " + rs.map { "¥\($0.amount ?? -1)\($0.isIncome ? "+" : "")\(describeT($0))" }.joined(separator: " / ")) }
    else { failures += 1; print("❌ \(name): " + errs.joined(separator: "; ")) }
}

// --- 微信 · 中文 ---
checkW("微信支付成功", ["9:41", "微信支付", "支付成功", "¥26.00", "收款方", "示例面馆", "支付方式", "招商银行储蓄卡(1357)", "支付时间", "2026年10月17日 12:30:05", "完成"],
       W(amount: 26, merchant: "示例面馆", category: "餐饮", date: "2026-10-17 12:30", accountType: "debit", tail: "1357", bank: "招商银行"))
checkW("微信账单详情", ["账单详情", "示例便利店", "-12.50", "当前状态 支付成功", "支付时间 2026年10月17日 08:15:20", "商品 饮料",
                     "商户全称 示例便利店有限公司", "支付方式 零钱", "交易单号 4200001234567890123456789012", "商户单号 1234567890123"],
       W(amount: 12.5, merchant: "示例便利店有限公司", category: "购物", date: "2026-10-17 08:15", accountType: "wechat"))
checkW("微信转账（对方已收款）", ["转账", "¥200.00", "对方已收款", "转账时间 2026年10月16日 20:00:00", "收款时间 2026年10月16日 20:01:00"],
       W(amount: 200, date: "2026-10-16 20:00"))
checkW("微信转账（已收款）", ["已收款", "¥88.00", "转账时间 2026年10月16日 21:00:00", "收款时间 2026年10月16日 21:00:30", "已存入零钱"],
       W(amount: 88, income: true, date: "2026-10-16 21:00"))
checkW("微信转账（待对方收款）", ["待对方收款", "¥50.00", "转账时间 2026年10月17日 10:00:00"], W(amount: 50))
checkW("微信红包（收到）", ["微信红包", "示例同学的红包", "88.88元", "已存入零钱，可直接消费"], W(amount: 88.88, income: true, category: "红包"))
checkW("微信退款", ["账单详情", "示例商城", "+59.00", "当前状态 已全额退款", "退款时间 2026年10月17日 14:00:00", "退款方式 退回零钱"],
       W(amount: 59, income: true, category: "退款"))
checkW("微信零钱充值", ["账单详情", "零钱充值", "+500.00", "当前状态 充值成功", "充值时间 2026年10月17日 09:00:00", "充值银行 招商银行(1357)"],
       W(amount: 500, transfer: ("debit", "wechat"), transferTail: "1357"))
checkW("微信零钱提现", ["账单详情", "零钱提现", "-300.00", "当前状态 已到账", "提现银行 招商银行(1357)", "服务费 ¥0.30"],
       W(amount: 300, transfer: ("wechat", "debit"), transferTail: "1357"))
checkW("微信话费充值是支出", ["账单详情", "手机充值", "-50.00", "当前状态 充值成功", "支付方式 零钱"], W(amount: 50, category: "通讯", accountType: "wechat"))
checkList("微信账单列表", ["全部账单", "2026年10月", "支出 ¥1,234.00 收入 ¥500.00", "扫二维码付款-给示例水果店", "-15.80", "10月17日 18:20",
                         "示例打车", "-23.00", "10月17日 08:30", "零钱充值-来自招商银行", "+200.00", "10月16日 12:00"],
          [W(amount: 15.8, merchant: "示例水果店", date: "2026-10-17 18:20"), W(amount: 23, category: "交通", date: "2026-10-17 08:30"),
           W(amount: 200, transfer: ("debit", "wechat"))])

// --- 微信 · 英文 ---
checkW("WeChat 支付成功", ["9:41", "WeChat Pay", "Payment Successful", "¥26.00", "Payee", "Sample Noodle House", "Payment Method",
                         "China Merchants Bank Debit Card(1357)", "Payment Time", "Oct 17, 2026 12:30:05", "Done"],
       W(amount: 26, merchant: "Sample Noodle House", category: "餐饮", date: "2026-10-17 12:30", accountType: "debit", tail: "1357", bank: "招商银行"))
checkW("WeChat Transaction Details", ["Transaction Details", "Sample Mart", "-12.50", "Status", "Successful", "Payment Time", "2026-10-17 08:15:20",
                                      "Product", "Drinks", "Merchant Full Name", "Sample Convenience Store Co., Ltd.", "Payment Method", "Balance",
                                      "Transaction ID", "4200001234567890123456789012", "Merchant Order No.", "ABC123456789", "WeChat Pay"],
       W(amount: 12.5, merchant: "Sample Convenience Store", category: "购物", date: "2026-10-17 08:15", accountType: "wechat"))
checkW("WeChat Transfer 已被接收", ["Transfer", "¥200.00", "Received by recipient", "Transfer Time", "Oct 16, 2026 8:00 PM"],
       W(amount: 200, date: "2026-10-16 20:00"))
checkW("WeChat Transfer Received", ["Received", "¥88.00", "Transfer Time", "Oct 16, 2026 9:00 PM", "Received Time", "Oct 16, 2026 9:00 PM", "Deposited to Balance"],
       W(amount: 88, income: true, date: "2026-10-16 21:00"))
checkW("WeChat Transfer Pending", ["Transfer", "¥50.00", "Waiting for Sample Friend to accept", "Transfer Time", "Oct 17, 2026 10:00 AM"],
       W(amount: 50, date: "2026-10-17 10:00"))
checkW("WeChat Red Packet", ["Red Packet from Sample Friend", "88.88 CNY", "Deposited to Balance"], W(amount: 88.88, income: true, category: "红包"))
checkW("WeChat Refund", ["Transaction Details", "Sample Mall", "+59.00", "Status", "Refunded", "Refund Time", "Oct 17, 2026 2:00 PM", "Refund Method", "Balance"],
       W(amount: 59, income: true, category: "退款", date: "2026-10-17 14:00"))
checkW("WeChat Balance Top-up", ["WeChat Pay", "Transaction Details", "Balance Top-up", "+500.00", "Status", "Successful", "Top-up Bank", "China Merchants Bank(1357)"],
       W(amount: 500, transfer: ("debit", "wechat"), transferTail: "1357"))
checkW("WeChat Withdraw", ["Withdraw", "-300.00", "Status", "Credited", "Withdraw to", "CMB Debit Card(1357)", "Service Fee", "¥0.30", "WeChat Pay"],
       W(amount: 300, transfer: ("wechat", "debit"), transferTail: "1357"))
checkW("来源不明的 Balance Top-up：不猜钱包", ["Balance Top-up", "+500.00", "Successful", "Payment Method", "CMB Debit Card(1357)"],
       W(amount: 500, transfer: ("debit", "?")))
checkList("WeChat Bills", ["Bills", "Oct 2026", "Expenses ¥1,234.00 Income ¥500.00", "Sample Fruit Shop", "-15.80", "Oct 17 18:20",
                          "Sample Taxi", "-23.00", "Oct 17 8:30 AM", "Balance Top-up", "+200.00", "Oct 16 12:00"],
          [W(amount: 15.8, merchant: "Sample Fruit Shop", date: "2026-10-17 18:20"), W(amount: 23, category: "交通", date: "2026-10-17 08:30"),
           W(amount: 200, transfer: ("?", "?"))])
checkW("WeChat HK$ 7-Eleven", ["Payment Successful", "HK$38.00", "Merchant", "7-Eleven (Sample Branch) >", "Payment Method", "Balance", "WeChat Pay"],
       W(amount: 38, merchant: "7-Eleven (Sample Branch)", category: "购物", accountType: "wechat"))
checkW("WeChat Metro", ["Payment Successful", "¥3.00", "Merchant", "Sample City Metro", "WeChat Pay"], W(amount: 3, category: "交通"))

// --- 支付宝 · 中文 ---
checkW("支付宝账单详情（花呗）", ["账单详情", "示例咖啡", "-32.00", "交易成功", "支付时间 2026-10-17 15:20:11", "付款方式 花呗", "商品说明 拿铁",
                            "账单分类 餐饮美食", "订单号 2026101722001400000000000001", "商家订单号 T20261017000001"],
       W(amount: 32, category: "餐饮", date: "2026-10-17 15:20", accountType: "consumerCredit"))
checkW("支付宝余额付款", ["账单详情", "示例超市", "-88.00", "交易成功", "付款方式 余额", "账单分类 日用百货"],
       W(amount: 88, merchant: "示例超市", category: "购物", accountType: "alipay"))
checkW("支付宝平台分类兜底", ["账单详情", "示例小铺", "-15.00", "交易成功", "账单分类 交通出行"], W(amount: 15, merchant: "示例小铺", category: "交通"))
checkW("支付宝收款", ["账单详情", "示例朋友", "+66.00", "交易成功", "收款方式 余额", "转账备注 饭钱"], W(amount: 66, income: true))
checkW("支付宝退款", ["账单详情", "示例店铺", "+19.90", "退款成功", "退款方式 花呗"], W(amount: 19.9, income: true, category: "退款"))
checkW("支付宝充值", ["账单详情", "充值-余额", "+1,000.00", "交易成功", "付款方式 建设银行储蓄卡(2468)"],
       W(amount: 1000, transfer: ("debit", "alipay"), transferTail: "2468"))
checkW("支付宝提现", ["账单详情", "余额提现", "-500.00", "交易成功", "提现到 建设银行储蓄卡(2468)", "支付宝"],
       W(amount: 500, transfer: ("alipay", "debit"), transferTail: "2468"))
checkW("转入余额宝", ["账单详情", "转入余额宝", "-2,000.00", "交易成功", "付款方式 招商银行储蓄卡(1357)"],
       W(amount: 2000, transfer: ("debit", "?"), transferTail: "1357", toName: "余额宝"))
checkW("花呗还款", ["账单详情", "花呗还款", "-1,200.00", "还款成功", "付款方式 余额宝"], W(amount: 1200, repay: true))
checkList("支付宝账单列表", ["账单", "2026年10月", "支出 ¥2,000.00 收入 ¥100.00", "示例奶茶店", "-18.00", "今天 10:05", "示例地铁", "-4.00", "昨天 08:12",
                          "示例朋友", "+100.00", "10-16 19:30"],
          [W(amount: 18, category: "餐饮", date: "2026-10-18 10:05"), W(amount: 4, category: "交通", date: "2026-10-17 08:12"),
           W(amount: 100, income: true, date: "2026-10-16 19:30")])

// --- 支付宝 · 英文 ---
checkW("Alipay Bill Details（Huabei）", ["Bill Details", "Sample Coffee", "-32.00", "Successful", "Payment Time", "Oct 17, 2026 3:20 PM", "Payment Method",
                                       "Huabei", "Product Description", "Latte", "Category", "Food & Beverage", "Order No.",
                                       "2026101722001400000000000001", "Merchant Order No.", "T20261017000001", "Alipay"],
       W(amount: 32, category: "餐饮", date: "2026-10-17 15:20", accountType: "consumerCredit"))
checkW("Alipay Balance", ["Bill Details", "Sample Supermarket", "-88.00", "Completed", "Payment Method", "Balance", "Category", "Daily Necessities", "Alipay"],
       W(amount: 88, merchant: "Sample Supermarket", category: "购物", accountType: "alipay"))
checkW("Alipay Paid to（交通银行信用卡）", ["Alipay", "Paid", "CNY 45.60", "Paid to", "Sample Pharmacy", "Pay with",
                                        "Bank of Communications Credit Card (9753)", "Time", "17 Oct 2026 10:53"],
       W(amount: 45.6, merchant: "Sample Pharmacy", category: "医疗", date: "2026-10-17 10:53", accountType: "credit", tail: "9753", bank: "交通银行"))
checkW("Alipay Received", ["Bill Details", "Sample Friend", "+66.00", "Successful", "Received with", "Balance", "Alipay"], W(amount: 66, income: true))
checkW("Alipay Refund", ["Bill Details", "Sample Shop", "+19.90", "Refund Successful", "Refund Method", "Huabei", "Alipay"],
       W(amount: 19.9, income: true, category: "退款"))
checkW("Alipay Top Up", ["Bill Details", "Top Up - Balance", "+1,000.00", "Successful", "Payment Method", "CCB Debit Card(2468)", "Alipay"],
       W(amount: 1000, transfer: ("debit", "alipay"), transferTail: "2468"))
checkW("Alipay Withdraw", ["Bill Details", "Withdraw", "-500.00", "Successful", "Withdraw to", "CCB Debit Card(2468)", "Alipay"],
       W(amount: 500, transfer: ("alipay", "debit"), transferTail: "2468"))
checkW("Alipay Yu'e Bao", ["Bill Details", "Transfer to Yu'e Bao", "-2,000.00", "Successful", "Payment Method", "CMB Debit Card(1357)", "Alipay"],
       W(amount: 2000, transfer: ("debit", "?"), transferTail: "1357", toName: "余额宝"))
checkW("Alipay Huabei Repayment", ["Bill Details", "Huabei Repayment", "-1,200.00", "Successful", "Payment Method", "Yu'e Bao", "Alipay"],
       W(amount: 1200, repay: true))
checkList("Alipay Bills", ["Bills", "Oct 2026", "Expenses ¥2,000.00 Income ¥100.00", "Sample Milk Tea", "-18.00", "Today 10:05", "Sample Metro", "-4.00",
                          "Yesterday 08:12", "Sample Friend", "+100.00", "Oct 16 7:30 PM", "Alipay"],
          [W(amount: 18, category: "餐饮", date: "2026-10-18 10:05"), W(amount: 4, category: "交通", date: "2026-10-17 08:12"),
           W(amount: 100, income: true, date: "2026-10-16 19:30")])
checkList("Alipay Bills（名称与金额同一行）", ["Bills", "Sample Bakery -9.90", "Oct 17 07:50", "Sample Bus Line -2.00", "Oct 17 08:00"],
          [W(amount: 9.9, merchant: "Sample Bakery", category: "餐饮", date: "2026-10-17 07:50"), W(amount: 2, date: "2026-10-17 08:00")])
checkW("Alipay Taobao", ["Bill Details", "Taobao - Sample Store", "-129.00", "Successful", "Alipay"], W(amount: 129, category: "购物"))

do {
    let r = ReceiptParser.parse(lines: ["Bill Details", "Withdraw", "-500.00", "Successful", "Withdraw to", "CCB Debit Card(2468)", "Alipay"], now: now, calendar: cal)
    if r.transferTo?.bankName == "建设银行" { print("✅ 提现到账银行只取银行名") } else { failures += 1; print("❌ 提现到账银行：\(r.transferTo?.bankName ?? "nil")") }
}

// --- 金额写法 / 商户关键词 ---
for (raw, want) in [("-¥26.00", 26.0), ("¥ 26.00", 26), ("RMB26.00", 26), ("HK$26.00", 26), ("26.00 CNY", 26), ("CNY 1,026.50", 1026.5)] {
    checkW("金额写法 \(raw)", ["Payment Successful", raw, "Merchant", "Sample Cafe"], W(amount: want, merchant: "Sample Cafe", category: "餐饮"))
}
for (merchant, cat) in [("Starbucks (Sample Plaza)", "餐饮"), ("McDonald's Sample Rd", "餐饮"), ("KFC Sample Store", "餐饮"), ("Meituan", "餐饮"),
                        ("DiDi Chuxing", "交通"), ("Didi", "交通"), ("MTR", "交通"), ("Taobao", "购物"), ("JD.com", "购物"), ("Pinduoduo", "购物"),
                        ("7-Eleven", "购物"), ("FamilyMart", "购物"), ("China Mobile", "通讯"), ("Trip.com", "旅行")] {
    checkW("关键词 \(merchant)", ["Payment Successful", "-¥10.00", "Merchant", merchant], W(amount: 10, merchant: merchant, category: cat))
}
for text in ["Small Shop", "Fetch Store", "JDK Studio"] {
    let c = CategoryGuesser.guess(text: text, isIncome: false)
    if c == nil { print("✅ 整词匹配：\(text) 无分类") } else { failures += 1; print("❌ 整词匹配：\(text) → \(c!)") }
}

// --- 订单号不能当金额 / 尾号 ---
checkW("订单号不当金额（标签与值分行）", ["Bill Details", "Sample Shop", "Order No.", "20261017123", "-8.00", "Transaction ID", "1234", "Payment Method", "Balance", "Alipay"],
       W(amount: 8, accountType: "alipay"))
do {
    let r = ReceiptParser.parse(lines: ["账单详情", "示例店", "-8.00", "订单号 2026101722001400001357", "付款方式 招商银行储蓄卡"], now: now, calendar: cal)
    if r.accountHint?.cardTail == nil { print("✅ 订单号末 4 位不当尾号") } else { failures += 1; print("❌ 订单号末 4 位被当成尾号") }
}

// --- 本地化 / 来源识别 ---
for (raw, want) in [("Oct 21, 2026 10:53", "2026-10-21 10:53"), ("21 Oct 2026", "2026-10-21"), ("Oct 2026", "2026年10月"),
                    ("Today 3:25 PM", "今天 15:25"), ("Oct 17 12:05 AM", "10月17日 00:05"), ("2026-10-21 10:53:12", "2026-10-21 10:53:12"),
                    ("Payment Method", "付款方式"), ("China Merchants Bank Debit Card (1234)", "招商银行储蓄卡 (1234)"),
                    ("CMB Credit Card(1234)", "招商银行信用卡(1234)"), ("Yu'e Bao", "余额宝"), ("Huabei", "花呗"), ("Starbucks", "Starbucks")] {
    let got = PaymentTerms.localize(raw, app: .unknown)
    if got == want { print("✅ 本地化 \(raw) → \(got)") } else { failures += 1; print("❌ 本地化 \(raw) → \(got)（应为 \(want)）") }
}
for (app, want) in [(PaymentApp.wechat, "零钱"), (.alipay, "账户余额")] {
    let got = PaymentTerms.localize("Balance", app: app)
    if got == want { print("✅ Balance（\(app.title)）→ \(got)") } else { failures += 1; print("❌ Balance（\(app.title)）→ \(got)") }
}
for (lines, app, english) in [(["微信支付", "支付成功", "¥1.00"], PaymentApp.wechat, false), (["WeChat Pay", "Payment Successful", "¥1.00", "Payment Method", "Balance"], .wechat, true),
                              (["支付宝", "账单详情"], .alipay, false), (["Bill Details", "Payment Method", "Huabei", "Alipay"], .alipay, true),
                              (["云闪付", "还款"], .unionpay, false), (["【招商银行】您账户1234于10月12日消费人民币45.60元"], .bank, false),
                              (["示例", "¥1.00"], .unknown, false)] {
    let s = PaymentScreenDetector.detect(lines)
    if s.app == app && s.english == english { print("✅ 来源 \(s.tag)") } else { failures += 1; print("❌ 来源 \(s.tag)（应为 \(app.title)·\(english ? "英文" : "中文")）") }
}


// ===== 2.0 (6)：云闪付 / 订单金额 vs 实付（全部为自造的合成数据）=====
checkW("云闪付 中英混合 实付优先",
       ["云闪付交易详情", "示例青秀区清风坊餐饮店", "-¥14.96", "优惠信息", "满2随机立减-¥0.04",
        "Current Status", "Transaction Successful", "Order Amount", "¥15.00",
        "Payment Method", "CMB Debit card[5858]", "Order Time", "2026.10.17 13:45:43"],
       W(amount: 14.96, merchant: "示例青秀区清风坊餐饮店", category: "餐饮",
         date: "2026-10-17 13:45", accountType: "debit", tail: "5858", bank: "招商银行"))
do {
    let r = ReceiptParser.parse(lines: ["云闪付交易详情", "示例青秀区清风坊餐饮店", "-¥14.96", "优惠信息", "满2随机立减-¥0.04",
                                        "Order Amount", "¥15.00", "Payment Method", "CMB Debit card[5858]",
                                        "Order Time", "2026.10.17 13:45:43"], now: now, calendar: cal)
    if r.discountNote == "随机立减 0.04" { print("✅ 云闪付优惠备注：\(r.discountNote!)") }
    else { failures += 1; print("❌ 云闪付优惠备注：\(r.discountNote ?? "nil")") }
}
checkW("支付宝 订单金额 vs 实付",
       ["账单详情", "示例面馆", "交易成功", "实付 ¥28.50", "订单金额 ¥30.00", "优惠 -¥1.50",
        "付款方式 余额", "支付时间 2026-10-17 12:00:00"],
       W(amount: 28.5, merchant: "示例面馆", category: "餐饮", date: "2026-10-17 12:00", accountType: "alipay"))
checkW("微信 大字实付优先于订单金额",
       ["微信支付", "支付成功", "示例咖啡馆", "-¥19.90", "订单金额 ¥20.00", "优惠立减 ¥0.10",
        "支付方式 零钱", "支付时间 2026年10月17日 09:10:00"],
       W(amount: 19.9, merchant: "示例咖啡馆", category: "餐饮", date: "2026-10-17 09:10", accountType: "wechat"))
checkW("云闪付 英文 Payment Method 括号尾号",
       ["云闪付", "示例便利店", "-¥8.00", "Transaction Successful", "Order Amount ¥8.00",
        "Payment Method", "CMB Debit Card (4242)", "Order Time", "2026.10.17 18:00:00"],
       W(amount: 8, merchant: "示例便利店", category: "购物", date: "2026-10-17 18:00",
         accountType: "debit", tail: "4242", bank: "招商银行"))
// 仅有订单金额、无实付时仍取订单金额
checkW("仅订单金额",
       ["账单详情", "示例潮玩店", "订单金额 ¥45.00", "交易成功", "付款方式 零钱"],
       W(amount: 45, merchant: "示例潮玩店", accountType: "wechat"))

// --- 商户清理（英文 / 箭头 / 省略号 / 微信标题前缀）---
for (raw, want) in [("Sample Shop >", "Sample Shop"), ("Merchant: Sample Cafe", "Sample Cafe"), ("示例便利店…", "示例便利店"),
                    ("Sample Store...", "Sample Store"), ("扫二维码付款-给示例水果店", "示例水果店"), ("Sample Foods Co., Ltd.", "Sample Foods"),
                    ("示例科技有限公司", "示例科技有限公司")] {
    let got = ReceiptParser.cleanMerchant(raw)
    if got == want { print("✅ 商户清理 \(raw) → \(got)") } else { failures += 1; print("❌ 商户清理 \(raw) → \(got)") }
}


// ===== 2.0 (7)：四种版式（全部为合成数据：示例商户 / 示例金额 / 尾号 8831）=====
func expect(_ ok: Bool, _ msg: String) {
    if ok { print("✅ \(msg)") } else { failures += 1; print("❌ \(msg)") }
}
let df7 = DateFormatter(); df7.timeZone = cal.timeZone; df7.dateFormat = "yyyy-MM-dd HH:mm"
func d7(_ d: Date?) -> String { d.map { df7.string(from: $0) } ?? "nil" }
func scr7(_ l: [String]) -> PaymentScreen { ReceiptParser.screen(l.map { OCRLine($0) }) }

// A. 银行公众号推送列表
let pushA = ["11:19", "浦发银行信用卡", "「积分当钱花」示例活动开兑!", "星期四 下午4:23", "交易提醒", "银行卡号: 尾号8831",
             "交易时间: 10月15日 16:23", "交易类型: 消费", "交易金额: 人民币23.45元", "商户名称: 美团-示例鲜品科技有限公司", "查看详情 >",
             "上午8:08", "交易提醒", "银行卡号: 尾号8831", "交易时间: 10月18日 08:08", "交易类型: 消费", "交易金额: 人民币12.34元",
             "商户名称: 美团-示例牛肉饭(示例大厦…", "查看详情 >", "账户服务 借钱额度 还款福利"]
let rA = ReceiptParser.parseAll(lines: pushA, now: now, calendar: cal)
expect(scr7(pushA).tag == "银行公众号", "A 银行公众号：版式识别")
expect(rA.count == 2, "A 银行公众号：两张交易提醒 → 2 笔（横幅 / 菜单不算）")
if rA.count == 2 {
    expect(rA[0].amount == 23.45 && !rA[0].isIncome && rA[0].merchant == "示例鲜品科技有限公司" && rA[0].discountNote == "美团"
           && d7(rA[0].date) == "2026-10-15 16:23", "A 第 1 笔：金额 / 商户去平台前缀 / 平台进备注 / 交易时间")
    expect(rA[1].amount == 12.34 && rA[1].merchant == "示例牛肉饭" && rA[1].categoryName == "餐饮" && d7(rA[1].date) == "2026-10-18 08:08",
           "A 第 2 笔：截断的分店名去掉、分类餐饮")
    expect(rA.allSatisfy { $0.accountHint?.bankName == "浦发银行" && $0.accountHint?.type == "credit" && $0.accountHint?.cardTail == "8831" && !$0.isCardRepayment },
           "A 账户：标题浦发银行信用卡 + 尾号 8831；菜单「还款福利」不算还款")
}
let pushRefund = ["浦发银行信用卡", "交易提醒", "银行卡号: 尾号8831", "交易时间: 10月16日 10:00", "交易类型: 退货",
                  "交易金额: 人民币12.34元", "商户名称: 美团-示例牛肉饭"]
let rAr = ReceiptParser.parseAll(lines: pushRefund, now: now, calendar: cal)
expect(rAr.count == 1 && rAr[0].isIncome && rAr[0].categoryName == "退款", "A 交易类型 退货 → 退款收入")
let pushRepay = ["浦发银行信用卡", "交易提醒", "银行卡号: 尾号8831", "交易时间: 10月16日 10:00", "交易类型: 还款",
                 "交易金额: 人民币880.00元"]
let rArp = ReceiptParser.parseAll(lines: pushRepay, now: now, calendar: cal)
expect(rArp.count == 1 && rArp[0].isCardRepayment && rArp[0].repaymentCard?.cardTail == "8831" && rArp[0].repaymentCard?.bankName == "浦发银行",
       "A 交易类型 还款 → 信用卡还款（被还卡浦发尾号 8831）")
let pushFuture = ["浦发银行信用卡", "交易提醒", "银行卡号: 尾号8831", "交易时间: 12月25日 10:00", "交易类型: 消费",
                  "交易金额: 人民币23.45元", "商户名称: 示例书店"]
expect(d7(ReceiptParser.parseAll(lines: pushFuture, now: now, calendar: cal).first?.date) == "2025-12-25 10:00", "A 未来日期退回去年")

// B. 微信聊天转账气泡
let chatB = ["有空再弄吧", "昨天 晚上7:00", "等你消息", "昨天 晚上7:10", "¥880.00", "已收款", "转账", "好了吗?给你3个", "还没",
             "昨天 晚上7:23", "按住 说话"]
let rB = ReceiptParser.parseAll(lines: chatB, now: now, calendar: cal)
expect(scr7(chatB).tag == "微信聊天转账", "B 聊天转账：版式识别")
expect(rB.count == 1 && rB[0].amount == 880 && rB[0].isIncome && rB[0].categoryName == "其他收入"
       && rB[0].accountHint?.type == "wechat" && d7(rB[0].date) == "2026-10-17 19:10",
       "B 已收款 → 收入 880 / 其他收入 / 微信零钱 / 昨天 19:10（聊天里的数字不算）")
let chatOut = ["星期四 下午4:23", "¥34.56", "已被接收", "转账", "收到"]
let rBo = ReceiptParser.parseAll(lines: chatOut, now: now, calendar: cal)
expect(rBo.count == 1 && !rBo[0].isIncome && rBo[0].amount == 34.56 && d7(rBo[0].date) == "2026-10-15 16:23", "B 已被接收 → 支出、星期四 16:23")
let chatPending = ["9:18", "示例好友", "08:30", "¥12.34", "请收款", "微信转账"]
let rBp = ReceiptParser.parseAll(lines: chatPending, now: now, calendar: cal)
expect(rBp.count == 1 && rBp[0].isIncome && rBp[0].discountNote == "待收款" && d7(rBp[0].date) == "2026-10-18 08:30", "B 请收款 → 仍记一笔，备注待收款")
let chatDetail = ["转账", "¥880.00", "已收款", "转账时间 2026年10月17日 19:10:00", "收款时间 2026年10月17日 19:11:00"]
expect(scr7(chatDetail).layout != .chatTransfer, "B 转账详情页不按聊天气泡处理")

// C. 微信支付助手卡片
let payC = ["9:18", "搜索消息号", "服务通知 支付消息 精彩动态", "08:30", "支付助手", "付款成功", "¥34.56",
            "交易对象 示例煲仔饭(示例大厦店)", "交易账户 浦发银行银联信用卡[8831]", "See details >",
            "Yesterday 19:15", "支付助手", "付款成功", "¥7.80", "交易对象 示例便利店", "交易账户 浦发银行银联信用卡[8831]"]
let rC = ReceiptParser.parseAll(lines: payC, now: now, calendar: cal)
expect(scr7(payC).tag == "支付助手", "C 支付助手：版式识别（不当成云闪付）")
expect(rC.count == 2, "C 两张卡片 → 2 笔（标签 / 搜索不算）")
if rC.count == 2 {
    expect(rC[0].amount == 34.56 && rC[0].merchant == "示例煲仔饭(示例大厦店)" && d7(rC[0].date) == "2026-10-18 08:30"
           && rC[0].accountHint?.bankName == "浦发银行" && rC[0].accountHint?.type == "credit" && rC[0].accountHint?.cardTail == "8831",
           "C 第 1 笔：交易对象 / 单独的 08:30 = 今天 / 浦发信用卡尾号 8831")
    expect(rC[1].amount == 7.8 && rC[1].merchant == "示例便利店" && d7(rC[1].date) == "2026-10-17 19:15", "C 第 2 笔：Yesterday 19:15")
}
let payLate = ["支付消息", "服务通知", "23:50", "支付助手", "付款成功", "¥12.34", "交易对象 示例书店"]
expect(d7(ReceiptParser.parseAll(lines: payLate, now: now, calendar: cal).first?.date) == "2026-10-17 23:50", "C 标题时间晚于现在 → 昨天")

// D. 云闪付英文 Transaction details
let upD = ["9:18", "Transaction details", "美团", "-¥34.56", "Discount Info UnionPay Discount-¥5.67", "Payee 示例煲仔饭(示例大厦店)",
           "Card Number SPDBCredit card[8831]", "Transaction Time 2026-10-17 11:08:41", "Order amount ¥40.23",
           "Transaction Category Consumption", "Category Other Categories-Other", "Payment Network UnionPay", "More",
           "Transactions at this merchant", "Go to Repay", "快捷管理银行卡 一键查"]
let upD2 = ["9:18", "Transaction details", "美团", "-¥34.56", "Discount Info", "UnionPay Discount-¥5.67", "Payee", "示例煲仔饭(示例大厦店)",
            "Card Number", "SPDBCredit card[8831]", "Transaction", "Time 2026-10-17 11:08:41", "Order amount", "¥40.23",
            "Transaction", "Category Consumption", "More", "Go to Repay"]
for (name, l) in [("D 单行", upD), ("D 分行", upD2)] {
    let r = ReceiptParser.parseAll(lines: l, now: now, calendar: cal)
    expect(r.count == 1 && r[0].amount == 34.56 && !r[0].isIncome && !r[0].isCardRepayment && r[0].merchant == "示例煲仔饭(示例大厦店)"
           && r[0].discountNote == "美团 · 云闪付立减 5.67" && r[0].categoryName == "餐饮" && d7(r[0].date) == "2026-10-17 11:08"
           && r[0].accountHint?.bankName == "浦发银行" && r[0].accountHint?.type == "credit" && r[0].accountHint?.cardTail == "8831",
           "\(name)：实付 34.56（非订单金额）/ Payee 商户 / 美团+立减进备注 / SPDBCredit → 浦发信用卡 / Go to Repay 不算还款")
}
expect(scr7(upD).tag == "云闪付·英文", "D 诊断标签：云闪付·英文")
expect(EnglishBankTerms.splitGlued("CMBDebit card[1234]") == "CMB Debit card[1234]", "粘连银行代码：CMBDebit → CMB Debit")
expect(AccountHintParser.parse(text: "浦发银行银联信用卡[8831]")?.cardTail == "8831", "交易账户 浦发银行银联信用卡[8831] → 尾号")

// 平台前缀
for (raw, m, p) in [("美团-示例牛肉饭", "示例牛肉饭", "美团"), ("饿了么-示例粥铺", "示例粥铺", "饿了么"), ("Meituan-示例面馆", "示例面馆", "美团"),
                    ("京东-示例数码", "示例数码", "京东"), ("示例便利店", "示例便利店", nil)] as [(String, String, String?)] {
    let got = ReceiptParser.splitPlatform(raw)
    expect(got.merchant == m && got.platform == p, "平台前缀 \(raw) → \(got.merchant) / \(got.platform ?? "无")")
}

// 跨截图查重：同一笔 34.56 的银行推送 + 支付助手 + 云闪付详情 → 后两张为重复
let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 11, minute: 8))!
let shots: [DuplicateMatcher.Entry] = [
    .init(amount: 34.56, merchant: "示例煲仔饭(示例大厦…", date: base, account: "pf8831"),
    .init(amount: 34.56, merchant: "示例煲仔饭(示例大厦店)", date: base.addingTimeInterval(60), account: "pf8831"),
    .init(amount: 34.56, merchant: "示例煲仔饭(示例大厦店)", date: base.addingTimeInterval(41), account: "pf8831"),
]
var seen7: [DuplicateMatcher.Entry] = []
var dupFlags: [Bool] = []
for e in shots { dupFlags.append(DuplicateMatcher.isDuplicate(e, among: seen7)); seen7.append(e) }
expect(dupFlags == [false, true, true], "查重：同一笔三张截图 → 记 1 笔、2 笔标重复")
expect(DuplicateMatcher.matches(.init(amount: 12.34, merchant: "美团-示例牛肉饭", date: base, account: nil),
                                .init(amount: 12.34, merchant: "示例牛肉饭(示例大厦店)", date: base.addingTimeInterval(240), account: "pf8831")),
       "查重：平台前缀 / 分店不同、4 分钟内、一侧无账户 → 重复")
expect(!DuplicateMatcher.matches(.init(amount: 34.56, merchant: "示例煲仔饭", date: base, account: "pf8831"),
                                 .init(amount: 34.56, merchant: "示例煲仔饭", date: base.addingTimeInterval(200), account: "cmb1234")),
       "查重：不同账户 → 不算重复")
expect(!DuplicateMatcher.matches(.init(amount: 34.56, merchant: "示例煲仔饭", date: base, account: "pf8831"),
                                 .init(amount: 34.56, merchant: "示例书店", date: base.addingTimeInterval(100), account: "pf8831")),
       "查重：商户明显不同 → 不算重复")
expect(!DuplicateMatcher.matches(.init(amount: 34.56, merchant: "示例煲仔饭", date: base, account: "pf8831"),
                                 .init(amount: 34.56, merchant: "示例煲仔饭", date: base.addingTimeInterval(900), account: "pf8831")),
       "查重：相隔 15 分钟 → 不算重复")
expect(DuplicateMatcher.matches(.init(amount: 30, merchant: "示例面馆", date: base, account: nil),
                                .init(amount: 30, merchant: "示例面馆", date: base.addingTimeInterval(90), account: nil)),
       "查重：旧规则（同商户 2 分钟内）仍有效")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
