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

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
