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

    /// 金额 / 商户备注 / 自定义时间 共用；每次询问前清空
    @Parameter(title: "输入内容")
    var reviewInput: String?

    /// 备用输入槽：同一轮里若主槽异常，换一个参数再问
    @Parameter(title: "输入内容（备用）")
    var reviewInputAlt: String?

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
            } catch {
                if Self.isUserCancel(error) {
                    return try finish([], cancelled: true, context: context)
                }
                // 非取消错误：走同一个 finish，避免 opaque return 类型不一致；并提示原因，避免弹窗静默消失
                return try finish(items, cancelled: false, errorMessage: error.localizedDescription, context: context)
            }
        }

        return try finish(items, cancelled: false, context: context)
    }

    // MARK: - 保存

    @MainActor
    private func finish(_ items: [ReviewItem], cancelled: Bool, errorMessage: String? = nil, context: ModelContext) throws -> some IntentResult & ProvidesDialog & ShowsSnippetView & ReturnsValue<Double> {
        if let errorMessage {
            return .result(value: Double(0),
                           dialog: IntentDialog("审核出错，没有保存任何记录。\n\(errorMessage)"),
                           view: ReviewSnippetView(title: "出错了", rows: rowsFor(items, context: context), footnote: errorMessage))
        }
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
            do {
                switch field {
                case .amount:
                    if let v = try await askAmount(current: item.amount, steps: &steps,
                                                   snippet: ReviewSnippetView(title: "第 \(number) 笔", rows: [row])) {
                        item.amount = v
                    }
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
                case .text:
                    let t = try await askText(
                        IntentDialog("输入「商户 / 备注」，例如「星巴克 / 下午茶」；只填商户可不写斜杠，输入「-」清空。当前：\(textSummary(item))")
                    )
                    applyText(t, to: &item)
                case .account:
                    let list = DataStore.accounts(in: context).map { AccountEntity($0) }
                    guard !list.isEmpty else { continue }
                    reviewAccount = nil
                    let a = try await $reviewAccount.requestDisambiguation(among: list, dialog: IntentDialog("选择账户（当前 \(row.accountName)）"))
                    item.accountID = a.id
                    item.accountEdited = true
                case .date:
                    if let d = try await askDate(current: item.date, steps: &steps,
                                                 snippet: ReviewSnippetView(title: "第 \(number) 笔", rows: [row])) {
                        item.date = d
                        item.dateRecognized = true
                    }
                case .done:
                    break
                }
            } catch {
                if Self.isUserCancel(error) { throw error }
                // 输入失败时留在修改菜单，提示原因，不结束整个快捷指令
                let next = (try? await choose(
                    [Option(key: "ok", title: "继续修改", icon: "arrow.clockwise"),
                     Option(key: Action.cancel.rawValue, title: "取消审核", icon: "xmark")],
                    dialog: "刚才这一步没完成：\(error.localizedDescription)",
                    view: ReviewSnippetView(title: "第 \(number) 笔", rows: [row], footnote: error.localizedDescription)
                )) ?? "ok"
                if next == Action.cancel.rawValue { throw ReviewCancelled() }
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
        let rawAmount = try await askText(IntentDialog("添加一笔：输入金额，例如 35 或 35.50"))
        guard let amount = Self.parseAmount(rawAmount) else { throw LedgerIntentError.invalidAmount }
        steps += 1
        reviewKind = nil
        let k = try await $reviewKind.requestDisambiguation(among: [.expense, .income], dialog: "支出还是收入？").kind
        var item = ReviewItem(amount: amount, kind: k, categoryID: nil, merchant: "",
                              note: note ?? "", accountID: nil, date: Date(), dateRecognized: true)
        item.isManual = true
        let cats = DataStore.categories(kind: k, in: context).map { CategoryEntity($0) }
        if !cats.isEmpty {
            steps += 1
            reviewCategory = nil
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
            let t = try await askText(IntentDialog("输入「商户 / 备注」，例如「便利店 / 早餐」"))
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

    // MARK: - 自由输入（String）与解析

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

    /// 弹出文本框。先清空参数；失败时换备用参数再试一次。
    @MainActor
    private func askText(_ dialog: IntentDialog) async throws -> String {
        reviewInput = nil
        do {
            return try await $reviewInput.requestValue(dialog)
        } catch {
            if Self.isUserCancel(error) { throw error }
            reviewInputAlt = nil
            return try await $reviewInputAlt.requestValue(dialog)
        }
    }

    /// 金额：先给快捷调整按钮（仍走 requestChoice），需要任意数字时再弹文本框并自行解析。
    /// 避免在 requestChoice 之后对 Double 调 requestValue（iOS 26/27 真机会直接结束弹窗）。
    @MainActor
    private func askAmount<V: View>(current: Double?, steps: inout Int, snippet: V) async throws -> Double? {
        let cur = current ?? 0
        var options: [Option] = []
        if let current {
            options.append(Option(key: "keep", title: "保持 \(Money.format(current))", icon: "equal.circle"))
            for delta in [1.0, -1.0, 10.0] {
                let v = max(0.01, ((current + delta) * 100).rounded() / 100)
                let sign = delta > 0 ? "+\(Int(delta))" : "\(Int(delta))"
                options.append(Option(key: "set:\(v)", title: "改为 \(Money.format(v))（\(sign)）",
                                      icon: delta > 0 ? "plus.circle" : "minus.circle"))
            }
        }
        options.append(Option(key: "type", title: "⌨️ 输入金额…", subtitle: "支持 35、35.5、¥35", icon: "keyboard"))
        if current != nil {
            options.append(Option(key: "back", title: "返回", icon: "chevron.backward"))
        }
        let key = try await choose(options,
                                   dialog: current == nil ? "金额是多少？" : "怎么改金额？（当前 \(Money.format(cur))）",
                                   view: snippet)
        if key == "back" || key == "keep" { return current }
        if key.hasPrefix("set:"), let v = Double(key.dropFirst(4)), v > 0 { return v }
        if key == "type" {
            steps += 1
            let raw = try await askText(IntentDialog(current == nil
                ? "输入金额，例如 35 或 35.50"
                : "输入新金额（当前 \(Money.format(cur))），例如 35、35.5、¥18.00"))
            guard let v = Self.parseAmount(raw) else {
                throw LedgerIntentError.invalidAmount
            }
            return v
        }
        return current
    }

    @MainActor
    private func askDate<V: View>(current: Date, steps: inout Int, snippet: V) async throws -> Date? {
        let options = [
            Option(key: "keep", title: "保持 \(DateText.monthDayTime.string(from: current))", icon: "equal.circle"),
            Option(key: "now", title: "改为现在", icon: "clock"),
            Option(key: "type", title: "⌨️ 输入时间…", subtitle: "例如 10月19日 12:30 或 12:30", icon: "keyboard"),
            Option(key: "back", title: "返回", icon: "chevron.backward"),
        ]
        let key = try await choose(options, dialog: "记账时间", view: snippet)
        switch key {
        case "back", "keep": return nil
        case "now": return Date()
        case "type":
            steps += 1
            let raw = try await askText(IntentDialog("输入时间，例如「10月19日 12:30」「今天 8:00」「12:30」（当前 \(DateText.monthDayTime.string(from: current))）"))
            guard let d = Self.parseDate(raw, reference: current) else {
                throw ReviewInputError("无法识别时间「\(raw)」。请用「10月19日 12:30」或「12:30」。")
            }
            return d
        default:
            return nil
        }
    }

    static func parseAmount(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        for token in ["¥", "￥", "元", "人民币", "RMB", "CNY", ","] {
            s = s.replacingOccurrences(of: token, with: "")
        }
        s = s.trimmingCharacters(in: .whitespaces)
        // 全角数字 → 半角
        s = String(s.map { ch -> Character in
            guard let v = ch.unicodeScalars.first?.value, (0xFF10...0xFF19).contains(v) else { return ch }
            return Character(UnicodeScalar(v - 0xFF10 + 0x30)!)
        })
        let negative = s.hasPrefix("-") || s.hasPrefix("－")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-－+＋"))
        guard let v = Double(s), v > 0, v < 100_000_000 else { return nil }
        let rounded = (v * 100).rounded() / 100
        return negative ? nil : rounded   // 记账金额用正数，收支类型另选
    }

    static func parseDate(_ raw: String, reference: Date) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let cal = DateText.calendar
        let lower = s.replacingOccurrences(of: "：", with: ":")
        if ["现在", "此刻", "当前"].contains(lower) { return Date() }
        // 今天 / 昨天 + 时间
        let timePart: String
        var dayOffset = 0
        if lower.hasPrefix("今天") {
            timePart = String(lower.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        } else if lower.hasPrefix("昨天") {
            dayOffset = -1
            timePart = String(lower.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        } else {
            timePart = lower
        }
        let formats = ["M月d日 HH:mm", "M月d日 H:mm", "MM-dd HH:mm", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm", "HH:mm", "H:mm"]
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.calendar = cal
        f.timeZone = .current
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: timePart) {
                var comp = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
                let ref = cal.dateComponents([.year, .month, .day], from: reference)
                if fmt.hasPrefix("HH") || fmt.hasPrefix("H:") {
                    comp.year = ref.year; comp.month = ref.month; comp.day = ref.day
                } else if !fmt.contains("yyyy") && (fmt.contains("月") || fmt.contains("MM")) {
                    comp.year = ref.year
                }
                if let base = cal.date(from: comp) {
                    return cal.date(byAdding: .day, value: dayOffset, to: base) ?? base
                }
            }
        }
        // 今天/昨天且没写时间 → 保留原来的时分
        if dayOffset != 0 || lower.hasPrefix("今天") {
            var comp = cal.dateComponents([.year, .month, .day, .hour, .minute], from: reference)
            let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: reference)) ?? reference
            let dc = cal.dateComponents([.year, .month, .day], from: day)
            comp.year = dc.year; comp.month = dc.month; comp.day = dc.day
            return cal.date(from: comp)
        }
        return nil
    }
}

