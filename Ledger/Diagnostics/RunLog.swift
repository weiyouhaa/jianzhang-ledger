import Foundation
#if canImport(os)
import os
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
// glibc 的 execinfo 没有导出到 Swift 模块（仅命令行测试在 Linux 上用到）
@_silgen_name("backtrace") func backtrace(_ buffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ size: Int32) -> Int32
@_silgen_name("backtrace_symbols_fd") func backtrace_symbols_fd(_ buffer: UnsafePointer<UnsafeMutableRawPointer?>, _ size: Int32, _ fd: Int32)
#endif

/// 运行日志（设置 › 智能记账 › 运行日志）：用于排查快捷指令崩溃等问题，用户可导出发送。
/// - 只记录步骤、耗时、内存、前后台、受保护数据等运行状态；绝不记录截图文字、金额、商户、密码。
/// - 每行直接 write(2) 到已打开的文件描述符（无用户态缓冲），进程崩溃也不会丢。
/// - 约 1 MB 轮转，保留当前与上一份。
/// - 崩溃：信号处理器向预先打开的 crash 文件写最小信息（仅 async-signal-safe 调用）；
///   被系统强杀（内存超限 / 看门狗，无法捕获）时，靠「未正常结束」标记在下次启动时补记。
final class RunLog: @unchecked Sendable {
    static let shared = RunLog()

    enum Level: String { case info = "INFO", warn = "WARN", error = "ERROR" }

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stateFD: Int32 = -1
    private var bootstrapped = false
    #if canImport(os)
    private let osLog = OSLog(subsystem: "com.fve.ledger", category: "run")
    #endif
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static let maxBytes: off_t = 1_000_000

    // 前后台 / 受保护数据：在主线程通知里更新的缓存（后台线程也能安全读取）
    private var appStateText = "?"
    private var protectedDataText = "?"

    /// 测试用：改写日志目录（须在 bootstrap 之前设置）
    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs", isDirectory: true)
    }
    static var currentURL: URL { directory.appendingPathComponent("run.log") }
    static var previousURL: URL { directory.appendingPathComponent("run.1.log") }
    static var crashURL: URL { directory.appendingPathComponent("crash.log") }
    static var stateURL: URL { directory.appendingPathComponent("state.txt") }

    private init() {}

    // MARK: 启动

    /// 幂等：App 启动（含为快捷指令在后台启动）时调用
    func bootstrap(reason: String) {
        lock.lock()
        if bootstrapped { lock.unlock(); return }
        bootstrapped = true
        let dir = Self.directory
        // 首次解锁后即可写（与快捷指令可能在锁屏期间运行一致），不依赖「受保护数据可用」
        #if os(iOS)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        #else
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #endif
        fd = Self.openAppend(Self.currentURL)
        stateFD = open(Self.stateURL.path, O_RDWR | O_CREAT, 0o644)
        lock.unlock()

        // 上次运行：信号崩溃记录 + 未正常结束标记
        importCrashFile()
        if let prev = try? String(contentsOf: Self.stateURL, encoding: .utf8),
           prev.hasPrefix("dirty|") {
            let parts = prev.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", omittingEmptySubsequences: false)
            let step = parts.count > 1 ? String(parts[1]) : "?"
            let mem = parts.count > 2 ? String(parts[2]) : "?"
            let when = parts.count > 3 ? String(parts[3]) : "?"
            log(.error, "recovery", "上次运行异常结束，最后步骤：\(step)，内存：\(mem) MB（\(when)）。若无崩溃信号记录，多为被系统强制结束（内存超限 / 运行超时）")
        }
        CrashGuard.install(crashPath: Self.crashURL.path)
        log(.info, "launch", "启动：\(reason) · \(Self.environmentLine())")
        log(.info, "image", Self.imageLine(), memory: false)
        markClean(step: "launch")
    }

    private static func openAppend(_ url: URL) -> Int32 {
        open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    }

    // MARK: 写日志

    /// step：步骤名（英文短词，便于搜索）；message：中文说明，不得包含截图文字 / 金额 / 商户
    func log(_ level: Level = .info, _ step: String, _ message: String = "", memory: Bool = true) {
        var line = "\(formatter.string(from: Date())) [\(level.rawValue)] [\(step)] \(message)"
        if memory { line += " | " + Self.resourceLine(appState: appState, protectedData: protectedData) }
        line += "\n"
        #if canImport(os)
        let type: OSLogType = level == .error ? .error : (level == .warn ? .default : .info)
        os_log("[%{public}@] %{public}@", log: osLog, type: type, step, message)
        #endif
        lock.lock()
        CrashGuard.setStep(step)
        if fd >= 0 {
            _ = line.withCString { write(fd, $0, strlen($0)) }
            rotateIfNeeded()
        }
        lock.unlock()
        updateStep(step)
    }

    private func rotateIfNeeded() {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > Self.maxBytes else { return }
        close(fd)
        try? FileManager.default.removeItem(at: Self.previousURL)
        try? FileManager.default.moveItem(at: Self.currentURL, to: Self.previousURL)
        fd = Self.openAppend(Self.currentURL)
    }

    // MARK: 未正常结束标记

    /// 一段需要正常结束的运行开始（快捷指令执行 / App 前台）
    func markDirty(step: String) { writeState("dirty", step: step) }
    /// 正常结束（快捷指令返回 / App 进入后台）
    func markClean(step: String) { writeState("clean", step: step) }

    /// 更新当前步骤（标记为 dirty 时下次启动可报告「最后步骤」）
    func updateStep(_ step: String) {
        lock.lock(); let dirty = currentDirty; lock.unlock()
        if dirty { writeState("dirty", step: step) }
    }

    private var currentDirty = false

    private func writeState(_ state: String, step: String) {
        let text = "\(state)|\(step)|\(String(format: "%.1f", Self.footprintMB()))|\(formatter.string(from: Date()))\n"
        lock.lock()
        defer { lock.unlock() }
        currentDirty = state == "dirty"
        guard stateFD >= 0 else { return }
        _ = ftruncate(stateFD, 0)
        _ = text.withCString { pwrite(stateFD, $0, strlen($0), 0) }
    }

    private func importCrashFile() {
        guard let text = try? String(contentsOf: Self.crashURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var first = true
        for line in text.split(separator: "\n").prefix(120) where !line.isEmpty {
            let isHeader = line.hasPrefix("signal ") || line.hasPrefix("exception ")
            log(.error, "crash", (isHeader || first ? "上次运行崩溃：" : "  ") + line, memory: false)
            first = false
        }
        try? "".write(to: Self.crashURL, atomically: false, encoding: .utf8)
    }

    /// 由主线程（UIKit 通知）更新；日志行从任意线程读取缓存值，不在后台线程碰 UIKit
    func setAppState(_ state: String, protectedData: String) {
        lock.lock()
        appStateText = state
        protectedDataText = protectedData
        lock.unlock()
    }

    private var appState: String { lock.lock(); defer { lock.unlock() }; return appStateText }
    private var protectedData: String { lock.lock(); defer { lock.unlock() }; return protectedDataText }

    // MARK: 资源

    static func footprintMB() -> Double {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
        #else
        return -1
        #endif
    }

    /// 距离系统内存上限还剩多少（iOS 专有；其它平台 -1）
    static func availableMB() -> Double {
        #if os(iOS)
        return Double(os_proc_available_memory()) / 1_048_576
        #else
        return -1
        #endif
    }

    static func thermalText() -> String {
        #if !canImport(Darwin)
        return "?"
        #else
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "正常"
        case .fair: return "偏热"
        case .serious: return "热"
        case .critical: return "过热"
        @unknown default: return "?"
        }
        #endif
    }

    static func resourceLine(appState: String, protectedData: String) -> String {
        String(format: "mem=%.1fMB avail=%.0fMB", footprintMB(), availableMB())
            + " \(appState) 受保护数据\(protectedData) 温度\(thermalText())"
    }

    static func deviceModel() -> String {
        var u = utsname()
        uname(&u)
        var machine = u.machine
        let size = MemoryLayout.size(ofValue: machine)
        return withUnsafeBytes(of: &machine) { raw in
            String(decoding: raw.prefix(size).prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "?"
        let b = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["JZBuildCommit"] as? String ?? "?"
        return "\(v) (\(b)) · \(commit)"
    }

    /// 主程序加载地址与 slide：配合构建产物里的 dSYM，可把崩溃回溯里的地址还原成函数名 / 行号
    static func imageLine() -> String {
        #if canImport(Darwin)
        let header = _dyld_get_image_header(0).map { UInt(bitPattern: $0) } ?? 0
        let slide = _dyld_get_image_vmaddr_slide(0)
        let name = _dyld_get_image_name(0).map { String(cString: $0) }.map { ($0 as NSString).lastPathComponent } ?? "?"
        return String(format: "主程序 %@ 加载地址 0x%lx slide 0x%lx", name, header, slide)
        #else
        return "主程序加载地址：不适用"
        #endif
    }

    static func environmentLine() -> String {
        "简账 \(appVersion) · iOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(deviceModel())"
    }

    // MARK: 读取 / 导出

    func readAll() -> String {
        lock.lock(); defer { lock.unlock() }
        let prev = (try? String(contentsOf: Self.previousURL, encoding: .utf8)) ?? ""
        let cur = (try? String(contentsOf: Self.currentURL, encoding: .utf8)) ?? ""
        return prev + cur
    }

    func clear() {
        lock.lock()
        if fd >= 0 { close(fd) }
        try? FileManager.default.removeItem(at: Self.previousURL)
        try? FileManager.default.removeItem(at: Self.currentURL)
        fd = Self.openAppend(Self.currentURL)
        lock.unlock()
        log(.info, "clear", "日志已清空")
    }
}

/// 崩溃捕获：信号处理器与未捕获异常。处理器里只用 write(2) 等 async-signal-safe 调用和预先分配的缓冲。
enum CrashGuard {
    nonisolated(unsafe) static var crashFD: Int32 = -1
    nonisolated(unsafe) static var stepBuffer: UnsafeMutablePointer<CChar> = {
        let p = UnsafeMutablePointer<CChar>.allocate(capacity: 96)
        p.initialize(repeating: 0, count: 96)
        return p
    }()
    nonisolated(unsafe) static var prefix: UnsafeMutablePointer<CChar> = strdup("signal ")!
    nonisolated(unsafe) static var middle: UnsafeMutablePointer<CChar> = strdup(" at step ")!
    nonisolated(unsafe) static var digits: UnsafeMutablePointer<CChar> = {
        let p = UnsafeMutablePointer<CChar>.allocate(capacity: 16)
        p.initialize(repeating: 0, count: 16)
        return p
    }()
    /// 预先分配的回溯缓冲：信号处理器里用 backtrace() 填充，再 backtrace_symbols_fd() 直接写到 fd（不分配内存）
    static let maxFrames: Int32 = 48
    nonisolated(unsafe) static var frames: UnsafeMutablePointer<UnsafeMutableRawPointer?> = {
        let p = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(CrashGuard.maxFrames))
        p.initialize(repeating: nil, count: Int(CrashGuard.maxFrames))
        return p
    }()
    nonisolated(unsafe) static var framesHeader: UnsafeMutablePointer<CChar> = strdup("crashing thread backtrace:\n")!
    nonisolated(unsafe) private static var installed = false
    static let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE]

    static func install(crashPath: String) {
        guard !installed else { return }
        installed = true
        crashFD = open(crashPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        _ = stepBuffer; _ = prefix; _ = middle; _ = digits; _ = frames; _ = framesHeader   // 提前初始化，处理器里不再分配
        // 先调用一次 backtrace，让它加载所需的库（首次调用可能分配内存，不能发生在信号处理器里）
        _ = backtrace(frames, maxFrames)
        for s in signals { signal(s, crashSignalHandler) }
        #if canImport(ObjectiveC)
        NSSetUncaughtExceptionHandler { exception in
            // 异常名与原因前 160 字（系统异常，不含用户数据）
            let reason = String((exception.reason ?? "").prefix(160))
            var line = "exception \(exception.name.rawValue): \(reason) at step \(String(cString: CrashGuard.stepBuffer))\n"
            for f in exception.callStackSymbols.prefix(40) { line += "  " + f + "\n" }
            if CrashGuard.crashFD >= 0 { _ = line.withCString { write(CrashGuard.crashFD, $0, strlen($0)) } }
        }
        #endif
    }

    /// 记录当前步骤到固定缓冲（最多 90 字节，截断）
    static func setStep(_ step: String) {
        let bytes = Array(step.utf8.prefix(90))
        bytes.withUnsafeBufferPointer { buf in
            for (i, b) in buf.enumerated() { stepBuffer[i] = CChar(bitPattern: b) }
        }
        stepBuffer[bytes.count] = 0
    }
}

private func crashSignalHandler(_ sig: Int32) {
    let fd = CrashGuard.crashFD
    if fd >= 0 {
        _ = write(fd, CrashGuard.prefix, strlen(CrashGuard.prefix))
        // 信号编号转十进制（无分配）
        var n = sig < 0 ? 0 : sig
        var len = 0
        var tmp: (CChar, CChar, CChar, CChar) = (48, 48, 48, 48)
        repeat {
            let d = CChar(48 + n % 10)
            switch len { case 0: tmp.0 = d; case 1: tmp.1 = d; case 2: tmp.2 = d; default: tmp.3 = d }
            n /= 10; len += 1
        } while n > 0 && len < 4
        var i = 0
        while i < len {
            let d: CChar
            switch len - 1 - i { case 0: d = tmp.0; case 1: d = tmp.1; case 2: d = tmp.2; default: d = tmp.3 }
            CrashGuard.digits[i] = d
            i += 1
        }
        CrashGuard.digits[len] = 10   // '\n' 放在步骤后面写
        _ = write(fd, CrashGuard.digits, len)
        _ = write(fd, CrashGuard.middle, strlen(CrashGuard.middle))
        _ = write(fd, CrashGuard.stepBuffer, strlen(CrashGuard.stepBuffer))
        var nl: CChar = 10
        _ = write(fd, &nl, 1)
        // 出错线程（同步信号在出错线程上处理）的回溯
        let count = backtrace(CrashGuard.frames, CrashGuard.maxFrames)
        if count > 0 {
            _ = write(fd, CrashGuard.framesHeader, strlen(CrashGuard.framesHeader))
            backtrace_symbols_fd(CrashGuard.frames, count, fd)
        }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}
