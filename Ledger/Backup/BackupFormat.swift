import Foundation

// MARK: - 备份文件格式（JSON，带版本号）

struct LedgerBackup: Codable {
    static let formatID = "jianzhang-backup"
    /// v2：新增账户、转账（转入账户、手续费）。
    /// v3：新增记账规则、周期账单、导入批次、分类预算。v1 / v2 备份仍可导入。
    static let currentVersion = 3

    var format: String = LedgerBackup.formatID
    var version: Int = LedgerBackup.currentVersion
    var createdAt: Date
    var appVersion: String
    var device: String
    var categories: [CategoryDTO]
    var records: [RecordDTO]
    var accounts: [AccountDTO]? = nil
    var rules: [RuleDTO]? = nil
    var recurring: [RecurringDTO]? = nil
    var importBatches: [BatchDTO]? = nil
    /// 变动日志（可选字段，旧版 App 读取时忽略；不计入自动备份的内容指纹）
    var changeLog: [ChangeLogDTO]? = nil
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
        var monthlyBudget: Double? = nil
        var lastAccountID: String? = nil
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
        var externalID: String? = nil
        var importBatchID: String? = nil
        var recurringKey: String? = nil
    }

    struct RuleDTO: Codable {
        var id: UUID
        var keyword: String
        var displayName: String
        var isLearned: Bool
        var kind: String
        var categoryID: String
        var accountID: String
        var hitCount: Int
        var isEnabled: Bool
        var createdAt: Date
        var updatedAt: Date
    }

    struct RecurringDTO: Codable {
        var id: UUID
        var name: String
        var amount: Double
        var kind: String
        var categoryID: String
        var accountID: String
        var toAccountID: String
        var note: String
        var merchant: String
        var frequency: String
        var interval: Int
        var weekday: Int
        var monthDay: Int
        var lastDayOfMonth: Bool
        var startDate: Date
        var endDate: Date?
        var maxCount: Int
        var autoCreate: Bool
        var remindEnabled: Bool
        var remindDaysBefore: Int
        var remindHour: Int
        var remindMinute: Int
        var isPaused: Bool
        var lastProcessedAt: Date?
        var createdAt: Date
    }

    struct BatchDTO: Codable {
        var id: UUID
        var source: String
        var fileName: String
        var createdAt: Date
        var recordCount: Int
        var expenseTotal: Double
        var incomeTotal: Double
        var firstDate: Date?
        var lastDate: Date?
    }

    struct ChangeLogDTO: Codable {
        var id: UUID
        var timestamp: Date
        var source: String
        var action: String
        var entityType: String
        var entityID: String
        var summary: String
        var diffs: String? = nil
        var children: String? = nil
        var childCount: Int? = nil
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
        var yearlyBudget: Double? = nil
        var budgetRollover: Bool? = nil
        var budgetAlerts: Bool? = nil
        var budgetWarnPercent: Int? = nil
        var learnRules: Bool? = nil
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
    /// 自动备份开启了加密，但本机钥匙串里没有保存备份密码
    case passwordRequired

    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "这不是简账的备份文件。"
        case .unsupportedVersion(let v): return "备份文件版本（v\(v)）比当前 App 新，请先升级简账。"
        case .unreadable(let m): return "无法读取备份文件：\(m)"
        case .passwordRequired: return "已开启「加密备份」，但还没有在本机保存备份密码。请在「iCloud 与备份 › 备份加密」中设置备份密码。"
        }
    }
}

/// 备份 JSON 编解码（纯 Foundation，便于在 macOS 命令行测试中复用）
enum BackupJSON {
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

    /// 自动识别：加密备份（JZBK 头）需要密码；明文 JSON（v1–v3）直接解析
    static func open(_ data: Data, password: String?) throws -> LedgerBackup {
        if BackupCrypto.isEncrypted(data) {
            guard let password, !password.isEmpty else { throw BackupCryptoError.passwordNeeded }
            return try decode(BackupCrypto.decrypt(data, password: password))
        }
        return try decode(data)
    }
}
