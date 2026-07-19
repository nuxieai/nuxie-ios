import Foundation
import Quick
import Nimble
@testable import Nuxie

final class FlowRuntimeFrameClockTests: QuickSpec {
    override class func spec() {
        describe("FlowRuntimeFrameClock") {
            it("uses zero for the first delta and elapsed display time thereafter") {
                var clock = FlowRuntimeFrameClock()

                expect(clock.frame(at: 10)).to(
                    equal(FlowRuntimeFrameTime(timestamp: 10, delta: 0))
                )
                let nextFrame = clock.frame(at: 10.016)
                expect(nextFrame.timestamp).to(equal(10.016))
                expect(nextFrame.delta).to(beCloseTo(0.016, within: 0.000_001))
            }

            it("never advances backward when timestamps regress") {
                var clock = FlowRuntimeFrameClock()
                _ = clock.frame(at: 5)

                expect(clock.frame(at: 4)).to(
                    equal(FlowRuntimeFrameTime(timestamp: 4, delta: 0))
                )
                expect(clock.frame(at: 5.25)).to(
                    equal(FlowRuntimeFrameTime(timestamp: 5.25, delta: 0.25))
                )
            }

            it("starts with zero again after a suspension reset") {
                var clock = FlowRuntimeFrameClock()
                _ = clock.frame(at: 1)
                _ = clock.frame(at: 2)

                clock.reset()

                expect(clock.frame(at: 100)).to(
                    equal(FlowRuntimeFrameTime(timestamp: 100, delta: 0))
                )
            }

            it("turns non-finite input into a zero-delta frame") {
                var clock = FlowRuntimeFrameClock()

                expect(clock.frame(at: .infinity)).to(
                    equal(FlowRuntimeFrameTime(timestamp: 0, delta: 0))
                )
                expect(clock.frame(at: 8)).to(
                    equal(FlowRuntimeFrameTime(timestamp: 8, delta: 0))
                )
            }
        }

        describe("FlowRuntimeSurfaceSizing") {
            it("converts point bounds to outward-rounded pixels using display scale") {
                expect(
                    FlowRuntimeSurfaceSizing.pixels(
                        width: 100.25,
                        height: 50.1,
                        scale: 2
                    )
                ).to(
                    equal(FlowRuntimeSurfaceSize(pixelWidth: 201, pixelHeight: 101))
                )
            }

            it("uses zero for empty or invalid geometry") {
                expect(
                    FlowRuntimeSurfaceSizing.pixels(width: -1, height: 20, scale: 3)
                ).to(
                    equal(FlowRuntimeSurfaceSize(pixelWidth: 0, pixelHeight: 60))
                )
                expect(
                    FlowRuntimeSurfaceSizing.pixels(width: 10, height: 10, scale: 0)
                ).to(
                    equal(FlowRuntimeSurfaceSize(pixelWidth: 0, pixelHeight: 0))
                )
            }
        }
    }
}
