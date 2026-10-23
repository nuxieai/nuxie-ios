import XCTest
@_spi(Testing) @testable import Nuxie

final class ExperienceScreenTransitionSpecTests: XCTestCase {
    func testPageForwardPreservesNamedFadePushAndModalAndPlainCut() {
        let forms: [[String: Any]] = [["type": "none"], ["type": "push"],
            ["type": "modal", "present": "sheet"], ["type": "modal", "present": "fullscreen"],
            ["type": "fade", "transitionId": "ab"]]
        for raw in forms {
            let spec = ExperienceScreenTransitionSpec.pageTransition(raw: raw, sourceScreenID: "A",
                isBack: false, diagnostic: { XCTFail("Unexpected diagnostic: \($0)") })
            XCTAssertEqual(spec, ExperienceScreenTransitionSpec(raw: raw))
        }
    }

    func testPageBackWithoutOwnTransitionUsesInferredCutWithoutDiagnostic() {
        XCTAssertEqual(ExperienceScreenTransitionSpec.pageTransition(raw: nil, sourceScreenID: "A",
            isBack: true, inferredBack: .none, diagnostic: { XCTFail("Unexpected diagnostic: \($0)") }), .none)
    }

    func testDefaultsToNoneForMissingTransition() {
        XCTAssertEqual(ExperienceScreenTransitionSpec(raw: nil), .none)
    }

    func testParsesSupportedTransitionPayloads() {
        XCTAssertEqual(
            ExperienceScreenTransitionSpec(raw: ["type": "none"]),
            ExperienceScreenTransitionSpec(kind: .none)
        )
        XCTAssertEqual(
            ExperienceScreenTransitionSpec(raw: ["type": "push"]),
            ExperienceScreenTransitionSpec(kind: .push)
        )
        XCTAssertEqual(
            ExperienceScreenTransitionSpec(raw: ["type": "modal"]),
            ExperienceScreenTransitionSpec(kind: .modal)
        )
        XCTAssertEqual(
            ExperienceScreenTransitionSpec(raw: ["type": "fade"]),
            ExperienceScreenTransitionSpec(kind: .fade)
        )
        XCTAssertEqual(
            ExperienceScreenTransitionSpec(raw: [
                "type": "custom",
                "transitionId": "transition.checkout_to_success",
            ]),
            ExperienceScreenTransitionSpec(
                kind: .custom(transitionId: "transition.checkout_to_success")
            )
        )
    }

    func testRejectsRemovedTransitionPayloads() {
        XCTAssertEqual(ExperienceScreenTransitionSpec(raw: ["type": "instant"]), .none)
        XCTAssertEqual(ExperienceScreenTransitionSpec(raw: ["type": "present"]), .none)
        XCTAssertEqual(ExperienceScreenTransitionSpec(raw: ["type": "dissolve"]), .none)
        XCTAssertEqual(ExperienceScreenTransitionSpec(raw: ["type": "move_in"]), .none)
        XCTAssertEqual(ExperienceScreenTransitionSpec(raw: ["type": "slide_out"]), .none)
    }

    func testAcceptsAnyCodableTransitionValues() {
        let spec = ExperienceScreenTransitionSpec(raw: AnyCodable([
            "type": "fade"
        ]))

        XCTAssertEqual(spec.kind, .fade)
        XCTAssertTrue(spec.isAnimated)
    }

    func testMissingCustomTransitionIdFallsBackToInstant() {
        XCTAssertEqual(
            ExperienceScreenTransitionSpec(raw: ["type": "custom"]),
            .none
        )
        XCTAssertEqual(
            ExperienceScreenTransitionSpec(raw: [
                "type": "custom",
                "transitionId": "  ",
            ]),
            .none
        )
    }

    func testUnknownTransitionKindsFallBackToInstant() {
        XCTAssertEqual(
            ExperienceScreenTransitionSpec(raw: ["type": "unknown"]),
            .none
        )
    }

    func testReduceMotionPreservesNavigationKindWhileDisablingAnimation() {
        for kind in [
            ExperienceScreenTransitionSpec.Kind.push,
            .modal,
            .fade,
            .custom(transitionId: "transition.checkout_to_success"),
        ] {
            let spec = ExperienceScreenTransitionSpec(kind: kind)

            XCTAssertEqual(spec.effectiveKind(reduceMotion: true), kind)
            XCTAssertEqual(spec.effectiveKind(reduceMotion: false), kind)
            XCTAssertFalse(spec.shouldAnimate(reduceMotion: true))
            XCTAssertTrue(spec.shouldAnimate(reduceMotion: false))
        }

        XCTAssertFalse(ExperienceScreenTransitionSpec.none.shouldAnimate(reduceMotion: false))
    }
}
