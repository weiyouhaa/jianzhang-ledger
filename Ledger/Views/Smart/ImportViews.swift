import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 一次待导入的账单文件
struct ImportSession: Identifiable {
    let id = UUID()
    let result: BillParseResult
    let fileName: String

    static let contentTypes: [UTType] = {
        var list: [UTType] = [.commaSeparatedText, .plainText, .text, .spreadsheet, .data]
        if let x = UTType(filenameExtension: "xlsx") { list.insert(x, at: 0) }
        return list
    }()

    /// 读取用户选中的文件（处理安全作用域）
    static func load(url: URL) throws -> ImportSession {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        do {
            let result = try BillParser.parse(data: data, fileName: url.lastPathComponent)
            guard !result.entries.isEmpty else { throw BillParseError.empty }
            return ImportSession(result: result, fileName: url.lastPathComponent)
        } catch let error as BillParseError {
            throw error
        } catch {
            // ZIP / 解压 / XML 错误
            throw ImportLoadError.xlsx(error.localizedDescription)
        }
    }
}

enum ImportLoadError: LocalizedError {
    case xlsx(String)
    var errorDescription: String? {
        switch self {
        case .xlsx(let m): return "无法读取这个 Excel 文件（\(m)）。可以用 Numbers / Excel 打开后「导出为 CSV」再导入。"
        }
    }
}

/// 导入预览：统计、逐笔勾选、修正分类 / 账户后导入
struct ImportPreviewView: View {
    let session: ImportSession
    var onFinish: (Int) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \LedgerAccount.sortOrder) private var accounts: [LedgerAccount]

    @State private var items: [ImportItem] = []
    @State private var options = ImportOptions()
    @State private var editingID: Int?
    @State private var errorMessage: String?
    @State private var didLoad = false

    private var chosen: [ImportItem] { items.filter { $0.include && $0.canImport } }

    var body: some View {
        let newItems = items.filter { $0.status == .new }
        let dupItems = items.filter { if case .likelyDuplicate = $0.status { return true }; return $0.status == .imported }
        let skipped = items.filter { $0.status.isSkipped }
        NavigationStack {
            List {
                Section { summaryCard(new: newItems.count, dup: dupItems.count, skipped: skipped.count) }
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

                Section {
                    Toggle("退款记为收入", isOn: $options.refundsAsIncome)
                    Toggle("不计收支导入为转账", isOn: $options.neutralAsTransfer)
                    Toggle("导入疑似重复的交易", isOn: $options.includeLikelyDuplicates)
                } header: {
                    Text("选项")
                } footer: {
                    Text("已全额退款、交易关闭的交易会跳过；部分退款按净额记账。不计收支（还款、转账、理财）匹配到两个账户时记为转账。")
                }

                if !newItems.isEmpty { itemSection("新交易", newItems) }
                if !dupItems.isEmpty { itemSection("重复", dupItems) }
                if !skipped.isEmpty { itemSection("跳过", skipped) }
            }
            .navigationTitle("导入\(session.result.source.title)账单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入 \(chosen.count) 笔", action: commit)
                        .fontWeight(.semibold)
                        .disabled(chosen.isEmpty)
                }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                items = BillImporter.prepare(session.result, options: options, in: context)
            }
            .onChange(of: options) { _, newOptions in reprepare(newOptions) }
            .sheet(item: editingBinding) { wrapper in
                ImportItemEditor(item: wrapper.item, categories: categories, accounts: accounts) { updated, applyAll in
                    apply(updated, toSameMerchant: applyAll)
                }
            }
            .alert("导入失败", isPresented: errorBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - 视图

    private func summaryCard(new: Int, dup: Int, skipped: Int) -> some View {
        let expense = chosen.filter { $0.kind == .expense }.reduce(0) { $0 + $1.entry.amount }
        let income = chosen.filter { $0.kind == .income }.reduce(0) { $0 + $1.entry.amount }
        let dates = items.map(\.entry.date)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: session.result.source.icon)
                    .font(.title2)
                    .foregroundStyle(session.result.source == .alipay ? Color(hex: "#1677FF") : Color(hex: "#07C160"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.fileName).font(.subheadline.weight(.medium)).lineLimit(1)
                    if let lo = dates.min(), let hi = dates.max() {
                        Text("\(DateText.shortDate.string(from: lo)) – \(DateText.shortDate.string(from: hi)) · 共 \(items.count) 行")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                countBlock("新交易", new, .green)
                countBlock("重复", dup, .orange)
                countBlock("跳过", skipped, .secondary)
            }
            HStack {
                Text("将导入 \(chosen.count) 笔")
                Spacer()
                Text("支出 \(Money.format(expense))  收入 \(Money.format(income))")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func countBlock(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func itemSection(_ title: String, _ list: [ImportItem]) -> some View {
        Section("\(title)（\(list.count)）") {
            ForEach(list) { item in row(item) }
        }
    }

    private func row(_ item: ImportItem) -> some View {
        let category = categories.first(where: { $0.id == item.categoryID })
        let account = accounts.first(where: { $0.id == item.accountID })
        let toAccount = accounts.first(where: { $0.id == item.toAccountID })
        let e = item.entry
        return HStack(spacing: 10) {
            Button {
                toggle(item)
            } label: {
                Image(systemName: item.include ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.include ? Color.accentColor : (item.canImport ? Color.secondary : Color.secondary.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!item.canImport)

            Button {
                editingID = item.id
            } label: {
                HStack(spacing: 10) {
                    if item.kind == .transfer {
                        CategoryIcon(icon: "arrow.left.arrow.right", color: Color(hex: "#30B0C7"), size: 34)
                    } else {
                        CategoryIcon(icon: category?.icon ?? "questionmark", color: category?.color ?? .gray, size: 34)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.merchant.isEmpty ? (category?.name ?? item.kind.title) : e.merchant)
                            .lineLimit(1)
                        Text(subtitle(item, category: category, account: account, toAccount: toAccount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let reason = reason(item) {
                            Text(reason)
                                .font(.caption2)
                                .foregroundStyle(item.status.isSkipped ? Color.secondary : Color.orange)
                        }
                    }
                    Spacer(minLength: 4)
                    Text((item.kind == .income ? "+" : (item.kind == .expense ? "-" : "")) + Money.format(e.amount))
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(item.kind == .income ? Color.green : (item.kind == .transfer ? Color.secondary : Color.primary))
                        .opacity(item.include ? 1 : 0.5)
                }
            }
            .tint(.primary)
        }
    }

    private func subtitle(_ item: ImportItem, category: LedgerCategory?, account: LedgerAccount?, toAccount: LedgerAccount?) -> String {
        var parts = [DateText.monthDayTime.string(from: item.entry.date)]
        if item.kind == .transfer {
            parts.append("\(account?.name ?? "?") → \(toAccount?.name ?? "?")")
        } else {
            parts.append(category?.name ?? "未分类")
            parts.append(account?.name ?? (item.entry.method.isEmpty || item.entry.method == "/" ? "未匹配账户" : item.entry.method))
        }
        return parts.joined(separator: " · ")
    }

    private func reason(_ item: ImportItem) -> String? {
        switch item.status {
        case .new:
            if item.edited { return "已修改" }
            if item.categorySource.hasPrefix("规则") { return item.categorySource }
            return nil
        case .imported: return "已导入过（订单号相同）"
        case .likelyDuplicate(let r): return r
        case .skipped(let r): return r
        }
    }

    // MARK: - 操作

    private struct EditingWrapper: Identifiable {
        let item: ImportItem
        var id: Int { item.id }
    }

    private var editingBinding: Binding<EditingWrapper?> {
        Binding(get: {
            guard let id = editingID, let item = items.first(where: { $0.id == id }) else { return nil }
            return EditingWrapper(item: item)
        }, set: { if $0 == nil { editingID = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func toggle(_ item: ImportItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }), items[i].canImport else { return }
        items[i].include.toggle()
    }

    private func apply(_ updated: ImportItem, toSameMerchant: Bool) {
        guard let i = items.firstIndex(where: { $0.id == updated.id }) else { return }
        var u = updated
        u.edited = true
        if !u.canImport { u.include = false }
        items[i] = u
        guard toSameMerchant, !u.entry.merchant.isEmpty, u.kind.countsInStats else { return }
        for j in items.indices where j != i && items[j].entry.merchant == u.entry.merchant && items[j].kind == u.kind {
            items[j].categoryID = u.categoryID
            if u.accountID != nil { items[j].accountID = u.accountID }
            items[j].edited = true
        }
    }

    /// 选项变化后重新计算，保留用户的修改和勾选
    private func reprepare(_ newOptions: ImportOptions) {
        let old = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var fresh = BillImporter.prepare(session.result, options: newOptions, in: context)
        for i in fresh.indices {
            guard let prev = old[fresh[i].id], prev.edited else { continue }
            fresh[i].kind = prev.kind
            fresh[i].categoryID = prev.categoryID
            fresh[i].accountID = prev.accountID
            fresh[i].toAccountID = prev.toAccountID
            fresh[i].edited = true
            fresh[i].include = prev.include && fresh[i].canImport
        }
        items = fresh
    }

    private func commit() {
        do {
            let batch = try BillImporter.commit(items, source: session.result.source, fileName: session.fileName, in: context)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onFinish(batch?.recordCount ?? 0)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 修正一笔待导入交易的类型、分类、账户
struct ImportItemEditor: View {
    @State var item: ImportItem
    let categories: [LedgerCategory]
    let accounts: [LedgerAccount]
    let onSave: (ImportItem, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var applyAll = true

    var body: some View {
        let e = item.entry
        NavigationStack {
            Form {
                Section {
                    LabeledContent("金额", value: Money.format(e.amount))
                    LabeledContent("时间", value: DateText.monthDayTime.string(from: e.date))
                    if !e.merchant.isEmpty { LabeledContent("交易对方", value: e.merchant) }
                    if !e.memo.isEmpty { LabeledContent("商品", value: e.memo) }
                    if !e.method.isEmpty && e.method != "/" { LabeledContent("付款方式", value: e.method) }
                    LabeledContent("状态", value: [e.direction, e.status].filter { !$0.isEmpty && $0 != "/" }.joined(separator: " · "))
                }
                Section {
                    Picker("类型", selection: $item.kind) {
                        Text("支出").tag(RecordKind.expense)
                        Text("收入").tag(RecordKind.income)
                        Text("转账").tag(RecordKind.transfer)
                    }
                    .pickerStyle(.segmented)
                    if item.kind == .transfer {
                        accountPicker("转出账户", $item.accountID)
                        accountPicker("转入账户", $item.toAccountID)
                    } else {
                        Picker("分类", selection: $item.categoryID) {
                            ForEach(categories.filter { $0.kind == item.kind }) { c in
                                Label(c.name, systemImage: c.icon).tag(UUID?.some(c.id))
                            }
                        }
                        accountPicker("账户", $item.accountID)
                    }
                }
                if item.kind.countsInStats && !e.merchant.isEmpty {
                    Section {
                        Toggle("同商户全部应用并记住", isOn: $applyAll)
                    } footer: {
                        Text("本次导入中「\(e.merchant)」的其他交易使用同样的分类，并加入记账规则。")
                    }
                }
                if item.status.isSkipped || item.status != .new {
                    Section {
                        Toggle("导入这一笔", isOn: $item.include)
                            .disabled(!item.canImport)
                    } footer: {
                        Text(item.status == .imported ? "订单号相同的交易已经导入过，不能重复导入。" : "")
                    }
                }
            }
            .navigationTitle("修改交易")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if item.status == .new && item.canImport { item.include = true }
                        onSave(item, applyAll)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onChange(of: item.kind) { _, k in
                if k.countsInStats && !categories.contains(where: { $0.id == item.categoryID && $0.kind == k }) {
                    item.categoryID = categories.first(where: { $0.kind == k && ($0.name == "其他" || $0.name == "其他收入") })?.id
                        ?? categories.first(where: { $0.kind == k })?.id
                }
            }
        }
    }

    private func accountPicker(_ title: String, _ selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("不选择").tag(UUID?.none)
            ForEach(accounts.filter { !$0.isArchived }) { a in
                Label(a.name, systemImage: a.iconName).tag(UUID?.some(a.id))
            }
        }
    }
}

/// 导入记录：可整批撤销
struct ImportBatchesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ImportBatch.createdAt, order: .reverse) private var batches: [ImportBatch]
    @State private var pendingUndo: ImportBatch?
    @State private var undoneMessage: String?

    var body: some View {
        List {
            if batches.isEmpty {
                ContentUnavailableView("还没有导入记录", systemImage: "tray.and.arrow.down",
                                       description: Text("在设置中选择「导入支付宝 / 微信账单」"))
                    .listRowBackground(Color.clear)
            }
            ForEach(batches) { batch in
                Button { pendingUndo = batch } label: { row(batch) }
                    .tint(.primary)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { pendingUndo = batch } label: {
                            Label("撤销", systemImage: "arrow.uturn.backward")
                        }
                    }
            }
        }
        .navigationTitle("导入记录")
        .navigationBarTitleDisplayMode(.inline)
        .alert("撤销这次导入？", isPresented: undoBinding, presenting: pendingUndo) { batch in
            Button("撤销并删除 \(BillImporter.records(of: batch, in: context).count) 笔", role: .destructive) {
                let n = BillImporter.undo(batch, in: context)
                undoneMessage = "已删除 \(n) 笔导入的记录"
            }
            Button("取消", role: .cancel) {}
        } message: { batch in
            Text("\(batch.source.title) · \(batch.fileName)\n\(DateText.monthDayTime.string(from: batch.createdAt)) 导入。导入后手动修改过的记录也会一并删除。")
        }
        .alert(undoneMessage ?? "", isPresented: Binding(get: { undoneMessage != nil }, set: { if !$0 { undoneMessage = nil } })) {
            Button("好", role: .cancel) {}
        }
    }

    private var undoBinding: Binding<Bool> {
        Binding(get: { pendingUndo != nil }, set: { if !$0 { pendingUndo = nil } })
    }

    private func row(_ batch: ImportBatch) -> some View {
        HStack(spacing: 12) {
            Image(systemName: batch.source.icon)
                .font(.title2)
                .foregroundStyle(batch.source == .alipay ? Color(hex: "#1677FF") : Color(hex: "#07C160"))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(batch.fileName.isEmpty ? batch.source.title : batch.fileName).lineLimit(1)
                Text("\(DateText.monthDayTime.string(from: batch.createdAt)) · \(batch.recordCount) 笔")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("-\(Money.format(batch.expenseTotal))").font(.subheadline.monospacedDigit())
                if batch.incomeTotal > 0 {
                    Text("+\(Money.format(batch.incomeTotal))").font(.caption.monospacedDigit()).foregroundStyle(.green)
                }
            }
        }
    }
}
