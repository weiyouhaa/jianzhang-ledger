import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import CryptoKit

enum RestoreMode {
    case merge
    case replace
}

struct RestoreResult {
    var insertedRecords = 0
    var skippedRecords = 0
    var insertedCategories = 0
    var insertedAccounts = 0
    var insertedRules = 0
    var insertedRecurring = 0

    var summary: String {
        var s = "导入 \(insertedRecords) 笔记录"
        if skippedRecords > 0 { s += "，跳过 \(skippedRecords) 笔已存在的记录" }
        if insertedCategories > 0 { s += "，新增 \(insertedCategories) 个分类" }
        if insertedAccounts > 0 { s += "，新增 \(insertedAccounts) 个账户" }
        if insertedRules > 0 { s += "，\(insertedRules) 条记账规则" }
        if insertedRecurring > 0 { s += "，\(insertedRecurring) 个周期账单" }
        return s + "。"
    }
}

enum BackupService {
    static let filePrefix = "简账备份-"

    static func fileName(for date: Date = Date(), encrypted: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return filePrefix + f.string(from: date) + (encrypted ? "." + BackupCrypto.fileExtension : ".json")
    }

    /// 生成备份文件内容。password 非空时加密（PBKDF2 + AES-256-GCM），在后台线程完成，避免卡住界面
    @MainActor
    static func exportData(context: ModelContext, password: String?) async throws -> Data {
        let backup = makeBackup(context: context)
        let iterations = BackupCrypto.tunedIterations()
        return try await Task.detached(priority: .userInitiated) { () throws -> Data in
            let json = try BackupJSON.encode(backup)
            guard let password, !password.isEmpty else { return json }
            return try BackupCrypto.encrypt(json, password: password, iterations: iterations)
        }.value
    }

    // MARK: 导出

    @MainActor
    static func makeBackup(context: ModelContext) -> LedgerBackup {
        let categories = (try? context.fetch(FetchDescriptor<LedgerCategory>(sortBy: [SortDescriptor(\LedgerCategory.sortOrder)]))) ?? []
        let records = (try? context.fetch(FetchDescriptor<LedgerRecord>(sortBy: [SortDescriptor(\LedgerRecord.date)]))) ?? []
        let accounts = (try? context.fetch(FetchDescriptor<LedgerAccount>(sortBy: [SortDescriptor(\LedgerAccount.sortOrder)]))) ?? []
        let d = UserDefaults.standard
        let settings = LedgerBackup.SettingsDTO(
            monthlyBudget: d.double(forKey: SettingsKey.monthlyBudget),
            currencySymbol: d.string(forKey: SettingsKey.currencySymbol),
            appearance: d.integer(forKey: SettingsKey.appearance),
            defaultAccount: d.string(forKey: SettingsKey.defaultAccount),
            hideInAppSwitcher: d.object(forKey: SettingsKey.hideInAppSwitcher) as? Bool,
            yearlyBudget: d.double(forKey: BudgetKey.yearly),
            budgetRollover: d.bool(forKey: BudgetKey.rollover),
            budgetAlerts: d.bool(forKey: BudgetKey.alertsEnabled),
            budgetWarnPercent: d.object(forKey: BudgetKey.warnPercent) as? Int,
            learnRules: d.object(forKey: RuleStore.learnKey) as? Bool
        )
        let rules = (try? context.fetch(FetchDescriptor<CategoryRule>())) ?? []
        let recurring = (try? context.fetch(FetchDescriptor<RecurringRule>())) ?? []
        let batches = (try? context.fetch(FetchDescriptor<ImportBatch>())) ?? []
        return LedgerBackup(
            createdAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            device: UIDevice.current.name,
            categories: categories.map {
                LedgerBackup.CategoryDTO(id: $0.id, name: $0.name, icon: $0.icon, colorHex: $0.colorHex, kind: $0.kindRaw,
                      sortOrder: $0.sortOrder, createdAt: $0.createdAt,
                      monthlyBudget: $0.monthlyBudget > 0 ? $0.monthlyBudget : nil,
                      lastAccountID: $0.lastAccountID.isEmpty ? nil : $0.lastAccountID)
            },
            records: records.map {
                LedgerBackup.RecordDTO(id: $0.id, amount: $0.amount, kind: $0.kindRaw, note: $0.note, merchant: $0.merchant,
                      account: $0.accountName, date: $0.date, source: $0.source, createdAt: $0.createdAt,
                      categoryID: $0.category?.id, accountID: $0.accountRef?.id, toAccountID: $0.toAccount?.id,
                      fee: $0.fee > 0 ? $0.fee : nil,
                      externalID: $0.externalID.isEmpty ? nil : $0.externalID,
                      importBatchID: $0.importBatchID.isEmpty ? nil : $0.importBatchID,
                      recurringKey: $0.recurringKey.isEmpty ? nil : $0.recurringKey)
            },
            accounts: accounts.map {
                LedgerBackup.AccountDTO(id: $0.id, name: $0.name, type: $0.typeRaw, initialBalance: $0.initialBalance,
                                        creditLimit: $0.creditLimit, billingDay: $0.billingDay, repaymentDay: $0.repaymentDay,
                                        icon: $0.icon, colorHex: $0.colorHex, note: $0.note,
                                        includeInNetWorth: $0.includeInNetWorth, isArchived: $0.isArchived,
                                        sortOrder: $0.sortOrder, createdAt: $0.createdAt)
            },
            rules: rules.map {
                LedgerBackup.RuleDTO(id: $0.id, keyword: $0.keyword, displayName: $0.displayName, isLearned: $0.isLearned,
                                     kind: $0.kindRaw, categoryID: $0.categoryID, accountID: $0.accountID,
                                     hitCount: $0.hitCount, isEnabled: $0.isEnabled, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            },
            recurring: recurring.map {
                LedgerBackup.RecurringDTO(id: $0.id, name: $0.name, amount: $0.amount, kind: $0.kindRaw,
                                          categoryID: $0.categoryID, accountID: $0.accountID, toAccountID: $0.toAccountID,
                                          note: $0.note, merchant: $0.merchant, frequency: $0.frequencyRaw,
                                          interval: $0.interval, weekday: $0.weekday, monthDay: $0.monthDay,
                                          lastDayOfMonth: $0.lastDayOfMonth, startDate: $0.startDate, endDate: $0.endDate,
                                          maxCount: $0.maxCount, autoCreate: $0.autoCreate, remindEnabled: $0.remindEnabled,
                                          remindDaysBefore: $0.remindDaysBefore, remindHour: $0.remindHour,
                                          remindMinute: $0.remindMinute, isPaused: $0.isPaused,
                                          lastProcessedAt: $0.lastProcessedAt, createdAt: $0.createdAt)
            },
            importBatches: batches.map {
                LedgerBackup.BatchDTO(id: $0.id, source: $0.sourceRaw, fileName: $0.fileName, createdAt: $0.createdAt,
                                      recordCount: $0.recordCount, expenseTotal: $0.expenseTotal, incomeTotal: $0.incomeTotal,
                                      firstDate: $0.firstDate, lastDate: $0.lastDate)
            },
            settings: settings
        )
    }

    static func encode(_ backup: LedgerBackup) throws -> Data { try BackupJSON.encode(backup) }

    static func decode(_ data: Data) throws -> LedgerBackup { try BackupJSON.decode(data) }

    /// 读取用户在「文件」中选择的备份（会触发 iCloud 文件下载）
    static func readData(from url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinatorError: NSError?
        var data: Data?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            do { data = try Data(contentsOf: readURL) } catch { readError = error }
        }
        if let e = coordinatorError ?? readError { throw BackupError.unreadable(e.localizedDescription) }
        guard let data, !data.isEmpty else { throw BackupError.unreadable("文件为空") }
        return data
    }

    // MARK: 恢复

    @MainActor
    static func restore(_ backup: LedgerBackup, mode: RestoreMode, context: ModelContext) throws -> RestoreResult {
        var result = RestoreResult()
        let existingCategories = (try? context.fetch(FetchDescriptor<LedgerCategory>())) ?? []
        let existingRecords = (try? context.fetch(FetchDescriptor<LedgerRecord>())) ?? []
        let existingAccounts = (try? context.fetch(FetchDescriptor<LedgerAccount>())) ?? []
        var accountMap: [UUID: LedgerAccount] = [:]
        var accountByID: [UUID: LedgerAccount] = [:]
        var accountByName: [String: LedgerAccount] = [:]

        var categoryMap: [UUID: LedgerCategory] = [:]
        var byID: [UUID: LedgerCategory] = [:]
        var byName: [String: LedgerCategory] = [:]
        var existingRecordIDs = Set<UUID>()
        let existingRules = (try? context.fetch(FetchDescriptor<CategoryRule>())) ?? []
        let existingRecurring = (try? context.fetch(FetchDescriptor<RecurringRule>())) ?? []
        let existingBatches = (try? context.fetch(FetchDescriptor<ImportBatch>())) ?? []

        switch mode {
        case .replace:
            for r in existingRecords { context.delete(r) }
            for c in existingCategories { context.delete(c) }
            for a in existingAccounts { context.delete(a) }
            for r in existingRules { context.delete(r) }
            for r in existingRecurring { context.delete(r) }
            for b in existingBatches { context.delete(b) }
        case .merge:
            for c in existingCategories {
                byID[c.id] = c
                byName[c.kindRaw + "|" + c.name] = c
            }
            existingRecordIDs = Set(existingRecords.map(\.id))
            for a in existingAccounts {
                accountByID[a.id] = a
                accountByName[a.name] = a
            }
        }

        for dto in backup.accounts ?? [] {
            if let a = accountByID[dto.id] ?? accountByName[dto.name] {
                accountMap[dto.id] = a
                continue
            }
            let a = LedgerAccount(name: dto.name, type: AccountType(rawValue: dto.type) ?? .otherAsset,
                                  initialBalance: dto.initialBalance, sortOrder: dto.sortOrder)
            a.id = dto.id
            a.creditLimit = dto.creditLimit
            a.billingDay = dto.billingDay
            a.repaymentDay = dto.repaymentDay
            a.icon = dto.icon
            a.colorHex = dto.colorHex
            a.note = dto.note
            a.includeInNetWorth = dto.includeInNetWorth
            a.isArchived = dto.isArchived
            a.createdAt = dto.createdAt
            context.insert(a)
            accountMap[dto.id] = a
            accountByName[dto.name] = a
            result.insertedAccounts += 1
        }

        for dto in backup.categories {
            if let c = byID[dto.id] ?? byName[dto.kind + "|" + dto.name] {
                categoryMap[dto.id] = c
                continue
            }
            let c = LedgerCategory(name: dto.name, icon: dto.icon, colorHex: dto.colorHex,
                                   kind: RecordKind(rawValue: dto.kind) ?? .expense, sortOrder: dto.sortOrder)
            c.id = dto.id
            c.createdAt = dto.createdAt
            c.monthlyBudget = dto.monthlyBudget ?? 0
            context.insert(c)
            categoryMap[dto.id] = c
            byName[dto.kind + "|" + dto.name] = c
            result.insertedCategories += 1
        }

        for dto in backup.records {
            if existingRecordIDs.contains(dto.id) {
                result.skippedRecords += 1
                continue
            }
            let r = LedgerRecord(amount: dto.amount, kind: RecordKind(rawValue: dto.kind) ?? .expense,
                                 category: dto.categoryID.flatMap { categoryMap[$0] }, note: dto.note,
                                 merchant: dto.merchant, account: dto.account, date: dto.date, source: dto.source)
            r.id = dto.id
            r.createdAt = dto.createdAt
            r.accountRef = dto.accountID.flatMap { accountMap[$0] }
            r.toAccount = dto.toAccountID.flatMap { accountMap[$0] }
            r.fee = dto.fee ?? 0
            r.externalID = dto.externalID ?? ""
            r.importBatchID = dto.importBatchID ?? ""
            r.recurringKey = dto.recurringKey ?? ""
            context.insert(r)
            existingRecordIDs.insert(dto.id)
            result.insertedRecords += 1
        }

        // v3：分类上次账户、分类预算（合并时只补充未设置的）
        func mapCategory(_ s: String) -> String {
            guard let id = UUID(uuidString: s) else { return "" }
            return (categoryMap[id]?.id ?? id).uuidString
        }
        func mapAccount(_ s: String) -> String {
            guard let id = UUID(uuidString: s) else { return "" }
            return (accountMap[id]?.id ?? id).uuidString
        }
        for dto in backup.categories {
            guard let c = categoryMap[dto.id] else { continue }
            if let b = dto.monthlyBudget, b > 0, c.monthlyBudget == 0 { c.monthlyBudget = b }
            if let a = dto.lastAccountID, c.lastAccountID.isEmpty { c.lastAccountID = mapAccount(a) }
        }

        let ruleIDs = Set(mode == .merge ? existingRules.map(\.id) : [])
        let ruleKeys = Set(mode == .merge ? existingRules.map { "\($0.isLearned)|\($0.keyword)" } : [])
        for dto in backup.rules ?? [] where !ruleIDs.contains(dto.id) && !ruleKeys.contains("\(dto.isLearned)|\(dto.keyword)") {
            let r = CategoryRule(keyword: dto.keyword, displayName: dto.displayName, isLearned: dto.isLearned,
                                 kind: RecordKind(rawValue: dto.kind), categoryID: nil, accountID: nil)
            r.id = dto.id
            r.categoryID = mapCategory(dto.categoryID)
            r.accountID = mapAccount(dto.accountID)
            r.hitCount = dto.hitCount
            r.isEnabled = dto.isEnabled
            r.createdAt = dto.createdAt
            r.updatedAt = dto.updatedAt
            context.insert(r)
            result.insertedRules += 1
        }

        let recurringIDs = Set(mode == .merge ? existingRecurring.map(\.id) : [])
        for dto in backup.recurring ?? [] where !recurringIDs.contains(dto.id) {
            let r = RecurringRule(name: dto.name, amount: dto.amount, kind: RecordKind(rawValue: dto.kind) ?? .expense,
                                  frequency: RecurrenceFrequency(rawValue: dto.frequency) ?? .monthly, startDate: dto.startDate)
            r.id = dto.id
            r.categoryID = mapCategory(dto.categoryID)
            r.accountID = mapAccount(dto.accountID)
            r.toAccountID = mapAccount(dto.toAccountID)
            r.note = dto.note
            r.merchant = dto.merchant
            r.interval = dto.interval
            r.weekday = dto.weekday
            r.monthDay = dto.monthDay
            r.lastDayOfMonth = dto.lastDayOfMonth
            r.endDate = dto.endDate
            r.maxCount = dto.maxCount
            r.autoCreate = dto.autoCreate
            r.remindEnabled = dto.remindEnabled
            r.remindDaysBefore = dto.remindDaysBefore
            r.remindHour = dto.remindHour
            r.remindMinute = dto.remindMinute
            r.isPaused = dto.isPaused
            r.lastProcessedAt = dto.lastProcessedAt
            r.createdAt = dto.createdAt
            context.insert(r)
            result.insertedRecurring += 1
        }

        let batchIDs = Set(mode == .merge ? existingBatches.map(\.id) : [])
        for dto in backup.importBatches ?? [] where !batchIDs.contains(dto.id) {
            let b = ImportBatch(source: BillSource(rawValue: dto.source) ?? .alipay, fileName: dto.fileName)
            b.id = dto.id
            b.createdAt = dto.createdAt
            b.recordCount = dto.recordCount
            b.expenseTotal = dto.expenseTotal
            b.incomeTotal = dto.incomeTotal
            b.firstDate = dto.firstDate
            b.lastDate = dto.lastDate
            context.insert(b)
        }

        if mode == .replace {
            applySettings(backup.settings)
        }
        try context.save()
        // 旧版（v1）备份只有账户文字：自动创建 / 关联账户
        let before = DataStore.accounts(in: context, includeArchived: true).count
        DataStore.linkLegacyAccounts(in: context)
        result.insertedAccounts += max(0, DataStore.accounts(in: context, includeArchived: true).count - before)
        return result
    }

    private static func applySettings(_ s: LedgerBackup.SettingsDTO) {
        let d = UserDefaults.standard
        if let v = s.monthlyBudget { d.set(v, forKey: SettingsKey.monthlyBudget) }
        if let v = s.currencySymbol { d.set(v, forKey: SettingsKey.currencySymbol) }
        if let v = s.appearance { d.set(v, forKey: SettingsKey.appearance) }
        if let v = s.defaultAccount { d.set(v, forKey: SettingsKey.defaultAccount) }
        if let v = s.hideInAppSwitcher { d.set(v, forKey: SettingsKey.hideInAppSwitcher) }
        if let v = s.yearlyBudget { d.set(v, forKey: BudgetKey.yearly) }
        if let v = s.budgetRollover { d.set(v, forKey: BudgetKey.rollover) }
        // 预算提醒需要通知权限：恢复后由用户在「预算」页重新开启
        if let v = s.budgetWarnPercent { d.set(v, forKey: BudgetKey.warnPercent) }
        if let v = s.learnRules { d.set(v, forKey: RuleStore.learnKey) }
    }
}

extension UTType {
    /// 简账加密备份（.jzbackup），在 Info.plist 的 UTExportedTypeDeclarations 中声明
    static let jzBackup = UTType(exportedAs: "com.fve.ledger.jzbackup", conformingTo: .data)
}

/// fileExporter 使用的文档
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .jzBackup] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else { throw BackupError.invalidFormat }
        data = d
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - 自动备份

/// 自动备份方式
enum AutoBackupMode: String, CaseIterable, Identifiable {
    /// 每次打开 / 切到后台时更新同一个备份文件（默认）
    case rolling
    /// 按频率生成带时间的备份，保留最近若干份
    case periodic

    var id: String { rawValue }
    var title: String {
        switch self {
        case .rolling: return "每次打开/关闭时更新"
        case .periodic: return "定期保留多份"
        }
    }
}

enum AutoBackup {
    static let intervalOptions: [Int] = [86_400, 3 * 86_400, 7 * 86_400]
    static let keepOptions: [Int] = [5, 10, 20, 30]
    static let snapshotKeepOptions: [Int] = [3, 7, 14, 30]
    /// 滚动备份的固定文件名（不含扩展名）
    static let rollingBaseName = "简账自动备份"

    static func intervalTitle(_ seconds: Int) -> String {
        switch seconds {
        case 86_400: return "每天"
        case 7 * 86_400: return "每周"
        default: return "每 \(seconds / 86_400) 天"
        }
    }

    static var mode: AutoBackupMode {
        AutoBackupMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.autoBackupMode) ?? "") ?? .rolling
    }

    static var interval: Int {
        let v = UserDefaults.standard.integer(forKey: SettingsKey.autoBackupInterval)
        return v > 0 ? v : 86_400
    }

    static var keepCount: Int {
        let v = UserDefaults.standard.integer(forKey: SettingsKey.autoBackupKeep)
        return v > 0 ? v : 10
    }

    static var dailySnapshotEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.autoBackupDailySnapshot) as? Bool ?? true
    }

    static var snapshotKeep: Int {
        let v = UserDefaults.standard.integer(forKey: SettingsKey.autoBackupSnapshotKeep)
        return v > 0 ? v : 7
    }

    /// 备份目录：优先 iCloud 容器的 Documents（在「文件 › iCloud 云盘 › 简账」中可见），否则本机 Documents（「文件 › 我的 iPhone › 简账」）
    static func directory() async -> (url: URL, isICloud: Bool) {
        if let container = await CloudSync.containerURL() {
            return (container.appendingPathComponent("Documents", isDirectory: true), true)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return (docs, false)
    }

    static func locationTitle(isICloud: Bool) -> String {
        isICloud ? "iCloud 云盘 › 简账" : "我的 iPhone › 简账（可在「文件」App 中复制到 iCloud 云盘）"
    }

    /// 内容指纹：备份时间固定为 0 后的 JSON 的 SHA-256，再加上加密状态。数据没变就不重写文件
    static func fingerprint(of backup: LedgerBackup, encrypted: Bool) throws -> String {
        var b = backup
        b.createdAt = Date(timeIntervalSince1970: 0)
        let digest = SHA256.hash(data: try BackupJSON.encode(b))
        return (encrypted ? "E:" : "P:") + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 修改 / 移除备份密码、切换加密后调用：下次自动备份强制重写
    static func invalidateFingerprint() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.autoBackupFingerprint)
    }

    /// 加密开启时取钥匙串中的备份密码（每次复用同一个，不再询问）；没有密码时拒绝写明文
    private static func passwordForBackup() throws -> String? {
        guard BackupPasswordStore.encryptionEnabled else { return nil }
        guard let saved = BackupPasswordStore.load() else {
            UserDefaults.standard.set(true, forKey: SettingsKey.backupNeedsPassword)
            throw BackupError.passwordRequired
        }
        UserDefaults.standard.set(false, forKey: SettingsKey.backupNeedsPassword)
        return saved
    }

    private static var isRunning = false

    /// 立即备份，返回写入的文件地址（滚动模式下为固定文件；数据无变化时也返回该文件）
    @MainActor
    @discardableResult
    static func backupNow(context: ModelContext, force: Bool = true) async throws -> URL {
        let password = try passwordForBackup()
        let encrypted = password != nil
        let backup = BackupService.makeBackup(context: context)
        let target = await directory()
        let iterations = BackupCrypto.tunedIterations()
        let mode = mode
        let keep = keepCount
        let snapshots = dailySnapshotEnabled ? snapshotKeep : 0
        let fp = try fingerprint(of: backup, encrypted: encrypted)
        let unchanged = !force && fp == UserDefaults.standard.string(forKey: SettingsKey.autoBackupFingerprint)

        let result = try await Task.detached(priority: .utility) { () throws -> (url: URL, wrote: Bool) in
            let fm = FileManager.default
            try fm.createDirectory(at: target.url, withIntermediateDirectories: true)
            let ext = encrypted ? BackupCrypto.fileExtension : "json"
            func makeData() throws -> Data {
                let json = try BackupJSON.encode(backup)
                guard let password else { return json }
                return try BackupCrypto.encrypt(json, password: password, iterations: iterations)
            }
            switch mode {
            case .periodic:
                let fileURL = target.url.appendingPathComponent(BackupService.fileName(encrypted: encrypted))
                try writeAtomically(try makeData(), to: fileURL)
                prune(in: target.url, keep: keep)
                return (fileURL, true)
            case .rolling:
                let fileURL = target.url.appendingPathComponent(rollingBaseName + "." + ext)
                var wrote = false
                if !unchanged || !fm.fileExists(atPath: fileURL.path) {
                    try writeAtomically(try makeData(), to: fileURL)
                    wrote = true
                }
                // 切换加密后删除另一种格式的旧滚动文件（避免留下明文副本）
                let other = target.url.appendingPathComponent(rollingBaseName + "." + (encrypted ? "json" : BackupCrypto.fileExtension))
                if fm.fileExists(atPath: other.path) { try? fm.removeItem(at: other) }
                // 每日快照：当天还没有就复制一份滚动文件
                if snapshots > 0 && !hasSnapshot(on: Date(), in: target.url) {
                    let snap = target.url.appendingPathComponent(BackupService.fileName(encrypted: encrypted))
                    if let d = try? Data(contentsOf: fileURL) { try writeAtomically(d, to: snap) }
                    prune(in: target.url, keep: snapshots)
                }
                return (fileURL, wrote)
            }
        }.value

        if result.wrote {
            UserDefaults.standard.set(fp, forKey: SettingsKey.autoBackupFingerprint)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: SettingsKey.lastBackupAt)
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: SettingsKey.lastBackupCheckAt)
        UserDefaults.standard.set(locationTitle(isICloud: target.isICloud), forKey: SettingsKey.lastBackupLocation)
        return result.url
    }

    /// 原子写入：先写到同目录的临时文件，再整体替换目标文件，写到一半崩溃也不会损坏原备份。
    /// iCloud 容器内通过 NSFileCoordinator 协调，避免与同步进程冲突。
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { dest in
            do {
                let tmp = dest.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).tmp")
                try data.write(to: tmp, options: [.completeFileProtectionUntilFirstUserAuthentication])
                if fm.fileExists(atPath: dest.path) {
                    _ = try fm.replaceItemAt(dest, withItemAt: tmp)
                } else {
                    try fm.moveItem(at: tmp, to: dest)
                }
                if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
            } catch {
                writeError = error
            }
        }
        if let e = coordError ?? writeError { throw e }
    }

    /// 回到前台时调用：定期模式按频率；滚动模式每次都检查（数据无变化则跳过写入）
    @MainActor
    static func runIfDue(context: ModelContext) async {
        guard !ScreenshotDemo.isActive, UserDefaults.standard.bool(forKey: SettingsKey.autoBackupEnabled), !isRunning else { return }
        if mode == .periodic {
            let last = UserDefaults.standard.double(forKey: SettingsKey.lastBackupAt)
            guard Date().timeIntervalSince1970 - last >= Double(interval) else { return }
        }
        isRunning = true
        defer { isRunning = false }
        _ = try? await backupNow(context: context, force: mode == .periodic)
    }

    /// 切到后台时调用（仅滚动模式）：申请后台时间把文件写完
    @MainActor
    static func runOnBackground(context: ModelContext) {
        guard !ScreenshotDemo.isActive, UserDefaults.standard.bool(forKey: SettingsKey.autoBackupEnabled),
              mode == .rolling, !isRunning else { return }
        isRunning = true
        var taskID = UIBackgroundTaskIdentifier.invalid
        func end() {
            if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID); taskID = .invalid }
        }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "简账自动备份") { end() }
        Task { @MainActor in
            _ = try? await backupNow(context: context, force: false)
            isRunning = false
            end()
        }
    }

    static func backupFiles(in dir: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(BackupService.filePrefix)
                && ["json", BackupCrypto.fileExtension].contains($0.pathExtension) }
            .sorted { $0.deletingPathExtension().lastPathComponent > $1.deletingPathExtension().lastPathComponent }
    }

    static func hasSnapshot(on date: Date, in dir: URL) -> Bool {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        let prefix = BackupService.filePrefix + f.string(from: date) + "-"
        return backupFiles(in: dir).contains { $0.lastPathComponent.hasPrefix(prefix) }
    }

    /// 只保留最近 keep 份（文件名含时间，按名称倒序即新到旧）
    static func prune(in dir: URL, keep: Int) {
        for old in backupFiles(in: dir).dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    static func countBackups() async -> Int {
        let target = await directory()
        return await Task.detached { backupFiles(in: target.url).count }.value
    }
}
