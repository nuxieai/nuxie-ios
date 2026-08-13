import XCTest
@testable import Nuxie

final class ExperienceScreenTransitionSpecTests: XCTestCase {
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

    func testReduceMotionMakesEveryAnimatedKindInstant() {
        for kind in [
            ExperienceScreenTransitionSpec.Kind.push,
            .modal,
            .fade,
            .custom(transitionId: "transition.checkout_to_success"),
        ] {
            let spec = ExperienceScreenTransitionSpec(kind: kind)

            XCTAssertEqual(spec.effectiveKind(reduceMotion: true), .none)
            XCTAssertEqual(spec.effectiveKind(reduceMotion: false), kind)
        }
    }
}
