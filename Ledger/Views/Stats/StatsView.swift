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
    @Environment(\.appTheme) private var theme
    /// 「信用卡还款计入支出」：开启后还款作为「信用卡还款」分类计入支出
    @AppStorage(RepaymentSetting.key) private var repaymentAsExpense = false
    @AppStorage(SettingsKey.hideAmounts) private var hideAmounts = false

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
                VStack(spacing: theme.isReceipt ? 14 : 16) {
                    if theme.isReceipt {
                        HStack {
                            ReceiptLabelText(text: "AUDIT FOLIO · 统计审计", color: theme.faint)
                            Spacer()
                            ReceiptLabelText(text: "RMB · CNY", color: theme.faint)
                        }
                        .padding(.horizontal, 2)
                        ReceiptSegmentedControl(
                            selection: $period,
                            options: Period.allCases.map { ($0, $0.rawValue) }
                        )
                    } else {
                        Picker("周期", selection: $period) {
                            ForEach(Period.allCases) { p in Text(p.rawValue).tag(p) }
                        }
                        .pickerStyle(.segmented)
                    }

                    periodNavigator

                    overviewCard(expense: expense, income: income, count: periodRecords.count)

                    if theme.isReceipt {
                        ReceiptSegmentedControl(
                            selection: $kind,
                            options: RecordKind.categoryKinds.map { ($0, $0.title + "构成") }
                        )
                    } else {
                        Picker("类型", selection: $kind) {
                            ForEach(RecordKind.categoryKinds) { k in Text(k.title).tag(k) }
                        }
                        .pickerStyle(.segmented)
                    }

                    // 设计稿顺序：审计单 → 预算单 → 印章环（BREAKDOWN）；默认皮肤保持原顺序
                    if theme.isReceipt {
                        budgetCardView(expense: expense)
                    }

                    if kindRecords.isEmpty {
                        card {
                            ThemedEmptyState("暂无\(kind.title)数据", systemImage: "chart.pie",
                                                   description: Text("换个时间段看看吧"))
                        }
                    } else {
                        pieCard(totals: totals, total: total)
                        if !theme.isReceipt {
                            trendCard(trend: trend)
                            rankingCard(totals: totals, total: total, records: kindRecords)
                        }
                    }

                    if !theme.isReceipt {
                        budgetCardView(expense: expense)
                    }

                    if !kindRecords.isEmpty && theme.isReceipt {
                        trendCard(trend: trend)
                        rankingCard(totals: totals, total: total, records: kindRecords)
                    }

                    if period == .year && !periodRecords.isEmpty {
                        compareCard(records: periodRecords)
                    }
                    if theme.isReceipt {
                        Color.clear.frame(height: 28)
                    }
                }
                .padding(.horizontal, theme.isReceipt ? ReceiptStyle.pageHorizontalMargin : 16)
                .padding(.vertical, 12)
            }
            .background(Color.themeBackdrop)
            .themedScreenBackground()
            .themedRootTitle("统计")
            .onChange(of: period) { _, _ in clearChartSelection() }
            .onChange(of: kind) { _, _ in clearChartSelection() }
            .onChange(of: anchor) { _, _ in clearChartSelection() }
        }
    }

    // MARK: - 子视图

    /// 3.5 (26) 小票皮肤：支出用暗红强调色，不用系统橙；卡片标题用打字机粗体
    private var expenseTint: Color { theme.isReceipt ? theme.accent : .orange }
    private var cardTitleFont: Font { theme.isReceipt ? theme.cardTitleFont : .ui(.headline) }

    /// 预算单（月度：分类预算执行；年度：年度预算细条）
    @ViewBuilder
    private func budgetCardView(expense: Double) -> some View {
        if period == .month {
            let status = BudgetService.status(records: allRecords, categories: categories, month: anchor, prefs: prefs)
            // 小票皮肤始终露出预算单（设计稿「◎ 预算」）；没设过也能从这里进去设
            if theme.isReceipt || status.total != nil || !status.categories.isEmpty {
                card { BudgetStatsCard(status: status) }
            }
        } else if yearlyBudget > 0 || theme.isReceipt {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    if theme.isReceipt {
                        Text("◎ 预算").font(cardTitleFont).foregroundStyle(theme.ink)
                    } else {
                        Label("年度预算", systemImage: "target").font(cardTitleFont)
                    }
                    if yearlyBudget > 0 {
                        BudgetProgressView(spent: expense, budget: yearlyBudget, title: "\(periodTitle)预算")
                    } else {
                        Text("还没有\(periodTitle)预算。到设置里填写年度总额后，这里会显示已用进度。")
                            .font(theme.metaFont)
                            .foregroundStyle(theme.faint)
                        NavigationLink {
                            BudgetView()
                        } label: {
                            Text("设置预算")
                                .font(theme.metaFont)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var periodNavigator: some View {
        if theme.isReceipt {
            HStack {
                Button { shift(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("上一段")
                Spacer()
                HStack(spacing: 8) {
                    Text(periodTitle)
                        .font(theme.sectionTitleFont)
                        .foregroundStyle(theme.ink)
                        .padding(.bottom, 3)
                        .overlay(alignment: .bottom) { Rectangle().fill(theme.accent).frame(height: 1.5) }
                    if canGoNext {
                        Button {
                            withAnimation(.snappy) { anchor = Date() }
                        } label: {
                            Text(period == .month ? "回本月" : "回今年")
                                .font(theme.labelFont)
                                .foregroundStyle(theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 3).fill(theme.accent.opacity(0.10)))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
                        }
                        .accessibilityIdentifier("stats-reset-current")
                    }
                }
                Spacer()
                Button { shift(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .disabled(!canGoNext)
                .opacity(canGoNext ? 1 : 0.35)
                .accessibilityLabel("下一段")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.faint)
        } else {
            defaultPeriodNavigator
        }
    }

    private var defaultPeriodNavigator: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left.circle.fill").font(.ui(.title2)) }
            Spacer()
            HStack(spacing: 8) {
                Text(periodTitle).font(.ui(.title3).weight(.semibold))
                if canGoNext {
                    Button(period == .month ? "回本月" : "回今年") {
                        withAnimation(.snappy) { anchor = Date() }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right.circle.fill").font(.ui(.title2)) }
                .disabled(!canGoNext)
        }
        .symbolRenderingMode(.hierarchical)
    }

    private func overviewCard(expense: Double, income: Double, count: Int) -> some View {
        let days = max(1, daysElapsed())
        return card(slot: true) {
            VStack(spacing: 14) {
                if theme.isReceipt {
                    HStack {
                        ReceiptLabelText(text: "LEDGER AUDIT", color: theme.faint)
                        Spacer()
                        ReceiptLabelText(text: periodTitle, color: theme.faint)
                    }
                    ThemedDashedRule()
                }
                HStack(alignment: .center) {
                    StatBlock(title: "支出", value: Money.masked(expense, hidden: hideAmounts))
                        .contentTransition(.numericText(value: expense))
                        .animation(.snappy(duration: 0.26), value: expense)
                    Spacer()
                    if theme.isReceipt {
                        Rectangle().fill(theme.rule).frame(width: 1, height: 32)
                        Spacer()
                    }
                    StatBlock(title: "收入", value: Money.masked(income, hidden: hideAmounts), alignment: .center,
                              valueColor: theme.isReceipt ? theme.income : nil)
                        .contentTransition(.numericText(value: income))
                        .animation(.snappy(duration: 0.26), value: income)
                    Spacer()
                    if theme.isReceipt {
                        Rectangle().fill(theme.rule).frame(width: 1, height: 32)
                        Spacer()
                    }
                    StatBlock(title: "结余", value: Money.masked(income - expense, hidden: hideAmounts), alignment: .trailing)
                        .contentTransition(.numericText(value: income - expense))
                        .animation(.snappy(duration: 0.26), value: income - expense)
                }
                if theme.isReceipt {
                    ThemedDashedRule()
                } else {
                    Divider()
                }
                HStack(alignment: .center) {
                    StatBlock(title: "日均支出", value: Money.masked(expense / Double(days), hidden: hideAmounts))
                        .contentTransition(.numericText(value: expense / Double(days)))
                        .animation(.snappy(duration: 0.26), value: expense)
                    Spacer()
                    if theme.isReceipt {
                        Rectangle().fill(theme.rule).frame(width: 1, height: 30)
                        Spacer()
                    }
                    StatBlock(title: "记账笔数", value: "\(count) 笔", alignment: .trailing)
                        .contentTransition(.numericText(value: Double(count)))
                        .animation(.snappy(duration: 0.26), value: count)
                }
            }
        }
    }

    @ViewBuilder
    private func pieCard(totals: [CategoryTotal], total: Double) -> some View {
        if theme.isReceipt {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("\(kind.title)构成 · BREAKDOWN").font(cardTitleFont)
                        Spacer()
                        Text("STAMP CHART")
                            .font(theme.labelFont)
                            .foregroundStyle(theme.faint)
                    }
                    ThemedDashedRule()
                    StampRingChart(slices: totals.map {
                        StampRingChart.Slice(id: $0.id, label: $0.name, amount: $0.total, color: $0.color)
                    })
                }
            }
        } else {
            defaultPieCard(totals: totals, total: total)
        }
    }

    private func defaultPieCard(totals: [CategoryTotal], total: Double) -> some View {
        let selected = totals.first { $0.id == selectedPieID }
        return card {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(kind.title)构成").font(cardTitleFont)
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
                                .font(.ui(.caption))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(Money.format(selected.total))
                                .font(.ui(.headline, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            Text(percent(selected.total, of: total))
                                .font(.ui(.caption2))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("总\(kind.title)").font(.ui(.caption)).foregroundStyle(.secondary)
                            Text(Money.format(total))
                                .font(.ui(.headline, design: .rounded))
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

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(totals.prefix(8)) { item in
                        Button {
                            withAnimation(.snappy) {
                                selectedPieID = selectedPieID == item.id ? nil : item.id
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(item.color).frame(width: 8, height: 8)
                                Text(item.name).font(.ui(.caption)).lineLimit(1)
                                    .fontWeight(selectedPieID == item.id ? .semibold : .regular)
                                Text(percent(item.total, of: total)).font(.ui(.caption2)).foregroundStyle(.secondary)
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
        let barColor: Color = kind == .expense ? expenseTint : Color.themeIncome
        let selected = nearestTrendPoint(to: selectedTrendDate, in: trend)
        return card {
            VStack(alignment: .leading, spacing: 12) {
                Text(period == .month ? "每日趋势" : "每月趋势").font(cardTitleFont)
                Chart {
                    ForEach(trend) { p in
                        BarMark(
                            x: .value("日期", p.date, unit: unit),
                            y: .value("金额", p.total)
                        )
                        .foregroundStyle(theme.isReceipt ? AnyShapeStyle(barColor.opacity(0.8)) : AnyShapeStyle(barColor.gradient))
                        .cornerRadius(3)
                        .opacity(selected == nil || selected?.id == p.id ? 1 : 0.35)
                    }
                    if let selected {
                        RuleMark(x: .value("选中", selected.date, unit: unit))
                            .foregroundStyle(Color.themeAccent.opacity(0.45))
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
                HStack {
                    Text(theme.isReceipt ? "分类排行 · RANKING" : "分类排行").font(cardTitleFont)
                    Spacer()
                    if theme.isReceipt {
                        ReceiptLabelText(text: "TOP \(totals.count)", color: theme.faint)
                    }
                }
                if theme.isReceipt {
                    ThemedDashedRule()
                }
                ForEach(Array(totals.enumerated()), id: \.element.id) { rankIdx, item in
                    NavigationLink {
                        CategoryRecordsView(
                            title: "\(item.name) · \(periodTitle)",
                            records: records.filter { Self.groupKey($0) == item.id }
                        )
                    } label: {
                        HStack(spacing: 12) {
                            CategoryIcon(icon: item.icon, color: item.color, size: 32, name: item.name, kindRaw: kind.rawValue)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("#\(rankIdx + 1)")
                                        .font(theme.isReceipt ? theme.labelFont : .ui(.caption2).monospacedDigit())
                                        .foregroundStyle(rankIdx < 3 ? theme.accent : theme.faint)
                                    Text(item.name)
                                        .font(theme.isReceipt ? theme.serifTitleFont : .ui(.subheadline))
                                        .foregroundStyle(theme.isReceipt ? theme.ink : .primary)
                                    Text(percent(item.total, of: total))
                                        .font(theme.isReceipt ? theme.metaFont : .ui(.caption))
                                        .foregroundStyle(theme.isReceipt ? theme.faint : .secondary)
                                    Spacer()
                                    Text(Money.format(item.total))
                                        .font(theme.isReceipt ? theme.amountFont(ReceiptStyle.Size.rowTitle) : .ui(.subheadline, design: .rounded).weight(.semibold))
                                        .foregroundStyle(theme.isReceipt ? theme.ink : .primary)
                                }
                                if theme.isReceipt {
                                    ReceiptBar(
                                        ratio: total > 0 ? item.total / total : 0,
                                        fill: theme.accent,
                                        track: theme.rule.opacity(0.55)
                                    )
                                    .frame(height: 3.5)
                                } else {
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.secondary.opacity(0.12))
                                            Capsule().fill(item.color)
                                                .frame(width: geo.size.width * (total > 0 ? item.total / total : 0))
                                        }
                                    }
                                    .frame(height: 6)
                                }
                                HStack(spacing: 6) {
                                    Text("\(item.count) 笔")
                                    if item.count > 1 {
                                        Text("· 笔均 \(Money.format(item.total / Double(item.count)))")
                                    }
                                }
                                .font(theme.isReceipt ? theme.labelFont : .ui(.caption2))
                                .foregroundStyle(theme.isReceipt ? theme.faint : .secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.isReceipt ? theme.faint : .secondary)
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
                Text("收支对比").font(cardTitleFont)
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
                            .foregroundStyle(Color.themeAccent.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                .chartForegroundStyleScale(["支出": expenseTint, "收入": Color.themeIncome])
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
                            .font(.ui(.subheadline).weight(.semibold))
                        HStack(spacing: 16) {
                            compareAmountRow(title: "支出", amount: expenseAmt, color: expenseTint)
                            compareAmountRow(title: "收入", amount: incomeAmt, color: Color.themeIncome)
                            Spacer(minLength: 0)
                            compareAmountRow(
                                title: "结余",
                                amount: balanceAmt,
                                color: balanceAmt >= 0 ? Color.themeIncome : expenseTint
                            )
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(theme.isReceipt ? theme.rule.opacity(0.28) : Color(.secondarySystemFill))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.themeAccent.opacity(0.35), lineWidth: 1)
                    )
                } else {
                    chartHint
                }
            }
        }
    }

    @ViewBuilder
    private func card<Content: View>(slot: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        if theme.isReceipt {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ReceiptStyle.Space.m)
                .padding(.bottom, 4)
                .receiptSurface(theme, hero: true, slot: slot)
        } else {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: theme.cardCorner, style: .continuous)
                        .fill(theme.cardFill)
                )
        }
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
            .font(.ui(.caption))
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
                Text(title).font(.ui(.subheadline).weight(.semibold))
                HStack(spacing: 8) {
                    Text(Money.format(amount))
                        .font(.ui(.title3, design: .rounded).weight(.bold))
                    if let percentText {
                        Text(percentText).font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                    if let count {
                        Text("\(count) 笔").font(.ui(.caption)).foregroundStyle(.secondary)
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
                .strokeBorder(Color.themeAccent.opacity(0.35), lineWidth: 1)
        )
    }

    private func compareAmountRow(title: String, amount: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.ui(.caption2)).foregroundStyle(.secondary)
            }
            Text(Money.format(amount))
                .font(.ui(.caption, design: .rounded).weight(.semibold))
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
    @Environment(\.modelContext) private var context
    @Environment(\.appTheme) private var theme
    @AppStorage("stats.categoryRecordsSort") private var sortRaw = CategoryRecordsSort.dateDesc.rawValue
    @State private var editing: LedgerRecord?
    @State private var stubRecord: LedgerRecord?
    @State private var prefillTarget: RecordPrefill?
    @State private var pendingDeleteAfterStub: LedgerRecord?
    @State private var pendingDelete: LedgerRecord?
    @State private var deletedIDs: Set<UUID> = []

    private var sort: CategoryRecordsSort {
        CategoryRecordsSort(rawValue: sortRaw) ?? .dateDesc
    }

    private var activeRecords: [LedgerRecord] {
        records.filter { !deletedIDs.contains($0.id) && $0.modelContext != nil }
    }

    private var sortedRecords: [LedgerRecord] {
        let base = activeRecords
        switch sort {
        case .dateDesc:
            return base.sorted { $0.date != $1.date ? $0.date > $1.date : $0.amount > $1.amount }
        case .dateAsc:
            return base.sorted { $0.date != $1.date ? $0.date < $1.date : $0.amount > $1.amount }
        case .amountDesc:
            return base.sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.date > $1.date }
        case .amountAsc:
            return base.sorted { $0.amount != $1.amount ? $0.amount < $1.amount : $0.date > $1.date }
        }
    }

    var body: some View {
        let list = sortedRecords
        let sum = list.reduce(0) { $0 + $1.amount }
        let avg = list.isEmpty ? 0 : sum / Double(list.count)
        let maxAmt = list.map(\.amount).max() ?? 0
        ThemedList {
            if !list.isEmpty {
                Section {
                    HStack {
                        StatBlock(title: "合计金额", value: Money.format(sum))
                        Spacer()
                        StatBlock(title: "笔均金额", value: Money.format(avg), alignment: .center)
                        Spacer()
                        StatBlock(title: "单笔最高", value: Money.format(maxAmt), alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                }
            }
            Section {
                ForEach(list) { r in
                    Button {
                        if theme.isReceipt {
                            stubRecord = r
                        } else {
                            editing = r
                        }
                    } label: {
                        RecordRow(record: r, showDate: true)
                    }
                    .buttonStyle(.borderless)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = r
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            editing = r
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            editing = r
                        } label: {
                            Label("编辑记录", systemImage: "pencil")
                        }
                        Button {
                            prefillTarget = RecordPrefill.duplicate(from: r, date: Date())
                        } label: {
                            Label("再来一笔", systemImage: "plus.square.on.square")
                        }
                        if r.kind == .expense && !r.isCreditRepayment {
                            Button {
                                let refundCatID = DataStore.category(named: "退款", kind: .income, in: context)?.id
                                prefillTarget = RecordPrefill.refund(from: r, refundCategoryID: refundCatID, date: Date())
                            } label: {
                                Label("记录退款", systemImage: "arrow.uturn.backward.circle")
                            }
                        }
                        Button(role: .destructive) {
                            pendingDelete = r
                        } label: {
                            Label("删除记录", systemImage: "trash")
                        }
                    }
                }
            } header: { ThemedSectionHeader {
                HStack {
                    Text("共 \(list.count) 笔 · \(Money.format(list.reduce(0) { $0 + $1.amount }))")
                        .textCase(nil)
                    Spacer(minLength: 4)
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
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.arrow.down")
                            Text(sort.title)
                        }
                        .font(.caption)
                        .foregroundStyle(.tint)
                    }
                    .textCase(nil)
                }
            } }
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
        .sheet(item: $prefillTarget) { prefill in
            RecordEditorView(record: nil, initialDate: prefill.date, initialKind: prefill.kind, prefill: prefill)
        }
        .sheet(item: $stubRecord, onDismiss: {
            if let d = pendingDeleteAfterStub {
                pendingDeleteAfterStub = nil
                pendingDelete = d
            }
        }) { r in
            ReceiptStubSheet(record: r, onDelete: { pendingDeleteAfterStub = r })
        }
        .alert("确认删除这笔记录？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { r in
            Button("删除", role: .destructive) {
                deletedIDs.insert(r.id)
                context.delete(r)
                try? context.save()
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { r in
            Text(r.deleteSummary)
        }
    }
}
