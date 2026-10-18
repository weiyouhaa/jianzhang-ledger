import SwiftUI

/// 敏感操作（如恢复备份）前验证 App 密码
struct PasscodeVerifyView: View {
    let reason: String
    let onSuccess: () -> Void

    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack {
                PasscodePad(
                    title: "输入 App 密码",
                    subtitle: reason,
                    length: lock.passcodeLength,
                    message: message,
                    onComplete: { code in
                        if lock.verify(code) {
                            dismiss()
                            onSuccess()
                            return true
                        }
                        message = "密码错误"
                        return false
                    }
                )
                Spacer()
            }
            .padding(.top, 40)
            .navigationTitle("验证密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .interactiveDismissDisabled()
    }
}
