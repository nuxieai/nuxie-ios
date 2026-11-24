import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The scheme an app fixes for its experiences: `system` follows the phone,
/// `light` and `dark` override it. Every way the SDK draws a screen applies
/// it the same way.
package enum ExperienceColorSchemeMode: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark
}

/// The appearance a mounted screen draws in. Its label names both the
/// `env.colorScheme` enum value and the `Theme` global's authored instance.
package enum ExperienceColorScheme: String, CaseIterable, Hashable, Sendable {
    case light
    case dark

    package var label: String { rawValue }
}

#if canImport(UIKit)
extension ExperienceColorScheme {
    /// Dark only when the traits are dark; an unspecified style draws light.
    package init(_ style: UIUserInterfaceStyle) {
        self = style == .dark ? .dark : .light
    }

    /// The scheme a screen draws in, from what UIKit says of it: its own
    /// traits' style (`own`) while its view is in a window or a style is
    /// forced on it (`forced`), else the style of the host it draws for
    /// (`host`), when one is known. Out of a window with nothing forced, a
    /// screen's own traits are the system's or stale: it has not joined the
    /// host yet, or it waits behind another screen or in a cache.
    package init(own: UIUserInterfaceStyle, forced: UIUserInterfaceStyle, inWindow: Bool,
                 host: UIUserInterfaceStyle?) {
        if let host, forced == .unspecified, !inWindow {
            self.init(host)
        } else {
            self.init(own)
        }
    }

    /// The scheme the screen `controller` draws in, for a host whose style
    /// is `host`.
    @MainActor
    package init(drawnBy controller: UIViewController, host: UIUserInterfaceStyle?) {
        self.init(own: controller.traitCollection.userInterfaceStyle,
                  forced: controller.overrideUserInterfaceStyle,
                  inWindow: controller.viewIfLoaded?.window != nil, host: host)
    }
}
#endif

#if canImport(UIKit)
extension ExperienceColorSchemeMode {
    /// The style a screen is forced to: none for `system`.
    package var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system:
            return .unspecified
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
#endif

#if canImport(AppKit)
extension ExperienceColorSchemeMode {
    package var appearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}
#endif
