import SwiftUI

/// 启动 / 回到前台时覆盖在最上层的锁屏
struct LockScreenView: View {
    @EnvironmentObject private var lock: AppLockManager
    @State private var message: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.35), Color(.systemBackground)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 20)
                Image(systemName: "lock.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                    .padding(18)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    PasscodePad(
                        title: "输入密码解锁简账",
                        length: lock.passcodeLength,
                        message: statusText(now: context.date),
                        disabled: lock.isLockedOut,
                        biometricIcon: (lock.biometricsEnabled && lock.canUseBiometrics) ? lock.biometryIcon : nil,
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
        .onAppear { lock.tryBiometricUnlock() }
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
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                Text("简账").font(.title2.weight(.semibold))
            }
        }
    }
}
