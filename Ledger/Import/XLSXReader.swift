import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// 读取 .xlsx 第一个工作表为二维字符串数组（不依赖第三方库）
enum XLSXReader {
    enum XLSXError: LocalizedError {
        case noWorksheet
        var errorDescription: String? { "无法读取 Excel 文件中的工作表，请在 Excel / Numbers 中另存为 CSV 后再导入。" }
    }

    static func isXLSX(_ data: Data) -> Bool {
        data.count > 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B
    }

    static func rows(from data: Data) throws -> [[String]] {
        let zip = try ZipArchive(data: data)
        var shared: [String] = []
        if let e = zip.entry(named: "xl/sharedStrings.xml") {
            shared = SharedStringsParser.parse(try zip.data(for: e))
        }
        let sheetEntry = zip.entry(named: "xl/worksheets/sheet1.xml")
            ?? zip.entries.filter { $0.name.hasPrefix("xl/worksheets/") && $0.name.hasSuffix(".xml") }
                .sorted { $0.name < $1.name }.first
        guard let sheetEntry else { throw XLSXError.noWorksheet }
        return SheetParser.parse(try zip.data(for: sheetEntry), shared: shared)
    }

    /// "AB12" → 27（从 0 开始的列号）
    static func columnIndex(_ ref: String) -> Int? {
        var n = 0
        var any = false
        for ch in ref.uppercased() {
            guard let a = ch.asciiValue, a >= 65, a <= 90 else { break }
            n = n * 26 + Int(a - 64)
            any = true
        }
        return any ? n - 1 : nil
    }

    private final class SharedStringsParser: NSObject, XMLParserDelegate {
        var strings: [String] = []
        var current = ""
        var inSI = false
        var inT = false
        var inPhonetic = false

        static func parse(_ data: Data) -> [String] {
            let d = SharedStringsParser()
            let p = XMLParser(data: data)
            p.delegate = d
            p.parse()
            return d.strings
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            switch localName(elementName) {
            case "si": inSI = true; current = ""
            case "t": inT = true
            case "rPh": inPhonetic = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch localName(elementName) {
            case "si": inSI = false; strings.append(current)
            case "t": inT = false
            case "rPh": inPhonetic = false
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inSI && inT && !inPhonetic { current += string }
        }
    }

    private final class SheetParser: NSObject, XMLParserDelegate {
        let shared: [String]
        var rows: [[String]] = []
        var row: [String] = []
        var cellRef = ""
        var cellType = ""
        var value = ""
        var inValue = false
        var inInlineT = false

        init(shared: [String]) { self.shared = shared }

        static func parse(_ data: Data, shared: [String]) -> [[String]] {
            let d = SheetParser(shared: shared)
            let p = XMLParser(data: data)
            p.delegate = d
            p.parse()
            return d.rows
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            switch localName(elementName) {
            case "row": row = []
            case "c":
                cellRef = attributeDict["r"] ?? ""
                cellType = attributeDict["t"] ?? ""
                value = ""
            case "v": inValue = true
            case "t": if cellType == "inlineStr" { inInlineT = true }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch localName(elementName) {
            case "v": inValue = false
            case "t": inInlineT = false
            case "c":
                var text = value
                if cellType == "s", let i = Int(value.trimmingCharacters(in: .whitespaces)), i >= 0, i < shared.count {
                    text = shared[i]
                } else if cellType == "b" {
                    text = value == "1" ? "TRUE" : "FALSE"
                }
                let col = XLSXReader.columnIndex(cellRef) ?? row.count
                if col < 5000 {
                    while row.count < col { row.append("") }
                    if row.count == col { row.append(text) } else { row[col] = text }
                }
            case "row": rows.append(row)
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inValue || inInlineT { value += string }
        }
    }

}

private func localName(_ name: String) -> String {
    if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
    return name
}
