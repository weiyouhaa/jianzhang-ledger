import AppIntents
import Foundation
import SwiftData
import SwiftUI

// MARK: - 审核方式

/// 「识图记账」的审核方式
enum ReviewModeAppEnum: String, AppEnum {
    case saveDirectly
    case review

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "审核方式"
    static var caseDisplayRepresentations: [ReviewModeAppEnum: DisplayRepresentation] = [
        .saveDirectly: DisplayRepresentation(title: "直接保存", subtitle: "识别后立即记账",
                                             image: .init(systemName: "bolt.fill")),
        .review: DisplayRepresentation(title: "弹窗审核", subtitle: "先列出识别结果，可增删改后再保存",
                                       image: .init(systemName: "checklist")),
    ]
}

// MARK: - 通用选项（iOS 17 / 18 用 requestDisambiguation 展示动态选项）

/// 审核流程中的一个可选项。标题是动态生成的（例如「全部保存（3 笔）」），所以用实体而不是 AppEnum。
struct ReviewChoiceEntity: AppEntity, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "选项"
    static var defaultQuery = ReviewChoiceQuery()

    let id: String
    let title: String
    let subtitle: String
    let icon: String

    var displayRepresentation: DisplayRepresentation {
        let sub: LocalizedStringResource? = subtitle.isEmpty ? nil : LocalizedStringResource(stringLiteral: subtitle)
        let image: DisplayRepresentation.Image? = icon.isEmpty ? nil : DisplayRepresentation.Image(systemName: icon)
        return DisplayRepresentation(title: LocalizedStringResource(stringLiteral: title), subtitle: sub, image: image)
    }
}

/// 当前这一步提供的选项（仅在一次 perform 期间有效，进程内存）
@MainActor
enum ReviewChoiceRegistry {
    static var current: [ReviewChoiceEntity] = []
}

struct ReviewChoiceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ReviewChoiceEntity] {
        await MainActor.run { ReviewChoiceRegistry.current.filter { identifiers.contains($0.id) } }
    }

    func suggestedEntities() async throws -> [ReviewChoiceEntity] {
        await MainActor.run { ReviewChoiceRegistry.current }
    }
}

// MARK: - 待审核的一笔

struct ReviewItem: Identifiable {
    let id = UUID()
    var amount: Double
    var kind: RecordKind
    var categoryID: UUID?
    var merchant: String
    var note: String
    var accountID: UUID?
    /// 信用卡还款（kind == .transfer）：被还款的信用卡；accountID 为付款账户
    var toAccountID: UUID? = nil
    var date: Date
    var dateRecognized: Bool
    var isDuplicate = false
    /// 重复项默认跳过；用户可改为仍然保存
    var saveDuplicate = false
    /// 用户手动改过分类 / 账户：保存后更新分类记忆
    var categoryEdited = false
    var accountEdited = false
    var isManual = false
    /// 截图上的卡号尾号（保存时学习「尾号 → 账户」；不显示、不记日志）
    var accountTail: String? = nil
    var payerTail: String? = nil
    var cardTail: String? = nil

    /// 还款 / 转账必须两个账户都已选定
    var isComplete: Bool { kind != .transfer || (accountID != nil && toAccountID != nil) }
    var willSave: Bool { (!isDuplicate || saveDuplicate) && isComplete }
}

/// 快照视图用的一行（纯值，可在 SwiftUI 片段中渲染）
struct ReviewRow: Identifiable, Hashable {
    var id: Int { index }
    let index: Int
    let isIncome: Bool
    let amountText: String
    let categoryName: String
    let icon: String
    let colorHex: String
    let merchant: String
    let note: String
    let accountName: String
    let timeText: String
    let duplicate: DuplicateState
    let isManual: Bool

    enum DuplicateState: Hashable { case none, skip, saveAnyway }
}

@MainActor
enum ReviewFormatter {
    static func row(_ item: ReviewItem, index: Int, in context: ModelContext) -> ReviewRow {
        let category = item.categoryID.flatMap { DataStore.category(id: $0, in: context) }
        let account = item.accountID.flatMap { DataStore.account(id: $0, in: context) }
        let isTransfer = item.kind == .transfer
        let toAccount = isTransfer ? item.toAccountID.flatMap { DataStore.account(id: $0, in: context) } : nil
        // 还没选卡的还款也按「信用卡还款」显示
        let isRepay = isTransfer && (toAccount == nil || toAccount?.type.isLiability == true)
        return ReviewRow(
            index: index,
            isIncome: item.kind == .income,
            amountText: (item.kind == .income ? "+" : (isTransfer ? " " : "-")) + Money.format(item.amount),
            categoryName: isTransfer ? (isRepay ? "信用卡还款" : "转账") : (category?.name ?? (item.kind == .income ? "其他收入" : "其他")),
            icon: isTransfer ? (isRepay ? LedgerRecord.repaymentIcon : "arrow.left.arrow.right") : (category?.icon ?? "tag.fill"),
            colorHex: isTransfer ? "#30B0C7" : (category?.colorHex ?? "#8E8E93"),
            merchant: item.merchant,
            note: item.note,
            accountName: isTransfer
                ? "\(account?.name ?? "未选付款账户") → \(toAccount?.name ?? (isRepay ? "未选信用卡" : "未选账户"))"
                : (account?.name ?? "未指定账户"),
            timeText: item.dateRecognized || item.isManual ? DateText.monthDayTime.string(from: item.date) : "时间未识别（按现在）",
            duplicate: item.isDuplicate ? (item.saveDuplicate ? .saveAnyway : .skip) : .none,
            isManual: item.isManual
        )
    }

    /// 一行文字摘要（选项标题 / 对话框）
    static func line(_ row: ReviewRow) -> String {
        let kindText = row.categoryName == "信用卡还款" ? "还款" : (row.categoryName == "转账" ? "转账" : (row.isIncome ? "收入" : "支出"))
        var parts = ["\(kindText) \(row.amountText.dropFirst())", row.categoryName]
        if !row.merchant.isEmpty { parts.append(row.merchant) }
        parts.append(row.accountName)
        parts.append(row.timeText)
        var s = parts.joined(separator: " · ")
        switch row.duplicate {
        case .skip: s += "（已存在，跳过）"
        case .saveAnyway: s += "（已存在，仍保存）"
        case .none: break
        }
        return s
    }
}

// MARK: - 片段视图（快捷指令弹窗中显示）

struct ReviewSnippetView: View {
    let title: String
    let rows: [ReviewRow]
    var footnote: String? = nil
    var maxRows = 8
    /// 识别引擎（Apple 智能 / 规则），创建时取本次识图的结果
    var engineLine: String? = OCRRunInfo.engineLine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: "text.viewfinder")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !totalText.isEmpty {
                    Text(totalText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty {
                Text("没有待保存的记录。可以「添加一笔」，或取消。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            ForEach(rows.prefix(maxRows)) { row in
                ReviewRowView(row: row)
                if row.index != rows.prefix(maxRows).last?.index {
                    Divider().padding(.leading, 44)
                }
            }
            if rows.count > maxRows {
                Text("还有 \(rows.count - maxRows) 笔…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let engineLine, !rows.isEmpty || footnote != nil {
                Label(engineLine, systemImage: engineLine.contains("Apple 智能") && !engineLine.contains("已用规则") ? "sparkles" : "text.magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(14)
    }

    private var totalText: String {
        let saving = rows.filter { $0.duplicate != .skip }
        guard !rows.isEmpty else { return "" }
        let skipped = rows.count - saving.count
        return skipped > 0 ? "保存 \(saving.count) 笔 · 跳过 \(skipped) 笔" : "共 \(rows.count) 笔"
    }
}

struct ReviewRowView: View {
    let row: ReviewRow

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack(alignment: .topLeading) {
                Image(systemName: row.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color(hex: row.colorHex), in: Circle())
                Text("\(row.index)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Color.primary.opacity(0.75), in: Circle())
                    .offset(x: -4, y: -4)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.merchant.isEmpty ? row.categoryName : row.merchant)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if row.isManual {
                        Text("手动添加")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                    switch row.duplicate {
                    case .skip:
                        badge("已存在 · 跳过", .orange)
                    case .saveAnyway:
                        badge("已存在 · 仍保存", .purple)
                    case .none:
                        EmptyView()
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(row.amountText)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(row.isIncome ? Color.green : Color.primary)
                .strikethrough(row.duplicate == .skip, color: .secondary)
                .opacity(row.duplicate == .skip ? 0.5 : 1)
        }
    }

    private var detail: String {
        var parts: [String] = [row.categoryName == "信用卡还款" ? "还款" : (row.isIncome ? "收入" : "支出")]
        if !row.merchant.isEmpty { parts.append(row.categoryName) }
        parts.append(row.accountName)
        parts.append(row.timeText)
        if !row.note.isEmpty { parts.append(row.note) }
        return parts.joined(separator: " · ")
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - 截图演示：模拟快捷指令弹窗（仅 -UIScreenshotDemo reviewsnippet）

struct ReviewSnippetDemoView: View {
    static let rows: [ReviewRow] = [
        ReviewRow(index: 1, isIncome: false, amountText: "-¥35.00", categoryName: "餐饮", icon: "fork.knife", colorHex: "#FF9500",
                  merchant: "星巴克咖啡", note: "", accountName: "微信", timeText: "10月19日 12:18", duplicate: .none, isManual: false),
        ReviewRow(index: 2, isIncome: false, amountText: "-¥23.50", categoryName: "交通", icon: "car.fill", colorHex: "#0A84FF",
                  merchant: "滴滴出行", note: "打车去公司", accountName: "支付宝", timeText: "10月19日 08:45", duplicate: .none, isManual: false),
        ReviewRow(index: 3, isIncome: false, amountText: "-¥18.00", categoryName: "餐饮", icon: "fork.knife", colorHex: "#FF9500",
                  merchant: "", note: "早餐", accountName: "现金", timeText: "10月19日 07:30", duplicate: .skip, isManual: false),
        ReviewRow(index: 4, isIncome: true, amountText: "+¥200.00", categoryName: "红包", icon: "gift.fill", colorHex: "#FF2D55",
                  merchant: "微信红包", note: "", accountName: "微信", timeText: "10月18日 10:00", duplicate: .none, isManual: true),
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("简账 · 识图记账").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                }
                Text("识别到 4 笔，请核对：").font(.headline)
                ReviewSnippetView(title: "识别结果", rows: Self.rows)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(spacing: 8) {
                    choice("✅ 全部保存（3 笔）", .accentColor, prominent: true)
                    HStack(spacing: 8) {
                        choice("✏️ 修改第几笔…", .primary)
                        choice("🗑 删除第几笔…", .red)
                    }
                    choice("⌨️ 在 App 里改金额 / 商户 / 时间", .primary)
                    HStack(spacing: 8) {
                        choice("➕ 添加一笔（打开 App）", .primary)
                        choice("♻️ 重复的 1 笔仍然保存", .primary)
                    }
                    choice("取消", .secondary)
                }
                Text("示意图：需要改金额/商户/时间时选「在 App 里改」，会先保存再打开简账（弹窗内不再弹出键盘）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    private func choice(_ title: String, _ color: Color, prominent: Bool = false) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(prominent ? Color.white : color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemFill)),
                        in: Capsule())
    }
}
