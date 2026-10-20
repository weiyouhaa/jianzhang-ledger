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
                                  timeout: Double = 8) async throws -> OCRRecognition {
        let lines = try await TextRecognizer.recognizeOCRLines(in: imageData)
        return await extract(lines: lines, now: now, vocabulary: vocabulary, timeout: timeout)
    }

    /// 规则解析结果（没有任何一笔时返回一个只带原文的结果）
    static func ruleReceipts(_ lines: [OCRLine], now: Date) -> [ParsedReceipt] {
        let all = ReceiptParser.parseAll(lines: lines, now: now)
        return all.isEmpty ? [ReceiptParser.parse(lines: lines.map(\.text), now: now)] : all
    }

    static func extract(lines: [OCRLine], now: Date, vocabulary: OCRVocabulary?, timeout: Double) async -> OCRRecognition {
        let rules = ruleReceipts(lines, now: now)
        guard OCREngineSetting.preferAppleIntelligence else {
            return OCRRecognition(receipts: rules, engine: .rules, note: nil)
        }
        let status = AppleIntelligenceStatus.current
        guard status.isAvailable else {
            return OCRRecognition(receipts: rules, engine: .rules, note: "Apple 智能\(status.shortReason)")
        }
        let prepared = ReceiptParser.prepare(lines)
        guard prepared.contains(where: { $0.text.rangeOfCharacter(from: .decimalDigits) != nil }) else {
            return OCRRecognition(receipts: rules, engine: .rules, note: nil)
        }
        let vocab = vocabulary ?? OCRVocabulary(expenseCategories: [], incomeCategories: [], accounts: [])
        let ctx = ModelMerge.Context(lines: prepared.map(\.text),
                                     categories: vocab.expenseCategories + vocab.incomeCategories,
                                     incomeCategories: vocab.incomeCategories, accounts: vocab.accounts,
                                     now: now, calendar: .current)
        let result = await AppleIntelligenceExtractor.extract(lines: prepared, vocabulary: vocab, timeout: timeout)
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
        return OCRRecognition(receipts: receipts, engine: outcome.engine, note: note)
    }
}
