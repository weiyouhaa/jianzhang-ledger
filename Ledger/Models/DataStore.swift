import Foundation
import SwiftData

/// 全局共享的 SwiftData 容器。App 界面与 App Intents（在 App 进程内运行）共用同一个容器 / 同一个存储文件。
enum DataStore {
    /// 启动时创建一次：容器 + 当前同步状态
    static let setup: (container: ModelContainer, status: SyncStatus) = makeContainer()
    static var shared: ModelContainer { setup.container }
    static var syncStatus: SyncStatus { setup.status }

    /// 当前 UI 应使用的容器（防窥模式下为独立文件）
    @MainActor
    static var active: ModelContainer { SessionManager.shared.container }

    @MainActor
    static var activeContext: ModelContext { SessionManager.shared.container.mainContext }

    private static let decoyStoreName = "LedgerDecoy"

    /// 存储文件名保持 "Ledger" 不变（Application Support/Ledger.store），本地 / iCloud 模式共用同一个文件，切换不丢数据
    private static func makeContainer() -> (container: ModelContainer, status: SyncStatus) {
        let schema = Schema([LedgerRecord.self, LedgerCategory.self, LedgerAccount.self,
                             CategoryRule.self, ImportBatch.self, RecurringRule.self])
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
                    migrateAccountsIfNeeded(container: container)
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
            migrateAccountsIfNeeded(container: container)
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
        // 账户同理：按名称合并
        let accounts = (try? context.fetch(FetchDescriptor<LedgerAccount>(sortBy: [SortDescriptor(\LedgerAccount.createdAt)]))) ?? []
        var keepAccounts: [String: LedgerAccount] = [:]
        for a in accounts {
            if let primary = keepAccounts[a.name] {
                for r in a.records ?? [] { r.accountRef = primary }
                for r in a.incomingTransfers ?? [] { r.toAccount = primary }
                context.delete(a)
                changed = true
            } else {
                keepAccounts[a.name] = a
            }
        }
        if changed { try? context.save() }
    }

    // MARK: - 账户

    private static let accountMigrationKey = "migration.accounts.v1"

    /// 首次启动新版本时：为旧记录里出现过的每个账户文字创建账户并关联
    static func migrateAccountsIfNeeded(container: ModelContainer) {
        guard !UserDefaults.standard.bool(forKey: accountMigrationKey) else { return }
        let context = ModelContext(container)
        linkLegacyAccounts(in: context)
        UserDefaults.standard.set(true, forKey: accountMigrationKey)
    }

    /// 把 accountRef 为空、但旧文本字段有值的记录关联到同名账户（没有则创建）。导入旧版备份后也会调用。
    @discardableResult
    static func linkLegacyAccounts(in context: ModelContext) -> Int {
        let records = (try? context.fetch(FetchDescriptor<LedgerRecord>())) ?? []
        var accounts = (try? context.fetch(FetchDescriptor<LedgerAccount>())) ?? []
        var byName: [String: LedgerAccount] = [:]
        for a in accounts { byName[a.name] = a }
        var nextOrder = (accounts.map(\.sortOrder).max() ?? -1) + 1
        var linked = 0
        for r in records where r.accountRef == nil {
            let name = r.account.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let account: LedgerAccount
            if let existing = byName[name] {
                account = existing
            } else {
                account = LedgerAccount(name: name, type: AccountType.guess(from: name), sortOrder: nextOrder)
                nextOrder += 1
                context.insert(account)
                accounts.append(account)
                byName[name] = account
            }
            r.accountRef = account
            linked += 1
        }
        if linked > 0 { try? context.save() }
        return linked
    }

    static func accounts(in context: ModelContext, includeArchived: Bool = false) -> [LedgerAccount] {
        let all = (try? context.fetch(FetchDescriptor<LedgerAccount>(sortBy: [SortDescriptor(\LedgerAccount.sortOrder)]))) ?? []
        return includeArchived ? all : all.filter { !$0.isArchived }
    }

    static func account(idString: String, in context: ModelContext) -> LedgerAccount? {
        guard let id = UUID(uuidString: idString) else { return nil }
        return account(id: id, in: context)
    }

    static func category(idString: String, in context: ModelContext) -> LedgerCategory? {
        guard let id = UUID(uuidString: idString) else { return nil }
        return category(id: id, in: context)
    }

    static func account(id: UUID, in context: ModelContext) -> LedgerAccount? {
        let target = id
        var descriptor = FetchDescriptor<LedgerAccount>(predicate: #Predicate<LedgerAccount> { $0.id == target })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    static func account(named name: String, in context: ModelContext) -> LedgerAccount? {
        guard !name.isEmpty else { return nil }
        return accounts(in: context, includeArchived: true).first { $0.name == name }
    }

    /// 根据 OCR 得到的付款方式线索匹配已有账户
    static func account(matching hint: AccountHint?, in context: ModelContext) -> LedgerAccount? {
        guard let hint else { return nil }
        let list = accounts(in: context)
        var candidates = list
        if let typeRaw = hint.type, let type = AccountType(rawValue: typeRaw) {
            candidates = list.filter { $0.type == type }
        }
        if let tail = hint.cardTail,
           let hit = (candidates.isEmpty ? list : candidates).first(where: { $0.name.contains(tail) || $0.note.contains(tail) }) {
            return hit
        }
        if let bank = hint.bankName {
            let aliases = AccountHint.aliases(forBank: bank)
            if let hit = candidates.first(where: { a in aliases.contains(where: { a.name.contains($0) }) }) { return hit }
        }
        return hint.type == nil ? nil : candidates.first
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

    static func record(id: UUID, in context: ModelContext) -> LedgerRecord? {
        let target = id
        var d = FetchDescriptor<LedgerRecord>(predicate: #Predicate<LedgerRecord> { $0.id == target })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
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

    // MARK: - 防窥独立库（永不走 CloudKit）

    static func makeDecoyContainer(inMemory: Bool) -> ModelContainer {
        let schema = Schema([LedgerRecord.self, LedgerCategory.self, LedgerAccount.self,
                             CategoryRule.self, ImportBatch.self, RecurringRule.self])
        let config = ModelConfiguration(decoyStoreName, schema: schema, isStoredInMemoryOnly: inMemory,
                                        allowsSave: true, cloudKitDatabase: .none)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            DecoySeeder.seedIfNeeded(container: container)
            return container
        } catch {
            fatalError("无法创建防窥数据存储：\(error)")
        }
    }

    static func deleteDecoyStoreFiles() {
        let fm = FileManager.default
        guard let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        for name in [decoyStoreName + ".store", decoyStoreName + ".store-shm", decoyStoreName + ".store-wal"] {
            try? fm.removeItem(at: support.appendingPathComponent(name))
        }
        UserDefaults.standard.removeObject(forKey: DecoySeeder.seededKey)
    }
}
