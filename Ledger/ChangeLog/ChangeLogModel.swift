import Foundation
import SwiftData

/// 变动来源
enum ChangeSource: String, CaseIterable, Identifiable, Codable {
    case app, shortcut, importing = "import", recurring, restore, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .app: return "App"
        case .shortcut: return "快捷指令"
        case .importing: return "导入"
        case .recurring: return "周期账单"
        case .restore: return "恢复备份"
        case .system: return "系统"
        }
    }
}

/// 操作
enum ChangeAction: String, CaseIterable, Identifiable, Codable {
    case create, update, delete, batch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .create: return "新增"
        case .update: return "修改"
        case .delete: return "删除"
        case .batch: return "批量"
        }
    }
}

/// 变动对象类型
enum ChangeEntity: String, CaseIterable, Identifiable, Codable {
    case record, account, category, budget, rule, recurring, settings, security, backup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .record: return "流水"
        case .account: return "账户"
        case .category: return "分类"
        case .budget: return "预算"
        case .rule: return "规则"
        case .recurring: return "周期"
        case .settings: return "设置"
        case .security: return "安全"
        case .backup: return "备份"
        }
    }
    var icon: String {
        switch self {
        case .record: return "list.bullet.rectangle"
        case .account: return "creditcard"
        case .category: return "square.grid.2x2"
        case .budget: return "target"
        case .rule: return "wand.and.stars"
        case .recurring: return "arrow.triangle.2.circlepath"
        case .settings: return "gearshape"
        case .security: return "lock.shield"
        case .backup: return "externaldrive"
        }
    }
}

/// 字段级变动（显示用字符串）
struct FieldDiff: Codable, Hashable {
    var field: String
    var old: String?
    var new: String?
}

/// 批量条目里的单项
struct ChildChange: Codable, Hashable {
    var action: String
    var entity: String
    var summary: String
    var diffs: [FieldDiff]? = nil
}

/// 变动日志（只存在真实库；防窥库的 Schema 里没有这个模型）。
/// CloudKit 兼容：所有属性有默认值，无唯一约束，无关系。
@Model
final class ChangeLogEntry {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var sourceRaw: String = ChangeSource.app.rawValue
    var actionRaw: String = ChangeAction.update.rawValue
    var entityTypeRaw: String = ChangeEntity.record.rawValue
    var entityID: String = ""
    var summary: String = ""
    /// [FieldDiff] 的 JSON
    var diffsJSON: String = ""
    /// 批量条目：[ChildChange] 的 JSON（最多保存 ChangeLogger.maxChildren 项）
    var childrenJSON: String = ""
    /// 批量条目包含的总项数
    var childCount: Int = 0

    init(timestamp: Date = Date(), source: ChangeSource, action: ChangeAction, entity: ChangeEntity,
         entityID: String = "", summary: String, diffs: [FieldDiff] = [], children: [ChildChange] = [], childCount: Int = 0) {
        self.id = UUID()
        self.timestamp = timestamp
        self.sourceRaw = source.rawValue
        self.actionRaw = action.rawValue
        self.entityTypeRaw = entity.rawValue
        self.entityID = entityID
        self.summary = summary
        self.diffsJSON = diffs.isEmpty ? "" : ChangeLogCoding.encode(diffs)
        self.childrenJSON = children.isEmpty ? "" : ChangeLogCoding.encode(children)
        self.childCount = childCount
    }

    var source: ChangeSource { ChangeSource(rawValue: sourceRaw) ?? .app }
    var action: ChangeAction { ChangeAction(rawValue: actionRaw) ?? .update }
    var entity: ChangeEntity { ChangeEntity(rawValue: entityTypeRaw) ?? .settings }
    var diffs: [FieldDiff] { ChangeLogCoding.decode(diffsJSON) ?? [] }
    var children: [ChildChange] { ChangeLogCoding.decode(childrenJSON) ?? [] }

    /// 搜索用文本
    var searchText: String { summary + " " + diffsJSON + " " + childrenJSON }

    var dto: LedgerBackup.ChangeLogDTO {
        .init(id: id, timestamp: timestamp, source: sourceRaw, action: actionRaw, entityType: entityTypeRaw,
              entityID: entityID, summary: summary, diffs: diffsJSON.isEmpty ? nil : diffsJSON,
              children: childrenJSON.isEmpty ? nil : childrenJSON, childCount: childCount > 0 ? childCount : nil)
    }

    convenience init(dto: LedgerBackup.ChangeLogDTO) {
        self.init(timestamp: dto.timestamp, source: ChangeSource(rawValue: dto.source) ?? .app,
                  action: ChangeAction(rawValue: dto.action) ?? .update,
                  entity: ChangeEntity(rawValue: dto.entityType) ?? .settings,
                  entityID: dto.entityID, summary: dto.summary, childCount: dto.childCount ?? 0)
        self.id = dto.id
        self.sourceRaw = dto.source
        self.actionRaw = dto.action
        self.entityTypeRaw = dto.entityType
        self.diffsJSON = dto.diffs ?? ""
        self.childrenJSON = dto.children ?? ""
    }
}

enum ChangeLogCoding {
    static func encode<T: Encodable>(_ v: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        guard let d = try? e.encode(v) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }
    static func decode<T: Decodable>(_ s: String) -> T? {
        guard !s.isEmpty, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}
