import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class JourneyExperimentPresentationTests: JourneyTestCase {
    func testExperimentExposureWaitsForTheSelectedVariantToBeShown() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseExperimentExposureWaitsForTheSelectedVariantToBeShown() }
    }

    private func exerciseExperimentExposureWaitsForTheSelectedVariantToBeShown() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "variant_b", isHoldout: true)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let gate = JourneyScreenCommitGate()
        addBoundedJourneyTeardown { await gate.release() }
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
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

        let journal = try await CustomerJourneyStore(
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
        XCTAssertNil(selectedExposure.shownAt)
        XCTAssertTrue(events.routedEvents.allSatisfy {
            $0.name != JourneyEvents.experimentExposure
        })

        await gate.release()
        try await withBoundedJourneyWait(timeout: 5) { await profileCommit.value }

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
        // Exposure metadata comes from the authenticated variant definition,
        // not the untrusted assignment hint supplied above.
        XCTAssertEqual(exposures.first?.properties["is_holdout"] as? Bool, false)
        let shownRuns = try await journal.runs()
        let shownRun = try XCTUnwrap(shownRuns.first)
        let shownExposure = try XCTUnwrap(shownRun.experimentExposures.first)
        XCTAssertNotNil(shownExposure.shownAt)
        XCTAssertNotNil(shownExposure.shownAt)
        XCTAssertEqual(exposures.first?.id, shownExposure.eventId)

        XCTAssertEqual(events.routedEvents.filter {
            $0.name == JourneyEvents.experimentExposure
        }.count, 1)
    }

    func testVisibleExposureRetriesWhenItsFirstJournalWriteFails() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseVisibleExposureRetriesWhenItsFirstJournalWriteFails() }
    }

    private func exerciseVisibleExposureRetriesWhenItsFirstJournalWriteFails() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(
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
            let value = RecordingJourneyPresenter()
            value.automaticallyRevealsShownPresentation = false
            return value
        }
        let persistenceFailures = JourneyJournalPersistenceFailures()
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
        let journal = try await CustomerJourneyStore(
            directory: directory,
            distinctId: "customer"
        )
        let persistedRuns = try await journal.runs()
        let persistedExposure = try XCTUnwrap(
            persistedRuns.first?.experimentExposures.first
        )
        XCTAssertNotNil(persistedExposure.shownAt)
        XCTAssertEqual(exposures.first?.id, persistedExposure.eventId)
        await service.shutdown()
    }

    func testShutdownJoinsAnInFlightExperimentExposureRetry() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseShutdownJoinsAnInFlightExperimentExposureRetry() }
    }

    private func exerciseShutdownJoinsAnInFlightExperimentExposureRetry() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "variant_b", isHoldout: false)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let captureGate = JourneyNthRoutedCaptureGate(
            eventName: JourneyEvents.experimentExposure,
            suspendedCall: 2
        )
        addBoundedJourneyTeardown { await captureGate.release() }
        events.routedCaptureHandler = { event, _ in
            await captureGate.intercept(event: event)
        }
        let presenter = await MainActor.run {
            let value = RecordingJourneyPresenter()
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

        let started = JourneyCompletionFlag()
        let completion = JourneyCompletionFlag()
        let shutdown = Task {
            started.finish()
            await service.shutdown()
            completion.finish()
        }
        for _ in 0..<100 where !started.isCompleted {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(started.isCompleted)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(completion.isCompleted)

        await captureGate.release()
        try await withBoundedJourneyWait(timeout: 5) { await shutdown.value }
        XCTAssertTrue(completion.isCompleted)
    }

    func testExperimentExposureIsReportedForSameScreenAlreadyActiveNavigation() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseExperimentExposureIsReportedForSameScreenAlreadyActiveNavigation() }
    }

    private func exerciseExperimentExposureIsReportedForSameScreenAlreadyActiveNavigation() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
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
            let value = RecordingJourneyPresenter()
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
        ), nil)

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
        let journal = try await CustomerJourneyStore(
            directory: directory,
            distinctId: "customer"
        )
        var exposureWasShown = false
        for _ in 0..<100 {
            let runs = try await journal.runs()
            exposureWasShown = runs.first?.experimentExposures.first?.shownAt != nil
            if exposureWasShown { break }
            await Task.yield()
        }
        XCTAssertTrue(exposureWasShown)
        let navigationScreenIds = await MainActor.run {
            presenter.navigationScreenIds
        }
        XCTAssertEqual(navigationScreenIds, ["screen_welcome", "screen_welcome"])
        await service.shutdown()
    }

    func testNavigatedExperimentExposureWaitsForTheVisibleScreenCallback() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseNavigatedExperimentExposureWaitsForTheVisibleScreenCallback() }
    }

    private func exerciseNavigatedExperimentExposureWaitsForTheVisibleScreenCallback() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedVisibleExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "variant_b", isHoldout: false)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run {
            let value = RecordingJourneyPresenter()
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
        ), nil)

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
        let journal = try await CustomerJourneyStore(
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
        try await withBoundedJourneyWait { [self] in try await exerciseUnfetchedExperimentReportsFallbackOnlyAfterDefaultVariantIsShown() }
    }

    private func exerciseUnfetchedExperimentReportsFallbackOnlyAfterDefaultVariantIsShown() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: nil
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run {
            let value = RecordingJourneyPresenter()
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

        XCTAssertTrue(events.routedEvents.allSatisfy {
            $0.name != JourneyEvents.experimentExposure
        })
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        await request.onPresentationRevealed("screen_welcome")
        let fallback = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.experimentExposure
        })
        XCTAssertEqual(fallback.properties["variant_key"] as? String, "variant_a")
        XCTAssertEqual(
            fallback.properties["assignment_source"] as? String,
            "fallback"
        )
        XCTAssertEqual(fallback.properties["is_holdout"] as? Bool, false)
    }

    func testHoldoutExposureTakesItsHoldoutFlagFromTheRelease() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseHoldoutExposureTakesItsHoldoutFlagFromTheRelease() }
    }

    private func exerciseHoldoutExposureTakesItsHoldoutFlagFromTheRelease() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "variant_b", isHoldout: false),
            holdoutVariantIds: ["variant_b"]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run {
            let value = RecordingJourneyPresenter()
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
        await request.onPresentationRevealed("screen_welcome")

        let holdout = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.experimentExposure
        })
        XCTAssertEqual(holdout.properties["variant_key"] as? String, "variant_b")
        XCTAssertEqual(
            holdout.properties["assignment_source"] as? String,
            "profile"
        )
        // Holdout truth comes from the authenticated variant definition, not
        // the assignment hint, which says otherwise here.
        XCTAssertEqual(holdout.properties["is_holdout"] as? Bool, true)
    }

    func testFallbackExposureReportsItsVariantsHoldoutFlag() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseFallbackExposureReportsItsVariantsHoldoutFlag() }
    }

    private func exerciseFallbackExposureReportsItsVariantsHoldoutFlag() async throws {
        // Publishing never signs a holdout fallback, but the executor runs
        // one (fixtures/journeys/planes/executor-controls.json): the exposure
        // reports the holdout path the person actually took.
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: nil,
            holdoutVariantIds: ["variant_a"]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run {
            let value = RecordingJourneyPresenter()
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
        await request.onPresentationRevealed("screen_welcome")

        let fallback = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.experimentExposure
        })
        XCTAssertEqual(fallback.properties["variant_key"] as? String, "variant_a")
        XCTAssertEqual(
            fallback.properties["assignment_source"] as? String,
            "fallback"
        )
        XCTAssertEqual(fallback.properties["is_holdout"] as? Bool, true)
    }

    func testDeclinedPresentationDoesNotReportExperimentExposure() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseDeclinedPresentationDoesNotReportExperimentExposure() }
    }

    private func exerciseDeclinedPresentationDoesNotReportExperimentExposure() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "variant_b", isHoldout: false)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
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
        })
    }

    func testUnhandledHostDismissalCompletesTheRenderedLeg() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseUnhandledHostDismissalCompletesTheRenderedLeg() }
    }

    private func exerciseUnhandledHostDismissalCompletesTheRenderedLeg() async throws {
        let harness = try await makeRenderedJourneyHarness()
        defer { removeTemporaryDirectoryIfPresent(harness.directory) }

        let accepted = await harness.request.onOutcome(
            .dismissed,
            harness.request.screenId
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(harness.events.routedEvents.map(\.name), [
            JourneyEvents.journeyStarted,
            JourneyEvents.journeyCompleted,
        ])
        XCTAssertEqual(
            harness.events.routedEvents.last?.properties["outcome"] as? String,
            "host_dismissed"
        )
        let remainingRuns = try await harness.journal.runs()
        XCTAssertTrue(remainingRuns.isEmpty)
    }

    func testHostDismissalRetryFlushesAnAlreadyDurableCompletion() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseHostDismissalRetryFlushesAnAlreadyDurableCompletion() }
    }

    private func exerciseHostDismissalRetryFlushesAnAlreadyDurableCompletion() async throws {
        let harness = try await makeRenderedJourneyHarness()
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
            JourneyEvents.journeyStarted,
            JourneyEvents.journeyCompleted,
        ])
        XCTAssertEqual(
            harness.events.routedEvents.last?.properties["outcome"] as? String,
            "host_dismissed"
        )
    }

    func testHandledHostDismissalClearsContextBeforeUnsupportedContinuationAbandons() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseHandledHostDismissalClearsContextBeforeUnsupportedContinuationAbandons() }
    }

    private func exerciseHandledHostDismissalClearsContextBeforeUnsupportedContinuationAbandons() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let eventField: [String: JourneyReleaseJSONValue] = [
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
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
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
        let journal = try await CustomerJourneyStore(
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
        try await withBoundedJourneyWait { [self] in try await exerciseIdentityClearShutsDownTheRenderedLegSurface() }
    }

    private func exerciseIdentityClearShutsDownTheRenderedLegSurface() async throws {
        let context = try await makeRenderedJourneyTestContext()
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
