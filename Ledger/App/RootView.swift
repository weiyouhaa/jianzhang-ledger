import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.appearance) private var appearance = 0
    @AppStorage(SettingsKey.hideInAppSwitcher) private var hideInAppSwitcher = true
    @State private var lockWindowShown = false

    var body: some View {
        ZStack {
            MainTabView()

            // 兜底：如果无法创建独立锁屏窗口，则在视图层级内显示锁屏
            if lock.isLocked && !lockWindowShown {
                LockScreenView()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .preferredColorScheme(colorScheme)
        .onAppear { syncLockWindow(lock.isLocked) }
        .task {
            // 刷新 iCloud 容器可用性（供下次启动决定是否启用 CloudKit），并按需自动备份
            await CloudSync.refreshAvailability()
            if DataStore.syncStatus.isCloud { DataStore.dedupeCategories(in: DataStore.shared.mainContext) }
            await AutoBackup.runIfDue(context: DataStore.shared.mainContext)
        }
        .onChange(of: lock.isLocked) { _, locked in
            syncLockWindow(locked)
        }
        .onChange(of: scenePhase) { _, phase in
            lock.handleScenePhase(phase)
            if phase == .active {
                Task { @MainActor in
                    if DataStore.syncStatus.isCloud { DataStore.dedupeCategories(in: DataStore.shared.mainContext) }
                    await AutoBackup.runIfDue(context: DataStore.shared.mainContext)
                }
            }
            if hideInAppSwitcher && phase != .active {
                OverlayWindowManager.shared.showPrivacy(style: interfaceStyle)
            } else {
                OverlayWindowManager.shared.hidePrivacy()
            }
        }
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

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("明细", systemImage: "list.bullet.rectangle.portrait") }
                .tag(0)
            StatsView()
                .tabItem { Label("统计", systemImage: "chart.pie.fill") }
                .tag(1)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(2)
        }
    }
}
