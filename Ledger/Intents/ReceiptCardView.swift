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
    /// 3.2 (23) 优惠 / 立减说明（截图上识别到时）
    var discount: String? = nil

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
    /// 3.2 (23) 数字 / 粗体打字机：Courier Prime Bold（中文回落宋体），随动态字体缩放
    static func typewriter(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        ReceiptTypeface.scaled(ReceiptTypeface.monoBold, size, relativeTo: style)
    }
    /// 大标题：Special Elite（做旧打字机）
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        ReceiptTypeface.scaled(ReceiptTypeface.display, size, relativeTo: style)
    }
    /// 正文：Courier Prime，粗细只分常规 / 粗体
    static func mono(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        let bold = weight == .semibold || weight == .bold || weight == .heavy || weight == .black
        return ReceiptTypeface.scaled(bold ? ReceiptTypeface.monoBold : ReceiptTypeface.mono,
                                      ReceiptTypeface.baseSize(style), relativeTo: style)
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

// MARK: - 整个片段（3.2 (23) 全量信息版）

/// 快捷指令 / Siri 的确认弹窗对片段有高度上限（HIG 建议自定义片段不超过约 340–400pt，超出会被裁掉）。
/// 3.1 (22) 用「紧凑 → 精简 → 极简」逐级隐藏字段 / 行，结果信息不全。3.2 (23) 改为：
/// 1. 每一笔都显示全部信息（类型、金额、商户、分类、时间、来源、账户、备注、优惠、时间来源 / 重复提醒），
///    用 11pt 等宽小字 + 两列「标签 值」网格，长文字换行而不是截断；
/// 2. 一页最多 3 笔（更多的用「下一页」选项翻页，合计行始终按全部记录计算）；
/// 3. 仍然放不下时只做等比缩小字号（1.0 → 0.56），绝不再隐藏任何字段或行；
/// 4. 去掉原来的标题行 / RECEIPT / 引擎行，笔数和引擎并入底部一行小字，省出空间。
struct ReceiptStackView: View {
    let title: String
    /// 当前页要显示的记录
    let rows: [ReviewRow]
    var footnote: String? = nil
    var engineLine: String? = nil
    /// 「共 5 笔 · 第 1–3 笔」等
    var countText: String = ""
    /// 合计行：例如 [("支出", "¥59.50"), ("收入", "¥200.00")]（按全部记录）
    var totals: [(String, String)] = []
    /// 片段内容的高度预算（pt）；nil = 不限高度，按原大小显示
    var heightBudget: CGFloat? = ReceiptStackView.defaultBudget
    /// 比系统建议的 340pt 再保守一点
    static let defaultBudget: CGFloat = 320
    /// 一页最多几笔
    static let pageSize = 3
    /// 放不下时依次尝试的字号缩放（每一级都是完整信息）
    static let scales: [CGFloat] = [1.0, 0.9, 0.8, 0.72, 0.64, 0.56]

    @Environment(\.colorScheme) var scheme

    var body: some View {
        let palette = ReceiptPalette.paper(scheme)
        if let heightBudget {
            ViewThatFits(in: .vertical) {
                content(Self.scales[0], palette)
                content(Self.scales[1], palette)
                content(Self.scales[2], palette)
                content(Self.scales[3], palette)
                content(Self.scales[4], palette)
                content(Self.scales[5], palette)
            }
            .frame(maxHeight: heightBudget, alignment: .top)
        } else {
            content(1, palette)
        }
    }

    /// 只有出错 / 已取消 / 第 N 笔这类标题才显示（「识别结果」不占一行）
    private var showsTitle: Bool { !title.isEmpty && title != "识别结果" }

    /// 某一缩放下的完整片段（预览也可以直接调用）
    func content(_ s: CGFloat, _ palette: ReceiptPalette) -> some View {
        VStack(alignment: .leading, spacing: 5 * s) {
            if showsTitle {
                Text(title)
                    .font(ReceiptTypeface.fixed(ReceiptTypeface.display, 13 * s))
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if rows.isEmpty && footnote == nil {
                Text("没有待保存的记录。可以「添加一笔」，或取消。")
                    .font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 11 * s))
                    .foregroundStyle(palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                if offset > 0 { DashedRule(color: palette.rule) }
                SnippetRecord(row: row, scale: s, palette: palette)
            }
            if !totals.isEmpty || !footerMeta.isEmpty {
                DashedRule(color: palette.rule)
                footer(s, palette)
            }
            if let footnote {
                Text(footnote)
                    .font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 10.5 * s))
                    .foregroundStyle(palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .compactReceiptPaper(palette, padding: max(5, 8 * s))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    /// 底部小字：笔数 / 页码 · 识别引擎
    private var footerMeta: String {
        var parts: [String] = []
        if !countText.isEmpty { parts.append(countText) }
        if let engineLine, !engineLine.isEmpty {
            parts.append(engineLine.replacingOccurrences(of: "识别引擎：", with: "引擎 "))
        }
        return parts.joined(separator: " · ")
    }

    private func footer(_ s: CGFloat, _ palette: ReceiptPalette) -> some View {
        VStack(alignment: .leading, spacing: 2 * s) {
            if !totals.isEmpty {
                totalsText(palette)
                    .font(ReceiptTypeface.fixed(ReceiptTypeface.monoBold, 11 * s))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !footerMeta.isEmpty {
                Text(footerMeta)
                    .font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 9.5 * s))
                    .foregroundStyle(palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func totalsText(_ palette: ReceiptPalette) -> Text {
        var text = Text("合计").foregroundStyle(palette.faint)
        for t in totals {
            text = text + Text("  \(t.0) \(t.1)").foregroundStyle(t.0 == "收入" ? palette.income : palette.ink)
        }
        return text
    }
}

/// 片段分页（快捷指令里用「下一页」选项翻页）
enum SnippetPager {
    static func pageCount(_ total: Int) -> Int {
        max(1, (total + ReceiptStackView.pageSize - 1) / ReceiptStackView.pageSize)
    }

    static func clamp(_ page: Int, total: Int) -> Int { min(max(page, 0), pageCount(total) - 1) }

    static func slice(_ rows: [ReviewRow], page: Int) -> [ReviewRow] {
        let p = clamp(page, total: rows.count)
        return Array(rows.dropFirst(p * ReceiptStackView.pageSize).prefix(ReceiptStackView.pageSize))
    }

    /// 「第 1–3 笔」
    static func rangeText(total: Int, page: Int) -> String {
        let p = clamp(page, total: total)
        let first = p * ReceiptStackView.pageSize + 1
        let last = min(total, first + ReceiptStackView.pageSize - 1)
        return first == last ? "第 \(first) 笔" : "第 \(first)–\(last) 笔"
    }

    /// 「共 5 笔（保存 4 · 跳过 1）· 第 1–3 笔」
    static func countText(_ rows: [ReviewRow], page: Int) -> String {
        guard !rows.isEmpty else { return "" }
        let skipped = rows.filter { $0.duplicate == .skip }.count
        var s = "共 \(rows.count) 笔"
        if skipped > 0 { s += "（保存 \(rows.count - skipped) · 跳过 \(skipped)）" }
        if pageCount(rows.count) > 1 {
            s += " · \(rangeText(total: rows.count, page: page))（\(clamp(page, total: rows.count) + 1)/\(pageCount(rows.count)) 页）"
        }
        return s
    }

    /// 合计（只算会保存的），按支出 / 收入 / 还款 / 转账分别合计
    static func totals(_ rows: [ReviewRow], format: (Double) -> String) -> [(String, String)] {
        let saving = rows.filter { $0.duplicate != .skip }
        return ["支出", "收入", "还款", "转账"].compactMap { kind in
            let list = saving.filter { $0.resolvedKind == kind }
            guard !list.isEmpty else { return nil }
            return (kind, format(list.reduce(0) { $0 + $1.amount }))
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

    /// 片段里的提示：时间来源 / 手动添加 / 可能重复
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

    /// 截图来源：微信 / 支付宝…；手动添加的写「手动」
    var sourceText: String {
        if let channel, !channel.isEmpty { return channel }
        return isManual ? "手动" : "截图"
    }
}

/// 片段里的一笔：所有字段都显示，长文字换行
struct SnippetRecord: View {
    let row: ReviewRow
    let scale: CGFloat
    let palette: ReceiptPalette

    private var s: CGFloat { scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 2.5 * s) {
            HStack(alignment: .firstTextBaseline, spacing: 5 * s) {
                Text("\(row.index)")
                    .font(ReceiptTypeface.fixed(ReceiptTypeface.monoBold, 10 * s))
                    .foregroundStyle(palette.faint)
                Image(systemName: row.icon)
                    .font(.system(size: 10 * s, weight: .bold))
                    .foregroundStyle(Color.cardHex(row.colorHex))
                    .accessibilityHidden(true)
                Text(row.title)
                    .font(ReceiptTypeface.fixed(ReceiptTypeface.monoBold, 12 * s))
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4 * s)
                Text(row.trimmedAmount)
                    .font(ReceiptTypeface.fixed(ReceiptTypeface.monoBold, 14 * s))
                    .foregroundStyle(row.isIncome ? palette.income : palette.ink)
                    .strikethrough(row.duplicate == .skip, color: palette.faint)
                    .opacity(row.duplicate == .skip ? 0.55 : 1)
                    .fixedSize()
            }
            pair(("类型", row.resolvedKind, false), ("分类", row.categoryName, false))
            pair(("时间", row.shortDateText, false), ("来源", row.sourceText, false))
            if row.isTransfer {
                kv("付款", row.fromAccount ?? "—", warn: (row.fromAccount ?? "未").hasPrefix("未"))
                kv(row.categoryName == "信用卡还款" ? "还入" : "收款", row.toAccount ?? "—",
                   warn: (row.toAccount ?? "未").hasPrefix("未"))
            } else {
                kv("账户", row.accountName, warn: row.accountName.hasPrefix("未"))
            }
            if !row.merchant.isEmpty, row.title != row.merchant {
                kv("商户", row.merchant)
            }
            if !row.note.isEmpty, !row.noteIsTitle, row.note != row.discount {
                kv("备注", row.note)
            }
            if let discount = row.discount, !discount.isEmpty {
                kv("优惠", discount)
            }
            if !row.snippetFlags.isEmpty {
                Text("⚠︎ " + row.snippetFlags.joined(separator: " · "))
                    .font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 10 * s))
                    .foregroundStyle(palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// 两列：左右各一个「标签 值」，等宽
    private func pair(_ a: (String, String, Bool), _ b: (String, String, Bool)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8 * s) {
            kv(a.0, a.1, warn: a.2)
            kv(b.0, b.1, warn: b.2)
        }
    }

    private func kv(_ label: String, _ value: String, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4 * s) {
            Text(label)
                .font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 9.5 * s))
                .foregroundStyle(palette.faint)
                .fixedSize()
            Text(value.isEmpty ? "—" : value)
                .font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 11 * s))
                .foregroundStyle(warn ? palette.accent : palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                  merchant: "示例烧腊饭店（示例大厦店）", note: "午餐 两人份", accountName: "储蓄卡-示例银行", timeText: "10月19日 12:18",
                  duplicate: .none, isManual: false, kindText: "支出", dateText: "2026年10月19日 12:18", channel: "云闪付",
                  amount: 39.80, discount: "示例立减 2.00"),
        ReviewRow(index: 2, isIncome: false, amountText: "-¥23.50", categoryName: "交通", icon: "car.fill", colorHex: "#0A84FF",
                  merchant: "示例出行", note: "打车去公司", accountName: "支付宝", timeText: "10月19日 08:45",
                  duplicate: .none, isManual: false, kindText: "支出", dateText: "2026年10月19日 08:45",
                  timeHint: "时间取自截图", channel: "支付宝", amount: 23.50),
        ReviewRow(index: 3, isIncome: false, amountText: "-¥18.00", categoryName: "餐饮", icon: "fork.knife", colorHex: "#FF9500",
                  merchant: "", note: "早餐", accountName: "现金", timeText: "10月19日 07:30",
                  duplicate: .skip, isManual: false, kindText: "支出", dateText: "2026年10月19日 07:30", amount: 18.00),
        ReviewRow(index: 4, isIncome: true, amountText: "+¥200.00", categoryName: "红包", icon: "gift.fill", colorHex: "#FF2D55",
                  merchant: "示例红包", note: "", accountName: "微信", timeText: "10月18日 10:00",
                  duplicate: .none, isManual: true, kindText: "收入", dateText: "2026年10月18日 10:00", channel: "微信", amount: 200.00),
        ReviewRow(index: 5, isIncome: false, amountText: "¥1,000.00", categoryName: "信用卡还款", icon: "creditcard.and.123", colorHex: "#30B0C7",
                  merchant: "", note: "", accountName: "储蓄卡-示例银行 → 未选信用卡", timeText: "10月18日 09:12",
                  duplicate: .none, isManual: false, kindText: "还款", dateText: "2026年10月18日 09:12",
                  fromAccount: "储蓄卡-示例银行", toAccount: "未选信用卡", channel: "银行", amount: 1000.00),
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
            receipt ? ReceiptTypeface.scaled(ReceiptTypeface.mono, style == .caption ? 12 : 15, relativeTo: style) : .system(style)
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
                             countText: "共 1 笔", totals: [("支出", "¥39.80")])
                .previewDisplayName("1 笔")
            ReceiptStackView(title: "识别结果", rows: SnippetPager.slice(ReviewRow.samples, page: 0), engineLine: "识别引擎：规则",
                             countText: SnippetPager.countText(ReviewRow.samples, page: 0),
                             totals: [("支出", "¥63.30"), ("收入", "¥200.00"), ("还款", "¥1,000.00")])
                .preferredColorScheme(.dark)
                .previewDisplayName("5 笔 · 第 1 页 · 深色")
            RecordSummaryCard(info: .sample, style: .receipt(.light), collapsed: .constant(false))
                .padding()
                .previewDisplayName("编辑页卡片")
        }
        .frame(width: 380)
        .background(Color(white: 0.92))
    }
}
#endif
