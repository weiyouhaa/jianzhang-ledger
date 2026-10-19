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
        epoch += 1
    }

    func enterDecoy() {
        if decoyContainer == nil {
            decoyContainer = DataStore.makeDecoyContainer(inMemory: ScreenshotDemo.isActive)
        }
        // 进入防窥后清掉「跳到 App 修改」的待办，避免真实记录编辑页漏出来
        PendingAppEdit.clear()
        guard mode != .decoy else { return }
        mode = .decoy
        epoch += 1
    }

    func forceDecoyForDemo() {
        decoyContainer = DataStore.makeDecoyContainer(inMemory: true)
        mode = .decoy
        epoch += 1
    }

    /// 重置防窥库为预设数据（真实模式下调用）
    func resetDecoyStore() {
        decoyContainer = nil
        DataStore.deleteDecoyStoreFiles()
        decoyContainer = DataStore.makeDecoyContainer(inMemory: false)
        if mode == .decoy { epoch += 1 }
    }
}

/// 快捷指令审核后「到 App 里改」的待办。只在真实模式解锁后消费。
enum PendingAppEdit {
    private static let key = "pending.appEdit.v1"

    struct Payload: Codable, Equatable {
        var recordID: String?
        var isNew: Bool
        var focus: String?
    }

    static func save(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> Payload? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
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
