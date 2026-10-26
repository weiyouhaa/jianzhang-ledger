import Foundation

// 首页明细日期范围测试（2.0 (16)）：默认本月、预设边界、翻月、跨月刷新、自定义、标题
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
cal.firstWeekday = 2

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("✓ \(msg)") } else { print("✗ \(msg)"); failures += 1 }
}
func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: day, hour: h, minute: min))!
}

let now = d(2026, 10, 26, 15, 30)

// 本月（默认）
let thisMonth = HomeDateRange.make(.thisMonth, now: now, calendar: cal)
check(thisMonth.start == d(2026, 10, 1) && thisMonth.end == d(2026, 11, 1), "本月 = 10/1 ..< 11/1")
check(thisMonth.isSingleMonth && thisMonth.preset == .thisMonth, "本月是单月")
check(thisMonth.title(now: now, calendar: cal) == "2026年10月", "本月标题 2026年10月")
check(thisMonth.contains(d(2026, 10, 31, 23, 59)) && !thisMonth.contains(d(2026, 11, 1)) && !thisMonth.contains(d(2026, 9, 30, 23, 59)), "本月边界")
check(thisMonth.queryLowerBound(calendar: cal) == d(2026, 9, 1), "单月查询多取上个月（预算结转）")
check(!thisMonth.canStepForward(now: now, calendar: cal), "本月不能往后翻")
check(thisMonth.balanceTitle == "本月结余", "本月结余")

// 上月
let last = HomeDateRange.make(.lastMonth, now: now, calendar: cal)
check(last.start == d(2026, 9, 1) && last.end == d(2026, 10, 1) && last.preset == .lastMonth, "上月 = 9 月")
check(last.canStepForward(now: now, calendar: cal), "上月可往后翻")
check(last.stepped(1, now: now, calendar: cal) == thisMonth, "上月 › = 本月")
check(thisMonth.stepped(-1, now: now, calendar: cal) == last, "本月 ‹ = 上月")
let aug = thisMonth.stepped(-2, now: now, calendar: cal)
check(aug.preset == .month && aug.start == d(2026, 8, 1) && aug.title(now: now, calendar: cal) == "2026年8月", "翻到 8 月")
let jan = HomeDateRange.monthRange(d(2026, 1, 15), now: now, calendar: cal).stepped(-1, now: now, calendar: cal)
check(jan.start == d(2025, 12, 1) && jan.end == d(2026, 1, 1) && jan.title(now: now, calendar: cal) == "2025年12月", "跨年翻月")

// 最近 7 / 30 天（含今天）
let l7 = HomeDateRange.make(.last7Days, now: now, calendar: cal)
check(l7.start == d(2026, 10, 20) && l7.end == d(2026, 10, 27), "最近 7 天 = 10/20 ..< 10/27")
check(l7.queryLowerBound(calendar: cal) == d(2026, 10, 20) && !l7.canStep, "最近 7 天不多取、不翻页")
let l30 = HomeDateRange.make(.last30Days, now: now, calendar: cal)
check(l30.start == d(2026, 9, 27) && l30.end == d(2026, 10, 27), "最近 30 天 = 9/27 ..< 10/27")

// 本年
let year = HomeDateRange.make(.thisYear, now: now, calendar: cal)
check(year.start == d(2026, 1, 1) && year.end == d(2027, 1, 1) && year.title(now: now, calendar: cal) == "2026年", "本年")
let y25 = year.stepped(-1, now: now, calendar: cal)
check(y25.preset == .year && y25.start == d(2025, 1, 1) && y25.canStepForward(now: now, calendar: cal), "‹ 翻到 2025 年")
check(y25.stepped(1, now: now, calendar: cal).preset == .thisYear, "› 回到本年")

// 全部
let all = HomeDateRange.make(.all, now: now, calendar: cal)
check(all.start == nil && all.end == nil && all.contains(d(1999, 1, 1)) && all.contains(d(2099, 1, 1)), "全部不设上下限")
check(all.queryLowerBound(calendar: cal) == nil && all.title(now: now, calendar: cal) == "全部", "全部标题 / 下界")

// 自定义：含首尾两天、颠倒自动交换、标题
let custom = HomeDateRange.make(.custom, now: now, calendar: cal, customStart: d(2026, 10, 18, 9), customEnd: d(2026, 10, 3, 22))
check(custom.start == d(2026, 10, 3) && custom.end == d(2026, 10, 19), "自定义颠倒时自动交换，含结束日")
check(custom.contains(d(2026, 10, 18, 23, 59)) && !custom.contains(d(2026, 10, 19)), "自定义结束日整天都算")
check(custom.title(now: now, calendar: cal) == "10月3日 – 10月18日", "自定义标题（今年不带年份）")
let cross = HomeDateRange.make(.custom, now: now, calendar: cal, customStart: d(2025, 12, 20), customEnd: d(2026, 1, 5))
check(cross.title(now: now, calendar: cal) == "2025年12月20日 – 2026年1月5日", "跨年自定义带年份")
let oneDay = HomeDateRange.make(.custom, now: now, calendar: cal, customStart: d(2026, 10, 8), customEnd: d(2026, 10, 8))
check(oneDay.title(now: now, calendar: cal) == "10月8日" && !oneDay.canStep, "单日自定义")

// 跨月 / 跨天刷新：本月、最近 N 天跟着走；翻到的月份、自定义不动
let nextMonthNow = d(2026, 11, 1, 0, 5)
check(thisMonth.refreshed(now: nextMonthNow, calendar: cal).start == d(2026, 11, 1), "跨月后「本月」变成 11 月")
check(l7.refreshed(now: nextMonthNow, calendar: cal).start == d(2026, 10, 26), "跨天后最近 7 天随之移动")
check(aug.refreshed(now: nextMonthNow, calendar: cal) == aug, "翻到的 8 月保持不变")
check(custom.refreshed(now: nextMonthNow, calendar: cal) == custom, "自定义保持不变")
// 刷新后 10 月成为「上月」
let octLater = HomeDateRange.monthRange(d(2026, 10, 1), now: nextMonthNow, calendar: cal)
check(octLater.preset == .lastMonth && octLater.balanceTitle == "上月结余", "11 月里看 10 月 = 上月")

// 预设菜单
check(HomeDateRange.Preset.menu.map(\.label) == ["本月", "上月", "最近 7 天", "最近 30 天", "本年", "全部", "自定义"], "预设菜单顺序")

// 按天卡片（2.0 (18)）
check(DaySummary.dayNumber(d(2026, 10, 6, 12), calendar: cal) == "6", "日期大数字")
check(DaySummary.relativeLabel(d(2026, 10, 26, 8), now: now, calendar: cal) == "今天", "今天")
check(DaySummary.relativeLabel(d(2026, 10, 25, 23), now: now, calendar: cal) == "昨天", "昨天")
check(DaySummary.relativeLabel(d(2026, 10, 21), now: now, calendar: cal) == "周三", "2026-10-21 是周三")
check(DaySummary.relativeLabel(d(2026, 10, 25), now: d(2026, 10, 26, 0, 0), calendar: cal) == "昨天", "零点时昨天仍是昨天")
check(DaySummary.dateLabel(d(2026, 10, 21), now: now, calendar: cal) == "10月21日", "今年不带年份")
check(DaySummary.dateLabel(d(2026, 10, 26), now: now, calendar: cal) == "10月26日 周一", "今天补星期")
check(DaySummary.dateLabel(d(2025, 12, 31), now: now, calendar: cal) == "2025年12月31日", "往年带年份")
let tk = DaySummary.topKeys([("餐饮", 30), ("交通", 50), ("餐饮", 30), ("购物", 10), ("娱乐", 60), ("零", 0)].map { (key: $0.0, amount: $0.1) })
check(tk == ["餐饮", "娱乐", "交通"], "分类排行按金额合计取前三（\(tk)）")
let tie = DaySummary.topKeys([("A", 10), ("B", 10)].map { (key: $0.0, amount: $0.1) }, limit: 5)
check(tie == ["A", "B"], "同额按出现顺序")
check(DaySummary.topKeys([(key: "A", amount: 0.0)]).isEmpty, "无支出无分类")
check(DaySummary.barRatio(expense: 50, maxExpense: 200) == 0.25, "占比条 25%")
check(DaySummary.barRatio(expense: 1, maxExpense: 10_000) == 0.04, "占比条最小露出")
check(DaySummary.barRatio(expense: 0, maxExpense: 100) == 0 && DaySummary.barRatio(expense: 10, maxExpense: 0) == 0, "无支出无条")
check(DaySummary.barRatio(expense: 300, maxExpense: 200) == 1, "占比条封顶")

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("All home range checks passed")
