import AppIntents

/// 审核弹窗里选「在 App 里改」后，由系统打开简账前台（openAppWhenRun）。
/// 待编辑的记录 ID 事先写在 UserDefaults（PendingAppEdit）；App 解锁进真实模式后再弹出编辑页。
struct OpenPendingEditIntent: AppIntent {
    static var title: LocalizedStringResource = "打开简账继续编辑"
    static var description = IntentDescription("打开简账以继续修改刚才保存的记录。")
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        return .result()
    }
}
