import SwiftUI
import SwiftData

/// 搜索与筛选
struct SearchView: View {
    @Query(sort: \LedgerRecord.date, order: .reverse) private var records: [LedgerRecord]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]

    @State private var text = ""
    @State private var kindFilter = 0          // 0 全部 1 支出 2 收入
    @State private var categoryID: UUID?
    @State private var useDateRange = false
    @State private var fromDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var toDate = Date()
    @State private var minAmountText = ""
    @State private var maxAmountText = ""
    @State private var editing: LedgerRecord?
    @AppStorage(RepaymentSetting.key) private var repaymentAsExpense = false

    private var filtered: [LedgerRecord] {
        let q = text.trimmingCharacters(in: .whitespaces)
        let minAmount = Money.parse(minAmountText)
        let maxAmount = Money.parse(maxAmountText)
        let cal = Calendar.current
        let start = cal.startOfDay(for: fromDate)
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: toDate)) ?? toDate

        return records.filter { r in
            // 余额校准不进搜索列表，只在账户明细 / 变动日志可见（2.0 (13)）
            if r.kind == .adjustment { return false }
            if kindFilter == 1 && !r.countsAsExpense(includeRepayment: repaymentAsExpense) { return false }
            if kindFilter == 2 && r.kind != .income { return false }
            if kindFilter == 3 && r.statsKind(includeRepayment: repaymentAsExpense) != nil { return false }
            if let categoryID, r.category?.id != categoryID { return false }
            if useDateRange && (r.date < start || r.date >= end) { return false }
            if let minAmount, r.amount < minAmount { return false }
            if let maxAmount, r.amount > maxAmount { return false }
            if !q.isEmpty {
                let amountString = String(format: "%.2f", r.amount)
                let hit = r.note.localizedCaseInsensitiveContains(q)
                    || r.merchant.localizedCaseInsensitiveContains(q)
                    || r.categoryName.localizedCaseInsensitiveContains(q)
                    || r.accountName.localizedCaseInsensitiveContains(q)
                    || (r.toAccount?.name.localizedCaseInsensitiveContains(q) ?? false)
                    || amountString.contains(q)
                if !hit { return false }
            }
            return true
        }
    }

    private var visibleCategories: [LedgerCategory] {
        switch kindFilter {
        case 1: return categories.filter { $0.kind == .expense }
        case 2: return categories.filter { $0.kind == .income }
        case 3: return []
        default: return categories
        }
    }

    var body: some View {
        let results = filtered
        let expense = results.filter { $0.countsAsExpense(includeRepayment: repaymentAsExpense) }.reduce(0) { $0 + $1.amount }
        let income = results.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }

        List {
            Section {
                Picker("类型", selection: $kindFilter) {
                    Text("全部").tag(0)
                    Text("支出").tag(1)
                    Text("收入").tag(2)
                    Text("转账").tag(3)
                }
                .pickerStyle(.segmented)

                Picker("分类", selection: $categoryID) {
                    Text("全部分类").tag(UUID?.none)
                    ForEach(visibleCategories) { c in
                        Label(c.name, systemImage: c.icon).tag(UUID?.some(c.id))
                    }
                }

                Toggle("按日期筛选", isOn: $useDateRange.animation())
                if useDateRange {
                    DatePicker("开始", selection: $fromDate, displayedComponents: .date)
                    DatePicker("结束", selection: $toDate, in: fromDate..., displayedComponents: .date)
                }

                HStack {
                    Text("金额")
                    TextField("最小", text: $minAmountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                    Text("—").foregroundStyle(.secondary)
                    TextField("最大", text: $maxAmountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                }
            } header: {
                Text("筛选")
            } footer: {
                // 2.0 (16)：明细页默认只显示本月，搜索不受影响
                Text(useDateRange ? "只搜索所选日期内的记录。" : "搜索全部日期的记录，不受明细页日期范围的影响。")
            }

            Section {
                if results.isEmpty {
                    ContentUnavailableView.search(text: text)
                } else {
                    ForEach(results) { r in
                        RecordRow(record: r, showDate: true)
                            .onTapGesture { editing = r }
                    }
                }
            } header: {
                Text("共 \(results.count) 笔 · 支出 \(Money.format(expense)) · 收入 \(Money.format(income))")
                    .textCase(nil)
            }
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索备注、商户、分类、金额")
        .onChange(of: kindFilter) { _, _ in
            if let id = categoryID, !visibleCategories.contains(where: { $0.id == id }) {
                categoryID = nil
            }
        }
        .sheet(item: $editing) { r in
            RecordEditorView(record: r)
        }
    }
}
