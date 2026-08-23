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
