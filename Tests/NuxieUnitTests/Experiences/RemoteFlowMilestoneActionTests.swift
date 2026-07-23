import XCTest
@testable import Nuxie

final class RemoteFlowMilestoneActionTests: XCTestCase {
    func testDecodesMilestoneAction() throws {
        let data = Data(
            """
            {
              "type": "milestone",
              "milestoneId": "signup_complete",
              "label": "Signed Up"
            }
            """.utf8
        )

        let action = try JSONDecoder().decode(JourneyAction.self, from: data)

        switch action {
        case .milestone(let milestone):
            XCTAssertEqual(milestone.type, "milestone")
            XCTAssertEqual(milestone.milestoneId, "signup_complete")
            XCTAssertEqual(milestone.label, "Signed Up")
        default:
            XCTFail("Expected milestone action")
        }
    }

    func testMilestoneActionRequiresMilestoneId() {
        let data = Data(
            """
            {
              "type": "milestone"
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(JourneyAction.self, from: data))
    }

    func testMilestoneActionRejectsBlankMilestoneId() {
        let data = Data(
            """
            {
              "type": "milestone",
              "milestoneId": "   "
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(JourneyAction.self, from: data))
    }
}
