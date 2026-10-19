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
                            // 确保防窥库已创建并写入预设
                            _ = DataStore.makeDecoyContainer(inMemory: false)
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

/// 真实模式下编辑防窥数据：用独立 modelContainer，不切换全局 SessionMode（避免锁屏态错乱）
struct DecoyDataEditorHost: View {
    @Environment(\.dismiss) private var dismiss
    private let container = DataStore.makeDecoyContainer(inMemory: false)

    var body: some View {
        NavigationStack {
            TabView {
                HomeView()
                    .tabItem { Label("明细", systemImage: "list.bullet.rectangle.portrait") }
                AssetsView()
                    .tabItem { Label("资产", systemImage: "wallet.pass.fill") }
                DecoyEditorSettingsStub()
                    .tabItem { Label("设置", systemImage: "gearshape.fill") }
            }
            .navigationTitle("编辑防窥数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .modelContainer(container)
    }
}

/// 防窥编辑器里的极简设置，避免露出「防窥」字样或真实备份入口
private struct DecoyEditorSettingsStub: View {
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("这里改的是防窥账本里的账户和流水，不影响真实数据。改完点右上角「完成」。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("说明")
        }
    }
}
