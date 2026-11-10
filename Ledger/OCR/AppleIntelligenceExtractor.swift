import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 「识别引擎」：自动（优先 Apple 智能）/ 仅规则。设备级设置（与外观一样存在标准偏好中）
enum OCREngineSetting {
    static let key = "ocr.engine"
    static let auto = "auto"
    static let rulesOnly = "rules"

    static var preferAppleIntelligence: Bool {
        (UserDefaults.standard.string(forKey: key) ?? auto) != rulesOnly
    }

    /// 「快捷指令中使用 Apple 智能」：默认关闭。快捷指令（背面轻点等）通常在其他 App 前台时于后台运行，
    /// 系统会限制后台调用端侧模型、并对后台运行时长有限制；关闭时快捷指令只用规则，App 内识图仍用 Apple 智能。
    static let shortcutsKey = "ocr.engine.shortcuts"
    static var useInShortcuts: Bool { UserDefaults.standard.bool(forKey: shortcutsKey) }

    /// App 内 / 快捷指令的模型超时上限（实际按已用时间自适应，见 ModelBudget）
    static let inAppTimeout: Double = ModelBudget.inAppMax
    static let shortcutTimeout: Double = ModelBudget.shortcutMax
}

/// Apple 智能（端侧基础模型）的可用状态
enum AppleIntelligenceStatus: Equatable {
    case available
    case unsupportedOS
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case unsupportedLanguage
    case unavailable

    var isAvailable: Bool { self == .available }

    /// 设置页的状态行
    var title: String {
        switch self {
        case .available: return "Apple 智能 可用"
        case .unsupportedOS: return "需要 iOS 26 或更高版本"
        case .deviceNotEligible: return "设备不支持"
        case .notEnabled: return "未开启（设置 › Apple 智能与 Siri）"
        case .modelNotReady: return "模型下载中"
        case .unsupportedLanguage: return "不支持中文 / 当前语言"
        case .unavailable: return "暂不可用"
        }
    }

    /// 回退说明里用：「Apple 智能 + 原因」
    var shortReason: String {
        switch self {
        case .available: return "可用"
        case .unsupportedOS: return "需要 iOS 26"
        case .deviceNotEligible: return "设备不支持"
        case .notEnabled: return "未开启"
        case .modelNotReady: return "模型下载中"
        case .unsupportedLanguage: return "不支持当前语言"
        case .unavailable: return "暂不可用"
        }
    }

    static var current: AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                // 提示词与 OCR 文字都是中文：需要模型支持简体中文
                return model.supportsLocale(Locale(identifier: "zh_CN")) ? .available : .unsupportedLanguage
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .deviceNotEligible
                case .appleIntelligenceNotEnabled: return .notEnabled
                case .modelNotReady: return .modelNotReady
                @unknown default: return .unavailable
                }
            }
        }
        #endif
        return .unsupportedOS
    }
}

#if canImport(FoundationModels)
// 单笔极速结构（覆盖 90%+ 日常消费/收款/退款/互转截图）：仅 5 个非可选标量字段、无外层数组包装、无日期/尾号/银行冗余字段，解码仅需 ~18 tokens
@available(iOS 26.0, *)
@Generable
struct AISingleReceipt {
    var amount: Double
    @Guide(.anyOf(["expense", "income", "refund", "transfer"]))
    var kind: String
    var merchant: String
    var category: String
    var account: String
}

@available(iOS 26.0, *)
@Generable
struct AIMultiReceipt {
    @Guide(.maximumCount(6))
    var items: [AISingleReceipt]
}

// 还款专用完整结构（含付款卡、被还款卡、尾号与银行）
@available(iOS 26.0, *)
@Generable(description: "一笔交易")
struct AIReceiptTransaction {
    @Guide(description: "原文金额，正数")
    var amount: Double
    @Guide(description: "类型", .anyOf(["expense", "income", "transfer", "repay"]))
    var kind: String
    @Guide(description: "商户、收款方或商品名称；不能是满减、立减、优惠券、红包、返现、积分、折扣等优惠活动文字")
    var merchant: String?
    @Guide(description: "分类名")
    var category: String?
    @Guide(description: "账户名")
    var account: String?
    @Guide(description: "日期时间原文")
    var date: String?
    var refund: Bool?
    @Guide(description: "付款账户")
    var from: String?
    @Guide(description: "收款或被还款账户")
    var to: String?
    @Guide(description: "付款卡末4位")
    var fromTail: String?
    @Guide(description: "被还款或收款卡末4位")
    var toTail: String?
    @Guide(description: "截图中的银行")
    var banks: [String]?
}

@available(iOS 26.0, *)
@Generable(description: "截图中的交易")
struct AIReceiptExtraction {
    @Guide(description: "从上到下", .maximumCount(8))
    var transactions: [AIReceiptTransaction]
}
#endif

/// 识图开始时（或打开记账页时提前）创建并预加载的会话；只依赖词表与级别，不含截图内容
final class PreparedModelSession: @unchecked Sendable {
    let level: PromptLevel
    let instructions: String
    let createdAt = Date()
    let wasPrewarmed: Bool
    fileprivate let session: AnyObject?

    fileprivate init(level: PromptLevel, instructions: String, session: AnyObject?, wasPrewarmed: Bool = false) {
        self.level = level
        self.instructions = instructions
        self.session = session
        self.wasPrewarmed = wasPrewarmed
    }
}

/// 一次抽取的统计（写日志 / 诊断，不含文字和金额）
final class ModelRunStats: @unchecked Sendable {
    private let lock = NSLock()
    private var _attempts: [String] = []
    private var _lastPrompt: String?
    private var _errorKinds: [ModelErrorKind] = []

    func add(attempt: String) { lock.lock(); _attempts.append(attempt); lock.unlock() }
    func set(prompt: String) { lock.lock(); _lastPrompt = prompt; lock.unlock() }
    func add(error: ModelErrorKind) { lock.lock(); _errorKinds.append(error); lock.unlock() }
    var attempts: Int { lock.lock(); defer { lock.unlock() }; return _attempts.count }
    var errorKinds: [ModelErrorKind] { lock.lock(); defer { lock.unlock() }; return _errorKinds }
    var promptSummary: String? { lock.lock(); defer { lock.unlock() }; return _lastPrompt }
    /// 诊断用的一行：「第 2 次 · 精简 · 约 1200 tokens · 首次：超出上下文长度」
    var line: String {
        lock.lock(); defer { lock.unlock() }
        var parts: [String] = []
        if !_attempts.isEmpty { parts.append(_attempts.joined(separator: " → ")) }
        if !_errorKinds.isEmpty { parts.append("错误 " + _errorKinds.map(\.title).joined(separator: "、")) }
        return parts.joined(separator: " · ")
    }
}

/// 用端侧模型从 OCR 文字中抽取交易。任何失败（不可用、语言、限流、超时、解码错误）都返回 failure，由调用方回退规则解析。
/// 超时是硬上限：到时立即返回并取消模型任务，不等待它结束（快捷指令在后台有运行时长限制，等待会被系统终止）。
/// 可恢复的错误（超出上下文 / 解码失败 / 并发 / 安全限制误判 / 未知）在剩余时间足够时用更短的提示词重试一次。
enum AppleIntelligenceExtractor {
    struct Failure: Error, Sendable {
        let reason: String
        var kind: ModelErrorKind = .unknown
    }

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var inFlight = false
    nonisolated(unsafe) private static var inFlightSince = Date.distantPast
    nonisolated(unsafe) private static var lastPrewarm: Date?
    nonisolated(unsafe) private static var warmSession: AnyObject?
    nonisolated(unsafe) private static var cachedPrepared: PreparedModelSession?

    private static func begin() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        // 超时后模型任务仍未结束：15 秒内不叠加新请求；超过 15 秒允许重新请求
        if inFlight && Date().timeIntervalSince(inFlightSince) < 15 { return false }
        inFlight = true
        inFlightSince = Date()
        return true
    }

    private static func end() {
        stateLock.lock(); inFlight = false; stateLock.unlock()
    }

    static var thermalSerious: Bool {
        let t = ProcessInfo.processInfo.thermalState
        return t == .serious || t == .critical
    }

    static func instructions(vocabulary: OCRVocabulary, level: PromptLevel) -> String {
        ModelPromptBuilder.instructions(expenseCategories: vocabulary.expenseCategories,
                                        incomeCategories: vocabulary.incomeCategories,
                                        accounts: vocabulary.accounts, level: level)
    }

    /// 预加载模型（App 回到前台 / 打开记一笔时调用）：直接按用户词表异步预热并缓存会话，选图期间完成 KV 预计算，避免阻塞主线程或与 Vision OCR 争抢 ANE
    static func prewarm(vocabulary: OCRVocabulary? = nil) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard OCREngineSetting.preferAppleIntelligence else { return }
            let vocabCopy = vocabulary
            Task.detached(priority: .utility) {
                guard AppleIntelligenceStatus.current.isAvailable else { return }
                let level = PromptLevel.initial(thermalSerious: thermalSerious)
                if let vocab = vocabCopy {
                    let ins = instructions(vocabulary: vocab, level: level)
                    stateLock.lock()
                    if let c = cachedPrepared, c.instructions == ins, Date().timeIntervalSince(c.createdAt) < 180 {
                        stateLock.unlock()
                        return
                    }
                    lastPrewarm = Date()
                    stateLock.unlock()
                    let session = LanguageModelSession(instructions: ins)
                    session.prewarm()
                    let prep = PreparedModelSession(level: level, instructions: ins, session: session, wasPrewarmed: true)
                    stateLock.lock()
                    cachedPrepared = prep
                    warmSession = session
                    stateLock.unlock()
                    return
                }
                stateLock.lock()
                let recent = lastPrewarm.map { Date().timeIntervalSince($0) < 120 } ?? false
                if !recent { lastPrewarm = Date() }
                stateLock.unlock()
                guard !recent else { return }
                let session = LanguageModelSession(instructions: "从支付截图OCR提取交易。")
                session.prewarm()
                stateLock.lock(); warmSession = session; stateLock.unlock()
            }
        }
        #endif
    }

    /// 识图开始时调用（在 OCR 之前）：优先复用打开页面时已预热好的同词表会话；
    /// 若尚未预热，仅创建会话而不与 Vision OCR 并发调用 prewarm()，避免争抢神经网络引擎（ANE）拖慢 OCR
    static func prepareSession(vocabulary: OCRVocabulary, prewarm: Bool = true) -> PreparedModelSession {
        let level = PromptLevel.initial(thermalSerious: thermalSerious)
        let ins = instructions(vocabulary: vocabulary, level: level)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            stateLock.lock()
            if let c = cachedPrepared, c.instructions == ins, Date().timeIntervalSince(c.createdAt) < 240 {
                cachedPrepared = nil
                stateLock.unlock()
                return c
            }
            stateLock.unlock()
            let session = LanguageModelSession(instructions: ins)
            return PreparedModelSession(level: level, instructions: ins, session: session, wasPrewarmed: false)
        }
        #endif
        return PreparedModelSession(level: level, instructions: ins, session: nil, wasPrewarmed: false)
    }

    static func extract(lines: [OCRLine], vocabulary: OCRVocabulary, timeout: Double,
                        prepared: PreparedModelSession? = nil, stats: ModelRunStats = ModelRunStats(),
                        screen: PaymentScreen? = nil, expectedCount: Int = 1,
                        allowRetry: Bool = true) async -> Result<[ModelTransaction], Failure> {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            // 上一次（超时后）仍在后台运行：不再叠加请求，直接用规则
            guard begin() else { return .failure(Failure(reason: "上一次识别仍在进行", kind: .concurrentRequests)) }
            let seconds = max(0.8, timeout)
            let deadline = Date().addingTimeInterval(seconds)
            let texts = lines.map(\.text)
            let source = texts.joined(separator: "\n")
            let scr = screen ?? PaymentScreenDetector.detect(texts)
            let isRepay = ModelPromptBuilder.looksLikeRepayment(texts)
            let isMulti = scr.layout == .bankPush || scr.layout == .payAssistant || scr.layout == .chatTransfer || expectedCount > 1
            let useFastSingle = !isRepay && !isMulti
            let firstLevel = prepared?.level ?? PromptLevel.initial(thermalSerious: thermalSerious)
            return await HardTimeout.run(seconds: seconds, onTimeout: { () -> Result<[ModelTransaction], Failure> in
                stats.add(error: .timeout)
                let n = stats.attempts
                return .failure(Failure(reason: "超时（\(String(format: "%.1f", seconds)) 秒\(n > 1 ? "，第 \(n) 次" : "")）", kind: .timeout))
            }, operation: { () async -> Result<[ModelTransaction], Failure> in
                defer {
                    end()
                    // 识别结束后异步补充预热下一个会话，保证连续识图也秒出
                    let vocabCopy = vocabulary
                    Task.detached(priority: .utility) {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        AppleIntelligenceExtractor.prewarm(vocabulary: vocabCopy)
                    }
                }
                var level = firstLevel
                var attempt = 1
                while true {
                    let ins = (attempt == 1 && prepared?.level == level) ? prepared!.instructions : instructions(vocabulary: vocabulary, level: level)
                    let built = useFastSingle
                        ? ModelPromptBuilder.buildFastSingle(lines: lines, instructions: ins, level: level, screen: scr)
                        : ModelPromptBuilder.build(lines: lines, instructions: ins, level: level, screen: scr)
                    stats.set(prompt: built.summary)
                    stats.add(attempt: "第 \(attempt) 次 \(level.title)\(useFastSingle ? "·单笔极速" : "") 约 \(built.estimatedTokens) tokens")
                    RunLog.shared.log(.info, "model-prompt", "第 \(attempt) 次：" + built.summary)
                    let reuse = attempt == 1 && prepared?.level == level ? prepared?.session as? LanguageModelSession : nil
                    if attempt == 1 {
                        RunLog.shared.log(.info, "model-session", reuse != nil
                            ? "复用会话（\(prepared?.wasPrewarmed == true ? "已提前预热" : "已就绪") \(Int(Date().timeIntervalSince(prepared!.createdAt) * 1000)) ms）" : "新建会话")
                    }
                    let t = Date()
                    do {
                        let session = reuse ?? LanguageModelSession(instructions: built.instructions)
                        let result: [ModelTransaction]
                        if useFastSingle {
                            result = try await runSingle(session: session, prompt: built.prompt)
                        } else if !isRepay {
                            result = try await runMulti(session: session, prompt: built.prompt, level: level)
                        } else {
                            result = try await runRepay(session: session, prompt: built.prompt, level: level)
                        }
                        RunLog.shared.log(.info, "model-attempt", "第 \(attempt) 次成功，用时 \(Int(Date().timeIntervalSince(t) * 1000)) ms，\(result.count) 笔")
                        return .success(result)
                    } catch {
                        let info = classify(error, source: source)
                        stats.add(error: info.kind)
                        let remaining = deadline.timeIntervalSinceNow
                        RunLog.shared.log(.warn, "model-error", "第 \(attempt) 次失败，用时 \(Int(Date().timeIntervalSince(t) * 1000)) ms："
                            + "\(info.kind.rawValue)（\(info.kind.title)）· \(info.detail) · 剩余 \(String(format: "%.1f", max(0, remaining))) 秒")
                        guard allowRetry else {
                            return .failure(Failure(reason: "出错：\(info.kind.title)", kind: info.kind))
                        }
                        // 后台限流（rateLimited）：等 1.5 秒用同级提示词、新会话再试一次（剩余时间够才试）
                        if attempt == 1, info.kind == .rateLimited, remaining >= ModelBudget.rateLimitRetryDelay + ModelBudget.minRetrySeconds,
                           !Task.isCancelled {
                            attempt = 2
                            RunLog.shared.log(.info, "model-retry", "后台调用受限（第 1 次 \(Int(Date().timeIntervalSince(t) * 1000)) ms 即被拒，"
                                + "\(reuse != nil ? "用的是预加载会话" : "未预加载")），\(ModelBudget.rateLimitRetryDelay) 秒后新建会话重试一次")
                            try? await Task.sleep(nanoseconds: UInt64(ModelBudget.rateLimitRetryDelay * 1_000_000_000))
                            continue
                        }
                        if attempt == 1, info.kind.retryable, remaining >= ModelBudget.minRetrySeconds, !Task.isCancelled {
                            attempt = 2
                            level = level.smaller
                            if info.kind == .concurrentRequests { try? await Task.sleep(nanoseconds: 400_000_000) }
                            RunLog.shared.log(.info, "model-retry", "改用\(level.title)提示词重试")
                            continue
                        }
                        let prefix = attempt > 1 ? "重试后仍" : ""
                        return .failure(Failure(reason: prefix + "出错：\(info.kind.title)", kind: info.kind))
                    }
                }
            })
        }
        #endif
        return .failure(Failure(reason: "需要 iOS 26"))
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func toModelTransaction(_ item: AISingleReceipt) -> ModelTransaction {
        let rawKind = item.kind.lowercased()
        let isRefund = rawKind == "refund"
        let kind = isRefund ? "income" : rawKind
        let acct = item.account.trimmingCharacters(in: .whitespacesAndNewlines)
        return ModelTransaction(amount: item.amount, kind: kind,
                                merchant: item.merchant.trimmingCharacters(in: .whitespacesAndNewlines),
                                note: "",
                                categoryName: item.category.trimmingCharacters(in: .whitespacesAndNewlines),
                                accountHint: acct.isEmpty ? "未知" : acct,
                                dateText: "", isRefund: isRefund,
                                fromAccountHint: "", toAccountHint: "",
                                fromCardTail: "", toCardTail: "",
                                bankNames: [], reason: "")
    }

    @available(iOS 26.0, *)
    private static func runSingle(session: LanguageModelSession, prompt: String) async throws -> [ModelTransaction] {
        try Task.checkCancellation()
        let response = try await session.respond(to: prompt, generating: AISingleReceipt.self,
                                                 options: GenerationOptions(sampling: .greedy,
                                                                            maximumResponseTokens: 120))
        return [toModelTransaction(response.content)]
    }

    @available(iOS 26.0, *)
    private static func runMulti(session: LanguageModelSession, prompt: String, level: PromptLevel) async throws -> [ModelTransaction] {
        try Task.checkCancellation()
        let response = try await session.respond(to: prompt, generating: AIMultiReceipt.self,
                                                 options: GenerationOptions(sampling: .greedy,
                                                                            maximumResponseTokens: min(level.maxResponseTokens, 260)))
        return response.content.items.prefix(8).map(toModelTransaction)
    }

    @available(iOS 26.0, *)
    private static func runRepay(session: LanguageModelSession, prompt: String, level: PromptLevel) async throws -> [ModelTransaction] {
        try Task.checkCancellation()
        let response = try await session.respond(to: prompt, generating: AIReceiptExtraction.self,
                                                 options: GenerationOptions(sampling: .greedy,
                                                                            maximumResponseTokens: min(level.maxResponseTokens, 240)))
        return response.content.transactions.prefix(12).map {
            let kind = $0.kind.lowercased() == "repay" ? "cardRepayment" : $0.kind
            return ModelTransaction(amount: $0.amount, kind: kind, merchant: $0.merchant ?? "", note: "",
                                    categoryName: $0.category ?? "", accountHint: ($0.account ?? "").isEmpty ? "未知" : $0.account!,
                                    dateText: $0.date ?? "", isRefund: $0.refund ?? false,
                                    fromAccountHint: $0.from ?? "", toAccountHint: $0.to ?? "",
                                    fromCardTail: $0.fromTail ?? "", toCardTail: $0.toTail ?? "",
                                    bankNames: Array(($0.banks ?? []).prefix(3)), reason: "")
        }
    }

    struct ErrorInfo {
        var kind: ModelErrorKind
        var detail: String
    }

    /// 精确的错误种类 + 脱敏后的框架说明（ASCII、去掉原文中出现的单词和长数字），绝不包含 OCR 文字和金额
    @available(iOS 26.0, *)
    static func classify(_ error: Error, source: String) -> ErrorInfo {
        func clean(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            let r = ModelErrorText.sanitize(s, source: source, limit: 120)
            return r.isEmpty ? nil : r
        }
        if let e = error as? LanguageModelSession.GenerationError {
            let kind: ModelErrorKind
            let context: LanguageModelSession.GenerationError.Context
            switch e {
            case .exceededContextWindowSize(let c): kind = .exceededContextWindowSize; context = c
            case .assetsUnavailable(let c): kind = .assetsUnavailable; context = c
            case .guardrailViolation(let c): kind = .guardrailViolation; context = c
            case .unsupportedGuide(let c): kind = .unsupportedGuide; context = c
            case .unsupportedLanguageOrLocale(let c): kind = .unsupportedLanguageOrLocale; context = c
            case .decodingFailure(let c): kind = .decodingFailure; context = c
            case .rateLimited(let c): kind = .rateLimited; context = c
            case .concurrentRequests(let c): kind = .concurrentRequests; context = c
            case .refusal(_, let c): kind = .refusal; context = c
            @unknown default:
                let name = String(String(describing: e).prefix(while: { $0 != "(" }).prefix(40))
                return ErrorInfo(kind: ModelErrorKind.guess(from: name), detail: "新错误类型 " + (clean(name) ?? "?"))
            }
            let parts = [clean(context.debugDescription).map { "说明: \($0)" }, clean(e.failureReason).map { "原因: \($0)" }].compactMap { $0 }
            return ErrorInfo(kind: kind, detail: "GenerationError.\(kind.rawValue)" + (parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")))
        }
        if error is CancellationError { return ErrorInfo(kind: .cancelled, detail: "CancellationError") }
        // 无法直接转换（例如新系统版本跨进程桥接成 NSError）：记 domain / code / userInfo 键 / 底层错误，按说明文字猜种类
        let ns = error as NSError
        var parts = ["\(ns.domain) \(ns.code)", "类型 \(String(describing: type(of: error)).prefix(60))"]
        let keys = ns.userInfo.keys.sorted().prefix(8)
        if !keys.isEmpty { parts.append("键 " + keys.joined(separator: ",")) }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError { parts.append("底层 \(u.domain) \(u.code)") }
        let texts = [ns.localizedDescription, ns.localizedFailureReason, ns.userInfo["NSDebugDescription"] as? String,
                     ns.userInfo["debugDescription"] as? String]
        var kind = ModelErrorKind.unknown
        for t in texts.compactMap({ $0 }) where kind == .unknown { kind = ModelErrorKind.guess(from: t) }
        if kind == .unknown { kind = ModelErrorKind.guess(from: String(describing: error)) }
        if let d = clean(ns.localizedDescription) { parts.append("说明: \(d)") }
        if let d = clean(ns.userInfo["NSDebugDescription"] as? String) { parts.append("调试: \(d)") }
        return ErrorInfo(kind: kind, detail: parts.joined(separator: " · "))
    }
    #endif
}
