import SwiftUI
import SwiftData
import AppIntents

struct SettingsView: View {
    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerRecord.date, order: .reverse) private var records: [LedgerRecord]

    @AppStorage(SettingsKey.monthlyBudget) private var budget: Double = 0
    @AppStorage(SettingsKey.currencySymbol) private var currencySymbol = "¥"
    @AppStorage(SettingsKey.appearance) private var appearance = 0
    @AppStorage(SettingsKey.defaultAccount) private var defaultAccount = ""
    @AppStorage(SettingsKey.hideInAppSwitcher) private var hideInAppSwitcher = true

    @State private var passcodeFlow: PasscodeFlowView.Mode?
    @State private var passcodeToggle = false
    @State private var biometricToggle = false
    @State private var budgetText = ""
    @State private var showDeleteAll = false
    @State private var biometricError: String?
    @FocusState private var budgetFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                securitySection
                bookkeepingSection
                shortcutSection
                appearanceSection
                dataSection
                aboutSection
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { budgetFocused = false }
                }
            }
            .onAppear {
                passcodeToggle = lock.passcodeEnabled
                biometricToggle = lock.biometricsEnabled
                if budget <= 0 {
                    budgetText = ""
                } else if budget == budget.rounded() {
                    budgetText = String(format: "%.0f", budget)
                } else {
                    budgetText = String(format: "%.2f", budget)
                }
            }
            .onChange(of: lock.passcodeEnabled) { _, enabled in
                passcodeToggle = enabled
                biometricToggle = lock.biometricsEnabled
            }
            .onChange(of: passcodeToggle) { _, on in
                if on != lock.passcodeEnabled {
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
            .confirmationDialog("删除全部记录？", isPresented: $showDeleteAll, titleVisibility: .visible) {
                Button("删除全部 \(records.count) 笔记录", role: .destructive) { deleteAll() }
            } message: {
                Text("此操作不可恢复，建议先导出 CSV 备份。分类会保留。")
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
                    passcodeFlow = .change
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
        } header: {
            Text("安全与隐私")
        } footer: {
            Text("密码以加盐哈希保存在本机钥匙串。快捷指令 / Siri 记账在后台运行，不需要解锁 App，但需要设备已解锁。")
        }
    }

    private var bookkeepingSection: some View {
        Section("记账") {
            NavigationLink {
                CategoryManagerView()
            } label: {
                Label("分类管理", systemImage: "square.grid.2x2.fill")
            }
            HStack {
                Label("每月预算", systemImage: "target")
                Spacer()
                TextField("未设置", text: $budgetText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($budgetFocused)
                    .frame(maxWidth: 140)
                    .onChange(of: budgetText) { _, newValue in
                        budget = max(0, Money.parse(newValue) ?? 0)
                    }
            }
            HStack {
                Label("默认账户", systemImage: "creditcard.fill")
                Spacer()
                Menu {
                    Button("不设置") { defaultAccount = "" }
                    ForEach(RecordEditorView.accountOptions, id: \.self) { option in
                        Button(option) { defaultAccount = option }
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
            ShareLink(
                item: CSVExportFile(rows: records.map { RecordSnapshot($0) }, fileName: exportFileName),
                preview: SharePreview("简账导出（\(records.count) 笔）")
            ) {
                Label("导出 CSV", systemImage: "square.and.arrow.up")
            }
            .disabled(records.isEmpty)
            Button(role: .destructive) {
                showDeleteAll = true
            } label: {
                Label("删除全部记录", systemImage: "trash")
            }
            .disabled(records.isEmpty)
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
        try? context.save()
    }
}
