import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum ExperienceColorSchemeMode: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark
}

/// The appearance a mounted screen draws in. Its label names both the
/// `env.colorScheme` enum value and the `Theme` global's authored instance.
enum ExperienceColorScheme: String, CaseIterable, Hashable, Sendable {
    case light
    case dark

    var label: String { rawValue }
}

#if canImport(UIKit)
extension ExperienceColorScheme {
    /// Dark only when the traits are dark; an unspecified style draws light.
    init(_ style: UIUserInterfaceStyle) {
        self = style == .dark ? .dark : .light
    }
}
#endif

#if canImport(UIKit)
extension ExperienceColorSchemeMode {
    var userInterfaceStyle: UIUserInterfaceStyle {
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
    var appearance: NSAppearance? {
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
