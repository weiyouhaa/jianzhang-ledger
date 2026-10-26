import Foundation
import SwiftData

/// 记账规则：商户 / 关键词 → 分类（+ 账户、收支类型）。
/// 关联对象以 UUID 字符串保存（CloudKit 兼容、删除分类后规则自动失效，不会级联出错）。
@Model
final class CategoryRule {
    var id: UUID = UUID()
    /// 学习规则：规整后的商户名；手动规则：用户输入的关键词
    var keyword: String = ""
    /// 展示用的原始商户名
    var displayName: String = ""
    var isLearned: Bool = true
    /// "" = 不限；expense / income
    var kindRaw: String = ""
    var categoryID: String = ""
    var accountID: String = ""
    var hitCount: Int = 0
    var isEnabled: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(keyword: String, displayName: String, isLearned: Bool, kind: RecordKind?, categoryID: UUID?, accountID: UUID?) {
        self.id = UUID()
        self.keyword = keyword
        self.displayName = displayName
        self.isLearned = isLearned
        self.kindRaw = kind?.rawValue ?? ""
        self.categoryID = categoryID?.uuidString ?? ""
        self.accountID = accountID?.uuidString ?? ""
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var kind: RecordKind? {
        get { kindRaw.isEmpty ? nil : RecordKind(rawValue: kindRaw) }
        set { kindRaw = newValue?.rawValue ?? "" }
    }

    var snapshot: RuleSnapshot {
        RuleSnapshot(id: id, keyword: keyword, isLearned: isLearned, kindRaw: kindRaw,
                     categoryID: UUID(uuidString: categoryID), accountID: UUID(uuidString: accountID), isEnabled: isEnabled)
    }
}

/// 一次账单导入，可整批撤销
@Model
final class ImportBatch {
    var id: UUID = UUID()
    var sourceRaw: String = BillSource.alipay.rawValue
    var fileName: String = ""
    var createdAt: Date = Date()
    var recordCount: Int = 0
    var expenseTotal: Double = 0
    var incomeTotal: Double = 0
    var firstDate: Date?
    var lastDate: Date?
    /// 导入历史账单时为保持当前余额而加到各账户 initialBalance 的调整量（JSON：账户 id → 调整量）。撤销时按此还原。
    var balanceOffsetsJSON: String = ""
    /// 本批中「日期不晚于导入前最新记录」的笔数（不影响余额）
    var balancePreservedCount: Int = 0

    init(source: BillSource, fileName: String) {
        self.id = UUID()
        self.sourceRaw = source.rawValue
        self.fileName = fileName
        self.createdAt = Date()
    }

    var source: BillSource { BillSource(rawValue: sourceRaw) ?? .alipay }

    var balanceOffsets: [String: Double] {
        get { ImportBalanceMath.decodeOffsets(balanceOffsetsJSON) }
        set { balanceOffsetsJSON = ImportBalanceMath.encodeOffsets(newValue) }
    }
}

/// 周期账单
@Model
final class RecurringRule {
    var id: UUID = UUID()
    var name: String = ""
    var amount: Double = 0
    var kindRaw: String = RecordKind.expense.rawValue
    var categoryID: String = ""
    var accountID: String = ""
    var toAccountID: String = ""
    var note: String = ""
    var merchant: String = ""
    var frequencyRaw: String = RecurrenceFrequency.monthly.rawValue
    var interval: Int = 1
    var weekday: Int = 2
    var monthDay: Int = 1
    var lastDayOfMonth: Bool = false
    var startDate: Date = Date()
    var endDate: Date?
    /// 0 = 不限次数
    var maxCount: Int = 0
    /// true：到期自动记账；false：只提醒，由用户确认「已付」
    var autoCreate: Bool = true
    var remindEnabled: Bool = false
    var remindDaysBefore: Int = 0
    var remindHour: Int = 9
    var remindMinute: Int = 0
    var isPaused: Bool = false
    /// 已处理到的最后一次发生时间（自动记账的追补进度）
    var lastProcessedAt: Date?
    var createdAt: Date = Date()

    init(name: String, amount: Double, kind: RecordKind, frequency: RecurrenceFrequency, startDate: Date) {
        self.id = UUID()
        self.name = name
        self.amount = amount
        self.kindRaw = kind.rawValue
        self.frequencyRaw = frequency.rawValue
        self.startDate = startDate
        self.createdAt = Date()
    }

    var kind: RecordKind {
        get { RecordKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    var frequency: RecurrenceFrequency {
        get { RecurrenceFrequency(rawValue: frequencyRaw) ?? .monthly }
        set { frequencyRaw = newValue.rawValue }
    }

    var spec: RecurrenceSpec {
        RecurrenceSpec(frequency: frequency, interval: max(1, interval), weekday: weekday, monthDay: monthDay,
                       lastDayOfMonth: lastDayOfMonth, start: startDate, end: endDate, maxCount: maxCount)
    }

    /// 生成记录的唯一键
    func key(for occurrence: Date) -> String {
        id.uuidString + "|" + DayKey.formatter.string(from: occurrence)
    }
}

/// 「yyyy-MM-dd」键（周期账单、预算提醒）
enum DayKey {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
