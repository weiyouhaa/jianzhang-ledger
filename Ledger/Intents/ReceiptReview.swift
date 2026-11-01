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
    /// 时间来源（截图文字 / 截图拍摄时间 / 状态栏 / 现在）：不是识别到的时在时间后面小字注明，方便修改
    var dateSource: TimeSource = .recognized
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
    /// 自己账户之间的转账（钱包充值 / 提现 / 余额宝转入转出），不是信用卡还款
    var isSelfTransfer = false
    /// 截图来源（微信 / 支付宝 / 云闪付 / 银行公众号…），卡片里显示；不保存、不记日志
    var channel: String? = nil
    /// 3.2 (23) 截图上的优惠 / 立减说明（片段里单独一行显示）
    var discount: String? = nil

    /// 还款 / 转账必须两个账户都已选定
    var isComplete: Bool { kind != .transfer || (accountID != nil && toAccountID != nil) }
    var willSave: Bool { (!isDuplicate || saveDuplicate) && isComplete }
}

// ReviewRow（快照视图用的一笔）定义在 ReceiptCardView.swift

@MainActor
enum ReviewFormatter {
    static func row(_ item: ReviewItem, index: Int, in context: ModelContext) -> ReviewRow {
        let category = item.categoryID.flatMap { DataStore.category(id: $0, in: context) }
        let account = item.accountID.flatMap { DataStore.account(id: $0, in: context) }
        let isTransfer = item.kind == .transfer
        let toAccount = isTransfer ? item.toAccountID.flatMap { DataStore.account(id: $0, in: context) } : nil
        // 还没选卡的还款也按「信用卡还款」显示
        let isRepay = isTransfer && !item.isSelfTransfer && (toAccount == nil || toAccount?.type.isLiability == true)
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
            timeText: timeText(item),
            duplicate: item.isDuplicate ? (item.saveDuplicate ? .saveAnyway : .skip) : .none,
            isManual: item.isManual,
            kindText: isTransfer ? (isRepay ? "还款" : "转账") : (item.kind == .income ? "收入" : "支出"),
            dateText: fullDate.string(from: item.date),
            timeHint: (item.dateRecognized || item.isManual) ? nil : item.dateSource.hint,
            fromAccount: isTransfer ? (account?.name ?? "未选付款账户") : nil,
            toAccount: isTransfer ? (toAccount?.name ?? (isRepay ? "未选信用卡" : "未选账户")) : nil,
            channel: item.channel,
            amount: item.amount,
            discount: item.discount
        )
    }

    /// 卡片里的完整时间：「2026年10月19日 12:30」
    static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f
    }()

    /// 识别到的 / 手动的只显示时间；截图时间、状态栏兜底的加一句来源；完全没有则「时间未识别（按现在）」
    static func timeText(_ item: ReviewItem) -> String {
        let text = DateText.monthDayTime.string(from: item.date)
        if item.dateRecognized || item.isManual { return text }
        switch item.dateSource {
        case .now: return TimeSource.now.hint ?? text
        default: return item.dateSource.hint.map { "\(text)（\($0)）" } ?? text
        }
    }

    /// 一行文字摘要（选项标题 / 对话框）
    static func line(_ row: ReviewRow) -> String {
        let kindText = row.categoryName == "信用卡还款" ? "还款" : (row.categoryName == "转账" ? "转账" : (row.isIncome ? "收入" : "支出"))
        var parts = ["\(kindText) \(row.amountText.dropFirst())", row.categoryName]
        if !row.merchant.isEmpty { parts.append(row.merchant) }
        parts.append(row.accountName)
        parts.append(row.timeText)
        if !row.note.isEmpty, !row.noteIsTitle, row.note != row.discount { parts.append("备注 \(row.note)") }
        if let discount = row.discount, !discount.isEmpty { parts.append("优惠 \(discount)") }
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
    /// 全部记录（合计按全部计算）；只显示 page 这一页
    let rows: [ReviewRow]
    var footnote: String? = nil
    /// 3.2 (23) 第几页（从 0 开始，每页 ReceiptStackView.pageSize 笔）
    var page = 0
    /// 识别引擎（Apple 智能 / 规则），创建时取本次识图的结果
    var engineLine: String? = OCRRunInfo.engineLine

    /// 3.2 (23) 全量信息小票：每笔所有字段都显示（小字、换行），多于 2 笔时分页，
    /// 放不下只缩小字号、不隐藏任何内容。详见 ReceiptStackView。
    var body: some View {
        ReceiptStackView(title: title, rows: SnippetPager.slice(rows, page: page), footnote: footnote, engineLine: engineLine,
                         countText: SnippetPager.countText(rows, page: page),
                         totals: SnippetPager.totals(rows, format: { Money.format($0) }))
    }
}

// MARK: - 截图演示：模拟快捷指令弹窗（仅 -UIScreenshotDemo reviewsnippet）

struct ReviewSnippetDemoView: View {
    static let rows: [ReviewRow] = Array(ReviewRow.samples.prefix(4))

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
                    choice("📄 下一页（第 3–4 笔）", .primary)
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
