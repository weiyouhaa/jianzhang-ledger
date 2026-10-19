import SwiftUI
import SwiftData

/// 新建 / 编辑账户
struct AccountEditorView: View {
    let account: LedgerAccount?
    var nextSortOrder: Int = 0

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allAccounts: [LedgerAccount]

    @State private var name = ""
    @State private var type: AccountType = .debit
    @State private var balanceText = ""
    @State private var limitText = ""
    @State private var billingDay = 0
    @State private var repaymentDay = 0
    @State private var icon = AccountType.debit.defaultIcon
    @State private var colorHex = AccountType.debit.defaultColor
    @State private var note = ""
    @State private var includeInNetWorth = true
    @State private var isArchived = false
    @State private var didLoad = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var includeTouched = false
    // 每月缴存（公积金与社保）
    @State private var contributionOn = false
    @State private var contributionText = ""
    @State private var contributionDay = 15

    static let iconOptions: [String] = {
        var list = AccountType.allCases.map(\.defaultIcon)
        list += ["creditcard", "wallet.pass.fill", "dollarsign.circle.fill", "yensign.circle.fill",
                 "bitcoinsign.circle.fill", "chart.pie.fill", "building.2.fill", "car.fill",
                 "person.2.fill", "gift.fill", "graduationcap.fill", "cross.case.fill"]
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        CategoryIcon(icon: icon, color: Color(hex: colorHex), size: 44)
                        TextField("账户名称，如 招商银行储蓄卡", text: $name)
                    }
                    Picker("类型", selection: $type) {
                        Section("资产") {
                            ForEach(AccountType.assetTypes) { t in
                                Label(t.title, systemImage: t.defaultIcon).tag(t)
                            }
                        }
                        Section("负债") {
                            ForEach(AccountType.liabilityTypes) { t in
                                Label(t.title, systemImage: t.defaultIcon).tag(t)
                            }
                        }
                    }
                    .onChange(of: type) { oldValue, newValue in
                        // 图标 / 颜色仍是旧类型默认值时，跟随新类型
                        if icon == oldValue.defaultIcon { icon = newValue.defaultIcon }
                        if colorHex == oldValue.defaultColor { colorHex = newValue.defaultColor }
                        if account == nil && !includeTouched { includeInNetWorth = newValue.defaultIncludeInNetWorth }
                    }
                }

                Section {
                    HStack {
                        Text(type.isLiability ? "初始欠款" : "初始余额")
                        TextField("0.00", text: $balanceText)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    if type.hasCreditLimit {
                        HStack {
                            Text("信用额度")
                            TextField("0.00", text: $limitText)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.decimalPad)
                        }
                        Picker("账单日", selection: $billingDay) {
                            Text("未设置").tag(0)
                            ForEach(1...28, id: \.self) { Text("每月 \($0) 日").tag($0) }
                        }
                        Picker("还款日", selection: $repaymentDay) {
                            Text("未设置").tag(0)
                            ForEach(1...28, id: \.self) { Text("每月 \($0) 日").tag($0) }
                        }
                    } else if type.isInstallmentLoan {
                        Picker("每月还款日", selection: $repaymentDay) {
                            Text("未设置").tag(0)
                            ForEach(1...28, id: \.self) { Text("每月 \($0) 日").tag($0) }
                        }
                    }
                } footer: {
                    Text(type.isLiability
                         ? "记账之前已有的欠款。之后用这张卡消费会增加欠款，转账还款会减少欠款。"
                         : "记账之前账户里已有的金额。余额 = 初始余额 + 收入 − 支出 ± 转账。与实际不符时可在账户详情中「余额校准」。")
                }

                if type.isSocialSecurity {
                    Section {
                        Toggle("每月缴存", isOn: $contributionOn)
                        if contributionOn {
                            HStack {
                                Text("每月金额")
                                TextField("单位 + 个人合计", text: $contributionText)
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(.decimalPad)
                            }
                            Picker("缴存日", selection: $contributionDay) {
                                ForEach(1...28, id: \.self) { Text("每月 \($0) 日").tag($0) }
                            }
                        }
                    } header: {
                        Text("缴存")
                    } footer: {
                        Text("到期自动记一笔「缴存」，只增加这个账户的余额，不计入收入和预算；可在「周期账单」中修改或暂停。公积金提取请在账户详情中点「提取」转到银行卡。")
                    }
                }

                Section("图标") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.iconOptions, id: \.self) { option in
                            Button { icon = option } label: {
                                CategoryIcon(icon: option, color: Color(hex: colorHex), size: 40, selected: icon == option)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("颜色") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(colorChoices, id: \.self) { hex in
                            Button { colorHex = hex } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 30, height: 30)
                                    .overlay(Circle().strokeBorder(Color.primary, lineWidth: colorHex == hex ? 2.5 : 0))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    TextField("备注（卡号尾号、用途等）", text: $note, axis: .vertical)
                    Toggle("计入净资产", isOn: Binding(get: { includeInNetWorth },
                                                    set: { includeInNetWorth = $0; includeTouched = true }))
                    if account != nil {
                        Toggle("归档（隐藏，不再出现在选择列表）", isOn: $isArchived)
                    }
                } footer: {
                    if type.isSocialSecurity {
                        Text("养老保险个人账户、个人养老金、企业年金要到退休才能领取，默认不计入净资产。资产页另外显示不含公积金与社保的「可支配资产」。")
                    }
                }

                if account != nil {
                    Section {
                        Button("删除账户", role: .destructive) { showDeleteConfirm = true }
                            .confirmationDialog("删除「\(name)」？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                                Button("删除", role: .destructive) { delete() }
                                Button("取消", role: .cancel) {}
                            } message: {
                                Text("相关的 \(account?.allEntries.count ?? 0) 笔记录会保留，但不再关联此账户。此操作不可撤销。")
                            }
                    } footer: {
                        Text("删除后，相关记录会保留，但不再关联此账户。只是不想再用时建议「归档」。")
                    }
                }
            }
            .navigationTitle(account == nil ? "新建账户" : "编辑账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("无法保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear(perform: load)
        }
    }

    private var colorChoices: [String] {
        var list = AccountType.allCases.map(\.defaultColor) + CategoryEditorView.colorOptions
        var seen = Set<String>()
        list = list.filter { seen.insert($0.uppercased()).inserted }
        return Array(list.prefix(24))
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let a = account else { return }
        name = a.name
        type = a.type
        let shown = a.type.isLiability ? -a.initialBalance : a.initialBalance
        balanceText = shown == 0 ? "" : String(format: "%.2f", shown)
        limitText = a.creditLimit == 0 ? "" : String(format: "%.2f", a.creditLimit)
        billingDay = a.billingDay
        repaymentDay = a.repaymentDay
        icon = a.iconName
        colorHex = a.colorHex
        note = a.note
        includeInNetWorth = a.includeInNetWorth
        isArchived = a.isArchived
        if let rule = RecurringEngine.contributionRule(for: a, in: context) {
            contributionOn = !rule.isPaused
            contributionText = Money.plain(rule.amount)
            contributionDay = min(28, max(1, rule.monthDay))
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if allAccounts.contains(where: { $0.name == trimmed && $0.id != account?.id }) {
            errorMessage = "已有同名账户「\(trimmed)」"
            return
        }
        let entered = Money.parse(balanceText) ?? 0
        let initial = type.isLiability ? -entered : entered
        let target: LedgerAccount
        if let account {
            target = account
            if account.name != trimmed {
                // 同步旧版账户文字，便于导出与搜索
                for r in account.records ?? [] where r.account == account.name { r.account = trimmed }
            }
        } else {
            target = LedgerAccount(name: trimmed, type: type, sortOrder: nextSortOrder)
            context.insert(target)
        }
        target.name = trimmed
        target.type = type
        target.initialBalance = initial
        target.creditLimit = type.hasCreditLimit ? max(0, Money.parse(limitText) ?? 0) : 0
        target.billingDay = type.hasCreditLimit ? billingDay : 0
        target.repaymentDay = (type.hasCreditLimit || type.isInstallmentLoan) ? repaymentDay : 0
        target.icon = icon
        target.colorHex = colorHex
        target.note = note
        target.includeInNetWorth = includeInNetWorth
        target.isArchived = isArchived
        syncContributionRule(for: target)
        try? context.save()
        RecurringEngine.run(in: context)
        Task { await NotificationManager.shared.rescheduleRecurring(in: context) }
        dismiss()
    }

    /// 「每月缴存」对应一个自动记账的周期账单（类型：缴存）
    private func syncContributionRule(for target: LedgerAccount) {
        let existing = RecurringEngine.contributionRule(for: target, in: context)
        let amount = Money.parse(contributionText) ?? 0
        guard type.isSocialSecurity, contributionOn, amount > 0 else {
            if let existing, type.isSocialSecurity { existing.isPaused = true }
            if let existing, !type.isSocialSecurity { context.delete(existing) }
            return
        }
        let cal = DateText.calendar
        let rule: RecurringRule
        if let existing {
            rule = existing
            if rule.monthDay != contributionDay {
                // 改了缴存日：从现在起按新日期，不补记
                rule.lastProcessedAt = Date()
            }
        } else {
            let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
            rule = RecurringRule(name: target.name + "缴存", amount: amount, kind: .contribution, frequency: .monthly, startDate: start)
            // 从下一次缴存日开始记账，之前的余额请填在「初始余额」中
            rule.lastProcessedAt = Date()
            context.insert(rule)
        }
        rule.name = target.name + "缴存"
        rule.amount = (amount * 100).rounded() / 100
        rule.kind = .contribution
        rule.accountID = target.id.uuidString
        rule.frequency = .monthly
        rule.interval = 1
        rule.monthDay = contributionDay
        rule.lastDayOfMonth = false
        rule.autoCreate = true
        rule.isPaused = false
    }

    private func delete() {
        guard let account else { return }
        if ModeDefaults.string(forKey: SettingsKey.defaultAccount) == account.name {
            ModeDefaults.set("", forKey: SettingsKey.defaultAccount)
        }
        context.delete(account)
        try? context.save()
        dismiss()
    }
}

/// 账户排序与归档
struct AccountManagerView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerAccount.sortOrder) private var accounts: [LedgerAccount]
    @State private var editorTarget: AccountEditorTarget?

    var body: some View {
        let active = accounts.filter { !$0.isArchived }
        let archived = accounts.filter { $0.isArchived }
        List {
            Section {
                ForEach(active) { a in
                    row(a)
                }
                .onMove { from, to in
                    var list = active
                    list.move(fromOffsets: from, toOffset: to)
                    for (i, a) in list.enumerated() { a.sortOrder = i }
                    try? context.save()
                }
            } header: {
                Text("使用中")
            } footer: {
                Text("点右上角「编辑」拖动排序；左滑可归档。")
            }

            if !archived.isEmpty {
                Section("已归档") {
                    ForEach(archived) { a in
                        row(a)
                    }
                }
            }
        }
        .navigationTitle("排序与归档")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { editorTarget = .new } label: { Image(systemName: "plus") }
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
    }

    private func row(_ a: LedgerAccount) -> some View {
        Button { editorTarget = .edit(a) } label: {
            HStack(spacing: 12) {
                CategoryIcon(icon: a.iconName, color: a.color, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).foregroundStyle(.primary)
                    Text(a.type.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Money.format(a.type.isLiability ? -a.balance() : a.balance()))
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions {
            if a.isArchived {
                Button {
                    a.isArchived = false
                    a.sortOrder = (accounts.filter { !$0.isArchived }.map(\.sortOrder).max() ?? -1) + 1
                    try? context.save()
                } label: { Label("恢复", systemImage: "tray.and.arrow.up") }
                    .tint(.green)
            } else {
                Button {
                    a.isArchived = true
                    try? context.save()
                } label: { Label("归档", systemImage: "archivebox") }
                    .tint(.orange)
            }
        }
    }
}
