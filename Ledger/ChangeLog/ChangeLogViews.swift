import SwiftUI
import SwiftData
import Combine

/// 设置 › 变动日志（仅真实模式可进入）
struct ChangeLogView: View {
    @State private var entries: [ChangeLogEntry] = []
    @State private var search = ""
    @State private var entityFilter: ChangeEntity?
    @State private var sourceFilter: ChangeSource?
    @AppStorage(ChangeLogger.retentionKey, store: .standard) private var retentionDays = 0
    @State private var showClearConfirm = false
    @State private var showPlainExportConfirm = false
    @State private var share: ShareItem?
    @State private var message: String?

    private var filtered: [ChangeLogEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return entries.filter { e in
            (entityFilter == nil || e.entity == entityFilter)
                && (sourceFilter == nil || e.source == sourceFilter)
                && (q.isEmpty || e.searchText.localizedCaseInsensitiveContains(q))
        }
    }

    private var groups: [(day: Date, items: [ChangeLogEntry])] {
        let cal = DateText.calendar
        var out: [(Date, [ChangeLogEntry])] = []
        for e in filtered {
            let day = cal.startOfDay(for: e.timestamp)
            if let last = out.last, last.0 == day { out[out.count - 1].1.append(e) } else { out.append((day, [e])) }
        }
        return out.map { (day: $0.0, items: $0.1) }
    }

    var body: some View {
        List {
            if entityFilter != nil || sourceFilter != nil {
                Section {
                    HStack {
                        Text("筛选：" + [entityFilter?.title, sourceFilter?.title].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline)
                        Spacer()
                        Button("清除") { entityFilter = nil; sourceFilter = nil }.font(.subheadline)
                    }
                }
            }
            if filtered.isEmpty {
                ContentUnavailableView {
                    Label(entries.isEmpty ? "还没有变动记录" : "没有符合条件的记录", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text(entries.isEmpty ? "记账、账户、分类、预算、规则、周期账单、设置与安全的每次变动都会记在这里。" : "换个关键词或筛选条件试试。")
                }
                .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.day) { group in
                Section(DateText.dayHeader.string(from: group.day)) {
                    ForEach(group.items) { e in
                        NavigationLink { ChangeLogDetailView(entry: e) } label: { ChangeLogRow(entry: e) }
                            .accessibilityIdentifier("changelog-row")
                    }
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("只记录真实账本的变动，不记录密码，也不记录防窥账本的任何内容。保留期限：\(ChangeLogger.retentionTitle(retentionDays))。")
            }
        }
        .navigationTitle("变动日志")
        .searchable(text: $search, prompt: "搜索摘要、字段或金额")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("类型", selection: $entityFilter) {
                        Text("全部类型").tag(ChangeEntity?.none)
                        ForEach(ChangeEntity.allCases) { Label($0.title, systemImage: $0.icon).tag(ChangeEntity?.some($0)) }
                    }
                    Picker("来源", selection: $sourceFilter) {
                        Text("全部来源").tag(ChangeSource?.none)
                        ForEach(ChangeSource.allCases) { Text($0.title).tag(ChangeSource?.some($0)) }
                    }
                } label: {
                    Image(systemName: entityFilter == nil && sourceFilter == nil
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("changelog-filter")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("保留期限", selection: $retentionDays) {
                        ForEach(ChangeLogger.retentionOptions, id: \.self) { Text(ChangeLogger.retentionTitle($0)).tag($0) }
                    }
                    Button { exportTapped() } label: { Label("导出日志", systemImage: "square.and.arrow.up") }
                        .disabled(entries.isEmpty)
                    Button(role: .destructive) { showClearConfirm = true } label: { Label("清空日志", systemImage: "trash") }
                        .disabled(entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("changelog-more")
            }
        }
        .alert("清空变动日志？", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) { ChangeLogger.shared.clearAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除全部 \(entries.count) 条记录，无法恢复。清空这一操作本身会记为新的第一条。")
        }
        .alert("导出明文日志？", isPresented: $showPlainExportConfirm) {
            Button("继续导出") { export(password: nil) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前未开启加密备份，导出的 JSON 没有加密，包含金额、备注等变动明细。")
        }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(message ?? "") }
        .sheet(item: $share) { item in
            ActivityView(items: [item.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .changeLogDidChange)) { _ in reload() }
    }

    private func reload() {
        entries = ChangeLogger.shared.fetchAll()
    }

    /// 与备份导出规则一致：开启加密时用本机保存的备份密码加密；未开启时确认后导出明文
    private func exportTapped() {
        if BackupPasswordStore.encryptionEnabled {
            guard let pw = BackupPasswordStore.load() else {
                message = "已开启「加密备份」，但本机还没有保存备份密码。请先在「iCloud 与备份 › 备份加密」中设置，或关闭加密后导出明文。"
                return
            }
            export(password: pw)
        } else {
            showPlainExportConfirm = true
        }
    }

    private func export(password: String?) {
        let dtos = entries.map(\.dto)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        let encrypted = password != nil
        let name = "简账变动日志-\(f.string(from: Date())).\(encrypted ? "jzlog" : "json")"
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(dtos)
            if let password {
                data = try BackupCrypto.encrypt(data, password: password, iterations: BackupCrypto.tunedIterations())
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            ChangeLogger.log(.create, .backup, summary: "导出变动日志（\(encrypted ? "加密" : "明文")，\(dtos.count) 条）")
            share = ShareItem(url: url)
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }
}

struct ChangeLogRow: View {
    let entry: ChangeLogEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.entity.icon)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.summary)
                    .font(.subheadline)
                    .lineLimit(2)
                Text("\(entry.action.title) · \(entry.entity.title) · \(entry.source.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(DateText.time.string(from: entry.timestamp))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private var tint: Color {
        switch entry.action {
        case .create: return .green
        case .update: return .blue
        case .delete: return .red
        case .batch: return .orange
        }
    }
}

struct ChangeLogDetailView: View {
    let entry: ChangeLogEntry

    var body: some View {
        List {
            Section {
                Text(entry.summary).font(.body)
                LabeledContent("时间", value: DateText.full.string(from: entry.timestamp))
                LabeledContent("操作", value: entry.action.title)
                LabeledContent("对象", value: entry.entity.title)
                LabeledContent("来源", value: entry.source.title)
            }
            let diffs = entry.diffs
            if !diffs.isEmpty {
                Section("字段变动") {
                    ForEach(Array(diffs.enumerated()), id: \.offset) { _, d in
                        DiffRow(diff: d)
                    }
                }
            }
            let children = entry.children
            if !children.isEmpty {
                Section {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, c in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(ChangeAction(rawValue: c.action)?.title ?? c.action) · \(ChangeEntity(rawValue: c.entity)?.title ?? c.entity)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(c.summary).font(.subheadline)
                            if let ds = c.diffs, c.action == ChangeAction.update.rawValue {
                                ForEach(Array(ds.enumerated()), id: \.offset) { _, d in
                                    Text("\(d.field)：\(d.old ?? "（空）") → \(d.new ?? "（空）")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text(entry.childCount > children.count ? "明细（共 \(entry.childCount) 项，显示前 \(children.count) 项）" : "明细（\(children.count) 项）")
                }
            }
        }
        .navigationTitle("变动详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DiffRow: View {
    let diff: FieldDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(diff.field).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let old = diff.old {
                    Text(old)
                        .strikethrough(diff.new != nil)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("diff-old-\(diff.field)")
                } else {
                    Text("（空）").foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                if let new = diff.new {
                    Text(new)
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("diff-new-\(diff.field)")
                } else {
                    Text("（空）").foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        }
    }
}

#if DEBUG
/// UI 测试探针：启动参数含 `-UITestChangeLogProbe` 时，在角落放一个几乎不可见的计数（真实库中的日志条数）
struct ChangeLogProbe: View {
    @State private var count = 0
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-UITestChangeLogProbe") }

    var body: some View {
        Text("\(count)")
            .font(.system(size: 6))
            .opacity(0.05)
            .accessibilityLabel("\(count)")
            .accessibilityIdentifier("debug-changelog-count")
            .onAppear { count = ChangeLogger.shared.fetchAll().count }
            .onReceive(NotificationCenter.default.publisher(for: .changeLogDidChange)) { _ in
                count = ChangeLogger.shared.fetchAll().count
            }
    }
}
#endif
