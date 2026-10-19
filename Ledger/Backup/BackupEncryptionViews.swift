import SwiftUI
import SwiftData

// MARK: - 密码输入（新密码 + 确认 + 强度）

struct BackupPasswordFields: View {
    @Binding var password: String
    @Binding var confirm: String
    var focusFirst = true

    @FocusState private var focus: Field?
    enum Field { case password, confirm }

    var body: some View {
        Group {
            SecureField("备份密码（至少 6 位）", text: $password)
                .textContentType(.newPassword)
                .focused($focus, equals: .password)
                .submitLabel(.next)
                .onSubmit { focus = .confirm }
            SecureField("再次输入密码", text: $confirm)
                .textContentType(.newPassword)
                .focused($focus, equals: .confirm)
                .submitLabel(.done)
            if !password.isEmpty {
                StrengthRow(strength: BackupCrypto.strength(of: password),
                            mismatch: !confirm.isEmpty && confirm != password)
            }
        }
        .onAppear {
            if focusFirst && password.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focus = .password }
            }
        }
    }

    static func isValid(_ password: String, _ confirm: String) -> Bool {
        password.count >= 6 && password == confirm
    }

    private struct StrengthRow: View {
        let strength: BackupCrypto.Strength
        let mismatch: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(1...3, id: \.self) { i in
                        Capsule()
                            .fill(i <= strength.rawValue ? color : Color(.systemGray5))
                            .frame(height: 5)
                    }
                }
                HStack {
                    Text("密码强度：\(strength.title)")
                        .foregroundStyle(strength == .tooShort ? .red : color)
                    Spacer()
                    if mismatch {
                        Label("两次输入不一致", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .font(.footnote)
                if strength == .weak || strength == .medium {
                    Text("建议 12 位以上，混合字母、数字和符号（也可以用一句好记的中文）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }

        private var color: Color {
            switch strength {
            case .tooShort, .weak: return .red
            case .medium: return .orange
            case .strong: return .green
            }
        }
    }
}

/// 进行中提示（派生密钥约需 0.5 秒）
struct CryptoProgressOverlay: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(title).font(.subheadline.weight(.medium))
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
    }
}

// MARK: - 导出备份

struct BackupExportSheet: View {
    /// 返回生成好的文件数据、文件名
    let onExport: (Data, String) -> Void

    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.backupEncryption) private var encryptionSetting = true

    @State private var encrypt = true
    @State private var useSaved = false
    @State private var password = ""
    @State private var confirm = ""
    @State private var remember = false
    @State private var working = false
    @State private var errorText: String?
    @State private var didLoad = false
    @State private var auth: SensitiveAuthRequest?
    private let hasSaved = BackupPasswordStore.hasPassword

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $encrypt.animation()) {
                        Label("加密备份", systemImage: encrypt ? "lock.fill" : "lock.open.fill")
                    }
                } footer: {
                    if encrypt {
                        Text("使用 AES-256-GCM 加密，密钥由备份密码经 PBKDF2-HMAC-SHA256 派生（\(BackupCrypto.minIterations / 10_000) 万次以上迭代）。文件扩展名为 .jzbackup。")
                    } else {
                        Label("将导出**明文** JSON：任何拿到文件的人都能直接看到全部账目、账户和备注。只在你确定文件不会外泄时使用。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                if encrypt {
                    if hasSaved {
                        Section {
                            Toggle(isOn: $useSaved.animation()) {
                                Label("使用已保存的备份密码", systemImage: "key.fill")
                            }
                        } footer: {
                            Text("备份密码已保存在本机钥匙串，自动备份也使用这个密码。")
                        }
                    }
                    if !useSaved {
                        Section {
                            BackupPasswordFields(password: $password, confirm: $confirm, focusFirst: !ScreenshotDemo.isActive)
                        } header: {
                            Text("设置备份密码")
                        } footer: {
                            Label("请务必牢记备份密码：简账不会上传或找回密码，忘记密码将**无法恢复**这份备份。", systemImage: "exclamationmark.lock.fill")
                                .foregroundStyle(.red)
                        }
                        Section {
                            Toggle(isOn: $remember) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hasSaved ? "替换本机保存的备份密码" : "在本机钥匙串记住密码")
                                    Text("仅此设备、不同步；自动备份将用它加密")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } footer: {
                            Text(lock.passcodeEnabled ? "查看或修改已保存的密码需要验证 App 密码或\(lock.biometryName)。" : "查看或修改已保存的密码需要验证设备密码或\(lock.biometryName)。")
                        }
                    }
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            }
            .disabled(working)
            .navigationTitle("导出备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(encrypt ? "加密并导出" : "导出明文") { start() }
                        .fontWeight(.semibold)
                        .disabled(!canExport || working)
                }
            }
            .overlay {
                if working { CryptoProgressOverlay(title: encrypt ? "正在加密备份…" : "正在生成备份…") }
            }
            .sensitiveAuthSheet($auth, lock: lock)
        }
        .interactiveDismissDisabled(working)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            encrypt = encryptionSetting
            useSaved = hasSaved
            remember = !hasSaved && UserDefaults.standard.bool(forKey: SettingsKey.autoBackupEnabled)
            if ScreenshotDemo.screen == "backupencrypt" {
                password = "jianzhang-2026!"
                confirm = password
                remember = true
            }
        }
    }

    private var canExport: Bool {
        !encrypt || useSaved || BackupPasswordFields.isValid(password, confirm)
    }

    private func start() {
        errorText = nil
        if encrypt && !useSaved && remember && hasSaved {
            // 替换已保存的密码需要验证身份
            lock.authenticateSensitive(reason: "验证后替换已保存的备份密码", pending: $auth) {
                BackupPasswordStore.save(password)
                run(password: password)
            }
            return
        }
        if encrypt && !useSaved && remember { BackupPasswordStore.save(password) }
        run(password: encrypt ? (useSaved ? BackupPasswordStore.load() : password) : nil)
    }

    private func run(password: String?) {
        if encrypt && (password ?? "").isEmpty {
            errorText = "无法读取已保存的备份密码，请重新输入。"
            useSaved = false
            return
        }
        working = true
        Task { @MainActor in
            do {
                let data = try await BackupService.exportData(context: context, password: password)
                working = false
                onExport(data, BackupService.fileName(encrypted: password != nil))
                dismiss()
            } catch {
                working = false
                errorText = error.localizedDescription
            }
        }
    }
}

// MARK: - 设置 / 修改本机保存的备份密码

struct BackupPasswordSetupSheet: View {
    var prompt: String? = nil
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                if let prompt {
                    Section {
                        Label(prompt, systemImage: "lock.trianglebadge.exclamationmark.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    BackupPasswordFields(password: $password, confirm: $confirm)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("密码只保存在本机钥匙串（仅此设备，不随 iCloud 钥匙串同步），自动备份和导出都可以使用。之前用其他密码加密的备份仍需原来的密码解密。")
                        Label("忘记密码将无法恢复加密备份，请另外妥善记录。", systemImage: "exclamationmark.lock.fill")
                            .foregroundStyle(.red)
                    }
                }
                if failed {
                    Text("保存到钥匙串失败，请稍后重试。").foregroundStyle(.red)
                }
            }
            .navigationTitle("备份密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if BackupPasswordStore.save(password) {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            onSaved()
                            dismiss()
                        } else {
                            failed = true
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!BackupPasswordFields.isValid(password, confirm))
                }
            }
        }
    }
}

// MARK: - 导入加密备份：输入密码

struct EncryptedImport: Identifiable {
    let id = UUID()
    let fileName: String
    let data: Data
}

struct BackupUnlockSheet: View {
    let item: EncryptedImport
    let onDecrypted: (LedgerBackup) -> Void

    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var working = false
    @State private var errorText: String?
    @State private var auth: SensitiveAuthRequest?
    @FocusState private var focused: Bool
    private let hasSaved = BackupPasswordStore.hasPassword

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(item.fileName, systemImage: "lock.doc.fill")
                        .lineLimit(2)
                    SecureField("备份密码", text: $password)
                        .textContentType(.password)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit { decrypt(password) }
                } header: {
                    Text("这是加密备份")
                } footer: {
                    Text("输入导出时设置的备份密码。密码错误或文件被修改都会无法解密，不会影响现有数据。")
                }
                if hasSaved {
                    Section {
                        Button {
                            lock.authenticateSensitive(reason: "使用已保存的备份密码解密", pending: $auth) {
                                if let saved = BackupPasswordStore.load() { decrypt(saved) }
                            }
                        } label: {
                            Label("使用已保存的密码（\(lock.passcodeEnabled && !lock.biometricsEnabled ? "App 密码" : lock.biometryName)）", systemImage: lock.biometryIcon)
                        }
                    }
                }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            }
            .disabled(working)
            .navigationTitle("解密备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("解密") { decrypt(password) }
                        .fontWeight(.semibold)
                        .disabled(password.isEmpty || working)
                }
            }
            .overlay { if working { CryptoProgressOverlay(title: "正在解密…") } }
            .sensitiveAuthSheet($auth, lock: lock)
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focused = true } }
        }
        .interactiveDismissDisabled(working)
    }

    private func decrypt(_ pw: String) {
        guard !pw.isEmpty, !working else { return }
        errorText = nil
        working = true
        let data = item.data
        Task { @MainActor in
            do {
                let backup = try await Task.detached(priority: .userInitiated) {
                    try BackupJSON.open(data, password: pw)
                }.value
                working = false
                onDecrypted(backup)
                dismiss()
            } catch {
                working = false
                errorText = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
