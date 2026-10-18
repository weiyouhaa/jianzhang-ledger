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

        let parsedList: [ParsedReceipt]
        do {
            parsedList = try await ReceiptRecognizer.recognizeAll(imageData: data)
        } catch {
            throw LedgerIntentError.unreadableImage
        }

        let found = parsedList.filter { ($0.amount ?? 0) > 0 }
        guard !found.isEmpty else {
            let raw = parsedList.first?.rawText ?? ""
            let preview = String(raw.replacingOccurrences(of: "\n", with: " ").prefix(60))
            throw LedgerIntentError.noAmount(preview.isEmpty ? "（无）" : preview)
        }

        struct Item {
            let parsed: ParsedReceipt
            let amount: Double
            let kind: RecordKind
            let merchant: String
            let date: Date
            let dateRecognized: Bool
        }
        let items: [Item] = found.map { p in
            let k: RecordKind
            if let kind {
                k = kind.kind
            } else if let category {
                k = RecordKind(rawValue: category.kindRaw) ?? .expense
            } else {
                k = p.isIncome ? .income : .expense
            }
            return Item(parsed: p, amount: p.amount ?? 0, kind: k, merchant: p.merchant ?? "",
                        date: p.date ?? Date(), dateRecognized: p.date != nil)
        }

        // 去重：同金额、同商户、时间相差 2 分钟内的已有记录
        var toSave: [Item] = []
        var skipped: [Item] = []
        for item in items {
            if item.dateRecognized && IntentRecorder.isDuplicate(amount: item.amount, merchant: item.merchant, date: item.date) {
                skipped.append(item)
            } else {
                toSave.append(item)
            }
        }

        func line(_ item: Item) -> String {
            var parts = ["\(item.kind.title) \(Money.format(item.amount))"]
            parts.append(category?.name ?? IntentRecorder.previewCategoryName(kind: item.kind, merchant: item.merchant,
                                                                                guessed: item.parsed.categoryName))
            if !item.merchant.isEmpty { parts.append(item.merchant) }
            parts.append(item.dateRecognized ? DateText.monthDayTime.string(from: item.date) : "时间未识别")
            return parts.joined(separator: " · ")
        }

        guard !toSave.isEmpty else {
            let text = "截图中的 \(skipped.count) 笔都已记过，未重复记账：\n" + skipped.map(line).joined(separator: "\n")
            return .result(value: 0, dialog: IntentDialog("\(text)"))
        }

        if confirmBeforeSaving {
            var text = toSave.count == 1 ? "识别到 1 笔：" : "识别到 \(toSave.count) 笔："
            for (i, item) in toSave.enumerated() { text += "\n\(i + 1). " + line(item) }
            if !skipped.isEmpty { text += "\n（另有 \(skipped.count) 笔已记过，将跳过）" }
            text += "\n确认记账吗？"
            // 用户点「取消」时会抛出错误，快捷指令随即停止，不会保存
            if #available(iOS 18.0, *) {
                try await requestConfirmation(dialog: IntentDialog("\(text)"))
            } else {
                try await requestConfirmation(result: .result(dialog: IntentDialog("\(text)")))
            }
        }

        var saved: [LedgerRecord] = []
        for item in toSave {
            let record = try IntentRecorder.save(
                amount: item.amount,
                kind: item.kind,
                categoryID: category?.id,
                categoryName: item.parsed.categoryName,
                note: note ?? "",
                merchant: item.merchant,
                date: item.date,
                source: "ocr",
                accountID: account?.id,
                accountHint: item.parsed.accountHint
            )
            saved.append(record)
        }

        var text: String
        if saved.count == 1 {
            text = "已记账：" + IntentRecorder.summary(of: saved[0])
        } else {
            text = "已记 \(saved.count) 笔："
            for (i, r) in saved.enumerated() { text += "\n\(i + 1). " + IntentRecorder.summary(of: r) }
        }
        if !skipped.isEmpty {
            text += "\n跳过 \(skipped.count) 笔重复：" + skipped.map(line).joined(separator: "；")
        }
        let total = saved.reduce(0) { $0 + $1.amount }
        return .result(value: total, dialog: IntentDialog("\(text)"))
    }
}
