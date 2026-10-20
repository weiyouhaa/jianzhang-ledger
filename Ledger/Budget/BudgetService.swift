import Foundation
import SwiftData

enum BudgetKey {
    static let yearly = "budget.yearly"
    static let rollover = "budget.rollover"
    static let alertsEnabled = "budget.alertsEnabled"
    static let warnPercent = "budget.alertWarn"
    static let alertOver = "budget.alertOver"
    static let sentAlerts = "budget.sentAlerts"
}

/// 一条预算进度
struct BudgetLine: Identifiable {
    let id: String
    let name: String
    let icon: String
    let colorHex: String
    /// 本期可用预算（含结转）
    let budget: Double
    /// 基础预算（不含结转）
    let base: Double
    let carry: Double
    let spent: Double

    var ratio: Double { budget > 0 ? spent / budget : (spent > 0 ? 2 : 0) }
    var remaining: Double { budget - spent }
    var isOver: Bool { spent > budget + 0.0001 }
}

struct BudgetStatus {
    var total: BudgetLine?
    var categories: [BudgetLine]
    var yearly: BudgetLine?
    var month: Date
}

/// 预算计算（总预算、分类预算、年度预算、结余结转）
enum BudgetService {
    static var calendar: Calendar { DateText.calendar }

    static func monthlyBase(_ prefs: UserDefaults) -> Double { max(0, prefs.double(forKey: SettingsKey.monthlyBudget)) }
    static func yearlyBudget(_ prefs: UserDefaults) -> Double { max(0, prefs.double(forKey: BudgetKey.yearly)) }
    static func rolloverEnabled(_ prefs: UserDefaults) -> Bool { prefs.bool(forKey: BudgetKey.rollover) }

    static func monthRange(_ month: Date) -> (Date, Date) {
        let start = calendar.startOfMonth(for: month)
        return (start, calendar.date(byAdding: .month, value: 1, to: start) ?? start)
    }

    /// includeRepayment：「信用卡还款计入支出」开启时，还款也占用总预算（分类预算不受影响：还款没有分类）
    static func spent(_ records: [LedgerRecord], from start: Date, to end: Date, categoryID: UUID? = nil,
                      includeRepayment: Bool = false) -> Double {
        records.reduce(0) { sum, r in
            guard r.countsAsExpense(includeRepayment: includeRepayment && categoryID == nil),
                  r.date >= start, r.date < end else { return sum }
            if let categoryID, r.category?.id != categoryID { return sum }
            return sum + r.amount
        }
    }

    /// 上月结余（可为负）结转到本月，只结转一个月，不滚雪球
    static func carry(base: Double, records: [LedgerRecord], month: Date, categoryID: UUID? = nil, prefs: UserDefaults) -> Double {
        guard rolloverEnabled(prefs), base > 0 else { return 0 }
        let (start, _) = monthRange(month)
        guard let prevStart = calendar.date(byAdding: .month, value: -1, to: start) else { return 0 }
        // 上个月没有任何记录（比如刚开始记账）时不结转
        let prevRecords = records.filter { $0.date >= prevStart && $0.date < start }
        guard !prevRecords.isEmpty else { return 0 }
        return base - spent(prevRecords, from: prevStart, to: start, categoryID: categoryID,
                            includeRepayment: RepaymentSetting.includeInExpense(prefs))
    }

    /// 本月总预算（含结转），用于首页与统计
    /// prefs：调用方所在子树的偏好（视图用 @Environment(\.ledgerPrefs)，后台用 ModeDefaults.prefs(for:)）
    static func effectiveMonthlyBudget(records: [LedgerRecord], month: Date, prefs: UserDefaults) -> Double {
        let base = monthlyBase(prefs)
        guard base > 0 else { return 0 }
        return max(0, base + carry(base: base, records: records, month: month, prefs: prefs))
    }

    static func status(records: [LedgerRecord], categories: [LedgerCategory], month: Date, prefs: UserDefaults) -> BudgetStatus {
        let (start, end) = monthRange(month)
        var result = BudgetStatus(total: nil, categories: [], yearly: nil, month: start)
        let base = monthlyBase(prefs)
        if base > 0 {
            let c = carry(base: base, records: records, month: start, prefs: prefs)
            result.total = BudgetLine(id: "total", name: "本月总预算", icon: "chart.pie.fill", colorHex: "#007AFF",
                                      budget: max(0, base + c), base: base, carry: c,
                                      spent: spent(records, from: start, to: end,
                                                   includeRepayment: RepaymentSetting.includeInExpense(prefs)))
        }
        for cat in categories where cat.kind == .expense && cat.monthlyBudget > 0 {
            // 结转只作用于总预算，分类预算每月固定
            result.categories.append(BudgetLine(id: cat.id.uuidString, name: cat.name, icon: cat.icon, colorHex: cat.colorHex,
                                                budget: cat.monthlyBudget, base: cat.monthlyBudget, carry: 0,
                                                spent: spent(records, from: start, to: end, categoryID: cat.id)))
        }
        result.categories.sort { $0.ratio > $1.ratio }
        let yearly = yearlyBudget(prefs)
        if yearly > 0, let yStart = calendar.date(from: calendar.dateComponents([.year], from: start)),
           let yEnd = calendar.date(byAdding: .year, value: 1, to: yStart) {
            result.yearly = BudgetLine(id: "yearly", name: "\(calendar.component(.year, from: start)) 年度预算", icon: "calendar",
                                       colorHex: "#5856D6", budget: yearly, base: yearly, carry: 0,
                                       spent: spent(records, from: yStart, to: yEnd,
                                                    includeRepayment: RepaymentSetting.includeInExpense(prefs)))
        }
        return result
    }

    @MainActor
    static func currentStatus(in context: ModelContext) -> BudgetStatus {
        let now = Date()
        let (start, end) = monthRange(now)
        let yStart = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? start
        let from = min(yStart, calendar.date(byAdding: .month, value: -1, to: start) ?? start)
        let records = DataStore.records(from: from, to: max(end, calendar.date(byAdding: .year, value: 1, to: yStart) ?? end), in: context)
        let categories = (try? context.fetch(FetchDescriptor<LedgerCategory>())) ?? []
        return status(records: records, categories: categories, month: now, prefs: ModeDefaults.prefs(for: context))
    }
}

/// 预算提醒：保存记录 / 导入 / 快捷指令 / 周期记账后检查，达到阈值时发本地通知（每期每档只提醒一次）
@MainActor
enum BudgetMonitor {
    /// 只有真实库会发预算通知，因此提醒设置固定读真实偏好
    private static var prefs: UserDefaults { .standard }
    static var alertsEnabled: Bool { prefs.bool(forKey: BudgetKey.alertsEnabled) }
    static var warnPercent: Int {
        let v = prefs.integer(forKey: BudgetKey.warnPercent)
        return v == 0 ? 80 : v
    }
    static var alertOver: Bool { prefs.object(forKey: BudgetKey.alertOver) as? Bool ?? true }

    static func check(in context: ModelContext) {
        // 防窥会话、或真实会话里「编辑防窥数据」（防窥容器）都不检查、不发通知
        guard ModeDefaults.isRealContext(context), !SessionManager.shared.isDecoy,
              alertsEnabled, !ScreenshotDemo.isActive else { return }
        let status = BudgetService.currentStatus(in: context)
        let monthKey = DayKey.formatter.string(from: status.month).prefix(7)
        let yearKey = monthKey.prefix(4)
        var sent = prefs.dictionary(forKey: BudgetKey.sentAlerts) as? [String: Bool] ?? [:]
        // 只保留本月 / 本年的记录
        sent = sent.filter { $0.key.hasPrefix(String(monthKey)) || $0.key.hasPrefix("Y" + yearKey) }

        var lines: [(BudgetLine, String)] = []
        if let t = status.total { lines.append((t, String(monthKey))) }
        lines += status.categories.map { ($0, String(monthKey)) }
        if let y = status.yearly { lines.append((y, "Y" + yearKey)) }

        for (line, period) in lines where line.budget > 0 {
            let ratio = line.spent / line.budget
            var level: String?
            if alertOver && ratio >= 1 { level = "over" }
            else if ratio * 100 >= Double(warnPercent) { level = "warn" }
            guard let level else { continue }
            let key = "\(period).\(line.id).\(level)"
            guard sent[key] != true else { continue }
            sent[key] = true
            if level == "over" { sent["\(period).\(line.id).warn"] = true }
            let title = level == "over" ? "\(line.name)已超支" : "\(line.name)已用 \(Money.percent(ratio))%"
            let body = level == "over"
                ? "已花 \(Money.format(line.spent))，超出 \(Money.format(line.spent - line.budget))。"
                : "预算 \(Money.format(line.budget))，已花 \(Money.format(line.spent))，还剩 \(Money.format(line.remaining))。"
            NotificationManager.shared.postNow(id: "budget.\(key)", title: title, body: body)
        }
        prefs.set(sent, forKey: BudgetKey.sentAlerts)
    }
}
