// Apple 智能结果校验 / 合并测试（模拟模型输出，合成数据）
// swiftc Ledger/OCR/ReceiptParser.swift Ledger/OCR/ModelMerge.swift Ledger/OCR/ModelPrompt.swift Ledger/OCR/AccountResolver.swift Tools/ModelMergeCheck/main.swift
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

// 11. 提示词：大字标记、行数 / 字数上限、指令包含语义说明与用户列表
let p = ModelPromptBuilder.build(lines: [OCRLine("¥18.00", midY: 0.31, height: 0.05), OCRLine("阿芳", midY: 0.35, height: 0.02)],
                                 instructions: "x", level: .normal)
check(p.prompt.contains("★¥18.00") && p.prompt.contains("阿芳") && !p.prompt.contains("y="), "提示词：大字标记，无行号 / 坐标")
let long = ModelPromptBuilder.build(lines: (0..<500).map { OCRLine("第\($0)行 一些文字", midY: 0.1 + Double($0) / 1000, height: 0.02) },
                                    instructions: "x", level: .minimal)
check(long.keptLines <= PromptLevel.minimal.maxLines && long.prompt.count <= PromptLevel.minimal.maxChars + 10 && long.truncatedLines > 0,
      "提示词截断（\(long.keptLines) 行，\(long.prompt.count) 字）")
let ins = ModelPromptBuilder.instructions(expenseCategories: expenseCats, incomeCategories: incomeCats, accounts: accounts, level: .normal)
check(ins.contains("支付成功") && ins.contains("招行信用卡") && ins.contains("repay") && ins.contains("餐饮"), "指令包含语义说明与用户列表")

// 12. 不得 trap：长数字串（订单号）、极端金额、重复名称、垃圾日期（全部为合成数据）
// 曾经：OCR 里 28 位订单号 → Double → ×100 → Int 溢出，Swift 运行时 trap（SIGTRAP），快捷指令「意外退出」
let orderLines = ["账单详情", "-144.43", "交易成功", "订单号", "2026102022001400000000000001",
                  "商户单号 9999999999999999999999999999999999", "流水 1234567890123456789.12",
                  "1,234,567,890,123,456,789.00", String(repeating: "9", count: 400)]
let edge1 = ModelMerge.merge(model: [ModelTransaction(amount: 144.43000000001, kind: "expense", merchant: "", dateText: "")],
                             rules: [], ctx: ctx(orderLines))
check(edge1.engine == .appleIntelligence && edge1.receipts.count == 1 && edge1.receipts.first?.amount == 144.43,
      "长订单号不 trap，144.43000000001 → 144.43")
let weird: [Double] = [0, -0.0, .nan, -.nan, .infinity, -.infinity, 1e20, -1e20, .greatestFiniteMagnitude,
                       .leastNonzeroMagnitude, 99_999_999.99, 100_000_000, 1e15, 9.2e16]
let edge2 = ModelMerge.merge(model: weird.map { ModelTransaction(amount: $0, kind: "expense") }, rules: [], ctx: ctx(orderLines))
check(edge2.receipts.allSatisfy { ($0.amount ?? 0).isFinite } && edge2.dropped == weird.count, "异常金额全部丢弃，不 trap（丢弃 \(edge2.dropped)）")
let negOK = ModelMerge.merge(model: [ModelTransaction(amount: -144.43, kind: "expense")], rules: [], ctx: ctx(orderLines))
check(negOK.dropped == 0 && negOK.receipts.first?.amount == 144.43, "2.0 (4)：原文「-144.43」、模型给负数 → 取绝对值后有效")
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

// 13. 英文云闪付还款（合成：卡尾号、金额均为虚构）：储蓄卡 1357 → 信用卡 2468，账户里还有一张交通银行信用卡（排在最前）
let upLines = ["云闪付交易详情", "Repay:CMB Credit card", "¥268.10", "Current Transaction Successful", "Status",
               "Order Amount ¥268.10", "Payment CMB Debit card[1357]", "Method", "Credit Card CMB Credit card[2468]", "Number",
               "Order Time 2026.09.15 09:08:07", "Order No. 2026091500000000000000000042"]
let idBocom = UUID(), idCmbCredit = UUID(), idCmbDebit = UUID(), idCcbDebit = UUID(), idWechat = UUID()
let userAccounts = [
    AccountCandidate(id: idBocom, name: "信用卡-交通银行", type: "credit"),
    AccountCandidate(id: idWechat, name: "微信", type: "wechat"),
    AccountCandidate(id: idCcbDebit, name: "储蓄卡-建设银行", type: "debit"),
    AccountCandidate(id: idCmbCredit, name: "信用卡-招商银行", type: "credit"),
    AccountCandidate(id: idCmbDebit, name: "储蓄卡-招商银行", type: "debit"),
]
func resolveRepay(_ r: ParsedReceipt?, _ accts: [AccountCandidate]) -> (card: AccountResolver.Resolution, payer: AccountResolver.Resolution) {
    let card = AccountResolver.resolve(hint: r?.repaymentCard ?? AccountHint(type: "credit"), modelName: r?.repaymentCardName, role: .card, accounts: accts)
    let payer = AccountResolver.resolve(hint: r?.accountHint, modelName: r?.accountName, role: .payer, accounts: accts, excluding: card.id)
    return (card, payer)
}
// 规则路径
let upRules = ReceiptParser.parseAll(lines: upLines.map { OCRLine($0) })
let ur = upRules.first
check(ur?.isCardRepayment == true && ur?.amount == 268.10 && ur?.merchant == nil, "规则：英文云闪付识别为信用卡还款，标题不当商户")
check(ur?.repaymentCard?.cardTail == "2468" && ur?.repaymentCard?.bankName == "招商银行", "规则：Credit Card Number → 被还款卡（招商 2468）")
check(ur?.accountHint?.cardTail == "1357" && ur?.accountHint?.type == "debit" && ur?.accountHint?.bankName == "招商银行", "规则：Payment Method → 付款账户（招商储蓄卡 1357）")
let rr = resolveRepay(ur, userAccounts)
check(rr.card.id == idCmbCredit && rr.card.via == .bank, "规则：信用卡匹配到招商信用卡（按银行），不是交通银行：\(rr.card)")
check(rr.payer.id == idCmbDebit && rr.payer.via == .bank, "规则：付款账户匹配到招商储蓄卡：\(rr.payer)")

// 模型路径（模拟输出）：模型把卡选成了交通银行 → 以原文银行为准
let upCtx = ModelMerge.Context(lines: upLines, categories: expenseCats + incomeCats, incomeCategories: incomeCats,
                               accounts: userAccounts.map(\.name), now: now, calendar: cal)
let modelRepay = ModelTransaction(amount: 268.10, kind: "cardRepayment", merchant: "CMB Credit card", categoryName: "其他",
                                  accountHint: "信用卡-交通银行", dateText: "2026.09.15 09:08:07",
                                  fromAccountHint: "未知", toAccountHint: "信用卡-交通银行",
                                  fromCardTail: "1357", toCardTail: "2468", bankNames: ["招商银行"], reason: "Repay 还款")
let om = ModelMerge.merge(model: [modelRepay], rules: upRules, ctx: upCtx)
let mr = om.receipts.first
check(om.engine == .appleIntelligence && mr?.isCardRepayment == true && mr?.categoryName == "信用卡还款" && mr?.merchant == nil, "模型：还款，标题为信用卡还款")
check(mr?.repaymentCard?.cardTail == "2468" && mr?.accountHint?.cardTail == "1357", "模型：尾号经原文校验后使用")
let mrr = resolveRepay(mr, userAccounts)
check(mrr.card.id == idCmbCredit && mrr.payer.id == idCmbDebit, "模型：即使模型选了交通银行，仍解析为招商信用卡 / 招商储蓄卡：\(mrr)")
// 模型把还款判成「支出」（2.0 (2) 的实际表现）→ 原文是还款，改为还款
let om2 = ModelMerge.merge(model: [ModelTransaction(amount: 268.10, kind: "expense", merchant: "CMB Credit card", categoryName: "其他",
                                                    accountHint: "信用卡-交通银行")], rules: upRules, ctx: upCtx)
let mExp = om2.receipts.first
check(mExp?.isCardRepayment == true && resolveRepay(mExp, userAccounts).card.id == idCmbCredit, "模型判为支出 → 按原文改为还款并匹配招商")
// 模型编造的尾号（原文没有）不采用
let fake = ModelMerge.merge(model: [ModelTransaction(amount: 268.10, kind: "cardRepayment", toCardTail: "9999")], rules: [], ctx: upCtx)
check(fake.receipts.first?.repaymentCard?.cardTail == "2468", "原文没有的尾号不采用")
// 尾号优先：两张招商信用卡，填了尾号的那张胜出；学到的尾号同样有效
let idCmbCredit2 = UUID()
var withTail = userAccounts + [AccountCandidate(id: idCmbCredit2, name: "招行经典白", type: "credit", cardTail: "2468")]
check(resolveRepay(mr, withTail).card == .init(id: idCmbCredit2, via: .tail), "尾号字段优先于银行")
withTail[withTail.count - 1].cardTail = ""
withTail[withTail.count - 1].learnedTails = ["2468"]
check(resolveRepay(mr, withTail).card == .init(id: idCmbCredit2, via: .tail), "学到的尾号优先于银行")
// 识别出招商但没有招商的卡：不选交通银行
let noCmb = userAccounts.filter { $0.id != idCmbCredit }
check(resolveRepay(mr, noCmb).card.id == nil, "没有同银行信用卡时不乱选别家银行")
// 银行未知、只有一张信用卡：兜底选它；有两张：不选
let single = [AccountCandidate(id: idBocom, name: "信用卡A", type: "credit"), AccountCandidate(id: idWechat, name: "微信", type: "wechat")]
check(AccountResolver.resolve(hint: AccountHint(type: "credit"), modelName: nil, role: .card, accounts: single).via == .fallback, "银行未知且只有一张卡 → 兜底")
check(AccountResolver.resolve(hint: AccountHint(type: "credit"), modelName: nil, role: .card, accounts: userAccounts).id == nil, "银行未知且多张卡 → 不自动选")
// 普通消费：「招商银行信用卡(2468)」→ 招商信用卡，不是第一张交通银行信用卡
let spend = AccountResolver.resolve(hint: AccountHint(type: "credit", cardTail: "2468", bankName: "招商银行"), modelName: nil, role: .single, accounts: userAccounts)
check(spend.id == idCmbCredit, "普通消费的信用卡按银行匹配")
check(AccountResolver.normalizeTail("[2468]") == "2468" && AccountResolver.normalizeTail("12") == nil && AccountResolver.normalizeTail(nil) == nil, "尾号规范化")
// ===== 2.0 (4)：提示词瘦身 / 预算 / 错误分类 / 金额格式（全部为合成数据）=====

// 英文云闪付（合成）：附英文字段说明、只附出现过的银行缩写、还款示例
let upLines = [OCRLine("9:41", midY: 0.02, height: 0.015), OCRLine("Repay:CMB Credit card", midY: 0.2, height: 0.03),
               OCRLine("¥268.10", midY: 0.25, height: 0.05), OCRLine("Payment Method", midY: 0.4, height: 0.02),
               OCRLine("CMB Debit card[1357]", midY: 0.42, height: 0.02), OCRLine("Credit Card Number", midY: 0.45, height: 0.02),
               OCRLine("CMB Credit card[2468]", midY: 0.47, height: 0.02), OCRLine("Order Time 2026.01.02 10:00:00", midY: 0.5, height: 0.02),
               OCRLine("Order Number 1234567890123456789012345678", midY: 0.55, height: 0.02), OCRLine("Customer Service", midY: 0.9, height: 0.02)]
let upIns = ModelPromptBuilder.instructions(expenseCategories: expenseCats, incomeCategories: incomeCats, accounts: accounts, level: .normal)
let up = ModelPromptBuilder.build(lines: upLines, instructions: upIns, level: .normal)
check(up.prompt.contains("Payment Method/Paid with") && up.prompt.contains("CMB=招商银行") && !up.prompt.contains("ICBC"),
      "英文截图：附英文字段说明，只列出现过的银行缩写")
check(up.prompt.contains("kind=repay") && up.prompt.contains("[2468]") && up.prompt.contains("[1357]"), "还款截图：附示例，保留尾号")
check(!up.prompt.contains("1234567890123") && !up.prompt.contains("9:41") && !up.prompt.contains("Customer Service") && up.noiseLines == 3,
      "去掉状态栏、订单号整行、客服按钮（去噪 \(up.noiseLines)）")
check(up.estimatedTokens + PromptLevel.normal.maxResponseTokens < ModelPromptBuilder.contextTokens - ModelPromptBuilder.safetyMargin,
      "还款截图 + 3 个分类组：估算 \(up.estimatedTokens) tokens + 输出上限 在上下文内")

// 中文截图：不附英文说明 / 还款示例；广告行、按钮行去掉；带付款字样的「优惠」行保留；卡号全号只留末 4 位
let cnLines = ["微信支付", "-26.00", "示例面馆", "当前状态 支付成功", "支付方式 零钱", "商户单号 4200001234567890123456", "限时福利 立即领取红包",
               "实付金额 优惠券抵扣 2.00", "收款卡号 6222 0000 1111 2468", "返回", "对此订单有疑问"].map { OCRLine($0) }
let cn = ModelPromptBuilder.build(lines: cnLines, instructions: "x", level: .normal)
check(!cn.prompt.contains("英文") && !cn.prompt.contains("例：") && cn.prompt.contains("示例面馆"), "中文截图：不附英文说明 / 示例")
check(!cn.prompt.contains("限时福利") && !cn.prompt.contains("对此订单") && !cn.prompt.contains("返回") && !cn.prompt.contains("42000012"),
      "广告 / 按钮 / 商户单号去掉")
check(cn.prompt.contains("优惠券抵扣") && cn.prompt.contains("#2468") && !cn.prompt.contains("6222"), "带付款字样的行保留；卡号全号只留末 4 位")
let dateLine = ModelPromptBuilder.clean([OCRLine("2026-10-21 21:56:01"), OCRLine("交易时间 2026-01-02 10:00")])
check(dateLine.lines.count == 2 && dateLine.lines[0].text == "2026-10-21 21:56:01", "日期时间不被当成长数字串")

// 大词表：14 个长账户名 + 30 个分类，标准级别仍在预算内；精简 / 极简更短
let bigAccounts = (1...14).map { "示例储蓄卡\($0)号" }
let bigCats = (1...30).map { "分类\($0)" }
let insN = ModelPromptBuilder.instructions(expenseCategories: bigCats, incomeCategories: ["工资", "红包"], accounts: bigAccounts, level: .normal)
let insC = ModelPromptBuilder.instructions(expenseCategories: bigCats, incomeCategories: ["工资", "红包"], accounts: bigAccounts, level: .compact)
let insM = ModelPromptBuilder.instructions(expenseCategories: bigCats, incomeCategories: ["工资", "红包"], accounts: bigAccounts, level: .minimal)
check(insN.count > insC.count && insC.count > insM.count, "指令长度：标准 \(insN.count) > 精简 \(insC.count) > 极简 \(insM.count)")
check(!insN.contains("分类21") && insM.contains("示例储蓄卡8号") && !insM.contains("示例储蓄卡9号") && insN.contains("示例储蓄卡14号"),
      "分类 / 账户按级别限量")
let bigLines = (0..<60).map { OCRLine("第\($0)行 示例商户名称很长很长很长 ¥\($0).00 备注文字", midY: 0.1 + Double($0) / 100, height: 0.02) }
for level in PromptLevel.allCases {
    let i = ModelPromptBuilder.instructions(expenseCategories: bigCats, incomeCategories: ["工资"], accounts: bigAccounts, level: level)
    let b = ModelPromptBuilder.build(lines: bigLines, instructions: i, level: level)
    check(b.estimatedTokens + level.maxResponseTokens + ModelPromptBuilder.safetyMargin <= ModelPromptBuilder.contextTokens,
          "\(level.title)：60 行长截图估算 \(b.estimatedTokens) tokens，在上下文内（\(b.keptLines) 行）")
}
check(ModelPromptBuilder.estimateTokens("招商银行") == 6 && ModelPromptBuilder.estimateTokens("Payment") == 3, "token 估算")
check(PromptLevel.initial(thermalSerious: true) == .compact && PromptLevel.normal.smaller == .compact && PromptLevel.compact.smaller == .minimal,
      "发热用精简；重试逐级缩短")
check(!ModelPromptBuilder.build(lines: [OCRLine("信用卡还款"), OCRLine("¥500.00")], instructions: "x", level: .minimal).prompt.contains("例："),
      "极简级别不附示例")

// 预算：OCR 快 → 15 秒；慢 → 递减，最少 8 秒；App 内最多 20 秒
check(ModelBudget.timeout(shortcut: true, elapsed: 0.5) == 15 && ModelBudget.timeout(shortcut: true, elapsed: 6) == 13
      && ModelBudget.timeout(shortcut: true, elapsed: 30) == 8 && ModelBudget.timeout(shortcut: true, elapsed: .nan) == 15, "快捷指令超时自适应")
check(ModelBudget.timeout(shortcut: false, elapsed: 1) == 20 && ModelBudget.timeout(shortcut: false, elapsed: 20) == 10, "App 内超时自适应")

// 错误分类：桥接成 NSError 时按说明文字猜种类，类型名本身不误判
check(ModelErrorKind.guess(from: "FoundationModels.LanguageModelSession.GenerationError error -1") == .unknown, "类型名不误判为语言错误")
check(ModelErrorKind.guess(from: "Exceeded model context window size") == .exceededContextWindowSize, "context window → 超出上下文")
check(ModelErrorKind.guess(from: "Failed to deserialize a Generable type from model output (decoding)") == .decodingFailure, "decoding")
check(ModelErrorKind.guess(from: "May contain sensitive or unsafe content") == .guardrailViolation, "guardrail")
check(ModelErrorKind.guess(from: "Failed to generate") == .unknown, "generate 不误判为限流")
check(ModelErrorKind.exceededContextWindowSize.retryable && ModelErrorKind.unknown.retryable && !ModelErrorKind.rateLimited.retryable
      && !ModelErrorKind.assetsUnavailable.retryable, "可重试的错误种类")

// 错误说明脱敏：不含原文单词、中文、金额、长数字
let src = "Repay CMB Credit card ¥268.10 Payment Method 示例面馆 1234567890"
let red = ModelErrorText.sanitize("Exceeded context window: 4200 tokens. Payment Method 示例面馆 268.10 1234567890 Repay", source: src)
check(red.contains("Exceeded context window") && red.contains("4200") && !red.contains("Payment") && !red.contains("Repay")
      && !red.contains("268") && !red.contains("123456") && !red.contains("示例"), "错误说明脱敏：\(red)")

// 金额格式：负数取绝对值、全角、货币符号、千分位空格、元
let fmtLines = ["示例超市", "－１２．００", "¥1, 234.50", "12 .50元", "付款 ￥88"]
let mf = ModelMerge.merge(model: [ModelTransaction(amount: -12, kind: "expense", merchant: "示例超市"),
                                  ModelTransaction(amount: 1234.5, kind: "expense", merchant: "示例超市", dateText: "a"),
                                  ModelTransaction(amount: 12.5, kind: "expense", merchant: "示例超市", dateText: "b"),
                                  ModelTransaction(amount: 88, kind: "expense", merchant: "示例超市", dateText: "c")],
                          rules: [], ctx: ctx(fmtLines))
check(mf.engine == .appleIntelligence && mf.receipts.count == 4 && mf.dropped == 0 && mf.receipts.first?.amount == 12,
      "负数 / 全角 / 千分位空格 / 元 都能匹配（\(mf.receipts.count) 笔，丢弃 \(mf.dropped)）")
let md = ModelMerge.merge(model: [ModelTransaction(amount: 0, kind: "expense"), ModelTransaction(amount: .nan, kind: "expense"),
                                  ModelTransaction(amount: 2e9, kind: "expense"), ModelTransaction(amount: 77, kind: "expense")],
                          rules: [], ctx: ctx(["示例", "¥88.00"]))
check(md.dropped == 4 && md.dropReasons == ["格式无效 1", "为零 1", "超出范围 1", "不在原文 1"], "丢弃原因分类：\(md.dropReasons)")
check(ModelMerge.nearMissHint(8.8, ModelMerge.numbers(in: "¥88.00")) == "小数位不同" && ModelMerge.nearMissHint(5, ModelMerge.numbers(in: "¥88.00")) == "原文无相近数字",
      "不在原文：区分小数位不同 / 编造")
let mr4 = ModelMerge.merge(model: [ModelTransaction(amount: 500, kind: "repay")], rules: [], ctx: ctx(["信用卡还款", "¥500.00"]))
check(mr4.receipts.first?.isCardRepayment == true, "kind=repay 识别为还款")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
