import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// 4.2 小票皮肤「记一笔 / 修改记录」：设计稿机械收银键盘 + 截屏识图凭条（默认皮肤仍用 RecordEditorView 表单）
struct ReceiptCashierView: View {
    var record: LedgerRecord? = nil
    var initialDate: Date = Date()
    var initialKind: RecordKind = .expense
    var presetAccountID: UUID? = nil
    var prefill: RecordPrefill? = nil
    var repayCardID: UUID? = nil
    var startInOCRMode: Bool = false
    var onDismiss: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Query(sort: \LedgerCategory.sortOrder) private var allCategories: [LedgerCategory]
    @Query(sort: \LedgerAccount.sortOrder) private var allAccounts: [LedgerAccount]
    @Query(sort: \CategoryRule.hitCount, order: .reverse) private var allRules: [CategoryRule]
    @AppStorage(SettingsKey.defaultAccount) private var defaultAccount = ""

    private enum Submode: String { case manual, ocr }
    @State private var submode: Submode = .manual
    @State private var kind: RecordKind = .expense
    @State private var amountText = ""
    @State private var note = ""
    @State private var merchant = ""
    @State private var feeText = ""
    @State private var selectedCategoryID: UUID?
    @State private var accountID: UUID?
    @State private var toAccountID: UUID?
    @State private var date = Date()
    @State private var source = "manual"
    @State private var recurringKey = ""
    @State private var alertMessage: String?
    @State private var showApprovedStamp = false
    @State private var showDeleteConfirm = false
    @State private var savedCountInSession = 0

    // OCR
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isRecognizing = false
    @State private var ocrEngineLine: String?
    @State private var ocrTimeHint: String?
    @State private var ocrReference: Date?
    @State private var ocrFallback: CaptureTime?
    @State private var ocrAccountTail: String?
    @State private var ocrCardTail: String?
    @State private var editingField: InlineField?
    @State private var inlineDraft = ""
    /// 用户在下拉里点过账户之后，换分类不再覆盖
    @State private var accountTouched = false
    @State private var hasOCRResult = false
    @State private var detectedReceipts: [ParsedReceipt] = []
    @State private var showReceiptPicker = false

    private enum InlineField: String, Identifiable {
        case amount, merchant, note, fee, type, category, account, toAccount, time
        var id: String { rawValue }
    }

    private var categories: [LedgerCategory] {
        allCategories.filter { $0.kind == kind }
    }
    private var selectableAccounts: [LedgerAccount] {
        allAccounts.filter { !$0.isArchived || $0.id == accountID || $0.id == toAccountID }
    }
    private var selectedCategory: LedgerCategory? {
        categories.first { $0.id == selectedCategoryID } ?? categories.first
    }
    private var selectedAccount: LedgerAccount? {
        selectableAccounts.first { $0.id == accountID }
    }
    private var hasExpressionOperator: Bool {
        amountText.dropFirst().contains(where: { $0 == "+" || $0 == "-" })
    }
    private var parsedAmount: Double? {
        Self.evaluateAmountExpression(amountText)
    }
    private var suggestedMerchants: [String] {
        let catID = selectedCategory?.id.uuidString ?? ""
        var out: [String] = []
        for r in allRules where r.isEnabled {
            let name = (r.displayName.isEmpty ? r.keyword : r.displayName).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !out.contains(name) else { continue }
            if !catID.isEmpty && r.categoryID == catID {
                out.insert(name, at: 0)
            } else {
                out.append(name)
            }
        }
        for fallback in ["星巴克", "美团", "京东商城", "全家便利店", "滴滴出行"] where !out.contains(fallback) {
            out.append(fallback)
        }
        return Array(out.prefix(8))
    }

    private var canStamp: Bool {
        guard let a = parsedAmount, a > 0 else { return false }
        if kind == .transfer { return accountID != nil && toAccountID != nil && accountID != toAccountID }
        return true
    }

    /// 支持简单加减算式（如 "35+12.5-3" → 44.5）
    static func evaluateAmountExpression(_ raw: String) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "￥", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if !cleaned.dropFirst().contains(where: { $0 == "+" || $0 == "-" }) {
            return Money.parse(cleaned)
        }
        var total = 0.0
        var currentSign = 1.0
        var token = ""
        var parsedAny = false
        for (i, ch) in cleaned.enumerated() {
            if (ch == "+" || ch == "-") && i > 0 {
                if let val = Double(token) {
                    total += currentSign * val
                    parsedAny = true
                }
                token = ""
                currentSign = ch == "+" ? 1.0 : -1.0
            } else {
                token.append(ch)
            }
        }
        if !token.isEmpty, let val = Double(token) {
            total += currentSign * val
            parsedAny = true
        }
        guard parsedAny else { return nil }
        return (total * 100).rounded() / 100
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                ScrollView(showsIndicators: false) {
                    VStack(spacing: ReceiptStyle.Space.m) {
                        if submode == .manual {
                            manualSheet
                            keypad
                        } else {
                            ocrSheet
                        }
                    }
                    .padding(.horizontal, ReceiptStyle.pageHorizontalMargin)
                    .padding(.top, 10)
                    .padding(.bottom, 20)
                }
            }
            .themedScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .alert("提示", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(alertMessage ?? "") }
            .onAppear {
                if startInOCRMode { submode = .ocr }
                date = initialDate
                bootstrapDefaults()
                if record == nil {
                    let vocab = DataStore.ocrVocabulary(categories: allCategories, accounts: allAccounts, isDecoy: SessionManager.shared.isDecoy)
                    AppleIntelligenceExtractor.prewarm(vocabulary: vocab)
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await recognizeBatch(items) }
            }
            .onChange(of: kind) { _, _ in
                if !categories.contains(where: { $0.id == selectedCategoryID }) {
                    selectedCategoryID = categories.first?.id
                }
            }
            .confirmationDialog("识别到 \(detectedReceipts.count) 笔交易", isPresented: $showReceiptPicker, titleVisibility: .visible) {
                Button("一键全部入账（共 \(detectedReceipts.count) 笔）") {
                    saveAllDetectedReceipts()
                }
                ForEach(Array(detectedReceipts.enumerated()), id: \.offset) { _, r in
                    Button("单选微调：" + RecordEditorView.receiptTitle(r)) { applyParsed(r) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("可直接将 \(detectedReceipts.count) 笔流水全部记入账本，或单选其中一笔在票面上微调。")
            }
            .confirmationDialog("删除这条记录？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let record {
                        let target = record
                        let ctx = context
                        close()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            ctx.delete(target)
                            try? ctx.save()
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("\(record?.deleteSummary ?? "")\n删除后无法恢复。")
            }
            .overlay {
                if showApprovedStamp {
                    approvedStampOverlay
                }
            }
        }
    }

    // MARK: - Top mode bar

    /// 设计稿顶栏：取消纸签 + 双模切换胶囊 + 朱砂保存键（同一行，不再用系统导航栏）
    private var headerBar: some View {
        HStack(spacing: 8) {
            Button { close() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                    Text("取消")
                        .font(theme.serifLabelFont)
                }
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(
                        LinearGradient(colors: [theme.cardFill, theme.paper], startPoint: .top, endPoint: .bottom)
                    )
                )
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.rule, lineWidth: 1))
                .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 2)

            HStack(spacing: 2) {
                modeChip(record != nil ? "⌨️ 编辑票据" : "⌨️ 手工记一笔", .manual)
                modeChip("📷 截屏识图", .ocr, badge: detectedReceipts.count > 1 ? "\(detectedReceipts.count)" : nil)
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.rule.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.rule, lineWidth: 1))

            Spacer(minLength: 2)

            if submode == .manual {
                Button { stampSave() } label: {
                    Text("保存")
                        .font(theme.serifLabelFont)
                        .foregroundStyle(canStamp ? theme.paper : theme.faint)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 4).fill(canStamp ? theme.accent : theme.rule.opacity(0.4)))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(canStamp ? theme.accent : theme.rule, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!canStamp)
            } else if hasOCRResult {
                // 设计稿：识图模式右上角直接「盖章保存」（票面底部还有一枚同动作的宽按钮）
                Button { stampSave(fromOCR: true) } label: {
                    Text("盖章保存")
                        .font(theme.serifLabelFont)
                        .foregroundStyle(theme.paper)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 4).fill(theme.accent))
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 46, height: 28)
            }
        }
        .padding(.horizontal, ReceiptStyle.pageHorizontalMargin)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(theme.paper.opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.rule.opacity(0.75)).frame(height: 0.7)
        }
    }

    private func modeChip(_ title: String, _ mode: Submode, badge: String? = nil) -> some View {
        Button {
            withAnimation(.snappy) {
                submode = mode
                editingField = nil
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(theme.serifLabelFont)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.paper)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(theme.accent))
                }
            }
            .foregroundStyle(submode == mode ? theme.accent : theme.faint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 3.5).fill(submode == mode ? theme.cardFill : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3.5).strokeBorder(submode == mode ? theme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(mode == .manual ? "cashier-mode-manual" : "cashier-mode-ocr")
    }

    // MARK: - Manual sheet

    private var manualSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ReceiptLabelText(
                    text: record != nil ? "CASHIER VOUCHER · 修订票据" : (savedCountInSession > 0 ? "CASHIER VOUCHER · 已连记 \(savedCountInSession) 笔" : "CASHIER VOUCHER · 手工收银台"),
                    color: theme.faint
                )
                Spacer()
                ReceiptLabelText(text: "CNY / RMB", color: theme.faint)
            }

            // 支出联 / 收入联 / 转账联
            HStack(spacing: 3) {
                typeTab("支出联", .expense)
                typeTab("收入联", .income)
                typeTab("转账联", .transfer)
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 4).fill(theme.rule.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.rule, lineWidth: 1))

            HStack(alignment: .center, spacing: 12) {
                let sealChar = ReceiptSquareStamp.sealCharacter(
                    name: kind == .transfer ? "转账" : (selectedCategory?.name ?? ""),
                    icon: kind == .transfer ? "arrow.left.arrow.right" : (selectedCategory?.icon ?? "tag"),
                    kindRaw: kind.rawValue
                )
                ReceiptSquareStamp(
                    char: sealChar,
                    size: 38,
                    tint: kind == .income ? theme.income : theme.accent
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(kind == .transfer ? "转账" : (selectedCategory?.name ?? "选择分类"))
                        .font(theme.sectionTitleFont)
                        .foregroundStyle(theme.ink)
                    TextField("输入摘要备注…", text: $note)
                        .font(theme.serifLabelFont)
                        .foregroundStyle(theme.faint)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("editor-note")
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if hasExpressionOperator {
                        Text(amountText + " =")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.faint)
                            .lineLimit(1)
                    }
                    Text(displayAmount)
                        .font(theme.heroAmountFont)
                        .monospacedDigit()
                        .foregroundStyle(kind == .income ? theme.income : theme.accent)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.16), value: amountText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .accessibilityIdentifier("cashier-amount")
                }
            }
            .padding(.vertical, 2)

            if kind != .transfer && !categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(categories.prefix(6)) { c in
                            let isSel = c.id == selectedCategory?.id
                            Button {
                                pickCategory(c)
                            } label: {
                                Text(c.name)
                                    .font(theme.serifLabelFont)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .foregroundStyle(isSel ? theme.accent : theme.ink)
                                    .background(RoundedRectangle(cornerRadius: 3.5).fill(isSel ? theme.accent.opacity(0.12) : theme.paper))
                                    .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(isSel ? theme.accent : theme.rule, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            ThemedDashedRule()

            VStack(spacing: 9) {
                voucherRow("时间", DateText.fullCN.string(from: date), field: .time)
                editorIf(.time)
                if kind != .transfer {
                    voucherRow("商户", merchant.isEmpty ? "可选（点此填写）" : merchant, field: .merchant)
                    editorIf(.merchant)
                    voucherRow("分类", selectedCategory?.name ?? "未分类", field: .category, menu: true)
                        .accessibilityIdentifier("cashier-category")
                    editorIf(.category)
                }
                let accountDisplay: String = {
                    guard let acc = selectedAccount else { return "未选账户" }
                    let bal = acc.balance()
                    if acc.type.isLiability {
                        return bal < 0 ? "\(acc.name)（欠 \(Money.compact(-bal))）" : acc.name
                    }
                    return "\(acc.name)（余 \(Money.compact(bal))）"
                }()
                voucherRow(kind == .transfer ? "转出" : "账户",
                           accountDisplay,
                           field: .account,
                           menu: true)
                .accessibilityIdentifier("cashier-account")
                editorIf(.account)
                if kind == .transfer {
                    voucherRow("转入",
                               selectableAccounts.first { $0.id == toAccountID }?.name ?? "选择账户",
                               field: .toAccount,
                               menu: true)
                    editorIf(.toAccount)
                    let parsedFee = Double(feeText) ?? 0
                    voucherRow("手续费", parsedFee > 0 ? Money.format(parsedFee) : "免手续费（点此填写）", field: .fee)
                    editorIf(.fee)
                    if let toCard = selectableAccounts.first(where: { $0.id == toAccountID }),
                       toCard.type.isLiability, toCard.debt > 0.004 {
                        let fullDebt = (toCard.debt * 100).rounded() / 100
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            amountText = String(format: "%.2f", fullDebt)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                Text("全额还款 \(Money.format(fullDebt))")
                                    .font(theme.labelFont.weight(.semibold))
                                Spacer()
                                Text("点此填入")
                                    .font(theme.labelFont)
                            }
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.accent.opacity(0.1)))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("repay-full")
                    }
                }
            }
            .padding(.top, 2)

            if record != nil {
                ThemedDashedRule()
                    .padding(.top, 2)
                HStack(spacing: 8) {
                    if kind.countsInStats {
                        NavigationLink {
                            RecurringEditorView(rule: nil, template: record)
                        } label: {
                            Text("↻ 设为周期账单")
                                .font(theme.labelFont)
                                .foregroundStyle(theme.ink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 6).fill(theme.paper))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.rule, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Text("🗑 撕毁作废")
                            .font(theme.labelFont.weight(.semibold))
                            .foregroundStyle(theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.accent.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cashier-delete")
                }
            }
        }
        .padding(16)
        .receiptSurface(theme, hero: true, slot: true)
    }

    private func typeTab(_ title: String, _ k: RecordKind) -> some View {
        Button {
            withAnimation(.snappy) {
                kind = k
                if k != .expense { note = note == "精品手冲咖啡" ? "" : note }
            }
        } label: {
            Text(title)
                .font(theme.serifLabelFont)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .foregroundStyle(kind == k ? theme.accent : theme.faint)
                .background(RoundedRectangle(cornerRadius: 3).fill(kind == k ? theme.cardFill : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(kind == k ? theme.accent.opacity(0.55) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Keypad

    private var keypad: some View { keypadFixed }

    /// 4×4 机械收银键盘（针对 iPhone 15 Pro Max 拇指热区优化）：右下「吐纸入账」跨两行，上方附带算式快捷条
    private var keypadFixed: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                operatorBtn("+", label: "＋ 加")
                operatorBtn("-", label: "－ 减")
                operatorBtn("C", label: "C 清空")
                if record == nil {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        stampSave(keepOpen: true)
                    } label: {
                        Text("🔁 保存并再记")
                            .font(theme.labelFont.weight(.semibold))
                            .foregroundStyle(canStamp ? theme.accent : theme.faint)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 5).fill(theme.cardFill))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(canStamp ? theme.accent.opacity(0.55) : theme.rule, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStamp)
                    .accessibilityIdentifier("cashier-save-next")
                }
            }
            HStack(spacing: 7) {
                keyBtn("1"); keyBtn("2"); keyBtn("3"); keyBtn("⌫")
            }
            HStack(spacing: 7) {
                keyBtn("4"); keyBtn("5"); keyBtn("6")
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.snappy) {
                        submode = .ocr
                        editingField = nil
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text("📷 识图").font(theme.serifLabelFont)
                        Text(detectedReceipts.count > 1 ? "\(detectedReceipts.count)笔待入" : "截屏入账")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [theme.cardFill, theme.paper], startPoint: .top, endPoint: .bottom))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
                    .shadow(color: theme.rule, radius: 0, y: 2)
                }
                .buttonStyle(.plain)
                .frame(width: 84)
            }
            HStack(alignment: .top, spacing: 7) {
                VStack(spacing: 7) {
                    HStack(spacing: 7) { keyBtn("7"); keyBtn("8"); keyBtn("9") }
                    HStack(spacing: 7) { keyBtn("00"); keyBtn("0"); keyBtn(".") }
                }
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    stampSave()
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "printer.dotmatrix")
                            .font(.system(size: 14, weight: .semibold))
                        Text(record != nil ? "盖章" : "吐纸").font(theme.serifTitleFont)
                        Text(record != nil ? "修订" : "入账").font(theme.serifTitleFont)
                    }
                    .foregroundStyle(theme.paper)
                    .frame(maxWidth: .infinity)
                    .frame(height: 111)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.accent))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: theme.accent.opacity(0.42), radius: 0, y: 2.5)
                    .shadow(color: theme.accent.opacity(0.28), radius: 5, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(!canStamp)
                .opacity(canStamp ? 1 : 0.55)
                .accessibilityIdentifier("cashier-feed")
                .frame(width: 84)
            }
        }
    }

    private func operatorBtn(_ key: String, label: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            pressKey(key)
        } label: {
            Text(label)
                .font(theme.labelFont.weight(.semibold))
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.rule, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cashier-op-\(key)")
    }

    private func keyBtn(_ key: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            pressKey(key)
        } label: {
            Text(key)
                .font(theme.amountFont(18))
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [theme.cardFill, theme.paper], startPoint: .top, endPoint: .bottom))
                )
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.rule, lineWidth: 1))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.white.opacity(theme.scheme == .dark ? 0.06 : 0.65))
                        .frame(height: 1)
                        .padding(.horizontal, 2)
                }
                .shadow(color: theme.rule, radius: 0, y: 2)
                .shadow(color: .black.opacity(0.06), radius: 2, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - OCR voucher

    private var ocrSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SHORTCUTS OCR VOUCHER")
                        .font(theme.labelFont)
                        .foregroundStyle(theme.faint)
                        .tracking(1.2)
                    Text(hasOCRResult ? "识别到 1 笔，确认无误即盖章：" : "选择支付截图开始识别（支持多选）")
                        .font(theme.sectionTitleFont)
                        .foregroundStyle(theme.ink)
                }
                Spacer()
                PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images, photoLibrary: .shared()) {
                    Text(isRecognizing ? "识别中…" : "↻ 重扫")
                        .font(theme.labelFont)
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.rule, lineWidth: 1))
                }
                .disabled(isRecognizing)
                .accessibilityIdentifier("cashier-ocr-rescan")
            }

            if hasOCRResult {
                HStack {
                    Text("1")
                        .font(theme.labelFont.weight(.bold))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(theme.accent.opacity(0.12)))
                    Button { beginEdit(.type) } label: {
                        Text(kind == .income ? "收入" : (kind == .transfer ? "转账" : "支出"))
                            .font(theme.metaFont)
                            .foregroundStyle(theme.faint)
                            
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { beginEdit(.amount) } label: {
                        Text(kind == .income ? displayAmount : "-\(displayAmount)")
                            .font(theme.heroAmountFont)
                            .monospacedDigit()
                            .foregroundStyle(theme.ink)
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Button { beginEdit(.merchant) } label: {
                        HStack(spacing: 6) {
                            Text(merchant.isEmpty ? "商户" : merchant)
                                .font(theme.sectionTitleFont)
                                .foregroundStyle(theme.ink)
                            Text("✎ 点此微调")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.faint)
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 3).fill(theme.rule.opacity(0.35)))
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(ocrEngineLine?.contains("规则") == true ? "OCR 规则识别" : "OCR")
                        .font(theme.labelFont)
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.accent.opacity(0.5), lineWidth: 1))
                }

                editorIf(.type)
                editorIf(.amount)
                editorIf(.merchant)

                voucherRow("时间", DateText.monthDayTime.string(from: date), field: .time)
                editorIf(.time)
                if let ocrTimeHint {
                    Button { beginEdit(.time) } label: {
                        HStack(spacing: 6) {
                            Text("⚠ " + ocrTimeHint)
                                .font(theme.labelFont)
                            Spacer()
                            Text("点击校准 ▾")
                                .font(theme.labelFont)
                                .underline()
                        }
                        .foregroundStyle(theme.caution)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.caution.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.caution.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                }
                if kind == .transfer {
                    voucherRow("转出", selectedAccount?.name ?? "未选账户", field: .account, menu: true)
                    editorIf(.account)
                    voucherRow("转入", selectableAccounts.first { $0.id == toAccountID }?.name ?? "选择账户", field: .toAccount, menu: true)
                    editorIf(.toAccount)
                    let parsedFee = Double(feeText) ?? 0
                    voucherRow("手续费", parsedFee > 0 ? Money.format(parsedFee) : "免手续费", field: .fee)
                    editorIf(.fee)
                } else {
                    voucherRow("账户", selectedAccount?.name ?? "未选账户", field: .account, menu: true)
                    editorIf(.account)
                    voucherRow("分类", selectedCategory?.name ?? "未分类", field: .category, menu: true)
                    editorIf(.category)
                }
                voucherRow("备注", note.isEmpty ? "无（点此添加）" : note, field: .note)
                editorIf(.note)

                FoldCrease()
                    .padding(.horizontal, -14)

                HStack {
                    Text("\(kind.title)合计（1 笔）")
                        .font(theme.metaFont)
                        .foregroundStyle(theme.faint)
                    Spacer()
                    Text(displayAmount)
                        .font(theme.rowAmountFont)
                        .foregroundStyle(theme.accent)
                }

                if let ocrEngineLine {
                    Text(ocrEngineLine)
                        .font(theme.labelFont)
                        .foregroundStyle(theme.faint)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.rule.opacity(0.25)))
                }

                Button { stampSave(fromOCR: true) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                        Text("确认无误 · 盖章保存")
                            .font(theme.metaFont.weight(.semibold))
                        Text(displayAmount)
                            .font(theme.labelFont)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.2)))
                    }
                    .foregroundStyle(theme.paper)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(theme.accent))
                }
                .buttonStyle(.plain)
                .disabled(!canStamp)
                .accessibilityIdentifier("cashier-stamp")

                HStack(spacing: 6) {
                    paperBtn("✎ 修改票面") { beginEdit(.merchant) }
                    paperBtn("＋ 手记一笔") {
                        withAnimation {
                            submode = .manual
                            editingField = nil
                        }
                    }
                    paperBtn("🗑 删除这笔") {
                        hasOCRResult = false
                        amountText = ""
                        feeText = ""
                        merchant = ""
                        photoItems = []
                    }
                }
            } else {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images, photoLibrary: .shared()) {
                    VStack(spacing: 10) {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 28))
                            .foregroundStyle(theme.accent)
                        Text(isRecognizing ? "正在识别…" : "选择支付截图识别（可多选最多 10 张）")
                            .font(theme.metaFont)
                            .foregroundStyle(theme.ink)
                        Text("在本机识别；优惠文案不作标题；取实付；退款记收入；时间未识别用截图时间兜底。")
                            .font(theme.labelFont)
                            .foregroundStyle(theme.faint)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
                .disabled(isRecognizing)
                .accessibilityIdentifier("cashier-ocr-picker")
            }
        }
        .padding(14)
        .receiptSurface(theme, hero: true, slot: true)
    }

    private func voucherRow(_ title: String, _ value: String, field: InlineField, menu: Bool = false) -> some View {
        Button {
            if menu { toggleMenu(field) } else { beginEdit(field) }
        } label: {
            HStack {
                Text(title).font(theme.metaFont).foregroundStyle(theme.faint)
                DotLeader(color: theme.rule)
                Text(menu ? "\(value) ▾" : value)
                    .font(theme.metaFont)
                    .foregroundStyle(editingField == field ? theme.accent : theme.ink)
            }
        }
        .buttonStyle(.plain)
    }

    private func paperBtn(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(theme.labelFont)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.rule, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func editorIf(_ field: InlineField) -> some View {
        if editingField == field {
            inlineEditor(field)
        }
    }

    @ViewBuilder
    private func inlineEditor(_ field: InlineField) -> some View {
        switch field {
        case .category:
            categoryDrawer
        case .account:
            accountDrawer(
                title: kind == .income ? "选择入账账户" : (kind == .transfer ? "选择转出账户" : "选择扣款账户"),
                current: accountID
            ) { id in
                accountID = id
                accountTouched = true
                if toAccountID == id { toAccountID = nil }
            }
        case .toAccount:
            accountDrawer(title: "选择转入账户", current: toAccountID) { id in
                toAccountID = id
            }
        default:
            textEditor(field)
        }
    }

    private func textEditor(_ field: InlineField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(editorTitle(field))
                .font(theme.labelFont)
                .foregroundStyle(theme.accent)
            switch field {
            case .amount:
                TextField("金额", text: $inlineDraft)
                    .keyboardType(.decimalPad)
                    .font(theme.rowAmountFont)
                HStack(spacing: 6) {
                    ForEach([11.11, 19.90, 28.00, 66.00], id: \.self) { val in
                        Button {
                            inlineDraft = String(format: "%.2f", val)
                        } label: {
                            Text(String(format: "¥%.2f", val))
                                .font(theme.labelFont)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 4).fill(theme.paper))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.rule, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            case .merchant:
                TextField("商户 / 收付款方", text: $inlineDraft)
                    .font(theme.metaFont)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestedMerchants, id: \.self) { m in
                            Button {
                                inlineDraft = m
                            } label: {
                                Text(m)
                                    .font(theme.labelFont)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.paper))
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.rule, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            case .note:
                TextField("项目内容 / 优惠备注", text: $inlineDraft)
                    .font(theme.metaFont)
            case .fee:
                TextField("手续费（元，选填）", text: $inlineDraft)
                    .keyboardType(.decimalPad)
                    .font(theme.rowAmountFont)
            case .type:
                Picker("类型", selection: $kind) {
                    Text("支出").tag(RecordKind.expense)
                    Text("收入").tag(RecordKind.income)
                    Text("转账").tag(RecordKind.transfer)
                }
                .pickerStyle(.segmented)
            case .time:
                DatePicker("时间", selection: $date)
                HStack(spacing: 6) {
                    Button("按现在") { date = Date(); ocrTimeHint = nil }
                        .font(theme.labelFont).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(theme.paper))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.rule, lineWidth: 1))
                    Button("今天下午") {
                        let cal = Calendar.current
                        date = cal.date(bySettingHour: 16, minute: 51, second: 0, of: Date()) ?? Date()
                        ocrTimeHint = nil
                    }
                    .font(theme.labelFont).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.paper))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.rule, lineWidth: 1))
                    Button("昨天晚间") {
                        let cal = Calendar.current
                        if let yest = cal.date(byAdding: .day, value: -1, to: Date()) {
                            date = cal.date(bySettingHour: 21, minute: 0, second: 0, of: yest) ?? Date()
                            ocrTimeHint = nil
                        }
                    }
                    .font(theme.labelFont).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.paper))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.rule, lineWidth: 1))
                }
                .buttonStyle(.plain)
            default:
                EmptyView()
            }
            HStack {
                Button("收起") { editingField = nil }
                Spacer()
                Button("确定") { applyInline(); editingField = nil }
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.accent)
            }
            .font(theme.metaFont)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.rule.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.accent.opacity(0.4), lineWidth: 1))
    }

    /// 分类、账户共用的纸签下拉：点一项即选定并收起，和识图票面同一套
    private func choiceDrawer<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(theme.labelFont.weight(.semibold))
                    .foregroundStyle(theme.accent)
                Spacer()
                Button("收起") { editingField = nil }
                    .font(theme.labelFont)
                    .foregroundStyle(theme.faint)
            }
            content()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.rule.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
    }

    private var categoryDrawer: some View {
        choiceDrawer(title: "切换账单分类") {
            if categories.isEmpty {
                Text("还没有\(kind.title)分类，请先在设置里添加。")
                    .font(theme.metaFont)
                    .foregroundStyle(theme.faint)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(categories) { c in
                        let selected = c.id == selectedCategory?.id
                        Button { pickCategory(c) } label: {
                            Text(c.name)
                                .font(theme.labelFont)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .foregroundStyle(selected ? theme.accent : theme.ink)
                                .background(RoundedRectangle(cornerRadius: 6).fill(theme.paper))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(selected ? theme.accent : theme.rule, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("cashier-category-option")
                    }
                }
            }
        }
    }

    private func accountDrawer(title: String, current: UUID?, onPick: @escaping (UUID) -> Void) -> some View {
        choiceDrawer(title: title) {
            if selectableAccounts.isEmpty {
                Text("还没有账户，请先在「资产」页添加。")
                    .font(theme.metaFont)
                    .foregroundStyle(theme.faint)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(selectableAccounts) { a in
                            let selected = a.id == current
                            Button {
                                onPick(a.id)
                                editingField = nil
                            } label: {
                                HStack {
                                    Text(a.name)
                                    Spacer(minLength: 8)
                                    if selected {
                                        Text("✓ 当前")
                                            .foregroundStyle(theme.accent)
                                    }
                                }
                                .font(theme.labelFont)
                                .foregroundStyle(theme.ink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6).fill(theme.paper))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(selected ? theme.accent : theme.rule, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("cashier-account-option")
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private func editorTitle(_ field: InlineField) -> String {
        switch field {
        case .amount: return "校准金额"
        case .merchant: return "修改商户 / 收付款方"
        case .note: return "修改项目内容 / 备注"
        case .fee: return "设置转账 / 提现手续费"
        case .type: return "切换收支方向"
        case .time: return "校准交易时间"
        case .category: return "切换账单分类"
        case .account: return "选择账户"
        case .toAccount: return "选择转入账户"
        }
    }

    private var approvedStampOverlay: some View {
        ZStack {
            Color.black.opacity(0.08).ignoresSafeArea()
            VStack(spacing: 4) {
                Text("JIANZHANG LEDGER")
                    .font(theme.labelFont)
                    .tracking(2)
                Text("已核准入账")
                    .font(theme.sectionTitleFont.weight(.bold))
                Text("APPROVED · \(Self.approvedDateLabel())")
                    .font(theme.labelFont)
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.paper.opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.accent, lineWidth: 2))
            .rotationEffect(.degrees(-8))
            .shadow(radius: 8)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Helpers

    private static func approvedDateLabel() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy.MM.dd"
        return f.string(from: Date())
    }

    private var displayAmount: String {
        if let a = parsedAmount { return Money.format(a) }
        if amountText.isEmpty { return "¥0.00" }
        return "¥" + amountText
    }

    private func bootstrapDefaults() {
        let defaultAcc = (defaultAccount.isEmpty ? nil : defaultAccount).flatMap { name in
            selectableAccounts.first(where: { $0.name == name })
        } ?? selectableAccounts.first

        if let record {
            kind = record.kind
            amountText = String(format: "%.2f", record.amount)
            feeText = record.fee > 0 ? String(format: "%.2f", record.fee) : ""
            date = record.date
            note = record.note
            merchant = record.merchant
            selectedCategoryID = record.category?.id
            accountID = record.accountRef?.id ?? selectableAccounts.first(where: { $0.name == record.account })?.id ?? defaultAcc?.id
            toAccountID = record.toAccount?.id
            source = record.source
            recurringKey = record.recurringKey
            accountTouched = true
            return
        }

        if let p = prefill {
            kind = p.kind
            amountText = p.amount > 0 ? String(format: "%.2f", p.amount) : ""
            date = p.date
            note = p.note
            merchant = p.merchant
            accountID = p.accountID ?? defaultAcc?.id
            toAccountID = p.toAccountID
            selectedCategoryID = p.categoryID ?? allCategories.first(where: { $0.kind == (p.kind.countsInStats ? p.kind : .expense) })?.id
            recurringKey = p.recurringKey
            source = p.recurringKey.isEmpty ? "manual" : "recurring"
            accountTouched = true
            return
        }

        if let repayCardID {
            kind = .transfer
            toAccountID = repayCardID
            merchant = "信用卡还款"
            let payers = selectableAccounts.filter { !$0.type.isLiability && !$0.type.isSocialSecurity && $0.id != repayCardID }
            accountID = (payers.first(where: { $0.name == defaultAccount })
                ?? payers.first(where: { $0.type == .debit })
                ?? payers.first)?.id
            accountTouched = true
            if let card = selectableAccounts.first(where: { $0.id == repayCardID }), card.debt > 0.004 {
                amountText = String(format: "%.2f", (card.debt * 100).rounded() / 100)
            }
            return
        }

        kind = initialKind
        selectedCategoryID = categories.first?.id
        if let presetAccountID {
            if kind == .transfer, let target = selectableAccounts.first(where: { $0.id == presetAccountID }), target.type.isLiability {
                toAccountID = presetAccountID
                merchant = "信用卡还款"
                let payers = selectableAccounts.filter { !$0.type.isLiability && !$0.type.isSocialSecurity && $0.id != presetAccountID }
                accountID = (payers.first(where: { $0.name == defaultAccount })
                    ?? payers.first(where: { $0.type == .debit })
                    ?? payers.first)?.id
            } else {
                accountID = presetAccountID
            }
            accountTouched = true
        } else {
            let firstCategory = allCategories.first(where: { $0.id == selectedCategoryID })
            accountID = (kind.countsInStats ? RuleStore.lastAccount(for: firstCategory, in: context)?.id : nil)
                ?? defaultAcc?.id
        }

        if ScreenshotDemo.isActive, amountText.isEmpty {
            if ScreenshotDemo.screen == "addocr" || startInOCRMode {
                // 设计稿 OCR 凭条样例（合成）
                hasOCRResult = true
                submode = .ocr
                kind = .expense
                amountText = "11.11"
                merchant = "一起"
                note = ""
                ocrEngineLine = "共 1 笔 · 引擎规则 · Apple 智能未给出有效结果，已用规则识别"
                ocrTimeHint = "时间未识别（已用当前时间），点此校准"
                if let c = categories.first(where: { $0.name == "购物" }) { selectedCategoryID = c.id }
                if let a = selectableAccounts.first(where: { $0.name.contains("浦发") || $0.name.contains("信用") }) {
                    accountID = a.id
                }
            } else {
                amountText = "35.00"
                note = "精品手冲咖啡"
                if let c = categories.first(where: { $0.name == "餐饮" }) { selectedCategoryID = c.id }
                if let a = selectableAccounts.first(where: { $0.name.contains("招行信用") }) { accountID = a.id }
            }
        }
    }

    private func pressKey(_ key: String) {
        if key == "C" {
            amountText = ""
            return
        }
        if key == "⌫" {
            if !amountText.isEmpty { amountText.removeLast() }
            return
        }
        if key == "+" || key == "-" {
            if amountText.isEmpty { return }
            if let last = amountText.last, last == "+" || last == "-" || last == "." {
                amountText.removeLast()
            }
            amountText.append(key)
            return
        }
        if key == "." {
            let currentSegment = amountText.split(whereSeparator: { $0 == "+" || $0 == "-" }).last.map(String.init) ?? ""
            if currentSegment.contains(".") { return }
            amountText += currentSegment.isEmpty ? "0." : "."
            return
        }
        if key == "00" {
            if amountText.isEmpty { amountText = "0" }
            else { amountText += "00" }
            trimAmount()
            return
        }
        amountText += key
        trimAmount()
    }

    private func trimAmount() {
        var rebuilt = ""
        var afterDotCount: Int? = nil
        for ch in amountText {
            if ch == "+" || ch == "-" {
                afterDotCount = nil
                rebuilt.append(ch)
            } else if ch == "." {
                if afterDotCount == nil {
                    afterDotCount = 0
                    rebuilt.append(ch)
                }
            } else if let c = afterDotCount {
                if c < 2 {
                    afterDotCount = c + 1
                    rebuilt.append(ch)
                }
            } else {
                rebuilt.append(ch)
            }
        }
        if rebuilt.count > 20 { rebuilt = String(rebuilt.prefix(20)) }
        amountText = rebuilt
    }

    private func toggleMenu(_ field: InlineField) {
        withAnimation(.snappy) {
            editingField = editingField == field ? nil : field
        }
    }

    private func pickCategory(_ category: LedgerCategory) {
        selectedCategoryID = category.id
        if note == "精品手冲咖啡", category.name != "餐饮" { note = "" }
        if !accountTouched, let account = RuleStore.lastAccount(for: category, in: context) {
            accountID = account.id
        }
        editingField = nil
    }

    private func beginEdit(_ field: InlineField) {
        editingField = field
        switch field {
        case .amount: inlineDraft = amountText
        case .merchant: inlineDraft = merchant
        case .note: inlineDraft = note
        case .fee: inlineDraft = feeText
        default: inlineDraft = ""
        }
    }

    private func applyInline() {
        switch editingField {
        case .amount:
            amountText = inlineDraft.replacingOccurrences(of: "¥", with: "").replacingOccurrences(of: ",", with: "")
        case .merchant:
            merchant = inlineDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if kind.countsInStats, !merchant.isEmpty,
               let hit = RuleStore.match(merchant: merchant, text: note, kind: kind, in: context, countHit: false) {
                if let c = hit.category, c.kind == kind { selectedCategoryID = c.id }
                if !accountTouched, let a = hit.account ?? RuleStore.lastAccount(for: hit.category, in: context) {
                    accountID = a.id
                }
            }
        case .note:
            note = inlineDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        case .fee:
            feeText = inlineDraft.replacingOccurrences(of: "¥", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        default: break
        }
    }

    private func close() {
        if let onDismiss { onDismiss() } else { dismiss() }
    }

    private func stampSave(fromOCR: Bool = false, keepOpen: Bool = false) {
        guard canStamp, let amount = parsedAmount else {
            alertMessage = "请输入有效金额"
            return
        }
        let cat = kind == .transfer ? nil : selectedCategory
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMerchant = kind == .transfer ? (merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "转账" : merchant.trimmingCharacters(in: .whitespacesAndNewlines)) : (kind.countsInStats ? merchant.trimmingCharacters(in: .whitespacesAndNewlines) : "")
        let fromAccount = selectedAccount
        let toAccount: LedgerAccount? = kind == .transfer ? selectableAccounts.first { $0.id == toAccountID } : nil
        let feeVal: Double = kind == .transfer ? max(0, Double(feeText) ?? 0) : 0

        let categoryChanged = record == nil || record?.category?.id != cat?.id || record?.accountRef?.id != fromAccount?.id
        if kind.countsInStats, !trimmedMerchant.isEmpty, categoryChanged {
            RuleStore.learn(merchant: trimmedMerchant, kind: kind, category: cat, account: fromAccount, in: context)
        }
        if kind.countsInStats { RuleStore.rememberAccount(fromAccount, for: cat) }

        let isOCR = fromOCR || submode == .ocr || source == "ocr"
        if let record {
            record.amount = amount
            record.kind = kind
            record.category = cat
            record.note = trimmedNote
            record.merchant = trimmedMerchant
            record.account = fromAccount?.name ?? ""
            record.accountRef = fromAccount
            record.toAccount = toAccount
            record.fee = feeVal
            record.date = date
        } else {
            let rec = LedgerRecord(amount: amount, kind: kind, category: cat,
                                   note: trimmedNote, merchant: trimmedMerchant,
                                   account: fromAccount?.name ?? "", date: date,
                                   source: isOCR ? "ocr" : source)
            rec.recurringKey = recurringKey
            rec.accountRef = fromAccount
            if kind == .transfer {
                rec.toAccount = toAccount
                rec.fee = feeVal
            }
            context.insert(rec)
        }
        if let tail = ocrAccountTail, let acc = fromAccount, !SessionManager.shared.isDecoy {
            if acc.cardTail.isEmpty { acc.cardTail = tail }
        }
        do {
            try context.save()
            if isOCR {
                CardTailMemory.learn(tail: ocrAccountTail, accountID: fromAccount?.id)
                if kind == .transfer { CardTailMemory.learn(tail: ocrCardTail, accountID: toAccount?.id) }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            BudgetMonitor.check(in: context)
            if keepOpen {
                savedCountInSession += 1
                amountText = ""
                feeText = ""
                note = ""
                merchant = ""
                return
            }
            if fromOCR || submode == .ocr {
                withAnimation(.spring) { showApprovedStamp = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { close() }
            } else {
                close()
            }
        } catch {
            alertMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Recognize (same rules as RecordEditorView, supports multi-photo batch)

    @MainActor
    private func recognizeBatch(_ items: [PhotosPickerItem]) async {
        isRecognizing = true
        defer {
            isRecognizing = false
            photoItems = []
        }
        let vocab = DataStore.ocrVocabulary(categories: allCategories, accounts: allAccounts, isDecoy: SessionManager.shared.isDecoy)
        var allFound: [ParsedReceipt] = []
        var firstRaw: [ParsedReceipt] = []
        var lastEngineLine: String? = nil

        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let started = Date()
                let capture = ScreenshotTime.capture(data: data, assetIdentifier: item.itemIdentifier, now: started)
                let reference = CaptureTime.reference(capture: capture, now: started)
                let recognition = try await ReceiptRecognizer.recognizeDetailed(imageData: data, now: reference, vocabulary: vocab)
                lastEngineLine = recognition.engineLine
                let fb = CaptureTime.fallback(capture: capture, statusBar: recognition.statusBarClock,
                                              now: Date(), calendar: .current)
                ocrReference = reference
                ocrFallback = fb
                let valid = recognition.receipts.filter { ($0.amount ?? 0) > 0 }.map { r -> ParsedReceipt in
                    var copy = r
                    if copy.date == nil {
                        let resolved = CaptureTime.resolve(recognized: nil, reference: reference, fallback: fb)
                        if resolved.source != .now { copy.date = resolved.date }
                    }
                    return copy
                }
                allFound.append(contentsOf: valid)
                if firstRaw.isEmpty { firstRaw = recognition.receipts }
            } catch {
                alertMessage = "识别失败：\(error.localizedDescription)"
            }
        }

        if items.count > 1 {
            ocrEngineLine = "已选 \(items.count) 张截图 · 识别到 \(allFound.count) 笔" + (lastEngineLine.map { " · " + $0 } ?? "")
        } else {
            ocrEngineLine = lastEngineLine
        }
        detectedReceipts = allFound.isEmpty ? firstRaw : allFound
        if allFound.count > 1 {
            showReceiptPicker = true
        } else if let single = allFound.first ?? firstRaw.first {
            applyParsed(single)
        } else {
            alertMessage = "未识别到有效交易金额"
        }
    }

    @MainActor
    private func applyParsed(_ parsed: ParsedReceipt) {
        guard let amount = parsed.amount else {
            alertMessage = "没有识别到金额，请手动填写或点字段微调"
            hasOCRResult = true
            return
        }
        amountText = String(format: "%.2f", amount)
        feeText = (parsed.fee ?? 0) > 0 ? String(format: "%.2f", parsed.fee!) : ""
        let fallback = ocrFallback ?? CaptureTime(date: date, source: .now)
        let t = CaptureTime.resolve(recognized: parsed.date, reference: ocrReference ?? Date(), fallback: fallback)
        if t.source != .now { date = t.date }
        ocrTimeHint = t.source == .now ? "时间未识别（已用当前时间），点此校准" : t.source.hint

        if parsed.isCardRepayment {
            kind = .transfer
            merchant = "信用卡还款"
            note = parsed.discountNote ?? ""
            let card = DataStore.account(matching: parsed.repaymentCard ?? AccountHint(type: "credit"),
                                         modelName: parsed.repaymentCardName, role: .card, in: context)
            if let card, card.type.isLiability {
                toAccountID = card.id
            } else {
                let active = selectableAccounts.filter { $0.type.isLiability }
                toAccountID = (active.first(where: { $0.type.hasCreditLimit && $0.debt > 0 })
                    ?? active.first(where: { $0.type.hasCreditLimit }) ?? active.first)?.id
            }
            if let payer = DataStore.account(matching: parsed.accountHint, modelName: parsed.accountName, role: .payer,
                                             excluding: toAccountID, in: context) {
                accountID = payer.id
            } else if accountID == nil || accountID == toAccountID
                        || selectableAccounts.first(where: { $0.id == accountID })?.type.isLiability == true {
                let payers = selectableAccounts.filter { !$0.type.isLiability && !$0.type.isSocialSecurity && $0.id != toAccountID }
                accountID = (payers.first(where: { $0.name == defaultAccount })
                    ?? payers.first(where: { $0.type == .debit }) ?? payers.first)?.id
            }
            ocrAccountTail = parsed.accountHint?.cardTail
            ocrCardTail = parsed.repaymentCard?.cardTail
            source = "ocr"
            hasOCRResult = true
            submode = .ocr
            return
        }

        if parsed.isSelfTransfer {
            kind = .transfer
            merchant = parsed.transferNote ?? "转账"
            note = [parsed.transferNote, parsed.discountNote].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let from = DataStore.account(matching: parsed.transferFrom, modelName: parsed.transferFromName, role: .single, in: context)
            let to = DataStore.account(matching: parsed.transferTo, modelName: parsed.transferToName, role: .single,
                                       excluding: from?.id, in: context)
            if let from { accountID = from.id }
            toAccountID = to?.id == accountID ? nil : to?.id
            ocrAccountTail = parsed.transferFrom?.cardTail
            ocrCardTail = parsed.transferTo?.cardTail
            source = "ocr"
            hasOCRResult = true
            submode = .ocr
            return
        }

        // 识图规则：实付金额；退款→收入；项目内容与优惠文案进备注非标题；时间兜底
        kind = parsed.isIncome ? .income : .expense
        merchant = parsed.merchant ?? ""
        note = parsed.discountNote ?? ""
        let list = categories
        let hit = RuleStore.match(merchant: parsed.merchant ?? "", text: parsed.discountNote ?? "", kind: kind, in: context, countHit: false)
        if let c = hit?.category, c.kind == kind {
            selectedCategoryID = c.id
        } else if let name = parsed.categoryName, let c = list.first(where: { $0.name == name }) {
            selectedCategoryID = c.id
        } else {
            selectedCategoryID = list.first?.id
        }
        ocrAccountTail = parsed.accountHint?.cardTail
        ocrCardTail = nil
        if let a = DataStore.account(matching: parsed.accountHint, modelName: parsed.accountName, role: .single, in: context)
            ?? selectableAccounts.first(where: { $0.name == (parsed.accountName ?? "") })
            ?? hit?.account {
            accountID = a.id
            accountTouched = true
        }
        source = "ocr"
        hasOCRResult = true
        submode = .ocr
    }

    @MainActor
    private func saveAllDetectedReceipts() {
        let valid = detectedReceipts.filter { ($0.amount ?? 0) > 0 }
        guard !valid.isEmpty else { return }
        let saved = RecordEditorView.batchInsert(
            receipts: valid,
            reference: ocrReference ?? Date(),
            fallback: ocrFallback ?? CaptureTime(date: date, source: .now),
            defaultAccountName: defaultAccount,
            allCategories: allCategories,
            selectableAccounts: selectableAccounts,
            in: context
        )
        guard saved > 0 else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        BudgetMonitor.check(in: context)
        withAnimation(.spring) { showApprovedStamp = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { close() }
    }
}
