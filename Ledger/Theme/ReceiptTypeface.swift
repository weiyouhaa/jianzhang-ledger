import CoreText
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// 3.2 (23) 小票皮肤字体（只依赖 SwiftUI + CoreText，CI 在 macOS 上渲染预览时也能用）。
// - 大标题：Special Elite（Apache 2.0，做旧打字机，接近参考图「Receipt Atlas / RECEIPT」）
// - 正文 / 数字：Courier Prime（SIL OFL 1.1，干净的打字机等宽）
// - 中文：两款字体都没有中文字形，用 CoreText 级联（cascade list）回落到宋体（有铅字感）；
//   设备上没有宋体时 CoreText 继续回落到系统中文字体（苹方）。
// 字体文件和许可证在 Ledger/Resources/Fonts/，Info.plist 的 UIAppFonts 注册。
enum ReceiptTypeface {
    static let display = "SpecialElite-Regular"
    static let mono = "CourierPrime-Regular"
    static let monoBold = "CourierPrime-Bold"
    static let fileNames = ["SpecialElite-Regular.ttf", "CourierPrime-Regular.ttf", "CourierPrime-Bold.ttf"]

    /// 中文回落：宋体（常规 / 粗）
    static let cjkSerif = "STSongti-SC-Regular"
    static let cjkSerifBold = "STSongti-SC-Bold"

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

    /// UIKit（导航栏 / 标签栏 / 分段控件）用
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

    /// 拉丁字母 / 数字用打字机字体，中文按级联列表回落到宋体
    static func ctFont(_ name: String, size: CGFloat) -> CTFont {
        let key = "\(name)|\(size)"
        cache.lock.lock()
        if let f = cache.fonts[key] { cache.lock.unlock(); return f }
        cache.lock.unlock()

        let resolved = isAvailable(name) ? name : systemFallback(for: name)
        let cjk = (name == mono) ? cjkSerif : cjkSerifBold
        let cascade = [CTFontDescriptorCreateWithNameAndSize(cjk as CFString, size)]
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
