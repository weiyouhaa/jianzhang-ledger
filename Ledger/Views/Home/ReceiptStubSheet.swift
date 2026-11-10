import SwiftUI
import SwiftData
import UIKit

/// 4.1 小票皮肤：点明细行弹出独立热敏回执存根（设计稿「单笔凭条溯源」）
/// 4.3 (45)：遵循系统 Sheet 规范——标准 detents、下拉关闭、显式「修改 / 再来一笔 / 退款 / 撕毁」按钮，无自定义手势
struct ReceiptStubSheet: View {
    let record: LedgerRecord
    /// 新建类动作（再来一笔 / 退款）使用的默认日期
    var newDate: Date = Date()
    var onDelete: (() -> Void)? = nil

    /// 凭条存根与编辑页在同一个 Sheet 里原地切换：不再「关闭一个 Sheet 再弹另一个」，避免两次 Sheet 转场叠加
    private enum Mode {
        case stub
        case edit
        case prefill(RecordPrefill)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDeleteConfirm = false
    @State private var didTriggerAction = false
    @State private var voucherAppeared = false
    @State private var mode: Mode = .stub
    @State private var detent: PresentationDetent
    private let stubDetent: PresentationDetent

    init(record: LedgerRecord, newDate: Date = Date(), onDelete: (() -> Void)? = nil) {
        self.record = record
        self.newDate = newDate
        self.onDelete = onDelete
        let h = Self.preferredStubHeight(for: record)
        self.stubDetent = .height(h)
        self._detent = State(initialValue: .height(h))
    }

    /// 根据记录字段行数静态计算存根弹窗高度，预留 iOS 26/27 Liquid Glass 导航栏与底部 Home Indicator 安全区高度，确保底部两排功能按钮及票据底边无需滚动即可完整显示
    private static func preferredStubHeight(for record: LedgerRecord) -> CGFloat {
        var extraRows = 0
        if record.kind == .transfer {
            extraRows += 1
            if record.fee > 0 { extraRows += 1 }
        }
        if !record.note.isEmpty && record.note != record.displayTitle {
            extraRows += 1
        }
        if !record.merchant.isEmpty && record.merchant != record.displayTitle {
            extraRows += 1
        }
        return min(max(680 + CGFloat(extraRows) * 34, 680), 780)
    }

    private var canRefund: Bool {
        record.kind == .expense && !record.isCreditRepayment
    }

    var body: some View {
        Group {
            switch mode {
            case .stub:
                stubBody
            case .edit:
                RecordEditorView(record: record)
            case .prefill(let p):
                RecordEditorView(record: nil, initialDate: p.date, initialKind: p.kind, prefill: p)
            }
        }
        .presentationDetents([stubDetent, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    private var stubBody: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ReceiptLabelText(text: "ORIGINAL RECEIPT VOUCHER", color: theme.faint)
                        Spacer()
                        VermilionStamp(text: "VERIFIED")
                    }
                    ThemedDashedRule()
                    HStack(alignment: .center, spacing: 12) {
                        let sealChar = ReceiptSquareStamp.sealCharacter(
                            name: record.categoryName,
                            icon: record.categoryIcon,
                            kindRaw: record.kind.rawValue
                        )
                        ReceiptSquareStamp(
                            char: sealChar,
                            size: 38,
                            tint: record.kind == .income ? theme.income : theme.accent,
                            highlighted: voucherAppeared
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.displayTitle)
                                .font(theme.sectionTitleFont)
                                .foregroundStyle(theme.ink)
                                .lineLimit(2)
                            Text("VOUCHER ID · " + String(record.id.uuidString.prefix(8)).uppercased())
                                .font(theme.labelFont)
                                .foregroundStyle(theme.faint)
                        }
                        Spacer()
                    }
                    Text(record.amountText)
                        .font(theme.heroAmountFont)
                        .monospacedDigit()
                        .foregroundStyle(amountColor)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    ThemedDashedRule()
                    stubRow("交易时间", DateText.monthDayTime.string(from: record.date))
                    stubRow("所属分类", record.categoryName)
                    if record.kind == .transfer {
                        stubRow(record.isCreditRepayment ? "付款账户" : "转出账户",
                                record.accountName.isEmpty ? "未选账户" : record.accountName)
                        stubRow(record.isCreditRepayment ? "还款信用卡" : "转入账户",
                                record.toAccount?.name ?? "未选账户")
                        if record.fee > 0 {
                            stubRow("手续费", Money.format(record.fee))
                        }
                    } else {
                        let accLabel = record.accountName.isEmpty ? "未选账户" : record.accountName
                        let balSuffix: String = {
                            guard let acc = record.accountRef else { return "" }
                            let bal = acc.balance()
                            if acc.type.isLiability {
                                return bal < 0 ? "（欠 \(Money.compact(-bal))）" : ""
                            }
                            return "（余 \(Money.compact(bal))）"
                        }()
                        stubRow(record.kind == .income ? "入账账户" : "扣款账户", accLabel + balSuffix)
                    }
                    if !record.note.isEmpty && record.note != record.displayTitle {
                        stubRow("备注", record.note)
                    }
                    if !record.merchant.isEmpty && record.merchant != record.displayTitle {
                        stubRow("商户", record.merchant)
                    }
                    HStack(spacing: 6) {
                        ReceiptLabelText(text: "记录来源", color: theme.faint)
                        DotLeader(color: theme.rule)
                        sourceBadge
                    }
                    ThemedDashedRule()
                    HStack(spacing: 8) {
                        Text("|||| ||| || |||| ||| | ||||")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(1.5)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(theme.faint.opacity(0.65))
                        Spacer(minLength: 6)
                        ReceiptLabelText(text: "JIANZHANG LEDGER", color: theme.faint)
                            .lineLimit(1)
                    }

                    // 主功能按钮行：修改（主操作）+ 再来一笔 + 退款（支出专属）+ 撕毁作废
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Button {
                                triggerEdit()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("修改")
                                        .font(theme.rowAmountFont)
                                }
                                .foregroundStyle(theme.paper)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                                .shadow(color: theme.accent.opacity(0.22), radius: 3, y: 1.5)
                            }
                            .buttonStyle(ReceiptPressButtonStyle())
                            .accessibilityIdentifier("stub-edit")

                            do {
                                Button {
                                    triggerDuplicate()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus.square.on.square")
                                            .font(.system(size: 12.5, weight: .medium))
                                        Text("再来一笔")
                                            .font(theme.rowAmountFont)
                                    }
                                    .foregroundStyle(theme.ink)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardFill))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.rule, lineWidth: 1))
                                    .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
                                }
                                .buttonStyle(ReceiptPressButtonStyle())
                                .accessibilityIdentifier("stub-duplicate")
                            }
                        }

                        HStack(spacing: 8) {
                            if canRefund {
                                Button {
                                    triggerRefund()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.uturn.backward.circle")
                                            .font(.system(size: 12.5, weight: .medium))
                                        Text("记录退款")
                                            .font(theme.metaFont.weight(.semibold))
                                    }
                                    .foregroundStyle(theme.income)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardFill))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.income.opacity(0.45), lineWidth: 1))
                                }
                                .buttonStyle(ReceiptPressButtonStyle())
                                .accessibilityIdentifier("stub-refund")
                            }

                            Button {
                                ReceiptHaptics.lightImpact()
                                dismiss()
                            } label: {
                                Text("保留存根")
                                    .font(theme.metaFont.weight(.semibold))
                                    .foregroundStyle(theme.ink)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardFill))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.rule, lineWidth: 1))
                            }
                            .buttonStyle(ReceiptPressButtonStyle())
                            .accessibilityIdentifier("stub-keep")

                            Button {
                                ReceiptHaptics.warning()
                                if onDelete != nil { triggerDelete() } else { showDeleteConfirm = true }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("撕毁作废")
                                        .font(theme.metaFont.weight(.semibold))
                                }
                                .foregroundStyle(theme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardFill))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.accent.opacity(0.4), lineWidth: 1))
                            }
                            .buttonStyle(ReceiptPressButtonStyle())
                            .accessibilityIdentifier("stub-delete")
                        }
                    }
                }
                .padding(ReceiptStyle.Space.m + 2)
                .receiptSurface(theme, hero: true, slot: true)
                .offset(y: voucherAppeared ? 0 : -8)
                .opacity(voucherAppeared ? 1 : 0.88)
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .onAppear {
                guard !voucherAppeared else { return }
                if reduceMotion {
                    voucherAppeared = true
                } else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                        voucherAppeared = true
                    }
                }
            }
            .themedScreenBackground()
            .navigationTitle("回执存根")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        triggerEdit()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .semibold))
                            Text("修改")
                        }
                        .font(theme.metaFont.weight(.semibold))
                        .foregroundStyle(theme.accent)
                    }
                    .accessibilityIdentifier("stub-toolbar-edit")
                }
            }
            .confirmationDialog("确定撕毁作废该笔凭条？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("撕毁作废", role: .destructive) {
                    guard !didTriggerAction else { return }
                    didTriggerAction = true
                    if let onDelete {
                        onDelete()
                        dismiss()
                    } else {
                        let target = record
                        let ctx = context
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            ctx.delete(target)
                            try? ctx.save()
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("作废后该记录将从账本中移除且不可恢复。")
            }
        }
    }

    private func triggerDelete() {
        guard !didTriggerAction, let onDelete else { return }
        didTriggerAction = true
        onDelete()
        dismiss()
    }

    private func triggerEdit() {
        guard !didTriggerAction else { return }
        didTriggerAction = true
        ReceiptHaptics.lightImpact()
        withAnimation(.snappy(duration: 0.24)) {
            detent = .large
            mode = .edit
        }
    }

    private func triggerDuplicate() {
        guard !didTriggerAction else { return }
        didTriggerAction = true
        ReceiptHaptics.lightImpact()
        withAnimation(.snappy(duration: 0.24)) {
            detent = .large
            mode = .prefill(RecordPrefill.duplicate(from: record, date: newDate))
        }
    }

    private func triggerRefund() {
        guard !didTriggerAction else { return }
        didTriggerAction = true
        ReceiptHaptics.lightImpact()
        let catID = DataStore.category(named: "退款", kind: .income, in: context)?.id
        withAnimation(.snappy(duration: 0.24)) {
            detent = .large
            mode = .prefill(RecordPrefill.refund(from: record, refundCategoryID: catID, date: newDate))
        }
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
            case "import": return "[导入]"
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
