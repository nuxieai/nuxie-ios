import CoreGraphics

/// The one geometry transform shared by runtime rendering, pointer input, and
/// native overlays: centered `.contain` with the artboard's authored origin.
///
/// Points outside `contentBounds` intentionally remain outside the artboard.
/// Callers must not clamp them before delivering pointer input to the runtime.
struct FlowContainCenterTransform: Equatable, Sendable {
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

        let scale = min(
            viewportBounds.width / artboardBounds.width,
            viewportBounds.height / artboardBounds.height
        )
        guard scale.isFinite, scale > 0 else { return nil }

        let width = artboardBounds.width * scale
        let height = artboardBounds.height * scale
        let contentBounds = CGRect(
            x: viewportBounds.minX + (viewportBounds.width - width) / 2,
            y: viewportBounds.minY + (viewportBounds.height - height) / 2,
            width: width,
            height: height
        )
        guard Self.isFinite(contentBounds) else { return nil }

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
