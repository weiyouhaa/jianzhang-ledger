import Foundation
import SwiftData

/// 导入预览中的一行
struct ImportItem: Identifiable, Equatable {
    enum Status: Equatable {
        case new
        /// 订单号已导入过：不能再导入
        case imported
        /// 时间相近、金额相同：可能已手动 / 识图记过
        case likelyDuplicate(String)
        case skipped(String)

        var isSkipped: Bool { if case .skipped = self { return true } else { return false } }
    }

    let entry: BillEntry
    var id: Int { entry.rowIndex }
    var status: Status
    var include: Bool
    var kind: RecordKind
    var categoryID: UUID?
    var accountID: UUID?
    var toAccountID: UUID?
    /// 分类来源说明（规则 / 平台分类 / 关键词）
    var categorySource: String
    /// 用户在预览里改过分类或账户
    var edited = false
    /// 疑似重复时匹配到的已有记录
    var matchedRecordID: UUID?
    /// 日期不晚于账本最新记录：导入后会调整初始余额，当前余额不变（2.0 (13)）
    var preservesBalance = false

    /// 能否勾选导入
    var canImport: Bool {
        if status == .imported { return false }
        if kind == .transfer { return accountID != nil && toAccountID != nil && accountID != toAccountID }
        return true
    }
}

struct ImportOptions: Equatable {
    var refundsAsIncome = true
    var neutralAsTransfer = true
    var includeLikelyDuplicates = false
}

/// 支付宝 / 微信账单 → 记录（规则分类、账户匹配、去重、批次撤销）
@MainActor
enum BillImporter {
    static func prepare(_ result: BillParseResult, options: ImportOptions, in context: ModelContext) -> [ImportItem] {
        let rules = RuleStore.allRules(in: context)
        let existingIDs: Set<String> = {
            let d = FetchDescriptor<LedgerRecord>(predicate: #Predicate<LedgerRecord> { $0.externalID != "" })
            return Set(((try? context.fetch(d)) ?? []).map(\.externalID))
        }()
        // 用于「时间相近、金额相同」判断的已有记录
        let dates = result.entries.map(\.date)
        var nearby: [LedgerRecord] = []
        if let lo = dates.min(), let hi = dates.max() {
            nearby = DataStore.records(from: lo.addingTimeInterval(-600), to: hi.addingTimeInterval(600), in: context)
                .filter { $0.externalID.isEmpty }
        }
        let latestExistingDate: Date? = {
            let all = (try? context.fetch(FetchDescriptor<LedgerRecord>())) ?? []
            return all.map(\.date).max()
        }()
        var seen = Set<String>()
        var items: [ImportItem] = []

        for e in result.entries {
            var status: ImportItem.Status = .new
            var kind: RecordKind
            switch e.kind {
            case .expense: kind = .expense
            case .income: kind = .income
            case .transfer: kind = .transfer
            case .skip:
                kind = e.naturalKind == .income ? .income : (e.naturalKind == .transfer ? .transfer : .expense)
                status = .skipped(e.skipReason ?? "跳过")
            }
            if e.kind == .income && e.isRefund && !options.refundsAsIncome {
                status = .skipped("退款（已设置不记为收入）")
            }

            let from = DataStore.account(matching: e.accountHint, in: context)
            var to: LedgerAccount?
            var categoryID: UUID?
            var categorySource = ""
            var accountID = from?.id

            if kind == .transfer {
                to = DataStore.account(matching: e.toAccountHint, in: context)
                if status == .new {
                    if !options.neutralAsTransfer {
                        status = .skipped(e.skipReason ?? "不计收支")
                    } else if from == nil || to == nil {
                        status = .skipped("不计收支：没有匹配到\(from == nil ? "转出" : "转入")账户")
                    } else if from?.id == to?.id {
                        status = .skipped("同一账户内的资金变动（如余额宝收益 / 零钱通）")
                    }
                }
            } else {
                if let hit = RuleStore.match(merchant: e.merchant, text: e.product, kind: kind, in: context,
                                             rules: rules, countHit: false), let c = hit.category, c.kind == kind {
                    categoryID = c.id
                    categorySource = "规则：" + (hit.rule.displayName.isEmpty ? hit.rule.keyword : hit.rule.displayName)
                    if accountID == nil { accountID = hit.account?.id }
                } else {
                    let c = DataStore.category(named: e.suggestedCategoryName, kind: kind, in: context)
                    categoryID = c?.id
                    if e.platformCategory != nil { categorySource = "平台分类：" + e.typeText }
                    else if e.keywordCategory != nil { categorySource = "关键词" }
                }
            }

            // 去重
            if !status.isSkipped {
                let oid = e.orderID
                if !oid.isEmpty && (existingIDs.contains(oid) || seen.contains(oid)) {
                    status = .imported
                }
            }
            if !e.orderID.isEmpty { seen.insert(e.orderID) }

            var item = ImportItem(entry: e, status: status, include: false, kind: kind, categoryID: categoryID,
                                  accountID: accountID, toAccountID: to?.id, categorySource: categorySource)
            item.preservesBalance = ImportBalanceMath.isHistorical(date: e.date, latestExisting: latestExistingDate)
            switch status {
            case .new: item.include = item.canImport
            case .likelyDuplicate: item.include = options.includeLikelyDuplicates && item.canImport
            default: item.include = false
            }
            items.append(item)
        }
        markLikelyDuplicates(&items, nearby: nearby, options: options)
        return items
    }

    /// 与已有记录（手动 / 识图 / 快捷指令记的，没有订单号）比对：同一匹配器（DedupeEngine），10 分钟窗口，
    /// 账户 / 商户加减分，转账也比对；一笔已有记录最多对应一行账单
    private static func markLikelyDuplicates(_ items: inout [ImportItem], nearby: [LedgerRecord], options: ImportOptions) {
        let candidates = items.indices.filter { items[$0].status == .new }
        guard !candidates.isEmpty, !nearby.isEmpty else { return }
        let bills = candidates.map { i -> DedupeRecord in
            let it = items[i]
            return DedupeRecord(id: "row\(it.id)", kind: it.kind.rawValue, amount: it.entry.amount, date: it.entry.date,
                                merchant: it.kind == .transfer ? "" : it.entry.merchant, note: it.entry.memo,
                                accountID: it.accountID?.uuidString,
                                toAccountID: it.kind == .transfer ? it.toAccountID?.uuidString : nil,
                                source: "bill")
        }
        let existing = nearby.filter { $0.kind != .adjustment }.map(DedupeService.dedupeRecord)
        let byID = Dictionary(nearby.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let matches = DedupeEngine.matchBills(bills, existing: existing, window: .min10)
        for i in candidates {
            guard let m = matches["row\(items[i].id)"], let rec = byID[m.existingID] else { continue }
            items[i].status = .likelyDuplicate("\(m.confidence.title)：已有「\(rec.deleteSummary)」（\(DedupeEngine.sourceTitle(rec.source))）")
            items[i].matchedRecordID = rec.id
            items[i].include = options.includeLikelyDuplicates && items[i].canImport
        }
    }

    /// 写入勾选的记录，返回批次。
    /// 日期不晚于导入前最新记录的交易会写入账本（统计 / 明细可见），但通过调整相关账户的 initialBalance 保持当前余额不变。
    @discardableResult
    static func commit(_ items: [ImportItem], source: BillSource, fileName: String, in context: ModelContext) throws -> ImportBatch? {
        let chosen = items.filter { $0.include && $0.canImport }
        guard !chosen.isEmpty else { return nil }
        let existing = (try? context.fetch(FetchDescriptor<LedgerRecord>())) ?? []
        let latestExistingDate = existing.map(\.date).max()
        let batch = ImportBatch(source: source, fileName: fileName)
        context.insert(batch)
        let batchID = batch.id.uuidString
        var expense = 0.0, income = 0.0
        var effectSum: [String: Double] = [:]
        var preservedCount = 0
        for item in chosen {
            let e = item.entry
            let category = item.kind.countsInStats ? item.categoryID.flatMap { DataStore.category(id: $0, in: context) } : nil
            let from = item.accountID.flatMap { DataStore.account(id: $0, in: context) }
            let to = item.kind == .transfer ? item.toAccountID.flatMap { DataStore.account(id: $0, in: context) } : nil
            let amount = (e.amount * 100).rounded() / 100
            let record = LedgerRecord(amount: amount, kind: item.kind, category: category,
                                      note: e.memo, merchant: item.kind == .transfer ? "" : e.merchant,
                                      account: from?.name ?? "", date: e.date, source: source.rawValue)
            if item.kind == .transfer && record.note.isEmpty { record.note = e.merchant }
            record.accountRef = from
            record.toAccount = to
            record.externalID = e.orderID
            record.importBatchID = batchID
            context.insert(record)
            if ImportBalanceMath.isHistorical(date: e.date, latestExisting: latestExistingDate) {
                preservedCount += 1
                ImportBalanceMath.accumulateEffects(into: &effectSum, kind: item.kind, amount: amount, fee: record.fee,
                                                    fromAccountID: from?.id.uuidString, toAccountID: to?.id.uuidString)
            }
            if item.edited && item.kind.countsInStats && !e.merchant.isEmpty {
                RuleStore.learn(merchant: e.merchant, kind: item.kind, category: category, account: from, in: context)
            }
            if item.kind == .expense { expense += record.amount }
            if item.kind == .income { income += record.amount }
        }
        let adjustments = ImportBalanceMath.initialBalanceAdjustments(fromEffects: effectSum)
        for (idStr, delta) in adjustments {
            guard let id = UUID(uuidString: idStr), let account = DataStore.account(id: id, in: context) else { continue }
            account.initialBalance = ((account.initialBalance + delta) * 100).rounded() / 100
        }
        batch.recordCount = chosen.count
        batch.expenseTotal = expense
        batch.incomeTotal = income
        batch.firstDate = chosen.map(\.entry.date).min()
        batch.lastDate = chosen.map(\.entry.date).max()
        batch.balanceOffsets = adjustments
        batch.balancePreservedCount = preservedCount
        try context.save()
        let newer = chosen.count - preservedCount
        RunLog.shared.log(.info, "import",
                          "写入 \(chosen.count) 笔（历史 \(preservedCount) 笔保持余额，较新 \(newer) 笔计入余额；调整 \(adjustments.count) 个账户初始余额）",
                          memory: false)
        BudgetMonitor.check(in: context)
        return batch
    }

    static func records(of batch: ImportBatch, in context: ModelContext) -> [LedgerRecord] {
        let target = batch.id.uuidString
        return (try? context.fetch(FetchDescriptor<LedgerRecord>(predicate: #Predicate<LedgerRecord> { $0.importBatchID == target }))) ?? []
    }

    /// 撤销整批导入：删除记录，并还原为保持余额而调整过的初始余额。返回删除的记录数。
    @discardableResult
    static func undo(_ batch: ImportBatch, in context: ModelContext) -> Int {
        let list = records(of: batch, in: context)
        let offsets = batch.balanceOffsets
        for (idStr, delta) in offsets {
            guard let id = UUID(uuidString: idStr), let account = DataStore.account(id: id, in: context) else { continue }
            account.initialBalance = ((account.initialBalance - delta) * 100).rounded() / 100
        }
        list.forEach { context.delete($0) }
        let n = list.count
        let preserved = batch.balancePreservedCount
        context.delete(batch)
        try? context.save()
        RunLog.shared.log(.info, "import",
                          "撤销导入 \(n) 笔（还原 \(offsets.count) 个账户初始余额；其中历史 \(preserved) 笔曾保持余额）",
                          memory: false)
        return n
    }
}
