import Foundation

// Apple 智能提示词的构建、长度估算、时间预算与错误分类（纯 Foundation，见 Tools/ModelMergeCheck）。
// 端侧模型上下文约 4096 tokens（指令 + 结构 + 文字 + 输出共用），中文约 1 字 1 token 以上：
// 2.0 (3) 的长指令 + 14 个带说明的账户 + 24 行 OCR + 900 输出上限已接近 / 超过上限，
// 表现为超时或 GenerationError。这里把每一部分都压短，并按温度 / 重试降级。

/// 提示词级别：标准 → 精简（设备发热）→ 极简（重试）
enum PromptLevel: String, Sendable, CaseIterable {
    case normal, compact, minimal

    var title: String {
        switch self {
        case .normal: return "标准"
        case .compact: return "精简"
        case .minimal: return "极简"
        }
    }
    var maxLines: Int { self == .normal ? 28 : self == .compact ? 20 : 14 }
    var maxChars: Int { self == .normal ? 760 : self == .compact ? 520 : 360 }
    var maxLineChars: Int { self == .normal ? 90 : 64 }
    var maxResponseTokens: Int { self == .normal ? 480 : self == .compact ? 400 : 320 }
    var maxAccounts: Int { self == .normal ? 16 : self == .compact ? 12 : 8 }
    var maxCategories: Int { self == .normal ? 20 : self == .compact ? 14 : 10 }
    /// 重试时的下一级
    var smaller: PromptLevel { self == .normal ? .compact : .minimal }
    /// 发热（serious / critical）时直接从精简开始
    static func initial(thermalSerious: Bool) -> PromptLevel { thermalSerious ? .compact : .normal }
}

/// 一次请求的提示词与长度统计（统计可写日志，文字本身不写）
struct ModelPrompt: Equatable, Sendable {
    var level: PromptLevel
    var instructions: String
    var prompt: String
    var totalLines: Int
    var keptLines: Int
    var noiseLines: Int
    var truncatedLines: Int
    var estimatedTokens: Int

    var summary: String {
        "级别 \(level.title) · 指令 \(instructions.count) 字 · 文字 \(prompt.count) 字（\(totalLines) 行 → \(keptLines) 行，去噪 \(noiseLines)"
            + (truncatedLines > 0 ? "，截断 \(truncatedLines)" : "") + "）· 约 \(estimatedTokens) tokens（含结构 \(ModelPromptBuilder.schemaTokenEstimate)，输出上限 \(level.maxResponseTokens)）"
    }
}

enum ModelPromptBuilder {
    /// 端侧模型上下文长度（tokens）
    static let contextTokens = 4096
    /// @Generable 结构（字段名 + 简短说明）大致占用
    static let schemaTokenEstimate = 200
    /// 估算误差余量
    static let safetyMargin = 300

    // MARK: 长度估算（没有官方 tokenCount API 时的保守估计）

    /// 中日韩字符按 1.3 token / 字，其他非空白字符约 3.2 字 / token
    static func estimateTokens(_ s: String) -> Int {
        var cjk = 0, other = 0
        for u in s.unicodeScalars {
            switch u.value {
            case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF: cjk += 1
            default:
                if !CharacterSet.whitespacesAndNewlines.contains(u) { other += 1 }
            }
        }
        return Int((Double(cjk) * 1.3).rounded(.up)) + Int((Double(other) / 3.2).rounded(.up))
    }

    // MARK: OCR 去噪

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private static let statusOnly = re(#"^(\d{1,2}:\d{2}|\d{1,3}\s?%|[2345]G\+?|LTE|VoLTE|HD|Wi-?Fi|SOS|无服务)$"#)
    private static let longDigits = re(#"\d(?:[\s-]?\d){11,}"#)
    private static let idLabel = re(#"单号|流水|编号|订单号|凭证号|参考号|交易号|批次号|终端号|商户号|order\s*(no|number|id)|transaction\s*(no|number|id)|serial|reference|ref\.?\s*no|voucher|\bID\b"#)
    private static let paymentWords = re(#"支付|付款|消费|还款|收款|转账|退款|实付|金额|到账|扣款|入账|repay|payment|amount|paid"#)
    private static let adWords = ["广告", "推广", "立即领取", "领取", "优惠券", "抽奖", "限时", "抢购", "下载", "免费领", "福利", "积分兑换",
                                  "专享", "点击", "了解详情", "去看看", "猜你喜欢", "为你推荐", "推荐", "开通", "邀请", "活动"]
    /// 只占一行的按钮 / 导航 / 页脚文字（整行完全一致才去掉）
    static let buttonLines: Set<String> = [
        "返回", "完成", "关闭", "取消", "更多", "分享", "首页", "我的", "全部", "筛选", "搜索", "编辑", "设置", "帮助", "客服",
        "<", "‹", "〈", "...", "…", "···", "×", "x", "X", "<返回", "< 返回",
        "back", "done", "close", "more", "share", "cancel", "help", "faq", "customer service", "contact us",
        "联系客服", "联系商家", "联系收款方", "对此订单有疑问", "对此账单有疑问", "常见问题", "查看帮助", "申请电子回单",
        "申请转账电子回单", "查看往来转账", "查看往来记录", "查看往来", "发起群收款", "查看更多", "去评价", "去看看", "去使用",
        "立即领取", "立即查看", "了解更多", "账单服务", "本服务由财付通提供", "本服务由支付宝提供", "查看账单详情", "更多操作",
    ]

    struct Cleaned: Equatable {
        var lines: [OCRLine]
        var noise: Int
    }

    /// 去掉状态栏、按钮 / 导航 / 页脚、广告、订单号等长 ID 行；其余长数字串替换为 #。不改动原始 OCR（规则解析仍用全文）。
    static func clean(_ lines: [OCRLine]) -> Cleaned {
        var out: [OCRLine] = []
        var noise = 0
        var last = ""
        for l in lines {
            var t = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            let ns = t as NSString
            let full = NSRange(location: 0, length: ns.length)
            // 状态栏：顶部 4.5% 内，或开头的纯时间 / 电量 / 信号
            if l.height > 0 && l.midY < 0.045 { noise += 1; continue }
            if statusOnly.firstMatch(in: t, range: full) != nil && (out.isEmpty || (l.height > 0 && l.midY < 0.08)) { noise += 1; continue }
            guard t.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }) else {
                noise += 1; continue
            }
            if buttonLines.contains(t.lowercased()) { noise += 1; continue }
            let hasPaymentWord = paymentWords.firstMatch(in: t, range: full) != nil
            if !hasPaymentWord && t.count >= 4 && adWords.contains(where: { t.contains($0) }) { noise += 1; continue }
            // 订单号 / 流水号 / 卡号全号：标签 + 长数字串整行去掉；其他行里的长数字串替换为 #
            if longDigits.firstMatch(in: t, range: full) != nil {
                if idLabel.firstMatch(in: t, range: full) != nil && !hasPaymentWord { noise += 1; continue }
                // 保留末 4 位（可能是卡号尾号），其余换成 #
                var stripped = t
                for m in longDigits.matches(in: t, range: full).reversed() {
                    let digits = ns.substring(with: m.range).filter(\.isNumber)
                    stripped = (stripped as NSString).replacingCharacters(in: m.range, with: "#" + String(digits.suffix(4)))
                }
                if stripped.trimmingCharacters(in: CharacterSet(charactersIn: "#0123456789 :：")).isEmpty { noise += 1; continue }
                t = stripped
            }
            if t == last { noise += 1; continue }
            last = t
            var c = l
            c.text = t
            out.append(c)
        }
        return Cleaned(lines: out, noise: noise)
    }

    // MARK: 文字中的线索（决定是否附上英文字段说明 / 还款示例）

    static let bankAbbreviations: [(String, String)] = [
        ("CMBC", "民生银行"), ("CMB", "招商银行"), ("ICBC", "工商银行"), ("CCB", "建设银行"), ("ABC", "农业银行"), ("BOCOM", "交通银行"),
        ("BCM", "交通银行"), ("BOC", "中国银行"), ("CIB", "兴业银行"), ("CEB", "光大银行"), ("SPDB", "浦发银行"), ("CITIC", "中信银行"),
        ("PSBC", "邮储银行"), ("GDB", "广发银行"), ("CGB", "广发银行"), ("PAB", "平安银行"),
    ]

    static func isEnglishHeavy(_ lines: [String]) -> Bool {
        let word = re(#"[A-Za-z]{4,}"#)
        return lines.filter { word.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }.count >= 3
    }

    static func looksLikeRepayment(_ lines: [String]) -> Bool {
        let r = re(#"还款|还信用卡|repay|credit\s*card"#)
        return lines.contains { r.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
    }

    /// 文字中出现的银行英文缩写（整词匹配）
    static func banksMentioned(_ lines: [String]) -> [(String, String)] {
        let text = lines.joined(separator: " ")
        var seen = Set<String>()
        var out: [(String, String)] = []
        for (abbr, name) in bankAbbreviations {
            let r = try! NSRegularExpression(pattern: "(?<![A-Za-z])\(abbr)(?![A-Za-z])")
            if r.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil, seen.insert(abbr).inserted {
                out.append((abbr, name))
            }
        }
        return out
    }

    // MARK: 指令（只依赖词表与级别：可在 OCR 之前创建会话并预加载）

    static func instructions(expenseCategories: [String], incomeCategories: [String], accounts: [String], level: PromptLevel) -> String {
        func short(_ s: String, _ n: Int) -> String { String(s.trimmingCharacters(in: .whitespaces).prefix(n)) }
        let expense = expenseCategories.prefix(level.maxCategories).map { short($0, 8) }
        let income = incomeCategories.prefix(max(4, level.maxCategories / 2)).map { short($0, 8) }
        let accts = accounts.prefix(level.maxAccounts).map { short($0, 14) }
        var s = """
        你是记账助手，从支付截图的 OCR 文字提取交易。
        - amount：原文中的交易金额，取正数，不得计算；忽略余额、额度、优惠、积分、广告、单号、卡号。
        - kind：付款/消费/支付成功/转给他人=expense；收款/到账=income；退款=income 且 refund=true；信用卡/花呗还款=repay；余额宝/零钱通转入转出、充值、提现、自己账户互转=transfer。
        - 还款/转账：from=付款账户，to=被还款卡或收款账户，fromTail/toTail=对应卡号末 4 位，banks=截图中的银行；要同银行同卡种，不确定就留空。
        - 多笔按从上到下各输出一次。★ 表示大字。没有的字段留空。
        """
        if level == .normal { s += "\n- date 原样抄写日期时间文字。" }
        s += "\n分类（category 只能选）：支出 \(expense.joined(separator: "、"))；收入 \(income.joined(separator: "、"))。还款不填分类。"
        s += "\n账户（account/from/to 只能选，或留空）：\(accts.isEmpty ? "无" : accts.joined(separator: "、"))"
        return s
    }

    // MARK: 提示词（OCR 文字 + 按需附加的说明）

    static func hints(lines: [String], level: PromptLevel) -> String {
        var parts: [String] = []
        if isEnglishHeavy(lines) {
            parts.append("英文：Repay/Repayment=还款；Payment Method/Paid with=付款账户(from)；Credit Card Number/Repay card=被还款卡(to)；Order Amount/Amount=金额；Order Time/Transaction Time=时间；Debit/Savings card=储蓄卡；Credit card=信用卡。")
            let banks = banksMentioned(lines)
            if !banks.isEmpty { parts.append("银行：" + banks.map { "\($0.0)=\($0.1)" }.joined(separator: "，") + "。") }
        }
        if looksLikeRepayment(lines) && level != .minimal {
            parts.append("例：「Repay:CCB Credit card / ¥88.00 / Payment Method CCB Debit card[1111] / Credit Card Number CCB Credit card[2222]」→ kind=repay amount=88 fromTail=1111 toTail=2222 banks=[建设银行]")
        }
        return parts.joined(separator: "\n")
    }

    /// 组装提示词：去噪 → 每行限长 → 按级别限行数 / 字数 → 总 token 超预算时继续去掉尾部行
    static func build(lines raw: [OCRLine], instructions: String, level: PromptLevel) -> ModelPrompt {
        let cleaned = clean(raw)
        let texts = cleaned.lines.map(\.text)
        let hint = hints(lines: texts, level: level)
        var body: [String] = []
        var chars = 0
        var truncated = 0
        for l in cleaned.lines {
            var t = String(l.text.prefix(level.maxLineChars))
            if l.height >= 0.03 { t = "★" + t }
            if body.count >= level.maxLines || chars + t.count + 1 > level.maxChars { truncated += 1; continue }
            body.append(t)
            chars += t.count + 1
        }
        func assemble() -> String {
            (hint.isEmpty ? "" : hint + "\n") + "OCR：\n" + body.joined(separator: "\n")
        }
        let fixed = estimateTokens(instructions) + schemaTokenEstimate + level.maxResponseTokens + safetyMargin
        var prompt = assemble()
        while body.count > 4 && fixed + estimateTokens(prompt) > contextTokens {
            body.removeLast(); truncated += 1
            prompt = assemble()
        }
        return ModelPrompt(level: level, instructions: instructions, prompt: prompt, totalLines: raw.count,
                           keptLines: body.count, noiseLines: cleaned.noise, truncatedLines: truncated,
                           estimatedTokens: estimateTokens(instructions) + schemaTokenEstimate + estimateTokens(prompt))
    }
}

// MARK: 时间预算

enum ModelBudget {
    /// 快捷指令：从开始识别算起约 19 秒内给出结果（之后还有审核弹窗），模型最多 15 秒、至少 8 秒
    static let shortcutTotal: Double = 19
    static let shortcutMax: Double = 15
    static let shortcutMin: Double = 8
    /// App 内：最多 20 秒
    static let inAppTotal: Double = 24
    static let inAppMax: Double = 20
    static let inAppMin: Double = 10
    /// 第一次失败后，剩余时间至少这么多才重试
    static let minRetrySeconds: Double = 4

    /// elapsed：识别开始（含 OCR）到现在的秒数
    static func timeout(shortcut: Bool, elapsed: Double) -> Double {
        let e = elapsed.isFinite ? max(0, elapsed) : 0
        if shortcut { return min(shortcutMax, max(shortcutMin, shortcutTotal - e)) }
        return min(inAppMax, max(inAppMin, inAppTotal - e))
    }
}

// MARK: 错误分类（日志 / 诊断只写种类与经过脱敏的框架说明，不写 OCR 文字和金额）

enum ModelErrorKind: String, Sendable, Equatable {
    case exceededContextWindowSize, guardrailViolation, assetsUnavailable, rateLimited, concurrentRequests,
         decodingFailure, unsupportedLanguageOrLocale, unsupportedGuide, refusal, cancelled, timeout, unknown

    var title: String {
        switch self {
        case .exceededContextWindowSize: return "超出上下文长度"
        case .guardrailViolation: return "触发安全限制"
        case .assetsUnavailable: return "模型资源不可用"
        case .rateLimited: return "后台调用受限"
        case .concurrentRequests: return "正忙（并发请求）"
        case .decodingFailure: return "结果解析失败"
        case .unsupportedLanguageOrLocale: return "不支持当前语言"
        case .unsupportedGuide: return "结构不受支持"
        case .refusal: return "模型拒绝"
        case .cancelled: return "已取消"
        case .timeout: return "超时"
        case .unknown: return "未知错误"
        }
    }

    /// 换更短的提示词 / 稍后再试一次有机会成功
    var retryable: Bool {
        switch self {
        case .exceededContextWindowSize, .decodingFailure, .concurrentRequests, .guardrailViolation, .unknown: return true
        default: return false
        }
    }

    /// 从错误种类名 / 说明文字猜种类（无法直接转换成 GenerationError 时，例如跨版本桥接成 NSError）
    static func guess(from text: String) -> ModelErrorKind {
        // 去掉类型名本身（「LanguageModelSession」「GenerationError」里的 language / rat 等会误判）
        var t = text.lowercased()
        for noise in ["foundationmodels.", "languagemodelsession", "generationerror", "operation", "domain"] {
            t = t.replacingOccurrences(of: noise, with: " ")
        }
        let table: [(String, ModelErrorKind)] = [
            ("context window", .exceededContextWindowSize), ("contextwindow", .exceededContextWindowSize), ("exceeded", .exceededContextWindowSize), ("guardrail", .guardrailViolation), ("unsafe", .guardrailViolation),
            ("sensitive", .guardrailViolation), ("asset", .assetsUnavailable), ("rate limit", .rateLimited), ("ratelimit", .rateLimited), ("rate-limit", .rateLimited), ("throttl", .rateLimited),
            ("concurrent", .concurrentRequests), ("decod", .decodingFailure), ("locale", .unsupportedLanguageOrLocale),
            ("language", .unsupportedLanguageOrLocale), ("guide", .unsupportedGuide), ("refus", .refusal), ("cancel", .cancelled),
        ]
        return table.first { t.contains($0.0) }?.1 ?? .unknown
    }
}

enum ModelErrorText {
    /// 框架给出的说明文字脱敏：只留 ASCII；带小数点或 5 位以上的数字换成 #；去掉在 OCR 原文中出现过的英文单词（≥3 字母）；限长
    static func sanitize(_ raw: String, source: String, limit: Int = 160) -> String {
        var ascii = String(String.UnicodeScalarView(raw.unicodeScalars.map { ($0.isASCII && $0.value >= 0x20 && $0.value < 0x7F) ? $0 : " " }))
        let num = try! NSRegularExpression(pattern: #"\d+\.\d+|\d{5,}"#)
        ascii = num.stringByReplacingMatches(in: ascii, range: NSRange(location: 0, length: (ascii as NSString).length), withTemplate: "#")
        let sourceWords = Set(source.lowercased().split(whereSeparator: { !$0.isLetter || !$0.isASCII }).map(String.init).filter { $0.count >= 3 })
        let word = try! NSRegularExpression(pattern: #"[A-Za-z]{3,}"#)
        let ns = ascii as NSString
        var out = ""
        var cursor = 0
        for m in word.matches(in: ascii, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let w = ns.substring(with: m.range)
            out += sourceWords.contains(w.lowercased()) ? "~" : w
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        let collapsed = out.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
        return String(collapsed.prefix(limit))
    }
}
