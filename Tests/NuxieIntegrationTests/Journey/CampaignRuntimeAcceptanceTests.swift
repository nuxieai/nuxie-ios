import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie
@testable import NuxieTestSupport

final class CampaignRuntimeAcceptanceTests: AsyncSpec {
    override class func spec() {
        describe("campaign runtime acceptance") {
            var mocks: MockFactory!
            var journeyStore: MockJourneyStore!
            var service: JourneyService!

            beforeEach {
                mocks = MockFactory.shared
                await mocks.resetAll()
                mocks.registerAll()
                mocks.identityService.setDistinctId("test-user")

                journeyStore = MockJourneyStore()
                service = JourneyService(journeyStore: journeyStore)
                Container.shared.journeyService.register { service }
            }

            afterEach {
                await service.shutdown()
                await mocks.resetAll()
                mocks.resetAllFactories()
            }

            it("starts a segment-triggered campaign journey when the matching segment is entered") {
                let flowId = "flow-segment"
                let campaign = makeCampaign(
                    id: "campaign-segment",
                    flowId: flowId,
                    trigger: .segment(SegmentTriggerConfig(condition: segmentCondition("premium")))
                )
                let flow = ResponseBuilders.buildRemoteFlow(id: flowId)
                mocks.flowService.mockFlows[flowId] = Flow(remoteFlow: flow)
                mocks.profileService.setProfileResponse(ProfileResponse(
                    campaigns: [campaign],
                    segments: [Segment(id: "premium", name: "Premium", condition: segmentCondition("premium"))],
                    flows: [flow],
                    userProperties: nil,
                    experiments: nil,
                    features: nil,
                    journeys: nil
                ))
                _ = try await mocks.profileService.refetchProfile(distinctId: "test-user")

                await service.initialize()
                await mocks.segmentService.triggerSegmentChange(
                    entered: [Segment(id: "premium", name: "Premium", condition: segmentCondition("premium"))],
                    exited: [],
                    remained: []
                )

                await expect {
                    await service.getActiveJourneys(for: "test-user").map(\.campaignId)
                }.toEventually(contain("campaign-segment"), timeout: .seconds(2))

                await expect {
                    mocks.eventService.trackWithResponseCalls.map(\.event)
                }.toEventually(contain("$journey_start"), timeout: .seconds(2))

                let startCall = mocks.eventService.trackWithResponseCalls.first {
                    $0.event == "$journey_start"
                }
                expect(startCall?.properties?["campaign_id"] as? String).to(equal("campaign-segment"))
                expect(startCall?.properties?["flow_id"] as? String).to(equal(flowId))
            }

            it("hydrates server-active journeys with their current node and context") {
                let campaign = makeCampaign(
                    id: "campaign-resume",
                    flowId: "flow-resume",
                    trigger: .event(EventTriggerConfig(eventName: "paywall_trigger", condition: nil))
                )
                let firstActive = ActiveJourney(
                    sessionId: "journey-server",
                    campaignId: campaign.id,
                    currentNodeId: "screen-2",
                    context: ["step": AnyCodable("checkout")]
                )

                await service.resumeFromServerState([firstActive], campaigns: [campaign])

                let resumed = await service.getActiveJourneys(for: "test-user").first {
                    $0.id == "journey-server"
                }
                expect(resumed?.status).to(equal(.paused))
                expect(resumed?.flowState.currentScreenId).to(equal("screen-2"))
                expect(resumed?.context["step"]?.value as? String).to(equal("checkout"))

                let existingActive = ActiveJourney(
                    sessionId: "journey-server",
                    campaignId: campaign.id,
                    currentNodeId: "screen-3",
                    context: ["step": AnyCodable("upsell")]
                )

                await service.resumeFromServerState([existingActive], campaigns: [campaign])

                let existing = await service.getActiveJourneys(for: "test-user").first {
                    $0.id == "journey-server"
                }
                expect(existing?.context["_server_resume"]?.value as? Bool).to(beTrue())
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

        func makeCampaign(
            id: String,
            flowId: String,
            trigger: CampaignTrigger
        ) -> Campaign {
            Campaign(
                id: id,
                name: "Campaign \(id)",
                flowId: flowId,
                flowNumber: 1,
                flowName: nil,
                reentry: .everyTime,
                publishedAt: "2024-01-01T00:00:00Z",
                trigger: trigger,
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                campaignType: nil
            )
        }
    }
}
