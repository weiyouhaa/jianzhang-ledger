import SwiftUI

/// 设置 › 智能记账 › 识别诊断：最近 10 次识图的引擎、耗时与回退原因（只存本机，不含截图文字和金额；防窥模式下不记录）
struct OCRDiagnosticsView: View {
    @State private var items: [OCRDiagnostic] = []
    @State private var status: AppleIntelligenceStatus = .unavailable

    var body: some View {
        List {
            Section {
                LabeledContent("Apple 智能", value: status.title)
                LabeledContent("识别引擎", value: OCREngineSetting.preferAppleIntelligence ? "自动（优先 Apple 智能）" : "仅规则")
                LabeledContent("快捷指令中使用", value: OCREngineSetting.useInShortcuts ? "开启" : "关闭")
                LabeledContent("超时（最多）", value: "App 内 \(Int(OCREngineSetting.inAppTimeout)) 秒 · 快捷指令 \(Int(OCREngineSetting.shortcutTimeout)) 秒")
            } header: {
                Text("当前状态")
            }

            if items.isEmpty {
                Section {
                    Text("暂无记录。识图记账一次后，这里会显示使用的引擎、耗时和回退原因。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(items) { d in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(d.engine).font(.subheadline.weight(.semibold))
                                Text(d.context.title).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(DateText.monthDayTime.string(from: d.date)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(timing(d)).font(.caption.monospacedDigit())
                            if let r = d.fallbackReason, !r.isEmpty {
                                Text(r).font(.caption).foregroundStyle(.orange)
                            }
                            if let m = d.modelDetail, !m.isEmpty {
                                Text(m).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text("Apple 智能状态：\(d.aiStatus)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("最近 \(items.count) 次")
                } footer: {
                    Text("只保存在本机，不含截图文字和金额，不会上传或备份。")
                }
                Section {
                    Button("清除诊断记录", role: .destructive) {
                        OCRDiagnostic.clear()
                        items = []
                    }
                }
            }
        }
        .navigationTitle("识别诊断")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            status = AppleIntelligenceStatus.current
            items = OCRDiagnostic.recent()
        }
    }

    private func timing(_ d: OCRDiagnostic) -> String {
        var parts = ["OCR \(d.ocrMs) ms"]
        if let m = d.modelMs { parts.append("模型 \(m) ms") }
        parts.append("\(d.lineCount) 行 → \(d.resultCount) 笔")
        if d.dropped > 0 { parts.append("剔除 \(d.dropped)") }
        return parts.joined(separator: " · ")
    }
}
