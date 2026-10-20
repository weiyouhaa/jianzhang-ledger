import Foundation
import SwiftData
import SwiftUI
import Combine

/// 当前会话：真实账本 or 防窥账本。锁屏后再解锁时按输入的密码决定进入哪边。
enum SessionMode: String {
    case real
    case decoy
}

@MainActor
final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    @Published private(set) var mode: SessionMode = .real
    /// 切换容器时递增，用于 `.id` 强制重建界面
    @Published private(set) var epoch: Int = 0

    private var decoyContainer: ModelContainer?

    private init() {
        ModeDefaults.setDecoyMode(false)
        if ScreenshotDemo.screen == "decoyhome" || ScreenshotDemo.screen == "decoyassets" {
            // 截图模式：启动即进入防窥库，避免 RootView.onAppear 里改 epoch 把界面拆掉
            forceDecoyForDemo()
        }
    }

    var isDecoy: Bool { mode == .decoy }

    var container: ModelContainer {
        if mode == .decoy {
            if let decoyContainer { return decoyContainer }
            let c = DataStore.makeDecoyContainer(inMemory: false)
            decoyContainer = c
            return c
        }
        return DataStore.shared
    }

    func enterReal() {
        guard mode != .real else { return }
        mode = .real
        ModeDefaults.setDecoyMode(false)
        epoch += 1
        // 回到真实账本后，按真实库重排周期提醒
        Task { await NotificationManager.shared.rescheduleRecurring(in: DataStore.shared.mainContext) }
    }

    func enterDecoy() {
        if decoyContainer == nil {
            decoyContainer = DataStore.makeDecoyContainer(inMemory: ScreenshotDemo.isActive)
        }
        ModeDefaults.seedDecoyDefaultsIfNeeded()
        // 进入防窥后清掉「跳到 App 修改」的待办，避免真实记录编辑页漏出来
        PendingAppEdit.clear()
        // 撤掉真实账本的待发/已送达通知，避免锁屏通知栏泄露真实金额
        NotificationManager.shared.removeAllLedgerNotifications()
        guard mode != .decoy else {
            ModeDefaults.setDecoyMode(true)
            return
        }
        mode = .decoy
        ModeDefaults.setDecoyMode(true)
        epoch += 1
    }

    func forceDecoyForDemo() {
        // decoyassets 走真实文件库（与真机进入防窥一致），decoyhome 用内存库保证截图数据固定
        decoyContainer = DataStore.makeDecoyContainer(inMemory: ScreenshotDemo.screen != "decoyassets")
        ModeDefaults.seedDecoyDefaultsIfNeeded()
        mode = .decoy
        ModeDefaults.setDecoyMode(true)
        epoch += 1
    }

    /// 真实模式下「编辑防窥数据」/ 设置防窥密码时用：与防窥会话共用同一个容器实例
    func decoyContainerForEditing() -> ModelContainer {
        if let decoyContainer { return decoyContainer }
        let c = DataStore.makeDecoyContainer(inMemory: ScreenshotDemo.isActive)
        decoyContainer = c
        return c
    }

    /// 重置防窥库为预设数据（真实模式下调用）
    func resetDecoyStore() {
        decoyContainer = nil
        DataStore.deleteDecoyStoreFiles()
        ModeDefaults.resetDecoyPrefs()
        decoyContainer = DataStore.makeDecoyContainer(inMemory: false)
        if mode == .decoy { epoch += 1 }
    }
}

/// 快捷指令审核后「到 App 里改」的待办。只在真实模式解锁后消费。
enum PendingAppEdit {
    private static let key = "pending.appEdit.v1"

    /// 标记有效期：快捷指令没能把 App 切到前台时，用户 10 分钟内打开简账仍会弹出编辑页
    static let ttl: TimeInterval = 600

    struct Payload: Codable, Equatable {
        var recordID: String?
        var isNew: Bool
        var focus: String?
        var savedAt: Date? = nil
    }

    static func save(_ payload: Payload) {
        var p = payload
        p.savedAt = Date()
        guard let data = try? JSONEncoder().encode(p) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load(now: Date = Date()) -> Payload? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        if let t = p.savedAt, now.timeIntervalSince(t) > ttl {
            clear()
            return nil
        }
        return p
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    @MainActor
    static func consumeIfNeeded() {
        guard !SessionManager.shared.isDecoy, let payload = load() else { return }
        clear()
        if payload.isNew {
            NotificationRouter.shared.prefill = RecordPrefill(
                amount: 0, kind: .expense, categoryID: nil, accountID: nil, toAccountID: nil,
                note: "", merchant: "", date: Date(), recurringKey: ""
            )
        } else if let id = payload.recordID {
            NotificationRouter.shared.editRecordID = id
        }
    }
}
