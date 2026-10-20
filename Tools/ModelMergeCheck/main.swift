// Apple 智能结果校验 / 合并测试（模拟模型输出，合成数据）
// swiftc Ledger/OCR/ReceiptParser.swift Ledger/OCR/ModelMerge.swift Tools/ModelMergeCheck/main.swift
import Foundation

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 9))!
var failures = 0
func check(_ ok: Bool, _ msg: String) {
    print((ok ? "✅ " : "❌ ") + msg)
    if !ok { failures += 1 }
}
func fmt(_ d: Date?) -> String {
    guard let d else { return "nil" }
    let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: d)
}

let expenseCats = ["餐饮", "交通", "购物", "娱乐", "生活缴费", "其他"]
let incomeCats = ["工资", "红包", "退款", "其他收入"]
let accounts = ["微信", "支付宝", "招商银行储蓄卡", "招行信用卡", "交通银行信用卡"]
func ctx(_ lines: [String]) -> ModelMerge.Context {
    .init(lines: lines, categories: expenseCats + incomeCats, incomeCategories: incomeCats, accounts: accounts, now: now, calendar: cal)
}

// 1. 微信两笔（合成）：模型结果有效 → 使用模型，分类 / 账户对齐到用户列表，日期用现有解析器
let wechat = ["9:41", "微信支付", "昨天 下午3:25", "阿芳", "¥18.00", "零钱", "昨天 晚上8:12", "华南畅行高速科技有限公司", "¥46.00",
              "交通银行信用卡(7316)", "零钱余额 ¥1,234.56"]
let rules1 = ReceiptParser.parseAll(lines: wechat, now: now, calendar: cal)
let m1 = [
    ModelTransaction(amount: 18, kind: "expense", merchant: "阿芳", categoryName: "餐饮", accountHint: "微信", dateText: "昨天 下午3:25"),
    ModelTransaction(amount: 46, kind: "expense", merchant: "华南畅行高速科技有限公司", categoryName: "交通出行",
                     accountHint: "交通银行信用卡", dateText: "昨天 晚上8:12"),
]
let o1 = ModelMerge.merge(model: m1, rules: rules1, ctx: ctx(wechat))
check(o1.engine == .appleIntelligence && o1.receipts.count == 2, "有效模型结果 → Apple 智能（\(o1.engine.title)，\(o1.receipts.count) 笔）")
check(o1.receipts.first?.date.map(fmt) == "2026-10-17 15:25", "日期由现有解析器解析模型日期文字：\(fmt(o1.receipts.first?.date))")
check(o1.receipts.last?.categoryName == "交通", "分类「交通出行」对齐到用户分类「交通」：\(o1.receipts.last?.categoryName ?? "nil")")
check(o1.receipts.last?.accountName == "交通银行信用卡", "账户对齐到用户账户")
check(o1.receipts.allSatisfy { $0.engine == .appleIntelligence }, "每笔都标注引擎")

// 2. 模型编造金额（余额不算；99 不在原文）→ 丢弃；规则更多 → 用规则
let m2 = [ModelTransaction(amount: 99, kind: "expense", merchant: "阿芳")]
let o2 = ModelMerge.merge(model: m2, rules: rules1, ctx: ctx(wechat))
check(o2.engine == .rules && o2.dropped == 1 && o2.fallbackReason != nil, "金额不在原文 → 丢弃并回退规则（\(o2.fallbackReason ?? "")）")

// 3. 部分编造：1 笔有效 1 笔编造，规则有 2 笔 → 规则
let m3 = [m1[0], ModelTransaction(amount: 460, kind: "expense", merchant: "华南畅行")]
let o3 = ModelMerge.merge(model: m3, rules: rules1, ctx: ctx(wechat))
check(o3.engine == .rules && o3.receipts.count == rules1.count, "有编造且规则笔数更多 → 规则（\(o3.receipts.count) 笔）")

// 4. 模型把「零钱余额 ¥1,234.56」当成交易：数字虽在原文，但只出现在余额行 → 丢弃；其余 2 笔与规则笔数相同 → 仍用模型
let o4 = ModelMerge.merge(model: m1 + [ModelTransaction(amount: 1234.56, kind: "expense", merchant: "零钱")], rules: rules1, ctx: ctx(wechat))
check(o4.dropped == 1 && o4.engine == .appleIntelligence && o4.receipts.count == 2, "余额行金额被丢弃（dropped \(o4.dropped)，\(o4.engine.title) \(o4.receipts.count) 笔）")
check(ModelMerge.merge(model: m1, rules: rules1, ctx: ctx(wechat)).dropped == 0, "无编造时 dropped = 0")

// 4b. 银行短信：交易金额与余额同一行 → 交易金额有效，余额无效
let sms = ["【招商银行】您账户6688于10月17日20:12消费人民币46.00元，余额2,000.00元。"]
check(!ModelMerge.onlyInBalanceLines(46, lines: sms), "短信同一行：消费 46.00 有效")
check(ModelMerge.onlyInBalanceLines(2000, lines: sms), "短信同一行：余额 2,000.00 无效")
let o4b = ModelMerge.merge(model: [ModelTransaction(amount: 46, kind: "expense", merchant: "招商银行", dateText: "10月17日20:12")],
                           rules: ReceiptParser.parseAll(lines: sms, now: now, calendar: cal), ctx: ctx(sms))
check(o4b.engine == .appleIntelligence && o4b.receipts.first.flatMap { $0.date }.map(fmt) == "2026-10-17 20:12", "短信：模型结果有效，日期 \(fmt(o4b.receipts.first?.date))")

// 5. 千分位金额与全角符号
check(ModelMerge.amountAppears(1234.56, in: "余额 ￥1,234.56"), "千分位 / 全角货币符号金额可匹配")
check(!ModelMerge.amountAppears(12.3, in: "¥123.00"), "12.3 不能匹配 123.00")
check(ModelMerge.amountAppears(3000, in: "-3,000.00"), "-3,000.00 匹配 3000")
check(!ModelMerge.amountAppears(0, in: "0.00"), "金额 0 无效")

// 6. 收款 / 退款语义
let recv = ["二维码收款到账", "+¥58.00", "付款方 张三", "今天 上午10:02"]
let o6 = ModelMerge.merge(model: [ModelTransaction(amount: 58, kind: "income", merchant: "张三", categoryName: "其他收入", dateText: "今天 上午10:02")],
                          rules: ReceiptParser.parseAll(lines: recv, now: now, calendar: cal), ctx: ctx(recv))
check(o6.receipts.first?.isIncome == true && o6.receipts.first?.categoryName == "其他收入", "收款 → 收入")
let refund = ["退款成功", "¥99.00", "退款方式 原路退回 花呗"]
let o7 = ModelMerge.merge(model: [ModelTransaction(amount: 99, kind: "expense", merchant: "某电商", isRefund: true)],
                          rules: ReceiptParser.parseAll(lines: refund, now: now, calendar: cal), ctx: ctx(refund))
check(o7.receipts.first?.isIncome == true && o7.receipts.first?.categoryName == "退款", "isRefund → 收入 · 退款")

// 7. 信用卡还款：卡名对齐，付款方式来自规则拆分
let repay = ["信用卡还款", "-3,000.00", "交易成功", "还款到 招商银行信用卡(1024)", "付款方式 招商银行储蓄卡(6688)"]
let o8 = ModelMerge.merge(model: [ModelTransaction(amount: 3000, kind: "cardRepayment", merchant: "招商银行", accountHint: "招行信用卡")],
                          rules: ReceiptParser.parseAll(lines: repay, now: now, calendar: cal), ctx: ctx(repay))
let r8 = o8.receipts.first
check(r8?.isCardRepayment == true && r8?.repaymentCardName == "招行信用卡" && r8?.categoryName == "信用卡还款", "信用卡还款 → 还款，卡名对齐")
check(r8?.repaymentCard?.cardTail == "1024" && r8?.accountHint?.cardTail == "6688", "还款的卡 / 付款账户线索来自原文")

// 8. 自有账户转账跳过；模型返回 nil（不可用）→ 规则并带原因
let o9 = ModelMerge.merge(model: [ModelTransaction(amount: 1000, kind: "transfer", merchant: "零钱通")], rules: [], ctx: ctx(["转入零钱通", "¥1000.00"]))
check(o9.skippedTransfers == 1 && o9.receipts.isEmpty, "账户间转账跳过")
let o10 = ModelMerge.merge(model: nil, rules: rules1, ctx: ctx(wechat), unavailableReason: "设备不支持 Apple 智能")
check(o10.engine == .rules && o10.receipts == rules1 && o10.fallbackReason == "设备不支持 Apple 智能", "模型不可用 → 规则结果原样返回")

// 9. 空结果 / 重复
let o11 = ModelMerge.merge(model: [], rules: rules1, ctx: ctx(wechat))
check(o11.engine == .rules && o11.receipts.count == rules1.count, "模型返回空 → 规则")
let o12 = ModelMerge.merge(model: [m1[0], m1[0], m1[1]], rules: rules1, ctx: ctx(wechat))
check(o12.engine == .appleIntelligence && o12.receipts.count == 2 && o12.dropped == 1, "重复项去重")

// 10. 未知账户 / 分类不在列表 → 关键词兜底
let o13 = ModelMerge.merge(model: [ModelTransaction(amount: 46, kind: "expense", merchant: "滴滴出行", categoryName: "出租车", accountHint: "未知")],
                           rules: [], ctx: ctx(["滴滴出行", "¥46.00"]))
check(o13.receipts.first?.accountName == nil && o13.receipts.first?.categoryName == "交通", "未知账户为 nil，分类不在列表时用关键词兜底：\(o13.receipts.first?.categoryName ?? "nil")")

// 11. 提示词：带行号、位置、大字标记，且有长度上限
let p = ModelMerge.promptText([OCRLine("¥18.00", midY: 0.31, height: 0.05), OCRLine("阿芳", midY: 0.25, height: 0.02)])
check(p.contains("L01 y=0.31 大字 | ¥18.00") && p.contains("L02 y=0.25 | 阿芳"), "提示词包含行号 / 位置")
let long = ModelMerge.promptText((0..<500).map { OCRLine("第\($0)行 一些文字") }, maxChars: 300)
check(long.count <= 300, "提示词截断（\(long.count) 字）")
let ins = ModelMerge.instructions(categories: expenseCats + incomeCats, incomeCategories: incomeCats, accounts: accounts)
check(ins.contains("对方已收款") && ins.contains("招行信用卡") && !ins.contains("支出分类中选：餐饮、交通、购物、娱乐、生活缴费、其他、工资"), "指令包含语义说明与用户列表")

// 12. 不得 trap：长数字串（订单号）、极端金额、重复名称、垃圾日期（全部为合成数据）
// 曾经：OCR 里 28 位订单号 → Double → ×100 → Int 溢出，Swift 运行时 trap（SIGTRAP），快捷指令「意外退出」
let orderLines = ["账单详情", "-144.43", "交易成功", "订单号", "2026102022001400000000000001",
                  "商户单号 9999999999999999999999999999999999", "流水 1234567890123456789.12",
                  "1,234,567,890,123,456,789.00", String(repeating: "9", count: 400)]
let edge1 = ModelMerge.merge(model: [ModelTransaction(amount: 144.43000000001, kind: "expense", merchant: "", dateText: "")],
                             rules: [], ctx: ctx(orderLines))
check(edge1.engine == .appleIntelligence && edge1.receipts.count == 1 && edge1.receipts.first?.amount == 144.43,
      "长订单号不 trap，144.43000000001 → 144.43")
let weird: [Double] = [-144.43, 0, -0.0, .nan, -.nan, .infinity, -.infinity, 1e20, -1e20, .greatestFiniteMagnitude,
                       .leastNonzeroMagnitude, 99_999_999.99, 100_000_000, 1e15, 9.2e16]
let edge2 = ModelMerge.merge(model: weird.map { ModelTransaction(amount: $0, kind: "expense") }, rules: [], ctx: ctx(orderLines))
check(edge2.receipts.allSatisfy { ($0.amount ?? 0).isFinite } && edge2.dropped == weird.count, "异常金额全部丢弃，不 trap（丢弃 \(edge2.dropped)）")
check(ModelMerge.cents(.nan) == nil && ModelMerge.cents(.infinity) == nil && ModelMerge.cents(1e300) == nil
      && ModelMerge.cents(-1e300) == nil && ModelMerge.cents(144.43000000001) == 14443, "cents 安全换算")
check(!ModelMerge.amountAppears(.nan, in: "nan") && !ModelMerge.amountAppears(1e30, in: "1000000000000000000000000000000"),
      "amountAppears 拒绝异常值")
check(!ModelMerge.onlyInBalanceLines(.nan, lines: orderLines) && !ModelMerge.onlyInBalanceLines(1e30, lines: ["余额 " + String(repeating: "9", count: 40)]),
      "onlyInBalanceLines 不 trap")
let nums = ModelMerge.numbers(in: orderLines.joined(separator: "\n"))
check(nums.contains(14443) && nums.allSatisfy { abs($0) < 1_000_000_000_000_000 }, "numbers 忽略超长数字串")

// 重复分类 / 账户名、空商户、垃圾日期、未知类型、退款、超长文字
var dupCtx = ctx(["示例小店", "¥88.00", "9999年99月99日 99:99:99"])
dupCtx.categories = ["餐饮", "餐饮", "购物", "工资", "工资"]
dupCtx.incomeCategories = ["工资", "工资"]
dupCtx.accounts = ["微信", "微信", "招行信用卡", "招行信用卡"]
let garbage = ["9999年99月99日 99:99:99", "昨天 下午99:99", "😀😀😀", String(repeating: "年月日", count: 400), "0000-00-00", "-1-1-1"]
for (i, g) in garbage.enumerated() {
    let o = ModelMerge.merge(model: [ModelTransaction(amount: 88, kind: ["expense", "income", "cardRepayment", "xyz", "", "transfer"][i],
                                                      merchant: i == 0 ? "" : String(repeating: "店", count: 500),
                                                      categoryName: "餐饮", accountHint: "微信", dateText: g, isRefund: i == 1)],
                             rules: [], ctx: dupCtx)
    check(o.receipts.count <= 1, "垃圾日期 / 重复名称 #\(i + 1) 不 trap")
}
// 规则结果里有异常金额：规则匹配时不 trap
var badRule = ParsedReceipt(); badRule.amount = .infinity
var badRule2 = ParsedReceipt(); badRule2.amount = .nan
var okRule = ParsedReceipt(); okRule.amount = 144.43
let edge3 = ModelMerge.merge(model: [ModelTransaction(amount: 144.43, kind: "expense")], rules: [badRule, badRule2, okRule], ctx: ctx(orderLines))
check(edge3.receipts.count == 1, "规则结果含 inf / NaN 时匹配不 trap")
// receipt(from:) 直接喂异常金额
let direct = ModelMerge.receipt(from: ModelTransaction(amount: .nan, kind: "expense"), ctx: ctx(orderLines), ruleMatch: nil)
check(direct.amount == nil, "receipt(from:) NaN 金额 → nil")
// 1 笔 vs 2 笔：结果数不同不影响
let edge4 = ModelMerge.merge(model: [ModelTransaction(amount: 144.43, kind: "expense")], rules: [okRule, okRule], ctx: ctx(orderLines))
check(edge4.receipts.count == 1, "模型 1 笔、规则 2 笔不 trap")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
