import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 账单导入的统一入口：设置里的文件选择器、「用其他应用打开 / 共享到简账」都走这里。
///
/// 2.0 (11) 修复「选择 Excel 没反应」：
/// - 预览页不再在文件选择器的回调里同步弹出（选择器还在收起时请求的 sheet 会被系统丢弃，表现为「没反应」），
///   而是在后台读取 + 解析完成、选择器完全收起后，由挂在 TabView 层的独立宿主弹出；
/// - 读取使用安全作用域 + NSFileCoordinator（iCloud 里尚未下载的文件会先下载），先把内容复制到内存再解析；
/// - 任何失败都弹出提示，不再静默；运行日志只记录类型 / 大小 / 笔数，不记录金额和商户。
@MainActor
final class BillImportCenter: ObservableObject {
    static let shared = BillImportCenter()

    @Published var session: ImportSession?
    @Published var message: String?
    @Published var isLoading = false
    /// 预览页真正出现在屏幕上（由预览内容的 onAppear 置位），用于检测「sheet 被系统丢弃」
    var previewAppeared = false

    /// 从其他 App 收到、但当前上锁 / 处于防窥模式而暂未处理的文件（仅内存，10 分钟有效）
    /// fromPicker：设置页里主动选择的文件，按当前账本导入（与 2.0 (11) 之前一致，防窥模式下导入防窥账本）
    private var pending: (data: Data, fileName: String, receivedAt: Date, fromPicker: Bool)?
    private static let pendingTTL: TimeInterval = 600

    /// 文件选择器允许的类型：显式列出 XLSX / XLS / CSV / ZIP，再兜底 .data，保证任何账单文件都能被选中
    nonisolated static let pickerTypes: [UTType] = {
        var list: [UTType] = []
        for id in ["org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls", "public.comma-separated-values-text"] {
            if let t = UTType(id) { list.append(t) }
        }
        for ext in ["xlsx", "xls", "csv"] {
            if let t = UTType(filenameExtension: ext), !list.contains(t) { list.append(t) }
        }
        list += [.commaSeparatedText, .tabSeparatedText, .plainText, .text, .spreadsheet, .zip, .data]
        var seen = Set<String>()
        return list.filter { seen.insert($0.identifier).inserted }
    }()

    // MARK: - 入口

    /// 设置页「导入账单」：用 UIKit 选择器选文件，选中后走与「共享 / 用其他应用打开」完全相同的路径
    func openPicker() {
        RunLog.shared.log(.info, "import", "设置页点击导入，打开 UIKit 文件选择器", memory: false)
        let ok = DocumentPicker.present(types: Self.pickerTypes, tag: "import", onPick: { [weak self] url in
            RunLog.shared.log(.info, "import", "选择器文件转入共享导入路径（.\(Self.ext(url))）", memory: false)
            self?.receive(url: url, isLocked: false, fromPicker: true)
        }, onCancel: {})
        if !ok { present(message: "无法打开文件选择器，请返回上一页后重试。") }
    }

    /// 其他 App「用其他应用打开 / 共享」过来的文件（onOpenURL）
    func receive(url: URL, isLocked: Bool, fromPicker: Bool = false) {
        RunLog.shared.log(.info, "import", "\(fromPicker ? "选择器文件" : "收到外部文件")（.\(Self.ext(url))）", memory: false)
        if fromPicker { isLoading = true }
        Task {
            do {
                let data = try await Self.readCoordinated(url)
                Self.cleanupInboxCopy(url)
                pending = (data, url.lastPathComponent, Date(), fromPicker)
                consumePendingIfPossible(isLocked: isLocked)
            } catch {
                Self.cleanupInboxCopy(url)
                isLoading = false
                RunLog.shared.log(.error, "import", "外部文件读取失败：\(error.localizedDescription)", memory: false)
                // 上锁 / 防窥时不提示，避免在锁屏或防窥账本里暴露真实导入行为
                if fromPicker || (!isLocked && !SessionManager.shared.isDecoy) {
                    present(message: "无法读取这个文件：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 解锁到真实模式后处理排队的外部文件；防窥模式下一直等到真实解锁
    func consumePendingIfPossible(isLocked: Bool) {
        guard let p = pending else { return }
        if Date().timeIntervalSince(p.receivedAt) > Self.pendingTTL {
            pending = nil
            isLoading = false
            RunLog.shared.log(.info, "import", "排队的外部文件已过期，丢弃", memory: false)
            return
        }
        guard !isLocked, p.fromPicker || !SessionManager.shared.isDecoy, !ScreenshotDemo.isActive else {
            isLoading = false
            RunLog.shared.log(.info, "import", "外部文件排队等待真实解锁", memory: false)
            return
        }
        pending = nil
        parse(data: p.data, fileName: p.fileName, origin: p.fromPicker ? "picker" : "open-in")
    }

    // MARK: - 读取 / 解析

    private func parse(data: Data, fileName: String, origin: String) {
        isLoading = true
        let kind = BillFileKind.detect(data)
        RunLog.shared.log(.info, "import", "文件类型 \(kind.rawValue)，大小 \(data.count) 字节（\(origin)）", memory: false)
        Task {
            let outcome: Result<BillParseResult, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let result = try BillParser.parse(data: data, fileName: fileName)
                    guard !result.entries.isEmpty else { throw BillParseError.empty }
                    return .success(result)
                } catch {
                    return .failure(error)
                }
            }.value
            isLoading = false
            switch outcome {
            case .success(let result):
                RunLog.shared.log(.info, "import", "解析成功：\(result.source.title)，\(result.entries.count) 笔，无法识别 \(result.unreadableRows) 行", memory: false)
                // 等文件选择器 / 共享面板完全收起后再弹预览，避免与正在消失的 presentation 冲突
                try? await Task.sleep(nanoseconds: 450_000_000)
                await showPreview(ImportSession(result: result, fileName: fileName))
            case .failure(let error):
                let text: String
                if let e = error as? BillParseError {
                    text = e.errorDescription ?? "无法识别这个账单文件。"
                } else {
                    text = ImportLoadError.xlsx(error.localizedDescription).errorDescription ?? "无法读取这个文件。"
                }
                RunLog.shared.log(.warn, "import", "解析失败：\(String(describing: error))", memory: false)
                present(message: text)
            }
        }
    }

    /// 弹出预览并确认它真的出现了：若被正在消失的 presentation 吞掉，重试一次；仍失败则弹提示，保证不会「没反应」
    private func showPreview(_ s: ImportSession) async {
        for attempt in 1...2 {
            previewAppeared = false
            session = s
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if previewAppeared { return }
            RunLog.shared.log(.warn, "import", "预览未出现（第 \(attempt) 次），重试", memory: false)
            session = nil
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        RunLog.shared.log(.error, "import", "预览两次都未能弹出", memory: false)
        message = "账单已读取（\(s.result.entries.count) 笔），但导入预览没能打开。请返回设置页后再试一次。"
    }

    /// 选择器被取消（用户点了取消，或系统收起了选择器）
    func handlePickerCancelled() {
        RunLog.shared.log(.info, "import", "选择器取消", memory: false)
    }

    /// 弹出提示；稍等选择器收起，避免提示框被丢弃
    func present(message text: String) {
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            message = text
        }
    }

    /// 读取文件内容：安全作用域 + 协调读取（会触发 iCloud 下载），在后台线程完成
    nonisolated static func readCoordinated(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var coordError: NSError?
            var readError: Error?
            var result: Data?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { readURL in
                do {
                    // 先复制到临时目录再读，避免直接读取 iCloud / 第三方 File Provider 的原文件
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("import-\(UUID().uuidString)")
                        .appendingPathExtension(readURL.pathExtension)
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    do {
                        try FileManager.default.copyItem(at: readURL, to: tmp)
                        result = try Data(contentsOf: tmp)
                    } catch {
                        result = try Data(contentsOf: readURL)
                    }
                } catch {
                    readError = error
                }
            }
            if let coordError { throw coordError }
            if let readError { throw readError }
            guard let data = result else { throw CocoaError(.fileReadUnknown) }
            guard !data.isEmpty else { throw BillParseError.empty }
            return data
        }.value
    }

    /// 「拷贝到简账」/ 选择器 asCopy 时系统放在 Documents/Inbox 或 tmp/*-Inbox 的副本，读完即删
    nonisolated static func cleanupInboxCopy(_ url: URL) {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(home), path.contains("/Inbox/") || path.contains("-Inbox/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func ext(_ url: URL) -> String {
        let e = url.pathExtension.lowercased()
        return e.isEmpty ? "无扩展名" : e
    }
}

/// 挂在 TabView 层的导入宿主：文件选择器、预览、提示各挂在独立的空视图上，
/// 不与设置页里的密码 / 防窥等 sheet、alert 共用同一个视图，避免 presentation 互相冲突。
struct BillImportHost: View {
    @ObservedObject private var center = BillImportCenter.shared

    var body: some View {
        ZStack {
            Color.clear
                .sheet(item: $center.session) { session in
                    ImportPreviewView(session: session) { count in
                        if count > 0 { center.present(message: "已导入 \(count) 笔。可在「导入记录」中整批撤销。") }
                    }
                    .onAppear {
                        center.previewAppeared = true
                        RunLog.shared.log(.info, "import", "预览已显示", memory: false)
                    }
                }
            Color.clear
                .alert("账单导入", isPresented: Binding(get: { center.message != nil }, set: { if !$0 { center.message = nil } })) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(center.message ?? "")
                }
            if center.isLoading {
                ProgressView("正在读取账单…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .allowsHitTesting(center.isLoading)
    }
}
