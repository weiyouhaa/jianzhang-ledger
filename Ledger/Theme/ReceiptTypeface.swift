import CoreText
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// 3.2 (23) 小票皮肤字体（只依赖 SwiftUI + CoreText，CI 在 macOS 上渲染预览时也能用）。
// - 大标题 / 粗体数字：Special Elite（Apache 2.0，做旧打字机，与参考图「Receipt Atlas / RECEIPT」同款）
// - 正文：Courier Prime（SIL OFL 1.1，干净的打字机等宽）
// - 中文：3.6 (27) 起打包「思源宋体」同源的 Noto Serif SC（SIL OFL 1.1）子集，改名为 JZ Noto Serif SC，
//   常规 / 粗体两档，收录 GB2312 全部 + App 内所有中文 + 全角标点。两款拉丁字体都没有中文字形，
//   用 CoreText 级联（cascade list）回落：打包宋体 → 系统宋体（有的话）→ 系统中文字体（苹方）。
//   子集外的生僻字（比如商户名）自动走后两级回落，不会出现方框。
// 字体文件和许可证在 Ledger/Resources/Fonts/，Info.plist 的 UIAppFonts 注册。
enum ReceiptTypeface {
    static let display = "SpecialElite-Regular"
    static let mono = "CourierPrime-Regular"
    static let monoBold = "CourierPrime-Bold"
    static let fileNames = [
        "SpecialElite-Regular.ttf", "CourierPrime-Regular.ttf", "CourierPrime-Bold.ttf",
        "JZNotoSerifSC-Regular.ttf", "JZNotoSerifSC-Bold.ttf",
    ]

    /// 中文：打包的宋体子集（常规 / 粗）
    static let cjkSerif = "JZNotoSerifSC-Regular"
    static let cjkSerifBold = "JZNotoSerifSC-Bold"
    /// 打包字体缺字时的第二级回落：系统宋体（iOS 默认不带，macOS 预览渲染有）
    static let systemSerif = "STSongti-SC-Regular"
    static let systemSerifBold = "STSongti-SC-Bold"

    /// 中文级联列表：只放确实已注册的字体（3.3 的空白标题就是级联到不存在的字体引起的），最后由系统补苹方
    static func cjkCascadeNames(for name: String) -> [String] {
        let regular = (name == mono)
        return [regular ? cjkSerif : cjkSerifBold, regular ? systemSerif : systemSerifBold].filter(isAvailable)
    }

    /// 打包字体加载失败时的兜底（系统自带 Courier New）
    private static func systemFallback(for name: String) -> String {
        name == mono ? "CourierNewPSMT" : "CourierNewPS-BoldMT"
    }

    // MARK: SwiftUI Font

    /// 固定字号（不随动态字体缩放）：快捷指令片段等需要精确控制高度的地方
    static func fixed(_ name: String, _ size: CGFloat) -> Font {
        Font(ctFont(name, size: size))
    }

    /// 随动态字体缩放：App 内界面
    static func scaled(_ name: String, _ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        Font(ctFont(name, size: scaledSize(size, relativeTo: style)))
    }

    /// 某个系统字号档位在小票皮肤下用哪款字体：大标题做旧打字机，标题 / 头条粗体等宽，其余常规等宽
    static func name(for style: Font.TextStyle, weight: Font.Weight? = nil) -> String {
        switch style {
        case .largeTitle, .title, .title2: return display
        default: break
        }
        if let weight, weight == .semibold || weight == .bold || weight == .heavy || weight == .black { return monoBold }
        switch style {
        case .title3, .headline: return monoBold
        default: return mono
        }
    }

    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
    }

    static func scaledSize(_ size: CGFloat, relativeTo style: Font.TextStyle) -> CGFloat {
        #if canImport(UIKit)
        return UIFontMetrics(forTextStyle: uiStyle(style)).scaledValue(for: size)
        #else
        return size
        #endif
    }

    #if canImport(UIKit)
    private static func uiStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .body: return .body
        case .callout: return .callout
        case .subheadline: return .subheadline
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }

    /// UIKit 栏（导航栏 / 标签栏 / 分段控件）用：UIFont + UIFontDescriptor 级联，不用桥接的 CTFont。
    /// 3.3 (24)：桥接的 CTFont（级联到 iOS 上并不存在的宋体）放进导航栏标题属性后，中文标题整段不绘制，
    /// 「简账 / 统计 / 资产 / 设置」位置只剩空白。3.6 (27)：级联里只放已注册的打包宋体（isAvailable 校验过），
    /// 用 UIKit 自己的 cascadeList 属性；打包宋体不可用时与 3.3 起的做法一样，交给系统回落到苹方。
    static func barFont(_ name: String, size: CGFloat) -> UIFont {
        let resolved = isAvailable(name) ? name : systemFallback(for: name)
        guard let base = UIFont(name: resolved, size: size) else {
            return .systemFont(ofSize: size, weight: name == mono ? .regular : .bold)
        }
        let cascade = cjkCascadeNames(for: name).prefix(1).map { UIFontDescriptor(name: $0, size: size) }
        guard !cascade.isEmpty else { return base }
        let desc = base.fontDescriptor.addingAttributes([.cascadeList: Array(cascade)])
        return UIFont(descriptor: desc, size: size)
    }

    /// 桥接的 CTFont（带宋体级联），只给需要 UIFont 的非栏位置用
    static func uiFont(_ name: String, size: CGFloat) -> UIFont {
        // CTFont 与 UIFont 免费桥接
        unsafeBitCast(ctFont(name, size: size), to: UIFont.self)
    }
    #endif

    // MARK: CoreText

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var fonts: [String: CTFont] = [:]
        var available: [String: Bool] = [:]
    }
    private static let cache = Cache()

    /// 拉丁字母 / 数字用打字机字体，中文按级联列表回落到打包宋体 → 系统宋体 → 苹方
    static func ctFont(_ name: String, size: CGFloat) -> CTFont {
        let key = "\(name)|\(size)"
        cache.lock.lock()
        if let f = cache.fonts[key] { cache.lock.unlock(); return f }
        cache.lock.unlock()

        let resolved = isAvailable(name) ? name : systemFallback(for: name)
        let cascade = cjkCascadeNames(for: name).map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, size) }
        let attrs: [CFString: Any] = [
            kCTFontNameAttribute: resolved,
            kCTFontCascadeListAttribute: cascade,
        ]
        let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(desc, size, nil)

        cache.lock.lock()
        cache.fonts[key] = font
        cache.lock.unlock()
        return font
    }

    /// 字体是否已注册（PostScript 名完全一致才算，避免 CoreText 静默替换成 Helvetica）
    static func isAvailable(_ name: String) -> Bool {
        cache.lock.lock()
        if let v = cache.available[name] { cache.lock.unlock(); return v }
        cache.lock.unlock()
        let probe = CTFontCreateWithName(name as CFString, 12, nil)
        let ok = (CTFontCopyPostScriptName(probe) as String) == name
        cache.lock.lock()
        cache.available[name] = ok
        cache.lock.unlock()
        return ok
    }

    /// 预览渲染（macOS 命令行）用：从目录注册打包字体。App 内由 Info.plist UIAppFonts 注册，不需要调用。
    @discardableResult
    static func registerFonts(in directory: URL) -> Int {
        var count = 0
        for file in fileNames {
            let url = directory.appendingPathComponent(file)
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) { count += 1 }
        }
        cache.lock.lock()
        cache.available.removeAll()
        cache.fonts.removeAll()
        cache.lock.unlock()
        return count
    }
}
