import Foundation
import CoreTransferable
import UniformTypeIdentifiers
#if canImport(UIKit)
import SwiftUI
import UIKit
#endif

/// 导出用的纯值快照（避免把 @Model 对象带进 Sendable 闭包）
struct RecordSnapshot: Sendable {
    let date: Date
    let kind: String
    let category: String
    let amount: Double
    let account: String
    let toAccount: String
    let fee: Double
    let merchant: String
    let note: String
    let source: String

    init(_ r: LedgerRecord) {
        date = r.date
        kind = r.kind.title
        category = r.categoryName
        amount = r.amount
        account = r.accountName
        toAccount = r.toAccount?.name ?? ""
        fee = r.fee
        merchant = r.merchant
        note = r.note
        source = r.source
    }
}

enum CSVBuilder {
    static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    static func build(_ rows: [RecordSnapshot]) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = ["日期,类型,分类,金额,账户,转入账户,手续费,商户,备注,来源"]
        for r in rows {
            let source: String
            switch r.source {
            case "ocr": source = "识图"
            case "shortcut": source = "快捷指令"
            default: source = "手动"
            }
            lines.append([
                f.string(from: r.date), r.kind, r.category, String(format: "%.2f", r.amount),
                r.account, r.toAccount, r.fee > 0 ? String(format: "%.2f", r.fee) : "", r.merchant, r.note, source,
            ].map(escape).joined(separator: ","))
        }
        // 加 UTF-8 BOM，Excel 打开中文不乱码
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(lines.joined(separator: "\r\n").data(using: .utf8) ?? Data())
        return data
    }
}

/// 供 ShareLink 使用的 CSV 文件
struct CSVExportFile: Transferable, Sendable {
    let rows: [RecordSnapshot]
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.fileName)
            try? FileManager.default.removeItem(at: url)
            try CSVBuilder.build(file.rows).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// 分享用的临时文件
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

#if canImport(UIKit)
/// 系统分享面板
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
