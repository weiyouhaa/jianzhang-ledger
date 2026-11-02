// CI（macOS）上用 ImageRenderer 把识图片段 / 小票皮肤渲染成 PNG（只用合成示例数据），方便不装 App 也能看效果。
// 用法：renderpreview <输出目录>
// 注意：小票各页面的图是「示意稿」——按 App 里同一套颜色 / 字体 / 规则手工拼出来的，
// 不是真机截图（Form / List / TabBar 等系统控件在 ImageRenderer 里画不出来）。
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct RenderPreview {
    @MainActor
    static func main() {
        let out = CommandLine.arguments.dropFirst().first ?? "."
        _ = ReceiptTypeface.registerFonts(in: URL(fileURLWithPath: "Ledger/Resources/Fonts"))
        for name in [ReceiptTypeface.display, ReceiptTypeface.mono, ReceiptTypeface.monoBold] {
            print("font \(name): \(ReceiptTypeface.isAvailable(name) ? "OK" : "MISSING")")
        }
        let s = ReviewRow.samples
        func snippet(_ rows: [ReviewRow], page: Int, budget: CGFloat? = ReceiptStackView.defaultBudget) -> some View {
            ReceiptStackView(title: "识别结果", rows: SnippetPager.slice(rows, page: page),
                             engineLine: "识别引擎：Apple 智能 · 模型 6.9 秒",
                             countText: SnippetPager.countText(rows, page: page),
                             totals: SnippetPager.totals(rows, format: { String(format: "¥%.2f", $0) }),
                             heightBudget: budget)
        }
        func box<V: View>(_ label: String, _ view: V, _ p: ReceiptPalette) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption2).foregroundStyle(p.faint)
                view
                    .frame(width: 360)
                    .frame(maxHeight: ReceiptStackView.defaultBudget, alignment: .top)
                    .overlay(alignment: .bottom) {
                        // 320pt 高度预算参考线
                        Rectangle().fill(Color.red.opacity(0.25)).frame(height: 1).offset(y: 1)
                    }
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.05)))
            }
        }
        func panel(_ scheme: ColorScheme) -> some View {
            let p = ReceiptPalette.paper(scheme)
            return VStack(alignment: .leading, spacing: 14) {
                Text(scheme == .dark ? "深色模式 · 高度预算 320pt（红线）" : "浅色模式 · 高度预算 320pt（红线）")
                    .font(.caption.bold()).foregroundStyle(p.faint)
                box("1 笔", snippet([s[0]], page: 0), p)
                box("2 笔", snippet([s[0], s[4]], page: 0), p)
                box("5 笔 · 第 1 页（第 1–2 笔）", snippet(s, page: 0), p)
                box("5 笔 · 第 2 页（第 3–4 笔）", snippet(s, page: 1), p)
                box("5 笔 · 第 3 页（第 5 笔）", snippet(s, page: 2), p)
            }
            .padding(16)
            .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.95))
            .environment(\.colorScheme, scheme)
        }
        // 不限高度的原大小版本，用来核对「信息是否齐全」
        func fullPanel(_ scheme: ColorScheme) -> some View {
            let p = ReceiptPalette.paper(scheme)
            return VStack(alignment: .leading, spacing: 14) {
                Text("原大小（不限高度）· 用来核对字段是否齐全").font(.caption.bold()).foregroundStyle(p.faint)
                ForEach(0..<3, id: \.self) { page in
                    snippet(s, page: page, budget: nil).frame(width: 360)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.05)))
                }
            }
            .padding(16)
            .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.95))
            .environment(\.colorScheme, scheme)
        }
        write(HStack(alignment: .top, spacing: 0) { panel(.light); panel(.dark); fullPanel(.light) },
              to: "\(out)/preview-snippet", ext: imageExt)
        // 3.4 (25) 放大加粗后的片段：长商户名、完整时间、信用卡账户都不截断
        func panel34(_ scheme: ColorScheme) -> some View {
            let p = ReceiptPalette.paper(scheme)
            let long = ReviewRow.longSample
            return VStack(alignment: .leading, spacing: 14) {
                Text(scheme == .dark ? "3.4 · 深色 · 高度预算 320pt（红线）" : "3.4 · 浅色 · 高度预算 320pt（红线）")
                    .font(.caption.bold()).foregroundStyle(p.faint)
                box("1 笔 · 长商户名", snippet([long], page: 0), p)
                box("1 笔 · 带重复提醒", snippet([s[1]], page: 0), p)
                box("2 笔", snippet([long, s[3]], page: 0), p)
                box("转账 / 还款", snippet([s[4]], page: 0), p)
            }
            .padding(16)
            .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.95))
            .environment(\.colorScheme, scheme)
        }
        write(HStack(alignment: .top, spacing: 0) { panel34(.light); panel34(.dark) },
              to: "\(out)/preview-snippet-3.4", ext: imageExt)
        write(ScreensDemo(), to: "\(out)/preview-receipt-screens", ext: imageExt)
        write(FontDemo(), to: "\(out)/preview-fonts", ext: imageExt)
        write(SkinChromeDemo(), to: "\(out)/preview-skins", ext: imageExt)
        write(EditorCardDemo(), to: "\(out)/preview-editor-card", ext: imageExt)
        write(StickyEditorDemo(), to: "\(out)/preview-editor-sticky", ext: imageExt)
        write(DayCardDemo(), to: "\(out)/preview-day-card", ext: imageExt)
    }

    static let imageExt = "png"

    @MainActor
    static func write<V: View>(_ view: V, to stem: String, ext: String) {
        let path = stem + "." + ext
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage,
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.\(ext)" as CFString, 1, nil)
        else { print("render failed: \(path)"); exit(1) }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { print("write failed: \(path)"); exit(1) }
        print("wrote \(path) \(cg.width)x\(cg.height)")
    }
}

// MARK: - 字体预览

struct FontDemo: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) { panel(.light); panel(.dark) }
    }

    private func panel(_ scheme: ColorScheme) -> some View {
        let p = ReceiptPalette.paper(scheme)
        return VStack(alignment: .leading, spacing: 10) {
            Text("SPECIAL ELITE · 标题").font(.caption2).foregroundStyle(p.faint)
            Text("简账 RECEIPT 2026").font(ReceiptTypeface.fixed(ReceiptTypeface.display, 30))
            Text("本月结余 ¥1,234.50").font(ReceiptTypeface.fixed(ReceiptTypeface.display, 22))
            DashedRule(color: p.rule)
            Text("COURIER PRIME BOLD · 金额 / 标题").font(.caption2).foregroundStyle(p.faint)
            Text("-¥39.80  +¥200.00  ¥1,000.00").font(ReceiptTypeface.fixed(ReceiptTypeface.monoBold, 20))
            Text("示例烧腊饭店 · 餐饮").font(ReceiptTypeface.fixed(ReceiptTypeface.monoBold, 17))
            DashedRule(color: p.rule)
            Text("COURIER PRIME · 正文 / 数字").font(.caption2).foregroundStyle(p.faint)
            Text("0123456789 ¥ · − … ABCDEFG abcdefg").font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 15))
            Text("时间 2026年10月19日 12:18  来源 云闪付").font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 13))
            Text("备注 午餐 两人份  优惠 示例立减 2.00").font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 11))
            DashedRule(color: p.rule)
            Text("中文回落：宋体（系统没有时由系统自动换成苹方）").font(.caption2).foregroundStyle(p.faint)
            Text("付款 储蓄卡-示例银行 → 未选信用卡").font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 14))
        }
        .foregroundStyle(p.ink)
        .padding(20)
        .frame(width: 400, alignment: .leading)
        .background(p.paper)
        .environment(\.colorScheme, scheme)
    }
}

// MARK: - 小票皮肤各页面示意

struct ScreensDemo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                phone(.light, "明细") { home(.light) }
                phone(.light, "统计") { stats(.light) }
                phone(.light, "资产") { assets(.light) }
                phone(.light, "设置") { settings(.light) }
            }
            HStack(alignment: .top, spacing: 16) {
                phone(.light, "记一笔", tabs: false) { editor(.light) }
                phone(.light, "选择账户", tabs: false) { picker(.light) }
                phone(.dark, "设置", tabs: true) { settings(.dark) }
                lock(.light)
            }
        }
        .padding(16)
        .background(Color(white: 0.85))
    }

    // MARK: 外框：导航栏 + 内容 + 标签栏
    private func phone<C: View>(_ scheme: ColorScheme, _ title: String, tabs: Bool = true,
                                @ViewBuilder _ content: () -> C) -> some View {
        let p = ReceiptPalette.paper(scheme)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                if tabs {
                    Text(title).font(ReceiptTypeface.fixed(ReceiptTypeface.display, 30)).padding(.top, 10)
                } else {
                    HStack {
                        Text("取消").font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 15)).foregroundStyle(p.accent)
                        Spacer()
                        Text(title).font(ReceiptTypeface.fixed(ReceiptTypeface.monoBold, 16))
                        Spacer()
                        Text("保存").font(ReceiptTypeface.fixed(ReceiptTypeface.monoBold, 15)).foregroundStyle(p.accent)
                    }
                    .padding(.vertical, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            Rectangle().fill(p.rule).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if tabs {
                Rectangle().fill(p.rule).frame(height: 0.5)
                HStack {
                    tab("list.bullet.rectangle.portrait", "明细", title == "明细", p)
                    tab("chart.pie.fill", "统计", title == "统计", p)
                    tab("wallet.pass.fill", "资产", title == "资产", p)
                    tab("gearshape.fill", "设置", title == "设置", p)
                }
                .padding(.vertical, 8)
                .background(p.paper)
            } else {
                // 底部操作栏（BottomActionBar）
                VStack(spacing: 0) {
                    DashedRule(color: p.rule)
                    HStack {
                        Text("删除").foregroundStyle(p.accent)
                        Spacer()
                        Text("保存并再记一笔")
                    }
                    .font(ReceiptTypeface.fixed(ReceiptTypeface.monoBold, 14))
                    .padding(12)
                }
                .background(p.paper)
            }
        }
        .foregroundStyle(p.ink)
        .frame(width: 260, height: 520)
        .background(p.backdrop)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(alignment: .topTrailing) {
            Text(scheme == .dark ? "深色" : "浅色").font(.caption2).padding(6).foregroundStyle(p.faint)
        }
        .environment(\.colorScheme, scheme)
    }

    private func tab(_ icon: String, _ label: String, _ on: Bool, _ p: ReceiptPalette) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 17))
            Text(label).font(ReceiptTypeface.fixed(on ? ReceiptTypeface.monoBold : ReceiptTypeface.mono, 10))
        }
        .foregroundStyle(on ? p.accent : p.faint)
        .frame(maxWidth: .infinity)
    }

    // MARK: 共用小部件
    private func header(_ text: String, _ p: ReceiptPalette) -> some View {
        Text(text).font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 11)).foregroundStyle(p.faint).padding(.leading, 6)
    }
    private func card<C: View>(_ p: ReceiptPalette, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { c() }
            .background(p.paper)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(p.rule, style: StrokeStyle(lineWidth: 0.8, dash: [4, 3])))
    }
    private func row(_ label: String, _ value: String = "", _ p: ReceiptPalette, chevron: Bool = true, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 14))
                Spacer()
                Text(value).font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 13)).foregroundStyle(p.faint)
                if chevron { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.faint) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            if !last { Rectangle().fill(p.rule).frame(height: 0.5).padding(.leading, 12) }
        }
    }
    private func toggle(_ label: String, _ on: Bool, _ p: ReceiptPalette, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 14))
                Spacer()
                Capsule().fill(on ? p.accent : p.rule).frame(width: 40, height: 24)
                    .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).padding(2) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if !last { Rectangle().fill(p.rule).frame(height: 0.5).padding(.leading, 12) }
        }
    }
    private func segmented(_ items: [String], _ sel: Int, _ p: ReceiptPalette) -> some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                Text(items[i])
                    .font(ReceiptTypeface.fixed(i == sel ? ReceiptTypeface.monoBold : ReceiptTypeface.mono, 12))
                    .foregroundStyle(i == sel ? p.accent : p.faint)
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(i == sel ? p.paper : .clear))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(p.rule.opacity(0.45)))
    }
    private func money(_ s: String, _ size: CGFloat = 14) -> Text {
        Text(s).font(ReceiptTypeface.fixed(ReceiptTypeface.monoBold, size))
    }

    // MARK: 各页面
    @ViewBuilder private func home(_ scheme: ColorScheme) -> some View {
        let p = ReceiptPalette.paper(scheme)
        card(p) {
            VStack(alignment: .leading, spacing: 6) {
                Text("2026年10月 · 12 笔").font(ReceiptTypeface.fixed(ReceiptTypeface.monoBold, 13))
                DashedRule(color: p.rule)
                Text("本月结余").font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 11)).foregroundStyle(p.faint)
                money("¥1,234.50", 24)
                DashedRule(color: p.rule)
                HStack { money("支 ¥2,000.00", 12); Spacer(); money("收 ¥3,234.50", 12).foregroundStyle(p.income) }
            }
            .padding(10)
        }
        header("10月19日 周一 · 3 笔", p)
        card(p) {
            ForEach(Array(ReviewRow.samples.prefix(3).enumerated()), id: \.offset) { i, r in
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: r.icon).font(.system(size: 13)).foregroundStyle(p.accent).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.categoryName).font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 13))
                            Text(r.note).font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 10)).foregroundStyle(p.faint)
                        }
                        Spacer()
                        money(r.amountText, 13)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    if i < 2 { Rectangle().fill(p.rule).frame(height: 0.5).padding(.leading, 40) }
                }
            }
        }
    }

    @ViewBuilder private func stats(_ scheme: ColorScheme) -> some View {
        let p = ReceiptPalette.paper(scheme)
        segmented(["支出", "收入"], 0, p)
        segmented(["周", "月", "年", "自定义"], 1, p)
        card(p) {
            VStack(alignment: .leading, spacing: 8) {
                Text("分类占比").font(ReceiptTypeface.fixed(ReceiptTypeface.monoBold, 13))
                ForEach([("餐饮", 0.62), ("交通", 0.24), ("购物", 0.14)], id: \.0) { name, v in
                    HStack(spacing: 6) {
                        Text(name).font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 12)).frame(width: 36, alignment: .leading)
                        GeometryReader { g in
                            Rectangle().fill(p.accent.opacity(0.75)).frame(width: g.size.width * v)
                        }
                        .frame(height: 8)
                        Text("\(Int(v * 100))%").font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 11)).foregroundStyle(p.faint)
                    }
                }
            }
            .padding(10)
        }
        // 空状态
        VStack(spacing: 8) {
            Image(systemName: "chart.pie").font(.system(size: 34, weight: .light)).foregroundStyle(p.faint)
            Text("暂无收入数据").font(ReceiptTypeface.fixed(ReceiptTypeface.display, 18))
            Text("换个时间段看看吧").font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 12)).foregroundStyle(p.faint)
        }
        .frame(maxWidth: .infinity).padding(.top, 8)
    }

    @ViewBuilder private func assets(_ scheme: ColorScheme) -> some View {
        let p = ReceiptPalette.paper(scheme)
        card(p) {
            VStack(alignment: .leading, spacing: 4) {
                Text("净资产").font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 11)).foregroundStyle(p.faint)
                money("¥12,345.60", 26)
            }
            .padding(10)
        }
        header("储蓄 / 电子钱包", p)
        card(p) {
            row("储蓄卡-示例银行", "¥8,000.00", p)
            row("支付宝", "¥3,000.00", p)
            row("微信", "¥1,345.60", p, last: true)
        }
        header("信用卡", p)
        card(p) { row("示例信用卡", "-¥0.00", p, last: true) }
    }

    @ViewBuilder private func settings(_ scheme: ColorScheme) -> some View {
        let p = ReceiptPalette.paper(scheme)
        header("外观", p)
        card(p) {
            row("皮肤", "小票", p)
            toggle("显示每日结余", true, p, last: true)
        }
        header("安全", p)
        card(p) {
            toggle("App 密码", true, p)
            toggle("面容 ID 解锁", false, p)
            row("防窥设置", "", p, last: true)
        }
        header("数据", p)
        card(p) {
            row("备份与恢复", "", p)
            row("导入账单", "", p, last: true)
        }
    }

    @ViewBuilder private func editor(_ scheme: ColorScheme) -> some View {
        let p = ReceiptPalette.paper(scheme)
        segmented(["支出", "收入", "转账", "还款"], 0, p)
        card(p) {
            VStack(alignment: .trailing, spacing: 2) {
                money("¥39.80", 34).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(10)
        }
        header("详情", p)
        card(p) {
            row("分类", "餐饮", p)
            row("账户", "储蓄卡-示例银行", p)
            row("时间", "10月19日 12:18", p)
            row("备注", "午餐 两人份", p, chevron: false, last: true)
        }
    }

    @ViewBuilder private func picker(_ scheme: ColorScheme) -> some View {
        let p = ReceiptPalette.paper(scheme)
        header("选择付款账户", p)
        card(p) {
            ForEach(["储蓄卡-示例银行", "支付宝", "微信", "现金"], id: \.self) { name in
                VStack(spacing: 0) {
                    HStack {
                        Text(name).font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 14))
                        Spacer()
                        if name == "支付宝" { Image(systemName: "checkmark").foregroundStyle(p.accent) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    Rectangle().fill(p.rule).frame(height: 0.5).padding(.leading, 12)
                }
            }
        }
    }

    private func lock(_ scheme: ColorScheme) -> some View {
        let p = ReceiptPalette.paper(scheme)
        return VStack(spacing: 18) {
            Image(systemName: "lock.fill").font(.system(size: 26)).foregroundStyle(p.accent)
                .padding(14).background(Circle().fill(p.accent.opacity(0.15)))
            Text("输入密码").font(ReceiptTypeface.fixed(ReceiptTypeface.monoBold, 18))
            HStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { i in
                    Circle().strokeBorder(p.ink.opacity(0.6), lineWidth: 1.2)
                        .background(Circle().fill(i < 2 ? p.ink : .clear)).frame(width: 12, height: 12)
                }
            }
            VStack(spacing: 10) {
                ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]], id: \.self) { r in
                    HStack(spacing: 18) {
                        ForEach(r, id: \.self) { k in
                            Text(k).font(ReceiptTypeface.fixed(ReceiptTypeface.mono, 26))
                                .frame(width: 56, height: 56)
                                .background(Circle().fill(k.isEmpty || k == "⌫" ? .clear : p.ink.opacity(0.08)))
                        }
                    }
                }
            }
            Text("锁屏（真实 / 防窥外观相同）").font(.caption2).foregroundStyle(p.faint)
        }
        .foregroundStyle(p.ink)
        .frame(width: 260, height: 520)
        .background(p.backdrop)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .environment(\.colorScheme, scheme)
    }
}
