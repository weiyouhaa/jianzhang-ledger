import Foundation

// 轻量校验：防窥密码与真实密码路由逻辑（不依赖 UIKit）
// 在 CI 上用简化版哈希逻辑镜像 DecoyPasscodeStore / PasscodeStore 的「不得相同」规则说明。

var failed = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "PASS " : "FAIL ") + name)
    if !ok { failed += 1 }
}

let real = "2580"
let decoy = "1470"
check(real != decoy, "防窥密码与真实密码不同")
check(decoy.count >= 4, "防窥密码长度合理")

// 路由表
enum Unlock { case real, decoy, reject }
func route(input: String, biometrics: Bool) -> Unlock {
    if biometrics { return .real }
    if input == real { return .real }
    if input == decoy { return .decoy }
    return .reject
}
check(route(input: real, biometrics: false) == .real, "真实密码 → 真实账本")
check(route(input: decoy, biometrics: false) == .decoy, "防窥密码 → 防窥账本")
check(route(input: "0000", biometrics: false) == .reject, "错误密码 → 拒绝")
check(route(input: decoy, biometrics: true) == .real, "面容 ID → 始终真实账本")


// 3.8 (29)：变动日志写入策略的纯逻辑镜像——防窥会话必须跳过（与 ChangeLogger.log / defaultsChanged 一致）
do {
    enum Mode { case real, decoy }
    func shouldWriteChangeLog(mode: Mode, installed: Bool) -> Bool {
        guard installed else { return false }
        return mode != .decoy
    }
    check(shouldWriteChangeLog(mode: .real, installed: true), "真实账本 + 已安装 → 写日志")
    check(!shouldWriteChangeLog(mode: .decoy, installed: true), "防窥会话 → 不写日志")
    check(!shouldWriteChangeLog(mode: .real, installed: false), "未安装 → 不写日志")
}

print(failed == 0 ? "PASSCODE ROUTE ALL PASSED" : "PASSCODE ROUTE \(failed) FAILED")
exit(failed == 0 ? 0 : 1)
