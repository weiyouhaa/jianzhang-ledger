import Foundation
import SwiftUI

// 2.0 (20) 识图结果「小票卡片」：快捷指令 / Siri 审核弹窗里的片段视图。
// 只依赖 SwiftUI + Foundation（不碰 SwiftData / UIKit），CI 上可以在 macOS 用 ImageRenderer 渲染预览图（合成数据）。

// MARK: - 一行（纯值）

/// 快照视图用的一笔（纯值，可在 SwiftUI 片段中渲染）
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
    // 2.0 (20) 卡片里逐项展示要保存的全部信息
    /// 支出 / 收入 / 还款 / 转账
    var kindText: String = ""
    /// 完整日期时间，例如「2026年10月19日 12:30」
    var dateText: String = ""
    /// 时间来源（不是从截图文字识别到时）：「时间取自截图」等
    var timeHint: String? = nil
    /// 转账 / 还款：付款账户、收款账户（未选时为提示文字）
    var fromAccount: String? = nil
    var toAccount: String? = nil
    /// 截图来源：微信 / 支付宝 / 云闪付 / 银行公众号…
    var channel: String? = nil
    /// 金额数值（合计用）
    var amount: Double = 0

    enum DuplicateState: Hashable { case none, skip, saveAnyway }

    var isTransfer: Bool { fromAccount != nil || toAccount != nil }
    var title: String { merchant.isEmpty ? (note.isEmpty ? categoryName : note) : merchant }
    /// 标题用了备注时，备注行不再重复
    var noteIsTitle: Bool { merchant.isEmpty && !note.isEmpty }
    var resolvedKind: String {
        if !kindText.isEmpty { return kindText }
        return categoryName == "信用卡还款" ? "还款" : (categoryName == "转账" ? "转账" : (isIncome ? "收入" : "支出"))
    }
}

// MARK: - 配色（小票纸）

struct ReceiptPalette {
    let paper: Color
    let ink: Color
    let faint: Color
    let rule: Color
    let accent: Color
    let income: Color
    let backdrop: Color

    static func paper(_ scheme: ColorScheme) -> ReceiptPalette {
        scheme == .dark
            ? ReceiptPalette(paper: .cardHex("#2B2722"), ink: .cardHex("#EFE7DA"), faint: .cardHex("#A79E90"),
                             rule: .cardHex("#5A5248"), accent: .cardHex("#E58A7C"), income: .cardHex("#8CC9A0"),
                             backdrop: .cardHex("#1C1A17"))
            : ReceiptPalette(paper: .cardHex("#FBF7EE"), ink: .cardHex("#26221E"), faint: .cardHex("#857C70"),
                             rule: .cardHex("#CFC6B6"), accent: .cardHex("#9E2B25"), income: .cardHex("#2F7D4F"),
                             backdrop: .cardHex("#EDE7DB"))
    }
}

extension Color {
    /// "#RRGGBB"（本文件自带，方便脱离 App 单独渲染预览）
    static func cardHex(_ hex: String) -> Color {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x8E8E93
        return Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255, opacity: 1)
    }
}

enum ReceiptFont {
    /// 标题「RECEIPT」用打字机字体；中文自动回落到系统字体
    static func typewriter(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom("CourierNewPS-BoldMT", size: size, relativeTo: style)
    }
    static func mono(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }
}

// MARK: - 锯齿边纸片

/// 上下两边是锯齿的矩形（小票撕口）
struct SerratedPaper: Shape {
    var tooth: CGFloat = 9
    var depth: CGFloat = 3.5

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let count = max(1, Int((rect.width / tooth).rounded()))
        let w = rect.width / CGFloat(count)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + depth))
        for i in 0..<count {
            let x = rect.minX + CGFloat(i) * w
            p.addLine(to: CGPoint(x: x + w / 2, y: rect.minY))
            p.addLine(to: CGPoint(x: x + w, y: rect.minY + depth))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))
        for i in 0..<count {
            let x = rect.maxX - CGFloat(i) * w
            p.addLine(to: CGPoint(x: x - w / 2, y: rect.maxY))
            p.addLine(to: CGPoint(x: x - w, y: rect.maxY - depth))
        }
        p.closeSubpath()
        return p
    }
}

/// 虚线分隔
struct DashedRule: View {
    var color: Color
    var body: some View {
        Line()
            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
}

extension View {
    /// 小票纸背景：暖白（深色模式为暖深灰）+ 锯齿上下边 + 极淡阴影
    func receiptPaper(_ palette: ReceiptPalette) -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(SerratedPaper().fill(palette.paper)
                .shadow(color: .black.opacity(0.10), radius: 3, y: 1))
    }
}

// MARK: - 标签在左、值在右的一行

struct ReceiptField: View {
    let label: String
    let value: String
    var icon: String? = nil
    var iconColor: Color? = nil
    var hint: String? = nil
    var valueColor: Color? = nil
    let palette: ReceiptPalette
    @Environment(\.dynamicTypeSize) var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    labelView
                    valueView(alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    labelView
                    Spacer(minLength: 8)
                    valueView(alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var labelView: some View {
        Text(label)
            .font(ReceiptFont.mono(.caption))
            .foregroundStyle(palette.faint)
            .fixedSize()
    }

    private func valueView(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(iconColor ?? palette.ink)
                        .accessibilityHidden(true)
                }
                Text(value)
                    .font(ReceiptFont.mono(.footnote, .medium))
                    .foregroundStyle(valueColor ?? palette.ink)
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hint {
                Text(hint)
                    .font(ReceiptFont.mono(.caption2))
                    .foregroundStyle(palette.accent)
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            }
        }
    }
}

// MARK: - 一笔的详细卡片

struct ReceiptCardView: View {
    let row: ReviewRow
    var showIndex = true
    let palette: ReceiptPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if showIndex {
                    Text(String(format: "No.%d", row.index))
                        .font(ReceiptFont.typewriter(13, relativeTo: .caption))
                        .foregroundStyle(palette.faint)
                }
                Spacer(minLength: 4)
                ReceiptBadges(row: row, palette: palette)
            }
            Text(row.title)
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            DashedRule(color: palette.rule)
            HStack(alignment: .firstTextBaseline) {
                Text(row.resolvedKind)
                    .font(ReceiptFont.mono(.subheadline, .semibold))
                    .foregroundStyle(palette.faint)
                Spacer(minLength: 8)
                Text(row.amountText.trimmingCharacters(in: .whitespaces))
                    .font(.system(.title2, design: .monospaced).weight(.bold))
                    .foregroundStyle(row.isIncome ? palette.income : palette.ink)
                    .strikethrough(row.duplicate == .skip, color: palette.faint)
                    .opacity(row.duplicate == .skip ? 0.5 : 1)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            DashedRule(color: palette.rule)
            ReceiptFields(row: row, palette: palette)
            if row.duplicate != .none {
                ReceiptDuplicateNote(state: row.duplicate, palette: palette)
            }
        }
        .receiptPaper(palette)
        .accessibilityElement(children: .contain)
    }
}

/// 时间 / 分类 / 账户 / 备注 / 来源
struct ReceiptFields: View {
    let row: ReviewRow
    let palette: ReceiptPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ReceiptField(label: "时间", value: row.dateText.isEmpty ? row.timeText : row.dateText,
                         hint: row.timeHint, palette: palette)
            if !row.isTransfer {
                ReceiptField(label: "分类", value: row.categoryName, icon: row.icon,
                             iconColor: .cardHex(row.colorHex), palette: palette)
                ReceiptField(label: "账户", value: row.accountName,
                             valueColor: row.accountName.hasPrefix("未") ? palette.accent : nil, palette: palette)
            } else {
                ReceiptField(label: "类型", value: row.categoryName, icon: row.icon,
                             iconColor: .cardHex(row.colorHex), palette: palette)
                ReceiptField(label: "付款账户", value: row.fromAccount ?? "—",
                             valueColor: (row.fromAccount ?? "未").hasPrefix("未") ? palette.accent : nil, palette: palette)
                ReceiptField(label: row.categoryName == "信用卡还款" ? "还入信用卡" : "收款账户", value: row.toAccount ?? "—",
                             valueColor: (row.toAccount ?? "未").hasPrefix("未") ? palette.accent : nil, palette: palette)
            }
            if !row.note.isEmpty, !row.noteIsTitle {
                ReceiptField(label: "备注", value: row.note, palette: palette)
            }
            if let channel = row.channel, !channel.isEmpty {
                ReceiptField(label: "来源", value: channel, palette: palette)
            }
        }
    }
}

struct ReceiptBadges: View {
    let row: ReviewRow
    let palette: ReceiptPalette

    var body: some View {
        HStack(spacing: 4) {
            if row.isManual { tag("手动添加", palette.faint) }
            switch row.duplicate {
            case .skip: tag("已存在 · 跳过", palette.accent)
            case .saveAnyway: tag("已存在 · 仍保存", palette.accent)
            case .none: EmptyView()
            }
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(ReceiptFont.mono(.caption2, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
    }
}

struct ReceiptDuplicateNote: View {
    let state: ReviewRow.DuplicateState
    let palette: ReceiptPalette

    var body: some View {
        Label(state == .skip ? "可能重复：账本里已有相同的记录，默认跳过不保存"
                             : "可能重复：账本里已有相同的记录，已选择仍然保存",
              systemImage: "exclamationmark.triangle")
            .font(ReceiptFont.mono(.caption2))
            .foregroundStyle(palette.accent)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.accent.opacity(0.7),
                                                               style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

// MARK: - 多笔时的一行（小票明细）

struct ReceiptLineItem: View {
    let row: ReviewRow
    let palette: ReceiptPalette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(row.index)")
                .font(ReceiptFont.mono(.caption, .bold))
                .foregroundStyle(palette.faint)
                .frame(minWidth: 14, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: row.icon)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.cardHex(row.colorHex))
                        .accessibilityHidden(true)
                    Text(row.title)
                        .font(.system(.subheadline, design: .serif).weight(.semibold))
                        .foregroundStyle(palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(detail)
                    .font(ReceiptFont.mono(.caption2))
                    .foregroundStyle(palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = row.timeHint {
                    Text(hint).font(ReceiptFont.mono(.caption2)).foregroundStyle(palette.accent)
                }
                if row.isManual || row.duplicate != .none {
                    ReceiptBadges(row: row, palette: palette)
                }
            }
            Spacer(minLength: 6)
            Text(row.amountText.trimmingCharacters(in: .whitespaces))
                .font(ReceiptFont.mono(.subheadline, .bold))
                .foregroundStyle(row.isIncome ? palette.income : palette.ink)
                .strikethrough(row.duplicate == .skip, color: palette.faint)
                .opacity(row.duplicate == .skip ? 0.5 : 1)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = [row.resolvedKind]
        if !row.isTransfer { parts.append(row.categoryName) }
        parts.append(row.isTransfer ? "\(row.fromAccount ?? "—") → \(row.toAccount ?? "—")" : row.accountName)
        parts.append(row.dateText.isEmpty ? row.timeText : row.dateText)
        if !row.note.isEmpty, !row.noteIsTitle { parts.append("备注 " + row.note) }
        if let c = row.channel, !c.isEmpty { parts.append(c) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 整个片段（3.1 (22) 紧凑版）

/// 快捷指令 / Siri 的确认弹窗对片段有高度上限，超出的部分会被裁掉，按钮也被挤得看不全。
/// 3.1 (22) 起片段只放「核对用」的紧凑小票：金额 + 标题一行、两列键值、提示合成一行；
/// 并给内容一个高度预算，用 ViewThatFits 依次尝试 紧凑 → 精简 → 极简，放不下就降级而不是被裁掉。
/// 完整的逐项小票移到 App 编辑页顶部（RecordSummaryCard）。
struct ReceiptStackView: View {
    let title: String
    let rows: [ReviewRow]
    var footnote: String? = nil
    var engineLine: String? = nil
    /// 「保存 2 笔 · 跳过 1 笔」/「共 3 笔」
    var countText: String = ""
    /// 合计行：例如 [("支出", "¥59.50"), ("收入", "¥200.00")]
    var totals: [(String, String)] = []
    var maxRows = 8
    /// 片段内容的高度预算（pt）；nil = 不限高度，只用「紧凑」一级
    var heightBudget: CGFloat? = ReceiptStackView.defaultBudget
    static let defaultBudget: CGFloat = 360

    @Environment(\.colorScheme) var scheme

    enum Density: Int { case compact, minimal, tiny }

    var body: some View {
        let palette = ReceiptPalette.paper(scheme)
        if let heightBudget {
            ViewThatFits(in: .vertical) {
                content(.compact, palette)
                content(.minimal, palette)
                content(.tiny, palette)
            }
            .frame(maxHeight: heightBudget, alignment: .top)
        } else {
            content(.compact, palette)
        }
    }

    /// 某一密度下的完整片段（预览 / 测试也可以直接指定密度）
    func content(_ density: Density, _ palette: ReceiptPalette) -> some View {
        VStack(alignment: .leading, spacing: density == .compact ? 8 : 6) {
            header(density)
            if rows.isEmpty {
                Text("没有待保存的记录。可以「添加一笔」，或取消。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if rows.count == 1 && density != .tiny {
                SnippetSingleCard(row: rows[0], density: density, palette: palette)
            } else {
                SnippetLineList(rows: rows, density: density, maxRows: maxRows, totals: totals, palette: palette)
            }
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(density == .compact ? 3 : 1)
            }
            if density == .compact, let engineLine, !rows.isEmpty || footnote != nil {
                Label(engineLine, systemImage: engineLine.contains("Apple 智能") && !engineLine.contains("已用规则") ? "sparkles" : "text.magnifyingglass")
                    .font(ReceiptFont.mono(.caption2))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density == .compact ? 10 : 8)
    }

    private func header(_ density: Density) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(.subheadline, design: .serif).weight(.bold))
                .lineLimit(1)
            if density == .compact {
                Text("RECEIPT")
                    .font(ReceiptFont.typewriter(12, relativeTo: .caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if !countText.isEmpty {
                Text(countText)
                    .font(ReceiptFont.mono(.caption, .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

extension View {
    /// 片段用的小票纸：更小的内边距和锯齿
    func compactReceiptPaper(_ palette: ReceiptPalette, padding: CGFloat = 10) -> some View {
        self
            .padding(.horizontal, padding + 1)
            .padding(.vertical, padding)
            .background(SerratedPaper(tooth: 7, depth: 2.5).fill(palette.paper)
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1))
    }
}

extension ReviewRow {
    /// 「10月19日 12:18」：卡片里去掉年份，省一点宽度
    var shortDateText: String {
        guard !dateText.isEmpty else { return timeText }
        if let r = dateText.range(of: "年") { return String(dateText[r.upperBound...]) }
        return dateText
    }

    /// 片段里的提示：时间来源 / 手动添加 / 可能重复，合成一行
    var snippetFlags: [String] {
        var flags: [String] = []
        if let timeHint { flags.append(timeHint) }
        if isManual { flags.append("手动添加") }
        switch duplicate {
        case .skip: flags.append("可能重复 · 默认跳过")
        case .saveAnyway: flags.append("可能重复 · 仍保存")
        case .none: break
        }
        return flags
    }

    /// 一行摘要：分类 · 账户 · 时间
    var snippetMeta: String {
        var parts: [String] = []
        if !isTransfer { parts.append(categoryName) }
        parts.append(isTransfer ? "\(fromAccount ?? "—") → \(toAccount ?? "—")" : accountName)
        parts.append(shortDateText)
        return parts.joined(separator: " · ")
    }

    var trimmedAmount: String { amountText.trimmingCharacters(in: .whitespaces) }
}

/// 片段里只有 1 笔：紧凑小票（头部金额 + 标题，两列键值）
struct SnippetSingleCard: View {
    let row: ReviewRow
    let density: ReceiptStackView.Density
    let palette: ReceiptPalette
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: density == .compact ? 7 : 4) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: row.icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.cardHex(row.colorHex))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.cardHex(row.colorHex).opacity(0.16)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.system(.subheadline, design: .serif).weight(.bold))
                        .foregroundStyle(palette.ink)
                        .lineLimit(density == .compact ? 2 : 1)
                    Text(density == .compact ? "\(row.resolvedKind) · \(row.categoryName)"
                                             : "\(row.resolvedKind) · \(row.snippetMeta)")
                        .font(ReceiptFont.mono(.caption2))
                        .foregroundStyle(palette.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(row.trimmedAmount)
                    .font(.system(density == .compact ? .title3 : .headline, design: .monospaced).weight(.bold))
                    .foregroundStyle(row.isIncome ? palette.income : palette.ink)
                    .strikethrough(row.duplicate == .skip, color: palette.faint)
                    .opacity(row.duplicate == .skip ? 0.5 : 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
            }
            if density == .compact {
                DashedRule(color: palette.rule)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        kv("时间", row.shortDateText)
                        kv("来源", row.channel.flatMap { $0.isEmpty ? nil : $0 } ?? (row.isManual ? "手动" : "截图"))
                    }
                    if row.isTransfer {
                        GridRow { kv("付款", row.fromAccount ?? "—", warn: (row.fromAccount ?? "未").hasPrefix("未")).gridCellColumns(2) }
                        GridRow {
                            kv(row.categoryName == "信用卡还款" ? "还入" : "收款", row.toAccount ?? "—",
                               warn: (row.toAccount ?? "未").hasPrefix("未")).gridCellColumns(2)
                        }
                    } else {
                        GridRow { kv("账户", row.accountName, warn: row.accountName.hasPrefix("未")).gridCellColumns(2) }
                    }
                    if !row.note.isEmpty, !row.noteIsTitle {
                        GridRow { kv("备注", row.note).gridCellColumns(2) }
                    }
                }
            }
            if !row.snippetFlags.isEmpty {
                Label(row.snippetFlags.joined(separator: " · "),
                      systemImage: row.duplicate == .none ? "info.circle" : "exclamationmark.triangle")
                    .font(ReceiptFont.mono(.caption2))
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
            }
        }
        .compactReceiptPaper(palette, padding: density == .compact ? 10 : 8)
        .accessibilityElement(children: .combine)
    }

    private func kv(_ label: String, _ value: String, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .font(ReceiptFont.mono(.caption2))
                .foregroundStyle(palette.faint)
                .fixedSize()
            Text(value)
                .font(ReceiptFont.mono(.caption, .medium))
                .foregroundStyle(warn ? palette.accent : palette.ink)
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 片段里有多笔：每笔一到两行 + 合计；精简时每笔一行，极简时只剩合计
struct SnippetLineList: View {
    let rows: [ReviewRow]
    let density: ReceiptStackView.Density
    var maxRows = 8
    var totals: [(String, String)] = []
    let palette: ReceiptPalette

    private var limit: Int {
        switch density {
        case .compact: return min(maxRows, 5)
        case .minimal: return min(maxRows, 3)
        case .tiny: return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density == .compact ? 6 : 4) {
            ForEach(Array(rows.prefix(limit).enumerated()), id: \.element.id) { offset, row in
                if offset > 0 { DashedRule(color: palette.rule.opacity(0.55)) }
                line(row)
            }
            if rows.count > limit {
                Text(limit == 0 ? "共 \(rows.count) 笔，详情见下方选项" : "还有 \(rows.count - limit) 笔…")
                    .font(ReceiptFont.mono(.caption2))
                    .foregroundStyle(palette.faint)
            }
            if !totals.isEmpty {
                DashedRule(color: palette.rule)
                totalsLine
            }
        }
        .compactReceiptPaper(palette, padding: density == .compact ? 10 : 8)
    }

    private func line(_ row: ReviewRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(row.index)")
                .font(ReceiptFont.mono(.caption2, .bold))
                .foregroundStyle(palette.faint)
                .frame(minWidth: 12, alignment: .leading)
            Image(systemName: row.icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.cardHex(row.colorHex))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(.footnote, design: .serif).weight(.semibold))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                if density == .compact {
                    meta(row)
                        .font(ReceiptFont.mono(.caption2))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(row.trimmedAmount)
                .font(ReceiptFont.mono(.footnote, .bold))
                .foregroundStyle(row.isIncome ? palette.income : palette.ink)
                .strikethrough(row.duplicate == .skip, color: palette.faint)
                .opacity(row.duplicate == .skip ? 0.5 : 1)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private func meta(_ row: ReviewRow) -> Text {
        let flags = row.snippetFlags
        let flagText = flags.isEmpty ? Text("") : Text(flags.joined(separator: " · ") + " · ").foregroundStyle(palette.accent)
        return flagText + Text(row.snippetMeta).foregroundStyle(palette.faint)
    }

    private var totalsLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("合计")
                .font(ReceiptFont.mono(.caption2, .semibold))
                .foregroundStyle(palette.faint)
            Spacer(minLength: 4)
            ForEach(Array(totals.enumerated()), id: \.offset) { _, t in
                Text("\(t.0) \(t.1)")
                    .font(ReceiptFont.mono(.caption, .bold))
                    .foregroundStyle(t.0 == "收入" ? palette.income : palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

// MARK: - 编辑页顶部的小票卡片（3.1 (22)）

/// 编辑页顶部卡片的一行
struct RecordCardLine: Hashable {
    var label: String
    var value: String
    var icon: String? = nil
    var colorHex: String? = nil
    /// 未选择 / 需要确认：用强调色
    var warn = false
}

/// 编辑页顶部卡片的内容（纯值，由编辑页的状态实时生成）
struct RecordCardInfo: Hashable {
    enum Tone: Hashable { case expense, income, neutral }
    var kindText: String
    var amountText: String
    var tone: Tone
    /// 金额还没填 / 无效：显示为淡色占位
    var amountPlaceholder = false
    var title: String
    var dateText: String
    var icon: String
    var colorHex: String
    var lines: [RecordCardLine] = []
    /// 识图 / 周期账单 等来源标记
    var badge: String? = nil
}

/// 卡片配色：跟随皮肤（默认 / 小票）和深浅色
struct RecordCardStyle {
    var receipt: Bool
    var paper: Color
    var ink: Color
    var faint: Color
    var rule: Color
    var accent: Color
    var income: Color
    var neutral: Color
    var corner: CGFloat

    static func receipt(_ scheme: ColorScheme) -> RecordCardStyle {
        let p = ReceiptPalette.paper(scheme)
        return RecordCardStyle(receipt: true, paper: p.paper, ink: p.ink, faint: p.faint, rule: p.rule,
                               accent: p.accent, income: p.income, neutral: .cardHex("#30B0C7"), corner: 4)
    }

    /// 默认皮肤的近似色（预览用；App 内由 AppTheme 生成）
    static func plain(_ scheme: ColorScheme) -> RecordCardStyle {
        let dark = scheme == .dark
        return RecordCardStyle(receipt: false,
                               paper: .cardHex(dark ? "#2C2C2E" : "#FFFFFF"),
                               ink: .cardHex(dark ? "#F5F5F7" : "#1C1C1E"),
                               faint: .cardHex(dark ? "#98989F" : "#6C6C70"),
                               rule: .cardHex(dark ? "#48484A" : "#E5E5EA"),
                               accent: .cardHex(dark ? "#3FC780" : "#219F66"),
                               income: .cardHex(dark ? "#3FC780" : "#219F66"),
                               neutral: .cardHex("#30B0C7"), corner: 16)
    }
}

/// 编辑页顶部的当笔记录卡片：类型 · 时间、标题、金额，展开时逐项列出分类 / 账户 / 备注等。
/// 只读，随编辑实时更新；可折叠成一行，避免和下方的金额输入框抢位置。
struct RecordSummaryCard: View {
    let info: RecordCardInfo
    let style: RecordCardStyle
    @Binding var collapsed: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { collapsed.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityHint(collapsed ? "展开卡片" : "折叠卡片")
            if !collapsed && !info.lines.isEmpty {
                divider
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(info.lines, id: \.self) { line in
                        lineView(line)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, style.receipt ? 14 : 12)
        .background(background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("record-summary-card")
    }

    private var amountColor: Color {
        if info.amountPlaceholder { return style.faint }
        switch info.tone {
        case .expense: return style.ink
        case .income: return style.income
        case .neutral: return style.neutral
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: info.icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.cardHex(info.colorHex))
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: style.receipt ? 4 : 10, style: .continuous)
                        .fill(Color.cardHex(info.colorHex).opacity(0.16))
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(style.receipt ? .system(.subheadline, design: .serif).weight(.bold) : .subheadline.weight(.semibold))
                    .foregroundStyle(style.ink)
                    .lineLimit(collapsed ? 1 : 2)
                HStack(spacing: 5) {
                    Text(info.kindText)
                    Text("·")
                    Text(info.dateText).lineLimit(1)
                    if let badge = info.badge {
                        Text(badge)
                            .font(style.receipt ? ReceiptFont.mono(.caption2, .semibold) : .caption2.weight(.semibold))
                            .foregroundStyle(style.accent)
                            .padding(.horizontal, 4).padding(.vertical, 0.5)
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .stroke(style.accent.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: style.receipt ? [3, 2] : [])))
                    }
                }
                .font(style.receipt ? ReceiptFont.mono(.caption2) : .caption)
                .foregroundStyle(style.faint)
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(info.amountText)
                .font(style.receipt ? .system(.title3, design: .monospaced).weight(.bold)
                                    : .system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(amountColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .layoutPriority(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(style.faint)
                .rotationEffect(.degrees(collapsed ? -90 : 0))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var divider: some View {
        if style.receipt {
            DashedRule(color: style.rule)
        } else {
            Rectangle().fill(style.rule).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func lineView(_ line: RecordCardLine) -> some View {
        let label = Text(line.label)
            .font(style.receipt ? ReceiptFont.mono(.caption) : .caption)
            .foregroundStyle(style.faint)
        let value = HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let icon = line.icon {
                Image(systemName: icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(line.colorHex.map { Color.cardHex($0) } ?? style.ink)
                    .accessibilityHidden(true)
            }
            Text(line.value)
                .font(style.receipt ? ReceiptFont.mono(.footnote, .medium) : .footnote.weight(.medium))
                .foregroundStyle(line.warn ? style.accent : style.ink)
                .lineLimit(3)
                .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
        }
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) { label; value }
                .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                label.fixedSize()
                Spacer(minLength: 8)
                value
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var background: some View {
        if style.receipt {
            SerratedPaper(tooth: 8, depth: 3).fill(style.paper)
                .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
        } else {
            RoundedRectangle(cornerRadius: style.corner, style: .continuous).fill(style.paper)
        }
    }
}

extension RecordCardInfo {
    /// 合成示例（预览 / CI 渲染用，不含真实数据）
    static let sample = RecordCardInfo(
        kindText: "支出", amountText: "-¥39.80", tone: .expense, title: "示例烧腊饭店（示例大厦店）",
        dateText: "2026年10月19日 12:18", icon: "fork.knife", colorHex: "#FF9500",
        lines: [
            RecordCardLine(label: "分类", value: "餐饮", icon: "fork.knife", colorHex: "#FF9500"),
            RecordCardLine(label: "账户", value: "储蓄卡-示例银行"),
            RecordCardLine(label: "备注", value: "示例立减 2.00"),
            RecordCardLine(label: "时间来源", value: "时间取自截图", warn: true),
        ],
        badge: "识图")

    static let sampleRepay = RecordCardInfo(
        kindText: "还款", amountText: "¥1,000.00", tone: .neutral, title: "信用卡还款",
        dateText: "2026年10月18日 09:12", icon: "creditcard.and.123", colorHex: "#30B0C7",
        lines: [
            RecordCardLine(label: "付款账户", value: "储蓄卡-示例银行"),
            RecordCardLine(label: "还款信用卡", value: "请选择", warn: true),
        ])
}

// MARK: - 合成示例数据（预览 / 截图演示 / CI 渲染；不含任何真实数据）

extension ReviewRow {
    static let samples: [ReviewRow] = [
        ReviewRow(index: 1, isIncome: false, amountText: "-¥39.80", categoryName: "餐饮", icon: "fork.knife", colorHex: "#FF9500",
                  merchant: "示例烧腊饭店（示例大厦店）", note: "示例立减 2.00", accountName: "储蓄卡-示例银行", timeText: "10月19日 12:18",
                  duplicate: .none, isManual: false, kindText: "支出", dateText: "2026年10月19日 12:18", channel: "云闪付"),
        ReviewRow(index: 2, isIncome: false, amountText: "-¥23.50", categoryName: "交通", icon: "car.fill", colorHex: "#0A84FF",
                  merchant: "示例出行", note: "打车去公司", accountName: "支付宝", timeText: "10月19日 08:45",
                  duplicate: .none, isManual: false, kindText: "支出", dateText: "2026年10月19日 08:45",
                  timeHint: "时间取自截图", channel: "支付宝"),
        ReviewRow(index: 3, isIncome: false, amountText: "-¥18.00", categoryName: "餐饮", icon: "fork.knife", colorHex: "#FF9500",
                  merchant: "", note: "早餐", accountName: "现金", timeText: "10月19日 07:30",
                  duplicate: .skip, isManual: false, kindText: "支出", dateText: "2026年10月19日 07:30"),
        ReviewRow(index: 4, isIncome: true, amountText: "+¥200.00", categoryName: "红包", icon: "gift.fill", colorHex: "#FF2D55",
                  merchant: "示例红包", note: "", accountName: "微信", timeText: "10月18日 10:00",
                  duplicate: .none, isManual: true, kindText: "收入", dateText: "2026年10月18日 10:00", channel: "微信"),
        ReviewRow(index: 5, isIncome: false, amountText: "¥1,000.00", categoryName: "信用卡还款", icon: "creditcard.and.123", colorHex: "#30B0C7",
                  merchant: "", note: "", accountName: "储蓄卡-示例银行 → 未选信用卡", timeText: "10月18日 09:12",
                  duplicate: .none, isManual: false, kindText: "还款", dateText: "2026年10月18日 09:12",
                  fromAccount: "储蓄卡-示例银行", toAccount: "未选信用卡", channel: "银行"),
    ]
}


/// 皮肤对比预览（合成数据，CI 渲染用；不含真实用户数据）
struct SkinChromeDemo: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            panel(.light, title: "浅色")
            panel(.dark, title: "深色")
        }
    }

    private func panel(_ scheme: ColorScheme, title: String) -> some View {
        let light = ReceiptPalette.paper(.light)
        let dark = ReceiptPalette.paper(.dark)
        return VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.caption.bold()).foregroundStyle(scheme == .dark ? dark.faint : light.faint)
            chrome(false, scheme)
            chrome(true, scheme)
        }
        .padding(14)
        .frame(width: 320)
        .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.93))
        .environment(\.colorScheme, scheme)
    }

    /// defaultStyle == false → 默认青绿；true → 小票
    private func chrome(_ receipt: Bool, _ scheme: ColorScheme) -> some View {
        let p = ReceiptPalette.paper(scheme)
        let accent = receipt ? p.accent : Color.cardHex(scheme == .dark ? "#3FC780" : "#219F66")
        let paper = receipt ? p.paper : Color.cardHex(scheme == .dark ? "#2C2C2E" : "#FFFFFF")
        let ink = receipt ? p.ink : Color.cardHex(scheme == .dark ? "#F5F5F7" : "#1C1C1E")
        let faint = receipt ? p.faint : Color.cardHex(scheme == .dark ? "#98989F" : "#6C6C70")
        let hero = receipt ? [paper] : [Color.cardHex("#1FA67A"), Color.cardHex("#1673A8")]
        let heroInk: Color = receipt ? ink : .white
        let heroFaint: Color = receipt ? faint : Color.white.opacity(0.8)
        return VStack(alignment: .leading, spacing: 10) {
            Text(receipt ? "小票" : "默认").font(.caption2.bold()).foregroundStyle(faint)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("2026年10月").font(receipt ? ReceiptFont.typewriter(15, relativeTo: .headline) : .headline)
                    Spacer()
                    Text("12 笔").font(.caption).opacity(0.8)
                }
                .foregroundStyle(heroInk)
                if receipt { DashedRule(color: p.rule) }
                Text("本月结余").font(.caption).foregroundStyle(heroFaint)
                Text("¥1,234.50")
                    .font(receipt ? ReceiptFont.typewriter(28, relativeTo: .title) : .system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(heroInk)
                if receipt { DashedRule(color: p.rule) }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("支出").font(.caption).foregroundStyle(heroFaint)
                        Text("¥2,000.00").font(receipt ? ReceiptFont.typewriter(15, relativeTo: .headline) : .headline).foregroundStyle(heroInk)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("收入").font(.caption).foregroundStyle(heroFaint)
                        Text("¥3,234.50").font(receipt ? ReceiptFont.typewriter(15, relativeTo: .headline) : .headline).foregroundStyle(heroInk)
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: receipt ? 4 : 20)
                    .fill(LinearGradient(colors: hero, startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay {
                if receipt {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(p.rule, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            }
            // day row（3.1 (22)：笔数在第一行，日期单独一行，右侧加每日结余）
            DayCardDemo.row(receipt: receipt, scheme: scheme, day: "19", relative: "今天", date: "10月19日 周一", count: 3,
                            expense: "-¥128.00", income: "+¥40.00", balance: "结余 -¥88.00", today: true)
        }
    }
}

/// 明细「按天卡片」预览（3.1 (22)，合成数据，CI 渲染用）：默认 / 小票 × 浅色 / 深色
struct DayCardDemo: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            panel(.light)
            panel(.dark)
        }
    }

    private func panel(_ scheme: ColorScheme) -> some View {
        let p = ReceiptPalette.paper(scheme)
        return VStack(alignment: .leading, spacing: 12) {
            Text(scheme == .dark ? "深色" : "浅色").font(.caption.bold()).foregroundStyle(p.faint)
            ForEach([false, true], id: \.self) { receipt in
                Text(receipt ? "小票" : "默认").font(.caption2.bold()).foregroundStyle(p.faint)
                Self.row(receipt: receipt, scheme: scheme, day: "21", relative: "周三", date: "10月21日", count: 6,
                         expense: "-¥128.40", income: "+¥40.00", balance: "结余 -¥88.40", today: false)
                Self.row(receipt: receipt, scheme: scheme, day: "30", relative: "周五", date: "10月30日", count: 2,
                         expense: "-¥36.00", income: "+¥200.00", balance: "结余 +¥164.00", today: false)
                Self.row(receipt: receipt, scheme: scheme, day: "29", relative: "周四", date: "10月29日", count: 1,
                         expense: "-¥12.00", income: nil, balance: "结余 -¥12.00", today: false)
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.93))
        .environment(\.colorScheme, scheme)
    }

    static func row(receipt: Bool, scheme: ColorScheme, day: String, relative: String, date: String, count: Int,
                    expense: String?, income: String?, balance: String, today: Bool) -> some View {
        let p = ReceiptPalette.paper(scheme)
        let accent = receipt ? p.accent : Color.cardHex(scheme == .dark ? "#3FC780" : "#219F66")
        let incomeColor = receipt ? p.income : accent
        let paper = receipt ? p.paper : Color.cardHex(scheme == .dark ? "#2C2C2E" : "#FFFFFF")
        let ink = receipt ? p.ink : Color.cardHex(scheme == .dark ? "#F5F5F7" : "#1C1C1E")
        let faint = receipt ? p.faint : Color.cardHex(scheme == .dark ? "#98989F" : "#6C6C70")
        let body: (Font.TextStyle) -> Font = { style in
            receipt ? .custom("CourierNewPSMT", size: style == .caption ? 12 : 15, relativeTo: style) : .system(style)
        }
        let positive = balance.contains("+")
        return HStack(spacing: 10) {
            Text(day)
                .font(receipt ? ReceiptFont.typewriter(20, relativeTo: .title2) : .title2.bold())
                .foregroundStyle(today ? (receipt ? paper : .white) : accent)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: receipt ? 4 : 12).fill(today ? accent : accent.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(relative).font(receipt ? ReceiptFont.typewriter(16, relativeTo: .headline) : .headline)
                        .foregroundStyle(today ? accent : ink)
                    Text("\(count) 笔").font(body(.caption)).foregroundStyle(faint)
                }
                Text(date).font(body(.subheadline)).foregroundStyle(faint).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if let expense {
                    Text(expense).font(receipt ? ReceiptFont.typewriter(16, relativeTo: .headline) : .headline.monospacedDigit())
                        .foregroundStyle(ink)
                }
                if let income {
                    Text(income).font(receipt ? ReceiptFont.typewriter(13, relativeTo: .subheadline) : .subheadline.monospacedDigit())
                        .foregroundStyle(incomeColor)
                }
                Text(balance).font(body(.caption)).monospacedDigit()
                    .foregroundStyle(positive ? incomeColor.opacity(0.8) : faint)
            }
            .lineLimit(1)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(faint.opacity(0.6))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: receipt ? 4 : 12).fill(paper))
        .overlay {
            if receipt {
                RoundedRectangle(cornerRadius: 4).strokeBorder(p.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }
}

/// 编辑页顶部卡片预览（3.1 (22)，合成数据）：默认 / 小票 × 浅色 / 深色，含折叠状态
struct EditorCardDemo: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            panel(.light)
            panel(.dark)
        }
    }

    private func panel(_ scheme: ColorScheme) -> some View {
        let p = ReceiptPalette.paper(scheme)
        return VStack(alignment: .leading, spacing: 12) {
            Text(scheme == .dark ? "深色" : "浅色").font(.caption.bold()).foregroundStyle(p.faint)
            Text("默认").font(.caption2.bold()).foregroundStyle(p.faint)
            RecordSummaryCard(info: .sample, style: .plain(scheme), collapsed: .constant(false))
            RecordSummaryCard(info: .sampleRepay, style: .plain(scheme), collapsed: .constant(true))
            Text("小票").font(.caption2.bold()).foregroundStyle(p.faint)
            RecordSummaryCard(info: .sample, style: .receipt(scheme), collapsed: .constant(false))
            RecordSummaryCard(info: .sampleRepay, style: .receipt(scheme), collapsed: .constant(false))
        }
        .padding(14)
        .frame(width: 380)
        .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.93))
        .environment(\.colorScheme, scheme)
    }
}

#if DEBUG
struct ReceiptStackView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ReceiptStackView(title: "识别结果", rows: [ReviewRow.samples[0]], engineLine: "识别引擎：Apple 智能 · 模型 6.9 秒",
                             countText: "共 1 笔")
                .previewDisplayName("1 笔")
            ReceiptStackView(title: "识别结果", rows: [ReviewRow.samples[1], ReviewRow.samples[4]], engineLine: "识别引擎：规则",
                             countText: "共 2 笔", totals: [("支出", "¥23.50"), ("还款", "¥1,000.00")])
                .preferredColorScheme(.dark)
                .previewDisplayName("2 笔 · 深色")
            ReceiptStackView(title: "识别结果", rows: ReviewRow.samples, engineLine: "识别引擎：Apple 智能",
                             countText: "保存 4 笔 · 跳过 1 笔", totals: [("支出", "¥63.30"), ("收入", "¥200.00")],
                             heightBudget: 200)
                .previewDisplayName("多笔 · 降级")
            RecordSummaryCard(info: .sample, style: .receipt(.light), collapsed: .constant(false))
                .padding()
                .previewDisplayName("编辑页卡片")
        }
        .frame(width: 380)
        .background(Color(white: 0.92))
    }
}
#endif
