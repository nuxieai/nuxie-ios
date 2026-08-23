import Foundation
import Quick
import Nimble

@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class HostDismissalTests: AsyncSpec {
    override class func spec() {
        nonisolated(unsafe) var serviceUnderTest: JourneyService?
        nonisolated(unsafe) var notificationToken: NSObjectProtocol?
        nonisolated(unsafe) var temporaryStorageURL: URL?

        beforeEach { @MainActor in
            serviceUnderTest = nil
            notificationToken = nil
            temporaryStorageURL = nil
            await NuxieSDK.shared.shutdown()
            await MockFactory.shared.resetAll()
        }

        afterEach { @MainActor in
            if let notificationToken {
                NotificationCenter.default.removeObserver(notificationToken)
            }
            await serviceUnderTest?.shutdown()
            await NuxieSDK.shared.shutdown()
            await MockFactory.shared.resetAll()
            if let temporaryStorageURL {
                try? FileManager.default.removeItem(at: temporaryStorageURL)
            }
            serviceUnderTest = nil
            notificationToken = nil
            temporaryStorageURL = nil
        }

        describe("host dismissal") {
            it("completes a pre-screen dismissal with host metadata") { @MainActor in
                let harness = await HostJourneyHarness.make(definition: .singleScreen())
                serviceUnderTest = harness.service
                let originEventId = "pre-screen-host-dismiss"
                let updates = TriggerUpdateRecorder()
                await harness.mocks.triggerBroker.register(eventId: originEventId) {
                    updates.append($0)
                }
                let journey = try await harness.startJourney(originEventId: originEventId)

                let beforeDismissal = await journey.snapshot()
                expect(beforeDismissal.executionState.pendingPresentation).toNot(beNil())
                expect(beforeDismissal.executionState.currentScreenId).to(beNil())

                guard let delegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the presentation's runtime delegate")
                    return
                }
                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                await delegate.experienceViewControllerDidRequestHostDismiss(
                    harness.controller
                )

                let terminal = await journey.snapshot()
                expect(terminal.status).to(equal(.completed))
                expect(terminal.exitReason).to(equal(.dismissed))
                let activeJourneys = await harness.service.getActiveJourneys(
                    for: harness.distinctId
                )
                expect(activeJourneys).to(beEmpty())
                expect(harness.store.loadJourney(id: journey.id)).to(beNil())

                guard let exit = harness.journeyExitedCall() else {
                    fail("expected a journey exit event")
                    return
                }
                expect(exit.properties?["reason"] as? String).to(equal("dismissed"))
                expect(exit.properties?["dismissed_by"] as? String).to(equal("host"))

                let journeyUpdate = try await waitForHostJourneyUpdate(in: updates)
                expect(journeyUpdate.journeyId).to(equal(journey.id))
                expect(journeyUpdate.exitReason).to(equal(.dismissed))
                expect(updates.values.contains(where: \.isDenied)).to(beFalse())
            }

            it("reserves the host outcome before a competing ordinary dismissal") { @MainActor in
                let harness = await HostJourneyHarness.make(definition: .singleScreen())
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "reserved-host-dismiss"
                )
                let notifications = HostDismissNotificationRecorder()
                notificationToken = NotificationCenter.default.addObserver(
                    forName: .nuxieDismiss,
                    object: nil,
                    queue: nil
                ) { notification in
                    notifications.append(notification)
                }

                guard let delegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the presentation's runtime delegate")
                    return
                }
                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                await harness.service.handleRuntimeDismiss(
                    journeyId: journey.id,
                    reason: .userDismissed,
                    controller: harness.controller
                )

                let reserved = await journey.snapshot()
                expect(reserved.status.isLive).to(beTrue())
                expect(reserved.exitReason).to(beNil())
                expect(notifications.values).to(beEmpty())

                await delegate.experienceViewControllerDidRequestHostDismiss(
                    harness.controller
                )

                let terminal = await journey.snapshot()
                expect(terminal.status).to(equal(.completed))
                expect(terminal.exitReason).to(equal(.dismissed))
                expect(notifications.values).to(haveCount(1))
                expect(notifications.values.first?.reason).to(equal("host_dismissed"))
                guard let exit = harness.journeyExitedCall() else {
                    fail("expected a journey exit event")
                    return
                }
                expect(exit.properties?["reason"] as? String).to(equal("dismissed"))
                expect(exit.properties?["dismissed_by"] as? String).to(equal("host"))
            }

            it("lets authoritative ownership loss override host reservation") { @MainActor in
                let harness = await HostJourneyHarness.make(definition: .singleScreen())
                serviceUnderTest = harness.service
                await harness.service.initialize()
                let updates = TriggerUpdateRecorder()
                await harness.mocks.triggerBroker.register(
                    eventId: "accepted-handoff-host-race"
                ) {
                    updates.append($0)
                }

                let handedOff = try await harness.startJourney(
                    originEventId: "accepted-handoff-host-race"
                )
                guard let handoffDelegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the handoff journey's runtime delegate")
                    return
                }
                await handoffDelegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                let acceptedHandoffEvent = "accepted-handoff-host-race-ack"
                harness.mocks.eventLog.setTrackWithResponseResult(
                    EventResponse(
                        status: "ok",
                        journeyOwnership: .init(
                            journeyId: handedOff.id,
                            accepted: true,
                            epoch: 1
                        )
                    ),
                    for: acceptedHandoffEvent
                )
                _ = try await harness.mocks.eventLog.trackForTrigger(
                    acceptedHandoffEvent,
                    properties: nil,
                    persistToHistory: false,
                    distinctIdOverride: harness.distinctId,
                    applyBeforeSend: false
                )

                let handedOffState = await handedOff.snapshot()
                let handoffReservation = await handedOff.hasHostDismissalReservation()
                expect(handedOffState.status).to(equal(.transferred))
                expect(handoffReservation).to(beFalse())
                expect(harness.store.loadJourney(id: handedOff.id)).to(beNil())
                let handoffDismissalResult = await handoffDelegate
                    .experienceViewControllerDidRequestHostDismiss(harness.controller)
                expect(handoffDismissalResult).to(beTrue())
                expect(updates.values.compactMap(\.journeyUpdate).last?.exitReason)
                    .to(equal(.dismissed))

                await harness.mocks.triggerBroker.register(
                    eventId: "epoch-rejected-host-race"
                ) {
                    updates.append($0)
                }
                let epochRejected = try await harness.startJourney(
                    originEventId: "epoch-rejected-host-race"
                )
                guard let rejectionDelegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the rejected journey's runtime delegate")
                    return
                }
                await rejectionDelegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                let epochRejectionEvent = "epoch-rejected-host-race-ack"
                harness.mocks.eventLog.setTrackWithResponseResult(
                    EventResponse(
                        status: "ok",
                        journeyClaim: .init(
                            journeyId: epochRejected.id,
                            accepted: false,
                            epoch: 1,
                            reason: "epoch_mismatch"
                        )
                    ),
                    for: epochRejectionEvent
                )
                _ = try await harness.mocks.eventLog.trackForTrigger(
                    epochRejectionEvent,
                    properties: nil,
                    persistToHistory: false,
                    distinctIdOverride: harness.distinctId,
                    applyBeforeSend: false
                )

                let rejectedState = await epochRejected.snapshot()
                let rejectionReservation = await epochRejected
                    .hasHostDismissalReservation()
                expect(rejectedState.status).to(equal(.superseded))
                expect(rejectionReservation).to(beFalse())
                expect(harness.store.loadJourney(id: epochRejected.id)).to(beNil())
                let rejectionDismissalResult = await rejectionDelegate
                    .experienceViewControllerDidRequestHostDismiss(harness.controller)
                expect(rejectionDismissalResult).to(beTrue())
                expect(harness.journeyExitedCalls()).to(beEmpty())
                expect(updates.values.compactMap(\.journeyUpdate))
                    .to(haveCount(2))
                expect(updates.values.compactMap(\.journeyUpdate).last?.exitReason)
                    .to(equal(.dismissed))
            }

            it("lets ownership loss revoke a terminal host capture before it commits") { @MainActor in
                let harness = await HostJourneyHarness.make(definition: .singleScreen())
                serviceUnderTest = harness.service
                await harness.service.initialize()
                let originEventId = "terminal-host-capture-ownership-race"
                let updates = TriggerUpdateRecorder()
                await harness.mocks.triggerBroker.register(eventId: originEventId) {
                    updates.append($0)
                }
                let journey = try await harness.startJourney(originEventId: originEventId)
                guard let delegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the presentation's runtime delegate")
                    return
                }

                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                let captureGate = HostDismissalAsyncGate()
                harness.mocks.eventLog.prepareTriggerPropertiesHandler = {
                    await captureGate.suspend()
                }
                let dismissal = Task { @MainActor in
                    await delegate.experienceViewControllerDidRequestHostDismiss(
                        harness.controller
                    )
                }
                try await waitForHostDismissalGate(captureGate)

                let terminal = await journey.snapshot()
                expect(terminal.status).to(equal(.completed))
                expect(terminal.pendingHostExitCapture).to(beTrue())

                await harness.mocks.eventLog.deliverEventResponseSignals(
                    EventResponse(
                        status: "ok",
                        journeyClaim: .init(
                            journeyId: journey.id,
                            accepted: false,
                            epoch: terminal.epoch,
                            reason: "epoch_mismatch"
                        )
                    )
                )
                await captureGate.release()

                let dismissalResult = await dismissal.value
                expect(dismissalResult).to(beTrue())
                let revoked = await journey.snapshot()
                expect(revoked.status).to(equal(.superseded))
                expect(harness.store.loadJourney(id: journey.id)).to(beNil())
                expect(harness.journeyExitedCalls()).to(beEmpty())
                let update = try await waitForHostJourneyUpdate(in: updates)
                expect(update.exitReason).to(equal(.dismissed))
                expect(updates.values.compactMap(\.journeyUpdate)).to(haveCount(1))
                expect(updates.values.contains(where: \.isDenied)).to(beFalse())
            }

            it("releases the host reservation but preserves retry authority after persistence fails") { @MainActor in
                let harness = await HostJourneyHarness.make(definition: .singleScreen())
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "failed-host-dismiss"
                )
                guard let delegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the presentation's runtime delegate")
                    return
                }

                harness.store.shouldThrowOnSave = true
                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                let terminalized = await delegate.experienceViewControllerDidRequestHostDismiss(
                    harness.controller
                )

                expect(terminalized).to(beFalse())
                let afterFailure = await journey.snapshot()
                expect(afterFailure.status.isLive).to(beTrue())
                expect(afterFailure.exitReason).to(beNil())
                let hostStillOwnsJourney = await journey.hasHostDismissalReservation()
                expect(hostStillOwnsJourney).to(beFalse())

                harness.store.shouldThrowOnSave = false
                await harness.service.handleRuntimeDismiss(
                    journeyId: journey.id,
                    reason: .userDismissed,
                    controller: harness.controller
                )

                let ordinaryDismissBlocked = await journey.snapshot()
                expect(ordinaryDismissBlocked.status.isLive).to(beTrue())
                expect(ordinaryDismissBlocked.exitReason).to(beNil())
                expect(harness.journeyExitedCalls()).to(beEmpty())

                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                let retried = await delegate.experienceViewControllerDidRequestHostDismiss(
                    harness.controller
                )
                expect(retried).to(beTrue())

                let terminal = await journey.snapshot()
                expect(terminal.status).to(equal(.completed))
                expect(terminal.exitReason).to(equal(.dismissed))
                let exits = harness.journeyExitedCalls()
                expect(exits).to(haveCount(1))
                expect(exits.first?.properties?["reason"] as? String)
                    .to(equal("dismissed"))
                expect(exits.first?.properties?["dismissed_by"] as? String)
                    .to(equal("host"))
            }

            it("preserves a reserved old-user host dismissal when persistence fails") { @MainActor in
                let callbackEvent = "late-reserved-old-user-callback"
                let taintedProperty = "replacement_user_reserved_taint"
                let definition = ExperienceDefinition.singleScreen(
                    routes: [
                        .init(
                            eventName: callbackEvent,
                            program: [
                                .object([
                                    "type": .string("update_customer"),
                                    "attributes": .object([
                                        taintedProperty: .string("yes"),
                                    ]),
                                ]),
                            ]
                        ),
                    ]
                )
                let harness = await HostJourneyHarness.make(definition: definition)
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "failed-reserved-old-user-host-dismiss"
                )
                let updates = TriggerUpdateRecorder()
                await harness.mocks.triggerBroker.register(
                    eventId: "failed-reserved-old-user-host-dismiss"
                ) {
                    updates.append($0)
                }
                guard let delegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the presentation's runtime delegate")
                    return
                }

                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                harness.mocks.identityService.setDistinctId("replacement-user")
                await harness.service.handleUserChange(
                    from: harness.distinctId,
                    to: "replacement-user"
                )

                harness.store.shouldThrowOnSave = true
                let terminalized = await delegate
                    .experienceViewControllerDidRequestHostDismiss(harness.controller)
                harness.store.shouldThrowOnSave = false

                expect(terminalized).to(beFalse())
                let retryable = await journey.snapshot()
                let reservation = await journey.hasHostDismissalReservation()
                expect(retryable.status.isLive).to(beTrue())
                expect(retryable.exitReason).to(beNil())
                expect(reservation).to(beFalse())
                expect(harness.store.loadJourney(id: journey.id)?.status.isLive).to(beTrue())
                expect(harness.journeyExitedCalls()).to(beEmpty())
                expect(updates.values).to(beEmpty())

                await harness.service.handleRendererEvent(
                    journeyId: journey.id,
                    event: ExperienceRendererEvent(
                        name: callbackEvent,
                        properties: [:],
                        screenId: HostJourneyHarness.screenId,
                        componentId: nil,
                        instanceId: nil
                    )
                )
                expect(
                    harness.mocks.identityService.getUserProperties()[taintedProperty]
                ).to(beNil())

                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                let retried = await delegate
                    .experienceViewControllerDidRequestHostDismiss(harness.controller)
                expect(retried).to(beTrue())
                let completed = await journey.snapshot()
                expect(completed.status).to(equal(.completed))
                expect(completed.exitReason).to(equal(.dismissed))
                expect(harness.journeyExitedCalls()).to(haveCount(1))
                let update = try await waitForHostJourneyUpdate(in: updates)
                expect(update.exitReason).to(equal(.dismissed))
                expect(updates.values.contains(where: \.isDenied)).to(beFalse())
            }

            it("retains an admitted host retry through a later identity change") { @MainActor in
                let harness = await HostJourneyHarness.make(definition: .singleScreen())
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "host-retry-before-identity-change"
                )
                guard let delegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the presentation's runtime delegate")
                    return
                }

                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                harness.store.shouldThrowOnSave = true
                let firstAttempt = await delegate
                    .experienceViewControllerDidRequestHostDismiss(harness.controller)
                harness.store.shouldThrowOnSave = false
                expect(firstAttempt).to(beFalse())

                harness.mocks.identityService.setDistinctId("replacement-user")
                await harness.service.handleUserChange(
                    from: harness.distinctId,
                    to: "replacement-user"
                )

                let retained = await harness.service.getActiveJourneys(
                    for: harness.distinctId
                )
                let retainedState = await journey.snapshot()
                expect(retained.map(\.id)).to(contain(journey.id))
                expect(retainedState.status.isLive).to(beTrue())

                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                let retried = await delegate
                    .experienceViewControllerDidRequestHostDismiss(harness.controller)
                let terminal = await journey.snapshot()
                expect(retried).to(beTrue())
                expect(terminal.exitReason).to(equal(.dismissed))
            }

            it("does not park a retained host retry under a replacement identity") { @MainActor in
                let harness = await HostJourneyHarness.make(definition: .singleScreen())
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "host-retry-background-identity"
                )
                guard let delegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the presentation's runtime delegate")
                    return
                }

                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                harness.store.shouldThrowOnSave = true
                let terminalized = await delegate
                    .experienceViewControllerDidRequestHostDismiss(harness.controller)
                harness.store.shouldThrowOnSave = false
                expect(terminalized).to(beFalse())

                harness.mocks.identityService.setDistinctId("replacement-user")
                await harness.service.handleUserChange(
                    from: harness.distinctId,
                    to: "replacement-user"
                )
                await harness.service.onAppDidEnterBackground()

                expect(harness.mocks.eventLog.trackedEvents.map(\.name))
                    .toNot(contain(JourneyEvents.journeyParked))
                let retained = await journey.snapshot()
                expect(retained.status.isLive).to(beTrue())
            }

            it("keeps an authorized host retry live when a converted down-fact arrives") { @MainActor in
                let harness = await HostJourneyHarness.make(
                    definition: .singleScreen(),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "host-retry-converted-fact"
                )
                guard let delegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the presentation's runtime delegate")
                    return
                }

                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                harness.store.shouldThrowOnSave = true
                let firstAttempt = await delegate
                    .experienceViewControllerDidRequestHostDismiss(harness.controller)
                harness.store.shouldThrowOnSave = false
                expect(firstAttempt).to(beFalse())

                harness.mocks.identityService.setDistinctId("replacement-user")
                await harness.service.handleUserChange(
                    from: harness.distinctId,
                    to: "replacement-user"
                )
                await harness.service.handleEvent(NuxieEvent(
                    name: JourneyEvents.journeyConverted,
                    distinctId: harness.distinctId,
                    properties: [
                        StoredEvent.originProperty: StoredEventOrigin.server.rawValue,
                        "journey_id": journey.id,
                        "at": Date(timeIntervalSince1970: 1_700_000_000).ISO8601Format(),
                        "source_fact_ref": "server-conversion-fact",
                    ]
                ))

                let retryable = await journey.snapshot()
                expect(retryable.status.isLive).to(beTrue())
                expect(retryable.exitReason).to(beNil())
                expect(retryable.convertedAt).to(beNil())
                expect(harness.journeyExitedCalls()).to(beEmpty())

                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                let retried = await delegate
                    .experienceViewControllerDidRequestHostDismiss(harness.controller)
                expect(retried).to(beTrue())
                let terminal = await journey.snapshot()
                expect(terminal.exitReason).to(equal(.dismissed))
                expect(harness.journeyExitedCalls()).to(haveCount(1))
            }

            it("retains host recovery until completion accounting succeeds") { @MainActor in
                let harness = await HostJourneyHarness.make(definition: .singleScreen())
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "host-completion-accounting-recovery"
                )
                guard let delegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the presentation's runtime delegate")
                    return
                }

                harness.store.shouldThrowOnRecord = true
                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                let terminalized = await delegate
                    .experienceViewControllerDidRequestHostDismiss(harness.controller)

                expect(terminalized).to(beTrue())
                guard let terminal = harness.store.loadJourney(id: journey.id) else {
                    fail("expected the host recovery snapshot")
                    return
                }
                expect(terminal.pendingHostExitCapture).to(beTrue())
                expect(harness.store.getCompletions(for: harness.distinctId)).to(beEmpty())

                harness.store.shouldThrowOnRecord = false
                await harness.service.onAppWillEnterForeground()

                expect(harness.store.loadJourney(id: journey.id)).to(beNil())
                let completions = harness.store.getCompletions(for: harness.distinctId)
                expect(completions.map(\.journeyId)).to(equal([journey.id]))
                expect(completions.first?.completedAt).to(equal(terminal.completedAt))

                await harness.service.onAppWillEnterForeground()
                expect(harness.store.getCompletions(for: harness.distinctId))
                    .to(haveCount(1))
            }

            it("drops a captured host exit fenced before completion recovery") { @MainActor in
                let harness = await HostJourneyHarness.make(definition: .singleScreen())
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "host-fenced-completion-recovery"
                )
                guard let delegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the presentation's runtime delegate")
                    return
                }

                harness.store.shouldThrowOnRecord = true
                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                let terminalized = await delegate
                    .experienceViewControllerDidRequestHostDismiss(harness.controller)
                expect(terminalized).to(beTrue())
                guard let terminal = harness.store.loadJourney(id: journey.id) else {
                    fail("expected the host recovery snapshot")
                    return
                }
                expect(terminal.pendingHostExitCapture).to(beTrue())
                expect(harness.journeyExitedCalls()).to(haveCount(1))
                expect(harness.store.getCompletions(for: harness.distinctId)).to(beEmpty())

                await harness.mocks.eventLog.deliverEventResponseSignals(
                    EventResponse(
                        status: "ok",
                        journeyClaim: .init(
                            journeyId: journey.id,
                            accepted: false,
                            epoch: terminal.epoch,
                            reason: "epoch_mismatch"
                        )
                    )
                )
                harness.store.shouldThrowOnRecord = false
                await harness.service.onAppWillEnterForeground()

                expect(harness.store.loadJourney(id: journey.id)).to(beNil())
                expect(harness.store.getCompletions(for: harness.distinctId)).to(beEmpty())
                expect(harness.journeyExitedCalls()).to(haveCount(1))
            }

            it("suppresses one-time reentry while host completion accounting awaits recovery") { @MainActor in
                let harness = await HostJourneyHarness.make(
                    definition: .singleScreen(),
                    reentry: .oneTime
                )
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "host-pending-completion-suppression"
                )
                guard let delegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the presentation's runtime delegate")
                    return
                }

                harness.store.shouldThrowOnRecord = true
                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                let terminalized = await delegate
                    .experienceViewControllerDidRequestHostDismiss(harness.controller)

                expect(terminalized).to(beTrue())
                expect(harness.store.loadJourney(id: journey.id)?.pendingHostExitCapture)
                    .to(beTrue())
                harness.mocks.eventLog.shouldFailJourneyOwnershipCheck = true
                let reenrollment = await harness.service.startJourney(
                    for: harness.experience,
                    distinctId: harness.distinctId,
                    originEventId: "host-pending-completion-reentry"
                )
                expect(reenrollment).to(beNil())
            }

            it("retains a reserved journey through an identity change") { @MainActor in
                let harness = await HostJourneyHarness.make(definition: .singleScreen())
                serviceUnderTest = harness.service
                let originEventId = "identity-change-host-dismiss"
                let updates = TriggerUpdateRecorder()
                await harness.mocks.triggerBroker.register(eventId: originEventId) {
                    updates.append($0)
                }
                let journey = try await harness.startJourney(originEventId: originEventId)
                guard let delegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the presentation's runtime delegate")
                    return
                }

                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                await harness.service.handleUserChange(
                    from: harness.distinctId,
                    to: "replacement-user"
                )

                let retained = await harness.service.getActiveJourneys(
                    for: harness.distinctId
                )
                expect(retained.map(\.id)).to(contain(journey.id))

                await delegate.experienceViewControllerDidRequestHostDismiss(
                    harness.controller
                )

                let terminal = await journey.snapshot()
                expect(terminal.status).to(equal(.completed))
                expect(terminal.exitReason).to(equal(.dismissed))
                guard let exit = harness.journeyExitedCall() else {
                    fail("expected a journey exit event")
                    return
                }
                expect(exit.properties?["reason"] as? String).to(equal("dismissed"))
                expect(exit.properties?["dismissed_by"] as? String).to(equal("host"))
                let update = try await waitForHostJourneyUpdate(in: updates)
                expect(update.exitReason).to(equal(.dismissed))
                expect(updates.values.contains(where: \.isDenied)).to(beFalse())
            }

            it("rejects a new host reservation after the identity changes") { @MainActor in
                let harness = await HostJourneyHarness.make(definition: .singleScreen())
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "late-host-reservation-after-identity-change"
                )
                guard let delegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the presentation's runtime delegate")
                    return
                }

                harness.mocks.identityService.setDistinctId("replacement-user")
                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )

                let reserved = await journey.hasHostDismissalReservation()
                expect(reserved).to(beFalse())

                let terminalized = await delegate
                    .experienceViewControllerDidRequestHostDismiss(harness.controller)
                let state = await journey.snapshot()
                expect(terminalized).to(beFalse())
                expect(state.status.isLive).to(beTrue())
                expect(harness.journeyExitedCalls()).to(beEmpty())
            }

            it("quarantines failed old-user cancellations") { @MainActor in
                let callbackEvent = "late-old-user-callback"
                let taintedProperty = "replacement_user_tainted"
                let definition = ExperienceDefinition.singleScreen(
                    routes: [
                        .init(
                            eventName: callbackEvent,
                            program: [
                                .object([
                                    "type": .string("update_customer"),
                                    "attributes": .object([
                                        taintedProperty: .string("yes"),
                                    ]),
                                ]),
                            ]
                        ),
                    ]
                )
                let harness = await HostJourneyHarness.make(definition: definition)
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "failed-old-user-cancellation"
                )

                harness.mocks.identityService.setDistinctId("replacement-user")
                harness.store.shouldThrowOnSave = true
                await harness.service.handleUserChange(
                    from: harness.distinctId,
                    to: "replacement-user"
                )
                harness.store.shouldThrowOnSave = false

                let quarantined = await journey.snapshot()
                expect(quarantined.status).to(equal(.cancelled))
                let oldJourneys = await harness.service.getActiveJourneys(
                    for: harness.distinctId
                )
                expect(oldJourneys).to(beEmpty())
                expect(harness.store.loadJourney(id: journey.id)).to(beNil())

                await harness.service.handleRendererEvent(
                    journeyId: journey.id,
                    event: ExperienceRendererEvent(
                        name: callbackEvent,
                        properties: [:],
                        screenId: HostJourneyHarness.screenId,
                        componentId: nil,
                        instanceId: nil
                    )
                )

                expect(
                    harness.mocks.identityService.getUserProperties()[taintedProperty]
                ).to(beNil())
                expect(harness.mocks.eventLog.routedEvents.map(\.name))
                    .toNot(contain(JourneyEvents.customerUpdated))
            }

            it("quarantines an in-flight old-user renderer callback") { @MainActor in
                let callbackEvent = "in-flight-old-user-callback"
                let taintedProperty = "replacement_user_in_flight_taint"
                let definition = ExperienceDefinition.singleScreen(
                    routes: [
                        .init(
                            eventName: callbackEvent,
                            program: [
                                .object([
                                    "type": .string("update_customer"),
                                    "attributes": .object([
                                        taintedProperty: .string("yes"),
                                    ]),
                                ]),
                            ]
                        ),
                    ]
                )
                let harness = await HostJourneyHarness.make(definition: definition)
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "in-flight-old-user-cancellation"
                )
                await harness.service.handleRuntimeReady(
                    journeyId: journey.id,
                    controller: harness.controller
                )
                let gate = HostDismissalAsyncGate()
                harness.mocks.eventLog.prepareTriggerPropertiesHandler = {
                    await gate.suspend()
                }

                let callback = Task {
                    await harness.service.handleRendererEvent(
                        journeyId: journey.id,
                        event: ExperienceRendererEvent(
                            name: callbackEvent,
                            properties: [:],
                            screenId: HostJourneyHarness.screenId,
                            componentId: nil,
                            instanceId: nil
                        )
                    )
                }
                try await waitForHostDismissalGate(gate)

                harness.mocks.identityService.setDistinctId("replacement-user")
                harness.store.shouldThrowOnSave = true
                await harness.service.handleUserChange(
                    from: harness.distinctId,
                    to: "replacement-user"
                )
                harness.store.shouldThrowOnSave = false
                await gate.release()
                await callback.value

                let quarantined = await journey.snapshot()
                expect(quarantined.status).to(equal(.cancelled))
                expect(
                    harness.mocks.identityService.getUserProperties()[taintedProperty]
                ).to(beNil())
                expect(harness.mocks.eventLog.routedEvents.map(\.name))
                    .toNot(contain(JourneyEvents.customerUpdated))
            }

            it("quarantines an admitted old-user scoped permission callback") { @MainActor in
                let harness = await HostJourneyHarness.make(definition: .singleScreen())
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "in-flight-old-user-permission"
                )
                let gate = HostDismissalAsyncGate()
                harness.mocks.eventLog.prepareTriggerPropertiesHandler = {
                    await gate.suspend()
                }

                let callback = Task {
                    await harness.service.handleScopedPermissionEvent(
                        journeyId: journey.id,
                        eventName: SystemEventNames.permissionGranted,
                        properties: ["type": "notifications"],
                        distinctId: harness.distinctId
                    )
                }
                try await waitForHostDismissalGate(gate)

                harness.mocks.identityService.setDistinctId("replacement-user")
                harness.store.shouldThrowOnSave = true
                await harness.service.handleUserChange(
                    from: harness.distinctId,
                    to: "replacement-user"
                )
                harness.store.shouldThrowOnSave = false
                await gate.release()
                await callback.value

                expect(harness.mocks.eventLog.trackForTriggerCalls.map(\.event))
                    .toNot(contain(SystemEventNames.permissionGranted))
                let quarantined = await journey.snapshot()
                expect(quarantined.status).to(equal(.cancelled))
            }

            it("quarantines an admitted old-user authored event before commit") { @MainActor in
                let callbackEvent = "in-flight-authored-source"
                let authoredEvent = "in-flight-authored-child"
                let definition = ExperienceDefinition.singleScreen(
                    routes: [
                        .init(
                            eventName: callbackEvent,
                            program: [
                                .object([
                                    "type": .string("send_event"),
                                    "eventName": .string(authoredEvent),
                                    "payload": .object([:]),
                                ]),
                            ]
                        ),
                    ]
                )
                let harness = await HostJourneyHarness.make(definition: definition)
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "in-flight-authored-event"
                )
                await harness.service.handleRuntimeReady(
                    journeyId: journey.id,
                    controller: harness.controller
                )
                let gate = HostDismissalNthCallGate(targetCall: 2)
                harness.mocks.eventLog.prepareTriggerPropertiesHandler = {
                    await gate.suspendIfTargetCall()
                }

                let callback = Task {
                    await harness.service.handleRendererEvent(
                        journeyId: journey.id,
                        event: ExperienceRendererEvent(
                            name: callbackEvent,
                            properties: [:],
                            screenId: HostJourneyHarness.screenId,
                            componentId: nil,
                            instanceId: nil
                        )
                    )
                }
                try await waitForHostDismissalGate(gate)

                harness.mocks.identityService.setDistinctId("replacement-user")
                harness.store.shouldThrowOnSave = true
                await harness.service.handleUserChange(
                    from: harness.distinctId,
                    to: "replacement-user"
                )
                harness.store.shouldThrowOnSave = false
                await gate.release()
                await callback.value

                expect(harness.mocks.eventLog.trackForTriggerCalls.map(\.event))
                    .toNot(contain(authoredEvent))
                expect(harness.mocks.eventLog.routedEvents.map(\.name))
                    .toNot(contain(authoredEvent))
            }

            it("quarantines an admitted old-user screen callback") { @MainActor in
                let definition = ExperienceDefinition.singleScreen(
                    routes: [
                        .init(
                            eventName: SystemEventNames.screenShown,
                            program: [
                                .object([
                                    "type": .string("connector_action"),
                                    "accountRef": .string("account-1"),
                                    "toolKey": .string("send-message"),
                                    "payload": .object([:]),
                                    "timeoutMs": .number(120_000),
                                    "onSucceeded": .array([]),
                                    "onFailed": .array([]),
                                    "onTimeout": .array([]),
                                ]),
                            ]
                        ),
                    ]
                )
                let harness = await HostJourneyHarness.make(definition: definition)
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "admitted-old-user-screen-callback"
                )
                await harness.service.handleRuntimeReady(
                    journeyId: journey.id,
                    controller: harness.controller
                )
                await journey.update {
                    $0.executionState.currentScreenId = nil
                }
                let gate = HostDismissalAsyncGate()
                harness.mocks.eventLog.drainHandler = {
                    await gate.suspend()
                }

                let callback = Task { @MainActor in
                    await harness.service.handleRendererScreenChanged(
                        journeyId: journey.id,
                        screenId: HostJourneyHarness.screenId
                    )
                }
                try await waitForHostDismissalGate(gate)

                harness.mocks.identityService.setDistinctId("replacement-user")
                harness.store.shouldThrowOnSave = true
                await harness.service.handleUserChange(
                    from: harness.distinctId,
                    to: "replacement-user"
                )
                harness.store.shouldThrowOnSave = false
                await gate.release()

                let callbackResult = await callback.value
                let quarantined = await journey.snapshot()
                expect(callbackResult).to(beFalse())
                expect(quarantined.status).to(equal(.cancelled))
                expect(harness.store.loadJourney(id: journey.id)).to(beNil())
                expect(
                    harness.mocks.eventLog.trackWithResponseCalls
                        .filter { $0.event == JourneyEvents.journeyTransition }
                ).to(beEmpty())
            }

            it("keeps a response-authored transition on its journey identity across a blocked flush") { @MainActor in
                let harness = await HostJourneyHarness.make(definition: .singleScreen())
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "blocked-transition-identity"
                )
                await harness.service.handleRuntimeReady(
                    journeyId: journey.id,
                    controller: harness.controller
                )
                await journey.update {
                    $0.executionState.currentScreenId = nil
                }
                let gate = HostDismissalAsyncGate()
                harness.mocks.eventLog.trackWithResponseHandler = { event in
                    guard event == JourneyEvents.journeyTransition else { return }
                    await gate.suspend()
                }

                let callback = Task { @MainActor in
                    await harness.service.handleRendererScreenChanged(
                        journeyId: journey.id,
                        screenId: HostJourneyHarness.screenId
                    )
                }
                try await waitForHostDismissalGate(gate)

                harness.mocks.identityService.setDistinctId("replacement-user")
                await harness.service.handleUserChange(
                    from: harness.distinctId,
                    to: "replacement-user"
                )
                await gate.release()
                _ = await callback.value

                let transitionCalls = harness.mocks.eventLog.trackWithResponseCalls
                    .filter { $0.event == JourneyEvents.journeyTransition }
                expect(transitionCalls).to(haveCount(1))
                expect(transitionCalls.first?.distinctIdOverride)
                    .to(equal(harness.distinctId))
            }

            it("lets host dismissal win over an authored screen dismissal exit") { @MainActor in
                let definition = ExperienceDefinition.singleScreen(
                    routes: [
                        .init(
                            eventName: SystemEventNames.screenDismissed,
                            program: [
                                .object([
                                    "type": .string("exit"),
                                    "reason": .string("error"),
                                ]),
                            ]
                        ),
                    ]
                )
                let harness = await HostJourneyHarness.make(definition: definition)
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "authored-exit-host-dismiss"
                )
                await harness.service.handleRuntimeReady(
                    journeyId: journey.id,
                    controller: harness.controller
                )

                let active = await journey.snapshot()
                expect(active.executionState.currentScreenId)
                    .to(equal(HostJourneyHarness.screenId))

                let notifications = HostDismissNotificationRecorder()
                notificationToken = NotificationCenter.default.addObserver(
                    forName: .nuxieDismiss,
                    object: nil,
                    queue: nil
                ) { notification in
                    notifications.append(notification)
                }

                guard let delegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the presentation's runtime delegate")
                    return
                }
                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                await delegate.experienceViewController(
                    harness.controller,
                    didDismissScreen: HostJourneyHarness.screenId,
                    revealingScreenId: nil,
                    method: ExperienceScreenDismissalMethod.host
                )

                let afterScreenTeardown = await journey.snapshot()
                expect(afterScreenTeardown.status.isLive).to(beTrue())
                expect(afterScreenTeardown.exitReason).to(beNil())

                await delegate.experienceViewControllerDidRequestHostDismiss(
                    harness.controller
                )

                let terminal = await journey.snapshot()
                expect(terminal.status).to(equal(.completed))
                expect(terminal.exitReason)
                    .to(equal(.dismissed), description: "host dismissal must win")
                guard let exit = harness.journeyExitedCall() else {
                    fail("expected a journey exit event")
                    return
                }
                expect(exit.properties?["reason"] as? String).to(equal("dismissed"))
                expect(exit.properties?["dismissed_by"] as? String).to(equal("host"))
                expect(notifications.values).to(haveCount(1))
                expect(notifications.values.first?.reason).to(equal("host_dismissed"))
                expect(notifications.values.first?.journeyId).to(equal(journey.id))
            }

            it("lets reserved host dismissal finish a ghost play-out") { @MainActor in
                let harness = await HostJourneyHarness.make(definition: .singleScreen())
                serviceUnderTest = harness.service
                let originEventId = "ghost-host-dismiss"
                let updates = TriggerUpdateRecorder()
                await harness.mocks.triggerBroker.register(eventId: originEventId) {
                    updates.append($0)
                }
                let journey = try await harness.startJourney(originEventId: originEventId)
                await journey.update { state in
                    state.isGhost = true
                }

                guard let delegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the presentation's runtime delegate")
                    return
                }
                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                await delegate.experienceViewControllerDidRequestHostDismiss(
                    harness.controller
                )

                let terminal = await journey.snapshot()
                expect(terminal.status).to(equal(.completed))
                expect(terminal.exitReason).to(equal(.dismissed))
                guard let exit = harness.journeyExitedCall() else {
                    fail("expected a journey exit event")
                    return
                }
                expect(exit.properties?["reason"] as? String).to(equal("dismissed"))
                expect(exit.properties?["dismissed_by"] as? String).to(equal("host"))
                let journeyUpdate = try await waitForHostJourneyUpdate(in: updates)
                expect(journeyUpdate.exitReason).to(equal(.dismissed))
                expect(updates.values.contains(where: \.isDenied)).to(beFalse())
            }

            it("abandons an active server effect wait") { @MainActor in
                let definition = ExperienceDefinition.singleScreen(
                    routes: [
                        .init(
                            eventName: SystemEventNames.screenShown,
                            program: [
                                .object([
                                    "type": .string("connector_action"),
                                    "accountRef": .string("account-1"),
                                    "toolKey": .string("send-message"),
                                    "payload": .object([:]),
                                    "timeoutMs": .number(120_000),
                                    "onSucceeded": .array([]),
                                    "onFailed": .array([]),
                                    "onTimeout": .array([]),
                                ]),
                            ]
                        ),
                    ]
                )
                let harness = await HostJourneyHarness.make(definition: definition)
                serviceUnderTest = harness.service
                let journey = try await harness.startJourney(
                    originEventId: "effect-wait-host-dismiss"
                )
                await harness.service.handleRuntimeReady(
                    journeyId: journey.id,
                    controller: harness.controller
                )
                guard let delegate = harness.mocks.experiencePresentationService
                    .currentRuntimeDelegate else {
                    fail("expected the presentation's runtime delegate")
                    return
                }
                await delegate.experienceViewController(
                    harness.controller,
                    didChangeScreen: HostJourneyHarness.screenId
                )

                let waiting = await journey.snapshot()
                expect(waiting.status).to(equal(.paused))
                expect(waiting.executionState.pendingAction?.kind).to(equal(.waitUntil))
                guard let requestedEffect = harness.mocks.eventLog.trackedEvents.last(where: {
                    $0.name == JourneyEvents.journeyEffectRequested
                }) else {
                    fail("expected a journey effect request")
                    return
                }
                expect(requestedEffect.properties?["journey_id"] as? String)
                    .to(equal(journey.id))

                await delegate.experienceViewControllerWillRequestHostDismiss(
                    harness.controller
                )
                await delegate.experienceViewControllerDidRequestHostDismiss(
                    harness.controller
                )

                let terminal = await journey.snapshot()
                expect(terminal.status).to(equal(.completed))
                expect(terminal.exitReason).to(equal(.dismissed))
                let activeAfterDismissal = await harness.service.getActiveJourneys(
                    for: harness.distinctId
                )
                expect(activeAfterDismissal).to(beEmpty())
                expect(harness.store.loadJourney(id: journey.id)).to(beNil())

                guard let properties = requestedEffect.properties,
                      let nodeId = properties["node_id"] as? String,
                      let invocationId = properties["invocation_id"] as? String else {
                    fail("expected the active server-effect invocation identity")
                    return
                }
                await harness.service.handleEvent(NuxieEvent(
                    name: JourneyEvents.journeyEffectCompleted,
                    distinctId: harness.distinctId,
                    properties: [
                        "journey_id": journey.id,
                        "node_id": nodeId,
                        "invocation_id": invocationId,
                        "status": "ok",
                    ]
                ))

                let activeAfterEffect = await harness.service.getActiveJourneys(
                    for: harness.distinctId
                )
                expect(activeAfterEffect).to(beEmpty())
                expect(harness.journeyExitedCalls()).to(haveCount(1))
            }

            it("resolves triggerAndWait as dismissed without denial") { @MainActor in
                let triggerEvent = "host-dismiss-trigger"
                let harness = await HostJourneyHarness.make(
                    definition: .singleScreen(),
                    triggerEvent: triggerEvent
                )
                serviceUnderTest = harness.service

                let featureInfo = FeatureInfo()
                let features = FeatureService(
                    api: harness.mocks.nuxieApi,
                    identity: harness.mocks.identityService,
                    profile: harness.mocks.profileService,
                    dateProvider: harness.mocks.dateProvider,
                    featureInfo: featureInfo,
                    cacheTTL: NuxieInternalConfiguration().featureCacheTTL
                )
                let triggerService = TriggerService(
                    eventLog: harness.mocks.eventLog,
                    journeys: harness.service,
                    features: features,
                    experiencePresentation: harness.mocks.experiencePresentationService,
                    featureInfo: featureInfo,
                    triggerBroker: harness.mocks.triggerBroker,
                    sleepProvider: harness.mocks.sleepProvider,
                    dateProvider: harness.mocks.dateProvider
                )

                var overrides = harness.mocks.unitTestOverrides()
                // Keep SDK startup's committed-event subscription away from
                // the real service under test. TriggerService owns the one
                // intentional route.
                overrides.journeys = MockJourneyService()
                overrides.triggers = triggerService
                overrides.journeyStore = MockJourneyStore()
                overrides.features = features
                overrides.featureInfo = featureInfo

                let storageURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "host-dismiss-trigger-\(UUID().uuidString)",
                        isDirectory: true
                    )
                temporaryStorageURL = storageURL
                try FileManager.default.createDirectory(
                    at: storageURL,
                    withIntermediateDirectories: true
                )
                let configuration = NuxieConfiguration(apiKey: "host-dismiss-trigger")
                configuration.testingOverrides.customStoragePath = storageURL
                configuration.beforeSend = { event in
                    switch event.name {
                    case SystemEventNames.appInstalled, SystemEventNames.appUpdated,
                         SystemEventNames.appOpened, SystemEventNames.appBackgrounded:
                        return nil
                    default:
                        return event
                    }
                }
                try NuxieSDK.shared.setup(with: configuration, overrides: overrides)

                let progress = TriggerUpdateRecorder()
                let result = TriggerResultRecorder()
                Task {
                    let resolved = await NuxieSDK.shared.triggerAndWait(triggerEvent) {
                        progress.append($0)
                    }
                    result.set(resolved)
                }

                let presentation = await waitForHostPresentation(
                    in: harness.mocks.experiencePresentationService
                )
                guard let presentedJourney = presentation?.journey else {
                    fail("expected a pending journey presentation")
                    return
                }
                await NuxieSDK.shared.dismiss()

                guard let resolved = await waitForHostTriggerResult(in: result) else {
                    fail("expected triggerAndWait to resolve")
                    return
                }
                guard case .journeyCompleted(let update) = resolved else {
                    fail("expected journeyCompleted, received \(resolved)")
                    return
                }
                expect(update.journeyId).to(equal(presentedJourney.id))
                expect(update.exitReason).to(equal(.dismissed))
                expect(progress.values.contains(where: \.isDenied)).to(beFalse())
            }
        }
    }
}

private func waitForHostJourneyUpdate(
    in recorder: TriggerUpdateRecorder
) async throws -> JourneyUpdate {
    for _ in 0..<200 {
        if let update = recorder.values.compactMap(\.journeyUpdate).last {
            return update
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw HostDismissalTestError.timedOut("journey update")
}

private func waitForHostPresentation(
    in presentation: MockExperiencePresentationService
) async -> (journey: Journey, delegate: any ExperienceRuntimeDelegate)? {
    for _ in 0..<200 {
        if let journey = presentation.lastPresentedJourney,
           let delegate = presentation.currentRuntimeDelegate {
            return (journey, delegate)
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return nil
}

private func waitForHostTriggerResult(
    in recorder: TriggerResultRecorder
) async -> TriggerResult? {
    for _ in 0..<200 {
        if let result = recorder.value {
            return result
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return nil
}

private actor HostDismissalAsyncGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isWaiting: Bool { entered && !released }

    func suspend() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor HostDismissalNthCallGate {
    private let targetCall: Int
    private var callCount = 0
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(targetCall: Int) {
        self.targetCall = targetCall
    }

    var isWaiting: Bool { entered && !released }

    func suspendIfTargetCall() async {
        callCount += 1
        guard callCount == targetCall else { return }
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private func waitForHostDismissalGate(_ gate: HostDismissalAsyncGate) async throws {
    for _ in 0..<200 {
        if await gate.isWaiting { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw HostDismissalTestError.timedOut("in-flight renderer callback")
}

private func waitForHostDismissalGate(_ gate: HostDismissalNthCallGate) async throws {
    for _ in 0..<200 {
        if await gate.isWaiting { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw HostDismissalTestError.timedOut("in-flight authored callback")
}

private struct HostJourneyHarness {
    static let screenId = "screen-1"
    static let distinctId = "host-dismiss-user"
    static let experienceId = "host-dismiss-experience"
    static let versionId = "host-dismiss-version"

    let mocks: MockFactory
    let store: MockJourneyStore
    let service: JourneyService
    let controller: MockExperienceViewController
    let experience: Experience
    let distinctId: String

    static func make(
        definition: ExperienceDefinition,
        triggerEvent: String = "host-dismiss-trigger",
        reentry: ExperienceReentry = .everyTime,
        exitPolicy: ExitPolicy? = nil
    ) async -> HostJourneyHarness {
        let mocks = MockFactory.shared
        let experience = makeExperience(
            definition: definition,
            triggerEvent: triggerEvent,
            reentry: reentry,
            exitPolicy: exitPolicy
        )
        let controller = await MainActor.run {
            MockExperienceViewController(
                mockExperienceVersionId: versionId,
                mockExperience: experience
            )
        }
        let store = MockJourneyStore()
        let service = mocks.makeJourneyService(journeyStore: store)
        let reference = ExperienceReference(
            experienceId: experience.id,
            versionId: experience.versionId
        )

        mocks.identityService.setDistinctId(distinctId)
        mocks.profileService.effectiveExperienceReferences = [reference]
        mocks.profileService.activeExperienceReferences = [reference]
        mocks.experienceService.mockExperiences[experience.versionId] = experience
        mocks.experiencePresentationService.defaultMockViewController = controller

        return HostJourneyHarness(
            mocks: mocks,
            store: store,
            service: service,
            controller: controller,
            experience: experience,
            distinctId: distinctId
        )
    }

    func startJourney(originEventId: String?) async throws -> Journey {
        guard let journey = await service.startJourney(
            for: experience,
            distinctId: distinctId,
            originEventId: originEventId
        ) else {
            throw HostDismissalTestError.failedToStartJourney
        }
        return journey
    }

    func journeyExitedCalls() -> [(event: String, properties: [String: Any]?)] {
        let queued = mocks.eventLog.trackedEvents
            .filter { $0.name == JourneyEvents.journeyExited }
            .map { (event: $0.name, properties: $0.properties) }
        let captured = mocks.eventLog.routedEvents
            .filter { $0.name == JourneyEvents.journeyExited }
            .map { (event: $0.name, properties: Optional($0.properties)) }
        let direct = mocks.eventLog.trackWithResponseCalls
            .filter { $0.event == JourneyEvents.journeyExited }
            .map { (event: $0.event, properties: $0.properties) }
        return queued + captured + direct
    }

    func journeyExitedCall() -> (event: String, properties: [String: Any]?)? {
        journeyExitedCalls().last
    }

    private static func makeExperience(
        definition: ExperienceDefinition,
        triggerEvent: String,
        reentry: ExperienceReentry,
        exitPolicy: ExitPolicy?
    ) -> Experience {
        let identity = ExperienceReleaseIdentity(
            appId: "test-app",
            environment: "test",
            experienceId: experienceId,
            experienceVersionId: versionId,
            buildId: "host-dismiss-build",
            versionNumber: 1,
            publishedAt: "2026-08-23T00:00:00.000Z",
            publishedAtSeq: 1
        )
        return Experience(
            behavior: ExperienceBehaviorDefinition(
                reference: .init(
                    experienceId: experienceId,
                    versionId: versionId
                ),
                buildId: identity.buildId,
                artifactContentHash: String(repeating: "a", count: 64),
                name: "Host dismissal",
                reentry: reentry,
                publishedAt: identity.publishedAt,
                trigger: .event(.init(eventName: triggerEvent, condition: nil)),
                goal: nil,
                exitPolicy: exitPolicy,
                conversionAnchor: nil,
                timeLimitSeconds: nil,
                experienceType: nil,
                presentationStyle: .fullScreen
            ),
            journey: definition.renderShell,
            definition: definition,
            assetBaseURL: URL(string: "https://assets.nuxie.ai/")!,
            authenticatedReleaseID: .init(
                identity: identity,
                descriptorSHA256: String(repeating: "b", count: 64)
            )
        )
    }
}

private extension ExperienceDefinition {
    struct HostDismissalRoute {
        let eventName: String
        let program: [ExperienceReleaseJSONValue]
    }

    static func singleScreen(
        routes routeDefinitions: [HostDismissalRoute] = []
    ) -> ExperienceDefinition {
        var routes: [JourneyRouteKey: JourneyRoute] = [:]
        var plans: [JourneyExecutionPlan] = []

        for (index, definition) in routeDefinitions.enumerated() {
            let key = JourneyRouteKey(
                host: .screen(HostJourneyHarness.screenId),
                eventName: definition.eventName
            )
            let revision = String(repeating: index.isMultiple(of: 2) ? "c" : "d", count: 64)
            let route = JourneyRoute(
                key: key,
                revisionSHA256: revision,
                program: definition.program
            )
            let cursor = JourneyExecutionCursor(
                programPath: "/program",
                actionIndex: 0
            )
            let region = JourneyExecutionRegion(
                id: "host-dismiss-region-\(index)",
                plane: .device,
                entryCursor: cursor,
                actionPaths: definition.program.indices.map { "/program/\($0)" }
            )
            routes[key] = route
            plans.append(JourneyExecutionPlan(
                id: "host-dismiss-plan-\(index)",
                route: key,
                revisionSHA256: revision,
                startPlane: .device,
                entryRegionId: region.id,
                entryCursor: cursor,
                deviceRegions: [region],
                serverRegions: [],
                handoffEdges: []
            ))
        }

        return ExperienceDefinition(
            entryRouteEventName: "host-dismiss-trigger",
            screens: [JourneyScreen(
                id: HostJourneyHarness.screenId,
                defaultViewModelName: nil,
                defaultInstanceId: nil
            )],
            viewModelValues: [],
            routes: routes,
            executionPlans: plans,
            responseSchema: nil,
            controlsByScreen: [:]
        )
    }
}

private final class TriggerUpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TriggerUpdate] = []

    func append(_ update: TriggerUpdate) {
        lock.withLock { storage.append(update) }
    }

    var values: [TriggerUpdate] {
        lock.withLock { storage }
    }
}

private final class TriggerResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TriggerResult?

    func set(_ result: TriggerResult) {
        lock.withLock { storage = result }
    }

    var value: TriggerResult? {
        lock.withLock { storage }
    }
}

private final class HostDismissNotificationRecorder: @unchecked Sendable {
    struct Value: Sendable {
        let journeyId: String?
        let reason: String?
    }

    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ notification: Notification) {
        let value = Value(
            journeyId: notification.userInfo?["journeyId"] as? String,
            reason: notification.userInfo?["reason"] as? String
        )
        lock.withLock { storage.append(value) }
    }
}

private extension TriggerUpdate {
    var journeyUpdate: JourneyUpdate? {
        guard case .journey(let update) = self else { return nil }
        return update
    }

    var isDenied: Bool {
        switch self {
        case .decision(.deniedImmediate), .featureAccess(.denied):
            return true
        default:
            return false
        }
    }
}

private enum HostDismissalTestError: Error {
    case failedToStartJourney
    case timedOut(String)
}
