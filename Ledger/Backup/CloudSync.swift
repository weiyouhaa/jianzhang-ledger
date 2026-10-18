import Foundation

/// 当前数据存储的 iCloud 同步状态
enum SyncStatus: Equatable, Sendable {
    case local
    case cloud
    case noAccount
    case noEntitlement
    case failed(String)

    var title: String {
        switch self {
        case .local: return "仅本机"
        case .cloud: return "iCloud 同步中"
        case .noAccount: return "未登录 iCloud"
        case .noEntitlement: return "签名不含 iCloud 权限"
        case .failed: return "iCloud 启动失败"
        }
    }

    var detail: String {
        switch self {
        case .local:
            return "数据只保存在本机。"
        case .cloud:
            return "数据通过 iCloud 私有数据库（CloudKit）在你登录同一 Apple ID 的设备间同步。"
        case .noAccount:
            return "已开启同步，但这台设备没有登录 iCloud，当前使用本机存储。"
        case .noEntitlement:
            return "已开启同步，但当前安装包的签名没有 iCloud / CloudKit 权限（免费 Apple ID、爱思助手、Sideloadly 等签名通常会去掉它），当前使用本机存储。"
        case .failed(let message):
            return "无法连接 iCloud 容器，已回退到本机存储：\(message)"
        }
    }

    var isCloud: Bool { self == .cloud }
}

enum CloudSync {
    /// iCloud 容器 ID 跟随 Bundle ID：iCloud.<bundle id>
    static var containerID: String {
        "iCloud." + (Bundle.main.bundleIdentifier ?? "com.fve.ledger")
    }

    static var hasAccount: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// iCloud 容器目录（需要 iCloud Documents 权限）。可能阻塞，必须在后台线程调用。
    static func containerURL() async -> URL? {
        let id = containerID
        return await Task.detached(priority: .utility) {
            FileManager.default.url(forUbiquityContainerIdentifier: id)
        }.value
    }

    /// 检查签名是否带有 iCloud 容器权限，并缓存结果供下次启动创建 CloudKit 存储时使用
    @discardableResult
    static func refreshAvailability() async -> Bool {
        guard hasAccount else {
            UserDefaults.standard.set(false, forKey: SettingsKey.iCloudContainerOK)
            return false
        }
        let ok = await containerURL() != nil
        UserDefaults.standard.set(ok, forKey: SettingsKey.iCloudContainerOK)
        return ok
    }
}
