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

/// 账单导入时：日期不晚于账本最新记录的交易，写入后通过调整初始余额保持当前余额不变（2.0 (13)）
enum ImportBalanceMath {
    /// 账本为空（没有已有记录）时，导入的每一笔都按「新交易」影响余额
    static func isHistorical(date: Date, latestExisting: Date?) -> Bool {
        guard let latestExisting else { return false }
        return date <= latestExisting
    }

    /// 把一条记录对各账户的影响累加到 offsets（accountID → 效果合计）
    static func accumulateEffects(
        into offsets: inout [String: Double],
        kind: RecordKind, amount: Double, fee: Double,
        fromAccountID: String?, toAccountID: String?
    ) {
        if let id = fromAccountID {
            offsets[id, default: 0] += BalanceMath.effect(kind: kind, amount: amount, fee: fee,
                                                          isSource: true, isTarget: false)
        }
        if kind == .transfer, let id = toAccountID {
            offsets[id, default: 0] += BalanceMath.effect(kind: kind, amount: amount, fee: fee,
                                                          isSource: false, isTarget: true)
        }
    }

    /// 为保持当前余额不变，应加到各账户 initialBalance 上的调整量（= −效果合计）
    static func initialBalanceAdjustments(fromEffects effects: [String: Double]) -> [String: Double] {
        effects.compactMapValues { abs($0) < 1e-9 ? nil : -$0 }
    }

    static func encodeOffsets(_ offsets: [String: Double]) -> String {
        guard !offsets.isEmpty,
              let data = try? JSONEncoder().encode(offsets),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    static func decodeOffsets(_ json: String) -> [String: Double] {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return map
    }

    /// 模拟：账户初始余额 + 已有记录效果；导入后按规则调整；返回导入后各账户余额
    static func simulate(
        initials: [String: Double],
        existingEffects: [(accountID: String, date: Date, effect: Double)],
        imported: [(kind: RecordKind, amount: Double, fee: Double, date: Date, from: String?, to: String?)]
    ) -> (balances: [String: Double], adjustments: [String: Double], preservedCount: Int) {
        let latest = existingEffects.map(\.date).max()
        var initialsNow = initials
        var running: [String: Double] = initials
        for e in existingEffects { running[e.accountID, default: 0] += e.effect }

        var effectSum: [String: Double] = [:]
        var preserved = 0
        for r in imported {
            if isHistorical(date: r.date, latestExisting: latest) {
                preserved += 1
                accumulateEffects(into: &effectSum, kind: r.kind, amount: r.amount, fee: r.fee,
                                  fromAccountID: r.from, toAccountID: r.to)
            }
            if let id = r.from {
                running[id, default: initials[id] ?? 0] += BalanceMath.effect(kind: r.kind, amount: r.amount, fee: r.fee,
                                                                              isSource: true, isTarget: false)
            }
            if r.kind == .transfer, let id = r.to {
                running[id, default: initials[id] ?? 0] += BalanceMath.effect(kind: r.kind, amount: r.amount, fee: r.fee,
                                                                              isSource: false, isTarget: true)
            }
        }
        let adj = initialBalanceAdjustments(fromEffects: effectSum)
        for (id, d) in adj {
            initialsNow[id, default: 0] += d
            running[id, default: 0] += d
        }
        // 余额 = 调整后的初始 + 全部效果；上面 running 已含效果，再加 adj 即最终余额
        return (running.mapValues { ($0 * 100).rounded() / 100 }, adj, preserved)
    }
}
