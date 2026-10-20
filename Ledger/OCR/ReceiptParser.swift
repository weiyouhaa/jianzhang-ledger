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
        #"[*＊]{2,}\s*(\d{4})(?!\d)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

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
            hint.bankName = bank
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
    private static let bankRegex: NSRegularExpression = {
        let alt = banks.map(\.0).joined(separator: "|")   // 长的在前：CMBC 先于 CMB
        return try! NSRegularExpression(pattern: "(?<![A-Za-z])(\(alt))(?![A-Za-z])")
    }()
    private static let phrases: [(String, String)] = [
        (#"(?i)credit\s*card\s*repayments?"#, "信用卡还款"),
        (#"(?i)(?<![A-Za-z])repay(?:ment)?s?(?![A-Za-z])"#, "还款"),
        (#"(?i)credit\s*cards?"#, "信用卡"),
        (#"(?i)debit\s*cards?|savings?\s*(?:cards?|account)"#, "储蓄卡"),
        (#"(?i)(?<![A-Za-z])ending\s*(?:in|with)?\s*(?=\d{4})"#, "尾号"),
        (#"(?i)(?<![A-Za-z])successful(?:ly)?(?![A-Za-z])|(?<![A-Za-z])success(?![A-Za-z])"#, "成功"),
    ].map { ($0.0, $0.1) }

    static func localize(_ text: String) -> String {
        guard text.range(of: "[A-Za-z]", options: .regularExpression) != nil else { return text }
        var out = text
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
        pattern: #"(?:还款卡|还款到|还款至|还款信用卡|还款账户)\s*[:：]?\s*([\p{Han}]{2,8}?银行)\s*(信用卡)?\s*(?:尾号)?\s*[（(]?\s*[*＊]*\s*(\d{4})?\s*[)）]?"#)
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
        pattern: #"([\p{Han}]{2,8}?银行)?(信用卡|花呗|白条)\s*(?:尾号|末四位)?\s*[（(]?\s*[*＊]*\s*(\d{4})?\s*[)）]?"#)

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
        let lines = prepare(rawLines)
        guard !lines.isEmpty else { return [] }
        let texts = lines.map(\.text)
        let segments = TransactionSegmenter.segments(lines: lines)

        var results: [ParsedReceipt] = []
        var lastHadOwnDate = true
        for seg in segments {
            let blockLines = Array(texts[seg.range])
            let heroes = Set(seg.heroes.map { $0 - seg.range.lowerBound })
            let r = parseBlock(lines: blockLines, heroes: heroes, now: now, calendar: calendar)
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
        return results
    }

    static func prepare(_ raw: [OCRLine]) -> [OCRLine] {
        raw.map { l in
            var c = l
            c.text = normalize(l.text).trimmingCharacters(in: .whitespacesAndNewlines)
            return c
        }
        .filter { !$0.text.isEmpty }
    }

    /// 解析一笔交易的文本块
    static func parseBlock(lines: [String], heroes: Set<Int>, now: Date, calendar: Calendar) -> ParsedReceipt {
        var result = ParsedReceipt()
        result.rawText = lines.joined(separator: "\n")

        var candidates = amountCandidates(lines: lines)
        for i in candidates.indices where heroes.contains(candidates[i].lineIndex) {
            candidates[i].score += 40   // 大字金额
        }
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
        // 英文界面（Repay:CMB Credit card 等）先转成中文再找账户线索 / 还款
        let hintText = EnglishBankTerms.localize(fullText)
        result.accountHint = AccountHintParser.parse(text: hintText)
        result.date = date(lines: lines, now: now, calendar: calendar)

        if RepaymentDetector.isCardRepayment(text: hintText) {
            result.isCardRepayment = true
            result.isIncome = false
            result.categoryName = "信用卡还款"
            let split = RepaymentDetector.split(text: hintText)
            result.repaymentCard = split.card
            result.accountHint = split.payer
            return result
        }

        if let m = result.merchant, let c = CategoryGuesser.guess(text: m, isIncome: result.isIncome) {
            result.categoryName = c
        } else {
            result.categoryName = CategoryGuesser.guess(text: fullText, isIncome: result.isIncome)
        }
        return result
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

    static let strongKeywords = ["实付款", "实付金额", "实付", "实收金额", "实收", "付款金额", "支付金额", "交易金额",
                                 "消费金额", "订单金额", "应付金额", "应付", "合计", "总计", "总金额", "总价",
                                 "支出金额", "转账金额", "收款金额", "到账金额", "退款金额", "扣款金额"]
    static let weakKeywords = ["金额", "价格", "消费", "支出", "付款", "支付", "交易", "扣款", "收款", "到账", "人民币"]
    static let negativeKeywords = ["优惠", "折扣", "立减", "减免", "抵扣", "积分", "余额", "可用", "限额", "额度",
                                   "原价", "运费", "配送费", "包装费", "手续费", "找零", "返现", "券", "满", "单价",
                                   "数量", "已省", "节省", "共省"]
    static let countSuffixes: Set<Character> = ["件", "个", "次", "份", "张", "笔", "位", "人", "天", "期", "号", "楼", "室", "%", "折", "斤", "克", "g", "G", "k", "K", "m", "M"]

    private static let amountPattern = try! NSRegularExpression(
        pattern: #"(?<![\d.,])([+\-]?)\s*(¥|RMB|CNY|人民币)?\s*([+\-]?)\s*(\d{1,3}(?:,\d{3})+|\d+)(\.\d{1,2})?(?![\d.])\s*(元)?"#)

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
                } else if weakKeywords.contains(where: { label.contains($0) }) {
                    score += 30; hasKeyword = true
                }
                // 标签与金额分行（如「实付款」下一行是「¥20.00」）
                if !hasKeyword, lineCandidates.isEmpty, label.trimmingCharacters(in: .whitespaces).count <= 1,
                   index > 0, !lineHadCandidates[index - 1] {
                    let prev = lines[index - 1]
                    if strongKeywords.contains(where: { prev.contains($0) }) { score += 45; hasKeyword = true }
                    else if weakKeywords.contains(where: { prev.contains($0) }) { score += 20; hasKeyword = true }
                    if negativeKeywords.contains(where: { prev.contains($0) }) { score -= 30 }
                }
                // 只看紧邻金额前面的一小段做负向判断，避免整行误伤
                let nearLabel = String(label.suffix(8))
                if negativeKeywords.contains(where: { nearLabel.contains($0) }) { score -= 45 }

                if hasCurrency { score += 30 }
                if decPart.count == 3 { score += 20 } else if decPart.count == 2 { score += 10 }
                if sign == "-" || sign == "+" { score += 25 }

                // 整行只有这个金额（微信/支付宝支付成功页的大字金额）
                let rest = ns.replacingCharacters(in: m.range, with: "")
                    .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":-+")))
                if rest.isEmpty { score += 20 }

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

    // MARK: - 商户

    static let merchantKeywords = ["商户全称", "商户名称", "商家名称", "收款方全称", "收款商户", "收款方", "收款人",
                                   "交易对方", "对方账户", "对方户名", "付款方", "付款人", "商品说明", "商品名称", "付款给", "转账给",
                                   "店铺名称", "门店名称", "商户", "商家", "店铺", "门店", "对方"]
    static let merchantBlacklist = ["支付成功", "付款成功", "交易成功", "支付完成", "账单详情", "交易详情", "完成",
                                    "当前状态", "返回", "已支付", "订单详情", "转账成功", "收款成功", "收款到账",
                                    "已收款", "数量", "单价", "金额", "合计", "实付", "支付方式", "付款方式",
                                    "账单分类", "订单号", "交易单号", "商户单号", "支付时间", "交易时间", "创建时间",
                                    "备注", "查看", "联系", "申请", "电子小票", "全部账单", "微信支付", "支付宝",
                                    "待收货", "已完成", "零钱", "储蓄卡", "信用卡", "交易状态", "留言", "我的账单",
                                    "支付服务", "账单服务", "付款成功", "对方已收款", "退款成功", "退款方式"]

    static func merchant(lines: [String], amountLineIndex: Int?) -> String? {
        for key in merchantKeywords {
            for (i, line) in lines.enumerated() {
                guard let r = line.range(of: key) else { continue }
                // 关键词需位于行首附近（避免「请向商家确认」之类）
                guard line.distance(from: line.startIndex, to: r.lowerBound) <= 2 else { continue }
                var value = String(line[r.upperBound...])
                value = cleanMerchant(value)
                if value.isEmpty, i + 1 < lines.count { value = cleanMerchant(lines[i + 1]) }
                if isPlausibleMerchant(value) { return value }
            }
        }
        // 兜底：从金额所在行往上找第一行像名称的文本
        if let idx = amountLineIndex, idx > 0 {
            for i in stride(from: idx - 1, through: 0, by: -1) {
                let v = cleanMerchant(lines[i])
                if isPlausibleMerchant(v) { return v }
            }
        }
        // 金额同一行前面的文字（账单列表「滴滴出行 -23.50」）
        if let idx = amountLineIndex, idx < lines.count {
            let label = cleanMerchant(lines[idx].replacingOccurrences(
                of: #"\s*[+-]?\s*¥?\s*[+-]?\s*[\d,]+(\.\d{1,2})?\s*元?\s*$"#, with: "", options: .regularExpression))
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

    static func cleanMerchant(_ s: String) -> String {
        var v = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":>›〉》|")))
        for re in avatarArtifactPatterns {
            let ns = v as NSString
            v = re.stringByReplacingMatches(in: v, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        }
        v = v.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":>›〉》|")))
        if v.count > 30 { v = String(v.prefix(30)) }
        return v
    }

    private static func isPlausibleMerchant(_ s: String) -> Bool {
        guard s.count >= 2, s.count <= 30 else { return false }
        if merchantBlacklist.contains(where: { s.contains($0) }) { return false }
        if s.hasPrefix("使用") && s.contains("支付") { return false }       // 「使用零钱支付」
        if TransactionSegmenter.isDateHeader(s) { return false }
        let digits = s.filter { $0.isNumber }.count
        if digits >= 3 { return false }
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return letters >= 2
    }

    // MARK: - 日期

    static let periodPattern = "凌晨|早上|早晨|上午|中午|下午|傍晚|晚上|夜里|夜间"
    private static let fullDatePattern = try! NSRegularExpression(
        pattern: #"(20\d{2})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?\s*(?:("# + periodPattern + #")?\s*(\d{1,2}):(\d{2})(?::(\d{2}))?)?"#)
    private static let monthDayPattern = try! NSRegularExpression(
        pattern: #"(?<!\d)(\d{1,2})\s*月\s*(\d{1,2})\s*日\s*(?:("# + periodPattern + #")?\s*(\d{1,2}):(\d{2}))?"#)
    private static let relativePattern = try! NSRegularExpression(
        pattern: #"(今天|昨天|前天|星期[一二三四五六日天]|周[一二三四五六日天])?\s*("# + periodPattern + #")?\s*(\d{1,2}):(\d{2})"#)
    private static let dashMonthDayPattern = try! NSRegularExpression(
        pattern: #"(?<![\d-])(\d{1,2})-(\d{1,2})\s+(\d{1,2}):(\d{2})"#)
    private static let bareDayPattern = try! NSRegularExpression(pattern: #"(今天|昨天|前天)"#)

    /// 「下午3:25」→ 15:25，「凌晨12:30」→ 0:30
    static func hour24(_ h: Int, period: String) -> Int {
        switch period {
        case "下午", "傍晚", "晚上", "夜里", "夜间": return h < 12 ? h + 12 : h
        case "中午": return h < 11 ? h + 12 : h
        case "凌晨", "早上", "早晨", "上午": return h == 12 ? 0 : h
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

    static func date(lines: [String], now: Date, calendar: Calendar) -> Date? {
        let text = lines.joined(separator: "\n")
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let latest = now.addingTimeInterval(2 * 86_400)

        if let m = fullDatePattern.firstMatch(in: text, range: range) {
            var c = DateComponents()
            c.year = Int(group(m, 1, ns)); c.month = Int(group(m, 2, ns)); c.day = Int(group(m, 3, ns))
            c.hour = hour24(Int(group(m, 5, ns)) ?? 12, period: group(m, 4, ns))
            c.minute = Int(group(m, 6, ns)) ?? 0; c.second = Int(group(m, 7, ns)) ?? 0
            if valid(c), let d = calendar.date(from: c), d <= latest { return d }
        }
        if let m = monthDayPattern.firstMatch(in: text, range: range) {
            var c = DateComponents()
            c.year = calendar.component(.year, from: now)
            c.month = Int(group(m, 1, ns)); c.day = Int(group(m, 2, ns))
            c.hour = hour24(Int(group(m, 4, ns)) ?? 12, period: group(m, 3, ns))
            c.minute = Int(group(m, 5, ns)) ?? 0
            if valid(c), var d = calendar.date(from: c) {
                if d > latest, let prev = calendar.date(byAdding: .year, value: -1, to: d) { d = prev }
                return d
            }
        }
        for m in relativePattern.matches(in: text, range: range) {
            let dayWord = group(m, 1, ns), period = group(m, 2, ns)
            guard !dayWord.isEmpty || !period.isEmpty else { continue }   // 单独的「14:32」多半是状态栏
            guard let h = Int(group(m, 3, ns)), let mi = Int(group(m, 4, ns)), h < 24, mi < 60 else { continue }
            let offset = dayOffset(dayWord, now: now, calendar: calendar) ?? 0
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  var d = calendar.date(bySettingHour: hour24(h, period: period), minute: mi, second: 0, of: day) else { continue }
            // 只有「下午3:00」没有日期、且晚于现在：视为昨天
            if dayWord.isEmpty, d > now.addingTimeInterval(300), let y = calendar.date(byAdding: .day, value: -1, to: d) { d = y }
            return d
        }
        if let m = dashMonthDayPattern.firstMatch(in: text, range: range) {
            var c = DateComponents()
            c.year = calendar.component(.year, from: now)
            c.month = Int(group(m, 1, ns)); c.day = Int(group(m, 2, ns))
            c.hour = Int(group(m, 3, ns)); c.minute = Int(group(m, 4, ns))
            if valid(c), var d = calendar.date(from: c) {
                if d > latest, let prev = calendar.date(byAdding: .year, value: -1, to: d) { d = prev }
                return d
            }
        }
        if let m = bareDayPattern.firstMatch(in: text, range: range),
           let offset = dayOffset(group(m, 1, ns), now: now, calendar: calendar),
           let day = calendar.date(byAdding: .day, value: offset, to: now) {
            return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)
        }
        return nil
    }

    private static func valid(_ c: DateComponents) -> Bool {
        guard let mo = c.month, let d = c.day else { return false }
        return (1...12).contains(mo) && (1...31).contains(d) && (0...23).contains(c.hour ?? 0) && (0...59).contains(c.minute ?? 0)
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
        pattern: #"^[+-]?\s*¥?\s*[+-]?\s*(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2}\s*元?$"#)
    private static let yenAmountOnlyPattern = try! NSRegularExpression(
        pattern: #"^[+-]?\s*¥\s*(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2}$"#)
    /// 账单列表行：「滴滴出行 -23.50」
    private static let billRowPattern = try! NSRegularExpression(
        pattern: #"^(\S.{1,29}?)\s+[+-]\s*¥?\s*(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2}$"#)

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
        let headers = texts.indices.filter { isDateHeader(texts[$0]) }
        if smsStarts.count >= 2 {
            starts = smsStarts
        } else if billRows.count >= 2 {
            starts = billRows
        } else {
            starts = headers
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
                let above = texts[max(0, i - 2)..<i]
                if above.contains(where: isPayLine) { heroSet.insert(i) }
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

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}

/// 根据关键词猜测分类（名称需与默认分类一致；找不到时由调用方回退到「其他」）
enum CategoryGuesser {
    static let expenseRules: [(String, [String])] = [
        ("生活缴费", ["电费", "水费", "燃气", "煤气", "国家电网", "供电", "自来水", "物业", "缴费", "宽带", "暖气"]),
        ("娱乐", ["电影", "影城", "影院", "猫眼", "淘票票", "游戏", "Steam", "腾讯视频", "爱奇艺", "优酷", "网易云", "QQ音乐",
                "哔哩哔哩", "bilibili", "B站", "KTV", "网吧", "剧本杀", "演出", "大麦", "健身"]),
        ("通讯", ["话费", "中国移动", "中国联通", "中国电信", "流量", "手机充值"]),
        ("交通", ["滴滴", "打车", "快车", "地铁", "公交", "出行", "高德", "加油", "中石化", "中石油", "停车", "高速", "ETC", "畅行", "通行费", "路桥", "收费站", "etc",
                "12306", "铁路", "哈啰", "单车", "曹操", "T3", "花小猪", "如祺", "享道", "充电"]),
        ("旅行", ["携程", "飞猪", "去哪儿", "酒店", "机票", "航空", "民宿", "景区", "门票", "同程", "途牛"]),
        ("居住", ["房租", "租金", "自如", "贝壳", "链家", "家政", "保洁"]),
        ("医疗", ["医院", "药房", "药店", "诊所", "医保", "挂号", "体检", "口腔", "牙科"]),
        ("教育", ["学费", "培训", "课程", "书店", "教育", "考试", "知识", "得到", "网课"]),
        ("餐饮", ["美团外卖", "饿了么", "外卖", "餐", "饭", "咖啡", "星巴克", "瑞幸", "肯德基", "KFC", "麦当劳", "奶茶", "喜茶",
                "蜜雪", "茶", "食堂", "烧烤", "火锅", "小吃", "饮品", "烘焙", "面包", "必胜客", "汉堡", "塔斯汀", "面馆",
                "料理", "酒楼", "饺子", "麻辣烫", "早点", "包子", "Coffee", "coffee", "库迪", "美团"]),
        ("购物", ["淘宝", "天猫", "京东", "拼多多", "超市", "便利店", "商城", "全家", "罗森", "7-11", "7-Eleven", "盒马",
                "沃尔玛", "永辉", "唯品会", "抖音", "优衣库", "屈臣氏", "名创", "山姆", "Costco", "苹果", "Apple", "小米",
                "华为", "商店", "百货", "购物"]),
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
        for (name, keywords) in rules where keywords.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return name
        }
        return nil
    }
}
