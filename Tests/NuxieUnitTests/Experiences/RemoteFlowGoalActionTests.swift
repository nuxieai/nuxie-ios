import XCTest
@testable import Nuxie

final class RemoteFlowGoalActionTests: XCTestCase {
    func testDecodesGoalAction() throws {
        let data = Data(
            """
            {
              "type": "goal",
              "goalId": "signup_complete",
              "label": "Signed Up"
            }
            """.utf8
        )

        let action = try JSONDecoder().decode(JourneyAction.self, from: data)

        switch action {
        case .goal(let goal):
            XCTAssertEqual(goal.type, "goal")
            XCTAssertEqual(goal.goalId, "signup_complete")
            XCTAssertEqual(goal.label, "Signed Up")
        default:
            XCTFail("Expected goal action")
        }
    }

    func testGoalActionRequiresGoalId() {
        let data = Data(
            """
            {
              "type": "goal"
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(JourneyAction.self, from: data))
    }

    func testGoalActionRejectsBlankGoalId() {
        let data = Data(
            """
            {
              "type": "goal",
              "goalId": "   "
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(JourneyAction.self, from: data))
    }
}
