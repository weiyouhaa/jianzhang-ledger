// 余额与统计口径测试：swiftc Ledger/Models/RecordKind.swift Tools/BalanceCheck/main.swift
import Foundation

struct Acc { let name: String; let liability: Bool; let initial: Double }
struct Rec { let kind: RecordKind; let amount: Double; let fee: Double; let from: String; let to: String? }

var failures = 0
func check(_ ok: Bool, _ msg: String) {
    print((ok ? "PASS " : "FAIL ") + msg)
    if !ok { failures += 1 }
}
func balance(_ a: Acc, _ recs: [Rec]) -> Double {
    a.initial + recs.reduce(0) { $0 + BalanceMath.effect(kind: $1.kind, amount: $1.amount, fee: $1.fee,
                                                        isSource: $1.from == a.name, isTarget: $1.to == a.name) }
}
func near(_ x: Double, _ y: Double) -> Bool { abs(x - y) < 0.001 }

let bank = Acc(name: "银行卡", liability: false, initial: 10_000)
let card = Acc(name: "信用卡", liability: true, initial: -3_000)   // 欠 3000
var recs: [Rec] = []
check(near(balance(bank, recs), 10_000) && near(max(0, -balance(card, recs)), 3_000), "初始：银行卡 10000，信用卡欠 3000")

// 还款 1000：银行卡 → 信用卡
let repay = Rec(kind: .transfer, amount: 1_000, fee: 0, from: "银行卡", to: "信用卡")
recs.append(repay)
check(near(balance(bank, recs), 9_000), "还款后银行卡 −1000 → 9000（实际 \(balance(bank, recs))）")
check(near(max(0, -balance(card, recs)), 2_000), "还款后信用卡欠 2000（实际 \(max(0, -balance(card, recs)))）")

// 编辑：金额改 1500
recs[0] = Rec(kind: .transfer, amount: 1_500, fee: 0, from: "银行卡", to: "信用卡")
check(near(balance(bank, recs), 8_500) && near(max(0, -balance(card, recs)), 1_500), "编辑为 1500：银行卡 8500，信用卡欠 1500")

// 删除：完全还原
recs.removeAll()
check(near(balance(bank, recs), 10_000) && near(max(0, -balance(card, recs)), 3_000), "删除后还原：银行卡 10000，信用卡欠 3000")

// 净资产不变（资产 −1000，负债 −1000）
let before = balance(bank, []) + balance(card, [])
let after = balance(bank, [repay]) + balance(card, [repay])
check(near(before, after), "还款不改变净资产（\(before) = \(after)）")

// 刷卡消费 + 还款：消费让欠款增加，还款抵消
let spend = Rec(kind: .expense, amount: 200, fee: 0, from: "信用卡", to: nil)
check(near(max(0, -balance(card, [spend, repay])), 2_200), "刷卡 200 + 还款 1000：欠 2200")

// 统计口径
check(BalanceMath.statsKind(kind: .transfer, toLiability: true, includeRepayment: false) == nil, "默认还款不计入支出")
check(BalanceMath.statsKind(kind: .transfer, toLiability: true, includeRepayment: true) == .expense, "开启后还款计入支出")
check(BalanceMath.statsKind(kind: .transfer, toLiability: false, includeRepayment: true) == nil, "普通转账始终不计入")
check(BalanceMath.statsKind(kind: .expense, toLiability: false, includeRepayment: false) == .expense, "支出照常计入")
check(BalanceMath.statsKind(kind: .adjustment, toLiability: false, includeRepayment: true) == nil, "校准不计入")
check(BalanceMath.isRepayment(kind: .transfer, toLiability: true) && !BalanceMath.isRepayment(kind: .expense, toLiability: true), "还款识别")

// MARK: - 导入历史账单保持余额（2.0 (13)）

func day(_ s: String) -> Date {
    let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")!; f.dateFormat = "yyyy-MM-dd"
    return f.date(from: s)!
}
func nearMap(_ a: [String: Double], _ b: [String: Double]) -> Bool {
    let keys = Set(a.keys).union(b.keys)
    return keys.allSatisfy { near(a[$0] ?? 0, b[$0] ?? 0) }
}

check(!ImportBalanceMath.isHistorical(date: day("2026-10-01"), latestExisting: nil), "空账本：导入都算新交易")
check(ImportBalanceMath.isHistorical(date: day("2026-09-01"), latestExisting: day("2026-10-01")), "早于最新 → 历史")
check(ImportBalanceMath.isHistorical(date: day("2026-10-01"), latestExisting: day("2026-10-01")), "等于最新 → 历史")
check(!ImportBalanceMath.isHistorical(date: day("2026-10-02"), latestExisting: day("2026-10-01")), "晚于最新 → 计入余额")

// 空账本：导入支出 50，余额应变
do {
    let r = ImportBalanceMath.simulate(initials: ["cash": 1000], existingEffects: [],
        imported: [(kind: .expense, amount: 50, fee: 0, date: day("2026-10-01"), from: "cash", to: nil)])
    check(r.preservedCount == 0 && near(r.balances["cash"] ?? 0, 950) && r.adjustments.isEmpty,
          "空账本导入支出：余额 1000→950，无初始余额调整")
}

// 有最新记录：导入更早的支出，余额不变，initialBalance 上调
do {
    let before = 5000.0
    let r = ImportBalanceMath.simulate(
        initials: ["bank": before],
        existingEffects: [(accountID: "bank", date: day("2026-10-20"), effect: -100)], // 余额已是 4900
        imported: [(kind: .expense, amount: 80, fee: 0, date: day("2026-10-05"), from: "bank", to: nil)])
    check(r.preservedCount == 1, "历史导入计为保持余额")
    check(near(r.adjustments["bank"] ?? 0, 80), "初始余额 +80 抵消历史支出效果")
    check(near(r.balances["bank"] ?? 0, 4900), "导入历史后当前余额仍为 4900")
    // 撤销：去掉调整
    // 更直接：撤销后余额 = 当前 − adj − effect_of_deleted = 4900 − 80 − (−80) = 4900
    check(near((r.balances["bank"] ?? 0) - (r.adjustments["bank"] ?? 0) - (-80), 4900), "撤销后余额还原为 4900")
}

// 导入比最新更新的：余额变化、无调整
do {
    let r = ImportBalanceMath.simulate(
        initials: ["bank": 5000],
        existingEffects: [(accountID: "bank", date: day("2026-10-01"), effect: 0)],
        imported: [(kind: .expense, amount: 30, fee: 0, date: day("2026-10-15"), from: "bank", to: nil)])
    check(r.preservedCount == 0 && r.adjustments.isEmpty && near(r.balances["bank"] ?? 0, 4970),
          "较新导入：余额 5000→4970，无调整")
}

// 历史转账：转出 / 转入双方都调初始余额
do {
    let r = ImportBalanceMath.simulate(
        initials: ["wechat": 800, "bank": 2000],
        existingEffects: [
            (accountID: "wechat", date: day("2026-10-18"), effect: -50),
            (accountID: "bank", date: day("2026-10-18"), effect: 0)
        ],
        imported: [(kind: .transfer, amount: 200, fee: 0, date: day("2026-09-01"), from: "bank", to: "wechat")])
    check(r.preservedCount == 1, "历史转账计为保持余额")
    check(near(r.adjustments["bank"] ?? 0, 200) && near(r.adjustments["wechat"] ?? 0, -200),
          "转账双方初始余额对冲（转出 +200，转入 −200）")
    check(near(r.balances["bank"] ?? 0, 2000) && near(r.balances["wechat"] ?? 0, 750),
          "历史转账后当前余额不变（bank 2000，wechat 750）")
}

// offsets 编解码
do {
    let raw = ImportBalanceMath.encodeOffsets(["a": 12.5, "b": -3])
    let back = ImportBalanceMath.decodeOffsets(raw)
    check(near(back["a"] ?? 0, 12.5) && near(back["b"] ?? 0, -3), "offsets JSON 往返")
    check(ImportBalanceMath.decodeOffsets("").isEmpty && ImportBalanceMath.encodeOffsets([:]).isEmpty, "空 offsets")
}


// MARK: - 账户明细「当条之后余额」(2.0 (14))

do {
    let d1 = day("2026-01-01")
    let d2 = day("2026-01-02")
    // 同日两条：id 字典序 a < b，先扣 100 再入 50
    let entries: [(id: String, date: Date, effect: Double)] = [
        ("b", d1, 50),   // income +50（故意乱序传入）
        ("a", d1, -100), // expense -100
        ("c", d2, -200),
    ]
    let map = BalanceMath.runningBalances(initialBalance: 1000, entries: entries)
    check(near(map["a"] ?? -1, 900), "同日先 a：1000−100 → 900（实际 \(map["a"] ?? -1)）")
    check(near(map["b"] ?? -1, 950), "同日后 b：900+50 → 950（实际 \(map["b"] ?? -1)）")
    check(near(map["c"] ?? -1, 750), "次日 c：950−200 → 750（实际 \(map["c"] ?? -1)）")
    // 最终应等于 initial + Σ effects
    let final = 1000 + entries.reduce(0) { $0 + $1.effect }
    check(near(map["c"] ?? -1, final), "最后一条之后余额 = 初始+全部效果")
}

do {
    // 负债：初始欠 3000（initial −3000）；还款转入 +1000 → −2000；校准 +50 → −1950
    let d1 = day("2026-03-01")
    let d2 = day("2026-03-02")
    let map = BalanceMath.runningBalances(
        initialBalance: -3000,
        entries: [
            ("repay", d1, BalanceMath.effect(kind: .transfer, amount: 1000, fee: 0, isSource: false, isTarget: true)),
            ("adj", d2, BalanceMath.effect(kind: .adjustment, amount: 50, fee: 0, isSource: true, isTarget: false)),
        ])
    check(near(map["repay"] ?? 0, -2000), "负债还款后余额 −2000（欠 2000）")
    check(near(map["adj"] ?? 0, -1950), "负债校准后余额 −1950（欠 1950）")
}

do {
    // 空列表
    check(BalanceMath.runningBalances(initialBalance: 42, entries: []).isEmpty, "无记录 → 空 map")
}



print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
