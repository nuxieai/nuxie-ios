import XCTest
@testable import Nuxie

final class FlowScreenTransitionSpecTests: XCTestCase {
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

    func testUnknownTransitionKindsFallBackToInstant() {
        // "custom" was declared but never implemented; it now falls back to
        // .none like any other unknown kind (truth principle: no API for
        // behavior that doesn't exist).
        let custom = ExperienceScreenTransitionSpec(raw: [
            "type": "custom",
            "transitionId": "transition.checkout_to_success"
        ])

        XCTAssertEqual(custom.kind, .none)
        XCTAssertFalse(custom.isAnimated)
    }
}
