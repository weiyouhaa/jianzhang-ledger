import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - 备份文件格式（JSON，带版本号）

struct LedgerBackup: Codable {
    static let formatID = "jianzhang-backup"
    /// v2：新增账户、转账（转入账户、手续费）。v1 备份仍可导入。
    static let currentVersion = 2

    var format: String = LedgerBackup.formatID
    var version: Int = LedgerBackup.currentVersion
    var createdAt: Date
    var appVersion: String
    var device: String
    var categories: [CategoryDTO]
    var records: [RecordDTO]
    var accounts: [AccountDTO]? = nil
    /// 不包含密码、面容 ID 等安全设置
    var settings: SettingsDTO

    struct CategoryDTO: Codable {
        var id: UUID
        var name: String
        var icon: String
        var colorHex: String
        var kind: String
        var sortOrder: Int
        var createdAt: Date
    }

    struct RecordDTO: Codable {
        var id: UUID
        var amount: Double
        var kind: String
        var note: String
        var merchant: String
        var account: String
        var date: Date
        var source: String
        var createdAt: Date
        var categoryID: UUID?
        var accountID: UUID? = nil
        var toAccountID: UUID? = nil
        var fee: Double? = nil
    }

    struct AccountDTO: Codable {
        var id: UUID
        var name: String
        var type: String
        var initialBalance: Double
        var creditLimit: Double
        var billingDay: Int
        var repaymentDay: Int
        var icon: String
        var colorHex: String
        var note: String
        var includeInNetWorth: Bool
        var isArchived: Bool
        var sortOrder: Int
        var createdAt: Date
    }

    struct SettingsDTO: Codable {
        var monthlyBudget: Double?
        var currencySymbol: String?
        var appearance: Int?
        var defaultAccount: String?
        var hideInAppSwitcher: Bool?
    }

    var recordDateRange: ClosedRange<Date>? {
        guard let lo = records.map(\.date).min(), let hi = records.map(\.date).max() else { return nil }
        return lo...hi
    }
}

enum BackupError: LocalizedError {
    case invalidFormat
    case unsupportedVersion(Int)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "这不是简账的备份文件。"
        case .unsupportedVersion(let v): return "备份文件版本（v\(v)）比当前 App 新，请先升级简账。"
        case .unreadable(let m): return "无法读取备份文件：\(m)"
        }
    }
}

enum RestoreMode {
    case merge
    case replace
}

struct RestoreResult {
    var insertedRecords = 0
    var skippedRecords = 0
    var insertedCategories = 0
    var insertedAccounts = 0

    var summary: String {
        var s = "导入 \(insertedRecords) 笔记录"
        if skippedRecords > 0 { s += "，跳过 \(skippedRecords) 笔已存在的记录" }
        if insertedCategories > 0 { s += "，新增 \(insertedCategories) 个分类" }
        if insertedAccounts > 0 { s += "，新增 \(insertedAccounts) 个账户" }
        return s + "。"
    }
}

enum BackupService {
    static let filePrefix = "简账备份-"

    static func fileName(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return filePrefix + f.string(from: date) + ".json"
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
            hideInAppSwitcher: d.object(forKey: SettingsKey.hideInAppSwitcher) as? Bool
        )
        return LedgerBackup(
            createdAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            device: UIDevice.current.name,
            categories: categories.map {
                LedgerBackup.CategoryDTO(id: $0.id, name: $0.name, icon: $0.icon, colorHex: $0.colorHex, kind: $0.kindRaw,
                      sortOrder: $0.sortOrder, createdAt: $0.createdAt)
            },
            records: records.map {
                LedgerBackup.RecordDTO(id: $0.id, amount: $0.amount, kind: $0.kindRaw, note: $0.note, merchant: $0.merchant,
                      account: $0.accountName, date: $0.date, source: $0.source, createdAt: $0.createdAt,
                      categoryID: $0.category?.id, accountID: $0.accountRef?.id, toAccountID: $0.toAccount?.id,
                      fee: $0.fee > 0 ? $0.fee : nil)
            },
            accounts: accounts.map {
                LedgerBackup.AccountDTO(id: $0.id, name: $0.name, type: $0.typeRaw, initialBalance: $0.initialBalance,
                                        creditLimit: $0.creditLimit, billingDay: $0.billingDay, repaymentDay: $0.repaymentDay,
                                        icon: $0.icon, colorHex: $0.colorHex, note: $0.note,
                                        includeInNetWorth: $0.includeInNetWorth, isArchived: $0.isArchived,
                                        sortOrder: $0.sortOrder, createdAt: $0.createdAt)
            },
            settings: settings
        )
    }

    static func encode(_ backup: LedgerBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> LedgerBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup: LedgerBackup
        do {
            backup = try decoder.decode(LedgerBackup.self, from: data)
        } catch {
            throw BackupError.invalidFormat
        }
        guard backup.format == LedgerBackup.formatID else { throw BackupError.invalidFormat }
        guard backup.version <= LedgerBackup.currentVersion else { throw BackupError.unsupportedVersion(backup.version) }
        return backup
    }

    /// 读取用户在「文件」中选择的备份（会触发 iCloud 文件下载）
    static func read(from url: URL) throws -> LedgerBackup {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinatorError: NSError?
        var data: Data?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            do { data = try Data(contentsOf: readURL) } catch { readError = error }
        }
        if let e = coordinatorError ?? readError { throw BackupError.unreadable(e.localizedDescription) }
        guard let data else { throw BackupError.unreadable("文件为空") }
        return try decode(data)
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

        switch mode {
        case .replace:
            for r in existingRecords { context.delete(r) }
            for c in existingCategories { context.delete(c) }
            for a in existingAccounts { context.delete(a) }
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
            context.insert(r)
            existingRecordIDs.insert(dto.id)
            result.insertedRecords += 1
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
    }
}

/// fileExporter 使用的文档
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
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

enum AutoBackup {
    static let intervalOptions: [Int] = [86_400, 3 * 86_400, 7 * 86_400]
    static let keepOptions: [Int] = [5, 10, 20, 30]

    static func intervalTitle(_ seconds: Int) -> String {
        switch seconds {
        case 86_400: return "每天"
        case 7 * 86_400: return "每周"
        default: return "每 \(seconds / 86_400) 天"
        }
    }

    static var interval: Int {
        let v = UserDefaults.standard.integer(forKey: SettingsKey.autoBackupInterval)
        return v > 0 ? v : 86_400
    }

    static var keepCount: Int {
        let v = UserDefaults.standard.integer(forKey: SettingsKey.autoBackupKeep)
        return v > 0 ? v : 10
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

    /// 立即备份，返回文件地址
    @MainActor
    @discardableResult
    static func backupNow(context: ModelContext) async throws -> URL {
        let data = try BackupService.encode(BackupService.makeBackup(context: context))
        let target = await directory()
        let keep = keepCount
        let url = try await Task.detached(priority: .utility) { () throws -> URL in
            let fm = FileManager.default
            try fm.createDirectory(at: target.url, withIntermediateDirectories: true)
            let fileURL = target.url.appendingPathComponent(BackupService.fileName())
            try data.write(to: fileURL, options: .atomic)
            prune(in: target.url, keep: keep)
            return fileURL
        }.value
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: SettingsKey.lastBackupAt)
        UserDefaults.standard.set(locationTitle(isICloud: target.isICloud), forKey: SettingsKey.lastBackupLocation)
        return url
    }

    /// 回到前台时调用：开启了自动备份且到期才执行
    @MainActor
    static func runIfDue(context: ModelContext) async {
        guard !ScreenshotDemo.isActive, UserDefaults.standard.bool(forKey: SettingsKey.autoBackupEnabled) else { return }
        let last = UserDefaults.standard.double(forKey: SettingsKey.lastBackupAt)
        guard Date().timeIntervalSince1970 - last >= Double(interval) else { return }
        _ = try? await backupNow(context: context)
    }

    static func backupFiles(in dir: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(BackupService.filePrefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
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
