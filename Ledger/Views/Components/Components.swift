import SwiftUI

/// 分类圆形图标
struct CategoryIcon: View {
    let icon: String
    let color: Color
    var size: CGFloat = 38
    var selected: Bool = false

    var body: some View {
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

/// 列表中的一条记录
struct RecordRow: View {
    let record: LedgerRecord
    var showDate: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(icon: record.categoryIcon, color: record.categoryColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(record.categoryName)
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
                        Image(systemName: "text.viewfinder")
                    } else if record.source == "shortcut" {
                        Image(systemName: "square.2.layers.3d")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(record.amountText)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(amountColor)
                Text(showDate ? DateText.monthDayTime.string(from: record.date) : DateText.time.string(from: record.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var amountColor: Color {
        switch record.kind {
        case .income: return .green
        case .expense: return .primary
        case .transfer, .adjustment: return .secondary
        }
    }
}

/// 预算进度条
struct BudgetProgressView: View {
    let spent: Double
    let budget: Double
    var light: Bool = false

    var body: some View {
        let ratio = budget > 0 ? spent / budget : 0
        let over = ratio > 1
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("本月预算 \(Money.format(budget))")
                Spacer()
                Text(over ? "超支 \(Money.format(spent - budget))" : "剩余 \(Money.format(budget - spent))")
            }
            .font(.caption)
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

    private func barColor(_ ratio: Double) -> Color {
        if ratio > 1 { return .red }
        if ratio > 0.8 { return .orange }
        return light ? .white : .green
    }
}

/// 金额 + 标题的小统计块
struct StatBlock: View {
    let title: String
    let value: String
    var alignment: HorizontalAlignment = .leading
    var light: Bool = false

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(light ? Color.white.opacity(0.8) : Color.secondary)
            Text(value)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(light ? Color.white : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}
