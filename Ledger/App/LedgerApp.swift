import SwiftUI
import SwiftData

@main
struct LedgerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var lock = AppLockManager()
    @ObservedObject private var session = SessionManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(lock)
                .environmentObject(session)
                // 切换真实 / 防窥容器时整树重建，避免串库
                .id(session.epoch)
        }
        .modelContainer(session.container)
    }
}
