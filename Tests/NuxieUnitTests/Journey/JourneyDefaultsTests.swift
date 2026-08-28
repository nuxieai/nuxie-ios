import Foundation
import Quick
import Nimble
@_spi(Testing) @testable import Nuxie
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
            it("uses a 14 day window and last_experience_shown when no overrides are provided") {
                let journey = JourneySnapshot(experience: makeExperience(), distinctId: "user-1", now: Date())

                expect(journey.conversionWindow).to(equal(14 * 24 * 60 * 60))
                expect(journey.conversionAnchor).to(equal(.lastExperienceShown))
                expect(journey.conversionAnchor.rawValue).to(equal("last_experience_shown"))
            }

            it("preserves an explicit conversion anchor") {
                let journey = JourneySnapshot(
                    experience: makeExperience(conversionAnchor: "journey_start"),
                    distinctId: "user-1",
                    now: Date()
                )

                expect(journey.conversionAnchor).to(equal(.journeyStart))
            }

            it("rejects retired flow-named conversion anchors") {
                let retiredAnchor = Data("\"last_flow_shown\"".utf8)

                expect {
                    try JSONDecoder().decode(ConversionAnchor.self, from: retiredAnchor)
                }.to(throwError())
            }

            it("rejects a handoff snapshot carrying a retired conversion anchor") {
                var journey = JourneySnapshot(
                    experience: makeExperience(conversionAnchor: "journey_start"),
                    distinctId: "user-1",
                    now: Date()
                )
                var envelope = journey.stateEnvelope()
                envelope.snapshots["conversionAnchor"] = AnyCodable("last_flow_shown")

                let applied = journey.applyStateEnvelope(envelope, epoch: 1)

                expect(applied).to(beFalse())
                expect(journey.epoch).to(equal(0))
                expect(journey.conversionAnchor).to(equal(.journeyStart))
            }

            it("rejects a handoff without membership facts atomically") {
                var journey = JourneySnapshot(
                    experience: makeExperience(),
                    distinctId: "user-1",
                    now: Date()
                )
                var envelope = journey.stateEnvelope()
                envelope.snapshots.removeValue(forKey: "segmentMemberships")
                envelope.context["untrusted"] = AnyCodable(true)

                let applied = journey.applyStateEnvelope(envelope, epoch: 4)

                expect(applied).to(beFalse())
                expect(journey.epoch).to(equal(0))
                expect(journey.context["untrusted"]).to(beNil())
            }

            it("refreshes the anchor when a last_experience_shown journey is presented") {
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

            it("leaves other anchors unchanged when an experience is presented") {
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
