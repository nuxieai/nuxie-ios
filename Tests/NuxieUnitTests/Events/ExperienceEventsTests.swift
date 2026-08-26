import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ExperienceEventsTests: AsyncSpec {
    override class func spec() {
        describe("Experience events") {
            var journey: JourneySnapshot!

            beforeEach {
                journey = TestJourneyBuilder(id: "test-journey-123")
                    .withExperienceId("test-experience-456")
                    .buildSnapshot()
            }

            it("experienceShownProperties includes ids") {
                let properties = JourneyEvents.experienceShownProperties(
                    experienceVersion: "flow-abc",
                    journey: journey
                )

                expect(properties["journey_id"] as? String).to(equal(journey.id))
                expect(properties["experience_id"] as? String).to(equal(journey.experienceId))
                expect(properties["experience_version"] as? String).to(equal("flow-abc"))
            }

            it("experienceDismissedProperties includes the mapped close reason") {
                let properties = JourneyEvents.experienceDismissedProperties(
                    experienceVersion: "flow-abc",
                    journey: journey,
                    reason: .goalMet
                )

                expect(properties["reason"] as? String).to(equal("goal_met"))
            }

            it("experienceErroredProperties includes error message when provided") {
                let properties = JourneyEvents.experienceErroredProperties(
                    experienceVersion: "flow-abc",
                    journey: journey,
                    errorMessage: "oops"
                )

                expect(properties["error_message"] as? String).to(equal("oops"))
            }

            it("experienceArtifactLoadSucceededProperties includes artifact metadata") {
                let properties = JourneyEvents.experienceArtifactLoadSucceededProperties(
                    experienceId: journey.experienceId,
                    experienceVersion: "flow-abc",
                    artifactBuildId: "build-1",
                    artifactSource: "cached_artifact",
                    artifactContentHash: "hash-123"
                )

                expect(properties["experience_version"] as? String).to(equal("flow-abc"))
                expect(properties["artifact_build_id"] as? String).to(equal("build-1"))
                expect(properties["artifact_source"] as? String).to(equal("cached_artifact"))
                expect(properties["artifact_content_hash"] as? String).to(equal("hash-123"))
            }

            it("experienceArtifactLoadFailedProperties includes error message when provided") {
                let properties = JourneyEvents.experienceArtifactLoadFailedProperties(
                    experienceId: journey.experienceId,
                    experienceVersion: "flow-abc",
                    artifactBuildId: "build-1",
                    artifactSource: "downloaded_artifact",
                    artifactContentHash: "hash-123",
                    errorMessage: "loading_timeout"
                )

                expect(properties["error_message"] as? String).to(equal("loading_timeout"))
                expect(properties["artifact_build_id"] as? String).to(equal("build-1"))
            }

            it("uses experience ids on customer, event, and app-action riders") {
                let customer = JourneyEvents.customerUpdatedProperties(
                    journey: journey,
                    screenId: "screen-1",
                    attributesUpdated: ["name"]
                )
                let event = JourneyEvents.eventSentProperties(
                    journey: journey,
                    screenId: "screen-1",
                    eventName: "answered",
                    eventProperties: [:]
                )
                let appAction = JourneyEvents.appActionRequestedProperties(
                    journey: journey,
                    screenId: "screen-1",
                    name: "completed",
                    payload: nil
                )

                for properties in [customer, event, appAction] {
                    expect(properties["experience_id"] as? String)
                        .to(equal(journey.experienceId))
                }
            }

            it("uses experience id and version on experiment exposure") {
                let properties = JourneyEvents.experimentExposureProperties(
                    journey: journey,
                    experimentKey: "checkout",
                    variantKey: "treatment",
                    experienceVersion: "flow-abc",
                    isHoldout: false
                )

                expect(properties["experience_id"] as? String)
                    .to(equal(journey.experienceId))
                expect(properties["experience_version"] as? String)
                    .to(equal("flow-abc"))
            }
        }
    }
}
