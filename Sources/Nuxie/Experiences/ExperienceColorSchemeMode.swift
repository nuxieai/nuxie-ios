import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum ExperienceColorSchemeMode: String, CaseIterable, Codable {
    case light
    case dark
}

#if canImport(UIKit)
extension ExperienceColorSchemeMode {
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
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
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}
#endif
