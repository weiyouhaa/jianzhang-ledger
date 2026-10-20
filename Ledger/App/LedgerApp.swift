import SwiftUI
import SwiftData

@main
struct LedgerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var lock = AppLockManager()
    @ObservedObject private var session = SessionManager.shared

    init() {
        // 最早的时机：在任何数据库 / 设置读取之前打开运行日志并安装崩溃捕获
        RunLog.shared.bootstrap(reason: "进程启动")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(lock)
                .environmentObject(session)
                // 当前模式的偏好 store（切模式时 epoch 变化整树重建，重新注入）
                .ledgerPrefs(ModeDefaults.store)
                // 切换真实 / 防窥容器时整树重建，避免串库
                .id(session.epoch)
        }
        .modelContainer(session.container)
    }
}
