import SwiftUI
import SwiftData
import Charts

struct StatsView: View {
    @Query(sort: \LedgerRecord.date, order: .reverse) private var allRecords: [LedgerRecord]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @AppStorage(BudgetKey.yearly, store: ModeDefaults.store) private var yearlyBudget: Double = 0

    @State private var period: Period = .month
    @State private var anchor: Date = Date()
    @State private var kind: RecordKind = .expense

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
        let periodRecords = allRecords.filter { $0.date >= r.start && $0.date < r.end && $0.kind.countsInStats }
        let kindRecords = periodRecords.filter { $0.kind == kind }
        let total = kindRecords.reduce(0) { $0 + $1.amount }
        let totals = categoryTotals(kindRecords)
        let trend = trendPoints(kindRecords, kindTitle: kind.title)
        let expense = periodRecords.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }
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
                        let status = BudgetService.status(records: allRecords, categories: categories, month: anchor)
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
        card {
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
                }
                .chartLegend(.hidden)
                .frame(height: 220)
                .overlay {
                    VStack(spacing: 2) {
                        Text("总\(kind.title)").font(.caption).foregroundStyle(.secondary)
                        Text(Money.format(total))
                            .font(.system(.headline, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: 120)
                }

                // 图例
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(totals.prefix(8)) { item in
                        HStack(spacing: 6) {
                            Circle().fill(item.color).frame(width: 8, height: 8)
                            Text(item.name).font(.caption).lineLimit(1)
                            Text(percent(item.total, of: total)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func trendCard(trend: [TrendPoint]) -> some View {
        let unit: Calendar.Component = period == .month ? .day : .month
        let barColor: Color = kind == .expense ? .orange : .green
        return card {
            VStack(alignment: .leading, spacing: 12) {
                Text(period == .month ? "每日趋势" : "每月趋势").font(.headline)
                Chart(trend) { p in
                    BarMark(
                        x: .value("日期", p.date, unit: unit),
                        y: .value("金额", p.total)
                    )
                    .foregroundStyle(barColor.gradient)
                    .cornerRadius(3)
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
                .frame(height: 200)
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
                            records: records.filter { ($0.category?.id.uuidString ?? "none") == item.id }
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
        let points = trendPoints(records.filter { $0.kind == .expense }, kindTitle: "支出")
            + trendPoints(records.filter { $0.kind == .income }, kindTitle: "收入")
        return card {
            VStack(alignment: .leading, spacing: 12) {
                Text("收支对比").font(.headline)
                Chart(points) { p in
                    BarMark(
                        x: .value("月份", p.date, unit: .month),
                        y: .value("金额", p.total)
                    )
                    .foregroundStyle(by: .value("类型", p.kindTitle))
                    .position(by: .value("类型", p.kindTitle))
                    .cornerRadius(3)
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
                .frame(height: 220)
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

    private func categoryTotals(_ records: [LedgerRecord]) -> [CategoryTotal] {
        let grouped = Dictionary(grouping: records) { $0.category?.id.uuidString ?? "none" }
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
struct CategoryRecordsView: View {
    let title: String
    let records: [LedgerRecord]
    @State private var editing: LedgerRecord?

    var body: some View {
        List {
            Section {
                ForEach(records) { r in
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
        .sheet(item: $editing) { r in
            RecordEditorView(record: r)
        }
    }
}
