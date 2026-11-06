import SwiftUI

/// 4.1 小票纸张方案（浅色下棉浆白 / 原浆暖黄；深色统一黑金炭票）
enum ReceiptPaper: String, CaseIterable, Identifiable {
    case cotton = "cotton"
    case vintage = "vintage"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .cotton: return "棉浆白纸"
        case .vintage: return "原浆暖黄"
        }
    }
    var detail: String {
        switch self {
        case .cotton: return "偏冷的米白热敏纸，接近 Aesop 小票"
        case .vintage: return "原浆暖黄热敏纸，更像复古收银卷纸"
        }
    }

    static var current: ReceiptPaper {
        ReceiptPaper(rawValue: UserDefaults.standard.string(forKey: SettingsKey.receiptPaper) ?? "") ?? .cotton
    }
}

/// 4.1 明细页悬浮记账方案
enum ReceiptFabStyle: String, CaseIterable, Identifiable {
    case seal = "seal"
    case capsule = "capsule"
    case pulltab = "pulltab"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .seal: return "双联火漆印章"
        case .capsule: return "中置出纸胶囊"
        case .pulltab: return "侧边黄铜拉环"
        }
    }

    static var current: ReceiptFabStyle {
        ReceiptFabStyle(rawValue: UserDefaults.standard.string(forKey: SettingsKey.receiptFab) ?? "") ?? .seal
    }
}

extension ReceiptStyle {
    /// 按纸张 + 明暗解析色板（深色忽略 cotton/vintage，统一炭票）
    static func palette(paper: ReceiptPaper, dark: Bool) -> (
        paper: Pair, elevated: Pair, backdrop: Pair, ink: Pair, faint: Pair,
        muted: Pair, rule: Pair, dashed: Pair, accent: Pair, income: Pair, caution: Pair, slot: Pair
    ) {
        if dark {
            return (
                paper: Pair(light: "#FAF7F0", dark: "#24201D"),
                elevated: Pair(light: "#FFFDF9", dark: "#2D2824"),
                backdrop: Pair(light: "#E3DAC9", dark: "#110F0D"),
                ink: Pair(light: "#1F1B18", dark: "#EFE8DE"),
                faint: Pair(light: "#655D55", dark: "#A3988C"),
                muted: Pair(light: "#968C82", dark: "#6E655B"),
                rule: Pair(light: "#D8CFC0", dark: "#37322D"),
                dashed: Pair(light: "#C2B7A4", dark: "#4A433C"),
                accent: Pair(light: "#A63628", dark: "#E06250"),
                income: Pair(light: "#295A3F", dark: "#59A17A"),
                caution: Pair(light: "#9A5F17", dark: "#E2A450"),
                slot: Pair(light: "#9C9283", dark: "#050404")
            )
        }
        switch paper {
        case .cotton:
            return (
                paper: Pair(light: "#FAF7F0", dark: "#24201D"),
                elevated: Pair(light: "#FFFDF9", dark: "#2D2824"),
                backdrop: Pair(light: "#E3DAC9", dark: "#110F0D"),
                ink: Pair(light: "#1F1B18", dark: "#EFE8DE"),
                faint: Pair(light: "#655D55", dark: "#A3988C"),
                muted: Pair(light: "#968C82", dark: "#6E655B"),
                rule: Pair(light: "#D8CFC0", dark: "#37322D"),
                dashed: Pair(light: "#C2B7A4", dark: "#4A433C"),
                accent: Pair(light: "#A63628", dark: "#E06250"),
                income: Pair(light: "#295A3F", dark: "#59A17A"),
                caution: Pair(light: "#9A5F17", dark: "#E2A450"),
                slot: Pair(light: "#9C9283", dark: "#050404")
            )
        case .vintage:
            return (
                paper: Pair(light: "#F4EAD8", dark: "#24201D"),
                elevated: Pair(light: "#FCF5E8", dark: "#2D2824"),
                backdrop: Pair(light: "#D7CBB8", dark: "#110F0D"),
                ink: Pair(light: "#28211B", dark: "#EFE8DE"),
                faint: Pair(light: "#66594C", dark: "#A3988C"),
                muted: Pair(light: "#908272", dark: "#6E655B"),
                rule: Pair(light: "#CEBFA8", dark: "#37322D"),
                dashed: Pair(light: "#B6A68D", dark: "#4A433C"),
                accent: Pair(light: "#9D2E20", dark: "#E06250"),
                income: Pair(light: "#27533B", dark: "#59A17A"),
                caution: Pair(light: "#8C5312", dark: "#E2A450"),
                slot: Pair(light: "#8D8170", dark: "#050404")
            )
        }
    }
}
