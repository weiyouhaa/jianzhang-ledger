import SwiftUI
import SwiftData

/// 周期账单列表：下次日期、本月预计金额
struct RecurringListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RecurringRule.createdAt) private var rules: [RecurringRule]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \LedgerAccount.sortOrder) private var accounts: [LedgerAccount]
    @State private var pendingDelete: RecurringRule?

    var body: some View {
        let keys = RecurringEngine.existingKeys(in: context)
        let active = rules.filter { !$0.isPaused }
        let monthExpense = active.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount * Double(RecurringEngine.occurrencesThisMonth($1)) }
        let monthIncome = active.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount * Double(RecurringEngine.occurrencesThisMonth($1)) }
        let sorted = rules.sorted { a, b in
            if a.isPaused != b.isPaused { return !a.isPaused }
            return (RecurringEngine.nextOccurrence(a, keys: keys) ?? .distantFuture) < (RecurringEngine.nextOccurrence(b, keys: keys) ?? .distantFuture)
        }
        List {
            Section {
                HStack {
                    StatBlock(title: "本月预计支出", value: Money.format(monthExpense))
                    Spacer()
                    StatBlock(title: "本月预计收入", value: Money.format(monthIncome), alignment: .trailing)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("「自动记账」到期后打开 App 时自动补记（不会重复）；「仅提醒」到期时发通知，可在通知上点「已付」或「记一笔」。")
            }

            if rules.isEmpty {
                ContentUnavailableView("还没有周期账单", systemImage: "arrow.triangle.2.circlepath",
                                       description: Text("房租、会员、还款、工资……点右上角 ＋ 添加，或在记录详情里「设为周期账单」"))
                    .listRowBackground(Color.clear)
            } else {
                Section("全部 \(rules.count) 项") {
                    ForEach(sorted) { rule in
                        NavigationLink {
                            RecurringEditorView(rule: rule)
                        } label: {
                            row(rule, next: RecurringEngine.nextOccurrence(rule, keys: keys), keys: keys)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { pendingDelete = rule } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .navigationTitle("周期账单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    RecurringEditorView(rule: nil)
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("删除这个周期账单？", isPresented: deleteBinding, presenting: pendingDelete) { rule in
            Button("删除", role: .destructive) {
                context.delete(rule)
                try? context.save()
                Task { await NotificationManager.shared.rescheduleRecurring(in: context) }
            }
            Button("取消", role: .cancel) {}
        } message: { rule in
            Text("\(rule.name) · \(rule.kind.title) \(Money.format(rule.amount)) · \(rule.spec.description(calendar: DateText.calendar))\n已生成的记录会保留。")
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func row(_ rule: RecurringRule, next: Date?, keys: [String: [LedgerRecord]]) -> some View {
        let category = categories.first(where: { $0.id.uuidString == rule.categoryID })
        let overdue = !rule.autoCreate && next.map { $0 < Date() && !RecurringEngine.isPaid(rule, occurrence: $0, keys: keys) } == true
        return HStack(spacing: 12) {
            if rule.kind == .transfer {
                CategoryIcon(icon: "arrow.left.arrow.right", color: Color(hex: "#30B0C7"), size: 38)
            } else {
                CategoryIcon(icon: category?.icon ?? "arrow.triangle.2.circlepath", color: category?.color ?? .gray, size: 38)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.name).lineLimit(1)
                    Text(rule.autoCreate ? "自动" : "提醒")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill((rule.autoCreate ? Color.green : Color.orange).opacity(0.15)))
                        .foregroundStyle(rule.autoCreate ? Color.green : Color.orange)
                    if rule.remindEnabled { Image(systemName: "bell.fill").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(rule.spec.description(calendar: DateText.calendar) + " · " + nextText(next, paused: rule.isPaused, overdue: overdue))
                    .font(.caption)
                    .foregroundStyle(overdue ? Color.orange : Color.secondary)
            }
            Spacer()
            Text((rule.kind == .income ? "+" : (rule.kind == .expense ? "-" : "")) + Money.format(rule.amount))
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(rule.kind == .income ? Color.green : (rule.kind == .transfer ? Color.secondary : Color.primary))
        }
        .opacity(rule.isPaused ? 0.5 : 1)
    }

    private func nextText(_ next: Date?, paused: Bool, overdue: Bool) -> String {
        if paused { return "已暂停" }
        guard let next else { return "已结束" }
        let cal = DateText.calendar
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: next)).day ?? 0
        let date = DateText.shortDate.string(from: next)
        if overdue { return "\(date) 待付" }
        switch days {
        case 0: return "今天"
        case 1: return "明天"
        default: return "下次 \(date)（\(days) 天后）"
        }
    }
}

/// 新建 / 编辑周期账单
struct RecurringEditorView: View {
    let rule: RecurringRule?
    /// 从已有记录「设为周期账单」
    var template: LedgerRecord? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \LedgerAccount.sortOrder) private var accounts: [LedgerAccount]

    @State private var name = ""
    @State private var amountText = ""
    @State private var kind: RecordKind = .expense
    @State private var categoryID: UUID?
    @State private var accountID: UUID?
    @State private var toAccountID: UUID?
    @State private var note = ""
    @State private var frequency: RecurrenceFrequency = .monthly
    @State private var interval = 1
    @State private var weekday = 2
    @State private var monthDay = 1
    @State private var lastDay = false
    @State private var startDate = Date()
    @State private var endMode = 0          // 0 永不 1 截止日期 2 次数
    @State private var endDate = Date()
    @State private var maxCount = 12
    @State private var autoCreate = true
    @State private var remindEnabled = false
    @State private var remindDaysBefore = 1
    @State private var remindTime = Date()
    @State private var isPaused = false
    @State private var didLoad = false
    @State private var showDelete = false
    @State private var permissionDenied = false

    private var amount: Double? { Money.parse(amountText) }

    private var canSave: Bool {
        guard let a = amount, a > 0, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if kind == .transfer { return accountID != nil && toAccountID != nil && accountID != toAccountID }
        return true
    }

    private var previewSpec: RecurrenceSpec {
        RecurrenceSpec(frequency: frequency, interval: interval, weekday: weekday, monthDay: monthDay, lastDayOfMonth: lastDay,
                       start: startDate, end: endMode == 1 ? endDate : nil, maxCount: endMode == 2 ? maxCount : 0)
    }

    var body: some View {
        Form {
            Section {
                TextField("名称，如：房租、视频会员", text: $name)
                Picker("类型", selection: $kind) {
                    ForEach(RecordKind.editorKinds) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text(Money.symbol).foregroundStyle(.secondary)
                    TextField("金额", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.title3.weight(.semibold).monospacedDigit())
                }
            }

            Section {
                if kind == .transfer {
                    accountPicker("转出账户", $accountID, allowNone: false)
                    accountPicker("转入账户", $toAccountID, allowNone: false)
                } else {
                    Picker("分类", selection: $categoryID) {
                        ForEach(categories.filter { $0.kind == kind }) { c in
                            Label(c.name, systemImage: c.icon).tag(UUID?.some(c.id))
                        }
                    }
                    accountPicker("账户", $accountID, allowNone: true)
                }
                TextField("备注（可选）", text: $note)
            }

            Section {
                Picker("频率", selection: $frequency) {
                    ForEach(RecurrenceFrequency.allCases) { Text($0.title).tag($0) }
                }
                Stepper("每 \(interval) \(frequency.unit)", value: $interval, in: 1...30)
                switch frequency {
                case .weekly:
                    Picker("星期", selection: $weekday) {
                        ForEach(1...7, id: \.self) { d in
                            Text("周" + ["日", "一", "二", "三", "四", "五", "六"][d - 1]).tag(d)
                        }
                    }
                case .monthly:
                    Toggle("每月最后一天", isOn: $lastDay)
                    if !lastDay {
                        Picker("日期", selection: $monthDay) {
                            ForEach(1...31, id: \.self) { Text("\($0) 日").tag($0) }
                        }
                    }
                default:
                    EmptyView()
                }
                DatePicker(frequency == .yearly ? "开始（每年同日）" : "开始", selection: $startDate)
                Picker("结束", selection: $endMode) {
                    Text("永不").tag(0)
                    Text("截止日期").tag(1)
                    Text("按次数").tag(2)
                }
                if endMode == 1 {
                    DatePicker("截止", selection: $endDate, in: startDate..., displayedComponents: .date)
                } else if endMode == 2 {
                    Stepper("共 \(maxCount) 次", value: $maxCount, in: 1...600)
                }
            } header: {
                Text("重复")
            } footer: {
                Text(previewText)
            }

            Section {
                Picker("到期时", selection: $autoCreate) {
                    Text("自动记账").tag(true)
                    Text("仅提醒").tag(false)
                }
                Toggle("通知提醒", isOn: $remindEnabled)
                if remindEnabled {
                    Stepper(remindDaysBefore == 0 ? "当天提醒" : "提前 \(remindDaysBefore) 天", value: $remindDaysBefore, in: 0...14)
                    DatePicker("提醒时间", selection: $remindTime, displayedComponents: .hourAndMinute)
                }
                if rule != nil { Toggle("暂停", isOn: $isPaused) }
            } footer: {
                Text(autoCreate ? "开始日期早于今天时，会补记之前的各期。" : "仅提醒的账单不会自动记账，在通知上点「已付」即可记一笔。")
            }

            if let rule {
                Section {
                    Button("删除这个周期账单", role: .destructive) { showDelete = true }
                        .frame(maxWidth: .infinity)
                        .confirmationDialog("删除这个周期账单？", isPresented: $showDelete, titleVisibility: .visible) {
                            Button("删除", role: .destructive) {
                                context.delete(rule)
                                try? context.save()
                                Task { await NotificationManager.shared.rescheduleRecurring(in: context) }
                                dismiss()
                            }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("\(rule.name) · \(rule.kind.title) \(Money.format(rule.amount))\n已生成的记录会保留。")
                        }
                }
            }
        }
        .navigationTitle(rule == nil ? "新建周期账单" : "编辑周期账单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save).fontWeight(.semibold).disabled(!canSave)
            }
        }
        .onAppear(perform: load)
        .onChange(of: kind) { _, k in
            if k.countsInStats && !categories.contains(where: { $0.id == categoryID && $0.kind == k }) {
                categoryID = categories.first(where: { $0.kind == k })?.id
            }
        }
        .onChange(of: remindEnabled) { _, on in
            guard on else { return }
            Task { @MainActor in
                if !(await NotificationManager.shared.requestAuthorization()) {
                    remindEnabled = false
                    permissionDenied = true
                }
            }
        }
        .alert("无法发送通知", isPresented: $permissionDenied) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请在系统「设置 › 通知 › 简账」中允许通知。")
        }
    }

    private var previewText: String {
        let cal = DateText.calendar
        let spec = previewSpec
        var list: [Date] = []
        var cursor = Date().addingTimeInterval(-1)
        if spec.start > cursor { cursor = spec.start.addingTimeInterval(-1) }
        for _ in 0..<3 {
            guard let n = spec.next(after: cursor, calendar: cal) else { break }
            list.append(n)
            cursor = n
        }
        let desc = spec.description(calendar: cal)
        if list.isEmpty { return desc + " · 已没有后续日期" }
        return desc + " · 接下来：" + list.map { DateText.shortDate.string(from: $0) }.joined(separator: "、")
    }

    private func accountPicker(_ title: String, _ selection: Binding<UUID?>, allowNone: Bool) -> some View {
        Picker(title, selection: selection) {
            if allowNone || selection.wrappedValue == nil { Text(allowNone ? "不选择" : "请选择").tag(UUID?.none) }
            ForEach(accounts.filter { !$0.isArchived || $0.id == selection.wrappedValue }) { a in
                Label(a.name, systemImage: a.iconName).tag(UUID?.some(a.id))
            }
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let cal = DateText.calendar
        let source: RecurringRule? = rule ?? template.map { RecurringEngine.makeRule(from: $0) }
        if let r = source {
            name = r.name
            amountText = r.amount > 0 ? Money.plain(r.amount) : ""
            kind = r.kind
            categoryID = UUID(uuidString: r.categoryID)
            accountID = UUID(uuidString: r.accountID)
            toAccountID = UUID(uuidString: r.toAccountID)
            note = r.note
            frequency = r.frequency
            interval = max(1, r.interval)
            weekday = r.weekday
            monthDay = r.monthDay
            lastDay = r.lastDayOfMonth
            startDate = r.startDate
            if let e = r.endDate { endMode = 1; endDate = e } else if r.maxCount > 0 { endMode = 2; maxCount = r.maxCount }
            autoCreate = r.autoCreate
            remindEnabled = r.remindEnabled
            remindDaysBefore = r.remindDaysBefore
            remindTime = cal.date(bySettingHour: r.remindHour, minute: r.remindMinute, second: 0, of: Date()) ?? Date()
            isPaused = r.isPaused
        } else {
            categoryID = categories.first(where: { $0.kind == .expense })?.id
            monthDay = cal.component(.day, from: Date())
            weekday = cal.component(.weekday, from: Date())
            startDate = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
            remindTime = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        }
        if rule == nil, template == nil { remindDaysBefore = 1 }
    }

    private func save() {
        guard let amount, canSave else { return }
        let cal = DateText.calendar
        let target: RecurringRule
        let isNew = rule == nil
        if let rule {
            target = rule
        } else {
            target = RecurringRule(name: "", amount: 0, kind: kind, frequency: frequency, startDate: startDate)
            context.insert(target)
        }
        let scheduleChanged = isNew || target.spec != previewSpec
        target.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        target.amount = (amount * 100).rounded() / 100
        target.kind = kind
        target.categoryID = kind.countsInStats ? (categoryID?.uuidString ?? "") : ""
        target.accountID = accountID?.uuidString ?? ""
        target.toAccountID = kind == .transfer ? (toAccountID?.uuidString ?? "") : ""
        target.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        target.frequency = frequency
        target.interval = interval
        target.weekday = weekday
        target.monthDay = monthDay
        target.lastDayOfMonth = lastDay
        target.startDate = startDate
        target.endDate = endMode == 1 ? endDate : nil
        target.maxCount = endMode == 2 ? maxCount : 0
        target.autoCreate = autoCreate
        target.remindEnabled = remindEnabled
        target.remindDaysBefore = remindDaysBefore
        target.remindHour = cal.component(.hour, from: remindTime)
        target.remindMinute = cal.component(.minute, from: remindTime)
        target.isPaused = isPaused
        if let template, isNew {
            // 这条记录本身就是第一期：不再重复生成
            target.merchant = template.merchant
            target.lastProcessedAt = template.date
            if template.recurringKey.isEmpty, cal.isDate(template.date, inSameDayAs: startDate) {
                template.recurringKey = target.key(for: template.date)
            }
        } else if !isNew && scheduleChanged {
            // 修改了周期：从现在起按新周期生成，不补记历史
            target.lastProcessedAt = max(target.lastProcessedAt ?? .distantPast, Date())
        }
        try? context.save()
        RecurringEngine.run(in: context)
        Task { await NotificationManager.shared.rescheduleRecurring(in: context) }
        dismiss()
    }
}
