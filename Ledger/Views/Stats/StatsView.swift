import SwiftUI
import SwiftData
import Charts

struct StatsView: View {
    @Query(sort: \LedgerRecord.date, order: .reverse) private var allRecords: [LedgerRecord]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @AppStorage(BudgetKey.yearly) private var yearlyBudget: Double = 0
    @AppStorage(SettingsKey.monthlyBudget) private var budgetSetting: Double = 0
    @AppStorage(BudgetKey.rollover) private var rolloverSetting = false
    @Environment(\.ledgerPrefs) private var prefs
    /// 「信用卡还款计入支出」：开启后还款作为「信用卡还款」分类计入支出
    @AppStorage(RepaymentSetting.key) private var repaymentAsExpense = false

    @State private var period: Period = .month
    @State private var anchor: Date = Date()
    @State private var kind: RecordKind = .expense
    /// 图表点选（chartOverlay + SpatialTap；不用 chartXSelection，ScrollView 里在 iOS 26/27 常不触发）
    @State private var selectedPieID: String?
    @State private var selectedTrendDate: Date?
    @State private var selectedCompareDate: Date?

    enum Period: String, CaseIterable, Identifiable {
        case month = "月度"
        case year = "年度"
        var id: String { rawValue }
    }

    struct CategoryTotal: Identifiable {
        let id: String
        let name: String
        let icon: String
        let color: Color
        let total: Double
        let count: Int
    }

    struct TrendPoint: Identifiable {
        let date: Date
        let total: Double
        let kindTitle: String
        var id: String { kindTitle + "\(date.timeIntervalSince1970)" }
    }

    private var calendar: Calendar { DateText.calendar }

    private var range: (start: Date, end: Date) {
        switch period {
        case .month:
            let s = calendar.startOfMonth(for: anchor)
            return (s, calendar.date(byAdding: .month, value: 1, to: s) ?? s)
        case .year:
            let s = calendar.startOfYear(for: anchor)
            return (s, calendar.date(byAdding: .year, value: 1, to: s) ?? s)
        }
    }

    private var periodTitle: String {
        period == .month ? DateText.month.string(from: anchor) : DateText.year.string(from: anchor)
    }

    private var canGoNext: Bool { range.end <= Date() }

    var body: some View {
        let r = range
        // 转账与余额校准不计入统计
        let inc = repaymentAsExpense
        let periodRecords = allRecords.filter { $0.date >= r.start && $0.date < r.end && $0.statsKind(includeRepayment: inc) != nil }
        let kindRecords = periodRecords.filter { $0.statsKind(includeRepayment: inc) == kind }
        let total = kindRecords.reduce(0) { $0 + $1.amount }
        let totals = categoryTotals(kindRecords)
        let trend = trendPoints(kindRecords, kindTitle: kind.title)
        let expense = periodRecords.filter { $0.statsKind(includeRepayment: inc) == .expense }.reduce(0) { $0 + $1.amount }
        let income = periodRecords.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("周期", selection: $period) {
                        ForEach(Period.allCases) { p in Text(p.rawValue).tag(p) }
                    }
                    .pickerStyle(.segmented)

                    periodNavigator

                    overviewCard(expense: expense, income: income, count: periodRecords.count)

                    if period == .month {
                        let status = BudgetService.status(records: allRecords, categories: categories, month: anchor, prefs: prefs)
                        if status.total != nil || !status.categories.isEmpty {
                            card { BudgetStatsCard(status: status) }
                        }
                    } else if yearlyBudget > 0 {
                        card {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("年度预算", systemImage: "target").font(.headline)
                                BudgetProgressView(spent: expense, budget: yearlyBudget, title: "\(periodTitle)预算")
                            }
                        }
                    }

                    Picker("类型", selection: $kind) {
                        ForEach(RecordKind.categoryKinds) { k in Text(k.title).tag(k) }
                    }
                    .pickerStyle(.segmented)

                    if kindRecords.isEmpty {
                        card {
                            ContentUnavailableView("暂无\(kind.title)数据", systemImage: "chart.pie",
                                                   description: Text("换个时间段看看吧"))
                        }
                    } else {
                        pieCard(totals: totals, total: total)
                        trendCard(trend: trend)
                        rankingCard(totals: totals, total: total, records: kindRecords)
                    }

                    if period == .year && !periodRecords.isEmpty {
                        compareCard(records: periodRecords)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("统计")
            .onChange(of: period) { _, _ in clearChartSelection() }
            .onChange(of: kind) { _, _ in clearChartSelection() }
            .onChange(of: anchor) { _, _ in clearChartSelection() }
        }
    }

    // MARK: - 子视图

    private var periodNavigator: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left.circle.fill").font(.title2) }
            Spacer()
            Text(periodTitle).font(.title3.weight(.semibold))
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right.circle.fill").font(.title2) }
                .disabled(!canGoNext)
        }
        .symbolRenderingMode(.hierarchical)
    }

    private func overviewCard(expense: Double, income: Double, count: Int) -> some View {
        let days = max(1, daysElapsed())
        return card {
            VStack(spacing: 14) {
                HStack {
                    StatBlock(title: "支出", value: Money.format(expense))
                    Spacer()
                    StatBlock(title: "收入", value: Money.format(income), alignment: .center)
                    Spacer()
                    StatBlock(title: "结余", value: Money.format(income - expense), alignment: .trailing)
                }
                Divider()
                HStack {
                    StatBlock(title: "日均支出", value: Money.format(expense / Double(days)))
                    Spacer()
                    StatBlock(title: "记账笔数", value: "\(count) 笔", alignment: .trailing)
                }
            }
        }
    }

    private func pieCard(totals: [CategoryTotal], total: Double) -> some View {
        let selected = totals.first { $0.id == selectedPieID }
        return card {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(kind.title)构成").font(.headline)
                Chart(totals) { item in
                    SectorMark(
                        angle: .value("金额", item.total),
                        innerRadius: .ratio(0.62),
                        angularInset: 1.5
                    )
                    .cornerRadius(4)
                    .foregroundStyle(item.color)
                    .opacity(selectedPieID == nil || selectedPieID == item.id ? 1 : 0.35)
                }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .highPriorityGesture(
                                SpatialTapGesture()
                                    .onEnded { event in
                                        selectPie(at: event.location, proxy: proxy, geo: geo, totals: totals, total: total)
                                    }
                            )
                    }
                }
                .frame(height: 220)
                .overlay {
                    VStack(spacing: 2) {
                        if let selected {
                            Text(selected.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(Money.format(selected.total))
                                .font(.system(.headline, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            Text(percent(selected.total, of: total))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("总\(kind.title)").font(.caption).foregroundStyle(.secondary)
                            Text(Money.format(total))
                                .font(.system(.headline, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        }
                    }
                    .frame(maxWidth: 120)
                    .allowsHitTesting(false)
                    .animation(.snappy, value: selectedPieID)
                }

                if let selected {
                    chartCallout(
                        title: selected.name,
                        amount: selected.total,
                        percentText: percent(selected.total, of: total),
                        count: selected.count,
                        color: selected.color
                    )
                } else {
                    chartHint
                }

                // 图例（可点选，图表手势的后备）
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(totals.prefix(8)) { item in
                        Button {
                            withAnimation(.snappy) {
                                selectedPieID = selectedPieID == item.id ? nil : item.id
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(item.color).frame(width: 8, height: 8)
                                Text(item.name).font(.caption).lineLimit(1)
                                    .fontWeight(selectedPieID == item.id ? .semibold : .regular)
                                Text(percent(item.total, of: total)).font(.caption2).foregroundStyle(.secondary)
                            }
                            .opacity(selectedPieID == nil || selectedPieID == item.id ? 1 : 0.45)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func trendCard(trend: [TrendPoint]) -> some View {
        let unit: Calendar.Component = period == .month ? .day : .month
        let barColor: Color = kind == .expense ? .orange : .green
        let selected = nearestTrendPoint(to: selectedTrendDate, in: trend)
        return card {
            VStack(alignment: .leading, spacing: 12) {
                Text(period == .month ? "每日趋势" : "每月趋势").font(.headline)
                Chart {
                    ForEach(trend) { p in
                        BarMark(
                            x: .value("日期", p.date, unit: unit),
                            y: .value("金额", p.total)
                        )
                        .foregroundStyle(barColor.gradient)
                        .cornerRadius(3)
                        .opacity(selected == nil || selected?.id == p.id ? 1 : 0.35)
                    }
                    if let selected {
                        RuleMark(x: .value("选中", selected.date, unit: unit))
                            .foregroundStyle(Color.accentColor.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(Money.compact(v))
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .highPriorityGesture(
                                SpatialTapGesture()
                                    .onEnded { event in
                                        selectDate(
                                            at: event.location,
                                            proxy: proxy,
                                            geo: geo,
                                            current: selectedTrendDate,
                                            set: { selectedTrendDate = $0 },
                                            granularity: unit
                                        )
                                    }
                            )
                    }
                }
                .frame(height: 200)

                if let selected {
                    chartCallout(
                        title: trendPointTitle(selected.date),
                        amount: selected.total,
                        percentText: nil,
                        count: nil,
                        color: barColor
                    )
                } else {
                    chartHint
                }
            }
        }
    }

    private func rankingCard(totals: [CategoryTotal], total: Double, records: [LedgerRecord]) -> some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                Text("分类排行").font(.headline)
                ForEach(totals) { item in
                    NavigationLink {
                        CategoryRecordsView(
                            title: "\(item.name) · \(periodTitle)",
                            records: records.filter { Self.groupKey($0) == item.id }
                        )
                    } label: {
                        HStack(spacing: 12) {
                            CategoryIcon(icon: item.icon, color: item.color, size: 34)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.name).font(.subheadline)
                                    Text(percent(item.total, of: total)).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(Money.format(item.total)).font(.system(.subheadline, design: .rounded).weight(.semibold))
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.secondary.opacity(0.12))
                                        Capsule().fill(item.color)
                                            .frame(width: geo.size.width * (total > 0 ? item.total / total : 0))
                                    }
                                }
                                .frame(height: 6)
                                Text("\(item.count) 笔").font(.caption2).foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func compareCard(records: [LedgerRecord]) -> some View {
        let points = trendPoints(records.filter { $0.countsAsExpense(includeRepayment: repaymentAsExpense) }, kindTitle: "支出")
            + trendPoints(records.filter { $0.kind == .income }, kindTitle: "收入")
        let selectedKey = selectedCompareDate.map { calendar.startOfMonth(for: $0) }
        let expenseAmt = selectedKey.flatMap { key in points.first { $0.kindTitle == "支出" && calendar.startOfMonth(for: $0.date) == key }?.total } ?? 0
        let incomeAmt = selectedKey.flatMap { key in points.first { $0.kindTitle == "收入" && calendar.startOfMonth(for: $0.date) == key }?.total } ?? 0
        let balanceAmt = incomeAmt - expenseAmt
        return card {
            VStack(alignment: .leading, spacing: 12) {
                Text("收支对比").font(.headline)
                Chart {
                    ForEach(points) { p in
                        BarMark(
                            x: .value("月份", p.date, unit: .month),
                            y: .value("金额", p.total)
                        )
                        .foregroundStyle(by: .value("类型", p.kindTitle))
                        .position(by: .value("类型", p.kindTitle))
                        .cornerRadius(3)
                        .opacity(compareBarOpacity(for: p.date, selectedKey: selectedKey))
                    }
                    if let selectedKey {
                        RuleMark(x: .value("选中", selectedKey, unit: .month))
                            .foregroundStyle(Color.accentColor.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                .chartForegroundStyleScale(["支出": Color.orange, "收入": Color.green])
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(Money.compact(v))
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .highPriorityGesture(
                                SpatialTapGesture()
                                    .onEnded { event in
                                        selectDate(
                                            at: event.location,
                                            proxy: proxy,
                                            geo: geo,
                                            current: selectedCompareDate,
                                            set: { selectedCompareDate = $0 },
                                            granularity: .month
                                        )
                                    }
                            )
                    }
                }
                .frame(height: 220)

                if let selectedKey {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(DateText.month.string(from: selectedKey))
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 16) {
                            compareAmountRow(title: "支出", amount: expenseAmt, color: .orange)
                            compareAmountRow(title: "收入", amount: incomeAmt, color: .green)
                            Spacer(minLength: 0)
                            compareAmountRow(
                                title: "结余",
                                amount: balanceAmt,
                                color: balanceAmt >= 0 ? .green : .orange
                            )
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemFill))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                    )
                } else {
                    chartHint
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }

    // MARK: - 计算

    /// 分类分组：信用卡还款（无分类）单独成组
    static func groupKey(_ r: LedgerRecord) -> String {
        r.isCreditRepayment ? "card-repayment" : (r.category?.id.uuidString ?? "none")
    }

    private func categoryTotals(_ records: [LedgerRecord]) -> [CategoryTotal] {
        let grouped = Dictionary(grouping: records) { Self.groupKey($0) }
        return grouped.map { key, list in
            let first = list.first
            return CategoryTotal(
                id: key,
                name: first?.categoryName ?? "未分类",
                icon: first?.categoryIcon ?? "questionmark.circle.fill",
                color: first?.categoryColor ?? .gray,
                total: list.reduce(0) { $0 + $1.amount },
                count: list.count
            )
        }
        .sorted { $0.total > $1.total }
    }

    private func trendPoints(_ records: [LedgerRecord], kindTitle: String) -> [TrendPoint] {
        let r = range
        let component: Calendar.Component = period == .month ? .day : .month
        var buckets: [Date: Double] = [:]
        var cursor = r.start
        while cursor < r.end {
            buckets[cursor] = 0
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }
        for rec in records {
            let key = period == .month ? calendar.startOfDay(for: rec.date) : calendar.startOfMonth(for: rec.date)
            buckets[key, default: 0] += rec.amount
        }
        return buckets
            .map { TrendPoint(date: $0.key, total: $0.value, kindTitle: kindTitle) }
            .sorted { $0.date < $1.date }
    }

    private func daysElapsed() -> Int {
        let r = range
        let end = min(r.end, Date())
        guard end > r.start else { return 1 }
        return (calendar.dateComponents([.day], from: r.start, to: end).day ?? 0) + 1
    }

    // MARK: - 图表点选

    private var chartHint: some View {
        Text("点按扇区或柱子查看详情")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private func chartCallout(title: String, amount: Double, percentText: String?, count: Int?, color: Color?) -> some View {
        HStack(spacing: 10) {
            if let color {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .frame(width: 4, height: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    Text(Money.format(amount))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    if let percentText {
                        Text(percentText).font(.caption).foregroundStyle(.secondary)
                    }
                    if let count {
                        Text("\(count) 笔").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
    }

    private func compareAmountRow(title: String, amount: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            Text(Money.format(amount))
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func compareBarOpacity(for date: Date, selectedKey: Date?) -> Double {
        guard let selectedKey else { return 1 }
        return calendar.startOfMonth(for: date) == selectedKey ? 1 : 0.35
    }

    private func clearChartSelection() {
        selectedPieID = nil
        selectedTrendDate = nil
        selectedCompareDate = nil
    }

    /// 饼图：把点击位置换成「从 12 点顺时针」的累计金额域，再落到分类
    private func selectPie(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy, totals: [CategoryTotal], total: Double) {
        guard total > 0, !totals.isEmpty else { return }
        let frame: CGRect
        if let pf = proxy.plotFrame {
            frame = geo[pf]
        } else {
            frame = geo.frame(in: .local)
        }
        let dx = location.x - frame.midX
        let dy = location.y - frame.midY
        let dist = hypot(dx, dy)
        let radius = min(frame.width, frame.height) / 2
        // 洞心或图外：取消选中
        if dist < radius * 0.28 || dist > radius * 1.2 {
            withAnimation(.snappy) { selectedPieID = nil }
            return
        }
        // SectorMark：从正上方起顺时针
        var radians = atan2(dx, -dy)
        if radians < 0 { radians += 2 * .pi }
        let value = (radians / (2 * .pi)) * total
        guard let item = category(atAngle: value, in: totals, total: total) else { return }
        withAnimation(.snappy) {
            selectedPieID = selectedPieID == item.id ? nil : item.id
        }
    }

    /// 柱状图：ChartProxy 把 x 映射为 Date，再写入选中（再点同一粒度则取消）
    private func selectDate(
        at location: CGPoint,
        proxy: ChartProxy,
        geo: GeometryProxy,
        current: Date?,
        set: (Date?) -> Void,
        granularity: Calendar.Component
    ) {
        let frame: CGRect
        if let pf = proxy.plotFrame {
            frame = geo[pf]
        } else {
            frame = geo.frame(in: .local)
        }
        let x = location.x - frame.origin.x
        guard let date: Date = proxy.value(atX: x) else { return }
        withAnimation(.snappy) {
            if let current, calendar.isDate(current, equalTo: date, toGranularity: granularity) {
                set(nil)
            } else {
                set(date)
            }
        }
    }

    /// 累计金额域 → 分类（饼图 SectorMark 的 angle 值域）
    private func category(atAngle angle: Double?, in totals: [CategoryTotal], total: Double) -> CategoryTotal? {
        guard let angle, total > 0, !totals.isEmpty else { return nil }
        var running = 0.0
        for item in totals {
            running += item.total
            if angle <= running { return item }
        }
        return totals.last
    }

    private func nearestTrendPoint(to date: Date?, in trend: [TrendPoint]) -> TrendPoint? {
        guard let date, !trend.isEmpty else { return nil }
        let key = period == .month ? calendar.startOfDay(for: date) : calendar.startOfMonth(for: date)
        if let exact = trend.first(where: {
            let k = period == .month ? calendar.startOfDay(for: $0.date) : calendar.startOfMonth(for: $0.date)
            return k == key
        }) {
            return exact
        }
        return trend.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
    }

    private func trendPointTitle(_ date: Date) -> String {
        if period == .month {
            return DateText.shortDate.string(from: date)
        }
        return DateText.month.string(from: date)
    }

    private func percent(_ value: Double, of total: Double) -> String {
        guard total > 0 else { return "0%" }
        return String(format: "%.1f%%", value / total * 100)
    }

    private func shift(_ delta: Int) {
        let component: Calendar.Component = period == .month ? .month : .year
        if let d = calendar.date(byAdding: component, value: delta, to: anchor) {
            withAnimation(.snappy) { anchor = d }
        }
    }
}

/// 某分类下的记录列表
/// 分类排行明细的排序（持久化，下次进入同一页沿用）
enum CategoryRecordsSort: String, CaseIterable, Identifiable {
    case dateDesc, dateAsc, amountDesc, amountAsc
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dateDesc: return "日期（新→旧）"
        case .dateAsc: return "日期（旧→新）"
        case .amountDesc: return "金额（大→小）"
        case .amountAsc: return "金额（小→大）"
        }
    }
    var shortTitle: String {
        switch self {
        case .dateDesc, .dateAsc: return "日期"
        case .amountDesc, .amountAsc: return "金额"
        }
    }
}

struct CategoryRecordsView: View {
    let title: String
    let records: [LedgerRecord]
    @AppStorage("stats.categoryRecordsSort") private var sortRaw = CategoryRecordsSort.dateDesc.rawValue
    @State private var editing: LedgerRecord?

    private var sort: CategoryRecordsSort {
        CategoryRecordsSort(rawValue: sortRaw) ?? .dateDesc
    }

    private var sortedRecords: [LedgerRecord] {
        switch sort {
        case .dateDesc:
            return records.sorted { $0.date != $1.date ? $0.date > $1.date : $0.amount > $1.amount }
        case .dateAsc:
            return records.sorted { $0.date != $1.date ? $0.date < $1.date : $0.amount > $1.amount }
        case .amountDesc:
            return records.sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.date > $1.date }
        case .amountAsc:
            return records.sorted { $0.amount != $1.amount ? $0.amount < $1.amount : $0.date > $1.date }
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(sortedRecords) { r in
                    RecordRow(record: r, showDate: true)
                        .onTapGesture { editing = r }
                }
            } header: {
                Text("共 \(records.count) 笔 · \(Money.format(records.reduce(0) { $0 + $1.amount }))")
                    .textCase(nil)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(CategoryRecordsSort.allCases) { option in
                        Button {
                            sortRaw = option.rawValue
                        } label: {
                            if option == sort {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down.circle")
                }
                .accessibilityLabel("排序：\(sort.title)")
            }
        }
        .sheet(item: $editing) { r in
            RecordEditorView(record: r)
        }
    }
}
