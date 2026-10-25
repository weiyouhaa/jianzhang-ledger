import Foundation

// 一键去重 / 导入查重的匹配引擎（只依赖 Foundation 与 DuplicateMatcher，Linux 上可测试：Tools/DedupeCheck）

/// 一笔记录的去重视图（与 SwiftData 无关）
struct DedupeRecord: Equatable {
    var id: String
    var kind: String
    var amount: Double
    var date: Date
    var merchant: String = ""
    var note: String = ""
    var accountID: String? = nil
    var toAccountID: String? = nil
    var categoryName: String? = nil
    var externalID: String = ""
    /// manual / ocr / shortcut / recurring / alipay / wechat
    var source: String = "manual"
    var importBatchID: String = ""
    var recurringKey: String = ""
    var createdAt: Date = .distantPast
}

enum DedupeConfidence: Int, Comparable, CaseIterable {
    case possible = 1, likely, certain

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .certain: return "确定重复"
        case .likely: return "很可能重复"
        case .possible: return "可能重复"
        }
    }

    static func from(score: Int) -> DedupeConfidence? {
        if score >= DedupeEngine.certainScore { return .certain }
        if score >= DedupeEngine.likelyScore { return .likely }
        if score >= DedupeEngine.possibleScore { return .possible }
        return nil
    }
}

/// 时间窗口：两笔相隔多久以内才可能是同一笔
enum DedupeWindow: String, CaseIterable, Identifiable {
    case min3, min10, min30, sameDay
    var id: String { rawValue }
    var title: String {
        switch self {
        case .min3: return "3 分钟"
        case .min10: return "10 分钟"
        case .min30: return "30 分钟"
        case .sameDay: return "同一天"
        }
    }
    /// 同一天时为 nil（按日历日判断）
    var seconds: TimeInterval? {
        switch self {
        case .min3: return 180
        case .min10: return 600
        case .min30: return 1800
        case .sameDay: return nil
        }
    }
}

struct DedupeOptions {
    var window: DedupeWindow = .min30
    /// 用户标记「不是重复」的记录对（DedupeEngine.pairKey）
    var ignoredPairs: Set<String> = []
    var calendar: Calendar = .current
}

struct DedupePairScore: Equatable {
    var score: Int
    var confidence: DedupeConfidence
    var reasons: [String]
}

struct DedupeGroup: Identifiable, Equatable {
    /// 组内记录 ID 排序后拼接
    var id: String
    /// 按时间排序
    var members: [DedupeRecord]
    /// 组内任意两笔里最低的置信度（最保守）
    var confidence: DedupeConfidence
    var suggestedKeepID: String
    var reasons: [String]

    var pairKeys: [String] {
        var out: [String] = []
        for i in members.indices { for j in members.indices where j > i { out.append(DedupeEngine.pairKey(members[i].id, members[j].id)) } }
        return out
    }
}

/// 保留一笔时，从要删除的记录里补上保留记录缺的信息（只补空字段；值为提供信息的记录 ID）
struct DedupeMergePatch: Equatable {
    var merchantFrom: String?
    var noteFrom: String?
    var categoryFrom: String?
    var accountFrom: String?
    var isEmpty: Bool { merchantFrom == nil && noteFrom == nil && categoryFrom == nil && accountFrom == nil }
    var fieldCount: Int { [merchantFrom, noteFrom, categoryFrom, accountFrom].compactMap { $0 }.count }
}

/// 自动处理的一组：保留哪笔、删哪些、补哪些字段
struct DedupeAutoItem: Identifiable, Equatable {
    var group: DedupeGroup
    var keep: DedupeRecord
    var delete: [DedupeRecord]
    var patch: DedupeMergePatch
    var id: String { group.id }
}

/// 账单导入时一行与已有记录的匹配
struct DedupeBillMatch: Equatable {
    var existingID: String
    var score: Int
    var confidence: DedupeConfidence
}

enum DedupeEngine {
    static let certainScore = 90
    static let likelyScore = 65
    static let possibleScore = 40
    static let importSources: Set<String> = ["alipay", "wechat"]

    static func pairKey(_ a: String, _ b: String) -> String { a < b ? a + "|" + b : b + "|" + a }

    static func sourceTitle(_ s: String) -> String {
        switch s {
        case "manual": return "手动"
        case "ocr": return "识图"
        case "shortcut": return "快捷指令"
        case "recurring": return "周期账单"
        case "alipay": return "账单导入·支付宝"
        case "wechat": return "账单导入·微信"
        default: return s.isEmpty ? "手动" : s
        }
    }

    static func isImported(_ r: DedupeRecord) -> Bool {
        !r.externalID.isEmpty || !r.importBatchID.isEmpty || importSources.contains(r.source)
    }

    /// 商户（转账没有商户时不比较；商户为空时用备注）
    private static func merchantKey(_ r: DedupeRecord) -> String {
        let m = DuplicateMatcher.normalizeMerchant(r.merchant)
        return m.isEmpty ? DuplicateMatcher.normalizeMerchant(r.note) : m
    }

    private static func withinWindow(_ a: Date, _ b: Date, _ options: DedupeOptions) -> Bool {
        if let s = options.window.seconds { return abs(a.timeIntervalSince(b)) <= s }
        return options.calendar.isDate(a, inSameDayAs: b)
    }

    /// 两笔记录是否可能是同一笔；nil = 一定不是（类型 / 金额不同、不同订单号、同一导入批次、转账账户不同、超出时间窗口、用户标记过）
    static func score(_ a: DedupeRecord, _ b: DedupeRecord, options: DedupeOptions) -> DedupePairScore? {
        guard a.id != b.id, a.kind == b.kind else { return nil }
        guard !options.ignoredPairs.contains(pairKey(a.id, b.id)) else { return nil }
        if !a.externalID.isEmpty && a.externalID == b.externalID {
            return DedupePairScore(score: 200, confidence: .certain, reasons: ["订单号相同"])
        }
        guard abs(a.amount - b.amount) < 0.005 else { return nil }
        // 同一账单来源的不同订单号：账单里本来就是两笔
        if !a.externalID.isEmpty && !b.externalID.isEmpty && a.source == b.source { return nil }
        // 同一批导入的两行：账单里本来就是两笔
        if !a.importBatchID.isEmpty && a.importBatchID == b.importBatchID { return nil }
        if !a.recurringKey.isEmpty && !b.recurringKey.isEmpty && a.recurringKey != b.recurringKey { return nil }
        guard withinWindow(a.date, b.date, options) else { return nil }

        var score = 20
        var reasons = ["金额相同"]
        /// 「确定重复」除了分数够高，还必须有商户相近（转账：转出 / 转入账户都相同）——只凭金额、时间、账户不自动删
        var identity = false
        let dt = abs(a.date.timeIntervalSince(b.date))
        switch dt {
        case ...60: score += 40; reasons.append("时间相差 1 分钟内")
        case ...180: score += 30; reasons.append("时间相差 \(max(1, Int((dt / 60).rounded()))) 分钟")
        case ...600: score += 20; reasons.append("时间相差 \(Int((dt / 60).rounded())) 分钟")
        case ...1800: score += 10; reasons.append("时间相差 \(Int((dt / 60).rounded())) 分钟")
        default: reasons.append("同一天")
        }

        if a.kind == "transfer" {
            // 转出 / 转入账户已知的必须一致
            if let x = a.accountID, let y = b.accountID, x != y { return nil }
            if let x = a.toAccountID, let y = b.toAccountID, x != y { return nil }
            let both = a.accountID != nil && a.accountID == b.accountID && a.toAccountID != nil && a.toAccountID == b.toAccountID
            let one = (a.accountID != nil && a.accountID == b.accountID) || (a.toAccountID != nil && a.toAccountID == b.toAccountID)
            if both { score += 40; identity = true; reasons.append("转出 / 转入账户相同") } else if one { score += 20; reasons.append("账户相同") }
        } else {
            if let x = a.accountID, let y = b.accountID {
                if x == y { score += 25; reasons.append("账户相同") } else { score -= 30 }
            }
            let ma = merchantKey(a), mb = merchantKey(b)
            if !ma.isEmpty && !mb.isEmpty {
                if DuplicateMatcher.merchantsCompatible(ma, mb) { score += 25; identity = true; reasons.append("商户相近") } else { score -= 25 }
            }
            if let x = a.categoryName, let y = b.categoryName, x == y, !x.isEmpty { score += 5 }
        }
        guard var c = DedupeConfidence.from(score: score) else { return nil }
        if c == .certain && !identity { c = .likely }
        return DedupePairScore(score: score, confidence: c, reasons: reasons)
    }

    /// 找出可能重复的组。完全连接聚类：两组合并时，跨组的每一对都必须可能重复
    /// （例如账单里两笔同额消费 + 手动记的一笔：手动那笔只会和其中一笔成组）
    static func groups(_ records: [DedupeRecord], options: DedupeOptions = DedupeOptions()) -> [DedupeGroup] {
        let maxSpan = options.window.seconds ?? 86_400
        // 候选：同类型、同金额（分）分桶，桶内按时间滑动
        var buckets: [String: [Int]] = [:]
        for (i, r) in records.enumerated() {
            buckets[r.kind + "|" + String(Int((r.amount * 100).rounded())), default: []].append(i)
        }
        var pairScores: [String: DedupePairScore] = [:]
        var edges: [(Int, Int, Int)] = []
        for idx in buckets.values where idx.count > 1 {
            let sorted = idx.sorted { records[$0].date < records[$1].date }
            for x in sorted.indices {
                var y = x + 1
                while y < sorted.count, records[sorted[y]].date.timeIntervalSince(records[sorted[x]].date) <= maxSpan {
                    let i = sorted[x], j = sorted[y]
                    if let s = score(records[i], records[j], options: options) {
                        pairScores[pairKey(records[i].id, records[j].id)] = s
                        edges.append((i, j, s.score))
                    }
                    y += 1
                }
            }
        }
        // 同订单号（金额可能被改过）
        var byExternal: [String: [Int]] = [:]
        for (i, r) in records.enumerated() where !r.externalID.isEmpty { byExternal[r.kind + "|" + r.externalID, default: []].append(i) }
        for idx in byExternal.values where idx.count > 1 {
            for x in idx.indices { for y in idx.indices where y > x {
                let i = idx[x], j = idx[y], k = pairKey(records[i].id, records[j].id)
                if pairScores[k] == nil, let s = score(records[i], records[j], options: options) { pairScores[k] = s; edges.append((i, j, s.score)) }
            } }
        }
        edges.sort { $0.2 != $1.2 ? $0.2 > $1.2 : (records[$0.0].id + records[$0.1].id) < (records[$1.0].id + records[$1.1].id) }

        var clusterOf = Array(records.indices)
        var clusters: [Int: [Int]] = [:]
        for i in records.indices { clusters[i] = [i] }
        for (i, j, _) in edges {
            let ci = clusterOf[i], cj = clusterOf[j]
            guard ci != cj, let a = clusters[ci], let b = clusters[cj] else { continue }
            let compatible = a.allSatisfy { x in b.allSatisfy { y in pairScores[pairKey(records[x].id, records[y].id)] != nil } }
            guard compatible else { continue }
            clusters[ci] = a + b
            clusters[cj] = nil
            for y in b { clusterOf[y] = ci }
        }

        var out: [DedupeGroup] = []
        for members in clusters.values where members.count > 1 {
            let list = members.map { records[$0] }.sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id }
            var minConf = DedupeConfidence.certain
            var best: DedupePairScore?
            for x in list.indices { for y in list.indices where y > x {
                guard let s = pairScores[pairKey(list[x].id, list[y].id)] else { continue }
                minConf = min(minConf, s.confidence)
                if best == nil || s.score > best!.score { best = s }
            } }
            let keep = suggestedKeep(list)
            out.append(DedupeGroup(id: list.map(\.id).sorted().joined(separator: "|"), members: list, confidence: minConf,
                                   suggestedKeepID: keep.id, reasons: best?.reasons ?? []))
        }
        // 置信度高的在前，同级按时间倒序
        return out.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return ($0.members.first?.date ?? .distantPast) > ($1.members.first?.date ?? .distantPast)
        }
    }

    /// 完整度：商户 / 备注 / 账户 / 分类（转账算转入账户）
    static func completeness(_ r: DedupeRecord) -> Int {
        var n = 0
        if !r.merchant.isEmpty { n += 1 }
        if !r.note.isEmpty { n += 1 }
        if r.accountID != nil { n += 1 }
        if r.kind == "transfer" ? r.toAccountID != nil : !(r.categoryName ?? "").isEmpty { n += 1 }
        return n
    }

    /// 建议保留：账单导入（有订单号，金额 / 时间最准）> 字段更完整 > 识图 / 快捷指令 > 最早记的
    static func suggestedKeep(_ members: [DedupeRecord]) -> DedupeRecord {
        func rank(_ r: DedupeRecord) -> Int {
            var v = completeness(r) * 10
            if !r.externalID.isEmpty { v += 1000 } else if isImported(r) { v += 500 }
            if r.source == "ocr" || r.source == "shortcut" { v += 2 } else if r.source == "manual" { v += 1 }
            return v
        }
        return members.max {
            let ra = rank($0), rb = rank($1)
            if ra != rb { return ra < rb }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }   // 同分保留最早记的
            return $0.id > $1.id
        } ?? members[0]
    }

    private static let genericCategories: Set<String> = ["其他", "其它", "未分类", "其他收入", "其他支出"]

    /// 保留 keep、删除 others 时要补的字段：保留的那笔为空才补；分类是「其他」时用手动选的分类
    static func mergePatch(keep: DedupeRecord, others: [DedupeRecord]) -> DedupeMergePatch {
        var p = DedupeMergePatch()
        let donors = others.sorted { a, b in
            // 手动记的（用户自己填的）优先
            let ma = a.source == "manual", mb = b.source == "manual"
            if ma != mb { return ma }
            return completeness(a) > completeness(b)
        }
        if keep.kind != "transfer" {
            if keep.merchant.isEmpty { p.merchantFrom = donors.first { !$0.merchant.isEmpty }?.id }
            let kc = keep.categoryName ?? ""
            if kc.isEmpty {
                p.categoryFrom = donors.first { !($0.categoryName ?? "").isEmpty }?.id
            } else if genericCategories.contains(kc) {
                p.categoryFrom = donors.first { $0.source == "manual" && !($0.categoryName ?? "").isEmpty && !genericCategories.contains($0.categoryName!) }?.id
            }
        }
        if keep.note.isEmpty { p.noteFrom = donors.first { !$0.note.isEmpty }?.id }
        if keep.accountID == nil { p.accountFrom = donors.first { $0.accountID != nil }?.id }
        return p
    }

    /// 自动处理：只处理「确定重复」的组，每组保留建议的一笔
    static func autoPlan(_ groups: [DedupeGroup]) -> [DedupeAutoItem] {
        groups.filter { $0.confidence == .certain }.compactMap { g in
            guard let keep = g.members.first(where: { $0.id == g.suggestedKeepID }) else { return nil }
            let others = g.members.filter { $0.id != keep.id }
            return DedupeAutoItem(group: g, keep: keep, delete: others, patch: mergePatch(keep: keep, others: others))
        }
    }

    /// 账单导入：每行账单最多匹配一笔已有记录、每笔已有记录最多匹配一行（按分数从高到低一对一分配）
    static func matchBills(_ bills: [DedupeRecord], existing: [DedupeRecord], window: DedupeWindow = .min10,
                           calendar: Calendar = .current) -> [String: DedupeBillMatch] {
        let options = DedupeOptions(window: window, ignoredPairs: [], calendar: calendar)
        var candidates: [(bill: String, existing: String, score: DedupePairScore)] = []
        for b in bills {
            for e in existing {
                if let s = score(b, e, options: options) { candidates.append((b.id, e.id, s)) }
            }
        }
        candidates.sort { $0.score.score != $1.score.score ? $0.score.score > $1.score.score : ($0.bill + $0.existing) < ($1.bill + $1.existing) }
        var usedBills = Set<String>(), usedExisting = Set<String>()
        var out: [String: DedupeBillMatch] = [:]
        for c in candidates where !usedBills.contains(c.bill) && !usedExisting.contains(c.existing) {
            usedBills.insert(c.bill); usedExisting.insert(c.existing)
            out[c.bill] = DedupeBillMatch(existingID: c.existing, score: c.score.score, confidence: c.score.confidence)
        }
        return out
    }
}
