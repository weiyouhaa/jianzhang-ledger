import SwiftUI

/// 分类图标：默认皮肤为彩色圆章；小票皮肤为复古汉字方印（[餐] [行] [购] [住] [入] [转]）
struct CategoryIcon: View {
    let icon: String
    let color: Color
    var size: CGFloat = 38
    var selected: Bool = false
    var name: String? = nil
    var kindRaw: String? = nil
    @Environment(\.appTheme) private var theme

    var body: some View {
        if theme.isReceipt {
            let ch = ReceiptSquareStamp.sealCharacter(name: name, icon: icon, kindRaw: kindRaw)
            let stampTint: Color? = {
                if selected { return theme.accent }
                if kindRaw == "income" { return theme.income }
                if ch == "住" || ch == "还" { return theme.accent }
                return nil
            }()
            ReceiptSquareStamp(character: ch, tint: stampTint, size: size, highlighted: selected)
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
    /// 首页连续热敏纸：行顶虚线，代替列表分隔线
    var showsTopRule: Bool = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: theme.isReceipt ? 10 : 8) {
            // 设计稿：同一天里的两笔之间是 1pt 实线（日结单头部才是虚线）
            if showsTopRule {
                Rectangle().fill(theme.rule.opacity(0.75)).frame(height: 1)
                    .accessibilityHidden(true)
            }
            row
        }
    }

    private var row: some View {
        HStack(spacing: theme.isReceipt ? 12 : 12) {
            CategoryIcon(
                icon: record.categoryIcon,
                color: record.categoryColor,
                size: theme.isReceipt ? 34 : 38,
                name: record.isCreditRepayment ? "还款" : record.categoryName,
                kindRaw: record.kindRaw
            )
            VStack(alignment: .leading, spacing: theme.isReceipt ? 3 : 3) {
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
                    if record.kind != .transfer, !record.merchant.isEmpty, !record.note.isEmpty, record.merchant != record.note {
                        let extra = record.displayTitle == record.merchant ? record.note : record.merchant
                        if !extra.isEmpty {
                            Text("·")
                            Text(extra)
                        }
                    }
                    if record.source == "ocr" {
                        if theme.isReceipt {
                            sourceMicroTag("[识图]", tint: theme.accent)
                        } else {
                            Image(systemName: "text.viewfinder")
                        }
                    } else if record.source == "shortcut" {
                        if theme.isReceipt {
                            sourceMicroTag("[快捷]", tint: theme.faint)
                        } else {
                            Image(systemName: "square.2.layers.3d")
                        }
                    } else if record.source == "recurring" {
                        if theme.isReceipt {
                            sourceMicroTag("[周期]", tint: theme.faint)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    } else if record.source == "import" {
                        if theme.isReceipt {
                            sourceMicroTag("[导入]", tint: theme.faint)
                        } else {
                            Image(systemName: "tray.and.arrow.down")
                        }
                    }
                }
                .font(theme.isReceipt ? theme.serifLabelFont : theme.body(.caption))
                .foregroundStyle(theme.faint)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: theme.isReceipt ? 3 : 3) {
                Text(record.amountText)
                    .font(theme.isReceipt ? theme.rowAmountFont : theme.amount(.body, weight: .semibold))
                    .receiptDigits(theme.isReceipt)
                    .foregroundStyle(amountColor)
                Text(showDate ? DateText.monthDayTime.string(from: record.date) : DateText.time.string(from: record.date))
                    .font(theme.mono(.caption2))
                    .foregroundStyle(theme.faint)
                if let runningBalanceText {
                    Text(runningBalanceText)
                        .font(theme.isReceipt ? theme.labelFont : .ui(.caption2))
                        .foregroundStyle(theme.faint.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(.vertical, theme.isReceipt ? 4 : 2)
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

    private func sourceMicroTag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(theme.labelFont)
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(tint.opacity(0.45), lineWidth: 0.9))
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
        let pct = Int((min(max(ratio, 0), 9.99) * 100).rounded())
        let over = ratio > 1
        if theme.isReceipt {
            // 设计稿：预算标签 + 已用百分比 + OVERRUN 朱砂印/剩余额度 + 2px 细条
            VStack(alignment: .leading, spacing: ReceiptStyle.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: ReceiptStyle.Space.xs) {
                    Text(title)
                        .font(theme.serifLabelFont)
                        .foregroundStyle(theme.faint)
                    Text("\(Money.format(budget))（已用 \(pct)%）")
                        .font(theme.metaFont).monospacedDigit()
                        .foregroundStyle(theme.faint)
                    Spacer(minLength: 4)
                    if over {
                        VermilionStamp(text: "OVERRUN · 超支 \(Money.format(spent - budget))")
                    } else {
                        Text("剩余 \(Money.format(budget - spent))")
                            .font(theme.metaFont).monospacedDigit()
                            .foregroundStyle(theme.ink)
                            .contentTransition(.numericText())
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                ReceiptBudgetMeter(ratio: ratio, fill: theme.budgetColor(ratio, threshold: 0.8))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(title) \(Money.format(budget)) · 已用 \(pct)%")
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
    var valueColor: Color? = nil
    /// 设计稿：首页汇总 16 / 资产盘点 15 / 统计审计 14
    var valueSize: CGFloat = ReceiptStyle.Size.rowAmount
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: alignment, spacing: theme.isReceipt ? ReceiptStyle.Space.xxs : 4) {
            if theme.isReceipt {
                Text(title)
                    .font(theme.serifLabelFont)
                    .foregroundStyle(theme.faint)
            } else {
                Text(title)
                    .font(theme.mono(.caption))
                    .foregroundStyle(light ? theme.heroFaint : theme.faint)
            }
            Text(value)
                .font(theme.isReceipt ? theme.amountFont(valueSize) : theme.amount(.headline))
                .receiptDigits(theme.isReceipt)
                .foregroundStyle(valueColor ?? (light ? theme.heroInk : theme.ink))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}
