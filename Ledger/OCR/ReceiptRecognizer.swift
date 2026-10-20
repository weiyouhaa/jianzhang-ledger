import Foundation

/// 识别时提供给 Apple 智能的用户词表（分类 / 账户名），由调用方从当前账本（真实或防窥）读取
struct OCRVocabulary: Sendable {
    var expenseCategories: [String]
    var incomeCategories: [String]
    var accounts: [String]
}

/// 一次识别的结果：交易列表 + 使用的引擎 + 回退说明
struct OCRRecognition {
    var receipts: [ParsedReceipt]
    var engine: RecognitionEngine
    /// 例如「Apple 智能：设备不支持，已用规则」
    var note: String?

    /// 结果页 / 审核弹窗里显示的一小行字
    var engineLine: String {
        if let note { return "识别引擎：\(engine.title) · \(note)" }
        return "识别引擎：\(engine.title)"
    }
}

/// 本次识图使用的引擎说明（快捷指令的审核 / 结果片段在底部用小字显示）
enum OCRRunInfo {
    nonisolated(unsafe) static var engineLine: String?
}

/// 识图运行场景
enum OCRRunContext: String, Codable, Sendable {
    case inApp
    case shortcut

    var title: String { self == .inApp ? "App 内" : "快捷指令" }
}

/// 识别诊断（设置 › 智能记账 › 识别诊断）：只记引擎、耗时、回退原因与错误文字，不含截图文字和金额。
/// 只存本机标准偏好，防窥模式下不记录。
struct OCRDiagnostic: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var context: OCRRunContext
    var engine: String
    var aiStatus: String
    var ocrMs: Int
    var modelMs: Int?
    var lineCount: Int
    var resultCount: Int
    var dropped: Int
    var fallbackReason: String?

    static let key = "diag.ocr.recent"

    static func record(_ d: OCRDiagnostic) {
        guard !ModeDefaults.isDecoyMode else { return }
        var list = recent()
        list.insert(d, at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func recent() -> [OCRDiagnostic] {
        guard !ModeDefaults.isDecoyMode, let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([OCRDiagnostic].self, from: data)) ?? []
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// OCR + 解析的组合入口，App 内「从截图识别」和快捷指令共用。
/// 文字识别始终用 Vision；交易抽取在 iOS 26+ 且 Apple 智能可用时优先用端侧模型，结果经原文校验，否则回退规则解析。
enum ReceiptRecognizer {
    static func recognize(imageData: Data) async throws -> ParsedReceipt {
        let all = try await recognizeAll(imageData: imageData)
        return all.first ?? ParsedReceipt(rawText: "")
    }

    /// 一张截图里的全部交易（从上到下）。没有识别到金额时返回一个 amount 为 nil 的结果，便于给出原文提示。
    static func recognizeAll(imageData: Data, now: Date = Date(), vocabulary: OCRVocabulary? = nil) async throws -> [ParsedReceipt] {
        try await recognizeDetailed(imageData: imageData, now: now, vocabulary: vocabulary).receipts
    }

    static func recognizeDetailed(imageData: Data, now: Date = Date(), vocabulary: OCRVocabulary? = nil,
                                  context: OCRRunContext = .inApp) async throws -> OCRRecognition {
        let t0 = Date()
        let lines = try await TextRecognizer.recognizeOCRLines(in: imageData)
        let ocrMs = Int(Date().timeIntervalSince(t0) * 1000)
        RunLog.shared.log(.info, "ocr-done", "OCR 共 \(lines.count) 行，用时 \(ocrMs) ms（\(context == .shortcut ? "快捷指令" : "App 内")）")
        return await extract(lines: lines, now: now, vocabulary: vocabulary, context: context, ocrMs: ocrMs)
    }

    /// 规则解析结果（没有任何一笔时返回一个只带原文的结果）
    static func ruleReceipts(_ lines: [OCRLine], now: Date) -> [ParsedReceipt] {
        let all = ReceiptParser.parseAll(lines: lines, now: now)
        return all.isEmpty ? [ReceiptParser.parse(lines: lines.map(\.text), now: now)] : all
    }

    static func seconds(_ ms: Int) -> String { String(format: "%.1f 秒", Double(ms) / 1000) }

    static func extract(lines: [OCRLine], now: Date, vocabulary: OCRVocabulary?, context: OCRRunContext,
                        ocrMs: Int = 0) async -> OCRRecognition {
        let tRules = Date()
        let rules = ruleReceipts(lines, now: now)
        RunLog.shared.log(.info, "rules", "规则解析：\(rules.filter { ($0.amount ?? 0) > 0 }.count) 笔，用时 \(Int(Date().timeIntervalSince(tRules) * 1000)) ms")
        // 只在真正要用 Apple 智能时才查询模型状态：关闭时完全不触碰 FoundationModels
        var checkedStatus: AppleIntelligenceStatus?
        func finish(_ r: OCRRecognition, modelMs: Int? = nil, dropped: Int = 0, reason: String? = nil) -> OCRRecognition {
            let found = r.receipts.filter { ($0.amount ?? 0) > 0 }
            RunLog.shared.log(.info, "engine-result",
                              "引擎：\(r.engine.title)，\(found.count) 笔" + ((reason ?? r.note).map { "（\($0)）" } ?? ""))
            OCRDiagnostic.record(OCRDiagnostic(context: context, engine: r.engine.title, aiStatus: checkedStatus?.title ?? "未检查（未启用）",
                                               ocrMs: ocrMs, modelMs: modelMs, lineCount: lines.count,
                                               resultCount: r.receipts.filter { ($0.amount ?? 0) > 0 }.count,
                                               dropped: dropped, fallbackReason: reason ?? r.note))
            return r
        }
        guard OCREngineSetting.preferAppleIntelligence else {
            return finish(OCRRecognition(receipts: rules, engine: .rules, note: nil), reason: "设置为仅规则")
        }
        if context == .shortcut && !OCREngineSetting.useInShortcuts {
            return finish(OCRRecognition(receipts: rules, engine: .rules, note: nil),
                          reason: "快捷指令中未启用 Apple 智能")
        }
        RunLog.shared.log(.info, "ai-status", "查询 Apple 智能状态")
        let status = AppleIntelligenceStatus.current
        checkedStatus = status
        RunLog.shared.log(.info, "ai-status", "Apple 智能：\(status.title)")
        guard status.isAvailable else {
            return finish(OCRRecognition(receipts: rules, engine: .rules, note: "Apple 智能\(status.shortReason)"))
        }
        let prepared = ReceiptParser.prepare(lines)
        guard prepared.contains(where: { $0.text.rangeOfCharacter(from: .decimalDigits) != nil }) else {
            return finish(OCRRecognition(receipts: rules, engine: .rules, note: nil), reason: "截图中没有数字")
        }
        let vocab = vocabulary ?? OCRVocabulary(expenseCategories: [], incomeCategories: [], accounts: [])
        let ctx = ModelMerge.Context(lines: prepared.map(\.text),
                                     categories: vocab.expenseCategories + vocab.incomeCategories,
                                     incomeCategories: vocab.incomeCategories, accounts: vocab.accounts,
                                     now: now, calendar: .current)
        let timeout = context == .shortcut ? OCREngineSetting.shortcutTimeout : OCREngineSetting.inAppTimeout
        let t1 = Date()
        RunLog.shared.log(.info, "model-start", "端侧模型开始（超时 \(Int(timeout)) 秒，\(prepared.count) 行）")
        let result = await AppleIntelligenceExtractor.extract(lines: prepared, vocabulary: vocab, timeout: timeout)
        let modelMs = Int(Date().timeIntervalSince(t1) * 1000)
        switch result {
        case .success(let txns): RunLog.shared.log(.info, "model-end", "模型完成，用时 \(modelMs) ms，\(txns.count) 笔")
        case .failure(let f): RunLog.shared.log(.warn, "model-end", "模型失败，用时 \(modelMs) ms：\(f.reason)")
        }
        let outcome: ModelMerge.Outcome
        switch result {
        case .success(let txns):
            outcome = ModelMerge.merge(model: txns, rules: rules, ctx: ctx)
        case .failure(let f):
            outcome = ModelMerge.merge(model: nil, rules: rules, ctx: ctx, unavailableReason: "Apple 智能\(f.reason)，已用规则")
        }
        var receipts = outcome.receipts
        if receipts.isEmpty { receipts = rules }
        var note = outcome.fallbackReason
        if note == nil, outcome.dropped > 0 { note = "已剔除 \(outcome.dropped) 笔不在原文中的金额" }
        // 引擎行带耗时，便于诊断
        let timing: String? = "模型 " + seconds(modelMs)
        let fullNote = [timing, note].compactMap { $0 }.joined(separator: " · ")
        return finish(OCRRecognition(receipts: receipts, engine: outcome.engine, note: fullNote.isEmpty ? nil : fullNote),
                      modelMs: modelMs, dropped: outcome.dropped)
    }
}
