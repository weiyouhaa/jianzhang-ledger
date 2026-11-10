import SwiftUI
import SwiftData

/// 一行分类预算进度
struct BudgetLineRow: View {
    let line: BudgetLine
    var compact = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        let ratio = line.budget > 0 ? line.spent / line.budget : 0
        if theme.isReceipt {
            receiptBody(ratio)
        } else {
            defaultBody(ratio)
        }
    }

    /// 设计稿预算执行单：分类名 + 已用 / 预算（含百分比）一行，剩余 + 字符刻度一行，行间实线
    private func receiptBody(_ ratio: Double) -> some View {
        VStack(alignment: .leading, spacing: ReceiptStyle.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: ReceiptStyle.Space.xs) {
                Text(line.name)
                    .font(theme.serifTitleFont)
                    .foregroundStyle(theme.ink)
                Spacer(minLength: ReceiptStyle.Space.xs)
                Text("\(Money.format(line.spent)) / \(Money.format(line.budget))")
                    .font(theme.metaFont).monospacedDigit()
                    .foregroundStyle(theme.ink)
                Text("(\(Money.percent(ratio))%)")
                    .font(theme.metaFont).monospacedDigit()
                    .foregroundStyle(theme.faint)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            HStack(alignment: .firstTextBaseline, spacing: ReceiptStyle.Space.xs) {
                Text(line.isOver ? "超支 \(Money.format(line.spent - line.budget))" : "剩余 \(Money.format(line.remaining))")
                    .foregroundStyle(line.isOver ? theme.accent : theme.faint)
                Spacer(minLength: ReceiptStyle.Space.xs)
                Text(BudgetProgressView.tickBarPublic(ratio: ratio))
                    .foregroundStyle(theme.budgetColor(ratio))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .font(theme.metaFont).monospacedDigit()

            if line.carry != 0 {
                Text("含上月结转 \(line.carry > 0 ? "+" : "")\(Money.format(line.carry))")
                    .font(theme.metaFont)
                    .foregroundStyle(theme.faint)
            }
        }
        .padding(.vertical, ReceiptStyle.Space.xxs)
    }

    private func defaultBody(_ ratio: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                CategoryIcon(icon: line.icon, color: Color.skinTint(line.colorHex), size: compact ? 28 : 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.name).font(.ui(.subheadline).weight(.medium))
                    Text(line.isOver ? "超支 \(Money.format(line.spent - line.budget))" : "剩余 \(Money.format(line.remaining))")
                        .font(.ui(.caption))
                        .foregroundStyle(line.isOver ? Color.red : Color.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Money.percent(ratio))%")
                        .font(.ui(.subheadline).weight(.semibold).monospacedDigit())
                        .foregroundStyle(Self.color(ratio))
                    Text("\(Money.format(line.spent)) / \(Money.format(line.budget))")
                        .font(.ui(.caption2).monospacedDigit())
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
                    .font(.ui(.caption2))
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func color(_ ratio: Double) -> Color {
        if ratio > 1 { return .red }
        if ratio >= 0.8 { return .orange }
        return Color.themeIncome
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

        ThemedForm {
            if status.total != nil || status.yearly != nil {
                Section {
                    if let t = status.total {
                        BudgetLineRow(line: t).padding(.vertical, 4)
                        if !t.isOver && t.remaining > 0 {
                            let cal = DateText.calendar
                            let now = Date()
                            let totalDays = cal.range(of: .day, in: .month, for: now)?.count ?? 30
                            let todayDay = cal.component(.day, from: now)
                            let leftDays = max(1, totalDays - todayDay + 1)
                            HStack {
                                Label("本月剩余 \(leftDays) 天 · 日均可花", systemImage: "calendar.day.timeline.left")
                                    .font(.ui(.caption))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(Money.format(t.remaining / Double(leftDays)) + " / 天")
                                    .font(.ui(.caption).weight(.semibold).monospacedDigit())
                                    .foregroundStyle(Color.themeIncome)
                                    .contentTransition(.numericText())
                            }
                        }
                    }
                    if let y = status.yearly { BudgetLineRow(line: y).padding(.vertical, 4) }
                } header: { ThemedSectionHeader { Text("本期进度") } }
            }

            Section {
                amountField("每月总预算", text: $monthlyText) { monthly = $0 }
                if categorySum > 0 && abs(monthly - categorySum) > 0.01 {
                    Button {
                        ReceiptHaptics.success()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            monthly = categorySum
                            monthlyText = Money.plain(categorySum)
                        }
                    } label: {
                        Label("用分类预算合计设为月总预算（\(Money.format(categorySum))）", systemImage: "sum")
                            .font(.ui(.caption))
                    }
                }
                Toggle(isOn: $rollover) {
                    Label("结余结转到下月", systemImage: "arrow.uturn.forward")
                }
                amountField("年度总预算", text: $yearlyText) { yearly = $0 }
                if monthly > 0 && abs(yearly - monthly * 12) > 0.01 {
                    Button {
                        ReceiptHaptics.success()
                        let targetYearly = monthly * 12
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            yearly = targetYearly
                            yearlyText = Money.plain(targetYearly)
                        }
                    } label: {
                        Label("按月预算 × 12 设为年度总预算（\(Money.format(monthly * 12))）", systemImage: "multiply.circle")
                            .font(.ui(.caption))
                    }
                }
            } header: { ThemedSectionHeader {
                Text("总预算")
            } } footer: { ThemedSectionFooter {
                Text("开启结转后，上月剩余（或超支）会加到（或扣减）本月预算，只结转一个月（仅总预算）。"
                     + (categorySum > 0 ? "\n分类预算合计 \(Money.format(categorySum))。" : ""))
            } }

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
                                    .font(.ui(.caption))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.primary)
                }
            } header: { ThemedSectionHeader {
                Text("分类月预算")
            } } footer: { ThemedSectionFooter {
                Text("点分类设置预算。统计页会显示各分类的使用进度。")
            } }

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
            } footer: { ThemedSectionFooter {
                Text("记账、导入账单、快捷指令记账后检查；每个预算每月每档只提醒一次。")
            } }
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
    @Environment(\.appTheme) private var theme

    private var hasBudget: Bool { status.total != nil || !status.categories.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.isReceipt ? ReceiptStyle.Space.s : 12) {
            HStack(alignment: .center) {
                if theme.isReceipt {
                    Text("◎ 预算").font(theme.cardTitleFont).foregroundStyle(theme.ink)
                } else {
                    Label("预算", systemImage: "target").font(.ui(.headline))
                }
                Spacer(minLength: 8)
                if theme.isReceipt, let t = status.total, t.isOver {
                    VermilionStamp(text: "超支 \(Money.format(t.spent - t.budget))")
                }
                NavigationLink {
                    BudgetView()
                } label: {
                    HStack(spacing: 2) {
                        Text(hasBudget ? "设置" : "去设置")
                        Image(systemName: "chevron.right")
                    }
                    .font(theme.isReceipt ? theme.metaFont : .ui(.subheadline))
                    .foregroundStyle(theme.isReceipt ? theme.faint : Color.accentColor)
                }
                .accessibilityIdentifier("budget-manage")
            }
            if theme.isReceipt {
                ThemedDashedRule()
            }
            if let t = status.total {
                BudgetProgressView(spent: t.spent, budget: t.budget, title: t.carry == 0 ? "本月预算" : "本月预算（含结转）")
            }
            if !status.categories.isEmpty {
                if status.total != nil {
                    if theme.isReceipt { Rectangle().fill(theme.rule).frame(height: 1) } else { Divider() }
                }
                // 设计稿：每个分类之间一条 1pt 实线
                ForEach(Array(status.categories.enumerated()), id: \.element.id) { index, line in
                    if theme.isReceipt && index > 0 {
                        Rectangle().fill(theme.rule).frame(height: 1)
                    }
                    BudgetLineRow(line: line, compact: true)
                }
            }
            if !hasBudget {
                Text("还没有本月预算。设一笔每月总额，或给餐饮、购物等分类单独设限额，这里会按已花金额画出执行进度。")
                    .font(theme.isReceipt ? theme.metaFont : .ui(.subheadline))
                    .foregroundStyle(theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
