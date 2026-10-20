import Foundation

// 运行日志自检：写入、轮转（保留 2 份）、未正常结束检测、崩溃记录导入、清空。全部用合成内容。
// 子进程模式：装好崩溃捕获后自己触发信号，父进程检查 crash.log
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--crash-child" {
    RunLog.directoryOverride = URL(fileURLWithPath: CommandLine.arguments[2])
    RunLog.shared.bootstrap(reason: "子进程")
    RunLog.shared.markDirty(step: "intent-start")
    RunLog.shared.log(.info, "vision-start", "合成步骤")
    raise(SIGSEGV)
}

var failures = 0
func check(_ cond: Bool, _ name: String) {
    print((cond ? "PASS " : "FAIL ") + name)
    if !cond { failures += 1 }
}

let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("runlogcheck-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
// 模拟「上次运行」：未正常结束 + 一条信号崩溃记录
try "dirty|vision-start|312.5|2026-01-01 10:00:00.000\n".write(to: dir.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
try "signal 9 at step vision-start\n".write(to: dir.appendingPathComponent("crash.log"), atomically: true, encoding: .utf8)

RunLog.directoryOverride = dir
let log = RunLog.shared
log.bootstrap(reason: "自检")
log.bootstrap(reason: "重复调用")   // 幂等

var text = log.readAll()
check(text.contains("上次运行异常结束，最后步骤：vision-start，内存：312.5 MB"), "检测到上次异常结束")
check(text.contains("[crash] 上次运行崩溃：signal 9 at step vision-start"), "导入崩溃记录")
check(text.components(separatedBy: "[launch]").count == 2, "bootstrap 幂等")
let crashLeft = (try? String(contentsOf: dir.appendingPathComponent("crash.log"), encoding: .utf8)) ?? "x"
check(crashLeft.isEmpty, "崩溃记录导入后清空")
let state = (try? String(contentsOf: dir.appendingPathComponent("state.txt"), encoding: .utf8)) ?? ""
check(state.hasPrefix("clean|launch|"), "启动后标记为正常")

log.markDirty(step: "intent-start")
log.log(.info, "ocr-input", "图片 public.png 1290×2796")
let dirty = (try? String(contentsOf: dir.appendingPathComponent("state.txt"), encoding: .utf8)) ?? ""
check(dirty.hasPrefix("dirty|ocr-input|"), "dirty 状态跟随最后步骤")
log.markClean(step: "intent-end")
check(((try? String(contentsOf: dir.appendingPathComponent("state.txt"), encoding: .utf8)) ?? "").hasPrefix("clean|intent-end|"), "正常结束")

// 行格式
let line = log.readAll().split(separator: "\n").first(where: { $0.contains("[ocr-input]") }).map(String.init) ?? ""
check(line.range(of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} \[INFO\] \[ocr-input\] "#, options: .regularExpression) != nil, "行格式")
check(line.contains("| mem="), "行带内存信息")

// 轮转：写满 > 1 MB，只保留 run.log + run.1.log
let filler = String(repeating: "x", count: 900)
for i in 0..<2600 { log.log(.info, "fill", "\(i) \(filler)", memory: false) }
let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
let logs = files.filter { $0.hasSuffix(".log") && $0.hasPrefix("run") }.sorted()
check(logs == ["run.1.log", "run.log"], "轮转只保留 2 份：\(logs)")
let size1 = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("run.1.log").path)[.size] as? Int) ?? 0
check(size1 > 1_000_000 && size1 < 1_010_000, "轮转阈值约 1 MB（\(size1)）")
text = log.readAll()
check(text.contains("[fill] 2599 "), "最新内容可读")

log.clear()
text = log.readAll()
check(!text.contains("[fill]") && text.contains("日志已清空"), "清空")

// 新进程写入不会被缓冲：读到的行数与写入一致
for i in 0..<50 { log.log(.info, "count", "\(i)", memory: false) }
check(log.readAll().components(separatedBy: "[count]").count == 51, "同步写入不丢行")

// 信号崩溃：子进程写出「signal 11 at step vision-start」，下次启动导入并报告最后步骤
let childDir = dir.appendingPathComponent("child")
try? FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)
let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
child.arguments = ["--crash-child", childDir.path]
try child.run()
child.waitUntilExit()
check(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGSEGV, "子进程被信号终止")
let crash = (try? String(contentsOf: childDir.appendingPathComponent("crash.log"), encoding: .utf8)) ?? ""
check(crash == "signal 11 at step vision-start\n", "信号处理器写出最后步骤：\(crash.debugDescription)")
let childState = (try? String(contentsOf: childDir.appendingPathComponent("state.txt"), encoding: .utf8)) ?? ""
check(childState.hasPrefix("dirty|vision-start|"), "崩溃后状态仍为 dirty")

try? FileManager.default.removeItem(at: dir)
print(failures == 0 ? "RunLogCheck: all passed" : "RunLogCheck: \(failures) failed")
exit(failures == 0 ? 0 : 1)
