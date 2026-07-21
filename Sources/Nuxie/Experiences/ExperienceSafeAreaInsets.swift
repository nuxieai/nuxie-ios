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

/// Maps device-point safe-area insets into artboard units for a runtime
/// artboard rendered with fit `.contain` and alignment `.center`.
///
/// With `.contain` the artboard is uniformly scaled to fit inside the view
/// and centered, which letterboxes (or pillarboxes) the remainder. A device
/// inset that falls entirely inside the letterbox band never overlaps the
/// artboard, so the corresponding artboard inset clamps to zero; an inset
/// that reaches past the band is divided by the scale factor to land in
/// artboard units.
enum FlowSafeAreaInsetMapper {
    static func artboardInsets(
        deviceInsets: ExperienceSafeAreaInsets,
        viewSize: CGSize,
        artboardSize: CGSize
    ) -> ExperienceSafeAreaInsets {
        guard viewSize.width > 0, viewSize.height > 0,
              artboardSize.width > 0, artboardSize.height > 0
        else {
            return .zero
        }

        let scale = min(
            Double(viewSize.width) / Double(artboardSize.width),
            Double(viewSize.height) / Double(artboardSize.height)
        )
        guard scale > 0 else {
            return .zero
        }

        let letterboxX = (Double(viewSize.width) - Double(artboardSize.width) * scale) / 2
        let letterboxY = (Double(viewSize.height) - Double(artboardSize.height) * scale) / 2

        func corrected(_ deviceInset: Double, letterbox: Double) -> Double {
            max(0, (deviceInset - letterbox) / scale)
        }

        return ExperienceSafeAreaInsets(
            top: corrected(deviceInsets.top, letterbox: letterboxY),
            bottom: corrected(deviceInsets.bottom, letterbox: letterboxY),
            left: corrected(deviceInsets.left, letterbox: letterboxX),
            right: corrected(deviceInsets.right, letterbox: letterboxX)
        )
    }
}
