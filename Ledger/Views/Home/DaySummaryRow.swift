import SwiftUI

/// 明细的「按天卡片」（2.0 (18) 重新设计的缩略界面）
/// 折叠时每天就是一张卡片：日期徽章 + 今天/昨天/星期·笔数 + 日期，右侧当天支出（主色）/ 收入（绿色）/ 结余（小字）、
/// 支出最多的分类图标，底部细条表示当天支出占范围内单日最高支出的比例。整行可点按展开 / 折叠。
struct DaySummaryRow: View {
    struct Chip: Identifiable {
        let id: String
        let icon: String
        let color: Color
    }

    let day: Date
    let count: Int
    let expense: Double
    let income: Double
    let chips: [Chip]
    let barRatio: Double
    let collapsed: Bool
    let hideAmounts: Bool

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.appTheme) private var theme
    private var calendar: Calendar { DateText.calendar }
    private var isToday: Bool { calendar.isDateInToday(day) }
    private var relative: String { DaySummary.relativeLabel(day, calendar: calendar) }
    private var dateLabel: String { DaySummary.dateLabel(day, calendar: calendar) }

    var body: some View {
        let large = typeSize.isAccessibilitySize
        let layout = large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))

        VStack(alignment: .leading, spacing: 10) {
            layout {
                HStack(spacing: 12) {
                    dayBadge
                    VStack(alignment: .leading, spacing: 2) {
                        // 3.1 (22) 笔数挪到第一行（小字），第二行只放日期，打字机字体下也不再折行
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(relative)
                                .font(theme.isReceipt ? theme.rowAmountFont : theme.title(.headline, weight: .semibold))
                                .foregroundStyle(theme.isReceipt ? theme.ink : (isToday ? theme.accent : theme.ink))
                            Text("\(count) 笔")
                                .font(theme.isReceipt ? theme.metaFont : theme.body(.caption))
                                .foregroundStyle(theme.faint)
                        }
                        .lineLimit(large ? nil : 1)
                        Text(dateLabel)
                            .font(theme.isReceipt ? theme.metaFont : theme.body(.subheadline))
                            .foregroundStyle(theme.faint)
                            .lineLimit(large ? nil : 1)
                            .minimumScaleFactor(0.8)
                    }
                    // 大字号时换行，不截断日期
                    .fixedSize(horizontal: false, vertical: true)
                    if large {
                        Spacer(minLength: 0)
                        chevron
                    }
                }
                if !large { Spacer(minLength: 4) }
                HStack(spacing: 10) {
                    if !chips.isEmpty && !large { chipStrip }
                    amounts(alignment: large ? .leading : .trailing)
                    if !large { chevron }
                }
            }
            if barRatio > 0 && !hideAmounts { bar }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, theme.isReceipt ? 4 : 0)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(collapsed ? "展开当天明细" : "折叠当天明细")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("home-day-card")
    }

    @ViewBuilder
    private var dayBadge: some View {
        if theme.isReceipt {
            // 3.5 (26) 小票皮肤：不再用实心色块，改成打字机大号日期数字；今天用暗红 + 下划线（同参考图当前月份）
            Text(DaySummary.dayNumber(day, calendar: calendar))
                .font(ReceiptTypeface.scaled(ReceiptTypeface.monoBold, 24, relativeTo: .title2))
                .monospacedDigit()
                .foregroundStyle(isToday ? theme.accent : theme.ink)
                .padding(.bottom, 2)
                .overlay(alignment: .bottom) {
                    if isToday { Rectangle().fill(theme.accent).frame(height: 1.5) }
                }
                .frame(minWidth: 36, minHeight: 40)
        } else {
            defaultDayBadge
        }
    }

    private var defaultDayBadge: some View {
        Text(DaySummary.dayNumber(day, calendar: calendar))
            .font(theme.amount(.title2))
            .monospacedDigit()
            .foregroundStyle(isToday ? (theme.isReceipt ? theme.paper : Color.white) : theme.accent)
            .padding(.horizontal, 6)
            .frame(minWidth: 44, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: theme.isReceipt ? 4 : 12,
                                 style: theme.isReceipt ? .circular : .continuous)
                    .fill(isToday ? theme.accent : theme.accent.opacity(theme.isReceipt ? 0.18 : 0.14))
            )
    }

    @ViewBuilder
    private func amounts(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if expense > 0 {
                Text("-" + Money.masked(expense, hidden: hideAmounts))
                    .font(theme.isReceipt ? theme.rowAmountFont : theme.amount(.headline))
                    .receiptDigits(theme.isReceipt)
                    .foregroundStyle(theme.ink)
            }
            if income > 0 {
                Text("+" + Money.masked(income, hidden: hideAmounts))
                    .font(theme.isReceipt ? theme.rowAmountFont : theme.amount(expense > 0 ? .subheadline : .headline))
                    .receiptDigits(theme.isReceipt)
                    .foregroundStyle(theme.income)
            }
            if expense <= 0 && income <= 0 {
                Text("无收支")
                    .font(theme.body(.subheadline))
                    .foregroundStyle(theme.faint)
            } else {
                // 3.1 (22) 每日结余 = 收入 − 支出（转账等不计），小字淡色
                Text(balanceText)
                    .font(theme.isReceipt ? theme.labelFont : theme.body(.caption))
                    .monospacedDigit()
                    .foregroundStyle(balance > 0.004 && !hideAmounts ? theme.income.opacity(0.8) : theme.faint)
                    .accessibilityIdentifier("home-day-balance")
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private var balance: Double { DaySummary.balance(expense: expense, income: income) }

    private var balanceText: String {
        DaySummary.balanceText(balance, formatted: Money.masked(abs(balance), hidden: hideAmounts), hidden: hideAmounts)
    }

    @ViewBuilder
    private var chipStrip: some View {
        if theme.isReceipt {
            // 3.5 (26) 小票皮肤：分类用一排小圆点（参考图的柔和色点），不再叠放彩色图标
            HStack(spacing: 4) {
                ForEach(chips) { chip in
                    Circle().fill(chip.color).frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
        } else {
            defaultChipStrip
        }
    }

    private var defaultChipStrip: some View {
        HStack(spacing: -6) {
            ForEach(chips) { chip in
                CategoryIcon(icon: chip.icon, color: chip.color, size: 24)
                    .background(Circle().fill(theme.paper))
                    .overlay(Circle().stroke(theme.paper, lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.ui(.footnote).weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(collapsed ? 0 : 90))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var bar: some View {
        if theme.isReceipt {
            ReceiptBar(ratio: max(barRatio, 0.01), fill: theme.accent.opacity(0.55), track: theme.rule.opacity(0.45))
        } else {
            defaultBar
        }
    }

    private var defaultBar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.rule.opacity(theme.isReceipt ? 1 : 0.5))
                Capsule()
                    .fill(theme.accent.opacity(0.65))
                    .frame(width: max(4, g.size.width * barRatio))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private var accessibilityText: String {
        var parts = ["\(relative)，\(dateLabel)", "\(count) 笔"]
        if expense > 0 { parts.append("支出 " + Money.masked(expense, hidden: hideAmounts)) }
        if income > 0 { parts.append("收入 " + Money.masked(income, hidden: hideAmounts)) }
        if expense > 0 || income > 0 { parts.append(balanceText) }
        parts.append(collapsed ? "已折叠" : "已展开")
        return parts.joined(separator: "，")
    }
}
