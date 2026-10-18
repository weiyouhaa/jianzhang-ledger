import Foundation
import SwiftData
import SwiftUI

/// 收支类型（以字符串存储，便于 #Predicate 过滤）
enum RecordKind: String, CaseIterable, Identifiable, Codable {
    case expense
    case income

    var id: String { rawValue }
    var title: String { self == .expense ? "支出" : "收入" }
    var sign: String { self == .expense ? "-" : "+" }
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

    /// 带符号金额：收入为正，支出为负
    var signedAmount: Double { kind == .income ? amount : -amount }

    var categoryName: String { category?.name ?? "未分类" }
    var categoryIcon: String { category?.icon ?? "questionmark.circle.fill" }
    var categoryColor: Color { category?.color ?? .gray }

    /// 列表中显示的标题：备注 > 商户 > 分类名
    var displayTitle: String {
        if !note.isEmpty { return note }
        if !merchant.isEmpty { return merchant }
        return categoryName
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
