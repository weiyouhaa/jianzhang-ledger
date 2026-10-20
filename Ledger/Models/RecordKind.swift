import Foundation

/// 记录类型（以字符串存储，便于 #Predicate 过滤）。转账、余额校准、缴存不计入收支统计和预算。
enum RecordKind: String, CaseIterable, Identifiable, Codable {
    case expense
    case income
    case transfer
    case adjustment
    /// 公积金 / 社保 / 年金缴存：只增加该账户余额，不计入收入
    case contribution

    var id: String { rawValue }
    var title: String {
        switch self {
        case .expense: return "支出"
        case .income: return "收入"
        case .transfer: return "转账"
        case .adjustment: return "余额校准"
        case .contribution: return "缴存"
        }
    }
    var sign: String {
        switch self {
        case .expense: return "-"
        case .income, .contribution: return "+"
        case .transfer, .adjustment: return ""
        }
    }
    /// 有分类、计入统计的类型
    static let categoryKinds: [RecordKind] = [.expense, .income]
    /// 记账页可选的类型
    static let editorKinds: [RecordKind] = [.expense, .income, .transfer]
    var countsInStats: Bool { self == .expense || self == .income }
}

/// 余额与统计口径（纯函数，不依赖 SwiftData，便于在命令行测试）
enum BalanceMath {
    /// 一条记录对某账户余额的影响。isSource：该账户是记录的账户（转账为转出方）；isTarget：转账的转入方。
    /// 信用卡还款 = 转入负债账户的转账：付款账户 −金额（−手续费），信用卡余额 +金额（欠款减少）。
    static func effect(kind: RecordKind, amount: Double, fee: Double, isSource: Bool, isTarget: Bool) -> Double {
        var delta = 0.0
        if isSource {
            switch kind {
            case .expense: delta -= amount
            case .income: delta += amount
            case .transfer: delta -= amount + fee
            case .adjustment, .contribution: delta += amount
            }
        }
        if kind == .transfer, isTarget {
            delta += amount
        }
        return delta
    }

    static func isRepayment(kind: RecordKind, toLiability: Bool) -> Bool { kind == .transfer && toLiability }

    /// 统计口径：支出 / 收入 / 不计（nil）。还款默认不计（刷卡消费已记为支出，避免重复）
    static func statsKind(kind: RecordKind, toLiability: Bool, includeRepayment: Bool) -> RecordKind? {
        switch kind {
        case .expense, .income: return kind
        case .transfer: return includeRepayment && toLiability ? .expense : nil
        case .adjustment, .contribution: return nil
        }
    }
}

/// 「信用卡还款计入支出」（按模式隔离：真实 / 防窥各一份）
enum RepaymentSetting {
    static let key = "stats.repaymentAsExpense"
    static func includeInExpense(_ prefs: UserDefaults) -> Bool { prefs.bool(forKey: key) }
}
