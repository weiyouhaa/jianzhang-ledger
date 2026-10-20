import Foundation
import LocalAuthentication
import SwiftUI

/// 备份密码：可选保存在本机钥匙串（仅此设备、不随 iCloud 钥匙串同步），供自动备份加密使用。
/// 查看、修改或在导入时取用都需要先验证 App 密码 / 面容 ID（未设 App 密码时用设备密码 / 面容 ID）。
enum BackupPasswordStore {
    private static let account = "backup.password"

    static var encryptionEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.backupEncryption) as? Bool ?? true
    }

    static var hasPassword: Bool {
        // 截图模式：备份设置页显示「已保存」，其他页面视为未保存
        guard !ScreenshotDemo.isActive else { return ScreenshotDemo.screen == "backup" }
        return load() != nil
    }

    static func load() -> String? {
        guard !ScreenshotDemo.isActive, let d = KeychainStore.get(account), let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    static func save(_ password: String) -> Bool {
        guard !ScreenshotDemo.isActive else { return false }
        let existed = load() != nil
        let ok = KeychainStore.set(Data(password.utf8), for: account)
        if ok {
            ChangeLogger.log(existed ? .update : .create, .security, summary: existed ? "备份密码已修改" : "已保存备份密码")
            UserDefaults.standard.set(false, forKey: SettingsKey.backupNeedsPassword)
            AutoBackup.invalidateFingerprint()
        }
        return ok
    }

    static func remove() {
        let existed = load() != nil
        KeychainStore.delete(account)
        if existed { ChangeLogger.log(.delete, .security, summary: "已移除本机保存的备份密码") }
        AutoBackup.invalidateFingerprint()
    }
}

/// 一次待验证的敏感操作
struct SensitiveAuthRequest: Identifiable {
    let id = UUID()
    let reason: String
    let onSuccess: () -> Void
}

extension AppLockManager {
    /// 验证用户身份后执行 action：
    /// - 设置了 App 密码：开启面容 ID 时先用面容 ID，失败或未开启则弹出 App 密码键盘（通过 pending）
    /// - 未设置 App 密码：用设备的面容 ID / 设备密码；设备本身没有锁屏密码时直接通过
    func authenticateSensitive(reason: String, pending: Binding<SensitiveAuthRequest?>, action: @escaping () -> Void) {
        if ScreenshotDemo.isActive { action(); return }
        if passcodeEnabled {
            Task { @MainActor in
                if biometricsEnabled, canUseBiometrics, await evaluateBiometrics(reason: reason) {
                    action()
                } else {
                    pending.wrappedValue = SensitiveAuthRequest(reason: reason, onSuccess: action)
                }
            }
            return
        }
        let ctx = LAContext()
        ctx.localizedCancelTitle = "取消"
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { action(); return }
        Task { @MainActor in
            if (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true {
                action()
            }
        }
    }
}

extension View {
    /// 配合 authenticateSensitive：需要输入 App 密码时弹出密码键盘
    func sensitiveAuthSheet(_ pending: Binding<SensitiveAuthRequest?>, lock: AppLockManager) -> some View {
        sheet(item: pending) { req in
            PasscodeVerifyView(reason: req.reason) {
                // 等密码键盘收起后再继续（可能还要弹出下一个页面）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { req.onSuccess() }
            }
                .environmentObject(lock)
        }
    }
}
