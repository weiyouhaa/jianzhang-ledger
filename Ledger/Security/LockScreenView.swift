import SwiftUI

/// 启动 / 回到前台时覆盖在最上层的锁屏
struct LockScreenView: View {
    @EnvironmentObject private var lock: AppLockManager
    @State private var message: String?

    var body: some View {
        ZStack {
            if AppSkin.current == .receipt {
                // 3.2 (23) 小票皮肤：暖纸底色（皮肤是设备级设置，真实 / 防窥一样，不暴露模式）
                Color.themeBackdrop.ignoresSafeArea()
            } else {
                LinearGradient(colors: [Color.themeAccent.opacity(0.35), Color(.systemBackground)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            }

            VStack(spacing: 24) {
                Spacer(minLength: 20)
                Image(systemName: "lock.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.themeAccent)
                    .padding(18)
                    .background(Circle().fill(Color.themeAccent.opacity(0.15)))

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    PasscodePad(
                        title: "输入密码解锁简账",
                        length: lock.passcodeLength,
                        message: statusText(now: context.date),
                        disabled: lock.isLockedOut,
                        biometricIcon: lock.showsBiometricOnLockScreen ? lock.biometryIcon : nil,
                        onBiometric: { lock.tryBiometricUnlock() },
                        onComplete: { code in
                            let ok = lock.unlock(with: code)
                            message = ok ? nil : "密码错误"
                            return ok
                        }
                    )
                }
                Spacer(minLength: 20)
            }
        }
        // 默认「密码」方式不自动弹面容 ID，避免被人举到脸前直接进入真实账本
        .onAppear { lock.autoBiometricUnlockIfAllowed() }
    }

    private func statusText(now: Date) -> String? {
        if let until = lock.lockoutUntil, until > now {
            return "尝试次数过多，请 \(Int(until.timeIntervalSince(now).rounded(.up))) 秒后重试"
        }
        if lock.failedAttempts > 0 {
            return "密码错误（已错误 \(lock.failedAttempts) 次）"
        }
        return message
    }
}

/// 进入多任务界面时遮挡内容
struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            if AppSkin.current == .receipt {
                Color.themeBackdrop.ignoresSafeArea()
            } else {
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
            }
            VStack(spacing: 12) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.themeAccent)
                Text("简账").font(.ui(.title2).weight(.semibold))
            }
        }
    }
}
