import AppIntents
import Foundation
import SwiftData
import SwiftUI
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

    // MARK: 审核流程内部使用的参数（不在参数摘要中显示，每次询问都通过对应参数的 requestValue / requestDisambiguation 发起）

    @Parameter(title: "选项")
    var reviewChoice: ReviewChoiceEntity?

    @Parameter(title: "金额")
    var reviewAmount: Double?

    @Parameter(title: "收支类型")
    var reviewKind: RecordKindAppEnum?

    @Parameter(title: "分类")
    var reviewCategory: CategoryEntity?

    @Parameter(title: "账户")
    var reviewAccount: AccountEntity?

    @Parameter(title: "商户 / 备注")
    var reviewText: String?

    @Parameter(title: "时间")
    var reviewDate: Date?

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
            guard let reviewed = try await runReview(items, steps: &steps, context: context,
                                                     emptyHint: found.isEmpty ? "没有识别到金额" + (rawPreview.isEmpty ? "。" : "（识别到的文字：\(rawPreview)）。") : nil) else {
                return try finish([], cancelled: true, context: context)
            }
            items = reviewed
        }

        return try finish(items, cancelled: false, context: context)
    }

    // MARK: - 保存

    @MainActor
    private func finish(_ items: [ReviewItem], cancelled: Bool, context: ModelContext) throws -> some IntentResult & ProvidesDialog & ShowsSnippetView & ReturnsValue<Double> {
        if cancelled {
            return .result(value: Double(0), dialog: IntentDialog("已取消，未保存任何记录。"),
                           view: ReviewSnippetView(title: "已取消", rows: []))
        }
        let toSave = items.filter(\.willSave)
        let skipped = items.filter { !$0.willSave }
        let skippedRows = skipped.enumerated().map { ReviewFormatter.row($0.element, index: $0.offset + 1, in: context) }

        guard !toSave.isEmpty else {
            let text = skipped.isEmpty
                ? "没有需要保存的记录，未记账。"
                : "截图中的 \(skipped.count) 笔都已记过，未重复记账。"
            return .result(value: Double(0), dialog: IntentDialog("\(text)"),
                           view: ReviewSnippetView(title: "未记账", rows: skippedRows))
        }

        var saved: [LedgerRecord] = []
        for item in toSave {
            let record = try IntentRecorder.save(
                amount: item.amount, kind: item.kind,
                categoryID: item.categoryID, categoryName: nil,
                note: item.note, merchant: item.merchant,
                date: item.date, source: item.isManual ? "shortcut" : "ocr",
                accountID: item.accountID
            )
            saved.append(record)
            // 分类记忆：用户在弹窗里改过分类 / 账户的商户，记住这次的选择
            if (item.categoryEdited || item.accountEdited), !item.merchant.isEmpty {
                RuleStore.learn(merchant: item.merchant, kind: item.kind, category: record.category,
                                account: item.accountEdited ? record.accountRef : nil, in: context)
            }
        }
        try? context.save()
        BudgetMonitor.check(in: context)

        var text: String
        if saved.count == 1 {
            text = "已记账：" + IntentRecorder.summary(of: saved[0])
        } else {
            let total = saved.reduce(0) { $0 + ($1.kind == .income ? 0 : $1.amount) }
            text = "已记 \(saved.count) 笔" + (total > 0 ? "，支出合计 \(Money.format(total))" : "") + "。"
        }
        if !skipped.isEmpty { text += "跳过 \(skipped.count) 笔重复。" }
        // 预算：超支 / 接近上限时提醒（通知由 BudgetMonitor 发送）
        if saved.contains(where: { $0.kind == .expense }), let t = BudgetService.currentStatus(in: context).total, t.budget > 0 {
            text += t.isOver ? "本月预算已超支 \(Money.format(-t.remaining))。" : "本月预算剩余 \(Money.format(t.remaining))。"
        }

        let savedRows = toSave.enumerated().map { ReviewFormatter.row($0.element, index: $0.offset + 1, in: context) }
        let total = saved.reduce(0) { $0 + $1.amount }
        return .result(value: total, dialog: IntentDialog("\(text)"),
                       view: ReviewSnippetView(title: "已记账", rows: savedRows))
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
            options.append(Option(key: Action.add.rawValue, title: "➕ 添加一笔", subtitle: "识别漏掉的可以手动补上", icon: "plus.circle"))
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
                items[index] = try await editItem(items[index], number: index + 1, steps: &steps, context: context)
            case .add:
                if let item = try await addItem(steps: &steps, context: context) { items.append(item) }
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
        case amount, kind, category, text, account, date, done
    }

    @MainActor
    private func editItem(_ original: ReviewItem, number: Int, steps: inout Int, context: ModelContext) async throws -> ReviewItem {
        var item = original
        while steps < Self.maxSteps {
            steps += 1
            let row = ReviewFormatter.row(item, index: number, in: context)
            let options: [Option] = [
                Option(key: Field.amount.rawValue, title: "金额（\(Money.format(item.amount))）", icon: "yensign.circle"),
                Option(key: Field.kind.rawValue, title: "收支类型（\(item.kind == .income ? "收入" : "支出")）", icon: "arrow.left.arrow.right"),
                Option(key: Field.category.rawValue, title: "分类（\(row.categoryName)）", icon: row.icon),
                Option(key: Field.text.rawValue, title: "商户 / 备注（\(textSummary(item))）", icon: "storefront"),
                Option(key: Field.account.rawValue, title: "账户（\(row.accountName)）", icon: "creditcard"),
                Option(key: Field.date.rawValue, title: "时间（\(DateText.monthDayTime.string(from: item.date))）", icon: "clock"),
                Option(key: Field.done.rawValue, title: "✅ 完成", icon: "checkmark"),
            ]
            let key = try await choose(options, dialog: "修改第 \(number) 笔：选择要改的项目",
                                       view: ReviewSnippetView(title: "第 \(number) 笔", rows: [row]))
            guard let field = Field(rawValue: key), field != .done else { break }
            steps += 1
            switch field {
            case .amount:
                let v = try await $reviewAmount.requestValue(IntentDialog("新的金额是多少？（当前 \(Money.format(item.amount))）"))
                if v > 0 && v < 100_000_000 { item.amount = (v * 100).rounded() / 100 }
            case .kind:
                let k = try await $reviewKind.requestDisambiguation(among: [.expense, .income],
                                                                    dialog: IntentDialog("收支类型（当前\(item.kind == .income ? "收入" : "支出")）"))
                if k.kind != item.kind {
                    item.kind = k.kind
                    // 分类跟着换成新类型下的默认分类
                    let resolved = IntentRecorder.resolve(kind: item.kind, merchant: item.merchant, note: item.note,
                                                          categoryID: nil, categoryName: nil, accountID: item.accountID, accountHint: nil)
                    item.categoryID = resolved.category?.id
                }
            case .category:
                let list = DataStore.categories(kind: item.kind, in: context).map { CategoryEntity($0) }
                guard !list.isEmpty else { continue }
                let c = try await $reviewCategory.requestDisambiguation(among: list, dialog: IntentDialog("选择分类（当前 \(row.categoryName)）"))
                item.categoryID = c.id
                item.kind = RecordKind(rawValue: c.kindRaw) ?? item.kind
                item.categoryEdited = true
            case .text:
                let t = try await $reviewText.requestValue(IntentDialog("输入「商户 / 备注」，例如「星巴克 / 下午茶」；只填商户可不写斜杠，输入「-」清空。当前：\(textSummary(item))"))
                applyText(t, to: &item)
            case .account:
                let list = DataStore.accounts(in: context).map { AccountEntity($0) }
                guard !list.isEmpty else { continue }
                let a = try await $reviewAccount.requestDisambiguation(among: list, dialog: IntentDialog("选择账户（当前 \(row.accountName)）"))
                item.accountID = a.id
                item.accountEdited = true
            case .date:
                let d = try await $reviewDate.requestValue(IntentDialog("记账时间（当前 \(DateText.monthDayTime.string(from: item.date))）"))
                item.date = d
                item.dateRecognized = true
            case .done:
                break
            }
            // 改了金额 / 商户 / 时间后重新判断是否重复
            if !item.isManual {
                item.isDuplicate = IntentRecorder.isDuplicate(amount: item.amount, merchant: item.merchant, date: item.date)
                if !item.isDuplicate { item.saveDuplicate = false }
            }
        }
        return item
    }

    private func textSummary(_ item: ReviewItem) -> String {
        let m = item.merchant.isEmpty ? "无商户" : item.merchant
        return item.note.isEmpty ? m : m + " / " + item.note
    }

    private func applyText(_ raw: String, to item: inout ReviewItem) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "-" || t == "－" {
            item.merchant = ""
            item.note = ""
            return
        }
        if let r = t.range(of: "/") ?? t.range(of: "／") {
            item.merchant = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            item.note = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            item.merchant = t
        }
    }

    // MARK: 添加

    @MainActor
    private func addItem(steps: inout Int, context: ModelContext) async throws -> ReviewItem? {
        steps += 1
        let amount = try await $reviewAmount.requestValue(IntentDialog("添加一笔：金额是多少？"))
        guard amount > 0, amount < 100_000_000 else { return nil }
        steps += 1
        let k = try await $reviewKind.requestDisambiguation(among: [.expense, .income], dialog: "支出还是收入？").kind
        var item = ReviewItem(amount: (amount * 100).rounded() / 100, kind: k, categoryID: nil, merchant: "",
                              note: note ?? "", accountID: nil, date: Date(), dateRecognized: true)
        item.isManual = true
        let cats = DataStore.categories(kind: k, in: context).map { CategoryEntity($0) }
        if !cats.isEmpty {
            steps += 1
            let c = try await $reviewCategory.requestDisambiguation(among: cats, dialog: "选择分类")
            item.categoryID = c.id
            item.categoryEdited = true
        }
        steps += 1
        let wantText = try await choose([
            Option(key: "text", title: "填写商户 / 备注", icon: "storefront"),
            Option(key: "skip", title: "跳过", icon: "forward"),
        ], dialog: "商户 / 备注（可选）", view: ReviewSnippetView(title: "新增一笔", rows: [ReviewFormatter.row(item, index: 1, in: context)]))
        if wantText == "text" {
            steps += 1
            let t = try await $reviewText.requestValue(IntentDialog("输入「商户 / 备注」，例如「便利店 / 早餐」"))
            applyText(t, to: &item)
        }
        let category = item.categoryID.flatMap { DataStore.category(id: $0, in: context) }
        let auto = RuleStore.lastAccount(for: category, in: context) ?? RuleStore.defaultAccount(in: context)
        let accounts = DataStore.accounts(in: context)
        if !accounts.isEmpty {
            steps += 1
            var options = [Option(key: "auto", title: "自动（\(auto?.name ?? "不指定")）", icon: "wand.and.stars")]
            options += accounts.map { Option(key: $0.id.uuidString, title: $0.name, subtitle: $0.type.title, icon: $0.iconName) }
            let key = try await choose(options, dialog: "账户（可选）",
                                       view: ReviewSnippetView(title: "新增一笔", rows: [ReviewFormatter.row(item, index: 1, in: context)]))
            if let id = UUID(uuidString: key) {
                item.accountID = id
                item.accountEdited = true
            } else {
                item.accountID = auto?.id
            }
        }
        return item
    }

    // MARK: - 选择（iOS 26：requestChoice + 视图；iOS 17 / 18：requestDisambiguation）

    @MainActor
    private func choose<V: View>(_ options: [Option], dialog: String, view: V) async throws -> String {
        if #available(iOS 26.0, *), options.count <= 8 {
            var map: [(IntentChoiceOption, String)] = []
            for o in options where o.key != Action.cancel.rawValue {
                let choice = IntentChoiceOption(title: LocalizedStringResource(stringLiteral: o.title),
                                                style: o.destructive ? .destructive : .default)
                map.append((choice, o.key))
            }
            let all = map.map(\.0) + [IntentChoiceOption.cancel]
            // 选择「取消」或系统取消手势会抛出错误，快捷指令随即停止，不会保存任何记录
            let picked = try await requestChoice(between: all, dialog: IntentDialog("\(dialog)"), view: view)
            guard let key = map.first(where: { $0.0 == picked })?.1 else { throw ReviewCancelled() }
            return key
        }
        let entities = options.enumerated().map { i, o in
            ReviewChoiceEntity(id: "\(i)|\(o.key)", title: o.title, subtitle: o.subtitle, icon: o.icon)
        }
        ReviewChoiceRegistry.current = entities
        let picked = try await $reviewChoice.requestDisambiguation(among: entities, dialog: IntentDialog("\(dialog)"))
        let key = String(picked.id.split(separator: "|", maxSplits: 1).last ?? "")
        return key
    }
}

