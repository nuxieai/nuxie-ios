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
                    mocks.eventLog.trackedEvents.map(\.name)
                }.toEventually(contain("$journey_start"), timeout: .seconds(2))

                let startEvent = mocks.eventLog.trackedEvents.first {
                    $0.name == "$journey_start"
                }
                expect(startEvent?.properties?["campaign_id"] as? String).to(equal("campaign-segment"))
                expect(startEvent?.properties?["flow_id"] as? String).to(equal(flowId))
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
