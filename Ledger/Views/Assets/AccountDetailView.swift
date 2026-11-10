import SwiftUI
import SwiftData
import Charts

/// 账户详情：余额、额度、余额走势、相关记录
struct AccountDetailView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let account: LedgerAccount

    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerRecord.date, order: .reverse) private var records: [LedgerRecord]
    @AppStorage(SettingsKey.hideAmounts) private var hideAmounts = false

    @State private var showEditor = false
    @State private var showAdjust = false
    @State private var newRecordKind: RecordKind?
    @State private var editingRecord: LedgerRecord?
    @State private var stubRecord: LedgerRecord?
    @State private var prefillTarget: RecordPrefill?
    @State private var pendingDeleteAfterStub: LedgerRecord?
    @State private var pendingDelete: LedgerRecord?
    @State private var txFilter: Int = 0    // 0 全部 1 支出 2 收入 3 转账
    @State private var searchText: String = ""
    /// 走势图点选的日期。空则徽章显示最新一点。
    @State private var inspectedDate: Date?

    private static let chartDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = DateText.calendar
        f.dateFormat = "MM/dd"
        return f
    }()

    private static let wholeYuan: NumberFormatter = {
        let n = NumberFormatter()
        n.numberStyle = .decimal
        n.maximumFractionDigits = 0
        n.usesGroupingSeparator = true
        n.locale = Locale(identifier: "zh_CN")
        return n
    }()

    struct BalancePoint: Identifiable {
        let index: Int
        let date: Date
        let value: Double
        var id: Int { index }
    }

    private func filterEntries(_ entries: [LedgerRecord]) -> [LedgerRecord] {
        let byKind: [LedgerRecord]
        switch txFilter {
        case 1: byKind = entries.filter { $0.kind == .expense }
        case 2: byKind = entries.filter { $0.kind == .income || $0.kind == .contribution }
        case 3: byKind = entries.filter { $0.kind == .transfer || $0.kind == .adjustment }
        default: byKind = entries
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return byKind }
        return byKind.filter {
            $0.displayTitle.lowercased().contains(q)
            || $0.categoryName.lowercased().contains(q)
            || $0.note.lowercased().contains(q)
            || $0.merchant.lowercased().contains(q)
            || String(format: "%.2f", $0.amount).contains(q)
        }
    }

    var body: some View {
        let _ = records.count   // 记录变化时刷新余额
        let allEntries = account.allEntries.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString > $1.id.uuidString
        }
        let entries = filterEntries(allEntries)
        let afterByID = runningBalanceAfterByID(entries: account.allEntries)
        let balance = account.balance()
        let points = balanceTrend(allEntries)

        Group {
            if theme.isReceipt {
                receiptScrollBody(entries: entries, totalCount: allEntries.count, afterByID: afterByID, balance: balance, points: points)
            } else {
                defaultListBody(entries: entries, totalCount: allEntries.count, afterByID: afterByID, balance: balance, points: points)
            }
        }
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
                context.delete(r)
                try? context.save()
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { r in
            Text(r.deleteSummary)
        }
    }

    private func receiptScrollBody(
        entries: [LedgerRecord],
        totalCount: Int,
        afterByID: [UUID: Double],
        balance: Double,
        points: [BalancePoint]
    ) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                receiptHeader(balance: balance)
                actionRow
                if points.count > 1 {
                    receiptChart(points)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(account.type.isSocialSecurity ? "缴存与提取" : "收支与转账")
                            .font(theme.cardTitleFont)
                            .foregroundStyle(theme.ink)
                        Text("TRANSACTIONS")
                            .font(theme.labelFont)
                            .foregroundStyle(theme.faint)
                        Spacer()
                        Text("共 \(entries.count) 笔")
                            .font(theme.metaFont)
                            .foregroundStyle(theme.faint)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                    if totalCount > 0 {
                        let inflow = entries.reduce(0.0) { sum, r in
                            let eff = r.effect(on: account)
                            return eff > 0 ? sum + eff : sum
                        }
                        let outflow = entries.reduce(0.0) { sum, r in
                            let eff = r.effect(on: account)
                            return eff < 0 ? sum + abs(eff) : sum
                        }
                        HStack(spacing: 6) {
                            ForEach([(0, "全部"), (1, "支出"), (2, "收入"), (3, "转账")], id: \.0) { tag, label in
                                let selected = txFilter == tag
                                Button {
                                    ReceiptHaptics.selection()
                                    withAnimation(.snappy(duration: 0.22)) { txFilter = tag }
                                } label: {
                                    Text(label)
                                        .font(theme.labelFont)
                                        .foregroundStyle(selected ? theme.accent : theme.faint)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(RoundedRectangle(cornerRadius: 3).fill(selected ? theme.accent.opacity(0.1) : Color.clear))
                                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected ? theme.accent.opacity(0.55) : theme.rule, lineWidth: 1))
                                        .scaleEffect(selected ? 1.03 : 1.0)
                                }
                                .buttonStyle(ReceiptPressButtonStyle())
                            }
                            Spacer()
                            let netFlow = inflow - outflow
                            Text("流入 \(Money.masked(inflow, hidden: hideAmounts)) · 流出 \(Money.masked(outflow, hidden: hideAmounts)) · 净 \(netFlow >= 0 ? "+" : "-")\(Money.masked(abs(netFlow), hidden: hideAmounts))")
                                .font(theme.labelFont)
                                .monospacedDigit()
                                .foregroundStyle(theme.faint)
                                .contentTransition(.numericText())
                                .animation(.snappy(duration: 0.22), value: inflow + outflow)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)

                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.faint)
                            TextField("搜索该账户流水…", text: $searchText)
                                .font(theme.serifLabelFont)
                                .textFieldStyle(.plain)
                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(theme.faint)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 4).fill(theme.cardFill))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.rule, lineWidth: 1))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    }

                    ThemedDashedRule()
                        .padding(.horizontal, 14)

                    if entries.isEmpty {
                        Text(totalCount == 0 ? "还没有关联到这个账户的记录" : "该分类下暂无记录")
                            .font(theme.serifLabelFont)
                            .foregroundStyle(theme.faint)
                            .padding(16)
                    } else {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { idx, r in
                            Button { stubRecord = r } label: {
                                RecordRow(
                                    record: r,
                                    showDate: true,
                                    runningBalanceText: runningBalanceCaption(afterByID[r.id] ?? account.initialBalance),
                                    showsTopRule: idx > 0
                                )
                                .padding(.horizontal, 14)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    editingRecord = r
                                } label: {
                                    Label("编辑记录", systemImage: "pencil")
                                }
                                if r.kind != .adjustment && r.kind != .contribution {
                                    Button {
                                        prefillTarget = RecordPrefill.duplicate(from: r, date: Date())
                                    } label: {
                                        Label("再来一笔", systemImage: "plus.square.on.square")
                                    }
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
                        Color.clear.frame(height: 6)
                    }
                }
                .receiptSurface(theme, hero: true)

                if !account.note.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ReceiptLabelText(text: "备注 · NOTE", color: theme.faint)
                        Text(account.note)
                            .font(theme.serifLabelFont)
                            .foregroundStyle(theme.ink)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .receiptSurface(theme, hero: false)
                }

                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, ReceiptStyle.pageHorizontalMargin)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .themedScreenBackground()
    }

    private func defaultListBody(
        entries: [LedgerRecord],
        totalCount: Int,
        afterByID: [UUID: Double],
        balance: Double,
        points: [BalancePoint]
    ) -> some View {
        ThemedList {
            Section {
                header(balance: balance)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                actionRow
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
                if totalCount > 0 {
                    Picker("筛选", selection: $txFilter) {
                        Text("全部").tag(0)
                        Text("支出").tag(1)
                        Text("收入").tag(2)
                        Text("转账").tag(3)
                    }
                    .pickerStyle(.segmented)
                }
                if entries.isEmpty {
                    Text(totalCount == 0 ? "还没有关联到这个账户的记录" : "该分类下暂无记录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { r in
                        Button { editingRecord = r } label: {
                            RecordRow(
                                record: r,
                                showDate: true,
                                runningBalanceText: runningBalanceCaption(afterByID[r.id] ?? account.initialBalance)
                            )
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = r
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                editingRecord = r
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                editingRecord = r
                            } label: {
                                Label("编辑记录", systemImage: "pencil")
                            }
                            if r.kind != .adjustment && r.kind != .contribution {
                                Button {
                                    prefillTarget = RecordPrefill.duplicate(from: r, date: Date())
                                } label: {
                                    Label("再来一笔", systemImage: "plus.square.on.square")
                                }
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
                }
            } header: { ThemedSectionHeader {
                Text(account.type.isSocialSecurity ? "缴存与提取（\(entries.count)）" : "收支与转账（\(entries.count)）")
            } }

            if !account.note.isEmpty {
                Section { Text(account.note) } header: { ThemedSectionHeader { Text("备注") } }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 头部

    @ViewBuilder
    private func header(balance: Double) -> some View {
        let liability = account.type.isLiability
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                CategoryIcon(icon: account.iconName, color: headerInk, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.type.title).font(.ui(.subheadline).weight(.semibold))
                    if !account.includeInNetWorth {
                        Text("不计入净资产").font(.ui(.caption2)).opacity(0.8)
                    }
                }
                Spacer()
                if account.isArchived {
                    Text("已归档").font(.ui(.caption)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.2)))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(liability ? (balance <= 0 ? "当前欠款" : "溢缴款") : "当前余额")
                    .font(.ui(.caption)).opacity(0.85)
                Text(Money.masked(liability ? abs(balance) : balance, hidden: hideAmounts))
                    .font(.uiSystem(size: 34, weight: .bold, design: .rounded))
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
                    .font(.ui(.caption))
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
                            .font(.ui(.caption).weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(days <= 3 ? 0.35 : 0.2)))
                    }
                }
                .font(.ui(.caption))
            }
        }
        .foregroundStyle(headerInk)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: theme.isReceipt ? ReceiptStyle.corner : 24, style: .continuous)
                .fill(headerFill)
        )
        .padding(.vertical, 4)
    }

    /// 设计稿页头：纸质「‹ 资产」/ 账户名 /「编辑」，不用系统导航栏
    private var receiptNav: some View {
        ZStack {
            Text(account.name)
                .font(ReceiptTypeface.scaled(ReceiptTypeface.cjkSerifBold, 17, relativeTo: .headline))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 78)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button { dismiss() } label: {
                    Text("‹ 资产")
                        .font(theme.serifLabelFont)
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
                .buttonStyle(PaperKeyButtonStyle())
                .accessibilityLabel("返回资产")
                Spacer()
                Button { showEditor = true } label: {
                    Text("编辑")
                        .font(theme.serifLabelFont)
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
                .buttonStyle(PaperKeyButtonStyle())
            }
        }
    }

    /// 设计稿 STATEMENT CARD：类型 · 机构 / 暖白大数字 / 额度带 / 账单日与还款日
    private func receiptHeader(balance: Double) -> some View {
        let liability = account.type.isLiability
        let used = max(0, -balance)
        let hasLimit = account.type.hasCreditLimit && account.creditLimit > 0
        let dark = theme.scheme == .dark
        let ink = ReceiptStyle.color(ReceiptStyle.statementInk, dark: dark)
        let faintInk = ink.opacity(0.8)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(statementKicker)
                    .font(ReceiptTypeface.scaled(ReceiptTypeface.cjkSerif, 14, relativeTo: .subheadline))
                    .tracking(0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                Text("STATEMENT CARD")
                    .font(theme.labelFont)
                    .tracking(2)
                    .foregroundStyle(ink.opacity(0.8))
            }
            .foregroundStyle(ink)
            .padding(.bottom, 12)

            Text(liability ? (balance <= 0 ? "当前欠款" : "溢缴款") : "当前余额")
                .font(theme.serifLabelFont)
                .foregroundStyle(faintInk)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Money.masked(liability ? abs(balance) : balance, hidden: hideAmounts))
                    .font(theme.amountFont(30))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer(minLength: 8)
                if account.isArchived {
                    Text("已归档")
                        .font(theme.labelFont)
                        .foregroundStyle(ink)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(faintInk, lineWidth: 1))
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 12)

            if hasLimit {
                VStack(spacing: 0) {
                    Rectangle().fill(Color.white.opacity(0.2)).frame(height: 1)
                    HStack(alignment: .top) {
                        sumColumn("已用额度", Money.masked(used, hidden: hideAmounts), alignment: .leading, ink: ink)
                        Spacer(minLength: 8)
                        sumColumn("可用额度", Money.masked(max(0, account.creditLimit - used), hidden: hideAmounts), alignment: .center, ink: ink)
                        Spacer(minLength: 8)
                        sumColumn("总额度", Money.masked(account.creditLimit, hidden: hideAmounts), alignment: .trailing, ink: ink)
                    }
                    .padding(.vertical, 10)
                    Rectangle().fill(Color.white.opacity(0.2)).frame(height: 1)
                }
            }
            if !account.includeInNetWorth {
                Text("不计入净资产")
                    .font(theme.labelFont)
                    .foregroundStyle(faintInk)
                    .padding(.top, 8)
            }
            if account.type.isSocialSecurity, let rule = RecurringEngine.contributionRule(for: account, in: context), !rule.isPaused {
                Text("每月 \(rule.monthDay) 日缴存 \(Money.masked(rule.amount, hidden: hideAmounts))")
                    .font(theme.serifLabelFont)
                    .foregroundStyle(faintInk)
                    .padding(.top, 8)
            }
            if account.billingDay > 0 || account.repaymentDay > 0 {
                HStack(spacing: 8) {
                    if account.billingDay > 0 {
                        Text("账单日 每月\(account.billingDay)日")
                    }
                    if account.billingDay > 0 && account.repaymentDay > 0 {
                        Spacer(minLength: 4)
                    }
                    if account.repaymentDay > 0 {
                        Text("还款日 每月\(account.repaymentDay)日")
                    }
                    Spacer(minLength: 4)
                    if let days = account.daysUntilRepayment() {
                        Text(days == 0 ? "今天还款" : "\(days) 天后还款")
                            .font(theme.labelFont)
                            .foregroundStyle(ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                .font(ReceiptTypeface.scaled(ReceiptTypeface.cjkSerif, 11, relativeTo: .caption2))
                .foregroundStyle(ink.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.top, 12)
            }
        }
        .padding(20)
        .background {
            shape.fill(LinearGradient(
                colors: [
                    Color(hex: dark ? "#5A2422" : "#7B3331"),
                    Color(hex: dark ? "#2C1210" : "#52201E")
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
        .overlay {
            shape.strokeBorder(Color(red: 1, green: 240 / 255, blue: 225 / 255).opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(dark ? 0.45 : 0.22), radius: 14, y: 8)
    }

    /// 「招行信用卡」→「信用卡 · 招行」；名称里没有机构时只显示类型
    private var statementKicker: String {
        let typeTitle = account.type.title
        let institution = statementInstitution(account.name)
        if institution.isEmpty || institution == typeTitle { return typeTitle }
        return "\(typeTitle) · \(institution)"
    }

    private func statementInstitution(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = ["信用卡", "储蓄卡", "借记卡", "银行卡", "花呗", "白条"]
        for suffix in suffixes where trimmed.hasSuffix(suffix) && trimmed.count > suffix.count {
            trimmed = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return trimmed
    }

    /// 卡面三联：已用 / 可用 / 总额度
    private func sumColumn(_ title: String, _ value: String, alignment: HorizontalAlignment, ink: Color) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title)
                .font(ReceiptTypeface.scaled(ReceiptTypeface.cjkSerif, 11, relativeTo: .caption2))
                .foregroundStyle(ink.opacity(0.8))
            Text(value)
                .font(theme.amountFont(12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if account.type.isSocialSecurity {
                actionButton("缴存", icon: "tray.and.arrow.down") { newRecordKind = .contribution }
                actionButton(account.type == .housingFund ? "提取" : "转出", icon: "arrow.up.forward.square") {
                    newRecordKind = .transfer
                }
            } else {
                actionButton("记一笔", icon: theme.isReceipt ? "pencil" : "square.and.pencil") { newRecordKind = .expense }
                actionButton(account.type.isLiability ? "还款" : "转账", icon: "arrow.left.arrow.right") {
                    newRecordKind = .transfer
                }
            }
            actionButton("余额校准", icon: theme.isReceipt ? "plus.circle" : "scope") { showAdjust = true }
        }
    }

    /// 4.0：小票皮肤信用卡卡面改用朱砂底 + 暖象牙高对比文字（设计稿 STATEMENT CARD）
    private var headerInk: Color {
        theme.isReceipt ? ReceiptStyle.color(ReceiptStyle.statementInk, dark: theme.scheme == .dark) : .white
    }
    private var headerFill: AnyShapeStyle {
        if theme.isReceipt {
            return AnyShapeStyle(ReceiptStyle.color(ReceiptStyle.statementFill, dark: theme.scheme == .dark))
        }
        return AnyShapeStyle(LinearGradient(colors: [account.color, account.color.opacity(0.7)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    @ViewBuilder
    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        if theme.isReceipt {
            Button(action: action) {
                VStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 15, weight: .regular))
                    Text(title).font(theme.serifLabelFont)
                }
                .foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(PaperKeyButtonStyle())
        } else {
            Button(action: action) {
                VStack(spacing: 6) {
                    Image(systemName: icon).font(.ui(.title3))
                    Text(title).font(.ui(.caption))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.themeCard))
            }
            .buttonStyle(.plain)
            .foregroundStyle(account.color)
        }
    }

    // MARK: - 走势

    /// 预计算每条记录发生后的余额（O(n log n)），列表展示用
    private func runningBalanceAfterByID(entries: [LedgerRecord]) -> [UUID: Double] {
        let payload = entries.map { (id: $0.id.uuidString, date: $0.date, effect: $0.effect(on: account)) }
        let byString = BalanceMath.runningBalances(initialBalance: account.initialBalance, entries: payload)
        var map: [UUID: Double] = [:]
        map.reserveCapacity(entries.count)
        for r in entries {
            if let v = byString[r.id.uuidString] { map[r.id] = v }
        }
        return map
    }

    /// 与账户头部口径一致：资产显示「余额」；负债显示「欠款」或「溢缴」
    private func runningBalanceCaption(_ signed: Double) -> String {
        if account.type.isLiability {
            if signed <= 0 {
                return "欠款 " + Money.masked(abs(signed), hidden: hideAmounts)
            }
            return "溢缴 " + Money.masked(signed, hidden: hideAmounts)
        }
        return "余额 " + Money.masked(signed, hidden: hideAmounts)
    }

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

    /// 设计稿：锯齿票面 + 可点选毫米坐标纸。徽章默认最新一点。
    private func receiptChart(_ points: [BalancePoint]) -> some View {
        let shown = inspectedPoint(in: points)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.type.isLiability ? "欠款走势" : "余额走势")
                    .font(theme.cardTitleFont)
                    .foregroundStyle(theme.ink)
                Spacer(minLength: 8)
                if let shown {
                    Text(chartBadge(shown))
                        .font(theme.metaFont)
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.accent.opacity(theme.scheme == .dark ? 0.16 : 0.10))
                        )
                }
            }
            ThemedDashedRule()
            receiptTrendChart(points)
                .frame(height: 145)
                .padding(12)
                .background {
                    MillimeterGridBackground(
                        paper: chartPaper,
                        line: theme.accent.opacity(theme.scheme == .dark ? 0.14 : 0.09),
                        subline: theme.accent.opacity(theme.scheme == .dark ? 0.06 : 0.04)
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(theme.rule, lineWidth: 1)
                }
                .overlay(alignment: .top) {
                    LinearGradient(colors: [Color.black.opacity(0.06), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 8)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .allowsHitTesting(false)
                }
        }
        .padding(.horizontal, ReceiptStyle.Space.m)
        .padding(.top, ReceiptStyle.Space.m)
        .padding(.bottom, ReceiptStyle.Space.s)
        .receiptSurface(theme, hero: true)
    }

    private var chartPaper: Color {
        if theme.scheme == .dark { return Color(hex: "#1B1815") }
        return Color(hex: ReceiptPaper.current == .vintage ? "#E7DCC6" : "#F0EAE0")
    }

    private func inspectedPoint(in points: [BalancePoint]) -> BalancePoint? {
        guard let inspectedDate else { return points.last }
        guard let hit = points.min(by: {
            abs($0.date.timeIntervalSince(inspectedDate)) < abs($1.date.timeIntervalSince(inspectedDate))
        }), abs(hit.date.timeIntervalSince(inspectedDate)) < 1 else {
            return points.last
        }
        return hit
    }

    /// 整数去掉 `.00`，仍保留千分位。设计稿徽章是 `11/06: ¥2,659`。
    private func chartBadge(_ point: BalancePoint) -> String {
        "\(Self.chartDay.string(from: point.date)): \(chartAmount(point.value))"
    }

    private func chartAmount(_ value: Double) -> String {
        if hideAmounts { return Money.symbol + "****" }
        let whole = abs(value - value.rounded()) < 0.001
        if whole, let body = Self.wholeYuan.string(from: NSNumber(value: abs(value))) {
            return (value < 0 ? "-" : "") + Money.symbol + body
        }
        return Money.format(value)
    }

    /// 波峰（最多两个）+ 当前点。点选的非波峰另加空心圈。
    private func trendMarkerIndexes(_ points: [BalancePoint], inspected: BalancePoint?) -> Set<Int> {
        var marks = Set<Int>()
        if let last = points.last { marks.insert(last.index) }
        if let inspected, inspected.index != points.last?.index {
            marks.insert(inspected.index)
        }
        guard points.count >= 3 else { return marks }
        var peaks: [(Int, Double)] = []
        for i in 1..<(points.count - 1) {
            let v = points[i].value
            if v > points[i - 1].value && v >= points[i + 1].value {
                peaks.append((points[i].index, v))
            }
        }
        for item in peaks.sorted(by: { $0.1 > $1.1 }).prefix(2) {
            marks.insert(item.0)
        }
        return marks
    }

    private func receiptTrendChart(_ points: [BalancePoint]) -> some View {
        let values = points.map(\.value)
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let span = max(hi - lo, max(abs(hi), 1) * 0.08)
        let pad = span * 0.22
        let domainLo = lo - pad
        let domainHi = hi + pad
        let inspected = inspectedPoint(in: points)
        let markers = trendMarkerIndexes(points, inspected: inspected)
        let lastIndex = points.last?.index
        return Chart(points) { p in
            AreaMark(
                x: .value("时间", p.date),
                yStart: .value("底", domainLo),
                yEnd: .value("余额", p.value)
            )
            .foregroundStyle(theme.accent.opacity(0.12))
            .interpolationMethod(.stepEnd)
            LineMark(x: .value("时间", p.date), y: .value("余额", p.value))
                .foregroundStyle(theme.accent)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.stepEnd)
            if markers.contains(p.index) {
                PointMark(x: .value("时间", p.date), y: .value("余额", p.value))
                    .symbol {
                        trendSymbol(isCurrent: p.index == lastIndex)
                    }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXScale(range: .plotDimension(padding: 10))
        .chartYScale(domain: domainLo...domainHi, range: .plotDimension(padding: 8))
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        SpatialTapGesture()
                            .onEnded { event in
                                inspectTrend(at: event.location, proxy: proxy, geo: geo, points: points)
                            }
                    )
            }
        }
    }

    private func trendSymbol(isCurrent: Bool) -> some View {
        Circle()
            .fill(isCurrent ? theme.accent : theme.paper)
            .overlay(Circle().stroke(isCurrent ? theme.paper : theme.accent, lineWidth: isCurrent ? 1.5 : 2))
            .frame(width: isCurrent ? 10 : 9, height: isCurrent ? 10 : 9)
    }

    private func inspectTrend(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy, points: [BalancePoint]) {
        let frame: CGRect
        if let plot = proxy.plotFrame {
            frame = geo[plot]
        } else {
            frame = geo.frame(in: .local)
        }
        let x = location.x - frame.origin.x
        guard let date: Date = proxy.value(atX: x),
              let nearest = points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
        else { return }
        withAnimation(.snappy) { inspectedDate = nearest.date }
    }

    private func trendChart(_ points: [BalancePoint]) -> some View {
        Chart(points) { p in
            AreaMark(x: .value("时间", p.date), y: .value("余额", p.value))
                .foregroundStyle(LinearGradient(
                    colors: [account.color.opacity(0.3), account.color.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                ))
                .interpolationMethod(.stepEnd)
            LineMark(x: .value("时间", p.date), y: .value("余额", p.value))
                .foregroundStyle(account.color)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.stepEnd)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.3))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(hideAmounts ? "**" : Money.compact(v))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.3))
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
            }
        }
    }
}

/// 纸质立体键：上浅下深的纸面、1pt 裁切线、2pt 键唇。按下下沉。
private struct PaperKeyButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .background(shape.fill(LinearGradient(
                colors: [theme.cardFill, theme.paper],
                startPoint: .top, endPoint: .bottom
            )))
            .overlay(shape.strokeBorder(theme.rule, lineWidth: 1))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(theme.scheme == .dark ? 0.08 : 0.75))
                    .frame(height: 1)
                    .padding(.horizontal, 1)
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
            .shadow(color: theme.rule.opacity(configuration.isPressed ? 0 : 1), radius: 0, y: configuration.isPressed ? 0 : 2)
            .shadow(color: Color.black.opacity(configuration.isPressed ? 0 : 0.08), radius: configuration.isPressed ? 0 : 2.5, y: configuration.isPressed ? 0 : 3)
            .offset(y: configuration.isPressed ? 2 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 4.0 小票：欠款走势底的毫米坐标纸（大格 40 / 小格 8）
private struct MillimeterGridBackground: View {
    var paper: Color
    var line: Color
    var subline: Color
    var major: CGFloat = 40
    var minor: CGFloat = 8

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(paper))
            let steps = max(1, Int((major / minor).rounded()))
            var x: CGFloat = 0
            while x <= size.width + 0.5 {
                let majorLine = Int((x / minor).rounded()) % steps == 0
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(path, with: .color(majorLine ? line : subline), lineWidth: majorLine ? 1 : 0.6)
                x += minor
            }
            var y: CGFloat = 0
            while y <= size.height + 0.5 {
                let majorLine = Int((y / minor).rounded()) % steps == 0
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(path, with: .color(majorLine ? line : subline), lineWidth: majorLine ? 1 : 0.6)
                y += minor
            }
        }
        .allowsHitTesting(false)
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
            ThemedForm {
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
                } footer: { ThemedSectionFooter {
                    if let delta, abs(delta) >= 0.005 {
                        Text("将生成一笔 \(delta > 0 ? "+" : "")\(Money.format(delta)) 的「余额校准」记录，不计入收支统计和预算。")
                    } else {
                        Text("输入银行 App / 支付宝等显示的真实\(liability ? "欠款" : "余额")，差额会记为一笔校准，不影响收支统计。")
                    }
                } }
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
