import Foundation

/// 账单来源
enum BillSource: String, Codable {
    case alipay
    case wechat

    var title: String { self == .alipay ? "支付宝" : "微信支付" }
    var icon: String { self == .alipay ? "a.circle.fill" : "message.fill" }
}

/// 导入结果中每一行的处理方式
enum BillKind: String {
    case expense, income, transfer, skip
}

/// 账单文件中的一笔交易（已规整、已初步分类）
struct BillEntry: Identifiable, Equatable {
    var id: Int { rowIndex }
    var rowIndex: Int
    var source: BillSource
    var date: Date
    var amount: Double
    var direction: String          // 支出 / 收入 / 不计收支 / "/"
    var typeText: String           // 交易分类（支付宝）/ 交易类型（微信）
    var counterparty: String
    var product: String
    var method: String             // 收/付款方式
    var status: String
    var orderID: String
    var merchantOrderID: String
    var remark: String

    var kind: BillKind = .expense
    /// 被跳过的行原本的收支类型（用户手动勾选时使用）
    var naturalKind: BillKind = .expense
    var skipReason: String?
    var isRefund = false
    var refundedAmount: Double = 0
    /// 平台分类映射到的默认分类名
    var platformCategory: String?
    /// 关键词猜测的分类名
    var keywordCategory: String?
    var accountHint: AccountHint?
    var toAccountHint: AccountHint?

    /// 建议分类：平台分类 > 关键词 > 宽泛的平台分类兜底
    var suggestedCategoryName: String? {
        if kind == .income || naturalKind == .income {
            return platformCategory ?? keywordCategory
        }
        return platformCategory ?? keywordCategory ?? (typeText.contains("充值缴费") ? "生活缴费" : nil)
    }

    /// 记账用的商户：交易对方，没有时用商品说明
    var merchant: String {
        let c = counterparty.trimmingCharacters(in: .whitespaces)
        if c.isEmpty || c == "/" { return product == "/" ? "" : product }
        return c
    }

    /// 备注：商品说明（与商户不同且有意义时）
    var memo: String {
        let p = product.trimmingCharacters(in: .whitespaces)
        if p.isEmpty || p == "/" || p == merchant { return "" }
        return p
    }
}

struct BillParseResult {
    var source: BillSource
    var entries: [BillEntry]
    /// 无法识别的数据行数
    var unreadableRows: Int
}

enum BillParseError: LocalizedError {
    case unreadableText
    case headerNotFound
    case empty
    /// 旧版二进制 Excel（.xls）或加密的 Excel：OLE 复合文档
    case legacyExcel
    /// 带解压密码的压缩包（微信 / 支付宝导出的账单压缩包）
    case encryptedArchive
    /// 压缩包里没有可识别的账单文件
    case archiveWithoutBill

    var errorDescription: String? {
        switch self {
        case .legacyExcel: return "这是旧版 Excel（.xls）或设置了打开密码的 Excel，简账暂不支持直接读取。请用 Numbers / Excel / WPS 打开后「导出为 CSV」或另存为 .xlsx 再导入。"
        case .encryptedArchive: return "这是带解压密码的账单压缩包。请先在「文件」App 中用账单邮件 / 短信里的解压密码解压，再选择里面的 CSV 或 XLSX 文件导入。"
        case .archiveWithoutBill: return "压缩包里没有找到 CSV / XLSX 账单文件。请解压后选择里面的账单文件导入。"
        case .unreadableText: return "无法识别文件编码。请确认是支付宝或微信导出的账单文件（CSV / XLSX）。"
        case .headerNotFound: return "没有找到账单表头（交易时间、收/支、金额…）。请确认文件是「支付宝交易明细」或「微信支付账单」。"
        case .empty: return "账单中没有可导入的交易。"
        }
    }
}

enum BillParser {
    /// 账单时间为北京时间
    static var timeZone = TimeZone(identifier: "Asia/Shanghai")!

    // MARK: - 入口

    static func parse(data: Data, fileName: String = "") throws -> BillParseResult {
        let rows: [[String]]
        switch BillFileKind.detect(data) {
        case .legacyExcel:
            throw BillParseError.legacyExcel
        case .xlsx:
            rows = try XLSXReader.rows(from: data)
        case .zip:
            // 普通 ZIP：未加密且里面恰好有账单文件时直接读取（例如解压密码为空的导出）
            let zip = try ZipArchive(data: data)
            let candidates = zip.entries.filter { e in
                let n = e.name.lowercased()
                return !n.hasPrefix("__macosx/") && (n.hasSuffix(".csv") || n.hasSuffix(".xlsx") || n.hasSuffix(".xls"))
            }
            guard let entry = candidates.first else { throw BillParseError.archiveWithoutBill }
            if candidates.contains(where: { $0.isEncrypted }) { throw BillParseError.encryptedArchive }
            let inner = try zip.data(for: entry)
            let innerName = (entry.name as NSString).lastPathComponent
            guard BillFileKind.detect(inner) != .zip else { throw BillParseError.archiveWithoutBill }
            return try parse(data: inner, fileName: innerName.isEmpty ? fileName : innerName)
        case .text:
            guard let text = decodeText(data) else { throw BillParseError.unreadableText }
            rows = parseCSV(text)
        }
        return try parse(rows: rows, fileName: fileName)
    }

    static func parse(rows rawRows: [[String]], fileName: String = "") throws -> BillParseResult {
        let rows = rawRows.map { $0.map(clean) }
        guard let headerIndex = rows.firstIndex(where: isHeader) else { throw BillParseError.headerNotFound }
        let header = rows[headerIndex]
        let preamble = rows[..<headerIndex].map { $0.joined(separator: " ") }.joined(separator: " ")

        let isWechatHeader = header.contains("交易类型") || header.contains("当前状态") || header.contains(where: { $0.hasPrefix("金额(") || $0.hasPrefix("金额（") })
        let isAlipayHeader = header.contains("交易分类") || header.contains("收/付款方式") || header.contains("交易订单号")
        let source: BillSource
        if preamble.contains("微信") || fileName.contains("微信") || (isWechatHeader && !isAlipayHeader) {
            source = .wechat
        } else {
            source = .alipay
        }

        func col(_ names: [String]) -> Int? {
            for n in names { if let i = header.firstIndex(of: n) { return i } }
            for n in names { if let i = header.firstIndex(where: { $0.hasPrefix(n) }) { return i } }
            return nil
        }
        guard let cTime = col(["交易时间", "交易创建时间", "付款时间"]),
              let cDir = col(["收/支"]),
              let cAmount = col(["金额(元)", "金额（元）", "金额"]) else { throw BillParseError.headerNotFound }
        let cType = col(["交易分类", "交易类型"])
        let cParty = col(["交易对方"])
        let cProduct = col(["商品说明", "商品名称", "商品"])
        let cMethod = col(["收/付款方式", "支付方式"])
        let cStatus = col(["交易状态", "当前状态"])
        let cOrder = col(["交易订单号", "交易单号", "交易号"])
        let cMerchantOrder = col(["商家订单号", "商户单号", "商户订单号"])
        let cRemark = col(["备注"])

        var entries: [BillEntry] = []
        var unreadable = 0
        for (offset, row) in rows[(headerIndex + 1)...].enumerated() {
            func v(_ c: Int?) -> String {
                guard let c, c < row.count else { return "" }
                return row[c]
            }
            let first = row.first ?? ""
            if row.allSatisfy({ $0.isEmpty }) || first.hasPrefix("---") || first.hasPrefix("===") { continue }
            guard let date = parseDate(v(cTime)), let amount = parseAmount(v(cAmount)) else {
                unreadable += 1
                continue
            }
            var e = BillEntry(rowIndex: offset, source: source, date: date, amount: amount, direction: v(cDir),
                              typeText: v(cType), counterparty: v(cParty), product: v(cProduct), method: v(cMethod),
                              status: v(cStatus), orderID: v(cOrder), merchantOrderID: v(cMerchantOrder), remark: v(cRemark))
            if e.remark == "/" { e.remark = "" }
            entries.append(e)
        }
        guard !entries.isEmpty else { throw BillParseError.empty }
        return BillParseResult(source: source, entries: classify(entries), unreadableRows: unreadable)
    }

    // MARK: - 分类（收支 / 退款 / 关闭 / 不计收支）

    static let closedKeywords = ["交易关闭", "已关闭", "支付失败", "交易失败", "失败", "已撤销", "撤销", "已取消", "取消", "未支付", "等待付款", "待付款"]

    static func classify(_ input: [BillEntry]) -> [BillEntry] {
        var entries = input
        // 第一遍：已全额 / 部分退款的原支付，记录被抵扣的退款（交易对方 + 金额）
        var nettedRefunds: [(party: String, amount: Double, order: String)] = []
        for i in entries.indices {
            var e = entries[i]
            let st = e.status
            if e.direction == "支出" {
                if st.contains("已全额退款") || (e.source == .alipay && st.contains("退款成功")) {
                    nettedRefunds.append((e.counterparty, e.amount, e.orderID))
                } else if let r = partialRefund(st) {
                    e.refundedAmount = r
                    nettedRefunds.append((e.counterparty, r, e.orderID))
                }
            }
            entries[i] = e
        }

        for i in entries.indices {
            var e = entries[i]
            let st = e.status
            let dir = e.direction
            let refundRow = e.typeText.contains("退款") || e.product.hasPrefix("退款") || e.product.contains("-退款")
                || (dir != "支出" && (st.contains("退款") || e.counterparty.contains("退款")))
            e.accountHint = methodHint(e)
            e.keywordCategory = CategoryGuesser.guess(text: e.counterparty + " " + e.product, isIncome: dir == "收入" || refundRow)

            if closedKeywords.contains(where: { st.contains($0) }) {
                e.naturalKind = dir == "收入" ? .income : .expense
                e.kind = .skip
                e.skipReason = "交易关闭 / 失败"
            } else if dir == "支出" {
                e.naturalKind = .expense
                e.platformCategory = platformCategory(e, isIncome: false)
                if st.contains("已全额退款") || (e.source == .alipay && st.contains("退款成功")) {
                    e.kind = .skip
                    e.skipReason = "已全额退款"
                } else if e.refundedAmount > 0 {
                    let net = ((e.amount - e.refundedAmount) * 100).rounded() / 100
                    if net <= 0 {
                        e.kind = .skip
                        e.skipReason = "已全额退款"
                    } else {
                        e.amount = net
                        e.kind = .expense
                    }
                } else {
                    e.kind = .expense
                }
            } else if refundRow {
                e.isRefund = true
                e.naturalKind = .income
                e.platformCategory = "退款"
                if let idx = nettedRefunds.firstIndex(where: { r in
                    (abs(r.amount - e.amount) < 0.005 && (r.party == e.counterparty || e.product.contains(r.party)))
                        || (!r.order.isEmpty && !e.orderID.isEmpty && e.orderID.hasPrefix(r.order))
                }) {
                    nettedRefunds.remove(at: idx)
                    e.kind = .skip
                    e.skipReason = "退款已在原交易中抵扣"
                } else {
                    e.kind = .income
                }
            } else if dir == "收入" {
                e.naturalKind = .income
                e.kind = .income
                e.platformCategory = platformCategory(e, isIncome: true)
            } else {
                // 不计收支 / 中性交易：余额宝、零钱通转入转出、充值提现、信用卡还款……
                e.naturalKind = .transfer
                e.kind = .transfer
                let hints = transferHints(e)
                e.accountHint = hints.from
                e.toAccountHint = hints.to
                e.skipReason = "不计收支（转账 / 理财 / 还款）"
            }
            entries[i] = e
        }
        return entries
    }

    private static let partialRefundPattern = try! NSRegularExpression(pattern: #"已退款\s*[(（]\s*[¥￥]?\s*([\d,]+(?:\.\d{1,2})?)\s*[)）]"#)

    static func partialRefund(_ status: String) -> Double? {
        let ns = status as NSString
        guard let m = partialRefundPattern.firstMatch(in: status, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Double(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: ""))
    }

    /// 付款方式 → 账户线索
    static func methodHint(_ e: BillEntry) -> AccountHint? {
        let m = e.method.trimmingCharacters(in: .whitespaces)
        if !m.isEmpty, m != "/" {
            if var h = AccountHintParser.parse(text: m) {
                if h.type == nil { h.type = "debit" }
                return h
            }
            if m.contains("余额宝") || m.contains("账户余额") || m == "余额" { return AccountHint(type: "alipay") }
            if m.contains("零钱") { return AccountHint(type: "wechat") }
        }
        // 没有付款方式（收入多为入账到余额 / 零钱）
        return AccountHint(type: e.source == .alipay ? "alipay" : "wechat")
    }

    /// 不计收支：推测转出、转入账户
    static func transferHints(_ e: BillEntry) -> (from: AccountHint?, to: AccountHint?) {
        let text = e.counterparty + " " + e.product + " " + e.typeText
        let method = methodHint(e)
        var target: AccountHint?
        if text.contains("信用卡还款") || text.contains("还信用卡") {
            var h = AccountHintParser.parse(text: e.product + " " + e.counterparty) ?? AccountHint()
            h.type = "credit"
            target = h
        } else if text.contains("花呗") && text.contains("还款") {
            target = AccountHint(type: "consumerCredit")
        } else if text.contains("白条") && text.contains("还款") {
            target = AccountHint(type: "consumerCredit")
        } else if text.contains("余额宝") {
            target = AccountHint(type: "alipay")
        } else if text.contains("零钱通") || text.contains("零钱") {
            target = AccountHint(type: "wechat")
        } else if text.contains("提现") {
            target = AccountHintParser.parse(text: e.product + " " + e.method) ?? AccountHint(type: "debit")
            return (AccountHint(type: e.source == .alipay ? "alipay" : "wechat"), target)
        } else if text.contains("充值") {
            target = AccountHint(type: e.source == .alipay ? "alipay" : "wechat")
        }
        // 「转出」「提现」：钱从目标流向付款方式
        if text.contains("转出") || text.contains("赎回") {
            return (target, method)
        }
        return (method, target)
    }

    /// 支付宝「交易分类」/ 微信「交易类型」→ 默认分类名
    static func platformCategory(_ e: BillEntry, isIncome: Bool) -> String? {
        let t = e.typeText
        if isIncome {
            if t.contains("红包") { return "红包" }
            if t.contains("投资理财") || t.contains("理财") { return "理财" }
            if t.contains("退款") { return "退款" }
            if t.contains("工资") { return "工资" }
            return nil
        }
        let map: [(String, String)] = [
            ("餐饮美食", "餐饮"), ("交通出行", "交通"), ("爱车养车", "交通"), ("日用百货", "购物"), ("服饰装扮", "购物"),
            ("数码电器", "购物"), ("家居家装", "购物"), ("美容美发", "购物"), ("母婴亲子", "购物"), ("运动户外", "娱乐"),
            ("文化休闲", "娱乐"), ("教育培训", "教育"), ("医疗健康", "医疗"), ("住房物业", "居住"),
            ("酒店旅游", "旅行"), ("公益捐赠", "人情"), ("转账红包", "人情"), ("微信红包", "人情"), ("红包", "人情"),
        ]
        return map.first { t.contains($0.0) }?.1
    }

    // MARK: - 表头 / CSV / 编码

    static func isHeader(_ row: [String]) -> Bool {
        row.contains(where: { $0 == "交易时间" || $0 == "交易创建时间" })
            && row.contains("收/支")
            && row.contains(where: { $0.hasPrefix("金额") })
    }

    static func clean(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("\u{FEFF}") { v.removeFirst() }
        if v.hasPrefix("`") { v.removeFirst() }
        return v.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\t")))
    }

    /// UTF-8（含 BOM）/ UTF-16 / GB18030（支付宝 CSV 默认编码）
    static func decodeText(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(3))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if b.count >= 2, (b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF) {
            return String(data: data, encoding: .utf16)
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        // kCFStringEncodingGB_18030_2000 = 0x0632，GBK = 0x0631（NSStringEncoding 需加 0x80000000）
        for raw: UInt in [0x8000_0632, 0x8000_0631, 0x8000_0930] {
            if let s = String(data: data, encoding: String.Encoding(rawValue: raw)) { return s }
        }
        return nil
    }

    /// RFC 4180 风格的 CSV 解析（引号、转义引号、换行）
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text.unicodeScalars)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 }
                    else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r":
                    row.append(field); field = ""; rows.append(row); row = []
                    if i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                case "\n":
                    row.append(field); field = ""; rows.append(row); row = []
                default: field.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func parseAmount(_ s: String) -> Double? {
        let cleaned = s.replacingOccurrences(of: "¥", with: "").replacingOccurrences(of: "￥", with: "")
            .replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "元", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned), v.isFinite else { return nil }
        return (abs(v) * 100).rounded() / 100
    }

    private static let dateFormatters: [DateFormatter] = ["yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd HH:mm",
                                                          "yyyy/M/d H:mm:ss", "yyyy/M/d H:mm", "yyyy-M-d H:mm:ss",
                                                          "yyyy年M月d日 HH:mm:ss", "yyyy-MM-dd"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = BillParser.timeZone
        f.dateFormat = $0
        return f
    }

    static func parseDate(_ s: String) -> Date? {
        let v = s.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        for f in dateFormatters {
            if let d = f.date(from: v) { return d }
        }
        // Excel 日期序列号（1899-12-30 起的天数，按北京时间）
        if let serial = Double(v), serial > 20_000, serial < 80_000 {
            let seconds = (serial - 25_569) * 86_400   // 25569 = 1970-01-01
            return Date(timeIntervalSince1970: seconds - Double(timeZone.secondsFromGMT()))
        }
        return nil
    }
}

/// 按文件内容（魔数）判断账单文件类型，不依赖扩展名 / UTType
enum BillFileKind: String {
    case xlsx          // ZIP 且含 xl/ 工作簿
    case zip           // 其它 ZIP（账单压缩包）
    case legacyExcel   // OLE 复合文档：.xls / 加密的 .xlsx
    case text          // CSV / TXT

    static func detect(_ data: Data) -> BillFileKind {
        let b = [UInt8](data.prefix(8))
        if b.count >= 8, b == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] { return .legacyExcel }
        guard XLSXReader.isXLSX(data) else { return .text }
        if let zip = try? ZipArchive(data: data) {
            return zip.entries.contains(where: { $0.name.hasPrefix("xl/") || $0.name == "[Content_Types].xml" }) ? .xlsx : .zip
        }
        // 无法读取目录：仍按 XLSX 处理，交给 XLSXReader 报具体错误
        return .xlsx
    }
}
