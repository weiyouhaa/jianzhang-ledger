import Foundation
import SwiftData

/// 全局共享的 SwiftData 容器。App 界面与 App Intents（在 App 进程内运行）共用同一个容器 / 同一个存储文件。
enum DataStore {
    /// 启动时创建一次：容器 + 当前同步状态
    static let setup: (container: ModelContainer, status: SyncStatus) = makeContainer()
    static var shared: ModelContainer { setup.container }
    static var syncStatus: SyncStatus { setup.status }

    /// 存储文件名保持 "Ledger" 不变（Application Support/Ledger.store），本地 / iCloud 模式共用同一个文件，切换不丢数据
    private static func makeContainer() -> (container: ModelContainer, status: SyncStatus) {
        let schema = Schema([LedgerRecord.self, LedgerCategory.self])
        var status: SyncStatus = .local

        if !ScreenshotDemo.isActive && UserDefaults.standard.bool(forKey: SettingsKey.iCloudSyncEnabled) {
            if !CloudSync.hasAccount {
                status = .noAccount
            } else if !UserDefaults.standard.bool(forKey: SettingsKey.iCloudContainerOK) {
                status = .noEntitlement
            } else {
                let cloudConfig = ModelConfiguration("Ledger", schema: schema, isStoredInMemoryOnly: false, allowsSave: true,
                                                     cloudKitDatabase: .private(CloudSync.containerID))
                do {
                    let container = try ModelContainer(for: schema, configurations: [cloudConfig])
                    seedIfNeeded(container: container)
                    return (container, .cloud)
                } catch {
                    status = .failed(error.localizedDescription)
                }
            }
        }

        // 本地模式：显式关闭 CloudKit（即使重签后带有 iCloud 权限，也不会自动开启同步）
        let localConfig = ModelConfiguration("Ledger", schema: schema, isStoredInMemoryOnly: ScreenshotDemo.isActive,
                                             allowsSave: true, cloudKitDatabase: .none)
        do {
            let container = try ModelContainer(for: schema, configurations: [localConfig])
            seedIfNeeded(container: container)
            ScreenshotDemo.seed(container: container)   // 仅截图模式下生效
            return (container, status)
        } catch {
            fatalError("无法创建数据存储：\(error)")
        }
    }

    /// iCloud 同步时，多台设备各自生成的默认分类会重复：按「类型 + 名称」合并，记录归到最早创建的分类
    @MainActor
    static func dedupeCategories(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<LedgerCategory>(sortBy: [SortDescriptor(\LedgerCategory.createdAt)]))) ?? []
        var keep: [String: LedgerCategory] = [:]
        var changed = false
        for c in all {
            let key = c.kindRaw + "|" + c.name
            if let primary = keep[key] {
                for r in c.records ?? [] { r.category = primary }
                context.delete(c)
                changed = true
            } else {
                keep[key] = c
            }
        }
        if changed { try? context.save() }
    }

    /// 首次启动写入默认分类（使用独立的 ModelContext，不依赖主线程）
    static func seedIfNeeded(container: ModelContainer) {
        let context = ModelContext(container)
        let count = (try? context.fetchCount(FetchDescriptor<LedgerCategory>())) ?? 0
        guard count == 0 else { return }
        for (index, item) in DefaultCategory.all.enumerated() {
            context.insert(LedgerCategory(name: item.name, icon: item.icon, colorHex: item.color,
                                          kind: item.kind, sortOrder: index))
        }
        try? context.save()
    }

    /// 某类型下的全部分类（按排序）
    static func categories(kind: RecordKind, in context: ModelContext) -> [LedgerCategory] {
        let raw = kind.rawValue
        let descriptor = FetchDescriptor<LedgerCategory>(
            predicate: #Predicate<LedgerCategory> { $0.kindRaw == raw },
            sortBy: [SortDescriptor(\LedgerCategory.sortOrder)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 按名称匹配分类；找不到时回退到「其他 / 其他收入」，再回退到该类型下的最后一个分类
    static func category(named name: String?, kind: RecordKind, in context: ModelContext) -> LedgerCategory? {
        let list = categories(kind: kind, in: context)
        if let name, let hit = list.first(where: { $0.name == name }) { return hit }
        if let name, let hit = list.first(where: { $0.name.contains(name) || name.contains($0.name) }) { return hit }
        let fallbackName = kind == .expense ? "其他" : "其他收入"
        return list.first(where: { $0.name == fallbackName }) ?? list.last
    }

    static func category(id: UUID, in context: ModelContext) -> LedgerCategory? {
        let target = id
        var descriptor = FetchDescriptor<LedgerCategory>(predicate: #Predicate<LedgerCategory> { $0.id == target })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// 某时间区间内的记录
    static func records(from start: Date, to end: Date, in context: ModelContext) -> [LedgerRecord] {
        let s = start, e = end
        let descriptor = FetchDescriptor<LedgerRecord>(
            predicate: #Predicate<LedgerRecord> { $0.date >= s && $0.date < e },
            sortBy: [SortDescriptor(\LedgerRecord.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
