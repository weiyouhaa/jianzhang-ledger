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
                     note: String, merchant: String, date: Date, source: String) throws -> LedgerRecord {
        let context = DataStore.shared.mainContext
        let category = categoryID.flatMap { DataStore.category(id: $0, in: context) }
            ?? DataStore.category(named: categoryName, kind: kind, in: context)
        let account = UserDefaults.standard.string(forKey: SettingsKey.defaultAccount) ?? ""
        let record = LedgerRecord(amount: (amount * 100).rounded() / 100, kind: kind, category: category,
                                  note: note, merchant: merchant, account: account, date: date, source: source)
        context.insert(record)
        do {
            try context.save()
        } catch {
            throw LedgerIntentError.saveFailed
        }
        return record
    }

    static func summary(of record: LedgerRecord) -> String {
        var parts = ["\(record.kind.title) \(Money.format(record.amount))", record.categoryName]
        if !record.merchant.isEmpty { parts.append(record.merchant) }
        if !record.note.isEmpty { parts.append(record.note) }
        parts.append(DateText.monthDayTime.string(from: record.date))
        return parts.joined(separator: " · ")
    }
}
