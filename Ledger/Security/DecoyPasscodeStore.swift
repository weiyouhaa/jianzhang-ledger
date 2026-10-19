import Foundation
import CryptoKit

/// 防窥密码：与真实 App 密码同样「盐 + 多轮 SHA-256」存钥匙串，必须与真实密码不同。
enum DecoyPasscodeStore {
    private static let account = "passcode.decoy.hash.v1"
    private static let iterations = 20_000
    private static let enabledKey = "lock.decoyEnabled"

    private struct Stored: Codable {
        let salt: Data
        let hash: Data
        let length: Int
    }

    static var isEnabled: Bool {
        get {
            let flag = UserDefaults.standard.bool(forKey: enabledKey)
            if ScreenshotDemo.isActive { return flag }
            return flag && isSet
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var isSet: Bool { load() != nil }
    static var length: Int { load()?.length ?? PasscodeStore.length }

    @discardableResult
    static func save(_ passcode: String) -> Bool {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return SecRandomCopyBytes(kSecRandomDefault, 16, base) == errSecSuccess
        }
        let stored = Stored(salt: salt, hash: derive(passcode, salt: salt), length: passcode.count)
        guard let data = try? JSONEncoder().encode(stored) else { return false }
        let ok = KeychainStore.set(data, for: account)
        if ok { isEnabled = true }
        return ok
    }

    static func verify(_ passcode: String) -> Bool {
        guard isEnabled, let stored = load() else { return false }
        return constantTimeEqual(derive(passcode, salt: stored.salt), stored.hash)
    }

    static func remove() {
        KeychainStore.delete(account)
        isEnabled = false
    }

    private static func load() -> Stored? {
        guard let data = KeychainStore.get(account) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private static func derive(_ passcode: String, salt: Data) -> Data {
        var digest = Data(SHA256.hash(data: salt + Data(passcode.utf8)))
        for _ in 0..<iterations {
            digest = Data(SHA256.hash(data: digest + salt))
        }
        return digest
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}
