import SwiftUI
import SwiftData
import PhotosUI

/// 4.2 小票皮肤「记一笔」：设计稿机械收银键盘 + 截屏识图凭条（默认皮肤仍用 RecordEditorView 表单）
struct ReceiptCashierView: View {
    var initialDate: Date = Date()
    var startInOCRMode: Bool = false
    var onDismiss: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Query(sort: \LedgerCategory.sortOrder) private var allCategories: [LedgerCategory]
    @Query(sort: \LedgerAccount.sortOrder) private var allAccounts: [LedgerAccount]
    @AppStorage(SettingsKey.defaultAccount) private var defaultAccount = ""

    private enum Submode: String { case manual, ocr }
    @State private var submode: Submode = .manual
    @State private var kind: RecordKind = .expense
    @State private var amountText = ""
    @State private var note = "精品手冲咖啡"
    @State private var merchant = ""
    @State private var selectedCategoryID: UUID?
    @State private var accountID: UUID?
    @State private var toAccountID: UUID?
    @State private var date = Date()
    @State private var source = "manual"
    @State private var alertMessage: String?
    @State private var showApprovedStamp = false

    // OCR
    @State private var photoItem: PhotosPickerItem?
    @State private var isRecognizing = false
    @State private var ocrEngineLine: String?
    @State private var ocrTimeHint: String?
    @State private var ocrReference: Date?
    @State private var ocrFallback: CaptureTime?
    @State private var ocrAccountTail: String?
    @State private var editingField: InlineField?
    @State private var inlineDraft = ""
    @State private var hasOCRResult = false
    @State private var detectedReceipts: [ParsedReceipt] = []
    @State private var showReceiptPicker = false

    private enum InlineField: String, Identifiable {
        case amount, merchant, type, category, account, time
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
    private var parsedAmount: Double? { Money.parse(amountText) }
    private var canStamp: Bool {
        guard let a = parsedAmount, a > 0 else { return false }
        if kind == .transfer { return accountID != nil && toAccountID != nil && accountID != toAccountID }
        return true
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modeBar
                ScrollView {
                    VStack(spacing: ReceiptStyle.Space.s) {
                        if submode == .manual {
                            manualSheet
                            keypad
                        } else {
                            ocrSheet
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .themedScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { close() }
                        .font(theme.metaFont)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if submode == .manual {
                        Button("保存") { stampSave() }
                            .font(theme.metaFont.weight(.semibold))
                            .foregroundStyle(canStamp ? theme.paper : theme.faint)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(canStamp ? theme.accent : theme.rule.opacity(0.4)))
                            .disabled(!canStamp)
                    } else {
                        EmptyView()
                    }
                }
            }
            .alert("提示", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(alertMessage ?? "") }
            .onAppear {
                if startInOCRMode { submode = .ocr }
                date = initialDate
                bootstrapDefaults()
                AppleIntelligenceExtractor.prewarm()
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await recognize(item) }
            }
            .onChange(of: kind) { _, _ in
                if !categories.contains(where: { $0.id == selectedCategoryID }) {
                    selectedCategoryID = categories.first?.id
                }
            }
            .confirmationDialog("识别到 \(detectedReceipts.count) 笔，选择一笔", isPresented: $showReceiptPicker, titleVisibility: .visible) {
                ForEach(Array(detectedReceipts.enumerated()), id: \.offset) { _, r in
                    Button(RecordEditorView.receiptTitle(r)) { applyParsed(r) }
                }
                Button("取消", role: .cancel) {}
            }
            .overlay {
                if showApprovedStamp {
                    approvedStampOverlay
                }
            }
        }
    }

    // MARK: - Top mode bar

    private var modeBar: some View {
        HStack(spacing: 8) {
            modeChip("⌨️ 手工记一笔", .manual)
            modeChip("📷 截屏识图", .ocr, badge: hasOCRResult || submode == .ocr ? nil : "1")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.paper.opacity(0.95))
    }

    private func modeChip(_ title: String, _ mode: Submode, badge: String? = nil) -> some View {
        Button {
            withAnimation(.snappy) { submode = mode }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(theme.labelFont)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.paper)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(theme.accent))
                }
            }
            .foregroundStyle(submode == mode ? theme.accent : theme.faint)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                Capsule().fill(submode == mode ? theme.paper : theme.rule.opacity(0.25))
            )
            .overlay(
                Capsule().strokeBorder(submode == mode ? theme.accent.opacity(0.55) : theme.rule, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(mode == .manual ? "cashier-mode-manual" : "cashier-mode-ocr")
    }

    // MARK: - Manual sheet

    private var manualSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 支出联 / 收入联 / 转账联
            HStack(spacing: 4) {
                typeTab("支出联", .expense)
                typeTab("收入联", .income)
                typeTab("转账联", .transfer)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.rule.opacity(0.35)))

            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(theme.accent.opacity(0.12))
                    Image(systemName: selectedCategory?.icon ?? "fork.knife")
                        .foregroundStyle(theme.accent)
                }
                .frame(width: 40, height: 40)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.accent.opacity(0.4), lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedCategory?.name ?? "分类")
                        .font(theme.sectionTitleFont)
                        .foregroundStyle(theme.ink)
                    TextField("输入摘要备注…", text: $note)
                        .font(theme.metaFont)
                        .foregroundStyle(theme.faint)
                        .textFieldStyle(.plain)
                }
                Spacer(minLength: 8)
                Text(displayAmount)
                    .font(theme.heroAmountFont)
                    .monospacedDigit()
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityIdentifier("cashier-amount")
            }
            .padding(.bottom, 6)
            ThemedDashedRule()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(quickCategories, id: \.name) { item in
                        let selected = selectedCategory?.name == item.name
                        Button {
                            selectQuick(item)
                        } label: {
                            Text(item.name)
                                .font(theme.labelFont)
                                .foregroundStyle(selected ? theme.accent : theme.ink)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(theme.paper))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? theme.accent : theme.rule, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(spacing: 8) {
                HStack {
                    Text("时间").font(theme.metaFont).foregroundStyle(theme.faint)
                    Spacer()
                    Text(DateText.full.string(from: date))
                        .font(theme.metaFont).monospacedDigit()
                        .foregroundStyle(theme.ink)
                }
                HStack {
                    Text("账户").font(theme.metaFont).foregroundStyle(theme.faint)
                    Spacer()
                    Button { cycleAccount() } label: {
                        HStack(spacing: 4) {
                            Text(selectedAccount?.name ?? "未选账户")
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .font(theme.labelFont)
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.paper))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.rule, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cashier-account")
                }
                if kind == .transfer {
                    HStack {
                        Text("转入").font(theme.metaFont).foregroundStyle(theme.faint)
                        Spacer()
                        Button { cycleToAccount() } label: {
                            Text(selectableAccounts.first { $0.id == toAccountID }?.name ?? "选择账户")
                                .font(theme.labelFont)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.rule, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(14)
        .receiptSurface(theme, hero: true)
    }

    private func typeTab(_ title: String, _ k: RecordKind) -> some View {
        Button {
            kind = k
            if k != .expense { note = note == "精品手冲咖啡" ? "" : note }
        } label: {
            Text(title)
                .font(theme.labelFont)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .foregroundStyle(kind == k ? theme.accent : theme.faint)
                .background(RoundedRectangle(cornerRadius: 4).fill(kind == k ? theme.paper : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(kind == k ? theme.accent.opacity(0.5) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Keypad

    private var keypad: some View { keypadFixed }

    /// 4×4 收银键盘：右下「吐纸入账」跨两行
    private var keypadFixed: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                keyBtn("1"); keyBtn("2"); keyBtn("3"); keyBtn("⌫")
            }
            HStack(spacing: 6) {
                keyBtn("4"); keyBtn("5"); keyBtn("6")
                Button {
                    withAnimation { submode = .ocr }
                } label: {
                    VStack(spacing: 1) {
                        Text("📷 识图").font(theme.labelFont)
                        Text("1笔待入").font(.system(size: 9))
                    }
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.paper))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 6) {
                    HStack(spacing: 6) { keyBtn("7"); keyBtn("8"); keyBtn("9") }
                    HStack(spacing: 6) { keyBtn("00"); keyBtn("0"); keyBtn(".") }
                }
                Button { stampSave() } label: {
                    VStack(spacing: 4) {
                        Text("吐纸").font(theme.metaFont.weight(.semibold))
                        Text("入账").font(theme.metaFont.weight(.semibold))
                    }
                    .foregroundStyle(theme.paper)
                    .frame(maxWidth: .infinity)
                    .frame(height: 102)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent))
                    .shadow(color: theme.accent.opacity(0.35), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .disabled(!canStamp)
                .opacity(canStamp ? 1 : 0.55)
                .accessibilityIdentifier("cashier-feed")
                .frame(width: 72)
            }
        }
    }

    private func keyBtn(_ key: String) -> some View {
        Button { pressKey(key) } label: {
            Text(key)
                .font(theme.rowAmountFont)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.rule, lineWidth: 1))
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
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
                    Text(hasOCRResult ? "识别到 1 笔，确认无误即盖章：" : "选择支付截图开始识别")
                        .font(theme.sectionTitleFont)
                        .foregroundStyle(theme.ink)
                }
                Spacer()
                PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
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

                if let editingField {
                    inlineEditor(editingField)
                }

                voucherRow("时间", DateText.monthDayTime.string(from: date), field: .time)
                if let ocrTimeHint {
                    Text(ocrTimeHint)
                        .font(theme.labelFont)
                        .foregroundStyle(theme.caution)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.caution.opacity(0.12)))
                }
                voucherRow("账户", selectedAccount?.name ?? "未选账户", field: .account)
                voucherRow("分类", selectedCategory?.name ?? "未分类", field: .category)

                ThemedDashedRule()

                HStack {
                    Text("支出合计（1 笔）")
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
                    paperBtn("＋ 手记一笔") { withAnimation { submode = .manual } }
                    paperBtn("🗑 删除这笔") {
                        hasOCRResult = false
                        amountText = ""
                        merchant = ""
                        photoItem = nil
                    }
                }
            } else {
                PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                    VStack(spacing: 10) {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 28))
                            .foregroundStyle(theme.accent)
                        Text(isRecognizing ? "正在识别…" : "选择支付截图识别")
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
        .receiptSurface(theme, hero: true)
    }

    private func voucherRow(_ title: String, _ value: String, field: InlineField) -> some View {
        Button { beginEdit(field) } label: {
            HStack {
                Text(title).font(theme.metaFont).foregroundStyle(theme.faint)
                DotLeader(color: theme.rule)
                Text(value).font(theme.metaFont).foregroundStyle(theme.ink)
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
    private func inlineEditor(_ field: InlineField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("原位微调 · \(field.rawValue)")
                .font(theme.labelFont)
                .foregroundStyle(theme.accent)
            switch field {
            case .amount:
                TextField("金额", text: $inlineDraft)
                    .keyboardType(.decimalPad)
                    .font(theme.rowAmountFont)
            case .merchant:
                TextField("商户 / 标题", text: $inlineDraft)
                    .font(theme.metaFont)
            case .type:
                Picker("类型", selection: $kind) {
                    Text("支出").tag(RecordKind.expense)
                    Text("收入").tag(RecordKind.income)
                    Text("转账").tag(RecordKind.transfer)
                }
                .pickerStyle(.segmented)
            case .category:
                Picker("分类", selection: $selectedCategoryID) {
                    ForEach(categories) { c in Text(c.name).tag(Optional(c.id)) }
                }
            case .account:
                Picker("账户", selection: $accountID) {
                    Text("未选").tag(Optional<UUID>.none)
                    ForEach(selectableAccounts) { a in Text(a.name).tag(Optional(a.id)) }
                }
            case .time:
                DatePicker("时间", selection: $date)
            }
            HStack {
                Button("取消") { editingField = nil }
                Spacer()
                Button("应用") { applyInline(); editingField = nil }
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.accent)
            }
            .font(theme.metaFont)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.rule.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.accent.opacity(0.4), lineWidth: 1))
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

    private struct QuickCat { let name: String; let note: String }
    private var quickCategories: [QuickCat] {
        [
            .init(name: "餐饮", note: "精品手冲咖啡"),
            .init(name: "购物", note: "日用百货采购"),
            .init(name: "交通", note: "打车出行"),
            .init(name: "娱乐", note: "电影演出"),
            .init(name: "居住", note: "水电物业")
        ]
    }

    private func selectQuick(_ item: QuickCat) {
        if let c = categories.first(where: { $0.name == item.name }) {
            selectedCategoryID = c.id
        }
        note = item.note
    }

    private func bootstrapDefaults() {
        selectedCategoryID = categories.first?.id
        if let name = defaultAccount.isEmpty ? nil : defaultAccount,
           let a = selectableAccounts.first(where: { $0.name == name }) {
            accountID = a.id
        } else {
            accountID = selectableAccounts.first?.id
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
        if key == "⌫" {
            if !amountText.isEmpty { amountText.removeLast() }
            return
        }
        if key == "." {
            if !amountText.contains(".") { amountText += amountText.isEmpty ? "0." : "." }
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
        if let dot = amountText.firstIndex(of: ".") {
            let decimals = amountText[amountText.index(after: dot)...]
            if decimals.count > 2 {
                amountText = String(amountText.prefix(upTo: amountText.index(dot, offsetBy: 3)))
            }
        }
        if amountText.count > 12 { amountText = String(amountText.prefix(12)) }
    }

    private func cycleAccount() {
        guard !selectableAccounts.isEmpty else { return }
        if let id = accountID, let i = selectableAccounts.firstIndex(where: { $0.id == id }) {
            accountID = selectableAccounts[(i + 1) % selectableAccounts.count].id
        } else {
            accountID = selectableAccounts.first?.id
        }
    }

    private func cycleToAccount() {
        let list = selectableAccounts.filter { $0.id != accountID }
        guard !list.isEmpty else { return }
        if let id = toAccountID, let i = list.firstIndex(where: { $0.id == id }) {
            toAccountID = list[(i + 1) % list.count].id
        } else {
            toAccountID = list.first?.id
        }
    }

    private func beginEdit(_ field: InlineField) {
        editingField = field
        switch field {
        case .amount: inlineDraft = amountText
        case .merchant: inlineDraft = merchant.isEmpty ? note : merchant
        default: inlineDraft = ""
        }
    }

    private func applyInline() {
        switch editingField {
        case .amount:
            amountText = inlineDraft.replacingOccurrences(of: "¥", with: "").replacingOccurrences(of: ",", with: "")
        case .merchant:
            merchant = inlineDraft
            if note.isEmpty { note = inlineDraft }
        default: break
        }
    }

    private func close() {
        if let onDismiss { onDismiss() } else { dismiss() }
    }

    private func stampSave(fromOCR: Bool = false) {
        guard canStamp, let amount = parsedAmount else {
            alertMessage = "请输入有效金额"
            return
        }
        let cat = kind == .transfer ? nil : selectedCategory
        let rec = LedgerRecord(amount: amount, kind: kind, category: cat,
                               note: note, merchant: merchant.isEmpty ? (fromOCR ? merchant : "") : merchant,
                               account: selectedAccount?.name ?? "", date: date,
                               source: fromOCR || submode == .ocr ? "ocr" : source)
        rec.accountRef = selectedAccount
        if kind == .transfer {
            rec.toAccount = selectableAccounts.first { $0.id == toAccountID }
        }
        context.insert(rec)
        if let tail = ocrAccountTail, let acc = selectedAccount, !SessionManager.shared.isDecoy {
            if acc.cardTail.isEmpty { acc.cardTail = tail }
        }
        do {
            try context.save()
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

    // MARK: - Recognize (same rules as RecordEditorView)

    @MainActor
    private func recognize(_ item: PhotosPickerItem) async {
        isRecognizing = true
        defer {
            isRecognizing = false
            photoItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                alertMessage = "无法读取图片"; return
            }
            let vocab = OCRVocabulary(
                expenseCategories: allCategories.filter { $0.kind == .expense }.map(\.name),
                incomeCategories: allCategories.filter { $0.kind == .income }.map(\.name),
                accounts: allAccounts.filter { !$0.isArchived }.map(\.name))
            let started = Date()
            let capture = ScreenshotTime.capture(data: data, assetIdentifier: item.itemIdentifier, now: started)
            let reference = CaptureTime.reference(capture: capture, now: started)
            let recognition = try await ReceiptRecognizer.recognizeDetailed(imageData: data, now: reference, vocabulary: vocab)
            ocrEngineLine = recognition.engineLine
            ocrReference = reference
            ocrFallback = CaptureTime.fallback(capture: capture, statusBar: recognition.statusBarClock,
                                               now: Date(), calendar: .current)
            let all = recognition.receipts
            let found = all.filter { ($0.amount ?? 0) > 0 }
            detectedReceipts = found.isEmpty ? all : found
            if found.count > 1 {
                showReceiptPicker = true
            } else {
                applyParsed(found.first ?? all.first ?? ParsedReceipt())
            }
        } catch {
            alertMessage = "识别失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func applyParsed(_ parsed: ParsedReceipt) {
        guard let amount = parsed.amount else {
            alertMessage = "没有识别到金额，请手动填写或点字段微调"
            hasOCRResult = true
            return
        }
        // 识图规则：实付金额；退款→收入；优惠文案进备注非标题；时间兜底
        kind = parsed.isIncome ? .income : (parsed.isSelfTransfer ? .transfer : .expense)
        if parsed.isCardRepayment { kind = .expense }
        amountText = String(format: "%.2f", amount)
        if let m = parsed.merchant, !m.isEmpty {
            merchant = m
        }
        if let n = parsed.discountNote, !n.isEmpty {
            note = n // 优惠文案进备注，不作标题
        } else if !merchant.isEmpty {
            note = ""
        }
        let fallback = ocrFallback ?? CaptureTime(date: date, source: .now)
        let t = CaptureTime.resolve(recognized: parsed.date, reference: ocrReference ?? Date(), fallback: fallback)
        if t.source != .now { date = t.date }
        ocrTimeHint = t.source == .now ? "时间未识别（已用当前时间），点此校准" : t.source.hint
        let list = categories
        let hit = RuleStore.match(merchant: parsed.merchant ?? "", kind: kind, in: context, countHit: false)
        if let c = hit?.category, c.kind == kind {
            selectedCategoryID = c.id
        } else if let name = parsed.categoryName, let c = list.first(where: { $0.name == name }) {
            selectedCategoryID = c.id
        } else {
            selectedCategoryID = list.first?.id
        }
        ocrAccountTail = parsed.accountHint?.cardTail
        if let a = DataStore.account(matching: parsed.accountHint, modelName: parsed.accountName, role: .single, in: context)
            ?? selectableAccounts.first(where: { $0.name == (parsed.accountName ?? "") })
            ?? hit?.account {
            accountID = a.id
        }
        source = "ocr"
        hasOCRResult = true
        submode = .ocr
    }
}
