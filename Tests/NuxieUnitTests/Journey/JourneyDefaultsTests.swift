import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class JourneyDefaultsTests: QuickSpec {
    override class func spec() {
        func makeExperience(
            conversionAnchor: String? = nil,
            experienceType: String? = "paywall"
        ) -> Experience {
            Experience(
                id: "camp_1",
                versionId: "flow_1",
                name: "Experience",
                reentry: .everyTime,
                publishedAt: "2026-01-01T00:00:00Z",
                trigger: .event(EventTriggerConfig(eventName: "app_opened", condition: nil)),
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: conversionAnchor,
                experienceType: experienceType
            )
        }

        describe("Journey defaults") {
            it("uses a 14 day window and last_flow_shown when no overrides are provided") {
                let journey = JourneySnapshot(experience: makeExperience(), distinctId: "user-1", now: Date())

                expect(journey.conversionWindow).to(equal(14 * 24 * 60 * 60))
                expect(journey.conversionAnchor).to(equal(.lastExperienceShown))
            }

            it("preserves an explicit conversion anchor") {
                let journey = JourneySnapshot(
                    experience: makeExperience(conversionAnchor: "journey_start"),
                    distinctId: "user-1",
                    now: Date()
                )

                expect(journey.conversionAnchor).to(equal(.journeyStart))
            }

            it("refreshes the anchor when a last_flow_shown journey is presented") {
                var journey = JourneySnapshot(
                    experience: makeExperience(),
                    distinctId: "user-1",
                    now: Date()
                )
                let shownAt = Date(timeIntervalSince1970: 1_700_000_300)

                journey.markExperienceShown(at: shownAt)

                expect(journey.conversionAnchorAt).to(equal(shownAt))
                expect(journey.updatedAt).to(equal(shownAt))
            }

            it("leaves non-last_flow_shown anchors unchanged when a flow is presented") {
                var journey = JourneySnapshot(
                    experience: makeExperience(conversionAnchor: "journey_start"),
                    distinctId: "user-1",
                    now: Date()
                )
                let createdAt = journey.conversionAnchorAt
                let shownAt = Date(timeIntervalSince1970: 1_700_000_300)

                journey.markExperienceShown(at: shownAt)

                expect(journey.conversionAnchorAt).to(equal(createdAt))
                expect(journey.updatedAt).to(equal(createdAt))
            }
        }
    }
}
