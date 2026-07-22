import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class EnrollmentPolicyTests: QuickSpec {
    override class func spec() {
        func decide(
            reentry: CampaignReentry,
            hasLiveJourney: Bool = false,
            hasCompleted: Bool = false,
            lastCompletionAt: Date? = nil,
            secondsSinceLastCompletion: TimeInterval = 0
        ) -> SuppressReason? {
            EnrollmentPolicy.suppressionReason(
                reentry: reentry,
                hasLiveJourney: hasLiveJourney,
                hasCompleted: { hasCompleted },
                lastCompletionAt: { lastCompletionAt },
                timeIntervalSinceLastCompletion: { _ in secondsSinceLastCompletion }
            )
        }

        describe("suppressionReason") {
            it("suppresses when a journey for the campaign is already live") {
                expect(decide(reentry: .everyTime, hasLiveJourney: true)) == .alreadyActive
            }

            it("always allows everyTime reentry") {
                expect(decide(reentry: .everyTime, hasCompleted: true)).to(beNil())
            }

            it("limits oneTime reentry after a completion") {
                expect(decide(reentry: .oneTime, hasCompleted: false)).to(beNil())
                expect(decide(reentry: .oneTime, hasCompleted: true)) == .reentryLimited
            }

            it("allows oncePerWindow with no completion history") {
                let window = Window(amount: 1, unit: .day)
                expect(decide(reentry: .oncePerWindow(window))).to(beNil())
            }

            it("limits oncePerWindow inside the window and allows at the boundary") {
                let window = Window(amount: 1, unit: .hour)
                let last = Date(timeIntervalSince1970: 1000)
                expect(decide(
                    reentry: .oncePerWindow(window),
                    lastCompletionAt: last,
                    secondsSinceLastCompletion: 3599
                )) == .reentryLimited
                expect(decide(
                    reentry: .oncePerWindow(window),
                    lastCompletionAt: last,
                    secondsSinceLastCompletion: 3600
                )).to(beNil())
            }

            it("does not query completion history unless the policy needs it") {
                var lookups = 0
                _ = EnrollmentPolicy.suppressionReason(
                    reentry: .everyTime,
                    hasLiveJourney: false,
                    hasCompleted: {
                        lookups += 1
                        return false
                    },
                    lastCompletionAt: {
                        lookups += 1
                        return nil
                    },
                    timeIntervalSinceLastCompletion: { _ in 0 }
                )
                expect(lookups) == 0
            }
        }

        describe("windowInterval") {
            it("converts every unit to seconds") {
                expect(EnrollmentPolicy.windowInterval(Window(amount: 2, unit: .minute))) == 120
                expect(EnrollmentPolicy.windowInterval(Window(amount: 2, unit: .hour))) == 7200
                expect(EnrollmentPolicy.windowInterval(Window(amount: 2, unit: .day))) == 172_800
                expect(EnrollmentPolicy.windowInterval(Window(amount: 2, unit: .week))) == 1_209_600
            }
        }
    }
}
