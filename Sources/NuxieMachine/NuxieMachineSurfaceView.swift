#if os(iOS) && !targetEnvironment(macCatalyst)
import NuxieRuntime
import QuartzCore
import UIKit

// COPIED, in small, from the SDK's Screen view: `ExperienceRuntimeSurfaceView`
// (the Metal layer and the touches) and `ExperienceRuntimePointerInputRouter`
// with `ExperienceLayoutTransform` (touches to pointers). Those types are
// internal to the `Nuxie` product, which this tests-only module does not
// import and this slice does not edit. The mapping is the same as theirs:
//
// - A touch's point in the view is its point on the artboard. The artboard
//   is laid out at the view's size with its origin at zero, so the transform
//   is one to one, and a point outside the artboard stays outside.
// - Each touch takes the lowest free pointer id from 1 to 64 when it goes
//   down, keeps it while it moves, and gives it back on up or exit. A move
//   from a touch that never went down is dropped, and so is a touch past 64.
// - A cancelled touch is an exit. The timestamp is the touch's own.
//
// Left out: hover, which a phone does not have, and the fold environment.
//
// Added here, which the SDK's Screen view does not do: on a sheet, the view
// answers the sheet's swipe from the last frame's scroll regions
// (`gestureRecognizerShouldBegin`), so a `scroll` on a sheet scrolls.

/// A transparent view whose layer is the Metal layer the engine draws into,
/// and whose touches become the engine's pointers.
@MainActor
package final class NuxieMachineSurfaceView: UIView {
    static let maximumActivePointers = 64

    override package class var layerClass: AnyClass { CAMetalLayer.self }

    /// Pointers, in artboard points, in the order the touches arrived.
    var onPointers: (([NuxieNativePointerEvent]) -> Void)?
    /// The view's size, scale or window changed.
    var onGeometryChange: (() -> Void)?

    private var pointerIDs: [ObjectIdentifier: Int32] = [:]

    /// The scroll regions of the last frame shown ([`NuxieMachineScreenViewController.show`]),
    /// in artboard points; none before the first.
    package var scrollRegions: [NuxieNativeScrollRegion]?
    /// The touch that went down first while none was down, where, in
    /// artboard points, and the scroll regions shown then. Cleared when that
    /// touch ends or is cancelled. The sheet's swipe is answered from these
    /// regions, not from frames drawn since: a page a few points below its
    /// top that a slow drag down scrolls to its top before UIKit asks is
    /// still a page that was scrolled when the finger went down.
    private var touchDown: (touch: ObjectIdentifier, point: CGPoint, regions: [NuxieNativeScrollRegion]?)?

    var metalLayer: CAMetalLayer {
        // The layer class above makes this cast always succeed.
        layer as! CAMetalLayer
    }

    /// The display scale the Screen is drawn at.
    var displayScale: CGFloat {
        window?.traitCollection.displayScale ?? traitCollection.displayScale
    }

    override package init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = UIColor.clear.cgColor
    }

    package required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override package func layoutSubviews() {
        super.layoutSubviews()
        let scale = displayScale
        if scale.isFinite, scale > 0 {
            contentScaleFactor = scale
            metalLayer.contentsScale = scale
        }
        onGeometryChange?()
    }

    override package func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            pointerIDs.removeAll()
            touchDown = nil
        }
        onGeometryChange?()
    }

    override package func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first {
            touchWentDown(ObjectIdentifier(touch), at: touch.location(in: self))
        }
        deliver(touches, as: .down)
        super.touchesBegan(touches, with: event)
    }

    override package func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(touches, as: .move)
        super.touchesMoved(touches, with: event)
    }

    override package func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        forget(touches)
        deliver(touches, as: .up)
        super.touchesEnded(touches, with: event)
    }

    override package func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        forget(touches)
        deliver(touches, as: .exit)
        super.touchesCancelled(touches, with: event)
    }

    /// A sheet's swipe is a pan above this view, and UIKit asks this view,
    /// the one under the finger, once the finger has moved about 10 points
    /// whether it may begin. The answer is [`sheetPanMayBegin`]'s. Any
    /// other recognizer, or a pan it has no answer for, is answered as
    /// UIKit would.
    override package func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.view !== self,
              let answer = sheetPanMayBegin(moving: pan.translation(in: self))
        else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        return answer
    }

    /// Whether the sheet's swipe may take a drag that has moved by
    /// `translation`, answered from where the touch went down and the scroll
    /// regions shown then ([`NuxieMachineSheetPan.mayBegin`]): over a
    /// `scroll`, a drag stays with the page unless it is downward and the
    /// page was at its top. None with no touch down, or one that went down
    /// before the first frame was shown.
    package func sheetPanMayBegin(moving translation: CGPoint) -> Bool? {
        guard let down = touchDown, let regions = down.regions else { return nil }
        return NuxieMachineSheetPan.mayBegin(from: down.point, moving: translation, over: regions)
    }

    /// A touch went down at `point`: kept, with the regions shown now, when
    /// no touch is down already.
    package func touchWentDown(_ touch: ObjectIdentifier, at point: CGPoint) {
        guard touchDown == nil else { return }
        touchDown = (touch, point, scrollRegions)
    }

    /// A touch ended or was cancelled: the one kept goes with it.
    package func touchLifted(_ touch: ObjectIdentifier) {
        guard touchDown?.touch == touch else { return }
        touchDown = nil
    }

    private func forget(_ touches: Set<UITouch>) {
        for touch in touches { touchLifted(ObjectIdentifier(touch)) }
    }

    private func deliver(_ touches: Set<UITouch>, as kind: NuxieNativePointerKind) {
        var events: [NuxieNativePointerEvent] = []
        for touch in touches {
            let source = ObjectIdentifier(touch)
            let terminal = kind == .up || kind == .exit
            let point = touch.location(in: self)
            let x = Float(point.x)
            let y = Float(point.y)
            let timestamp = Float(touch.timestamp)
            guard x.isFinite, y.isFinite, touch.timestamp.isFinite, touch.timestamp >= 0,
                  timestamp.isFinite else {
                if terminal { pointerIDs.removeValue(forKey: source) }
                continue
            }
            let pointerID: Int32?
            if terminal {
                pointerID = pointerIDs.removeValue(forKey: source)
            } else if kind == .down {
                pointerID = pointerIDs[source] ?? allocate(source)
            } else {
                pointerID = pointerIDs[source]
            }
            guard let pointerID else { continue }
            events.append(NuxieNativePointerEvent(kind: kind, x: x, y: y, pointerID: pointerID,
                                                  timestamp: timestamp))
        }
        if !events.isEmpty { onPointers?(events) }
    }

    private func allocate(_ source: ObjectIdentifier) -> Int32? {
        guard pointerIDs.count < Self.maximumActivePointers else { return nil }
        let used = Set(pointerIDs.values)
        for candidate in Int32(1)...Int32(Self.maximumActivePointers) where !used.contains(candidate) {
            pointerIDs[source] = candidate
            return candidate
        }
        return nil
    }
}

/// Whether a sheet's swipe may take a drag on a machine component, from
/// where the drag went down and the scroll regions of the frame shown then.
///
/// - Down outside every region: yes, as on any sheet.
/// - Down inside one or more regions: yes only when the drag is mostly
///   downward and none of the regions under the touch can move toward its
///   top. A page scrolled down moves back first, and an inner list at its
///   top inside a page scrolled down moves the page. Otherwise no: the sheet
///   stays and the drag goes on to the page, which scrolls up, springs at an
///   end, or does nothing on a sideways drag.
///
/// A region's box is clipped by the boxes of the regions it is inside
/// before the touch is tested against it, since the capture leaves its boxes
/// unclipped. The answer is about where the page stood when the finger went
/// down: one frame old, on purpose.
package enum NuxieMachineSheetPan {
    /// `start` and `regions` in the same points (the artboard's), and
    /// `translation` the drag so far, positive y downward.
    package static func mayBegin(from start: CGPoint, moving translation: CGPoint,
                                 over regions: [NuxieNativeScrollRegion]) -> Bool {
        var visible: [CGRect] = []
        visible.reserveCapacity(regions.count)
        for (index, region) in regions.enumerated() {
            if let parent = region.parent, parent >= 0, parent < index {
                visible.append(region.bounds.intersection(visible[parent]))
            } else {
                visible.append(region.bounds)
            }
        }
        let under = regions.indices.filter { !visible[$0].isNull && visible[$0].contains(start) }
        guard !under.isEmpty else { return true }
        let downward = translation.y > 0 && abs(translation.y) > abs(translation.x)
        guard downward else { return false }
        return !under.contains { regions[$0].canScroll & NuxieNativeScrollRegion.towardTop != 0 }
    }
}
#endif
