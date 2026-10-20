import SwiftUI
import SwiftData
import PhotosUI

/// 新建 / 编辑记录（支出、收入、转账；余额校准记录也可在此修改）
struct RecordEditorView: View {
    let record: LedgerRecord?
    var initialDate: Date = Date()
    var initialKind: RecordKind = .expense
    var presetAccountID: UUID? = nil
    /// 周期账单提醒「记一笔」时带入的内容
    var prefill: RecordPrefill? = nil
    /// 资产页长按信用卡「还款」：直接进入信用卡还款，并选好这张卡
    var repayCardID: UUID? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LedgerCategory.sortOrder) private var allCategories: [LedgerCategory]
    @Query(sort: \LedgerAccount.sortOrder) private var allAccounts: [LedgerAccount]
    @AppStorage(SettingsKey.defaultAccount) private var defaultAccount = ""
    @Environment(\.ledgerPrefs) private var prefs

    @State private var kind: RecordKind = .expense
    @State private var amountText = ""
    @State private var selectedCategoryID: UUID?
    @State private var note = ""
    @State private var merchant = ""
    @State private var accountID: UUID?
    @State private var toAccountID: UUID?
    @State private var feeText = ""
    @State private var date = Date()
    @State private var source = "manual"
    @State private var didLoad = false
    @State private var recurringKey = ""
    /// 用户是否手动改过账户 / 分类（自动带出时不覆盖用户的选择）
    @State private var accountTouched = false
    @State private var categoryTouched = false
    @State private var ruleHint: String?
    /// 支出页的「信用卡还款」：保存为 付款账户 → 负债账户 的转账（付款账户减少，欠款减少，默认不计入支出统计）
    @State private var repayMode = false

    @State private var photoItem: PhotosPickerItem?
    @State private var isRecognizing = false
    @State private var alertMessage: String?
    @State private var showDeleteConfirm = false
    @State private var detectedReceipts: [ParsedReceipt] = []
    @State private var showReceiptPicker = false
    /// 上次识图使用的引擎（Apple 智能 / 规则）及回退说明
    @State private var ocrEngineLine: String?
    @FocusState private var amountFocused: Bool

    private var categories: [LedgerCategory] {
        allCategories.filter { $0.kind == kind }
    }

    /// 可选账户：未归档的，以及当前记录已关联的
    private var selectableAccounts: [LedgerAccount] {
        allAccounts.filter { !$0.isArchived || $0.id == accountID || $0.id == toAccountID }
    }

    /// 还款的付款账户：非负债账户
    private var payerAccounts: [LedgerAccount] {
        selectableAccounts.filter { !$0.type.isLiability || $0.id == accountID }
    }

    /// 还款的目标：信用卡 / 花呗 / 贷款等负债账户
    private var cardAccounts: [LedgerAccount] {
        selectableAccounts.filter { $0.type.isLiability || $0.id == toAccountID }
    }

    private var selectedCard: LedgerAccount? {
        allAccounts.first(where: { $0.id == toAccountID })
    }

    /// 当前欠款（编辑已有还款时，加回这条记录本身还掉的金额）
    private var fullRepaymentAmount: Double? {
        guard let card = selectedCard, card.type.isLiability else { return nil }
        var owed = card.debt
        if let record, record.isCreditRepayment, record.toAccount?.id == card.id {
            owed = max(0, -(card.balance() - record.amount))
        }
        return owed > 0.004 ? (owed * 100).rounded() / 100 : nil
    }

    private var parsedAmount: Double? { Money.parse(amountText) }

    private var amountValid: Bool {
        guard let a = parsedAmount else { return false }
        return kind == .adjustment ? a != 0 : a > 0
    }

    private var canSave: Bool {
        guard amountValid else { return false }
        if repayMode {
            return accountID != nil && accountID != toAccountID && (selectedCard?.type.isLiability ?? false)
        }
        if kind == .transfer {
            return accountID != nil && toAccountID != nil && accountID != toAccountID
        }
        if kind == .contribution || kind == .adjustment { return accountID != nil }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if kind == .adjustment {
                        Label("余额校准（不计入收支统计）", systemImage: "slider.horizontal.3")
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    } else if kind == .contribution {
                        Label("缴存（增加账户余额，不计入收入）", systemImage: "tray.and.arrow.down.fill")
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    } else {
                        Picker("类型", selection: $kind) {
                            ForEach(RecordKind.editorKinds) { k in
                                Text(k.title).tag(k)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowSeparator(.hidden)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Money.symbol)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $amountText)
                            .keyboardType(kind == .adjustment ? .numbersAndPunctuation : .decimalPad)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(amountColor)
                            .focused($amountFocused)
                    }
                    .padding(.vertical, 4)
                }

                if kind == .transfer {
                    transferSection
                } else if kind == .contribution {
                    Section {
                        accountPicker(title: "缴存账户", selection: $accountID, allowNone: false)
                    } footer: {
                        Text("公积金、医保、养老保险等每月缴存。单位和个人缴纳部分都可以记在这里；提取请用「转账」转到银行卡。")
                    }
                } else if kind == .adjustment {
                    Section {
                        accountPicker(title: "账户", selection: $accountID, allowNone: false)
                    } footer: {
                        Text("正数表示调增余额，负数表示调减。")
                    }
                } else {
                    categorySection
                    if repayMode { repaymentSection }
                }

                Section {
                    DatePicker("时间", selection: $date)
                    TextField("备注", text: $note)
                    if kind.countsInStats && !repayMode {
                        TextField("商户（可选）", text: $merchant)
                        accountPicker(title: "账户", selection: userAccountBinding, allowNone: true)
                    }
                } footer: {
                    if let ruleHint, kind.countsInStats, !repayMode {
                        Label(ruleHint, systemImage: "wand.and.stars")
                    }
                }

                if kind.countsInStats {
                    Section {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            HStack {
                                Label("从支付截图识别填写", systemImage: "text.viewfinder")
                                Spacer()
                                if isRecognizing { ProgressView() }
                            }
                        }
                        .disabled(isRecognizing)
                        .confirmationDialog("识别到 \(detectedReceipts.count) 笔交易，选择要填写的一笔", isPresented: $showReceiptPicker,
                                            titleVisibility: .visible) {
                            ForEach(Array(detectedReceipts.enumerated()), id: \.offset) { _, r in
                                Button(Self.receiptTitle(r)) { apply(r) }
                            }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("其余几笔可再次识别后选择，或用快捷指令「识图记账」一次全部记入。" + (ocrEngineLine.map { "\n" + $0 } ?? ""))
                        }
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("在本机识别金额、商户、时间与付款账户，图片不会上传。")
                            if let ocrEngineLine {
                                Text(ocrEngineLine)
                                    .font(.caption2)
                                    .accessibilityIdentifier("ocr-engine-line")
                            }
                        }
                    }
                }

                if let record, record.kind != .adjustment {
                    Section {
                        NavigationLink {
                            RecurringEditorView(rule: nil, template: record)
                        } label: {
                            Label(record.recurringKey.isEmpty ? "设为周期账单" : "由周期账单生成 · 再建一个周期",
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                    } footer: {
                        Text("按这条记录的金额、分类和账户，每月 / 每周等自动记账或提醒。")
                    }
                }

                if record != nil {
                    Section {
                        Button("删除这条记录", role: .destructive) { showDeleteConfirm = true }
                            .frame(maxWidth: .infinity)
                            // 挂在按钮上：iOS 26 的气泡指向这个按钮，iOS 17/18 仍是底部操作表
                            .confirmationDialog("删除这条记录？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                                Button("删除", role: .destructive) { deleteRecord() }
                                Button("取消", role: .cancel) {}
                            } message: {
                                Text("\(record?.deleteSummary ?? "")\n删除后无法恢复。")
                            }
                    }
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { amountFocused = false }
                }
            }
            .onAppear {
                load()
                // 预加载端侧模型，选图识别时少等冷启动
                AppleIntelligenceExtractor.prewarm()
            }
            .onChange(of: kind) { _, newKind in
                if newKind != .expense { repayMode = false }
                if newKind.countsInStats && !categories.contains(where: { $0.id == selectedCategoryID }) {
                    selectedCategoryID = categories.first?.id
                }
            }
            .onChange(of: merchant) { _, value in
                applyRule(merchant: value, overrideCategory: !categoryTouched)
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await recognize(item) }
            }
            .alert("提示", isPresented: alertBinding) {
                Button("好", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }

        }
    }

    // MARK: - Sections

    private var navTitle: String {
        if kind == .contribution { return record == nil ? "缴存" : "编辑缴存" }
        if repayMode { return record == nil ? "信用卡还款" : "编辑还款" }
        if record == nil { return kind == .transfer ? "转账" : "记一笔" }
        return kind == .adjustment ? "余额校准" : "编辑记录"
    }

    private var amountColor: Color {
        if repayMode { return Color(hex: "#30B0C7") }
        switch kind {
        case .income: return .green
        case .contribution: return Color(hex: "#E8A33D")
        case .expense: return .primary
        case .transfer, .adjustment: return Color(hex: "#30B0C7")
        }
    }

    private var categorySection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 14) {
                if kind == .expense {
                    VStack(spacing: 6) {
                        CategoryIcon(icon: LedgerRecord.repaymentIcon, color: LedgerRecord.repaymentColor, size: 44, selected: repayMode)
                        Text("信用卡还款")
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(repayMode ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("tile-card-repayment")
                    .onTapGesture {
                        UISelectionFeedbackGenerator().selectionChanged()
                        enterRepayMode(card: nil)
                    }
                }
                ForEach(categories) { c in
                    VStack(spacing: 6) {
                        CategoryIcon(icon: c.icon, color: c.color, size: 44, selected: !repayMode && c.id == selectedCategoryID)
                        Text(c.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(!repayMode && c.id == selectedCategoryID ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UISelectionFeedbackGenerator().selectionChanged()
                        if repayMode {
                            repayMode = false
                            if allAccounts.first(where: { $0.id == accountID })?.type.isLiability == true { accountID = nil }
                        }
                        selectedCategoryID = c.id
                        categoryTouched = true
                        ruleHint = nil
                        // 新记录：带出该分类上次使用的账户
                        if record == nil, !accountTouched, let a = RuleStore.lastAccount(for: c, in: context) {
                            accountID = a.id
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        } header: {
            HStack {
                Text("分类")
                Spacer()
                NavigationLink("管理") { CategoryManagerView(initialKind: kind) }
                    .font(.caption)
                    .textCase(nil)
            }
        }
    }

    private var transferSection: some View {
        Section {
            accountPicker(title: "转出账户", selection: $accountID, allowNone: false)
            accountPicker(title: "转入账户", selection: $toAccountID, allowNone: false)
            HStack {
                Text("手续费")
                Spacer()
                TextField("0.00", text: $feeText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 140)
            }
        } header: {
            Text("转账 / 还款")
        } footer: {
            if accountID != nil && accountID == toAccountID {
                Text("转出和转入账户不能相同。").foregroundStyle(.red)
            } else if allAccounts.isEmpty {
                Text("还没有账户，请先在「资产」页添加。")
            } else {
                Text("转入信用卡 / 花呗即为还款。转账不计入收支统计和预算，手续费从转出账户扣除。")
            }
        }
    }

    private var repaymentSection: some View {
        Section {
            accountPicker(title: "付款账户", selection: $accountID, allowNone: false, options: payerAccounts)
                .accessibilityIdentifier("repay-from")
            accountPicker(title: "还款信用卡", selection: $toAccountID, allowNone: false, options: cardAccounts)
                .accessibilityIdentifier("repay-card")
            if let full = fullRepaymentAmount {
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    amountText = String(format: "%.2f", full)
                    amountFocused = false
                } label: {
                    Label("全额还款 \(Money.format(full))", systemImage: "checkmark.circle")
                }
                .accessibilityIdentifier("repay-full")
            }
        } header: {
            Text("信用卡还款")
        } footer: {
            if accountID != nil && accountID == toAccountID {
                Text("付款账户和信用卡不能相同。").foregroundStyle(.red)
            } else if cardAccounts.isEmpty {
                Text("还没有信用卡 / 花呗等负债账户，请先在「资产」页添加。")
            } else {
                Text(RepaymentSetting.includeInExpense(prefs)
                     ? "付款账户余额减少，信用卡欠款同步减少。已设置「信用卡还款计入支出」，会计入支出统计。"
                     : "付款账户余额减少，信用卡欠款同步减少。刷卡消费已记为支出，还款默认不再计入支出（可在设置中开启）。")
            }
        }
    }

    /// 切到信用卡还款：付款账户默认用默认账户（非负债），信用卡默认选有欠款的第一张
    private func enterRepayMode(card: UUID?) {
        repayMode = true
        ruleHint = nil
        if let card { toAccountID = card }
        if selectedCard?.type.isLiability != true {
            let active = allAccounts.filter { $0.type.isLiability && !$0.isArchived }
            toAccountID = (active.first(where: { $0.type.hasCreditLimit && $0.debt > 0 })
                ?? active.first(where: { $0.type.hasCreditLimit }) ?? active.first)?.id
        }
        let current = allAccounts.first(where: { $0.id == accountID })
        if current == nil || current?.type.isLiability == true || accountID == toAccountID {
            let payers = allAccounts.filter { !$0.type.isLiability && !$0.isArchived && !$0.type.isSocialSecurity && $0.id != toAccountID }
            accountID = (payers.first(where: { $0.name == defaultAccount })
                ?? payers.first(where: { $0.type == .debit }) ?? payers.first)?.id
        }
    }

    private func accountPicker(title: String, selection: Binding<UUID?>, allowNone: Bool,
                               options: [LedgerAccount]? = nil) -> some View {
        Picker(title, selection: selection) {
            if allowNone || selection.wrappedValue == nil {
                Text(allowNone ? "不选择" : "请选择").tag(UUID?.none)
            }
            ForEach(options ?? selectableAccounts) { a in
                Label(a.name, systemImage: a.iconName).tag(UUID?.some(a.id))
            }
        }
    }

    private var userAccountBinding: Binding<UUID?> {
        Binding(get: { accountID }, set: { accountID = $0; accountTouched = true })
    }

    /// 套用记账规则（分类记忆）。只影响新记录，且不覆盖用户手动选择的分类 / 账户。
    private func applyRule(merchant value: String, overrideCategory: Bool) {
        guard record == nil, kind.countsInStats else { return }
        guard let hit = RuleStore.match(merchant: value, text: note, kind: kind, in: context, countHit: false) else { return }
        if overrideCategory, let c = hit.category, c.kind == kind {
            selectedCategoryID = c.id
            ruleHint = "已按记账规则「\(hit.rule.displayName.isEmpty ? hit.rule.keyword : hit.rule.displayName)」选择 \(c.name)"
        }
        if !accountTouched, let a = hit.account ?? RuleStore.lastAccount(for: hit.category, in: context) {
            accountID = a.id
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })
    }

    // MARK: - 数据

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        if let record {
            kind = record.isCreditRepayment ? .expense : record.kind
            repayMode = record.isCreditRepayment
            amountText = String(format: "%.2f", record.amount)
            selectedCategoryID = record.category?.id
            note = record.note
            merchant = record.merchant
            accountID = record.accountRef?.id ?? allAccounts.first(where: { $0.name == record.account })?.id
            toAccountID = record.toAccount?.id
            feeText = record.fee > 0 ? String(format: "%.2f", record.fee) : ""
            date = record.date
            source = record.source
        } else if let p = prefill {
            kind = p.kind
            amountText = p.amount > 0 ? String(format: "%.2f", p.amount) : ""
            date = p.date
            note = p.note
            merchant = p.merchant
            accountID = p.accountID ?? allAccounts.first(where: { $0.name == defaultAccount && !$0.isArchived })?.id
            toAccountID = p.toAccountID
            selectedCategoryID = p.categoryID ?? allCategories.first(where: { $0.kind == (p.kind.countsInStats ? p.kind : .expense) })?.id
            recurringKey = p.recurringKey
            source = p.recurringKey.isEmpty ? "manual" : "recurring"
            accountTouched = true
            categoryTouched = true
        } else if let repayCardID {
            kind = .expense
            date = initialDate
            selectedCategoryID = allCategories.first(where: { $0.kind == .expense })?.id
            enterRepayMode(card: repayCardID)
            accountTouched = true
            if ScreenshotDemo.isActive, let full = fullRepaymentAmount {
                amountText = String(format: "%.2f", full)
            } else {
                amountFocused = true
            }
        } else {
            kind = initialKind
            date = initialDate
            selectedCategoryID = allCategories.first(where: { $0.kind == (initialKind.countsInStats ? initialKind : .expense) })?.id
            let firstCategory = allCategories.first(where: { $0.id == selectedCategoryID })
            accountID = presetAccountID
                ?? (initialKind.countsInStats ? RuleStore.lastAccount(for: firstCategory, in: context)?.id : nil)
                ?? allAccounts.first(where: { $0.name == defaultAccount && !$0.isArchived })?.id
            if presetAccountID != nil { accountTouched = true }
            amountFocused = true
        }
    }

    private func save() {
        guard let amount = parsedAmount, amountValid else {
            alertMessage = "请输入有效的金额"
            return
        }
        // 信用卡还款以「付款账户 → 信用卡」的转账保存：沿用转账的余额算法，无需新字段（CloudKit / 迁移安全）
        let kind: RecordKind = repayMode ? .transfer : self.kind
        if kind == .transfer {
            guard accountID != nil, toAccountID != nil, accountID != toAccountID else {
                alertMessage = repayMode ? "请选择付款账户和要还款的信用卡" : "请选择不同的转出和转入账户"
                return
            }
        }
        let category: LedgerCategory? = kind.countsInStats ? allCategories.first(where: { $0.id == selectedCategoryID }) : nil
        let fromAccount = allAccounts.first(where: { $0.id == accountID })
        let toAccount: LedgerAccount? = kind == .transfer ? allAccounts.first(where: { $0.id == toAccountID }) : nil
        let fee: Double
        if repayMode {
            fee = record?.isCreditRepayment == true ? (record?.fee ?? 0) : 0
        } else {
            fee = kind == .transfer ? max(0, Money.parse(feeText) ?? 0) : 0
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMerchant = kind.countsInStats ? merchant.trimmingCharacters(in: .whitespacesAndNewlines) : ""

        // 分类记忆：有商户时记住「商户 → 分类 + 账户」（编辑时仅在分类或账户改变时更新）
        let categoryChanged = record == nil || record?.category?.id != category?.id || record?.accountRef?.id != fromAccount?.id
        if kind.countsInStats, !trimmedMerchant.isEmpty, categoryChanged {
            RuleStore.learn(merchant: trimmedMerchant, kind: kind, category: category, account: fromAccount, in: context)
        }
        if kind.countsInStats { RuleStore.rememberAccount(fromAccount, for: category) }

        let target: LedgerRecord
        if let record {
            target = record
            target.amount = amount
            target.kind = kind
            target.note = trimmedNote
            target.merchant = trimmedMerchant
            target.date = date
        } else {
            target = LedgerRecord(amount: amount, kind: kind, category: nil, note: trimmedNote,
                                  merchant: trimmedMerchant, date: date, source: source)
            target.recurringKey = recurringKey
            context.insert(target)
        }
        target.category = category
        target.accountRef = fromAccount
        target.toAccount = toAccount
        target.fee = fee
        target.account = fromAccount?.name ?? ""   // 兼容旧版文本字段

        do {
            try context.save()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            BudgetMonitor.check(in: context)
            dismiss()
        } catch {
            alertMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func deleteRecord() {
        guard let record else { return }
        context.delete(record)
        try? context.save()
        dismiss()
    }

    // MARK: - 识图

    @MainActor
    private func recognize(_ item: PhotosPickerItem) async {
        isRecognizing = true
        defer {
            isRecognizing = false
            photoItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                alertMessage = "无法读取这张图片"
                return
            }
            let vocab = OCRVocabulary(
                expenseCategories: allCategories.filter { $0.kind == .expense }.map(\.name),
                incomeCategories: allCategories.filter { $0.kind == .income }.map(\.name),
                accounts: allAccounts.filter { !$0.isArchived }.map(\.name))
            let recognition = try await ReceiptRecognizer.recognizeDetailed(imageData: data, vocabulary: vocab)
            ocrEngineLine = recognition.engineLine
            let all = recognition.receipts
            let found = all.filter { ($0.amount ?? 0) > 0 }
            if found.count > 1 {
                // 一张截图里有多笔：让用户选择要填写哪一笔
                detectedReceipts = found
                showReceiptPicker = true
            } else {
                apply(found.first ?? all.first ?? ParsedReceipt())
            }
        } catch {
            alertMessage = "识别失败：\(error.localizedDescription)"
        }
    }

    static func receiptTitle(_ r: ParsedReceipt) -> String {
        var parts = [(r.isCardRepayment ? "信用卡还款 " : (r.isIncome ? "收入 " : "支出 ")) + Money.format(r.amount ?? 0)]
        if let m = r.merchant, !m.isEmpty { parts.append(m) }
        if let d = r.date { parts.append(DateText.monthDayTime.string(from: d)) }
        return parts.joined(separator: " · ")
    }

    @MainActor
    private func apply(_ parsed: ParsedReceipt) {
        guard let amount = parsed.amount else {
            alertMessage = "没有识别到金额，请手动填写"
            return
        }
        if parsed.isCardRepayment {
            kind = .expense
            amountText = String(format: "%.2f", amount)
            if let d = parsed.date { date = d }
            let card = account(named: parsed.repaymentCardName) ?? DataStore.account(matching: parsed.repaymentCard, in: context)
            if let payer = DataStore.account(matching: parsed.accountHint, in: context), !payer.type.isLiability {
                accountID = payer.id
            }
            enterRepayMode(card: card?.type.isLiability == true ? card?.id : nil)
            if note.isEmpty, let m = parsed.merchant, !m.isEmpty { note = m }
            source = "ocr"
            return
        }
        repayMode = false
        kind = parsed.isIncome ? .income : .expense
        amountText = String(format: "%.2f", amount)
        if let m = parsed.merchant { merchant = m }
        if let d = parsed.date { date = d }
        let list = allCategories.filter { $0.kind == kind }
        let hit = RuleStore.match(merchant: parsed.merchant ?? "", kind: kind, in: context, countHit: false)
        if let c = hit?.category, c.kind == kind {
            // 记账规则优先于关键词猜测
            selectedCategoryID = c.id
            ruleHint = "已按记账规则「\(hit!.rule.displayName.isEmpty ? hit!.rule.keyword : hit!.rule.displayName)」选择 \(c.name)"
        } else if let name = parsed.categoryName, let c = list.first(where: { $0.name == name }) {
            selectedCategoryID = c.id
        } else if !list.contains(where: { $0.id == selectedCategoryID }) {
            selectedCategoryID = list.first?.id
        }
        // Apple 智能选出的账户名 > 付款方式线索 > 记账规则
        if let a = account(named: parsed.accountName) ?? DataStore.account(matching: parsed.accountHint, in: context) ?? hit?.account {
            accountID = a.id
        }
        source = "ocr"
    }

    private func account(named name: String?) -> LedgerAccount? {
        guard let name, !name.isEmpty else { return nil }
        return allAccounts.first(where: { $0.name == name && !$0.isArchived })
    }
}
