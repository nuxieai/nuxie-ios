import XCTest
@testable import Nuxie

final class ExperienceRevealGateTests: XCTestCase {
    func testRevealCrossfadeIsImmediateForReduceMotion() {
        XCTAssertEqual(
            ExperienceShellRevealTransition.duration(reduceMotion: true),
            0
        )
        XCTAssertGreaterThan(
            ExperienceShellRevealTransition.duration(reduceMotion: false),
            0
        )
    }

    func testRequiresInputReadinessAndFirstCompleteDrawableExactlyOnce() {
        var gate = ExperienceRevealGate()

        XCTAssertFalse(gate.markInputReady())
        XCTAssertFalse(gate.markPresentedDrawable(.init(
            presentedTime: 1,
            pixelWidth: 0,
            pixelHeight: 844,
            drawCalls: 1,
            provenance: .injectedTestObserver
        )))
        XCTAssertTrue(gate.markPresentedDrawable(.init(
            presentedTime: 2,
            pixelWidth: 390,
            pixelHeight: 844,
            drawCalls: 1,
            provenance: .injectedTestObserver
        )))
        XCTAssertFalse(gate.markPresentedDrawable(.init(
            presentedTime: 3,
            pixelWidth: 390,
            pixelHeight: 844,
            drawCalls: 2,
            provenance: .injectedTestObserver
        )))
    }

    func testDrawableMayArriveBeforeInputReadiness() {
        var gate = ExperienceRevealGate()
        XCTAssertFalse(gate.markPresentedDrawable(.init(
            presentedTime: 1,
            pixelWidth: 390,
            pixelHeight: 844,
            drawCalls: 1,
            provenance: .runtimeCompletionProxy
        )))
        XCTAssertTrue(gate.markInputReady())
        XCTAssertFalse(gate.markInputReady())
    }
}
