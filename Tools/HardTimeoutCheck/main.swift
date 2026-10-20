// 硬超时测试：swiftc Ledger/OCR/HardTimeout.swift Tools/HardTimeoutCheck/main.swift
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: String) {
    print((ok ? "✅ " : "❌ ") + msg)
    if !ok { failures += 1 }
}

/// 不响应取消的慢操作（模拟模型不理会 cancel）
func stubborn(_ seconds: Double) -> Int {
    Thread.sleep(forTimeInterval: seconds)
    return 1
}

let sema = DispatchSemaphore(value: 0)
Task {
    // 1. 慢且不响应取消：0.5 秒超时必须在 ~0.5 秒返回，而不是等 3 秒
    var t = Date()
    let r1 = await HardTimeout.run(seconds: 0.5, onTimeout: { -1 }, operation: { stubborn(3) })
    let e1 = Date().timeIntervalSince(t)
    check(r1 == -1 && e1 < 1.5, String(format: "不响应取消的慢操作：%.2f 秒返回超时", e1))

    // 2. 快操作返回结果
    t = Date()
    let r2 = await HardTimeout.run(seconds: 2, onTimeout: { -1 }, operation: { 42 })
    check(r2 == 42 && Date().timeIntervalSince(t) < 1, "快操作返回结果")

    // 3. 响应取消的操作超时后被取消
    let flag = CancelFlag()
    let r3 = await HardTimeout.run(seconds: 0.2, onTimeout: { -1 }, operation: {
        do { try await Task.sleep(nanoseconds: 2_000_000_000); return 7 } catch { flag.set(); return -2 }
    })
    try? await Task.sleep(nanoseconds: 300_000_000)
    check(r3 == -1 && flag.value, "超时后取消了操作")

    // 4. 竞态：操作耗时 ≈ 超时，重复 300 次，不得崩溃（续体只恢复一次），每次都有结果
    var got = 0
    for i in 0..<300 {
        let r = await HardTimeout.run(seconds: 0.01, onTimeout: { -1 }, operation: {
            if i % 2 == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
            return i
        })
        if r == -1 || r == i { got += 1 }
    }
    check(got == 300, "竞态 300 次均正常返回（无重复恢复崩溃）")

    // 5. 并发 50 个
    let results = await withTaskGroup(of: Int.self) { g -> [Int] in
        for i in 0..<50 { g.addTask { await HardTimeout.run(seconds: 0.05, onTimeout: { -1 }, operation: { i % 3 == 0 ? stubborn(0.2) : i }) } }
        var all: [Int] = []
        for await r in g { all.append(r) }
        return all
    }
    check(results.count == 50, "并发 50 个均返回")
    sema.signal()
}
sema.wait()
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}
