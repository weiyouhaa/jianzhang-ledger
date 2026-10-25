// 一键去重 / 导入查重 自检（纯合成数据；Linux 与 macOS 均可运行）：
// swiftc Ledger/OCR/ReceiptParser.swift Ledger/Dedupe/DedupeEngine.swift Tools/DedupeCheck/main.swift -o /tmp/dedupecheck && /tmp/dedupecheck
import Foundation

var failures = 0
func expect(_ cond: Bool, _ msg: String) {
    if cond { print("✅ \(msg)") } else { failures += 1; print("❌ \(msg)") }
}

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
func t(_ day: Int, _ h: Int, _ m: Int, _ s: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 3, day: day, hour: h, minute: m, second: s))!
}
func rec(_ id: String, _ amount: Double, _ date: Date, kind: String = "expense", merchant: String = "", note: String = "",
         account: String? = nil, to: String? = nil, category: String? = nil, ext: String = "", source: String = "manual",
         batch: String = "", created: Date? = nil) -> DedupeRecord {
    DedupeRecord(id: id, kind: kind, amount: amount, date: date, merchant: merchant, note: note, accountID: account,
                 toAccountID: to, categoryName: category, externalID: ext, source: source, importBatchID: batch,
                 recurringKey: "", createdAt: created ?? date)
}
func opts(_ w: DedupeWindow = .min30, ignored: Set<String> = []) -> DedupeOptions {
    DedupeOptions(window: w, ignoredPairs: ignored, calendar: cal)
}
func groupOf(_ groups: [DedupeGroup], _ id: String) -> DedupeGroup? { groups.first { $0.members.contains { $0.id == id } } }

// MARK: 打分

do {
    let a = rec("a", 23.5, t(5, 12, 0), merchant: "示例面馆", account: "acc1", category: "餐饮", source: "manual")
    let b = rec("b", 23.5, t(5, 12, 0, 40), merchant: "美团-示例面馆", account: "acc1", category: "餐饮", source: "ocr")
    let s = DedupeEngine.score(a, b, options: opts())
    expect(s?.confidence == .certain, "同额、40 秒内、同账户、商户相近（去掉平台前缀）→ 确定重复 (\(s?.score ?? -1))")

    let c = rec("c", 23.5, t(5, 12, 2), source: "shortcut")
    let sc = DedupeEngine.score(a, c, options: opts())
    expect(sc?.confidence == .possible, "只知金额和时间（2 分钟）→ 可能重复 (\(sc?.score ?? -1))")

    let d = rec("d", 23.5, t(5, 12, 2), account: "acc1", source: "shortcut")
    expect(DedupeEngine.score(a, d, options: opts())?.confidence == .likely, "2 分钟 + 同账户 → 很可能")

    let e = rec("e", 23.5, t(5, 12, 0, 20), account: "acc2", source: "ocr")
    expect(DedupeEngine.score(a, e, options: opts()) == nil, "账户不同 → 不算重复")

    let f = rec("f", 23.5, t(5, 12, 0, 20), merchant: "示例书店", account: "acc1", source: "ocr")
    let sf = DedupeEngine.score(a, f, options: opts())
    expect(sf == nil || sf!.confidence < .likely, "商户明显不同 → 降为可能或不算 (\(sf?.score ?? -1))")

    let g = rec("g", 23.51, t(5, 12, 0), merchant: "示例面馆", account: "acc1")
    expect(DedupeEngine.score(a, g, options: opts()) == nil, "金额差 1 分 → 不算重复")

    let h = rec("h", 23.5, t(5, 12, 0), kind: "income", merchant: "示例面馆", account: "acc1")
    expect(DedupeEngine.score(a, h, options: opts()) == nil, "收入与支出 → 不算重复")

    let noMerchant = rec("nm", 23.5, t(5, 12, 0, 30), account: "acc1", category: "餐饮", source: "manual")
    let snm = DedupeEngine.score(a, noMerchant, options: opts())
    expect(snm?.confidence == .likely, "没有商户可比：时间 + 账户 + 分类再接近也只到「很可能」，不会被自动删 (\(snm?.score ?? -1))")

    let late = rec("late", 23.5, t(5, 12, 25), merchant: "示例面馆", account: "acc1")
    expect(DedupeEngine.score(a, late, options: opts(.min30)) != nil, "25 分钟：30 分钟窗口内")
    expect(DedupeEngine.score(a, late, options: opts(.min10)) == nil, "25 分钟：10 分钟窗口外")
    expect(DedupeEngine.score(a, late, options: opts(.min3)) == nil, "25 分钟：3 分钟窗口外")
    let evening = rec("eve", 23.5, t(5, 19, 0), merchant: "示例面馆", account: "acc1")
    expect(DedupeEngine.score(a, evening, options: opts(.sameDay)) != nil, "同一天窗口：中午与晚上可比对")
    expect(DedupeEngine.score(a, rec("nd", 23.5, t(6, 0, 5), merchant: "示例面馆", account: "acc1"), options: opts(.sameDay)) == nil,
           "同一天窗口：跨天不比对")
    expect(DedupeEngine.score(a, b, options: opts(ignored: [DedupeEngine.pairKey("b", "a")])) == nil, "标记过「不是重复」→ 不再出现")
}

// MARK: 订单号 / 导入批次

do {
    let x = rec("x1", 88, t(7, 9, 0), ext: "ORD-0001", source: "alipay", batch: "B1")
    let y = rec("x2", 88, t(7, 9, 0), ext: "ORD-0001", source: "alipay", batch: "B2")
    expect(DedupeEngine.score(x, y, options: opts())?.confidence == .certain, "订单号相同 → 确定重复")
    let z = rec("x3", 88, t(7, 9, 0), ext: "ORD-0002", source: "alipay", batch: "B2")
    expect(DedupeEngine.score(x, z, options: opts()) == nil, "同一来源、不同订单号 → 不是重复")
    let w = rec("x4", 88, t(7, 9, 0), source: "alipay", batch: "B1")
    expect(DedupeEngine.score(x, w, options: opts()) == nil, "同一导入批次的两行 → 不是重复")
    let edited = rec("x5", 90, t(7, 9, 0), ext: "ORD-0001", source: "alipay", batch: "B3")
    let gs = DedupeEngine.groups([x, edited], options: opts())
    expect(gs.count == 1 && gs[0].confidence == .certain, "订单号相同但金额被改过 → 仍成组")
}

// MARK: 转账

do {
    let t1 = rec("t1", 500, t(8, 10, 0), kind: "transfer", account: "card", to: "wallet", source: "manual")
    let t2 = rec("t2", 500, t(8, 10, 0, 30), kind: "transfer", account: "card", to: "wallet", source: "shortcut")
    expect(DedupeEngine.score(t1, t2, options: opts())?.confidence == .certain, "转账：同转出 / 转入账户、30 秒 → 确定重复")
    let t3 = rec("t3", 500, t(8, 10, 0, 30), kind: "transfer", account: "card", to: "credit", source: "shortcut")
    expect(DedupeEngine.score(t1, t3, options: opts()) == nil, "转账：转入账户不同 → 不算重复")
}

// MARK: 分组

do {
    // 三张截图记了三次同一笔
    let r1 = rec("r1", 31.8, t(10, 18, 0), merchant: "示例煲仔饭（示例大厦店）", account: "acc1", source: "ocr", created: t(10, 18, 1))
    let r2 = rec("r2", 31.8, t(10, 18, 0, 30), merchant: "示例煲仔饭", account: "acc1", source: "shortcut", created: t(10, 18, 2))
    let r3 = rec("r3", 31.8, t(10, 18, 1), merchant: "示例煲仔饭(示例大厦店)", account: "acc1", category: "餐饮", source: "manual", created: t(10, 18, 3))
    // 不相关的
    let u1 = rec("u1", 12, t(10, 8, 0), merchant: "示例便利店", account: "acc1")
    let u2 = rec("u2", 31.8, t(11, 18, 0), merchant: "示例煲仔饭", account: "acc1")
    let groups = DedupeEngine.groups([u1, r2, u2, r3, r1], options: opts())
    expect(groups.count == 1, "三笔同一消费 → 1 组（\(groups.count)）")
    expect(groups.first?.members.map(\.id) == ["r1", "r2", "r3"], "组内按时间排序：\(groups.first?.members.map(\.id) ?? [])")
    expect(groups.first?.confidence == .certain, "三笔两两确定 → 组为确定重复")
    expect(groups.first?.suggestedKeepID == "r3", "建议保留字段最完整的一笔（有分类）：\(groups.first?.suggestedKeepID ?? "-")")

    // 账单里两笔同额（同一批次）+ 手动记的一笔 → 手动那笔只和最接近的一笔成组
    let b1 = rec("b1", 15, t(12, 8, 0), merchant: "示例咖啡", ext: "ORD-A", source: "wechat", batch: "W1")
    let b2 = rec("b2", 15, t(12, 8, 9), merchant: "示例咖啡", ext: "ORD-B", source: "wechat", batch: "W1")
    let m = rec("m", 15, t(12, 8, 8), merchant: "示例咖啡", category: "餐饮", source: "manual")
    let g2 = DedupeEngine.groups([b1, b2, m], options: opts())
    expect(g2.count == 1 && Set(g2[0].members.map(\.id)) == ["b2", "m"], "账单两笔 + 手动一笔 → 只成一组（手动 + 最近的账单）：\(g2.map { $0.members.map(\.id) })")
    expect(g2.first?.suggestedKeepID == "b2", "建议保留有订单号的账单记录")
    if let g = g2.first, let keep = g.members.first(where: { $0.id == g.suggestedKeepID }) {
        let patch = DedupeEngine.mergePatch(keep: keep, others: g.members.filter { $0.id != keep.id })
        expect(patch.categoryFrom == "m", "合并：账单记录没有分类 → 用手动记录的分类")
        expect(patch.merchantFrom == nil, "合并：账单记录已有商户 → 不覆盖")
    }

    // 连锁：A~B、B~C 但 A、C 账户冲突 → 不能放进同一组
    let c1 = rec("c1", 9.9, t(13, 9, 0), account: "accA")
    let c2 = rec("c2", 9.9, t(13, 9, 1))
    let c3 = rec("c3", 9.9, t(13, 9, 2), account: "accB")
    let g3 = DedupeEngine.groups([c1, c2, c3], options: opts())
    expect(g3.count == 1 && g3[0].members.count == 2, "账户冲突的两笔不会被连锁到同一组：\(g3.map { $0.members.map(\.id) })")

    // 不是重复
    let ignored = DedupeEngine.groups([r1, r2, r3], options: opts(ignored: Set(groups[0].pairKeys)))
    expect(ignored.isEmpty, "整组标记「不是重复」后不再出现")
}

// MARK: 自动处理

do {
    let sure1 = rec("s1", 42, t(14, 12, 0), merchant: "示例面馆", note: "", account: "acc1", ext: "ORD-S", source: "alipay", batch: "A1")
    let sure2 = rec("s2", 42, t(14, 12, 0, 20), merchant: "示例面馆", note: "和同事", account: "acc1", category: "餐饮", source: "manual")
    let maybe1 = rec("p1", 6, t(14, 15, 0), source: "manual")
    let maybe2 = rec("p2", 6, t(14, 15, 2), source: "shortcut")
    let groups = DedupeEngine.groups([sure1, sure2, maybe1, maybe2], options: opts())
    expect(groups.count == 2, "两组：确定 + 可能")
    let plan = DedupeEngine.autoPlan(groups)
    expect(plan.count == 1 && plan[0].keep.id == "s1" && plan[0].delete.map(\.id) == ["s2"], "自动处理只动确定重复的组，保留账单导入那笔")
    expect(plan.first?.patch.noteFrom == "s2" && plan.first?.patch.categoryFrom == "s2", "自动处理：把手动记录的备注 / 分类补到保留记录")
}

// MARK: 账单导入一对一

do {
    // 账单两行同额 15 元，已有一笔手动记录 → 只有一行标为疑似重复
    let bills = [rec("row1", 15, t(20, 8, 0), merchant: "示例咖啡", source: "bill"),
                 rec("row2", 15, t(20, 8, 6), merchant: "示例咖啡", source: "bill"),
                 rec("row3", 200, t(20, 9, 0), kind: "transfer", account: "card", to: "wallet", source: "bill"),
                 rec("row4", 66, t(20, 10, 0), merchant: "示例超市", source: "bill")]
    let existing = [rec("e1", 15, t(20, 8, 5), merchant: "示例咖啡", source: "manual"),
                    rec("e2", 200, t(20, 9, 3), kind: "transfer", account: "card", to: "wallet", source: "manual"),
                    rec("e3", 66, t(20, 10, 15), merchant: "示例超市", source: "manual")]
    let m = DedupeEngine.matchBills(bills, existing: existing, window: .min10, calendar: cal)
    expect(m["row2"]?.existingID == "e1" && m["row1"] == nil, "一笔已有记录只匹配最接近的一行账单：\(m.mapValues(\.existingID))")
    expect(m["row3"]?.existingID == "e2", "转账也会比对（3 分钟内、账户相同）")
    expect(m["row4"] == nil, "15 分钟 → 超出导入默认的 10 分钟窗口")
    let wide = DedupeEngine.matchBills([bills[0]], existing: [rec("e4", 15, t(20, 8, 8), account: "acc9", source: "ocr")],
                                       window: .min10, calendar: cal)
    expect(wide["row1"]?.existingID == "e4", "8 分钟（原来只看 3 分钟）现在也能提示")
}

print(failures == 0 ? "\n全部通过" : "\n失败 \(failures) 项")
exit(failures == 0 ? 0 : 1)
