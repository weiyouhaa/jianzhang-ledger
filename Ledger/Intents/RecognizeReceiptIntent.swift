import AppIntents
import Foundation
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 「识图记账」：接收快捷指令传入的截图/照片，设备端 OCR 后记账。
/// 默认「弹窗审核」：不打开 App，在快捷指令弹窗中列出识别结果，可增 / 删 / 改后再保存。
struct RecognizeReceiptIntent: AppIntent {
    static var title: LocalizedStringResource = "识图记账"
    static var description = IntentDescription("识别支付宝、微信、银行等支付截图中的金额、商户与时间，在弹窗中审核（可修改、删除、添加）后记账，也可直接保存。识别在本机完成，不联网。")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(
        title: "图片",
        supportedTypeIdentifiers: ["public.image"],
        requestValueDialog: "请选择要识别的支付截图",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var image: IntentFile

    /// 新参数：审核方式（默认弹窗审核）
    @Parameter(title: "审核方式", description: "弹窗审核：先列出识别结果，可修改 / 删除 / 添加后再保存；直接保存：识别后立即记账", default: .review)
    var reviewMode: ReviewModeAppEnum

    /// 旧版参数（保留标识符，兼容已有快捷指令）：打开时等同「弹窗审核」
    @Parameter(title: "保存前确认（旧）", description: "已由「审核方式」取代；打开时等同「弹窗审核」", default: false)
    var confirmBeforeSaving: Bool

    @Parameter(title: "指定分类", description: "留空则根据商户关键词自动判断")
    var category: CategoryEntity?

    @Parameter(title: "收支类型", description: "留空则自动判断（默认支出）")
    var kind: RecordKindAppEnum?

    @Parameter(title: "账户", description: "留空则根据截图中的付款方式（支付宝 / 微信 / 银行卡尾号 / 信用卡 / 花呗）匹配")
    var account: AccountEntity?

    @Parameter(title: "备注")
    var note: String?

    // MARK: 审核流程内部参数（不出现在参数摘要）
    // 自由输入统一走 String：iOS 26/27 上 requestChoice 之后再对 Double/Date 调 requestValue
    // 会直接结束弹窗（真机复现）；String 文本框更稳，金额/时间自行解析。
    // 多轮询问前先把对应参数置 nil，避免「已有值」被当成已解析而不再弹窗。

    @Parameter(title: "选项")
    var reviewChoice: ReviewChoiceEntity?

    @Parameter(title: "收支类型")
    var reviewKind: RecordKindAppEnum?

    @Parameter(title: "分类")
    var reviewCategory: CategoryEntity?

    @Parameter(title: "账户")
    var reviewAccount: AccountEntity?


    static var parameterSummary: some ParameterSummary {
        Summary("识别 \(\.$image) 并记账") {
            \.$reviewMode
            \.$category
            \.$kind
            \.$account
            \.$note
        }
    }

    /// 一次运行最多询问的步数，防止无限循环
    static let maxSteps = 30

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView & ReturnsValue<Double> {
        let data = image.data
        guard !data.isEmpty else { throw LedgerIntentError.unreadableImage }

        let parsedList: [ParsedReceipt]
        do {
            parsedList = try await ReceiptRecognizer.recognizeAll(imageData: data)
        } catch {
            throw LedgerIntentError.unreadableImage
        }

        let found = parsedList.filter { ($0.amount ?? 0) > 0 }
        let context = DataStore.shared.mainContext
        let review = reviewMode == .review || confirmBeforeSaving

        guard !found.isEmpty || review else {
            let raw = parsedList.first?.rawText ?? ""
            let preview = String(raw.replacingOccurrences(of: "\n", with: " ").prefix(60))
            throw LedgerIntentError.noAmount(preview.isEmpty ? "（无）" : preview)
        }

        var items: [ReviewItem] = found.map { p in
            let k: RecordKind
            if let kind {
                k = kind.kind
            } else if let category {
                k = RecordKind(rawValue: category.kindRaw) ?? .expense
            } else {
                k = p.isIncome ? .income : .expense
            }
            let merchant = p.merchant ?? ""
            let resolved = IntentRecorder.resolve(kind: k, merchant: merchant, note: note ?? "",
                                                  categoryID: category?.id, categoryName: p.categoryName,
                                                  accountID: account?.id, accountHint: p.accountHint)
            var item = ReviewItem(amount: p.amount ?? 0, kind: k, categoryID: resolved.category?.id,
                                  merchant: merchant, note: note ?? "", accountID: resolved.account?.id,
                                  date: p.date ?? Date(), dateRecognized: p.date != nil)
            // 去重：同金额、同商户、时间相差 2 分钟内的已有记录
            item.isDuplicate = item.dateRecognized
                && IntentRecorder.isDuplicate(amount: item.amount, merchant: item.merchant, date: item.date)
            return item
        }

        if review {
            var steps = 0
            let rawPreview = String((parsedList.first?.rawText ?? "").replacingOccurrences(of: "\n", with: " ").prefix(40))
            do {
                guard let reviewed = try await runReview(items, steps: &steps, context: context,
                                                         emptyHint: found.isEmpty ? "没有识别到金额" + (rawPreview.isEmpty ? "。" : "（识别到的文字：\(rawPreview)）。") : nil) else {
                    return try finish([], cancelled: true, context: context)
                }
                items = reviewed
            } catch let jump as JumpToApp {
                let saved = try persist(jump.items, context: context)
                let focusID: UUID?
                if let idx = jump.focusRecordIndex, idx < jump.items.count {
                    let target = jump.items[idx]
                    focusID = saved.first(where: {
                        abs($0.amount - target.amount) < 0.005
                            && $0.merchant == target.merchant
                            && abs($0.date.timeIntervalSince(target.date)) < 2
                    })?.id ?? saved.last?.id
                } else {
                    focusID = nil
                }
                PendingAppEdit.save(.init(recordID: focusID?.uuidString, isNew: jump.focusRecordIndex == nil, focus: nil))
                Self.bringAppToForeground()
                let msg = jump.focusRecordIndex == nil
                    ? "已保存 \(saved.count) 笔。正在打开简账，请在新建页补上这一笔。"
                    : "已保存 \(saved.count) 笔。正在打开简账继续修改。"
                return try finish(jump.items, cancelled: false, alreadySaved: saved, jumpMessage: msg, context: context)
            } catch {
                if Self.isUserCancel(error) {
                    return try finish([], cancelled: true, context: context)
                }
                return try finish(items, cancelled: false, errorMessage: error.localizedDescription, context: context)
            }
        }

        return try finish(items, cancelled: false, context: context)
    }

    // MARK: - 保存

    @MainActor
    private func finish(_ items: [ReviewItem], cancelled: Bool, errorMessage: String? = nil,
                        alreadySaved: [LedgerRecord]? = nil, jumpMessage: String? = nil,
                        context: ModelContext) throws -> some IntentResult & ProvidesDialog & ShowsSnippetView & ReturnsValue<Double> {
        if let errorMessage {
            return .result(value: Double(0),
                           dialog: IntentDialog("审核出错，没有保存任何记录。\n\(errorMessage)"),
                           view: ReviewSnippetView(title: "出错了", rows: rowsFor(items, context: context), footnote: errorMessage))
        }
        if cancelled {
            return .result(value: Double(0), dialog: IntentDialog("已取消，未保存任何记录。"),
                           view: ReviewSnippetView(title: "已取消", rows: []))
        }

        let saved: [LedgerRecord]
        let toSave = items.filter(\.willSave)
        let skipped = items.filter { !$0.willSave }

        if let alreadySaved {
            saved = alreadySaved
        } else {
            guard !toSave.isEmpty else {
                let text = skipped.isEmpty
                    ? "没有需要保存的记录，未记账。"
                    : "截图中的 \(skipped.count) 笔都已记过，未重复记账。"
                let skippedRows = skipped.enumerated().map { ReviewFormatter.row($0.element, index: $0.offset + 1, in: context) }
                return .result(value: Double(0), dialog: IntentDialog("\(text)"),
                               view: ReviewSnippetView(title: "未记账", rows: skippedRows))
            }
            saved = try persist(items, context: context)
        }

        var text: String
        if let jumpMessage {
            text = jumpMessage
        } else if saved.count == 1 {
            text = "已记账：" + IntentRecorder.summary(of: saved[0])
        } else {
            let expenseTotal = saved.reduce(0) { $0 + ($1.kind == .income ? 0 : $1.amount) }
            text = "已记 \(saved.count) 笔" + (expenseTotal > 0 ? "，支出合计 \(Money.format(expenseTotal))" : "") + "。"
            if !skipped.isEmpty { text += "跳过 \(skipped.count) 笔重复。" }
            if saved.contains(where: { $0.kind == .expense }), let b = BudgetService.currentStatus(in: context).total, b.budget > 0 {
                text += b.isOver ? "本月预算已超支 \(Money.format(-b.remaining))。" : "本月预算剩余 \(Money.format(b.remaining))。"
            }
        }

        let savedRows = toSave.enumerated().map { ReviewFormatter.row($0.element, index: $0.offset + 1, in: context) }
        let title = jumpMessage == nil ? "已记账" : "已保存，前往 App"
        let total = saved.reduce(0) { $0 + $1.amount }
        return .result(value: total, dialog: IntentDialog("\(text)"),
                       view: ReviewSnippetView(title: title, rows: savedRows))
    }

    // MARK: - 审核循环

    private enum Action: String {
        case saveAll, edit, delete, add, toggleDuplicates, cancel
    }

    private struct Option {
        let key: String
        let title: String
        var subtitle: String = ""
        var icon: String = ""
        var destructive = false
    }

    private struct ReviewCancelled: Error, CustomLocalizedStringResourceConvertible {
        var localizedStringResource: LocalizedStringResource { "已取消，未保存任何记录。" }
    }

    private struct ReviewInputError: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    @MainActor
    private func runReview(_ start: [ReviewItem], steps: inout Int, context: ModelContext, emptyHint: String?) async throws -> [ReviewItem]? {
        var items = start
        var hint = emptyHint
        while true {
            if steps >= Self.maxSteps {
                // 步数用尽：最后确认一次，取消则抛出错误、不保存
                let n = items.filter(\.willSave).count
                try await confirmFinal("操作步骤较多，先到这里。保存当前的 \(n) 笔吗？", items: items, context: context)
                return items
            }
            steps += 1
            let rows = rowsFor(items, context: context)
            let saving = items.filter(\.willSave)
            let single = items.count == 1
            var options: [Option] = []
            if !saving.isEmpty {
                let total = saving.reduce(0) { $0 + $1.amount }
                options.append(Option(key: Action.saveAll.rawValue,
                                      title: single ? "✅ 保存" : "✅ 全部保存（\(saving.count) 笔）",
                                      subtitle: "合计 \(Money.format(total))", icon: "checkmark.circle.fill"))
            }
            if !items.isEmpty {
                options.append(Option(key: Action.edit.rawValue, title: single ? "✏️ 修改" : "✏️ 修改第几笔…",
                                      subtitle: "金额、类型、分类、商户、账户、时间", icon: "pencil"))
                options.append(Option(key: Action.delete.rawValue, title: single ? "🗑 删除这笔" : "🗑 删除第几笔…",
                                      icon: "trash", destructive: true))
            }
            options.append(Option(key: Action.add.rawValue, title: "➕ 添加一笔（打开 App）",
                                  subtitle: "先保存当前列表，再打开新建页", icon: "plus.circle"))
            let dups = items.filter(\.isDuplicate)
            if !dups.isEmpty {
                let allSaving = dups.allSatisfy(\.saveDuplicate)
                options.append(Option(key: Action.toggleDuplicates.rawValue,
                                      title: allSaving ? "↩️ 重复的 \(dups.count) 笔改为跳过" : "♻️ 重复的 \(dups.count) 笔仍然保存",
                                      subtitle: "已有相同金额、商户、时间的记录", icon: "arrow.triangle.2.circlepath"))
            }
            if saving.isEmpty {
                options.append(Option(key: Action.saveAll.rawValue, title: "完成（不保存）", icon: "xmark.circle"))
            }
            options.append(Option(key: Action.cancel.rawValue, title: "取消", icon: "xmark"))

            var dialog: String
            if items.isEmpty {
                dialog = (hint ?? "已没有待保存的记录。") + "可以手动添加一笔。"
            } else {
                dialog = single ? "识别到 1 笔，确认无误就保存：" : "识别到 \(items.count) 笔，请核对："
                if #unavailable(iOS 26.0) {
                    // iOS 17 / 18 的选择列表无法附带视图，把明细写进提示文字
                    for r in rows { dialog += "\n\(r.index). " + ReviewFormatter.line(r) }
                }
            }
            hint = nil
            let snippet = ReviewSnippetView(title: items.isEmpty ? "识图记账" : "识别结果", rows: rows)
            let key = try await choose(options, dialog: dialog, view: snippet)

            switch Action(rawValue: key) ?? .cancel {
            case .saveAll:
                return items
            case .cancel:
                return nil
            case .toggleDuplicates:
                let allSaving = dups.allSatisfy(\.saveDuplicate)
                for i in items.indices where items[i].isDuplicate { items[i].saveDuplicate = !allSaving }
            case .delete:
                guard let index = try await pickItem(items, verb: "删除", steps: &steps, context: context) else { continue }
                items.remove(at: index)
            case .edit:
                guard let index = try await pickItem(items, verb: "修改", steps: &steps, context: context) else { continue }
                do {
                    items[index] = try await editItem(items[index], number: index + 1, steps: &steps, context: context,
                                                      allItems: items, index: index)
                } catch let jump as JumpToApp {
                    throw jump
                }
            case .add:
                _ = try await addItem(steps: &steps, context: context, allItems: items)
            }
        }
    }

    @MainActor
    private func rowsFor(_ items: [ReviewItem], context: ModelContext) -> [ReviewRow] {
        items.enumerated().map { ReviewFormatter.row($0.element, index: $0.offset + 1, in: context) }
    }

    @MainActor
    private func confirmFinal(_ text: String, items: [ReviewItem], context: ModelContext) async throws {
        let view = ReviewSnippetView(title: "识别结果", rows: rowsFor(items, context: context))
        // 带视图的确认（iOS 16+ 可用；在新系统上标记为 deprecated，但行为不变）
        try await requestConfirmation(result: .result(dialog: IntentDialog("\(text)"), view: view), confirmationActionName: .continue)
    }

    /// 选择第几笔；只有一笔时直接返回
    @MainActor
    private func pickItem(_ items: [ReviewItem], verb: String, steps: inout Int, context: ModelContext) async throws -> Int? {
        guard items.count > 1 else { return items.isEmpty ? nil : 0 }
        steps += 1
        let rows = rowsFor(items, context: context)
        var options = rows.map { r in
            Option(key: "\(r.index - 1)", title: "第 \(r.index) 笔 · \(r.amountText.dropFirst()) · \(r.merchant.isEmpty ? r.categoryName : r.merchant)",
                   subtitle: ReviewFormatter.line(r), icon: r.icon, destructive: verb == "删除")
        }
        options.append(Option(key: "back", title: "返回", icon: "chevron.backward"))
        let key = try await choose(options, dialog: "\(verb)哪一笔？",
                                   view: ReviewSnippetView(title: "识别结果", rows: rows))
        return Int(key)
    }

    // MARK: 修改

    private enum Field: String, CaseIterable {
        case appEdit, kind, category, account, dateNow, done
    }

    /// 需要打字的修改：先保存列表再打开 App（弹窗内不再做文本输入，iOS 27 上 requestChoice 后再输入会直接消失）
    private struct JumpToApp: Error {
        let focusRecordIndex: Int?   // nil = 新建
        var items: [ReviewItem]
    }

    @MainActor
    private func editItem(_ original: ReviewItem, number: Int, steps: inout Int, context: ModelContext,
                          allItems: [ReviewItem], index: Int) async throws -> ReviewItem {
        var item = original
        while steps < Self.maxSteps {
            steps += 1
            let row = ReviewFormatter.row(item, index: number, in: context)
            let options: [Option] = [
                Option(key: Field.appEdit.rawValue, title: "⌨️ 在 App 里改金额 / 商户 / 时间",
                       subtitle: "先保存当前列表，再打开简账编辑", icon: "arrow.up.forward.app"),
                Option(key: Field.kind.rawValue, title: "收支类型（\(item.kind == .income ? "收入" : "支出")）", icon: "arrow.left.arrow.right"),
                Option(key: Field.category.rawValue, title: "分类（\(row.categoryName)）", icon: row.icon),
                Option(key: Field.account.rawValue, title: "账户（\(row.accountName)）", icon: "creditcard"),
                Option(key: Field.dateNow.rawValue, title: "时间改为现在",
                       subtitle: DateText.monthDayTime.string(from: item.date), icon: "clock"),
                Option(key: Field.done.rawValue, title: "✅ 完成", icon: "checkmark"),
            ]
            let key = try await choose(options, dialog: "修改第 \(number) 笔：选择要改的项目",
                                       view: ReviewSnippetView(title: "第 \(number) 笔", rows: [row]))
            guard let field = Field(rawValue: key), field != .done else { break }
            steps += 1
            switch field {
            case .appEdit:
                var snapshot = allItems
                snapshot[index] = item
                throw JumpToApp(focusRecordIndex: index, items: snapshot)
            case .kind:
                reviewKind = nil
                let k = try await $reviewKind.requestDisambiguation(among: [.expense, .income],
                                                                    dialog: IntentDialog("收支类型（当前\(item.kind == .income ? "收入" : "支出")）"))
                if k.kind != item.kind {
                    item.kind = k.kind
                    let resolved = IntentRecorder.resolve(kind: item.kind, merchant: item.merchant, note: item.note,
                                                          categoryID: nil, categoryName: nil, accountID: item.accountID, accountHint: nil)
                    item.categoryID = resolved.category?.id
                }
            case .category:
                let list = DataStore.categories(kind: item.kind, in: context).map { CategoryEntity($0) }
                guard !list.isEmpty else { continue }
                reviewCategory = nil
                let c = try await $reviewCategory.requestDisambiguation(among: list, dialog: IntentDialog("选择分类（当前 \(row.categoryName)）"))
                item.categoryID = c.id
                item.kind = RecordKind(rawValue: c.kindRaw) ?? item.kind
                item.categoryEdited = true
            case .account:
                let list = DataStore.accounts(in: context).map { AccountEntity($0) }
                guard !list.isEmpty else { continue }
                reviewAccount = nil
                let a = try await $reviewAccount.requestDisambiguation(among: list, dialog: IntentDialog("选择账户（当前 \(row.accountName)）"))
                item.accountID = a.id
                item.accountEdited = true
            case .dateNow:
                item.date = Date()
                item.dateRecognized = true
            case .done:
                break
            }
            if !item.isManual {
                item.isDuplicate = IntentRecorder.isDuplicate(amount: item.amount, merchant: item.merchant, date: item.date)
                if !item.isDuplicate { item.saveDuplicate = false }
            }
        }
        return item
    }

    // MARK: 添加（改为跳进 App 新建）

    @MainActor
    private func addItem(steps: inout Int, context: ModelContext, allItems: [ReviewItem]) async throws -> ReviewItem? {
        let key = try await choose([
            Option(key: "app", title: "⌨️ 在 App 里添加一笔", subtitle: "先保存当前列表，再打开新建页", icon: "arrow.up.forward.app"),
            Option(key: "back", title: "返回", icon: "chevron.backward"),
        ], dialog: "添加一笔需要输入金额等，将打开简账完成。",
           view: ReviewSnippetView(title: "识别结果", rows: rowsFor(allItems, context: context)))
        if key == "app" { throw JumpToApp(focusRecordIndex: nil, items: allItems) }
        return nil
    }


    @MainActor
    private static func bringAppToForeground() {
        guard let url = URL(string: "jianzhang://pending-edit") else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    @MainActor
    @discardableResult
    private func persist(_ items: [ReviewItem], context: ModelContext) throws -> [LedgerRecord] {
        var saved: [LedgerRecord] = []
        for item in items where item.willSave {
            let record = try IntentRecorder.save(
                amount: item.amount, kind: item.kind,
                categoryID: item.categoryID, categoryName: nil,
                note: item.note, merchant: item.merchant,
                date: item.date, source: item.isManual ? "shortcut" : "ocr",
                accountID: item.accountID
            )
            saved.append(record)
            if (item.categoryEdited || item.accountEdited), !item.merchant.isEmpty {
                RuleStore.learn(merchant: item.merchant, kind: item.kind, category: record.category,
                                account: item.accountEdited ? record.accountRef : nil, in: context)
            }
        }
        try? context.save()
        if !SessionManager.shared.isDecoy {
            BudgetMonitor.check(in: context)
        }
        return saved
    }

    // MARK: - 选择（iOS 26：requestChoice + 视图；iOS 17 / 18：requestDisambiguation）

    @MainActor
    private func choose<V: View>(_ options: [Option], dialog: String, view: V) async throws -> String {
        if #available(iOS 26.0, *), options.count <= 8 {
            // 用稳定 title 做映射：iOS 27 上 IntentChoiceOption 的 == 不一定能匹配到我们创建时的实例
            var map: [(title: String, key: String, option: IntentChoiceOption)] = []
            for o in options where o.key != Action.cancel.rawValue {
                let title = o.title
                let choice = IntentChoiceOption(title: LocalizedStringResource(stringLiteral: title),
                                                style: o.destructive ? .destructive : .default)
                map.append((title, o.key, choice))
            }
            let all = map.map(\.option) + [IntentChoiceOption.cancel]
            let picked = try await requestChoice(between: all, dialog: IntentDialog("\(dialog)"), view: view)
            if let key = map.first(where: { $0.option == picked })?.key { return key }
            // 回退：按标题字符串比对（LocalizedStringResource 的 debug/description 不稳定时仍尽量匹配）
            let pickedTitle = String(describing: picked.title)
            if let key = map.first(where: { String(describing: $0.option.title) == pickedTitle || $0.title == pickedTitle })?.key {
                return key
            }
            throw ReviewCancelled()
        }
        reviewChoice = nil
        let entities = options.enumerated().map { i, o in
            ReviewChoiceEntity(id: "\(i)|\(o.key)", title: o.title, subtitle: o.subtitle, icon: o.icon)
        }
        ReviewChoiceRegistry.current = entities
        let picked = try await $reviewChoice.requestDisambiguation(among: entities, dialog: IntentDialog("\(dialog)"))
        let key = String(picked.id.split(separator: "|", maxSplits: 1).last ?? "")
        if key == Action.cancel.rawValue { throw ReviewCancelled() }
        return key
    }

    /// 用户明确取消（含 requestChoice 的 cancel、系统手势）；其它错误要提示，不能当取消吞掉
    static func isUserCancel(_ error: Error) -> Bool {
        if error is ReviewCancelled { return true }
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let lower = text.lowercased()
        if lower.contains("cancel") || text.contains("取消") { return true }
        return false
    }

}
