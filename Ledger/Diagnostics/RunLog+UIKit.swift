import Foundation
import UIKit

/// 运行日志的 UIKit 部分：只在主线程读 UIApplication 状态，写进 RunLog 的缓存
extension RunLog {

    @MainActor
    func refreshAppState() {
        let app = UIApplication.shared
        let s: String
        switch app.applicationState {
        case .active: s = "前台"
        case .inactive: s = "非活跃"
        case .background: s = "后台"
        @unknown default: s = "?"
        }
        setAppState(s, protectedData: app.isProtectedDataAvailable ? "可用" : "不可用")
    }

    /// 前后台、受保护数据、内存警告：主线程通知（App 启动时安装一次）
    @MainActor
    func installObservers() {
        let nc = NotificationCenter.default
        refreshAppState()
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RunLog.shared.refreshAppState() }
            RunLog.shared.markDirty(step: "foreground")
            RunLog.shared.log(.info, "lifecycle", "进入前台")
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RunLog.shared.refreshAppState() }
            RunLog.shared.log(.info, "lifecycle", "进入后台")
            RunLog.shared.markClean(step: "background")
        }
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.willResignActiveNotification,
                     UIApplication.protectedDataDidBecomeAvailableNotification,
                     UIApplication.protectedDataWillBecomeUnavailableNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RunLog.shared.refreshAppState() }
            }
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            RunLog.shared.log(.warn, "memory-warning", "收到系统内存警告")
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
            RunLog.shared.log(.info, "thermal", "温度状态变化")
        }
    }


}
