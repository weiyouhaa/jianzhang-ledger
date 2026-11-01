import Foundation

// 3.3 (24) 识图查重：查重窗口 + 「可能重复」提示文字（只依赖 Foundation / DuplicateMatcher / TimeSource，
// Linux 上可测试：Tools/DupFlagCheck）

/// 识图得到的一笔与账本 / 本批里哪一笔相似
struct DuplicateHit: Equatable {
    /// 账本里的记录：时间、金额、标题（商户 / 备注 / 分类）
    var date: Date
    var amount: Double
    var title: String
    /// 同一批截图里的第 N 笔（1 起）；nil = 账本里已有的记录
    var batchIndex: Int? = nil
}

enum DuplicateHint {
    /// 查重的时间窗口。
    /// 2.0 (19) 起找不到交易时间时以截图时间 / 状态栏 / 现在为账单时间，旧代码只对「识别到时间」的查重，
    /// 于是这些笔完全不查重（3.3 修复）。截图时间通常比交易晚几分钟到几十分钟，所以用更宽的窗口，
    /// 但仍要求金额相同且商户相近 / 账户相同（DuplicateMatcher 的规则）。
    static func window(for source: TimeSource) -> TimeInterval {
        switch source {
        case .recognized, .manual: return DuplicateMatcher.window
        case .screenshot, .file, .statusBar, .now: return 30 * 60
        }
    }

    /// 金额相同 + （商户相近 / 账户相同），时间差在 window 内；返回第一笔匹配的下标
    static func firstMatch(_ e: DuplicateMatcher.Entry, among list: [DuplicateMatcher.Entry],
                           window: TimeInterval = DuplicateMatcher.window) -> Int? {
        if let i = list.firstIndex(where: { DuplicateMatcher.matches(e, $0) }) { return i }
        guard window > DuplicateMatcher.window else { return nil }
        return list.firstIndex { b in
            guard abs(e.amount - b.amount) < 0.005, abs(e.date.timeIntervalSince(b.date)) <= window else { return false }
            // 宽窗口：必须有正面证据（商户相近或同一账户），且没有冲突（商户不同 / 账户不同）
            let ma = DuplicateMatcher.normalizeMerchant(e.merchant), mb = DuplicateMatcher.normalizeMerchant(b.merchant)
            let merchantMatch = !ma.isEmpty && !mb.isEmpty && DuplicateMatcher.merchantsCompatible(ma, mb)
            let merchantConflict = !ma.isEmpty && !mb.isEmpty && !merchantMatch
            let accountMatch = e.account != nil && e.account == b.account
            let accountConflict = e.account != nil && b.account != nil && e.account != b.account
            return !merchantConflict && !accountConflict && (merchantMatch || accountMatch)
        }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    static let amountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = true
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    /// 「10月31日 14:03 ¥39.80 · 标题」
    static func summary(_ hit: DuplicateHit, symbol: String = "¥", timeZone: TimeZone = .current) -> String {
        let f = dateFormatter
        f.timeZone = timeZone
        let amount = symbol + (amountFormatter.string(from: NSNumber(value: abs(hit.amount))) ?? String(format: "%.2f", abs(hit.amount)))
        var s = "\(f.string(from: hit.date)) \(amount)"
        let title = hit.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { s += " · " + title }
        return s
    }

    /// 片段 / 编辑页顶部卡片里的红色提示
    /// - skip：默认跳过；saveAnyway：已选择仍保存；nil：编辑页（保存时自己决定）
    static func banner(_ hit: DuplicateHit?, skip: Bool?, symbol: String = "¥", timeZone: TimeZone = .current) -> String {
        var s: String
        if let hit, let n = hit.batchIndex {
            s = "⚠︎ 可能重复：与本批第 \(n) 笔是同一笔"
        } else if let hit {
            s = "⚠︎ 可能重复：与 \(summary(hit, symbol: symbol, timeZone: timeZone)) 的记录相似"
        } else {
            s = "⚠︎ 可能重复：账本里已有相似的记录"
        }
        switch skip {
        case true?: s += "（默认跳过）"
        case false?: s += "（仍保存）"
        case nil: break
        }
        return s
    }
}
