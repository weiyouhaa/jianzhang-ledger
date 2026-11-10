import SwiftUI
import SwiftData

private struct ReceiptStubTarget: Identifiable {
    let id: UUID
    let record: LedgerRecord
    init(_ record: LedgerRecord) { self.id = record.id; self.record = record }
}

/// 明细页滚动状态：只在「开始滚动 / 停下」时写入一次，避免滚动中每帧刷新整页
@MainActor
final class HomeFabVisibility: ObservableObject {
    @Published private(set) var hidden = false {
        didSet {
            #if DEBUG
            if hidden != oldValue { Self.debugLog("hidden=\(hidden ? 1 : 0)") }
            #endif
        }
    }
    private var showWork: DispatchWorkItem?
    private var lastOffset: CGFloat?
    private var firstSampleAt: Date?

    /// 每帧收到内容偏移：只要还在动就保持隐藏；停止变化 0.3 秒后再显示（手指拖动、惯性、回弹都算在动）
    #if DEBUG
    static func debugLog(_ line: String) {
        guard ProcessInfo.processInfo.arguments.contains("-JZFabDebugLog") else { return }
        let url = URL(fileURLWithPath: "/tmp/jzfab.log")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }
    #endif

    func noteOffset(_ y: CGFloat) {
        #if DEBUG
        Self.debugLog("offset=\(Int(y))")
        #endif
        defer { lastOffset = y }
        // 首次布局时系统会调整一次内容内边距（0 → 导航栏高度），这不是用户滑动，忽略开头 0.6 秒
        guard let first = firstSampleAt else { firstSampleAt = Date(); return }
        guard Date().timeIntervalSince(first) > 0.6 else { return }
        guard let last = lastOffset, abs(y - last) > 0.5 else { return }
        if !hidden { hidden = true }
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hidden else { return }
            self.hidden = false
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

/// 只有悬浮按钮本身观察滚动状态；列表不会因按钮显隐而重算
private struct HomeFabAutoHide<Content: View>: View {
    @ObservedObject var visibility: HomeFabVisibility
    @ViewBuilder var content: Content

    var body: some View {
        content
            .opacity(visibility.hidden ? 0 : 1)
            .scaleEffect(visibility.hidden ? 0.86 : 1, anchor: .bottomTrailing)
            .offset(y: visibility.hidden ? 24 : 0)
            .allowsHitTesting(!visibility.hidden)
            .accessibilityHidden(visibility.hidden)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: visibility.hidden)
    }
}

/// 滚动偏移汇报（ScrollView / List 通用）：iOS 18+ 用滚动几何（逐帧可靠）；iOS 17 退回拖动手势
private struct HomeScrollActivityReporter: ViewModifier {
    let visibility: HomeFabVisibility

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                visibility.noteOffset(y)
            }
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { visibility.noteOffset($0.translation.height) }
            )
        }
    }
}

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appTheme) private var theme
    @ObservedObject private var session = SessionManager.shared
    /// 明细的日期范围（2.0 (16)）：默认本月，只在本次会话记住，冷启动回到本月
    @State private var range = HomeDateRange.make(.thisMonth, calendar: DateText.calendar)
    /// 折叠的日期（按天的 startOfDay），只在本次会话记住
    @State private var collapsedDays: Set<Date> = []
    @State private var showRangeSheet = false
    @State private var editorTarget: EditorTarget?
    @State private var pendingDelete: LedgerRecord?
    @State private var showDemoSearch = false
    @State private var stubTarget: ReceiptStubTarget?
    @State private var pendingDeleteAfterStub: LedgerRecord?
    /// 引用持有（不被 HomeView 观察），滚动时只刷新悬浮按钮
    @State private var fabVisibility = HomeFabVisibility()

    enum EditorTarget: Identifiable {
        case new
        case newOCR
        case edit(LedgerRecord)
        case prefill(RecordPrefill)

        var id: String {
            switch self {
            case .new: return "new"
            case .newOCR: return "new-ocr"
            case .edit(let r): return "edit-" + r.id.uuidString
            case .prefill(let p): return "prefill-" + p.id.uuidString
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
                           showDemoSearch: $showDemoSearch,
                           stubTarget: $stubTarget,
                           fabVisibility: fabVisibility)
            .themedRootTitle("简账")
            .overlay(alignment: theme.isReceipt ? receiptFabAnchor : .bottomTrailing) {
              HomeFabAutoHide(visibility: fabVisibility) {
                if theme.isReceipt {
                    ReceiptHomeFab(
                        style: ReceiptFabStyle.current,
                        onAdd: { editorTarget = .new },
                        onOCR: { editorTarget = .newOCR }
                    )
                    .padding(.trailing, ReceiptFabStyle.current == .pulltab ? 0 : 18)
                    .padding(.bottom, ReceiptFabStyle.current == .capsule ? 14 : 18)
                } else {
                    Button { editorTarget = .new } label: {
                        Image(systemName: "plus")
                            .font(.ui(.title2).weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(Circle().fill(Color.themeAccent.gradient))
                            .shadow(color: Color.themeAccent.opacity(0.4), radius: 10, y: 5)
                    }
                    .accessibilityLabel("记一笔")
                    .accessibilityIdentifier("home-add")
                    .padding(.trailing, 22)
                    .padding(.bottom, 20)
                }
              }
            }
            .navigationDestination(isPresented: $showDemoSearch) { SearchView() }
            .sheet(item: $editorTarget) { target in
                switch target {
                case .new:
                    RecordEditorView(record: nil, initialDate: newRecordDate)
                case .newOCR:
                    RecordEditorView(record: nil, initialDate: newRecordDate, startInOCRMode: true)
                case .edit(let record):
                    RecordEditorView(record: record)
                case .prefill(let prefill):
                    RecordEditorView(record: nil, initialDate: prefill.date, initialKind: prefill.kind, prefill: prefill)
                }
            }
            .sheet(item: $stubTarget, onDismiss: {
                if let r = pendingDeleteAfterStub {
                    pendingDeleteAfterStub = nil
                    pendingDelete = r
                }
            }) { target in
                ReceiptStubSheet(
                    record: target.record,
                    newDate: newRecordDate,
                    onDelete: { pendingDeleteAfterStub = target.record }
                )
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

    /// 悬浮按钮锚点：印章与拉环靠右，胶囊居中，避免挡住日结金额
    private var receiptFabAnchor: Alignment {
        switch ReceiptFabStyle.current {
        case .seal, .pulltab: return .bottomTrailing
        case .capsule: return .bottom
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
    @AppStorage(SettingsKey.appearance, store: .standard) private var appearance = 0
    @AppStorage(SettingsKey.receiptPaper, store: .standard) private var receiptPaperRaw = ReceiptPaper.cotton.rawValue
    @State private var showInlineFilter = false
    @State private var inlineFilterText = ""
    @State private var inlineKindFilter = 0   // 0 全部 1 支出 2 收入 3 转账

    @Binding var range: HomeDateRange
    @Binding var collapsedDays: Set<Date>
    @Binding var showRangeSheet: Bool
    @Binding var editorTarget: HomeView.EditorTarget?
    @Binding var pendingDelete: LedgerRecord?
    @Binding var showDemoSearch: Bool
    @Binding var stubTarget: ReceiptStubTarget?
    let fabVisibility: HomeFabVisibility
    @Environment(\.appTheme) private var theme

    /// 范围内（单月时多带上个月，供预算结转）的记录；余额校准在谓词里就排除（2.0 (13)：只在账户明细和变动日志里显示）
    @Query private var queried: [LedgerRecord]

    init(range: Binding<HomeDateRange>, collapsedDays: Binding<Set<Date>>, showRangeSheet: Binding<Bool>,
         editorTarget: Binding<HomeView.EditorTarget?>, pendingDelete: Binding<LedgerRecord?>, showDemoSearch: Binding<Bool>,
         stubTarget: Binding<ReceiptStubTarget?>, fabVisibility: HomeFabVisibility) {
        self.fabVisibility = fabVisibility
        _range = range
        _collapsedDays = collapsedDays
        _showRangeSheet = showRangeSheet
        _editorTarget = editorTarget
        _pendingDelete = pendingDelete
        _showDemoSearch = showDemoSearch
        _stubTarget = stubTarget
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

    private var filteredRangeRecords: [LedgerRecord] {
        var list = rangeRecords
        switch inlineKindFilter {
        case 1:
            list = list.filter { $0.countsAsExpense(includeRepayment: repaymentAsExpense) }
        case 2:
            list = list.filter { $0.kind == .income }
        case 3:
            list = list.filter { $0.kind == .transfer || $0.kind == .contribution }
        default:
            break
        }
        let q = inlineFilterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.displayTitle.lowercased().contains(q)
            || $0.categoryName.lowercased().contains(q)
            || $0.accountName.lowercased().contains(q)
            || ($0.toAccount?.name.lowercased().contains(q) ?? false)
            || $0.note.lowercased().contains(q)
            || $0.merchant.lowercased().contains(q)
            || String(format: "%.2f", $0.amount).contains(q)
        }
    }

    var body: some View {
        let records = theme.isReceipt ? filteredRangeRecords : rangeRecords
        let allRangeRecords = rangeRecords
        let groups = dayGroups(records)
        let income = allRangeRecords.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }
        let includeRepayment = repaymentAsExpense
        let expense = allRangeRecords.filter { $0.countsAsExpense(includeRepayment: includeRepayment) }.reduce(0) { $0 + $1.amount }
        let budget: Double = {
            guard range.isSingleMonth, let start = range.start else { return 0 }
            return BudgetService.effectiveMonthlyBudget(records: queried, month: start, prefs: prefs)
        }()
        let allCollapsed = !groups.isEmpty && groups.allSatisfy { collapsedDays.contains($0.day) }

        Group {
            if theme.isReceipt {
                receiptScrollBody(
                    records: records,
                    totalCount: allRangeRecords.count,
                    groups: groups,
                    income: income,
                    expense: expense,
                    budget: budget,
                    allCollapsed: allCollapsed
                )
            } else {
                defaultListBody(
                    records: records,
                    groups: groups,
                    income: income,
                    expense: expense,
                    budget: budget,
                    allCollapsed: allCollapsed
                )
            }
        }
        .task {
            // 截图模式：直接打开记一笔 / 搜索
            if ScreenshotDemo.screen == "add" && editorTarget == nil { editorTarget = .new }
            if ScreenshotDemo.screen == "addocr" && editorTarget == nil { editorTarget = .newOCR }
            if ScreenshotDemo.screen == "search" && !showDemoSearch { showDemoSearch = true }
            if ScreenshotDemo.screen == "editrec" && editorTarget == nil {
                // 3.4 (25) 截图：打开一条演示记录的编辑页（悬浮卡片）
                try? await Task.sleep(nanoseconds: 800_000_000)
                if let r = dayGroups(rangeRecords).first?.records.first { editorTarget = .edit(r) }
            }
            if ScreenshotDemo.screen == "delete" && pendingDelete == nil {
                try? await Task.sleep(nanoseconds: 800_000_000)
                pendingDelete = dayGroups(rangeRecords).first?.records.first
            }
        }
    }

    /// 小票皮肤专属：脱离 iOS 27 List(.insetGrouped) 26pt 气泡裁切，真实渲染出纸槽、三层纸张投影、锯齿撕边与打孔连续热敏纸卷
    private func receiptScrollBody(
        records: [LedgerRecord],
        totalCount: Int,
        groups: [DayGroup],
        income: Double,
        expense: Double,
        budget: Double,
        allCollapsed: Bool
    ) -> some View {
        let maxDayExpense = groups.map(\.expense).max() ?? 0
        return ScrollView {
            LazyVStack(spacing: 14) {
                // 顶部纸本账操作条（脱离系统导航栏胶囊气泡，针对 iPhone 15 Pro Max 宽屏对齐）
                receiptTopActionRow(groups: groups, allCollapsed: allCollapsed)

                if showInlineFilter {
                    receiptInlineFilterBar(records: records)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // 1. 顶部月度结余汇总凭条（带机械出纸槽 + 锯齿下沿 + 完整三层投影）
                SummaryCard(
                    title: range.title(calendar: calendar),
                    balanceTitle: range.balanceTitle,
                    income: income,
                    expense: expense,
                    count: totalCount,
                    budget: budget,
                    hideAmounts: hideAmounts,
                    canStep: range.canStep,
                    canGoNext: range.canStepForward(calendar: calendar),
                    offersBudgetSetup: range.isSingleMonth,
                    onPrevious: { step(-1) },
                    onNext: { step(1) },
                    onPickRange: { showRangeSheet = true },
                    onToggleHideAmounts: { withAnimation { hideAmounts.toggle() } },
                    onResetToThisMonth: (range.preset != .thisMonth || range.canStepForward(calendar: calendar)) ? { resetToThisMonth() } : nil
                )

                // 2. 按日流水连续热敏纸卷（带左右咬边打孔折痕 FoldCrease + 末尾锯齿撕口）
                if records.isEmpty {
                    let hasInlineFilter = !inlineFilterText.isEmpty || inlineKindFilter != 0
                    VStack(spacing: 12) {
                        ThemedEmptyState(
                            !hasInlineFilter ? range.emptyTitle : "没有匹配的凭条",
                            systemImage: "tray",
                            description: Text(
                                hasInlineFilter
                                ? "换个筛选条件或关键词试试，或点击右上角放大镜搜索全部历史账单"
                                : (range.preset == .thisMonth
                                   ? "点右下角的 ＋ 记一笔，或在快捷指令中使用「识图记账」"
                                   : "点上方的日期换个范围，或用右上角的搜索查找全部记录")
                            )
                        ) {
                            if hasInlineFilter {
                                Button("清空筛选") {
                                    inlineFilterText = ""
                                    inlineKindFilter = 0
                                }
                            } else if range.preset != .thisMonth {
                                Button("回到本月") { resetToThisMonth() }
                            }
                        }
                    }
                    .padding(18)
                    .receiptSurface(theme, hero: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.day) { idx, group in
                            let isCollapsed = collapsedDays.contains(group.day)
                            VStack(spacing: 0) {
                                DaySummaryRow(
                                    day: group.day,
                                    count: group.records.count,
                                    expense: group.expense,
                                    income: group.income,
                                    chips: chips(for: group),
                                    barRatio: DaySummary.barRatio(expense: group.expense, maxExpense: maxDayExpense),
                                    collapsed: isCollapsed,
                                    hideAmounts: hideAmounts
                                )
                                .padding(.horizontal, 16)
                                .padding(.top, idx == 0 ? 14 : 8)
                                .padding(.bottom, isCollapsed ? 12 : 6)
                                .contentShape(Rectangle())
                                .onTapGesture { toggle(group.day) }
                                .accessibilityAction { toggle(group.day) }

                                if !isCollapsed {
                                    LazyVStack(spacing: 0) {
                                        ForEach(Array(group.records.enumerated()), id: \.element.id) { recIdx, record in
                                            receiptRecordButton(record, showTopRule: recIdx > 0)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 6)
                                        }
                                    }
                                    .padding(.bottom, 10)
                                }
                            }

                            if idx < groups.count - 1 {
                                FoldCrease()
                            }
                        }
                    }
                    .receiptSurface(theme, hero: true)
                }

                // 给底部双联火漆印章和标签栏留出充裕净空（iPhone 15 Pro Max 单手浏览到底部也不遮挡）
                Color.clear.frame(height: 112)
            }
            .padding(.horizontal, ReceiptStyle.pageHorizontalMargin)
            .padding(.top, 4)
        }
        .modifier(HomeScrollActivityReporter(visibility: fabVisibility))
        .themedScreenBackground()
    }

    private func receiptTopActionRow(groups: [DayGroup], allCollapsed: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VermilionStamp(text: "FOLIO · 纸本账")
                .accessibilityLabel("纸本账")

            Button {
                cyclePaperTheme()
            } label: {
                Text(currentPaperBadgeText)
                    .font(theme.labelFont)
                    .foregroundStyle(theme.faint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(theme.rule.opacity(0.32)))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            if !session.isDecoy && ModeDefaults.isRealContext(context) {
                NavigationLink {
                    DedupeView()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "square.on.square.dashed")
                            .font(.system(size: 11, weight: .medium))
                        Text("去重")
                            .font(theme.serifLabelFont)
                    }
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.cardFill))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.rule, lineWidth: 1))
                    .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("一键去重")
                .accessibilityIdentifier("home-dedupe")
            }

            // 三联一体纸质胶囊按钮：[ 折叠/展开 | 搜索 | 筛选 | 纸张切换 ]
            HStack(spacing: 2) {
                Button {
                    withAnimation(.snappy) {
                        if allCollapsed { collapsedDays.removeAll() } else { collapsedDays.formUnion(groups.map(\.day)) }
                    }
                } label: {
                    Image(systemName: allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.ink)
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(groups.isEmpty)
                .accessibilityLabel(allCollapsed ? "全部展开" : "全部折叠")
                .accessibilityIdentifier("home-collapse-toggle")

                Rectangle().fill(theme.rule).frame(width: 1, height: 14)

                NavigationLink {
                    SearchView()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.ink)
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索全部记录")
                .accessibilityIdentifier("home-search")

                Rectangle().fill(theme.rule).frame(width: 1, height: 14)

                Button {
                    withAnimation(.snappy) {
                        showInlineFilter.toggle()
                        if !showInlineFilter {
                            inlineFilterText = ""
                            inlineKindFilter = 0
                        }
                    }
                } label: {
                    Image(systemName: (showInlineFilter || inlineKindFilter != 0) ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle((showInlineFilter || inlineKindFilter != 0) ? theme.accent : theme.ink)
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("当月票面快筛")
                .accessibilityIdentifier("home-inline-filter")

                Rectangle().fill(theme.rule).frame(width: 1, height: 14)

                Button {
                    cyclePaperTheme()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.ink)
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换纸张材质")
                .accessibilityIdentifier("home-cycle-paper")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [theme.cardFill, theme.paper], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(theme.rule, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
        }
        .padding(.horizontal, 2)
    }

    private var currentPaperBadgeText: String {
        if appearance == 2 { return "炭黑 DARK" }
        let p = ReceiptPaper(rawValue: receiptPaperRaw) ?? .cotton
        return p == .vintage ? "暖黄 VINTAGE" : "棉白 COTTON"
    }

    private func receiptInlineFilterBar(records: [LedgerRecord]) -> some View {
        let hasQuery = !inlineFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || inlineKindFilter != 0
        let matchedExpense = hasQuery ? records.filter { $0.countsAsExpense(includeRepayment: repaymentAsExpense) }.reduce(0) { $0 + $1.amount } : 0
        let matchedIncome = hasQuery ? records.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount } : 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach([(0, "全部"), (1, "支出"), (2, "收入"), (3, "转账")], id: \.0) { tag, label in
                    let selected = inlineKindFilter == tag
                    Button {
                        ReceiptHaptics.selection()
                        withAnimation(.snappy(duration: 0.22)) { inlineKindFilter = tag }
                    } label: {
                        Text(label)
                            .font(theme.labelFont)
                            .foregroundStyle(selected ? theme.paper : theme.ink)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 3).fill(selected ? theme.accent : theme.cardFill))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected ? theme.accent : theme.rule, lineWidth: 1))
                            .scaleEffect(selected ? 1.03 : 1.0)
                    }
                    .buttonStyle(ReceiptPressButtonStyle())
                }
                Spacer()
                if hasQuery {
                    Button("重置") {
                        ReceiptHaptics.lightImpact()
                        withAnimation(.snappy(duration: 0.22)) {
                            inlineFilterText = ""
                            inlineKindFilter = 0
                        }
                    }
                    .font(theme.labelFont)
                    .foregroundStyle(theme.accent)
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.faint)
                TextField("快筛当月商户、分类、账户、备注或金额…", text: $inlineFilterText)
                    .font(theme.serifLabelFont)
                    .textFieldStyle(.plain)
                if !inlineFilterText.isEmpty {
                    Button {
                        inlineFilterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.faint)
                    }
                    .buttonStyle(.plain)
                }
            }
            if hasQuery {
                HStack(spacing: 8) {
                    Text("匹配 \(records.count) 笔")
                    if matchedExpense > 0 {
                        Text("· 支出 \(Money.masked(matchedExpense, hidden: hideAmounts))")
                    }
                    if matchedIncome > 0 {
                        Text("· 收入 \(Money.masked(matchedIncome, hidden: hideAmounts))")
                    }
                    Spacer()
                }
                .font(theme.labelFont)
                .foregroundStyle(theme.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 4).fill(theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.rule, lineWidth: 1))
    }

    private func receiptRecordButton(_ record: LedgerRecord, showTopRule: Bool) -> some View {
        Button {
            stubTarget = ReceiptStubTarget(record)
        } label: {
            RecordRow(record: record, showsTopRule: showTopRule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("record-row")
        .accessibilityLabel(record.displayTitle)
        .contextMenu {
            Button {
                stubTarget = ReceiptStubTarget(record)
            } label: {
                Label("查看凭条存根", systemImage: "doc.text.magnifyingglass")
            }
            Button {
                editorTarget = .edit(record)
            } label: {
                Label("修改记录", systemImage: "pencil")
            }
            Button {
                editorTarget = .prefill(RecordPrefill.duplicate(from: record, date: Date()))
            } label: {
                Label("再来一笔", systemImage: "plus.square.on.square")
            }
            if record.kind == .expense && !record.isCreditRepayment {
                Button {
                    let refundCatID = DataStore.category(named: "退款", kind: .income, in: context)?.id
                    editorTarget = .prefill(RecordPrefill.refund(from: record, refundCategoryID: refundCatID, date: Date()))
                } label: {
                    Label("记录退款", systemImage: "arrow.uturn.backward.circle")
                }
            }
            Button(role: .destructive) {
                pendingDelete = record
            } label: {
                Label("撕毁作废", systemImage: "trash")
            }
        }
    }

    private func defaultListBody(
        records: [LedgerRecord],
        groups: [DayGroup],
        income: Double,
        expense: Double,
        budget: Double,
        allCollapsed: Bool
    ) -> some View {
        ThemedList {
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
                    offersBudgetSetup: range.isSingleMonth,
                    onPrevious: { step(-1) },
                    onNext: { step(1) },
                    onPickRange: { showRangeSheet = true }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if records.isEmpty {
                Section {
                    ThemedEmptyState(range.emptyTitle, systemImage: "tray",
                                     description: Text(range.preset == .thisMonth
                                                       ? "点右下角的 ＋ 记一笔，或在快捷指令中使用「识图记账」"
                                                       : "点上方的日期换个范围，或用右上角的搜索查找全部记录")) {
                        if range.preset != .thisMonth {
                            Button("回到本月") { resetToThisMonth() }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                let maxDayExpense = groups.map(\.expense).max() ?? 0
                ForEach(groups, id: \.day) { group in
                    let collapsed = collapsedDays.contains(group.day)
                    Section {
                        DaySummaryRow(day: group.day,
                                      count: group.records.count,
                                      expense: group.expense,
                                      income: group.income,
                                      chips: chips(for: group),
                                      barRatio: DaySummary.barRatio(expense: group.expense, maxExpense: maxDayExpense),
                                      collapsed: collapsed,
                                      hideAmounts: hideAmounts)
                            .onTapGesture { toggle(group.day) }
                            .accessibilityAction { toggle(group.day) }
                        if !collapsed {
                            ForEach(group.records) { record in
                                recordLink(record, openStub: false)
                            }
                        }
                    }
                }
            }

            // 给右下角 ＋ 和底部标签栏留出空间
            Color.clear.frame(height: 84).listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .modifier(HomeScrollActivityReporter(visibility: fabVisibility))
        .themedScreenBackground()
        .listSectionSpacing(.compact)
        .toolbar {
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
    }

    /// 3.8 (29)：Button 替代 onTapGesture，UI 测试点标题文字也能打开编辑页
    private func recordLink(_ record: LedgerRecord, openStub: Bool, showTopRule: Bool? = nil) -> some View {
        Button {
            if openStub {
                stubTarget = ReceiptStubTarget(record)
            } else {
                editorTarget = .edit(record)
            }
        } label: {
            RecordRow(record: record, showsTopRule: showTopRule ?? openStub)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("record-row")
        .accessibilityLabel(record.displayTitle)
        .listRowSeparator(openStub ? .hidden : .automatic)
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

    private func toggle(_ day: Date) {
        withAnimation(.snappy) {
            if collapsedDays.contains(day) { collapsedDays.remove(day) } else { collapsedDays.insert(day) }
        }
    }

    /// 当天支出最多的前三个分类图标
    private func chips(for group: DayGroup) -> [DaySummaryRow.Chip] {
        let spent = group.records.filter { $0.countsAsExpense(includeRepayment: group.includeRepayment) }
        let keys = DaySummary.topKeys(spent.map { (key: $0.categoryName, amount: $0.amount) })
        return keys.compactMap { key in
            spent.first { $0.categoryName == key }.map {
                DaySummaryRow.Chip(id: key, icon: $0.categoryIcon, color: $0.categoryColor)
            }
        }
    }

    private func step(_ delta: Int) {
        withAnimation(.snappy) { range = range.stepped(delta, calendar: calendar) }
    }

    private func resetToThisMonth() {
        withAnimation(.snappy) { range = HomeDateRange.make(.thisMonth, calendar: calendar) }
    }

    private func cyclePaperTheme() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if appearance == 2 {
                appearance = 1
                receiptPaperRaw = ReceiptPaper.cotton.rawValue
            } else if (ReceiptPaper(rawValue: receiptPaperRaw) ?? .cotton) == .cotton {
                appearance = 1
                receiptPaperRaw = ReceiptPaper.vintage.rawValue
            } else {
                appearance = 2
            }
        }
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
            ThemedList {
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
                                    .font(.ui(.caption))
                                    .foregroundStyle(.secondary)
                                if range.preset == p {
                                    Image(systemName: "checkmark").foregroundStyle(Color.themeAccent)
                                }
                            }
                        }
                    }
                } footer: { ThemedSectionFooter {
                    Text("选「本月」即可回到本月。范围只在本次使用中记住，下次打开回到本月。搜索不受此范围影响。")
                } }

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
    /// 单月范围才提供预算入口（没设过时露出「设置」）
    var offersBudgetSetup: Bool = false
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onPickRange: () -> Void
    var onToggleHideAmounts: (() -> Void)? = nil
    var onResetToThisMonth: (() -> Void)? = nil
    @Environment(\.appTheme) private var theme

    var body: some View {
        if theme.isReceipt { receiptBody } else { defaultBody }
    }

    /// 3.5 (26) 小票皮肤汇总卡：打字机标题 + 暗红下划线（同参考图当前月份）、小号字距标签、
    /// 一个大号结余数字、两列对齐的支出 / 收入，预算用点引线行；只有这张 hero 卡用齿孔下沿
    private var receiptBody: some View {
        VStack(alignment: .leading, spacing: ReceiptStyle.Space.m) {
            HStack(alignment: .center) {
                ReceiptLabelText(text: "MONTHLY STATEMENT", color: theme.faint)
                Spacer(minLength: 8)
                ReceiptLabelText(text: "NO. \(Self.statementNo(count: count))", color: theme.faint)
            }
            ThemedDashedRule()
            HStack(alignment: .center, spacing: ReceiptStyle.Space.xxs) {
                if canStep {
                    Button(action: onPrevious) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .foregroundStyle(theme.faint)
                    .accessibilityLabel("上一段")
                }
                Button(action: onPickRange) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title)
                            .font(theme.serifSectionFont)
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.faint)
                    }
                    .padding(.bottom, 3)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(theme.accent).frame(height: 1.5)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("日期范围：\(title)")
                .accessibilityHint("选择本月、上月、最近 7 天等")
                .accessibilityIdentifier("home-range")
                if canStep {
                    Button(action: onNext) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .foregroundStyle(theme.faint)
                    .disabled(!canGoNext)
                    .opacity(canGoNext ? 1 : 0.35)
                    .accessibilityLabel("下一段")
                }
                if let onResetToThisMonth {
                    Button(action: onResetToThisMonth) {
                        Text("回本月")
                            .font(theme.labelFont)
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 3).fill(theme.accent.opacity(0.10)))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
                    }
                    .accessibilityLabel("回到本月")
                    .accessibilityIdentifier("home-reset-month")
                }
                Spacer(minLength: ReceiptStyle.Space.xs)
                Text("共 \(count) 笔")
                    .font(theme.metaFont)
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.rule.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.rule, lineWidth: 1))
            }
            .buttonStyle(.plain)

            ThemedDashedRule()

            VStack(alignment: .leading, spacing: ReceiptStyle.Space.xs) {
                HStack(alignment: .center, spacing: 6) {
                    Text(balanceTitle + " · NET BALANCE")
                        .font(theme.serifLabelFont)
                        .foregroundStyle(theme.faint)
                    if let onToggleHideAmounts {
                        Button {
                            ReceiptHaptics.selection()
                            withAnimation(.snappy(duration: 0.24)) {
                                onToggleHideAmounts()
                            }
                        } label: {
                            Image(systemName: hideAmounts ? "eye.slash" : "eye")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.faint)
                                .symbolEffect(.bounce, value: hideAmounts)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(hideAmounts ? "显示金额" : "隐藏金额")
                        .accessibilityIdentifier("home-toggle-hide-amounts")
                    }
                    Spacer(minLength: 8)
                    ReceiptLabelText(text: "CNY / RMB", color: theme.faint)
                }
                Text(Money.masked(income - expense, hidden: hideAmounts))
                    .font(theme.heroAmountFont)
                    .monospacedDigit()
                    .foregroundStyle(theme.ink)
                    .contentTransition(.numericText(value: income - expense))
                    .animation(.snappy(duration: 0.26), value: income - expense)
                    .animation(.snappy(duration: 0.22), value: hideAmounts)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            ThemedDashedRule()

            HStack(alignment: .center) {
                StatBlock(title: "总支出 · OUT", value: Money.masked(expense, hidden: hideAmounts),
                          valueSize: ReceiptStyle.Size.body + 2)
                    .contentTransition(.numericText(value: expense))
                    .animation(.snappy(duration: 0.26), value: expense)
                Spacer()
                Rectangle()
                    .fill(theme.rule)
                    .frame(width: 1, height: 34)
                Spacer()
                if count > 0 && expense > 0 {
                    StatBlock(title: "笔均支出 · AVG", value: Money.masked(expense / Double(max(1, count)), hidden: hideAmounts),
                              alignment: .center, valueSize: ReceiptStyle.Size.body)
                        .contentTransition(.numericText(value: expense / Double(max(1, count))))
                    Spacer()
                    Rectangle()
                        .fill(theme.rule)
                        .frame(width: 1, height: 34)
                    Spacer()
                }
                StatBlock(title: "总收入 · IN", value: Money.masked(income, hidden: hideAmounts),
                          alignment: .trailing, valueColor: theme.income, valueSize: ReceiptStyle.Size.body + 2)
                    .contentTransition(.numericText(value: income))
                    .animation(.snappy(duration: 0.26), value: income)
            }

            if !hideAmounts && (budget > 0 || offersBudgetSetup) {
                ThemedDashedRule()
                budgetSlot
            }
        }
        .padding(.horizontal, ReceiptStyle.Space.l - 4)
        .padding(.top, ReceiptStyle.Space.m)
        .padding(.bottom, ReceiptStyle.Space.m)
        .receiptSurface(theme, hero: true, slot: true)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var budgetSlot: some View {
        if budget > 0 {
            BudgetProgressView(spent: expense, budget: budget, light: !theme.isReceipt)
        } else {
            NavigationLink {
                BudgetView()
            } label: {
                HStack(spacing: 6) {
                    Text("本月预算")
                        .font(theme.isReceipt ? theme.serifLabelFont : theme.mono(.caption))
                    Text("未设置")
                        .font(theme.isReceipt ? theme.metaFont : theme.mono(.caption))
                    Spacer(minLength: 8)
                    Text("设置")
                        .font(theme.isReceipt ? theme.metaFont : theme.mono(.caption))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(theme.isReceipt ? theme.faint : theme.heroFaint)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home-budget-setup")
        }
    }

    private static func statementNo(count: Int) -> String {
        let cal = DateText.calendar
        let now = Date()
        let y = cal.component(.year, from: now)
        let m = cal.component(.month, from: now)
        // 设计稿：NO. 202611-020（年月-笔数，三位）
        return String(format: "%04d%02d-%03d", y, m, max(0, min(count, 999)))
    }

    private var defaultBody: some View {
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
                        Image(systemName: "calendar").font(.ui(.subheadline))
                        Text(title)
                            .font(theme.title(.headline))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: "chevron.down").font(.ui(.caption2).weight(.bold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.isReceipt ? theme.accent.opacity(0.12) : .white.opacity(0.2)))
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
                    .font(theme.mono(.caption))
                    .opacity(0.8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.heroInk)

            if theme.usesDashedRules { ThemedDashedRule() }

            VStack(alignment: .leading, spacing: 4) {
                Text(balanceTitle)
                    .font(theme.mono(.caption))
                    .foregroundStyle(theme.heroFaint)
                Text(Money.masked(income - expense, hidden: hideAmounts))
                    .font(theme.amountSize(36))
                    .foregroundStyle(theme.heroInk)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            if theme.usesDashedRules { ThemedDashedRule() }

            HStack {
                StatBlock(title: "支出", value: Money.masked(expense, hidden: hideAmounts), light: true)
                Spacer()
                StatBlock(title: "收入", value: Money.masked(income, hidden: hideAmounts), alignment: .trailing, light: true)
            }

            if !hideAmounts && (budget > 0 || offersBudgetSetup) {
                budgetSlot
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: theme.isReceipt ? 4 : 24,
                             style: theme.isReceipt ? .circular : .continuous)
                .fill(LinearGradient(colors: theme.heroFill,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay {
            if theme.usesDashedRules {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(theme.rule, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
        }
        .shadow(color: Color.black.opacity(theme.isReceipt ? 0.04 : 0.12), radius: theme.isReceipt ? 2 : 12, y: theme.isReceipt ? 1 : 6)
        .padding(.vertical, 4)
    }
}
