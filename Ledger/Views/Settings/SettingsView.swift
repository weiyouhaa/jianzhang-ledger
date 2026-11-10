import SwiftUI
import SwiftData
import AppIntents

struct SettingsView: View {
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerRecord.date, order: .reverse) private var records: [LedgerRecord]
    @Query(sort: \LedgerAccount.sortOrder) private var accounts: [LedgerAccount]

    @AppStorage(SettingsKey.monthlyBudget) private var budget: Double = 0
    @AppStorage(SettingsKey.currencySymbol) private var currencySymbol = "¥"
    @AppStorage(SettingsKey.appearance, store: .standard) private var appearance = 0
    @AppStorage(SettingsKey.skin, store: .standard) private var skinRaw = AppSkin.defaultSkinRaw
    @AppStorage(SettingsKey.receiptPaper, store: .standard) private var receiptPaperRaw = ReceiptPaper.cotton.rawValue
    @AppStorage(SettingsKey.receiptFab, store: .standard) private var receiptFabRaw = ReceiptFabStyle.seal.rawValue
    @AppStorage(SettingsKey.defaultAccount) private var defaultAccount = ""
    @AppStorage(RepaymentSetting.key) private var repaymentAsExpense = false
    /// 识图「识别引擎」：设备级设置
    @AppStorage(OCREngineSetting.key, store: .standard) private var ocrEngine = OCREngineSetting.auto
    @State private var aiStatus: AppleIntelligenceStatus = .unavailable
    @AppStorage(OCREngineSetting.shortcutsKey, store: .standard) private var aiInShortcuts = false
    @AppStorage(SettingsKey.hideInAppSwitcher, store: .standard) private var hideInAppSwitcher = true
    @AppStorage(SettingsKey.lastBackupAt, store: .standard) private var lastBackupAt: Double = 0
    @State private var showDemoBackup = false
    @State private var demoDestination: String?
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
    @AppStorage(SettingsKey.backupNeedsPassword, store: .standard) private var backupNeedsPassword = false
    @State private var biometricError: String?

    var body: some View {
        NavigationStack {
            Group {
                if theme.isReceipt {
                    receiptScrollBody
                } else {
                    defaultFormBody
                }
            }
            .themedScreenBackground()
            .themedRootTitle("设置")
            .navigationDestination(isPresented: $showDemoBackup) { BackupSettingsView() }
            .navigationDestination(item: $demoDestination) { screen in
                switch screen {
                case "rules": RulesView()
                case "recurring": RecurringListView()
                case "changelog": ChangeLogView()
                default: BudgetView()
                }
            }
            .task {
                // 截图模式：直接打开对应页面
                switch ScreenshotDemo.screen {
                case "backup", "backupencrypt": if !showDemoBackup { showDemoBackup = true }
                case "decoyeditor", "decoyeditorhome":
                    if !showDecoyEditor { showDecoyEditor = true }
                case "decoysettings":
                    decoyEnabled = true
                    // 截图里展开防窥选项：依赖 decoyEnabled 已为 true
                    break
                case "rules", "recurring", "budgets", "changelog": if demoDestination == nil { demoDestination = ScreenshotDemo.screen }
                case "import":
                    if BillImportCenter.shared.session == nil, let session = ScreenshotDemo.importSession() { BillImportCenter.shared.session = session }
                default: break
                }
            }
            // 账单导入：选择器用 UIKit 直接弹出（2.0 (12)），预览 / 提示挂在 TabView 层的 BillImportHost 上：
            // 之前与本页的密码 sheet、多个 alert 挂在同一个 Form 上，且在选择器回调里同步弹预览，选完 Excel 会「没反应」
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
        // 防窥相关的弹窗挂在 NavigationStack 上，而不是 Form 里的 Section：
        // 挂在列表 Section 上的 presentation 会随单元格重建 / 复用被系统收起（「弹一下就消失」）
        .onAppear { decoyEnabled = DecoyPasscodeStore.isEnabled }
        .sheet(isPresented: $showDecoySetup, onDismiss: { decoyEnabled = DecoyPasscodeStore.isEnabled }) {
            DecoyPasscodeSetupView {
                decoyEnabled = true
                // 开防窥时回到默认：输密码解锁、锁屏不显示面容按钮（锁屏看起来始终一样）
                lock.unlockMethod = .passcode
                lock.showBiometricButton = false
            }
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
        .alert("提示", isPresented: Binding(get: { decoyMessage != nil }, set: { if !$0 { decoyMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(decoyMessage ?? "") }
    }

    // MARK: - Sections

    private var defaultFormBody: some View {
        ThemedForm {
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
    }

    /// 小票皮肤专属：独立 ScrollView + 直角纸张卡片，消除 iOS 27 Form 26pt 大圆角与出纸口裁切
    private var receiptScrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VermilionStamp(text: "PREFERENCES · 账本设置")
                    Spacer()
                    ReceiptLabelText(text: "LOCAL ONLY", color: theme.faint)
                }
                .padding(.horizontal, 2)

                if !session.isDecoy {
                    receiptCard(
                        title: "iCloud 与备份",
                        footer: "可导出备份到 iCloud 云盘并随时恢复；iCloud 自动同步需要付费开发者账号签名。"
                    ) {
                        NavigationLink {
                            BackupSettingsView()
                        } label: {
                            receiptRowLabel(
                                "iCloud 同步与备份",
                                icon: DataStore.syncStatus.isCloud ? "icloud.fill" : "externaldrive.badge.icloud",
                                detail: DataStore.syncStatus.title,
                                showChevron: true
                            )
                        }
                        .buttonStyle(.plain)

                        if backupNeedsPassword {
                            receiptRule
                            Label("自动备份已暂停：需要设置备份密码", systemImage: "exclamationmark.triangle.fill")
                                .font(theme.serifLabelFont)
                                .foregroundStyle(theme.caution)
                                .padding(.vertical, 10)
                        }

                        receiptRule
                        let backupDetail: String = {
                            guard lastBackupAt > 0 else { return "从未备份" }
                            let d = Date(timeIntervalSince1970: lastBackupAt)
                            let days = max(0, Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0)
                            let tag = days == 0 ? "今日已备份 · " : "\(days)天前 · "
                            return tag + DateText.full.string(from: d)
                        }()
                        receiptRowLabel(
                            "上次备份",
                            icon: "clock",
                            detail: backupDetail,
                            showChevron: false
                        )
                    }

                    receiptCard(
                        title: "快捷指令",
                        footer: "在「快捷指令」App 中搜索「简账」即可找到「识图记账」「记一笔」「本月收支」。"
                    ) {
                        NavigationLink {
                            ShortcutGuideView()
                        } label: {
                            receiptRowLabel("识图记账设置教程", icon: "text.viewfinder", detail: "", showChevron: true)
                        }
                        .buttonStyle(.plain)

                        receiptRule
                        ShortcutsLink()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                }

                let paperNote = skinRaw == AppSkin.receipt.rawValue
                    ? " 当前纸张：" + (ReceiptPaper(rawValue: receiptPaperRaw) ?? .cotton).detail + "。"
                    : ""
                receiptCard(
                    title: "外观",
                    footer: AppSkin.stored(skinRaw).detail + paperNote + " 皮肤与纸张为设备级设置，真实账本与防窥账本外观一致。"
                ) {
                    HStack(spacing: 10) {
                        Label("明暗与纸张", systemImage: "circle.lefthalf.filled")
                            .font(theme.serifTitleFont)
                            .foregroundStyle(theme.ink)
                        Spacer(minLength: 8)
                        HStack(spacing: 6) {
                            paperChip("棉白", paper: .cotton)
                            paperChip("暖黄", paper: .vintage)
                            paperChip("炭黑", paper: nil)
                        }
                    }
                    .padding(.vertical, 10)

                    receiptRule

                    Menu {
                        ForEach(AppSkin.allCases) { skin in
                            Button {
                                ReceiptHaptics.selection()
                                withAnimation(.snappy(duration: 0.28)) {
                                    skinRaw = skin.rawValue
                                }
                            } label: {
                                if skinRaw == skin.rawValue { Label(skin.label, systemImage: "checkmark") }
                                else { Text(skin.label) }
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Label("皮肤", systemImage: "paintpalette.fill")
                                .font(theme.serifTitleFont)
                                .foregroundStyle(theme.ink)
                            Spacer(minLength: 8)
                            VermilionStamp(text: "✓ \(AppSkin.stored(skinRaw).label)")
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-skin")

                    if skinRaw == AppSkin.receipt.rawValue {
                        receiptRule
                        HStack(spacing: 10) {
                            Label("悬浮记账", systemImage: "plus.viewfinder")
                                .font(theme.serifTitleFont)
                                .foregroundStyle(theme.ink)
                            Spacer(minLength: 8)
                            HStack(spacing: 6) {
                                fabChip("印章 A", style: .seal)
                                fabChip("胶囊 B", style: .capsule)
                                fabChip("拉环 C", style: .pulltab)
                            }
                        }
                        .padding(.vertical, 10)
                        .accessibilityIdentifier("settings-receipt-fab")
                    }
                }

                // 实时小票预览（独立展示在纸面外，保留完整机械出纸口与三层纸张投影）
                SkinLivePreview(skin: AppSkin.stored(skinRaw))
                    .padding(.vertical, 4)
                    .animation(.easeInOut(duration: 0.2), value: skinRaw)
                    .animation(.easeInOut(duration: 0.2), value: receiptPaperRaw)

                receiptSecurityCard

                if !session.isDecoy {
                    receiptBookkeepingCard
                    receiptSmartCard
                    receiptDataCard
                } else {
                    receiptCard(title: "数据", footer: "所有记账仅保存在这台设备上。") {
                        receiptRowLabel("账本保存在本机", icon: "internaldrive.fill", detail: "仅本机", showChevron: false)
                    }
                }

                receiptCard(title: "关于", footer: nil) {
                    HStack {
                        Text("版本")
                            .font(theme.serifTitleFont)
                            .foregroundStyle(theme.ink)
                        Spacer()
                        Text(appVersion)
                            .font(theme.metaFont)
                            .foregroundStyle(theme.faint)
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("about-version-row")

                    receiptRule
                    Label("数据本地存储 · 识别在本机完成 · 无网络请求", systemImage: "checkmark.shield.fill")
                        .font(theme.serifLabelFont)
                        .foregroundStyle(theme.faint)
                        .padding(.vertical, 10)
                }

                Color.clear.frame(height: 28)
            }
            .padding(.horizontal, ReceiptStyle.pageHorizontalMargin)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
    }

    private var receiptSecurityCard: some View {
        receiptCard(
            title: "安全与隐私",
            footer: session.isDecoy
                ? "密码以加盐哈希保存在本机钥匙串。"
                : "密码以加盐哈希保存在本机钥匙串。面容 ID / 触控 ID 始终进入真实账本；只有输入防窥密码才会进入防窥账本。"
        ) {
            Toggle(isOn: $passcodeToggle) {
                Label("密码锁", systemImage: "lock.fill")
                    .font(theme.serifTitleFont)
                    .foregroundStyle(theme.ink)
            }
            .tint(theme.accent)
            .padding(.vertical, 8)

            if lock.passcodeEnabled {
                receiptRule
                Button {
                    if session.isDecoy {
                        decoyMessage = "暂时无法修改密码，请稍后再试。"
                    } else {
                        passcodeFlow = .change
                    }
                } label: {
                    receiptRowLabel("修改密码", icon: "key.fill", detail: "", showChevron: true)
                }
                .buttonStyle(.plain)

                if lock.canUseBiometrics && !session.isDecoy {
                    receiptRule
                    Toggle(isOn: $biometricToggle) {
                        Label("允许\(lock.biometryName)", systemImage: lock.biometryIcon)
                            .font(theme.serifTitleFont)
                            .foregroundStyle(theme.ink)
                    }
                    .tint(theme.accent)
                    .padding(.vertical, 8)

                    if lock.biometricsEnabled {
                        receiptRule
                        Menu {
                            Button("密码") { lock.unlockMethod = .passcode }
                            Button("自动\(lock.biometryName)") { lock.unlockMethod = .autoBiometric }
                        } label: {
                            receiptRowLabel(
                                "解锁方式",
                                icon: "lock.open.fill",
                                detail: lock.unlockMethod == .autoBiometric ? "自动\(lock.biometryName)" : "密码",
                                showChevron: true
                            )
                        }
                        .buttonStyle(.plain)

                        if lock.unlockMethod == .passcode {
                            receiptRule
                            Toggle(isOn: $lock.showBiometricButton) {
                                Label("锁屏显示\(lock.biometryName)按钮", systemImage: "hand.tap")
                                    .font(theme.serifTitleFont)
                                    .foregroundStyle(theme.ink)
                            }
                            .tint(theme.accent)
                            .padding(.vertical, 8)
                        }
                    }
                }

                receiptRule
                Menu {
                    ForEach(AppLockManager.graceOptions, id: \.self) { seconds in
                        Button(AppLockManager.graceTitle(seconds)) { lock.gracePeriod = seconds }
                    }
                } label: {
                    receiptRowLabel(
                        "离开后多久需要解锁",
                        icon: "timer",
                        detail: AppLockManager.graceTitle(lock.gracePeriod),
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)

                receiptRule
                Button {
                    lock.lockNow()
                } label: {
                    receiptRowLabel("立即锁定", icon: "lock.rotation", detail: "", showChevron: false)
                }
                .buttonStyle(.plain)
            }

            receiptRule
            Toggle(isOn: $hideInAppSwitcher) {
                Label("多任务界面隐藏内容", systemImage: "eye.slash.fill")
                    .font(theme.serifTitleFont)
                    .foregroundStyle(theme.ink)
            }
            .tint(theme.accent)
            .padding(.vertical, 8)

            if lock.passcodeEnabled && !session.isDecoy {
                receiptRule
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
                        .font(theme.serifTitleFont)
                        .foregroundStyle(theme.ink)
                }
                .tint(theme.accent)
                .padding(.vertical, 8)

                if decoyEnabled {
                    receiptRule
                    Button { showDecoyEditor = true } label: {
                        receiptRowLabel("编辑防窥数据", icon: "pencil.and.outline", detail: "", showChevron: true)
                    }
                    .buttonStyle(.plain)

                    receiptRule
                    Button(role: .destructive) { showDecoyResetConfirm = true } label: {
                        HStack {
                            Label("重置为预设数据", systemImage: "arrow.counterclockwise")
                                .font(theme.serifTitleFont)
                                .foregroundStyle(theme.accent)
                            Spacer()
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var receiptBookkeepingCard: some View {
        receiptCard(
            title: "记账",
            footer: "默认关闭：刷卡消费已记为支出，还款只是把钱从银行卡转到信用卡，再计入会重复。"
        ) {
            NavigationLink {
                CategoryManagerView()
            } label: {
                receiptRowLabel("分类管理", icon: "square.grid.2x2.fill", detail: "", showChevron: true)
            }
            .buttonStyle(.plain)

            receiptRule
            NavigationLink {
                BudgetView()
            } label: {
                receiptRowLabel("预算", icon: "target", detail: budget > 0 ? "每月 \(Money.format(budget))" : "未设置", showChevron: true)
            }
            .buttonStyle(.plain)

            receiptRule
            Menu {
                Button("不设置") { defaultAccount = "" }
                ForEach(accounts.filter { !$0.isArchived }) { a in
                    Button(a.name) { defaultAccount = a.name }
                }
            } label: {
                receiptRowLabel("默认账户", icon: "creditcard.fill", detail: defaultAccount.isEmpty ? "不设置" : defaultAccount, showChevron: true)
            }
            .buttonStyle(.plain)

            receiptRule
            Menu {
                Button("人民币 ¥") { currencySymbol = "¥" }
                Button("美元 $") { currencySymbol = "$" }
                Button("欧元 €") { currencySymbol = "€" }
                Button("港币 HK$") { currencySymbol = "HK$" }
                Button("日元 JP¥") { currencySymbol = "JP¥" }
            } label: {
                receiptRowLabel("货币符号", icon: "dollarsign.circle.fill", detail: currencySymbol, showChevron: true)
            }
            .buttonStyle(.plain)

            receiptRule
            Toggle(isOn: $repaymentAsExpense) {
                Label("信用卡还款计入支出", systemImage: LedgerRecord.repaymentIcon)
                    .font(theme.serifTitleFont)
                    .foregroundStyle(theme.ink)
            }
            .tint(theme.accent)
            .padding(.vertical, 8)
            .accessibilityIdentifier("toggle-repayment-expense")
        }
    }

    private var receiptSmartCard: some View {
        receiptCard(
            title: "智能记账",
            footer: "识图记账：文字识别始终在本机用 Vision；不可用或出错时自动改用规则。全程不联网。"
        ) {
            NavigationLink {
                RulesView()
            } label: {
                receiptRowLabel("记账规则", icon: "wand.and.stars", detail: rules.isEmpty ? "" : "\(rules.count) 条", showChevron: true)
            }
            .buttonStyle(.plain)

            receiptRule
            Menu {
                Button("自动（优先 Apple 智能）") { ocrEngine = OCREngineSetting.auto }
                Button("仅规则") { ocrEngine = OCREngineSetting.rulesOnly }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("识别引擎", systemImage: "text.viewfinder")
                            .font(theme.serifTitleFont)
                            .foregroundStyle(theme.ink)
                        Text(ocrEngine == OCREngineSetting.rulesOnly ? "仅用本地规则 · \(aiStatus.title)" : aiStatus.title)
                            .font(theme.serifLabelFont)
                            .foregroundStyle(aiStatus.isAvailable && ocrEngine != OCREngineSetting.rulesOnly ? theme.income : theme.faint)
                            .accessibilityIdentifier("ai-status")
                    }
                    Spacer()
                    Text(ocrEngine == OCREngineSetting.rulesOnly ? "仅规则" : "自动")
                        .font(theme.serifLabelFont)
                        .foregroundStyle(theme.faint)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.faint)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ocr-engine-picker")
            .onAppear { aiStatus = AppleIntelligenceStatus.current }

            if ocrEngine != OCREngineSetting.rulesOnly {
                receiptRule
                Toggle(isOn: $aiInShortcuts) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("快捷指令中使用 Apple 智能", systemImage: "square.2.layers.3d")
                            .font(theme.serifTitleFont)
                            .foregroundStyle(theme.ink)
                        Text("默认关闭：开启后最多等 \(Int(OCREngineSetting.shortcutTimeout)) 秒，出错自动改用规则。")
                            .font(theme.serifLabelFont)
                            .foregroundStyle(theme.faint)
                    }
                }
                .tint(theme.accent)
                .padding(.vertical, 8)
                .accessibilityIdentifier("toggle-ai-shortcuts")
            }

            receiptRule
            NavigationLink {
                OCRDiagnosticsView()
            } label: {
                receiptRowLabel("识别诊断", icon: "stethoscope", detail: "", showChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-ocr-diagnostics")

            if !session.isDecoy {
                receiptRule
                NavigationLink {
                    RunLogView()
                } label: {
                    receiptRowLabel("运行日志", icon: "list.bullet.rectangle", detail: "", showChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-run-log")
            }

            receiptRule
            Button {
                BillImportCenter.shared.openPicker()
            } label: {
                receiptRowLabel("导入支付宝 / 微信账单", icon: "square.and.arrow.down.on.square", detail: "", showChevron: true)
            }
            .buttonStyle(.plain)

            receiptRule
            NavigationLink {
                ImportBatchesView()
            } label: {
                receiptRowLabel("导入记录", icon: "clock.arrow.circlepath", detail: batches.isEmpty ? "" : "\(batches.count) 次", showChevron: true)
            }
            .buttonStyle(.plain)

            receiptRule
            NavigationLink {
                RecurringListView()
            } label: {
                receiptRowLabel("周期账单", icon: "arrow.triangle.2.circlepath", detail: recurringRules.isEmpty ? "" : "\(recurringRules.count) 项", showChevron: true)
            }
            .buttonStyle(.plain)
        }
    }

    private var receiptDataCard: some View {
        receiptCard(
            title: "数据",
            footer: "共 \(records.count) 笔记录。所有数据仅保存在本机，不会上传到任何服务器。"
        ) {
            HStack(spacing: 0) {
                ledgerOverviewStat("总记录", "\(records.count) 笔")
                    .contentTransition(.numericText())
                Rectangle().fill(theme.rule).frame(width: 1, height: 26)
                ledgerOverviewStat("活跃账户", "\(accounts.filter { !$0.isArchived }.count) 个")
                    .contentTransition(.numericText())
                Rectangle().fill(theme.rule).frame(width: 1, height: 26)
                ledgerOverviewStat("记忆规则", "\(rules.count) 条")
                    .contentTransition(.numericText())
                Rectangle().fill(theme.rule).frame(width: 1, height: 26)
                ledgerOverviewStat("周期账单", "\(recurringRules.filter { !$0.isPaused }.count) 项")
                    .contentTransition(.numericText())
            }
            .padding(.vertical, 10)
            .accessibilityIdentifier("settings-ledger-overview")

            receiptRule
            NavigationLink {
                ChangeLogView()
            } label: {
                receiptRowLabel("变动日志", icon: "clock.badge.checkmark", detail: "", showChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-changelog")

            receiptRule
            NavigationLink {
                DedupeView()
            } label: {
                receiptRowLabel("一键去重", icon: "square.on.square.dashed", detail: "", showChevron: true)
            }
            .buttonStyle(.plain)
            .disabled(records.isEmpty)
            .accessibilityIdentifier("settings-dedupe")

            receiptRule
            Button {
                showCSVWarning = true
            } label: {
                receiptRowLabel("导出 CSV", icon: "square.and.arrow.up", detail: "", showChevron: false)
            }
            .buttonStyle(.plain)
            .disabled(records.isEmpty)
            .alert("导出明文 CSV？", isPresented: $showCSVWarning) {
                Button("继续导出") { exportCSV() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("CSV 文件没有加密，任何拿到文件的人都能看到全部 \(records.count) 笔记录、金额和备注。")
            }
            .sheet(item: $csvShare) { item in
                ActivityView(items: [item.url])
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }

            receiptRule
            Button(role: .destructive) {
                showDeleteAll = true
            } label: {
                HStack {
                    Label("删除全部记录", systemImage: "trash")
                        .font(theme.serifTitleFont)
                        .foregroundStyle(theme.accent)
                    Spacer()
                }
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .disabled(records.isEmpty)
            .confirmationDialog("删除全部记录？", isPresented: $showDeleteAll, titleVisibility: .visible) {
                Button("删除全部 \(records.count) 笔记录", role: .destructive) { deleteAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作不可恢复，建议先导出 CSV 或 JSON 备份。分类和账户会保留。")
            }
        }
    }

    private func ledgerOverviewStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(theme.metaFont.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(theme.ink)
            Text(label)
                .font(theme.labelFont)
                .foregroundStyle(theme.faint)
        }
        .frame(maxWidth: .infinity)
    }

    private func receiptCard<Content: View>(title: String, footer: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ReceiptLabelText(text: title, color: theme.faint)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .receiptSurface(theme, hero: false)
            if let footer {
                Text(footer)
                    .font(theme.serifLabelFont)
                    .foregroundStyle(theme.faint)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func receiptRowLabel(_ title: String, icon: String, detail: String, showChevron: Bool) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: icon)
                .font(theme.serifTitleFont)
                .foregroundStyle(theme.ink)
            Spacer(minLength: 8)
            if !detail.isEmpty {
                Text(detail)
                    .font(theme.serifLabelFont)
                    .foregroundStyle(theme.faint)
            }
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.faint)
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var receiptRule: some View {
        Rectangle()
            .fill(theme.rule.opacity(0.65))
            .frame(height: 0.8)
    }

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
                if lock.canUseBiometrics && !session.isDecoy {
                    Toggle(isOn: $biometricToggle) {
                        Label("允许\(lock.biometryName)", systemImage: lock.biometryIcon)
                    }
                    if lock.biometricsEnabled {
                        Picker(selection: $lock.unlockMethod) {
                            Text("密码").tag(AppLockManager.UnlockMethod.passcode)
                            Text("自动\(lock.biometryName)").tag(AppLockManager.UnlockMethod.autoBiometric)
                        } label: {
                            Label("解锁方式", systemImage: "lock.open.fill")
                        }
                        if lock.unlockMethod == .passcode {
                            Toggle(isOn: $lock.showBiometricButton) {
                                Label("锁屏显示\(lock.biometryName)按钮", systemImage: "hand.tap")
                            }
                        }
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
        } header: { ThemedSectionHeader {
            Text("安全与隐私")
        } } footer: { ThemedSectionFooter {
            if session.isDecoy {
                Text("密码以加盐哈希保存在本机钥匙串。")
            } else {
                Text("密码以加盐哈希保存在本机钥匙串。解锁方式默认「密码」：锁屏不会自动识别面容；选「自动面容 ID」才会在打开时自动识别。面容 ID / 触控 ID 始终进入真实账本；只有输入防窥密码才会进入防窥账本。防窥账本使用独立数据库与独立偏好（预算、默认账户、分类记忆等），不会同步到 iCloud，也不会写入真实备份。进入防窥时会撤掉真实账本的本地通知。快捷指令记账始终写入真实账本。")
            }
        } }
    }

    private var bookkeepingSection: some View {
        Section {
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
                        .font(.ui(.subheadline))
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
            Toggle(isOn: $repaymentAsExpense) {
                Label("信用卡还款计入支出", systemImage: LedgerRecord.repaymentIcon)
            }
            .accessibilityIdentifier("toggle-repayment-expense")
        } header: { ThemedSectionHeader {
            Text("记账")
        } } footer: { ThemedSectionFooter {
            Text("默认关闭：刷卡消费已记为支出，还款只是把钱从银行卡转到信用卡，再计入会重复。开启后首页、统计和总预算都会把还款算作支出。")
        } }
    }

    private var smartSection: some View {
        Section {
            NavigationLink {
                RulesView()
            } label: {
                settingRow("记账规则", icon: "wand.and.stars", detail: rules.isEmpty ? "" : "\(rules.count) 条")
            }
            Picker(selection: $ocrEngine) {
                Text("自动（优先 Apple 智能）").tag(OCREngineSetting.auto)
                Text("仅规则").tag(OCREngineSetting.rulesOnly)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("识别引擎", systemImage: "text.viewfinder")
                    Text(ocrEngine == OCREngineSetting.rulesOnly ? "仅用本地规则 · \(aiStatus.title)" : aiStatus.title)
                        .font(.ui(.caption))
                        .foregroundStyle(aiStatus.isAvailable && ocrEngine != OCREngineSetting.rulesOnly ? Color.themeIncome : Color.secondary)
                        .accessibilityIdentifier("ai-status")
                }
            }
            .accessibilityIdentifier("ocr-engine-picker")
            .onAppear { aiStatus = AppleIntelligenceStatus.current }
            if ocrEngine != OCREngineSetting.rulesOnly {
                Toggle(isOn: $aiInShortcuts) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("快捷指令中使用 Apple 智能", systemImage: "square.2.layers.3d")
                        Text("默认关闭：背面轻点等快捷指令在后台运行，系统会限制模型调用和运行时长。开启后最多等 \(Int(OCREngineSetting.shortcutTimeout)) 秒（按识图已用时间调整），出错会用更短的提示词重试一次，仍不行自动改用规则。")
                            .font(.ui(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("toggle-ai-shortcuts")
            }
            NavigationLink {
                OCRDiagnosticsView()
            } label: {
                Label("识别诊断", systemImage: "stethoscope")
            }
            .accessibilityIdentifier("settings-ocr-diagnostics")
            if !session.isDecoy {
                NavigationLink {
                    RunLogView()
                } label: {
                    Label("运行日志", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("settings-run-log")
            }
            Button {
                BillImportCenter.shared.openPicker()
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
        } header: { ThemedSectionHeader {
            Text("智能记账")
        } } footer: { ThemedSectionFooter {
            Text("识图记账：文字识别始终在本机用 Vision；「自动」时，在支持 Apple 智能的设备（iOS 26+）上再用端侧模型理解交易，结果会与原文核对（金额必须出现在截图中），不可用或出错时自动改用规则。全程不联网。\n\n支付宝：我的 › 账单 › 右上角 ··· › 开具交易流水证明 › 用于个人对账；微信：我 › 服务 › 钱包 › 账单 › 常见问题 › 下载账单 › 用于个人对账。收到的 CSV / XLSX 文件（解压后）用「存储到文件」保存，再在这里导入。")
        } }
    }

    private func settingRow(_ title: String, icon: String, detail: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if !detail.isEmpty {
                Text(detail).font(.ui(.subheadline)).foregroundStyle(.secondary)
            }
        }
    }

    /// 防窥模式下的「数据」：措辞普通，绝不提防窥，且不会碰到真实备份
    private var decoyDataSection: some View {
        Section {
            Label("账本保存在本机", systemImage: "internaldrive.fill")
            Text("当前不会使用 iCloud 同步或自动备份。")
                .font(.ui(.subheadline))
                .foregroundStyle(.secondary)
        } header: { ThemedSectionHeader {
            Text("数据")
        } } footer: { ThemedSectionFooter {
            Text("所有记账仅保存在这台设备上。")
        } }
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
                        .font(.ui(.subheadline))
                        .foregroundStyle(.secondary)
                }
            }
            if backupNeedsPassword {
                Label("自动备份已暂停：需要设置备份密码", systemImage: "exclamationmark.triangle.fill")
                    .font(.ui(.subheadline))
                    .foregroundStyle(.orange)
            }
            HStack {
                Label("上次备份", systemImage: "clock")
                Spacer()
                Text(lastBackupAt > 0 ? DateText.full.string(from: Date(timeIntervalSince1970: lastBackupAt)) : "从未")
                    .font(.ui(.subheadline))
                    .foregroundStyle(.secondary)
            }
        } header: { ThemedSectionHeader {
            Text("iCloud 与备份")
        } } footer: { ThemedSectionFooter {
            Text("可导出备份到 iCloud 云盘并随时恢复；iCloud 自动同步需要付费开发者账号签名。")
        } }
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
        } header: { ThemedSectionHeader {
            Text("快捷指令")
        } } footer: { ThemedSectionFooter {
            Text("在「快捷指令」App 中搜索「简账」即可找到「识图记账」「记一笔」「本月收支」。")
        } }
    }

    private var appearanceSection: some View {
        Section {
            if theme.isReceipt {
                // 设计稿：明暗与纸张合成一行三枚纸质芯片（棉白 / 暖黄 / 炭黑）
                HStack(spacing: 10) {
                    Label("明暗与纸张", systemImage: "circle.lefthalf.filled")
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        paperChip("棉白", paper: .cotton)
                        paperChip("暖黄", paper: .vintage)
                        paperChip("炭黑", paper: nil)
                    }
                }
                // 设计稿：皮肤当前值是一枚朱砂印章，点开仍可切回默认皮肤
                Menu {
                    ForEach(AppSkin.allCases) { skin in
                        Button {
                            skinRaw = skin.rawValue
                        } label: {
                            if skinRaw == skin.rawValue { Label(skin.label, systemImage: "checkmark") }
                            else { Text(skin.label) }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Label("皮肤", systemImage: "paintpalette.fill")
                        Spacer(minLength: 8)
                        VermilionStamp(text: "✓ \(AppSkin.stored(skinRaw).label)")
                    }
                }
                .accessibilityIdentifier("settings-skin")
            } else {
                Picker(selection: $appearance) {
                    Text("跟随系统").tag(0)
                    Text("浅色").tag(1)
                    Text("深色").tag(2)
                } label: {
                    Label("明暗", systemImage: "circle.lefthalf.filled")
                }
                Picker(selection: $skinRaw) {
                    ForEach(AppSkin.allCases) { skin in
                        Text(skin.label).tag(skin.rawValue)
                    }
                } label: {
                    Label("皮肤", systemImage: "paintpalette.fill")
                }
                .accessibilityIdentifier("settings-skin")
            }
            if skinRaw == AppSkin.receipt.rawValue {
                if theme.isReceipt {
                    HStack(spacing: 10) {
                        Label("悬浮记账", systemImage: "plus.viewfinder")
                        Spacer(minLength: 8)
                        HStack(spacing: 6) {
                            fabChip("印章 A", style: .seal)
                            fabChip("胶囊 B", style: .capsule)
                            fabChip("拉环 C", style: .pulltab)
                        }
                    }
                    .accessibilityIdentifier("settings-receipt-fab")
                } else {
                    Picker(selection: $receiptFabRaw) {
                        ForEach(ReceiptFabStyle.allCases) { f in
                            Text(f.label).tag(f.rawValue)
                        }
                    } label: {
                        Label("悬浮记账", systemImage: "plus.viewfinder")
                    }
                    .accessibilityIdentifier("settings-receipt-fab")
                }
            }
            SkinLivePreview(skin: AppSkin.stored(skinRaw))
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .listRowBackground(Color.clear)
                .animation(.easeInOut(duration: 0.2), value: skinRaw)
                .animation(.easeInOut(duration: 0.2), value: receiptPaperRaw)
        } header: { ThemedSectionHeader {
            Text("外观")
        } } footer: { ThemedSectionFooter {
            let paperNote = skinRaw == AppSkin.receipt.rawValue
                ? " 当前纸张：" + (ReceiptPaper(rawValue: receiptPaperRaw) ?? .cotton).detail + "。"
                : ""
            Text(AppSkin.stored(skinRaw).detail + paperNote + " 皮肤与纸张为设备级设置，真实账本与防窥账本外观一致。")
        } }
    }

    /// 设计稿纸质芯片：棉白 / 暖黄（浅色纸张）与炭黑（深色），选中项纸面高亮 + 朱砂字
    private func paperChip(_ title: String, paper: ReceiptPaper?) -> some View {
        let selected: Bool = {
            if let paper { return appearance != 2 && (ReceiptPaper(rawValue: receiptPaperRaw) ?? .cotton) == paper }
            return appearance == 2
        }()
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if let paper {
                    appearance = 1
                    receiptPaperRaw = paper.rawValue
                } else {
                    appearance = 2
                }
            }
        } label: {
            Text(title)
                .font(theme.isReceipt ? theme.serifLabelFont : .ui(.caption))
                .foregroundStyle(selected ? theme.accent : theme.faint)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(selected ? theme.rule.opacity(0.18) : theme.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(selected ? theme.accent.opacity(0.45) : theme.rule, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("settings-paper-\(title)")
    }

    private func fabChip(_ title: String, style: ReceiptFabStyle) -> some View {
        let selected = (ReceiptFabStyle(rawValue: receiptFabRaw) ?? .seal) == style
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                receiptFabRaw = style.rawValue
            }
        } label: {
            Text(title)
                .font(theme.serifLabelFont)
                .foregroundStyle(selected ? theme.accent : theme.faint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(selected ? theme.rule.opacity(0.18) : theme.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(selected ? theme.accent.opacity(0.45) : theme.rule, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("settings-fab-\(style.rawValue)")
    }

    private var dataSection: some View {
        Section {
            // 仅真实模式（dataSection 在防窥会话中不显示；编辑防窥数据里也没有设置页）
            NavigationLink {
                ChangeLogView()
            } label: {
                Label("变动日志", systemImage: "clock.badge.checkmark")
            }
            .accessibilityIdentifier("settings-changelog")
            NavigationLink {
                DedupeView()
            } label: {
                Label("一键去重", systemImage: "square.on.square.dashed")
            }
            .disabled(records.isEmpty)
            .accessibilityIdentifier("settings-dedupe")
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
        } header: { ThemedSectionHeader {
            Text("数据")
        } } footer: { ThemedSectionFooter {
            Text("共 \(records.count) 笔记录。所有数据仅保存在本机，不会上传到任何服务器。")
        } }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("版本")
                Spacer()
                Text(appVersion).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("about-version-row")
            Label("数据本地存储 · 识别在本机完成 · 无网络请求", systemImage: "checkmark.shield.fill")
                .font(.ui(.footnote))
                .foregroundStyle(.secondary)
        } header: { ThemedSectionHeader { Text("关于") } }
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
        let commit = Bundle.main.object(forInfoDictionaryKey: "JZBuildCommit") as? String ?? ""
        return "\(v) (\(b))" + (commit.isEmpty || commit == "dev" ? "" : " · \(commit)")
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
                lock.showBiometricButton = true
            } else {
                biometricToggle = false
                biometricError = "\(lock.biometryName)验证未通过。"
            }
        }
    }

    @MainActor
    private func deleteAll() {
        ChangeLogger.with(.app, title: "删除全部记录") {
            for r in records { context.delete(r) }
            for b in batches { context.delete(b) }
            try? context.save()
        }
        DedupeUndoStore.clear()
    }
}
