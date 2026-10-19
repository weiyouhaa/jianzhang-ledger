import Foundation
import SwiftUI

/// 真实 / 防窥两套偏好隔离。
/// - 真实模式：`UserDefaults.standard`（与旧版兼容）
/// - 防窥模式：独立 suite `com.fve.ledger.decoyprefs`，不读写真实预算等
///
/// SwiftData 内的分类预算、记账规则、周期账单、分类上次账户随容器隔离；
/// 这里只覆盖仍落在 UserDefaults 上的用户数据。
enum ModeDefaults {
    static let decoySuiteName = "com.fve.ledger.decoyprefs"

    /// 由 SessionManager 在切模式时同步，供非 MainActor 路径（Money / BudgetService）读取。
    nonisolated(unsafe) private static var _isDecoy = false

    private static let globalKeys: Set<String> = [
        SettingsKey.appearance,
        SettingsKey.hideInAppSwitcher,
        SettingsKey.iCloudSyncEnabled,
        SettingsKey.iCloudContainerOK,
        SettingsKey.autoBackupEnabled,
        SettingsKey.autoBackupInterval,
        SettingsKey.autoBackupKeep,
        SettingsKey.lastBackupAt,
        SettingsKey.lastBackupLocation,
        SettingsKey.backupEncryption,
        SettingsKey.backupNeedsPassword,
        SettingsKey.autoBackupMode,
        SettingsKey.autoBackupDailySnapshot,
        SettingsKey.autoBackupSnapshotKeep,
        SettingsKey.autoBackupFingerprint,
        SettingsKey.lastBackupCheckAt,
        "backup.kdfIterations",
        "lock.biometricsEnabled",
        "lock.gracePeriod",
        "lock.decoyEnabled",
        "decoy.seeded.v1",
        "decoy.prefs.seeded.v1",
        "pending.appEdit.v1",
    ]

    static var decoy: UserDefaults { UserDefaults(suiteName: decoySuiteName) ?? .standard }

    /// 当前模式（可在任意线程读）
    nonisolated static var isDecoyMode: Bool { _isDecoy }

    nonisolated static func setDecoyMode(_ decoy: Bool) { _isDecoy = decoy }

    /// 当前模式应使用的 store（可在任意线程）
    nonisolated static var store: UserDefaults { _isDecoy ? decoy : .standard }

    nonisolated static func isGlobal(_ key: String) -> Bool {
        if globalKeys.contains(key) { return true }
        return key.hasPrefix("lock.") || key.hasPrefix("icloud.") || key.hasPrefix("backup.")
            || key.hasPrefix("pending.") || key.hasPrefix("migration.")
    }

    nonisolated static func store(for key: String) -> UserDefaults { isGlobal(key) ? .standard : store }

    nonisolated static func object(forKey key: String) -> Any? { store(for: key).object(forKey: key) }
    nonisolated static func bool(forKey key: String) -> Bool { store(for: key).bool(forKey: key) }
    nonisolated static func integer(forKey key: String) -> Int { store(for: key).integer(forKey: key) }
    nonisolated static func double(forKey key: String) -> Double { store(for: key).double(forKey: key) }
    nonisolated static func string(forKey key: String) -> String? { store(for: key).string(forKey: key) }
    nonisolated static func dictionary(forKey key: String) -> [String: Any]? { store(for: key).dictionary(forKey: key) }
    nonisolated static func set(_ value: Any?, forKey key: String) { store(for: key).set(value, forKey: key) }
    nonisolated static func removeObject(forKey key: String) { store(for: key).removeObject(forKey: key) }

    /// 防窥 suite 默认值（与真实账本数字无关）
    static func seedDecoyDefaultsIfNeeded() {
        let d = decoy
        let flag = "decoy.prefs.seeded.v1"
        guard d.object(forKey: flag) == nil else { return }
        writeDecoyDefaults(to: d)
        d.set(true, forKey: flag)
    }

    /// 重置防窥偏好（恢复预设数据时调用）
    static func resetDecoyPrefs() {
        let d = decoy
        for key in d.dictionaryRepresentation().keys {
            // 只清本 suite；全局键本来就不在这里
            d.removeObject(forKey: key)
        }
        writeDecoyDefaults(to: d)
        d.set(true, forKey: "decoy.prefs.seeded.v1")
    }

    private static func writeDecoyDefaults(to d: UserDefaults) {
        d.set(3000.0, forKey: SettingsKey.monthlyBudget)
        d.set(0.0, forKey: BudgetKey.yearly)
        d.set(false, forKey: BudgetKey.rollover)
        d.set(false, forKey: BudgetKey.alertsEnabled)
        d.set(80, forKey: BudgetKey.warnPercent)
        d.set(true, forKey: BudgetKey.alertOver)
        d.set("¥", forKey: SettingsKey.currencySymbol)
        d.set("", forKey: SettingsKey.defaultAccount)
        d.set(true, forKey: RuleStore.learnKey)
        d.removeObject(forKey: BudgetKey.sentAlerts)
    }
}

/// SwiftUI 绑定：读写跟随当前 Session 模式
@MainActor
enum ModePref {
    static func double(_ key: String, default def: Double = 0) -> Double {
        ModeDefaults.object(forKey: key) == nil ? def : ModeDefaults.double(forKey: key)
    }
    static func setDouble(_ value: Double, _ key: String) { ModeDefaults.set(value, forKey: key) }
    static func bool(_ key: String, default def: Bool = false) -> Bool {
        ModeDefaults.object(forKey: key) == nil ? def : ModeDefaults.bool(forKey: key)
    }
    static func setBool(_ value: Bool, _ key: String) { ModeDefaults.set(value, forKey: key) }
    static func int(_ key: String, default def: Int = 0) -> Int {
        ModeDefaults.object(forKey: key) == nil ? def : ModeDefaults.integer(forKey: key)
    }
    static func setInt(_ value: Int, _ key: String) { ModeDefaults.set(value, forKey: key) }
    static func string(_ key: String, default def: String = "") -> String {
        ModeDefaults.string(forKey: key) ?? def
    }
    static func setString(_ value: String, _ key: String) { ModeDefaults.set(value, forKey: key) }

    static func bindingDouble(_ key: String, default def: Double = 0) -> Binding<Double> {
        Binding(get: { double(key, default: def) }, set: { setDouble($0, key) })
    }
    static func bindingBool(_ key: String, default def: Bool = false) -> Binding<Bool> {
        Binding(get: { bool(key, default: def) }, set: { setBool($0, key) })
    }
    static func bindingInt(_ key: String, default def: Int = 0) -> Binding<Int> {
        Binding(get: { int(key, default: def) }, set: { setInt($0, key) })
    }
    static func bindingString(_ key: String, default def: String = "") -> Binding<String> {
        Binding(get: { string(key, default: def) }, set: { setString($0, key) })
    }
}
