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
        let experienceId = "ownership-experience"
        let flowId = "ownership-flow-v1"

        func experience(
            id: String = experienceId,
            versionId: String = flowId,
            trigger: ExperienceTrigger? = nil
        ) -> Experience {
            Experience(
                id: id,
                name: "Ownership",
                flowId: versionId,
                flowNumber: 1,
                flowName: nil,
                reentry: .everyTime,
                publishedAt: "2026-07-25T00:00:00Z",
                trigger: trigger,
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                experienceType: nil
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

        func mailboxEntry(
            kind: JourneyMailboxKind = .pending,
            stateVersion: Int = 1,
            pendingAction: FlowPendingAction? = nil,
            resumeNodeId: String? = nil,
            checkpointAt: Date? = nil
        ) -> JourneyMailboxEntry {
            JourneyMailboxEntry(
                kind: kind,
                journeyId: "server-run-1",
                experienceId: experienceId,
                experienceVersion: flowId,
                epoch: 2,
                stateVersion: stateVersion,
                envelope: JourneyStateEnvelope(
                    stateVersion: stateVersion,
                    context: ["source": AnyCodable("server")],
                    flowState: FlowJourneyState(
                        regionId: "device-region-1",
                        currentNodeId: "wait-node",
                        pendingAction: pendingAction
                    ),
                    snapshots: [:]
                ),
                expiresAt: Date().addingTimeInterval(3_600),
                resumeNodeId: resumeNodeId,
                checkpointAt: checkpointAt
            )
        }

        func prime(
            mailbox: [JourneyMailboxEntry],
            regionActions: [JourneyAction]? = nil,
            experiences: [Experience]? = nil
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
                    experiences: experiences ?? [experience()],
                    segments: [],
                    pinnedVersions: [remoteFlow],
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

        it("claims a journey from a pinned version after the active version advances") {
            await prime(
                mailbox: [mailboxEntry()],
                experiences: [experience(versionId: "ownership-flow-v2")]
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

            let active = await service.getActiveJourneys(for: distinctId)
            expect(active).to(haveCount(1))
            expect(active.first?.experienceVersion).to(equal(flowId))
            expect(store.loadJourney(id: "server-run-1")?.experienceVersion)
                .to(equal(flowId))
        }

        it("claims a journey when reentry filtering leaves only its pinned version") {
            await prime(
                mailbox: [mailboxEntry()],
                experiences: []
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

            let active = await service.getActiveJourneys(for: distinctId)
            expect(active).to(haveCount(1))
            expect(active.first?.experienceId).to(equal(experienceId))
            expect(active.first?.experienceVersion).to(equal(flowId))
        }

        it("restores a claimable takeover without running it more eagerly than relaunch") {
            let checkpointAt = Date(timeIntervalSince1970: 1_785_196_200)
            await prime(
                mailbox: [
                    mailboxEntry(
                        kind: .claimable,
                        resumeNodeId: "question-3",
                        checkpointAt: checkpointAt
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

            let active = await service.getActiveJourneys(for: distinctId)
            expect(active).to(haveCount(1))
            expect(active.first?.status).to(equal(.active))
            expect(active.first?.resumePoint).to(equal(
                JourneyResumePoint(
                    nodeId: "question-3",
                    checkpointAt: checkpointAt
                )
            ))
            expect(
                mocks.eventLog.trackedEvents.contains {
                    $0.name == JourneyEvents.journeyParked
                }
            ).to(beFalse())
            expect(mocks.flowPresentationService.presentFlowCallCount)
                .to(equal(0))

            await service.handleEvent(
                NuxieEvent(name: "finish", distinctId: distinctId)
            )

            expect(mocks.flowPresentationService.presentFlowCallCount)
                .to(equal(1))
            expect(mocks.flowPresentationService.lastPresentedJourney?.resumePoint)
                .to(equal(
                    JourneyResumePoint(
                        nodeId: "question-3",
                        checkpointAt: checkpointAt
                    )
                ))
        }

        it("re-arms a claimed pending action and fires it immediately when past due") {
            let now = mocks.dateProvider.now()
            let pending = FlowPendingAction(
                handlerId: "claimed-wait",
                screenId: nil,
                componentId: nil,
                actionIndex: 0,
                kind: .delay,
                resumeAt: now.addingTimeInterval(-60),
                condition: nil,
                maxTimeMs: nil,
                startedAt: now.addingTimeInterval(-120),
                resumeActions: [
                    .milestone(
                        MilestoneAction(
                            nodeId: "claimed-resume",
                            milestoneId: "claimed-wait-resumed"
                        )
                    )
                ]
            )
            mocks.sleepProvider.shouldCompleteImmediately = true
            await prime(
                mailbox: [
                    mailboxEntry(
                        kind: .claimable,
                        pendingAction: pending,
                        resumeNodeId: "claimed-wait",
                        checkpointAt: now.addingTimeInterval(-120)
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

            await polling(expect {
                mocks.eventLog.trackForTriggerCalls.contains {
                    $0.event == JourneyEvents.journeyMilestone
                        && $0.properties?["milestone_id"] as? String
                            == "claimed-wait-resumed"
                }
            }).value.toEventually(beTrue(), timeout: .seconds(2))
            expect(mocks.sleepProvider.sleepCalls.map(\.duration))
                .to(contain(0))
            let active = await service.getActiveJourneys(for: distinctId)
            expect(active.first?.flowState.pendingAction).to(beNil())
        }

        it("skips a claimable offer when the journey already exists locally") {
            await prime(
                mailbox: [
                    mailboxEntry(
                        kind: .claimable,
                        resumeNodeId: "question-3",
                        checkpointAt: mocks.dateProvider.now()
                    )
                ]
            )
            let local = Journey(
                id: "server-run-1",
                experience: experience(),
                distinctId: distinctId,
                now: mocks.dateProvider.now()
            )
            try store.saveJourney(local)

            await service.initialize()

            expect(mocks.eventLog.trackForTriggerCalls).to(beEmpty())
            let active = await service.getActiveJourneys(for: distinctId)
            expect(active.map(\.id)).to(equal(["server-run-1"]))
            expect(active.first).to(beIdenticalTo(local))
        }

        it("discards the original-device run after a takeover epoch rejection") {
            await prime(
                mailbox: [
                    mailboxEntry(
                        kind: .claimable,
                        resumeNodeId: "question-3",
                        checkpointAt: mocks.dateProvider.now()
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
            let claimed = await service.getActiveJourneys(for: distinctId)
            expect(claimed).to(haveCount(1))

            mocks.eventLog.trackWithResponseResult = EventResponse(
                status: "rejected",
                journeyOwnership:
                    EventResponse.JourneyOwnershipAcknowledgement(
                        journeyId: "server-run-1",
                        accepted: false,
                        epoch: 4,
                        reason: "stale_epoch"
                    )
            )
            _ = try await mocks.eventLog.trackWithResponse(
                "original-device-stale-emission",
                properties: nil
            )

            let remaining = await service.getActiveJourneys(for: distinctId)
            expect(remaining).to(beEmpty())
            expect(store.loadJourney(id: "server-run-1")).to(beNil())
            expect(store.getCompletions(for: distinctId)).to(beEmpty())
        }

        it("never enrolls a triggerless server-owned experience from a local event") {
            let clientExperience = experience(
                id: "client-owned-experience",
                trigger: .event(
                    EventTriggerConfig(
                        eventName: "matching-local-event",
                        condition: nil
                    )
                )
            )
            await prime(
                mailbox: [],
                experiences: [experience(), clientExperience]
            )

            await service.initialize()
            await service.handleEvent(
                NuxieEvent(
                    name: "matching-local-event",
                    distinctId: distinctId
                )
            )

            let active = await service.getActiveJourneys(for: distinctId)
            expect(active.map(\.experienceId)).to(equal(["client-owned-experience"]))
            expect(active.map(\.experienceId)).toNot(contain(experienceId))
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

        it("keeps a device timeout handoff terminal when a late seizure response loses") {
            await prime(
                mailbox: [mailboxEntry()],
                regionActions: [
                    .handoff(
                        HandoffAction(
                            nodeId: "timeout-handoff",
                            edgeId: "timeout-edge",
                            direction: "device_to_server",
                            toRegionId: "server-timeout",
                            toNodeId: "timeout-push"
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
                    journeyOwnership:
                        EventResponse.JourneyOwnershipAcknowledgement(
                            journeyId: "server-run-1",
                            accepted: true,
                            epoch: 4
                        )
                ),
                for: JourneyEvents.journeyHandoff
            )

            await service.initialize()

            let afterHandoff = await service.getActiveJourneys(
                for: distinctId
            )
            expect(afterHandoff).to(beEmpty())
            expect(
                mocks.eventLog.trackForTriggerCalls.filter {
                    $0.event == JourneyEvents.journeyHandoff
                }
            ).to(haveCount(1))

            mocks.eventLog.trackWithResponseResult = EventResponse(
                status: "rejected",
                journeyOwnership:
                    EventResponse.JourneyOwnershipAcknowledgement(
                        journeyId: "server-run-1",
                        accepted: false,
                        epoch: 4,
                        reason: "stale_epoch"
                    )
            )
            _ = try await mocks.eventLog.trackWithResponse(
                "late-seizure-probe",
                properties: nil
            )

            let afterLateSeizure = await service.getActiveJourneys(
                for: distinctId
            )
            expect(afterLateSeizure).to(beEmpty())
            expect(store.loadJourney(id: "server-run-1")).to(beNil())
            expect(store.getCompletions(for: distinctId)).to(beEmpty())
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
                for: experience(),
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
