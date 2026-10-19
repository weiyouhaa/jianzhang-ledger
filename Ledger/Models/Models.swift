import Foundation
import SwiftData
import SwiftUI

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

@Model
final class LedgerCategory {
    var id: UUID = UUID()
    var name: String = ""
    var icon: String = "tag.fill"
    var colorHex: String = "#8E8E93"
    var kindRaw: String = RecordKind.expense.rawValue
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    /// 分类月预算（0 = 未设置）
    var monthlyBudget: Double = 0
    /// 该分类最近一次使用的账户（UUID 字符串），记一笔时自动带出
    var lastAccountID: String = ""

    @Relationship(deleteRule: .nullify, inverse: \LedgerRecord.category)
    var records: [LedgerRecord]? = []

    init(name: String, icon: String, colorHex: String, kind: RecordKind, sortOrder: Int) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.kindRaw = kind.rawValue
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    var kind: RecordKind {
        get { RecordKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    var color: Color { Color(hex: colorHex) }
}

@Model
final class LedgerRecord {
    var id: UUID = UUID()
    var amount: Double = 0
    var kindRaw: String = RecordKind.expense.rawValue
    var note: String = ""
    var merchant: String = ""
    var account: String = ""
    var date: Date = Date()
    /// manual / ocr / shortcut
    var source: String = "manual"
    var createdAt: Date = Date()
    var category: LedgerCategory?
    /// 账户（支出 / 收入所用账户；转账时为转出账户；校准时为被校准账户）
    var accountRef: LedgerAccount?
    /// 转账的转入账户
    var toAccount: LedgerAccount?
    /// 转账手续费（从转出账户扣除）
    var fee: Double = 0
    /// 外部订单号（账单导入时的交易订单号，用于去重）
    var externalID: String = ""
    /// 所属导入批次（ImportBatch.id 的字符串），用于整批撤销
    var importBatchID: String = ""
    /// 周期账单生成的记录：「规则ID|yyyy-MM-dd」，保证不重复生成
    var recurringKey: String = ""

    init(amount: Double, kind: RecordKind, category: LedgerCategory?, note: String = "", merchant: String = "",
         account: String = "", date: Date = Date(), source: String = "manual") {
        self.id = UUID()
        self.amount = amount
        self.kindRaw = kind.rawValue
        self.category = category
        self.note = note
        self.merchant = merchant
        self.account = account
        self.date = date
        self.source = source
        self.createdAt = Date()
    }

    var kind: RecordKind {
        get { RecordKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    /// 账户显示名：优先关联的账户，其次旧版文本字段
    var accountName: String { accountRef?.name ?? account }

    var isCreditRepayment: Bool { kind == .transfer && (toAccount?.type.isLiability ?? false) }

    var categoryName: String {
        switch kind {
        case .transfer: return isCreditRepayment ? "还款" : "转账"
        case .adjustment: return "余额校准"
        case .contribution: return "缴存"
        default: return category?.name ?? "未分类"
        }
    }
    var categoryIcon: String {
        switch kind {
        case .transfer: return isCreditRepayment ? "creditcard.and.123" : "arrow.left.arrow.right"
        case .adjustment: return "slider.horizontal.3"
        case .contribution: return "tray.and.arrow.down.fill"
        default: return category?.icon ?? "questionmark.circle.fill"
        }
    }
    var categoryColor: Color {
        switch kind {
        case .transfer: return Color(hex: "#30B0C7")
        case .adjustment: return .gray
        case .contribution: return accountRef?.color ?? Color(hex: "#E8A33D")
        default: return category?.color ?? .gray
        }
    }

    /// 列表中显示的标题：备注 > 商户 > 分类名（转账显示「A → B」）
    var displayTitle: String {
        if !note.isEmpty { return note }
        if !merchant.isEmpty { return merchant }
        if kind == .transfer { return (accountRef?.name ?? "?") + " → " + (toAccount?.name ?? "?") }
        if kind == .contribution { return (accountRef?.name ?? "") + "缴存" }
        return categoryName
    }

    /// 删除确认里显示的摘要：「华南畅行高速科技… -¥46.00 · 10月17日 20:12」
    var deleteSummary: String {
        var title = displayTitle
        if title.count > 12 { title = String(title.prefix(12)) + "…" }
        return "\(title) \(amountText) · \(DateText.monthDayTime.string(from: date))"
    }

    /// 列表中显示的金额文本
    var amountText: String {
        switch kind {
        case .expense: return "-" + Money.format(amount)
        case .income, .contribution: return "+" + Money.format(amount)
        case .transfer: return Money.format(amount)
        case .adjustment: return (amount >= 0 ? "+" : "") + Money.format(amount)
        }
    }

    /// 本记录对某账户余额的影响
    func effect(on account: LedgerAccount) -> Double {
        var delta = 0.0
        if accountRef?.id == account.id {
            switch kind {
            case .expense: delta -= amount
            case .income: delta += amount
            case .transfer: delta -= amount + fee
            case .adjustment, .contribution: delta += amount
            }
        }
        if kind == .transfer, toAccount?.id == account.id {
            delta += amount
        }
        return delta
    }
}

/// 账户类型
enum AccountType: String, CaseIterable, Identifiable, Codable {
    case debit, alipay, wechat, cash, investment, receivable, otherAsset
    /// 公积金与社保（个人账户）、年金
    case housingFund, medicalAccount, pensionAccount, privatePension, enterpriseAnnuity
    case credit, consumerCredit
    /// 房贷（商业贷款 / 公积金贷款）、车贷
    case mortgage, fundLoan, carLoan
    case loan, otherLiability

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cash: return "现金"
        case .debit: return "储蓄卡"
        case .alipay: return "支付宝"
        case .wechat: return "微信"
        case .investment: return "投资理财"
        case .receivable: return "借出 / 应收"
        case .otherAsset: return "其他资产"
        case .housingFund: return "住房公积金"
        case .medicalAccount: return "医保个人账户"
        case .pensionAccount: return "养老保险个人账户"
        case .privatePension: return "个人养老金"
        case .enterpriseAnnuity: return "企业年金"
        case .credit: return "信用卡"
        case .consumerCredit: return "花呗 / 白条"
        case .mortgage: return "房贷（商贷）"
        case .fundLoan: return "房贷（公积金贷款）"
        case .carLoan: return "车贷"
        case .loan: return "借入 / 贷款"
        case .otherLiability: return "其他负债"
        }
    }

    var isLiability: Bool {
        switch self {
        case .credit, .consumerCredit, .mortgage, .fundLoan, .carLoan, .loan, .otherLiability: return true
        default: return false
        }
    }

    /// 有额度与还款日
    var hasCreditLimit: Bool { self == .credit || self == .consumerCredit }

    /// 公积金与社保类（资产页单独分组，可设每月缴存，「可支配资产」中不含）
    var isSocialSecurity: Bool { Self.socialTypes.contains(self) }

    /// 分期贷款：可设还款日
    var isInstallmentLoan: Bool { self == .mortgage || self == .fundLoan || self == .carLoan || self == .loan }

    /// 新建账户时「计入净资产」的默认值：养老金类到退休才能领取，默认不计入
    var defaultIncludeInNetWorth: Bool {
        switch self {
        case .pensionAccount, .privatePension, .enterpriseAnnuity: return false
        default: return true
        }
    }

    static let socialTypes: [AccountType] = [.housingFund, .medicalAccount, .pensionAccount, .privatePension, .enterpriseAnnuity]
    var defaultIcon: String {
        switch self {
        case .cash: return "banknote.fill"
        case .debit: return "building.columns.fill"
        case .alipay: return "a.circle.fill"
        case .wechat: return "message.fill"
        case .investment: return "chart.line.uptrend.xyaxis"
        case .receivable: return "person.crop.circle.badge.clock"
        case .otherAsset: return "archivebox.fill"
        case .housingFund: return "building.columns.circle.fill"
        case .medicalAccount: return "cross.case.fill"
        case .pensionAccount: return "shield.lefthalf.filled"
        case .privatePension: return "leaf.fill"
        case .enterpriseAnnuity: return "building.2.fill"
        case .credit: return "creditcard.fill"
        case .consumerCredit: return "cart.badge.clock"
        case .mortgage: return "house.fill"
        case .fundLoan: return "house.and.flag.fill"
        case .carLoan: return "car.fill"
        case .loan: return "house.circle.fill"
        case .otherLiability: return "exclamationmark.circle.fill"
        }
    }

    var defaultColor: String {
        switch self {
        case .cash: return "#FF9500"
        case .debit: return "#E03C31"
        case .alipay: return "#1677FF"
        case .wechat: return "#07C160"
        case .investment: return "#AF52DE"
        case .receivable: return "#30B0C7"
        case .otherAsset: return "#8E8E93"
        case .housingFund: return "#E8A33D"
        case .medicalAccount: return "#FF6B6B"
        case .pensionAccount: return "#5856D6"
        case .privatePension: return "#2FA46C"
        case .enterpriseAnnuity: return "#0A84FF"
        case .credit: return "#C8102E"
        case .consumerCredit: return "#00A3FF"
        case .mortgage: return "#A2845E"
        case .fundLoan: return "#C69C6D"
        case .carLoan: return "#7D6B5D"
        case .loan: return "#A2845E"
        case .otherLiability: return "#636366"
        }
    }

    static let assetTypes: [AccountType] = allCases.filter { !$0.isLiability }
    static let liabilityTypes: [AccountType] = allCases.filter { $0.isLiability }

    /// 根据旧版账户文字猜测类型
    static func guess(from name: String) -> AccountType {
        if name.contains("信用卡") { return .credit }
        if ["花呗", "白条", "月付", "分期"].contains(where: { name.contains($0) }) { return .consumerCredit }
        if name.contains("公积金贷") { return .fundLoan }
        if name.contains("房贷") || name.contains("商贷") { return .mortgage }
        if name.contains("车贷") { return .carLoan }
        if ["贷款", "借入"].contains(where: { name.contains($0) }) { return .loan }
        if name.contains("公积金") { return .housingFund }
        if name.contains("医保") { return .medicalAccount }
        if name.contains("个人养老金") { return .privatePension }
        if name.contains("年金") { return .enterpriseAnnuity }
        if name.contains("养老") || name.contains("社保") { return .pensionAccount }
        if ["借出", "借给", "应收"].contains(where: { name.contains($0) }) { return .receivable }
        if name.contains("支付宝") || name.contains("余额宝") { return .alipay }
        if name.contains("微信") || name.contains("零钱") { return .wechat }
        if ["储蓄卡", "银行卡", "借记卡", "银行"].contains(where: { name.contains($0) }) { return .debit }
        if name.contains("现金") { return .cash }
        if ["基金", "股票", "理财", "投资"].contains(where: { name.contains($0) }) { return .investment }
        return .otherAsset
    }
}

@Model
final class LedgerAccount {
    var id: UUID = UUID()
    var name: String = ""
    var typeRaw: String = AccountType.cash.rawValue
    /// 初始余额（负债类为负数，表示欠款）
    var initialBalance: Double = 0
    var creditLimit: Double = 0
    /// 账单日 / 还款日（1–28，0 表示未设置）
    var billingDay: Int = 0
    var repaymentDay: Int = 0
    var icon: String = ""
    var colorHex: String = "#007AFF"
    var note: String = ""
    var includeInNetWorth: Bool = true
    var isArchived: Bool = false
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \LedgerRecord.accountRef)
    var records: [LedgerRecord]? = []
    @Relationship(deleteRule: .nullify, inverse: \LedgerRecord.toAccount)
    var incomingTransfers: [LedgerRecord]? = []

    init(name: String, type: AccountType, initialBalance: Double = 0, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.typeRaw = type.rawValue
        self.initialBalance = initialBalance
        self.icon = type.defaultIcon
        self.colorHex = type.defaultColor
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    var type: AccountType {
        get { AccountType(rawValue: typeRaw) ?? .otherAsset }
        set { typeRaw = newValue.rawValue }
    }

    var color: Color { Color(hex: colorHex) }
    var iconName: String { icon.isEmpty ? type.defaultIcon : icon }

    /// 与该账户相关的全部记录（含转入）
    var allEntries: [LedgerRecord] {
        var seen = Set<UUID>()
        var list: [LedgerRecord] = []
        for r in (records ?? []) + (incomingTransfers ?? []) where seen.insert(r.id).inserted {
            list.append(r)
        }
        return list
    }

    /// 余额 = 初始余额 + 收入 − 支出 ± 转账 + 校准
    func balance(asOf date: Date? = nil) -> Double {
        var total = initialBalance
        for r in allEntries {
            if let date, r.date > date { continue }
            total += r.effect(on: self)
        }
        return (total * 100).rounded() / 100
    }

    /// 负债账户的欠款（正数）
    var debt: Double { max(0, -balance()) }

    /// 距下一个还款日的天数
    func daysUntilRepayment(from now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard repaymentDay > 0 else { return nil }
        let today = calendar.startOfDay(for: now)
        for offset in 0..<3 {
            guard let month = calendar.date(byAdding: .month, value: offset, to: today) else { continue }
            var c = calendar.dateComponents([.year, .month], from: month)
            let range = calendar.range(of: .day, in: .month, for: month) ?? 1..<29
            c.day = min(repaymentDay, range.count)
            if let d = calendar.date(from: c), d >= today {
                return calendar.dateComponents([.day], from: today, to: d).day
            }
        }
        return nil
    }
}

/// 默认分类
struct DefaultCategory {
    let name: String
    let icon: String
    let color: String
    let kind: RecordKind

    static let all: [DefaultCategory] = [
        .init(name: "餐饮", icon: "fork.knife", color: "#FF9500", kind: .expense),
        .init(name: "交通", icon: "car.fill", color: "#007AFF", kind: .expense),
        .init(name: "购物", icon: "bag.fill", color: "#FF2D55", kind: .expense),
        .init(name: "娱乐", icon: "gamecontroller.fill", color: "#AF52DE", kind: .expense),
        .init(name: "生活缴费", icon: "bolt.fill", color: "#FFB800", kind: .expense),
        .init(name: "居住", icon: "house.fill", color: "#A2845E", kind: .expense),
        .init(name: "通讯", icon: "phone.fill", color: "#34C759", kind: .expense),
        .init(name: "医疗", icon: "cross.case.fill", color: "#FF3B30", kind: .expense),
        .init(name: "教育", icon: "book.fill", color: "#5856D6", kind: .expense),
        .init(name: "旅行", icon: "airplane", color: "#30B0C7", kind: .expense),
        .init(name: "人情", icon: "gift.fill", color: "#FF6482", kind: .expense),
        .init(name: "其他", icon: "ellipsis.circle.fill", color: "#8E8E93", kind: .expense),
        .init(name: "工资", icon: "banknote.fill", color: "#34C759", kind: .income),
        .init(name: "奖金", icon: "star.fill", color: "#FF9F0A", kind: .income),
        .init(name: "理财", icon: "chart.line.uptrend.xyaxis", color: "#5AC8FA", kind: .income),
        .init(name: "红包", icon: "envelope.fill", color: "#FF3B30", kind: .income),
        .init(name: "退款", icon: "arrow.uturn.backward.circle.fill", color: "#64D2FF", kind: .income),
        .init(name: "其他收入", icon: "plus.circle.fill", color: "#8E8E93", kind: .income),
    ]
}
