import SwiftUI

/// 设置 / 修改 / 关闭密码流程。修改与关闭都需要先验证当前密码。
struct PasscodeFlowView: View {
    enum Mode: String, Identifiable {
        case set, change, disable
        var id: String { rawValue }
    }
    private enum Step { case verifyCurrent, enterNew, confirmNew }

    let mode: Mode
    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step
    @State private var newLength = 6
    @State private var firstEntry = ""
    @State private var message: String?

    init(mode: Mode) {
        self.mode = mode
        _step = State(initialValue: mode == .set ? .enterNew : .verifyCurrent)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if step == .enterNew {
                    Picker("密码位数", selection: $newLength) {
                        Text("4 位").tag(4)
                        Text("5 位").tag(5)
                        Text("6 位").tag(6)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 40)
                }

                PasscodePad(
                    title: title,
                    subtitle: subtitle,
                    length: currentLength,
                    message: message,
                    disabled: step == .verifyCurrent && lock.isLockedOut,
                    onComplete: handle
                )
                .id(step)
                Spacer()
            }
            .padding(.top, 30)
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .interactiveDismissDisabled()
    }

    private var navTitle: String {
        switch mode {
        case .set: return "设置密码"
        case .change: return "修改密码"
        case .disable: return "关闭密码"
        }
    }

    private var title: String {
        switch step {
        case .verifyCurrent: return "输入当前密码"
        case .enterNew: return "输入新密码"
        case .confirmNew: return "再次输入新密码"
        }
    }

    private var subtitle: String? {
        switch step {
        case .verifyCurrent: return mode == .disable ? "关闭后打开 App 将不再需要密码" : nil
        case .enterNew: return "密码仅以加盐哈希形式保存在本机钥匙串中"
        case .confirmNew: return nil
        }
    }

    private var currentLength: Int {
        switch step {
        case .verifyCurrent: return lock.passcodeLength
        case .enterNew, .confirmNew: return newLength
        }
    }

    private func handle(_ code: String) -> Bool {
        switch step {
        case .verifyCurrent:
            guard lock.verify(code) else {
                message = "密码错误"
                return false
            }
            message = nil
            if mode == .disable {
                lock.disablePasscode()
                dismiss()
            } else {
                step = .enterNew
            }
            return true
        case .enterNew:
            firstEntry = code
            message = nil
            step = .confirmNew
            return true
        case .confirmNew:
            guard code == firstEntry else {
                message = "两次输入不一致，请重新设置"
                firstEntry = ""
                step = .enterNew
                return false
            }
            if lock.setPasscode(code) {
                dismiss()
                return true
            }
            message = "保存失败，请重试"
            step = .enterNew
            return false
        }
    }
}
