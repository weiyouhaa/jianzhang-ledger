
import SwiftUI
import SwiftData

/// 设置防窥密码（必须与 App 密码不同）
struct DecoyPasscodeSetupView: View {
    var onSaved: () -> Void

    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var first = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack {
                PasscodePad(
                    title: step == 0 ? "设置防窥密码" : "再输入一次",
                    subtitle: step == 0
                        ? "锁屏时输入此密码将进入另一套账本（与真实密码必须不同）"
                        : "请再次输入以防输错",
                    length: lock.passcodeLength,
                    message: message,
                    onComplete: { code in
                        if step == 0 {
                            if PasscodeStore.verify(code) {
                                message = "不能与 App 密码相同"
                                return false
                            }
                            first = code
                            step = 1
                            message = nil
                            return true
                        }
                        if code != first {
                            message = "两次输入不一致"
                            step = 0
                            first = ""
                            return false
                        }
                        if DecoyPasscodeStore.save(code) {
                            _ = SessionManager.shared.decoyContainerForEditing()
                            onSaved()
                            dismiss()
                            return true
                        }
                        message = "保存失败"
                        return false
                    }
                )
                Spacer()
            }
            .padding(.top, 40)
            .navigationTitle("防窥密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .interactiveDismissDisabled()
    }
}

/// 真实模式下编辑防窥数据：独立 modelContainer，不切换全局 SessionMode。
/// 不再外包一层 NavigationStack（HomeView / AssetsView 自带 NavigationStack，嵌套会让内部弹窗不稳定），
/// 「完成」按钮放在底部安全区。容器复用 SessionManager 里同一个防窥容器，避免同一个库文件被多个容器同时打开。
struct DecoyDataEditorHost: View {
    @Environment(\.dismiss) private var dismiss
    @State private var container: ModelContainer?
    @State private var tab = ScreenshotDemo.screen == "decoyeditor" ? 1 : 0

    var body: some View {
        // 顶栏与内容用 VStack 上下排布：TabView 整体位于顶栏下方，
        // 子页面自己的导航栏（大标题、右上角按钮）不会被顶栏盖住。
        // （TabView 外层的 safeAreaInset 在 iOS 26/27 上不会传进各 tab 的 NavigationStack。）
        VStack(spacing: 0) {
            HStack {
                Text("编辑防窥数据").font(.subheadline.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("decoy-editor-done")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar, ignoresSafeAreaEdges: .top)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("decoy-editor-bar")

            Group {
                if let container {
                    TabView(selection: $tab) {
                        HomeView()
                            .tabItem { Label("明细", systemImage: "list.bullet.rectangle.portrait") }
                            .tag(0)
                        AssetsView()
                            .tabItem { Label("资产", systemImage: "wallet.pass.fill") }
                            .tag(1)
                        NavigationStack {
                            Form {
                                Text("这里改的是防窥账本里的账户和流水，不影响真实数据。改完点「完成」。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .navigationTitle("说明")
                        }
                        .tabItem { Label("说明", systemImage: "info.circle") }
                        .tag(2)
                    }
                    .modelContainer(container)
                    // 嵌入的明细 / 资产页读防窥偏好（预算 ¥3,000、默认账户、隐藏金额…），真实页面不受影响
                    .ledgerPrefs(ModeDefaults.decoy)
                } else {
                    ProgressView("正在打开…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear { Money.symbolOverride = nil }
        .onAppear {
            Money.symbolOverride = ModeDefaults.decoy.string(forKey: SettingsKey.currencySymbol) ?? "¥"
            if container == nil {
                container = SessionManager.shared.decoyContainerForEditing()
            }
        }
    }
}
