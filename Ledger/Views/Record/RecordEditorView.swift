import SwiftUI
import SwiftData
import PhotosUI

/// 新建 / 编辑记录
struct RecordEditorView: View {
    let record: LedgerRecord?
    var initialDate: Date = Date()

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LedgerCategory.sortOrder) private var allCategories: [LedgerCategory]
    @AppStorage(SettingsKey.defaultAccount) private var defaultAccount = ""

    @State private var kind: RecordKind = .expense
    @State private var amountText = ""
    @State private var selectedCategoryID: UUID?
    @State private var note = ""
    @State private var merchant = ""
    @State private var account = ""
    @State private var date = Date()
    @State private var source = "manual"
    @State private var didLoad = false

    @State private var photoItem: PhotosPickerItem?
    @State private var isRecognizing = false
    @State private var alertMessage: String?
    @State private var showDeleteConfirm = false
    @FocusState private var amountFocused: Bool

    static let accountOptions = ["现金", "支付宝", "微信", "银行卡", "信用卡", "花呗"]

    private var categories: [LedgerCategory] {
        allCategories.filter { $0.kind == kind }
    }

    private var parsedAmount: Double? { Money.parse(amountText) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("类型", selection: $kind) {
                        ForEach(RecordKind.allCases) { k in
                            Text(k.title).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Money.symbol)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(kind == .income ? Color.green : Color.primary)
                            .focused($amountFocused)
                    }
                    .padding(.vertical, 4)
                }

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

                Section {
                    DatePicker("时间", selection: $date)
                    TextField("备注", text: $note)
                    TextField("商户（可选）", text: $merchant)
                    HStack {
                        TextField("账户（可选）", text: $account)
                        Menu {
                            ForEach(Self.accountOptions, id: \.self) { option in
                                Button(option) { account = option }
                            }
                            if !account.isEmpty {
                                Button("清空", role: .destructive) { account = "" }
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

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
                    Text("在本机识别金额、商户与时间，图片不会上传。")
                }

                if record != nil {
                    Section {
                        Button("删除这条记录", role: .destructive) { showDeleteConfirm = true }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(record == nil ? "记一笔" : "编辑记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled((parsedAmount ?? 0) <= 0)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { amountFocused = false }
                }
            }
            .onAppear(perform: load)
            .onChange(of: kind) { _, _ in
                if !categories.contains(where: { $0.id == selectedCategoryID }) {
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
            account = record.account
            date = record.date
            source = record.source
        } else {
            date = initialDate
            account = defaultAccount
            selectedCategoryID = allCategories.first(where: { $0.kind == .expense })?.id
            amountFocused = true
        }
    }

    private func save() {
        guard let amount = parsedAmount, amount > 0 else {
            alertMessage = "请输入有效的金额"
            return
        }
        let category = allCategories.first { $0.id == selectedCategoryID }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMerchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)

        if let record {
            record.amount = amount
            record.kind = kind
            record.category = category
            record.note = trimmedNote
            record.merchant = trimmedMerchant
            record.account = trimmedAccount
            record.date = date
        } else {
            let newRecord = LedgerRecord(amount: amount, kind: kind, category: category, note: trimmedNote,
                                         merchant: trimmedMerchant, account: trimmedAccount, date: date, source: source)
            context.insert(newRecord)
        }
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
        source = "ocr"
    }
}
