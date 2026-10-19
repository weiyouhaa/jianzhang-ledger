import SwiftUI
import SwiftData

/// 资产页长按「修改余额」：输入实际余额，差额记为校准或收支
struct QuickBalanceSheet: View {
    let account: LedgerAccount

    enum Mode: String, CaseIterable, Identifiable {
        case adjustment, record
        var id: String { rawValue }
        var title: String { self == .adjustment ? "余额校准（不计收支）" : "记为收入 / 支出" }
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var mode: Mode = .adjustment
    @State private var didLoad = false
    @FocusState private var focused: Bool

    private var liability: Bool { account.type.isLiability }
    private var current: Double { account.balance() }
    /// 界面上显示的数值：负债显示欠款（正数）
    private var shown: Double { liability ? -current : current }

    /// 对余额的影响（正 = 余额增加）
    private var delta: Double? {
        guard let v = Money.parse(text) else { return nil }
        let target = liability ? -v : v
        let d = ((target - current) * 100).rounded() / 100
        return d
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                HStack(spacing: 6) {
                    CategoryIcon(icon: account.iconName, color: account.color, size: 22)
                    Text(account.name).font(.headline).lineLimit(1)
                }
                Spacer()
                Button("保存", action: save)
                    .fontWeight(.semibold)
                    .disabled(delta == nil || abs(delta ?? 0) < 0.005)
            }

            VStack(spacing: 4) {
                Text(liability ? "实际欠款" : "实际余额")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Money.symbol)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    TextField("0.00", text: $text)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .keyboardType(shown < 0 ? .numbersAndPunctuation : .decimalPad)
                        .focused($focused)
                        .multilineTextAlignment(.center)
                        .fixedSize()
                }
                Text(differenceText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(differenceColor)
            }

            Picker("校准方式", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            text = Money.plain(shown)
            focused = true
        }
    }

    private var differenceText: String {
        let book = "账面 " + Money.format(shown)
        guard let delta, abs(delta) >= 0.005 else { return book + " · 未修改" }
        // 负债：余额减少 = 欠款增加
        let change = liability ? -delta : delta
        let what = liability ? "欠款" : "余额"
        let diff = (change > 0 ? "+" : "") + Money.format(change)
        if mode == .record {
            return book + " · \(what) \(diff)，记一笔\(delta > 0 ? "收入" : "支出")"
        }
        return book + " · \(what) \(diff)"
    }

    private var differenceColor: Color {
        guard let delta, abs(delta) >= 0.005 else { return .secondary }
        return delta > 0 ? .green : .red
    }

    private func save() {
        guard let delta, abs(delta) >= 0.005 else { return }
        let r: LedgerRecord
        switch mode {
        case .adjustment:
            r = LedgerRecord(amount: delta, kind: .adjustment, category: nil, note: "余额校准",
                             account: account.name, date: Date(), source: "manual")
        case .record:
            let kind: RecordKind = delta > 0 ? .income : .expense
            r = LedgerRecord(amount: abs(delta), kind: kind, category: DataStore.category(named: nil, kind: kind, in: context),
                             note: "余额调整", account: account.name, date: Date(), source: "manual")
        }
        r.accountRef = account
        context.insert(r)
        try? context.save()
        if mode == .record { BudgetMonitor.check(in: context) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}
