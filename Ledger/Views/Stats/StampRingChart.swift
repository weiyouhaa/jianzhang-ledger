import SwiftUI

/// 4.2 设计稿「支出构成 · STAMP CHART」印章环形图（复古印泥色盘 + 可点选图例 + 双圈印章外框）
struct StampRingChart: View {
    struct Slice: Identifiable {
        let id: String
        let label: String
        let amount: Double
        let color: Color
    }

    let slices: [Slice]
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedID: String?
    @State private var appearProgress: CGFloat = 0
    var total: Double { max(slices.reduce(0) { $0 + $1.amount }, 0.0001) }

    /// 超过 5 个分类时，前 4 项单列，第 5 项起合并为「其他」，确保环形图与图例严格闭合为 100%
    private var displaySlices: [Slice] {
        guard slices.count > 5 else { return slices }
        let top4 = Array(slices.prefix(4))
        let restAmount = slices.dropFirst(4).reduce(0) { $0 + $1.amount }
        guard restAmount > 0 else { return top4 }
        return top4 + [Slice(id: "__other__", label: "其他", amount: restAmount, color: .gray)]
    }

    /// 设计稿复古印泥色盘：朱砂红、琥珀褐、黛绿、青灰、暖灰褐
    private var inkPalette: [Color] {
        if theme.scheme == .dark {
            return [
                Color(hex: "#D65A4A"),
                Color(hex: "#C88B3A"),
                Color(hex: "#4B8F68"),
                Color(hex: "#8E877E"),
                Color(hex: "#6B645C")
            ]
        }
        return [
            Color(hex: "#A63628"),
            Color(hex: "#9A5F17"),
            Color(hex: "#295A3F"),
            Color(hex: "#5B6059"),
            Color(hex: "#8A7E72")
        ]
    }

    private func inkColor(at index: Int, fallback: Color) -> Color {
        guard theme.isReceipt else { return fallback }
        return inkPalette[index % inkPalette.count]
    }

    private var activeSlice: (index: Int, slice: Slice)? {
        let top = Array(displaySlices.enumerated())
        if let selectedID, let hit = top.first(where: { $0.element.id == selectedID }) {
            return (hit.offset, hit.element)
        }
        if let first = top.first {
            return (first.offset, first.element)
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                // 双层复古印章外圈
                Circle()
                    .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1.2)
                    .frame(width: 100, height: 100)
                Circle()
                    .strokeBorder(theme.rule, style: StrokeStyle(lineWidth: 0.9, dash: [2.5, 2]))
                    .frame(width: 92, height: 92)

                ForEach(Array(ringSlices.enumerated()), id: \.offset) { idx, item in
                    let isSelected = selectedID == nil || selectedID == item.id
                    Circle()
                        .trim(from: item.from * appearProgress, to: item.to * appearProgress)
                        .stroke(item.color.opacity(isSelected ? 1 : 0.32), style: StrokeStyle(lineWidth: 11, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 74, height: 74)
                        .animation(.spring(response: 0.45, dampingFraction: 0.84), value: item.to)
                }
                // 印章内孔
                Circle()
                    .fill(theme.cardFill)
                    .frame(width: 50, height: 50)
                    .overlay(
                        Circle().strokeBorder(theme.rule.opacity(0.75), lineWidth: 1)
                    )
                if let active = activeSlice {
                    VStack(spacing: 1) {
                        Text(active.slice.label)
                            .font(theme.serifLabelFont)
                            .foregroundStyle(theme.faint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(String(format: "%.1f%%", active.slice.amount / total * 100))
                            .font(theme.isReceipt ? theme.metaFont : Font.custom(ReceiptTypeface.monoBold, size: 11))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(inkColor(at: active.index, fallback: active.slice.color))
                        Text(Money.compact(active.slice.amount))
                            .font(theme.labelFont)
                            .monospacedDigit()
                            .foregroundStyle(theme.faint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(width: 100, height: 100)
            .onAppear {
                guard appearProgress == 0 else { return }
                if reduceMotion {
                    appearProgress = 1
                } else {
                    withAnimation(.spring(response: 0.52, dampingFraction: 0.84)) {
                        appearProgress = 1
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(displaySlices.enumerated()), id: \.element.id) { idx, s in
                    let color = inkColor(at: idx, fallback: s.color)
                    let isSel = selectedID == s.id
                    Button {
                        ReceiptHaptics.selection()
                        withAnimation(.snappy(duration: 0.22)) {
                            selectedID = isSel ? nil : s.id
                        }
                    } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(color)
                                .frame(width: 7, height: 7)
                            Text(s.label)
                                .font(theme.serifLabelFont)
                                .foregroundStyle(isSel ? color : theme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(String(format: "%.1f%% · %@", s.amount / total * 100, Money.format(s.amount)))
                                .font(theme.metaFont)
                                .monospacedDigit()
                                .foregroundStyle(isSel ? color : theme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var ringSlices: [(id: String, from: CGFloat, to: CGFloat, color: Color)] {
        var start: CGFloat = 0
        var out: [(String, CGFloat, CGFloat, Color)] = []
        let gap: CGFloat = 0.014
        for (idx, s) in displaySlices.enumerated() {
            let frac = CGFloat(s.amount / total)
            let end = min(1, start + max(0, frac - gap))
            out.append((s.id, start, end, inkColor(at: idx, fallback: s.color)))
            start = min(1, end + gap)
        }
        return out
    }
}
