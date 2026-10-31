import Foundation

/// OCR 文本解析结果
struct ParsedReceipt: Equatable {
    var amount: Double?
    var isIncome: Bool = false
    var merchant: String?
    var date: Date?
    var categoryName: String?
    /// 付款方式线索（支付宝 / 微信 / 银行卡尾号 / 信用卡 / 花呗）
    var accountHint: AccountHint?
    /// 信用卡 / 花呗还款截图：isCardRepayment 为 true，accountHint 为付款账户线索，repaymentCard 为被还款的卡
    var isCardRepayment: Bool = false
    var repaymentCard: AccountHint?
    /// Apple 智能识别时：模型从用户账户列表中选出的账户名（还款时为被还款的卡）；规则识别为 nil
    var accountName: String?
    var repaymentCardName: String?
    /// 识别引擎（审核弹窗 / 结果里显示）
    var engine: RecognitionEngine = .rules
    var rawText: String = ""
    /// 金额候选得分（内部用于多笔拆分时过滤低置信度片段）
    var score: Double = 0
    /// 钱包充值 / 提现 / 余额宝、零钱通转入转出：自己账户之间的转账（transferFrom → transferTo）
    var isSelfTransfer: Bool = false
    var transferFrom: AccountHint?
    var transferTo: AccountHint?
    /// 账户名线索（「余额宝」「零钱通」，或 Apple 智能选出的账户名）
    var transferFromName: String?
    var transferToName: String?
    /// 「零钱充值」「余额提现」「转入余额宝」，作为备注
    var transferNote: String?
    /// 优惠信息短备注（如「随机立减 0.04」），不另记一笔
    var discountNote: String?
}

/// 识别引擎：Apple 智能（端侧模型抽取 + 校验）或本地规则
enum RecognitionEngine: String, Equatable, Sendable {
    case appleIntelligence
    case rules

    var title: String { self == .appleIntelligence ? "Apple 智能" : "规则" }
}

/// OCR 的一行文字及其在图中的位置（归一化坐标，midY 0 = 顶部、1 = 底部）。
/// 没有位置信息时 height 为 0，解析器只用文本规则。
struct OCRLine: Equatable {
    var text: String
    var midY: Double = 0
    var height: Double = 0

    init(_ text: String, midY: Double = 0, height: Double = 0) {
        self.text = text
        self.midY = midY
        self.height = height
    }
}

/// 从 OCR 文本中提取的付款账户线索
struct AccountHint: Equatable {
    /// AccountType 的 rawValue：cash / debit / alipay / wechat / credit / consumerCredit …
    var type: String?
    var cardTail: String?
    var bankName: String?

    /// 「招商银行」→ ["招商银行", "招商", "招行"]
    static func aliases(forBank bank: String) -> [String] {
        var list = [bank]
        var core = bank
        if core.hasPrefix("中国") && core.count > 4 { core = String(core.dropFirst(2)) }
        if core.hasSuffix("银行") { core = String(core.dropLast(2)) }
        if core.count >= 2 {
            list.append(core)
            list.append(String(core.prefix(1)) + "行")
        }
        if bank == "中国银行" { list.append("中行") }
        return list
    }
}

enum AccountHintParser {
    private static let bankPattern = try! NSRegularExpression(pattern: #"([\p{Han}]{2,8}?银行)"#)
    private static let tailPatterns: [NSRegularExpression] = [
        #"(?:尾号|末四位|末4位|账户|账号)\s*[*＊]*\s*(\d{4})(?!\d)"#,
        #"\(\s*[*＊]*\s*(\d{4})\s*\)"#,
        #"[（\[【]\s*[*＊]*\s*(\d{4})\s*[）\]】]"#,
        #"[*＊]{2,}\s*(\d{4})(?!\d)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static let knownBanks = ["中国工商银行", "中国建设银行", "中国农业银行", "中国邮政储蓄银行", "中国银行", "工商银行", "建设银行", "农业银行",
                             "交通银行", "招商银行", "邮储银行", "邮政储蓄银行", "中信银行", "光大银行", "民生银行", "兴业银行", "浦发银行",
                             "广发银行", "平安银行", "华夏银行", "浙商银行", "渤海银行", "恒丰银行", "北京银行", "上海银行", "江苏银行",
                             "宁波银行", "南京银行", "杭州银行", "微众银行", "网商银行", "汇丰银行", "渣打银行", "花旗银行", "东亚银行"]

    /// 银行简称（只在后面紧跟「信用卡 / 储蓄卡 / 借记卡 / 银行卡」时使用，避免「平安保险」「民生缴费」之类误判）
    static let shortBanks: [(String, String)] = [
        ("浦发", "浦发银行"), ("招行", "招商银行"), ("招商", "招商银行"), ("工行", "工商银行"), ("建行", "建设银行"), ("农行", "农业银行"),
        ("中行", "中国银行"), ("交行", "交通银行"), ("中信", "中信银行"), ("光大", "光大银行"), ("民生", "民生银行"), ("兴业", "兴业银行"),
        ("平安", "平安银行"), ("华夏", "华夏银行"), ("广发", "广发银行"), ("邮储", "邮储银行"),
    ]
    private static let shortBankPattern = try! NSRegularExpression(
        pattern: "(" + shortBanks.map(\.0).joined(separator: "|") + #")(?=\s*(?:银联)?\s*(?:信用卡|储蓄卡|借记卡|银行卡))"#)

    static func parse(text: String) -> AccountHint? {
        var hint = AccountHint()
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = bankPattern.firstMatch(in: text, range: range) {
            var bank = ns.substring(with: m.range(at: 1))
            // 「使用交通银行」「您的招商银行」→ 去掉前面的动词 / 代词
            let prefixes = ["使用", "通过", "您的", "你的", "我的", "绑定", "来自", "还款", "用", "您", "在", "向", "从"]
            var changed = true
            while changed {
                changed = false
                for p in prefixes where bank.hasPrefix(p) && bank.count - p.count >= 4 {
                    bank = String(bank.dropFirst(p.count))
                    changed = true
                }
            }
            // 「交易成功提现到建设银行」：包含已知银行名时只取银行名（最长匹配）
            if let known = knownBanks.filter({ bank.contains($0) }).max(by: { $0.count < $1.count }) { bank = known }
            hint.bankName = bank
        } else if let m = shortBankPattern.firstMatch(in: text, range: range) {
            // 「浦发信用卡」「招行储蓄卡」：简称后面紧跟卡种时才认
            let short = ns.substring(with: m.range(at: 1))
            hint.bankName = shortBanks.first(where: { $0.0 == short })?.1
        }
        for re in tailPatterns {
            if let m = re.firstMatch(in: text, range: range) {
                hint.cardTail = ns.substring(with: m.range(at: 1))
                break
            }
        }
        if text.contains("信用卡") {
            hint.type = "credit"
        } else if ["花呗", "白条", "月付"].contains(where: { text.contains($0) }) {
            hint.type = "consumerCredit"
        } else if text.contains("储蓄卡") || text.contains("借记卡") || (hint.bankName != nil && hint.cardTail != nil) {
            hint.type = "debit"
        } else if text.contains("零钱") {
            hint.type = "wechat"
        } else if text.contains("余额宝") || text.contains("账户余额") {
            hint.type = "alipay"
        } else if text.contains("微信支付") {
            hint.type = "wechat"
        } else if text.contains("支付宝") {
            hint.type = "alipay"
        } else if hint.bankName != nil {
            hint.type = "debit"
        }
        if hint.type == nil && hint.cardTail == nil && hint.bankName == nil { return nil }
        return hint
    }
}

/// 英文界面（云闪付 / 银行 App 英文版）的银行缩写与卡种 → 中文，仅用于还款识别与账户线索（不改商户名）
enum EnglishBankTerms {
    static let banks: [(String, String)] = [
        ("BOCOM", "交通银行"), ("CMBC", "民生银行"), ("CITIC", "中信银行"), ("PINGAN", "平安银行"), ("PSBC", "邮储银行"),
        ("SPDB", "浦发银行"), ("ICBC", "工商银行"), ("CMB", "招商银行"), ("CCB", "建设银行"), ("ABC", "农业银行"),
        ("BOC", "中国银行"), ("BCM", "交通银行"), ("CIB", "兴业银行"), ("CEB", "光大银行"), ("PAB", "平安银行"),
        ("GDB", "广发银行"), ("CGB", "广发银行"), ("HXB", "华夏银行"),
    ]
    private static var bankAlternation: String { banks.map(\.0).joined(separator: "|") }
    private static let bankRegex: NSRegularExpression = {
        let alt = banks.map(\.0).joined(separator: "|")   // 长的在前：CMBC 先于 CMB
        return try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])(\(alt))(?![A-Za-z0-9])")
    }()
    private static let phrases: [(String, String)] = [
        (#"(?i)credit\s*card\s*repayments?"#, "信用卡还款"),
        // 云闪付 / 银行 App 英文详情页的字段标签（标签可能被换行拆开：「Payment … Method」「Credit Card … Number」）
        (#"(?i)(?:credit\s*card\s*(?:number|no\.?)|repay(?:ment)?\s*card|card\s*repaid)(?![A-Za-z])"#, "还款卡 "),
        (#"(?i)(?<![A-Za-z])credit\s*card(?=\s+(?:\#(bankAlternation))(?![A-Za-z]))"#, "还款卡 "),
        (#"(?i)(?<![A-Za-z])pay(?:ment)?\s*(?:method|card|account)(?![A-Za-z])"#, "付款方式 "),
        (#"(?i)(?<![A-Za-z])payment(?=\s+(?:\#(bankAlternation))(?![A-Za-z]))"#, "付款方式 "),
        (#"(?i)(?<![A-Za-z])paid\s*(?:with|by|from)(?![A-Za-z])"#, "付款方式 "),
        (#"(?i)(?<![A-Za-z])repay(?:ment)?s?(?![A-Za-z])"#, "还款"),
        (#"(?i)credit\s*cards?"#, "信用卡"),
        (#"(?i)debit\s*cards?|savings?\s*(?:cards?|account)"#, "储蓄卡"),
        (#"(?i)(?<![A-Za-z])ending\s*(?:in|with)?\s*(?=\d{4})"#, "尾号"),
        (#"(?i)(?<![A-Za-z])successful(?:ly)?(?![A-Za-z])|(?<![A-Za-z])success(?![A-Za-z])"#, "成功"),
    ].map { ($0.0, $0.1) }

    /// 「SPDBCredit card」「CMBDebit card」：银行缩写与卡种粘在一起时先拆开
    private static let gluedRegex: NSRegularExpression = {
        let alt = banks.map(\.0).joined(separator: "|")
        return try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])(\(alt))(?=(?i:credit|debit|savings?|card))")
    }()

    static func splitGlued(_ text: String) -> String {
        guard text.range(of: "[A-Z]{3}", options: .regularExpression) != nil else { return text }
        let ns = text as NSString
        return gluedRegex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "$1 ")
    }

    static func localize(_ text: String) -> String {
        guard text.range(of: "[A-Za-z]", options: .regularExpression) != nil else { return text }
        var out = splitGlued(text)
        for (pattern, zh) in phrases {
            out = out.replacingOccurrences(of: pattern, with: zh, options: .regularExpression)
        }
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in bankRegex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let abbr = ns.substring(with: m.range(at: 1))
            result += banks.first(where: { $0.0 == abbr })?.1 ?? abbr
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        // 「招商银行 信用卡」→「招商银行信用卡」：去掉中文之间由英文空格留下的空白
        return result.replacingOccurrences(of: #"(?<=\p{Han})\s+(?=\p{Han})"#, with: "", options: .regularExpression)
    }
}

/// 信用卡还款识别：「信用卡还款」「还信用卡」「还款到 xx 信用卡」「花呗 / 白条还款」
enum RepaymentDetector {
    static func isCardRepayment(text: String) -> Bool {
        let t = text.replacingOccurrences(of: " ", with: "")
        if t.contains("退款") { return false }
        if t.contains("信用卡还款") || t.contains("还信用卡") || t.contains("信用卡已还") { return true }
        guard t.contains("还款") else { return false }
        if t.contains("信用卡") || t.contains("花呗") || t.contains("白条") || t.contains("还款到") || t.contains("还款至") { return true }
        // 云闪付等：「还款成功 / 还款金额 / 还款卡」+ 银行名
        return ["还款成功", "还款金额", "还款卡", "本期还款", "还款账户"].contains(where: { t.contains($0) }) && t.contains("银行")
    }

    /// 「还款卡 / 还款到 / 还款至 招商银行(1024)」：标签后的银行卡就是被还款的卡
    private static let labelledCard = try! NSRegularExpression(
        pattern: #"(?:还款卡|还款到|还款至|还款信用卡|还款账户)\s*[:：]?\s*([\p{Han}]{2,8}?银行)\s*(信用卡)?\s*(?:尾号)?\s*[（(\[【]?\s*[*＊]*\s*(\d{4})?\s*[)）\]】]?"#)
    /// 付款方式标签
    private static let payerLabel = try! NSRegularExpression(pattern: #"(?:付款卡|付款方式|付款账户|扣款卡|扣款账户|支付方式)\s*[:：]?\s*(.{2,30})"#)

    private static func payerHint(in text: String) -> AccountHint? {
        let ns = text as NSString
        guard let m = payerLabel.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let hint = AccountHintParser.parse(text: ns.substring(with: m.range(at: 1)))
        if let h = hint, h.type == "credit" || h.type == "consumerCredit" { return nil }
        return hint
    }

    private static let cardPattern = try! NSRegularExpression(
        pattern: #"([\p{Han}]{2,8}?银行)?(信用卡|花呗|白条)\s*(?:尾号|末四位)?\s*[（(\[【]?\s*[*＊]*\s*(\d{4})?\s*[)）\]】]?"#)

    /// 拆出被还款的卡与付款账户：带尾号的「xx 信用卡」优先作为卡，其余文字再解析付款方式
    static func split(text: String) -> (card: AccountHint?, payer: AccountHint?) {
        let cleaned = text.replacingOccurrences(of: "信用卡还款", with: " ")
            .replacingOccurrences(of: "还信用卡", with: " ")
        let ns = cleaned as NSString
        if let m = labelledCard.firstMatch(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            var card = AccountHint(type: "credit")
            card.bankName = ns.substring(with: m.range(at: 1))
            if m.range(at: 3).location != NSNotFound { card.cardTail = ns.substring(with: m.range(at: 3)) }
            let rest = ns.replacingCharacters(in: m.range, with: " ")
            var payer = payerHint(in: rest) ?? AccountHintParser.parse(text: rest)
            if let p = payer, p.type == "credit" || p.type == "consumerCredit" { payer = nil }
            return (card, payer)
        }
        let matches = cardPattern.matches(in: cleaned, range: NSRange(location: 0, length: ns.length))
        guard let m = matches.first(where: { $0.range(at: 3).location != NSNotFound }) ?? matches.first else {
            return (AccountHint(type: "credit"), AccountHintParser.parse(text: cleaned))
        }
        var card = AccountHint()
        let kindWord = ns.substring(with: m.range(at: 2))
        card.type = kindWord == "信用卡" ? "credit" : "consumerCredit"
        if m.range(at: 1).location != NSNotFound {
            var bank = ns.substring(with: m.range(at: 1))
            for p in ["信用卡还款", "还款到", "还款至", "还款", "到", "至", "向"] where bank.hasPrefix(p) && bank.count - p.count >= 4 {
                bank = String(bank.dropFirst(p.count))
            }
            card.bankName = bank
        }
        if m.range(at: 3).location != NSNotFound { card.cardTail = ns.substring(with: m.range(at: 3)) }
        let rest = ns.replacingCharacters(in: m.range, with: " ")
        var payer = payerHint(in: rest) ?? AccountHintParser.parse(text: rest)
        if let p = payer, p.type == "credit" || p.type == "consumerCredit" { payer = nil }
        return (card, payer)
    }
}

/// 从支付截图 / 小票 / 银行短信的 OCR 文本中提取金额、商户、时间并猜测分类。
/// 纯 Foundation 实现，不依赖 Apple 专有框架，可在 Linux 上做单元检查（见 Tools/ParserCheck）。
enum ReceiptParser {

    // MARK: - 公共入口

    /// 单笔解析（取第一笔；没有识别到金额时返回 amount 为 nil 的结果）
    static func parse(lines rawLines: [String], now: Date = Date(), calendar: Calendar = .current) -> ParsedReceipt {
        let all = parseAll(lines: rawLines.map { OCRLine($0) }, now: now, calendar: calendar)
        if let first = all.first { return first }
        let lines = prepare(rawLines.map { OCRLine($0) }).map(\.text)
        return parseBlock(lines: lines, heroes: [], now: now, calendar: calendar)
    }

    static func parseAll(lines rawLines: [String], now: Date = Date(), calendar: Calendar = .current) -> [ParsedReceipt] {
        parseAll(lines: rawLines.map { OCRLine($0) }, now: now, calendar: calendar)
    }

    /// 多笔解析：按日期标题（昨天 下午3:25 / 10月17日 / 2026-10-17 …）、银行短信、账单列表行、
    /// 以及多个大字金额（Vision 行高）把截图拆成若干笔交易，按截图从上到下返回。
    static func parseAll(lines rawLines: [OCRLine], now: Date = Date(), calendar: Calendar = .current) -> [ParsedReceipt] {
        let screen = self.screen(rawLines)
        var lines = prepare(rawLines, screen: screen)
        guard !lines.isEmpty else { return [] }
        // 微信聊天里的转账气泡：只取气泡金额，聊天文字里的数字不算
        if screen.layout == .chatTransfer {
            let chat = ScreenLayouts.chatTransfers(texts: lines.map(\.text), now: now, calendar: calendar)
            if !chat.isEmpty { return chat }
        }
        // 支付助手：卡片上方单独一行的「11:09」是这张卡片的时间（今天），当作日期标题
        if screen.layout == .payAssistant {
            let texts = lines.map(\.text)
            for i in lines.indices {
                if let t = ScreenLayouts.assistantHeader(texts: texts, index: i, now: now, calendar: calendar) { lines[i].text = t }
            }
        }
        let texts = lines.map(\.text)
        var segments = TransactionSegmenter.segments(lines: lines)
        // 单笔详情页（交易详情 / 账单详情 / 云闪付 Transaction details）：整页只算一笔，
        // 订单金额 / 优惠 / 交易时间等字段行不能自成一笔
        if screen.layout == .none, !segments.isEmpty, segments.count > 1 || segments[0].range != 0..<texts.count, DetailLabels.isDetailPage(texts, heroCount: Set(segments.flatMap(\.heroes)).count) {
            segments = [TransactionSegmenter.Segment(range: 0..<texts.count, heroes: segments.flatMap(\.heroes))]
        }

        var results: [ParsedReceipt] = []
        var lastHadOwnDate = true
        for seg in segments {
            let blockLines = Array(texts[seg.range])
            let heroes = Set(seg.heroes.map { $0 - seg.range.lowerBound })
            let r = parseBlock(lines: blockLines, heroes: heroes, now: now, calendar: calendar, app: screen.app)
            let threshold: Double = (seg.isPreamble && segments.count > 1) ? 20 : -20
            if r.amount != nil, r.score > threshold {
                results.append(r)
                lastHadOwnDate = r.date != nil
            } else if !lastHadOwnDate, let d = r.date, !results.isEmpty {
                // 小票末尾单独一行的日期，归到上一笔
                results[results.count - 1].date = d
                lastHadOwnDate = true
            }
        }
        if screen.layout == .bankPush { ScreenLayouts.applyBankPush(&results, texts: texts) }
        return OrderAmountGuard.filter(results, lines: texts)
    }

    /// 截图来源（微信 / 支付宝 / 云闪付 / 银行）与界面语言
    static func screen(_ raw: [OCRLine]) -> PaymentScreen {
        PaymentScreenDetector.detect(raw.map { normalize($0.text) })
    }

    /// 规范化（全角 → 半角）+ 英文界面标签转中文。规则解析、Apple 智能提示词与金额校验都用这份文字
    static func prepare(_ raw: [OCRLine], screen: PaymentScreen? = nil) -> [OCRLine] {
        let app = (screen ?? self.screen(raw)).app
        var lines = raw.map { l -> OCRLine in
            var c = l
            c.text = EnglishBankTerms.splitGlued(unglue(stripNoise(normalize(l.text).trimmingCharacters(in: .whitespacesAndNewlines))))
            return c
        }.filter { !$0.text.isEmpty }
        lines = DetailLabels.rejoin(lines)
        return lines.map { l in
            var c = l
            c.text = PaymentTerms.localize(l.text, app: app)
            return c
        }
        .filter { !$0.text.isEmpty }
    }

    /// 按钮 / 菜单 / 推荐入口：「Go to Repay」「去还款」「还款福利」不是还款，「Transactions at this merchant」不是交易
    private static let noisePatterns: [NSRegularExpression] = [
        #"(?i)(?<![A-Za-z])go\s*to\s*repay(?:ment)?(?![A-Za-z])"#, #"(?i)(?<![A-Za-z])repay\s+now(?![A-Za-z])"#,
        #"还款福利|去还款|立即还款"#,
        #"(?i)^\s*(?:view\s+)?(?:all\s+)?transactions?\s+(?:at|with)\s+this\s+merchant\s*[>›]?\s*$"#,
        #"^\s*查看详情\s*[>›]?\s*$"#,
        // 云闪付底部广告「快捷管理 银行卡 / 云闪付银行卡一键查」（会被当成「快捷管理银行」）
        #"^\s*快捷管理.*$"#, #"^.*一键查\s*[>›]?\s*$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// OCR 把标签和值粘在一起：「Order amount¥40.23」「Card NumberSPDBCredit card[1234]」
    private static let gluePatterns: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"([a-z])([¥￥$])"#), "$1 $2"),
        (try! NSRegularExpression(pattern: #"(?i:(card\s*(?:number|no\.?)|payee|order\s*amount|transaction\s*time|payment\s*method))(?=[A-Z0-9\p{Han}])"#), "$1 "),
    ]

    static func unglue(_ line: String) -> String {
        var s = line
        for (re, tpl) in gluePatterns {
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: tpl)
        }
        return s
    }

    static func stripNoise(_ line: String) -> String {
        var s = line
        for re in noisePatterns {
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 解析一笔交易的文本块
    static func parseBlock(lines: [String], heroes: Set<Int>, now: Date, calendar: Calendar, app: PaymentApp = .unknown) -> ParsedReceipt {
        var result = ParsedReceipt()
        result.rawText = lines.joined(separator: "\n")

        var candidates = amountCandidates(lines: lines)
        for i in candidates.indices where heroes.contains(candidates[i].lineIndex) {
            candidates[i].score += 40   // 大字金额
        }
        preferActualPaid(&candidates, lines: lines)
        let best = candidates.max { a, b in
            if a.score == b.score { return a.lineIndex > b.lineIndex } // 同分取靠上的
            return a.score < b.score
        }
        if let best, best.score > -20 {
            result.amount = (best.value * 100).rounded() / 100
            result.score = best.score
        }

        // 收入 / 支出：默认支出，只有明确的收入信号才算收入
        let fullText = lines.joined(separator: " ")
        result.isIncome = IncomeDetector.isIncome(text: fullText, sign: best?.sign ?? "")

        result.merchant = merchant(lines: lines, amountLineIndex: best?.lineIndex)
        // 「美团-示例牛肉饭」→ 商户「示例牛肉饭」，平台「美团」写进备注
        var platform: String?
        if let m = result.merchant {
            let split = splitPlatform(m)
            result.merchant = split.merchant
            platform = split.platform
        }
        // 云闪付等详情：金额上方的平台图标名（美团），商户取 Payee / 收款方
        if platform == nil, let i = best?.lineIndex, i > 0 {
            let above = cleanMerchant(lines[i - 1])
            if platformNames.contains(above), let m = result.merchant, m != above { platform = above }
        }
        if let m = result.merchant, platformNames.contains(m) { platform = nil }
        let notes = [platform, discountNote(lines: lines)].compactMap { $0 }
        result.discountNote = notes.isEmpty ? nil : notes.joined(separator: " · ")
        // 英文界面（Repay:CMB Credit card 等）先转成中文再找账户线索 / 还款
        let hintText = EnglishBankTerms.localize(fullText)
        // 付款方式那一行最准（整段文字里可能还有「微信支付」标题、广告里的银行名）
        result.accountHint = paymentMethodHint(lines: lines) ?? AccountHintParser.parse(text: hintText)
        result.date = date(lines: lines, now: now, calendar: calendar)

        if RepaymentDetector.isCardRepayment(text: hintText) {
            result.isCardRepayment = true
            result.isIncome = false
            result.categoryName = "信用卡还款"
            let split = RepaymentDetector.split(text: hintText)
            result.repaymentCard = split.card
            result.accountHint = split.payer
            // 还款的标题统一为「信用卡还款」（不把「Repay:CMB Credit card」当商户）
            result.merchant = nil
            return result
        }

        // 钱包充值 / 提现 / 余额宝转入转出：自己账户之间的转账
        if let t = SelfTransferDetector.detect(text: hintText, app: app) {
            result.isSelfTransfer = true
            result.isIncome = false
            result.categoryName = nil
            result.merchant = nil
            result.transferFrom = t.from
            result.transferTo = t.to
            result.transferFromName = t.fromName
            result.transferToName = t.toName
            result.transferNote = t.note
            result.accountHint = t.from
            return result
        }

        // 商户关键词 > 平台自带的账单分类（支付宝 Category）> 全文关键词
        if let m = result.merchant, let c = CategoryGuesser.guess(text: m, isIncome: result.isIncome) {
            result.categoryName = c
        } else if let p = platform, let c = CategoryGuesser.guess(text: p, isIncome: result.isIncome) {
            result.categoryName = c
        } else if !result.isIncome, let c = PlatformCategory.find(in: lines) {
            result.categoryName = c
        } else {
            result.categoryName = CategoryGuesser.guess(text: fullText, isIncome: result.isIncome)
        }
        return result
    }

    private static let methodLabel = try! NSRegularExpression(pattern: #"^(?:付款方式|支付方式|付款卡|扣款卡|扣款账户|付款账户|交易账户|交易卡号|银行卡号|卡号)\s*[:：]?\s*(.*)$"#)

    /// 「付款方式 招商银行储蓄卡(1234)」或标签与值分行
    static func paymentMethodHint(lines: [String]) -> AccountHint? {
        for (i, l) in lines.enumerated() {
            let ns = l as NSString
            guard let m = methodLabel.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) else { continue }
            var v = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if v.isEmpty, i + 1 < lines.count { v = lines[i + 1] }
            if v == "余额" { v = "账户余额" }
            if let h = AccountHintParser.parse(text: EnglishBankTerms.localize(v)) { return h }
        }
        return nil
    }

    // MARK: - 规范化

    static func normalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "：": out.append(":")
            case "，": out.append(",")
            case "．": out.append(".")
            case "－", "—", "–", "−": out.append("-")
            case "＋": out.append("+")
            case "￥": out.append("¥")
            case "（": out.append("(")
            case "）": out.append(")")
            case "　": out.append(" ")
            default:
                if let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1,
                   scalar.value >= 0xFF10, scalar.value <= 0xFF19,
                   let half = Unicode.Scalar(scalar.value - 0xFF10 + 0x30) {
                    out.unicodeScalars.append(half) // 全角数字
                } else {
                    out.append(ch)
                }
            }
        }
        // "23. 50" / "23 .50" -> "23.50"
        out = replace(#"(\d)\s*\.\s+(\d)"#, in: out, with: "$1.$2")
        out = replace(#"(\d)\s+\.(\d)"#, in: out, with: "$1.$2")
        return out
    }

    // MARK: - 金额

    struct AmountCandidate: Equatable {
        var value: Double
        var score: Double
        var lineIndex: Int
        var sign: String   // "+", "-", ""
    }

    /// 实付 / 实际成交（优先于订单金额）
    static let strongKeywords = ["实付款", "实付金额", "实付", "实际支付", "实际付款", "实收金额", "实收",
                                 "付款金额", "支付金额", "交易金额", "消费金额", "合计", "总计", "总金额", "总价",
                                 "支出金额", "转账金额", "收款金额", "到账金额", "退款金额", "扣款金额"]
    /// 订单原价 / 应付：有实付或大字带符号金额时让位
    static let orderKeywords = ["订单金额", "应付金额", "应付"]
    static let weakKeywords = ["金额", "价格", "消费", "支出", "付款", "支付", "交易", "扣款", "收款", "到账", "人民币"]
    static let negativeKeywords = ["优惠", "折扣", "立减", "减免", "抵扣", "积分", "余额", "可用", "限额", "额度",
                                   "原价", "运费", "配送费", "包装费", "手续费", "找零", "返现", "券", "满", "单价",
                                   "数量", "已省", "节省", "共省"]
    static let countSuffixes: Set<Character> = ["件", "个", "次", "份", "张", "笔", "位", "人", "天", "期", "号", "楼", "室", "%", "折", "斤", "克", "g", "G", "k", "K", "m", "M"]

    private static let amountPattern = try! NSRegularExpression(
        pattern: #"(?<![\d.,])([+\-]?)\s*(¥|RMB|CNY|HKD|USD|HK\$|US\$|\$|人民币)?\s*([+\-]?)\s*(\d{1,3}(?:,\d{3})+|\d+)(\.\d{1,2})?(?![\d.])\s*(元|CNY|RMB|HKD|USD)?"#)

    private static let removalPatterns: [NSRegularExpression] = [
        #"20\d{2}\s*[-/.年]\s*\d{1,2}\s*[-/.月]\s*\d{1,2}\s*日?"#,
        #"\d{1,2}\s*月\s*\d{1,2}\s*日"#,
        #"\d{1,2}:\d{2}(?::\d{2})?"#,
        #"[A-Za-z0-9]{13,}"#,
        #"\d{9,}"#,
        #"(尾号|卡号|末四位|账户|账号|卡)\s*\(?\s*\*{0,4}\d{3,4}\)?"#,
        #"\(\s*\d{4}\s*\)"#,
        #"\d+(?:\.\d+)?\s*%"#,
        #"[x×X*]\s*\d+"#,
        #"\d+\s*[x×X*]"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static let idLabels = ["订单号", "交易单号", "商户单号", "流水号", "订单编号", "交易号", "参考号", "凭证号", "交易流水", "商户订单号", "商家订单号", "单号"]

    static func isIDLine(_ line: String) -> Bool {
        idLabels.contains { line.hasPrefix($0) }
    }

    static func isIDLabelOnly(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":")))
        return idLabels.contains(t)
    }

    /// 只有字母数字（订单号的值）
    static func isIDValue(_ line: String) -> Bool {
        let t = line.replacingOccurrences(of: " ", with: "")
        return t.count >= 6 && t.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } && t.contains(where: \.isNumber)
    }

    static func cleanForAmounts(_ line: String) -> String {
        var s = line
        for re in removalPatterns {
            let ns = s as NSString
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        }
        return s
    }

    static func amountCandidates(lines: [String]) -> [AmountCandidate] {
        var all: [AmountCandidate] = []
        var lineHadCandidates = [Bool](repeating: false, count: lines.count)

        for (index, line) in lines.enumerated() {
            // 订单号 / 交易单号 / 流水号（含标签与号码分行）不是金额
            if isIDLine(line) || (index > 0 && isIDLabelOnly(lines[index - 1]) && isIDValue(line)) { continue }
            let cleaned = cleanForAmounts(line)
            let ns = cleaned as NSString
            let matches = amountPattern.matches(in: cleaned, range: NSRange(location: 0, length: ns.length))
            var previousEnd = 0
            var lineCandidates: [AmountCandidate] = []

            for m in matches {
                let intPart = group(m, 4, ns).replacingOccurrences(of: ",", with: "")
                let decPart = group(m, 5, ns)
                guard let value = Double(intPart + decPart), value > 0 else { previousEnd = m.range.location + m.range.length; continue }

                let sign1 = group(m, 1, ns), sign2 = group(m, 3, ns)
                let sign = !sign1.isEmpty ? sign1 : sign2
                let hasCurrency = !group(m, 2, ns).isEmpty || !group(m, 6, ns).isEmpty

                let labelRange = NSRange(location: previousEnd, length: max(0, m.range.location - previousEnd))
                var label = ns.substring(with: labelRange)
                if group(m, 2, ns) == "人民币" { label += "人民币" }
                previousEnd = m.range.location + m.range.length

                var score: Double = 0
                var hasKeyword = false

                if strongKeywords.contains(where: { label.contains($0) }) {
                    score += 60; hasKeyword = true
                } else if orderKeywords.contains(where: { label.contains($0) }) {
                    score += 28; hasKeyword = true   // 低于带符号的整行金额
                } else if weakKeywords.contains(where: { label.contains($0) }) {
                    score += 30; hasKeyword = true
                }
                // 标签与金额分行（如「实付款」下一行是「¥20.00」）
                if !hasKeyword, lineCandidates.isEmpty, label.trimmingCharacters(in: .whitespaces).count <= 1,
                   index > 0, !lineHadCandidates[index - 1] {
                    let prev = lines[index - 1]
                    if strongKeywords.contains(where: { prev.contains($0) }) { score += 45; hasKeyword = true }
                    else if orderKeywords.contains(where: { prev.contains($0) }) { score += 22; hasKeyword = true }
                    else if weakKeywords.contains(where: { prev.contains($0) }) { score += 20; hasKeyword = true }
                    if negativeKeywords.contains(where: { prev.contains($0) }) { score -= 55 }
                }
                // 只看紧邻金额前面的一小段做负向判断，避免整行误伤
                let nearLabel = String(label.suffix(8))
                if negativeKeywords.contains(where: { nearLabel.contains($0) }) { score -= 55 }

                if hasCurrency { score += 30 }
                if decPart.count == 3 { score += 20 } else if decPart.count == 2 { score += 10 }
                if sign == "-" || sign == "+" { score += 25 }

                // 整行只有这个金额（微信/支付宝/云闪付详情页的大字金额）
                let rest = ns.replacingCharacters(in: m.range, with: "")
                    .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":-+")))
                let amountOnly = rest.isEmpty
                if amountOnly { score += 20 }
                // 带正负号的整行金额（如「-¥14.96」）优先于下方「订单金额」
                if amountOnly && (sign == "-" || sign == "+") { score += 15 }

                if decPart.isEmpty && !hasCurrency {
                    score -= 15
                    if !hasKeyword { score -= 10 }
                    if value >= 1900 && value <= 2100 { score -= 30 }
                }
                // 紧跟量词：「共3件」「2人」
                let afterLoc = m.range.location + m.range.length
                if afterLoc < ns.length {
                    let after = ns.substring(from: afterLoc).trimmingCharacters(in: .whitespaces)
                    if let c = after.first, countSuffixes.contains(c), !hasCurrency { score -= 50 }
                }
                if value > 1_000_000 { score -= 60 }
                score -= Double(index) * 0.3

                lineCandidates.append(AmountCandidate(value: value, score: score, lineIndex: index, sign: sign))
            }
            lineHadCandidates[index] = !lineCandidates.isEmpty
            all.append(contentsOf: lineCandidates)
        }
        return all
    }


    /// 同时出现「订单金额 / 应付」与带符号整行金额（或实付）且差额≈优惠时，抬高实付候选
    private static func preferActualPaid(_ candidates: inout [AmountCandidate], lines: [String]) {
        guard candidates.count >= 2 else { return }
        func looksOrder(_ c: AmountCandidate) -> Bool {
            let i = c.lineIndex
            if orderKeywords.contains(where: { lines[i].contains($0) }) { return true }
            if i > 0, orderKeywords.contains(where: { lines[i - 1].contains($0) }) { return true }
            return false
        }
        func looksPaid(_ c: AmountCandidate) -> Bool {
            if signedAmountOnly(c, lines: lines) { return true }
            let i = c.lineIndex
            if strongKeywords.contains(where: { lines[i].contains($0) }) { return true }
            if i > 0, strongKeywords.contains(where: { lines[i - 1].contains($0) }) { return true }
            return false
        }
        func looksDiscount(_ c: AmountCandidate) -> Bool {
            let i = c.lineIndex
            let near = lines[i] + (i > 0 ? lines[i - 1] : "")
            return negativeKeywords.contains(where: { near.contains($0) })
        }
        guard let order = candidates.filter(looksOrder).max(by: { $0.score < $1.score }) else { return }
        let discountVal = candidates.filter(looksDiscount).map(\.value).max() ?? 0
        let expected = ((order.value - discountVal) * 100).rounded() / 100
        let paids = candidates.filter(looksPaid)
        guard let paid = paids.min(by: { abs($0.value - expected) < abs($1.value - expected) }) else { return }
        let paidR = (paid.value * 100).rounded() / 100
        let closeToExpected = abs(paidR - expected) < 0.021
        let sameAsOrderAbove = discountVal == 0 && abs(paidR - order.value) < 0.021 && paid.lineIndex < order.lineIndex
        guard closeToExpected || sameAsOrderAbove else { return }
        if let idx = candidates.firstIndex(where: { $0.lineIndex == paid.lineIndex && abs($0.value - paid.value) < 0.001 }) {
            candidates[idx].score += 50
        }
    }

    private static func signedAmountOnly(_ c: AmountCandidate, lines: [String]) -> Bool {
        guard c.sign == "-" || c.sign == "+" else { return false }
        let cleaned = cleanForAmounts(lines[c.lineIndex])
        let ns = cleaned as NSString
        guard let m = amountPattern.firstMatch(in: cleaned, range: NSRange(location: 0, length: ns.length)) else { return false }
        let rest = ns.replacingCharacters(in: m.range, with: "")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":-+")))
        return rest.isEmpty
    }

    /// 「优惠信息 / 满2随机立减 -¥0.04」→「随机立减 0.04」
    static func discountNote(lines: [String]) -> String? {
        let join = lines.joined(separator: " ")
        guard join.contains("优惠") || join.contains("立减") || join.contains("满减") || join.contains("折扣") else { return nil }
        let specs: [(String, String)] = [
            (#"云闪付立减\s*[:：]?\s*[¥￥\-]*\s*(\d+(?:\.\d{1,2})?)"#, "云闪付立减"),
            (#"随机立减\s*[:：]?\s*[¥￥\-]*\s*(\d+(?:\.\d{1,2})?)"#, "随机立减"),
            (#"满\d+(?:\.\d+)?(?:元)?(?:随机)?立减\s*[:：]?\s*[¥￥\-]*\s*(\d+(?:\.\d{1,2})?)"#, "随机立减"),
            (#"(?:优惠|立减|满减|折扣)[^\d]{0,16}(\d+\.\d{1,2})"#, "优惠"),
        ]
        for (pat, label) in specs {
            guard let re = try? NSRegularExpression(pattern: pat) else { continue }
            let ns = join as NSString
            if let m = re.firstMatch(in: join, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 {
                let amt = ns.substring(with: m.range(at: 1))
                if let v = Double(amt), v > 0, v < 10_000 {
                    return "\(label) \(amt)"
                }
            }
        }
        return nil
    }

    // MARK: - 商户

    static let merchantKeywords = ["商户全称", "商户名称", "交易对象", "商家名称", "收款方全称", "收款商户", "收款方", "收款人",
                                   "交易对方", "对方账户", "对方户名", "付款方", "付款人", "商品说明", "商品名称", "付款给", "转账给",
                                   "店铺名称", "门店名称", "商户", "商家", "店铺", "门店", "对方"]
    static let merchantBlacklist = ["支付成功", "付款成功", "交易成功", "支付完成", "账单详情", "交易详情", "完成",
                                    "当前状态", "返回", "已支付", "订单详情", "转账成功", "收款成功", "收款到账",
                                    "已收款", "数量", "单价", "金额", "合计", "实付", "支付方式", "付款方式",
                                    "账单分类", "订单号", "交易单号", "商户单号", "支付时间", "交易时间", "创建时间",
                                    "备注", "查看", "联系", "申请", "电子小票", "全部账单", "微信支付", "支付宝",
                                    "待收货", "已完成", "零钱", "储蓄卡", "信用卡", "交易状态", "留言", "我的账单",
                                    "支付服务", "账单服务", "付款成功", "对方已收款", "退款成功", "退款方式",
                                    "优惠信息", "优惠详情", "活动优惠", "随机立减", "满减", "云闪付", "订单金额",
                                    "优惠", "立减", "折扣", "支付助手", "交易提醒", "服务通知", "支付消息", "精彩动态", "搜索消息号", "交易类型"]

    /// 平台名（「美团-xx」的前缀、云闪付详情金额上方的图标名）
    static let platformNames: Set<String> = ["美团", "美团外卖", "饿了么", "拼多多", "京东", "支付宝", "财付通", "抖音", "淘宝", "天猫",
                                             "Meituan", "Eleme", "JD"]
    private static let platformPrefix = try! NSRegularExpression(
        pattern: #"^(美团外卖|美团|饿了么|拼多多|京东|支付宝|财付通|抖音|淘宝|天猫|(?i:meituan|eleme))\s*[-—_·:：]\s*(.{2,})$"#)

    /// 「美团-示例牛肉饭」→ ("示例牛肉饭", "美团")；没有平台前缀时原样返回
    static func splitPlatform(_ merchant: String) -> (merchant: String, platform: String?) {
        let ns = merchant as NSString
        guard let m = platformPrefix.firstMatch(in: merchant, range: NSRange(location: 0, length: ns.length)) else { return (merchant, nil) }
        var p = ns.substring(with: m.range(at: 1))
        if p.lowercased() == "meituan" { p = "美团" } else if p.lowercased() == "eleme" { p = "饿了么" }
        let rest = cleanMerchant(ns.substring(with: m.range(at: 2)))
        return rest.count >= 2 ? (rest, p) : (merchant, nil)
    }

    static func merchant(lines: [String], amountLineIndex: Int?) -> String? {
        for key in merchantKeywords {
            for (i, line) in lines.enumerated() {
                guard let r = line.range(of: key) else { continue }
                // 关键词需位于行首附近（避免「请向商家确认」之类）
                guard line.distance(from: line.startIndex, to: r.lowerBound) <= 2 else { continue }
                if line[r.upperBound...].hasPrefix("式") { continue }   // 「付款方式」不是「付款方」
                var value = String(line[r.upperBound...])
                value = cleanMerchant(value)
                if value.isEmpty, i + 1 < lines.count { value = cleanMerchant(lines[i + 1]) }
                if isPlausibleMerchant(value), !DetailLabels.isLabel(value) { return value }
                // 值在标签上面（OCR 阅读顺序：「示例店 / 收款方 / 浦发银行信用卡[1234]」）
                if String(line[r.upperBound...]).trimmingCharacters(in: merchantTrim).isEmpty, i > 0, i - 1 != amountLineIndex {
                    let prev = cleanMerchant(lines[i - 1])
                    if isPlausibleMerchant(prev), !DetailLabels.isLabel(prev), !platformNames.contains(prev) { return prev }
                }
            }
        }
        // 兜底：从金额所在行往上找第一行像名称的文本
        if let idx = amountLineIndex, idx > 0 {
            for i in stride(from: idx - 1, through: 0, by: -1) {
                let v = cleanMerchant(lines[i])
                guard isPlausibleMerchant(v) else { continue }
                // 金额上方是平台图标名（美团）且下面有收款方标签：商户在字段区（标签与值分开排列）
                if platformNames.contains(v), lines.contains(where: { DetailLabels.merchantLabels.contains($0.trimmingCharacters(in: .whitespaces)) }) {
                    for j in (idx + 1)..<lines.count {
                        let w = cleanMerchant(lines[j])
                        if isPlausibleMerchant(w), !DetailLabels.isLabel(w), !platformNames.contains(w), w.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }),
                           AccountHintParser.parse(text: w) == nil { return w }
                    }
                }
                return v
            }
        }
        // 金额同一行前面的文字（账单列表「滴滴出行 -23.50」）
        if let idx = amountLineIndex, idx < lines.count {
            let label = cleanMerchant(lines[idx].replacingOccurrences(
                of: #"\s*[+-]?\s*(?:¥|CNY|RMB|HK\$|US\$|\$)?\s*[+-]?\s*[\d,]+(\.\d{1,2})?\s*(?:元|CNY|RMB)?\s*$"#, with: "", options: .regularExpression))
            if label != cleanMerchant(lines[idx]), isPlausibleMerchant(label) { return label }
        }
        // 银行短信：「…在美团支付交易人民币45.60元」
        let joined = lines.joined(separator: " ")
        if let r = joined.range(of: #"在([\p{Han}A-Za-z0-9()（）·\-]{2,20}?)(?:消费|支付|交易|扣款|付款)"#, options: .regularExpression) {
            var v = String(joined[r])
            v = String(v.dropFirst())
            for suffix in ["消费", "支付", "交易", "扣款", "付款"] where v.hasSuffix(suffix) { v = String(v.dropLast(suffix.count)); break }
            v = cleanMerchant(v)
            if isPlausibleMerchant(v) { return v }
        }
        // 再往下看两行（「订单金额 ¥1299」下一行才是商户的情况）
        if let idx = amountLineIndex {
            for i in (idx + 1)..<min(idx + 3, lines.count) {
                let v = cleanMerchant(lines[i])
                if isPlausibleMerchant(v) { return v }
            }
        }
        return nil
    }

    /// 头像 / 图标被 OCR 成的杂字符：「C 阿芳」「é阿芳」「© 美团」
    private static let avatarArtifactPatterns: [NSRegularExpression] = [
        #"^[^\p{L}\p{N}(（]+"#,                       // 开头的符号
        #"^[A-Za-zÀ-ÿ]{1,2}\s+(?=\p{Han})"#,           // 单个（或两个）拉丁字母 + 空格 + 汉字
        #"^[À-ÿ](?=\p{Han})"#,                         // 带重音的单字母紧贴汉字
        #"^[\p{Han}]\s+(?=[\p{Han}]{2,})"#,           // 单个汉字图标 + 空格（如「微 美团外卖」）
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let merchantTrim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":>›〉》»|.…·"))

    static func cleanMerchant(_ s: String) -> String {
        var v = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":>›〉》»|")))
        // 英文前缀与结尾省略号 / 箭头：「Merchant: Starbucks…」「示例便利店 >」
        v = v.replacingOccurrences(of: #"^(?i:merchant|payee|paid\s+to|pay\s+to|recipient|store)\s*[:：]?\s+"#, with: "", options: .regularExpression)
        v = v.replacingOccurrences(of: #"(?:\.{2,}|…+|\s*[>›»]+)\s*$"#, with: "", options: .regularExpression)
        // 微信账单标题「扫二维码付款-给示例水果店」「转账-给 xx」
        v = v.replacingOccurrences(of: #"^(?:扫二维码付款|二维码付款|扫码付款|付款|转账)\s*-?\s*给\s*"#, with: "", options: .regularExpression)
        // 英文公司后缀：「Sample Store Co., Ltd.」→「Sample Store」
        v = v.replacingOccurrences(of: #"(?i)[\s,]+(?:co\.?,?\s*ltd\.?|company\s+limited|limited|ltd\.?|inc\.?|llc)\s*$"#, with: "", options: .regularExpression)
        for re in avatarArtifactPatterns {
            let ns = v as NSString
            v = re.stringByReplacingMatches(in: v, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        }
        v = v.trimmingCharacters(in: merchantTrim)
        // 被截断的「示例牛肉饭(示例大厦…」：去掉没有右括号的分店部分
        if let open = v.lastIndex(of: "("), !v[open...].contains(")"), v.distance(from: v.startIndex, to: open) >= 2 {
            v = String(v[..<open]).trimmingCharacters(in: merchantTrim)
        }
        if v.count > 30 { v = String(v.prefix(30)).trimmingCharacters(in: .whitespaces) }
        return v
    }

    /// 英文界面里没被转成中文的按钮 / 页面文字
    static let englishBlacklist: Set<String> = ["details", "detail", "done", "back", "bills", "bill", "more", "help", "share", "view",
                                                "customer service", "contact merchant", "need help", "view all", "all", "filter", "search",
                                                "successful", "success", "completed", "paid", "pending", "cny", "rmb"]

    static func isPlausibleMerchant(_ s: String) -> Bool {
        guard s.count >= 2, s.count <= 30 else { return false }
        if merchantBlacklist.contains(where: { s.contains($0) }) { return false }
        if englishBlacklist.contains(s.lowercased()) { return false }
        if s.hasPrefix("收到转账") || s.hasPrefix("收到红包") || s == "红包" || s == "转账" || s == "退款" || s == "全部账单" { return false }
        if ["余额", "账户余额", "零钱", "零钱通", "余额宝", "花呗", "微信支付", "支付宝"].contains(s) { return false }
        if s.hasPrefix("使用") && s.contains("支付") { return false }       // 「使用零钱支付」
        if TransactionSegmenter.isDateHeader(s) { return false }
        // 交易类型 / 分类 / 支付网络的值：「消费」「Consumption」「Other Categories-Other」「UnionPay」
        if DetailLabels.isLabel(s) { return false }
        if DetailLabels.fieldValues.contains(s) || DetailLabels.fieldValues.contains(s.lowercased()) { return false }
        if s.range(of: #"(?i)categor|其他分类|^银联|unionpay"#, options: .regularExpression) != nil { return false }
        let digits = s.filter { $0.isNumber }.count
        if digits >= 3 { return false }
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return letters >= 2
    }

    // MARK: - 日期

    static let periodPattern = "凌晨|早上|早晨|上午|中午|下午|傍晚|晚上|夜里|夜间"
    /// 12 小时制后缀：PM / p.m. / AM
    private static let ampmPattern = #"(?:\s*([AaPp])\.?\s?[Mm]\.?(?![A-Za-z]))?"#
    // 前后不能紧挨数字：订单号 / 流水号里的「…2026.10.26…」「12026-10-26」不是日期
    private static let fullDatePattern = try! NSRegularExpression(
        pattern: #"(?<![\d.])(20\d{2})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})(?!\d)\s*日?[\sT]*(?:("# + periodPattern + #")?\s*(\d{1,2}):(\d{2})(?::(\d{2}))?"# + ampmPattern + ")?")
    private static let monthDayPattern = try! NSRegularExpression(
        pattern: #"(?<!\d)(\d{1,2})\s*月\s*(\d{1,2})\s*日\s*(?:("# + periodPattern + #")?\s*(\d{1,2}):(\d{2}))?"#)
    private static let relativePattern = try! NSRegularExpression(
        pattern: #"(今天|昨天|前天|星期[一二三四五六日天]|周[一二三四五六日天])?\s*("# + periodPattern + #")?\s*(\d{1,2}):(\d{2})"#)
    // 「10-26 14:03」「10/26 14:03」（无年份）
    private static let dashMonthDayPattern = try! NSRegularExpression(
        pattern: #"(?<![\d\-/.])(\d{1,2})[-/](\d{1,2})(?![\d/])\s+(\d{1,2}):(\d{2})"#)
    private static let bareDayPattern = try! NSRegularExpression(pattern: #"(今天|昨天|前天)"#)
    static let englishMonths = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    private static let monthNamePattern = #"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)(?:[a-z]{0,6})\.?"#
    private static let englishTimePattern = #"(?:\s*,?\s*(?:at\s+)?(\d{1,2}):(\d{2})(?::(\d{2}))?"# + ampmPattern + ")?"
    // 「Oct 26, 2026 14:03」「October 26 2026 at 2:03 PM」「Oct 26 14:03」（年份可省略）
    private static let englishMonthFirst = try! NSRegularExpression(
        pattern: #"(?i)(?<![A-Za-z])"# + monthNamePattern + #"\s+(\d{1,2})(?:st|nd|rd|th)?(?!\d)(?:\s*,?\s*(20\d{2})(?!\d))?"# + englishTimePattern)
    // 「26 Oct 2026 14:03」「26 Oct, 2026」
    private static let englishDayFirst = try! NSRegularExpression(
        pattern: #"(?i)(?<![\d:])(\d{1,2})\s+"# + monthNamePattern + #"(?:\s*,?\s*(20\d{2})(?!\d))?"# + englishTimePattern)
    // 「10/26/2026 14:03」（美式）/「26/10/2026 14:03」（日在前，日 > 12 时可判断）
    private static let slashYearLastPattern = try! NSRegularExpression(
        pattern: #"(?<![\d/])(\d{1,2})/(\d{1,2})/(20\d{2})(?!\d)(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?"# + ampmPattern + ")?")
    /// 交易时间标签：同一行出现时优先取这一行的时间；只有「时:分」时也只认带标签的（单独的「14:32」多半是状态栏）
    static let timeLabelPattern = #"(?i)(支付时间|付款时间|交易时间|创建时间|下单时间|到账时间|转账时间|收款时间|消费时间|完成时间|记账时间|提现时间|充值时间|退款时间|还款时间|入账时间|交易日期|payment time|transaction time|transaction date|time of payment|order time|created|date|time)"#
    private static let labeledTimePattern = try! NSRegularExpression(
        pattern: timeLabelPattern + #"\s*[:：]?\s*("# + periodPattern + #")?\s*(\d{1,2}):(\d{2})(?::\d{2})?"# + ampmPattern)
    private static let timeLabelRegex = try! NSRegularExpression(pattern: timeLabelPattern)

    /// 交易时间允许晚于截图 / 现在的容差（时钟误差）
    static let futureTolerance: TimeInterval = 15 * 60
    /// 早于截图时间这么久的日期视为误识别（例如证件有效期、商品生产日期）
    static let maxPast: TimeInterval = 10 * 366 * 86_400

    /// 「下午3:25」→ 15:25，「凌晨12:30」→ 0:30
    static func hour24(_ h: Int, period: String) -> Int {
        switch period {
        case "下午", "傍晚", "晚上", "夜里", "夜间": return h < 12 ? h + 12 : h
        case "中午": return h < 11 ? h + 12 : h
        case "凌晨", "早上", "早晨", "上午": return h == 12 ? 0 : h
        default: return h
        }
    }

    /// 「2:03 PM」→ 14:03，「12:10 AM」→ 0:10；ampm 为空时原样返回
    static func hour12(_ h: Int, ampm: String) -> Int {
        switch ampm.lowercased() {
        case "p": return h < 12 ? h + 12 : h
        case "a": return h == 12 ? 0 : h
        default: return h
        }
    }

    private static func dayOffset(_ word: String, now: Date, calendar: Calendar) -> Int? {
        switch word {
        case "": return nil
        case "今天": return 0
        case "昨天": return -1
        case "前天": return -2
        default:
            let names: [Character: Int] = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
            guard let ch = word.last, let weekday = names[ch] else { return nil }
            for back in 1...7 {
                if let d = calendar.date(byAdding: .day, value: -back, to: now),
                   calendar.component(.weekday, from: d) == weekday { return -back }
            }
            return nil
        }
    }

    /// 交易时间是否合理：不晚于参考时间（截图时间，没有则为现在）+ 容差，也不早于参考时间 10 年以上
    static func isPlausible(_ d: Date, reference: Date) -> Bool {
        d <= reference.addingTimeInterval(futureTolerance) && d >= reference.addingTimeInterval(-maxPast)
    }

    /// 从文字中找交易时间。`now` 是参考时间：截图时间（拿得到时）或现在，
    /// 用于推断「今天 / 昨天」、补全缺失的年份，并拒绝晚于它的日期。
    static func date(lines: [String], now: Date, calendar: Calendar) -> Date? {
        let text = lines.joined(separator: "\n")
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)

        /// 同一种写法有多处时：带「支付时间 / 交易时间」等标签的行优先，其次取第一个合理的
        func best(_ regex: NSRegularExpression, _ make: (NSTextCheckingResult) -> Date?) -> Date? {
            var first: Date?
            for m in regex.matches(in: text, range: range) {
                guard let d = make(m), isPlausible(d, reference: now) else { continue }
                if labeled(m.range, ns) { return d }
                if first == nil { first = d }
            }
            return first
        }
        /// 没有年份：取参考时间所在年；那一天在参考时间之后（例如 1 月初看到「12-31」）则是去年
        func inferYear(_ c: DateComponents) -> Date? {
            var c = c
            c.year = calendar.component(.year, from: now)
            guard valid(c), var d = calendar.date(from: c) else { return nil }
            if calendar.startOfDay(for: d) > now, let prev = calendar.date(byAdding: .year, value: -1, to: d) { d = prev }
            return d
        }
        /// 只有日期没有时间：当天按参考时间（不会晚于截图），其他日子按中午 12 点
        func noonOrReference(_ d: Date, hasTime: Bool) -> Date {
            guard !hasTime else { return d }
            if calendar.isDate(d, inSameDayAs: now), d > now { return now }
            return d
        }

        if let d = best(fullDatePattern, { m in
            var c = DateComponents()
            c.year = Int(group(m, 1, ns)); c.month = Int(group(m, 2, ns)); c.day = Int(group(m, 3, ns))
            let hasTime = !group(m, 5, ns).isEmpty
            c.hour = hour12(hour24(Int(group(m, 5, ns)) ?? 12, period: group(m, 4, ns)), ampm: group(m, 8, ns))
            c.minute = Int(group(m, 6, ns)) ?? 0; c.second = Int(group(m, 7, ns)) ?? 0
            guard valid(c), let d = calendar.date(from: c) else { return nil }
            return noonOrReference(d, hasTime: hasTime)
        }) { return d }
        if let d = best(englishMonthFirst, { m in englishDate(m, ns, month: 1, day: 2, year: 3, time: 4, calendar: calendar, inferYear: inferYear, adjust: noonOrReference) }) { return d }
        if let d = best(englishDayFirst, { m in englishDate(m, ns, month: 2, day: 1, year: 3, time: 4, calendar: calendar, inferYear: inferYear, adjust: noonOrReference) }) { return d }
        if let d = best(slashYearLastPattern, { m in
            guard let a = Int(group(m, 1, ns)), let b = Int(group(m, 2, ns)) else { return nil }
            var c = DateComponents()
            // 默认美式 月/日/年；第一个数 > 12 时是 日/月/年
            (c.month, c.day) = a > 12 ? (b, a) : (a, b)
            c.year = Int(group(m, 3, ns))
            let hasTime = !group(m, 4, ns).isEmpty
            c.hour = hour12(Int(group(m, 4, ns)) ?? 12, ampm: group(m, 7, ns))
            c.minute = Int(group(m, 5, ns)) ?? 0; c.second = Int(group(m, 6, ns)) ?? 0
            guard valid(c), let d = calendar.date(from: c) else { return nil }
            return noonOrReference(d, hasTime: hasTime)
        }) { return d }
        if let d = best(monthDayPattern, { m in
            var c = DateComponents()
            c.month = Int(group(m, 1, ns)); c.day = Int(group(m, 2, ns))
            let hasTime = !group(m, 4, ns).isEmpty
            c.hour = hour24(Int(group(m, 4, ns)) ?? 12, period: group(m, 3, ns))
            c.minute = Int(group(m, 5, ns)) ?? 0
            return inferYear(c).map { noonOrReference($0, hasTime: hasTime) }
        }) { return d }
        var rejectedDayWord = false   // 「今天 23:00」晚于截图：整句不可信，也不退回到单独的「今天」
        for m in relativePattern.matches(in: text, range: range) {
            let dayWord = group(m, 1, ns), period = group(m, 2, ns)
            guard !dayWord.isEmpty || !period.isEmpty else { continue }   // 单独的「14:32」多半是状态栏
            guard let h = Int(group(m, 3, ns)), let mi = Int(group(m, 4, ns)), h < 24, mi < 60 else { continue }
            let offset = dayOffset(dayWord, now: now, calendar: calendar) ?? 0
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  var d = calendar.date(bySettingHour: hour24(h, period: period), minute: mi, second: 0, of: day) else { continue }
            // 只有「下午3:00」没有日期、且晚于参考时间：视为昨天
            if dayWord.isEmpty, d > now.addingTimeInterval(300), let y = calendar.date(byAdding: .day, value: -1, to: d) { d = y }
            guard isPlausible(d, reference: now) else {
                if !dayWord.isEmpty { rejectedDayWord = true }
                continue
            }
            return d
        }
        if let d = best(dashMonthDayPattern, { m in
            var c = DateComponents()
            c.month = Int(group(m, 1, ns)); c.day = Int(group(m, 2, ns))
            c.hour = Int(group(m, 3, ns)); c.minute = Int(group(m, 4, ns))
            return inferYear(c)
        }) { return d }
        // 「支付时间 14:03」：只有时分，按参考时间（截图）那天；晚于参考时间则是前一天
        for m in labeledTimePattern.matches(in: text, range: range) {
            guard let h = Int(group(m, 3, ns)), let mi = Int(group(m, 4, ns)), h < 24, mi < 60 else { continue }
            let hour = hour12(hour24(h, period: group(m, 2, ns)), ampm: group(m, 5, ns))
            guard var d = calendar.date(bySettingHour: hour, minute: mi, second: 0, of: now) else { continue }
            if d > now.addingTimeInterval(300), let y = calendar.date(byAdding: .day, value: -1, to: d) { d = y }
            return d
        }
        if !rejectedDayWord, let m = bareDayPattern.firstMatch(in: text, range: range),
           let offset = dayOffset(group(m, 1, ns), now: now, calendar: calendar),
           let day = calendar.date(byAdding: .day, value: offset, to: now),
           let d = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) {
            return min(d, now)
        }
        return nil
    }

    private static func englishDate(_ m: NSTextCheckingResult, _ ns: NSString, month: Int, day: Int, year: Int, time: Int,
                                    calendar: Calendar, inferYear: (DateComponents) -> Date?,
                                    adjust: (Date, Bool) -> Date) -> Date? {
        guard let mo = englishMonths[String(group(m, month, ns).prefix(3)).lowercased()] else { return nil }
        var c = DateComponents()
        c.month = mo; c.day = Int(group(m, day, ns))
        let hasTime = !group(m, time, ns).isEmpty
        c.hour = hour12(Int(group(m, time, ns)) ?? 12, ampm: group(m, time + 3, ns))
        c.minute = Int(group(m, time + 1, ns)) ?? 0; c.second = Int(group(m, time + 2, ns)) ?? 0
        let d: Date?
        if let y = Int(group(m, year, ns)) {
            c.year = y
            d = valid(c) ? calendar.date(from: c) : nil
        } else {
            // 没有年份也没有时间的「May 5」太容易误判（英文单词），不取
            guard hasTime else { return nil }
            d = inferYear(c)
        }
        return d.map { adjust($0, hasTime) }
    }

    /// 匹配所在的那一行是否带交易时间标签（支付时间 / Payment Time …）
    private static func labeled(_ r: NSRange, _ ns: NSString) -> Bool {
        let line = ns.lineRange(for: r)
        let prefix = NSRange(location: line.location, length: max(0, r.location - line.location))
        return timeLabelRegex.firstMatch(in: ns as String, range: prefix) != nil
    }

    /// 截图顶部状态栏的时钟（「14:32」，只有时分）：只作为找不到交易时间、也拿不到截图时间时的弱线索。
    /// 只看最上面 3 行里 midY < 0.06 的行；没有位置信息（midY 全为 0）时只看第一行。
    static func statusBarClock(_ lines: [OCRLine]) -> (hour: Int, minute: Int)? {
        let positioned = lines.contains { $0.midY > 0 }
        let candidates = positioned ? lines.prefix(3).filter { $0.midY < 0.06 } : Array(lines.prefix(1))
        for line in candidates {
            let t = line.text.trimmingCharacters(in: .whitespaces)
            guard let r = t.range(of: #"^(\d{1,2}):(\d{2})(?!\d)"#, options: .regularExpression) else { continue }
            // 后面只能跟很短的信号 / 电量文字（「5G 80」），不能是一整句
            guard t[r.upperBound...].count <= 12 else { continue }
            let parts = t[r].split(separator: ":")
            guard let h = Int(parts[0]), let m = Int(parts[1]), h < 24, m < 60 else { continue }
            return (h, m)
        }
        return nil
    }

    private static func valid(_ c: DateComponents) -> Bool {
        guard let mo = c.month, let d = c.day else { return false }
        return (1...12).contains(mo) && (1...31).contains(d) && (0...23).contains(c.hour ?? 0) && (0...59).contains(c.minute ?? 0)
            && (0...59).contains(c.second ?? 0)
    }

    // MARK: - 工具

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ ns: NSString) -> String {
        guard i < m.numberOfRanges else { return "" }
        let r = m.range(at: i)
        guard r.location != NSNotFound else { return "" }
        return ns.substring(with: r)
    }

    private static func replace(_ pattern: String, in s: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}

/// 收入 / 支出判断。默认支出；「对方已收款」是对方收到钱，属于支出。
enum IncomeDetector {
    /// 明确的支出信号
    static let expensePatterns: [NSRegularExpression] = [
        #"对方已收款|对方已收钱|待对方收款|等待对方收款"#,
        #"支付成功|付款成功|已支付|支付完成|付款完成"#,
        #"使用.{0,20}?支付"#,
        #"实付|扣款|消费|付款给|转账给|向.{1,12}付款|支出|还款"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// 明确的收入信号（先去掉「对方已收款」等表述再匹配）
    static let incomePatterns: [NSRegularExpression] = [
        #"收款到账|收款成功|已收款|已收钱|到账成功|已到账|入账|转入成功|已存入|收到转账|收到红包"#,
        #"退款成功|已退款|退款到账|退款金额|退回"#,
        #"收入|工资|代发|存入|转入"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static let neutralizers = ["对方已收款", "对方已收钱", "待对方收款", "等待对方收款", "可用余额", "转入账户"]

    static func isIncome(text: String, sign: String) -> Bool {
        if sign == "-" { return false }
        let expense = expensePatterns.contains { matches($0, text) }
        if sign == "+" { return !expense || strongIncome(text) }
        var cleaned = text
        for n in neutralizers { cleaned = cleaned.replacingOccurrences(of: n, with: " ") }
        let income = incomePatterns.contains { matches($0, cleaned) }
        if !income { return false }
        if !expense { return true }
        // 两种信号都有：退款 / 到账类明确信号优先，否则按支出
        return strongIncome(cleaned)
    }

    private static func strongIncome(_ text: String) -> Bool {
        ["退款成功", "已退款", "退款到账", "收款到账", "到账成功", "收到转账", "已存入零钱", "红包已存入"].contains { text.contains($0) }
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}

/// 把一张截图的 OCR 行切分成若干笔交易
enum TransactionSegmenter {
    struct Segment: Equatable {
        var range: Range<Int>
        var heroes: [Int] = []       // 大字金额所在行（全局下标）
        var isPreamble = false       // 第一个分隔点之前的内容（状态栏、导航标题等）
    }

    private static let headerPatterns: [NSRegularExpression] = [
        #"20\d{2}\s*[-/.年]\s*\d{1,2}\s*[-/.月]\s*\d{1,2}\s*日?"#,
        #"\d{1,2}\s*月\s*\d{1,2}\s*日"#,
        #"(?<![\d-])\d{1,2}-\d{1,2}(?=\s+\d{1,2}:\d{2})"#,
        #"今天|昨天|前天|星期[一二三四五六日天]|周[一二三四五六日天]"#,
        #"(?:"# + ReceiptParser.periodPattern + #")\s*\d{1,2}:\d{2}"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    private static let timePattern = try! NSRegularExpression(pattern: #"\d{1,2}:\d{2}(?::\d{2})?"#)
    private static let amountOnlyPattern = try! NSRegularExpression(
        pattern: #"^[+-]?\s*(?:¥|CNY|RMB|HK\$|US\$|\$)?\s*[+-]?\s*(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2}\s*(?:元|CNY|RMB)?$"#)
    private static let yenAmountOnlyPattern = try! NSRegularExpression(
        pattern: #"^[+-]?\s*(?:¥|CNY|RMB|HK\$|US\$)\s*(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2}$"#)
    /// 账单列表行：「滴滴出行 -23.50」
    private static let billRowPattern = try! NSRegularExpression(
        pattern: #"^(\S.{1,29}?)\s+[+-]\s*(?:¥|CNY|RMB|HK\$|US\$|\$)?\s*(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2}\s*(?:元|CNY|RMB)?$"#)

    /// 整行只有日期 / 时间（如「昨天 下午3:25」「10月17日 20:12」「2026-10-16 19:20」），状态栏的「8:50」不算
    static func isDateHeader(_ text: String) -> Bool {
        var s = text
        var hit = false
        for re in headerPatterns {
            let ns = s as NSString
            let r = NSRange(location: 0, length: ns.length)
            if re.firstMatch(in: s, range: r) != nil { hit = true }
            s = re.stringByReplacingMatches(in: s, range: r, withTemplate: " ")
        }
        guard hit else { return false }
        let ns = s as NSString
        s = timePattern.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        let rest = s.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
        return rest.count <= 2
    }

    static func isAmountOnly(_ text: String) -> Bool { matches(amountOnlyPattern, text) }

    /// 单独一行的时间字段标签：「支付时间」「转账时间」「时间」
    static func isTimeLabel(_ text: String) -> Bool {
        text.range(of: #"^\p{Han}{0,6}(?:时间|日期)\s*[:：]?$"#, options: .regularExpression) != nil
    }

    private static func isPayLine(_ text: String) -> Bool {
        ["支付", "付款", "收款", "到账", "转账", "使用", "方式", "金额", "实付"].contains { text.contains($0) }
    }

    private static func isBillRow(_ text: String) -> Bool {
        let ns = text as NSString
        guard let m = billRowPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return false }
        let label = ns.substring(with: m.range(at: 1))
        if ["优惠", "折扣", "立减", "减免", "抵扣", "运费", "配送费", "手续费", "找零", "返现", "券",
            "合计", "实付", "总计", "应付", "金额", "小计"].contains(where: { label.contains($0) }) { return false }
        return label.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 2
    }

    static func segments(lines: [OCRLine]) -> [Segment] {
        let texts = lines.map(\.text)
        let n = texts.count
        guard n > 0 else { return [] }

        // 1. 分隔点
        var starts: [Int] = []
        let smsStarts = texts.indices.filter { texts[$0].hasPrefix("【") }
        let billRows = texts.indices.filter { isBillRow(texts[$0]) }
        // 「支付时间」标签下一行的日期是字段值（英文界面常见标签与值分行），不是列表的日期分隔
        // 交易时间的值（标签在上一行，或 OCR 把值排在标签前、标签在下一行）不是日期标题
        let headers = texts.indices.filter { isDateHeader(texts[$0]) && !($0 > 0 && isTimeLabel(texts[$0 - 1]))
            && !($0 + 1 < texts.count && isTimeLabel(texts[$0 + 1]) && !isDateHeader(texts[$0 + 1])) }
        if smsStarts.count >= 2 {
            starts = smsStarts
        } else if billRows.count >= 2 {
            starts = billRows
        } else {
            starts = headers
        }

        // 账单列表（微信 / 支付宝，中英文）：每行「名称 / 金额 / 时间」，时间在金额下面 → 每笔以时间行结尾
        if smsStarts.count < 2, billRows.count < 2, let rows = trailingDateRows(texts: texts, headers: headers) {
            return rows
        }

        var segs: [Segment] = []
        // 账单列表 / 短信列表的开头是月度汇总等，不当作一笔交易
        let listMode = smsStarts.count >= 2 || billRows.count >= 2
        if starts.isEmpty || (starts[0] > 0 && !listMode) {
            segs.append(Segment(range: 0..<(starts.first ?? n), isPreamble: !starts.isEmpty))
        }
        for (i, s) in starts.enumerated() {
            segs.append(Segment(range: s..<(i + 1 < starts.count ? starts[i + 1] : n)))
        }

        // 2. 大字金额：优先用 Vision 行高（≥ 中位行高 × 1.6），没有位置信息时用文本规则
        let heights = lines.map(\.height).filter { $0 > 0 }.sorted()
        let median = heights.isEmpty ? 0 : heights[heights.count / 2]
        var heroSet = Set<Int>()
        if median > 0 {
            for i in 0..<n where lines[i].height >= median * 1.6 && isAmountOnly(texts[i]) { heroSet.insert(i) }
        }
        if heroSet.isEmpty {
            for i in 0..<n where matches(yenAmountOnlyPattern, texts[i]) {
                // 「订单金额 / 应付」旁的金额不是大字实付
                if i > 0, ReceiptParser.orderKeywords.contains(where: { texts[i - 1].contains($0) }) { continue }
                if i > 0, ReceiptParser.negativeKeywords.contains(where: { texts[i - 1].contains($0) }) { continue }
                let above = texts[max(0, i - 2)..<i]
                let signed = texts[i].hasPrefix("-") || texts[i].hasPrefix("+")
                    || texts[i].contains("¥-") || texts[i].contains("$-")
                // 带 ± 的整行金额（云闪付 / 支付宝详情大字）视为 hero；或上方有支付相关字
                if signed || above.contains(where: isPayLine) { heroSet.insert(i) }
            }
        }

        // 3. 同一块里有多个大字金额：在第二笔的标题行（金额上方第一行非支付方式文字）处再切开
        var result: [Segment] = []
        for seg in segs {
            let heroes = seg.range.filter { heroSet.contains($0) }
            guard heroes.count >= 2 else {
                var s = seg; s.heroes = heroes; result.append(s); continue
            }
            var cuts: [Int] = []
            for k in 1..<heroes.count {
                let prev = heroes[k - 1], hero = heroes[k]
                var cut = hero
                var j = hero - 1
                while j > prev {
                    if isPayLine(texts[j]) || isAmountOnly(texts[j]) { j -= 1; continue }
                    cut = j
                    break
                }
                cuts.append(max(prev + 1, cut))
            }
            var lower = seg.range.lowerBound
            for (k, c) in cuts.enumerated() {
                result.append(Segment(range: lower..<c, heroes: [heroes[k]], isPreamble: seg.isPreamble && k == 0))
                lower = c
            }
            result.append(Segment(range: lower..<seg.range.upperBound, heroes: [heroes[heroes.count - 1]]))
        }
        return result
    }

    /// 至少 2 个时间行、且大多数紧跟在单独一行的金额后面：按「名称、金额、时间」切分（名称取金额上一行；中间的汇总 / 广告行不计）
    static func trailingDateRows(texts: [String], headers: [Int]) -> [Segment]? {
        let rows = headers.filter { $0 >= 1 && isAmountOnly(texts[$0 - 1]) }
        guard rows.count >= 2, rows.count * 3 >= headers.count * 2 else { return nil }
        var result: [Segment] = []
        var lowerLimit = 0
        for h in rows {
            let amountIdx = h - 1
            var start = amountIdx
            let t = amountIdx - 1
            if t >= lowerLimit, !isAmountOnly(texts[t]), !isDateHeader(texts[t]), !isSummary(texts[t]) { start = t }
            result.append(Segment(range: start..<(h + 1)))
            lowerLimit = h + 1
        }
        return result
    }

    /// 列表顶部的月份 / 收支汇总：「2026年10月」「支出 ¥1,234.00 收入 ¥500.00」
    static func isSummary(_ text: String) -> Bool {
        if text.range(of: #"^20\d{2}年\d{1,2}月$|^\d{1,2}月$|^本月"#, options: .regularExpression) != nil { return true }
        return (text.hasPrefix("支出") || text.hasPrefix("收入") || text.hasPrefix("共支出")) && text.range(of: #"\d"#, options: .regularExpression) != nil
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}

/// 根据关键词猜测分类（名称需与默认分类一致；找不到时由调用方回退到「其他」）
enum CategoryGuesser {
    static let expenseRules: [(String, [String])] = [
        ("生活缴费", ["电费", "水费", "燃气", "煤气", "国家电网", "供电", "自来水", "物业", "缴费", "宽带", "暖气",
                  "Electricity", "State Grid", "Water Bill", "Gas Bill", "Utility"]),
        ("娱乐", ["电影", "影城", "影院", "猫眼", "淘票票", "游戏", "Steam", "腾讯视频", "爱奇艺", "优酷", "网易云", "QQ音乐",
                "哔哩哔哩", "bilibili", "B站", "KTV", "网吧", "剧本杀", "演出", "大麦", "健身",
                "Netflix", "iQIYI", "Tencent Video", "Youku", "Cinema", "Movie", "Spotify", "Gym"]),
        ("通讯", ["话费", "中国移动", "中国联通", "中国电信", "流量", "手机充值", "China Mobile", "China Unicom", "China Telecom"]),
        ("交通", ["滴滴", "打车", "快车", "地铁", "公交", "出行", "高德", "加油", "中石化", "中石油", "停车", "高速", "ETC", "畅行", "通行费", "路桥", "收费站", "etc",
                "12306", "铁路", "哈啰", "单车", "曹操", "T3", "花小猪", "如祺", "享道", "充电",
                "Didi", "DiDi Chuxing", "Metro", "MTR", "Subway Station", "Railway", "Taxi", "Uber", "Parking", "Gas Station", "Sinopec",
                "PetroChina", "Hellobike", "Hello Bike", "Amap", "Highway", "Toll", "Airport Express", "Octopus"]),
        ("旅行", ["携程", "飞猪", "去哪儿", "酒店", "机票", "航空", "民宿", "景区", "门票", "同程", "途牛",
                "Ctrip", "Trip.com", "Fliggy", "Qunar", "Hotel", "Airlines", "Air China", "Airbnb"]),
        ("居住", ["房租", "租金", "自如", "贝壳", "链家", "家政", "保洁"]),
        ("医疗", ["医院", "药房", "药店", "诊所", "医保", "挂号", "体检", "口腔", "牙科", "Hospital", "Pharmacy", "Clinic"]),
        ("教育", ["学费", "培训", "课程", "书店", "教育", "考试", "知识", "得到", "网课"]),
        ("餐饮", ["美团外卖", "饿了么", "外卖", "餐", "饭", "咖啡", "星巴克", "瑞幸", "肯德基", "KFC", "麦当劳", "奶茶", "喜茶",
                "蜜雪", "茶", "食堂", "烧烤", "火锅", "小吃", "饮品", "烘焙", "面包", "必胜客", "汉堡", "塔斯汀", "面馆",
                "料理", "酒楼", "饺子", "麻辣烫", "早点", "包子", "Coffee", "coffee", "库迪", "美团",
                "Starbucks", "McDonald", "McDonalds", "Luckin", "Meituan", "Ele.me", "Eleme", "Burger King", "Pizza Hut", "Heytea",
                "Mixue", "Milk Tea", "Bubble Tea", "Cafe", "Café", "Restaurant", "Bakery", "Noodle", "Noodles", "Dumpling", "Hot Pot", "Hotpot", "Bistro", "Canteen", "Tim Hortons"]),
        ("购物", ["淘宝", "天猫", "京东", "拼多多", "超市", "便利店", "商城", "全家", "罗森", "7-11", "7-Eleven", "盒马",
                "沃尔玛", "永辉", "唯品会", "抖音", "优衣库", "屈臣氏", "名创", "山姆", "Costco", "苹果", "Apple", "小米",
                "华为", "商店", "百货", "购物",
                "Taobao", "Tmall", "JD", "JD.com", "Pinduoduo", "PDD", "7-Eleven", "7-11", "FamilyMart", "Family Mart", "Lawson", "Walmart",
                "Hema", "Freshippo", "Sam's Club", "IKEA", "Uniqlo", "Watsons", "Miniso", "Supermarket", "Mall", "Convenience Store", "Mannings", "Circle K"]),
        ("人情", ["发红包", "礼金", "份子", "礼物", "鲜花", "花店"]),
    ]

    static let incomeRules: [(String, [String])] = [
        ("工资", ["工资", "薪资", "薪金", "代发"]),
        ("奖金", ["奖金", "绩效", "年终", "奖励"]),
        ("理财", ["收益", "利息", "理财", "基金", "分红", "余额宝"]),
        ("红包", ["红包"]),
        ("退款", ["退款", "退货", "退回"]),
    ]

    static func guess(text: String, isIncome: Bool) -> String? {
        let rules = isIncome ? incomeRules : expenseRules
        for (name, keywords) in rules where keywords.contains(where: { contains(text, $0) }) {
            return name
        }
        return nil
    }

    /// 英文关键词按整词匹配（「JD」不匹配「JDK」，「Mall」不匹配「Small」，「etc」不匹配「Fetch」），中文按包含
    static func contains(_ text: String, _ keyword: String) -> Bool {
        guard keyword.unicodeScalars.allSatisfy({ $0.isASCII }) else { return text.localizedCaseInsensitiveContains(keyword) }
        let escaped = NSRegularExpression.escapedPattern(for: keyword)
        return text.range(of: "(?<![A-Za-z])" + escaped + "(?![A-Za-z])", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

// MARK: - 微信 / 支付宝（中英文界面）

/// 截图来源（只用于诊断标签与提示词，不含文字）
enum PaymentApp: String, Equatable, Sendable {
    case wechat, alipay, unionpay, bank, unknown

    var title: String {
        switch self {
        case .wechat: return "微信"
        case .alipay: return "支付宝"
        case .unionpay: return "云闪付"
        case .bank: return "银行"
        case .unknown: return "未知"
        }
    }
}

/// 特殊版式：银行公众号推送列表、微信聊天转账气泡、微信支付助手卡片
enum ScreenLayout: String, Equatable, Sendable {
    case none, bankPush, chatTransfer, payAssistant

    var title: String? {
        switch self {
        case .bankPush: return "银行公众号"
        case .chatTransfer: return "微信聊天转账"
        case .payAssistant: return "支付助手"
        case .none: return nil
        }
    }
}

struct PaymentScreen: Equatable, Sendable {
    var app: PaymentApp = .unknown
    var english = false
    var layout: ScreenLayout = .none
    /// 日志 / 诊断用的标签：「微信·英文」「银行公众号」
    var tag: String { layout.title ?? "\(app.title)·\(english ? "英文" : "中文")" }
}

enum PaymentScreenDetector {
    private static let signals: [(PaymentApp, [String])] = [
        (.wechat, ["微信支付", "微信转账", "微信红包", "零钱通", "零钱", "财付通", "WeChat", "Weixin", "Tenpay", "Wallet Balance", "Mini Fund"]),
        (.alipay, ["支付宝", "花呗", "余额宝", "蚂蚁", "Alipay", "Huabei", "Yu'e Bao", "Yu’e Bao", "Yue Bao", "Yuebao", "Ant Credit Pay", "Ant Group"]),
        (.unionpay, ["云闪付", "银联", "UnionPay", "Union Pay", "QuickPass"]),
    ]

    static func detect(_ texts: [String]) -> PaymentScreen {
        let joined = texts.joined(separator: "\n")
        var scores: [PaymentApp: Int] = [:]
        for (app, words) in signals {
            for w in words where joined.range(of: w, options: [.caseInsensitive]) != nil { scores[app, default: 0] += 1 }
        }
        if texts.contains(where: { $0.hasPrefix("【") && $0.contains("银行】") }) { scores[.bank, default: 0] += 3 }
        let sorted = scores.sorted { $0.value > $1.value }
        var app = PaymentApp.unknown
        if let top = sorted.first, top.value > 0, sorted.count < 2 || sorted[1].value < top.value { app = top.key }
        var han = 0, latin = 0
        for u in joined.unicodeScalars {
            if (0x4E00...0x9FFF).contains(Int(u.value)) { han += 1 } else if (u.value >= 65 && u.value <= 90) || (u.value >= 97 && u.value <= 122) { latin += 1 }
        }
        let layout = ScreenLayouts.detect(texts)
        switch layout {
        case .bankPush: app = .bank
        case .chatTransfer, .payAssistant: app = .wechat
        case .none: break
        }
        return PaymentScreen(app: app, english: latin >= 12 && latin > han * 2, layout: layout)
    }
}

/// 英文界面（微信 / 支付宝 / 银行 App 英文版）→ 中文标签与说法，之后交给中文规则。只改标签、状态、日期格式与钱包 / 银行名，不改商户名。
enum PaymentTerms {
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }

    private static let monthAlt = #"(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?"#
    private static func month(_ s: String) -> Int? {
        let k = String(s.lowercased().prefix(3))
        return ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12][k]
    }
    private static let mdy = re(#"(?<![A-Za-z])"# + monthAlt + #"\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(20\d{2})(?!\d)"#)
    private static let dmy = re(#"(?<!\d)(\d{1,2})(?:st|nd|rd|th)?\s+"# + monthAlt + #",?\s+(20\d{2})(?!\d)"#)
    private static let my = re(#"(?<![A-Za-z])"# + monthAlt + #",?\s+(20\d{2})(?!\d)"#)
    private static let md = re(#"(?<![A-Za-z])"# + monthAlt + #"\s+(\d{1,2})(?:st|nd|rd|th)?(?![\d,:])"#)
    private static let atTime = re(#"\s+at\s+(?=\d{1,2}:\d{2})"#)
    private static let ampm = re(#"(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AP])\.?\s?M\.?(?![A-Za-z])"#)

    /// 长的在前
    static let bankNames: [(String, String)] = [
        ("Industrial and Commercial Bank of China", "工商银行"), ("Agricultural Bank of China", "农业银行"),
        ("Postal Savings Bank of China", "邮储银行"), ("Shanghai Pudong Development Bank", "浦发银行"),
        ("China Construction Bank", "建设银行"), ("China Merchants Bank", "招商银行"), ("Bank of Communications", "交通银行"),
        ("China Minsheng Bank", "民生银行"), ("China Everbright Bank", "光大银行"), ("China Guangfa Bank", "广发银行"),
        ("China CITIC Bank", "中信银行"), ("CITIC Bank", "中信银行"), ("Industrial Bank", "兴业银行"), ("Ping An Bank", "平安银行"),
        ("Hua Xia Bank", "华夏银行"), ("Huaxia Bank", "华夏银行"), ("Bank of Beijing", "北京银行"), ("Bank of Shanghai", "上海银行"),
        ("Bank of Ningbo", "宁波银行"), ("Bank of Jiangsu", "江苏银行"), ("Bank of China", "中国银行"),
    ]
    private static let bankRegexes: [(NSRegularExpression, String)] = bankNames.map {
        (re("(?<![A-Za-z])" + $0.0.replacingOccurrences(of: " ", with: #"\s+"#) + "(?![A-Za-z])"), $0.1)
    }

    /// 整行或任意位置的短语（顺序有意义：长的、具体的在前）
    private static let phrases: [(NSRegularExpression, String)] = [
        (#"Payment\s+Success(?:ful)?|Paid\s+Successfully|Successfully\s+Paid|Payment\s+Completed"#, "支付成功"),
        (#"Transaction\s+(?:Successful|Completed|Success)"#, "交易成功"),
        (#"Refund(?:ed)?\s+Success(?:ful|fully)?|Refunded\s+Successfully"#, "退款成功"),
        (#"(?:Received|Accepted)\s+by\s+(?:the\s+)?(?:recipient|payee|receiver)|(?:Recipient|Payee|Receiver)\s+(?:has\s+)?(?:received|accepted)|Transfer\s+Accepted"#, "对方已收款"),
        (#"Waiting\s+for\s+.{0,24}?to\s+(?:accept|receive)|Awaiting\s+(?:acceptance|receipt)|Pending\s+acceptance|To\s+be\s+received\s+by\s+(?:the\s+)?recipient"#, "待对方收款"),
        (#"Transfer\s+Received|Received\s+Transfer"#, "收到转账"),
        (#"Transfer(?:red)?\s+from"#, "收到转账 来自"),
        (#"Red\s+(?:Packet|Envelope)s?\s+(?:Received|from)|Received\s+(?:a\s+)?Red\s+(?:Packet|Envelope)"#, "收到红包 "),
        (#"Sent\s+(?:a\s+)?Red\s+(?:Packet|Envelope)|Red\s+(?:Packet|Envelope)\s+Sent|Send\s+Red\s+(?:Packet|Envelope)"#, "发红包"),
        (#"Red\s+(?:Packet|Envelope)s?|Lucky\s+Money|Hongbao"#, "红包"),
        (#"(?:Mobile|Phone)\s+(?:Top[\s-]?up|Recharge|Credit)|Phone\s+Bill"#, "手机充值"),
        (#"Withdraw(?:al|n)?\s+to"#, "提现到 "),
        (#"Withdraw(?:al|n|als)?|Cash\s+Out"#, "提现"),
        (#"Top[\s-]?up\s+to|Recharge\s+to|Add\s+(?:Money|Funds)\s+to"#, "充值到"),
        (#"Top[\s-]?ups?|Recharge|Add\s+(?:Money|Funds)"#, "充值"),
        (#"Transfer(?:red)?\s+to"#, "转账给"),
        (#"Refund(?:ed)?\s+to"#, "退回 "),
        (#"Refunded"#, "已退款"),
        (#"Refunds?"#, "退款"),
        (#"Transfers?"#, "转账"),
        (#"Income"#, "收入"),
        (#"Expenses?|Expenditures?|Spending"#, "支出"),
        (#"Service\s+Fee|Handling\s+Fee|Transaction\s+Fee"#, "手续费"),
        (#"(?:UnionPay|Union\s+Pay|QuickPass)\s+(?:Discount|Instant\s+Discount|Reduction)"#, "云闪付立减"),
        (#"Discounts?|Coupons?|Vouchers?|Promotions?|Cashback|Points"#, "优惠"),
        (#"Consumption|Purchase"#, "消费"),
        (#"Today"#, "今天"), (#"Yesterday"#, "昨天"),
    ].map { (re("(?<![A-Za-z])(?:" + $0.0 + ")(?![A-Za-z])"), $0.1) }

    /// 整行状态（只在一行只有这个词时替换）
    private static let statusLines: [(NSRegularExpression, String)] = [
        (#"Paid"#, "已支付"), (#"Successful|Success|Completed|Complete|Done"#, "交易成功"),
        (#"Received"#, "已收款"), (#"Pending|Processing|In\s+Progress"#, "处理中"),
        (#"Bills?|Transactions?|All\s+Transactions|Bill\s+List"#, "全部账单"),
        (#"(?:Transaction|Bill|Payment|Order|Transfer)\s+Details?|Details?"#, "账单详情"),
    ].map { (re(#"^\s*(?:"# + $0.0 + #")\s*$"#), $0.1) }

    /// 行首标签：label 后需是冒号 / 行尾，或（多词标签）空白 + 值
    private static let labels: [(String, String, Bool)] = [
        // (英文标签, 中文, 是否允许「标签 + 空格 + 值」写在同一行)
        (#"Merchant\s+Full\s+Name"#, "商户全称", true), (#"Merchant\s+Name|Store\s+Name|Shop\s+Name"#, "商户名称", true),
        (#"Merchant\s+Order\s+(?:No\.?|Number|ID)"#, "商户单号", true),
        (#"Transaction\s+(?:No\.?|Number|ID)|Trade\s+(?:No\.?|Number)|Order\s+(?:No\.?|Number|ID)|Bill\s+(?:No\.?|Number)|Reference\s+(?:No\.?|Number)|Serial\s+(?:No\.?|Number)|Payment\s+ID"#, "订单号", true),
        (#"Total\s+Amount|Actual\s+Payment|Actual\s+Amount|Amount\s+Paid|Paid\s+Amount|Amount\s+Payable"#, "实付金额", true),
        (#"Order\s+Amount"#, "订单金额", true), (#"Refund\s+Amount"#, "退款金额", true),
        (#"Transaction\s+Amount|Payment\s+Amount|Transfer\s+Amount"#, "交易金额", true),
        (#"Card\s+(?:Number|No\.?)|Payment\s+Method|Payment\s+Account|Payment\s+Source|Payment\s+Card|Funding\s+Source|Paid\s+with|Pay\s+with|Paid\s+by|Pay\s+by|Pay\s+from|Paid\s+from"#, "付款方式", true),
        (#"Refund\s+Method|Refund\s+Account"#, "退款方式", true),
        (#"Receiving\s+Account|Credited\s+to|Deposit\s+Account|Arrival\s+Account|Bank\s+Card"#, "到账账户", true),
        (#"Refund\s+Time|Refunded\s+(?:at|on)"#, "退款时间", true), (#"Top[\s-]?up\s+Time|Withdraw(?:al)?\s+Time"#, "到账时间", true),
        (#"Payment\s+Time|Transaction\s+Time|Trade\s+Time|Order\s+Time|Creation\s+Time|Created\s+(?:at|on)|Paid\s+(?:at|on)|Transfer\s+Time|Received\s+Time|Date\s+(?:&|and)\s+Time"#, "支付时间", true),
        (#"Transaction\s+Status|Payment\s+Status|Current\s+Status|Order\s+Status"#, "当前状态", true),
        (#"Bill\s+Category|Transaction\s+Category|Spending\s+Category"#, "账单分类", true),
        (#"Product\s+(?:Name|Description|Info)|Goods\s+(?:Name|Description)|Order\s+Description|Item\s+Name"#, "商品说明", true),
        (#"Paid\s+to|Pay\s+to"#, "收款方", true),
        (#"Merchant|Payee|Recipient|Receiver|Counterparty|Beneficiary"#, "收款方", false),
        (#"Payer|Sender"#, "付款方", false),
        (#"Product|Goods|Item|Description"#, "商品说明", false),
        (#"Notes?|Remarks?|Memo|Message|Comments?|Postscript"#, "备注", false),
        (#"Total|Amount"#, "实付金额", false),
        (#"Status"#, "当前状态", false),
        (#"Category"#, "账单分类", false),
        (#"Time|Date|Created|Date/Time"#, "支付时间", false),
        (#"To"#, "收款方", false), (#"From"#, "付款方", false),
    ]
    private static let labelRegexes: [(NSRegularExpression, String)] = labels.map { label, zh, inline in
        // inline：「Payment Method CMB Debit Card」；否则只接受「Label」「Label: 值」「Time 2026-…」（数字 / 货币值）
        // 非 inline 标签后面紧跟中文值（「Payee 示例牛肉饭」）也算
        let tail = inline ? #"(?:\s*[:：]\s*|\s+|\s*$)"# : #"(?:\s*[:：]\s*|\s*$|\s+(?=[\d¥$+\-\p{Han}]))"#
        return (re(#"^\s*(?:"# + label + ")" + tail), zh + " ")
    }

    /// 一行的本地化（app：决定「Balance」是微信零钱还是支付宝余额）
    static func localize(_ line: String, app: PaymentApp) -> String {
        guard line.range(of: "[A-Za-z]", options: .regularExpression) != nil else { return line }
        var s = line
        // 1. 日期 / 时间
        s = sub(mdy, s) { g in "\(g[3])-\(String(format: "%02d", month(g[1]) ?? 1))-\(String(format: "%02d", Int(g[2]) ?? 1))" }
        s = sub(dmy, s) { g in "\(g[3])-\(String(format: "%02d", month(g[2]) ?? 1))-\(String(format: "%02d", Int(g[1]) ?? 1))" }
        s = sub(my, s) { g in "\(g[2])年\(month(g[1]) ?? 1)月" }
        s = sub(md, s) { g in "\(month(g[1]) ?? 1)月\(Int(g[2]) ?? 1)日" }
        s = atTime.stringByReplacingMatches(in: s, range: full(s), withTemplate: " ")
        s = sub(ampm, s) { g in
            var h = Int(g[1]) ?? 0
            let pm = g[4].uppercased() == "P"
            if pm && h < 12 { h += 12 } else if !pm && h == 12 { h = 0 }
            return String(format: "%02d:%@", h, g[2]) + (g[3].isEmpty ? "" : ":\(g[3])")
        }
        // 2. 整行状态 / 页面标题
        for (r, zh) in statusLines where r.firstMatch(in: s, range: full(s)) != nil { return zh }
        // 3. 行首标签
        for (r, zh) in labelRegexes {
            if let m = r.firstMatch(in: s, range: full(s)) {
                s = zh + (s as NSString).substring(from: m.range.location + m.range.length)
                break
            }
        }
        // 4. 银行全称、钱包
        for (r, zh) in bankRegexes { s = r.stringByReplacingMatches(in: s, range: full(s), withTemplate: zh) }
        s = replace(#"(?<![A-Za-z])Alipay\s+Balance(?![A-Za-z])"#, s, "账户余额")
        s = replace(#"(?<![A-Za-z])Wallet\s+Balance(?![A-Za-z])"#, s, "零钱")
        s = replace(#"(?<![A-Za-z])Yu\s*['’]?\s*e\s*Bao(?![A-Za-z])|(?<![A-Za-z])Yuebao(?![A-Za-z])"#, s, "余额宝")
        s = replace(#"(?<![A-Za-z])(?:Huabei|Ant\s+Credit\s+Pay)(?![A-Za-z])"#, s, "花呗")
        s = replace(#"(?<![A-Za-z])(?:Mini\s+Fund|LingQianTong)(?![A-Za-z])"#, s, "零钱通")
        s = replace(#"(?<![A-Za-z])(?:WeChat|Weixin)\s+Pay(?:ment)?(?![A-Za-z])"#, s, "微信支付")
        s = replace(#"(?<![A-Za-z])Balance(?=\s*[:：]?\s*[¥$]?\s*\d)"#, s, "余额")
        let wallet = app == .wechat ? "零钱" : app == .alipay ? "账户余额" : "余额"
        s = replace(#"(?<![A-Za-z])Balance(?![A-Za-z])"#, s, wallet)
        s = replace(#"(?<![A-Za-z])Alipay(?![A-Za-z])"#, s, "支付宝")
        s = replace(#"(零钱|账户余额)\s*充值"#, s, "$1充值")
        // 5. 短语
        for (r, zh) in phrases { s = r.stringByReplacingMatches(in: s, range: full(s), withTemplate: zh) }
        // 6. 银行缩写 / 卡种 / 云闪付说法（已有）
        s = EnglishBankTerms.localize(s)
        return s.replacingOccurrences(of: #"(?<=\p{Han})\s+(?=\p{Han})"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func full(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }

    private static func replace(_ pattern: String, _ s: String, _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
    }

    /// 用回调替换每个匹配（groups[0] 是整段）
    private static func sub(_ r: NSRegularExpression, _ s: String, _ f: ([String]) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in r.matches(in: s, range: full(s)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let rg = m.range(at: i)
                return rg.location == NSNotFound ? "" : ns.substring(with: rg)
            }
            out += f(groups)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}

/// 平台自带的账单分类（支付宝「账单分类」/ Category）→ 默认分类名
enum PlatformCategory {
    static let table: [(String, [String])] = [
        ("餐饮", ["餐饮美食", "美食", "餐饮", "Food & Beverage", "Food and Beverage", "Food & Drink", "Food & Dining", "Dining", "Catering", "Restaurants"]),
        ("交通", ["交通出行", "爱车养车", "交通", "Transportation", "Transport", "Travel & Transport", "Car Services", "Auto"]),
        ("购物", ["日用百货", "服饰装扮", "数码电器", "美容美发", "母婴亲子", "家居家装", "宠物", "购物", "Daily Necessities", "Groceries",
                "Shopping", "Clothing", "Apparel", "Electronics", "Digital", "Beauty", "Home", "Supermarket"]),
        ("生活缴费", ["充值缴费", "生活缴费", "Recharge & Payment", "Top-up & Bills", "Utilities", "Bills & Utilities", "Living Payment"]),
        ("娱乐", ["休闲娱乐", "运动户外", "文化休闲", "Entertainment", "Leisure", "Sports"]),
        ("医疗", ["医疗健康", "Healthcare", "Medical", "Health"]),
        ("教育", ["教育培训", "Education"]),
        ("旅行", ["酒店旅游", "Hotel & Travel", "Travel", "Hotels"]),
        ("居住", ["住房物业", "Housing", "Property", "Rent"]),
        ("通讯", ["通讯", "Telecom", "Mobile"]),
    ]

    static func map(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        for (name, words) in table where words.contains(where: { v.compare($0, options: [.caseInsensitive]) == .orderedSame }) { return name }
        for (name, words) in table where words.contains(where: { $0.count >= 4 && v.localizedCaseInsensitiveContains($0) }) { return name }
        return nil
    }

    /// 「账单分类 餐饮美食」或标签与值分行
    static func find(in lines: [String]) -> String? {
        for (i, l) in lines.enumerated() {
            guard let r = l.range(of: "账单分类"), l.distance(from: l.startIndex, to: r.lowerBound) <= 1 else { continue }
            var v = String(l[r.upperBound...]).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":>›")))
            if v.isEmpty, i + 1 < lines.count { v = lines[i + 1] }
            if let c = map(v) { return c }
        }
        return nil
    }
}

/// 钱包充值 / 提现 / 余额宝、零钱通转入转出：自己账户之间的转账，不是支出 / 收入
enum SelfTransferDetector {
    enum Kind: String, Equatable { case topUp, withdraw, fundIn, fundOut }

    struct Result: Equatable {
        var kind: Kind
        var from: AccountHint?
        var to: AccountHint?
        var fromName: String?
        var toName: String?
        var note: String
    }

    /// 这些「充值」是消费（话费、游戏、加油卡……）
    static let consumptionWords = ["话费", "手机充值", "流量", "游戏", "Q币", "会员", "油卡", "加油", "电费", "水费", "燃气", "公交卡",
                                   "交通卡", "ETC", "校园卡", "饭卡", "缴费", "点券", "钻石", "视频"]

    static func detect(text: String, app: PaymentApp) -> Result? {
        let t = text.replacingOccurrences(of: " ", with: "")
        if t.contains("退款") || RepaymentDetector.isCardRepayment(text: t) { return nil }
        let fundName: String? = t.contains("余额宝") ? "余额宝" : t.contains("零钱通") ? "零钱通" : nil
        let walletType: String? = {
            if t.contains("零钱") && !t.contains("零钱通") { return "wechat" }
            if t.contains("账户余额") || t.contains("充值-余额") { return "alipay" }
            // 「余额充值 / 余额提现」：英文界面的 Balance 在微信是零钱、在支付宝是余额，来源不明时不猜
            if t.contains("余额充值") || t.contains("余额提现") || t.contains("充值到余额") {
                return app == .wechat ? "wechat" : app == .alipay ? "alipay" : nil
            }
            if t.contains("零钱通") { return "wechat" }
            if t.contains("余额宝") { return "alipay" }
            return app == .wechat ? "wechat" : app == .alipay ? "alipay" : nil
        }()
        let walletHint = walletType.map { AccountHint(type: $0) }
        let walletName = walletType == "wechat" ? "零钱" : walletType == "alipay" ? "余额" : "钱包"

        if let fund = fundName {
            let into = t.range(of: #"转入\#(fund)|\#(fund)-?转入|存入\#(fund)|转入到\#(fund)|买入\#(fund)|转账给\#(fund)|转账到\#(fund)|充值到\#(fund)"#, options: .regularExpression) != nil
            let out = t.range(of: #"\#(fund)-?转出|转出\#(fund)|从\#(fund)转出|\#(fund)提现|\#(fund)取出"#, options: .regularExpression) != nil
            if into || out {
                let bank = bankHint(text)
                let other = bank ?? walletHint
                return into
                    ? Result(kind: .fundIn, from: other, to: nil, fromName: nil, toName: fund, note: "转入\(fund)")
                    : Result(kind: .fundOut, from: nil, to: other, fromName: fund, toName: nil, note: "\(fund)转出")
            }
        }
        if t.contains("提现") {
            return Result(kind: .withdraw, from: walletHint, to: bankHint(text), note: "\(walletName)提现")
        }
        if t.contains("充值") {
            let explicit = t.range(of: #"零钱充值|充值到零钱|余额充值|充值到余额|账户余额充值|充值-余额|充值-账户余额"#, options: .regularExpression) != nil
            if !explicit && consumptionWords.contains(where: { t.localizedCaseInsensitiveContains($0) }) { return nil }
            guard explicit || walletType != nil else { return nil }
            return Result(kind: .topUp, from: bankHint(text), to: walletHint, note: "\(walletName)充值")
        }
        return nil
    }

    /// 文字里的银行卡（去掉钱包词后解析）：银行 / 尾号 / 卡种
    static func bankHint(_ text: String) -> AccountHint? {
        var s = text
        for w in ["零钱通", "零钱", "余额宝", "账户余额", "余额", "微信支付", "支付宝"] { s = s.replacingOccurrences(of: w, with: " ") }
        guard var h = AccountHintParser.parse(text: s), h.bankName != nil || h.cardTail != nil || h.type == "debit" || h.type == "credit" else { return nil }
        if h.type == nil || h.type == "wechat" || h.type == "alipay" { h.type = "debit" }
        return h
    }
}

// MARK: - 特殊版式（银行公众号 / 聊天转账 / 支付助手）

enum ScreenLayouts {
    private static func compact(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "") }

    static func detect(_ texts: [String]) -> ScreenLayout {
        let c = texts.map(compact)
        if c.contains(where: { $0.contains("支付助手") || $0.hasPrefix("交易对象") })
            || (c.contains(where: { $0.contains("支付消息") }) && c.contains(where: { $0.contains("服务通知") })) {
            return .payAssistant
        }
        let hasCard = c.contains { $0.contains("交易提醒") || $0.contains("动账提醒") || $0.contains("消费提醒") || $0.contains("账户变动") }
        let hasField = c.contains { $0.hasPrefix("交易金额") || $0.hasPrefix("交易类型") }
        if hasCard && hasField { return .bankPush }
        if !chatBubbles(texts).isEmpty { return .chatTransfer }
        return .none
    }

    // MARK: 聊天转账气泡

    static let incomeStatuses = ["已收款", "已收钱", "请收款", "待收款", "已领取"]
    static let expenseStatuses = ["已被接收", "已被领取", "对方已收款", "对方已收钱", "待对方收款", "待对方确认收款", "待接收", "已被收款"]
    static let pendingStatuses = ["请收款", "待收款", "待对方收款", "待对方确认收款", "待接收"]
    private static let bubbleAmount = try! NSRegularExpression(pattern: #"^[¥$]\s*((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?)$"#)

    struct Bubble { var amountLine: Int; var amount: Double; var status: String }

    /// 转账气泡：「¥1200.00」+ 状态（已收款 / 已被接收 / 请收款…）+「转账 / 微信转账」。转账详情页（有转账时间 / 单号）不算
    static func chatBubbles(_ texts: [String]) -> [Bubble] {
        let c = texts.map(compact)
        if c.contains(where: { $0.contains("转账时间") || $0.contains("收款时间") || $0.contains("转账单号") || $0.contains("支付时间") }) { return [] }
        var result: [Bubble] = []
        for (i, line) in c.enumerated() {
            let ns = line as NSString
            guard let m = bubbleAmount.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let v = Double(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")), v > 0 else { continue }
            let near = (i + 1)..<min(i + 3, c.count)
            guard let si = near.first(where: { j in c[j].count <= 10 && (incomeStatuses + expenseStatuses).contains(where: { c[j].contains($0) }) }) else { continue }
            let window = max(0, i - 1)..<min(i + 4, c.count)
            guard window.contains(where: { ["转账", "微信转账", "[转账]"].contains(c[$0]) }) else { continue }
            let st = c[si]
            let status = (expenseStatuses + incomeStatuses).first(where: { st.contains($0) }) ?? st
            result.append(Bubble(amountLine: i, amount: v, status: status))
        }
        return result
    }

    /// 单独一行的「19:10」：今天（晚于现在 5 分钟以上则是昨天）
    static func bareTime(_ text: String, now: Date, calendar: Calendar) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: #"^(\d{1,2}):(\d{2})$"#, options: .regularExpression), r == t.startIndex..<t.endIndex else { return nil }
        let parts = t.split(separator: ":")
        guard let h = Int(parts[0]), let mi = Int(parts[1]), h < 24, mi < 60,
              let d = calendar.date(bySettingHour: h, minute: mi, second: 0, of: now) else { return nil }
        return (d > now.addingTimeInterval(300) ? "昨天 " : "今天 ") + String(format: "%02d:%02d", h, mi)
    }

    static func chatTransfers(texts: [String], now: Date, calendar: Calendar) -> [ParsedReceipt] {
        chatBubbles(texts).map { b in
            var r = ParsedReceipt()
            r.amount = (b.amount * 100).rounded() / 100
            r.isIncome = !expenseStatuses.contains(b.status)
            r.score = 100
            r.accountHint = AccountHint(type: "wechat")
            r.categoryName = r.isIncome ? "其他收入" : nil
            r.discountNote = pendingStatuses.contains(b.status) ? "待收款" : nil
            r.rawText = texts[b.amountLine..<min(b.amountLine + 3, texts.count)].joined(separator: "\n")
            // 时间：气泡上方最近的时间行（昨天 晚上7:10 / 星期四 下午4:23 / 19:10）
            var j = b.amountLine - 1
            while j >= 0 {
                if TransactionSegmenter.isDateHeader(texts[j]) {
                    r.date = ReceiptParser.date(lines: [texts[j]], now: now, calendar: calendar)
                    break
                }
                if j > 0, let t = bareTime(texts[j], now: now, calendar: calendar) {
                    r.date = ReceiptParser.date(lines: [t], now: now, calendar: calendar)
                    break
                }
                j -= 1
            }
            return r
        }
    }

    // MARK: 支付助手

    static func assistantHeader(texts: [String], index i: Int, now: Date, calendar: Calendar) -> String? {
        guard let t = bareTime(texts[i], now: now, calendar: calendar) else { return nil }
        let next = texts[(i + 1)..<min(i + 4, texts.count)].map(compact)
        let cardWords = ["支付助手", "付款成功", "支付成功", "收款到账", "收款成功", "退款", "微信支付", "交易对象"]
        return next.contains(where: { l in cardWords.contains(where: { l.contains($0) }) }) ? t : nil
    }

    // MARK: 银行公众号推送

    private static let typePattern = try! NSRegularExpression(pattern: #"交易类型\s*[:：]?\s*(\S+)"#)

    /// 标题里的银行与卡种（「浦发银行信用卡」）补到每笔的尾号上；交易类型 退货 / 退款 = 收入，还款 = 信用卡还款
    static func applyBankPush(_ results: inout [ParsedReceipt], texts: [String]) {
        let firstCard = texts.firstIndex(where: { compact($0).contains("提醒") }) ?? min(3, texts.count)
        let title = texts[0..<firstCard].first(where: { $0.contains("银行") || $0.contains("信用卡") })
        let titleHint = title.flatMap { AccountHintParser.parse(text: EnglishBankTerms.localize($0)) }
        for i in results.indices {
            var r = results[i]
            var hint = r.accountHint ?? AccountHint()
            if hint.bankName == nil, let b = titleHint?.bankName { hint.bankName = b }
            if titleHint?.type == "credit" { hint.type = "credit" }
            if hint.type == nil, hint.bankName != nil { hint.type = "debit" }
            if hint.bankName != nil || hint.cardTail != nil || hint.type != nil { r.accountHint = hint }
            let raw = r.rawText as NSString
            if let m = typePattern.firstMatch(in: r.rawText, range: NSRange(location: 0, length: raw.length)) {
                let type = raw.substring(with: m.range(at: 1))
                if type.contains("退货") || type.contains("退款") {
                    r.isIncome = true
                    r.categoryName = "退款"
                } else if type.contains("还款") {
                    r.isCardRepayment = true
                    r.isIncome = false
                    r.categoryName = "信用卡还款"
                    var card = hint; card.type = "credit"
                    r.repaymentCard = card
                    r.accountHint = nil
                    r.merchant = nil
                } else if type.contains("消费") || type.contains("支付") || type.contains("扣款") {
                    r.isIncome = false
                }
            }
            results[i] = r
        }
    }
}

// MARK: - 跨截图查重

/// 同一笔交易的多张截图（银行推送 / 支付助手 / 云闪付详情）：金额相同、账户相同、时间相差 5 分钟内、商户相近 → 重复
enum DuplicateMatcher {
    struct Entry: Equatable {
        var amount: Double
        var merchant: String
        var date: Date
        /// 账户标识（账户 ID 或「银行+尾号」）；未知为 nil
        var account: String?
    }

    static let window: TimeInterval = 300

    static func isDuplicate(_ e: Entry, among list: [Entry]) -> Bool {
        list.contains { matches(e, $0) }
    }

    static func matches(_ a: Entry, _ b: Entry) -> Bool {
        guard abs(a.amount - b.amount) < 0.005 else { return false }
        let dt = abs(a.date.timeIntervalSince(b.date))
        let ma = normalizeMerchant(a.merchant), mb = normalizeMerchant(b.merchant)
        // 旧规则：同商户、2 分钟内（重复识别同一张截图）
        if dt <= 120 && ma == mb && !(ma.isEmpty && a.account != b.account) { return true }
        guard dt <= window else { return false }
        let accountMatch = a.account != nil && a.account == b.account
        let accountConflict = a.account != nil && b.account != nil && a.account != b.account
        let merchantMatch = !ma.isEmpty && !mb.isEmpty && merchantsCompatible(ma, mb)
        let merchantConflict = !ma.isEmpty && !mb.isEmpty && !merchantMatch
        return !accountConflict && !merchantConflict && (accountMatch || merchantMatch)
    }

    /// 去掉平台前缀、括号里的分店、空白与标点；只有平台名（美团）时视为空
    static func normalizeMerchant(_ m: String) -> String {
        var v = ReceiptParser.splitPlatform(ReceiptParser.cleanMerchant(m)).merchant
        if ReceiptParser.platformNames.contains(v) { return "" }
        v = v.replacingOccurrences(of: #"[(（\[【][^)）\]】]*[)）\]】]?"#, with: "", options: .regularExpression)
        v = v.replacingOccurrences(of: #"(?:科技|网络|信息|餐饮|管理|服务)?(?:股份)?有限(?:责任)?公司$"#, with: "", options: .regularExpression)
        v = v.replacingOccurrences(of: #"[\s\p{P}\p{S}]"#, with: "", options: .regularExpression)
        return v.lowercased()
    }

    static func merchantsCompatible(_ a: String, _ b: String) -> Bool {
        if a == b || a.contains(b) || b.contains(a) { return true }
        func grams(_ s: String) -> Set<String> {
            let c = Array(s)
            guard c.count >= 2 else { return [s] }
            return Set((0..<(c.count - 1)).map { String(c[$0...$0 + 1]) })
        }
        let ga = grams(a), gb = grams(b)
        let common = ga.intersection(gb).count
        return common >= 2 && Double(common) / Double(min(ga.count, gb.count)) >= 0.5
    }
}

// MARK: - 单笔详情页（标签换行 / 值在标签前 / 订单金额）

enum DetailLabels {
    /// 英文标签被换成两行：「Transaction / Time」「Payment / Network」「Card / Number」
    static let pairs: [String: [String]] = [
        "transaction": ["time", "category", "type", "status", "date", "amount", "no.", "no", "number", "details"],
        "payment": ["network", "method", "time", "account", "details"],
        "order": ["amount", "time", "no.", "no", "number"],
        "card": ["number", "no.", "no"],
        "current": ["status"],
        "discount": ["info", "information"],
        "transfer": ["time"],
    ]

    /// 合并换行的标签：标签首词单独一行（或后面跟着值），后 1–2 行内有单独的第二个词 → 合成一个标签，去掉第二个词那行
    static func rejoin(_ lines: [OCRLine]) -> [OCRLine] {
        var out = lines
        var i = 0
        while i < out.count {
            let t = out[i].text.trimmingCharacters(in: .whitespaces)
            let parts = t.split(separator: " ", maxSplits: 1).map(String.init)
            guard let first = parts.first, let seconds = pairs[first.lowercased()] else { i += 1; continue }
            let rest = parts.count > 1 ? parts[1] : ""
            // 「Transaction Time …」已经完整：跳过
            if let r = rest.split(separator: " ").first, seconds.contains(r.lowercased()) { i += 1; continue }
            var merged = false
            for j in (i + 1)..<min(i + 3, out.count) {
                let w = out[j].text.trimmingCharacters(in: .whitespaces)
                if seconds.contains(w.lowercased()) {
                    out[i].text = first + " " + w + (rest.isEmpty ? "" : " " + rest)
                    out.remove(at: j)
                    merged = true
                    break
                }
            }
            i += merged ? 1 : 1
        }
        return out
    }

    /// 本地化后的字段标签（整行）
    static let labels: Set<String> = ["收款方", "付款方式", "支付方式", "交易时间", "支付时间", "订单金额", "交易类型", "账单分类", "交易分类",
                                      "分类", "当前状态", "优惠信息", "优惠", "支付网络", "卡号", "交易账户", "商户", "商户名称", "交易对象", "全部账单",
                                      "付款卡", "订单号", "交易单号", "商户单号", "备注", "Payment", "Network", "Payment Network", "Category"]
    static let merchantLabels: Set<String> = ["收款方", "商户", "商户名称", "商户全称", "交易对象", "收款商户", "收款方全称"]
    /// 字段值，不能当商户名
    static let fieldValues: Set<String> = ["消费", "支出", "收入", "其他", "其他分类", "银联", "consumption", "purchase", "unionpay",
                                           "other", "other categories-other", "交易成功", "支付成功", "Consumption", "UnionPay"]

    static func isLabel(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if labels.contains(t) { return true }
        return t.range(of: #"^(?:优惠|全部账单)\s*(?:Info|信息)?$"#, options: .regularExpression) != nil
    }

    private static let titlePattern = try! NSRegularExpression(
        pattern: #"^(?:云闪付)?(?:交易详情|账单详情|支付详情|订单详情|(?i:transaction|bill|payment|order)\s+(?i:details?))$"#)

    /// 单笔详情页：顶部是「交易详情 / 账单详情 / Transaction details」标题，或只有一个大字金额且有 ≥ 3 个字段标签
    static func isDetailPage(_ texts: [String], heroCount: Int) -> Bool {
        let head = texts.prefix(6)
        if head.contains(where: { titlePattern.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }) {
            return true
        }
        guard heroCount == 1 else { return false }
        let keys = ["收款方", "付款方式", "支付方式", "订单金额", "交易时间", "支付时间", "当前状态", "交易类型", "账单分类", "优惠信息", "交易单号"]
        let found = Set(texts.compactMap { t in keys.first { t.hasPrefix($0) } })
        return found.count >= 3
    }
}

/// 同一张截图里「实付」与「订单金额」被拆成两笔时去掉订单金额那笔：
/// 时间相同（±1 分钟或其一无时间）且 金额 = 另一笔 + 截图上的优惠，或金额只出现在订单金额 / 原价行
enum OrderAmountGuard {
    private static let orderLabels = ["订单金额", "原价", "应付", "商品总价", "Order amount", "Order Amount"]

    static func filter(_ list: [ParsedReceipt], lines: [String]) -> [ParsedReceipt] {
        guard list.count >= 2 else { return list }
        let discounts = discountValues(lines)
        let orderAmounts = orderValues(lines)
        var drop = Set<Int>()
        for i in list.indices {
            for j in list.indices where i != j && !drop.contains(j) && !drop.contains(i) {
                guard let a = list[i].amount, let b = list[j].amount, a > b + 0.004 else { continue }
                guard list[i].isIncome == list[j].isIncome, !list[i].isCardRepayment, !list[j].isCardRepayment else { continue }
                let sameTime: Bool = {
                    guard let da = list[i].date, let db = list[j].date else { return true }
                    return abs(da.timeIntervalSince(db)) <= 60
                }()
                guard sameTime else { continue }
                let plusDiscount = discounts.contains { abs(b + $0 - a) < 0.005 }
                let isOrderLine = orderAmounts.contains { abs($0 - a) < 0.005 }
                if plusDiscount || isOrderLine { drop.insert(i) }
            }
        }
        return list.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    private static let money = try! NSRegularExpression(pattern: #"(\d+(?:,\d{3})*\.\d{1,2})"#)

    private static func values(in s: String) -> [Double] {
        let ns = s as NSString
        return money.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            Double(ns.substring(with: $0.range(at: 1)).replacingOccurrences(of: ",", with: ""))
        }
    }

    static func discountValues(_ lines: [String]) -> [Double] {
        lines.filter { l in ["优惠", "立减", "满减", "折扣", "Discount", "抵扣", "红包抵扣"].contains { l.contains($0) } }.flatMap(values)
    }

    /// 订单金额标签同一行或相邻行（值在标签前 / 后）的金额
    static func orderValues(_ lines: [String]) -> [Double] {
        var out: [Double] = []
        for (i, l) in lines.enumerated() where orderLabels.contains(where: { l.contains($0) }) {
            out += values(in: l)
            for k in [i - 1, i + 1] where k >= 0 && k < lines.count && TransactionSegmenter.isAmountOnly(lines[k]) { out += values(in: lines[k]) }
        }
        return out
    }
}
