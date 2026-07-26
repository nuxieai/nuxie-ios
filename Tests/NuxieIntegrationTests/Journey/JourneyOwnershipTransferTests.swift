import Foundation
import Nimble
import Quick
@testable import Nuxie
@testable import NuxieTestSupport

final class JourneyOwnershipTransferTests: AsyncSpec {
    override class func spec() {
        var mocks: MockFactory!
        var store: MockJourneyStore!
        var service: JourneyService!

        let distinctId = "ownership-user"
        let campaignId = "ownership-campaign"
        let flowId = "ownership-flow-v1"

        func campaign(
            id: String = campaignId,
            trigger: CampaignTrigger? = nil
        ) -> Campaign {
            Campaign(
                id: id,
                name: "Ownership",
                flowId: flowId,
                flowNumber: 1,
                flowName: nil,
                reentry: .everyTime,
                publishedAt: "2026-07-25T00:00:00Z",
                trigger: trigger,
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                campaignType: nil
            )
        }

        func flow(
            regionActions: [JourneyAction] = [
                .delay(DelayAction(durationMs: 60_000)),
                .milestone(MilestoneAction(milestoneId: "after-wait")),
            ]
        ) -> RemoteFlow {
            let finish = JourneyEventHandler(
                id: "finish-handler",
                eventName: "finish",
                actions: [.exit(ExitAction(reason: "completed"))]
            )
            return RemoteFlow(
                id: flowId,
                flowArtifact: FlowArtifact(
                    url: "https://example.com/ownership",
                    manifest: BuildManifest(
                        totalFiles: 1,
                        totalSize: 1,
                        contentHash: "ownership-hash",
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
                        EventDeclaration(id: "finish-event", eventName: "finish")
                    ]
                ],
                handlers: [RemoteFlow.journeyEventHostKey: [finish]],
                deviceRegions: [
                    RemoteFlowDeviceRegion(
                        id: "device-region-1",
                        entryNodeId: "wait-node",
                        actions: regionActions
                    )
                ]
            )
        }

        func mailboxEntry(stateVersion: Int = 1) -> JourneyMailboxEntry {
            JourneyMailboxEntry(
                journeyId: "server-run-1",
                experienceId: campaignId,
                experienceVersion: flowId,
                epoch: 2,
                stateVersion: stateVersion,
                envelope: JourneyStateEnvelope(
                    stateVersion: stateVersion,
                    context: ["source": AnyCodable("server")],
                    flowState: FlowJourneyState(
                        regionId: "device-region-1",
                        currentNodeId: "wait-node"
                    ),
                    snapshots: [:]
                ),
                expiresAt: Date().addingTimeInterval(3_600)
            )
        }

        func prime(
            mailbox: [JourneyMailboxEntry],
            regionActions: [JourneyAction]? = nil,
            campaigns: [Campaign]? = nil
        ) async {
            let remoteFlow = regionActions.map {
                flow(regionActions: $0)
            } ?? flow()
            mocks.identityService.setDistinctId(distinctId)
            mocks.flowService.mockExperiences[flowId] = Experience(
                screens: remoteFlow
            )
            mocks.profileService.setProfileResponse(
                ProfileResponse(
                    campaigns: campaigns ?? [campaign()],
                    segments: [],
                    flows: [remoteFlow],
                    mailbox: mailbox
                )
            )
            _ = try? await mocks.profileService.refetchProfile(
                distinctId: distinctId
            )
        }

        beforeEach {
            mocks = MockFactory.shared
            await mocks.resetAll()
            store = MockJourneyStore()
            service = mocks.makeJourneyService(journeyStore: store)
        }

        afterEach {
            await service.shutdown()
            await mocks.resetAll()
        }

        it("admits an accepted mailbox claim through persisted resume") {
            await prime(mailbox: [mailboxEntry()])
            mocks.eventLog.trackWithResponseResult = EventResponse(
                status: "ok",
                journeyClaim: EventResponse.JourneyClaimAcknowledgement(
                    journeyId: "server-run-1",
                    accepted: true,
                    epoch: 3
                )
            )

            await service.initialize()

            let active = await service.getActiveJourneys(for: distinctId)
            expect(active).to(haveCount(1))
            expect(active.first?.id).to(equal("server-run-1"))
            expect(active.first?.epoch).to(equal(3))
            expect(active.first?.getContext("source") as? String).to(equal("server"))
            expect(store.loadJourney(id: "server-run-1")).toNot(beNil())
            expect(mocks.eventLog.trackForTriggerCalls.first?.event)
                .to(equal(JourneyEvents.journeyClaimed))
        }

        it("never enrolls a triggerless server-owned campaign from a local event") {
            let clientCampaign = campaign(
                id: "client-owned-campaign",
                trigger: .event(
                    EventTriggerConfig(
                        eventName: "matching-local-event",
                        condition: nil
                    )
                )
            )
            await prime(
                mailbox: [],
                campaigns: [campaign(), clientCampaign]
            )

            await service.initialize()
            await service.handleEvent(
                NuxieEvent(
                    name: "matching-local-event",
                    distinctId: distinctId
                )
            )

            let active = await service.getActiveJourneys(for: distinctId)
            expect(active.map(\.campaignId)).to(equal(["client-owned-campaign"]))
            expect(active.map(\.campaignId)).toNot(contain(campaignId))
        }

        it("refuses an unknown mailbox state version without claiming") {
            await prime(mailbox: [mailboxEntry(stateVersion: 99)])

            await service.initialize()

            let active = await service.getActiveJourneys(for: distinctId)
            expect(active).to(beEmpty())
            expect(store.loadJourney(id: "server-run-1")).to(beNil())
            expect(mocks.eventLog.trackForTriggerCalls).to(beEmpty())
        }

        it("discards a resumed run when the server rejects its epoch") {
            await prime(mailbox: [mailboxEntry()])
            mocks.eventLog.trackWithResponseResult = EventResponse(
                status: "ok",
                journeyClaim: EventResponse.JourneyClaimAcknowledgement(
                    journeyId: "server-run-1",
                    accepted: true,
                    epoch: 3
                )
            )
            await service.initialize()
            let claimed = await service.getActiveJourneys(for: distinctId)
            expect(claimed).to(haveCount(1))

            mocks.eventLog.trackWithResponseResult = EventResponse(
                status: "rejected",
                journeyClaim: EventResponse.JourneyClaimAcknowledgement(
                    journeyId: "server-run-1",
                    accepted: false,
                    epoch: 4,
                    reason: "stale_epoch"
                )
            )
            mocks.dateProvider.advance(by: 61)
            await service.checkExpiredTimers()

            let active = await service.getActiveJourneys(for: distinctId)
            expect(active).to(beEmpty())
            expect(store.loadJourney(id: "server-run-1")).to(beNil())
            expect(store.getCompletions(for: distinctId)).to(beEmpty())
        }

        it("durably hands a device region back without recording completion") {
            await prime(
                mailbox: [mailboxEntry()],
                regionActions: [
                    .handoff(
                        HandoffAction(
                            nodeId: "handoff-node",
                            edgeId: "edge-1",
                            direction: "device_to_server",
                            toRegionId: "server-region-1",
                            toNodeId: "email-node"
                        )
                    )
                ]
            )
            mocks.eventLog.setTrackWithResponseResult(
                EventResponse(
                    status: "ok",
                    journeyClaim: EventResponse.JourneyClaimAcknowledgement(
                        journeyId: "server-run-1",
                        accepted: true,
                        epoch: 3
                    )
                ),
                for: JourneyEvents.journeyClaimed
            )
            mocks.eventLog.setTrackWithResponseResult(
                EventResponse(
                    status: "ok",
                journeyOwnership: EventResponse.JourneyOwnershipAcknowledgement(
                    journeyId: "server-run-1",
                    accepted: true,
                    epoch: 4
                )
                ),
                for: JourneyEvents.journeyHandoff
            )

            await service.initialize()

            let active = await service.getActiveJourneys(for: distinctId)
            expect(active).to(beEmpty())
            expect(store.loadJourney(id: "server-run-1")).to(beNil())
            expect(store.getCompletions(for: distinctId)).to(beEmpty())
            expect(
                mocks.eventLog.trackForTriggerCalls.contains {
                    $0.event == JourneyEvents.journeyHandoff
                        && $0.properties?["epoch"] as? Int == 3
                }
            ).to(beTrue())
        }

        it("retains a handed-off run until a delayed ownership acknowledgement arrives") {
            await prime(
                mailbox: [mailboxEntry()],
                regionActions: [
                    .handoff(
                        HandoffAction(
                            nodeId: "handoff-node",
                            edgeId: "edge-1",
                            direction: "device_to_server",
                            toRegionId: "server-region-1",
                            toNodeId: "email-node"
                        )
                    )
                ]
            )
            mocks.eventLog.trackWithResponseResult = EventResponse(
                status: "ok",
                journeyClaim: EventResponse.JourneyClaimAcknowledgement(
                    journeyId: "server-run-1",
                    accepted: true,
                    epoch: 3
                )
            )

            await service.initialize()

            let retained = await service.getActiveJourneys(for: distinctId)
            expect(retained).to(haveCount(1))
            expect(store.loadJourney(id: "server-run-1")).toNot(beNil())

            mocks.eventLog.trackWithResponseResult = EventResponse(
                status: "ok",
                journeyOwnership: EventResponse.JourneyOwnershipAcknowledgement(
                    journeyId: "server-run-1",
                    accepted: true,
                    epoch: 4
                )
            )
            _ = try await mocks.eventLog.trackWithResponse(
                "ownership-ack-probe",
                properties: nil
            )

            let activeAfterAck = await service.getActiveJourneys(
                for: distinctId
            )
            expect(activeAfterAck).to(beEmpty())
            expect(store.loadJourney(id: "server-run-1")).to(beNil())
            expect(store.getCompletions(for: distinctId)).to(beEmpty())
        }

        it("plays a superseded journey to local exit without accounting") {
            await prime(mailbox: [])
            await service.initialize()
            guard let journey = await service.startJourney(
                for: campaign(),
                distinctId: distinctId,
                originEventId: nil
            ) else {
                return fail("Expected journey")
            }
            await service.handleEvent(
                NuxieEvent(
                    name: JourneyEvents.journeySuperseded,
                    distinctId: distinctId,
                    properties: [
                        "journey_id": journey.id,
                        StoredEvent.originProperty:
                            StoredEventOrigin.server.rawValue,
                    ]
                )
            )
            await service.handleEvent(
                NuxieEvent(name: "finish", distinctId: distinctId)
            )

            let active = await service.getActiveJourneys(for: distinctId)
            expect(active).to(beEmpty())
            expect(store.getCompletions(for: distinctId)).to(beEmpty())
            expect(
                mocks.eventLog.trackWithResponseCalls.contains {
                    $0.event == JourneyEvents.journeyExited
                }
            ).to(beFalse())
        }
    }
}
