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
                    VStack(spacing: 0) {
                        Divider()
                        content
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                }
            }
    }
}
