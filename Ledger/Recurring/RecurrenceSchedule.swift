import Foundation

/// 周期频率
enum RecurrenceFrequency: String, CaseIterable, Identifiable, Codable {
    case daily, weekly, monthly, yearly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .daily: return "每天"
        case .weekly: return "每周"
        case .monthly: return "每月"
        case .yearly: return "每年"
        }
    }
    var unit: String {
        switch self {
        case .daily: return "天"
        case .weekly: return "周"
        case .monthly: return "个月"
        case .yearly: return "年"
        }
    }
}

/// 周期规则的纯计算部分（与 SwiftData 解耦，便于测试）
struct RecurrenceSpec: Equatable {
    var frequency: RecurrenceFrequency
    var interval: Int = 1
    /// 每周：1 = 周日 … 7 = 周六（Calendar.weekday）
    var weekday: Int = 2
    /// 每月：1–31（超过当月天数时取当月最后一天）
    var monthDay: Int = 1
    var lastDayOfMonth = false
    var start: Date
    var end: Date?
    /// 0 = 不限次数
    var maxCount: Int = 0

    /// 第 1 次到 through（含）之间的全部发生日期（时间取 start 的时分）
    func occurrences(through: Date, calendar: Calendar, limit: Int = 20000) -> [Date] {
        var result: [Date] = []
        let startDay = calendar.startOfDay(for: start)
        let hm = calendar.dateComponents([.hour, .minute], from: start)
        let step = max(1, interval)
        var n = 0
        var guardCount = 0
        let endLimit = end.map { endOfDay($0, calendar) }
        while guardCount < limit * 4 {
            guardCount += 1
            guard let day = candidate(n, startDay: startDay, step: step, calendar: calendar) else { break }
            n += 1
            if day < startDay { continue }
            guard let d = calendar.date(bySettingHour: hm.hour ?? 9, minute: hm.minute ?? 0, second: 0, of: day) else { continue }
            if d > through { break }
            if let endLimit, d > endLimit { break }
            if maxCount > 0 && result.count >= maxCount { break }
            result.append(d)
            if result.count >= limit { break }
        }
        return result
    }

    /// after 之后（不含）的下一次
    func next(after: Date, calendar: Calendar) -> Date? {
        var horizon = after
        for _ in 0..<6 {
            horizon = calendar.date(byAdding: .year, value: 2, to: horizon) ?? horizon
            if let d = occurrences(through: horizon, calendar: calendar).first(where: { $0 > after }) { return d }
            if let end, end < after { return nil }
        }
        return nil
    }

    private func candidate(_ n: Int, startDay: Date, step: Int, calendar: Calendar) -> Date? {
        switch frequency {
        case .daily:
            return calendar.date(byAdding: .day, value: n * step, to: startDay)
        case .weekly:
            let wd = calendar.component(.weekday, from: startDay)
            let shift = (weekday - wd + 7) % 7
            guard let first = calendar.date(byAdding: .day, value: shift, to: startDay) else { return nil }
            return calendar.date(byAdding: .day, value: n * step * 7, to: first)
        case .monthly:
            guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: startDay)),
                  let m = calendar.date(byAdding: .month, value: n * step, to: monthStart),
                  let days = calendar.range(of: .day, in: .month, for: m)?.count else { return nil }
            let day = lastDayOfMonth ? days : min(max(1, monthDay), days)
            return calendar.date(byAdding: .day, value: day - 1, to: m)
        case .yearly:
            let comps = calendar.dateComponents([.year, .month, .day], from: startDay)
            var c = DateComponents()
            c.year = (comps.year ?? 2000) + n * step
            c.month = comps.month
            c.day = 1
            guard let firstOfMonth = calendar.date(from: c),
                  let days = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count else { return nil }
            return calendar.date(byAdding: .day, value: min(comps.day ?? 1, days) - 1, to: firstOfMonth)
        }
    }

    private func endOfDay(_ d: Date, _ calendar: Calendar) -> Date {
        let s = calendar.startOfDay(for: d)
        return calendar.date(byAdding: .day, value: 1, to: s)?.addingTimeInterval(-1) ?? d
    }

    /// 「每月 10 日」「每 2 周 周一」「每月最后一天」
    func description(calendar: Calendar) -> String {
        let prefix = interval > 1 ? "每 \(interval) \(frequency.unit)" : frequency.title
        switch frequency {
        case .daily: return prefix
        case .weekly:
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            return prefix + " 周" + names[max(0, min(6, weekday - 1))]
        case .monthly: return prefix + (lastDayOfMonth ? " 最后一天" : " \(monthDay) 日")
        case .yearly:
            let c = calendar.dateComponents([.month, .day], from: start)
            return prefix + " \(c.month ?? 1)月\(c.day ?? 1)日"
        }
    }
}
