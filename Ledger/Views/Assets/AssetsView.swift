import SwiftUI
import SwiftData
import Charts

/// 「资产」页：净资产、各账户余额、净资产趋势
struct AssetsView: View {
    @Environment(\.appTheme) private var theme
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

    /// 与「排序与归档」完全同一个顺序（共用 sortedForDisplay）
    private var activeAccounts: [LedgerAccount] { accounts.sortedForDisplay().filter { !$0.isArchived } }

    /// 按设置里的顺序，把「相邻且同类」的账户合成一张凭条。
    /// 不跨位置归并：显示顺序与「排序与归档」逐行一致。
    struct AccountRun: Identifiable {
        enum Kind { case type(AccountType), social }
        let id: String
        let kind: Kind
        let accounts: [LedgerAccount]
        var isLiability: Bool {
            if case .type(let t) = kind { return t.isLiability }
            return false
        }
    }

    private func accountRuns(_ list: [LedgerAccount]) -> [AccountRun] {
        var runs: [AccountRun] = []
        var currentKey: String?
        var currentKind: AccountRun.Kind = .social
        var bucket: [LedgerAccount] = []
        func flush() {
            guard let key = currentKey, !bucket.isEmpty else { return }
            runs.append(AccountRun(id: "\(key)-\(runs.count)", kind: currentKind, accounts: bucket))
        }
        for a in list {
            let key = a.type.isSocialSecurity ? "social" : a.type.rawValue
            if key != currentKey {
                flush()
                currentKey = key
                currentKind = a.type.isSocialSecurity ? .social : .type(a.type)
                bucket = []
            }
            bucket.append(a)
        }
        flush()
        return runs
    }

    var body: some View {
        let _ = records.count   // 记录变化时刷新余额
        let active = activeAccounts
        let balances = Dictionary(active.map { ($0.id, $0.balance()) }, uniquingKeysWith: { a, _ in a })
        let included = active.filter { $0.includeInNetWorth }
        let totalAssets = included.filter { !$0.type.isLiability }.reduce(0) { $0 + (balances[$1.id] ?? 0) }
        let totalLiabilities = -included.filter { $0.type.isLiability }.reduce(0) { $0 + (balances[$1.id] ?? 0) }
        let assetGroups = groups(active, liability: false)
        let liabilityGroups = groups(active, liability: true)
        // 严格按「排序与归档」里拖动的顺序（sortOrder）排列，不再按账户类型的固定先后打乱
        let social = active.filter { $0.type.isSocialSecurity }
        // 可支配资产：不含公积金与社保类账户
        let socialIncluded = included.filter { $0.type.isSocialSecurity }.reduce(0) { $0 + (balances[$1.id] ?? 0) }

        NavigationStack {
          ScrollViewReader { proxy in
            Group {
                if theme.isReceipt {
                    receiptScrollBody(
                        active: active,
                        balances: balances,
                        totalAssets: totalAssets,
                        totalLiabilities: totalLiabilities,
                        socialIncluded: socialIncluded,
                        assetGroups: assetGroups,
                        liabilityGroups: liabilityGroups,
                        social: social,
                        included: included
                    )
                } else {
                    defaultListBody(
                        active: active,
                        balances: balances,
                        totalAssets: totalAssets,
                        totalLiabilities: totalLiabilities,
                        socialIncluded: socialIncluded,
                        assetGroups: assetGroups,
                        liabilityGroups: liabilityGroups,
                        social: social,
                        included: included
                    )
                }
            }
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
                if !theme.isReceipt {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withAnimation { hideAmounts.toggle() }
                        } label: {
                            Image(systemName: hideAmounts ? "eye.slash" : "eye")
                        }
                        .accessibilityLabel(hideAmounts ? "显示金额" : "隐藏金额")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        addAccountMenu(activeCount: active.count) {
                            Image(systemName: "plus.circle.fill")
                        }
                    }
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

    private func addAccountMenu<LabelView: View>(activeCount: Int, @ViewBuilder label: () -> LabelView) -> some View {
        Menu {
            Button { editorTarget = .new } label: { Label("新建账户", systemImage: "plus") }
            Button { showTransfer = true } label: { Label("转账 / 还款", systemImage: "arrow.left.arrow.right") }
                .disabled(activeCount < 2)
            NavigationLink {
                AccountManagerView()
            } label: {
                Label("排序与归档", systemImage: "arrow.up.arrow.down")
            }
        } label: {
            label()
        }
        .accessibilityIdentifier("assets-add-menu")
    }

    /// 小票皮肤专属：独立 ScrollView 渲染，告别 iOS 27 List(.insetGrouped) 26pt 圆角裁切与液态玻璃顶栏
    private func receiptScrollBody(
        active: [LedgerAccount],
        balances: [UUID: Double],
        totalAssets: Double,
        totalLiabilities: Double,
        socialIncluded: Double,
        assetGroups: [TypeGroup],
        liabilityGroups: [TypeGroup],
        social: [LedgerAccount],
        included: [LedgerAccount]
    ) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    VermilionStamp(text: "BALANCE FOLIO · 资产盘点")
                    Spacer()
                    if active.count >= 2 {
                        Button {
                            showTransfer = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("转账")
                                    .font(theme.serifLabelFont)
                            }
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(LinearGradient(colors: [theme.cardFill, theme.paper], startPoint: .top, endPoint: .bottom))
                            )
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.rule, lineWidth: 1))
                            .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("assets-quick-transfer")
                    }
                    addAccountMenu(activeCount: active.count) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("账户与转账")
                                .font(theme.serifLabelFont)
                        }
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(LinearGradient(colors: [theme.cardFill, theme.paper], startPoint: .top, endPoint: .bottom))
                        )
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.rule, lineWidth: 1))
                        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 2)

                NetWorthCard(
                    netWorth: totalAssets - totalLiabilities,
                    assets: totalAssets,
                    liabilities: totalLiabilities,
                    disposable: social.isEmpty ? nil : totalAssets - socialIncluded,
                    hidden: $hideAmounts
                )

                if active.isEmpty {
                    ThemedEmptyState(
                        "还没有账户",
                        systemImage: "wallet.pass",
                        description: Text("添加储蓄卡、支付宝、微信、信用卡等账户，记账时选择账户即可自动计算余额和净资产。")
                    ) {
                        Button("添加账户") { editorTarget = .new }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(16)
                    .receiptSurface(theme, hero: true)
                } else {
                    // 各类账户凭条：顺序与「排序与归档」逐行一致
                    let runs = accountRuns(active)
                    let firstSocialID = runs.first { if case .social = $0.kind { return true }; return false }?.id
                    ForEach(runs) { run in
                        let subtotal = run.accounts.reduce(0) { $0 + (balances[$1.id] ?? 0) }
                        switch run.kind {
                        case .type(let type) where type.isLiability:
                            receiptAccountSheet(
                                title: "负债 · \(type.title)",
                                badge: "CREDIT VOUCHER",
                                total: "欠 " + Money.masked(max(0, -subtotal), hidden: hideAmounts),
                                totalColor: theme.accent,
                                accounts: run.accounts,
                                balances: balances,
                                footnote: nil
                            )
                        case .type(let type):
                            receiptAccountSheet(
                                title: type.title,
                                badge: "LIQUID ASSET",
                                total: Money.masked(subtotal, hidden: hideAmounts),
                                totalColor: theme.ink,
                                accounts: run.accounts,
                                balances: balances,
                                footnote: nil
                            )
                        case .social:
                            receiptAccountSheet(
                                title: "公积金与社保",
                                badge: "RESERVE FUND",
                                total: Money.masked(subtotal, hidden: hideAmounts),
                                totalColor: theme.ink,
                                accounts: run.accounts,
                                balances: balances,
                                footnote: run.accounts.contains(where: { !$0.includeInNetWorth })
                                    ? "标 ⊖ 的账户退休前不能领取，不计入净资产。"
                                    : nil
                            )
                            .id(run.id == firstSocialID ? "social" : run.id)
                        }
                    }

                    let trend = netWorthTrend(included)
                    if trend.count > 1 {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("净资产趋势 · TREND")
                                    .font(theme.cardTitleFont)
                                    .foregroundStyle(theme.ink)
                                Spacer()
                                ReceiptLabelText(text: "12 MONTHS", color: theme.faint)
                            }
                            ThemedDashedRule()
                            NetWorthChart(points: trend, hidden: hideAmounts)
                                .frame(height: 165)
                                .padding(.vertical, 4)
                        }
                        .padding(ReceiptStyle.Space.m)
                        .receiptSurface(theme, hero: true)
                    }
                }

                let archivedCount = accounts.count - active.count
                if archivedCount > 0 {
                    NavigationLink {
                        AccountManagerView()
                    } label: {
                        HStack {
                            Label("已归档账户（\(archivedCount)）", systemImage: "archivebox")
                                .font(theme.serifLabelFont)
                                .foregroundStyle(theme.faint)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.faint)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 4).fill(theme.cardFill))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.rule, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                Color.clear.frame(height: 28)
            }
            .padding(.horizontal, ReceiptStyle.pageHorizontalMargin)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
        .themedScreenBackground()
    }

    private func receiptAccountSheet(
        title: String,
        badge: String,
        total: String,
        totalColor: Color,
        accounts: [LedgerAccount],
        balances: [UUID: Double],
        footnote: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(theme.cardTitleFont)
                    .foregroundStyle(theme.ink)
                Text("\(accounts.count) 户")
                    .font(theme.labelFont)
                    .foregroundStyle(theme.faint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 2.5).fill(theme.rule.opacity(0.32)))
                Text(badge)
                    .font(theme.labelFont)
                    .foregroundStyle(theme.faint)
                Spacer(minLength: 8)
                Text(total)
                    .font(theme.metaFont)
                    .monospacedDigit()
                    .foregroundStyle(totalColor)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            ThemedDashedRule()
                .padding(.horizontal, 14)

            ForEach(Array(accounts.enumerated()), id: \.element.id) { idx, a in
                if idx > 0 {
                    Rectangle()
                        .fill(theme.rule.opacity(0.65))
                        .frame(height: 0.8)
                        .padding(.horizontal, 14)
                }
                accountRow(a, balances: balances)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }

            if let footnote {
                ThemedDashedRule()
                    .padding(.horizontal, 14)
                Text(footnote)
                    .font(theme.serifLabelFont)
                    .foregroundStyle(theme.faint)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            } else {
                Color.clear.frame(height: 4)
            }
        }
        .receiptSurface(theme, hero: true)
    }

    private func defaultListBody(
        active: [LedgerAccount],
        balances: [UUID: Double],
        totalAssets: Double,
        totalLiabilities: Double,
        socialIncluded: Double,
        assetGroups: [TypeGroup],
        liabilityGroups: [TypeGroup],
        social: [LedgerAccount],
        included: [LedgerAccount]
    ) -> some View {
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
                // 与「排序与归档」逐行一致：相邻同类账户合成一节
                let runs = accountRuns(active)
                let firstSocialID = runs.first { if case .social = $0.kind { return true }; return false }?.id
                ForEach(runs) { run in
                    switch run.kind {
                    case .type(let type):
                        accountSection(TypeGroup(type: type, accounts: run.accounts), balances: balances)
                    case .social:
                        socialSection(run.accounts, balances: balances)
                            .id(run.id == firstSocialID ? "social" : run.id)
                    }
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
    }

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

    /// 连续纸卷上的分类带：小号字距标签 + 该组小计（替代分节标题，保留分类信息）
    private func receiptGroupRow(_ title: String, total: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(theme.serifLabelFont)
                .foregroundStyle(theme.faint)
            Spacer(minLength: 8)
            Text(total)
                .font(theme.metaFont)
                .monospacedDigit()
                .foregroundStyle(theme.faint)
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: -6, trailing: 20))
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// 分类带下的说明（如「标 ⊖ 的账户不计入净资产」）
    private func receiptNoteRow(_ text: String) -> some View {
        Text(text)
            .font(theme.serifLabelFont)
            .foregroundStyle(theme.faint)
            .padding(.vertical, 2)
            .listRowSeparator(.hidden)
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
        // 设计稿：连续纸卷上的行分隔线从纸面左缘起画，不留图标的缩进
        .alignmentGuide(.listRowSeparatorLeading) { _ in theme.isReceipt ? 0 : 16 }
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
        // list 已按 sortOrder 排好：类型分组按其第一个账户出现的先后排列，组内保持拖动顺序
        var order: [AccountType] = []
        var buckets: [AccountType: [LedgerAccount]] = [:]
        for a in list where a.type.isLiability == liability && !a.type.isSocialSecurity {
            if buckets[a.type] == nil { order.append(a.type) }
            buckets[a.type, default: []].append(a)
        }
        return order.map { TypeGroup(type: $0, accounts: buckets[$0] ?? []) }
    }


    /// 最近 12 个月每月月末的净资产
    private func netWorthTrend(_ list: [LedgerAccount]) -> [NetWorthPoint] {
        guard !list.isEmpty else { return [] }
        let cal = DateText.calendar
        let thisMonth = cal.startOfMonth(for: Date())
        var points: [NetWorthPoint] = []
        // 性能：每个账户的流水只展开一次（原先 12 个月 × 每账户都重新展开并去重）
        let flows: [(initial: Double, items: [(date: Date, effect: Double)])] = list.map { a in
            (a.initialBalance, a.allEntries.map { (date: $0.date, effect: $0.effect(on: a)) })
        }
        for back in stride(from: 11, through: 0, by: -1) {
            guard let monthStart = cal.date(byAdding: .month, value: -back, to: thisMonth) else { continue }
            let end: Date = back == 0 ? Date() : (cal.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart).addingTimeInterval(-1)
            let value = flows.reduce(0.0) { sum, flow in
                var total = flow.initial
                for item in flow.items where item.date <= end { total += item.effect }
                return sum + (total * 100).rounded() / 100
            }
            points.append(NetWorthPoint(date: monthStart, value: value))
        }
        // 去掉开头没有任何变化的月份（记账开始之前）
        if let firstRecord = flows.flatMap({ $0.items }).map(\.date).min() {
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
            // 设计稿票头：BALANCE SHEET / VALUATION · CNY + 虚线
            VStack(spacing: ReceiptStyle.Space.xs) {
                HStack {
                    ReceiptLabelText(text: "BALANCE SHEET", color: theme.faint)
                    Spacer()
                    ReceiptLabelText(text: "VALUATION · CNY", color: theme.faint)
                }
                ThemedDashedRule()
            }
            HStack(alignment: .center, spacing: ReceiptStyle.Space.xs) {
                ReceiptLabelText(text: "净资产", color: theme.faint)
                Button {
                    ReceiptHaptics.selection()
                    withAnimation(.snappy(duration: 0.24)) { hidden.toggle() }
                } label: {
                    Image(systemName: hidden ? "eye.slash" : "eye")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.faint)
                        .symbolEffect(.bounce, value: hidden)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hidden ? "显示金额" : "隐藏金额")
                Spacer()
                if assets > 0 {
                    VermilionStamp(text: String(format: "负债率 %.1f%%", liabilities / max(assets, 0.01) * 100))
                }
            }
            Text(Money.masked(netWorth, hidden: hidden))
                .font(theme.isReceipt ? theme.amountFont(30) : theme.heroAmountFont)
                .monospacedDigit()
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText(value: netWorth))
                .animation(.snappy(duration: 0.26), value: netWorth)
                .animation(.snappy(duration: 0.22), value: hidden)
            ThemedDashedRule()
            HStack(alignment: .center) {
                StatBlock(title: "总资产 · ASSETS", value: Money.masked(assets, hidden: hidden))
                    .contentTransition(.numericText(value: assets))
                    .animation(.snappy(duration: 0.26), value: assets)
                Spacer()
                Rectangle()
                    .fill(theme.rule)
                    .frame(width: 1, height: 32)
                Spacer()
                StatBlock(title: "总负债 · DEBT", value: Money.masked(liabilities, hidden: hidden),
                          alignment: .trailing, valueColor: theme.accent)
                    .contentTransition(.numericText(value: liabilities))
                    .animation(.snappy(duration: 0.26), value: liabilities)
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
        }
        .padding(.horizontal, ReceiptStyle.Space.l - 4)
        .padding(.vertical, ReceiptStyle.Space.m)
        .receiptSurface(theme, hero: true, slot: true)
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

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: theme.isReceipt ? ReceiptStyle.Space.s : 12) {
            CategoryIcon(
                icon: account.iconName,
                color: account.color,
                size: theme.isReceipt ? 32 : 38,
                name: account.name,
                kindRaw: account.type.isLiability ? "expense" : "asset"
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(account.name)
                        .font(theme.isReceipt ? theme.serifTitleFont : .ui(.body))
                        .foregroundStyle(theme.isReceipt ? theme.ink : .primary)
                        .lineLimit(1)
                    if !account.includeInNetWorth {
                        Image(systemName: "minus.circle")
                            .font(.ui(.caption2))
                            .foregroundStyle(theme.isReceipt ? theme.faint : .secondary)
                    }
                }
                Text(subtitle)
                    .font(theme.isReceipt ? theme.serifLabelFont : .ui(.caption))
                    .foregroundStyle(theme.isReceipt ? theme.faint : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(balanceText)
                    .font(theme.isReceipt ? theme.amountFont(ReceiptStyle.Size.rowTitle) : .ui(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(balanceColor)
                if account.type.hasCreditLimit, account.creditLimit > 0, !hidden {
                    CreditUsageBar(used: max(0, -balance), limit: account.creditLimit)
                        .frame(width: 72, height: 4)
                }
            }
            if theme.isReceipt {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.faint.opacity(0.75))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var balanceText: String {
        if account.type.isLiability {
            return balance <= 0 ? Money.masked(-balance, hidden: hidden) : "溢缴 " + Money.masked(balance, hidden: hidden)
        }
        return Money.masked(balance, hidden: hidden)
    }

    private var balanceColor: Color {
        if theme.isReceipt {
            if account.type.isLiability { return balance < 0 ? theme.accent : theme.income }
            return balance < 0 ? theme.accent : theme.ink
        }
        if account.type.isLiability { return balance < 0 ? .red : Color.themeIncome }
        return balance < 0 ? .red : .primary
    }

    private var subtitle: String {
        if account.type.hasCreditLimit, account.creditLimit > 0 {
            let used = max(0, -balance)
            let pct = Int((min(max(used / account.creditLimit, 0), 9.99) * 100).rounded())
            var s = hidden ? "额度 ****" : "已用 \(pct)% · 可用 " + Money.format(max(0, account.creditLimit - used))
            if let days = account.daysUntilRepayment() {
                s += days == 0 ? " · 今天还款" : " · \(days)天后还款"
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


extension Array where Element == LedgerAccount {
    /// 账户的统一显示顺序：资产页与「排序与归档」共用，保证两处逐行一致。
    /// sortOrder 相同（旧数据 / 刚新建）时按创建时间、名称兜底，顺序稳定不跳。
    func sortedForDisplay() -> [LedgerAccount] {
        sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.name < $1.name
        }
    }
}
