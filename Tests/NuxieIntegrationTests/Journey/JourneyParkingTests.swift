import Foundation
import Nimble
import Quick
@testable import Nuxie
@testable import NuxieTestSupport

final class JourneyParkingTests: AsyncSpec {
    override class func spec() {
        var mocks: MockFactory!
        var store: MockJourneyStore!
        var service: JourneyService!

        let distinctId = "parking-user"
        let campaignId = "parking-campaign"
        let flowId = "parking-flow-v1"
        let now = Date(timeIntervalSince1970: 1_785_196_800)

        func campaign() -> Campaign {
            Campaign(
                id: campaignId,
                name: "Parking",
                flowId: flowId,
                flowNumber: 1,
                flowName: nil,
                reentry: .everyTime,
                publishedAt: "2026-07-27T00:00:00Z",
                trigger: nil,
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                campaignType: nil
            )
        }

        func flow() -> RemoteFlow {
            let pauseHandler = JourneyEventHandler(
                id: "pause-handler",
                eventName: "pause_journey",
                actions: [
                    .delay(
                        DelayAction(
                            nodeId: "wait-node",
                            durationMs: 60_000
                        )
                    )
                ]
            )
            return RemoteFlow(
                id: flowId,
                flowArtifact: FlowArtifact(
                    url: "https://example.com/parking",
                    manifest: BuildManifest(
                        totalFiles: 1,
                        totalSize: 1,
                        contentHash: "parking-hash",
                        files: [
                            BuildFile(
                                path: "index.html",
                                size: 1,
                                contentType: "text/html"
                            )
                        ]
                    )
                ),
                screens: [
                    RemoteFlowScreen(
                        id: "screen-1",
                        defaultViewModelName: nil,
                        defaultInstanceId: nil
                    )
                ],
                events: [
                    RemoteFlow.journeyEventHostKey: [
                        EventDeclaration(
                            id: "pause-event",
                            eventName: "pause_journey"
                        )
                    ]
                ],
                handlers: [
                    RemoteFlow.journeyEventHostKey: [pauseHandler]
                ]
            )
        }

        beforeEach {
            mocks = MockFactory.shared
            await mocks.resetAll()
            mocks.dateProvider.setCurrentDate(now)
            mocks.identityService.setDistinctId(distinctId)
            let remoteFlow = flow()
            mocks.flowService.mockExperiences[flowId] = Experience(
                screens: remoteFlow
            )
            mocks.profileService.setProfileResponse(
                ProfileResponse(
                    campaigns: [campaign()],
                    segments: [],
                    flows: [remoteFlow]
                )
            )
            _ = try? await mocks.profileService.refetchProfile(
                distinctId: distinctId
            )
            store = MockJourneyStore()
            service = mocks.makeJourneyService(journeyStore: store)
        }

        afterEach {
            await service.shutdown()
            await mocks.resetAll()
        }

        it("enqueues a device-plane checkpoint for every live journey before background flush") {
            await service.initialize()
            guard let journey = await service.startJourney(
                for: campaign(),
                distinctId: distinctId,
                originEventId: nil
            ) else {
                return fail("Expected a live journey")
            }
            journey.epoch = 4
            journey.context["answer"] = AnyCodable(3)
            journey.flowState.regionId = "device-main"
            journey.flowState.currentNodeId = "question-3"

            await service.onAppDidEnterBackground()

            let parked = mocks.eventLog.trackedEvents.last {
                $0.name == "$journey_parked"
            }
            expect(parked).toNot(beNil())
            expect(parked?.properties?["journey_id"] as? String)
                .to(equal(journey.id))
            expect(parked?.properties?["epoch"] as? Int).to(equal(4))
            expect(parked?.properties?["reason"] as? String)
                .to(equal("background"))
            expect(parked?.properties?["pending_deadline_at"]).to(beNil())

            let checkpoint = parked?.properties?["checkpoint"]
                as? [String: Any]
            expect(checkpoint?["stateVersion"] as? Int).to(equal(1))
            expect((checkpoint?["context"] as? [String: Any])?["answer"] as? Int)
                .to(equal(3))
            let flowState = checkpoint?["flowState"] as? [String: Any]
            expect(flowState?["plane"] as? String).to(equal("device"))
            expect(flowState?["regionId"] as? String).to(equal("device-main"))
            expect(flowState?["currentNodeId"] as? String)
                .to(equal("question-3"))
        }

        it("enqueues the pending-action deadline when a journey pauses on a wait") {
            await service.initialize()
            guard let journey = await service.startJourney(
                for: campaign(),
                distinctId: distinctId,
                originEventId: nil
            ) else {
                return fail("Expected a live journey")
            }
            journey.epoch = 7

            await service.handleEvent(
                NuxieEvent(
                    name: "pause_journey",
                    distinctId: distinctId,
                    timestamp: now
                )
            )

            let parked = mocks.eventLog.trackedEvents.last {
                $0.name == "$journey_parked"
            }
            expect(parked?.properties?["journey_id"] as? String)
                .to(equal(journey.id))
            expect(parked?.properties?["epoch"] as? Int).to(equal(7))
            expect(parked?.properties?["reason"] as? String).to(equal("wait"))
            expect(parked?.properties?["pending_deadline_at"] as? String)
                .to(equal("2026-07-28T00:01:00.000Z"))

            let checkpoint = parked?.properties?["checkpoint"]
                as? [String: Any]
            let flowState = checkpoint?["flowState"] as? [String: Any]
            let pendingAction = flowState?["pendingAction"] as? [String: Any]
            expect(flowState?["plane"] as? String).to(equal("device"))
            expect(pendingAction?["resumeAt"] as? String)
                .to(equal("2026-07-28T00:01:00Z"))
            expect(pendingAction?["kind"] as? String).to(equal("delay"))
        }
    }
}
