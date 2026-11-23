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

/// A transparent view whose layer is the Metal layer the engine draws into,
/// and whose touches become the engine's pointers.
@MainActor
final class NuxieMachineSurfaceView: UIView {
    static let maximumActivePointers = 64

    override class var layerClass: AnyClass { CAMetalLayer.self }

    /// Pointers, in artboard points, in the order the touches arrived.
    var onPointers: (([NuxieNativePointerEvent]) -> Void)?
    /// The view's size, scale or window changed.
    var onGeometryChange: (() -> Void)?

    private var pointerIDs: [ObjectIdentifier: Int32] = [:]

    var metalLayer: CAMetalLayer {
        // The layer class above makes this cast always succeed.
        layer as! CAMetalLayer
    }

    /// The display scale the Screen is drawn at.
    var displayScale: CGFloat {
        window?.traitCollection.displayScale ?? traitCollection.displayScale
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = UIColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = displayScale
        if scale.isFinite, scale > 0 {
            contentScaleFactor = scale
            metalLayer.contentsScale = scale
        }
        onGeometryChange?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { pointerIDs.removeAll() }
        onGeometryChange?()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(touches, as: .down)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(touches, as: .move)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(touches, as: .up)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(touches, as: .exit)
        super.touchesCancelled(touches, with: event)
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

    /// A tap at `point` with no finger: a press and a release there, sent
    /// as a touch's pointers are, with the lowest pointer id no touch holds
    /// and the clock a touch's timestamp reads. False when every id is held.
    func tap(at point: CGPoint) -> Bool {
        guard let pointerID = (Int32(1)...Int32(Self.maximumActivePointers))
                .first(where: { !pointerIDs.values.contains($0) }) else { return false }
        let x = Float(point.x)
        let y = Float(point.y)
        let timestamp = Float(ProcessInfo.processInfo.systemUptime)
        guard x.isFinite, y.isFinite, timestamp.isFinite else { return false }
        onPointers?([.down, .up].map {
            NuxieNativePointerEvent(kind: $0, x: x, y: y, pointerID: pointerID, timestamp: timestamp)
        })
        return true
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
#endif
