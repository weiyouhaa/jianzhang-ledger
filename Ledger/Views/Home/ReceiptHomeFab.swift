import SwiftUI

/// 4.1 设计稿三种悬浮方案：双联火漆印章（推荐）/ 中置出纸胶囊 / 侧边黄铜拉环
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

    /// 方案 A：右下双联——上「识图」纸签，下朱砂「+ 记账」圆章
    private var sealFab: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button(action: onOCR) {
                HStack(spacing: 4) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("识图")
                        .font(theme.labelFont)
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.paper)
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.45), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("识图记账")
            .accessibilityIdentifier("home-ocr")

            Button(action: onAdd) {
                VStack(spacing: 2) {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .bold))
                    Text("记账")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(theme.paper)
                .frame(width: 64, height: 64)
                .background(
                    Circle()
                        .fill(theme.accent)
                        .shadow(color: theme.accent.opacity(0.35), radius: 6, y: 3)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("记一笔")
            .accessibilityIdentifier("home-add")
        }
    }

    /// 方案 B：导航栏上方中置出纸胶囊
    private var capsuleFab: some View {
        HStack(spacing: 0) {
            Button(action: onOCR) {
                Label("识图", systemImage: "camera.fill")
                    .font(theme.metaFont)
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .accessibilityIdentifier("home-ocr")
            Rectangle().fill(theme.rule).frame(width: 1, height: 22)
            Button(action: onAdd) {
                Label("记账", systemImage: "plus")
                    .font(theme.metaFont.weight(.semibold))
                    .foregroundStyle(theme.paper)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(theme.accent)
            }
            .accessibilityIdentifier("home-add")
        }
        .background(Capsule().fill(theme.paper))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(theme.rule, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
        // 中置：由 overlay 的 alignment 在外层改；此处仍放右下时靠外层 padding 调整
        .offset(x: -110, y: -8)
    }

    /// 方案 C：右侧边拉环
    private var pulltabFab: some View {
        VStack(spacing: 0) {
            Button(action: onOCR) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 36, height: 36)
            }
            .accessibilityIdentifier("home-ocr")
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.paper)
                    .frame(width: 36, height: 44)
                    .background(theme.accent)
            }
            .accessibilityIdentifier("home-add")
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.rule, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
        .offset(x: 10)
    }
}
