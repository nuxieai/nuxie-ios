import CoreGraphics

/// The point-space transform shared by pointer input and native overlays.
/// View points differ from artboard points only by their origins.
///
/// Points outside `contentBounds` intentionally remain outside the artboard.
/// Callers must not clamp them before delivering pointer input to the runtime.
struct ExperienceLayoutTransform: Equatable, Sendable {
    let artboardBounds: CGRect
    let viewportBounds: CGRect
    let contentBounds: CGRect
    let scale: CGFloat

    init?(artboardBounds: CGRect, viewportBounds: CGRect) {
        guard Self.isFinite(artboardBounds),
              Self.isFinite(viewportBounds),
              artboardBounds.width > 0,
              artboardBounds.height > 0,
              viewportBounds.width > 0,
              viewportBounds.height > 0 else {
            return nil
        }

        let scale: CGFloat = 1
        let contentBounds = viewportBounds

        self.artboardBounds = artboardBounds
        self.viewportBounds = viewportBounds
        self.contentBounds = contentBounds
        self.scale = scale
    }

    func artboardPoint(fromViewport point: CGPoint) -> CGPoint {
        CGPoint(
            x: artboardBounds.minX + (point.x - contentBounds.minX) / scale,
            y: artboardBounds.minY + (point.y - contentBounds.minY) / scale
        )
    }

    func viewportPoint(fromArtboard point: CGPoint) -> CGPoint {
        CGPoint(
            x: contentBounds.minX + (point.x - artboardBounds.minX) * scale,
            y: contentBounds.minY + (point.y - artboardBounds.minY) * scale
        )
    }

    func artboardRect(fromViewport rect: CGRect) -> CGRect {
        let origin = artboardPoint(fromViewport: rect.origin)
        return CGRect(
            origin: origin,
            size: CGSize(width: rect.width / scale, height: rect.height / scale)
        )
    }

    func viewportRect(fromArtboard rect: CGRect) -> CGRect {
        let origin = viewportPoint(fromArtboard: rect.origin)
        return CGRect(
            origin: origin,
            size: CGSize(width: rect.width * scale, height: rect.height * scale)
        )
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite &&
            rect.origin.y.isFinite &&
            rect.size.width.isFinite &&
            rect.size.height.isFinite
    }
}
