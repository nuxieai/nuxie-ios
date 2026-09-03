import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class DeviceLegRendererPublicationTests: DeviceLegTestCase {
    func testRenderedArmPresentsItsAuthenticatedScreenWithoutParking() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        let request = await MainActor.run { presenter.request }
        XCTAssertEqual(request?.screenId, "screen_welcome")
        XCTAssertEqual(request?.owner.distinctId, "customer")
        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
        ])
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let activeRuns = try await journal.runs()
        let run = try XCTUnwrap(activeRuns.first)
        XCTAssertNil(run.park)
        XCTAssertNil(run.completion)
    }

    func testRenderedEmissionCommitsBeforeCompletionAndFinishesItsOwnedSurface() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let completionCommitted = expectation(description: "completion committed")
        let presentationFinished = expectation(description: "presentation finished")
        events.addEventHandler(pattern: JourneyEvents.journeyLegCompleted) { _ in
            completionCommitted.fulfill()
        }
        await MainActor.run {
            presenter.onFinish = { presentationFinished.fulfill() }
        }
        let accepted = await request.onEmissionBatch(ScreenEmissionBatch(
            journeyId: request.owner.journeyId,
            executionOwnershipEpoch: 0,
            lifecycleGeneration: 0,
            presentationEpoch: 1,
            batchSequence: 0,
            previousCommittedBatchSequence: nil,
            invocationId: "continue-invocation",
            source: .init(
                screenId: request.screenId,
                actionId: "continue",
                componentId: nil,
                instanceId: nil
            ),
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000301",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00.123Z",
                name: "continue",
                payload: ["source": .string("button")]
            )]
        ))

        XCTAssertTrue(accepted)
        await fulfillment(
            of: [completionCommitted, presentationFinished],
            timeout: 2
        )
        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
            "continue",
            JourneyEvents.journeyLegCompleted,
        ])
        let emitted = try XCTUnwrap(events.routedEvents.first { $0.name == "continue" })
        XCTAssertEqual(emitted.properties["source"] as? String, "button")
        XCTAssertEqual(emitted.properties["screen_id"] as? String, "screen_welcome")
        XCTAssertEqual(emitted.properties["journey_id"] as? String, request.owner.journeyId)
        let finished = await MainActor.run { presenter.finishedOwners }
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?.journeyId, request.owner.journeyId)
        XCTAssertEqual(finished.first?.ownerDistinctId, "customer")
    }

    func testRenderedEmissionBatchPublishesAllEventsOrNoneBeforeRetry() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = replacing(
            base,
            inputs: .init(
                eventFields: [],
                responseFields: [[
                    "key": .string("plan"),
                    "type": .string("string"),
                    "required": .bool(false),
                ]]
            ),
            screens: [.init(
                id: "screen_welcome",
                defaultViewModelName: "WelcomeModel",
                defaultInstanceId: "welcome",
                responseCaptures: ["plan"]
            )]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let initialRuns = try await journal.runs()
        let initialStep = try XCTUnwrap(initialRuns.first?.stepId)
        let batch = ScreenEmissionBatch(
            journeyId: request.owner.journeyId,
            executionOwnershipEpoch: 0,
            lifecycleGeneration: 0,
            presentationEpoch: 1,
            batchSequence: 0,
            previousCommittedBatchSequence: nil,
            invocationId: "atomic-invocation",
            source: .init(
                screenId: request.screenId,
                actionId: "continue",
                componentId: nil,
                instanceId: nil
            ),
            emissions: [
                .init(
                    id: "00000000-0000-7000-8000-000000000320",
                    sequence: 0,
                    occurredAt: "2026-08-29T12:00:00.122Z",
                    name: SystemEventNames.responseSet,
                    payload: [
                        "field": .string("plan"),
                        "value": .string("yearly"),
                    ]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000321",
                    sequence: 1,
                    occurredAt: "2026-08-29T12:00:00.123Z",
                    name: "button_tapped",
                    payload: ["source": .string("primary")]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000322",
                    sequence: 2,
                    occurredAt: "2026-08-29T12:00:00.124Z",
                    name: "continue",
                    payload: ["source": .string("primary")]
                ),
            ]
        )

        events.stableCaptureBatchFailureIndex = 1
        let firstAccepted = await request.onEmissionBatch(batch)
        XCTAssertFalse(firstAccepted)
        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
        ])
        let runsAfterFailure = try await journal.runs()
        let runAfterFailure = try XCTUnwrap(runsAfterFailure.first)
        XCTAssertEqual(runAfterFailure.stepId, initialStep)
        guard case .string(let stagedResponse)? =
            runAfterFailure.context.responses["plan"] else {
            return XCTFail("Expected the response to be staged before event publication")
        }
        XCTAssertEqual(stagedResponse, "yearly")
        XCTAssertEqual(
            runAfterFailure.pendingPresentationPublication?.invocationId,
            batch.invocationId
        )

        events.stableCaptureBatchFailureIndex = nil
        let completionCommitted = expectation(description: "completion committed")
        events.addEventHandler(pattern: JourneyEvents.journeyLegCompleted) { _ in
            completionCommitted.fulfill()
        }
        let retryAccepted = await request.onEmissionBatch(batch)
        XCTAssertTrue(retryAccepted)
        await fulfillment(of: [completionCommitted], timeout: 2)
        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
            "button_tapped",
            "continue",
            JourneyEvents.journeyLegCompleted,
        ])
    }

    func testPendingRendererPublicationReplaysItsRouteAfterRestart() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let responseField: [String: ExperienceReleaseJSONValue] = [
            "key": .string("plan"),
            "type": .string("text"),
            "required": .bool(false),
        ]
        let snapshot = replacing(
            base,
            inputs: .init(
                eventFields: [],
                responseFields: [responseField]
            ),
            completionOutputs: [
                "continue": .init(
                    eventFields: [],
                    responseFields: [responseField]
                ),
            ],
            screens: [.init(
                id: "screen_welcome",
                defaultViewModelName: "WelcomeModel",
                defaultInstanceId: "welcome",
                responseCaptures: ["plan"]
            )]
        )
        let retainedRelease = try XCTUnwrap(
            snapshot.releasesByDigest.values.first
        )
        do {
            let identity = MockIdentityService()
            identity.setDistinctId("customer")
            let events = MockEventLog()
            events.identity = identity
            let presenter = await MainActor.run {
                RecordingDeviceLegPresenter()
            }
            let service = makeService(
                identity: identity,
                events: events,
                directory: directory,
                presenter: presenter
            )

            await service.initialize()
            await service.profileDidCommit(snapshot, distinctId: "customer")
            let presentedRequest = await MainActor.run { presenter.request }
            let request = try XCTUnwrap(presentedRequest)
            events.stableCaptureBatchFailureIndex = 0

            let accepted = await request.onEmissionBatch(presentationBatch(
                request: request,
                invocationId: "restart-publication",
                emissions: [
                    .init(
                        id: "00000000-0000-7000-8000-000000000337",
                        sequence: 0,
                        occurredAt: "2026-08-29T12:00:00.120Z",
                        name: SystemEventNames.responseSet,
                        payload: [
                            "field": .string("plan"),
                            "value": .string("yearly"),
                        ]
                    ),
                    .init(
                        id: "00000000-0000-7000-8000-000000000338",
                        sequence: 1,
                        occurredAt: "2026-08-29T12:00:00.121Z",
                        name: "continue",
                        payload: [:]
                    ),
                ]
            ))

            XCTAssertFalse(accepted)
            let journal = try DeviceLegRunJournal(
                directory: directory,
                distinctId: "customer"
            )
            let persistedRuns = try await journal.runs()
            let run = try XCTUnwrap(persistedRuns.first)
            XCTAssertEqual(
                run.pendingPresentationPublication?.invocationId,
                "restart-publication"
            )
            guard case .string(let response)? =
                run.context.responses["plan"] else {
                return XCTFail("Expected the staged response to survive capture failure")
            }
            XCTAssertEqual(response, "yearly")
            XCTAssertFalse(events.routedEvents.contains {
                $0.name == "continue"
            })
        }

        let recoveryIdentity = MockIdentityService()
        recoveryIdentity.setDistinctId("customer")
        let recoveryEvents = MockEventLog()
        recoveryEvents.identity = recoveryIdentity
        let recoveryService = makeService(
            identity: recoveryIdentity,
            events: recoveryEvents,
            directory: directory,
            pinnedReleaseAuthenticator: { _, _ in retainedRelease }
        )

        await recoveryService.initialize()

        let replayed = recoveryEvents.routedEvents.filter {
            $0.name == "continue"
        }
        XCTAssertEqual(replayed.count, 1)
        XCTAssertEqual(
            replayed.first?.id,
            "00000000-0000-7000-8000-000000000338"
        )
        let completion = try XCTUnwrap(recoveryEvents.routedEvents.first {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        XCTAssertEqual(completion.properties["outcome"] as? String, "continue")
        let outputs = try XCTUnwrap(
            completion.properties["outputs"] as? [String: Any]
        )
        let responses = try XCTUnwrap(outputs["responses"] as? [String: Any])
        XCTAssertEqual(responses["plan"] as? String, "yearly")
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let remainingRuns = try await journal.runs()
        XCTAssertTrue(remainingRuns.isEmpty)
        await recoveryService.shutdown()
    }

    func testPendingResponseChangeResumesItsWaitAfterRestart() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let snapshot = renderedResponseWaitSnapshot(
            try await authenticatedRenderedSnapshot(fixture)
        )
        let retainedRelease = try XCTUnwrap(
            snapshot.releasesByDigest.values.first
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let persistenceFailures = DeviceLegJournalPersistenceFailures()
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter,
            journalBeforePersist: { try persistenceFailures.beforePersist() }
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let routedToWait = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "route-to-response-wait",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000341",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00.120Z",
                name: "continue",
                payload: [:]
            )]
        ))
        XCTAssertTrue(routedToWait)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        for _ in 0..<200 {
            let runs = try await journal.runs()
            if runs.first?.stepId == "wait", runs.first?.park != nil {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let waitingRuns = try await journal.runs()
        let waitingRun = try XCTUnwrap(waitingRuns.first)
        XCTAssertEqual(waitingRun.stepId, "wait")
        XCTAssertNotNil(waitingRun.park)

        // The response publication itself is durable, then the simulated
        // process dies before its response-change signal can clear the outbox.
        persistenceFailures.failAfterSuccessfulWrites(1)
        let responseAccepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            batchSequence: 1,
            previousCommittedBatchSequence: 0,
            invocationId: "response-before-restart",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000342",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00.121Z",
                name: SystemEventNames.responseSet,
                payload: [
                    "field": .string("consent"),
                    "value": .bool(true),
                ]
            )]
        ))
        XCTAssertFalse(responseAccepted)
        let stagedRuns = try await journal.runs()
        let staged = try XCTUnwrap(stagedRuns.first)
        XCTAssertEqual(
            staged.pendingPresentationPublication?.invocationId,
            "response-before-restart"
        )

        let recoveryIdentity = MockIdentityService()
        recoveryIdentity.setDistinctId("customer")
        let recoveryEvents = MockEventLog()
        recoveryEvents.identity = recoveryIdentity
        let recoveryService = makeService(
            identity: recoveryIdentity,
            events: recoveryEvents,
            directory: directory,
            pinnedReleaseAuthenticator: { _, _ in retainedRelease }
        )

        await recoveryService.initialize()

        let completion = try XCTUnwrap(recoveryEvents.routedEvents.first {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        XCTAssertEqual(completion.properties["outcome"] as? String, "responded")
        let outputs = try XCTUnwrap(
            completion.properties["outputs"] as? [String: Any]
        )
        let responses = try XCTUnwrap(outputs["responses"] as? [String: Any])
        XCTAssertEqual(responses["consent"] as? Bool, true)
        let remainingRuns = try await journal.runs()
        XCTAssertTrue(remainingRuns.isEmpty)
        await recoveryService.shutdown()
    }

    func testRendererBatchRemainsRejectedWhenPublicationCannotStage() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = replacing(
            base,
            inputs: .init(
                eventFields: [],
                responseFields: [[
                    "key": .string("plan"),
                    "type": .string("string"),
                    "required": .bool(false),
                ]]
            ),
            screens: [.init(
                id: "screen_welcome",
                defaultViewModelName: "WelcomeModel",
                defaultInstanceId: "welcome",
                responseCaptures: ["plan"]
            )]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let beforeSendCalls = DeviceLegBeforeSendCallRecorder()
        events.preparedTriggerBeforeSend = { event in
            if event.id == "00000000-0000-7000-8000-000000000340" {
                beforeSendCalls.record()
            }
            return event
        }
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let persistenceFailures = DeviceLegJournalPersistenceFailures()
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter,
            journalBeforePersist: { try persistenceFailures.beforePersist() }
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        // The outbox record owns the response and stable event IDs together.
        // If that write fails, the renderer keeps the batch and no event may
        // become visible.
        persistenceFailures.failNext(1)

        let batch = presentationBatch(
            request: request,
            invocationId: "response-abandonment-rejected",
            emissions: [
                .init(
                    id: "00000000-0000-7000-8000-000000000339",
                    sequence: 0,
                    occurredAt: "2026-08-29T12:00:00.120Z",
                    name: SystemEventNames.responseSet,
                    payload: [
                        "field": .string("plan"),
                        "value": .string("yearly"),
                    ]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000340",
                    sequence: 1,
                    occurredAt: "2026-08-29T12:00:00.121Z",
                    name: "button_tapped",
                    payload: [:]
                ),
            ]
        )
        let accepted = await request.onEmissionBatch(batch)

        XCTAssertFalse(accepted)
        let persistedRuns = try await journal.runs()
        let run = try XCTUnwrap(persistedRuns.first)
        XCTAssertNil(run.completion)
        XCTAssertNil(run.context.responses["plan"])
        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
        ])
        let finishedOwners = await MainActor.run { presenter.finishedOwners }
        XCTAssertTrue(finishedOwners.isEmpty)

        let retryAccepted = await request.onEmissionBatch(batch)
        XCTAssertTrue(retryAccepted)
        XCTAssertEqual(
            beforeSendCalls.callCount,
            1,
            "beforeSend must run only after the outbox owns the batch"
        )
        let runsAfterRetry = try await journal.runs()
        let persistedAfterRetry = try XCTUnwrap(runsAfterRetry.first)
        guard case .string(let response)? =
            persistedAfterRetry.context.responses["plan"] else {
            return XCTFail("Expected the retried response to be durable")
        }
        XCTAssertEqual(response, "yearly")
        XCTAssertNil(persistedAfterRetry.pendingPresentationPublication)
    }

    func testBeforeSendDroppedRenderedEventDoesNotAdvanceItsScreenRoute() async throws {
        let harness = try await makeRenderedDeviceLegHarness { event in
            event.name == "continue" ? nil : event
        }
        defer { removeTemporaryDirectoryIfPresent(harness.directory) }
        let initialRuns = try await harness.journal.runs()
        let initialRun = try XCTUnwrap(initialRuns.first)

        let accepted = await harness.request.onEmissionBatch(presentationBatch(
            request: harness.request,
            invocationId: "dropped-screen-route",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000323",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00.123Z",
                name: "continue",
                payload: [:]
            )]
        ))

        XCTAssertTrue(accepted)
        XCTAssertFalse(harness.events.routedEvents.contains {
            $0.name == "continue"
        })
        XCTAssertFalse(harness.events.routedEvents.contains {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        let currentRuns = try await harness.journal.runs()
        let currentRun = try XCTUnwrap(currentRuns.first)
        XCTAssertEqual(currentRun.stepId, initialRun.stepId)
        XCTAssertNil(currentRun.completion)
        let finishedOwners = await MainActor.run {
            harness.presenter.finishedOwners
        }
        XCTAssertTrue(finishedOwners.isEmpty)
    }

    func testBeforeSendRenameAwayFromRenderedRouteDoesNotAdvance() async throws {
        let harness = try await makeRenderedDeviceLegHarness { event in
            guard event.name == "continue" else { return event }
            return NuxieEvent(
                id: event.id,
                name: "continue_redacted",
                distinctId: event.distinctId,
                properties: event.properties,
                timestamp: event.timestamp
            )
        }
        defer { removeTemporaryDirectoryIfPresent(harness.directory) }
        let accepted = await harness.request.onEmissionBatch(presentationBatch(
            request: harness.request,
            invocationId: "renamed-away-screen-route",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000324",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00.123Z",
                name: "continue",
                payload: [:]
            )]
        ))

        XCTAssertTrue(accepted)
        XCTAssertTrue(harness.events.routedEvents.contains {
            $0.name == "continue_redacted"
        })
        XCTAssertFalse(harness.events.routedEvents.contains {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        let runs = try await harness.journal.runs()
        let run = try XCTUnwrap(runs.first)
        XCTAssertNil(run.completion)
    }

    func testBeforeSendRenameIntoRenderedRouteAdvances() async throws {
        let harness = try await makeRenderedDeviceLegHarness { event in
            guard event.name == "primary_tapped" else { return event }
            return NuxieEvent(
                id: event.id,
                name: "continue",
                distinctId: event.distinctId,
                properties: event.properties,
                timestamp: event.timestamp
            )
        }
        defer { removeTemporaryDirectoryIfPresent(harness.directory) }
        let completed = expectation(description: "renamed route completed")
        harness.events.addEventHandler(
            pattern: JourneyEvents.journeyLegCompleted
        ) { _ in
            completed.fulfill()
        }
        let accepted = await harness.request.onEmissionBatch(presentationBatch(
            request: harness.request,
            invocationId: "renamed-into-screen-route",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000325",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00.123Z",
                name: "primary_tapped",
                payload: [:]
            )]
        ))

        XCTAssertTrue(accepted)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertTrue(harness.events.routedEvents.contains {
            $0.name == "continue"
        })
    }

    func testBeforeSendRenderedPropertyRewriteDrivesRoutedControl() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let snapshot = renderedEventPropertyBranchSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            eventName: "continue"
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        events.preparedTriggerBeforeSend = { event in
            guard event.name == "continue" else { return event }
            var properties = event.properties
            properties["allow"] = true
            return NuxieEvent(
                id: event.id,
                name: event.name,
                distinctId: event.distinctId,
                properties: properties,
                timestamp: event.timestamp
            )
        }
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let completed = expectation(description: "transformed event completed")
        events.addEventHandler(pattern: JourneyEvents.journeyLegCompleted) { _ in
            completed.fulfill()
        }

        let accepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "transformed-event-properties",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000326",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00.123Z",
                name: "continue",
                payload: ["allow": .bool(false)]
            )]
        ))

        XCTAssertTrue(accepted)
        await fulfillment(of: [completed], timeout: 2)
        let routed = try XCTUnwrap(events.routedEvents.first {
            $0.name == "continue"
        })
        XCTAssertEqual(routed.properties["allow"] as? Bool, true)
        let completion = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        XCTAssertEqual(
            completion.properties["outcome"] as? String,
            "transformed"
        )
    }

    func testRenderedBatchDurablyStagesResponsesBeforePublishingAllEventsAndUsesFirstRoute() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let responseField: [String: ExperienceReleaseJSONValue] = [
            "key": .string("plan"),
            "type": .string("string"),
            "required": .bool(false),
        ]
        let snapshot = replacing(
            base,
            inputs: .init(eventFields: [], responseFields: [responseField]),
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "show_details",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_details"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
            ],
            routes: [.init(
                host: .init(kind: .screen, screenId: "screen_welcome"),
                eventName: "continue",
                entryStepId: "show_details"
            )],
            screens: [
                .init(
                    id: "screen_welcome",
                    defaultViewModelName: "WelcomeModel",
                    defaultInstanceId: "welcome",
                    responseCaptures: ["plan"]
                ),
                .init(
                    id: "screen_details",
                    defaultViewModelName: "DetailsModel",
                    defaultInstanceId: "details",
                    responseCaptures: []
                ),
            ]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let persistence = DeviceLegResponsePersistenceProbe()
        events.prepareTriggerPropertiesHandler = {
            let runs = try? await journal.runs()
            let durableResponse: String?
            if let run = runs?.first,
               case .string(let value)? = run.context.responses["plan"] {
                durableResponse = value
            } else {
                durableResponse = nil
            }
            await persistence.record(durableResponse)
        }

        let accepted = await request.onEmissionBatch(ScreenEmissionBatch(
            journeyId: request.owner.journeyId,
            executionOwnershipEpoch: 0,
            lifecycleGeneration: 0,
            presentationEpoch: 1,
            batchSequence: 0,
            previousCommittedBatchSequence: nil,
            invocationId: "response-route-invocation",
            source: .init(
                screenId: "screen_welcome",
                actionId: "continue",
                componentId: nil,
                instanceId: nil
            ),
            emissions: [
                .init(
                    id: "00000000-0000-7000-8000-000000000331",
                    sequence: 0,
                    occurredAt: "2026-08-29T12:00:00.120Z",
                    name: SystemEventNames.responseSet,
                    payload: [
                        "field": .string("plan"),
                        "value": .string("yearly"),
                    ]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000332",
                    sequence: 1,
                    occurredAt: "2026-08-29T12:00:00.121Z",
                    name: "before_route",
                    payload: [:]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000333",
                    sequence: 2,
                    occurredAt: "2026-08-29T12:00:00.122Z",
                    name: "continue",
                    payload: [:]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000334",
                    sequence: 3,
                    occurredAt: "2026-08-29T12:00:00.123Z",
                    name: "tail_event",
                    payload: [:]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000335",
                    sequence: 4,
                    occurredAt: "2026-08-29T12:00:00.124Z",
                    name: SystemEventNames.responseSet,
                    payload: [
                        "field": .string("plan"),
                        "value": .string("monthly"),
                    ]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000336",
                    sequence: 5,
                    occurredAt: "2026-08-29T12:00:00.125Z",
                    name: "continue",
                    payload: [:]
                ),
            ]
        ))
        events.prepareTriggerPropertiesHandler = nil

        XCTAssertTrue(accepted)
        let persistenceObservations = await persistence.observations()
        XCTAssertEqual(persistenceObservations, [
            "monthly",
            "monthly",
            "monthly",
            "monthly",
        ])
        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
            "before_route",
            "continue",
            "tail_event",
            "continue",
        ])
        let runs = try await journal.runs()
        let run = try XCTUnwrap(runs.first)
        guard case .string(let response)? = run.context.responses["plan"] else {
            return XCTFail("Expected the response to remain durable")
        }
        XCTAssertEqual(response, "monthly")
    }
}
