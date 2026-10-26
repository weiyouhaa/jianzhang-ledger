import SwiftUI

/// 明细的「按天卡片」（2.0 (18) 重新设计的缩略界面）
/// 折叠时每天就是一张卡片：日期徽章 + 今天/昨天/星期 + 日期·笔数，右侧当天支出（主色）/ 收入（绿色）、
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
                        Text(relative)
                            .font(.headline)
                            .foregroundStyle(isToday ? Color.accentColor : Color.primary)
                        Text("\(dateLabel) · \(count) 笔")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(collapsed ? "展开当天明细" : "折叠当天明细")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("home-day-card")
    }

    private var dayBadge: some View {
        Text(DaySummary.dayNumber(day, calendar: calendar))
            .font(.title2.weight(.bold))
            .fontDesign(.rounded)
            .monospacedDigit()
            .foregroundStyle(isToday ? Color.white : Color.accentColor)
            .padding(.horizontal, 6)
            .frame(minWidth: 44, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isToday ? Color.accentColor : Color.accentColor.opacity(0.14))
            )
    }

    @ViewBuilder
    private func amounts(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if expense > 0 {
                Text("-" + Money.masked(expense, hidden: hideAmounts))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            if income > 0 {
                Text("+" + Money.masked(income, hidden: hideAmounts))
                    .font((expense > 0 ? Font.subheadline : Font.headline).monospacedDigit())
                    .foregroundStyle(.green)
            }
            if expense <= 0 && income <= 0 {
                Text("无收支")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private var chipStrip: some View {
        HStack(spacing: -6) {
            ForEach(chips) { chip in
                CategoryIcon(icon: chip.icon, color: chip.color, size: 24)
                    .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                    .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(collapsed ? 0 : 90))
            .accessibilityHidden(true)
    }

    private var bar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(Color.accentColor.opacity(0.65))
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
        parts.append(collapsed ? "已折叠" : "已展开")
        return parts.joined(separator: "，")
    }
}
