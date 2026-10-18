import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 设置 › iCloud 与备份
struct BackupSettingsView: View {
    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.modelContext) private var context

    @AppStorage(SettingsKey.iCloudSyncEnabled) private var syncEnabled = false
    @AppStorage(SettingsKey.autoBackupEnabled) private var autoBackupEnabled = false
    @AppStorage(SettingsKey.autoBackupInterval) private var autoBackupInterval = 86_400
    @AppStorage(SettingsKey.autoBackupKeep) private var autoBackupKeep = 10
    @AppStorage(SettingsKey.lastBackupAt) private var lastBackupAt: Double = 0
    @AppStorage(SettingsKey.lastBackupLocation) private var lastBackupLocation = ""

    @State private var syncToggle = false
    @State private var didLoad = false
    @State private var checkingICloud = false
    @State private var iCloudAvailable: Bool?
    @State private var backupCount = 0
    @State private var backingUp = false

    @State private var exportDocument: BackupDocument?
    @State private var exportFileName = ""
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var pendingImport: ImportedBackup?
    @State private var alertTitle = ""
    @State private var alertMessage: String?

    struct ImportedBackup: Identifiable {
        let id = UUID()
        let fileName: String
        let backup: LedgerBackup
    }

    var body: some View {
        Form {
            syncSection
            manualSection
            autoSection
        }
        .navigationTitle("iCloud 与备份")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            syncToggle = syncEnabled
        }
        .task {
            checkingICloud = true
            iCloudAvailable = await CloudSync.refreshAvailability()
            checkingICloud = false
            backupCount = await AutoBackup.countBackups()
        }
        .onChange(of: syncToggle) { _, on in
            handleSyncToggle(on)
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json,
                      defaultFilename: exportFileName) { result in
            switch result {
            case .success(let url):
                showAlert("已导出", "备份已保存为「\(url.lastPathComponent)」。")
            case .failure(let error):
                showAlert("导出失败", error.localizedDescription)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                do {
                    let backup = try BackupService.read(from: url)
                    pendingImport = ImportedBackup(fileName: url.lastPathComponent, backup: backup)
                } catch {
                    showAlert("无法导入", error.localizedDescription)
                }
            case .failure(let error):
                showAlert("无法导入", error.localizedDescription)
            }
        }
        .sheet(item: $pendingImport) { item in
            BackupPreviewView(item: item) { mode in
                performRestore(item.backup, mode: mode)
            }
            .environmentObject(lock)
        }
        .alert(alertTitle, isPresented: alertBinding) {
            Button("好", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Sections

    private var syncSection: some View {
        Section {
            HStack {
                Label("当前状态", systemImage: DataStore.syncStatus.isCloud ? "icloud.fill" : "internaldrive.fill")
                Spacer()
                Text(DataStore.syncStatus.title)
                    .foregroundStyle(DataStore.syncStatus.isCloud ? Color.green : Color.secondary)
            }
            Toggle(isOn: $syncToggle) {
                Label("iCloud 同步（CloudKit）", systemImage: "arrow.triangle.2.circlepath.icloud.fill")
            }
            .disabled(checkingICloud)
            if syncEnabled != DataStore.syncStatus.isCloud && pendingRestartNeeded {
                Label("设置将在完全退出并重新打开 App 后生效", systemImage: "arrow.clockwise.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("iCloud 同步")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(DataStore.syncStatus.detail)
                Text("iCloud 同步需要用**付费 Apple 开发者账号**并开启 iCloud（CloudKit）能力重新签名；免费 Apple ID、爱思助手、Sideloadly 等签名通常不含该权限，此时请使用下方的「备份到 iCloud 云盘」。开启前建议先导出一次备份。")
                if let iCloudAvailable {
                    Text(iCloudAvailable ? "检测结果：当前签名可以访问 iCloud 容器。" : "检测结果：当前签名或设备无法访问 iCloud 容器。")
                }
            }
        }
    }

    private var pendingRestartNeeded: Bool {
        // 开启了但因权限/账号问题回退的情况已在状态里说明，不再提示重启
        switch DataStore.syncStatus {
        case .noAccount, .noEntitlement, .failed: return !syncEnabled
        default: return true
        }
    }

    private var manualSection: some View {
        Section {
            Button {
                prepareExport()
            } label: {
                Label("导出备份到文件…", systemImage: "square.and.arrow.up.on.square")
            }
            Button {
                showImporter = true
            } label: {
                Label("从备份恢复…", systemImage: "arrow.down.doc")
            }
        } header: {
            Text("手动备份")
        } footer: {
            Text("备份为 JSON 文件，包含全部记录、分类和预算等设置（不含密码）。导出时选择「iCloud 云盘」即可存到云端；恢复时可选择合并（按 ID 去重）或替换全部数据\(lock.passcodeEnabled ? "，需要输入 App 密码" : "")。")
        }
    }

    private var autoSection: some View {
        Section {
            Toggle(isOn: $autoBackupEnabled) {
                Label("自动备份", systemImage: "clock.arrow.circlepath")
            }
            if autoBackupEnabled {
                Picker(selection: $autoBackupInterval) {
                    ForEach(AutoBackup.intervalOptions, id: \.self) { s in
                        Text(AutoBackup.intervalTitle(s)).tag(s)
                    }
                } label: {
                    Label("频率", systemImage: "calendar")
                }
                Picker(selection: $autoBackupKeep) {
                    ForEach(AutoBackup.keepOptions, id: \.self) { n in
                        Text("\(n) 份").tag(n)
                    }
                } label: {
                    Label("保留最近", systemImage: "square.stack.3d.up.fill")
                }
            }
            Button {
                Task { await backupNow() }
            } label: {
                HStack {
                    Label("立即备份", systemImage: "externaldrive.badge.icloud")
                    Spacer()
                    if backingUp { ProgressView() }
                }
            }
            .disabled(backingUp)
            HStack {
                Text("上次备份")
                Spacer()
                Text(lastBackupText).foregroundStyle(.secondary)
            }
            if !lastBackupLocation.isEmpty {
                HStack(alignment: .top) {
                    Text("位置")
                    Spacer()
                    Text(lastBackupLocation)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
            }
        } header: {
            Text("自动备份")
        } footer: {
            Text("回到 App 时按频率自动备份。签名带 iCloud 权限时备份到「iCloud 云盘 › 简账」，否则保存在「文件 › 我的 iPhone › 简账」，可手动复制到 iCloud 云盘。当前共有 \(backupCount) 份备份。")
        }
    }

    // MARK: - Actions

    private var lastBackupText: String {
        guard lastBackupAt > 0 else { return "从未" }
        return DateText.full.string(from: Date(timeIntervalSince1970: lastBackupAt))
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })
    }

    private func showAlert(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
    }

    @MainActor
    private func prepareExport() {
        do {
            let data = try BackupService.encode(BackupService.makeBackup(context: context))
            exportDocument = BackupDocument(data: data)
            exportFileName = BackupService.fileName()
            showExporter = true
        } catch {
            showAlert("导出失败", error.localizedDescription)
        }
    }

    @MainActor
    private func backupNow() async {
        backingUp = true
        defer { backingUp = false }
        do {
            let url = try await AutoBackup.backupNow(context: context)
            backupCount = await AutoBackup.countBackups()
            showAlert("备份完成", "已保存「\(url.lastPathComponent)」。")
        } catch {
            showAlert("备份失败", error.localizedDescription)
        }
    }

    @MainActor
    private func performRestore(_ backup: LedgerBackup, mode: RestoreMode) {
        pendingImport = nil
        let title: String
        let message: String
        do {
            let result = try BackupService.restore(backup, mode: mode, context: context)
            title = "恢复完成"
            message = result.summary
        } catch {
            title = "恢复失败"
            message = error.localizedDescription
        }
        // 等弹窗关闭动画结束再显示结果
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            showAlert(title, message)
        }
    }

    @MainActor
    private func handleSyncToggle(_ on: Bool) {
        guard on != syncEnabled else { return }
        if !on {
            syncEnabled = false
            return
        }
        Task { @MainActor in
            checkingICloud = true
            let ok = await CloudSync.refreshAvailability()
            checkingICloud = false
            iCloudAvailable = ok
            if ok {
                syncEnabled = true
                showAlert("已开启 iCloud 同步", "请完全退出并重新打开简账后生效。首次同步会把现有数据上传到你的 iCloud 私有数据库。")
            } else {
                syncToggle = false
                showAlert("无法开启 iCloud 同步",
                          CloudSync.hasAccount
                          ? "当前安装包的签名不含 iCloud（CloudKit）权限。需要用付费 Apple 开发者账号、开启 iCloud 能力并配置容器「\(CloudSync.containerID)」后重新签名。你仍可以使用「备份到 iCloud 云盘」。"
                          : "这台设备没有登录 iCloud。请先在系统设置中登录 Apple ID 并打开 iCloud。")
            }
        }
    }
}

/// 导入前预览备份内容，选择合并 / 替换
struct BackupPreviewView: View {
    let item: BackupSettingsView.ImportedBackup
    let onRestore: (RestoreMode) -> Void

    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.dismiss) private var dismiss
    @State private var showReplaceConfirm = false
    @State private var verifyMode: RestoreMode?

    var body: some View {
        let b = item.backup
        NavigationStack {
            Form {
                Section("备份信息") {
                    row("文件", item.fileName)
                    row("备份时间", DateText.full.string(from: b.createdAt))
                    row("来自设备", b.device)
                    row("App 版本", b.appVersion)
                }
                Section("内容") {
                    row("记录", "\(b.records.count) 笔")
                    row("分类", "\(b.categories.count) 个")
                    if let range = b.recordDateRange {
                        row("时间范围", DateText.shortDate.string(from: range.lowerBound) + " – " + DateText.shortDate.string(from: range.upperBound))
                    }
                    row("支出合计", Money.format(b.records.filter { $0.kind == RecordKind.expense.rawValue }.reduce(0) { $0 + $1.amount }))
                    row("收入合计", Money.format(b.records.filter { $0.kind == RecordKind.income.rawValue }.reduce(0) { $0 + $1.amount }))
                }
                Section {
                    Button {
                        start(.merge)
                    } label: {
                        Label("合并到现有数据", systemImage: "arrow.triangle.merge")
                    }
                    Button(role: .destructive) {
                        showReplaceConfirm = true
                    } label: {
                        Label("替换全部数据", systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("合并：按记录 ID 去重，已存在的记录跳过，同名分类自动对应。替换：删除当前所有记录和分类后导入，并恢复预算等设置。")
                }
            }
            .navigationTitle("从备份恢复")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .confirmationDialog("替换全部数据？", isPresented: $showReplaceConfirm, titleVisibility: .visible) {
                Button("删除现有数据并导入", role: .destructive) { start(.replace) }
            } message: {
                Text("当前所有记录和分类将被删除，且无法撤销。")
            }
            .sheet(item: verifyBinding) { wrapper in
                PasscodeVerifyView(reason: wrapper.mode == .replace ? "替换数据前请验证 App 密码" : "恢复数据前请验证 App 密码") {
                    onRestore(wrapper.mode)
                }
                .environmentObject(lock)
            }
        }
    }

    private struct ModeWrapper: Identifiable {
        let mode: RestoreMode
        var id: String { mode == .merge ? "merge" : "replace" }
    }

    private var verifyBinding: Binding<ModeWrapper?> {
        Binding(
            get: { verifyMode.map { ModeWrapper(mode: $0) } },
            set: { verifyMode = $0?.mode }
        )
    }

    private func start(_ mode: RestoreMode) {
        if lock.passcodeEnabled {
            verifyMode = mode
        } else {
            onRestore(mode)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
