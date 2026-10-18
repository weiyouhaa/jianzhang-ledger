import SwiftUI
import SwiftData
import PhotosUI

/// 新建 / 编辑记录（支出、收入、转账；余额校准记录也可在此修改）
struct RecordEditorView: View {
    let record: LedgerRecord?
    var initialDate: Date = Date()
    var initialKind: RecordKind = .expense
    var presetAccountID: UUID? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LedgerCategory.sortOrder) private var allCategories: [LedgerCategory]
    @Query(sort: \LedgerAccount.sortOrder) private var allAccounts: [LedgerAccount]
    @AppStorage(SettingsKey.defaultAccount) private var defaultAccount = ""

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

    @State private var photoItem: PhotosPickerItem?
    @State private var isRecognizing = false
    @State private var alertMessage: String?
    @State private var showDeleteConfirm = false
    @FocusState private var amountFocused: Bool

    private var categories: [LedgerCategory] {
        allCategories.filter { $0.kind == kind }
    }

    /// 可选账户：未归档的，以及当前记录已关联的
    private var selectableAccounts: [LedgerAccount] {
        allAccounts.filter { !$0.isArchived || $0.id == accountID || $0.id == toAccountID }
    }

    private var parsedAmount: Double? { Money.parse(amountText) }

    private var amountValid: Bool {
        guard let a = parsedAmount else { return false }
        return kind == .adjustment ? a != 0 : a > 0
    }

    private var canSave: Bool {
        guard amountValid else { return false }
        if kind == .transfer {
            return accountID != nil && toAccountID != nil && accountID != toAccountID
        }
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
                } else if kind == .adjustment {
                    Section {
                        accountPicker(title: "账户", selection: $accountID, allowNone: false)
                    } footer: {
                        Text("正数表示调增余额，负数表示调减。")
                    }
                } else {
                    categorySection
                }

                Section {
                    DatePicker("时间", selection: $date)
                    TextField("备注", text: $note)
                    if kind.countsInStats {
                        TextField("商户（可选）", text: $merchant)
                        accountPicker(title: "账户", selection: $accountID, allowNone: true)
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
                    } footer: {
                        Text("在本机识别金额、商户、时间与付款账户，图片不会上传。")
                    }
                }

                if record != nil {
                    Section {
                        Button("删除这条记录", role: .destructive) { showDeleteConfirm = true }
                            .frame(maxWidth: .infinity)
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
            .onAppear(perform: load)
            .onChange(of: kind) { _, newKind in
                if newKind.countsInStats && !categories.contains(where: { $0.id == selectedCategoryID }) {
                    selectedCategoryID = categories.first?.id
                }
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
            .confirmationDialog("确定删除这条记录？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) { deleteRecord() }
            }
        }
    }

    // MARK: - Sections

    private var navTitle: String {
        if record == nil { return kind == .transfer ? "转账" : "记一笔" }
        return kind == .adjustment ? "余额校准" : "编辑记录"
    }

    private var amountColor: Color {
        switch kind {
        case .income: return .green
        case .expense: return .primary
        case .transfer, .adjustment: return Color(hex: "#30B0C7")
        }
    }

    private var categorySection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 14) {
                ForEach(categories) { c in
                    VStack(spacing: 6) {
                        CategoryIcon(icon: c.icon, color: c.color, size: 44, selected: c.id == selectedCategoryID)
                        Text(c.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(c.id == selectedCategoryID ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UISelectionFeedbackGenerator().selectionChanged()
                        selectedCategoryID = c.id
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

    private func accountPicker(title: String, selection: Binding<UUID?>, allowNone: Bool) -> some View {
        Picker(title, selection: selection) {
            if allowNone || selection.wrappedValue == nil {
                Text(allowNone ? "不选择" : "请选择").tag(UUID?.none)
            }
            ForEach(selectableAccounts) { a in
                Label(a.name, systemImage: a.iconName).tag(UUID?.some(a.id))
            }
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
            kind = record.kind
            amountText = String(format: "%.2f", record.amount)
            selectedCategoryID = record.category?.id
            note = record.note
            merchant = record.merchant
            accountID = record.accountRef?.id ?? allAccounts.first(where: { $0.name == record.account })?.id
            toAccountID = record.toAccount?.id
            feeText = record.fee > 0 ? String(format: "%.2f", record.fee) : ""
            date = record.date
            source = record.source
        } else {
            kind = initialKind
            date = initialDate
            accountID = presetAccountID ?? allAccounts.first(where: { $0.name == defaultAccount && !$0.isArchived })?.id
            selectedCategoryID = allCategories.first(where: { $0.kind == (initialKind.countsInStats ? initialKind : .expense) })?.id
            amountFocused = true
        }
    }

    private func save() {
        guard let amount = parsedAmount, amountValid else {
            alertMessage = "请输入有效的金额"
            return
        }
        if kind == .transfer {
            guard accountID != nil, toAccountID != nil, accountID != toAccountID else {
                alertMessage = "请选择不同的转出和转入账户"
                return
            }
        }
        let category: LedgerCategory? = kind.countsInStats ? allCategories.first(where: { $0.id == selectedCategoryID }) : nil
        let fromAccount = allAccounts.first(where: { $0.id == accountID })
        let toAccount: LedgerAccount? = kind == .transfer ? allAccounts.first(where: { $0.id == toAccountID }) : nil
        let fee = kind == .transfer ? max(0, Money.parse(feeText) ?? 0) : 0
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMerchant = kind.countsInStats ? merchant.trimmingCharacters(in: .whitespacesAndNewlines) : ""

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
            let parsed = try await ReceiptRecognizer.recognize(imageData: data)
            apply(parsed)
        } catch {
            alertMessage = "识别失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func apply(_ parsed: ParsedReceipt) {
        guard let amount = parsed.amount else {
            alertMessage = "没有识别到金额，请手动填写"
            return
        }
        kind = parsed.isIncome ? .income : .expense
        amountText = String(format: "%.2f", amount)
        if let m = parsed.merchant, merchant.isEmpty { merchant = m }
        if let d = parsed.date { date = d }
        let list = allCategories.filter { $0.kind == kind }
        if let name = parsed.categoryName, let c = list.first(where: { $0.name == name }) {
            selectedCategoryID = c.id
        } else if !list.contains(where: { $0.id == selectedCategoryID }) {
            selectedCategoryID = list.first?.id
        }
        if let a = DataStore.account(matching: parsed.accountHint, in: context) {
            accountID = a.id
        }
        source = "ocr"
    }
}
