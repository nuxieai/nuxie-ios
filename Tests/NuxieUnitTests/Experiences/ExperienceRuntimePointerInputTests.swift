#if canImport(UIKit)
import CoreGraphics
import Foundation
import Nimble
import Quick
import UIKit
@testable import Nuxie

final class ExperienceRuntimePointerInputTests: QuickSpec {
    override class func spec() {
        describe("ExperienceRuntimePointerInputRouter") {
            it("configures multitouch and noncancelling hover capture") { @MainActor in
                let view = ExperienceRuntimeSurfaceView(frame: .zero)
                let hover = view.gestureRecognizers?.compactMap {
                    $0 as? UIHoverGestureRecognizer
                }

                expect(view.isMultipleTouchEnabled).to(beTrue())
                expect(hover?.count).to(equal(1))
                expect(hover?.first?.cancelsTouchesInView).to(beFalse())
                expect(ExperienceRuntimeSurfaceView.cancelledTouchKind).to(equal(.exit))
            }

            it("captures UIKit touch timestamps at the surface") { @MainActor in
                let view = ExperienceRuntimeSurfaceView(frame: .zero)
                let touch = TimestampedTouch(
                    timestamp: 123.75,
                    location: CGPoint(x: 11, y: 22)
                )

                let event = view.pointerEvent(for: touch, as: .down)

                expect(event.source).to(equal(ExperienceRuntimePointerSourceID(touch)))
                expect(event.kind).to(equal(.down))
                expect(event.location).to(equal(CGPoint(x: 11, y: 22)))
                expect(event.timestampSeconds).to(equal(touch.timestamp))
            }

            it("preserves event timestamps and rejects values outside the f32 ABI") {
                var router = ExperienceRuntimePointerInputRouter()
                let transform = ExperienceContainCenterTransform(
                    artboardBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                    viewportBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
                )!
                let validSource = NSObject()
                let valid = ExperienceRuntimeViewPointerEvent(
                    source: ExperienceRuntimePointerSourceID(validSource),
                    kind: .down,
                    location: CGPoint(x: 10, y: 20),
                    timestampSeconds: 123.75
                )

                let mapped = router.runtimeEvents(for: [valid], transform: transform)

                expect(valid.timestampSeconds).to(equal(123.75))
                expect(mapped.map(\.timestamp)).to(equal([Float(123.75)]))

                let invalidTimestamps = [
                    -1.0,
                    Double.infinity,
                    Double.nan,
                    Double(Float.greatestFiniteMagnitude) * 2,
                ]
                let rejected = router.runtimeEvents(
                    for: invalidTimestamps.map { timestamp in
                        ExperienceRuntimeViewPointerEvent(
                            source: ExperienceRuntimePointerSourceID(NSObject()),
                            kind: .move,
                            location: CGPoint(x: 10, y: 20),
                            timestampSeconds: timestamp
                        )
                    },
                    transform: transform
                )
                expect(rejected).to(beEmpty())
            }

            it("shares a bounded set of stable positive IDs across touch and hover sources") {
                var router = ExperienceRuntimePointerInputRouter()
                let transform = ExperienceContainCenterTransform(
                    artboardBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                    viewportBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
                )!
                let limit = ExperienceRuntimePointerInputRouter.maximumActivePointers
                let sources = (0...limit).map { _ in
                    NSObject()
                }
                let initial = router.runtimeEvents(
                    for: sources.map { source in
                        ExperienceRuntimeViewPointerEvent(
                            source: ExperienceRuntimePointerSourceID(source),
                            kind: .move,
                            location: CGPoint(x: 20, y: 30)
                        )
                    },
                    transform: transform
                )

                expect(initial.count).to(equal(limit))
                expect(Set(initial.map(\.pointerID))).to(
                    equal(Set(Int32(1)...Int32(limit)))
                )
                expect(initial.allSatisfy { $0.pointerID > 0 }).to(beTrue())

                let repeated = router.runtimeEvents(
                    for: [
                        ExperienceRuntimeViewPointerEvent(
                            source: ExperienceRuntimePointerSourceID(sources[0]),
                            kind: .move,
                            location: CGPoint(x: 40, y: 50)
                        )
                    ],
                    transform: transform
                )
                expect(repeated.map(\.pointerID)).to(equal([1]))

                let exited = router.runtimeEvents(
                    for: [
                        ExperienceRuntimeViewPointerEvent(
                            source: ExperienceRuntimePointerSourceID(sources[0]),
                            kind: .exit,
                            location: CGPoint(x: 40, y: 50)
                        )
                    ],
                    transform: transform
                )
                expect(exited.map(\.pointerID)).to(equal([1]))

                let admitted = router.runtimeEvents(
                    for: [
                        ExperienceRuntimeViewPointerEvent(
                            source: ExperienceRuntimePointerSourceID(
                                sources[limit]
                            ),
                            kind: .down,
                            location: CGPoint(x: 60, y: 70)
                        )
                    ],
                    transform: transform
                )
                expect(admitted.map(\.pointerID)).to(equal([1]))
            }

            it("releases on up and supports a standalone hover exit") {
                var router = ExperienceRuntimePointerInputRouter()
                let transform = ExperienceContainCenterTransform(
                    artboardBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                    viewportBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
                )!
                let touch = NSObject()
                let touchSource = ExperienceRuntimePointerSourceID(touch)
                let touchEvents = router.runtimeEvents(
                    for: [
                        ExperienceRuntimeViewPointerEvent(
                            source: touchSource,
                            kind: .down,
                            location: CGPoint(x: 10, y: 20)
                        ),
                        ExperienceRuntimeViewPointerEvent(
                            source: touchSource,
                            kind: .move,
                            location: CGPoint(x: 20, y: 30)
                        ),
                        ExperienceRuntimeViewPointerEvent(
                            source: touchSource,
                            kind: .up,
                            location: CGPoint(x: 30, y: 40)
                        ),
                        ExperienceRuntimeViewPointerEvent(
                            source: touchSource,
                            kind: .exit,
                            location: CGPoint(x: 30, y: 40)
                        ),
                    ],
                    transform: transform
                )
                expect(touchEvents.map(\.kind)).to(equal([.down, .move, .up]))
                expect(touchEvents.map(\.pointerID)).to(equal([1, 1, 1]))

                let hover = NSObject()
                let hoverSource = ExperienceRuntimePointerSourceID(hover)
                let hoverEvents = router.runtimeEvents(
                    for: [
                        ExperienceRuntimeViewPointerEvent(
                            source: hoverSource,
                            kind: .move,
                            location: CGPoint(x: 40, y: 50)
                        ),
                        ExperienceRuntimeViewPointerEvent(
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

@MainActor
private final class TimestampedTouch: UITouch {
    private let capturedTimestamp: TimeInterval
    private let capturedLocation: CGPoint

    init(timestamp: TimeInterval, location: CGPoint) {
        self.capturedTimestamp = timestamp
        self.capturedLocation = location
        super.init()
    }

    override var timestamp: TimeInterval { capturedTimestamp }

    override func location(in view: UIView?) -> CGPoint { capturedLocation }
}
#endif
