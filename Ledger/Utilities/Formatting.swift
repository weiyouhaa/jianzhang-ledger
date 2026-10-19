import Foundation
import SwiftUI
import UIKit

enum Money {
    static var symbol: String { UserDefaults.standard.string(forKey: SettingsKey.currencySymbol) ?? "¥" }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = true
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    /// 1234.5 -> "¥1,234.50"
    static func format(_ value: Double, showSymbol: Bool = true) -> String {
        let s = formatter.string(from: NSNumber(value: abs(value))) ?? String(format: "%.2f", abs(value))
        let sign = value < 0 ? "-" : ""
        return sign + (showSymbol ? symbol : "") + s
    }

    /// 紧凑格式，用于图表坐标轴：12000 -> "1.2万"
    static func compact(_ value: Double) -> String {
        let v = abs(value)
        if v >= 10_000 { return String(format: "%.1f万", value / 10_000) }
        if v >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        return String(format: "%.0f", value)
    }

    /// 资产页隐藏金额
    static func masked(_ value: Double, hidden: Bool) -> String {
        hidden ? symbol + "****" : format(value)
    }

    /// 解析用户输入的金额字符串
    /// 输入框用：整数不带小数
    static func plain(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    static func parse(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "￥", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned), v.isFinite else { return nil }
        return (v * 100).rounded() / 100
    }
}

enum DateText {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "zh_CN")
        c.firstWeekday = 2
        return c
    }()

    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.calendar = calendar
        f.dateFormat = format
        return f
    }

    static let month = make("yyyy年M月")
    static let year = make("yyyy年")
    static let dayHeader = make("M月d日 EEEE")
    static let shortDate = make("M月d日")
    static let time = make("HH:mm")
    static let full = make("yyyy-MM-dd HH:mm")
    static let monthDayTime = make("M月d日 HH:mm")

    static func dayHeaderText(_ date: Date) -> String {
        if calendar.isDateInToday(date) { return "今天 · " + shortDate.string(from: date) }
        if calendar.isDateInYesterday(date) { return "昨天 · " + shortDate.string(from: date) }
        return dayHeader.string(from: date)
    }
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? date
    }
    func startOfYear(for date: Date) -> Date {
        self.date(from: dateComponents([.year], from: date)) ?? date
    }
}

enum SettingsKey {
    static let monthlyBudget = "monthlyBudget"
    static let currencySymbol = "currencySymbol"
    static let appearance = "appearance"          // 0 跟随系统 1 浅色 2 深色
    static let defaultAccount = "defaultAccount"
    static let hideInAppSwitcher = "hideInAppSwitcher"
    static let hideAmounts = "assets.hideAmounts"
    // iCloud 与备份
    static let iCloudSyncEnabled = "icloud.syncEnabled"
    static let iCloudContainerOK = "icloud.containerAvailable"
    static let autoBackupEnabled = "backup.autoEnabled"
    static let autoBackupInterval = "backup.intervalSeconds"
    static let autoBackupKeep = "backup.keepCount"
    static let lastBackupAt = "backup.lastAt"            // timeIntervalSince1970，0 = 从未
    static let lastBackupLocation = "backup.lastLocation"
    /// 加密备份（默认开启）
    static let backupEncryption = "backup.encryptionEnabled"
    /// 自动备份因没有保存备份密码而跳过
    static let backupNeedsPassword = "backup.needsPassword"
    /// 自动备份方式：rolling（每次打开/关闭时更新同一文件，默认）/ periodic（定期保留多份）
    static let autoBackupMode = "backup.mode"
    /// 滚动模式下额外保留每日快照（默认开，保留 7 份）
    static let autoBackupDailySnapshot = "backup.dailySnapshot"
    static let autoBackupSnapshotKeep = "backup.snapshotKeep"
    static let autoBackupFingerprint = "backup.fingerprint"
    static let lastBackupCheckAt = "backup.lastCheckAt"
}

extension Color {
    /// "#RRGGBB" / "RRGGBB"
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b: Double
        if s.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        } else {
            r = 0.56; g = 0.56; b = 0.58
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// 转为 "#RRGGBB"
    func toHex() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        func clamp(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }
}
