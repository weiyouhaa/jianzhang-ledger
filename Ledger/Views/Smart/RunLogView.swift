import SwiftUI
import UIKit

/// 设置 › 智能记账 › 运行日志：步骤、耗时、内存、前后台、崩溃记录。只在真实模式显示。
/// 不含截图文字、金额、商户、密码；导出后由用户自行决定发给谁。
struct RunLogView: View {
    struct Entry: Identifiable {
        let id: Int
        let time: String
        let level: String
        let step: String
        let message: String
        let resources: String
    }

    @State private var entries: [Entry] = []
    @State private var exportURL: URL?
    @State private var copied = false
    @State private var confirmClear = false

    /// 列表只显示最近 500 条（导出包含全部）
    static let displayLimit = 500

    var body: some View {
        List {
            Section {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("导出日志", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("runlog-export")
                }
                Button {
                    UIPasteboard.general.string = Self.exportText()
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制全部", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("runlog-copy")
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .accessibilityIdentifier("runlog-clear")
            } footer: {
                Text("记录识图记账每一步的耗时、内存、前后台状态和崩溃信息，便于排查「简账意外退出」。不含截图文字、金额、商户和密码，只保存在本机（约 2 MB 上限）。导出的文件附带 App 版本、系统版本和机型。")
            }

            Section {
                if entries.isEmpty {
                    Text("暂无日志").foregroundStyle(.secondary)
                }
                ForEach(entries) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(e.level)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(color(e.level))
                            Text(e.step).font(.caption.monospaced().weight(.semibold))
                            Spacer()
                            Text(e.time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if !e.message.isEmpty {
                            Text(e.message).font(.caption)
                        }
                        if !e.resources.isEmpty {
                            Text(e.resources).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 1)
                }
            } header: {
                Text("最近 \(entries.count) 条（新的在上）")
            }
        }
        .accessibilityIdentifier("runlog-list")
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .refreshable { reload() }
        .confirmationDialog("清空运行日志？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                RunLog.shared.clear()
                reload()
            }
        }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "ERROR": return .red
        case "WARN": return .orange
        default: return .secondary
        }
    }

    private func reload() {
        copied = false
        entries = Self.parse(RunLog.shared.readAll(), limit: Self.displayLimit)
        exportURL = Self.writeExportFile()
    }

    /// 「2026-10-20 15:25:01.123 [INFO] [step] 说明 | mem=…」→ Entry；新的在前
    static func parse(_ text: String, limit: Int) -> [Entry] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit)
        var out: [Entry] = []
        out.reserveCapacity(lines.count)
        for (i, raw) in lines.enumerated().reversed() {
            let line = String(raw)
            var rest = Substring(line)
            let time = rest.count >= 23 ? String(rest.prefix(23).dropFirst(5)) : ""   // MM-dd HH:mm:ss.SSS
            rest = rest.dropFirst(min(24, rest.count))
            func bracket() -> String {
                guard rest.hasPrefix("["), let end = rest.firstIndex(of: "]") else { return "" }
                let v = String(rest[rest.index(after: rest.startIndex)..<end])
                rest = rest[rest.index(after: end)...].drop(while: { $0 == " " })
                return v
            }
            let level = bracket()
            let step = bracket()
            var message = String(rest)
            var resources = ""
            if let r = message.range(of: " | mem=") {
                resources = String(message[message.index(r.lowerBound, offsetBy: 3)...])
                message = String(message[..<r.lowerBound])
            }
            if level.isEmpty { message = line }
            out.append(Entry(id: i, time: time, level: level.isEmpty ? "INFO" : level, step: step,
                             message: message, resources: resources))
        }
        return out
    }

    // MARK: 导出

    static func exportText() -> String {
        var s = "简账运行日志\n"
        s += "导出时间：\(DateText.monthDayTime.string(from: Date())) (\(TimeZone.current.identifier))\n"
        s += "App 版本：\(RunLog.appVersion)\n"
        s += "iOS 版本：\(UIDevice.current.systemVersion)\n"
        s += "机型：\(RunLog.deviceModel())\n"
        s += "识别引擎：\(OCREngineSetting.preferAppleIntelligence ? "自动（优先 Apple 智能）" : "仅规则")，"
        s += "快捷指令中使用 Apple 智能：\(OCREngineSetting.useInShortcuts ? "开" : "关")\n"
        s += "当前：" + RunLog.resourceLine(appState: "导出时", protectedData: UIApplication.shared.isProtectedDataAvailable ? "可用" : "不可用") + "\n"
        s += "\n== 识别诊断（最近 \(OCRDiagnostic.recent().count) 次）==\n"
        for d in OCRDiagnostic.recent() {
            var parts = ["\(DateText.monthDayTime.string(from: d.date))", d.context.title, d.engine,
                         "OCR \(d.ocrMs) ms"]
            if let m = d.modelMs { parts.append("模型 \(m) ms") }
            parts.append("\(d.lineCount) 行 → \(d.resultCount) 笔")
            if d.dropped > 0 { parts.append("剔除 \(d.dropped)") }
            if let r = d.fallbackReason, !r.isEmpty { parts.append(r) }
            parts.append("Apple 智能：\(d.aiStatus)")
            s += parts.joined(separator: " · ") + "\n"
        }
        s += "\n== 运行日志 ==\n"
        s += RunLog.shared.readAll()
        return s
    }

    /// 写到临时目录，ShareLink 以 .txt 文件分享
    static func writeExportFile() -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("简账运行日志-\(f.string(from: Date())).txt")
        // 清掉之前导出的临时文件
        if let old = try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil) {
            for u in old where u.lastPathComponent.hasPrefix("简账运行日志-") { try? FileManager.default.removeItem(at: u) }
        }
        do {
            try exportText().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
