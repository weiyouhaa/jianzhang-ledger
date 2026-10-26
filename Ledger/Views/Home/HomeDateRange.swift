import Foundation

/// 首页「明细」的日期范围（2.0 (16)）
/// 只在本次会话内记住；冷启动回到「本月」，跨月 / 跨天时相对范围自动刷新。
/// 纯 Foundation，便于在 Linux 上用 Tools/HomeRangeCheck 测试。
struct HomeDateRange: Equatable {
    enum Preset: String, CaseIterable, Identifiable {
        case thisMonth, lastMonth, last7Days, last30Days, thisYear, all, custom
        /// 用 ‹ › 翻到的某个自然月 / 某一年
        case month, year

        var id: String { rawValue }

        /// 范围选择面板里列出的预设
        static let menu: [Preset] = [.thisMonth, .lastMonth, .last7Days, .last30Days, .thisYear, .all, .custom]

        var label: String {
            switch self {
            case .thisMonth: return "本月"
            case .lastMonth: return "上月"
            case .last7Days: return "最近 7 天"
            case .last30Days: return "最近 30 天"
            case .thisYear: return "本年"
            case .all: return "全部"
            case .custom: return "自定义"
            case .month: return "按月"
            case .year: return "按年"
            }
        }
    }

    var preset: Preset
    /// 含
    var start: Date?
    /// 不含；nil 表示不设上限
    var end: Date?

    // MARK: 构造

    static func make(_ preset: Preset, now: Date = Date(), calendar: Calendar,
                     customStart: Date? = nil, customEnd: Date? = nil) -> HomeDateRange {
        let today = calendar.startOfDay(for: now)
        let thisMonthStart = monthStart(now, calendar)
        switch preset {
        case .thisMonth, .month:
            return monthRange(thisMonthStart, preset: .thisMonth, calendar: calendar)
        case .lastMonth:
            let s = calendar.date(byAdding: .month, value: -1, to: thisMonthStart) ?? thisMonthStart
            return monthRange(s, preset: .lastMonth, calendar: calendar)
        case .last7Days, .last30Days:
            let days = preset == .last7Days ? 7 : 30
            let s = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
            return HomeDateRange(preset: preset, start: s, end: calendar.date(byAdding: .day, value: 1, to: today))
        case .thisYear, .year:
            let s = yearStart(now, calendar)
            return HomeDateRange(preset: .thisYear, start: s, end: calendar.date(byAdding: .year, value: 1, to: s))
        case .all:
            return HomeDateRange(preset: .all, start: nil, end: nil)
        case .custom:
            var a = calendar.startOfDay(for: customStart ?? thisMonthStart)
            var b = calendar.startOfDay(for: customEnd ?? today)
            if a > b { swap(&a, &b) }
            return HomeDateRange(preset: .custom, start: a, end: calendar.date(byAdding: .day, value: 1, to: b))
        }
    }

    /// 某个自然月；本月 / 上月会自动标成对应预设
    static func monthRange(_ anyDayInMonth: Date, preset: Preset = .month, now: Date = Date(), calendar: Calendar) -> HomeDateRange {
        let s = monthStart(anyDayInMonth, calendar)
        let e = calendar.date(byAdding: .month, value: 1, to: s) ?? s
        let current = monthStart(now, calendar)
        var p = preset
        if p == .month || p == .thisMonth || p == .lastMonth {
            if s == current { p = .thisMonth }
            else if s == calendar.date(byAdding: .month, value: -1, to: current) { p = .lastMonth }
            else { p = .month }
        }
        return HomeDateRange(preset: p, start: s, end: e)
    }

    // MARK: 属性

    /// 是否恰好是一个自然月（显示预算、可 ‹ › 翻月）
    var isSingleMonth: Bool { preset == .thisMonth || preset == .lastMonth || preset == .month }
    var isSingleYear: Bool { preset == .thisYear || preset == .year }
    var canStep: Bool { isSingleMonth || isSingleYear }

    func contains(_ date: Date) -> Bool {
        if let start, date < start { return false }
        if let end, date >= end { return false }
        return true
    }

    /// 查询下界：单月时多取上个月，供预算结转计算；nil 表示不设下限
    func queryLowerBound(calendar: Calendar) -> Date? {
        guard let start else { return nil }
        if isSingleMonth { return calendar.date(byAdding: .month, value: -1, to: start) ?? start }
        return start
    }

    /// ‹ ›：单月翻一个月，单年翻一年
    func stepped(_ delta: Int, now: Date = Date(), calendar: Calendar) -> HomeDateRange {
        guard let start else { return self }
        if isSingleMonth {
            let s = calendar.date(byAdding: .month, value: delta, to: start) ?? start
            return HomeDateRange.monthRange(s, now: now, calendar: calendar)
        }
        if isSingleYear {
            let s = calendar.date(byAdding: .year, value: delta, to: start) ?? start
            let p: Preset = s == HomeDateRange.yearStart(now, calendar) ? .thisYear : .year
            return HomeDateRange(preset: p, start: s, end: calendar.date(byAdding: .year, value: 1, to: s))
        }
        return self
    }

    /// 不能翻到未来
    func canStepForward(now: Date = Date(), calendar: Calendar) -> Bool {
        guard canStep, let end else { return false }
        return end <= now
    }

    /// 跨月 / 跨天后刷新相对范围（本月、上月、最近 N 天、本年）；按月 / 按年 / 自定义 / 全部保持不变
    func refreshed(now: Date = Date(), calendar: Calendar) -> HomeDateRange {
        switch preset {
        case .thisMonth, .lastMonth, .last7Days, .last30Days, .thisYear:
            return HomeDateRange.make(preset, now: now, calendar: calendar)
        default:
            return self
        }
    }

    /// 范围胶囊上的文字
    func title(now: Date = Date(), calendar: Calendar) -> String {
        switch preset {
        case .last7Days, .last30Days, .all: return preset.label
        default: break
        }
        guard let start else { return Preset.all.label }
        let y = calendar.component(.year, from: start)
        let m = calendar.component(.month, from: start)
        if isSingleMonth { return "\(y)年\(m)月" }
        if isSingleYear { return "\(y)年" }
        // 自定义：同一天只显示一天；不在今年时带年份
        let last = end.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) } ?? start
        let thisYear = calendar.component(.year, from: now)
        func fmt(_ d: Date, withYear: Bool) -> String {
            let c = calendar.dateComponents([.year, .month, .day], from: d)
            let md = "\(c.month ?? 0)月\(c.day ?? 0)日"
            return withYear ? "\(c.year ?? 0)年" + md : md
        }
        let ly = calendar.component(.year, from: last)
        let needYear = y != thisYear || ly != thisYear || y != ly
        if calendar.isDate(start, inSameDayAs: last) { return fmt(start, withYear: needYear) }
        return fmt(start, withYear: needYear) + " – " + fmt(last, withYear: needYear)
    }

    /// 结余标题：本月结余 / 上月结余 / 本年结余 / 结余
    var balanceTitle: String {
        switch preset {
        case .thisMonth: return "本月结余"
        case .lastMonth: return "上月结余"
        case .thisYear: return "本年结余"
        case .month: return "当月结余"
        case .year: return "当年结余"
        default: return "区间结余"
        }
    }

    /// 空状态文字
    var emptyTitle: String {
        switch preset {
        case .thisMonth: return "本月还没有记录"
        case .all: return "还没有任何记录"
        default: return "这段时间没有记录"
        }
    }

    // MARK: 工具

    static func monthStart(_ d: Date, _ calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: d)) ?? calendar.startOfDay(for: d)
    }

    static func yearStart(_ d: Date, _ calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year], from: d)) ?? calendar.startOfDay(for: d)
    }
}
