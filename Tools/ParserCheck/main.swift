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

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
