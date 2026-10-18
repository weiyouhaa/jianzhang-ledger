import SwiftUI
import SwiftData

/// 分类管理：增删改、拖动排序
struct CategoryManagerView: View {
    var initialKind: RecordKind = .expense

    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerCategory.sortOrder) private var allCategories: [LedgerCategory]
    @State private var kind: RecordKind = .expense
    @State private var didLoad = false
    @State private var editing: CategoryEditTarget?
    @State private var pendingDelete: LedgerCategory?

    enum CategoryEditTarget: Identifiable {
        case new(RecordKind)
        case edit(LedgerCategory)
        var id: String {
            switch self {
            case .new(let k): return "new-" + k.rawValue
            case .edit(let c): return c.id.uuidString
            }
        }
    }

    private var categories: [LedgerCategory] { allCategories.filter { $0.kind == kind } }

    var body: some View {
        List {
            Section {
                Picker("类型", selection: $kind) {
                    ForEach(RecordKind.allCases) { k in Text(k.title).tag(k) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                ForEach(categories) { c in
                    HStack(spacing: 12) {
                        CategoryIcon(icon: c.icon, color: c.color, size: 34)
                        Text(c.name)
                        Spacer()
                        Text("\(c.records?.count ?? 0) 笔")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = .edit(c) }
                    .swipeActions {
                        Button(role: .destructive) { pendingDelete = c } label: { Label("删除", systemImage: "trash") }
                    }
                }
                .onMove(perform: move)
            } footer: {
                Text("轻点编辑，右上角「编辑」可拖动排序。删除分类后，相关记录会变为「未分类」。")
            }
        }
        .navigationTitle("分类管理")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .bottomBar) {
                Button {
                    editing = .new(kind)
                } label: {
                    Label("新建分类", systemImage: "plus.circle.fill")
                }
            }
        }
        .onAppear {
            if !didLoad { kind = initialKind; didLoad = true }
        }
        .sheet(item: $editing) { target in
            switch target {
            case .new(let k):
                CategoryEditorView(category: nil, kind: k, nextSortOrder: (allCategories.map(\.sortOrder).max() ?? 0) + 1)
            case .edit(let c):
                CategoryEditorView(category: c, kind: c.kind, nextSortOrder: c.sortOrder)
            }
        }
        .confirmationDialog("删除分类「\(pendingDelete?.name ?? "")」？", isPresented: deleteBinding, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let c = pendingDelete {
                    context.delete(c)
                    try? context.save()
                }
                pendingDelete = nil
            }
        } message: {
            Text("该分类下的 \(pendingDelete?.records?.count ?? 0) 笔记录将变为「未分类」。")
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func move(from source: IndexSet, to destination: Int) {
        var list = categories
        list.move(fromOffsets: source, toOffset: destination)
        // 重新编号：保持支出/收入各自的相对顺序
        let base = list.map(\.sortOrder).min() ?? 0
        for (i, c) in list.enumerated() { c.sortOrder = base + i }
        // 避免与另一类型的排序号冲突不影响功能（查询时按类型过滤）
        try? context.save()
    }
}

/// 新建 / 编辑分类
struct CategoryEditorView: View {
    let category: LedgerCategory?
    let kind: RecordKind
    let nextSortOrder: Int

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = "tag.fill"
    @State private var color = Color(hex: "#FF9500")
    @State private var colorHex = "#FF9500"
    @State private var didLoad = false

    static let iconOptions = [
        "fork.knife", "cup.and.saucer.fill", "takeoutbag.and.cup.and.straw.fill", "wineglass.fill", "birthday.cake.fill",
        "car.fill", "bus.fill", "tram.fill", "bicycle", "fuelpump.fill", "airplane", "bag.fill", "cart.fill",
        "basket.fill", "tshirt.fill", "gift.fill", "gamecontroller.fill", "film.fill", "music.note", "tv.fill",
        "book.fill", "graduationcap.fill", "house.fill", "bolt.fill", "drop.fill", "flame.fill", "wifi",
        "phone.fill", "cross.case.fill", "pills.fill", "heart.fill", "pawprint.fill", "figure.run", "dumbbell.fill",
        "scissors", "sparkles", "wrench.and.screwdriver.fill", "creditcard.fill", "banknote.fill", "star.fill",
        "chart.line.uptrend.xyaxis", "envelope.fill", "arrow.uturn.backward.circle.fill", "plus.circle.fill",
        "person.2.fill", "figure.and.child.holdinghands", "laptopcomputer", "iphone", "camera.fill", "leaf.fill",
        "ellipsis.circle.fill", "tag.fill",
    ]

    static let colorOptions = [
        "#FF3B30", "#FF6482", "#FF2D55", "#FF9500", "#FF9F0A", "#FFB800", "#34C759", "#30B0C7",
        "#5AC8FA", "#64D2FF", "#007AFF", "#5856D6", "#AF52DE", "#A2845E", "#8E8E93", "#1FA67A",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            CategoryIcon(icon: icon, color: Color(hex: colorHex), size: 64, selected: true)
                            Text(name.isEmpty ? "分类名称" : name).font(.headline)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    TextField("名称", text: $name)
                }

                Section("颜色") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(Self.colorOptions, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(Color.primary, lineWidth: colorHex == hex ? 2.5 : 0).padding(-4))
                                .onTapGesture { colorHex = hex; color = Color(hex: hex) }
                        }
                    }
                    .padding(.vertical, 6)
                    ColorPicker("自定义颜色", selection: $color, supportsOpacity: false)
                }

                Section("图标") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                        ForEach(Self.iconOptions, id: \.self) { symbol in
                            CategoryIcon(icon: symbol, color: Color(hex: colorHex), size: 40, selected: symbol == icon)
                                .onTapGesture { icon = symbol }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle(category == nil ? "新建\(kind.title)分类" : "编辑分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                if let category {
                    name = category.name
                    icon = category.icon
                    colorHex = category.colorHex
                    color = Color(hex: category.colorHex)
                }
            }
            .onChange(of: color) { _, newColor in
                let hex = newColor.toHex()
                if hex != colorHex { colorHex = hex }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let category {
            category.name = trimmed
            category.icon = icon
            category.colorHex = colorHex
        } else {
            context.insert(LedgerCategory(name: trimmed, icon: icon, colorHex: colorHex, kind: kind, sortOrder: nextSortOrder))
        }
        try? context.save()
        dismiss()
    }
}
