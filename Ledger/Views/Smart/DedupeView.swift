import SwiftUI
import SwiftData

/// 一键去重：找出可能重复的记录，用户逐组选择保留，或交给 App 自动处理「确定重复」的组。
/// 只操作真实账本（DataStore.shared）；防窥模式下不扫描、不删除，也不显示撤销。
struct DedupeView: View {
    @ObservedObject private var session = SessionManager.shared
    @AppStorage(DedupeService.windowKey, store: .standard) private var windowRaw = DedupeWindow.min30.rawValue

    @State private var groups: [DedupeGroup] = []
    @State private var keepIDs: [String: Set<String>] = [:]
    @State private var scanned = 0
    @State private var loaded = false
    @State private var showDeleteConfirm = false
    @State private var showAutoConfirm = false
    @State private var showUndoConfirm = false
    @State private var undoSnapshot: DedupeUndoSnapshot?
    @State private var message: String?
    @State private var lookup: [String: LedgerRecord] = [:]

    private var window: DedupeWindow { DedupeWindow(rawValue: windowRaw) ?? .min30 }
    private var isReal: Bool { !session.isDecoy }
    private var context: ModelContext { DataStore.shared.mainContext }

    /// 当前选择下要删除的记录数 / 金额（只算至少保留一笔、且有要删的组）
    private var pending: (groups: Int, records: Int, amount: Double) {
        var g = 0, n = 0, sum = 0.0
        for group in groups {
            let keep = keepIDs[group.id] ?? [group.suggestedKeepID]
            guard !keep.isEmpty else { continue }
            let drop = group.members.filter { !keep.contains($0.id) }
            guard !drop.isEmpty else { continue }
            g += 1; n += drop.count; sum += drop.reduce(0) { $0 + $1.amount }
        }
        return (g, n, sum)
    }

    private var autoPlan: [DedupeAutoItem] {
        DedupeEngine.autoPlan(groups)
    }

    var body: some View {
        List {
            Section {
                Picker("时间窗口", selection: $windowRaw) {
                    ForEach(DedupeWindow.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text("金额、类型相同，且在这个时间范围内的记录才会被比对；账户、商户一致会提高可信度，订单号相同即确定重复。")
            }

            if isReal, let snap = undoSnapshot {
                Section {
                    Button {
                        showUndoConfirm = true
                    } label: {
                        Label("撤销上次去重（恢复 \(snap.deleted.count) 笔）", systemImage: "arrow.uturn.backward")
                    }
                    .accessibilityIdentifier("dedupe-undo")
                } footer: {
                    Text("\(snap.title) · \(DateText.full.string(from: snap.date))")
                }
            }

            if !loaded {
                Section { HStack { ProgressView(); Text("正在查找…").foregroundStyle(.secondary) } }
            } else if groups.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal").font(.largeTitle).foregroundStyle(.green)
                        Text("没有发现可能重复的记录").font(.headline)
                        if isReal { Text("已检查 \(scanned) 笔").font(.footnote).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            } else {
                Section {
                    summary
                }
                ForEach(groups) { group in
                    groupSection(group)
                }
            }
        }
        .navigationTitle("一键去重")
        .navigationBarTitleDisplayMode(.inline)
        .bottomActionBar(isPresented: isReal && !groups.isEmpty) {
            HStack(spacing: 12) {
                Button {
                    showAutoConfirm = true
                } label: {
                    Text("自动处理").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(autoPlan.isEmpty)
                .accessibilityIdentifier("dedupe-auto")
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Text("删除所选 \(pending.records) 笔").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(pending.records == 0)
                .accessibilityIdentifier("dedupe-delete")
            }
        }
        .onAppear { if !loaded { reload() } }
        .onChange(of: windowRaw) { _, _ in reload() }
        .alert("删除所选记录？", isPresented: $showDeleteConfirm) {
            Button("删除 \(pending.records) 笔", role: .destructive) { applySelection() }
            Button("取消", role: .cancel) {}
        } message: {
            let p = pending
            Text("将处理 \(p.groups) 组，删除 \(p.records) 笔（合计 \(Money.format(p.amount))），每组保留勾选的记录；只保留一笔时会把被删记录里的分类、备注、商户、账户补到保留的那笔（仅补空白）。删除记入变动日志，可在本页撤销。")
        }
        .sheet(isPresented: $showAutoConfirm) {
            NavigationStack { autoPreview }
                .presentationDetents([.medium, .large])
        }
        .alert("撤销上次去重？", isPresented: $showUndoConfirm) {
            Button("恢复") { undo() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("恢复 \(undoSnapshot?.deleted.count ?? 0) 笔被删除的记录，并还原被补全的字段。")
        }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: - 视图

    private var summary: some View {
        let certain = groups.filter { $0.confidence == .certain }.count
        let likely = groups.filter { $0.confidence == .likely }.count
        let possible = groups.count - certain - likely
        return VStack(alignment: .leading, spacing: 6) {
            Text("发现 \(groups.count) 组可能重复（已检查 \(scanned) 笔）").font(.headline)
            Text("确定重复 \(certain) · 很可能 \(likely) · 可能 \(possible)").font(.subheadline).foregroundStyle(.secondary)
            Text("每组默认勾选建议保留的一笔，点按记录切换保留 / 删除。「自动处理」只处理确定重复的组。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func groupSection(_ group: DedupeGroup) -> some View {
        Section {
            ForEach(group.members, id: \.id) { r in
                recordRow(r, group: group)
            }
            Button {
                DedupeService.ignore(group)
                withAnimation {
                    groups.removeAll { $0.id == group.id }
                    keepIDs[group.id] = nil
                }
            } label: {
                Label("不是重复", systemImage: "hand.raised")
            }
        } header: {
            HStack {
                Text(group.confidence.title)
                    .foregroundStyle(color(group.confidence))
                Spacer()
                Text(group.reasons.joined(separator: " · ")).lineLimit(1)
            }
        }
    }

    private func recordRow(_ r: DedupeRecord, group: DedupeGroup) -> some View {
        let keep = keepIDs[group.id] ?? [group.suggestedKeepID]
        let kept = keep.contains(r.id)
        let rec = lookup[r.id]
        return Button {
            var s = keep
            if kept { s.remove(r.id) } else { s.insert(r.id) }
            keepIDs[group.id] = s
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: kept ? "checkmark.circle.fill" : "trash.circle")
                    .foregroundStyle(kept ? Color.green : Color.red)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(rec?.displayTitle ?? r.merchant).font(.body).lineLimit(1)
                        Spacer()
                        Text(rec?.amountText ?? Money.format(r.amount)).font(.body.monospacedDigit())
                    }
                    Text(detailLine(r, rec)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(DedupeEngine.sourceTitle(r.source))
                        if r.id == group.suggestedKeepID { Text("建议保留").foregroundStyle(.green) }
                        if !kept { Text("将删除").foregroundStyle(.red) }
                    }
                    .font(.caption2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detailLine(_ r: DedupeRecord, _ rec: LedgerRecord?) -> String {
        var parts = [DateText.full.string(from: r.date)]
        if let rec {
            if rec.kind == .transfer {
                parts.append((rec.accountRef?.name ?? "?") + " → " + (rec.toAccount?.name ?? "?"))
            } else {
                if !rec.merchant.isEmpty && rec.merchant != rec.displayTitle { parts.append(rec.merchant) }
                parts.append(rec.accountName.isEmpty ? "无账户" : rec.accountName)
                parts.append(rec.categoryName)
            }
            if !rec.note.isEmpty && rec.note != rec.displayTitle { parts.append("备注：" + rec.note) }
        }
        return parts.joined(separator: " · ")
    }

    private func color(_ c: DedupeConfidence) -> Color {
        switch c {
        case .certain: return .red
        case .likely: return .orange
        case .possible: return .secondary
        }
    }

    private var autoPreview: some View {
        let plan = autoPlan
        let deleteCount = plan.reduce(0) { $0 + $1.delete.count }
        let mergeCount = plan.reduce(0) { $0 + $1.patch.fieldCount }
        return List {
            Section {
                Text("将处理 \(plan.count) 组「确定重复」，删除 \(deleteCount) 笔，补全 \(mergeCount) 项信息。很可能 / 可能重复的组不会动，请手动确认。")
                    .font(.subheadline)
            }
            ForEach(plan) { item in
                Section {
                    Label(lookup[item.keep.id]?.deleteSummary ?? item.keep.id, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    ForEach(item.delete, id: \.id) { d in
                        Label(lookup[d.id]?.deleteSummary ?? d.id, systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    if !item.patch.isEmpty {
                        Text("补全：" + patchText(item.patch)).font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("保留 \(DedupeEngine.sourceTitle(item.keep.source))的一笔")
                }
            }
        }
        .navigationTitle("自动处理预览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { showAutoConfirm = false } }
            ToolbarItem(placement: .confirmationAction) {
                Button("删除 \(deleteCount) 笔", role: .destructive) {
                    showAutoConfirm = false
                    applyAuto()
                }
                .disabled(deleteCount == 0)
            }
        }
    }

    private func patchText(_ p: DedupeMergePatch) -> String {
        var s: [String] = []
        if p.categoryFrom != nil { s.append("分类") }
        if p.noteFrom != nil { s.append("备注") }
        if p.merchantFrom != nil { s.append("商户") }
        if p.accountFrom != nil { s.append("账户") }
        return s.joined(separator: "、")
    }

    // MARK: - 操作

    private func reload() {
        undoSnapshot = isReal ? DedupeUndoStore.load() : nil
        guard isReal else {
            // 防窥：不读、不删任何数据
            groups = []; scanned = 0; lookup = [:]; loaded = true
            return
        }
        let result = DedupeService.scan(window: window, in: context)
        groups = result.groups
        scanned = result.scanned
        keepIDs = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, Set([$0.suggestedKeepID])) })
        let ids = Set(groups.flatMap { $0.members.map(\.id) })
        let all = (try? context.fetch(FetchDescriptor<LedgerRecord>())) ?? []
        lookup = Dictionary(all.filter { ids.contains($0.id.uuidString) }.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        loaded = true
    }

    private func applySelection() {
        guard isReal else { return }
        let decisions = groups.map { DedupeService.Decision(group: $0, keepIDs: keepIDs[$0.id] ?? [$0.suggestedKeepID]) }
            .filter { !$0.keepIDs.isEmpty }
        run(decisions, title: "一键去重")
    }

    private func applyAuto() {
        guard isReal else { return }
        let decisions = autoPlan.map { DedupeService.Decision(group: $0.group, keepIDs: [$0.keep.id]) }
        run(decisions, title: "一键去重（自动处理）")
    }

    private func run(_ decisions: [DedupeService.Decision], title: String) {
        do {
            let o = try DedupeService.apply(decisions, title: title, in: context)
            message = o.deleted == 0 ? "没有需要删除的记录" : "已删除 \(o.deleted) 笔重复记录" + (o.merged > 0 ? "，补全 \(o.merged) 项信息" : "") + "。可在本页撤销。"
        } catch {
            message = "删除失败：\(error.localizedDescription)"
        }
        reload()
    }

    private func undo() {
        guard isReal else { return }
        do {
            let n = try DedupeService.undoLast(in: context)
            message = "已恢复 \(n) 笔记录"
        } catch {
            message = "撤销失败：\(error.localizedDescription)"
        }
        reload()
    }
}
