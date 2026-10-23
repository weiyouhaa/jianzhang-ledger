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
    /// iOS 26+：默认后台运行；「在 App 里改」时用 continueInForeground 由系统把简账切到前台
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
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
        // 运行日志：每一步留痕（不记录截图文字、金额、商户）；进程被系统强制结束时，下次启动可报告最后步骤
        let log = RunLog.shared
        log.bootstrap(reason: "快捷指令")
        log.refreshAppState()
        log.markDirty(step: "intent-start")
        let started = Date()
        defer {
            // App 仍在前台时保持「运行中」标记，由进入后台时清除
            if UIApplication.shared.applicationState == .background {
                log.markClean(step: "intent-end")
            } else {
                log.markDirty(step: "foreground")
            }
        }
        log.log(.info, "intent-start", "识图记账开始：审核方式=\(reviewMode == .review || confirmBeforeSaving ? "弹窗审核" : "直接保存")"
                + "，指定分类=\(category == nil ? "否" : "是")，指定类型=\(kind == nil ? "否" : "是")"
                + "，指定账户=\(account == nil ? "否" : "是")，备注=\(note?.isEmpty == false ? "有" : "无")"
                + "，Apple 智能（快捷指令）=\(OCREngineSetting.preferAppleIntelligence && OCREngineSetting.useInShortcuts ? "开" : "关")")
        if #available(iOS 26.0, *) {
            log.log(.info, "intent-mode", "运行方式：\(String(describing: systemContext.currentMode).prefix(40))")
        }

        let data = image.data
        log.log(.info, "intent-input", "输入文件：\(image.type?.identifier ?? "未知类型")，\(data.count / 1024) KB")
        guard !data.isEmpty else {
            log.log(.error, "intent-input", "输入为空")
            throw LedgerIntentError.unreadableImage
        }

        let parsedList: [ParsedReceipt]
        OCRRunInfo.engineLine = nil
        do {
            // 快捷指令可能在后台运行：端侧模型在后台会被限流，失败时自动回退规则并在结果里注明
            log.log(.info, "vocabulary", "读取分类 / 账户名")
            let vocabulary = IntentRecorder.ocrVocabulary()
            log.log(.info, "vocabulary", "分类 \(vocabulary.expenseCategories.count + vocabulary.incomeCategories.count) 个，账户 \(vocabulary.accounts.count) 个")
            let recognition = try await ReceiptRecognizer.recognizeDetailed(imageData: data,
                                                                            vocabulary: vocabulary,
                                                                            context: .shortcut)
            parsedList = recognition.receipts
            OCRRunInfo.engineLine = recognition.engineLine
        } catch {
            let ns = error as NSError
            log.log(.error, "recognize-failed", "识别失败：\(ns.domain) \(ns.code)")
            throw LedgerIntentError.unreadableImage
        }

        let found = parsedList.filter { ($0.amount ?? 0) > 0 }
        let context = DataStore.shared.mainContext
        let review = reviewMode == .review || confirmBeforeSaving

        log.log(.info, "parsed", "识别结果 \(parsedList.count) 段，含金额 \(found.count) 笔，"
                + "还款 \(found.filter(\.isCardRepayment).count) 笔，收入 \(found.filter(\.isIncome).count) 笔，带时间 \(found.filter { $0.date != nil }.count) 笔")
        guard !found.isEmpty || review else {
            log.log(.warn, "no-amount", "没有识别到金额")
            let raw = parsedList.first?.rawText ?? ""
            let preview = String(raw.replacingOccurrences(of: "\n", with: " ").prefix(60))
            throw LedgerIntentError.noAmount(preview.isEmpty ? "（无）" : preview)
        }

        log.log(.info, "resolve", "匹配分类 / 账户（\(found.count) 笔）")
        var items: [ReviewItem] = found.enumerated().map { index, p in
            let k: RecordKind
            if let kind {
                k = kind.kind
            } else if let category {
                k = RecordKind(rawValue: category.kindRaw) ?? .expense
            } else {
                k = p.isIncome ? .income : .expense
            }
            let merchant = p.isCardRepayment ? "" : (p.merchant ?? "")
            let modelAccount = p.isCardRepayment || account != nil ? nil
                : IntentRecorder.resolveAccount(hint: p.accountHint, modelName: p.accountName, role: .single, label: "账户")
            let resolved = IntentRecorder.resolve(kind: k, merchant: merchant, note: note ?? "",
                                                  categoryID: category?.id, categoryName: p.categoryName,
                                                  accountID: account?.id ?? modelAccount?.id,
                                                  accountHint: p.accountHint)
            var item = ReviewItem(amount: p.amount ?? 0, kind: k, categoryID: resolved.category?.id,
                                  merchant: merchant, note: note ?? p.discountNote ?? "", accountID: resolved.account?.id,
                                  date: p.date ?? Date(), dateRecognized: p.date != nil)
            item.accountTail = p.isCardRepayment ? nil : p.accountHint?.cardTail
            // 信用卡还款截图：付款账户 → 信用卡 的转账（未指定类型 / 分类时）。
            // 信用卡没匹配上也保持「还款」，在审核里选卡（不再退回成「支出 · 其他」）
            if p.isCardRepayment, kind == nil, category == nil {
                let card = IntentRecorder.repaymentCard(name: p.repaymentCardName, hint: p.repaymentCard)
                let payer = IntentRecorder.repaymentPayer(accountID: account?.id, hint: p.accountHint,
                                                          modelName: p.accountName, excluding: card?.id ?? UUID())
                item.kind = .transfer
                item.categoryID = nil
                item.toAccountID = card?.id
                item.accountID = payer?.id
                item.merchant = ""
                item.note = note ?? ""
                item.payerTail = p.accountHint?.cardTail
                item.cardTail = p.repaymentCard?.cardTail
                RunLog.shared.log(.info, "repayment", "第 \(index + 1) 笔：信用卡还款，付款账户\(payer == nil ? "未定" : "已定")，信用卡\(card == nil ? "未定（需选择）" : "已定")")
            }
            // 钱包充值 / 提现 / 余额宝转入转出：自己账户之间的转账（不计入收支）
            if p.isSelfTransfer, !p.isCardRepayment, kind == nil, category == nil {
                let fromID = account?.id ?? IntentRecorder.resolveAccount(hint: p.transferFrom, modelName: p.transferFromName,
                                                                          role: .single, label: "转出账户")?.id
                let to = IntentRecorder.resolveAccount(hint: p.transferTo, modelName: p.transferToName, role: .single,
                                                       excluding: fromID, label: "转入账户")
                item.kind = .transfer
                item.isSelfTransfer = true
                item.categoryID = nil
                item.accountID = fromID
                item.toAccountID = to?.id == fromID ? nil : to?.id
                item.merchant = ""
                item.note = note ?? p.transferNote ?? ""
                item.accountTail = nil
                item.payerTail = p.transferFrom?.cardTail
                item.cardTail = p.transferTo?.cardTail
                RunLog.shared.log(.info, "self-transfer", "第 \(index + 1) 笔：账户间转账，转出账户\(item.accountID == nil ? "未定" : "已定")，转入账户\(item.toAccountID == nil ? "未定（需选择）" : "已定")")
            }
            // 去重：同金额、同商户、时间相差 2 分钟内的已有记录
            RunLog.shared.log(.info, "dedupe", "第 \(index + 1) 笔：查重")
            item.isDuplicate = item.dateRecognized
                && IntentRecorder.isDuplicate(amount: item.amount, merchant: item.merchant, date: item.date)
            return item
        }

        log.log(.info, "items", "待处理 \(items.count) 笔，重复 \(items.filter(\.isDuplicate).count) 笔，转账 \(items.filter { $0.kind == .transfer }.count) 笔")
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
                log.log(.info, "jump-to-app", "转到 App 继续（\(jump.focusRecordIndex == nil ? "新建" : "编辑")）")
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
                let opened = await continueInApp()
                log.log(opened ? .info : .warn, "continue-in-app", opened ? "已切到前台" : "未能切到前台")
                let what = jump.focusRecordIndex == nil ? "新建页" : "编辑页"
                let msg = opened
                    ? "已保存 \(saved.count) 笔，正在打开简账的\(what)。若没有自动打开，10 分钟内打开简账（解锁后）会自动弹出。"
                    : "已保存 \(saved.count) 笔。没能自动打开简账：请在 10 分钟内手动打开简账，解锁后会自动弹出\(what)。"
                return try finish(jump.items, cancelled: false, alreadySaved: saved, jumpMessage: msg, context: context)
            } catch {
                if Self.isUserCancel(error) {
                    log.log(.info, "review-cancel", "用户取消")
                    return try finish([], cancelled: true, context: context)
                }
                let ns = error as NSError
                log.log(.error, "review-error", "审核出错：\(ns.domain) \(ns.code)")
                return try finish(items, cancelled: false, errorMessage: error.localizedDescription, context: context)
            }
        }

        let result = try finish(items, cancelled: false, context: context)
        log.log(.info, "intent-end", "识图记账结束，总用时 \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return result
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
            RunLog.shared.log(.info, "review-build", "生成审核列表（\(items.count) 笔）")
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
                if items.contains(where: { !$0.isComplete }) {
                    dialog += "\n还款 / 转账还没选好账户：点「修改」→「账户」选择。"
                }
                if #unavailable(iOS 26.0) {
                    // iOS 17 / 18 的选择列表无法附带视图，把明细写进提示文字
                    for r in rows { dialog += "\n\(r.index). " + ReviewFormatter.line(r) }
                }
            }
            hint = nil
            RunLog.shared.log(.info, "review-step", "审核第 \(steps) 步：\(items.count) 笔，\(options.count) 个选项")
            let snippet = ReviewSnippetView(title: items.isEmpty ? "识图记账" : "识别结果", rows: rows)
            let key = try await choose(options, dialog: dialog, view: snippet)
            RunLog.shared.log(.info, "review-choice", "选择：\(key)")

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
                Option(key: Field.kind.rawValue, title: "收支类型（\(kindTitle(item, in: context))）", icon: "arrow.left.arrow.right"),
                Option(key: Field.category.rawValue, title: "分类（\(row.categoryName)）", icon: row.icon),
                Option(key: Field.account.rawValue, title: item.kind == .transfer ? "账户（\(row.accountName)）" : "账户（\(row.accountName)）",
                       subtitle: item.kind == .transfer ? "付款账户 → 收款 / 信用卡" : "", icon: "creditcard"),
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
                let pickedKind = try await choose([
                    Option(key: "expense", title: "支出", icon: "arrow.up.circle"),
                    Option(key: "income", title: "收入", icon: "arrow.down.circle"),
                    Option(key: "repay", title: "💳 信用卡还款", subtitle: "选择付款账户和还款信用卡", icon: LedgerRecord.repaymentIcon),
                    Option(key: "transfer", title: "转账", subtitle: "自己的账户之间", icon: "arrow.left.arrow.right"),
                    Option(key: "back", title: "返回", icon: "chevron.backward"),
                ], dialog: "收支类型（当前 \(kindTitle(item, in: context))）", view: ReviewSnippetView(title: "第 \(number) 笔", rows: [row]))
                RunLog.shared.log(.info, "review-kind", "选择类型：\(pickedKind)")
                switch pickedKind {
                case "expense", "income":
                    let newKind: RecordKind = pickedKind == "income" ? .income : .expense
                    item.isSelfTransfer = false
                    if newKind != item.kind {
                        let wasTransfer = item.kind == .transfer
                        item.kind = newKind
                        item.toAccountID = nil
                        if wasTransfer, item.accountID.flatMap({ DataStore.account(id: $0, in: context) })?.type.isLiability == true {
                            item.accountID = nil
                        }
                        let resolved = IntentRecorder.resolve(kind: item.kind, merchant: item.merchant, note: item.note,
                                                              categoryID: nil, categoryName: nil, accountID: item.accountID, accountHint: nil)
                        item.categoryID = resolved.category?.id
                        if item.accountID == nil { item.accountID = resolved.account?.id }
                    }
                case "repay", "transfer":
                    if try await chooseTransferAccounts(&item, repayment: pickedKind == "repay", number: number, steps: &steps, context: context) {
                        item.categoryEdited = true
                    }
                default:
                    break
                }
            case .category:
                let cats = DataStore.categories(kind: item.kind == .transfer ? .expense : item.kind, in: context)
                var entries: [Option] = []
                if item.kind != .income {
                    entries.append(Option(key: "repay", title: "💳 信用卡还款", subtitle: "付款账户 → 信用卡，不计入支出", icon: LedgerRecord.repaymentIcon))
                }
                entries += cats.map { Option(key: $0.id.uuidString, title: $0.name, icon: $0.icon) }
                RunLog.shared.log(.info, "review-category", "选择分类（\(cats.count) 个）")
                guard let key = try await pickPaged(entries, dialog: "选择分类（当前 \(row.categoryName)）",
                                                    view: ReviewSnippetView(title: "第 \(number) 笔", rows: [row]), steps: &steps) else { continue }
                if key == "repay" {
                    _ = try await chooseTransferAccounts(&item, repayment: true, number: number, steps: &steps, context: context)
                } else if let id = UUID(uuidString: key), let c = DataStore.category(id: id, in: context) {
                    if item.kind == .transfer { item.toAccountID = nil }
                    item.isSelfTransfer = false
                    item.categoryID = c.id
                    item.kind = c.kind
                    item.categoryEdited = true
                }
            case .account where item.kind == .transfer:
                let isRepay = !item.isSelfTransfer && (item.toAccountID.flatMap { DataStore.account(id: $0, in: context) }?.type.isLiability ?? true)
                _ = try await chooseTransferAccounts(&item, repayment: isRepay, number: number, steps: &steps, context: context)
            case .account:
                let list = DataStore.accounts(in: context).map { AccountEntity($0) }
                guard !list.isEmpty else { continue }
                reviewAccount = nil
                RunLog.shared.log(.info, "review-account", "选择账户（\(list.count) 个）")
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

    private func kindTitle(_ item: ReviewItem, in context: ModelContext) -> String {
        switch item.kind {
        case .income: return "收入"
        case .transfer:
            if item.isSelfTransfer { return "转账" }
            let to = item.toAccountID.flatMap { DataStore.account(id: $0, in: context) }
            return to == nil || to?.type.isLiability == true ? "信用卡还款" : "转账"
        default: return "支出"
        }
    }

    /// 还款 / 转账：用按钮依次选付款账户与收款账户（还款时只列负债账户），不需要输入文字。返回是否已修改。
    @MainActor
    private func chooseTransferAccounts(_ item: inout ReviewItem, repayment: Bool, number: Int, steps: inout Int,
                                        context: ModelContext) async throws -> Bool {
        let all = DataStore.accounts(in: context)
        let payers = repayment ? all.filter { !$0.type.isLiability } : all
        func options(_ list: [LedgerAccount], current: UUID?) -> [Option] {
            list.map { a in
                Option(key: a.id.uuidString, title: (a.id == current ? "✓ " : "") + a.name, subtitle: a.type.title, icon: a.iconName)
            }
        }
        let snippet = ReviewSnippetView(title: "第 \(number) 笔", rows: [ReviewFormatter.row(item, index: number, in: context)])
        RunLog.shared.log(.info, "review-transfer", "\(repayment ? "还款" : "转账")：选择付款账户（\(payers.count) 个）")
        guard let fromKey = try await pickPaged(options(payers, current: item.accountID),
                                                dialog: repayment ? "付款账户（从哪个账户还款）" : "转出账户",
                                                view: snippet, steps: &steps),
              let fromID = UUID(uuidString: fromKey) else { return false }
        let targets = (repayment ? all.filter(\.type.isLiability) : all).filter { $0.id != fromID }
        guard !targets.isEmpty else { return false }
        RunLog.shared.log(.info, "review-transfer", "选择\(repayment ? "还款信用卡" : "转入账户")（\(targets.count) 个）")
        guard let toKey = try await pickPaged(options(targets, current: item.toAccountID),
                                              dialog: repayment ? "还款信用卡（还哪张卡）" : "转入账户",
                                              view: snippet, steps: &steps),
              let toID = UUID(uuidString: toKey) else { return false }
        item.kind = .transfer
        item.categoryID = nil
        item.accountID = fromID
        item.toAccountID = toID
        item.merchant = ""
        item.accountEdited = true
        item.isSelfTransfer = !repayment
        return true
    }

    /// 按钮列表分页：每页最多 6 项 + 「更多」+「返回」（加系统的取消不超过 9 个按钮）。返回选中的 key，「返回」为 nil
    @MainActor
    private func pickPaged<V: View>(_ entries: [Option], dialog: String, view: V, steps: inout Int) async throws -> String? {
        let pageSize = 6
        var page = 0
        let pages = max(1, (entries.count + pageSize - 1) / pageSize)
        while steps < Self.maxSteps {
            steps += 1
            let start = page * pageSize
            let slice = Array(entries[start..<min(entries.count, start + pageSize)])
            var options = slice
            if pages > 1 {
                options.append(Option(key: "__more", title: "更多…（\(page + 1)/\(pages)）", icon: "ellipsis.circle"))
            }
            options.append(Option(key: "__back", title: "返回", icon: "chevron.backward"))
            let key = try await choose(options, dialog: dialog, view: view)
            switch key {
            case "__more": page = (page + 1) % pages
            case "__back": return nil
            default: return key
            }
        }
        return nil
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


    /// 用系统认可的方式把 App 切到前台（iOS 26：continueInForeground；iOS 17–25：requestToContinueInForeground）。
    /// 返回是否成功切到前台。失败时待编辑标记仍保留 10 分钟，下次打开 App 解锁后消费。
    @MainActor
    private func continueInApp() async -> Bool {
        if #available(iOS 26.0, *) {
            guard systemContext.currentMode.canContinueInForeground else { return false }
            do {
                try await continueInForeground(nil, alwaysConfirm: false)
                return true
            } catch {
                return false
            }
        } else {
            do {
                try await requestToContinueInForeground(IntentDialog("打开简账继续编辑"))
                return true
            } catch {
                return false
            }
        }
    }

    @MainActor
    @discardableResult
    private func persist(_ items: [ReviewItem], context: ModelContext) throws -> [LedgerRecord] {
        let t0 = Date()
        RunLog.shared.log(.info, "save-start", "保存 \(items.filter(\.willSave).count) 笔")
        var saved: [LedgerRecord] = []
        for item in items where item.willSave {
            if item.kind == .transfer {
                guard let to = item.toAccountID, let from = item.accountID else {
                    RunLog.shared.log(.warn, "save-skip", "还款 / 转账缺少账户，跳过")
                    continue
                }
                saved.append(try IntentRecorder.saveRepayment(amount: item.amount, fromID: from, toID: to, note: item.note,
                                                              date: item.date, source: item.isManual ? "shortcut" : "ocr"))
                // 记住尾号 → 账户（用户确认保存即视为正确）
                CardTailMemory.learn(tail: item.payerTail, accountID: from)
                CardTailMemory.learn(tail: item.cardTail, accountID: to)
                continue
            }
            CardTailMemory.learn(tail: item.accountTail, accountID: item.accountID)
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
        ChangeLogger.with(.shortcut) {
            do { try context.save() } catch {
                let ns = error as NSError
                RunLog.shared.log(.error, "save-failed", "写入数据库失败：\(ns.domain) \(ns.code)")
            }
        }
        RunLog.shared.log(.info, "save-done", "已保存 \(saved.count) 笔，用时 \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        if !SessionManager.shared.isDecoy {
            BudgetMonitor.check(in: context)
        }
        return saved
    }

    // MARK: - 选择（iOS 26：requestChoice + 视图；iOS 17 / 18：requestDisambiguation）

    @MainActor
    private func choose<V: View>(_ options: [Option], dialog: String, view: V) async throws -> String {
        RunLog.shared.log(.info, "review-ask", "弹出选择（\(options.count) 项）")
        defer { RunLog.shared.log(.info, "review-answer", "选择已返回") }
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

/// iOS 17–25：允许在执行中请求切到前台（iOS 26 起由 supportedModes 取代）
@available(iOSApplicationExtension, unavailable)
extension RecognizeReceiptIntent: ForegroundContinuableIntent {}
