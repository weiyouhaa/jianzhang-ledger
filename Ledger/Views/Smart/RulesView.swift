import SwiftUI
import SwiftData

/// 记账规则：查看 / 编辑 / 删除学习到的商户规则，添加手动关键词规则
struct RulesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \CategoryRule.updatedAt, order: .reverse) private var rules: [CategoryRule]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \LedgerAccount.sortOrder) private var accounts: [LedgerAccount]
    @AppStorage(RuleStore.learnKey) private var learnEnabled = true

    @State private var editorTarget: EditorTarget?
    @State private var pendingDelete: CategoryRule?
    @State private var searchText = ""

    enum EditorTarget: Identifiable {
        case new
        case edit(CategoryRule)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let r): return r.id.uuidString
            }
        }
    }

    private func filtered(_ list: [CategoryRule]) -> [CategoryRule] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter { $0.displayName.localizedCaseInsensitiveContains(q) || $0.keyword.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let manual = filtered(rules.filter { !$0.isLearned })
        let learned = filtered(rules.filter(\.isLearned))
        List {
            Section {
                Toggle(isOn: $learnEnabled) {
                    Label("自动记住商户分类", systemImage: "brain.head.profile")
                }
            } footer: {
                Text("记账或修改记录时，记住「商户 → 分类 / 账户」。之后识图记账、快捷指令和账单导入会优先按规则分类，比关键词猜测更准。")
            }

            Section {
                ForEach(manual) { rule in row(rule) }
                Button {
                    editorTarget = .new
                } label: {
                    Label("添加关键词规则", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("关键词规则")
            } footer: {
                Text("商户名或备注包含关键词即套用，关键词越长越优先。")
            }

            Section {
                if learned.isEmpty {
                    Text(searchText.isEmpty ? "还没有学习到的商户。记几笔带商户的账后会出现在这里。" : "没有匹配的规则")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(learned) { rule in row(rule) }
            } header: {
                Text("已记住的商户（\(rules.filter(\.isLearned).count)）")
            }
        }
        .searchable(text: $searchText, prompt: "搜索商户或关键词")
        .navigationTitle("记账规则")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editorTarget) { target in
            switch target {
            case .new: RuleEditorView(rule: nil)
            case .edit(let r): RuleEditorView(rule: r)
            }
        }
        // 列表左滑删除 → alert（iOS 26 下不会锚到屏幕顶部）
        .alert("删除这条规则？", isPresented: deleteBinding, presenting: pendingDelete) { rule in
            Button("删除", role: .destructive) {
                context.delete(rule)
                try? context.save()
            }
            Button("取消", role: .cancel) {}
        } message: { rule in
            Text("\(summary(rule))\n已记的账不受影响。")
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func summary(_ rule: CategoryRule) -> String {
        let name = rule.displayName.isEmpty ? rule.keyword : rule.displayName
        return "\(name) → " + target(rule)
    }

    private func target(_ rule: CategoryRule) -> String {
        var parts: [String] = []
        if let c = categories.first(where: { $0.id.uuidString == rule.categoryID }) { parts.append(c.name) }
        else if rule.categoryID.isEmpty { parts.append(rule.kind?.title ?? "不改分类") }
        else { parts.append("分类已删除") }
        if let a = accounts.first(where: { $0.id.uuidString == rule.accountID }) { parts.append(a.name) }
        return parts.joined(separator: " · ")
    }

    private func row(_ rule: CategoryRule) -> some View {
        let category = categories.first(where: { $0.id.uuidString == rule.categoryID })
        return Button {
            editorTarget = .edit(rule)
        } label: {
            HStack(spacing: 12) {
                CategoryIcon(icon: category?.icon ?? "tag.fill", color: category?.color ?? .gray, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(rule.displayName.isEmpty ? rule.keyword : rule.displayName)
                            .font(.body)
                            .foregroundStyle(rule.isEnabled ? Color.primary : Color.secondary)
                        if !rule.isLearned {
                            Text("关键词").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                        if !rule.isEnabled {
                            Text("已停用").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("→ " + target(rule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if rule.hitCount > 0 {
                    Text("用过 \(rule.hitCount) 次")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .tint(.primary)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { pendingDelete = rule } label: { Label("删除", systemImage: "trash") }
        }
    }
}

/// 新建 / 编辑规则
struct RuleEditorView: View {
    let rule: CategoryRule?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \LedgerAccount.sortOrder) private var accounts: [LedgerAccount]

    @State private var keyword = ""
    @State private var kind: RecordKind = .expense
    @State private var categoryID: UUID?
    @State private var accountID: UUID?
    @State private var isEnabled = true
    @State private var showDelete = false
    @State private var didLoad = false

    private var isLearned: Bool { rule?.isLearned ?? false }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(isLearned ? "商户名" : "关键词，如：高速、医保、工资", text: $keyword)
                    Picker("类型", selection: $kind) {
                        Text("支出").tag(RecordKind.expense)
                        Text("收入").tag(RecordKind.income)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(isLearned ? "按商户名模糊匹配（去掉分店、公司后缀后比较）。" : "商户名或备注包含这个关键词时套用。")
                }
                Section("套用") {
                    Picker("分类", selection: $categoryID) {
                        ForEach(categories.filter { $0.kind == kind }) { c in
                            Label(c.name, systemImage: c.icon).tag(UUID?.some(c.id))
                        }
                    }
                    Picker("账户", selection: $accountID) {
                        Text("不指定").tag(UUID?.none)
                        ForEach(accounts.filter { !$0.isArchived || $0.id == accountID }) { a in
                            Label(a.name, systemImage: a.iconName).tag(UUID?.some(a.id))
                        }
                    }
                    Toggle("启用", isOn: $isEnabled)
                }
                if let rule {
                    Section {
                        if rule.hitCount > 0 {
                            LabeledContent("命中次数", value: "\(rule.hitCount)")
                        }
                        LabeledContent("更新时间", value: DateText.monthDayTime.string(from: rule.updatedAt))
                    }
                    Section {
                        Button("删除这条规则", role: .destructive) { showDelete = true }
                            .frame(maxWidth: .infinity)
                            .confirmationDialog("删除这条规则？", isPresented: $showDelete, titleVisibility: .visible) {
                                Button("删除", role: .destructive) {
                                    context.delete(rule)
                                    try? context.save()
                                    dismiss()
                                }
                                Button("取消", role: .cancel) {}
                            } message: {
                                Text("\(rule.displayName.isEmpty ? rule.keyword : rule.displayName)\n已记的账不受影响。")
                            }
                    }
                }
            }
            .navigationTitle(rule == nil ? "新建关键词规则" : "编辑规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .fontWeight(.semibold)
                        .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty || categoryID == nil)
                }
            }
            .onAppear(perform: load)
            .onChange(of: kind) { _, k in
                if !categories.contains(where: { $0.id == categoryID && $0.kind == k }) {
                    categoryID = categories.first(where: { $0.kind == k })?.id
                }
            }
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        if let rule {
            keyword = rule.displayName.isEmpty ? rule.keyword : rule.displayName
            kind = rule.kind ?? DataStore.category(idString: rule.categoryID, in: context)?.kind ?? .expense
            categoryID = UUID(uuidString: rule.categoryID)
            accountID = UUID(uuidString: rule.accountID)
            isEnabled = rule.isEnabled
        } else {
            categoryID = categories.first(where: { $0.kind == .expense })?.id
        }
    }

    private func save() {
        let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = rule ?? {
            let r = CategoryRule(keyword: "", displayName: "", isLearned: false, kind: kind, categoryID: nil, accountID: nil)
            context.insert(r)
            return r
        }()
        target.displayName = text
        target.keyword = target.isLearned ? MerchantNormalizer.normalize(text) : text.lowercased()
        target.kind = kind
        target.categoryID = categoryID?.uuidString ?? ""
        target.accountID = accountID?.uuidString ?? ""
        target.isEnabled = isEnabled
        target.updatedAt = Date()
        try? context.save()
        dismiss()
    }
}
