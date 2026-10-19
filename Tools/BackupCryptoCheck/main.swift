import Foundation

// 加密备份自检（macOS CI）：
// swiftc Ledger/Backup/BackupCrypto.swift Ledger/Backup/BackupFormat.swift Tools/BackupCryptoCheck/main.swift -o backupcheck
// ./backupcheck Tests/Fixtures/backup

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "PASS " : "FAIL ") + name)
    if !ok { failures += 1 }
}
func expectError(_ name: String, _ expected: BackupCryptoError? = nil, _ body: () throws -> Void) {
    do {
        try body()
        check(false, name + "（应当失败却成功了）")
    } catch let e as BackupCryptoError {
        check(expected == nil || e == expected, name + " → \(e)")
    } catch {
        check(expected == nil, name + " → \(error)")
    }
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/Fixtures/backup")
let v1 = try Data(contentsOf: dir.appendingPathComponent("v1-plain.json"))
let v3 = try Data(contentsOf: dir.appendingPathComponent("v3-plain.json"))

// 1. 明文备份仍可解析（v1 / v3），且不会被识别为加密
for (name, data) in [("v1", v1), ("v3", v3)] {
    check(!BackupCrypto.isEncrypted(data), "\(name) 明文不被识别为加密")
    do {
        let b = try BackupJSON.open(data, password: nil)
        check(b.records.count == 2, "\(name) 明文解析：\(b.records.count) 笔记录")
    } catch {
        check(false, "\(name) 明文解析失败：\(error)")
    }
}

// 2. 往返：加密 → 解密 → 内容逐字节一致 → 能解析
let password = "简账-Backup 2026!"
let t0 = Date()
let iterations = BackupCrypto.tunedIterations()
let enc = try BackupCrypto.encrypt(v3, password: password, iterations: iterations)
let encMs = Int(Date().timeIntervalSince(t0) * 1000)
print("迭代次数 \(iterations)，校准 + 加密耗时 \(encMs) ms，明文 \(v3.count) B → 密文 \(enc.count) B")
check(iterations >= 600_000, "迭代次数 ≥ 600000")
check(BackupCrypto.isEncrypted(enc), "密文带 JZBK 文件头")
check(enc.range(of: Data("jianzhang-backup".utf8)) == nil && enc.range(of: Data("星巴克".utf8)) == nil, "密文中不含明文内容")
let h = try BackupCrypto.parseHeader(enc)
check(h.iterations == max(iterations, BackupCrypto.minIterations), "文件头记录迭代次数 \(h.iterations)")
check(h.salt.count == 16 && h.nonce.count == 12, "salt 16 B / nonce 12 B")
check(h.flags & BackupCrypto.flagCompressed != 0, "已压缩")
let t1 = Date()
let dec = try BackupCrypto.decrypt(enc, password: password)
print("解密耗时 \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
check(dec == v3, "往返后与原文逐字节一致")
let opened = try BackupJSON.open(enc, password: password)
check(opened.version == 3 && opened.accounts?.count == 2, "加密备份解析为 v3 备份")

// Unicode 规范化：NFD 输入的同一密码也能解开
let nfd = password.decomposedStringWithCanonicalMapping
check((try? BackupCrypto.decrypt(enc, password: nfd)) == v3, "NFC/NFD 同形密码等价")

// 同一明文两次加密结果不同（随机 salt / nonce）
let enc2 = try BackupCrypto.encrypt(v3, password: password, iterations: iterations)
check(enc2 != enc, "两次加密密文不同")

// 不压缩路径
let encRaw = try BackupCrypto.encrypt(v1, password: password, iterations: 600_000, compress: false)
check((try? BackupCrypto.decrypt(encRaw, password: password)) == v1, "不压缩往返")

// 3. 错误密码 → wrongPassword（不崩溃）
expectError("错误密码", .wrongPassword) { _ = try BackupCrypto.decrypt(enc, password: "wrong-password") }
expectError("空密码", .passwordNeeded) { _ = try BackupCrypto.decrypt(enc, password: "") }
expectError("加密备份未提供密码", .passwordNeeded) { _ = try BackupJSON.open(enc, password: nil) }

// 4. 篡改任意位置的一个字节都会失败：文件头（AAD）、salt、nonce、密文、标签
let positions: [(String, Int)] = [
    ("flags", 6), ("保留字节", 7), ("salt", 14), ("nonce", 13 + 16 + 3),
    ("密文开头", h.length), ("密文中间", h.length + (enc.count - h.length - 16) / 2), ("认证标签", enc.count - 1),
]
for (name, i) in positions {
    var t = enc
    t[i] ^= 0x01
    expectError("篡改\(name)（第 \(i) 字节）") { _ = try BackupCrypto.decrypt(t, password: password) }
}
var badIter = enc
badIter[11] ^= 0x01   // 迭代次数改动 → 密钥不同 → 认证失败
expectError("篡改迭代次数", .wrongPassword) { _ = try BackupCrypto.decrypt(badIter, password: password) }
expectError("截断文件") { _ = try BackupCrypto.decrypt(enc.prefix(40), password: password) }
expectError("截掉标签") { _ = try BackupCrypto.decrypt(enc.dropLast(16), password: password) }
var future = enc
future[4] = 9
expectError("未来格式版本", .unsupported(9)) { _ = try BackupCrypto.decrypt(future, password: password) }

// 5. 密码强度
check(BackupCrypto.strength(of: "12345") == .tooShort, "强度：5 位过短")
check(BackupCrypto.strength(of: "111111") == .weak, "强度：重复字符弱")
check(BackupCrypto.strength(of: "jianzhang-2026!") == .strong, "强度：长且混合为强")

print(failures == 0 ? "BACKUP CRYPTO ALL PASSED" : "BACKUP CRYPTO \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
