import Foundation
import SwiftData

/// 一键去重的数据操作（只用于真实账本：调用方传入 DataStore.shared 的 context，防窥模式下不调用）
@MainActor
enum DedupeService {
    static let ignoredPairsKey = "dedupe.ignoredPairs"
    static let windowKey = "dedupe.window"

    static func dedupeRecord(_ r: LedgerRecord) -> DedupeRecord {
        DedupeRecord(id: r.id.uuidString, kind: r.kindRaw, amount: r.amount, date: r.date,
                     merchant: r.merchant, note: r.note,
                     accountID: r.accountRef?.id.uuidString,
                     toAccountID: r.kind == .transfer ? r.toAccount?.id.uuidString : nil,
                     categoryName: r.kind.countsInStats ? r.category?.name : nil,
                     externalID: r.externalID, source: r.source, importBatchID: r.importBatchID,
                     recurringKey: r.recurringKey, createdAt: r.createdAt)
    }

    // MARK: - 「不是重复」

    static var ignoredPairs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: ignoredPairsKey) ?? [])
    }

    static func ignore(_ group: DedupeGroup) {
        var s = ignoredPairs
        s.formUnion(group.pairKeys)
        UserDefaults.standard.set(Array(s).sorted(), forKey: ignoredPairsKey)
        RunLog.shared.log(.info, "dedupe", "标记不是重复：\(group.members.count) 笔", memory: false)
    }

    static func clearIgnored() {
        UserDefaults.standard.removeObject(forKey: ignoredPairsKey)
    }

    // MARK: - 扫描

    static func scan(window: DedupeWindow, in context: ModelContext) -> (groups: [DedupeGroup], scanned: Int) {
        let all = ((try? context.fetch(FetchDescriptor<LedgerRecord>())) ?? []).filter { $0.kind != .adjustment }
        let options = DedupeOptions(window: window, ignoredPairs: ignoredPairs, calendar: DateText.calendar)
        let groups = DedupeEngine.groups(all.map(dedupeRecord), options: options)
        RunLog.shared.log(.info, "dedupe", "扫描 \(all.count) 笔（窗口 \(window.title)），发现 \(groups.count) 组", memory: false)
        return (groups, all.count)
    }

    // MARK: - 删除 + 合并

    struct Decision {
        var group: DedupeGroup
        var keepIDs: Set<String>
    }

    struct Outcome {
        var deleted = 0
        var merged = 0
        var groups = 0
    }

    /// 删除每组未保留的记录；只保留一笔时把被删记录里有用的信息补到保留的那笔。整批写入变动日志，可撤销上一批
    @discardableResult
    static func apply(_ decisions: [Decision], title: String, in context: ModelContext) throws -> Outcome {
        let ids = Set(decisions.flatMap { $0.group.members.map(\.id) })
        let all = (try? context.fetch(FetchDescriptor<LedgerRecord>())) ?? []
        let byID = Dictionary(all.filter { ids.contains($0.id.uuidString) }.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })

        var outcome = Outcome()
        var snapshot = DedupeUndoSnapshot(title: title, date: Date(), deleted: [], kept: [])
        var toDelete: [LedgerRecord] = []
        for d in decisions {
            let keep = d.group.members.filter { d.keepIDs.contains($0.id) }
            let drop = d.group.members.filter { !d.keepIDs.contains($0.id) }
            guard !keep.isEmpty, !drop.isEmpty else { continue }
            let dropRecords = drop.compactMap { byID[$0.id] }
            guard !dropRecords.isEmpty else { continue }
            outcome.groups += 1
            if keep.count == 1, let k = keep.first, let kr = byID[k.id] {
                let patch = DedupeEngine.mergePatch(keep: k, others: drop)
                if !patch.isEmpty {
                    snapshot.kept.append(.init(kr))
                    if let src = patch.merchantFrom.flatMap({ byID[$0] }) { kr.merchant = src.merchant }
                    if let src = patch.noteFrom.flatMap({ byID[$0] }) { kr.note = src.note }
                    if let src = patch.categoryFrom.flatMap({ byID[$0] }), let c = src.category { kr.category = c }
                    if let src = patch.accountFrom.flatMap({ byID[$0] }), let a = src.accountRef {
                        kr.accountRef = a
                        kr.account = a.name
                    }
                    outcome.merged += patch.fieldCount
                }
            }
            for r in dropRecords {
                snapshot.deleted.append(.init(r))
                toDelete.append(r)
            }
        }
        guard !toDelete.isEmpty else { return outcome }
        for r in toDelete { context.delete(r) }
        do {
            try ChangeLogger.with(.app, title: title) { try context.save() }
        } catch {
            context.rollback()
            RunLog.shared.log(.error, "dedupe", "删除失败：\(error.localizedDescription)", memory: false)
            throw error
        }
        outcome.deleted = toDelete.count
        DedupeUndoStore.save(snapshot)
        RunLog.shared.log(.info, "dedupe", "\(title)：\(outcome.groups) 组，删除 \(outcome.deleted) 笔，补全 \(outcome.merged) 项", memory: false)
        return outcome
    }

    // MARK: - 撤销

    /// 恢复上一批删除的记录（含分类 / 账户关系），并还原被补全的字段
    @discardableResult
    static func undoLast(in context: ModelContext) throws -> Int {
        guard let snap = DedupeUndoStore.load() else { return 0 }
        let existing = Set(((try? context.fetch(FetchDescriptor<LedgerRecord>())) ?? []).map(\.id))
        var restored = 0
        for d in snap.deleted where !existing.contains(d.id) {
            let kind = RecordKind(rawValue: d.kind) ?? .expense
            let r = LedgerRecord(amount: d.amount, kind: kind, category: d.categoryID.flatMap { DataStore.category(id: $0, in: context) },
                                 note: d.note, merchant: d.merchant, account: d.account, date: d.date, source: d.source)
            r.id = d.id
            r.createdAt = d.createdAt
            r.accountRef = d.accountID.flatMap { DataStore.account(id: $0, in: context) }
            r.toAccount = d.toAccountID.flatMap { DataStore.account(id: $0, in: context) }
            r.fee = d.fee
            r.externalID = d.externalID
            r.importBatchID = d.importBatchID
            r.recurringKey = d.recurringKey
            context.insert(r)
            restored += 1
        }
        let keptIDs = Set(snap.kept.map(\.id))
        if !keptIDs.isEmpty {
            let all = (try? context.fetch(FetchDescriptor<LedgerRecord>())) ?? []
            for r in all where keptIDs.contains(r.id) {
                guard let k = snap.kept.first(where: { $0.id == r.id }) else { continue }
                r.merchant = k.merchant
                r.note = k.note
                r.category = k.categoryID.flatMap { DataStore.category(id: $0, in: context) }
                r.accountRef = k.accountID.flatMap { DataStore.account(id: $0, in: context) }
                r.account = k.account
            }
        }
        do {
            try ChangeLogger.with(.app, title: "撤销去重") { try context.save() }
        } catch {
            context.rollback()
            RunLog.shared.log(.error, "dedupe", "撤销失败：\(error.localizedDescription)", memory: false)
            throw error
        }
        DedupeUndoStore.clear()
        RunLog.shared.log(.info, "dedupe", "撤销去重：恢复 \(restored) 笔", memory: false)
        return restored
    }
}

/// 上一批去重删除的记录快照（仅真实账本；本机文件，完整文件保护）
struct DedupeUndoSnapshot: Codable {
    struct Deleted: Codable {
        var id: UUID
        var amount: Double
        var kind: String
        var note: String
        var merchant: String
        var account: String
        var date: Date
        var source: String
        var createdAt: Date
        var categoryID: UUID?
        var accountID: UUID?
        var toAccountID: UUID?
        var fee: Double
        var externalID: String
        var importBatchID: String
        var recurringKey: String

        init(_ r: LedgerRecord) {
            id = r.id; amount = r.amount; kind = r.kindRaw; note = r.note; merchant = r.merchant; account = r.account
            date = r.date; source = r.source; createdAt = r.createdAt; categoryID = r.category?.id
            accountID = r.accountRef?.id; toAccountID = r.toAccount?.id; fee = r.fee
            externalID = r.externalID; importBatchID = r.importBatchID; recurringKey = r.recurringKey
        }
    }

    /// 被补全字段的保留记录：补全前的值
    struct Kept: Codable {
        var id: UUID
        var merchant: String
        var note: String
        var categoryID: UUID?
        var accountID: UUID?
        var account: String

        init(_ r: LedgerRecord) {
            id = r.id; merchant = r.merchant; note = r.note; categoryID = r.category?.id
            accountID = r.accountRef?.id; account = r.account
        }
    }

    var title: String
    var date: Date
    var deleted: [Deleted]
    var kept: [Kept]
}

enum DedupeUndoStore {
    private static var url: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dedupe-undo.json")
    }

    static func save(_ s: DedupeUndoSnapshot) {
        guard let url, let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func load() -> DedupeUndoSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DedupeUndoSnapshot.self, from: data)
    }

    static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
