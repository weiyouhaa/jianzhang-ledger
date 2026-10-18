import Foundation
import SwiftData
import UIKit
import UserNotifications

/// 通知点击「记一笔」后，由主界面弹出预填好的记账页
@MainActor
final class NotificationRouter: ObservableObject {
    static let shared = NotificationRouter()
    @Published var prefill: RecordPrefill?
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationManager.shared
        NotificationManager.shared.registerCategories()
        return true
    }
}

/// 本地通知：周期账单提醒、预算提醒。只在用户开启提醒时才申请权限。
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    static let remindCategory = "RECURRING_REMIND"
    static let autoCategory = "RECURRING_AUTO"
    static let paidAction = "PAID"
    static let openAction = "OPEN"
    static let recurringPrefix = "recurring."
    /// iOS 最多保留 64 个待发通知，给预算等其他通知留余量
    static let maxPending = 50

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func registerCategories() {
        let paid = UNNotificationAction(identifier: Self.paidAction, title: "已付", options: [.authenticationRequired])
        let open = UNNotificationAction(identifier: Self.openAction, title: "记一笔", options: [.foreground])
        let remind = UNNotificationCategory(identifier: Self.remindCategory, actions: [paid, open], intentIdentifiers: [])
        let auto = UNNotificationCategory(identifier: Self.autoCategory, actions: [open], intentIdentifiers: [])
        center.setNotificationCategories([remind, auto])
    }

    /// 申请通知权限（仅在用户打开提醒开关时调用）
    func requestAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    func isAuthorized() async -> Bool {
        let s = await center.notificationSettings().authorizationStatus
        return s == .authorized || s == .provisional || s == .ephemeral
    }

    func postNow(id: String, title: String, body: String) {
        Task {
            guard await isAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: id, content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            try? await center.add(request)
        }
    }

    /// 重新安排周期账单提醒（启动、回到前台、编辑规则后调用）
    @MainActor
    func rescheduleRecurring(in context: ModelContext) async {
        guard !ScreenshotDemo.isActive else { return }
        let pending = await center.pendingNotificationRequests()
        let old = pending.map(\.identifier).filter { $0.hasPrefix(Self.recurringPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: old)

        let rules = RecurringEngine.allRules(in: context).filter { $0.remindEnabled && !$0.isPaused && $0.amount > 0 }
        guard !rules.isEmpty, await isAuthorized() else { return }

        let cal = DateText.calendar
        let now = Date()
        let horizon = cal.date(byAdding: .day, value: 70, to: now) ?? now
        let keys = RecurringEngine.existingKeys(in: context)
        var items: [(fire: Date, rule: RecurringRule, occ: Date)] = []
        for rule in rules {
            let from = now.addingTimeInterval(-15 * 86400)
            for occ in rule.spec.occurrences(through: horizon, calendar: cal) where occ >= from {
                let day = cal.startOfDay(for: occ)
                guard let base = cal.date(byAdding: .day, value: -max(0, rule.remindDaysBefore), to: day),
                      let fire = cal.date(bySettingHour: rule.remindHour, minute: rule.remindMinute, second: 0, of: base),
                      fire > now else { continue }
                if RecurringEngine.isPaid(rule, occurrence: occ, keys: keys) { continue }
                items.append((fire, rule, occ))
            }
        }
        items.sort { $0.fire < $1.fire }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd"
        for item in items.prefix(Self.maxPending) {
            let rule = item.rule
            let content = UNMutableNotificationContent()
            let days = rule.remindDaysBefore
            let when = days == 0 ? "今天" : (days == 1 ? "明天" : "\(days) 天后")
            content.title = rule.autoCreate ? "\(rule.name) \(when)自动记账" : "\(rule.name) \(when)到期"
            content.body = "\(rule.kind.title) \(Money.format(rule.amount)) · \(DateText.monthDayTime.string(from: item.occ))"
                + (rule.autoCreate ? "" : "\n长按可标记「已付」或打开「记一笔」")
            content.sound = .default
            content.categoryIdentifier = rule.autoCreate ? Self.autoCategory : Self.remindCategory
            content.userInfo = ["ruleID": rule.id.uuidString, "occurrence": item.occ.timeIntervalSince1970]
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: item.fire)
            let request = UNNotificationRequest(identifier: "\(Self.recurringPrefix)\(rule.id.uuidString).\(df.string(from: item.occ))",
                                                content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            try? await center.add(request)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        guard let idString = info["ruleID"] as? String, let ruleID = UUID(uuidString: idString),
              let t = info["occurrence"] as? Double else {
            completionHandler()
            return
        }
        let occurrence = Date(timeIntervalSince1970: t)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let context = DataStore.shared.mainContext
                if action == Self.paidAction {
                    RecurringEngine.markPaid(ruleID: ruleID, occurrence: occurrence, in: context)
                } else if action == Self.openAction || action == UNNotificationDefaultActionIdentifier {
                    if let rule = RecurringEngine.rule(id: ruleID, in: context) {
                        let keys = RecurringEngine.existingKeys(in: context)
                        if !RecurringEngine.isPaid(rule, occurrence: occurrence, keys: keys) {
                            NotificationRouter.shared.prefill = RecurringEngine.prefill(rule, occurrence: occurrence)
                        }
                    }
                }
                completionHandler()
            }
        }
    }
}
