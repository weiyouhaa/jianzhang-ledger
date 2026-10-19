import Foundation
import SwiftData

/// 防窥账本首次使用时写入看起来平常的演示数据（小额日常开销，绝不暗示「这是假的」）。
enum DecoySeeder {
    static let seededKey = "decoy.seeded.v1"

    @MainActor
    static func seedIfNeeded(container: ModelContainer, force: Bool = false) {
        let context = ModelContext(container)
        if force {
            for r in (try? context.fetch(FetchDescriptor<LedgerRecord>())) ?? [] { context.delete(r) }
            for c in (try? context.fetch(FetchDescriptor<LedgerCategory>())) ?? [] { context.delete(c) }
            for a in (try? context.fetch(FetchDescriptor<LedgerAccount>())) ?? [] { context.delete(a) }
            for x in (try? context.fetch(FetchDescriptor<CategoryRule>())) ?? [] { context.delete(x) }
            for x in (try? context.fetch(FetchDescriptor<RecurringRule>())) ?? [] { context.delete(x) }
            for x in (try? context.fetch(FetchDescriptor<ImportBatch>())) ?? [] { context.delete(x) }
            try? context.save()
            UserDefaults.standard.set(false, forKey: seededKey)
        }
        let existing = (try? context.fetch(FetchDescriptor<LedgerRecord>())) ?? []
        guard force || (!UserDefaults.standard.bool(forKey: seededKey) && existing.isEmpty) else { return }

        DataStore.seedIfNeeded(container: container)   // 默认分类
        // 账户
        let cash = LedgerAccount(name: "现金", type: .cash, initialBalance: 320, sortOrder: 0)
        let wechat = LedgerAccount(name: "微信", type: .wechat, initialBalance: 860, sortOrder: 1)
        let alipay = LedgerAccount(name: "支付宝", type: .alipay, initialBalance: 1240, sortOrder: 2)
        let bank = LedgerAccount(name: "银行卡", type: .debit, initialBalance: 6800, sortOrder: 3)
        for a in [cash, wechat, alipay, bank] { context.insert(a) }

        let cats = (try? context.fetch(FetchDescriptor<LedgerCategory>())) ?? []
        func cat(_ name: String, _ kind: RecordKind) -> LedgerCategory? {
            cats.first { $0.name == name && $0.kind == kind }
        }

        let cal = DateText.calendar
        let today = Date()
        // 近 45 天的小额流水
        let samples: [(Int, Int, Int, Double, String, RecordKind, String, String, LedgerAccount)] = [
            (0, 12, 20, 28, "餐饮", .expense, "午饭", "沙县小吃", wechat),
            (0, 8, 10, 6, "交通", .expense, "地铁", "", alipay),
            (1, 19, 40, 45.5, "餐饮", .expense, "晚饭外卖", "美团外卖", wechat),
            (2, 9, 0, 15, "通讯", .expense, "话费", "中国移动", alipay),
            (3, 13, 15, 32, "餐饮", .expense, "", "瑞幸咖啡", wechat),
            (5, 18, 30, 68, "购物", .expense, "日用品", "叮咚买菜", alipay),
            (7, 12, 0, 22, "餐饮", .expense, "午饭", "", cash),
            (8, 21, 10, 99, "娱乐", .expense, "电影", "淘票票", wechat),
            (10, 8, 45, 18.5, "交通", .expense, "打车", "滴滴出行", alipay),
            (12, 11, 30, 16, "餐饮", .expense, "早餐", "", cash),
            (14, 20, 0, 120, "人情", .expense, "聚餐 AA", "", wechat),
            (16, 9, 20, 35, "医疗", .expense, "感冒药", "药店", alipay),
            (18, 14, 0, 56, "购物", .expense, "", "拼多多", alipay),
            (20, 7, 50, 4, "交通", .expense, "公交", "", cash),
            (22, 12, 40, 42, "餐饮", .expense, "工作餐", "", wechat),
            (25, 10, 0, 200, "红包", .income, "微信红包", "", wechat),
            (28, 19, 20, 88, "餐饮", .expense, "海底捞", "", bank),
            (30, 8, 30, 12, "餐饮", .expense, "早餐", "", cash),
            (32, 21, 0, 30, "通讯", .expense, "宽带", "电信", alipay),
            (35, 13, 10, 26, "餐饮", .expense, "", "肯德基", wechat),
            (38, 17, 45, 15.8, "交通", .expense, "地铁月充", "", alipay),
            (40, 12, 0, 5000, "工资", .income, "工资", "", bank),
            (42, 20, 30, 210, "购物", .expense, "衣服", "优衣库", bank),
            (44, 9, 15, 9.9, "娱乐", .expense, "会员", "爱奇艺", alipay),
        ]
        for (day, hour, minute, amount, catName, kind, note, merchant, account) in samples {
            var comps = cal.dateComponents([.year, .month, .day], from: today)
            let base = cal.date(from: comps) ?? today
            let date = cal.date(byAdding: DateComponents(day: -day, hour: hour, minute: minute), to: cal.startOfDay(for: base)) ?? today
            let r = LedgerRecord(amount: amount, kind: kind, category: cat(catName, kind),
                                 note: note, merchant: merchant, account: account.name, date: date, source: "manual")
            r.accountRef = account
            context.insert(r)
        }

        ModeDefaults.seedDecoyDefaultsIfNeeded()
        ModeDefaults.decoy.set(3000.0, forKey: SettingsKey.monthlyBudget)
        try? context.save()
        UserDefaults.standard.set(true, forKey: seededKey)
    }
}
