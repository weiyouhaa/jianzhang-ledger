import AppIntents
import Foundation
import UniformTypeIdentifiers

/// 「识图记账」：接收快捷指令传入的截图/照片，设备端 OCR 后自动记一笔
struct RecognizeReceiptIntent: AppIntent {
    static var title: LocalizedStringResource = "识图记账"
    static var description = IntentDescription("识别支付宝、微信、银行等支付截图中的金额、商户与时间，自动记一笔。识别在本机完成，不联网。")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(
        title: "图片",
        supportedTypeIdentifiers: ["public.image"],
        requestValueDialog: "请选择要识别的支付截图",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var image: IntentFile

    @Parameter(title: "保存前确认", default: false)
    var confirmBeforeSaving: Bool

    @Parameter(title: "指定分类", description: "留空则根据商户关键词自动判断")
    var category: CategoryEntity?

    @Parameter(title: "收支类型", description: "留空则自动判断（默认支出）")
    var kind: RecordKindAppEnum?

    @Parameter(title: "账户", description: "留空则根据截图中的付款方式（支付宝 / 微信 / 银行卡尾号 / 信用卡 / 花呗）匹配")
    var account: AccountEntity?

    @Parameter(title: "备注")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("识别 \(\.$image) 并记账") {
            \.$confirmBeforeSaving
            \.$category
            \.$kind
            \.$account
            \.$note
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let data = image.data
        guard !data.isEmpty else { throw LedgerIntentError.unreadableImage }

        let parsed: ParsedReceipt
        do {
            parsed = try await ReceiptRecognizer.recognize(imageData: data)
        } catch {
            throw LedgerIntentError.unreadableImage
        }

        guard let amount = parsed.amount, amount > 0 else {
            let preview = String(parsed.rawText.replacingOccurrences(of: "\n", with: " ").prefix(60))
            throw LedgerIntentError.noAmount(preview.isEmpty ? "（无）" : preview)
        }

        let recordKind: RecordKind
        if let kind {
            recordKind = kind.kind
        } else if let category {
            recordKind = RecordKind(rawValue: category.kindRaw) ?? .expense
        } else {
            recordKind = parsed.isIncome ? .income : .expense
        }

        let merchant = parsed.merchant ?? ""
        let date = parsed.date ?? Date()

        if confirmBeforeSaving {
            let categoryText = category?.name ?? parsed.categoryName ?? "自动"
            var text = "识别到\(recordKind.title) \(Money.format(amount))，分类：\(categoryText)"
            if !merchant.isEmpty { text += "，商户：\(merchant)" }
            text += "。确认记账吗？"
            // 用户点「取消」时会抛出错误，快捷指令随即停止，不会保存
            if #available(iOS 18.0, *) {
                try await requestConfirmation(dialog: IntentDialog("\(text)"))
            } else {
                try await requestConfirmation(result: .result(dialog: IntentDialog("\(text)")))
            }
        }

        let record = try IntentRecorder.save(
            amount: amount,
            kind: recordKind,
            categoryID: category?.id,
            categoryName: parsed.categoryName,
            note: note ?? "",
            merchant: merchant,
            date: date,
            source: "ocr",
            accountID: account?.id,
            accountHint: parsed.accountHint
        )
        let summary = "已记账：" + IntentRecorder.summary(of: record)
        return .result(value: record.amount, dialog: IntentDialog("\(summary)"))
    }
}
