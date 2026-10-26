import UIKit
import UniformTypeIdentifiers

/// 直接用 UIKit 弹出文件选择器（2.0 (12)）。
///
/// iOS 27.2 beta 上 SwiftUI `.fileImporter` 选完文件后回调丢失（选择器收起，什么都不发生）。
/// 这里从当前最上层的 UIViewController 弹出 `UIDocumentPickerViewController(asCopy: true)`，
/// 代理对象由 `DocumentPicker.active` 强引用，直到选择 / 取消（或下次弹出）为止。
@MainActor
final class DocumentPicker: NSObject, UIDocumentPickerDelegate {
    /// 当前正在显示的选择器的代理（强引用，避免代理被释放后回调丢失）
    private static var active: DocumentPicker?

    private let tag: String
    private let onPick: (URL) -> Void
    private let onCancel: () -> Void
    private var finished = false

    private init(tag: String, onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        self.tag = tag
        self.onPick = onPick
        self.onCancel = onCancel
    }

    /// 弹出选择器；找不到可用的 UIViewController 时返回 false（调用方需提示用户）
    @discardableResult
    static func present(types: [UTType], tag: String,
                        onPick: @escaping (URL) -> Void,
                        onCancel: @escaping () -> Void = {}) -> Bool {
        guard let top = topViewController() else {
            RunLog.shared.log(.error, tag, "无法弹出文件选择器：找不到最上层页面", memory: false)
            return false
        }
        let coordinator = DocumentPicker(tag: tag, onPick: onPick, onCancel: onCancel)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = coordinator
        picker.modalPresentationStyle = .formSheet
        active = coordinator
        // 不接管 picker 的 presentationController 代理，避免干扰系统选择器自身的收起 / 回调；
        // 下滑收起时 active 会在下次弹出时被替换
        top.present(picker, animated: true)
        RunLog.shared.log(.info, tag, "已弹出文件选择器（自 \(String(describing: type(of: top)))）", memory: false)
        return true
    }

    // MARK: UIDocumentPickerDelegate

    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        MainActor.assumeIsolated {
            let exts = urls.map { $0.pathExtension.isEmpty ? "无扩展名" : $0.pathExtension.lowercased() }.joined(separator: ",")
            RunLog.shared.log(.info, tag, "选择器 didPick：\(urls.count) 个（\(exts)）", memory: false)
            finish()
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        MainActor.assumeIsolated {
            RunLog.shared.log(.info, tag, "选择器已取消", memory: false)
            finish()
            onCancel()
        }
    }

    private func finish() {
        finished = true
        if DocumentPicker.active === self { DocumentPicker.active = nil }
    }

    // MARK: 最上层页面

    /// 主窗口（普通层级，排除锁屏 / 隐私遮罩等 overlay 窗口）的最上层 presented 页面
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let windows = scene?.windows ?? []
        let window = windows.first { $0.isKeyWindow && $0.windowLevel == .normal }
            ?? windows.first { $0.windowLevel == .normal && !$0.isHidden }
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}
