import Foundation

/// Apple 智能（端侧模型）抽取出的一笔交易：纯值，便于在命令行用模拟输出测试校验 / 合并逻辑
struct ModelTransaction: Equatable, Sendable {
    var amount: Double
    /// expense / income / transfer / cardRepayment
    var kind: String
    var merchant: String = ""
    var note: String = ""
    var categoryName: String = ""
    /// 用户账户名之一，或「未知」
    var accountHint: String = "未知"
    /// 截图上看到的日期时间原文
    var dateText: String = ""
    var isRefund: Bool = false
}

/// 模型抽取结果的校验与合并（纯 Foundation，见 Tools/ModelMergeCheck）
enum ModelMerge {
    struct Context {
        var lines: [String]
        var categories: [String]         // 用户的支出 + 收入分类名
        var incomeCategories: [String]
        var accounts: [String]           // 用户的账户名
        var now: Date
        var calendar: Calendar
    }

    struct Outcome: Equatable {
        var receipts: [ParsedReceipt]
        var engine: RecognitionEngine
        /// 校验时丢弃的条数（金额不在原文中 / 金额无效 / 重复）
        var dropped: Int
        /// 跳过的自有账户间转账（余额宝 / 零钱通 / 充值提现）
        var skippedTransfers: Int
        /// 回退到规则时的原因（显示给用户的一小行字）
        var fallbackReason: String?
    }

    /// 运行日志钩子（App 内指向 RunLog；命令行测试为空操作）。只传步骤名和计数，不传文字 / 金额。
    nonisolated(unsafe) static var trace: (_ step: String, _ message: String) -> Void = { _, _ in }

    // MARK: 金额校验

    /// 合理的交易金额上限（1 亿）；模型输出的金额先过这一关再参与任何换算
    static let maxAmount: Double = 100_000_000

    static func isValidAmount(_ v: Double) -> Bool {
        v.isFinite && v > 0 && v < maxAmount
    }

    /// 匹配数字串：长数字串（订单号 / 卡号 / 流水号）不会被当成金额
    private static let numberPattern = try! NSRegularExpression(pattern: #"\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?"#)
    /// 去掉千分位后超过这个长度的数字串直接忽略（远大于 maxAmount）
    private static let maxNumberLength = 15

    /// 原文里出现过的全部数字（去掉千分位、全角、货币符号），保留两位小数
    static func numbers(in text: String) -> Set<Int> {
        let normalized = ReceiptParser.normalize(text)
        let ns = normalized as NSString
        var result = Set<Int>()
        for m in numberPattern.matches(in: normalized, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: m.range).replacingOccurrences(of: ",", with: "")
            guard raw.count <= maxNumberLength, let v = Double(raw), let c = cents(v) else { continue }
            result.insert(c)
        }
        return result
    }

    /// 金额 → 分。非有限值或超出范围返回 nil（绝不做会溢出的 Int 转换：
    /// 曾因 OCR 中 28 位订单号转 Int 溢出，Swift 运行时 trap 导致快捷指令「意外退出」）
    static func cents(_ v: Double) -> Int? {
        guard v.isFinite else { return nil }
        let c = (v * 100).rounded()
        guard abs(c) < 1e15 else { return nil }
        return Int(c)
    }

    /// 金额必须在 OCR 原文中出现（模型不得编造金额）
    static func amountAppears(_ amount: Double, in text: String) -> Bool {
        guard isValidAmount(amount), let c = cents(amount) else { return false }
        return numbers(in: text).contains(c)
    }

    private static let balanceWords = ["余额", "可用额度", "可用", "额度", "积分", "剩余"]

    /// 该金额的每一次出现都紧跟在「余额 / 可用额度 / 积分」之后：不是交易金额（模型常把余额当成交易）。
    /// 按出现位置判断，所以「消费 46.00 元，余额 2000.00 元」里的 46 仍有效。
    static func onlyInBalanceLines(_ amount: Double, lines: [String]) -> Bool {
        guard let target = cents(amount) else { return false }
        let re = numberPattern
        var occurrences = 0
        for raw in lines {
            let line = ReceiptParser.normalize(raw)
            let ns = line as NSString
            for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: m.range).replacingOccurrences(of: ",", with: "")
                guard raw.count <= maxNumberLength, let v = Double(raw), cents(v) == target else { continue }
                occurrences += 1
                let from = max(0, m.range.location - 8)
                let before = ns.substring(with: NSRange(location: from, length: m.range.location - from))
                // 只看最近的分隔符之后：「消费46元，余额2000元」中 2000 前是「余额」，46 前是「消费」
                let tail = before.components(separatedBy: CharacterSet(charactersIn: "，,。;；|")).last ?? before
                if !balanceWords.contains(where: { tail.contains($0) }) { return false }
            }
        }
        return occurrences > 0
    }

    // MARK: 单条转换

    /// 名称对齐到用户列表：完全一致 > 互相包含；对不上返回 nil
    static func align(_ name: String, to list: [String]) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != "未知" else { return nil }
        if let hit = list.first(where: { $0 == n }) { return hit }
        return list.first(where: { $0.contains(n) || n.contains($0) })
    }

    /// 把一条通过校验的模型结果转换成 ParsedReceipt；同金额的规则结果作为补充（日期 / 付款方式线索）
    static func receipt(from t: ModelTransaction, ctx: Context, ruleMatch: ParsedReceipt?) -> ParsedReceipt {
        var r = ParsedReceipt()
        r.engine = .appleIntelligence
        r.amount = isValidAmount(t.amount) ? (t.amount * 100).rounded() / 100 : nil
        r.score = 100
        r.rawText = ctx.lines.joined(separator: "\n")
        let kind = t.kind.lowercased()
        r.isIncome = kind == "income" || t.isRefund
        r.isCardRepayment = kind == "cardrepayment" && !t.isRefund
        // 模型给的文字字段限长，避免异常长输出进入后续处理
        let merchant = ReceiptParser.cleanMerchant(String(t.merchant.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)))
        r.merchant = merchant.isEmpty ? ruleMatch?.merchant : merchant
        let dateText = String(t.dateText.prefix(60))
        if !dateText.isEmpty, let d = ReceiptParser.date(lines: [dateText], now: ctx.now, calendar: ctx.calendar),
           abs(d.timeIntervalSince(ctx.now)) < 20 * 366 * 86_400 {
            r.date = d
        } else {
            r.date = ruleMatch?.date
        }
        let account = align(t.accountHint, to: ctx.accounts)
        if r.isCardRepayment {
            r.categoryName = "信用卡还款"
            r.repaymentCardName = account
            let split = RepaymentDetector.split(text: EnglishBankTerms.localize(ctx.lines.joined(separator: " ")))
            r.repaymentCard = ruleMatch?.repaymentCard ?? split.card
            r.accountHint = ruleMatch?.isCardRepayment == true ? ruleMatch?.accountHint : split.payer
        } else {
            r.accountName = account
            r.accountHint = ruleMatch?.accountHint
            let pool = r.isIncome ? ctx.incomeCategories : ctx.categories.filter { !ctx.incomeCategories.contains($0) }
            if t.isRefund, pool.contains("退款") {
                r.categoryName = "退款"
            } else if let c = align(t.categoryName, to: pool) {
                r.categoryName = c
            } else {
                r.categoryName = CategoryGuesser.guess(text: r.merchant ?? "", isIncome: r.isIncome)
                    ?? ruleMatch?.categoryName
            }
        }
        return r
    }

    // MARK: 校验 + 合并

    /// model 为 nil 表示模型不可用 / 出错（unavailableReason 说明原因）
    static func merge(model: [ModelTransaction]?, rules: [ParsedReceipt], ctx: Context,
                      unavailableReason: String? = nil) -> Outcome {
        let ruleItems = rules.filter { ($0.amount ?? 0) > 0 }
        guard let model else {
            return Outcome(receipts: rules, engine: .rules, dropped: 0, skippedTransfers: 0, fallbackReason: unavailableReason)
        }
        trace("model-validate", "模型 \(model.count) 笔，规则 \(ruleItems.count) 笔，OCR \(ctx.lines.count) 行")
        let text = ctx.lines.joined(separator: "\n")
        let textNumbers = numbers(in: text)
        trace("model-validate", "原文数字 \(textNumbers.count) 个")
        var valid: [ParsedReceipt] = []
        var dropped = 0
        var skipped = 0
        var seen = Set<String>()
        var usedRules = Set<Int>()
        for (i, t) in model.enumerated() {
            guard isValidAmount(t.amount), let c = cents(t.amount) else {
                trace("model-validate", "第 \(i + 1) 笔：金额无效，丢弃"); dropped += 1; continue
            }
            guard textNumbers.contains(c) else {
                trace("model-validate", "第 \(i + 1) 笔：金额不在原文中，丢弃"); dropped += 1; continue
            }
            guard !onlyInBalanceLines(t.amount, lines: ctx.lines) else {
                trace("model-validate", "第 \(i + 1) 笔：只出现在余额处，丢弃"); dropped += 1; continue
            }
            if t.kind.lowercased() == "transfer" { trace("model-validate", "第 \(i + 1) 笔：账户间转账，跳过"); skipped += 1; continue }
            let key = "\(c)|\(t.merchant)|\(t.dateText)"
            guard seen.insert(key).inserted else { trace("model-dedupe", "第 \(i + 1) 笔：重复，丢弃"); dropped += 1; continue }
            // 同金额、未被占用的规则结果，用来补充日期和付款方式
            let idx = ruleItems.indices.first { j in
                guard !usedRules.contains(j), let a = ruleItems[j].amount, let rc = cents(a) else { return false }
                return rc == c
            }
            if let idx { usedRules.insert(idx) }
            trace("rules-apply", "第 \(i + 1) 笔：\(idx == nil ? "无" : "有")同金额规则结果")
            valid.append(receipt(from: t, ctx: ctx, ruleMatch: idx.map { ruleItems[$0] }))
            trace("model-convert", "第 \(i + 1) 笔：已转换")
        }
        trace("merge", "有效 \(valid.count) 笔，丢弃 \(dropped)，转账 \(skipped)")
        if valid.isEmpty {
            let reason = skipped > 0 && dropped == 0 && ruleItems.isEmpty
                ? "Apple 智能判断为账户间转账，未记账"
                : "Apple 智能未给出有效结果，已用规则识别"
            if skipped > 0 && dropped == 0 && ruleItems.isEmpty {
                return Outcome(receipts: rules, engine: .appleIntelligence, dropped: 0, skippedTransfers: skipped, fallbackReason: reason)
            }
            return Outcome(receipts: rules, engine: .rules, dropped: dropped, skippedTransfers: skipped, fallbackReason: reason)
        }
        // 模型有编造（金额不在原文）且规则识别出更多笔：更信任规则
        if dropped > 0 && ruleItems.count > valid.count {
            return Outcome(receipts: rules, engine: .rules, dropped: dropped, skippedTransfers: skipped,
                           fallbackReason: "Apple 智能结果未通过校验，已用规则识别")
        }
        return Outcome(receipts: valid, engine: .appleIntelligence, dropped: dropped, skippedTransfers: skipped, fallbackReason: nil)
    }

    // MARK: 提示词（尽量短：端侧模型冷启动 + 生成都与输入长度相关）

    /// 只保留可能与交易有关的行：去掉状态栏（顶部 4.5% 内）、纯时间 / 电量 / 符号行，最多 40 行
    static func relevantLines(_ lines: [OCRLine]) -> [OCRLine] {
        let timeOnly = try! NSRegularExpression(pattern: #"^\d{1,2}:\d{2}$"#)
        var out: [OCRLine] = []
        for l in lines {
            let t = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if l.height > 0 && l.midY < 0.045 { continue }
            let ns = t as NSString
            if timeOnly.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) != nil && out.isEmpty { continue }
            guard t.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }) else { continue }
            out.append(l)
            if out.count >= 40 { break }
        }
        return out
    }

    /// 给模型的 OCR 文本：带行号、纵向位置和大字标记，截断到 maxChars
    static func promptText(_ lines: [OCRLine], maxChars: Int = 1200) -> String {
        var out: [String] = []
        var total = 0
        for (i, l) in lines.enumerated() {
            let t = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            var tag = String(format: "L%02d", i + 1)
            if l.height > 0 {
                tag += String(format: " y=%.2f", l.midY)
                if l.height >= 0.03 { tag += " 大字" }
            }
            let line = "\(tag) | \(t)"
            total += line.count + 1
            if total > maxChars { break }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    static let compactInstructionsHeader = """
    The person's locale is zh_CN.
    你是记账助手：从支付截图的 OCR 文字中提取交易，只输出结构化结果。
    """

    static func instructions(categories: [String], incomeCategories: [String], accounts: [String]) -> String {
        let expense = Array(categories.filter { !incomeCategories.contains($0) }.prefix(30))
        let income = Array(incomeCategories.prefix(15))
        let accts = Array(accounts.prefix(20))
        return compactInstructionsHeader + """

        规则：
        1. 金额必须是原文里出现的数字，不得编造或计算；忽略余额、可用额度、优惠说明、积分、广告、状态栏时间、订单号、卡号。
        2. 对方已收款/支付成功/付款/消费 = expense；收款/到账/收入 = income；退款 = income 且 isRefund=true；信用卡还款/还信用卡/花呗还款/Repay/Repayment = cardRepayment；余额宝/零钱通转入转出、充值、提现、自己账户互转 = transfer；转账给他人 = expense。
        3. 银行短信：支出/消费/扣款 = expense，存入/收入 = income。
        4. 多笔按从上到下分别输出，不要重复。
        5. categoryName 只能选：支出 \(expense.joined(separator: "、"))；收入 \(income.joined(separator: "、"))。
        6. accountHint 只能选：\(accts.isEmpty ? "（无）" : accts.joined(separator: "、"))，或「未知」；信用卡还款时填被还款的卡。
        7. dateText 原样抄写日期时间文字，没有留空。
        """
    }
}
