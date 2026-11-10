import SwiftUI
import UIKit
import SwiftData
import PhotosUI
import Photos

/// 新建 / 编辑记录（支出、收入、转账；余额校准记录也可在此修改）
struct RecordEditorView: View {
    let record: LedgerRecord?
    var initialDate: Date = Date()
    var initialKind: RecordKind = .expense
    var presetAccountID: UUID? = nil
    /// 周期账单提醒「记一笔」时带入的内容
    var prefill: RecordPrefill? = nil
    /// 资产页长按信用卡「还款」：直接进入信用卡还款，并选好这张卡
    var repayCardID: UUID? = nil
    /// 4.1 设计稿：从「识图」入口打开时，记账弹窗内置切到截屏识图子模式
    var startInOCRMode: Bool = false

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LedgerCategory.sortOrder) private var allCategories: [LedgerCategory]
    @Query(sort: \LedgerAccount.sortOrder) private var allAccounts: [LedgerAccount]
    @Query(sort: \CategoryRule.hitCount, order: .reverse) private var allRules: [CategoryRule]
    @AppStorage(SettingsKey.defaultAccount) private var defaultAccount = ""
    @Environment(\.ledgerPrefs) private var prefs
    @Environment(\.appTheme) private var theme
    /// 顶部卡片折叠状态（设备级，真实 / 防窥一致）
    @AppStorage(SettingsKey.editorCardCollapsed, store: .standard) private var cardCollapsed = false

    @State private var kind: RecordKind = .expense
    @State private var amountText = ""
    @State private var selectedCategoryID: UUID?
    @State private var note = ""
    @State private var merchant = ""
    @State private var accountID: UUID?
    @State private var toAccountID: UUID?
    @State private var feeText = ""
    @State private var date = Date()
    @State private var source = "manual"
    /// 识图得到的卡号尾号（保存时学习「尾号 → 账户」，仅真实模式）
    @State private var ocrAccountTail: String?
    @State private var ocrCardTail: String?
    @State private var didLoad = false
    @State private var recurringKey = ""
    /// 用户是否手动改过账户 / 分类（自动带出时不覆盖用户的选择）
    @State private var accountTouched = false
    @State private var categoryTouched = false
    @State private var ruleHint: String?
    /// 支出页的「信用卡还款」：保存为 付款账户 → 负债账户 的转账（付款账户减少，欠款减少，默认不计入支出统计）
    @State private var repayMode = false
    /// receipt 皮肤记一笔双模：manual / ocr（贴设计稿顶栏切换）
    private enum EditorSubmode: String { case manual, ocr }
    @State private var editorSubmode: EditorSubmode = .manual

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isRecognizing = false
    @State private var alertMessage: String?
    @State private var showDeleteConfirm = false
    @State private var savedCountInSession = 0
    @State private var detectedReceipts: [ParsedReceipt] = []
    @State private var showReceiptPicker = false
    /// 上次识图使用的引擎（Apple 智能 / 规则）及回退说明
    @State private var ocrEngineLine: String?
    /// 识图的时间参考（截图拍摄时间，没有则为识图时的现在）与找不到交易时间时的兜底（2.0 (19)）
    @State private var ocrReference: Date?
    @State private var ocrFallback: CaptureTime?
    /// 时间不是从截图文字里识别到的：在时间下方小字说明来源；用户改了时间后不再显示
    @State private var ocrTimeHint: String?
    @State private var ocrTimeHintDate: Date?
    @FocusState private var amountFocused: Bool
    /// 3.4 (25) 键盘弹出时顶部卡片临时只显示头部（和重复提醒），保证下方表单还有足够空间
    @State private var keyboardShown = false

    private var categories: [LedgerCategory] {
        allCategories.filter { $0.kind == kind }
    }

    /// 可选账户：未归档的，以及当前记录已关联的
    private var selectableAccounts: [LedgerAccount] {
        allAccounts.filter { !$0.isArchived || $0.id == accountID || $0.id == toAccountID }
    }

    /// 还款的付款账户：非负债账户
    private var payerAccounts: [LedgerAccount] {
        selectableAccounts.filter { !$0.type.isLiability || $0.id == accountID }
    }

    /// 还款的目标：信用卡 / 花呗 / 贷款等负债账户
    private var cardAccounts: [LedgerAccount] {
        selectableAccounts.filter { $0.type.isLiability || $0.id == toAccountID }
    }

    private var selectedCard: LedgerAccount? {
        allAccounts.first(where: { $0.id == toAccountID })
    }

    /// 当前欠款（编辑已有还款时，加回这条记录本身还掉的金额）
    private var fullRepaymentAmount: Double? {
        guard let card = selectedCard, card.type.isLiability else { return nil }
        var owed = card.debt
        if let record, record.isCreditRepayment, record.toAccount?.id == card.id {
            owed = max(0, -(card.balance() - record.amount))
        }
        return owed > 0.004 ? (owed * 100).rounded() / 100 : nil
    }

    private var parsedAmount: Double? { Money.parse(amountText) }

    private var amountValid: Bool {
        guard let a = parsedAmount else { return false }
        return kind == .adjustment ? a != 0 : a > 0
    }

    private var canSave: Bool {
        guard amountValid else { return false }
        if repayMode {
            return accountID != nil && accountID != toAccountID && (selectedCard?.type.isLiability ?? false)
        }
        if kind == .transfer {
            return accountID != nil && toAccountID != nil && accountID != toAccountID
        }
        if kind == .contribution || kind == .adjustment { return accountID != nil }
        return true
    }

    var body: some View {
        // 4.3 (46)：修改已有记录统一走系统表单（record != nil 不进收银台）；收银台只用于新建 / 再来一笔 / 退款
        if theme.isReceipt && record == nil && initialKind != .contribution && initialKind != .adjustment {
            ReceiptCashierView(
                record: record,
                initialDate: initialDate,
                initialKind: initialKind,
                presetAccountID: presetAccountID,
                prefill: prefill,
                repayCardID: repayCardID,
                startInOCRMode: startInOCRMode
            )
        } else {
        NavigationStack {
            ThemedForm {
                if theme.isReceipt && record == nil {
                    Section {
                        Picker("记账方式", selection: $editorSubmode) {
                            Text("⌨️ 手工记账").tag(EditorSubmode.manual)
                            Text("📷 截屏识图").tag(EditorSubmode.ocr)
                        }
                        .pickerStyle(.segmented)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("editor-submode")
                    }
                }
                if theme.isReceipt && record == nil && editorSubmode == .ocr {
                    Section {
                        PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images, photoLibrary: .shared()) {
                            HStack {
                                Label(isRecognizing ? "正在识别…" : "选择支付截图识别（可多选）", systemImage: "text.viewfinder")
                                Spacer()
                                if isRecognizing { ProgressView() }
                            }
                        }
                        .disabled(isRecognizing)
                        .accessibilityIdentifier("editor-ocr-picker")
                        if let ocrEngineLine {
                            Text(ocrEngineLine)
                                .font(.ui(.caption2))
                                .foregroundStyle(.secondary)
                        }
                    } footer: { ThemedSectionFooter {
                        Text("在本机识别金额、商户、时间与付款账户；识别后可直接改字段再保存。图片不会上传。")
                    } }
                }
                Section {
                    if kind == .adjustment {
                        Label("余额校准（不计入收支统计）", systemImage: "slider.horizontal.3")
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    } else if kind == .contribution {
                        Label("缴存（增加账户余额，不计入收入）", systemImage: "tray.and.arrow.down.fill")
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    } else {
                        Picker("类型", selection: $kind) {
                            ForEach(RecordKind.editorKinds) { k in
                                Text(k.title).tag(k)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowSeparator(.hidden)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Money.symbol)
                            .font(.uiSystem(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $amountText)
                            .keyboardType(kind == .adjustment ? .numbersAndPunctuation : .decimalPad)
                            .font(.uiSystem(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(amountColor)
                            .focused($amountFocused)
                    }
                    .padding(.vertical, 4)
                }

                if kind == .transfer {
                    transferSection
                } else if kind == .contribution {
                    Section {
                        accountPicker(title: "缴存账户", selection: $accountID, allowNone: false)
                    } footer: { ThemedSectionFooter {
                        Text("公积金、医保、养老保险等每月缴存。单位和个人缴纳部分都可以记在这里；提取请用「转账」转到银行卡。")
                    } }
                } else if kind == .adjustment {
                    Section {
                        accountPicker(title: "账户", selection: $accountID, allowNone: false)
                    } footer: { ThemedSectionFooter {
                        Text("正数表示调增余额，负数表示调减。")
                    } }
                } else {
                    categorySection
                    if repayMode { repaymentSection }
                }

                Section {
                    DatePicker("时间", selection: $date)
                    HStack(spacing: 8) {
                        Text("快捷日期")
                            .font(.ui(.caption))
                            .foregroundStyle(.secondary)
                        Spacer()
                        ForEach([(0, "今天"), (-1, "昨天"), (-2, "前天")], id: \.0) { offset, label in
                            let targetDate = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
                            let isSameDay = Calendar.current.isDate(date, inSameDayAs: targetDate)
                            Button {
                                ReceiptHaptics.selection()
                                let cal = Calendar.current
                                let comps = cal.dateComponents([.hour, .minute, .second], from: date)
                                withAnimation(.snappy(duration: 0.22)) {
                                    if let d = cal.date(byAdding: .day, value: offset, to: Date()),
                                       let merged = cal.date(bySettingHour: comps.hour ?? 12, minute: comps.minute ?? 0, second: comps.second ?? 0, of: d) {
                                        date = merged
                                    } else {
                                        date = targetDate
                                    }
                                }
                            } label: {
                                Text(label)
                                    .font(.ui(.caption).weight(isSameDay ? .semibold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(isSameDay ? Color.themeAccent.opacity(0.16) : Color(.secondarySystemFill)))
                                    .foregroundStyle(isSameDay ? Color.themeAccent : .primary)
                                    .scaleEffect(isSameDay ? 1.03 : 1.0)
                            }
                            .buttonStyle(ReceiptPressButtonStyle())
                        }
                    }
                    if let ocrTimeHint, ocrTimeHintDate == date {
                        Label(ocrTimeHint, systemImage: "clock.badge.questionmark")
                            .font(.ui(.caption))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("ocr-time-source")
                    }
                    TextField("备注", text: $note)
                        .accessibilityIdentifier("editor-note")
                    if kind.countsInStats && !repayMode {
                        TextField("商户（可选）", text: $merchant)
                            .accessibilityIdentifier("editor-merchant")
                        let suggestions = suggestedMerchants
                        if !suggestions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    Text("常去：")
                                        .font(.ui(.caption2))
                                        .foregroundStyle(.secondary)
                                    ForEach(suggestions, id: \.self) { m in
                                        Button {
                                            UISelectionFeedbackGenerator().selectionChanged()
                                            merchant = m
                                        } label: {
                                            Text(m)
                                                .font(.ui(.caption))
                                                .padding(.horizontal, 9)
                                                .padding(.vertical, 4)
                                                .background(Capsule().fill(merchant == m ? Color.themeAccent.opacity(0.16) : Color(.secondarySystemFill)))
                                                .foregroundStyle(merchant == m ? Color.themeAccent : .primary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        accountPicker(title: "账户", selection: userAccountBinding, allowNone: true)
                    }
                } footer: { ThemedSectionFooter {
                    if let ruleHint, kind.countsInStats, !repayMode {
                        Label(ruleHint, systemImage: "wand.and.stars")
                    }
                } }

                if kind.countsInStats && !(theme.isReceipt && record == nil && editorSubmode == .ocr) {
                    Section {
                        PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images, photoLibrary: .shared()) {
                            HStack {
                                Label("从支付截图识别填写（支持多选）", systemImage: "text.viewfinder")
                                Spacer()
                                if isRecognizing { ProgressView() }
                            }
                        }
                        .disabled(isRecognizing)
                        .confirmationDialog("识别到 \(detectedReceipts.count) 笔交易，选择入账方式", isPresented: $showReceiptPicker,
                                            titleVisibility: .visible) {
                            Button("一键全部入账（共 \(detectedReceipts.count) 笔）") {
                                let saved = Self.batchInsert(
                                    receipts: detectedReceipts,
                                    reference: ocrReference ?? Date(),
                                    fallback: ocrFallback ?? CaptureTime(date: date, source: .now),
                                    defaultAccountName: defaultAccount,
                                    allCategories: allCategories,
                                    selectableAccounts: selectableAccounts,
                                    in: context
                                )
                                if saved > 0 {
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    BudgetMonitor.check(in: context)
                                    dismiss()
                                }
                            }
                            ForEach(Array(detectedReceipts.enumerated()), id: \.offset) { _, r in
                                Button("单选微调：" + Self.receiptTitle(r)) { apply(r) }
                            }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("可直接一次全部记入账本，或单选其中一笔在表单中微调。" + (ocrEngineLine.map { "\n" + $0 } ?? ""))
                        }
                    } footer: { ThemedSectionFooter {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("在本机识别金额、商户、时间与付款账户，图片不会上传。")
                            if let ocrEngineLine {
                                Text(ocrEngineLine)
                                    .font(.ui(.caption2))
                                    .accessibilityIdentifier("ocr-engine-line")
                            }
                        }
                    } }
                }

                if record == nil {
                    Section {
                        Button {
                            save(keepOpen: true)
                        } label: {
                            HStack {
                                Label("保存并再记一笔", systemImage: "arrow.triangle.2.circlepath")
                                Spacer()
                                if savedCountInSession > 0 {
                                    Text("已连记 \(savedCountInSession) 笔")
                                        .font(.ui(.caption))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!canSave)
                        .accessibilityIdentifier("editor-save-next")
                    }
                }

                if let record, record.kind != .adjustment {
                    Section {
                        NavigationLink {
                            RecurringEditorView(rule: nil, template: record)
                        } label: {
                            Label(record.recurringKey.isEmpty ? "设为周期账单" : "由周期账单生成 · 再建一个周期",
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                    } footer: { ThemedSectionFooter {
                        Text("按这条记录的金额、分类和账户，每月 / 每周等自动记账或提醒。")
                    } }
                }

                if record != nil {
                    Section {
                        Button("删除这条记录", role: .destructive) { showDeleteConfirm = true }
                            .frame(maxWidth: .infinity)
                            // 挂在按钮上：iOS 26 的气泡指向这个按钮，iOS 17/18 仍是底部操作表
                            .confirmationDialog("删除这条记录？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                                Button("删除", role: .destructive) { deleteRecord() }
                                Button("取消", role: .cancel) {}
                            } message: {
                                Text("\(record?.deleteSummary ?? "")\n删除后无法恢复。")
                            }
                    }
                }
            }
            .themedScreenBackground()
            // 3.4 (25) 顶部卡片固定在导航栏下方（不随表单滚动），表单在它下面单独滚动
            .safeAreaInset(edge: .top, spacing: 0) { stickyCard }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                withAnimation(.snappy(duration: 0.2)) { keyboardShown = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.snappy(duration: 0.2)) { keyboardShown = false }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { amountFocused = false }
                }
            }
            .onAppear {
                if startInOCRMode { editorSubmode = .ocr }
                load()
                if record == nil {
                    // 预加载端侧模型（带当前分类与账户词表），选图识别时直接复用已预热会话
                    let vocab = DataStore.ocrVocabulary(categories: allCategories, accounts: allAccounts, isDecoy: SessionManager.shared.isDecoy)
                    AppleIntelligenceExtractor.prewarm(vocabulary: vocab)
                }
            }
            .onChange(of: kind) { _, newKind in
                if newKind != .expense { repayMode = false }
                if newKind.countsInStats && !categories.contains(where: { $0.id == selectedCategoryID }) {
                    selectedCategoryID = categories.first?.id
                }
            }
            .onChange(of: allAccounts.count) { _, _ in
                // 3.8 (29)：首帧 Query 为空时 enterRepayMode 选不了卡；账户到位后再补一次
                if didLoad { refreshRepayTargetsIfNeeded() }
            }
            .onChange(of: merchant) { _, value in
                applyRule(merchant: value, overrideCategory: !categoryTouched)
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await recognizeBatch(items) }
            }
            .alert("提示", isPresented: alertBinding) {
                Button("好", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }

        } // NavigationStack
        } // else default form
    }

    // MARK: - 顶部卡片（3.1 (22)）

    /// 3.4 (25) 悬浮在顶部的当笔卡片：页面底色垫底 + 底部一条分隔，表单内容从它下面滚过不会透出来
    private var stickyCard: some View {
        RecordSummaryCard(info: cardInfo, style: cardStyle, collapsed: $cardCollapsed, compact: keyboardShown)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .background(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    Color.themeBackdrop
                    Rectangle().fill(theme.rule.opacity(0.6)).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .horizontal)
            }
            .accessibilityIdentifier("editor-sticky-card")
    }

    private var cardStyle: RecordCardStyle {
        RecordCardStyle(receipt: theme.isReceipt, paper: theme.isReceipt ? theme.paper : theme.cardFill,
                        ink: theme.ink, faint: theme.faint, rule: theme.rule, accent: theme.accent,
                        income: theme.income, neutral: Color(hex: "#30B0C7"), corner: theme.cardCorner)
    }

    /// 由编辑页当前状态生成卡片内容（纯计算，任何字段变化都会重新生成）
    private var cardInfo: RecordCardInfo {
        let amount = parsedAmount
        let placeholder = !amountValid
        let category = allCategories.first(where: { $0.id == selectedCategoryID })
        let from = allAccounts.first(where: { $0.id == accountID })
        let to = allAccounts.first(where: { $0.id == toAccountID })
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMerchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)

        let kindText: String
        let tone: RecordCardInfo.Tone
        let sign: String
        let icon: String
        let colorHex: String
        let fallbackTitle: String
        var lines: [RecordCardLine] = []
        var useMerchant = false

        if repayMode {
            kindText = "还款"; tone = .neutral; sign = ""
            icon = LedgerRecord.repaymentIcon; colorHex = "#30B0C7"; fallbackTitle = "信用卡还款"
            lines.append(RecordCardLine(label: "付款账户", value: from?.name ?? "请选择", warn: from == nil))
            lines.append(RecordCardLine(label: "还款信用卡", value: to?.name ?? "请选择", warn: to == nil))
        } else {
            switch kind {
            case .expense, .income:
                kindText = kind.title; tone = kind == .income ? .income : .expense; sign = kind.sign
                icon = category?.icon ?? "tag.fill"; colorHex = category?.colorHex ?? "#8E8E93"
                fallbackTitle = category?.name ?? kind.title
                useMerchant = true
                lines.append(RecordCardLine(label: "分类", value: category?.name ?? "未选择", icon: category?.icon,
                                            colorHex: category?.colorHex, warn: category == nil))
                lines.append(RecordCardLine(label: "账户", value: from?.name ?? "未选择"))
            case .transfer:
                kindText = kind.title; tone = .neutral; sign = ""
                icon = "arrow.left.arrow.right"; colorHex = "#30B0C7"; fallbackTitle = "转账"
                lines.append(RecordCardLine(label: "转出账户", value: from?.name ?? "请选择", warn: from == nil))
                lines.append(RecordCardLine(label: "转入账户", value: to?.name ?? "请选择", warn: to == nil))
                if let fee = Money.parse(feeText), fee > 0 {
                    lines.append(RecordCardLine(label: "手续费", value: Money.format(fee)))
                }
            case .contribution:
                kindText = kind.title; tone = .neutral; sign = "+"
                icon = "tray.and.arrow.down.fill"; colorHex = "#E8A33D"; fallbackTitle = from?.name ?? "缴存"
                lines.append(RecordCardLine(label: "缴存账户", value: from?.name ?? "请选择", warn: from == nil))
            case .adjustment:
                kindText = kind.title; tone = .neutral; sign = ""
                icon = "slider.horizontal.3"; colorHex = "#8E8E93"; fallbackTitle = from?.name ?? "余额校准"
                lines.append(RecordCardLine(label: "账户", value: from?.name ?? "请选择", warn: from == nil))
            }
        }

        // 标题：商户 > 备注 > 分类 / 类型；备注不当标题时单独一行
        let title: String
        if useMerchant, !trimmedMerchant.isEmpty {
            title = trimmedMerchant
            if !trimmedNote.isEmpty { lines.append(RecordCardLine(label: "备注", value: trimmedNote)) }
        } else if !trimmedNote.isEmpty {
            title = trimmedNote
        } else {
            title = fallbackTitle
        }
        if let ocrTimeHint, ocrTimeHintDate == date {
            lines.append(RecordCardLine(label: "时间来源", value: ocrTimeHint, warn: true))
        }

        let amountText: String
        if let amount, !placeholder {
            amountText = kind == .adjustment && !repayMode ? (amount > 0 ? "+" : "") + Money.format(amount)
                                                           : sign + Money.format(amount)
        } else {
            amountText = Money.format(0)
        }
        let badge: String? = source == "ocr" ? "识图" : (source == "recurring" ? "周期账单" : nil)
        return RecordCardInfo(kindText: kindText, amountText: amountText, tone: tone, amountPlaceholder: placeholder,
                              title: title, dateText: ReviewFormatter.fullDate.string(from: date),
                              icon: icon, colorHex: colorHex, lines: lines, badge: badge,
                              duplicate: duplicateWarning(amount: placeholder ? nil : amount, merchant: trimmedMerchant))
    }

    /// 3.3 (24) 编辑页顶部卡片的「可能重复」：账本里金额相同、商户相近 / 同账户、时间相近的另一笔
    /// （时间不是从截图识别到的放宽到 30 分钟）。余额校准 / 缴存不查。
    private func duplicateWarning(amount: Double?, merchant: String) -> String? {
        guard let amount, amount > 0, kind == .expense || kind == .income || kind == .transfer || repayMode else { return nil }
        let window = (ocrTimeHint != nil && ocrTimeHintDate == date) ? DuplicateHint.window(for: .screenshot) : DuplicateMatcher.window
        guard let hit = IntentRecorder.duplicateHit(amount: amount, merchant: merchant, date: date, accountID: accountID,
                                                    window: window, excluding: record?.id, in: context) else { return nil }
        return DuplicateHint.banner(hit, skip: nil, symbol: Money.symbol)
    }

    // MARK: - Sections

    private var navTitle: String {
        if kind == .contribution { return record == nil ? "缴存" : "编辑缴存" }
        if repayMode { return record == nil ? "信用卡还款" : "编辑还款" }
        if record == nil { return kind == .transfer ? "转账" : "记一笔" }
        return kind == .adjustment ? "余额校准" : "编辑记录"
    }

    private var amountColor: Color {
        if repayMode { return Color(hex: "#30B0C7") }
        switch kind {
        case .income: return Color.themeIncome
        case .contribution: return Color(hex: "#E8A33D")
        case .expense: return .primary
        case .transfer, .adjustment: return Color(hex: "#30B0C7")
        }
    }

    private var categorySection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 14) {
                if kind == .expense {
                    // 3.8 (29)：用 Button 而不是 onTapGesture，UI 测试 / VoiceOver 的 activate 才能进还款模式
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        enterRepayMode(card: nil)
                        refreshRepayTargetsIfNeeded()
                    } label: {
                        VStack(spacing: 6) {
                            CategoryIcon(icon: LedgerRecord.repaymentIcon, color: LedgerRecord.repaymentColor, size: 44, selected: repayMode)
                            Text("信用卡还款")
                                .font(.ui(.caption2))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .foregroundStyle(repayMode ? Color.primary : Color.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("tile-card-repayment")
                    .accessibilityLabel("信用卡还款")
                    .accessibilityAddTraits(.isButton)
                }
                ForEach(categories) { c in
                    VStack(spacing: 6) {
                        CategoryIcon(icon: c.icon, color: c.color, size: 44, selected: !repayMode && c.id == selectedCategoryID)
                        Text(c.name)
                            .font(.ui(.caption2))
                            .lineLimit(1)
                            .foregroundStyle(!repayMode && c.id == selectedCategoryID ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UISelectionFeedbackGenerator().selectionChanged()
                        if repayMode {
                            repayMode = false
                            if allAccounts.first(where: { $0.id == accountID })?.type.isLiability == true { accountID = nil }
                        }
                        selectedCategoryID = c.id
                        categoryTouched = true
                        ruleHint = nil
                        // 新记录：带出该分类上次使用的账户
                        if record == nil, !accountTouched, let a = RuleStore.lastAccount(for: c, in: context) {
                            accountID = a.id
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        } header: { ThemedSectionHeader {
            HStack {
                Text("分类")
                Spacer()
                NavigationLink("管理") { CategoryManagerView(initialKind: kind) }
                    .font(.ui(.caption))
                    .textCase(nil)
            }
        } }
    }

    private var transferSection: some View {
        Section {
            accountPicker(title: "转出账户", selection: $accountID, allowNone: false)
            accountPicker(title: "转入账户", selection: $toAccountID, allowNone: false)
            HStack {
                Text("手续费")
                Spacer()
                TextField("0.00", text: $feeText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 140)
            }
        } header: { ThemedSectionHeader {
            Text("转账 / 还款")
        } } footer: { ThemedSectionFooter {
            if accountID != nil && accountID == toAccountID {
                Text("转出和转入账户不能相同。").foregroundStyle(.red)
            } else if allAccounts.isEmpty {
                Text("还没有账户，请先在「资产」页添加。")
            } else {
                Text("转入信用卡 / 花呗即为还款。转账不计入收支统计和预算，手续费从转出账户扣除。")
            }
        } }
    }

    private var repaymentSection: some View {
        Section {
            accountPicker(title: "付款账户", selection: $accountID, allowNone: false, options: payerAccounts)
                .accessibilityIdentifier("repay-from")
                .accessibilityLabel("付款账户")
            accountPicker(title: "还款信用卡", selection: $toAccountID, allowNone: false, options: cardAccounts)
                .accessibilityIdentifier("repay-card")
                .accessibilityLabel("还款信用卡")
            // 3.8 (29)：稳定探针（勿用极小透明 Text，iOS 26 会从 a11y 树里丢掉）
            Text("还款表单")
                .font(.ui(.caption2))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("repay-form")
                .accessibilityLabel("还款表单")
            if let full = fullRepaymentAmount {
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    amountText = String(format: "%.2f", full)
                    amountFocused = false
                } label: {
                    Label("全额还款 \(Money.format(full))", systemImage: "checkmark.circle")
                }
                .accessibilityIdentifier("repay-full")
            }
        } header: { ThemedSectionHeader {
            Text("信用卡还款")
        } } footer: { ThemedSectionFooter {
            if accountID != nil && accountID == toAccountID {
                Text("付款账户和信用卡不能相同。").foregroundStyle(.red)
            } else if cardAccounts.isEmpty {
                Text("还没有信用卡 / 花呗等负债账户，请先在「资产」页添加。")
            } else {
                Text(RepaymentSetting.includeInExpense(prefs)
                     ? "付款账户余额减少，信用卡欠款同步减少。已设置「信用卡还款计入支出」，会计入支出统计。"
                     : "付款账户余额减少，信用卡欠款同步减少。刷卡消费已记为支出，还款默认不再计入支出（可在设置中开启）。")
            }
        } }
    }

    /// 切到信用卡还款：付款账户默认用默认账户（非负债），信用卡默认选有欠款的第一张。
    /// 3.8 (29)：显式传入的 card 不能被「账户 Query 尚未就绪」覆盖成 nil，否则全额还款按钮不出现。
    private func enterRepayMode(card: UUID?) {
        repayMode = true
        ruleHint = nil
        if let card {
            toAccountID = card
        } else if selectedCard?.type.isLiability != true {
            let active = allAccounts.filter { $0.type.isLiability && !$0.isArchived }
            toAccountID = (active.first(where: { $0.type.hasCreditLimit && $0.debt > 0 })
                ?? active.first(where: { $0.type.hasCreditLimit }) ?? active.first)?.id
        }
        // 账户列表可能在 onAppear 时还是空的：有显式 card 时保留 UUID，等 Query 到位后再解析
        let current = allAccounts.first(where: { $0.id == accountID })
        if current == nil || current?.type.isLiability == true || accountID == toAccountID {
            let payers = allAccounts.filter { !$0.type.isLiability && !$0.isArchived && !$0.type.isSocialSecurity && $0.id != toAccountID }
            if !payers.isEmpty {
                accountID = (payers.first(where: { $0.name == defaultAccount })
                    ?? payers.first(where: { $0.type == .debit }) ?? payers.first)?.id
            }
        }
    }

    /// Query 晚于首帧时补全还款目标 / 演示金额（避免全额还款按钮一直不出现）
    private func refreshRepayTargetsIfNeeded() {
        guard repayMode else { return }
        if let repayCardID {
            if toAccountID != repayCardID { toAccountID = repayCardID }
        } else if toAccountID == nil || selectedCard?.type.isLiability != true {
            let active = allAccounts.filter { $0.type.isLiability && !$0.isArchived }
            toAccountID = (active.first(where: { $0.type.hasCreditLimit && $0.debt > 0 })
                ?? active.first(where: { $0.type.hasCreditLimit }) ?? active.first)?.id
        }
        if accountID == nil || accountID == toAccountID
            || allAccounts.first(where: { $0.id == accountID })?.type.isLiability == true {
            let payers = allAccounts.filter { !$0.type.isLiability && !$0.isArchived && !$0.type.isSocialSecurity && $0.id != toAccountID }
            if !payers.isEmpty {
                accountID = (payers.first(where: { $0.name == defaultAccount })
                    ?? payers.first(where: { $0.type == .debit }) ?? payers.first)?.id
            }
        }
        if ScreenshotDemo.isActive, (amountText.isEmpty || Money.parse(amountText) == 0),
           let full = fullRepaymentAmount {
            amountText = String(format: "%.2f", full)
        }
    }

    private func accountPicker(title: String, selection: Binding<UUID?>, allowNone: Bool,
                               options: [LedgerAccount]? = nil) -> some View {
        Picker(title, selection: selection) {
            if allowNone || selection.wrappedValue == nil {
                Text(allowNone ? "不选择" : "请选择").tag(UUID?.none)
            }
            ForEach(options ?? selectableAccounts) { a in
                Label(a.name, systemImage: a.iconName).tag(UUID?.some(a.id))
            }
        }
    }

    private var userAccountBinding: Binding<UUID?> {
        Binding(get: { accountID }, set: { accountID = $0; accountTouched = true })
    }

    private var suggestedMerchants: [String] {
        let catID = selectedCategoryID?.uuidString ?? ""
        var out: [String] = []
        for r in allRules where r.isEnabled {
            let name = (r.displayName.isEmpty ? r.keyword : r.displayName).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !out.contains(name) else { continue }
            if !catID.isEmpty && r.categoryID == catID {
                out.insert(name, at: 0)
            } else if r.kind == nil || r.kind == kind {
                out.append(name)
            }
        }
        return Array(out.prefix(8))
    }

    /// 套用记账规则（分类记忆）。只影响新记录，且不覆盖用户手动选择的分类 / 账户。
    private func applyRule(merchant value: String, overrideCategory: Bool) {
        guard record == nil, kind.countsInStats else { return }
        guard let hit = RuleStore.match(merchant: value, text: note, kind: kind, in: context, countHit: false) else { return }
        if overrideCategory, let c = hit.category, c.kind == kind {
            selectedCategoryID = c.id
            ruleHint = "已按记账规则「\(hit.rule.displayName.isEmpty ? hit.rule.keyword : hit.rule.displayName)」选择 \(c.name)"
        }
        if !accountTouched, let a = hit.account ?? RuleStore.lastAccount(for: hit.category, in: context) {
            accountID = a.id
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })
    }

    // MARK: - 数据

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        if let record {
            kind = record.isCreditRepayment ? .expense : record.kind
            repayMode = record.isCreditRepayment
            amountText = String(format: "%.2f", record.amount)
            selectedCategoryID = record.category?.id
            note = record.note
            merchant = record.merchant
            accountID = record.accountRef?.id ?? allAccounts.first(where: { $0.name == record.account })?.id
            toAccountID = record.toAccount?.id
            feeText = record.fee > 0 ? String(format: "%.2f", record.fee) : ""
            date = record.date
            source = record.source
        } else if let p = prefill {
            kind = p.kind
            amountText = p.amount > 0 ? String(format: "%.2f", p.amount) : ""
            date = p.date
            note = p.note
            merchant = p.merchant
            accountID = p.accountID ?? allAccounts.first(where: { $0.name == defaultAccount && !$0.isArchived })?.id
            toAccountID = p.toAccountID
            selectedCategoryID = p.categoryID ?? allCategories.first(where: { $0.kind == (p.kind.countsInStats ? p.kind : .expense) })?.id
            recurringKey = p.recurringKey
            source = p.recurringKey.isEmpty ? "manual" : "recurring"
            accountTouched = true
            categoryTouched = true
        } else if let repayCardID {
            kind = .expense
            date = initialDate
            selectedCategoryID = allCategories.first(where: { $0.kind == .expense })?.id
            enterRepayMode(card: repayCardID)
            refreshRepayTargetsIfNeeded()
            accountTouched = true
            if ScreenshotDemo.isActive, let full = fullRepaymentAmount {
                amountText = String(format: "%.2f", full)
            } else {
                amountFocused = true
            }
        } else {
            kind = initialKind
            date = initialDate
            selectedCategoryID = allCategories.first(where: { $0.kind == (initialKind.countsInStats ? initialKind : .expense) })?.id
            let firstCategory = allCategories.first(where: { $0.id == selectedCategoryID })
            accountID = presetAccountID
                ?? (initialKind.countsInStats ? RuleStore.lastAccount(for: firstCategory, in: context)?.id : nil)
                ?? allAccounts.first(where: { $0.name == defaultAccount && !$0.isArchived })?.id
            if presetAccountID != nil { accountTouched = true }
            amountFocused = true
        }
    }

    private func save(keepOpen: Bool = false) {
        guard let amount = parsedAmount, amountValid else {
            alertMessage = "请输入有效的金额"
            return
        }
        // 信用卡还款以「付款账户 → 信用卡」的转账保存：沿用转账的余额算法，无需新字段（CloudKit / 迁移安全）
        let kind: RecordKind = repayMode ? .transfer : self.kind
        if kind == .transfer {
            guard accountID != nil, toAccountID != nil, accountID != toAccountID else {
                alertMessage = repayMode ? "请选择付款账户和要还款的信用卡" : "请选择不同的转出和转入账户"
                return
            }
        }
        let category: LedgerCategory? = kind.countsInStats ? allCategories.first(where: { $0.id == selectedCategoryID }) : nil
        let fromAccount = allAccounts.first(where: { $0.id == accountID })
        let toAccount: LedgerAccount? = kind == .transfer ? allAccounts.first(where: { $0.id == toAccountID }) : nil
        let fee: Double
        if repayMode {
            fee = record?.isCreditRepayment == true ? (record?.fee ?? 0) : max(0, Money.parse(feeText) ?? 0)
        } else {
            fee = kind == .transfer ? max(0, Money.parse(feeText) ?? 0) : 0
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMerchant = kind.countsInStats ? merchant.trimmingCharacters(in: .whitespacesAndNewlines) : ""

        // 分类记忆：有商户时记住「商户 → 分类 + 账户」（编辑时仅在分类或账户改变时更新）
        let categoryChanged = record == nil || record?.category?.id != category?.id || record?.accountRef?.id != fromAccount?.id
        if kind.countsInStats, !trimmedMerchant.isEmpty, categoryChanged {
            RuleStore.learn(merchant: trimmedMerchant, kind: kind, category: category, account: fromAccount, in: context)
        }
        if kind.countsInStats { RuleStore.rememberAccount(fromAccount, for: category) }

        let target: LedgerRecord
        if let record {
            target = record
            target.amount = amount
            target.kind = kind
            target.note = trimmedNote
            target.merchant = trimmedMerchant
            target.date = date
        } else {
            target = LedgerRecord(amount: amount, kind: kind, category: nil, note: trimmedNote,
                                  merchant: trimmedMerchant, date: date, source: source)
            target.recurringKey = recurringKey
            context.insert(target)
        }
        target.category = category
        target.accountRef = fromAccount
        target.toAccount = toAccount
        target.fee = fee
        target.account = fromAccount?.name ?? ""   // 兼容旧版文本字段

        do {
            try context.save()
            if source == "ocr" {
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
                ruleHint = nil
                amountFocused = true
                return
            }
            dismiss()
        } catch {
            alertMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func deleteRecord() {
        guard let record else { return }
        let ctx = context
        dismiss()
        // 等 sheet 退场后再删除，避免退场重绘时读取已删除的模型对象
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            ctx.delete(record)
            try? ctx.save()
        }
    }

    // MARK: - 识图

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
                RunLog.shared.log(.info, "capture-time", "截图时间：\(capture?.source.logTag ?? "无（按现在）")")
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
        if allFound.count > 1 {
            detectedReceipts = allFound
            showReceiptPicker = true
        } else if let single = allFound.first ?? firstRaw.first {
            apply(single)
        } else {
            alertMessage = "无法识别图片中的交易信息"
        }
    }

    static func receiptTitle(_ r: ParsedReceipt) -> String {
        var parts = [(r.isCardRepayment ? "信用卡还款 " : r.isSelfTransfer ? "转账 " : (r.isIncome ? "收入 " : "支出 ")) + Money.format(r.amount ?? 0)]
        if r.isSelfTransfer, let n = r.transferNote, !n.isEmpty { parts.append(n) }
        if let m = r.merchant, !m.isEmpty { parts.append(m) }
        if let d = r.date { parts.append(DateText.monthDayTime.string(from: d)) }
        return parts.joined(separator: " · ")
    }

    @MainActor
    private func apply(_ parsed: ParsedReceipt) {
        guard let amount = parsed.amount else {
            alertMessage = "没有识别到金额，请手动填写"
            return
        }
        feeText = (parsed.fee ?? 0) > 0 ? String(format: "%.2f", parsed.fee!) : ""
        if parsed.isCardRepayment {
            kind = .expense
            amountText = String(format: "%.2f", amount)
            applyDate(parsed)
            let card = DataStore.account(matching: parsed.repaymentCard ?? AccountHint(type: "credit"),
                                         modelName: parsed.repaymentCardName, role: .card, in: context)
            if let payer = DataStore.account(matching: parsed.accountHint, modelName: parsed.accountName, role: .payer,
                                             excluding: card?.id, in: context) {
                accountID = payer.id
            }
            enterRepayMode(card: card?.type.isLiability == true ? card?.id : nil)
            if note.isEmpty || source == "ocr" { note = parsed.discountNote ?? "" }
            ocrAccountTail = parsed.accountHint?.cardTail
            ocrCardTail = parsed.repaymentCard?.cardTail
            source = "ocr"
            return
        }
        repayMode = false
        if parsed.isSelfTransfer {
            // 钱包充值 / 提现 / 余额宝转入转出：自己账户之间的转账
            kind = .transfer
            amountText = String(format: "%.2f", amount)
            applyDate(parsed)
            let from = DataStore.account(matching: parsed.transferFrom, modelName: parsed.transferFromName, role: .single, in: context)
            let to = DataStore.account(matching: parsed.transferTo, modelName: parsed.transferToName, role: .single,
                                       excluding: from?.id, in: context)
            if let from { accountID = from.id }
            toAccountID = to?.id == accountID ? nil : to?.id
            if note.isEmpty || source == "ocr" {
                note = [parsed.transferNote, parsed.discountNote].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            }
            ocrAccountTail = parsed.transferFrom?.cardTail
            ocrCardTail = parsed.transferTo?.cardTail
            source = "ocr"
            return
        }
        kind = parsed.isIncome ? .income : .expense
        amountText = String(format: "%.2f", amount)
        if let m = parsed.merchant { merchant = m }
        if note.isEmpty || source == "ocr" { note = parsed.discountNote ?? "" }
        applyDate(parsed)
        let list = allCategories.filter { $0.kind == kind }
        let hit = RuleStore.match(merchant: parsed.merchant ?? "", text: parsed.discountNote ?? note, kind: kind, in: context, countHit: false)
        if let c = hit?.category, c.kind == kind {
            // 记账规则优先于关键词猜测
            selectedCategoryID = c.id
            ruleHint = "已按记账规则「\(hit!.rule.displayName.isEmpty ? hit!.rule.keyword : hit!.rule.displayName)」选择 \(c.name)"
        } else if let name = parsed.categoryName, let c = list.first(where: { $0.name == name }) {
            selectedCategoryID = c.id
        } else if !list.contains(where: { $0.id == selectedCategoryID }) {
            selectedCategoryID = list.first?.id
        }
        // Apple 智能选出的账户名 > 付款方式线索 > 记账规则
        ocrAccountTail = parsed.accountHint?.cardTail
        ocrCardTail = nil
        if let a = DataStore.account(matching: parsed.accountHint, modelName: parsed.accountName, role: .single, in: context)
            ?? account(named: parsed.accountName) ?? hit?.account {
            accountID = a.id
        }
        source = "ocr"
    }

    /// 识别到且合理的交易时间直接用；否则用截图时间（或状态栏时钟），并在时间下方注明来源。
    /// 完全拿不到时保留当前时间，提示「时间未识别」。运行日志只记来源。
    @MainActor
    private func applyDate(_ parsed: ParsedReceipt) {
        let fallback = ocrFallback ?? CaptureTime(date: date, source: .now)
        let t = CaptureTime.resolve(recognized: parsed.date, reference: ocrReference ?? Date(), fallback: fallback)
        RunLog.shared.log(.info, "time-source", "账单时间来源：\(t.source.logTag)"
                          + (parsed.date != nil && t.source != .recognized ? "（识别到的时间不合理，已弃用）" : ""))
        if t.source != .now { date = t.date }
        ocrTimeHint = t.source == .now ? "时间未识别，请确认" : t.source.hint
        ocrTimeHintDate = ocrTimeHint == nil ? nil : date
    }

    private func account(named name: String?) -> LedgerAccount? {
        guard let name, !name.isEmpty else { return nil }
        return allAccounts.first(where: { $0.name == name && !$0.isArchived })
    }

    /// 多笔截图一键批量入账（复用与单笔相同的分类规则、账户匹配与信用卡还款/互转识别）
    @MainActor
    static func batchInsert(
        receipts: [ParsedReceipt],
        reference: Date,
        fallback: CaptureTime,
        defaultAccountName: String,
        allCategories: [LedgerCategory],
        selectableAccounts: [LedgerAccount],
        in context: ModelContext
    ) -> Int {
        var saved = 0
        let defaultAcc = (defaultAccountName.isEmpty ? nil : defaultAccountName).flatMap { name in
            selectableAccounts.first(where: { $0.name == name })
        } ?? selectableAccounts.first

        for parsed in receipts {
            guard let amount = parsed.amount, amount > 0 else { continue }
            let t = CaptureTime.resolve(recognized: parsed.date, reference: reference, fallback: fallback)
            let recDate = t.date
            let feeVal = max(0, parsed.fee ?? 0)

            if parsed.isCardRepayment {
                let card = DataStore.account(matching: parsed.repaymentCard ?? AccountHint(type: "credit"),
                                             modelName: parsed.repaymentCardName, role: .card, in: context)
                    ?? selectableAccounts.filter { $0.type.isLiability }.first
                let payer = DataStore.account(matching: parsed.accountHint, modelName: parsed.accountName, role: .payer,
                                              excluding: card?.id, in: context)
                    ?? selectableAccounts.filter { !$0.type.isLiability && !$0.type.isSocialSecurity && $0.id != card?.id }.first
                let rec = LedgerRecord(amount: (amount * 100).rounded() / 100, kind: .transfer, category: nil,
                                       note: parsed.discountNote ?? "", merchant: "信用卡还款",
                                       account: payer?.name ?? "", date: recDate, source: "ocr")
                rec.accountRef = payer
                rec.toAccount = card
                rec.fee = feeVal
                context.insert(rec)
                CardTailMemory.learn(tail: parsed.accountHint?.cardTail, accountID: payer?.id)
                CardTailMemory.learn(tail: parsed.repaymentCard?.cardTail, accountID: card?.id)
                saved += 1
                continue
            }

            if parsed.isSelfTransfer {
                let from = DataStore.account(matching: parsed.transferFrom, modelName: parsed.transferFromName, role: .single, in: context)
                let to = DataStore.account(matching: parsed.transferTo, modelName: parsed.transferToName, role: .single,
                                           excluding: from?.id, in: context)
                let note = [parsed.transferNote, parsed.discountNote].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                let rec = LedgerRecord(amount: (amount * 100).rounded() / 100, kind: .transfer, category: nil,
                                       note: note, merchant: parsed.transferNote ?? "转账",
                                       account: from?.name ?? "", date: recDate, source: "ocr")
                rec.accountRef = from
                rec.toAccount = to?.id == from?.id ? nil : to
                rec.fee = feeVal
                context.insert(rec)
                CardTailMemory.learn(tail: parsed.transferFrom?.cardTail, accountID: from?.id)
                CardTailMemory.learn(tail: parsed.transferTo?.cardTail, accountID: to?.id)
                saved += 1
                continue
            }

            let recKind: RecordKind = parsed.isIncome ? .income : .expense
            let list = allCategories.filter { $0.kind == recKind }
            let hit = RuleStore.match(merchant: parsed.merchant ?? "", text: parsed.discountNote ?? "", kind: recKind, in: context, countHit: true)
            let cat: LedgerCategory? = {
                if let c = hit?.category, c.kind == recKind { return c }
                if let name = parsed.categoryName, let c = list.first(where: { $0.name == name }) { return c }
                return list.first
            }()
            let from = DataStore.account(matching: parsed.accountHint, modelName: parsed.accountName, role: .single, in: context)
                ?? selectableAccounts.first(where: { $0.name == (parsed.accountName ?? "") })
                ?? hit?.account
                ?? RuleStore.lastAccount(for: cat, in: context)
                ?? defaultAcc
            let rec = LedgerRecord(amount: (amount * 100).rounded() / 100, kind: recKind, category: cat,
                                   note: parsed.discountNote ?? "", merchant: parsed.merchant ?? "",
                                   account: from?.name ?? "", date: recDate, source: "ocr")
            rec.accountRef = from
            context.insert(rec)
            CardTailMemory.learn(tail: parsed.accountHint?.cardTail, accountID: from?.id)
            saved += 1
        }
        if saved > 0 {
            try? context.save()
        }
        return saved
    }
}
