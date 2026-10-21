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
// 结构尽量短：字段名短、说明短、非必填字段可省略（少占上下文、少生成 token）
@available(iOS 26.0, *)
@Generable(description: "一笔交易")
struct AIReceiptTransaction {
    @Guide(description: "原文金额，正数")
    var amount: Double
    @Guide(description: "类型", .anyOf(["expense", "income", "transfer", "repay"]))
    var kind: String
    @Guide(description: "商户或对方")
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

/// 识图开始时（与 OCR 并行）创建并预加载的会话；只依赖词表与级别，不含截图内容
final class PreparedModelSession: @unchecked Sendable {
    let level: PromptLevel
    let instructions: String
    let createdAt = Date()
    fileprivate let session: AnyObject?

    fileprivate init(level: PromptLevel, instructions: String, session: AnyObject?) {
        self.level = level
        self.instructions = instructions
        self.session = session
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

    private static func begin() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        // 超时后模型任务仍未结束：60 秒内不叠加新请求；超过 60 秒视为卡死，允许重新请求
        if inFlight && Date().timeIntervalSince(inFlightSince) < 60 { return false }
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

    /// 预加载模型（App 回到前台 / 打开记一笔时调用），减少首次识别的冷启动时间
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard OCREngineSetting.preferAppleIntelligence, AppleIntelligenceStatus.current.isAvailable else { return }
            stateLock.lock()
            let recent = lastPrewarm.map { Date().timeIntervalSince($0) < 120 } ?? false
            if !recent { lastPrewarm = Date() }
            stateLock.unlock()
            guard !recent else { return }
            let session = LanguageModelSession(instructions: "你是记账助手，从支付截图的 OCR 文字提取交易。")
            session.prewarm()
            // 持有一会儿，避免会话立即释放导致预加载被放弃
            stateLock.lock(); warmSession = session; stateLock.unlock()
        }
        #endif
    }

    /// 识图开始时调用（在 OCR 之前）：按词表与温度创建会话并预加载，OCR 期间模型同时加载
    static func prepareSession(vocabulary: OCRVocabulary) -> PreparedModelSession {
        let level = PromptLevel.initial(thermalSerious: thermalSerious)
        let ins = instructions(vocabulary: vocabulary, level: level)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: ins)
            session.prewarm()
            return PreparedModelSession(level: level, instructions: ins, session: session)
        }
        #endif
        return PreparedModelSession(level: level, instructions: ins, session: nil)
    }

    static func extract(lines: [OCRLine], vocabulary: OCRVocabulary, timeout: Double,
                        prepared: PreparedModelSession? = nil, stats: ModelRunStats = ModelRunStats()) async -> Result<[ModelTransaction], Failure> {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            // 上一次（超时后）仍在后台运行：不再叠加请求，直接用规则
            guard begin() else { return .failure(Failure(reason: "上一次识别仍在进行", kind: .concurrentRequests)) }
            let seconds = max(1, timeout)
            let deadline = Date().addingTimeInterval(seconds)
            let source = lines.map(\.text).joined(separator: "\n")
            let firstLevel = prepared?.level ?? PromptLevel.initial(thermalSerious: thermalSerious)
            return await HardTimeout.run(seconds: seconds, onTimeout: { () -> Result<[ModelTransaction], Failure> in
                stats.add(error: .timeout)
                let n = stats.attempts
                return .failure(Failure(reason: "超时（\(Int(seconds)) 秒\(n > 1 ? "，第 \(n) 次" : "")）", kind: .timeout))
            }, operation: { () async -> Result<[ModelTransaction], Failure> in
                defer { end() }
                var level = firstLevel
                var attempt = 1
                while true {
                    let ins = (attempt == 1 && prepared?.level == level) ? prepared!.instructions : instructions(vocabulary: vocabulary, level: level)
                    let built = ModelPromptBuilder.build(lines: lines, instructions: ins, level: level)
                    stats.set(prompt: built.summary)
                    stats.add(attempt: "第 \(attempt) 次 \(level.title) 约 \(built.estimatedTokens) tokens")
                    RunLog.shared.log(.info, "model-prompt", "第 \(attempt) 次：" + built.summary)
                    let reuse = attempt == 1 && prepared?.level == level ? prepared?.session as? LanguageModelSession : nil
                    if attempt == 1 {
                        RunLog.shared.log(.info, "model-session", reuse != nil
                            ? "使用预加载会话（已预加载 \(Int(Date().timeIntervalSince(prepared!.createdAt) * 1000)) ms）" : "新建会话")
                    }
                    let t = Date()
                    do {
                        let session = reuse ?? LanguageModelSession(instructions: built.instructions)
                        let result = try await run(session: session, prompt: built.prompt, level: level)
                        RunLog.shared.log(.info, "model-attempt", "第 \(attempt) 次成功，用时 \(Int(Date().timeIntervalSince(t) * 1000)) ms，\(result.count) 笔")
                        return .success(result)
                    } catch {
                        let info = classify(error, source: source)
                        stats.add(error: info.kind)
                        let remaining = deadline.timeIntervalSinceNow
                        RunLog.shared.log(.warn, "model-error", "第 \(attempt) 次失败，用时 \(Int(Date().timeIntervalSince(t) * 1000)) ms："
                            + "\(info.kind.rawValue)（\(info.kind.title)）· \(info.detail) · 剩余 \(String(format: "%.1f", max(0, remaining))) 秒")
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
    private static func run(session: LanguageModelSession, prompt: String, level: PromptLevel) async throws -> [ModelTransaction] {
        try Task.checkCancellation()
        let response = try await session.respond(to: prompt, generating: AIReceiptExtraction.self,
                                                 options: GenerationOptions(sampling: .greedy,
                                                                            maximumResponseTokens: level.maxResponseTokens))
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
