import Foundation
import Nimble
import Quick

@testable import Nuxie

final class RemoteFlowMilestoneActionTests: QuickSpec {
    override class func spec() {
        describe("MilestoneAction") {
            it("decodes a milestone action") {
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

                guard case .milestone(let milestone) = action else {
                    fail("Expected milestone action")
                    return
                }
                expect(milestone.type).to(equal("milestone"))
                expect(milestone.milestoneId).to(equal("signup_complete"))
                expect(milestone.label).to(equal("Signed Up"))
            }

            it("requires a milestone id") {
                let data = Data(
                    """
                    {
                      "type": "milestone"
                    }
                    """.utf8
                )

                expect {
                    try JSONDecoder().decode(JourneyAction.self, from: data)
                }.to(throwError())
            }

            it("rejects a blank milestone id") {
                let data = Data(
                    """
                    {
                      "type": "milestone",
                      "milestoneId": "   "
                    }
                    """.utf8
                )

                expect {
                    try JSONDecoder().decode(JourneyAction.self, from: data)
                }.to(throwError())
            }
        }
    }
}
