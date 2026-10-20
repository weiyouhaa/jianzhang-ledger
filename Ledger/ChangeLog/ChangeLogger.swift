import Foundation
import SwiftData
import UIKit

extension Notification.Name {
    /// 写入 / 清空变动日志后（主线程）发出，日志页据此刷新
    static let changeLogDidChange = Notification.Name("ChangeLogDidChange")
}

/// 变动日志：
/// - SwiftData：监听真实库所有 ModelContext 的 willSave / didSave（含 App Intents 在后台 / 主上下文里的保存）。
///   willSave 时用一个新的 ModelContext 从存储里读出旧值，与内存中的新值逐字段比较；didSave 成功后再一次性写入日志。
///   防窥库是另一个容器，不会被记录；日志自身的写入（只含 ChangeLogEntry）会被忽略，不会循环。
/// - 设置：监听 UserDefaults.standard 的变化，与快照比较受关注的键（不含任何密码 / 哈希），防抖后合并写入。
///   防窥会话中不记录设置变化（防窥偏好在独立 suite，本来就不会被看到）。
/// - 安全 / 备份等事件：显式调用 `ChangeLogger.log`，只写事件描述，绝不写密码。
final class ChangeLogger: @unchecked Sendable {
    static let shared = ChangeLogger()
    /// 批量条目最多保存的明细数
    static let maxChildren = 300
    /// 单次保存超过这么多项时合并为一条「批量」
    static let batchThreshold = 8
    /// 保留期限（天，0 = 永久）
    static let retentionKey = "changelog.retentionDays"
    static let retentionOptions: [Int] = [0, 365, 90]
    static func retentionTitle(_ days: Int) -> String {
        switch days {
        case 0: return "永久"
        case 365: return "1 年"
        default: return "\(days) 天"
        }
    }

    struct Scope {
        var source: ChangeSource
        /// 非空时，这次保存合并为一条批量日志，摘要以此开头
        var title: String?
    }

    /// 调用方可声明来源 / 批量标题（同步、异步代码都可用）
    @TaskLocal static var scope: Scope?

    @discardableResult
    static func with<T>(_ source: ChangeSource, title: String? = nil, _ body: () throws -> T) rethrows -> T {
        try $scope.withValue(Scope(source: source, title: title)) { try body() }
    }

    @discardableResult
    static func withAsync<T>(_ source: ChangeSource, title: String? = nil, _ body: () async throws -> T) async rethrows -> T {
        try await $scope.withValue(Scope(source: source, title: title)) { try await body() }
    }

    // MARK: - 状态

    private var container: ModelContainer?
    private let lock = NSLock()
    private var pending: [ObjectIdentifier: [Draft]] = [:]
    private var observers: [NSObjectProtocol] = []
    private var settingsSnapshot: [String: String] = [:]
    // 以下只在主线程访问
    private var pendingSettings: [String: PendingSetting] = [:]
    private var pendingOrder: [String] = []
    private var flushWork: DispatchWorkItem?

    var isInstalled: Bool { container != nil }

    /// 一条待写入的日志
    struct Draft {
        var source: ChangeSource
        var action: ChangeAction
        var entity: ChangeEntity
        var entityID: String = ""
        var summary: String
        var diffs: [FieldDiff] = []
        var children: [ChildChange] = []
        var childCount: Int = 0
    }

    private struct PendingSetting {
        var label: String
        var entity: ChangeEntity
        var old: String
        var new: String
        var source: ChangeSource
    }

    // MARK: - 安装

    /// 由 DataStore 在真实容器创建后调用一次
    func install(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        settingsSnapshot = currentSettings()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: ModelContext.willSave, object: nil, queue: nil) { [weak self] note in
            self?.willSave(note)
        })
        observers.append(nc.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] note in
            self?.didSave(note)
        })
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.defaultsChanged()
        })
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.flushSettings()
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.prune() }
    }

    // MARK: - SwiftData

    private func willSave(_ note: Notification) {
        guard let container, let ctx = note.object as? ModelContext, ctx.container === container else { return }
        let inserted = ctx.insertedModelsArray
        let changed = ctx.changedModelsArray
        let deleted = ctx.deletedModelsArray
        func relevant(_ m: any PersistentModel) -> Bool { !(m is ChangeLogEntry) }
        guard inserted.contains(where: relevant) || changed.contains(where: relevant) || deleted.contains(where: relevant) else {
            lock.withLock { _ = pending.removeValue(forKey: ObjectIdentifier(ctx)) }
            return
        }
        let drafts = buildDrafts(inserted: inserted, changed: changed, deleted: deleted, container: container)
        lock.withLock { pending[ObjectIdentifier(ctx)] = drafts }
    }

    private func didSave(_ note: Notification) {
        guard let ctx = note.object as? ModelContext else { return }
        let drafts = lock.withLock { pending.removeValue(forKey: ObjectIdentifier(ctx)) } ?? []
        guard !drafts.isEmpty else { return }
        write(drafts)
    }

    private func buildDrafts(inserted: [any PersistentModel], changed: [any PersistentModel], deleted: [any PersistentModel],
                             container: ModelContainer) -> [Draft] {
        let fresh = ModelContext(container)
        fresh.autosaveEnabled = false
        let lookup = Lookup(context: fresh)
        let old = OldValues(changed + deleted, context: fresh, lookup: lookup)

        var items: [Draft] = []
        var inferred: ChangeSource?
        var importTitle: String?

        for m in inserted {
            if let b = m as? ImportBatch {
                importTitle = "导入\(b.source.title)账单「\(b.fileName)」"
                inferred = .importing
                continue
            }
            if let r = m as? LedgerRecord, inferred == nil || inferred == .app {
                if !r.importBatchID.isEmpty { inferred = .importing }
                else if r.source == "recurring" { inferred = .recurring }
                else if r.source == "shortcut" || r.source == "ocr" { inferred = .shortcut }
            }
            guard let d = Describe.model(m, lookup: lookup) else { continue }
            let diffs = d.fields.filter { !$0.value.isEmpty }.map { FieldDiff(field: $0.label, old: nil, new: $0.value) }
            items.append(Draft(source: .app, action: .create, entity: d.entity, entityID: d.id, summary: d.summary, diffs: diffs))
        }

        var deletedNames = Set<String>()
        for m in deleted {
            if let b = m as? ImportBatch { importTitle = "撤销导入「\(b.fileName)」"; continue }
            guard let d = old.desc(for: m) ?? Describe.model(m, lookup: lookup) else { continue }
            if d.entity == .account || d.entity == .category { deletedNames.insert(d.name) }
            let diffs = d.fields.filter { !$0.value.isEmpty }.map { FieldDiff(field: $0.label, old: $0.value, new: nil) }
            items.append(Draft(source: .app, action: .delete, entity: d.entity, entityID: d.id, summary: d.summary, diffs: diffs))
        }

        for m in changed {
            guard !(m is ImportBatch), let now = Describe.model(m, lookup: lookup), let before = old.desc(for: m) else { continue }
            var diffs: [FieldDiff] = []
            let beforeMap = Dictionary(before.fields.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
            for f in now.fields {
                let o = beforeMap[f.label] ?? ""
                if o != f.value { diffs.append(FieldDiff(field: f.label, old: o.isEmpty ? nil : o, new: f.value.isEmpty ? nil : f.value)) }
            }
            // 删除账户 / 分类时被置空的关联，不单独记一条
            diffs.removeAll { d in Describe.relationFields.contains(d.field) && d.new == nil && deletedNames.contains(d.old ?? "") }
            guard !diffs.isEmpty else { continue }
            var entity = now.entity
            if entity == .category && diffs.allSatisfy({ $0.field == "月预算" }) { entity = .budget }
            items.append(Draft(source: .app, action: .update, entity: entity, entityID: now.id, summary: now.summary, diffs: diffs))
        }

        guard !items.isEmpty || importTitle != nil else { return [] }
        let scope = Self.scope
        let source = scope?.source ?? inferred ?? .app
        var title = scope?.title ?? importTitle
        if title == nil && source == .recurring && items.count > 1 { title = "周期账单自动记账" }

        if title == nil && items.count <= Self.batchThreshold {
            return items.map { (item: Draft) -> Draft in
                var d = item
                d.source = source
                return d
            }
        }
        return [Self.batch(items, source: source, title: title ?? "批量变动")]
    }

    static func batch(_ items: [Draft], source: ChangeSource, title: String) -> Draft {
        var counts: [ChangeAction: Int] = [:]
        var entityCounts: [ChangeEntity: Int] = [:]
        for i in items {
            counts[i.action, default: 0] += 1
            entityCounts[i.entity, default: 0] += 1
        }
        let main = entityCounts.max { $0.value < $1.value }?.key ?? .record
        let parts = [ChangeAction.create, .update, .delete].compactMap { a in counts[a].map { "\(a.title) \($0)" } }
        let keepDiffs = items.count <= maxChildren
        let children = items.prefix(maxChildren).map {
            ChildChange(action: $0.action.rawValue, entity: $0.entity.rawValue, summary: $0.summary,
                        diffs: keepDiffs && !$0.diffs.isEmpty ? $0.diffs : nil)
        }
        let summary = parts.isEmpty ? title : title + "：" + parts.joined(separator: " · ")
        return Draft(source: source, action: .batch, entity: main, summary: summary,
                     children: Array(children), childCount: items.count)
    }

    // MARK: - 写入

    private func write(_ drafts: [Draft]) {
        guard let container, !drafts.isEmpty else { return }
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        let now = Date()
        for (i, d) in drafts.enumerated() {
            // 同一批的条目按顺序错开 1 毫秒，列表排序稳定
            ctx.insert(ChangeLogEntry(timestamp: now.addingTimeInterval(Double(i) / 1000), source: d.source, action: d.action,
                                      entity: d.entity, entityID: d.entityID, summary: d.summary, diffs: d.diffs,
                                      children: d.children, childCount: d.childCount))
        }
        try? ctx.save()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .changeLogDidChange, object: nil) }
    }

    /// 显式记录（安全、备份、清空数据等）。防窥会话中不记录。
    static func log(_ action: ChangeAction, _ entity: ChangeEntity, summary: String, diffs: [FieldDiff] = [],
                    source: ChangeSource? = nil) {
        guard shared.isInstalled, !ModeDefaults.isDecoyMode else { return }
        shared.write([Draft(source: source ?? scope?.source ?? .app, action: action, entity: entity, summary: summary, diffs: diffs)])
    }

    /// 清空全部日志；清空本身记为第一条
    func clearAll() {
        guard let container else { return }
        let ctx = ModelContext(container)
        let n = (try? ctx.fetchCount(FetchDescriptor<ChangeLogEntry>())) ?? 0
        try? ctx.delete(model: ChangeLogEntry.self)
        try? ctx.save()
        write([Draft(source: .app, action: .delete, entity: .settings, summary: "清空变动日志（\(n) 条）")])
    }

    /// 按保留期限删除旧日志
    func prune() {
        guard let container else { return }
        let days = UserDefaults.standard.integer(forKey: Self.retentionKey)
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let ctx = ModelContext(container)
        try? ctx.delete(model: ChangeLogEntry.self, where: #Predicate<ChangeLogEntry> { $0.timestamp < cutoff })
        try? ctx.save()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .changeLogDidChange, object: nil) }
    }

    /// 读取（新到旧）
    func fetchAll() -> [ChangeLogEntry] {
        guard let container else { return [] }
        let ctx = ModelContext(container)
        return (try? ctx.fetch(FetchDescriptor<ChangeLogEntry>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)]))) ?? []
    }

    // MARK: - 设置

    private func currentSettings() -> [String: String] {
        let d = UserDefaults.standard
        var out: [String: String] = [:]
        for s in WatchedSetting.all { out[s.key] = s.format(d.object(forKey: s.key)) }
        return out
    }

    private func defaultsChanged() {
        guard container != nil else { return }
        let now = currentSettings()
        let decoy = ModeDefaults.isDecoyMode
        let source = Self.scope?.source ?? .app
        var changes: [(WatchedSetting, String, String)] = []
        lock.withLock {
            for s in WatchedSetting.all {
                let o = settingsSnapshot[s.key] ?? "", n = now[s.key] ?? ""
                if o != n { changes.append((s, o, n)) }
            }
            settingsSnapshot = now
        }
        guard !changes.isEmpty, !decoy else { return }
        let found = changes
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for (s, o, n) in found {
                if var p = self.pendingSettings[s.key] {
                    p.new = n
                    self.pendingSettings[s.key] = p
                } else {
                    self.pendingSettings[s.key] = PendingSetting(label: s.label, entity: s.entity, old: o, new: n, source: source)
                    self.pendingOrder.append(s.key)
                }
                if s.key == Self.retentionKey { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.prune() } }
            }
            self.flushWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flushSettings() }
            self.flushWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        }
    }

    /// 合并待写的设置变化（主线程）
    func flushSettings() {
        flushWork?.cancel()
        flushWork = nil
        let items = pendingOrder.compactMap { pendingSettings[$0] }.filter { $0.old != $0.new }
        pendingSettings.removeAll()
        pendingOrder.removeAll()
        guard !items.isEmpty else { return }
        var drafts: [Draft] = []
        for entity in ChangeEntity.allCases {
            let group = items.filter { $0.entity == entity }
            guard let first = group.first else { continue }
            let diffs = group.map { FieldDiff(field: $0.label, old: $0.old, new: $0.new) }
            var summary = "\(first.label)：\(first.old) → \(first.new)"
            if group.count > 1 { summary += " 等 \(group.count) 项" }
            drafts.append(Draft(source: first.source, action: .update, entity: entity, summary: summary, diffs: diffs))
        }
        write(drafts)
    }
}

// MARK: - 描述模型

/// 一个模型的可读快照
struct ModelDesc {
    var entity: ChangeEntity
    var id: String
    var name: String
    var summary: String
    var fields: [(label: String, value: String)]
}

/// 分类 / 账户名称（规则、周期账单以 UUID 字符串引用它们）
final class Lookup {
    private let context: ModelContext
    private lazy var categories: [String: String] = {
        let all = (try? context.fetch(FetchDescriptor<LedgerCategory>())) ?? []
        return Dictionary(all.map { ($0.id.uuidString, $0.name) }, uniquingKeysWith: { a, _ in a })
    }()
    private lazy var accounts: [String: String] = {
        let all = (try? context.fetch(FetchDescriptor<LedgerAccount>())) ?? []
        return Dictionary(all.map { ($0.id.uuidString, $0.name) }, uniquingKeysWith: { a, _ in a })
    }()
    init(context: ModelContext) { self.context = context }
    func category(_ id: String) -> String { id.isEmpty ? "" : (categories[id] ?? "（已删除）") }
    func account(_ id: String) -> String { id.isEmpty ? "" : (accounts[id] ?? "（已删除）") }
}

enum Describe {
    static let relationFields: Set<String> = ["分类", "账户", "转入账户"]

    static func money(_ v: Double) -> String {
        let sym = UserDefaults.standard.string(forKey: SettingsKey.currencySymbol) ?? "¥"
        return (v < 0 ? "-" : "") + sym + Money.format(abs(v), showSymbol: false)
    }
    static func yesNo(_ b: Bool) -> String { b ? "是" : "否" }
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func model(_ m: any PersistentModel, lookup: Lookup) -> ModelDesc? {
        switch m {
        case let r as LedgerRecord: return record(r)
        case let a as LedgerAccount: return account(a)
        case let c as LedgerCategory: return category(c)
        case let r as CategoryRule: return rule(r, lookup: lookup)
        case let r as RecurringRule: return recurring(r, lookup: lookup)
        default: return nil
        }
    }

    static func record(_ r: LedgerRecord) -> ModelDesc {
        var title = r.displayTitle
        if title.count > 14 { title = String(title.prefix(14)) + "…" }
        let amount = r.kind.sign + money(r.amount)
        let summary = "\(title) \(amount) · \(DateText.monthDayTime.string(from: r.date))"
        return ModelDesc(entity: .record, id: r.id.uuidString, name: title, summary: summary, fields: [
            ("类型", r.kind.title),
            ("金额", money(r.amount)),
            ("分类", r.kind.countsInStats ? (r.category?.name ?? "") : ""),
            ("账户", r.accountName),
            ("转入账户", r.kind == .transfer ? (r.toAccount?.name ?? "") : ""),
            ("手续费", r.fee > 0 ? money(r.fee) : ""),
            ("时间", DateText.full.string(from: r.date)),
            ("商户", r.merchant),
            ("备注", r.note),
        ])
    }

    static func account(_ a: LedgerAccount) -> ModelDesc {
        ModelDesc(entity: .account, id: a.id.uuidString, name: a.name, summary: "\(a.name)（\(a.type.title)）", fields: [
            ("名称", a.name),
            ("类型", a.type.title),
            ("初始余额", money(a.initialBalance)),
            ("额度", a.creditLimit > 0 ? money(a.creditLimit) : ""),
            ("账单日", a.billingDay > 0 ? "每月 \(a.billingDay) 日" : ""),
            ("还款日", a.repaymentDay > 0 ? "每月 \(a.repaymentDay) 日" : ""),
            ("图标", a.icon),
            ("颜色", a.colorHex),
            ("备注", a.note),
            ("计入净资产", yesNo(a.includeInNetWorth)),
            ("已归档", yesNo(a.isArchived)),
        ])
    }

    static func category(_ c: LedgerCategory) -> ModelDesc {
        ModelDesc(entity: .category, id: c.id.uuidString, name: c.name, summary: "\(c.name)（\(c.kind.title)分类）", fields: [
            ("名称", c.name),
            ("类型", c.kind.title),
            ("图标", c.icon),
            ("颜色", c.colorHex),
            ("月预算", c.monthlyBudget > 0 ? money(c.monthlyBudget) : "未设置"),
        ])
    }

    static func rule(_ r: CategoryRule, lookup: Lookup) -> ModelDesc {
        let cat = lookup.category(r.categoryID)
        let name = r.displayName.isEmpty ? r.keyword : r.displayName
        return ModelDesc(entity: .rule, id: r.id.uuidString, name: name,
                         summary: name + (cat.isEmpty ? "" : " → \(cat)"), fields: [
            ("关键词", r.keyword),
            ("显示名", r.displayName),
            ("方式", r.isLearned ? "自动学习" : "手动"),
            ("收支", r.kind?.title ?? "不限"),
            ("分类", cat),
            ("账户", lookup.account(r.accountID)),
            ("启用", yesNo(r.isEnabled)),
        ])
    }

    static func recurring(_ r: RecurringRule, lookup: Lookup) -> ModelDesc {
        let freq = r.interval > 1 ? "每 \(r.interval) \(r.frequency.unit)" : r.frequency.title
        return ModelDesc(entity: .recurring, id: r.id.uuidString, name: r.name,
                         summary: "\(r.name) \(money(r.amount)) · \(freq)", fields: [
            ("名称", r.name),
            ("金额", money(r.amount)),
            ("类型", r.kind.title),
            ("分类", lookup.category(r.categoryID)),
            ("账户", lookup.account(r.accountID)),
            ("转入账户", lookup.account(r.toAccountID)),
            ("频率", freq),
            ("开始日期", dayFormatter.string(from: r.startDate)),
            ("结束日期", r.endDate.map { dayFormatter.string(from: $0) } ?? ""),
            ("次数上限", r.maxCount > 0 ? "\(r.maxCount) 次" : ""),
            ("自动记账", yesNo(r.autoCreate)),
            ("提醒", r.remindEnabled ? "提前 \(r.remindDaysBefore) 天 \(String(format: "%02d:%02d", r.remindHour, r.remindMinute))" : "关"),
            ("暂停", yesNo(r.isPaused)),
            ("商户", r.merchant),
            ("备注", r.note),
        ])
    }
}

/// 从存储（未保存前）读出的旧值
private struct OldValues {
    private var byID: [String: ModelDesc] = [:]

    init(_ models: [any PersistentModel], context: ModelContext, lookup: Lookup) {
        var records: [UUID] = [], accounts: [UUID] = [], categories: [UUID] = [], rules: [UUID] = [], recurring: [UUID] = []
        for m in models {
            switch m {
            case let r as LedgerRecord: records.append(r.id)
            case let a as LedgerAccount: accounts.append(a.id)
            case let c as LedgerCategory: categories.append(c.id)
            case let r as CategoryRule: rules.append(r.id)
            case let r as RecurringRule: recurring.append(r.id)
            default: break
            }
        }
        func add(_ d: ModelDesc) { byID[d.entity.rawValue + d.id] = d }
        if !records.isEmpty {
            let ids = records
            for r in (try? context.fetch(FetchDescriptor<LedgerRecord>(predicate: #Predicate { ids.contains($0.id) }))) ?? [] { add(Describe.record(r)) }
        }
        if !accounts.isEmpty {
            let ids = accounts
            for a in (try? context.fetch(FetchDescriptor<LedgerAccount>(predicate: #Predicate { ids.contains($0.id) }))) ?? [] { add(Describe.account(a)) }
        }
        if !categories.isEmpty {
            let ids = categories
            for c in (try? context.fetch(FetchDescriptor<LedgerCategory>(predicate: #Predicate { ids.contains($0.id) }))) ?? [] { add(Describe.category(c)) }
        }
        if !rules.isEmpty {
            let ids = rules
            for r in (try? context.fetch(FetchDescriptor<CategoryRule>(predicate: #Predicate { ids.contains($0.id) }))) ?? [] { add(Describe.rule(r, lookup: lookup)) }
        }
        if !recurring.isEmpty {
            let ids = recurring
            for r in (try? context.fetch(FetchDescriptor<RecurringRule>(predicate: #Predicate { ids.contains($0.id) }))) ?? [] { add(Describe.recurring(r, lookup: lookup)) }
        }
    }

    func desc(for m: any PersistentModel) -> ModelDesc? {
        switch m {
        case let r as LedgerRecord: return byID[ChangeEntity.record.rawValue + r.id.uuidString]
        case let a as LedgerAccount: return byID[ChangeEntity.account.rawValue + a.id.uuidString]
        case let c as LedgerCategory: return byID[ChangeEntity.category.rawValue + c.id.uuidString]
        case let r as CategoryRule: return byID[ChangeEntity.rule.rawValue + r.id.uuidString]
        case let r as RecurringRule: return byID[ChangeEntity.recurring.rawValue + r.id.uuidString]
        default: return nil
        }
    }
}

// MARK: - 关注的设置项

struct WatchedSetting {
    let key: String
    let label: String
    let entity: ChangeEntity
    let format: (Any?) -> String

    private static func bool(_ def: Bool) -> (Any?) -> String { { ($0 as? Bool ?? def) ? "开" : "关" } }
    private static func moneyOrUnset(_ v: Any?) -> String {
        let d = (v as? Double) ?? (v as? NSNumber)?.doubleValue ?? 0
        return d > 0 ? Describe.money(d) : "未设置"
    }
    private static func int(_ v: Any?, _ def: Int) -> Int {
        let i = (v as? Int) ?? (v as? NSNumber)?.intValue ?? 0
        return i > 0 ? i : def
    }

    static let all: [WatchedSetting] = [
        // 预算
        .init(key: SettingsKey.monthlyBudget, label: "月预算", entity: .budget, format: WatchedSetting.moneyOrUnset),
        .init(key: BudgetKey.yearly, label: "年度预算", entity: .budget, format: WatchedSetting.moneyOrUnset),
        .init(key: BudgetKey.rollover, label: "预算结转", entity: .budget, format: WatchedSetting.bool(false)),
        .init(key: BudgetKey.alertsEnabled, label: "预算提醒", entity: .budget, format: WatchedSetting.bool(false)),
        .init(key: BudgetKey.warnPercent, label: "提醒阈值", entity: .budget, format: { "\(WatchedSetting.int($0, 80))%" }),
        .init(key: BudgetKey.alertOver, label: "超支提醒", entity: .budget, format: WatchedSetting.bool(true)),
        // 记账 / 外观
        .init(key: SettingsKey.currencySymbol, label: "货币符号", entity: .settings, format: { ($0 as? String) ?? "¥" }),
        .init(key: SettingsKey.defaultAccount, label: "默认账户", entity: .settings,
              format: { let s = ($0 as? String) ?? ""; return s.isEmpty ? "不设置" : s }),
        .init(key: RuleStore.learnKey, label: "自动学习分类", entity: .settings, format: WatchedSetting.bool(true)),
        .init(key: SettingsKey.hideAmounts, label: "隐藏金额", entity: .settings, format: WatchedSetting.bool(false)),
        .init(key: SettingsKey.appearance, label: "主题", entity: .settings, format: {
            switch WatchedSetting.int($0, 0) { case 1: return "浅色"; case 2: return "深色"; default: return "跟随系统" }
        }),
        .init(key: ChangeLogger.retentionKey, label: "日志保留", entity: .settings,
              format: { ChangeLogger.retentionTitle((($0 as? Int) ?? (($0 as? NSNumber)?.intValue ?? 0))) }),
        // 安全（只记开关 / 方式，不含密码）
        .init(key: SettingsKey.hideInAppSwitcher, label: "多任务界面隐藏内容", entity: .security, format: WatchedSetting.bool(true)),
        .init(key: AppLockManager.Keys.biometrics, label: "面容 ID / 触控 ID", entity: .security, format: WatchedSetting.bool(false)),
        .init(key: AppLockManager.Keys.unlockMethod, label: "解锁方式", entity: .security, format: {
            ($0 as? String) == AppLockManager.UnlockMethod.autoBiometric.rawValue ? "自动面容 ID" : "密码"
        }),
        .init(key: AppLockManager.Keys.biometricButton, label: "锁屏显示面容 ID 按钮", entity: .security, format: WatchedSetting.bool(false)),
        .init(key: AppLockManager.Keys.grace, label: "离开后多久需要解锁", entity: .security,
              format: { AppLockManager.graceTitle((($0 as? Int) ?? (($0 as? NSNumber)?.intValue ?? 0))) }),
        // 备份
        .init(key: SettingsKey.iCloudSyncEnabled, label: "iCloud 同步", entity: .backup, format: WatchedSetting.bool(false)),
        .init(key: SettingsKey.autoBackupEnabled, label: "自动备份", entity: .backup, format: WatchedSetting.bool(false)),
        .init(key: SettingsKey.autoBackupMode, label: "自动备份方式", entity: .backup,
              format: { (AutoBackupMode(rawValue: ($0 as? String) ?? "") ?? .rolling).title }),
        .init(key: SettingsKey.autoBackupInterval, label: "备份频率", entity: .backup,
              format: { AutoBackup.intervalTitle(WatchedSetting.int($0, 86_400)) }),
        .init(key: SettingsKey.autoBackupKeep, label: "保留份数", entity: .backup, format: { "\(WatchedSetting.int($0, 10)) 份" }),
        .init(key: SettingsKey.autoBackupDailySnapshot, label: "每日快照", entity: .backup, format: WatchedSetting.bool(true)),
        .init(key: SettingsKey.autoBackupSnapshotKeep, label: "快照保留", entity: .backup, format: { "\(WatchedSetting.int($0, 7)) 份" }),
        .init(key: SettingsKey.backupEncryption, label: "加密备份", entity: .backup, format: WatchedSetting.bool(true)),
    ]
}
