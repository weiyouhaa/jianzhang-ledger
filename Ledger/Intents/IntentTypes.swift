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
        let category = categoryID.flatMap { DataStore.category(id: $0, in: context) }
            ?? DataStore.category(named: categoryName, kind: kind, in: context)
        // 账户：指定 > 识图线索匹配 > 默认账户
        let defaultName = UserDefaults.standard.string(forKey: SettingsKey.defaultAccount) ?? ""
        let account: LedgerAccount? = accountID.flatMap { DataStore.account(id: $0, in: context) }
            ?? DataStore.account(matching: accountHint, in: context)
            ?? DataStore.account(named: defaultName, in: context)
        let record = LedgerRecord(amount: (amount * 100).rounded() / 100, kind: kind, category: category,
                                  note: note, merchant: merchant, account: account?.name ?? "", date: date, source: source)
        record.accountRef = account
        context.insert(record)
        do {
            try context.save()
        } catch {
            throw LedgerIntentError.saveFailed
        }
        return record
    }

    /// 重复判断：金额相同、商户相同、时间相差 2 分钟以内（重复识别同一张截图时不重复记账）
    @MainActor
    static func isDuplicate(amount: Double, merchant: String, date: Date) -> Bool {
        let context = DataStore.shared.mainContext
        let start = date.addingTimeInterval(-120), end = date.addingTimeInterval(120)
        let descriptor = FetchDescriptor<LedgerRecord>(predicate: #Predicate<LedgerRecord> { $0.date >= start && $0.date <= end })
        let list = (try? context.fetch(descriptor)) ?? []
        let rounded = (amount * 100).rounded() / 100
        let m = merchant.trimmingCharacters(in: .whitespaces)
        return list.contains { r in
            abs(r.amount - rounded) < 0.005 && r.merchant.trimmingCharacters(in: .whitespaces) == m
        }
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
