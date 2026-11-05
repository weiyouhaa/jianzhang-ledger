import SwiftUI
import SwiftData
import Charts

/// 「资产」页：净资产、各账户余额、净资产趋势
struct AssetsView: View {
    @Query(sort: \LedgerAccount.sortOrder) private var accounts: [LedgerAccount]
    @Query(sort: \LedgerRecord.date) private var records: [LedgerRecord]
    @AppStorage(SettingsKey.hideAmounts) private var hideAmounts = false

    @State private var editorTarget: AccountEditorTarget?
    @State private var showTransfer = false
    @State private var demoAccount: LedgerAccount?
    @State private var showDemoAccount = false
    /// 长按「修改余额」：只存账户 UUID（不持有 SwiftData 对象），sheet 内再按 ID 取账户
    @State private var quickBalanceTarget: QuickBalanceTarget?
    @State private var recordTarget: AccountRecordTarget?

    struct QuickBalanceTarget: Identifiable, Equatable {
        let id: UUID
    }

    struct AccountRecordTarget: Identifiable {
        let account: LedgerAccount
        let kind: RecordKind
        /// 长按信用卡「还款」：直接进入支出 · 信用卡还款
        var repay = false
        var id: String { account.id.uuidString + kind.rawValue + (repay ? "-repay" : "") }
    }

    struct NetWorthPoint: Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    struct TypeGroup: Identifiable {
        let type: AccountType
        let accounts: [LedgerAccount]
        var id: String { type.rawValue }
    }

    private var activeAccounts: [LedgerAccount] { accounts.filter { !$0.isArchived } }

    var body: some View {
        let _ = records.count   // 记录变化时刷新余额
        let active = activeAccounts
        let balances = Dictionary(active.map { ($0.id, $0.balance()) }, uniquingKeysWith: { a, _ in a })
        let included = active.filter { $0.includeInNetWorth }
        let totalAssets = included.filter { !$0.type.isLiability }.reduce(0) { $0 + (balances[$1.id] ?? 0) }
        let totalLiabilities = -included.filter { $0.type.isLiability }.reduce(0) { $0 + (balances[$1.id] ?? 0) }
        let assetGroups = groups(active, liability: false)
        let liabilityGroups = groups(active, liability: true)
        let social = active.filter { $0.type.isSocialSecurity }.sorted {
            let a = AccountType.socialTypes.firstIndex(of: $0.type) ?? 0, b = AccountType.socialTypes.firstIndex(of: $1.type) ?? 0
            return a == b ? $0.sortOrder < $1.sortOrder : a < b
        }
        // 可支配资产：不含公积金与社保类账户
        let socialIncluded = included.filter { $0.type.isSocialSecurity }.reduce(0) { $0 + (balances[$1.id] ?? 0) }

        NavigationStack {
          ScrollViewReader { proxy in
            ThemedList {
                Section {
                    NetWorthCard(netWorth: totalAssets - totalLiabilities, assets: totalAssets,
                                 liabilities: totalLiabilities,
                                 disposable: social.isEmpty ? nil : totalAssets - socialIncluded,
                                 hidden: $hideAmounts)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                if active.isEmpty {
                    Section {
                        ThemedEmptyState("还没有账户", systemImage: "wallet.pass",
                                         description: Text("添加储蓄卡、支付宝、微信、信用卡等账户，记账时选择账户即可自动计算余额和净资产。")) {
                            Button("添加账户") { editorTarget = .new }
                                .buttonStyle(.borderedProminent)
                        }
                        .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(assetGroups) { group in
                        accountSection(group, balances: balances)
                    }
                    if !social.isEmpty {
                        socialSection(social, balances: balances)
                            .id("social")
                    }
                    ForEach(liabilityGroups) { group in
                        accountSection(group, balances: balances)
                    }

                    let trend = netWorthTrend(included)
                    if trend.count > 1 {
                        Section {
                            NetWorthChart(points: trend, hidden: hideAmounts)
                                .frame(height: 170)
                                .padding(.vertical, 6)
                        } header: { ThemedSectionHeader { Text("净资产趋势") } }
                    }
                }

                let archivedCount = accounts.count - active.count
                if archivedCount > 0 {
                    Section {
                        NavigationLink {
                            AccountManagerView()
                        } label: {
                            Label("已归档账户（\(archivedCount)）", systemImage: "archivebox")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .themedScreenBackground()
            .task {
                // 截图模式：滚动到「公积金与社保」
                if ScreenshotDemo.screen == "assetssocial" {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    proxy.scrollTo("social", anchor: UnitPoint(x: 0.5, y: 0.3))
                }
            }
          }
            .themedRootTitle("资产")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation { hideAmounts.toggle() }
                    } label: {
                        Image(systemName: hideAmounts ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(hideAmounts ? "显示金额" : "隐藏金额")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { editorTarget = .new } label: { Label("新建账户", systemImage: "plus") }
                        Button { showTransfer = true } label: { Label("转账 / 还款", systemImage: "arrow.left.arrow.right") }
                            .disabled(active.count < 2)
                        NavigationLink {
                            AccountManagerView()
                        } label: {
                            Label("排序与归档", systemImage: "arrow.up.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityIdentifier("assets-add-menu")
                }
            }
            .sheet(item: $editorTarget) { target in
                switch target {
                case .new:
                    AccountEditorView(account: nil, nextSortOrder: (accounts.map(\.sortOrder).max() ?? -1) + 1)
                case .edit(let a):
                    AccountEditorView(account: a, nextSortOrder: a.sortOrder)
                }
            }
            .sheet(isPresented: $showTransfer) {
                RecordEditorView(record: nil, initialKind: .transfer)
            }
            .sheet(item: $quickBalanceTarget) { t in
                if let a = accounts.first(where: { $0.id == t.id }) {
                    QuickBalanceSheet(account: a)
                        .presentationDetents([.height(270)])
                        .presentationDragIndicator(.visible)
                }
            }
            .sheet(item: $recordTarget) { t in
                if t.repay {
                    RecordEditorView(record: nil, initialKind: .expense, repayCardID: t.account.id)
                } else {
                    RecordEditorView(record: nil, initialKind: t.kind, presetAccountID: t.account.id)
                }
            }
            .navigationDestination(isPresented: $showDemoAccount) {
                if let demoAccount { AccountDetailView(account: demoAccount) }
            }
            .task {
                // 截图模式：直接打开账户详情
                if ScreenshotDemo.screen == "quickbalance", quickBalanceTarget == nil,
                   let a = activeAccounts.first(where: { $0.type == .debit }) ?? activeAccounts.first {
                    quickBalanceTarget = QuickBalanceTarget(id: a.id)
                }
                if ScreenshotDemo.screen == "cardrepayment", recordTarget == nil,
                   let card = activeAccounts.first(where: { $0.type == .credit }) {
                    recordTarget = AccountRecordTarget(account: card, kind: .expense, repay: true)
                }
                if ScreenshotDemo.screen == "account", !showDemoAccount,
                   let target = activeAccounts.first(where: { $0.type == .credit }) ?? activeAccounts.first {
                    demoAccount = target
                    showDemoAccount = true
                }
            }
        }
    }

    // MARK: - 子视图

    private func accountSection(_ group: TypeGroup, balances: [UUID: Double]) -> some View {
        let total = group.accounts.reduce(0) { $0 + (balances[$1.id] ?? 0) }
        return Section {
            ForEach(group.accounts) { a in
                accountRow(a, balances: balances)
            }
        } header: { ThemedSectionHeader {
            HStack {
                Text(group.type.isLiability ? "负债 · \(group.type.title)" : group.type.title)
                Spacer()
                Text(group.type.isLiability
                     ? "欠 " + Money.masked(max(0, -total), hidden: hideAmounts)
                     : Money.masked(total, hidden: hideAmounts))
            }
            .font(.ui(.caption))
            .textCase(nil)
        } }
    }

    /// 公积金与社保：多种类型合在一个分组
    private func socialSection(_ list: [LedgerAccount], balances: [UUID: Double]) -> some View {
        let total = list.reduce(0) { $0 + (balances[$1.id] ?? 0) }
        return Section {
            ForEach(list) { a in
                accountRow(a, balances: balances)
            }
        } header: { ThemedSectionHeader {
            HStack {
                Label("公积金与社保", systemImage: "building.columns")
                Spacer()
                Text(Money.masked(total, hidden: hideAmounts))
            }
            .font(.ui(.caption))
            .textCase(nil)
        } } footer: { ThemedSectionFooter {
            if list.contains(where: { !$0.includeInNetWorth }) {
                Text("标 ⊖ 的账户（如养老保险个人账户）退休前不能领取，不计入净资产。")
            }
        } }
    }

    /// 账户行：点按进入详情，左滑编辑，长按快捷菜单
    private func accountRow(_ a: LedgerAccount, balances: [UUID: Double]) -> some View {
        let balance = balances[a.id] ?? 0
        return NavigationLink {
            AccountDetailView(account: a)
        } label: {
            AccountRow(account: a, balance: balance, hidden: hideAmounts)
        }
        .accessibilityIdentifier("account-" + a.name)
        .swipeActions {
            Button { editorTarget = .edit(a) } label: { Label("编辑", systemImage: "pencil") }
                .tint(.blue)
        }
        .contextMenu {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                present { quickBalanceTarget = QuickBalanceTarget(id: a.id) }
            } label: {
                Label(a.type.isLiability ? "修改欠款" : "修改余额", systemImage: "pencil.circle")
            }
            if a.type.isLiability {
                Button { present { recordTarget = AccountRecordTarget(account: a, kind: .expense, repay: true) } } label: {
                    Label("还款", systemImage: LedgerRecord.repaymentIcon)
                }
                .accessibilityIdentifier("menu-repay")
            }
            Divider()
            if a.type.isSocialSecurity {
                Button { present { recordTarget = AccountRecordTarget(account: a, kind: .contribution) } } label: {
                    Label("缴存", systemImage: "tray.and.arrow.down")
                }
            } else {
                Button { present { recordTarget = AccountRecordTarget(account: a, kind: .expense) } } label: {
                    Label("记一笔", systemImage: "square.and.pencil")
                }
            }
            Button { present { recordTarget = AccountRecordTarget(account: a, kind: .transfer) } } label: {
                Label(a.type == .housingFund ? "提取 / 转账" : "转账",
                      systemImage: "arrow.left.arrow.right")
            }
            Button { present { editorTarget = .edit(a) } } label: {
                Label("编辑账户", systemImage: "slider.horizontal.3")
            }
        } preview: {
            AccountPreviewCard(account: a, balance: balance, hidden: hideAmounts)
        }
    }

    /// 从长按菜单里弹 sheet：等菜单（带预览）收起动画结束再设状态。
    /// 菜单还在收起时就 present，iOS 26/27 上 sheet 会被菜单的退场转场一起带走（闪一下就消失）。
    /// 3.8 (29)：CI / iOS 26 上菜单退场偶发 >0.7s，提到 1.0s
    private func present(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: action)
    }

    private func groups(_ list: [LedgerAccount], liability: Bool) -> [TypeGroup] {
        let types = (liability ? AccountType.liabilityTypes : AccountType.assetTypes).filter { !$0.isSocialSecurity }
        return types.compactMap { t in
            let items = list.filter { $0.type == t }
            return items.isEmpty ? nil : TypeGroup(type: t, accounts: items)
        }
    }

    /// 最近 12 个月每月月末的净资产
    private func netWorthTrend(_ list: [LedgerAccount]) -> [NetWorthPoint] {
        guard !list.isEmpty else { return [] }
        let cal = DateText.calendar
        let thisMonth = cal.startOfMonth(for: Date())
        var points: [NetWorthPoint] = []
        for back in stride(from: 11, through: 0, by: -1) {
            guard let monthStart = cal.date(byAdding: .month, value: -back, to: thisMonth) else { continue }
            let end: Date = back == 0 ? Date() : (cal.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart).addingTimeInterval(-1)
            let value = list.reduce(0) { $0 + $1.balance(asOf: end) }
            points.append(NetWorthPoint(date: monthStart, value: value))
        }
        // 去掉开头没有任何变化的月份（记账开始之前）
        if let firstRecord = list.flatMap({ $0.allEntries }).map(\.date).min() {
            let start = cal.startOfMonth(for: firstRecord)
            let trimmed = points.filter { $0.date >= start }
            return trimmed.count >= 2 ? trimmed : Array(points.suffix(2))
        }
        return []
    }
}

enum AccountEditorTarget: Identifiable {
    case new
    case edit(LedgerAccount)
    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let a): return a.id.uuidString
        }
    }
}

/// 顶部净资产卡片
struct NetWorthCard: View {
    let netWorth: Double
    let assets: Double
    let liabilities: Double
    /// 可支配资产（不含公积金与社保）；没有这类账户时为 nil
    var disposable: Double? = nil
    @Binding var hidden: Bool
    @Environment(\.appTheme) private var theme

    private var heroColors: [Color] {
        theme.isReceipt ? theme.heroFill : [Color(hex: "#5E5CE6"), Color(hex: "#1673A8")]
    }

    var body: some View {
        if theme.isReceipt { receiptBody } else { defaultBody }
    }

    /// 3.5 (26) 小票皮肤净资产卡：与首页汇总卡同一套 hero 版式（标签 / 大数字 / 两列 / 点引线 / 细条）
    private var receiptBody: some View {
        VStack(alignment: .leading, spacing: ReceiptStyle.Space.m) {
            HStack(alignment: .center, spacing: ReceiptStyle.Space.xs) {
                ReceiptLabelText(text: "净资产", color: theme.faint)
                Button {
                    withAnimation { hidden.toggle() }
                } label: {
                    Image(systemName: hidden ? "eye.slash" : "eye")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.faint)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hidden ? "显示金额" : "隐藏金额")
                Spacer()
                Image(systemName: "wallet.pass")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(theme.faint)
            }
            Text(Money.masked(netWorth, hidden: hidden))
                .font(theme.heroAmountFont)
                .monospacedDigit()
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            ThemedDashedRule()
            HStack(alignment: .top) {
                StatBlock(title: "总资产", value: Money.masked(assets, hidden: hidden))
                Spacer()
                StatBlock(title: "总负债", value: Money.masked(liabilities, hidden: hidden), alignment: .trailing)
            }
            if let disposable {
                HStack(alignment: .firstTextBaseline, spacing: ReceiptStyle.Space.xs) {
                    Text("可支配资产").font(theme.metaFont).foregroundStyle(theme.faint)
                    DotLeader(color: theme.rule)
                    Text(Money.masked(disposable, hidden: hidden))
                        .font(theme.metaFont).monospacedDigit()
                        .foregroundStyle(theme.ink)
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                .accessibilityHint("不含公积金与社保")
            }
            if assets > 0 && !hidden {
                let ratio = min(max(liabilities / assets, 0), 1)
                VStack(alignment: .leading, spacing: ReceiptStyle.Space.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        ReceiptLabelText(text: "负债率", color: theme.faint)
                        Spacer()
                        Text(String(format: "%.1f%%", liabilities / assets * 100))
                            .font(theme.metaFont).monospacedDigit()
                            .foregroundStyle(theme.ink)
                    }
                    ReceiptBar(ratio: ratio, fill: theme.accent, track: theme.rule.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, ReceiptStyle.Space.l - 4)
        .padding(.vertical, ReceiptStyle.Space.m)
        .receiptSurface(theme, hero: true)
        .padding(.vertical, 4)
    }

    private var defaultBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("净资产")
                    .font(theme.mono(.subheadline))
                    .foregroundStyle(theme.heroFaint)
                Button {
                    withAnimation { hidden.toggle() }
                } label: {
                    Image(systemName: hidden ? "eye.slash.fill" : "eye.fill")
                        .font(.ui(.subheadline))
                        .foregroundStyle(theme.heroFaint)
                }
                .buttonStyle(.plain)
                Spacer()
                Image(systemName: "wallet.pass.fill").foregroundStyle(theme.heroFaint.opacity(0.7))
            }
            if theme.usesDashedRules { ThemedDashedRule() }
            Text(Money.masked(netWorth, hidden: hidden))
                .font(theme.amountSize(36))
                .foregroundStyle(theme.heroInk)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            if theme.usesDashedRules { ThemedDashedRule() }
            HStack {
                StatBlock(title: "总资产", value: Money.masked(assets, hidden: hidden), light: true)
                Spacer()
                StatBlock(title: "总负债", value: Money.masked(liabilities, hidden: hidden), alignment: .trailing, light: true)
            }
            if let disposable {
                HStack(spacing: 6) {
                    Image(systemName: "banknote")
                    Text("可支配资产 " + Money.masked(disposable, hidden: hidden))
                    Text("· 不含公积金与社保").opacity(0.75)
                    Spacer()
                }
                .font(theme.mono(.caption))
                .foregroundStyle(theme.heroFaint)
            }
            if assets > 0 && !hidden {
                let ratio = min(max(liabilities / assets, 0), 1)
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.isReceipt ? theme.rule : Color.white.opacity(0.25))
                            Capsule().fill(theme.isReceipt ? theme.accent : Color.white)
                                .frame(width: geo.size.width * ratio)
                        }
                    }
                    .frame(height: 6)
                    Text("负债率 " + String(format: "%.1f%%", liabilities / assets * 100))
                        .font(theme.mono(.caption2))
                        .foregroundStyle(theme.heroFaint)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: theme.isReceipt ? 4 : 24,
                             style: theme.isReceipt ? .circular : .continuous)
                .fill(LinearGradient(colors: heroColors,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay {
            if theme.usesDashedRules {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(theme.rule, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
        }
        .shadow(color: Color.black.opacity(theme.isReceipt ? 0.04 : 0.12),
                radius: theme.isReceipt ? 2 : 12, y: theme.isReceipt ? 1 : 6)
        .padding(.vertical, 4)
    }
}

/// 净资产折线图
struct NetWorthChart: View {
    let points: [AssetsView.NetWorthPoint]
    let hidden: Bool
    @Environment(\.appTheme) private var theme
    /// 3.5 (26) 小票皮肤：折线用墨色，不用系统紫
    private var lineColor: Color { theme.isReceipt ? theme.ink : Color(hex: "#5E5CE6") }

    var body: some View {
        Chart(points) { p in
            AreaMark(x: .value("月份", p.date, unit: .month), y: .value("净资产", p.value))
                .foregroundStyle(LinearGradient(colors: [lineColor.opacity(theme.isReceipt ? 0.12 : 0.35), lineColor.opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("月份", p.date, unit: .month), y: .value("净资产", p.value))
                .foregroundStyle(lineColor)
                .lineStyle(StrokeStyle(lineWidth: theme.isReceipt ? 1.5 : 2.5))
                .interpolationMethod(.catmullRom)
            PointMark(x: .value("月份", p.date, unit: .month), y: .value("净资产", p.value))
                .foregroundStyle(lineColor)
                .symbolSize(24)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(hidden ? "**" : Money.compact(v))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.defaultDigits))
            }
        }
    }
}

/// 账户行
struct AccountRow: View {
    let account: LedgerAccount
    let balance: Double
    let hidden: Bool

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(icon: account.iconName, color: account.color, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(account.name).lineLimit(1)
                    if !account.includeInNetWorth {
                        Image(systemName: "minus.circle").font(.ui(.caption2)).foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(balanceText)
                    .font(.ui(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(balanceColor)
                if account.type.hasCreditLimit, account.creditLimit > 0, !hidden {
                    CreditUsageBar(used: max(0, -balance), limit: account.creditLimit)
                        .frame(width: 70, height: 4)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var balanceText: String {
        if account.type.isLiability {
            return balance <= 0 ? Money.masked(-balance, hidden: hidden) : "溢缴 " + Money.masked(balance, hidden: hidden)
        }
        return Money.masked(balance, hidden: hidden)
    }

    private var balanceColor: Color {
        if account.type.isLiability { return balance < 0 ? .red : Color.themeIncome }
        return balance < 0 ? .red : .primary
    }

    private var subtitle: String {
        if account.type.hasCreditLimit, account.creditLimit > 0 {
            let used = max(0, -balance)
            var s = hidden ? "额度 ****" : "可用 " + Money.format(max(0, account.creditLimit - used))
            if let days = account.daysUntilRepayment() {
                s += days == 0 ? " · 今天还款" : " · \(days) 天后还款"
            }
            return s
        }
        if !account.note.isEmpty { return account.note }
        return account.type.title
    }
}

struct CreditUsageBar: View {
    let used: Double
    let limit: Double
    @Environment(\.appTheme) private var theme

    @ViewBuilder
    var body: some View {
        let ratio = limit > 0 ? min(max(used / limit, 0), 1) : 0
        if theme.isReceipt {
            // 3.5 (26) 小票皮肤：细条 + 降饱和状态色
            ReceiptBar(ratio: ratio, fill: ratio > 0.8 ? theme.accent : theme.caution, track: theme.rule.opacity(0.6))
        } else {
            defaultBar(ratio)
        }
    }

    private func defaultBar(_ ratio: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(ratio > 0.8 ? Color.red : Color.orange).frame(width: geo.size.width * ratio)
            }
        }
    }
}

/// 长按账户行时的预览卡片
struct AccountPreviewCard: View {
    let account: LedgerAccount
    let balance: Double
    let hidden: Bool

    var body: some View {
        let liability = account.type.isLiability
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CategoryIcon(icon: account.iconName, color: .white, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).font(.ui(.headline))
                    Text(account.type.title + (account.includeInNetWorth ? "" : " · 不计入净资产"))
                        .font(.ui(.caption)).opacity(0.85)
                }
            }
            Text(liability ? (balance <= 0 ? "当前欠款" : "溢缴款") : "当前余额")
                .font(.ui(.caption)).opacity(0.85)
            Text(Money.masked(liability ? abs(balance) : balance, hidden: hidden))
                .font(.uiSystem(size: 30, weight: .bold, design: .rounded))
            if !account.note.isEmpty {
                Text(account.note).font(.ui(.caption)).opacity(0.85).lineLimit(2)
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(width: 300, alignment: .leading)
        .background(LinearGradient(colors: [account.color, account.color.opacity(0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
