import SwiftUI
import SwiftData
import AppIntents

struct SettingsView: View {
    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerRecord.date, order: .reverse) private var records: [LedgerRecord]
    @Query(sort: \LedgerAccount.sortOrder) private var accounts: [LedgerAccount]

    @AppStorage(SettingsKey.monthlyBudget) private var budget: Double = 0
    @AppStorage(SettingsKey.currencySymbol) private var currencySymbol = "¥"
    @AppStorage(SettingsKey.appearance) private var appearance = 0
    @AppStorage(SettingsKey.defaultAccount) private var defaultAccount = ""
    @AppStorage(SettingsKey.hideInAppSwitcher) private var hideInAppSwitcher = true
    @AppStorage(SettingsKey.lastBackupAt) private var lastBackupAt: Double = 0
    @State private var showDemoBackup = false
    @State private var demoDestination: String?
    @State private var showFileImporter = false
    @State private var importSession: ImportSession?
    @State private var importMessage: String?
    @Query private var rules: [CategoryRule]
    @Query private var recurringRules: [RecurringRule]
    @Query private var batches: [ImportBatch]

    @State private var passcodeFlow: PasscodeFlowView.Mode?
    @State private var passcodeToggle = false
    @State private var biometricToggle = false
    @State private var decoyEnabled = DecoyPasscodeStore.isEnabled
    @State private var showDecoySetup = false
    @State private var showDecoyEditor = false
    @State private var showDecoyResetConfirm = false
    @State private var decoyMessage: String?
    @EnvironmentObject private var session: SessionManager
    @State private var showDeleteAll = false
    @State private var showCSVWarning = false
    @State private var csvShare: ShareItem?
    @AppStorage(SettingsKey.backupNeedsPassword) private var backupNeedsPassword = false
    @State private var biometricError: String?

    var body: some View {
        NavigationStack {
            Form {
                securitySection
                if !session.isDecoy {
                    bookkeepingSection
                    smartSection
                    backupSection
                    shortcutSection
                } else {
                    decoyDataSection
                }
                appearanceSection
                if !session.isDecoy {
                    dataSection
                }
                aboutSection
            }
            .navigationTitle("设置")
            .navigationDestination(isPresented: $showDemoBackup) { BackupSettingsView() }
            .navigationDestination(item: $demoDestination) { screen in
                switch screen {
                case "rules": RulesView()
                case "recurring": RecurringListView()
                default: BudgetView()
                }
            }
            .task {
                // 截图模式：直接打开对应页面
                switch ScreenshotDemo.screen {
                case "backup", "backupencrypt": if !showDemoBackup { showDemoBackup = true }
                case "decoysettings":
                    decoyEnabled = true
                    // 截图里展开防窥选项：依赖 decoyEnabled 已为 true
                    break
                case "rules", "recurring", "budgets": if demoDestination == nil { demoDestination = ScreenshotDemo.screen }
                case "import":
                    if importSession == nil, let session = ScreenshotDemo.importSession() { importSession = session }
                default: break
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: ImportSession.contentTypes) { result in
                switch result {
                case .success(let url):
                    do { importSession = try ImportSession.load(url: url) }
                    catch { importMessage = error.localizedDescription }
                case .failure(let error):
                    importMessage = error.localizedDescription
                }
            }
            .sheet(item: $importSession) { session in
                ImportPreviewView(session: session) { count in
                    if count > 0 { importMessage = "已导入 \(count) 笔。可在「导入记录」中整批撤销。" }
                }
            }
            .alert("账单导入", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importMessage ?? "")
            }
            .onAppear {
                passcodeToggle = lock.passcodeEnabled
                biometricToggle = lock.biometricsEnabled
            }
            .onChange(of: lock.passcodeEnabled) { _, enabled in
                passcodeToggle = enabled
                biometricToggle = lock.biometricsEnabled
            }
            .onChange(of: passcodeToggle) { _, on in
                if session.isDecoy {
                    passcodeToggle = lock.passcodeEnabled
                    decoyMessage = "暂时无法修改密码，请稍后再试。"
                } else if on != lock.passcodeEnabled {
                    passcodeFlow = on ? .set : .disable
                }
            }
            .onChange(of: biometricToggle) { _, on in
                handleBiometricToggle(on)
            }
            .sheet(item: $passcodeFlow, onDismiss: {
                // 流程被取消时，把开关恢复成真实状态
                passcodeToggle = lock.passcodeEnabled
                biometricToggle = lock.biometricsEnabled
            }) { mode in
                PasscodeFlowView(mode: mode)
                    .environmentObject(lock)
            }
            .alert("无法开启", isPresented: biometricAlertBinding) {
                Button("好", role: .cancel) { biometricError = nil }
            } message: {
                Text(biometricError ?? "")
            }
        }
    }

    // MARK: - Sections

    private var securitySection: some View {
        Section {
            Toggle(isOn: $passcodeToggle) {
                Label("密码锁", systemImage: "lock.fill")
            }
            if lock.passcodeEnabled {
                Button {
                    if session.isDecoy {
                        decoyMessage = "暂时无法修改密码，请稍后再试。"
                    } else {
                        passcodeFlow = .change
                    }
                } label: {
                    Label("修改密码", systemImage: "key.fill")
                }
                if lock.canUseBiometrics {
                    Toggle(isOn: $biometricToggle) {
                        Label("\(lock.biometryName)解锁", systemImage: lock.biometryIcon)
                    }
                }
                Picker(selection: $lock.gracePeriod) {
                    ForEach(AppLockManager.graceOptions, id: \.self) { seconds in
                        Text(AppLockManager.graceTitle(seconds)).tag(seconds)
                    }
                } label: {
                    Label("离开后多久需要解锁", systemImage: "timer")
                }
                Button {
                    lock.lockNow()
                } label: {
                    Label("立即锁定", systemImage: "lock.rotation")
                }
            }
            Toggle(isOn: $hideInAppSwitcher) {
                Label("多任务界面隐藏内容", systemImage: "eye.slash.fill")
            }
            if lock.passcodeEnabled && !session.isDecoy {
                Toggle(isOn: Binding(
                    get: { decoyEnabled },
                    set: { on in
                        if on {
                            showDecoySetup = true
                        } else {
                            DecoyPasscodeStore.remove()
                            decoyEnabled = false
                        }
                    }
                )) {
                    Label("防窥模式", systemImage: "eye.trianglebadge.exclamationmark")
                }
                if decoyEnabled {
                    Button { showDecoyEditor = true } label: {
                        Label("编辑防窥数据", systemImage: "pencil.and.outline")
                    }
                    Button(role: .destructive) { showDecoyResetConfirm = true } label: {
                        Label("重置为预设数据", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        } header: {
            Text("安全与隐私")
        } footer: {
            if session.isDecoy {
                Text("密码以加盐哈希保存在本机钥匙串。")
            } else {
                Text("密码以加盐哈希保存在本机钥匙串。面容 ID / 触控 ID 始终进入真实账本；只有输入防窥密码才会进入防窥账本。防窥数据存在独立文件中，不会同步到 iCloud，也不会写入真实备份。快捷指令记账始终写入真实账本。")
            }
        }
        .onAppear { decoyEnabled = DecoyPasscodeStore.isEnabled }
        .sheet(isPresented: $showDecoySetup, onDismiss: { decoyEnabled = DecoyPasscodeStore.isEnabled }) {
            DecoyPasscodeSetupView { decoyEnabled = true }
                .environmentObject(lock)
        }
        .fullScreenCover(isPresented: $showDecoyEditor) {
            DecoyDataEditorHost()
                .environmentObject(lock)
        }
        .confirmationDialog("重置防窥数据？", isPresented: $showDecoyResetConfirm, titleVisibility: .visible) {
            Button("恢复为预设数据", role: .destructive) {
                session.resetDecoyStore()
                decoyMessage = "已恢复为预设的防窥账本数据。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前防窥账本里的账户和记录会被替换成一套普通的小额示例数据。")
        }
        /.alert("提示", isPresented: Binding(get: { decoyMessage != nil }, set: { if !$0 { decoyMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(decoyMessage ?? "") }
    }

    private var bookkeepingSection: some View {
        Section("记账") {
            NavigationLink {
                CategoryManagerView()
            } label: {
                Label("分类管理", systemImage: "square.grid.2x2.fill")
            }
            NavigationLink {
                BudgetView()
            } label: {
                HStack {
                    Label("预算", systemImage: "target")
                    Spacer()
                    Text(budget > 0 ? "每月 \(Money.format(budget))" : "未设置")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Label("默认账户", systemImage: "creditcard.fill")
                Spacer()
                Menu {
                    Button("不设置") { defaultAccount = "" }
                    ForEach(accounts.filter { !$0.isArchived }) { a in
                        Button(a.name) { defaultAccount = a.name }
                    }
                } label: {
                    Text(defaultAccount.isEmpty ? "不设置" : defaultAccount)
                        .foregroundStyle(.secondary)
                }
            }
            Picker(selection: $currencySymbol) {
                Text("人民币 ¥").tag("¥")
                Text("美元 $").tag("$")
                Text("欧元 €").tag("€")
                Text("港币 HK$").tag("HK$")
                Text("日元 JP¥").tag("JP¥")
            } label: {
                Label("货币符号", systemImage: "dollarsign.circle.fill")
            }
        }
    }

    private var smartSection: some View {
        Section {
            NavigationLink {
                RulesView()
            } label: {
                settingRow("记账规则", icon: "wand.and.stars", detail: rules.isEmpty ? "" : "\(rules.count) 条")
            }
            Button {
                showFileImporter = true
            } label: {
                Label("导入支付宝 / 微信账单", systemImage: "square.and.arrow.down.on.square")
            }
            NavigationLink {
                ImportBatchesView()
            } label: {
                settingRow("导入记录", icon: "clock.arrow.circlepath", detail: batches.isEmpty ? "" : "\(batches.count) 次")
            }
            NavigationLink {
                RecurringListView()
            } label: {
                settingRow("周期账单", icon: "arrow.triangle.2.circlepath", detail: recurringRules.isEmpty ? "" : "\(recurringRules.count) 项")
            }
        } header: {
            Text("智能记账")
        } footer: {
            Text("支付宝：我的 › 账单 › 右上角 ··· › 开具交易流水证明 › 用于个人对账；微信：我 › 服务 › 钱包 › 账单 › 常见问题 › 下载账单 › 用于个人对账。收到的 CSV / XLSX 文件（解压后）用「存储到文件」保存，再在这里导入。")
        }
    }

    private func settingRow(_ title: String, icon: String, detail: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if !detail.isEmpty {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    /// 防窥模式下的「数据」：措辞普通，绝不提防窥，且不会碰到真实备份
    private var decoyDataSection: some View {
        Section {
            Label("账本保存在本机", systemImage: "internaldrive.fill")
            Text("当前不会使用 iCloud 同步或自动备份。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } header: {
            Text("数据")
        } footer: {
            Text("所有记账仅保存在这台设备上。")
        }
    }

    private var backupSection: some View {
        Section {
            NavigationLink {
                BackupSettingsView()
            } label: {
                HStack {
                    Label("iCloud 同步与备份", systemImage: DataStore.syncStatus.isCloud ? "icloud.fill" : "externaldrive.badge.icloud")
                    Spacer()
                    Text(DataStore.syncStatus.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if backupNeedsPassword {
                Label("自动备份已暂停：需要设置备份密码", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            HStack {
                Label("上次备份", systemImage: "clock")
                Spacer()
                Text(lastBackupAt > 0 ? DateText.full.string(from: Date(timeIntervalSince1970: lastBackupAt)) : "从未")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("iCloud 与备份")
        } footer: {
            Text("可导出备份到 iCloud 云盘并随时恢复；iCloud 自动同步需要付费开发者账号签名。")
        }
    }

    private var shortcutSection: some View {
        Section {
            NavigationLink {
                ShortcutGuideView()
            } label: {
                Label("识图记账设置教程", systemImage: "text.viewfinder")
            }
            ShortcutsLink()
                .frame(maxWidth: .infinity)
        } header: {
            Text("快捷指令")
        } footer: {
            Text("在「快捷指令」App 中搜索「简账」即可找到「识图记账」「记一笔」「本月收支」。")
        }
    }

    private var appearanceSection: some View {
        Section("外观") {
            Picker(selection: $appearance) {
                Text("跟随系统").tag(0)
                Text("浅色").tag(1)
                Text("深色").tag(2)
            } label: {
                Label("主题", systemImage: "circle.lefthalf.filled")
            }
        }
    }

    private var dataSection: some View {
        Section {
            Button {
                showCSVWarning = true
            } label: {
                Label("导出 CSV", systemImage: "square.and.arrow.up")
            }
            .disabled(records.isEmpty)
            .alert("导出明文 CSV？", isPresented: $showCSVWarning) {
                Button("继续导出") { exportCSV() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("CSV 文件没有加密，任何拿到文件的人都能看到全部 \(records.count) 笔记录、金额和备注。请只分享给信任的人或 App；需要加密请使用「iCloud 与备份 › 导出备份」。")
            }
            .sheet(item: $csvShare) { item in
                ActivityView(items: [item.url])
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
            Button(role: .destructive) {
                showDeleteAll = true
            } label: {
                Label("删除全部记录", systemImage: "trash")
            }
            .disabled(records.isEmpty)
            .confirmationDialog("删除全部记录？", isPresented: $showDeleteAll, titleVisibility: .visible) {
                Button("删除全部 \(records.count) 笔记录", role: .destructive) { deleteAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作不可恢复，建议先导出 CSV 或 JSON 备份。分类和账户会保留。")
            }
        } header: {
            Text("数据")
        } footer: {
            Text("共 \(records.count) 笔记录。所有数据仅保存在本机，不会上传到任何服务器。")
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("版本")
                Spacer()
                Text(appVersion).foregroundStyle(.secondary)
            }
            Label("数据本地存储 · 识别在本机完成 · 无网络请求", systemImage: "checkmark.shield.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func exportCSV() {
        let rows = records.map { RecordSnapshot($0) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(exportFileName)
        do {
            try? FileManager.default.removeItem(at: url)
            try CSVBuilder.build(rows).write(to: url, options: [.atomic, .completeFileProtection])
            csvShare = ShareItem(url: url)
        } catch {
            importMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private var exportFileName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return "简账导出-\(f.string(from: Date())).csv"
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    private var biometricAlertBinding: Binding<Bool> {
        Binding(get: { biometricError != nil }, set: { if !$0 { biometricError = nil } })
    }

    @MainActor
    private func handleBiometricToggle(_ on: Bool) {
        guard on != lock.biometricsEnabled else { return }
        if !on {
            lock.biometricsEnabled = false
            return
        }
        Task { @MainActor in
            let ok = await lock.evaluateBiometrics(reason: "开启\(lock.biometryName)解锁简账")
            if ok {
                lock.biometricsEnabled = true
            } else {
                biometricToggle = false
                biometricError = "\(lock.biometryName)验证未通过。"
            }
        }
    }

    @MainActor
    private func deleteAll() {
        for r in records { context.delete(r) }
        for b in batches { context.delete(b) }
        try? context.save()
    }
}
