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

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
