import Foundation
import SwiftData

/// 打开记账页时预填的内容（来自周期账单提醒）
struct RecordPrefill: Identifiable, Equatable {
    let id = UUID()
    var amount: Double
    var kind: RecordKind
    var categoryID: UUID?
    var accountID: UUID?
    var toAccountID: UUID?
    var note: String
    var merchant: String
    var date: Date
    var recurringKey: String
}

/// 周期账单：到期自动记账（启动 / 回到前台时追补到今天，幂等），以及「已付」确认
@MainActor
enum RecurringEngine {
    static var calendar: Calendar { DateText.calendar }

    static func allRules(in context: ModelContext) -> [RecurringRule] {
        (try? context.fetch(FetchDescriptor<RecurringRule>(sortBy: [SortDescriptor(\RecurringRule.createdAt)]))) ?? []
    }

    static func rule(id: UUID, in context: ModelContext) -> RecurringRule? {
        let target = id
        var d = FetchDescriptor<RecurringRule>(predicate: #Predicate<RecurringRule> { $0.id == target })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    static func existingKeys(in context: ModelContext) -> [String: [LedgerRecord]] {
        let d = FetchDescriptor<LedgerRecord>(predicate: #Predicate<LedgerRecord> { $0.recurringKey != "" })
        let list = (try? context.fetch(d)) ?? []
        return Dictionary(grouping: list, by: \.recurringKey)
    }

    static func isPaid(_ rule: RecurringRule, occurrence: Date, keys: [String: [LedgerRecord]]) -> Bool {
        keys[rule.key(for: occurrence)] != nil
    }

    /// 生成到期的自动记账记录，返回新生成的笔数
    @discardableResult
    static func run(in context: ModelContext, now: Date = Date()) -> Int {
        var keys = existingKeys(in: context)
        var created = 0
        // 多设备同步可能产生同一期的重复记录：保留最早的一条
        for (_, list) in keys where list.count > 1 {
            for extra in list.sorted(by: { $0.createdAt < $1.createdAt }).dropFirst() { context.delete(extra) }
        }
        for rule in allRules(in: context) where rule.autoCreate && !rule.isPaused && rule.amount > 0 {
            let occurrences = rule.spec.occurrences(through: now, calendar: calendar)
            let processed = rule.lastProcessedAt
            for occ in occurrences {
                if let processed, occ <= processed { continue }
                let key = rule.key(for: occ)
                if keys[key] != nil { continue }
                guard let record = makeRecord(rule, occurrence: occ, in: context) else { continue }
                context.insert(record)
                keys[key] = [record]
                created += 1
            }
            if let last = occurrences.last, last > (processed ?? .distantPast) { rule.lastProcessedAt = last }
        }
        if context.hasChanges { try? context.save() }
        if created > 0 { BudgetMonitor.check(in: context) }
        return created
    }

    static func makeRecord(_ rule: RecurringRule, occurrence: Date, in context: ModelContext) -> LedgerRecord? {
        let account = DataStore.account(idString: rule.accountID, in: context)
        let kind = rule.kind
        var category: LedgerCategory?
        var toAccount: LedgerAccount?
        if kind == .transfer {
            toAccount = DataStore.account(idString: rule.toAccountID, in: context)
            guard account != nil, toAccount != nil, account?.id != toAccount?.id else { return nil }
        } else {
            category = DataStore.category(idString: rule.categoryID, in: context)
                ?? DataStore.category(named: nil, kind: kind, in: context)
        }
        let note = rule.note.isEmpty ? rule.name : rule.note
        let record = LedgerRecord(amount: (rule.amount * 100).rounded() / 100, kind: kind, category: category, note: note,
                                  merchant: rule.merchant, account: account?.name ?? "", date: occurrence, source: "recurring")
        record.accountRef = account
        record.toAccount = toAccount
        record.recurringKey = rule.key(for: occurrence)
        return record
    }

    /// 通知上的「已付」：为这一期记账（已记过则忽略）
    @discardableResult
    static func markPaid(ruleID: UUID, occurrence: Date, in context: ModelContext) -> LedgerRecord? {
        guard let rule = rule(id: ruleID, in: context) else { return nil }
        let keys = existingKeys(in: context)
        if let existing = keys[rule.key(for: occurrence)]?.first { return existing }
        guard let record = makeRecord(rule, occurrence: occurrence, in: context) else { return nil }
        context.insert(record)
        try? context.save()
        BudgetMonitor.check(in: context)
        return record
    }

    static func prefill(_ rule: RecurringRule, occurrence: Date) -> RecordPrefill {
        RecordPrefill(amount: rule.amount, kind: rule.kind, categoryID: UUID(uuidString: rule.categoryID),
                      accountID: UUID(uuidString: rule.accountID), toAccountID: UUID(uuidString: rule.toAccountID),
                      note: rule.note.isEmpty ? rule.name : rule.note, merchant: rule.merchant,
                      date: occurrence, recurringKey: rule.key(for: occurrence))
    }

    /// 下一次（今天及以后，或最早一期未付的只提醒账单）
    static func nextOccurrence(_ rule: RecurringRule, keys: [String: [LedgerRecord]], now: Date = Date()) -> Date? {
        let today = calendar.startOfDay(for: now)
        if !rule.autoCreate {
            // 只提醒：最近 31 天内未付的一期优先显示
            let recent = rule.spec.occurrences(through: now, calendar: calendar)
                .filter { $0 >= today.addingTimeInterval(-31 * 86400) && $0 >= rule.createdAt.addingTimeInterval(-86400) }
            if let unpaid = recent.first(where: { !isPaid(rule, occurrence: $0, keys: keys) }) { return unpaid }
        }
        return rule.spec.next(after: today.addingTimeInterval(-1), calendar: calendar).flatMap { d in
            rule.autoCreate && d <= now ? rule.spec.next(after: now, calendar: calendar) : d
        }
    }

    /// 本月共发生几次
    static func occurrencesThisMonth(_ rule: RecurringRule, now: Date = Date()) -> Int {
        let (start, end) = BudgetService.monthRange(now)
        return rule.spec.occurrences(through: end.addingTimeInterval(-1), calendar: calendar).filter { $0 >= start }.count
    }

    /// 从一条已有记录建立周期账单（这一笔视为第一期，不会重复生成）
    static func makeRule(from record: LedgerRecord) -> RecurringRule {
        let name = record.merchant.isEmpty ? (record.note.isEmpty ? record.categoryName : record.note) : record.merchant
        let rule = RecurringRule(name: name, amount: record.amount, kind: record.kind, frequency: .monthly, startDate: record.date)
        rule.categoryID = record.category?.id.uuidString ?? ""
        rule.accountID = record.accountRef?.id.uuidString ?? ""
        rule.toAccountID = record.toAccount?.id.uuidString ?? ""
        rule.note = record.note
        rule.merchant = record.merchant
        rule.monthDay = calendar.component(.day, from: record.date)
        rule.weekday = calendar.component(.weekday, from: record.date)
        return rule
    }
}
