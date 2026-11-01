import SwiftUI

extension View {
    /// 从 Tab 内推入的页面需要底部操作按钮时用这个，不要用 `.toolbar { ToolbarItem(placement: .bottomBar) }`：
    /// iOS 26/27 的悬浮玻璃 TabBar 会盖在底部工具栏上，按钮点不到。
    /// 这里在本页隐藏 TabBar，并把操作栏放进底部 safeAreaInset——列表 / 表单的内容会自动让出空间，能完整滚到操作栏上方。
    func bottomActionBar<Bar: View>(isPresented: Bool = true, @ViewBuilder _ bar: () -> Bar) -> some View {
        let content = bar()
        return self
            .toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isPresented {
                    ThemedActionBarChrome {
                        content
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                }
            }
    }
}

/// 3.2 (23) 底部操作栏外观：默认皮肤 = 原来的分隔线 + 系统栏材质；小票皮肤 = 虚线 + 纸色底 + 打字机字体
private struct ThemedActionBarChrome<Content: View>: View {
    @Environment(\.appTheme) private var theme
    @ViewBuilder let content: Content

    var body: some View {
        if theme.isReceipt {
            VStack(spacing: 0) {
                ThemedDashedRule()
                content
                    .font(theme.mono(.body, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .background(theme.paper.ignoresSafeArea(edges: .bottom))
        } else {
            VStack(spacing: 0) {
                Divider()
                content
            }
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }
}
