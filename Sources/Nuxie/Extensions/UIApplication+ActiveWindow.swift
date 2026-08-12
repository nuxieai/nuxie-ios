#if canImport(UIKit)
import UIKit

extension UIApplication {
    
    /// Returns the UIWindow most appropriate for presenting UI ("active window").
    /// Order of preference:
    ///  1) Key window in a foreground-active scene
    ///  2) First visible `.normal` window in a foreground-active scene
    ///  3) Key window in a foreground-inactive scene
    ///  4) First visible `.normal` window in a foreground-inactive scene
    @available(iOS 15.0, *)
    @available(iOSApplicationExtension, unavailable, message: "UIApplication is unavailable in app extensions.")
    var activeWindow: UIWindow? {
        assert(Thread.isMainThread, "activeWindow must be called on the main thread.")
        
        // 1–2. Foreground-active scenes
        if let win = firstWindow(inScenesWithStates: [.foregroundActive]) {
            return win
        }
        // 3–4. Foreground-inactive scenes (e.g., during app switcher)
        if let win = firstWindow(inScenesWithStates: [.foregroundInactive]) {
            return win
        }

        // Last resort: search all scenes
        let allWindows = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }

        return allWindows.first(where: { $0.isKeyWindow })
            ?? allWindows.first(where: { $0.windowLevel == .normal && !$0.isHidden && $0.alpha > 0 })
    }

    /// Returns the foreground "active" UIWindowScene if available, otherwise a foreground-inactive one.
    @available(iOS 15.0, *)
    @available(iOSApplicationExtension, unavailable, message: "UIApplication is unavailable in app extensions.")
    var activeWindowScene: UIWindowScene? {
        assert(Thread.isMainThread, "activeWindowScene must be called on the main thread.")
        return connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
            ?? connectedScenes.first { $0.activationState == .foregroundInactive } as? UIWindowScene
    }

    /// Finds the active window inside a specific UIWindowScene.
    @available(iOS 15.0, *)
    @available(iOSApplicationExtension, unavailable, message: "UIApplication is unavailable in app extensions.")
    func activeWindow(in scene: UIWindowScene) -> UIWindow? {
        assert(Thread.isMainThread, "activeWindow(in:) must be called on the main thread.")
        if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
        return scene.windows.first(where: { $0.windowLevel == .normal && !$0.isHidden && $0.alpha > 0 })
    }

    // MARK: - Helpers

    @available(iOS 15.0, *)
    private func firstWindow(inScenesWithStates states: [UIScene.ActivationState]) -> UIWindow? {
        // Prefer scenes in the given states; order of `connectedScenes` is not guaranteed,
        // so we just return the first match that has a suitable window.
        let scenes = connectedScenes
            .filter { states.contains($0.activationState) }
            .compactMap { $0 as? UIWindowScene }

        // Prefer a key window, then a visible normal-level window.
        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
            if let normal = scene.windows.first(where: { $0.windowLevel == .normal && !$0.isHidden && $0.alpha > 0 }) { return normal }
        }
        return nil
    }
}
#endif
