import Foundation
import Quick
import Nimble
import NuxieRuntime
@testable import Nuxie
@testable import NuxieTestSupport

final class ExperienceRuntimeAcceptanceTests: AsyncSpec {
    override class func spec() {
        describe("experience runtime acceptance") {
            var mocks: MockFactory!
            var journeyStore: MockJourneyStore!
            var service: JourneyService!

            beforeEach {
                mocks = MockFactory.shared
                await mocks.resetAll()
                mocks.identityService.setDistinctId("test-user")

                journeyStore = MockJourneyStore()
                service = mocks.makeJourneyService(journeyStore: journeyStore)
            }

            afterEach {
                await service.shutdown()
                await mocks.resetAll()
            }

            it("keeps event-triggered experiences inert when a server seed changes") {
                let flowId = "flow-segment"
                let experience = makeExperience(
                    id: "experience-segment",
                    flowId: flowId,
                    trigger: .event(
                        EventTriggerConfig(
                            eventName: "paywall_trigger",
                            condition: nil
                        )
                    )
                )
                let flow = ResponseBuilders.buildJourneyDocument(id: flowId)
                mocks.experienceService.mockExperiences[flowId] = Experience(
                    id: experience.id,
                    versionId: experience.versionId,
                    buildId: experience.buildId,
                    name: experience.name,
                    reentry: experience.reentry,
                    publishedAt: experience.publishedAt,
                    trigger: experience.trigger,
                    goal: experience.goal,
                    exitPolicy: experience.exitPolicy,
                    conversionAnchor: experience.conversionAnchor,
                    experienceType: experience.experienceType,
                    journey: flow,
                    assetBaseURL: experience.assetBaseURL
                )
                let reference = ExperienceReference(
                    experienceId: experience.id,
                    versionId: experience.versionId
                )
                mocks.profileService.effectiveExperienceReferences = [reference]
                mocks.profileService.activeExperienceReferences = [reference]
                mocks.profileService.setProfileResponse(ProfileResponse(
                    segments: [Segment(id: "premium", name: "Premium", condition: segmentCondition("premium"))],
                    userProperties: nil,
                    experiments: nil,
                    features: nil
                ))
                _ = try await mocks.profileService.refetchProfile(distinctId: "test-user")

                await service.initialize()
                _ = await mocks.segmentService.applySeed(
                    SegmentMembershipSeed(
                        evaluatedAt: nil,
                        memberships: [
                            SeededSegmentMembership(segmentId: "premium", enteredAt: Date())
                        ]
                    ),
                    generation: 1,
                    distinctId: "test-user"
                )

                let active = await service.getActiveJourneys(for: "test-user")
                expect(active).to(beEmpty())
                expect(mocks.eventLog.trackWithResponseCalls).to(beEmpty())
            }

        }

        func segmentCondition(_ segmentId: String) -> IREnvelope {
            IREnvelope(
                ir_version: 1,
                engine_min: nil,
                compiled_at: nil,
                expr: .segment(op: "in", id: segmentId, within: nil)
            )
        }

        func makeExperience(
            id: String,
            flowId: String,
            trigger: ExperienceTrigger
        ) -> Experience {
            Experience(
                id: id,
                versionId: flowId,
                name: "Experience \(id)",
                reentry: .everyTime,
                publishedAt: "2024-01-01T00:00:00Z",
                trigger: trigger,
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                experienceType: nil
            )
        }
    }
}
