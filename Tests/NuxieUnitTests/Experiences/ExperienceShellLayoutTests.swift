import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ExperienceShellLayoutTests: XCTestCase {
    func testReleasePresentationAdmitsOnlyOrientationAndBackground() throws {
        let presentation: [String: Any] = ["orientation": "portrait", "backgroundColor": "#102030FF"]
        XCTAssertNoThrow(try JourneyReleaseSchemaPrimitives.validatePresentation(presentation))
        for field in ["style", "sheet", "drawer"] {
            var extra = presentation
            if field == "style" { extra[field] = "full_screen" } else { extra[field] = [String: Any]() }
            XCTAssertThrowsError(try JourneyReleaseSchemaPrimitives.validatePresentation(extra))
        }
    }

    @MainActor
    func testPresentingNavigateSelectsFirstLayer() throws {
        let experience = MockExperienceViewController(mockExperienceVersionId: "first-layer").experience
        let screenID = try XCTUnwrap(experience.behaviorPresentationScreens.keys.first)
        XCTAssertEqual(experience.shellContract(screenId: screenID)?.layer.kind, .fullscreen)
        let transition = ExperienceScreenTransitionSpec(kind: .modal,
            presentation: .init(height: .medium, closedBy: .none))
        XCTAssertEqual(experience.shellContract(screenId: screenID, transition: transition)?.layer,
                       .init(height: .medium, closedBy: .none))
        let dialog = ExperienceScreenTransitionSpec(kind: .modal, presentation: .init(kind: .dialog))
        XCTAssertEqual(experience.shellContract(screenId: screenID, transition: dialog)?.layer.kind, .fullscreen)
    }
}
