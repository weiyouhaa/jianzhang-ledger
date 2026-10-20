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
    /// 还款 / 转账：付款账户（用户账户名之一或「未知」）与收款 / 被还款账户
    var fromAccountHint: String = ""
    var toAccountHint: String = ""
    /// 截图上看到的 4 位尾号（付款卡 / 被还款的卡）
    var fromCardTail: String = ""
    var toCardTail: String = ""
    /// 截图中出现的银行（中文全称或英文缩写，如 CMB）
    var bankNames: [String] = []
    /// 模型给出的简短判断理由（只用于调试，日志里只记长度）
    var reason: String = ""
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
        var kind = t.kind.lowercased()
        let localizedText = EnglishBankTerms.localize(ctx.lines.joined(separator: " "))
        // 原文明确是信用卡还款（还款 + 信用卡 / 银行），模型却判为普通支出：按还款处理（截图证据优先于模型的分类）
        if kind == "expense", !t.isRefund,
           ruleMatch?.isCardRepayment == true || RepaymentDetector.isCardRepayment(text: localizedText) {
            kind = "cardrepayment"
            trace("model-kind", "模型判为支出，原文是信用卡还款 → 改为还款")
        }
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
            // 模型的语义判断优先：付款方 / 被还款卡的账户名、尾号、银行；规则结果只补缺
            r.categoryName = "信用卡还款"
            r.merchant = nil
            let toName = align(t.toAccountHint, to: ctx.accounts) ?? account
            let fromName = align(t.fromAccountHint, to: ctx.accounts)
            r.repaymentCardName = toName
            r.accountName = fromName
            let split = RepaymentDetector.split(text: localizedText)
            let ruleCard = ruleMatch?.isCardRepayment == true ? ruleMatch?.repaymentCard : nil
            let rulePayer = ruleMatch?.isCardRepayment == true ? ruleMatch?.accountHint : nil
            let banks = t.bankNames.map { EnglishBankTerms.localize($0).trimmingCharacters(in: .whitespaces) }.filter { $0.hasSuffix("银行") }
            var card = AccountHint(type: "credit")
            card.cardTail = verifiedTail(t.toCardTail, ctx: ctx) ?? ruleCard?.cardTail ?? split.card?.cardTail
            // 银行以原文证据为准，其次才是模型选的账户名
            card.bankName = ruleCard?.bankName ?? split.card?.bankName ?? bank(in: t.toAccountHint) ?? (banks.count == 1 ? banks[0] : nil)
            if let ty = ruleCard?.type ?? split.card?.type { card.type = ty }
            r.repaymentCard = card
            var payer = rulePayer ?? split.payer ?? AccountHint()
            if let tail = verifiedTail(t.fromCardTail, ctx: ctx) { payer.cardTail = tail }
            if payer.bankName == nil, let b = bank(in: t.fromAccountHint) { payer.bankName = b }
            if payer.bankName == nil, banks.count == 1 { payer.bankName = banks[0] }
            if payer.type == nil, payer.bankName != nil { payer.type = "debit" }
            r.accountHint = (payer.type == nil && payer.bankName == nil && payer.cardTail == nil) ? nil : payer
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

    /// 模型给的尾号：必须是 4 位数字且在原文中出现过（防止编造）
    static func verifiedTail(_ raw: String, ctx: Context) -> String? {
        guard let tail = AccountResolver.normalizeTail(raw), raw.filter(\.isNumber).count == 4 else { return nil }
        return ctx.lines.contains(where: { $0.contains(tail) }) ? tail : nil
    }

    /// 文字里的银行名（英文缩写先转中文）
    static func bank(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != "未知" else { return nil }
        return AccountHintParser.parse(text: EnglishBankTerms.localize(t))?.bankName
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
            trace("model-item", "第 \(i + 1) 笔：类型 \(t.kind.prefix(16))，付款账户\(t.fromAccountHint.isEmpty || t.fromAccountHint == "未知" ? "无" : "有")"
                  + "，收款账户\(t.toAccountHint.isEmpty || t.toAccountHint == "未知" ? "无" : "有")，尾号 \(t.fromCardTail.isEmpty ? 0 : 1)+\(t.toCardTail.isEmpty ? 0 : 1)"
                  + "，银行 \(t.bankNames.count) 个，理由 \(t.reason.count) 字")
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

    static func instructions(categories: [String], incomeCategories: [String], accounts: [String],
                             accountDetails: [String] = []) -> String {
        let expense = Array(categories.filter { !incomeCategories.contains($0) }.prefix(30))
        let income = Array(incomeCategories.prefix(15))
        let accts = Array((accountDetails.count == accounts.count && !accountDetails.isEmpty ? accountDetails : accounts).prefix(20))
        return compactInstructionsHeader + """

        规则：
        1. 先理解截图语义再填写。金额必须是原文里出现的数字，不得编造或计算；忽略余额、可用额度、优惠、积分、广告、状态栏时间、订单号 / 流水号 / 卡号。
        2. 类型：对方已收款/支付成功/付款/消费 = expense；收款/到账/收入 = income；退款 = income 且 isRefund=true；信用卡还款/还信用卡/花呗还款/Repay/Repayment = cardRepayment；余额宝/零钱通转入转出、充值、提现、自己账户互转 = transfer；转账给他人 = expense。
        3. 英文界面（云闪付 / 银行 App）：Repay、Repayment = 还款；Payment Method / Payment Card / Paid with = 付款账户；Credit Card Number / Repay card = 被还款的信用卡；Order Amount / Amount = 金额；Order Time / Transaction Time = 时间；Debit / Savings card = 储蓄卡；Credit card = 信用卡。银行缩写：CMB 招商银行，CMBC 民生银行，ICBC 工商银行，CCB 建设银行，ABC 农业银行，BOC 中国银行，BOCOM/BCM 交通银行，CIB 兴业银行，CEB 光大银行，SPDB 浦发银行，CITIC 中信银行，PSBC 邮储银行，GDB/CGB 广发银行，PAB 平安银行。
        4. 还款 / 转账：fromAccountHint 填付款账户，toAccountHint 填被还款的卡或收款账户；fromCardTail / toCardTail 填截图上对应卡号的最后 4 位；bankNames 填截图中出现的银行。必须选同一家银行、同一卡种的账户；不确定填「未知」，不要选别家银行的卡。
        5. 银行短信：支出/消费/扣款 = expense，存入/收入 = income。多笔按从上到下分别输出，不要重复。
        6. categoryName 只能选：支出 \(expense.joined(separator: "、"))；收入 \(income.joined(separator: "、"))。还款不用填分类。
        7. 账户名只能从下列选择（〔〕内是说明，只填〔〕前的名字），或「未知」：\(accts.isEmpty ? "（无）" : accts.joined(separator: "、"))
        8. dateText 原样抄写日期时间文字，没有留空。reason 用不超过 15 个字说明判断依据。

        示例（虚构）：
        「Repay:CCB Credit card / ¥88.00 / Payment Method CCB Debit card[1111] / Credit Card Number CCB Credit card[2222] / Order Time 2026.01.02 10:00:00」→ kind=cardRepayment amount=88 fromCardTail=1111 toCardTail=2222 bankNames=[建设银行] dateText=2026.01.02 10:00:00
        「微信支付 / 示例面馆 / -26.00 / 支付成功 / 支付方式 零钱」→ kind=expense amount=26 merchant=示例面馆 categoryName=餐饮
        「支付宝 / 账单详情 / 信用卡还款 / -500.00 / 还款到 工商银行信用卡(3333) / 付款方式 余额宝」→ kind=cardRepayment amount=500 toCardTail=3333 bankNames=[工商银行]
        """
    }
}
