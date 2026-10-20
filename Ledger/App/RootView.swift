import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var lock: AppLockManager
    @EnvironmentObject private var session: SessionManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.appearance, store: .standard) private var appearance = 0
    @AppStorage(SettingsKey.hideInAppSwitcher, store: .standard) private var hideInAppSwitcher = true
    @State private var lockWindowShown = false

    var body: some View {
        ZStack {
            MainTabView()

            if ScreenshotDemo.screen == "reviewsnippet" {
                ReviewSnippetDemoView().zIndex(3)
            }
            #if DEBUG
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
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .preferredColorScheme(colorScheme)
        .onOpenURL { url in
            guard url.scheme == "jianzhang" else { return }
            if !lock.isLocked { PendingAppEdit.consumeIfNeeded() }
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
        }
        .onChange(of: lock.isLocked) { _, locked in
            syncLockWindow(locked)
        }
        .onChange(of: scenePhase) { _, phase in
            lock.handleScenePhase(phase)
            // 快捷指令 continueInForeground 切到前台：未上锁时直接弹编辑页；上锁则等解锁（真实密码 / 面容）后再弹
            if phase == .active && !lock.isLocked { PendingAppEdit.consumeIfNeeded() }
            if phase == .active {
                AppleIntelligenceExtractor.prewarm()
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
    @State private var tab = ScreenshotDemo.initialTab
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
        .onAppear { PendingAppEdit.consumeIfNeeded() }
    }
}
