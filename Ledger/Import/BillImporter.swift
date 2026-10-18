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
                } else if kind != .transfer, nearby.contains(where: {
                    $0.kind == kind && abs($0.amount - e.amount) < 0.005 && abs($0.date.timeIntervalSince(e.date)) <= 180
                }) {
                    status = .likelyDuplicate("已有一笔时间相近、金额相同的记录")
                }
            }
            if !e.orderID.isEmpty { seen.insert(e.orderID) }

            var item = ImportItem(entry: e, status: status, include: false, kind: kind, categoryID: categoryID,
                                  accountID: accountID, toAccountID: to?.id, categorySource: categorySource)
            switch status {
            case .new: item.include = item.canImport
            case .likelyDuplicate: item.include = options.includeLikelyDuplicates && item.canImport
            default: item.include = false
            }
            items.append(item)
        }
        return items
    }

    /// 写入勾选的记录，返回批次
    @discardableResult
    static func commit(_ items: [ImportItem], source: BillSource, fileName: String, in context: ModelContext) throws -> ImportBatch? {
        let chosen = items.filter { $0.include && $0.canImport }
        guard !chosen.isEmpty else { return nil }
        let batch = ImportBatch(source: source, fileName: fileName)
        context.insert(batch)
        let batchID = batch.id.uuidString
        var expense = 0.0, income = 0.0
        for item in chosen {
            let e = item.entry
            let category = item.kind.countsInStats ? item.categoryID.flatMap { DataStore.category(id: $0, in: context) } : nil
            let from = item.accountID.flatMap { DataStore.account(id: $0, in: context) }
            let to = item.kind == .transfer ? item.toAccountID.flatMap { DataStore.account(id: $0, in: context) } : nil
            let record = LedgerRecord(amount: (e.amount * 100).rounded() / 100, kind: item.kind, category: category,
                                      note: e.memo, merchant: item.kind == .transfer ? "" : e.merchant,
                                      account: from?.name ?? "", date: e.date, source: source.rawValue)
            if item.kind == .transfer && record.note.isEmpty { record.note = e.merchant }
            record.accountRef = from
            record.toAccount = to
            record.externalID = e.orderID
            record.importBatchID = batchID
            context.insert(record)
            if item.edited && item.kind.countsInStats && !e.merchant.isEmpty {
                RuleStore.learn(merchant: e.merchant, kind: item.kind, category: category, account: from, in: context)
            }
            if item.kind == .expense { expense += record.amount }
            if item.kind == .income { income += record.amount }
        }
        batch.recordCount = chosen.count
        batch.expenseTotal = expense
        batch.incomeTotal = income
        batch.firstDate = chosen.map(\.entry.date).min()
        batch.lastDate = chosen.map(\.entry.date).max()
        try context.save()
        BudgetMonitor.check(in: context)
        return batch
    }

    static func records(of batch: ImportBatch, in context: ModelContext) -> [LedgerRecord] {
        let target = batch.id.uuidString
        return (try? context.fetch(FetchDescriptor<LedgerRecord>(predicate: #Predicate<LedgerRecord> { $0.importBatchID == target }))) ?? []
    }

    /// 撤销整批导入，返回删除的记录数
    @discardableResult
    static func undo(_ batch: ImportBatch, in context: ModelContext) -> Int {
        let list = records(of: batch, in: context)
        list.forEach { context.delete($0) }
        context.delete(batch)
        try? context.save()
        return list.count
    }
}
