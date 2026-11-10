import SwiftUI

/// 设计稿三种悬浮方案：双联火漆印章（推荐）/ 中置出纸胶囊 / 侧边黄铜拉环
struct ReceiptHomeFab: View {
    var style: ReceiptFabStyle = .seal
    var onAdd: () -> Void
    var onOCR: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        switch style {
        case .seal:
            sealFab
        case .capsule:
            capsuleFab
        case .pulltab:
            pulltabFab
        }
    }

    /// 方案 A：识图纸签连在火漆圆章左侧（针对 iPhone 15 Pro Max 右手拇指热区优化，固定尺寸不截断）
    private var sealFab: some View {
        HStack(spacing: -8) {
            Button(action: onOCR) {
                HStack(spacing: 5) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.accent)
                    Text("识图")
                        .font(theme.serifLabelFont.weight(.semibold))
                        .foregroundStyle(theme.ink)
                }
                .fixedSize()
                .padding(.leading, 11)
                .padding(.trailing, 16)
                .padding(.vertical, 7)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 4, topTrailingRadius: 4)
                        .fill(LinearGradient(colors: [theme.cardFill, theme.paper], startPoint: .top, endPoint: .bottom))
                )
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 4, topTrailingRadius: 4)
                        .strokeBorder(theme.accent.opacity(0.45), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("识图记账")
            .accessibilityIdentifier("home-ocr")
            .zIndex(0)

            Button(action: onAdd) {
                VStack(spacing: 0) {
                    Text("+")
                        .font(ReceiptTypeface.scaled(ReceiptTypeface.mono, 25, relativeTo: .title2))
                        .offset(y: -1)
                    Text("记账")
                        .font(ReceiptTypeface.scaled(ReceiptTypeface.cjkSerifBold, 9.5, relativeTo: .caption2))
                        .tracking(1.2)
                        .opacity(0.95)
                }
                .foregroundStyle(Color(red: 1, green: 0.99, blue: 0.97))
                .frame(width: 56, height: 56)
                .background(waxSeal)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("记一笔")
            .accessibilityIdentifier("home-add")
            .zIndex(1)
        }
        .fixedSize()
    }

    /// 方案 B：底部中央双联胶囊，不挡住左右金额
    private var capsuleFab: some View {
        HStack(spacing: 6) {
            Button(action: onOCR) {
                HStack(spacing: 5) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 13, weight: .semibold))
                    Text("识图核对")
                        .font(theme.metaFont.weight(.medium))
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(theme.accent.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("识图记账")
            .accessibilityIdentifier("home-ocr")

            Button(action: onAdd) {
                HStack(spacing: 4) {
                    Text("＋").font(theme.rowAmountFont)
                    Text("记一笔").font(theme.metaFont.weight(.semibold))
                }
                .foregroundStyle(Color(red: 1, green: 0.99, blue: 0.98))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [theme.accent, theme.accent.opacity(0.88)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                )
                .overlay(Capsule().strokeBorder(Color(red: 0.95, green: 0.87, blue: 0.81).opacity(0.8), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("记一笔")
            .accessibilityIdentifier("home-add")
        }
        .padding(5)
        .background(Capsule().fill(theme.cardFill))
        .overlay(Capsule().strokeBorder(theme.accent.opacity(0.42), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
    }

    /// 方案 C：贴右缘的票夹拉环
    private var pulltabFab: some View {
        VStack(spacing: 0) {
            Button(action: onAdd) {
                VStack(spacing: 1) {
                    Text("＋")
                        .font(theme.rowAmountFont)
                    Text("记账")
                        .font(theme.labelFont)
                        .tracking(1.2)
                }
                .foregroundStyle(Color(red: 1, green: 0.99, blue: 0.98))
                .frame(width: 48, height: 50)
                .background(theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("记一笔")
            .accessibilityIdentifier("home-add")

            Button(action: onOCR) {
                VStack(spacing: 1) {
                    Text("[¥]")
                        .font(ReceiptTypeface.scaled(ReceiptTypeface.monoBold, 11, relativeTo: .caption2))
                    Text("识图")
                        .font(theme.labelFont)
                }
                .foregroundStyle(theme.accent)
                .frame(width: 48, height: 42)
                .background(theme.accent.opacity(0.12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("识图记账")
            .accessibilityIdentifier("home-ocr")
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous))
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
    }

    private var waxSeal: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        theme.accent.opacity(0.85),
                        theme.accent,
                        theme.accent.opacity(0.72)
                    ],
                    center: UnitPoint(x: 0.32, y: 0.28),
                    startRadius: 1,
                    endRadius: 42
                )
            )
            .overlay(Circle().strokeBorder(Color(red: 0.95, green: 0.87, blue: 0.81), lineWidth: 2))
            .overlay(Circle().strokeBorder(theme.accent.opacity(0.45), lineWidth: 1.5).padding(-2))
            .shadow(color: theme.accent.opacity(0.45), radius: 10, y: 6)
            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
    }
}
