import SwiftUI

/// 分类圆形图标
struct CategoryIcon: View {
    let icon: String
    let color: Color
    var size: CGFloat = 38
    var selected: Bool = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        if theme.isReceipt {
            // 3.5 (26) 小票皮肤：极淡的墨水色圆底 + 细线条图标（颜色已在 Color.skinTint 里降饱和）
            ZStack {
                Circle()
                    .fill(selected ? color : color.opacity(theme.scheme == .dark ? 0.20 : 0.11))
                Image(systemName: icon)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(selected ? theme.paper : color)
            }
            .frame(width: size, height: size)
            .overlay(
                Circle().strokeBorder(theme.ink.opacity(selected ? 0.55 : 0), lineWidth: 1).padding(-4)
            )
        } else {
            ZStack {
                Circle()
                    .fill(selected ? color : color.opacity(0.16))
                Image(systemName: icon)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : color)
            }
            .frame(width: size, height: size)
            .overlay(
                Circle().strokeBorder(color.opacity(selected ? 0.35 : 0), lineWidth: 3).padding(-4)
            )
        }
    }
}

/// 列表中的一条记录
struct RecordRow: View {
    let record: LedgerRecord
    var showDate: Bool = false
    /// 账户详情：该条记录发生后的余额文案（如「余额 ¥1,234.56」）；首页明细不传
    var runningBalanceText: String? = nil
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: theme.isReceipt ? ReceiptStyle.Space.s : 12) {
            CategoryIcon(icon: record.categoryIcon, color: record.categoryColor, size: theme.isReceipt ? 32 : 38)
            VStack(alignment: .leading, spacing: theme.isReceipt ? ReceiptStyle.Space.xxs : 3) {
                Text(record.displayTitle)
                    .font(theme.isReceipt ? theme.rowTitleFont : theme.body(.body))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if record.isCreditRepayment {
                        // 信用卡还款：付款账户 → 信用卡（标题无备注时已是「信用卡还款」）
                        if !record.note.isEmpty {
                            Text("信用卡还款")
                            Text("·")
                        }
                        Text("\(record.accountName.isEmpty ? "未选账户" : record.accountName) → \(record.toAccount?.name ?? "")")
                            .accessibilityIdentifier("repayment-route")
                    } else {
                        Text(record.categoryName)
                    }
                    if record.kind == .transfer {
                        if record.fee > 0 {
                            Text("·")
                            Text("手续费 \(Money.format(record.fee))")
                        }
                    } else if !record.accountName.isEmpty {
                        Text("·")
                        Text(record.accountName)
                    }
                    if record.source == "ocr" {
                        if theme.isReceipt {
                            Text("[识图]")
                                .font(theme.labelFont)
                                .tracking(ReceiptStyle.labelTracking * 0.4)
                                .foregroundStyle(theme.accent)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
                        } else {
                            Image(systemName: "text.viewfinder")
                        }
                    } else if record.source == "shortcut" {
                        Image(systemName: "square.2.layers.3d")
                    }
                }
                .font(theme.isReceipt ? theme.metaFont : theme.body(.caption))
                .foregroundStyle(theme.faint)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: theme.isReceipt ? ReceiptStyle.Space.xxs : 3) {
                Text(record.amountText)
                    .font(theme.isReceipt ? theme.rowAmountFont : theme.amount(.body, weight: .semibold))
                    .receiptDigits(theme.isReceipt)
                    .foregroundStyle(amountColor)
                Text(showDate ? DateText.monthDayTime.string(from: record.date) : DateText.time.string(from: record.date))
                    .font(theme.mono(.caption2))
                    .foregroundStyle(theme.faint)
                if let runningBalanceText {
                    Text(runningBalanceText)
                        .font(.ui(.caption2))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(.vertical, theme.isReceipt ? ReceiptStyle.Space.xxs : 2)
        .contentShape(Rectangle())
    }

    private var amountColor: Color {
        switch record.kind {
        case .income: return theme.income
        case .contribution: return theme.isReceipt ? theme.caution : Color(hex: "#E8A33D")
        case .expense: return theme.ink
        case .transfer, .adjustment: return theme.faint
        }
    }
}

/// 预算进度条
struct BudgetProgressView: View {
    let spent: Double
    let budget: Double
    var light: Bool = false
    var title: String = "本月预算"
    @Environment(\.appTheme) private var theme

    var body: some View {
        let ratio = budget > 0 ? spent / budget : 0
        let over = ratio > 1
        if theme.isReceipt {
            // 4.1 设计稿：OVERRUN 朱砂印 + [|····] 字符刻度 + 细条
            VStack(alignment: .leading, spacing: ReceiptStyle.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: ReceiptStyle.Space.xs) {
                    ReceiptLabelText(text: title, color: theme.faint)
                    Text(Money.format(budget))
                        .font(theme.metaFont).monospacedDigit()
                        .foregroundStyle(theme.faint)
                    Spacer(minLength: 4)
                    if over {
                        Text("OVERRUN · 超支 \(Money.format(spent - budget))")
                            .font(theme.labelFont)
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.accent.opacity(0.55), lineWidth: 1.2))
                            .rotationEffect(.degrees(-2))
                    } else {
                        Text("剩余 \(Money.format(budget - spent))")
                            .font(theme.metaFont).monospacedDigit()
                            .foregroundStyle(theme.ink)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                HStack(spacing: 8) {
                    Text(over ? "超支" : "剩余 \(Money.format(max(0, budget - spent)))")
                        .font(theme.metaFont)
                        .foregroundStyle(theme.budgetColor(ratio, threshold: 0.8))
                    Text(Self.tickBarPublic(ratio: ratio))
                        .font(theme.metaFont)
                        .foregroundStyle(theme.budgetColor(ratio, threshold: 0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                ReceiptBar(ratio: ratio, fill: theme.budgetColor(ratio, threshold: 0.8), track: theme.rule.opacity(0.6))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(title) \(Money.format(budget))")
                    Spacer()
                    Text(over ? "超支 \(Money.format(spent - budget))" : "剩余 \(Money.format(budget - spent))")
                }
                .font(.ui(.caption))
                .foregroundStyle(light ? Color.white.opacity(0.9) : Color.secondary)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(light ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(barColor(ratio))
                            .frame(width: geo.size.width * min(max(ratio, 0), 1))
                    }
                }
                .frame(height: 8)
            }
        }
    }

    /// 设计稿字符刻度：[||||||||····] 满格 | / 空格 ·
    static func tickBarPublic(ratio: Double, width: Int = 20) -> String {
        let filled = max(0, min(width, Int((min(ratio, 1) * Double(width)).rounded())))
        return "[" + String(repeating: "|", count: filled) + String(repeating: "·", count: width - filled) + "]"
    }

    private func barColor(_ ratio: Double) -> Color {
        if ratio > 1 { return .red }
        if ratio > 0.8 { return .orange }
        return light ? .white : Color.themeIncome
    }
}

/// 金额 + 标题的小统计块
struct StatBlock: View {
    let title: String
    let value: String
    var alignment: HorizontalAlignment = .leading
    var light: Bool = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: alignment, spacing: theme.isReceipt ? ReceiptStyle.Space.xxs : 4) {
            if theme.isReceipt {
                ReceiptLabelText(text: title, color: theme.faint)
            } else {
                Text(title)
                    .font(theme.mono(.caption))
                    .foregroundStyle(light ? theme.heroFaint : theme.faint)
            }
            Text(value)
                .font(theme.isReceipt ? theme.rowAmountFont : theme.amount(.headline))
                .receiptDigits(theme.isReceipt)
                .foregroundStyle(light ? theme.heroInk : theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}
