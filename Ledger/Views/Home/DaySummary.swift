import Foundation

/// 明细「按天卡片」的纯计算（2.0 (18)）：日期文字、星期、分类排行、占比条。
/// 纯 Foundation，便于在 Linux 上用 Tools/HomeRangeCheck 测试。
enum DaySummary {
    static let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    /// 日期大数字：「26」
    static func dayNumber(_ day: Date, calendar: Calendar) -> String {
        String(calendar.component(.day, from: day))
    }

    /// 第一行：今天 / 昨天 / 周X
    static func relativeLabel(_ day: Date, now: Date = Date(), calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "今天" }
        if let y = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: y) { return "昨天" }
        return weekdays[(calendar.component(.weekday, from: day) - 1 + 7) % 7]
    }

    /// 第二行：「10月26日」，不在今年时带年份；今天 / 昨天时再补上星期
    static func dateLabel(_ day: Date, now: Date = Date(), calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
        var s = "\(c.month ?? 0)月\(c.day ?? 0)日"
        if c.year != calendar.component(.year, from: now) { s = "\(c.year ?? 0)年" + s }
        let rel = relativeLabel(day, now: now, calendar: calendar)
        if rel == "今天" || rel == "昨天" { s += " " + weekdays[((c.weekday ?? 1) - 1 + 7) % 7] }
        return s
    }

    /// 当天支出最多的前几个分类（金额相同按首次出现顺序）
    static func topKeys<K: Hashable>(_ items: [(key: K, amount: Double)], limit: Int = 3) -> [K] {
        var sums: [K: Double] = [:]
        var order: [K] = []
        for it in items where it.amount > 0 {
            if sums[it.key] == nil { order.append(it.key) }
            sums[it.key, default: 0] += it.amount
        }
        let indexed = order.enumerated().map { ($0.offset, $0.element) }
        return indexed
            .sorted { a, b in
                let sa = sums[a.1] ?? 0, sb = sums[b.1] ?? 0
                return sa != sb ? sa > sb : a.0 < b.0
            }
            .prefix(max(0, limit))
            .map { $0.1 }
    }

    /// 当天支出相对于范围内单日最高支出的比例；有支出时至少露出一点
    static func barRatio(expense: Double, maxExpense: Double) -> Double {
        guard expense > 0, maxExpense > 0 else { return 0 }
        return min(1, max(0.04, expense / maxExpense))
    }
}
