import SwiftUI
import UIKit

// 3.2 (23) 小票皮肤的「全局」统一：不在每个页面里各写一遍，而是集中在这里——
// 1. Font.ui(...)：所有页面的字号档位都走这里；默认皮肤原样返回系统字体，小票皮肤换成 Courier Prime / Special Elite；
// 2. Color.theme*：强调色 / 收入色 / 卡片底 / 页面底，默认皮肤原样返回系统颜色；
// 3. ThemedForm / ThemedList：表单和列表的行背景、分隔线、页面底色、默认字体和文字颜色；
// 4. ThemeChrome.apply：导航栏 / 标签栏 / 分段控件（UIKit 外观），切换皮肤时整棵界面重建一次生效。
// 皮肤存在 UserDefaults.standard（设备级），真实 / 防窥共用，不会暴露当前模式。

extension AppSkin {
    /// 当前皮肤（设备级设置）
    static var current: AppSkin {
        stored(UserDefaults.standard.string(forKey: SettingsKey.skin) ?? AppSkin.default.rawValue)
    }
}

// MARK: - 标签页根页面标题

extension View {
    /// 标签页根页面（明细 / 统计 / 资产 / 设置）的标题。
    /// 小票皮肤下 UIKit 大标题不绘制（3.2 实测：大标题位置只剩一块空白，换字体也一样），
    /// 所以小票皮肤用行内标题（与「记一笔」等页面同一条路径，已验证能显示）；默认皮肤保持系统大标题不变。
    func themedRootTitle(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(AppSkin.current == .receipt ? .inline : .automatic)
    }
}

// MARK: - 字体

extension Font {
    /// 页面通用字体：默认皮肤 = 系统字体（与之前完全一样）；小票皮肤 = 打字机字体（中文回落宋体）
    static func ui(_ style: Font.TextStyle, design: Font.Design? = nil) -> Font {
        guard AppSkin.current == .receipt else {
            if let design { return .system(style, design: design) }
            return .system(style)
        }
        return ReceiptTypeface.scaled(ReceiptTypeface.name(for: style), ReceiptTypeface.baseSize(style), relativeTo: style)
    }

    /// 固定字号的大数字（金额输入、净资产等）：默认皮肤 = 原来的系统圆体
    static func uiSystem(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        guard AppSkin.current == .receipt else { return .system(size: size, weight: weight, design: design) }
        return ReceiptTypeface.scaled(ReceiptTypeface.name(for: .body, weight: weight),
                                      size * 0.92, relativeTo: .largeTitle)
    }
}

// MARK: - 颜色

extension Color {
    /// 强调色：默认皮肤 = 资源里的 AccentColor
    static var themeAccent: Color {
        AppSkin.current == .receipt ? Color(uiColor: ThemeChrome.ui(.accent)) : Color.accentColor
    }
    /// 收入色：默认皮肤 = 系统绿色
    static var themeIncome: Color {
        AppSkin.current == .receipt ? Color(uiColor: ThemeChrome.ui(.income)) : Color.green
    }
    /// 卡片 / 行底色：默认皮肤 = secondarySystemGroupedBackground
    static var themeCard: Color {
        AppSkin.current == .receipt ? Color(uiColor: ThemeChrome.ui(.paper)) : Color(.secondarySystemGroupedBackground)
    }
    /// 页面底色：默认皮肤 = systemGroupedBackground
    static var themeBackdrop: Color {
        AppSkin.current == .receipt ? Color(uiColor: ThemeChrome.ui(.backdrop)) : Color(.systemGroupedBackground)
    }
    /// 3.5 (26) 分类 / 账户颜色：默认皮肤原色；小票皮肤降饱和成墨水色（随浅色 / 深色切换）
    static func skinTint(_ hex: String) -> Color {
        guard AppSkin.current == .receipt else { return Color(hex: hex) }
        let light = ReceiptStyle.mutedRGB(hex, dark: false), dark = ReceiptStyle.mutedRGB(hex, dark: true)
        return Color(uiColor: UIColor { trait in
            let c = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    /// 浅填充（胶囊 / 输入框底）：默认皮肤 = 原来的系统填充色
    static func themeFill(_ system: UIColor) -> Color {
        AppSkin.current == .receipt ? Color(uiColor: ThemeChrome.ui(.rule)).opacity(0.45) : Color(system)
    }
}

// MARK: - 表单 / 列表

/// 小票皮肤下：注入主题、强调色、文字颜色（.secondary 等层级色随之变成暖灰）、默认打字机字体
struct ThemedChrome: ViewModifier {
    @AppStorage(SettingsKey.skin, store: .standard) private var skinRaw = AppSkin.default.rawValue
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let theme = AppTheme.resolve(skin: AppSkin.stored(skinRaw), scheme: scheme)
        if theme.isReceipt {
            content
                .environment(\.appTheme, theme)
                .tint(theme.accent)
                .foregroundStyle(theme.ink)
                .font(.ui(.body))
        } else {
            content
        }
    }
}

/// 替代 Form：默认皮肤就是原来的 Form；小票皮肤换纸色行、虚线色分隔、暖色页面底
struct ThemedForm<Content: View>: View {
    private let content: Content
    @AppStorage(SettingsKey.skin, store: .standard) private var skinRaw = AppSkin.default.rawValue
    @Environment(\.colorScheme) private var scheme

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        let theme = AppTheme.resolve(skin: AppSkin.stored(skinRaw), scheme: scheme)
        if theme.isReceipt {
            Form {
                Group { content }
                    .listRowBackground(theme.paper)
                    .listRowSeparatorTint(theme.rule)
                    .listSectionSeparatorTint(theme.rule)
            }
            .scrollContentBackground(.hidden)
            .background(theme.backdrop.ignoresSafeArea())
            .modifier(ThemedChrome())
        } else {
            Form { content }
        }
    }
}

/// 替代 List：同 ThemedForm
struct ThemedList<Content: View>: View {
    private let content: Content
    @AppStorage(SettingsKey.skin, store: .standard) private var skinRaw = AppSkin.default.rawValue
    @Environment(\.colorScheme) private var scheme

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        let theme = AppTheme.resolve(skin: AppSkin.stored(skinRaw), scheme: scheme)
        if theme.isReceipt {
            List {
                Group { content }
                    .listRowBackground(theme.paper)
                    .listRowSeparatorTint(theme.rule)
                    .listSectionSeparatorTint(theme.rule)
            }
            .scrollContentBackground(.hidden)
            .background(theme.backdrop.ignoresSafeArea())
            .modifier(ThemedChrome())
        } else {
            List { content }
        }
    }
}

extension View {
    /// 页面 / 弹窗根视图：小票皮肤下注入主题和默认字体颜色（默认皮肤无变化）
    func themedChrome() -> some View { modifier(ThemedChrome()) }
}

// MARK: - UIKit 外观（导航栏 / 标签栏 / 分段控件）

@MainActor
enum ThemeChrome {
    enum Token { case accent, income, ink, faint, rule, paper, backdrop }

    /// 随浅色 / 深色自动切换的小票色
    nonisolated static func ui(_ token: Token) -> UIColor {
        let pair: ReceiptStyle.Pair
        switch token {
        case .accent: pair = ReceiptStyle.accent
        case .income: pair = ReceiptStyle.income
        case .ink: pair = ReceiptStyle.ink
        case .faint: pair = ReceiptStyle.faint
        case .rule: pair = ReceiptStyle.rule
        case .paper: pair = ReceiptStyle.paper
        case .backdrop: pair = ReceiptStyle.backdrop
        }
        let light = rgb(pair.light), dark = rgb(pair.dark)
        return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    nonisolated private static func rgb(_ hex: String) -> UIColor {
        let v = UInt64(hex.dropFirst(), radix: 16) ?? 0
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// 启动时：只有小票皮肤才改 UIKit 外观（默认皮肤完全不碰，保持系统原样）
    static func applyAtLaunch() {
        if AppSkin.current == .receipt { apply(.receipt) }
    }

    /// 设置导航栏 / 标签栏 / 分段控件外观。新建的栏才会生效，所以切换皮肤后 RootView 会重建界面。
    static func apply(_ skin: AppSkin) {
        let nav = UINavigationBar.appearance()
        let tab = UITabBar.appearance()
        let seg = UISegmentedControl.appearance()
        guard skin == .receipt else {
            // 切回默认：恢复系统默认外观
            nav.standardAppearance = UINavigationBarAppearance()
            nav.scrollEdgeAppearance = nil
            nav.compactAppearance = nil
            nav.compactScrollEdgeAppearance = nil
            tab.standardAppearance = UITabBarAppearance()
            tab.scrollEdgeAppearance = nil
            seg.selectedSegmentTintColor = nil
            seg.setTitleTextAttributes(nil, for: .normal)
            seg.setTitleTextAttributes(nil, for: .selected)
            return
        }
        let ink = ui(.ink), faint = ui(.faint), accent = ui(.accent), rule = ui(.rule)
        // 栏上的字体必须是普通 UIFont（见 ReceiptTypeface.barFont）
        let mono = { (size: CGFloat) in ReceiptTypeface.barFont(ReceiptTypeface.mono, size: size) }
        let bold = { (size: CGFloat) in ReceiptTypeface.barFont(ReceiptTypeface.monoBold, size: size) }

        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = ui(.backdrop)
        bar.shadowColor = .clear  // 3.5 (26)：导航栏下不再画分隔线，标题和纸面连成一体
        bar.titleTextAttributes = [.font: bold(17), .foregroundColor: ink]
        // 小票皮肤的标签页根页面改用行内标题（见 themedRootTitle），这里的大标题字体只作兜底
        bar.largeTitleTextAttributes = [.font: bold(30), .foregroundColor: ink]
        let button = UIBarButtonItemAppearance()
        button.normal.titleTextAttributes = [.font: mono(17), .foregroundColor: accent]
        bar.buttonAppearance = button
        bar.backButtonAppearance = button
        let done = UIBarButtonItemAppearance()
        done.normal.titleTextAttributes = [.font: bold(17), .foregroundColor: accent]
        bar.doneButtonAppearance = done
        nav.standardAppearance = bar
        nav.scrollEdgeAppearance = bar
        nav.compactAppearance = bar
        nav.compactScrollEdgeAppearance = bar

        let tabs = UITabBarAppearance()
        tabs.configureWithOpaqueBackground()
        tabs.backgroundColor = ui(.paper)
        tabs.shadowColor = .clear
        for item in [tabs.stackedLayoutAppearance, tabs.inlineLayoutAppearance, tabs.compactInlineLayoutAppearance] {
            item.normal.iconColor = faint
            item.normal.titleTextAttributes = [.font: mono(10), .foregroundColor: faint]
            item.selected.iconColor = accent
            item.selected.titleTextAttributes = [.font: bold(10), .foregroundColor: accent]
        }
        tab.standardAppearance = tabs
        tab.scrollEdgeAppearance = tabs

        seg.selectedSegmentTintColor = ui(.paper)
        seg.setTitleTextAttributes([.font: mono(13), .foregroundColor: faint], for: .normal)
        seg.setTitleTextAttributes([.font: bold(13), .foregroundColor: accent], for: .selected)
    }
}

// MARK: - 空状态

/// 替代 ContentUnavailableView：默认皮肤原样使用系统空状态；小票皮肤用打字机字体 + 暖灰图标
struct ThemedEmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    var description: Text? = nil
    private let actions: Actions
    @Environment(\.appTheme) private var theme

    init(_ title: String, systemImage: String, description: Text? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        if theme.isReceipt {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(theme.faint)
                Text(title)
                    .font(theme.display(.title3))
                    .foregroundStyle(theme.ink)
                    .multilineTextAlignment(.center)
                if let description {
                    description
                        .font(theme.mono(.subheadline))
                        .foregroundStyle(theme.faint)
                        .multilineTextAlignment(.center)
                }
                actions
                    .font(theme.mono(.body, weight: .bold))
                    .padding(.top, 4)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
        } else {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                if let description { description }
            } actions: {
                actions
            }
        }
    }
}

extension ThemedEmptyState where Actions == EmptyView {
    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.init(title, systemImage: systemImage, description: description) { EmptyView() }
    }
}
