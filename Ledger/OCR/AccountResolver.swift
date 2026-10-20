import Foundation

/// 识图账户匹配（纯 Foundation，见 Tools/ModelMergeCheck）：尾号 > 同银行同卡种 > 模型给的账户名 > 兜底。
/// 已识别出银行时，绝不因为一个泛泛的「信用卡」就选中别家银行的卡。
struct AccountCandidate: Equatable {
    var id: UUID
    var name: String
    /// AccountType.rawValue
    var type: String
    var note: String = ""
    /// 账户里填写的卡号尾号（可空）
    var cardTail: String = ""
    /// 记账时学到的尾号（真实模式）
    var learnedTails: Set<String> = []

    static let liabilityTypes: Set<String> = ["credit", "consumerCredit", "mortgage", "fundLoan", "carLoan", "loan", "otherLiability"]
    var isLiability: Bool { Self.liabilityTypes.contains(type) }

    /// 账户的全部尾号：字段 + 学到的 + 名称 / 备注里独立的 4 位数字
    var tails: Set<String> {
        var s = learnedTails
        let t = cardTail.trimmingCharacters(in: .whitespaces)
        if t.count == 4 { s.insert(t) }
        for text in [name, note] {
            for m in AccountResolver.tailRegex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                s.insert((text as NSString).substring(with: m.range))
            }
        }
        return s
    }

    /// 名称 / 备注里出现了这家银行（含简称：招商银行 / 招商 / 招行，英文缩写 CMB）
    func matchesBank(_ bank: String) -> Bool {
        let hay = name + " " + note
        if AccountHint.aliases(forBank: bank).contains(where: { hay.contains($0) }) { return true }
        let localized = EnglishBankTerms.localize(hay)
        return localized != hay && AccountHint.aliases(forBank: bank).contains(where: { localized.contains($0) })
    }
}

enum AccountResolver {
    enum Role: String {
        /// 普通收支的账户
        case single
        /// 还款 / 转账的付款方（非负债）
        case payer
        /// 被还款的信用卡 / 花呗（负债）
        case card
    }

    enum Via: String { case tail, bank, name, fallback, none }

    struct Resolution: Equatable {
        var id: UUID?
        var via: Via
    }

    static let tailRegex = try! NSRegularExpression(pattern: #"(?<!\d)\d{4}(?!\d)"#)

    /// 4 位尾号（其它长度 / 非数字返回 nil）
    static func normalizeTail(_ s: String?) -> String? {
        guard let s else { return nil }
        let digits = s.filter(\.isNumber)
        guard digits.count >= 4 else { return nil }
        let tail = String(digits.suffix(4))
        return tail.allSatisfy { ("0"..."9").contains($0) } ? tail : nil
    }

    static func resolve(hint: AccountHint?, modelName: String?, role: Role, accounts: [AccountCandidate],
                        excluding: UUID? = nil) -> Resolution {
        let usable = accounts.filter { $0.id != excluding }
        // 角色决定可选范围：被还款的一定是负债，付款方一定不是负债
        let pool: [AccountCandidate]
        switch role {
        case .card: pool = usable.filter(\.isLiability)
        case .payer: pool = usable.filter { !$0.isLiability }
        case .single: pool = usable
        }
        guard !pool.isEmpty else { return Resolution(id: nil, via: .none) }
        let typed: [AccountCandidate] = {
            guard let t = hint?.type else { return pool }
            let same = pool.filter { $0.type == t }
            return same.isEmpty ? pool : same
        }()
        let bank = hint?.bankName.flatMap { $0.isEmpty ? nil : $0 }

        // 1. 尾号
        if let tail = normalizeTail(hint?.cardTail) {
            let hits = pool.filter { $0.tails.contains(tail) }
            if let hit = hits.first(where: { a in typed.contains(where: { $0.id == a.id }) }) ?? hits.first {
                return Resolution(id: hit.id, via: .tail)
            }
        }
        // 2. 同银行：同卡种优先
        if let bank {
            if let hit = typed.first(where: { $0.matchesBank(bank) }) ?? pool.first(where: { $0.matchesBank(bank) }) {
                return Resolution(id: hit.id, via: .bank)
            }
        }
        // 3. 模型给的账户名（已识别银行时必须是同一家银行）
        if let name = modelName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != "未知",
           let hit = pool.first(where: { $0.name == name }) {
            if bank == nil || hit.matchesBank(bank!) { return Resolution(id: hit.id, via: .name) }
        }
        // 4. 兜底：已识别银行但没有这家银行的账户 → 不乱选（交给用户 / 默认账户）
        if bank != nil { return Resolution(id: nil, via: .none) }
        switch role {
        case .card:
            // 只有一张同类卡时才自动选
            let cards = typed.filter { $0.type == (hint?.type ?? "credit") }
            return cards.count == 1 ? Resolution(id: cards[0].id, via: .fallback) : Resolution(id: nil, via: .none)
        case .payer, .single:
            guard let t = hint?.type, let first = pool.first(where: { $0.type == t }) else { return Resolution(id: nil, via: .none) }
            return Resolution(id: first.id, via: .fallback)
        }
    }
}
