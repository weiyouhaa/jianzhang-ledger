import Foundation
import SwiftData

/// 仅用于自动截图：Debug 构建下传入启动参数 `-UIScreenshotDemo <home|add|stats|assets|account|settings|backup|lock|search|delete>` 时，
/// 使用内存数据库并写入示例数据，直接打开对应页面。正常启动（或 Release 构建）完全不受影响。
enum ScreenshotDemo {
    static let screen: String? = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-UIScreenshotDemo"), i + 1 < args.count {
            return args[i + 1]
        }
        #endif
        return nil
    }()

    static var isActive: Bool { screen != nil }

    static var initialTab: Int {
        switch screen {
        case "stats": return 1
        case "assets", "account": return 2
        case "settings", "backup": return 3
        default: return 0
        }
    }

    private struct Sample {
        let day: Int        // 本月第几天之前（0 = 今天）
        let hour: Int
        let minute: Int
        let amount: Double
        let category: String
        let kind: RecordKind
        let note: String
        let merchant: String
        let account: String
        let source: String
    }

    static func seed(container: ModelContainer) {
        guard isActive else { return }
        let context = ModelContext(container)
        UserDefaults.standard.set(5000.0, forKey: SettingsKey.monthlyBudget)
        UserDefaults.standard.set("¥", forKey: SettingsKey.currencySymbol)
        if screen == "backup" {
            UserDefaults.standard.set(true, forKey: SettingsKey.autoBackupEnabled)
            UserDefaults.standard.set(Date().addingTimeInterval(-3 * 3600).timeIntervalSince1970, forKey: SettingsKey.lastBackupAt)
            UserDefaults.standard.set(AutoBackup.locationTitle(isICloud: false), forKey: SettingsKey.lastBackupLocation)
        }

        let samples: [Sample] = [
            .init(day: 0, hour: 12, minute: 18, amount: 35, category: "餐饮", kind: .expense, note: "", merchant: "星巴克咖啡", account: "微信", source: "ocr"),
            .init(day: 0, hour: 8, minute: 45, amount: 23.5, category: "交通", kind: .expense, note: "打车去公司", merchant: "滴滴出行", account: "支付宝", source: "ocr"),
            .init(day: 0, hour: 7, minute: 30, amount: 18, category: "餐饮", kind: .expense, note: "早餐", merchant: "", account: "现金", source: "manual"),
            .init(day: 1, hour: 19, minute: 20, amount: 286.4, category: "购物", kind: .expense, note: "周末采购", merchant: "盒马鲜生", account: "花呗", source: "manual"),
            .init(day: 1, hour: 15, minute: 2, amount: 69.9, category: "娱乐", kind: .expense, note: "电影票", merchant: "猫眼电影", account: "微信", source: "shortcut"),
            .init(day: 1, hour: 10, minute: 0, amount: 200, category: "红包", kind: .income, note: "生日红包", merchant: "", account: "微信", source: "manual"),
            .init(day: 2, hour: 12, minute: 40, amount: 45.6, category: "餐饮", kind: .expense, note: "午饭外卖", merchant: "美团外卖", account: "银行卡", source: "ocr"),
            .init(day: 3, hour: 21, minute: 10, amount: 168, category: "生活缴费", kind: .expense, note: "电费", merchant: "国家电网", account: "支付宝", source: "manual"),
            .init(day: 4, hour: 18, minute: 30, amount: 328, category: "人情", kind: .expense, note: "朋友聚餐 AA", merchant: "", account: "微信", source: "manual"),
            .init(day: 5, hour: 9, minute: 15, amount: 50, category: "通讯", kind: .expense, note: "话费充值", merchant: "中国移动", account: "支付宝", source: "manual"),
            .init(day: 6, hour: 14, minute: 0, amount: 899, category: "购物", kind: .expense, note: "运动鞋", merchant: "京东", account: "信用卡", source: "manual"),
            .init(day: 8, hour: 11, minute: 20, amount: 128, category: "医疗", kind: .expense, note: "感冒药", merchant: "大参林药房", account: "支付宝", source: "manual"),
            .init(day: 9, hour: 20, minute: 0, amount: 1260, category: "理财", kind: .income, note: "基金收益", merchant: "", account: "支付宝", source: "manual"),
            .init(day: 10, hour: 9, minute: 0, amount: 2800, category: "居住", kind: .expense, note: "房租", merchant: "", account: "银行卡", source: "manual"),
            .init(day: 12, hour: 13, minute: 5, amount: 58, category: "餐饮", kind: .expense, note: "火锅", merchant: "海底捞", account: "微信", source: "ocr"),
            .init(day: 14, hour: 10, minute: 0, amount: 16800, category: "工资", kind: .income, note: "10 月工资", merchant: "", account: "银行卡", source: "manual"),
            .init(day: 15, hour: 17, minute: 45, amount: 199, category: "教育", kind: .expense, note: "网课", merchant: "", account: "支付宝", source: "manual"),
        ]

        let cal = DateText.calendar
        let now = Date()
        let maxDaysBack = max(0, cal.component(.day, from: now) - 1)

        // 账户
        struct DemoAccount {
            let name: String
            let type: AccountType
            let initial: Double
            var limit: Double = 0
            var billing: Int = 0
            var repayment: Int = 0
            var note: String = ""
        }
        let demoAccounts: [DemoAccount] = [
            .init(name: "招商银行储蓄卡", type: .debit, initial: 28000, note: "尾号 6688"),
            .init(name: "支付宝", type: .alipay, initial: 3500),
            .init(name: "微信", type: .wechat, initial: 1200),
            .init(name: "现金", type: .cash, initial: 600),
            .init(name: "借给朋友", type: .receivable, initial: 5000, note: "小王，年底还"),
            .init(name: "招行信用卡", type: .credit, initial: -3200, limit: 50000, billing: 5, repayment: 23, note: "尾号 1024"),
            .init(name: "花呗", type: .consumerCredit, initial: -860, limit: 8000, billing: 1, repayment: 10),
        ]
        var accountByName: [String: LedgerAccount] = [:]
        for (i, d) in demoAccounts.enumerated() {
            let a = LedgerAccount(name: d.name, type: d.type, initialBalance: d.initial, sortOrder: i)
            a.creditLimit = d.limit
            a.billingDay = d.billing
            a.repaymentDay = d.repayment
            a.note = d.note
            a.createdAt = cal.date(byAdding: .month, value: -10, to: now) ?? now
            context.insert(a)
            accountByName[d.name] = a
        }
        let legacyAlias = ["银行卡": "招商银行储蓄卡", "信用卡": "招行信用卡"]
        func account(_ legacy: String) -> LedgerAccount? {
            accountByName[legacyAlias[legacy] ?? legacy]
        }
        func transfer(_ amount: Double, from: String, to: String, date: Date, note: String) {
            let r = LedgerRecord(amount: amount, kind: .transfer, category: nil, note: note,
                                 account: from, date: date, source: "manual")
            r.accountRef = accountByName[from]
            r.toAccount = accountByName[to]
            context.insert(r)
        }
        func dayDate(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            let base = cal.date(byAdding: .day, value: -min(day, maxDaysBack), to: now) ?? now
            let d = cal.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
            return d > now ? now.addingTimeInterval(-Double(60 * (day + 2))) : d
        }
        transfer(3000, from: "招商银行储蓄卡", to: "招行信用卡", date: dayDate(2, 9, 30), note: "信用卡还款")
        transfer(1000, from: "招商银行储蓄卡", to: "支付宝", date: dayDate(7, 20, 15), note: "充值")

        func category(_ name: String, _ kind: RecordKind) -> LedgerCategory? {
            DataStore.category(named: name, kind: kind, in: context)
        }

        for s in samples {
            let dayBack = min(s.day, maxDaysBack)
            guard let base = cal.date(byAdding: .day, value: -dayBack, to: now),
                  var date = cal.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: base) else { continue }
            if date > now { date = now.addingTimeInterval(-Double(60 * (s.day + 1))) }
            let acc = account(s.account)
            let r = LedgerRecord(amount: s.amount, kind: s.kind, category: category(s.category, s.kind),
                                 note: s.note, merchant: s.merchant, account: acc?.name ?? s.account, date: date, source: s.source)
            r.accountRef = acc
            context.insert(r)
        }

        // 前几个月的数据，让年度图表有内容
        let monthly: [(String, RecordKind, Double, String)] = [
            ("工资", .income, 16800, "招商银行储蓄卡"), ("居住", .expense, 2800, "招商银行储蓄卡"),
            ("餐饮", .expense, 1650, "微信"), ("交通", .expense, 420, "支付宝"),
            ("购物", .expense, 1300, "招行信用卡"), ("娱乐", .expense, 380, "支付宝"),
        ]
        for back in 1...9 {
            guard let monthDate = cal.date(byAdding: .month, value: -back, to: now),
                  cal.component(.year, from: monthDate) == cal.component(.year, from: now) else { continue }
            let start = cal.startOfMonth(for: monthDate)
            for (i, item) in monthly.enumerated() {
                let factor = 0.75 + Double((back * 7 + i * 3) % 10) / 20
                let date = cal.date(byAdding: .day, value: 2 + i * 4, to: start) ?? start
                let amount = (item.2 * factor).rounded()
                let r = LedgerRecord(amount: amount, kind: item.1, category: category(item.0, item.1),
                                     account: item.3, date: date)
                r.accountRef = accountByName[item.3]
                context.insert(r)
                if item.0 == "购物" {
                    // 次月 23 日还清上月账单
                    let nextMonth = cal.date(byAdding: .month, value: 1, to: start) ?? start
                    let payDay = cal.date(byAdding: .day, value: 22, to: nextMonth) ?? nextMonth
                    if payDay < now, back > 1 {
                        transfer(amount, from: "招商银行储蓄卡", to: "招行信用卡", date: payDay, note: "信用卡还款")
                    }
                }
            }
            let mid = cal.date(byAdding: .day, value: 15, to: start) ?? start
            transfer(2000, from: "招商银行储蓄卡", to: "微信", date: mid, note: "零钱充值")
            transfer(800, from: "招商银行储蓄卡", to: "支付宝", date: mid, note: "充值")
        }
        try? context.save()
    }
}
