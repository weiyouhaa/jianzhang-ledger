import Foundation
import MetricKit

/// MetricKit：系统在下次启动（iOS 15+）送达上次的崩溃 / 卡死 / CPU 异常诊断，以及每日的退出原因统计。
/// 摘要写入运行日志：异常类型、信号、终止原因、出问题线程的前几帧（二进制名 + 偏移；设备上没有符号）。
final class MetricsCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricsCollector()
    private static let seenKey = "diag.metrickit.seen"

    func start() {
        MXMetricManager.shared.add(self)
        // 已送达但尚未处理的诊断（例如上次运行在本订阅建立前就已投递）
        handle(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) { handle(payloads) }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            guard let obj = try? JSONSerialization.jsonObject(with: p.jsonRepresentation()) as? [String: Any],
                  let exits = obj["applicationExitMetrics"] as? [String: Any] else { continue }
            let summary = Self.nonZeroCounts(exits)
            if !summary.isEmpty {
                RunLog.shared.log(.info, "metrickit-exits", "退出统计（\(Self.range(p.timeStampBegin, p.timeStampEnd))）：" + summary, memory: false)
            }
        }
    }

    private func handle(_ payloads: [MXDiagnosticPayload]) {
        var seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
        for p in payloads {
            let key = "\(p.timeStampBegin.timeIntervalSince1970)-\(p.timeStampEnd.timeIntervalSince1970)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            for line in Self.summarize(p.jsonRepresentation()) {
                RunLog.shared.log(.error, "metrickit", line, memory: false)
            }
        }
        UserDefaults.standard.set(Array(seen.suffix(50)), forKey: Self.seenKey)
    }

    // MARK: 摘要（纯 JSON 解析，不依赖具体属性名，系统版本变化时更稳）

    static func summarize(_ json: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return [] }
        var lines: [String] = []
        let kinds: [(String, String)] = [("crashDiagnostics", "崩溃"), ("hangDiagnostics", "卡死"),
                                         ("cpuExceptionDiagnostics", "CPU 异常"), ("diskWriteExceptionDiagnostics", "磁盘写入异常"),
                                         ("appLaunchDiagnostics", "启动过慢")]
        for (key, title) in kinds {
            for d in (obj[key] as? [[String: Any]]) ?? [] {
                let meta = d["diagnosticMetaData"] as? [String: Any] ?? [:]
                var parts = [title]
                for k in ["appVersion", "appBuildVersion", "osVersion", "exceptionType", "exceptionCode", "signal",
                          "terminationReason", "hangDuration", "virtualMemoryRegionInfo", "lowPowerModeEnabled"] {
                    if let v = meta[k] { parts.append("\(k)=\(String(describing: v).prefix(160))") }
                }
                if let tree = d["callStackTree"] as? [String: Any] {
                    let frames = topFrames(tree, limit: 8)
                    if !frames.isEmpty { parts.append("frames: " + frames.joined(separator: " < ")) }
                }
                lines.append(parts.joined(separator: " · "))
            }
        }
        return lines
    }

    /// 被归因线程（threadAttributed）沿 subFrames 向下的前几帧
    static func topFrames(_ tree: [String: Any], limit: Int) -> [String] {
        let stacks = tree["callStacks"] as? [[String: Any]] ?? []
        let stack = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? stacks.first
        var frames: [String] = []
        var current = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        while let f = current, frames.count < limit {
            let name = f["binaryName"] as? String ?? "?"
            let off = f["offsetIntoBinaryTextSegment"].map { "\($0)" } ?? "?"
            frames.append("\(name)+\(off)")
            current = (f["subFrames"] as? [[String: Any]])?.first
        }
        return frames
    }

    static func nonZeroCounts(_ dict: [String: Any], prefix: String = "") -> String {
        var parts: [String] = []
        for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
            if let sub = v as? [String: Any] {
                let s = nonZeroCounts(sub, prefix: k + ".")
                if !s.isEmpty { parts.append(s) }
            } else if let n = v as? NSNumber, n.intValue != 0 {
                parts.append("\(prefix)\(k)=\(n)")
            }
        }
        return parts.joined(separator: ", ")
    }

    static func range(_ a: Date, _ b: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return "\(f.string(from: a))–\(f.string(from: b))"
    }
}
