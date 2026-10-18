import SwiftUI
import UIKit

/// 用独立的高层级 UIWindow 显示锁屏 / 隐私遮罩，
/// 这样即使当前弹出了 sheet（如编辑页），回到前台时内容也会被完整遮住。
@MainActor
final class OverlayWindowManager {
    static let shared = OverlayWindowManager()

    private var lockWindow: UIWindow?
    private var privacyWindow: UIWindow?

    private var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }

    @discardableResult
    func showLock(lock: AppLockManager, style: UIUserInterfaceStyle) -> Bool {
        if let lockWindow {
            lockWindow.alpha = 1
            lockWindow.isHidden = false
            return true
        }
        guard let scene else { return false }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 2)
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: AnyView(LockScreenView().environmentObject(lock)))
        host.view.backgroundColor = .systemBackground
        window.rootViewController = host
        window.makeKeyAndVisible()
        lockWindow = window
        return true
    }

    func hideLock() {
        guard let window = lockWindow else { return }
        lockWindow = nil
        UIView.animate(withDuration: 0.25, animations: {
            window.alpha = 0
        }, completion: { _ in
            window.isHidden = true
            window.rootViewController = nil
        })
        scene?.windows.first(where: { $0.windowLevel == .normal })?.makeKey()
    }

    func showPrivacy(style: UIUserInterfaceStyle) {
        if let privacyWindow {
            privacyWindow.isHidden = false
            return
        }
        guard let scene else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.overrideUserInterfaceStyle = style
        window.isUserInteractionEnabled = false
        let host = UIHostingController(rootView: AnyView(PrivacyCoverView()))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        privacyWindow = window
    }

    func hidePrivacy() {
        privacyWindow?.isHidden = true
    }
}
