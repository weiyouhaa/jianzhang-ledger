import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var session = SessionManager.shared
    /// 明细的日期范围（2.0 (16)）：默认本月，只在本次会话记住，冷启动回到本月
    @State private var range = HomeDateRange.make(.thisMonth, calendar: DateText.calendar)
    /// 折叠的日期（按天的 startOfDay），只在本次会话记住
    @State private var collapsedDays: Set<Date> = []
    @State private var showRangeSheet = false
    @State private var editorTarget: EditorTarget?
    @State private var pendingDelete: LedgerRecord?
    @State private var showDemoSearch = false

    enum EditorTarget: Identifiable {
        case new
        case edit(LedgerRecord)

        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let r): return "edit-" + r.id.uuidString
            }
        }
    }

    var body: some View {
        NavigationStack {
            HomeRecordList(range: $range,
                           collapsedDays: $collapsedDays,
                           showRangeSheet: $showRangeSheet,
                           editorTarget: $editorTarget,
                           pendingDelete: $pendingDelete,
                           showDemoSearch: $showDemoSearch)
            .navigationTitle("简账")
            .overlay(alignment: .bottomTrailing) {
                Button {
                    editorTarget = .new
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(Color.accentColor.gradient))
                        .shadow(color: Color.accentColor.opacity(0.4), radius: 10, y: 5)
                }
                .accessibilityLabel("记一笔")
                .accessibilityIdentifier("home-add")
                .padding(.trailing, 22)
                .padding(.bottom, 20)
            }
            .navigationDestination(isPresented: $showDemoSearch) { SearchView() }
            .sheet(item: $editorTarget) { target in
                switch target {
                case .new:
                    RecordEditorView(record: nil, initialDate: newRecordDate)
                case .edit(let record):
                    RecordEditorView(record: record)
                }
            }
            .sheet(isPresented: $showRangeSheet) {
                HomeRangeSheet(range: $range)
                    .presentationDetents([.medium, .large])
            }
            // 左滑删除用居中的 alert：iOS 26 的 confirmationDialog 会变成指向所挂视图的气泡，离被滑动的行很远
            .alert("删除这条记录？", isPresented: deleteDialogBinding, presenting: pendingDelete) { r in
                Button("删除", role: .destructive) {
                    pendingDelete = nil
                    withAnimation {
                        context.delete(r)
                        try? context.save()
                    }
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { r in
                Text("\(r.deleteSummary)\n删除后无法恢复。")
            }
        }
        // 跨月 / 跨天回到前台时刷新「本月」「最近 N 天」等相对范围
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshRange() }
        }
        .onAppear { refreshRange() }
        // 真实 / 防窥切换时回到默认，不把上一个账本的浏览状态带过去
        .onChange(of: session.isDecoy) { _, _ in
            range = HomeDateRange.make(.thisMonth, calendar: DateText.calendar)
            collapsedDays = []
        }
    }

    /// 记一笔的默认日期：范围包含今天就用现在，否则用范围第一天
    private var newRecordDate: Date {
        let now = Date()
        if range.contains(now) { return now }
        return range.start ?? now
    }

    private func refreshRange() {
        let r = range.refreshed(calendar: DateText.calendar)
        if r != range { range = r }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

/// 明细列表：按日期范围用谓词查询，不加载全部记录（2.0 (16)）
private struct HomeRecordList: View {
    @Environment(\.modelContext) private var context
    @Environment(\.ledgerPrefs) private var prefs
    @ObservedObject private var session = SessionManager.shared
    /// 预算变化时刷新
    @AppStorage(SettingsKey.monthlyBudget) private var budgetSetting: Double = 0
    @AppStorage(BudgetKey.rollover) private var rolloverSetting = false
    @AppStorage(RepaymentSetting.key) private var repaymentAsExpense = false
    @AppStorage(SettingsKey.hideAmounts) private var hideAmounts = false

    @Binding var range: HomeDateRange
    @Binding var collapsedDays: Set<Date>
    @Binding var showRangeSheet: Bool
    @Binding var editorTarget: HomeView.EditorTarget?
    @Binding var pendingDelete: LedgerRecord?
    @Binding var showDemoSearch: Bool

    /// 范围内（单月时多带上个月，供预算结转）的记录；余额校准在谓词里就排除（2.0 (13)：只在账户明细和变动日志里显示）
    @Query private var queried: [LedgerRecord]

    init(range: Binding<HomeDateRange>, collapsedDays: Binding<Set<Date>>, showRangeSheet: Binding<Bool>,
         editorTarget: Binding<HomeView.EditorTarget?>, pendingDelete: Binding<LedgerRecord?>, showDemoSearch: Binding<Bool>) {
        _range = range
        _collapsedDays = collapsedDays
        _showRangeSheet = showRangeSheet
        _editorTarget = editorTarget
        _pendingDelete = pendingDelete
        _showDemoSearch = showDemoSearch
        let r = range.wrappedValue
        let lo = r.queryLowerBound(calendar: DateText.calendar) ?? Date.distantPast
        let hi = r.end ?? Date.distantFuture
        let adjustment = RecordKind.adjustment.rawValue
        _queried = Query(filter: #Predicate<LedgerRecord> { rec in
            rec.date >= lo && rec.date < hi && rec.kindRaw != adjustment
        }, sort: \LedgerRecord.date, order: .reverse)
    }

    struct DayGroup {
        let day: Date
        let records: [LedgerRecord]
        /// 「信用卡还款计入支出」
        var includeRepayment = false
        var income: Double { records.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount } }
        var expense: Double { records.filter { $0.countsAsExpense(includeRepayment: includeRepayment) }.reduce(0) { $0 + $1.amount } }
    }

    private var calendar: Calendar { DateText.calendar }

    private var rangeRecords: [LedgerRecord] {
        let r = range
        return queried.filter { r.contains($0.date) }
    }

    private func dayGroups(_ records: [LedgerRecord]) -> [DayGroup] {
        let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.date) }
        return grouped
            .map { DayGroup(day: $0.key, records: $0.value.sorted { $0.date > $1.date },
                            includeRepayment: repaymentAsExpense) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        let records = rangeRecords
        let groups = dayGroups(records)
        let income = records.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }
        let includeRepayment = repaymentAsExpense
        let expense = records.filter { $0.countsAsExpense(includeRepayment: includeRepayment) }.reduce(0) { $0 + $1.amount }
        let budget: Double = {
            guard range.isSingleMonth, let start = range.start else { return 0 }
            return BudgetService.effectiveMonthlyBudget(records: queried, month: start, prefs: prefs)
        }()
        let allCollapsed = !groups.isEmpty && groups.allSatisfy { collapsedDays.contains($0.day) }

        List {
            Section {
                SummaryCard(
                    title: range.title(calendar: calendar),
                    balanceTitle: range.balanceTitle,
                    income: income,
                    expense: expense,
                    count: records.count,
                    budget: budget,
                    hideAmounts: hideAmounts,
                    canStep: range.canStep,
                    canGoNext: range.canStepForward(calendar: calendar),
                    onPrevious: { step(-1) },
                    onNext: { step(1) },
                    onPickRange: { showRangeSheet = true }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if records.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(range.emptyTitle, systemImage: "tray")
                    } description: {
                        Text(range.preset == .thisMonth
                             ? "点右下角的 ＋ 记一笔，或在快捷指令中使用「识图记账」"
                             : "点上方的日期换个范围，或用右上角的搜索查找全部记录")
                    } actions: {
                        if range.preset != .thisMonth {
                            Button("回到本月") { resetToThisMonth() }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(groups, id: \.day) { group in
                    let collapsed = collapsedDays.contains(group.day)
                    Section {
                        if !collapsed {
                            ForEach(group.records) { record in
                                RecordRow(record: record)
                                    .onTapGesture { editorTarget = .edit(record) }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            pendingDelete = record
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                        Button {
                                            editorTarget = .edit(record)
                                        } label: {
                                            Label("编辑", systemImage: "pencil")
                                        }
                                        .tint(.blue)
                                    }
                            }
                        }
                    } header: {
                        dayHeader(group, collapsed: collapsed)
                    }
                }
            }

            // 给右下角 ＋ 和底部标签栏留出空间
            Color.clear.frame(height: 84).listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .toolbar {
            // 2.0 (17)：全部折叠 / 全部展开放到右上角，一个按钮切换
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.snappy) {
                        if allCollapsed { collapsedDays.removeAll() } else { collapsedDays.formUnion(groups.map(\.day)) }
                    }
                } label: {
                    Image(systemName: allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                }
                .disabled(groups.isEmpty)
                .accessibilityLabel(allCollapsed ? "全部展开" : "全部折叠")
                .accessibilityIdentifier("home-collapse-toggle")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SearchView()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("搜索全部记录")
                .accessibilityIdentifier("home-search")
            }
            // 一键去重只看真实账本（防窥会话、编辑防窥数据时都不显示）
            if !session.isDecoy && ModeDefaults.isRealContext(context) {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        DedupeView()
                    } label: {
                        Image(systemName: "square.on.square.dashed")
                    }
                    .accessibilityLabel("一键去重")
                    .accessibilityIdentifier("home-dedupe")
                }
            }
        }
        .task {
            // 截图模式：直接打开记一笔 / 搜索
            if ScreenshotDemo.screen == "add" && editorTarget == nil { editorTarget = .new }
            if ScreenshotDemo.screen == "search" && !showDemoSearch { showDemoSearch = true }
            if ScreenshotDemo.screen == "delete" && pendingDelete == nil {
                try? await Task.sleep(nanoseconds: 800_000_000)
                pendingDelete = dayGroups(rangeRecords).first?.records.first
            }
        }
    }

    /// 可点按的日期标题：折叠后仍显示当天支出 / 收入和笔数
    private func dayHeader(_ group: DayGroup, collapsed: Bool) -> some View {
        Button {
            withAnimation(.snappy) {
                if collapsed { collapsedDays.remove(group.day) } else { collapsedDays.insert(group.day) }
            }
        } label: {
            // 2.0 (17)：字号加大（Dynamic Type），点按区域至少 44pt
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16)
                Text(DateText.dayHeaderText(group.day))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("\(group.records.count) 笔")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    if group.expense > 0 { Text("支 \(Money.masked(group.expense, hidden: hideAmounts))") }
                    if group.income > 0 { Text("收 \(Money.masked(group.income, hidden: hideAmounts))") }
                }
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .textCase(nil)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(DateText.dayHeaderText(group.day))，\(group.records.count) 笔")
        .accessibilityHint(collapsed ? "展开" : "折叠")
    }

    private func step(_ delta: Int) {
        withAnimation(.snappy) { range = range.stepped(delta, calendar: calendar) }
    }

    private func resetToThisMonth() {
        withAnimation(.snappy) { range = HomeDateRange.make(.thisMonth, calendar: calendar) }
    }
}

/// 日期范围选择：本月 / 上月 / 最近 7 天 / 最近 30 天 / 本年 / 全部 / 自定义
struct HomeRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var range: HomeDateRange
    @State private var customStart: Date
    @State private var customEnd: Date
    @State private var showCustom: Bool

    init(range: Binding<HomeDateRange>) {
        _range = range
        let r = range.wrappedValue
        let cal = DateText.calendar
        let now = Date()
        let start = r.start ?? cal.startOfMonth(for: now)
        let lastDay = r.end.flatMap { cal.date(byAdding: .day, value: -1, to: $0) } ?? now
        _customStart = State(initialValue: start)
        _customEnd = State(initialValue: max(start, lastDay))
        _showCustom = State(initialValue: r.preset == .custom)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(HomeDateRange.Preset.menu.filter { $0 != .custom }) { p in
                        Button {
                            range = HomeDateRange.make(p, calendar: DateText.calendar)
                            dismiss()
                        } label: {
                            HStack {
                                Text(p.label).foregroundStyle(.primary)
                                Spacer()
                                Text(HomeDateRange.make(p, calendar: DateText.calendar).title(calendar: DateText.calendar))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if range.preset == p {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("选「本月」即可回到本月。范围只在本次使用中记住，下次打开回到本月。搜索不受此范围影响。")
                }

                Section {
                    Toggle("自定义", isOn: $showCustom.animation())
                    if showCustom {
                        DatePicker("开始", selection: $customStart, displayedComponents: .date)
                        DatePicker("结束", selection: $customEnd, in: customStart..., displayedComponents: .date)
                        Button("应用") {
                            range = HomeDateRange.make(.custom, calendar: DateText.calendar,
                                                       customStart: customStart, customEnd: customEnd)
                            dismiss()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("日期范围")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onChange(of: customStart) { _, s in
                if customEnd < s { customEnd = s }
            }
        }
    }
}

/// 首页顶部的汇总卡片（2.0 (16)：跟随所选日期范围）
struct SummaryCard: View {
    let title: String
    let balanceTitle: String
    let income: Double
    let expense: Double
    let count: Int
    let budget: Double
    let hideAmounts: Bool
    let canStep: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onPickRange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 4) {
                if canStep {
                    Button(action: onPrevious) {
                        Image(systemName: "chevron.left").padding(8)
                    }
                    .accessibilityLabel("上一段")
                }
                Button(action: onPickRange) {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").font(.subheadline)
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.2)))
                    .contentShape(Capsule())
                }
                .accessibilityLabel("日期范围：\(title)")
                .accessibilityHint("选择本月、上月、最近 7 天等")
                .accessibilityIdentifier("home-range")
                if canStep {
                    Button(action: onNext) {
                        Image(systemName: "chevron.right").padding(8)
                    }
                    .disabled(!canGoNext)
                    .opacity(canGoNext ? 1 : 0.35)
                    .accessibilityLabel("下一段")
                }
                Spacer()
                Text("\(count) 笔")
                    .font(.caption)
                    .opacity(0.8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 4) {
                Text(balanceTitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                Text(Money.masked(income - expense, hidden: hideAmounts))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            HStack {
                StatBlock(title: "支出", value: Money.masked(expense, hidden: hideAmounts), light: true)
                Spacer()
                StatBlock(title: "收入", value: Money.masked(income, hidden: hideAmounts), alignment: .trailing, light: true)
            }

            if budget > 0 && !hideAmounts {
                BudgetProgressView(spent: expense, budget: budget, light: true)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(hex: "#1FA67A"), Color(hex: "#1673A8")],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 6)
        .padding(.vertical, 4)
    }
}
