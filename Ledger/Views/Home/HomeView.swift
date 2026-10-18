import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerRecord.date, order: .reverse) private var allRecords: [LedgerRecord]
    @AppStorage(SettingsKey.monthlyBudget) private var budget: Double = 0
    @AppStorage(BudgetKey.rollover) private var rollover = false

    @State private var month: Date = DateText.calendar.startOfMonth(for: Date())
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

    struct DayGroup {
        let day: Date
        let records: [LedgerRecord]
        var income: Double { records.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount } }
        var expense: Double { records.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount } }
    }

    private var calendar: Calendar { DateText.calendar }

    private var monthRecords: [LedgerRecord] {
        let start = month
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return allRecords.filter { $0.date >= start && $0.date < end }
    }

    private var dayGroups: [DayGroup] {
        let grouped = Dictionary(grouping: monthRecords) { calendar.startOfDay(for: $0.date) }
        return grouped
            .map { DayGroup(day: $0.key, records: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }

    private var isCurrentMonth: Bool {
        calendar.isDate(month, equalTo: Date(), toGranularity: .month)
    }

    var body: some View {
        let records = monthRecords
        let income = records.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }
        let expense = records.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }

        NavigationStack {
            List {
                Section {
                    SummaryCard(
                        month: month,
                        income: income,
                        expense: expense,
                        budget: BudgetService.effectiveMonthlyBudget(records: allRecords, month: month),
                        canGoNext: !isCurrentMonth,
                        onPrevious: { shiftMonth(-1) },
                        onNext: { shiftMonth(1) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if records.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "本月还没有记录",
                            systemImage: "tray",
                            description: Text("点右下角的 ＋ 记一笔，或在快捷指令中使用「识图记账」")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(dayGroups, id: \.day) { group in
                        Section {
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
                        } header: {
                            HStack {
                                Text(DateText.dayHeaderText(group.day))
                                Spacer()
                                if group.expense > 0 { Text("支 \(Money.format(group.expense))") }
                                if group.income > 0 { Text("收 \(Money.format(group.income))") }
                            }
                            .font(.caption)
                            .textCase(nil)
                        }
                    }
                }

                Color.clear.frame(height: 60).listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("简账")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SearchView()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
                if !isCurrentMonth {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("本月") {
                            withAnimation { month = calendar.startOfMonth(for: Date()) }
                        }
                    }
                }
            }
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
                .padding(.trailing, 22)
                .padding(.bottom, 20)
                .accessibilityLabel("记一笔")
            }
            .task {
                // 截图模式：直接打开记一笔 / 搜索
                if ScreenshotDemo.screen == "add" && editorTarget == nil { editorTarget = .new }
                if ScreenshotDemo.screen == "search" && !showDemoSearch { showDemoSearch = true }
                if ScreenshotDemo.screen == "delete" && pendingDelete == nil {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    pendingDelete = dayGroups.first?.records.first
                }
            }
            .navigationDestination(isPresented: $showDemoSearch) { SearchView() }
            .sheet(item: $editorTarget) { target in
                switch target {
                case .new:
                    RecordEditorView(record: nil, initialDate: isCurrentMonth ? Date() : month)
                case .edit(let record):
                    RecordEditorView(record: record)
                }
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
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func shiftMonth(_ delta: Int) {
        if let m = calendar.date(byAdding: .month, value: delta, to: month) {
            withAnimation(.snappy) { month = m }
        }
    }
}

/// 首页顶部的月度汇总卡片
struct SummaryCard: View {
    let month: Date
    let income: Double
    let expense: Double
    let budget: Double
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(action: onPrevious) {
                    Image(systemName: "chevron.left").padding(6)
                }
                Text(DateText.month.string(from: month))
                    .font(.headline)
                Button(action: onNext) {
                    Image(systemName: "chevron.right").padding(6)
                }
                .disabled(!canGoNext)
                .opacity(canGoNext ? 1 : 0.35)
                Spacer()
                Image(systemName: "book.closed.fill").opacity(0.6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 4) {
                Text("本月结余")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                Text(Money.format(income - expense))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            HStack {
                StatBlock(title: "支出", value: Money.format(expense), light: true)
                Spacer()
                StatBlock(title: "收入", value: Money.format(income), alignment: .trailing, light: true)
            }

            if budget > 0 {
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
