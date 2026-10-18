import Foundation
import SwiftData

/// 全局共享的 SwiftData 容器。App 界面与 App Intents（在 App 进程内运行）共用同一个容器 / 同一个存储文件。
enum DataStore {
    static let shared: ModelContainer = {
        let schema = Schema([LedgerRecord.self, LedgerCategory.self])
        let config = ModelConfiguration("Ledger", schema: schema, isStoredInMemoryOnly: ScreenshotDemo.isActive, allowsSave: true)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            seedIfNeeded(container: container)
            ScreenshotDemo.seed(container: container)   // 仅截图模式下生效
            return container
        } catch {
            fatalError("无法创建数据存储：\(error)")
        }
    }()

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
