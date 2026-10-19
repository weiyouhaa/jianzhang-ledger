import SwiftUI
import SwiftData
import Charts

/// 账户详情：余额、额度、余额走势、相关记录
struct AccountDetailView: View {
    let account: LedgerAccount

    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerRecord.date, order: .reverse) private var records: [LedgerRecord]
    @AppStorage(SettingsKey.hideAmounts) private var hideAmounts = false

    @State private var showEditor = false
    @State private var showAdjust = false
    @State private var newRecordKind: RecordKind?
    @State private var editingRecord: LedgerRecord?

    struct BalancePoint: Identifiable {
        let index: Int
        let date: Date
        let value: Double
        var id: Int { index }
    }

    var body: some View {
        let _ = records.count   // 记录变化时刷新余额
        let entries = account.allEntries.sorted { $0.date > $1.date }
        let balance = account.balance()
        let points = balanceTrend(entries)

        List {
            Section {
                header(balance: balance)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                HStack(spacing: 10) {
                    if account.type.isSocialSecurity {
                        actionButton("缴存", icon: "tray.and.arrow.down") { newRecordKind = .contribution }
                        actionButton(account.type == .housingFund ? "提取" : "转出", icon: "arrow.up.forward.square") {
                            newRecordKind = .transfer
                        }
                    } else {
                        actionButton("记一笔", icon: "square.and.pencil") { newRecordKind = .expense }
                        actionButton(account.type.isLiability ? "还款" : "转账", icon: "arrow.left.arrow.right") {
                            newRecordKind = .transfer
                        }
                    }
                    actionButton("余额校准", icon: "scope") { showAdjust = true }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            }

            if points.count > 1 {
                Section(account.type.isLiability ? "欠款走势" : "余额走势") {
                    trendChart(points)
                        .frame(height: 160)
                        .padding(.vertical, 6)
                }
            }

            Section {
                if entries.isEmpty {
                    Text("还没有关联到这个账户的记录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { r in
                        Button { editingRecord = r } label: {
                            RecordRow(record: r, showDate: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text(account.type.isSocialSecurity ? "缴存与提取（\(entries.count)）" : "收支与转账（\(entries.count)）")
            }

            if !account.note.isEmpty {
                Section("备注") { Text(account.note) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { showEditor = true }
            }
        }
        .sheet(isPresented: $showEditor) {
            AccountEditorView(account: account, nextSortOrder: account.sortOrder)
        }
        .sheet(isPresented: $showAdjust) {
            BalanceAdjustView(account: account)
                .presentationDetents([.medium])
        }
        .sheet(item: $newRecordKind) { kind in
            RecordEditorView(record: nil, initialKind: kind, presetAccountID: account.id)
        }
        .sheet(item: $editingRecord) { r in
            RecordEditorView(record: r)
        }
    }

    // MARK: - 头部

    @ViewBuilder
    private func header(balance: Double) -> some View {
        let liability = account.type.isLiability
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                CategoryIcon(icon: account.iconName, color: .white, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.type.title).font(.subheadline.weight(.semibold))
                    if !account.includeInNetWorth {
                        Text("不计入净资产").font(.caption2).opacity(0.8)
                    }
                }
                Spacer()
                if account.isArchived {
                    Text("已归档").font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.2)))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(liability ? (balance <= 0 ? "当前欠款" : "溢缴款") : "当前余额")
                    .font(.caption).opacity(0.85)
                Text(Money.masked(liability ? abs(balance) : balance, hidden: hideAmounts))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            if account.type.hasCreditLimit, account.creditLimit > 0 {
                let used = max(0, -balance)
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(Color.white)
                                .frame(width: geo.size.width * min(max(used / account.creditLimit, 0), 1))
                        }
                    }
                    .frame(height: 6)
                    HStack {
                        StatBlock(title: "已用额度", value: Money.masked(used, hidden: hideAmounts), light: true)
                        Spacer()
                        StatBlock(title: "可用额度", value: Money.masked(max(0, account.creditLimit - used), hidden: hideAmounts), light: true)
                        Spacer()
                        StatBlock(title: "总额度", value: Money.masked(account.creditLimit, hidden: hideAmounts),
                                  alignment: .trailing, light: true)
                    }
                }
            }
            if account.type.isSocialSecurity, let rule = RecurringEngine.contributionRule(for: account, in: context), !rule.isPaused {
                Label("每月 \(rule.monthDay) 日缴存 \(Money.masked(rule.amount, hidden: hideAmounts))", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
            }
            if account.billingDay > 0 || account.repaymentDay > 0 {
                HStack(spacing: 14) {
                    if account.billingDay > 0 {
                        Label("账单日 每月\(account.billingDay)日", systemImage: "doc.text")
                    }
                    if account.repaymentDay > 0 {
                        Label("还款日 每月\(account.repaymentDay)日", systemImage: "calendar")
                    }
                    Spacer()
                    if let days = account.daysUntilRepayment() {
                        Text(days == 0 ? "今天还款" : "\(days) 天后还款")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(days <= 3 ? 0.35 : 0.2)))
                    }
                }
                .font(.caption)
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [account.color, account.color.opacity(0.7)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .padding(.vertical, 4)
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(account.color)
    }

    // MARK: - 走势

    /// 每笔记录后的余额（负债显示为欠款）
    private func balanceTrend(_ entriesDesc: [LedgerRecord]) -> [BalancePoint] {
        let asc = entriesDesc.reversed()
        guard let first = asc.first else { return [] }
        let sign: Double = account.type.isLiability ? -1 : 1
        var running = account.initialBalance
        var points = [BalancePoint(index: 0, date: min(account.createdAt, first.date).addingTimeInterval(-3600), value: running * sign)]
        for (i, r) in asc.enumerated() {
            running += r.effect(on: account)
            points.append(BalancePoint(index: i + 1, date: r.date, value: (running * 100).rounded() / 100 * sign))
        }
        return Array(points.suffix(120))
    }

    private func trendChart(_ points: [BalancePoint]) -> some View {
        Chart(points) { p in
            AreaMark(x: .value("时间", p.date), y: .value("余额", p.value))
                .foregroundStyle(LinearGradient(colors: [account.color.opacity(0.3), account.color.opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.stepEnd)
            LineMark(x: .value("时间", p.date), y: .value("余额", p.value))
                .foregroundStyle(account.color)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.stepEnd)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(hideAmounts ? "**" : Money.compact(v))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
            }
        }
    }
}

/// 余额校准：输入实际余额，生成一笔不计入统计的校准记录
struct BalanceAdjustView: View {
    let account: LedgerAccount

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var valueText = ""
    @State private var note = ""
    @FocusState private var focused: Bool

    var body: some View {
        let liability = account.type.isLiability
        let current = account.balance()
        let shown = liability ? -current : current
        let target = Money.parse(valueText)
        let delta: Double? = target.map { ((liability ? -$0 : $0) - current) }

        NavigationStack {
            Form {
                Section {
                    LabeledContent(liability ? "账面欠款" : "账面余额", value: Money.format(shown))
                    HStack {
                        Text(liability ? "实际欠款" : "实际余额")
                        TextField(Money.format(shown), text: $valueText)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                            .focused($focused)
                    }
                    TextField("备注（可选）", text: $note)
                } footer: {
                    if let delta, abs(delta) >= 0.005 {
                        Text("将生成一笔 \(delta > 0 ? "+" : "")\(Money.format(delta)) 的「余额校准」记录，不计入收支统计和预算。")
                    } else {
                        Text("输入银行 App / 支付宝等显示的真实\(liability ? "欠款" : "余额")，差额会记为一笔校准，不影响收支统计。")
                    }
                }
            }
            .navigationTitle("余额校准")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("校准") { save(delta: delta ?? 0) }
                        .disabled(delta == nil || abs(delta ?? 0) < 0.005)
                }
            }
            .onAppear { focused = true }
        }
    }

    private func save(delta: Double) {
        let r = LedgerRecord(amount: (delta * 100).rounded() / 100, kind: .adjustment, category: nil,
                             note: note.isEmpty ? "余额校准" : note, merchant: "", account: account.name,
                             date: Date(), source: "manual")
        r.accountRef = account
        context.insert(r)
        try? context.save()
        dismiss()
    }
}
