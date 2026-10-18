import SwiftUI
import AppIntents

/// 「识图记账」快捷指令设置教程
struct ShortcutGuideView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("截一张支付成功页，自动记一笔", systemImage: "sparkles")
                        .font(.headline)
                    Text("支持支付宝、微信、云闪付、银行 App 的支付结果页 / 账单详情，以及小票照片和银行短信截图。识别在本机完成，不联网。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("方案一：截屏后自动识别（推荐）") {
                step(1, "打开「快捷指令」App，点右上角 ＋ 新建快捷指令。")
                step(2, "添加操作「截屏」（Take Screenshot）。")
                step(3, "添加操作「识图记账」（搜索「简账」），图片参数会自动连接上一步的截屏。")
                step(4, "（可选）打开「保存前确认」，或指定分类。")
                step(5, "把快捷指令命名为「识图记账」。")
                step(6, "前往 设置 › 辅助功能 › 触控 › 轻点背面，选择「轻点两下」→ 该快捷指令；iPhone 15 Pro 及以上也可在 设置 › 操作按钮 中绑定。")
                Text("之后在支付成功页轻点两下手机背面，即可自动截屏并记账。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("方案二：从相册选择") {
                step(1, "新建快捷指令，添加「选择照片」。")
                step(2, "添加「识图记账」，图片参数选择上一步的照片。")
                step(3, "可加入主屏幕或在共享表单中使用。")
            }

            Section("方案三：直接用 Siri") {
                Text("对 Siri 说「简账记一笔」「简账本月收支」，或「用简账识图记账」。")
            }

            Section {
                ShortcutsLink()
                    .frame(maxWidth: .infinity)
            } footer: {
                Text("快捷指令在后台运行，不需要解锁 App 密码，但需要设备已解锁。识别结果可在首页查看和修改。")
            }
        }
        .navigationTitle("识图记账教程")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}
