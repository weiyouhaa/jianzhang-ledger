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
                step(4, "「审核方式」默认为「弹窗审核」：识别后不打开 App，直接在弹窗里列出每一笔，可「全部保存」「修改」「删除」「添加一笔」；想一键记账可改为「直接保存」。也可以指定分类或账户。")
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

            Section {
                Label("✅ 全部保存：保存列表中未跳过的记录", systemImage: "checkmark.circle")
                Label("✏️ 修改：可在弹窗内改收支类型、分类、账户，或把时间改为现在", systemImage: "pencil")
                Label("⌨️ 在 App 里改金额 / 商户 / 时间：先保存当前列表，再打开简账编辑对应那一笔（弹窗里不再弹出键盘）", systemImage: "arrow.up.forward.app")
                Label("➕ 添加一笔（打开 App）：先保存列表，再打开新建记账页", systemImage: "plus.circle")
                Label("🗑 删除 / ♻️ 重复项 / 取消", systemImage: "trash")
            } header: {
                Text("弹窗审核")
            } footer: {
                Text("iOS 26+ 用按钮 + 卡片；iOS 17 / 18 用列表。因系统限制，弹窗内无法稳定弹出键盘，需要打字的修改会跳进 App。")
            }
            .font(.subheadline)

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
