import SwiftUI
import SwiftData

/// 一行分类预算进度
struct BudgetLineRow: View {
    let line: BudgetLine
    var compact = false

    var body: some View {
        let ratio = line.budget > 0 ? line.spent / line.budget : 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                CategoryIcon(icon: line.icon, color: Color(hex: line.colorHex), size: compact ? 28 : 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.name).font(.subheadline.weight(.medium))
                    Text(line.isOver ? "超支 \(Money.format(line.spent - line.budget))" : "剩余 \(Money.format(line.remaining))")
                        .font(.caption)
                        .foregroundStyle(line.isOver ? Color.red : Color.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int((ratio * 100).rounded()))%")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Self.color(ratio))
                    Text("\(Money.format(line.spent)) / \(Money.format(line.budget))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Self.color(ratio))
                        .frame(width: geo.size.width * min(max(ratio, 0), 1))
                }
            }
            .frame(height: 6)
            if line.carry != 0 {
                Text("含上月结转 \(line.carry > 0 ? "+" : "")\(Money.format(line.carry))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func color(_ ratio: Double) -> Color {
        if ratio > 1 { return .red }
        if ratio >= 0.8 { return .orange }
        return .green
    }
}

/// 预算设置：总预算（结转）、年度预算、分类预算、提醒
struct BudgetView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerRecord.date, order: .reverse) private var records: [LedgerRecord]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]

    @AppStorage(SettingsKey.monthlyBudget) private var monthly: Double = 0
    @AppStorage(BudgetKey.yearly) private var yearly: Double = 0
    @AppStorage(BudgetKey.rollover) private var rollover = false
    @AppStorage(BudgetKey.alertsEnabled) private var alertsEnabled = false
    @AppStorage(BudgetKey.warnPercent) private var warnPercent = 80
    @AppStorage(BudgetKey.alertOver) private var alertOver = true
    @Environment(\.ledgerPrefs) private var prefs

    @State private var monthlyText = ""
    @State private var yearlyText = ""
    @State private var editing: LedgerCategory?
    @State private var editText = ""
    @State private var permissionDenied = false
    @FocusState private var focused: Bool

    private var expenseCategories: [LedgerCategory] { categories.filter { $0.kind == .expense } }

    var body: some View {
        let status = BudgetService.status(records: records, categories: categories, month: Date(), prefs: prefs)
        let spentByCategory = Dictionary(grouping: records.filter {
            $0.kind == .expense && DateText.calendar.isDate($0.date, equalTo: Date(), toGranularity: .month)
        }, by: { $0.category?.id }).mapValues { $0.reduce(0) { $0 + $1.amount } }
        let categorySum = expenseCategories.reduce(0) { $0 + $1.monthlyBudget }

        Form {
            if status.total != nil || status.yearly != nil {
                Section("本期进度") {
                    if let t = status.total { BudgetLineRow(line: t).padding(.vertical, 4) }
                    if let y = status.yearly { BudgetLineRow(line: y).padding(.vertical, 4) }
                }
            }

            Section {
                amountField("每月总预算", text: $monthlyText) { monthly = $0 }
                Toggle(isOn: $rollover) {
                    Label("结余结转到下月", systemImage: "arrow.uturn.forward")
                }
                amountField("年度总预算", text: $yearlyText) { yearly = $0 }
            } header: {
                Text("总预算")
            } footer: {
                Text("开启结转后，上月剩余（或超支）会加到（或扣减）本月预算，只结转一个月（仅总预算）。"
                     + (categorySum > 0 ? "\n分类预算合计 \(Money.format(categorySum))。" : ""))
            }

            Section {
                ForEach(expenseCategories) { c in
                    Button {
                        editText = c.monthlyBudget > 0 ? Money.plain(c.monthlyBudget) : ""
                        editing = c
                    } label: {
                        if let line = status.categories.first(where: { $0.id == c.id.uuidString }) {
                            BudgetLineRow(line: line, compact: true).padding(.vertical, 2)
                        } else {
                            HStack(spacing: 10) {
                                CategoryIcon(icon: c.icon, color: c.color, size: 28)
                                Text(c.name)
                                Spacer()
                                Text("本月 \(Money.format(spentByCategory[c.id] ?? 0)) · 未设置")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.primary)
                }
            } header: {
                Text("分类月预算")
            } footer: {
                Text("点分类设置预算。统计页会显示各分类的使用进度。")
            }

            Section {
                Toggle(isOn: $alertsEnabled) {
                    Label("预算提醒", systemImage: "bell.badge.fill")
                }
                if alertsEnabled {
                    Picker("提前提醒", selection: $warnPercent) {
                        ForEach([50, 60, 70, 80, 90], id: \.self) { Text("用到 \($0)%").tag($0) }
                    }
                    Toggle("超支时提醒", isOn: $alertOver)
                }
            } footer: {
                Text("记账、导入账单、快捷指令记账后检查；每个预算每月每档只提醒一次。")
            }
        }
        .navigationTitle("预算")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            monthlyText = monthly > 0 ? Money.plain(monthly) : ""
            yearlyText = yearly > 0 ? Money.plain(yearly) : ""
        }
        .onChange(of: alertsEnabled) { _, on in
            guard on else { return }
            Task { @MainActor in
                if await NotificationManager.shared.requestAuthorization() {
                    BudgetMonitor.check(in: context)
                } else {
                    alertsEnabled = false
                    permissionDenied = true
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focused = false }
            }
        }
        // 列表级操作用 alert（iOS 26 不会锚定到屏幕顶部）
        .alert(editing.map { "「\($0.name)」月预算" } ?? "", isPresented: editingBinding, presenting: editing) { c in
            TextField("金额，留空表示不设置", text: $editText)
                .keyboardType(.decimalPad)
            Button("保存") {
                c.monthlyBudget = max(0, Money.parse(editText) ?? 0)
                try? context.save()
                BudgetMonitor.check(in: context)
            }
            if c.monthlyBudget > 0 {
                Button("清除预算", role: .destructive) {
                    c.monthlyBudget = 0
                    try? context.save()
                }
            }
            Button("取消", role: .cancel) {}
        } message: { c in
            Text("本月已花 \(Money.format(spentByCategory[c.id] ?? 0))")
        }
        .alert("无法发送通知", isPresented: $permissionDenied) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请在系统「设置 › 通知 › 简账」中允许通知。")
        }
    }

    private var editingBinding: Binding<Bool> {
        Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })
    }

    private func amountField(_ title: String, text: Binding<String>, onChange: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("未设置", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .frame(maxWidth: 140)
                .onChange(of: text.wrappedValue) { _, v in onChange(max(0, Money.parse(v) ?? 0)) }
        }
    }
}

/// 统计页：本月预算 + 分类预算进度
struct BudgetStatsCard: View {
    let status: BudgetStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("预算", systemImage: "target").font(.headline)
                Spacer()
                NavigationLink {
                    BudgetView()
                } label: {
                    HStack(spacing: 2) {
                        Text("管理")
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline)
                }
            }
            if let t = status.total {
                BudgetProgressView(spent: t.spent, budget: t.budget, title: t.carry == 0 ? "本月预算" : "本月预算（含结转）")
            }
            if !status.categories.isEmpty {
                if status.total != nil { Divider() }
                ForEach(status.categories) { line in
                    BudgetLineRow(line: line, compact: true)
                }
            }
        }
    }
}
