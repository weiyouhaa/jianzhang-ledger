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
@available(iOS 26.0, *)
@Generable(description: "支付截图中的一笔交易")
struct AIReceiptTransaction {
    @Guide(description: "交易金额，正数；必须是 OCR 文字里原样出现过的数字，不能计算或编造")
    var amount: Double
    @Guide(description: "交易类型：expense 支出，income 收入，transfer 自己账户之间转账，cardRepayment 信用卡/花呗还款",
           .anyOf(["expense", "income", "transfer", "cardRepayment"]))
    var kind: String
    @Guide(description: "商户、收款方或付款方名称；没有则为空字符串")
    var merchant: String
    @Guide(description: "简短备注；可为空字符串")
    var note: String
    @Guide(description: "分类名，只能使用指令中列出的分类名")
    var categoryName: String
    @Guide(description: "账户名，只能使用指令中列出的账户名；看不出来填「未知」")
    var accountHint: String
    @Guide(description: "截图上看到的日期时间原文，例如「昨天 下午3:25」；没有则为空字符串")
    var dateText: String
    @Guide(description: "是否为退款")
    var isRefund: Bool
}

@available(iOS 26.0, *)
@Generable(description: "截图中的全部交易")
struct AIReceiptExtraction {
    @Guide(description: "按截图从上到下排列的交易；没有交易时为空数组")
    var transactions: [AIReceiptTransaction]
}
#endif

/// 用端侧模型从 OCR 文字中抽取交易。任何失败（不可用、语言、限流、超时、解码错误）都返回 failure，由调用方回退规则解析。
enum AppleIntelligenceExtractor {
    struct Failure: Error, Sendable {
        let reason: String
    }

    static func extract(lines: [OCRLine], vocabulary: OCRVocabulary, timeout: Double) async -> Result<[ModelTransaction], Failure> {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let prompt = "以下是一张截图的 OCR 文字（每行：行号、纵向位置 y（0 顶部，1 底部）、大字标记 | 文字）。请提取其中的交易。\n\n"
                + ModelMerge.promptText(lines)
            let instructions = ModelMerge.instructions(
                categories: vocabulary.expenseCategories + vocabulary.incomeCategories,
                incomeCategories: vocabulary.incomeCategories, accounts: vocabulary.accounts)
            do {
                let txns = try await withThrowingTaskGroup(of: [ModelTransaction].self) { group -> [ModelTransaction] in
                    group.addTask { try await run(prompt: prompt, instructions: instructions) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                        throw Failure(reason: "超时（\(Int(timeout)) 秒）")
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next() else { throw Failure(reason: "无结果") }
                    return first
                }
                return .success(txns)
            } catch let f as Failure {
                return .failure(f)
            } catch {
                return .failure(Failure(reason: describe(error)))
            }
        }
        #endif
        return .failure(Failure(reason: "需要 iOS 26"))
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func run(prompt: String, instructions: String) async throws -> [ModelTransaction] {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: AIReceiptExtraction.self,
                                                 options: GenerationOptions(sampling: .greedy))
        return response.content.transactions.map {
            ModelTransaction(amount: $0.amount, kind: $0.kind, merchant: $0.merchant, note: $0.note,
                             categoryName: $0.categoryName, accountHint: $0.accountHint,
                             dateText: $0.dateText, isRefund: $0.isRefund)
        }
    }

    @available(iOS 26.0, *)
    private static func describe(_ error: Error) -> String {
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .rateLimited: return "后台调用受限（快捷指令在后台运行时常见）"
            case .unsupportedLanguageOrLocale: return "不支持当前语言"
            case .decodingFailure: return "结果解析失败"
            case .concurrentRequests: return "正忙"
            default: return "出错"
            }
        }
        if error is CancellationError { return "已取消" }
        return "出错"
    }
    #endif
}
