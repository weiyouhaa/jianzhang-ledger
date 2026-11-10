import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var lock: AppLockManager
    @EnvironmentObject private var session: SessionManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.appearance, store: .standard) private var appearance = 0
    @AppStorage(SettingsKey.skin, store: .standard) private var skinRaw = AppSkin.defaultSkinRaw
    @AppStorage(SettingsKey.receiptPaper, store: .standard) private var receiptPaperRaw = ReceiptPaper.cotton.rawValue
    @AppStorage(SettingsKey.receiptFab, store: .standard) private var receiptFabRaw = ReceiptFabStyle.seal.rawValue
    @AppStorage(SettingsKey.hideInAppSwitcher, store: .standard) private var hideInAppSwitcher = true
    @State private var lockWindowShown = false
    /// 3.2 (23) 当前已应用到 UIKit 外观（导航栏 / 标签栏）的皮肤；变化时整棵主界面重建一次
    @State private var chromeSkin = AppSkin.current.rawValue
    /// 提到这里：皮肤切换重建主界面后仍停留在原来的标签页
    @State private var tab = ScreenshotDemo.initialTab

    var body: some View {
        ZStack {
            MainTabView(tab: $tab)
                .modifier(RootThemeInjector(skinRaw: chromeSkin))
                .id("\(chromeSkin)-\(receiptPaperRaw)-\(receiptFabRaw)")

            if ScreenshotDemo.screen == "reviewsnippet" {
                ReviewSnippetDemoView().zIndex(3)
            }
            #if DEBUG
            if OCRMemoryProbe.enabled {
                OCRMemoryProbe()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .allowsHitTesting(false)
                    .zIndex(4)
            }
            if ChangeLogProbe.enabled {
                ChangeLogProbe()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
                    .zIndex(4)
            }
            #endif

            // 兜底：如果无法创建独立锁屏窗口，则在视图层级内显示锁屏
            if lock.isLocked && !lockWindowShown {
                LockScreenView()
                    .themedChrome()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .preferredColorScheme(colorScheme)
        .onOpenURL { url in
            // 其他 App「用其他应用打开 / 共享」过来的账单文件（CSV / XLSX / XLS），见 Info.plist CFBundleDocumentTypes
            if url.isFileURL {
                BillImportCenter.shared.receive(url: url, isLocked: lock.isLocked)
                return
            }
            guard url.scheme == "jianzhang" else { return }
            if !lock.isLocked { PendingAppEdit.consumeIfNeeded() }
        }
        .onChange(of: skinRaw) { _, newValue in
            // 先改 UIKit 外观，再重建界面（新建的导航栏 / 标签栏才会用新外观）
            ThemeChrome.apply(AppSkin.stored(newValue))
            chromeSkin = newValue
        }
        .onAppear {
            syncLockWindow(lock.isLocked)
            if ScreenshotDemo.screen == "decoysettings" {
                DecoyPasscodeStore.isEnabled = true
            }
        }
        .task {
            await CloudSync.refreshAvailability()
            if !SessionManager.shared.isDecoy {
                if DataStore.syncStatus.isCloud { DataStore.dedupeCategories(in: DataStore.shared.mainContext) }
                await AutoBackup.runIfDue(context: DataStore.shared.mainContext)
            }
            await Self.runSmartTasks()
            if !lock.isLocked { PendingAppEdit.consumeIfNeeded() }
            BillImportCenter.shared.consumePendingIfPossible(isLocked: lock.isLocked)
        }
        .onChange(of: lock.isLocked) { _, locked in
            syncLockWindow(locked)
            if !locked {
                // 等真实 / 防窥模式切换完成后再判断；防窥模式下排队的文件继续等待真实解锁
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    BillImportCenter.shared.consumePendingIfPossible(isLocked: lock.isLocked)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            lock.handleScenePhase(phase)
            // 快捷指令 continueInForeground 切到前台：未上锁时直接弹编辑页；上锁则等解锁（真实密码 / 面容）后再弹
            if phase == .active && !lock.isLocked {
                PendingAppEdit.consumeIfNeeded()
                BillImportCenter.shared.consumePendingIfPossible(isLocked: false)
            }
            if phase == .active {
                AppleIntelligenceExtractor.prewarm(vocabulary: IntentRecorder.ocrVocabulary())
                Task { @MainActor in
                    if !SessionManager.shared.isDecoy {
                        if DataStore.syncStatus.isCloud { DataStore.dedupeCategories(in: DataStore.shared.mainContext) }
                        await AutoBackup.runIfDue(context: DataStore.shared.mainContext)
                    }
                    await Self.runSmartTasks()
                }
            }
            if phase == .background, !SessionManager.shared.isDecoy {
                AutoBackup.runOnBackground(context: DataStore.shared.mainContext)
            }
            if hideInAppSwitcher && phase != .active {
                OverlayWindowManager.shared.showPrivacy(style: interfaceStyle)
            } else {
                OverlayWindowManager.shared.hidePrivacy()
            }
        }
    }

    /// 周期账单追补记账、预算检查、重排提醒
    @MainActor
    static func runSmartTasks() async {
        guard !ScreenshotDemo.isActive else { return }
        // 防窥模式：不跑真实周期账单 / 预算通知，避免真实数据渗入通知中心
        if SessionManager.shared.isDecoy { return }
        let context = DataStore.shared.mainContext
        RecurringEngine.run(in: context)
        BudgetMonitor.check(in: context)
        await NotificationManager.shared.rescheduleRecurring(in: context)
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    private var interfaceStyle: UIUserInterfaceStyle {
        switch appearance {
        case 1: return .light
        case 2: return .dark
        default: return .unspecified
        }
    }

    @MainActor
    private func syncLockWindow(_ locked: Bool) {
        if locked {
            lockWindowShown = OverlayWindowManager.shared.showLock(lock: lock, style: interfaceStyle)
        } else {
            OverlayWindowManager.shared.hideLock()
            lockWindowShown = false
        }
    }
}

struct MainTabView: View {
    @Binding var tab: Int
    @ObservedObject private var router = NotificationRouter.shared

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("明细", systemImage: "list.bullet.rectangle.portrait") }
                .tag(0)
            StatsView()
                .tabItem { Label("统计", systemImage: "chart.pie.fill") }
                .tag(1)
            AssetsView()
                .tabItem { Label("资产", systemImage: "wallet.pass.fill") }
                .tag(2)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .sheet(item: $router.prefill) { p in
            RecordEditorView(record: nil, prefill: p)
        }
        .sheet(isPresented: Binding(
            get: { router.editRecordID != nil },
            set: { if !$0 { router.editRecordID = nil } }
        )) {
            if let id = router.editRecordID.flatMap({ UUID(uuidString: $0) }),
               let record = DataStore.record(id: id, in: DataStore.activeContext) {
                RecordEditorView(record: record)
            } else {
                NavigationStack {
                    Text("找不到这条记录，可能已被删除。")
                        .padding()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { router.editRecordID = nil } } }
                }
            }
        }
        // 账单导入（文件选择器 / 预览 / 提示）的独立宿主
        .overlay { BillImportHost() }
        .onAppear { PendingAppEdit.consumeIfNeeded() }
    }
}

/// 在 preferredColorScheme 生效后，按当前 ColorScheme 注入 AppTheme，并统一 tint（标签栏 / 按钮强调色）。
private struct RootThemeInjector: ViewModifier {
    let skinRaw: String
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let theme = AppTheme.resolve(skin: AppSkin.stored(skinRaw), scheme: scheme)
        if theme.isReceipt {
            // 小票皮肤：默认文字颜色 / 字体也统一（.secondary 等层级色随之变成暖灰）
            content
                .environment(\.appTheme, theme)
                .tint(theme.accent)
                .foregroundStyle(theme.ink)
                .font(.ui(.body))
        } else {
            content
                .environment(\.appTheme, theme)
                .tint(theme.accent)
        }
    }
}
