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
            balance: Double? = nil,
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
                expect(GatePlanEvaluation.hasAccess(access(balance: 2.5), requiredBalance: 2.5)) == true
                expect(GatePlanEvaluation.hasAccess(access(balance: 2.5), requiredBalance: 2.75)) == false
                expect(GatePlanEvaluation.hasAccess(access(balance: nil), requiredBalance: nil)) == false
            }

            it("accepts an authoritative opaque decision only for its exact requirement") {
                let opaque = FeatureAccess(
                    authoritative: FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: "credit_wallet",
                        requiredBalance: 2,
                        code: "feature_found",
                        allowed: true,
                        unlimited: false,
                        balance: 8,
                        type: .creditSystem,
                        preview: nil
                    ),
                    requestedFeatureId: "exports"
                )

                expect(GatePlanEvaluation.hasAccess(opaque, requiredBalance: 2)) == true
                expect(GatePlanEvaluation.hasAccess(opaque, requiredBalance: nil)) == false

                let defaultOpaque = FeatureAccess(
                    authoritative: FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: "credit_wallet",
                        requiredBalance: 1,
                        code: "feature_found",
                        allowed: true,
                        unlimited: false,
                        balance: 8,
                        type: .creditSystem,
                        preview: nil
                    ),
                    requestedFeatureId: "exports"
                )
                expect(GatePlanEvaluation.hasAccess(defaultOpaque, requiredBalance: nil)) == true
            }

            it("does not trust an ordinary metered allowed flag without balance") {
                let ordinary = access(allowed: true, balance: nil, type: .metered)

                expect(GatePlanEvaluation.hasAccess(ordinary, requiredBalance: nil)) == false
                expect(GatePlanEvaluation.hasAccess(ordinary, requiredBalance: 2)) == false
            }
        }
    }
}
