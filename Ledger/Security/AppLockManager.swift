import Foundation
import LocalAuthentication
import SwiftUI

/// 应用锁状态管理：启动 / 回到前台时按宽限期决定是否上锁，支持面容 ID / 触控 ID
@MainActor
final class AppLockManager: ObservableObject {
    @Published private(set) var isLocked: Bool
    @Published private(set) var passcodeEnabled: Bool
    @Published var biometricsEnabled: Bool {
        didSet { UserDefaults.standard.set(biometricsEnabled, forKey: Keys.biometrics) }
    }
    /// 宽限期（秒）：离开 App 不超过该时长回来时不需要重新解锁。0 = 立即
    @Published var gracePeriod: Int {
        didSet { UserDefaults.standard.set(gracePeriod, forKey: Keys.grace) }
    }
    @Published private(set) var failedAttempts: Int = 0
    @Published private(set) var lockoutUntil: Date?

    private var backgroundedAt: Date?
    private var isAuthenticatingBiometrics = false

    nonisolated static let graceOptions: [Int] = [0, 30, 60, 300, 900, 3600]

    nonisolated static func graceTitle(_ seconds: Int) -> String {
        switch seconds {
        case 0: return "立即"
        case ..<60: return "\(seconds) 秒"
        case ..<3600: return "\(seconds / 60) 分钟"
        default: return "\(seconds / 3600) 小时"
        }
    }

    private enum Keys {
        static let biometrics = "lock.biometricsEnabled"
        static let grace = "lock.gracePeriod"
    }

    init() {
        let enabled = PasscodeStore.isSet
        passcodeEnabled = enabled
        isLocked = enabled
        biometricsEnabled = UserDefaults.standard.bool(forKey: Keys.biometrics)
        gracePeriod = UserDefaults.standard.object(forKey: Keys.grace) as? Int ?? 0
    }

    var passcodeLength: Int { PasscodeStore.length }

    // MARK: - 生命周期

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if backgroundedAt == nil { backgroundedAt = Date() }
            if passcodeEnabled && gracePeriod == 0 { isLocked = true }
        case .active:
            // 只有真正从后台回来才处理；面容 ID 弹窗只会让 App 进入 inactive，避免取消后反复弹出
            guard let t = backgroundedAt else { break }
            backgroundedAt = nil
            if passcodeEnabled, Date().timeIntervalSince(t) >= Double(gracePeriod) {
                isLocked = true
            }
            if isLocked { tryBiometricUnlock() }
        default:
            break
        }
    }

    // MARK: - 解锁

    var isLockedOut: Bool {
        if let until = lockoutUntil, until > Date() { return true }
        return false
    }

    /// 返回是否解锁成功
    @discardableResult
    func unlock(with passcode: String) -> Bool {
        guard !isLockedOut else { return false }
        if PasscodeStore.verify(passcode) {
            failedAttempts = 0
            lockoutUntil = nil
            withAnimation(.easeOut(duration: 0.25)) { isLocked = false }
            return true
        }
        failedAttempts += 1
        if failedAttempts >= 5 {
            // 连续错误 5 次起逐级锁定：30 秒、60 秒、120 秒……
            let seconds = 30.0 * pow(2.0, Double(failedAttempts - 5))
            lockoutUntil = Date().addingTimeInterval(min(seconds, 3600))
        }
        return false
    }

    var biometryType: LABiometryType {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ctx.biometryType
    }

    var biometryName: String {
        switch biometryType {
        case .faceID: return "面容 ID"
        case .touchID: return "触控 ID"
        case .opticID: return "Optic ID"
        default: return "生物识别"
        }
    }

    var biometryIcon: String {
        switch biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.shield"
        }
    }

    var canUseBiometrics: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    func tryBiometricUnlock() {
        guard isLocked, passcodeEnabled, biometricsEnabled, canUseBiometrics, !isAuthenticatingBiometrics else { return }
        isAuthenticatingBiometrics = true
        Task {
            let ok = await evaluateBiometrics(reason: "解锁简账")
            isAuthenticatingBiometrics = false
            if ok {
                failedAttempts = 0
                lockoutUntil = nil
                withAnimation(.easeOut(duration: 0.25)) { isLocked = false }
            }
        }
    }

    func evaluateBiometrics(reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "输入密码"
        ctx.localizedCancelTitle = "取消"
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch {
            return false
        }
    }

    // MARK: - 设置

    func setPasscode(_ passcode: String) -> Bool {
        guard PasscodeStore.save(passcode) else { return false }
        passcodeEnabled = true
        return true
    }

    func disablePasscode() {
        PasscodeStore.remove()
        passcodeEnabled = false
        biometricsEnabled = false
        isLocked = false
    }

    func verify(_ passcode: String) -> Bool {
        PasscodeStore.verify(passcode)
    }

    func lockNow() {
        guard passcodeEnabled else { return }
        withAnimation { isLocked = true }
    }
}
