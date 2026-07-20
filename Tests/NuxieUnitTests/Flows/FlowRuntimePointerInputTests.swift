#if canImport(UIKit)
import CoreGraphics
import Nimble
import Quick
import UIKit
@testable import Nuxie

final class FlowRuntimePointerInputTests: QuickSpec {
    override class func spec() {
        describe("FlowRuntimePointerInputRouter") {
            it("configures multitouch and noncancelling hover capture") { @MainActor in
                let view = FlowRuntimeSurfaceView(frame: .zero)
                let hover = view.gestureRecognizers?.compactMap {
                    $0 as? UIHoverGestureRecognizer
                }

                expect(view.isMultipleTouchEnabled).to(beTrue())
                expect(hover?.count).to(equal(1))
                expect(hover?.first?.cancelsTouchesInView).to(beFalse())
            }

            it("shares 32 stable positive IDs across touch and hover sources") {
                var router = FlowRuntimePointerInputRouter()
                let transform = FlowContainCenterTransform(
                    artboardBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                    viewportBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
                )!
                let sources = (0...FlowRuntimeSessionLimits.pointerEvents).map { _ in
                    NSObject()
                }
                let initial = router.runtimeEvents(
                    for: sources.map { source in
                        FlowRuntimeViewPointerEvent(
                            source: FlowRuntimePointerSourceID(source),
                            kind: .move,
                            location: CGPoint(x: 20, y: 30)
                        )
                    },
                    transform: transform
                )

                expect(initial.count).to(equal(FlowRuntimeSessionLimits.pointerEvents))
                expect(Set(initial.map(\.pointerID))).to(
                    equal(Set(Int32(1)...Int32(FlowRuntimeSessionLimits.pointerEvents)))
                )
                expect(initial.allSatisfy { $0.pointerID > 0 }).to(beTrue())

                let repeated = router.runtimeEvents(
                    for: [
                        FlowRuntimeViewPointerEvent(
                            source: FlowRuntimePointerSourceID(sources[0]),
                            kind: .move,
                            location: CGPoint(x: 40, y: 50)
                        )
                    ],
                    transform: transform
                )
                expect(repeated.map(\.pointerID)).to(equal([1]))

                let exited = router.runtimeEvents(
                    for: [
                        FlowRuntimeViewPointerEvent(
                            source: FlowRuntimePointerSourceID(sources[0]),
                            kind: .exit,
                            location: CGPoint(x: 40, y: 50)
                        )
                    ],
                    transform: transform
                )
                expect(exited.map(\.pointerID)).to(equal([1]))

                let admitted = router.runtimeEvents(
                    for: [
                        FlowRuntimeViewPointerEvent(
                            source: FlowRuntimePointerSourceID(
                                sources[FlowRuntimeSessionLimits.pointerEvents]
                            ),
                            kind: .down,
                            location: CGPoint(x: 60, y: 70)
                        )
                    ],
                    transform: transform
                )
                expect(admitted.map(\.pointerID)).to(equal([1]))
            }

            it("releases on cancel and supports a standalone hover exit") {
                var router = FlowRuntimePointerInputRouter()
                let transform = FlowContainCenterTransform(
                    artboardBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                    viewportBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
                )!
                let touch = NSObject()
                let touchSource = FlowRuntimePointerSourceID(touch)
                let touchEvents = router.runtimeEvents(
                    for: [
                        FlowRuntimeViewPointerEvent(
                            source: touchSource,
                            kind: .down,
                            location: CGPoint(x: 10, y: 20)
                        ),
                        FlowRuntimeViewPointerEvent(
                            source: touchSource,
                            kind: .move,
                            location: CGPoint(x: 20, y: 30)
                        ),
                        FlowRuntimeViewPointerEvent(
                            source: touchSource,
                            kind: .cancel,
                            location: CGPoint(x: 30, y: 40)
                        ),
                        FlowRuntimeViewPointerEvent(
                            source: touchSource,
                            kind: .exit,
                            location: CGPoint(x: 30, y: 40)
                        ),
                    ],
                    transform: transform
                )
                expect(touchEvents.map(\.kind)).to(equal([.down, .move, .cancel]))
                expect(touchEvents.map(\.pointerID)).to(equal([1, 1, 1]))

                let hover = NSObject()
                let hoverSource = FlowRuntimePointerSourceID(hover)
                let hoverEvents = router.runtimeEvents(
                    for: [
                        FlowRuntimeViewPointerEvent(
                            source: hoverSource,
                            kind: .move,
                            location: CGPoint(x: 40, y: 50)
                        ),
                        FlowRuntimeViewPointerEvent(
                            source: hoverSource,
                            kind: .exit,
                            location: CGPoint(x: 50, y: 60)
                        ),
                    ],
                    transform: transform
                )
                expect(hoverEvents.map(\.kind)).to(equal([.move, .exit]))
                expect(hoverEvents.map(\.pointerID)).to(equal([1, 1]))
            }
        }
    }
}
#endif
