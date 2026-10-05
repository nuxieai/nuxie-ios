import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Safe-area insets for a rectangular surface, expressed in that surface's
/// own coordinate space (points for a UIKit view or artboard units for a
/// runtime surface).
struct ExperienceSafeAreaInsets: Equatable {
    var top: Double
    var bottom: Double
    var left: Double
    var right: Double

    static let zero = ExperienceSafeAreaInsets(top: 0, bottom: 0, left: 0, right: 0)
}

#if canImport(UIKit)
extension ExperienceSafeAreaInsets {
    init(_ insets: UIEdgeInsets) {
        self.init(
            top: Double(insets.top),
            bottom: Double(insets.bottom),
            left: Double(insets.left),
            right: Double(insets.right)
        )
    }
}
#endif

#if canImport(UIKit)
@MainActor
func experienceSafeAreaInsets(for view: UIView) -> ExperienceSafeAreaInsets {
    ExperienceSafeAreaInsets(view.safeAreaInsets)
}
#endif
