import Foundation
import SwiftData

/// 仅用于自动截图：Debug 构建下传入启动参数 `-UIScreenshotDemo <screen>`（home、add、assetssocial、quickbalance、backupencrypt、reviewsnippet、decoysettings、decoyhome、stats、statsbudget、assets、account、settings、backup、lock、search、delete、rules、import、recurring、budgets）时，
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
        case "stats", "statsbudget": return 1
        case "assets", "account", "assetssocial", "quickbalance", "decoyassets": return 2
        case "settings", "backup", "backupencrypt", "decoysettings", "decoyeditor", "decoyeditorhome", "rules", "import", "recurring", "budgets": return 3
        case "decoyhome": return 0
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
        let budgetScreens = ["budgets", "statsbudget"].contains(screen ?? "")
        UserDefaults.standard.set(budgetScreens ? 8000.0 : 5000.0, forKey: SettingsKey.monthlyBudget)
        UserDefaults.standard.set(budgetScreens, forKey: BudgetKey.rollover)
        UserDefaults.standard.set(budgetScreens ? 100000.0 : 0, forKey: BudgetKey.yearly)
        UserDefaults.standard.set(budgetScreens, forKey: BudgetKey.alertsEnabled)
        UserDefaults.standard.set(80, forKey: BudgetKey.warnPercent)
        UserDefaults.standard.set(true, forKey: RuleStore.learnKey)
        UserDefaults.standard.set("¥", forKey: SettingsKey.currencySymbol)
        if ["decoysettings", "decoyhome", "decoyassets", "decoyeditor", "decoyeditorhome"].contains(screen ?? "") {
            UserDefaults.standard.set(true, forKey: "lock.decoyEnabled")
            if screen == "decoyhome" || screen == "decoyassets" { ModeDefaults.setDecoyMode(true) }
            ModeDefaults.seedDecoyDefaultsIfNeeded()
            ModeDefaults.decoy.set(3000.0, forKey: SettingsKey.monthlyBudget)
        }
        if screen == "backup" || screen == "backupencrypt" {
            UserDefaults.standard.set(true, forKey: SettingsKey.autoBackupEnabled)
            UserDefaults.standard.set(true, forKey: SettingsKey.backupEncryption)
            UserDefaults.standard.set(false, forKey: SettingsKey.backupNeedsPassword)
            UserDefaults.standard.set(AutoBackupMode.rolling.rawValue, forKey: SettingsKey.autoBackupMode)
            UserDefaults.standard.set(true, forKey: SettingsKey.autoBackupDailySnapshot)
            UserDefaults.standard.set(7, forKey: SettingsKey.autoBackupSnapshotKeep)
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
            .init(name: "住房公积金", type: .housingFund, initial: 41400, note: "单位 + 个人各 12%"),
            .init(name: "医保个人账户", type: .medicalAccount, initial: 2420, note: "可在定点药店使用"),
            .init(name: "养老保险个人账户", type: .pensionAccount, initial: 58600, note: "退休后按月领取"),
        ]
        var accountByName: [String: LedgerAccount] = [:]
        for (i, d) in demoAccounts.enumerated() {
            let a = LedgerAccount(name: d.name, type: d.type, initialBalance: d.initial, sortOrder: i)
            a.creditLimit = d.limit
            a.billingDay = d.billing
            a.repaymentDay = d.repayment
            a.note = d.note
            a.includeInNetWorth = d.type.defaultIncludeInNetWorth
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

        // 公积金 / 医保每月缴存：过去几个月的缴存记录 + 每月自动缴存规则
        let contributions: [(String, Double)] = [("住房公积金", 2400), ("医保个人账户", 280), ("养老保险个人账户", 960)]
        for (name, amount) in contributions {
            guard let acc = accountByName[name] else { continue }
            for back in 0...5 {
                guard let m = cal.date(byAdding: .month, value: -back, to: cal.startOfMonth(for: now)),
                      let d = cal.date(byAdding: .day, value: 14, to: m),
                      let date = cal.date(bySettingHour: 9, minute: 0, second: 0, of: d), date < now else { continue }
                let r = LedgerRecord(amount: amount, kind: .contribution, category: nil, note: "",
                                     account: name, date: date, source: "recurring")
                r.accountRef = acc
                context.insert(r)
            }
            let rule = RecurringRule(name: name + "缴存", amount: amount, kind: .contribution, frequency: .monthly,
                                     startDate: cal.date(byAdding: .month, value: -6, to: now) ?? now)
            rule.accountID = acc.id.uuidString
            rule.monthDay = 15
            rule.autoCreate = true
            rule.lastProcessedAt = now
            context.insert(rule)
        }
        // 公积金提取（转到储蓄卡）
        transfer(6000, from: "住房公积金", to: "招商银行储蓄卡", date: dayDate(12, 10, 30), note: "公积金提取（租房）")

        seedSmart(context: context, accounts: accountByName, now: now)
        try? context.save()
    }

    // MARK: - 记账规则 / 周期账单 / 分类预算

    private static func seedSmart(context: ModelContext, accounts: [String: LedgerAccount], now: Date) {
        let cal = DateText.calendar
        func cat(_ name: String, _ kind: RecordKind = .expense) -> LedgerCategory? {
            DataStore.category(named: name, kind: kind, in: context)
        }
        // 分类预算
        for (name, value) in [("餐饮", 1500.0), ("交通", 600.0), ("购物", 1200.0), ("娱乐", 400.0), ("居住", 2800.0)] {
            cat(name)?.monthlyBudget = value
        }

        // 记账规则
        struct DemoRule { let name: String; let learned: Bool; let kind: RecordKind; let category: String; let account: String?; let hits: Int }
        let demoRules: [DemoRule] = [
            .init(name: "高速", learned: false, kind: .expense, category: "交通", account: "招行信用卡", hits: 6),
            .init(name: "工资", learned: false, kind: .income, category: "工资", account: "招商银行储蓄卡", hits: 9),
            .init(name: "医保", learned: false, kind: .expense, category: "医疗", account: nil, hits: 2),
            .init(name: "星巴克咖啡", learned: true, kind: .expense, category: "餐饮", account: "微信", hits: 14),
            .init(name: "滴滴出行", learned: true, kind: .expense, category: "交通", account: "支付宝", hits: 11),
            .init(name: "盒马鲜生", learned: true, kind: .expense, category: "购物", account: "花呗", hits: 7),
            .init(name: "猫眼电影", learned: true, kind: .expense, category: "娱乐", account: "微信", hits: 3),
            .init(name: "国家电网", learned: true, kind: .expense, category: "生活缴费", account: "支付宝", hits: 4),
            .init(name: "大参林药房", learned: true, kind: .expense, category: "医疗", account: "支付宝", hits: 1),
        ]
        for (i, d) in demoRules.enumerated() {
            let r = CategoryRule(keyword: d.learned ? MerchantNormalizer.normalize(d.name) : d.name, displayName: d.name,
                                 isLearned: d.learned, kind: d.kind, categoryID: cat(d.category, d.kind)?.id,
                                 accountID: d.account.flatMap { accounts[$0]?.id })
            r.hitCount = d.hits
            r.updatedAt = now.addingTimeInterval(-Double(i) * 3600 * 20)
            context.insert(r)
        }

        // 周期账单（lastProcessedAt = 现在，截图时不会再生成记录）
        func start(monthsBack: Int, day: Int) -> Date {
            let base = cal.date(byAdding: .month, value: -monthsBack, to: cal.startOfMonth(for: now)) ?? now
            let d = cal.date(byAdding: .day, value: day - 1, to: base) ?? base
            return cal.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d
        }
        struct DemoRecurring {
            let name: String; let amount: Double; let kind: RecordKind; let category: String?
            let account: String; var to: String? = nil
            let frequency: RecurrenceFrequency; var day: Int = 1; var lastDay = false
            let auto: Bool; var remind = false; var daysBefore = 1
        }
        let demoRecurring: [DemoRecurring] = [
            .init(name: "房租", amount: 2800, kind: .expense, category: "居住", account: "招商银行储蓄卡", frequency: .monthly, day: 10, auto: true, remind: true),
            .init(name: "工资", amount: 16800, kind: .income, category: "工资", account: "招商银行储蓄卡", frequency: .monthly, day: 4, auto: true),
            .init(name: "视频会员", amount: 25, kind: .expense, category: "娱乐", account: "支付宝", frequency: .monthly, day: 22, auto: false, remind: true, daysBefore: 0),
            .init(name: "信用卡还款", amount: 3000, kind: .transfer, category: nil, account: "招商银行储蓄卡", to: "招行信用卡", frequency: .monthly, day: 23, auto: false, remind: true, daysBefore: 2),
            .init(name: "话费", amount: 50, kind: .expense, category: "通讯", account: "支付宝", frequency: .monthly, lastDay: true, auto: true),
            .init(name: "健身年卡", amount: 1999, kind: .expense, category: "娱乐", account: "招行信用卡", frequency: .yearly, day: 1, auto: false, remind: true, daysBefore: 7),
        ]
        for (i, d) in demoRecurring.enumerated() {
            let startDate = d.frequency == .yearly
                ? (cal.date(byAdding: .month, value: 1, to: start(monthsBack: 11, day: 1)) ?? now)
                : start(monthsBack: 6, day: d.lastDay ? 1 : d.day)
            let r = RecurringRule(name: d.name, amount: d.amount, kind: d.kind, frequency: d.frequency, startDate: startDate)
            r.categoryID = d.category.flatMap { cat($0, d.kind)?.id.uuidString } ?? ""
            r.accountID = accounts[d.account]?.id.uuidString ?? ""
            r.toAccountID = d.to.flatMap { accounts[$0]?.id.uuidString } ?? ""
            r.monthDay = d.day
            r.lastDayOfMonth = d.lastDay
            r.autoCreate = d.auto
            r.remindEnabled = d.remind
            r.remindDaysBefore = d.daysBefore
            r.lastProcessedAt = now
            r.createdAt = now.addingTimeInterval(Double(i))
            context.insert(r)
        }

        // 一次历史导入
        let batch = ImportBatch(source: .alipay, fileName: "支付宝交易明细(20260901-20260930).csv")
        batch.createdAt = now.addingTimeInterval(-86400 * 12)
        batch.recordCount = 46
        batch.expenseTotal = 3862.5
        batch.incomeTotal = 1260
        context.insert(batch)
    }

    /// 导入预览截图用的微信账单（日期相对今天，含一笔与已有记录重复的盒马）
    static func importSession() -> ImportSession? {
        let cal = DateText.calendar
        let now = Date()
        let maxBack = max(0, cal.component(.day, from: now) - 1)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = cal
        f.timeZone = BillParser.timeZone   // 账单时间按北京时间解析
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func t(_ day: Int, _ h: Int, _ m: Int) -> String {
            let base = cal.date(byAdding: .day, value: -min(day, maxBack), to: now) ?? now
            var d = cal.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
            if d > now { d = now.addingTimeInterval(-Double(600 * (day + 1))) }
            return f.string(from: d)
        }
        var n = 0
        func row(_ time: String, _ type: String, _ party: String, _ goods: String, _ dir: String, _ amount: String,
                 _ method: String, _ status: String) -> String {
            n += 1
            return "\(time),\(type),\(party),\(goods),\(dir),¥\(amount),\(method),\(status),42000000012026\(String(format: "%08d", n)) ,/,/"
        }
        let rows = [
            row(t(0, 8, 40), "商户消费", "星巴克", "拿铁 大杯", "支出", "32.00", "零钱", "支付成功"),
            row(t(1, 19, 20), "商户消费", "盒马鲜生", "周末采购", "支出", "286.40", "花呗", "支付成功"),
            row(t(1, 9, 5), "商户消费", "滴滴出行", "快车", "支出", "18.60", "招商银行信用卡(1024)", "支付成功"),
            row(t(2, 18, 12), "商户消费", "华南畅行高速科技有限公司", "高速通行费", "支出", "46.00", "招商银行信用卡(1024)", "支付成功"),
            row(t(2, 12, 0), "商户消费", "美团", "外卖订单", "支出", "30.00", "零钱", "已退款(￥5.00)"),
            row(t(2, 13, 0), "美团-退款", "美团", "/", "收入", "5.00", "零钱", "已退款(￥5.00)"),
            row(t(3, 20, 30), "商户消费", "京东", "蓝牙耳机", "支出", "199.00", "零钱", "支付成功"),
            row(t(3, 9, 0), "微信红包", "李四", "/", "收入", "88.00", "/", "已存入零钱"),
            row(t(4, 10, 0), "信用卡还款", "招商银行", "信用卡还款", "/", "2000.00", "招商银行储蓄卡(6688)", "支付成功"),
            row(t(4, 21, 0), "零钱通", "/", "转入零钱通-来自零钱", "/", "500.00", "零钱", "支付成功"),
            row(t(5, 11, 30), "商户消费", "中国电信", "话费充值", "支出", "100.00", "零钱", "支付成功"),
            row(t(5, 8, 0), "扫二维码付款", "早餐店", "二维码付款", "支出", "8.50", "零钱", "支付失败"),
        ]
        let text = (["微信支付账单明细,,,,,,,,,,", "微信昵称：[演示],,,,,,,,,,", ",,,,,,,,,,",
                     "----------------------微信支付账单明细列表--------------------,,,,,,,,,,",
                     "交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注"] + rows)
            .joined(separator: "\n")
        guard let result = try? BillParser.parse(data: Data(text.utf8), fileName: "微信支付账单.csv") else { return nil }
        return ImportSession(result: result, fileName: "微信支付账单(20261001-20261018).csv")
    }
}
