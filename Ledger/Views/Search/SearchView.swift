import SwiftUI
import SwiftData

/// 搜索与筛选
struct SearchView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerRecord.date, order: .reverse) private var records: [LedgerRecord]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \LedgerAccount.sortOrder) private var accounts: [LedgerAccount]

    @State private var text = ""
    @State private var kindFilter = 0          // 0 全部 1 支出 2 收入 3 转账
    @State private var categoryID: UUID?
    @State private var accountID: UUID?
    @State private var sourceFilter: SourceFilter = .all
    @State private var useDateRange = false
    @State private var fromDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var toDate = Date()
    @State private var minAmountText = ""
    @State private var maxAmountText = ""
    @State private var editing: LedgerRecord?
    @State private var stubRecord: LedgerRecord?
    @State private var pendingDeleteAfterStub: LedgerRecord?
    @State private var prefillTarget: RecordPrefill?
    @State private var pendingDelete: LedgerRecord?
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showBatchDeleteConfirm = false
    @State private var showAdvancedFilters = false
    @Environment(\.appTheme) private var theme
    @AppStorage(RepaymentSetting.key) private var repaymentAsExpense = false
    @AppStorage("search.sortOption") private var sortOptionRaw = SortOption.dateDesc.rawValue

    enum SortOption: String, CaseIterable, Identifiable {
        case dateDesc = "时间倒序"
        case dateAsc = "时间正序"
        case amountDesc = "金额倒序"
        case amountAsc = "金额正序"

        var id: String { rawValue }
        var title: String { rawValue }
        var icon: String {
            switch self {
            case .dateDesc: return "arrow.down"
            case .dateAsc: return "arrow.up"
            case .amountDesc: return "yensign.circle"
            case .amountAsc: return "yensign.circle.fill"
            }
        }
    }

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all = "全部来源"
        case ocr = "截屏识图"
        case shortcut = "快捷指令"
        case manual = "手工记账"
        case imported = "账单导入"
        case recurring = "周期账单"

        var id: String { rawValue }
        var title: String { rawValue }

        func matches(_ r: LedgerRecord) -> Bool {
            switch self {
            case .all: return true
            case .ocr: return r.source == "ocr"
            case .shortcut: return r.source == "shortcut"
            case .manual: return r.source == "manual" && r.importBatchID.isEmpty && r.recurringKey.isEmpty
            case .imported: return r.source == "import" || !r.importBatchID.isEmpty
            case .recurring: return r.source == "recurring" || !r.recurringKey.isEmpty
            }
        }
    }

    private var sortOption: SortOption {
        get { SortOption(rawValue: sortOptionRaw) ?? .dateDesc }
        nonmutating set { sortOptionRaw = newValue.rawValue }
    }

    private var sortOptionBinding: Binding<SortOption> {
        Binding(get: { sortOption }, set: { sortOption = $0 })
    }

    private var hasActiveFilters: Bool {
        kindFilter != 0 || categoryID != nil || accountID != nil || sourceFilter != .all
            || useDateRange || !minAmountText.isEmpty || !maxAmountText.isEmpty
    }

    private var activeAdvancedFilterCount: Int {
        var n = 0
        if categoryID != nil { n += 1 }
        if accountID != nil { n += 1 }
        if sourceFilter != .all { n += 1 }
        if useDateRange { n += 1 }
        if !minAmountText.isEmpty || !maxAmountText.isEmpty { n += 1 }
        return n
    }

    private func resetFilters() {
        withAnimation(.snappy) {
            kindFilter = 0
            categoryID = nil
            accountID = nil
            sourceFilter = .all
            useDateRange = false
            minAmountText = ""
            maxAmountText = ""
        }
    }

    private var filtered: [LedgerRecord] {
        let q = text.trimmingCharacters(in: .whitespaces)
        let minAmount = Money.parse(minAmountText)
        let maxAmount = Money.parse(maxAmountText)
        let cal = Calendar.current
        let start = cal.startOfDay(for: fromDate)
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: toDate)) ?? toDate
        let selectedAccountName = accountID.flatMap { id in accounts.first(where: { $0.id == id })?.name }

        let list = records.filter { r in
            // 余额校准不进搜索列表，只在账户明细 / 变动日志可见（2.0 (13)）
            if r.kind == .adjustment { return false }
            if kindFilter == 1 && !r.countsAsExpense(includeRepayment: repaymentAsExpense) { return false }
            if kindFilter == 2 && r.kind != .income { return false }
            if kindFilter == 3 && r.statsKind(includeRepayment: repaymentAsExpense) != nil { return false }
            if let categoryID, r.category?.id != categoryID { return false }
            if let accountID {
                let hitAccount = r.accountRef?.id == accountID
                    || r.toAccount?.id == accountID
                    || (r.accountRef == nil && selectedAccountName != nil && r.account == selectedAccountName)
                if !hitAccount { return false }
            }
            if !sourceFilter.matches(r) { return false }
            if useDateRange && (r.date < start || r.date >= end) { return false }
            if let minAmount, r.amount < minAmount { return false }
            if let maxAmount, r.amount > maxAmount { return false }
            if !q.isEmpty {
                let amountString = String(format: "%.2f", r.amount)
                let formattedAmount = Money.format(r.amount)
                let hit = r.note.localizedCaseInsensitiveContains(q)
                    || r.merchant.localizedCaseInsensitiveContains(q)
                    || r.categoryName.localizedCaseInsensitiveContains(q)
                    || r.accountName.localizedCaseInsensitiveContains(q)
                    || (r.toAccount?.name.localizedCaseInsensitiveContains(q) ?? false)
                    || amountString.contains(q)
                    || formattedAmount.localizedCaseInsensitiveContains(q)
                if !hit { return false }
            }
            return true
        }

        switch sortOption {
        case .dateDesc:
            return list.sorted { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }
        case .dateAsc:
            return list.sorted { ($0.date, $0.createdAt) < ($1.date, $1.createdAt) }
        case .amountDesc:
            return list.sorted {
                if $0.amount != $1.amount {
                    return $0.amount > $1.amount
                }
                return $0.date > $1.date
            }
        case .amountAsc:
            return list.sorted {
                if $0.amount != $1.amount {
                    return $0.amount < $1.amount
                }
                return $0.date < $1.date
            }
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

    private var selectableAccounts: [LedgerAccount] {
        accounts.filter { !$0.isArchived || $0.id == accountID }
    }

    var body: some View {
        let results = filtered
        let expense = results.filter { $0.countsAsExpense(includeRepayment: repaymentAsExpense) }.reduce(0) { $0 + $1.amount }
        let income = results.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }

        ThemedList {
            Section {
                Picker("类型", selection: $kindFilter) {
                    Text("全部").tag(0)
                    Text("支出").tag(1)
                    Text("收入").tag(2)
                    Text("转账").tag(3)
                }
                .pickerStyle(.segmented)

                Button {
                    ReceiptHaptics.selection()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                        showAdvancedFilters.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Label("高级筛选（分类 / 账户 / 来源 / 日期 / 金额）", systemImage: "slider.horizontal.3")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        if activeAdvancedFilterCount > 0 {
                            Text("已设 \(activeAdvancedFilterCount) 项")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.themeAccent)
                                .contentTransition(.numericText())
                        }
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees((showAdvancedFilters || activeAdvancedFilterCount > 0) ? 180 : 0))
                            .animation(.snappy(duration: 0.22), value: showAdvancedFilters || activeAdvancedFilterCount > 0)
                    }
                }
                .accessibilityIdentifier("search-advanced-toggle")

                if showAdvancedFilters || activeAdvancedFilterCount > 0 {
                    if kindFilter != 3 {
                        Picker("分类", selection: $categoryID) {
                            Text("全部分类").tag(UUID?.none)
                            ForEach(visibleCategories) { c in
                                Label(c.name, systemImage: c.icon).tag(UUID?.some(c.id))
                            }
                        }
                    }

                    Picker("账户", selection: $accountID) {
                        Text("全部账户").tag(UUID?.none)
                        ForEach(selectableAccounts) { a in
                            Label(a.name, systemImage: a.iconName).tag(UUID?.some(a.id))
                        }
                    }

                    Picker("来源", selection: $sourceFilter) {
                        ForEach(SourceFilter.allCases) { s in
                            Text(s.title).tag(s)
                        }
                    }

                    Picker("排序", selection: sortOptionBinding) {
                        ForEach(SortOption.allCases) { opt in
                            Label(opt.title, systemImage: opt.icon).tag(opt)
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
                }

                if hasActiveFilters {
                    Button(role: .destructive) {
                        resetFilters()
                    } label: {
                        HStack {
                            Spacer()
                            Label("重置筛选条件", systemImage: "arrow.counterclockwise")
                            Spacer()
                        }
                    }
                }
            } header: { ThemedSectionHeader {
                Text("筛选")
            } } footer: { ThemedSectionFooter {
                // 2.0 (16)：明细页默认只显示本月，搜索不受影响
                Text(useDateRange ? "只搜索所选日期内的记录。" : "搜索全部日期的记录，不受明细页日期范围的影响。")
            } }

            Section {
                if !results.isEmpty {
                    let net = income - expense
                    let netText = (net >= 0 ? "+" : "-") + Money.format(abs(net))
                    HStack(spacing: 8) {
                        Text("共 \(results.count) 笔")
                            .fontWeight(.semibold)
                        Spacer()
                        if expense > 0 {
                            Text("支出 \(Money.format(expense))")
                        }
                        if income > 0 {
                            Text("收入 \(Money.format(income))")
                                .foregroundStyle(Color.themeIncome)
                        }
                        Text("净额 \(netText)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption.monospacedDigit())
                    .contentTransition(.numericText())
                }
                if results.isEmpty {
                    ContentUnavailableView.search(text: text)
                } else {
                    ForEach(results) { r in
                        let isSelected = selectedIDs.contains(r.id)
                        Button {
                            if isSelecting {
                                toggleSelection(r.id)
                            } else if theme.isReceipt {
                                stubRecord = r
                            } else {
                                editing = r
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if isSelecting {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 19, weight: .medium))
                                        .foregroundStyle(isSelected ? Color.themeAccent : .secondary)
                                }
                                RecordRow(record: r, showDate: true)
                            }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("record-row")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !isSelecting {
                                Button(role: .destructive) {
                                    pendingDelete = r
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    editing = r
                                } label: {
                                    Label("修改", systemImage: "pencil")
                                }
                                .tint(.blue)
                                Button {
                                    prefillTarget = RecordPrefill.duplicate(from: r, date: Date())
                                } label: {
                                    Label("再来一笔", systemImage: "plus.square.on.square")
                                }
                                .tint(.orange)
                            }
                        }
                        .contextMenu {
                            if theme.isReceipt {
                                Button {
                                    stubRecord = r
                                } label: {
                                    Label("查看凭条存根", systemImage: "doc.text.magnifyingglass")
                                }
                            }
                            Button {
                                editing = r
                            } label: {
                                Label("修改记录", systemImage: "pencil")
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
                            Button {
                                withAnimation(.snappy) {
                                    isSelecting = true
                                    selectedIDs.insert(r.id)
                                }
                            } label: {
                                Label("多选批量管理", systemImage: "checkmark.circle")
                            }
                            Button(role: .destructive) {
                                pendingDelete = r
                            } label: {
                                Label("删除记录", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: { ThemedSectionHeader {
                HStack {
                    Text("共 \(results.count) 笔 · 支出 \(Money.format(expense)) · 收入 \(Money.format(income))")
                        .textCase(nil)
                    Spacer(minLength: 4)
                    if isSelecting && !results.isEmpty {
                        let allSelected = results.allSatisfy { selectedIDs.contains($0.id) }
                        Button(allSelected ? "取消全选" : "全选") {
                            withAnimation(.snappy) {
                                if allSelected {
                                    selectedIDs.removeAll()
                                } else {
                                    selectedIDs = Set(results.map(\.id))
                                }
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                    } else {
                        Menu {
                            Picker("排序方式", selection: sortOptionBinding) {
                                ForEach(SortOption.allCases) { opt in
                                    Label(opt.title, systemImage: opt.icon).tag(opt)
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up.arrow.down")
                                Text(sortOption.title)
                            }
                            .font(.caption)
                            .foregroundStyle(.tint)
                        }
                        .textCase(nil)
                    }
                }
            } }
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                batchActionBar(results: results)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !results.isEmpty || isSelecting {
                    Button(isSelecting ? "完成" : "批量") {
                        withAnimation(.snappy) {
                            isSelecting.toggle()
                            if !isSelecting { selectedIDs.removeAll() }
                        }
                    }
                    .accessibilityIdentifier("search-batch-toggle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序方式", selection: sortOptionBinding) {
                        ForEach(SortOption.allCases) { opt in
                            Label(opt.title, systemImage: opt.icon).tag(opt)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("排序方式")
                .accessibilityIdentifier("search-sort-menu")
            }
        }
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索商户、备注、分类、账户、金额")
        .onChange(of: kindFilter) { _, _ in
            if let id = categoryID, !visibleCategories.contains(where: { $0.id == id }) {
                categoryID = nil
            }
        }
        .sheet(item: $editing) { r in
            RecordEditorView(record: r)
        }
        .sheet(item: $stubRecord, onDismiss: {
            if let d = pendingDeleteAfterStub {
                pendingDeleteAfterStub = nil
                pendingDelete = d
            }
        }) { r in
            ReceiptStubSheet(record: r, onDelete: { pendingDeleteAfterStub = r })
        }
        .sheet(item: $prefillTarget) { p in
            RecordEditorView(record: nil, initialDate: p.date, initialKind: p.kind, prefill: p)
        }
        .alert("确认删除这笔记录？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { r in
            Button("删除", role: .destructive) {
                context.delete(r)
                try? context.save()
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { r in
            Text(r.deleteSummary)
        }
        .alert("确认批量删除已选的 \(selectedIDs.count) 笔记录？", isPresented: $showBatchDeleteConfirm) {
            Button("删除 \(selectedIDs.count) 笔", role: .destructive) {
                batchDelete(in: results)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复。")
        }
    }

    private func toggleSelection(_ id: UUID) {
        UISelectionFeedbackGenerator().selectionChanged()
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func selectedRecords(in results: [LedgerRecord]) -> [LedgerRecord] {
        results.filter { selectedIDs.contains($0.id) }
    }

    private func batchUpdateCategory(_ category: LedgerCategory, in results: [LedgerRecord]) {
        let targets = selectedRecords(in: results).filter { $0.kind == category.kind }
        guard !targets.isEmpty else { return }
        for r in targets {
            r.category = category
        }
        try? context.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.snappy) {
            selectedIDs.removeAll()
            isSelecting = false
        }
    }

    private func batchUpdateAccount(_ account: LedgerAccount, in results: [LedgerRecord]) {
        let targets = selectedRecords(in: results)
        guard !targets.isEmpty else { return }
        for r in targets {
            if r.kind == .transfer && r.toAccount?.id == account.id { continue }
            r.accountRef = account
            r.account = account.name
        }
        try? context.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.snappy) {
            selectedIDs.removeAll()
            isSelecting = false
        }
    }

    private func batchDelete(in results: [LedgerRecord]) {
        let targets = selectedRecords(in: results)
        guard !targets.isEmpty else { return }
        for r in targets {
            context.delete(r)
        }
        try? context.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.snappy) {
            selectedIDs.removeAll()
            isSelecting = false
        }
    }

    @ViewBuilder
    private func batchActionBar(results: [LedgerRecord]) -> some View {
        let selected = selectedRecords(in: results)
        HStack(spacing: 12) {
            Text("已选 \(selected.count) 笔")
                .font(theme.isReceipt ? theme.metaFont.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(theme.isReceipt ? theme.ink : .primary)

            Spacer()

            Menu {
                Section("改为支出分类") {
                    ForEach(categories.filter { $0.kind == .expense }) { c in
                        Button {
                            batchUpdateCategory(c, in: results)
                        } label: {
                            Label(c.name, systemImage: c.icon)
                        }
                    }
                }
                Section("改为收入分类") {
                    ForEach(categories.filter { $0.kind == .income }) { c in
                        Button {
                            batchUpdateCategory(c, in: results)
                        } label: {
                            Label(c.name, systemImage: c.icon)
                        }
                    }
                }
            } label: {
                Label("改分类", systemImage: "folder")
                    .font(theme.isReceipt ? theme.labelFont.weight(.semibold) : .caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.themeCard))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.rule, lineWidth: 1))
            }
            .disabled(selected.isEmpty)

            Menu {
                ForEach(selectableAccounts) { a in
                    Button {
                        batchUpdateAccount(a, in: results)
                    } label: {
                        Label(a.name, systemImage: a.iconName)
                    }
                }
            } label: {
                Label("改账户", systemImage: "creditcard")
                    .font(theme.isReceipt ? theme.labelFont.weight(.semibold) : .caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.themeCard))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.rule, lineWidth: 1))
            }
            .disabled(selected.isEmpty)

            Button(role: .destructive) {
                showBatchDeleteConfirm = true
            } label: {
                Label("删除", systemImage: "trash")
                    .font(theme.isReceipt ? theme.labelFont.weight(.semibold) : .caption.weight(.semibold))
                    .foregroundStyle(selected.isEmpty ? Color.secondary : Color.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.themeCard))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.red.opacity(selected.isEmpty ? 0.2 : 0.45), lineWidth: 1))
            }
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
