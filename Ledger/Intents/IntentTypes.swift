import AppIntents
import Foundation
import SwiftData

/// 快捷指令中的「收支类型」
enum RecordKindAppEnum: String, AppEnum {
    case expense
    case income

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "收支类型"
    static var caseDisplayRepresentations: [RecordKindAppEnum: DisplayRepresentation] = [
        .expense: "支出",
        .income: "收入",
    ]

    var kind: RecordKind { RecordKind(rawValue: rawValue) ?? .expense }
}

/// 快捷指令中的「分类」（来自用户自定义分类，动态查询）
struct CategoryEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "分类"
    static var defaultQuery = CategoryQuery()

    let id: UUID
    let name: String
    let icon: String
    let kindRaw: String

    var kindTitle: String { kindRaw == RecordKind.income.rawValue ? "收入" : "支出" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(kindTitle)",
            image: DisplayRepresentation.Image(systemName: icon)
        )
    }

    init(id: UUID, name: String, icon: String, kindRaw: String) {
        self.id = id
        self.name = name
        self.icon = icon
        self.kindRaw = kindRaw
    }

    init(_ category: LedgerCategory) {
        self.init(id: category.id, name: category.name, icon: category.icon, kindRaw: category.kindRaw)
    }
}

struct CategoryQuery: EntityStringQuery {
    private func allCategories() -> [CategoryEntity] {
        // 只读查询使用独立上下文，不依赖主线程
        let context = ModelContext(DataStore.shared)
        let descriptor = FetchDescriptor<LedgerCategory>(sortBy: [
            SortDescriptor(\LedgerCategory.kindRaw),
            SortDescriptor(\LedgerCategory.sortOrder),
        ])
        let list = (try? context.fetch(descriptor)) ?? []
        return list.map { CategoryEntity($0) }
    }

    func entities(for identifiers: [UUID]) async throws -> [CategoryEntity] {
        allCategories().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [CategoryEntity] {
        let q = string.trimmingCharacters(in: .whitespaces)
        return allCategories().filter { $0.name.contains(q) || q.contains($0.name) }
    }

    func suggestedEntities() async throws -> [CategoryEntity] {
        allCategories()
    }
}

/// 快捷指令中的「账户」
struct AccountEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "账户"
    static var defaultQuery = AccountQuery()

    let id: UUID
    let name: String
    let icon: String
    let typeTitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(typeTitle)",
            image: DisplayRepresentation.Image(systemName: icon)
        )
    }

    init(id: UUID, name: String, icon: String, typeTitle: String) {
        self.id = id
        self.name = name
        self.icon = icon
        self.typeTitle = typeTitle
    }

    init(_ account: LedgerAccount) {
        self.init(id: account.id, name: account.name, icon: account.iconName, typeTitle: account.type.title)
    }
}

struct AccountQuery: EntityStringQuery {
    private func allAccounts() -> [AccountEntity] {
        let context = ModelContext(DataStore.shared)
        let descriptor = FetchDescriptor<LedgerAccount>(sortBy: [SortDescriptor(\LedgerAccount.sortOrder)])
        let list = (try? context.fetch(descriptor)) ?? []
        return list.filter { !$0.isArchived }.map { AccountEntity($0) }
    }

    func entities(for identifiers: [UUID]) async throws -> [AccountEntity] {
        allAccounts().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [AccountEntity] {
        let q = string.trimmingCharacters(in: .whitespaces)
        return allAccounts().filter { $0.name.contains(q) || q.contains($0.name) }
    }

    func suggestedEntities() async throws -> [AccountEntity] {
        allAccounts()
    }
}

enum LedgerIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unreadableImage
    case noAmount(String)
    case invalidAmount
    case saveFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unreadableImage:
            return "无法读取这张图片，请传入截图或照片。"
        case .noAmount(let preview):
            return "没有识别到金额。识别到的文字：\(preview)"
        case .invalidAmount:
            return "金额需要大于 0。"
        case .saveFailed:
            return "保存失败，请稍后重试。"
        }
    }
}

/// 记账写入（App Intents 与 App 共用同一个 ModelContainer 的 mainContext）
enum IntentRecorder {
    @MainActor
    static func save(amount: Double, kind: RecordKind, categoryID: UUID?, categoryName: String?,
                     note: String, merchant: String, date: Date, source: String,
                     accountID: UUID? = nil, accountHint: AccountHint? = nil) throws -> LedgerRecord {
        let context = DataStore.shared.mainContext
        // 分类：指定 > 记账规则（分类记忆）> 关键词猜测
        let hit = categoryID == nil ? RuleStore.match(merchant: merchant, text: note, kind: kind, in: context) : nil
        let category = categoryID.flatMap { DataStore.category(id: $0, in: context) }
            ?? hit?.category
            ?? DataStore.category(named: categoryName, kind: kind, in: context)
        // 账户：指定 > 识图线索匹配 > 规则账户 > 该分类上次使用的账户 > 默认账户
        let account: LedgerAccount? = accountID.flatMap { DataStore.account(id: $0, in: context) }
            ?? DataStore.account(matching: accountHint, in: context)
            ?? hit?.account
            ?? RuleStore.lastAccount(for: category, in: context)
            ?? RuleStore.defaultAccount(in: context)
        let record = LedgerRecord(amount: (amount * 100).rounded() / 100, kind: kind, category: category,
                                  note: note, merchant: merchant, account: account?.name ?? "", date: date, source: source)
        record.accountRef = account
        context.insert(record)
        RuleStore.rememberAccount(account, for: category)
        do {
            try ChangeLogger.with(.shortcut) { try context.save() }
        } catch {
            throw LedgerIntentError.saveFailed
        }
        BudgetMonitor.check(in: context)
        return record
    }

    /// 识图用词表：真实账本的分类与未归档账户名（提供给 Apple 智能）
    @MainActor
    static func ocrVocabulary() -> OCRVocabulary {
        let context = DataStore.shared.mainContext
        let cats = (try? context.fetch(FetchDescriptor<LedgerCategory>(sortBy: [SortDescriptor(\LedgerCategory.sortOrder)]))) ?? []
        let accounts = DataStore.accounts(in: context)
        let learned = CardTailMemory.all()
        return OCRVocabulary(expenseCategories: cats.filter { $0.kind == .expense }.map(\.name),
                             incomeCategories: cats.filter { $0.kind == .income }.map(\.name),
                             accounts: accounts.map(\.name),
                             accountDetails: accounts.map { a in
                                 var parts = [a.type.title]
                                 if let bank = CardTailMemory.bankName(of: a) { parts.append(bank) }
                                 let tails = CardTailMemory.tails(of: a, learned: learned)
                                 if !tails.isEmpty { parts.append("尾号" + tails.sorted().joined(separator: "/")) }
                                 return "\(a.name)〔\(parts.joined(separator: "·"))〕"
                             })
    }

    /// 按尾号 > 同银行同卡种 > 模型账户名 > 兜底 匹配账户；日志只记匹配方式
    @MainActor
    static func resolveAccount(hint: AccountHint?, modelName: String?, role: AccountResolver.Role,
                               excluding: UUID? = nil, label: String) -> LedgerAccount? {
        let r = DataStore.accountResolution(matching: hint, modelName: modelName, role: role, excluding: excluding,
                                            in: DataStore.shared.mainContext)
        RunLog.shared.log(.info, "account-resolve", "\(label)：\(r.via.title)")
        return r.account
    }

    /// Apple 智能选出的账户名 → 账户 ID
    @MainActor
    static func accountID(named name: String?) -> UUID? {
        guard let name, !name.isEmpty else { return nil }
        return DataStore.accounts(in: DataStore.shared.mainContext).first(where: { $0.name == name })?.id
    }

    /// 识图得到的信用卡还款：被还款的负债账户（线索匹配不到时，只有一张信用卡就用它）
    @MainActor
    static func repaymentCard(name: String? = nil, hint: AccountHint?) -> LedgerAccount? {
        resolveAccount(hint: hint ?? AccountHint(type: "credit"), modelName: name, role: .card, label: "还款信用卡")
    }

    /// 还款的付款账户：指定 > 识图线索（非负债）> 默认账户（非负债）> 第一张储蓄卡
    @MainActor
    static func repaymentPayer(accountID: UUID?, hint: AccountHint?, modelName: String? = nil,
                               excluding cardID: UUID) -> LedgerAccount? {
        let context = DataStore.shared.mainContext
        let resolved = accountID == nil
            ? resolveAccount(hint: hint, modelName: modelName, role: .payer, excluding: cardID, label: "付款账户") : nil
        if accountID == nil && resolved == nil { RunLog.shared.log(.info, "account-resolve", "付款账户：默认账户") }
        let candidates: [LedgerAccount?] = [
            accountID.flatMap { DataStore.account(id: $0, in: context) },
            resolved,
            RuleStore.defaultAccount(in: context),
            DataStore.accounts(in: context).first(where: { $0.type == .debit }),
        ]
        return candidates.compactMap { $0 }.first(where: { !$0.type.isLiability && $0.id != cardID })
    }

    /// 保存一笔信用卡还款（付款账户 → 信用卡的转账，不计入收支统计，除非开启「信用卡还款计入支出」）
    @MainActor
    @discardableResult
    static func saveRepayment(amount: Double, fromID: UUID, toID: UUID, note: String, date: Date, source: String) throws -> LedgerRecord {
        let context = DataStore.shared.mainContext
        let from = DataStore.account(id: fromID, in: context)
        let record = LedgerRecord(amount: (amount * 100).rounded() / 100, kind: .transfer, category: nil,
                                  note: note, merchant: "", account: from?.name ?? "", date: date, source: source)
        record.accountRef = from
        record.toAccount = DataStore.account(id: toID, in: context)
        context.insert(record)
        do {
            try ChangeLogger.with(.shortcut) { try context.save() }
        } catch {
            throw LedgerIntentError.saveFailed
        }
        return record
    }

    /// 审核预览：按与 save 相同的优先级解析分类和账户（不累计规则命中次数）
    @MainActor
    static func resolve(kind: RecordKind, merchant: String, note: String, categoryID: UUID?, categoryName: String?,
                        accountID: UUID?, accountHint: AccountHint?) -> (category: LedgerCategory?, account: LedgerAccount?) {
        let context = DataStore.shared.mainContext
        let hit = categoryID == nil ? RuleStore.match(merchant: merchant, text: note, kind: kind, in: context, countHit: false) : nil
        let category = categoryID.flatMap { DataStore.category(id: $0, in: context) }
            ?? hit?.category
            ?? DataStore.category(named: categoryName, kind: kind, in: context)
        let account: LedgerAccount? = accountID.flatMap { DataStore.account(id: $0, in: context) }
            ?? DataStore.account(matching: accountHint, in: context)
            ?? hit?.account
            ?? RuleStore.lastAccount(for: category, in: context)
            ?? RuleStore.defaultAccount(in: context)
        return (category, account)
    }

    /// 预览用：规则命中时显示规则分类
    @MainActor
    static func previewCategoryName(kind: RecordKind, merchant: String, guessed: String?) -> String {
        let context = DataStore.shared.mainContext
        if let c = RuleStore.match(merchant: merchant, kind: kind, in: context, countHit: false)?.category { return c.name }
        return guessed ?? (kind == .income ? "其他收入" : "其他")
    }

    /// 重复判断：金额相同，且（同商户 2 分钟内，或同账户 / 商户相近 5 分钟内）。
    /// 同一笔交易的银行推送、支付助手、云闪付详情截图只记一次
    @MainActor
    static func isDuplicate(amount: Double, merchant: String, date: Date, accountID: UUID? = nil) -> Bool {
        let context = DataStore.shared.mainContext
        let start = date.addingTimeInterval(-DuplicateMatcher.window), end = date.addingTimeInterval(DuplicateMatcher.window)
        let descriptor = FetchDescriptor<LedgerRecord>(predicate: #Predicate<LedgerRecord> { $0.date >= start && $0.date <= end })
        let list = (try? context.fetch(descriptor)) ?? []
        let entry = DuplicateMatcher.Entry(amount: (amount * 100).rounded() / 100, merchant: merchant, date: date,
                                           account: accountID?.uuidString)
        return DuplicateMatcher.isDuplicate(entry, among: list.map {
            DuplicateMatcher.Entry(amount: $0.amount, merchant: $0.merchant, date: $0.date, account: $0.accountRef?.id.uuidString)
        })
    }

    static func summary(of record: LedgerRecord) -> String {
        var parts = ["\(record.kind.title) \(Money.format(record.amount))", record.categoryName]
        if !record.merchant.isEmpty { parts.append(record.merchant) }
        if !record.note.isEmpty { parts.append(record.note) }
        if let a = record.accountRef { parts.append(a.name) }
        parts.append(DateText.monthDayTime.string(from: record.date))
        return parts.joined(separator: " · ")
    }
}

extension AccountResolver.Via {
    var title: String {
        switch self {
        case .tail: return "按尾号"
        case .bank: return "按银行 + 卡种"
        case .name: return "按 Apple 智能账户名"
        case .fallback: return "兜底"
        case .none: return "未匹配"
        }
    }
}

/// 记住「卡号尾号 → 账户」：用户保存识图记录时学习（仅真实模式；防窥模式不读不写）
enum CardTailMemory {
    static let key = "learn.cardTails"

    static func all() -> [String: String] {
        guard !ModeDefaults.isDecoyMode else { return [:] }
        return UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func learn(tail: String?, accountID: UUID?) {
        guard !ModeDefaults.isDecoyMode, let accountID, let tail = AccountResolver.normalizeTail(tail) else { return }
        var map = all()
        guard map[tail] != accountID.uuidString else { return }
        map[tail] = accountID.uuidString
        if map.count > 60 { map = Dictionary(map.suffix(60), uniquingKeysWith: { a, _ in a }) }
        UserDefaults.standard.set(map, forKey: key)
        RunLog.shared.log(.info, "learn-tail", "记住了 1 个卡号尾号")
    }

    static func tails(of a: LedgerAccount, learned: [String: String]) -> Set<String> {
        var s = Set(learned.filter { $0.value == a.id.uuidString }.map(\.key))
        if a.cardTail.count == 4 { s.insert(a.cardTail) }
        return s
    }

    /// 账户名 / 备注里的银行（「储蓄卡-招商银行」「招行信用卡」→ 招商银行 / 招行）
    static func bankName(of a: LedgerAccount) -> String? {
        let text = EnglishBankTerms.localize(a.name + " " + a.note)
        if let b = AccountHintParser.parse(text: text)?.bankName { return b }
        for (_, zh) in EnglishBankTerms.banks {
            if AccountHint.aliases(forBank: zh).dropFirst().contains(where: { text.contains($0) }) { return zh }
        }
        return nil
    }
}
