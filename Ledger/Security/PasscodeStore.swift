import Foundation
import CryptoKit

/// 密码只以「随机盐 + 多轮 SHA-256」的哈希形式保存在 Keychain 中，明文不落盘
enum PasscodeStore {
    private static let account = "passcode.hash.v1"
    private static let iterations = 20_000

    private struct Stored: Codable {
        let salt: Data
        let hash: Data
        let length: Int
    }

    static var isSet: Bool { load() != nil }
    static var length: Int { load()?.length ?? 4 }

    static func save(_ passcode: String) -> Bool {
        var salt = Data(count: 16)
        let ok = salt.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return SecRandomCopyBytes(kSecRandomDefault, 16, base) == errSecSuccess
        }
        if !ok { salt = Data(UUID().uuidString.utf8) }
        let stored = Stored(salt: salt, hash: derive(passcode, salt: salt), length: passcode.count)
        guard let data = try? JSONEncoder().encode(stored) else { return false }
        return KeychainStore.set(data, for: account)
    }

    static func verify(_ passcode: String) -> Bool {
        guard let stored = load() else { return false }
        let candidate = derive(passcode, salt: stored.salt)
        return constantTimeEqual(candidate, stored.hash)
    }

    static func remove() {
        KeychainStore.delete(account)
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
