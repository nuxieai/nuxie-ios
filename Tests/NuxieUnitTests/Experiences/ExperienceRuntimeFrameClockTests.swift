import Foundation
import Quick
import Nimble
import NuxieRuntime
@testable import Nuxie

final class ExperienceRuntimeFrameClockTests: QuickSpec {
    override class func spec() {
        describe("ExperienceRuntimeFrameClock") {
            it("uses zero for the first delta and elapsed display time thereafter") {
                var clock = ExperienceRuntimeFrameClock()

                expect(clock.frame(at: 10)).to(
                    equal(ExperienceRuntimeFrameTime(timestamp: 10, delta: 0))
                )
                let nextFrame = clock.frame(at: 10.016)
                expect(nextFrame.timestamp).to(equal(10.016))
                expect(nextFrame.delta).to(beCloseTo(0.016, within: 0.000_001))
            }

            it("never advances backward when timestamps regress") {
                var clock = ExperienceRuntimeFrameClock()
                _ = clock.frame(at: 5)

                expect(clock.frame(at: 4)).to(
                    equal(ExperienceRuntimeFrameTime(timestamp: 4, delta: 0))
                )
                expect(clock.frame(at: 5.25)).to(
                    equal(ExperienceRuntimeFrameTime(timestamp: 5.25, delta: 0.25))
                )
            }

            it("starts with zero again after a suspension reset") {
                var clock = ExperienceRuntimeFrameClock()
                _ = clock.frame(at: 1)
                _ = clock.frame(at: 2)

                clock.reset()

                expect(clock.frame(at: 100)).to(
                    equal(ExperienceRuntimeFrameTime(timestamp: 100, delta: 0))
                )
            }

            it("turns non-finite input into a zero-delta frame") {
                var clock = ExperienceRuntimeFrameClock()

                expect(clock.frame(at: .infinity)).to(
                    equal(ExperienceRuntimeFrameTime(timestamp: 0, delta: 0))
                )
                expect(clock.frame(at: 8)).to(
                    equal(ExperienceRuntimeFrameTime(timestamp: 8, delta: 0))
                )
            }

            it("renders text at zero delta without consuming authored animation time") {
                var clock = ExperienceRuntimeFrameClock()
                _ = clock.frame(at: 1)

                expect(clock.zeroDeltaFrame(at: 1.5)).to(
                    equal(ExperienceRuntimeFrameTime(timestamp: 1, delta: 0))
                )
                expect(clock.frame(at: 2)).to(
                    equal(ExperienceRuntimeFrameTime(timestamp: 2, delta: 1))
                )
            }

            it("seeds an unstarted clock for a text-only render") {
                var clock = ExperienceRuntimeFrameClock()

                expect(clock.zeroDeltaFrame(at: 4)).to(
                    equal(ExperienceRuntimeFrameTime(timestamp: 4, delta: 0))
                )
                expect(clock.frame(at: 5)).to(
                    equal(ExperienceRuntimeFrameTime(timestamp: 5, delta: 1))
                )
            }
        }

        describe("ExperienceRuntimeSurfaceSizing") {
            it("converts point bounds to outward-rounded pixels using display scale") {
                expect(
                    ExperienceRuntimeSurfaceSizing.pixels(
                        width: 100.25,
                        height: 50.1,
                        scale: 2
                    )
                ).to(
                    equal(ExperienceRuntimeSurfaceSize(pixelWidth: 201, pixelHeight: 101))
                )
            }

            it("uses zero for empty or invalid geometry") {
                expect(
                    ExperienceRuntimeSurfaceSizing.pixels(width: -1, height: 20, scale: 3)
                ).to(
                    equal(ExperienceRuntimeSurfaceSize(pixelWidth: 0, pixelHeight: 60))
                )
                expect(
                    ExperienceRuntimeSurfaceSizing.pixels(width: 10, height: 10, scale: 0)
                ).to(
                    equal(ExperienceRuntimeSurfaceSize(pixelWidth: 0, pixelHeight: 0))
                )
            }
        }
    }
}
