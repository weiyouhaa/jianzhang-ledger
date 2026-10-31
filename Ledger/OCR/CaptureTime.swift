import Foundation

/// 账单时间的来源（2.0 (19)）。审核 / 编辑界面用 `hint` 轻提示，运行日志只记 `logTag`（不含金额、商户）。
enum TimeSource: String, Codable, Equatable, CaseIterable {
    /// 截图文字里的交易时间
    case recognized
    /// 截图拍摄时间：照片库的创建时间，或图片 EXIF / XMP 里的拍摄时间
    case screenshot
    /// 图片文件的创建时间（没有拍摄时间时）
    case file
    /// 截图顶部状态栏的时钟（只有时分，按当天）：弱线索
    case statusBar
    /// 都拿不到：按现在
    case now
    /// 用户手动改过
    case manual

    /// 审核 / 编辑界面上的小字提示；识别到的、手动改过的不提示
    var hint: String? {
        switch self {
        case .recognized, .manual: return nil
        case .screenshot: return "时间取自截图"
        case .file: return "时间取自图片文件"
        case .statusBar: return "时间取自截图状态栏"
        case .now: return "时间未识别（按现在）"
        }
    }

    var logTag: String {
        switch self {
        case .recognized: return "截图文字"
        case .screenshot: return "截图拍摄时间"
        case .file: return "文件时间"
        case .statusBar: return "状态栏时钟"
        case .now: return "现在"
        case .manual: return "手动"
        }
    }
}

/// 截图本身的时间（拍摄 / 文件），以及找不到交易时间时的兜底。纯 Foundation，见 Tools/ParserCheck。
struct CaptureTime: Equatable {
    var date: Date
    var source: TimeSource

    /// 早于 iPhone 出现（2007）或晚于现在 + 容差的拍摄时间不可信（相机时钟错乱 / 元数据损坏）
    static func isPlausibleCapture(_ d: Date, now: Date) -> Bool {
        d >= Date(timeIntervalSince1970: 1_167_609_600) && d <= now.addingTimeInterval(ReceiptParser.futureTolerance)
    }

    /// EXIF「2026:10:26 14:03:05」（本地时间），可带 OffsetTimeOriginal「+08:00」；
    /// XMP「2026-10-26T14:03:05+08:00」/「2026-10-26T14:03:05」/「2026-10-26T14:03:05.123Z」也认。
    static func parseMetadataDate(_ raw: String, offset: String? = nil, timeZone: TimeZone) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let re = try? NSRegularExpression(pattern:
            #"^(\d{4})[:\-](\d{2})[:\-](\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*(Z|[+\-]\d{2}:?\d{2})?$"#),
              let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
        let ns = s as NSString
        func g(_ i: Int) -> String {
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        var c = DateComponents()
        c.year = Int(g(1)); c.month = Int(g(2)); c.day = Int(g(3))
        c.hour = Int(g(4)); c.minute = Int(g(5)); c.second = Int(g(6)) ?? 0
        guard let y = c.year, y >= 1970, let mo = c.month, (1...12).contains(mo), let d = c.day, (1...31).contains(d),
              let h = c.hour, h < 24, let mi = c.minute, mi < 60 else { return nil }
        let zone = g(7).isEmpty ? (offset.flatMap(Self.zone(from:)) ?? timeZone) : (Self.zone(from: g(7)) ?? timeZone)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: c)
    }

    /// 「+08:00」「-0500」「Z」→ TimeZone
    static func zone(from s: String) -> TimeZone? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t == "Z" { return TimeZone(secondsFromGMT: 0) }
        let digits = t.filter(\.isNumber)
        guard let sign = t.first, sign == "+" || sign == "-", digits.count == 4,
              let h = Int(digits.prefix(2)), let m = Int(digits.suffix(2)), h <= 14, m < 60 else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (h * 3600 + m * 60))
    }

    /// 状态栏时钟 → 日期：参考「现在」那天的这个时分；晚于现在（+5 分钟）则是昨天
    static func statusBarDate(hour: Int, minute: Int, now: Date, calendar: Calendar) -> Date? {
        guard var d = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        if d > now.addingTimeInterval(300), let y = calendar.date(byAdding: .day, value: -1, to: d) { d = y }
        return d
    }

    /// 找不到交易时间时的兜底：截图拍摄时间 / 文件时间 → 状态栏时钟（弱线索）→ 现在
    static func fallback(capture: CaptureTime?, statusBar: (hour: Int, minute: Int)?, now: Date, calendar: Calendar) -> CaptureTime {
        if let capture, isPlausibleCapture(capture.date, now: now) { return capture }
        if let sb = statusBar, let d = statusBarDate(hour: sb.hour, minute: sb.minute, now: now, calendar: calendar) {
            return CaptureTime(date: d, source: .statusBar)
        }
        return CaptureTime(date: now, source: .now)
    }

    /// 最终的账单时间：识别到且合理（不晚于截图时间 + 容差、不早于 10 年前）用识别的，否则兜底
    static func resolve(recognized: Date?, reference: Date, fallback: CaptureTime) -> CaptureTime {
        if let d = recognized, ReceiptParser.isPlausible(d, reference: reference) {
            return CaptureTime(date: d, source: .recognized)
        }
        return fallback
    }

    /// 解析时用的参考时间：可信的截图时间，否则现在
    static func reference(capture: CaptureTime?, now: Date) -> Date {
        if let capture, isPlausibleCapture(capture.date, now: now) { return capture.date }
        return now
    }
}
