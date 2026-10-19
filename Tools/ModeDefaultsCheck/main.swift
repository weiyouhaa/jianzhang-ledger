import Foundation

/// 轻量校验：防窥偏好 suite 与 standard 隔离（不依赖 SwiftUI / SessionManager）
var failed = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "PASS " : "FAIL ") + name)
    if !ok { failed += 1 }
}

let suiteName = "com.fve.ledger.decoyprefs.ci-test-\(UUID().uuidString)"
guard let decoy = UserDefaults(suiteName: suiteName) else {
    print("FAIL create suite")
    exit(1)
}
defer {
    decoy.removePersistentDomain(forName: suiteName)
}

let realKey = "monthlyBudget"
let learnKey = "rules.learnEnabled"

// 真实 standard 写入大额预算
UserDefaults.standard.set(99999.0, forKey: realKey)
UserDefaults.standard.set(false, forKey: learnKey)

// 防窥 suite 写入小额
decoy.set(3000.0, forKey: realKey)
decoy.set(true, forKey: learnKey)

check(UserDefaults.standard.double(forKey: realKey) == 99999.0, "真实 standard 预算保持 99999")
check(decoy.double(forKey: realKey) == 3000.0, "防窥 suite 预算为 3000")
check(UserDefaults.standard.double(forKey: realKey) != decoy.double(forKey: realKey), "两边预算不相等")
check(UserDefaults.standard.bool(forKey: learnKey) == false, "真实 learnEnabled=false")
check(decoy.bool(forKey: learnKey) == true, "防窥 learnEnabled=true")

// 清除防窥不影响真实
decoy.removeObject(forKey: realKey)
check(UserDefaults.standard.double(forKey: realKey) == 99999.0, "清防窥 suite 不改真实预算")

// 清理测试写入的 standard 键（尽量还原）
UserDefaults.standard.removeObject(forKey: realKey)
UserDefaults.standard.removeObject(forKey: learnKey)

print(failed == 0 ? "MODE DEFAULTS ISOLATION ALL PASSED" : "MODE DEFAULTS \(failed) FAILED")
exit(failed == 0 ? 0 : 1)
