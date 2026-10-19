import Foundation
import CryptoKit
import CommonCrypto
import Security

/// 加密备份（.jzbackup）
///
/// 文件布局（多字节整数均为大端）：
/// ```
/// 0   4  magic "JZBK"
/// 4   1  格式版本（1）
/// 5   1  KDF（1 = PBKDF2-HMAC-SHA256）
/// 6   1  flags（bit0 = 明文先经 zlib 压缩）
/// 7   1  保留（0）
/// 8   4  PBKDF2 迭代次数
/// 12  1  salt 长度 n（16）
/// 13  n  salt
/// ..  12 AES-GCM nonce
/// ..     密文（v3 备份 JSON，可能已压缩）
/// 末尾 16 GCM 认证标签
/// ```
/// 从 magic 到 nonce 的整个文件头作为 GCM 附加认证数据（AAD），改动任何一个字节都会解密失败。
enum BackupCryptoError: LocalizedError, Equatable {
    case passwordNeeded
    case wrongPassword
    case corrupted
    case unsupported(Int)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .passwordNeeded: return "这是加密备份，请输入备份密码。"
        case .wrongPassword: return "备份密码不正确，或文件已损坏 / 被修改。"
        case .corrupted: return "加密备份文件不完整或已损坏。"
        case .unsupported(let v): return "加密备份格式（v\(v)）比当前 App 新，请先升级简账。"
        case .failed(let m): return "加密失败：\(m)"
        }
    }
}

enum BackupCrypto {
    static let fileExtension = "jzbackup"
    static let magic: [UInt8] = Array("JZBK".utf8)
    static let formatVersion: UInt8 = 1
    static let kdfPBKDF2SHA256: UInt8 = 1
    static let flagCompressed: UInt8 = 0x01
    static let saltLength = 16
    static let nonceLength = 12
    static let tagLength = 16
    /// OWASP 2023 建议的 PBKDF2-HMAC-SHA256 下限
    static let minIterations: UInt32 = 600_000
    /// 读取时的上限，防止被构造的文件卡死
    static let maxIterations: UInt32 = 20_000_000
    static let targetMilliseconds: UInt32 = 500

    static func isEncrypted(_ data: Data) -> Bool {
        data.count >= 4 && Array(data.prefix(4)) == magic
    }

    // MARK: 迭代次数

    /// 按本机速度校准，使派生密钥约耗时 0.5 秒（不少于 60 万次），结果缓存在本机
    static func tunedIterations() -> UInt32 {
        let key = "backup.kdfIterations"
        let cached = UInt32(clamping: UserDefaults.standard.integer(forKey: key))
        if cached >= minIterations { return cached }
        let rounds = CCCalibratePBKDF(CCPBKDFAlgorithm(kCCPBKDF2), 16, saltLength,
                                      CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 32, targetMilliseconds)
        let tuned = min(max(rounds, minIterations), 10_000_000)
        UserDefaults.standard.set(Int(tuned), forKey: key)
        return tuned
    }

    // MARK: 密钥派生

    static func deriveKey(password: String, salt: [UInt8], iterations: UInt32) throws -> SymmetricKey {
        // 统一 Unicode 规范化，避免不同输入法产生的同形字符导致密码不一致
        let pw = Array(password.precomposedStringWithCanonicalMapping.utf8)
        guard !pw.isEmpty else { throw BackupCryptoError.passwordNeeded }
        var derived = [UInt8](repeating: 0, count: 32)
        let status = pw.withUnsafeBufferPointer { pwBuf in
            pwBuf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(pw.count, 1)) { pwPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwPtr, pw.count,
                                     salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw BackupCryptoError.failed("PBKDF2 \(status)") }
        defer { for i in derived.indices { derived[i] = 0 } }
        return SymmetricKey(data: derived)
    }

    static func randomBytes(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw BackupCryptoError.failed("随机数生成失败")
        }
        return bytes
    }

    // MARK: 加密 / 解密

    static func encrypt(_ plain: Data, password: String, iterations: UInt32 = minIterations, compress: Bool = true) throws -> Data {
        guard !password.isEmpty else { throw BackupCryptoError.passwordNeeded }
        let rounds = max(iterations, minIterations)
        var payload = plain
        var flags: UInt8 = 0
        if compress, let z = try? (plain as NSData).compressed(using: .zlib) as Data, z.count < plain.count {
            payload = z
            flags |= flagCompressed
        }
        let salt = try randomBytes(saltLength)
        let nonceBytes = try randomBytes(nonceLength)
        var header = Data(magic)
        header.append(contentsOf: [formatVersion, kdfPBKDF2SHA256, flags, 0])
        header.append(contentsOf: withUnsafeBytes(of: rounds.bigEndian, Array.init))
        header.append(UInt8(saltLength))
        header.append(contentsOf: salt)
        header.append(contentsOf: nonceBytes)

        let key = try deriveKey(password: password, salt: salt, iterations: rounds)
        do {
            let sealed = try AES.GCM.seal(payload, using: key, nonce: AES.GCM.Nonce(data: nonceBytes), authenticating: header)
            var out = header
            out.append(sealed.ciphertext)
            out.append(sealed.tag)
            return out
        } catch {
            throw BackupCryptoError.failed(error.localizedDescription)
        }
    }

    struct Header {
        var version: UInt8
        var kdf: UInt8
        var flags: UInt8
        var iterations: UInt32
        var salt: [UInt8]
        var nonce: [UInt8]
        var length: Int
    }

    static func parseHeader(_ data: Data) throws -> Header {
        let b = [UInt8](data)
        guard b.count >= 13, Array(b[0..<4]) == magic else { throw BackupCryptoError.corrupted }
        guard b[4] == formatVersion else {
            throw b[4] > formatVersion ? BackupCryptoError.unsupported(Int(b[4])) : BackupCryptoError.corrupted
        }
        guard b[5] == kdfPBKDF2SHA256 else { throw BackupCryptoError.unsupported(Int(b[5])) }
        let iterations = b[8..<12].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let saltLen = Int(b[12])
        let headerLen = 13 + saltLen + nonceLength
        guard saltLen >= 8, b.count >= headerLen + tagLength else { throw BackupCryptoError.corrupted }
        guard iterations >= 1_000, iterations <= maxIterations else { throw BackupCryptoError.corrupted }
        return Header(version: b[4], kdf: b[5], flags: b[6], iterations: iterations,
                      salt: Array(b[13..<(13 + saltLen)]),
                      nonce: Array(b[(13 + saltLen)..<headerLen]),
                      length: headerLen)
    }

    static func decrypt(_ data: Data, password: String) throws -> Data {
        guard !password.isEmpty else { throw BackupCryptoError.passwordNeeded }
        let data = Data(data)   // 归一化下标从 0 开始
        let h = try parseHeader(data)
        let header = data.prefix(h.length)
        let body = data.dropFirst(h.length)
        let ciphertext = body.dropLast(tagLength)
        let tag = body.suffix(tagLength)
        let key = try deriveKey(password: password, salt: h.salt, iterations: h.iterations)
        let payload: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: h.nonce), ciphertext: ciphertext, tag: tag)
            payload = try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            // CryptoKitError.authenticationFailure：密码错误或内容被改动
            throw BackupCryptoError.wrongPassword
        }
        if h.flags & flagCompressed != 0 {
            guard let plain = try? (payload as NSData).decompressed(using: .zlib) as Data else { throw BackupCryptoError.corrupted }
            return plain
        }
        return payload
    }

    // MARK: 密码强度

    enum Strength: Int {
        case tooShort, weak, medium, strong
        var title: String {
            switch self {
            case .tooShort: return "至少 6 位"
            case .weak: return "弱"
            case .medium: return "中"
            case .strong: return "强"
            }
        }
    }

    static func strength(of password: String) -> Strength {
        let n = password.count
        if n < 6 { return .tooShort }
        var classes = 0
        if password.contains(where: { $0.isLowercase }) { classes += 1 }
        if password.contains(where: { $0.isUppercase }) { classes += 1 }
        if password.contains(where: { $0.isNumber }) { classes += 1 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { classes += 1 }
        if password.unicodeScalars.contains(where: { $0.value > 0x2E80 }) { classes += 1 }   // 中文等
        if Set(password).count <= 2 { return .weak }
        let score = n + classes * 3
        if n >= 12 && classes >= 2 || score >= 20 { return .strong }
        if n >= 8 && classes >= 2 || score >= 14 { return .medium }
        return .weak
    }
}
