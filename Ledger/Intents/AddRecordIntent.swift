import AppIntents
import Foundation

/// 「记一笔」：通过快捷指令 / Siri 直接记账
struct AddRecordIntent: AppIntent {
    static var title: LocalizedStringResource = "记一笔"
    static var description = IntentDescription("快速记录一笔支出或收入。")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "金额")
    var amount: Double

    @Parameter(title: "收支类型", default: .expense)
    var kind: RecordKindAppEnum

    @Parameter(title: "分类", description: "留空则记入「其他」")
    var category: CategoryEntity?

    @Parameter(title: "备注")
    var note: String?

    @Parameter(title: "账户", description: "留空则使用默认账户")
    var account: AccountEntity?

    @Parameter(title: "时间", description: "留空则为当前时间")
    var date: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("记一笔\(\.$kind) \(\.$amount)") {
            \.$category
            \.$account
            \.$note
            \.$date
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        guard amount > 0, amount < 100_000_000 else { throw LedgerIntentError.invalidAmount }
        // 选择了分类时以分类的收支类型为准，避免「工资」被记成支出
        let recordKind: RecordKind = category.flatMap { RecordKind(rawValue: $0.kindRaw) } ?? kind.kind
        let record = try IntentRecorder.save(
            amount: amount,
            kind: recordKind,
            categoryID: category?.id,
            categoryName: nil,
            note: note ?? "",
            merchant: "",
            date: date ?? Date(),
            source: "shortcut",
            accountID: account?.id
        )
        let summary = "已记账：" + IntentRecorder.summary(of: record)
        return .result(value: record.amount, dialog: IntentDialog("\(summary)"))
    }
}

/// 「本月收支」：用 Siri 问一句就知道本月花了多少
struct MonthSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "本月收支"
    static var description = IntentDescription("查看本月支出、收入、结余与预算剩余。")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let cal = DateText.calendar
        let start = cal.startOfMonth(for: Date())
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? Date()
        let records = DataStore.records(from: start, to: end, in: DataStore.shared.mainContext)
        let includeRepayment = RepaymentSetting.includeInExpense(UserDefaults.standard)
        let expense = records.filter { $0.countsAsExpense(includeRepayment: includeRepayment) }.reduce(0) { $0 + $1.amount }
        let income = records.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }
        var text = "本月支出 \(Money.format(expense))，收入 \(Money.format(income))，结余 \(Money.format(income - expense))"
        let budget = UserDefaults.standard.double(forKey: SettingsKey.monthlyBudget)
        if budget > 0 {
            text += "；预算剩余 \(Money.format(budget - expense))"
        }
        return .result(value: expense, dialog: IntentDialog("\(text)"))
    }
}
