import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class GatePlanEvaluationTests: QuickSpec {
    override class func spec() {
        func access(
            allowed: Bool = false,
            unlimited: Bool = false,
            balance: Int? = nil,
            type: FeatureType = .metered
        ) -> FeatureAccess {
            FeatureAccess(allowed: allowed, unlimited: unlimited, balance: balance, type: type)
        }

        describe("hasAccess") {
            it("denies with no access record") {
                expect(GatePlanEvaluation.hasAccess(nil, requiredBalance: nil)) == false
            }

            it("uses the allowed flag for boolean features") {
                expect(GatePlanEvaluation.hasAccess(access(allowed: true, type: .boolean), requiredBalance: nil)) == true
                expect(GatePlanEvaluation.hasAccess(access(allowed: false, type: .boolean), requiredBalance: nil)) == false
            }

            it("always allows unlimited metered features") {
                expect(GatePlanEvaluation.hasAccess(access(unlimited: true), requiredBalance: 100)) == true
            }

            it("compares balance against the required amount, defaulting to 1") {
                expect(GatePlanEvaluation.hasAccess(access(balance: 1), requiredBalance: nil)) == true
                expect(GatePlanEvaluation.hasAccess(access(balance: 0), requiredBalance: nil)) == false
                expect(GatePlanEvaluation.hasAccess(access(balance: 5), requiredBalance: 5)) == true
                expect(GatePlanEvaluation.hasAccess(access(balance: 4), requiredBalance: 5)) == false
                expect(GatePlanEvaluation.hasAccess(access(balance: nil), requiredBalance: nil)) == false
            }
        }
    }
}
