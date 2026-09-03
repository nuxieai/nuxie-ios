import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class DeviceLegExperimentPresentationTests: DeviceLegTestCase {
    func testExperimentExposureWaitsForTheSelectedVariantToBeShown() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "variant_b", isHoldout: true)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let gate = DeviceLegScreenCommitGate()
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        await MainActor.run {
            presenter.automaticallyRevealsShownPresentation = false
            presenter.presentHandler = { _ in
                await gate.suspend()
                return .shown
            }
        }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )
        await service.initialize()

        let profileCommit = Task {
            await service.profileDidCommit(snapshot, distinctId: "customer")
        }
        await gate.waitUntilEntered()

        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let selectedRuns = try await journal.runs()
        let selectedRun = try XCTUnwrap(selectedRuns.first)
        let selectedExposure = try XCTUnwrap(
            selectedRun.experimentExposures.first
        )
        XCTAssertEqual(selectedExposure.experimentId, "experiment_checkout")
        XCTAssertEqual(selectedExposure.variantId, "variant_b")
        XCTAssertEqual(selectedExposure.kind, .assigned)
        XCTAssertNil(selectedExposure.shownAt)
        XCTAssertFalse(selectedExposure.queued)
        XCTAssertTrue(events.routedEvents.allSatisfy {
            $0.name != JourneyEvents.experimentExposure
        })

        await gate.release()
        await profileCommit.value

        XCTAssertTrue(events.routedEvents.allSatisfy {
            $0.name != JourneyEvents.experimentExposure
        })
        let capturedRequest = await MainActor.run { presenter.request }
        let presentedRequest = try XCTUnwrap(capturedRequest)
        await presentedRequest.onPresentationRevealed("screen_welcome")

        let exposures = events.routedEvents.filter {
            $0.name == JourneyEvents.experimentExposure
        }
        XCTAssertEqual(exposures.count, 1)
        XCTAssertEqual(
            exposures.first?.properties["experiment_key"] as? String,
            "experiment_checkout"
        )
        XCTAssertEqual(
            exposures.first?.properties["variant_key"] as? String,
            "variant_b"
        )
        XCTAssertEqual(
            exposures.first?.properties["assignment_source"] as? String,
            "profile"
        )
        XCTAssertEqual(exposures.first?.properties["is_holdout"] as? Bool, true)
        let shownRuns = try await journal.runs()
        let shownRun = try XCTUnwrap(shownRuns.first)
        let shownExposure = try XCTUnwrap(shownRun.experimentExposures.first)
        XCTAssertNotNil(shownExposure.shownAt)
        XCTAssertTrue(shownExposure.queued)
        XCTAssertEqual(exposures.first?.id, shownExposure.eventId)

        _ = try await DeviceLegExperimentExposureReporter(
            journal: journal,
            events: events
        ).flushPending()
        XCTAssertEqual(events.routedEvents.filter {
            $0.name == JourneyEvents.experimentExposure
        }.count, 1)
    }

    func testVisibleExposureRetriesWhenItsFirstJournalWriteFails() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let snapshot = renderedExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "variant_b", isHoldout: false)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run {
            let value = RecordingDeviceLegPresenter()
            value.automaticallyRevealsShownPresentation = false
            return value
        }
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
        persistenceFailures.failNext(1)

        await request.onPresentationRevealed("screen_welcome")

        for _ in 0..<300 {
            if events.routedEvents.contains(where: {
                $0.name == JourneyEvents.experimentExposure
            }) { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let exposures = events.routedEvents.filter {
            $0.name == JourneyEvents.experimentExposure
        }
        XCTAssertEqual(exposures.count, 1)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let persistedRuns = try await journal.runs()
        let persistedExposure = try XCTUnwrap(
            persistedRuns.first?.experimentExposures.first
        )
        XCTAssertNotNil(persistedExposure.shownAt)
        XCTAssertTrue(persistedExposure.queued)
        await service.shutdown()
    }

    func testShutdownJoinsAnInFlightExperimentExposureRetry() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "variant_b", isHoldout: false)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let captureGate = DeviceLegNthRoutedCaptureGate(
            eventName: JourneyEvents.experimentExposure,
            suspendedCall: 2
        )
        events.routedCaptureHandler = { event, _ in
            await captureGate.intercept(event: event)
        }
        let presenter = await MainActor.run {
            let value = RecordingDeviceLegPresenter()
            value.automaticallyRevealsShownPresentation = false
            return value
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
        events.routedCaptureFailuresRemaining = 1
        await request.onPresentationRevealed("screen_welcome")
        for _ in 0..<200 {
            if await captureGate.isSuspended() { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let retryIsSuspended = await captureGate.isSuspended()
        XCTAssertTrue(retryIsSuspended)

        let completion = DeviceLegCompletionFlag()
        let shutdown = Task {
            await service.shutdown()
            completion.finish()
        }
        // Profile teardown makes its own flush attempt before shutdown reaches
        // the retry-task join. Wait for that attempt so this assertion cannot
        // pass merely because the shutdown task has not started yet.
        for _ in 0..<100 {
            if await captureGate.observationCount() >= 3 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let captureCount = await captureGate.observationCount()
        XCTAssertGreaterThanOrEqual(captureCount, 3)
        XCTAssertFalse(completion.isCompleted)

        await captureGate.release()
        await shutdown.value
        XCTAssertTrue(completion.isCompleted)
    }

    func testExperimentExposureIsReportedForSameScreenAlreadyActiveNavigation() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedVisibleExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "variant_b", isHoldout: false),
            targetScreenId: "screen_welcome"
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run {
            let value = RecordingDeviceLegPresenter()
            value.navigationResult = .alreadyActive
            return value
        }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        XCTAssertFalse(events.routedEvents.contains {
            $0.name == JourneyEvents.experimentExposure
        })
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let exposureCaptured = expectation(description: "selected variant exposed")
        events.addEventHandler(pattern: JourneyEvents.experimentExposure) { _ in
            exposureCaptured.fulfill()
        }

        let accepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "select-visible-experiment",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000305",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00Z",
                name: "continue",
                payload: [:]
            )]
        ))

        XCTAssertTrue(accepted)
        await fulfillment(of: [exposureCaptured], timeout: 2)
        let exposures = events.routedEvents.filter {
            $0.name == JourneyEvents.experimentExposure
        }
        XCTAssertEqual(exposures.count, 1)
        XCTAssertEqual(
            exposures.first?.properties["experiment_key"] as? String,
            "experiment_checkout"
        )
        XCTAssertEqual(
            exposures.first?.properties["variant_key"] as? String,
            "variant_b"
        )
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        var exposureWasQueued = false
        for _ in 0..<100 {
            let runs = try await journal.runs()
            exposureWasQueued = runs.first?.experimentExposures.first?.queued
                == true
            if exposureWasQueued { break }
            await Task.yield()
        }
        XCTAssertTrue(exposureWasQueued)
        let navigationScreenIds = await MainActor.run {
            presenter.navigationScreenIds
        }
        XCTAssertEqual(navigationScreenIds, ["screen_welcome", "screen_welcome"])
        await service.shutdown()
    }

    func testNavigatedExperimentExposureWaitsForTheVisibleScreenCallback() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedVisibleExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "variant_b", isHoldout: false)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run {
            let value = RecordingDeviceLegPresenter()
            value.navigationResult = .navigated
            return value
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
        let accepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "select-navigated-experiment",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000306",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00Z",
                name: "continue",
                payload: [:]
            )]
        ))

        XCTAssertTrue(accepted)
        for _ in 0..<100 {
            let navigationCount = await MainActor.run {
                presenter.navigationScreenIds.count
            }
            if navigationCount == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(events.routedEvents.contains {
            $0.name == JourneyEvents.experimentExposure
        })

        // The decision selected the destination screen. A late lifecycle
        // callback from the screen being replaced must not expose it.
        await request.onPresentationRevealed("screen_welcome")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(events.routedEvents.contains {
            $0.name == JourneyEvents.experimentExposure
        })
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let boundRuns = try await journal.runs()
        let boundExposure = try XCTUnwrap(
            boundRuns.first?.experimentExposures.first
        )
        XCTAssertEqual(boundExposure.presentationScreenId, "screen_details")
        XCTAssertNil(boundExposure.shownAt)

        // Production invokes this callback from the target screen's active
        // lifecycle boundary. Merely returning `.navigated` above must not
        // count as an impression.
        await request.onPresentationRevealed("screen_details")
        for _ in 0..<100 {
            let exposureCount = events.routedEvents.filter {
                $0.name == JourneyEvents.experimentExposure
            }.count
            if exposureCount == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let exposureCount = events.routedEvents.filter {
            $0.name == JourneyEvents.experimentExposure
        }.count
        XCTAssertEqual(exposureCount, 1)
    }

    func testUnfetchedExperimentReportsFallbackOnlyAfterDefaultVariantIsShown() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: nil
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

        XCTAssertTrue(events.routedEvents.allSatisfy {
            $0.name != JourneyEvents.experimentExposure
        })
        let fallback = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.experimentExposureFallback
        })
        XCTAssertEqual(fallback.properties["variant_key"] as? String, "variant_a")
        XCTAssertEqual(
            fallback.properties["assignment_source"] as? String,
            "no_assignment"
        )
    }

    func testUnknownAssignmentSkipsEveryVariantAndReportsTheErrorImmediately() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let snapshot = renderedExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "missing", isHoldout: false)
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

        let error = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.experimentExposureError
        })
        XCTAssertEqual(error.properties["variant_key"] as? String, "missing")
        XCTAssertEqual(error.properties["reason"] as? String, "variant_not_found")
        XCTAssertFalse(events.routedEvents.contains {
            $0.name == JourneyEvents.experimentExposure
                || $0.name == JourneyEvents.experimentExposureFallback
        })
        let presentationCount = await MainActor.run {
            presenter.presentationRequests.count
        }
        XCTAssertEqual(presentationCount, 0)
    }

    func testDeclinedPresentationDoesNotReportExperimentExposure() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "variant_b", isHoldout: false)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        await MainActor.run { presenter.result = .declined }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertTrue(events.routedEvents.allSatisfy {
            $0.name != JourneyEvents.experimentExposure
                && $0.name != JourneyEvents.experimentExposureFallback
                && $0.name != JourneyEvents.experimentExposureError
        })
    }

    func testUnhandledHostDismissalCompletesTheRenderedLeg() async throws {
        let harness = try await makeRenderedDeviceLegHarness()
        defer { removeTemporaryDirectoryIfPresent(harness.directory) }

        let accepted = await harness.request.onOutcome(
            .dismissed,
            harness.request.screenId
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(harness.events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
            JourneyEvents.journeyLegCompleted,
        ])
        XCTAssertEqual(
            harness.events.routedEvents.last?.properties["outcome"] as? String,
            "host_dismissed"
        )
        let remainingRuns = try await harness.journal.runs()
        XCTAssertTrue(remainingRuns.isEmpty)
    }

    func testHostDismissalRetryFlushesAnAlreadyDurableCompletion() async throws {
        let harness = try await makeRenderedDeviceLegHarness()
        defer { removeTemporaryDirectoryIfPresent(harness.directory) }
        let runs = try await harness.journal.runs()
        let run = try XCTUnwrap(runs.first)
        try await harness.journal.complete(
            run.id,
            outcome: "host_dismissed",
            at: Date(timeIntervalSince1970: 2)
        )

        let accepted = await harness.request.onOutcome(
            .dismissed,
            harness.request.screenId
        )

        XCTAssertTrue(accepted)
        let remainingRuns = try await harness.journal.runs()
        XCTAssertTrue(remainingRuns.isEmpty)
        XCTAssertEqual(harness.events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
            JourneyEvents.journeyLegCompleted,
        ])
        XCTAssertEqual(
            harness.events.routedEvents.last?.properties["outcome"] as? String,
            "host_dismissed"
        )
    }

    func testHandledHostDismissalClearsContextBeforeUnsupportedContinuationAbandons() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let eventField: [String: ExperienceReleaseJSONValue] = [
            "key": .string("stale"),
            "type": .string("string"),
            "required": .bool(true),
        ]
        let snapshot = replacing(
            try await authenticatedRenderedSnapshot(fixture),
            inputs: .init(eventFields: [eventField], responseFields: []),
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
                    id: "server_only",
                    action: ["type": .string("server_only")],
                    outlets: [:],
                    outcome: nil
                ),
            ],
            routes: [.init(
                host: .init(kind: .screen, screenId: "screen_welcome"),
                eventName: "host_dismissed",
                entryStepId: "server_only"
            )],
            armContext: .init(
                event: ["stale": .string("old-value")],
                responses: [:]
            )
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
        let accepted = await request.onOutcome(.dismissed, "screen_welcome")
        XCTAssertTrue(accepted)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        for _ in 0..<100 {
            if try await journal.runs().first?.stepId == "server_only" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let recordedRun = try await journal.runs().first
        let run = try XCTUnwrap(recordedRun)

        XCTAssertEqual(run.stepId, "server_only")
        XCTAssertTrue(run.context.event.dictionary.isEmpty)
        XCTAssertNil(run.park)

        await MainActor.run {
            request.onPresentationFinished()
        }
        for _ in 0..<100 {
            if try await journal.runs().isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let continuedRuns = try await journal.runs()
        XCTAssertTrue(continuedRuns.isEmpty)
        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "abandoned"
        )
    }

    func testIdentityClearShutsDownTheRenderedLegSurface() async throws {
        let context = try await makeRenderedDeviceLegTestContext()
        defer { removeTemporaryDirectoryIfPresent(context.directory) }
        await context.service.profileDidCommit(
            context.snapshot,
            distinctId: "customer"
        )

        await context.service.profileDidClear(distinctId: "customer")

        let shutdownOwners = await MainActor.run {
            context.presenter.shutdownOwners
        }
        XCTAssertEqual(shutdownOwners, ["customer"])
    }
}
