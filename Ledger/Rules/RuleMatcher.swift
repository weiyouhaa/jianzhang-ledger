import Foundation

/// 商户名规整：去括号内容（分店名）、公司后缀、空白与标点，统一小写
enum MerchantNormalizer {
    private static let bracketPattern = try! NSRegularExpression(pattern: #"[(（\[【<《][^)）\]】>》]*[)）\]】>》]"#)
    private static let suffixes = ["股份有限公司", "有限责任公司", "有限公司", "分公司", "总公司", "公司", "集团"]

    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased()
        let ns = s as NSString
        s = bracketPattern.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        var changed = true
        while changed {
            changed = false
            for suf in suffixes where s.hasSuffix(suf) && s.count > suf.count + 1 {
                s = String(s.dropLast(suf.count))
                changed = true
            }
        }
        let kept = s.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
        return String(String.UnicodeScalarView(kept))
    }
}

/// 规则的纯数据快照（与 SwiftData 模型解耦，便于测试）
struct RuleSnapshot: Equatable {
    var id: UUID
    /// 学习规则为规整后的商户名；手动规则为用户输入的关键词
    var keyword: String
    var isLearned: Bool
    var kindRaw: String = ""
    var categoryID: UUID?
    var accountID: UUID?
    var isEnabled: Bool = true
}

enum RuleMatcher {
    /// 匹配顺序：学习规则（商户完全一致）> 手动关键词规则（最长关键词优先）> 学习规则（商户名互相包含）。
    /// kind 为 nil 时不限收支类型（识图记账自动判断的场景，规则可以改写类型）。
    static func match(merchant: String, text: String = "", kind: String? = nil, rules: [RuleSnapshot]) -> RuleSnapshot? {
        let usable = rules.filter { r in
            r.isEnabled && (kind == nil || r.kindRaw.isEmpty || r.kindRaw == kind)
        }
        let nm = MerchantNormalizer.normalize(merchant)
        if !nm.isEmpty, let exact = usable.first(where: { $0.isLearned && $0.keyword == nm }) {
            return exact
        }
        let haystack = MerchantNormalizer.normalize(merchant + " " + text)
        if !haystack.isEmpty {
            let manual = usable
                .filter { !$0.isLearned }
                .compactMap { r -> (RuleSnapshot, Int)? in
                    let k = MerchantNormalizer.normalize(r.keyword)
                    return !k.isEmpty && haystack.contains(k) ? (r, k.count) : nil
                }
                .max { $0.1 < $1.1 }
            if let manual { return manual.0 }
        }
        if nm.count >= 2 {
            let fuzzy = usable
                .filter { $0.isLearned && $0.keyword.count >= 2 && (nm.contains($0.keyword) || $0.keyword.contains(nm)) }
                .max { $0.keyword.count < $1.keyword.count }
            if let fuzzy { return fuzzy }
        }
        return nil
    }
}
