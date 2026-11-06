import SwiftUI

/// 4.2 设计稿「支出构成 · STAMP CHART」印章环形图（多层 stroke-dash 圆环 + 中心百分比）
struct StampRingChart: View {
    struct Slice: Identifiable {
        let id: String
        let label: String
        let amount: Double
        let color: Color
    }

    let slices: [Slice]
    var total: Double { max(slices.reduce(0) { $0 + $1.amount }, 0.0001) }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                // outer paper ring (stamp rim)
                Circle()
                    .strokeBorder(stampRim, lineWidth: 1.2)
                    .frame(width: 104, height: 104)
                Circle()
                    .strokeBorder(stampRim.opacity(0.35), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
                    .frame(width: 96, height: 96)

                ForEach(Array(ringSlices.enumerated()), id: \.offset) { _, item in
                    Circle()
                        .trim(from: item.from, to: item.to)
                        .stroke(item.color, style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 78, height: 78)
                }
                // inner hole like stamp
                Circle()
                    .fill(Color.clear)
                    .frame(width: 48, height: 48)
                    .overlay(
                        Circle().strokeBorder(stampRim.opacity(0.5), lineWidth: 1)
                    )
                VStack(spacing: 0) {
                    Text(topPercent)
                        .font(Font.custom(ReceiptTypeface.monoBold, size: 11))
                        .monospacedDigit()
                    Text("STAMP")
                        .font(.custom(ReceiptTypeface.mono, size: 7))
                        .foregroundStyle(stampRim)
                }
            }
            .frame(width: 104, height: 104)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(slices.prefix(3))) { s in
                    HStack {
                        Text("● \(s.label)")
                            .font(.ui(.caption))
                            .foregroundStyle(s.color)
                        Spacer()
                        Text(String(format: "%.1f%% · %@", s.amount / total * 100, Money.format(s.amount)))
                            .font(.custom(ReceiptTypeface.mono, size: 11))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var stampRim: Color { Color.themeAccent.opacity(0.55) }

    private var topPercent: String {
        guard let first = slices.first else { return "—" }
        return String(format: "%.1f%%", first.amount / total * 100)
    }

    private var ringSlices: [(from: CGFloat, to: CGFloat, color: Color)] {
        var start: CGFloat = 0
        var out: [(CGFloat, CGFloat, Color)] = []
        // small gap between slices like stamp notches
        let gap: CGFloat = 0.012
        for s in slices.prefix(5) {
            let frac = CGFloat(s.amount / total)
            let end = min(1, start + max(0, frac - gap))
            out.append((start, end, s.color))
            start = min(1, end + gap)
        }
        return out
    }
}
