#if canImport(UIKit) && canImport(QuartzCore)
import Foundation
import Metal
import QuartzCore
import UIKit

@MainActor
protocol ExperienceRuntimeSurfaceViewObserver: AnyObject {
    func runtimeSurfaceViewGeometryDidChange()
    func runtimeSurfaceViewVisibilityDidChange()
    func runtimeSurfaceViewDidReceivePointerEvents(
        _ events: [ExperienceRuntimeViewPointerEvent]
    )
}

/// Transparent UIKit host whose Metal layer, visibility, and input remain
/// MainActor-owned. It contains no runtime or product policy.
@MainActor
final class ExperienceRuntimeSurfaceView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    weak var runtimeObserver: (any ExperienceRuntimeSurfaceViewObserver)?

    override var isHidden: Bool {
        didSet {
            if isHidden != oldValue {
                runtimeObserver?.runtimeSurfaceViewVisibilityDidChange()
            }
        }
    }

    override var alpha: CGFloat {
        didSet {
            if alpha != oldValue {
                runtimeObserver?.runtimeSurfaceViewVisibilityDidChange()
            }
        }
    }

    var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? contentScaleFactor
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        runtimeObserver?.runtimeSurfaceViewGeometryDidChange()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        runtimeObserver?.runtimeSurfaceViewVisibilityDidChange()
        runtimeObserver?.runtimeSurfaceViewGeometryDidChange()
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
        deliver(touches, as: .up)
        super.touchesCancelled(touches, with: event)
    }

    private func configureLayer() {
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = UIColor.clear.cgColor
        metalLayer.contentsScale = contentScaleFactor

        let recognizer = UIHoverGestureRecognizer(
            target: self,
            action: #selector(handleHover(_:))
        )
        recognizer.cancelsTouchesInView = false
        addGestureRecognizer(recognizer)
    }

    private func deliver(
        _ touches: Set<UITouch>,
        as kind: ExperienceInteractivePointerKind
    ) {
        guard !touches.isEmpty else { return }
        runtimeObserver?.runtimeSurfaceViewDidReceivePointerEvents(
            touches.map { pointerEvent(for: $0, as: kind) }
        )
    }

    func pointerEvent(
        for touch: UITouch,
        as kind: ExperienceInteractivePointerKind
    ) -> ExperienceRuntimeViewPointerEvent {
        ExperienceRuntimeViewPointerEvent(
            source: ExperienceRuntimePointerSourceID(touch),
            kind: kind,
            location: touch.location(in: self),
            timestampSeconds: touch.timestamp
        )
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        let kind: ExperienceInteractivePointerKind
        switch recognizer.state {
        case .began, .changed:
            kind = .move
        case .ended, .cancelled, .failed:
            kind = .exit
        case .possible:
            return
        @unknown default:
            return
        }
        runtimeObserver?.runtimeSurfaceViewDidReceivePointerEvents([
            ExperienceRuntimeViewPointerEvent(
                source: ExperienceRuntimePointerSourceID(recognizer),
                kind: kind,
                location: recognizer.location(in: self),
                timestampSeconds: CACurrentMediaTime()
            ),
        ])
    }
}

/// Nonblocking drawable budget. Native completion releases each permit after
/// the command buffer is finished, so UIKit never waits on GPU backpressure.
@MainActor
final class ExperienceRuntimeDrawableGate {
    private let semaphore: DispatchSemaphore

    init(capacity: Int) {
        precondition(capacity > 0)
        semaphore = DispatchSemaphore(value: capacity)
    }

    func tryAcquire() -> ExperienceRuntimeDrawablePermit? {
        guard semaphore.wait(timeout: .now()) == .success else { return nil }
        return ExperienceRuntimeDrawablePermit(semaphore: semaphore)
    }
}

final class ExperienceRuntimeDrawablePermit: @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    private let lock = NSLock()
    private var isReleased = false

    fileprivate init(semaphore: DispatchSemaphore) {
        self.semaphore = semaphore
    }

    func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()
        semaphore.signal()
    }

    deinit { release() }
}
#endif
