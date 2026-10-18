import Foundation
import SwiftData

/// 规则命中结果
struct RuleHit {
    var rule: CategoryRule
    var category: LedgerCategory?
    var account: LedgerAccount?
    var kind: RecordKind?
}

/// 分类记忆：学习「商户 → 分类 / 账户」，并在识图、快捷指令、账单导入时优先套用
@MainActor
enum RuleStore {
    static let learnKey = "rules.learnEnabled"

    static var learnEnabled: Bool {
        get { UserDefaults.standard.object(forKey: learnKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: learnKey) }
    }

    static func allRules(in context: ModelContext) -> [CategoryRule] {
        (try? context.fetch(FetchDescriptor<CategoryRule>(sortBy: [SortDescriptor(\CategoryRule.updatedAt, order: .reverse)]))) ?? []
    }

    /// 匹配规则（kind 为空表示不限收支）。命中时累计次数。
    static func match(merchant: String, text: String = "", kind: RecordKind?, in context: ModelContext,
                      rules: [CategoryRule]? = nil, countHit: Bool = true) -> RuleHit? {
        let list = rules ?? allRules(in: context)
        guard !list.isEmpty else { return nil }
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard let snap = RuleMatcher.match(merchant: merchant, text: text, kind: kind?.rawValue,
                                           rules: list.map(\.snapshot)),
              let rule = byID[snap.id] else { return nil }
        let category = DataStore.category(idString: rule.categoryID, in: context)
        let account = DataStore.account(idString: rule.accountID, in: context)
        // 分类已被删除且没有其他信息的规则视为失效
        if category == nil && account == nil && rule.kind == nil { return nil }
        if countHit { rule.hitCount += 1 }
        return RuleHit(rule: rule, category: category, account: account, kind: rule.kind ?? category?.kind)
    }

    /// 用户确认了某商户的分类 / 账户：新建或更新学习规则
    @discardableResult
    static func learn(merchant: String, kind: RecordKind, category: LedgerCategory?, account: LedgerAccount?,
                      in context: ModelContext, force: Bool = false) -> CategoryRule? {
        guard force || learnEnabled, kind.countsInStats, let category else { return nil }
        let display = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = MerchantNormalizer.normalize(display)
        guard key.count >= 2 else { return nil }
        let rules = allRules(in: context)
        if let existing = rules.first(where: { $0.isLearned && $0.keyword == key }) {
            let changed = existing.categoryID != category.id.uuidString
                || (account != nil && existing.accountID != account!.id.uuidString)
                || existing.kindRaw != kind.rawValue
            existing.categoryID = category.id.uuidString
            if let account { existing.accountID = account.id.uuidString }
            existing.kindRaw = kind.rawValue
            existing.displayName = display
            if changed { existing.updatedAt = Date() }
            return existing
        }
        // 已有手动关键词规则给出同样结果时，不再重复学习
        if let manual = RuleMatcher.match(merchant: display, kind: kind.rawValue, rules: rules.map(\.snapshot)),
           !manual.isLearned, manual.categoryID == category.id {
            return nil
        }
        let rule = CategoryRule(keyword: key, displayName: display, isLearned: true, kind: kind,
                                categoryID: category.id, accountID: account?.id)
        context.insert(rule)
        return rule
    }

    /// 记住分类最近使用的账户
    static func rememberAccount(_ account: LedgerAccount?, for category: LedgerCategory?) {
        guard let account, let category else { return }
        if category.lastAccountID != account.id.uuidString { category.lastAccountID = account.id.uuidString }
    }

    static func lastAccount(for category: LedgerCategory?, in context: ModelContext) -> LedgerAccount? {
        guard let category, let a = DataStore.account(idString: category.lastAccountID, in: context), !a.isArchived else { return nil }
        return a
    }

    static func defaultAccount(in context: ModelContext) -> LedgerAccount? {
        let name = UserDefaults.standard.string(forKey: SettingsKey.defaultAccount) ?? ""
        return DataStore.account(named: name, in: context)
    }
}
