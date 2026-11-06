import SwiftUI

/// 4.1 小票皮肤：点明细行弹出独立热敏回执存根（设计稿「单笔凭条溯源」）
struct ReceiptStubSheet: View {
    let record: LedgerRecord
    var onEdit: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ReceiptStyle.Space.m) {
                    HStack {
                        ReceiptLabelText(text: "THERMAL STUB", color: theme.faint)
                        Spacer()
                        ReceiptLabelText(text: DateText.monthDayTime.string(from: record.date), color: theme.faint)
                    }
                    ThemedDashedRule()
                    Text(record.displayTitle)
                        .font(theme.sectionTitleFont)
                        .foregroundStyle(theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(record.amountText)
                        .font(theme.heroAmountFont)
                        .monospacedDigit()
                        .foregroundStyle(amountColor)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    ThemedDashedRule()
                    stubRow("分类", record.categoryName)
                    stubRow("账户", record.accountName.isEmpty ? "未选账户" : record.accountName)
                    if !record.note.isEmpty {
                        stubRow("备注", record.note)
                    }
                    if !record.merchant.isEmpty {
                        stubRow("商户", record.merchant)
                    }
                    HStack(spacing: 6) {
                        ReceiptLabelText(text: "来源", color: theme.faint)
                        DotLeader(color: theme.rule)
                        sourceBadge
                    }
                    ThemedDashedRule()
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onEdit() }
                    } label: {
                        Text("在票面上修改")
                            .font(theme.rowAmountFont)
                            .foregroundStyle(theme.paper)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 10).fill(theme.accent))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("stub-edit")
                }
                .padding(ReceiptStyle.Space.l)
                .receiptSurface(theme, hero: true)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .themedScreenBackground()
            .themedRootTitle("回执存根")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var amountColor: Color {
        switch record.kind {
        case .income: return theme.income
        case .expense: return theme.ink
        default: return theme.faint
        }
    }

    private func stubRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ReceiptStyle.Space.xs) {
            ReceiptLabelText(text: title, color: theme.faint)
            DotLeader(color: theme.rule)
            Text(value)
                .font(theme.rowTitleFont)
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private var sourceBadge: some View {
        let label: String = {
            switch record.source {
            case "ocr": return "[识图]"
            case "shortcut": return "[快捷指令]"
            case "recurring": return "[周期]"
            default: return "[手记]"
            }
        }()
        Text(label)
            .font(theme.labelFont)
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
    }
}
