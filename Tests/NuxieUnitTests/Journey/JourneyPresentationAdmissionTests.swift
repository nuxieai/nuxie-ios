import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class JourneyPresentationAdmissionTests: JourneyTestCase {

    func testDeclinedPresentationKeepsItsBackoffWhileTheClockMovesUntilTheSurfaceFrees() async throws {
        let clock = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1000))
        let sleeper = MockSleepProvider()
        let context = try await makeRenderedJourneyTestContext(dateProvider: clock, sleepProvider: sleeper)
        defer { removeTemporaryDirectoryIfPresent(context.directory) }
        let trace = await MainActor.run { PresentationRetryTrace() }
        await MainActor.run {
            context.presenter.presentHandler = { _ in
                trace.attempts.append(ProcessInfo.processInfo.systemUptime)
                return trace.surfaceFree ? .shown : .declined
            }
        }
        await context.service.profileDidCommit(context.snapshot, distinctId: "customer")
        let initial = try await context.journal.runs()
        let admitted = try XCTUnwrap(initial.first)
        XCTAssertNotNil(admitted.park)
        let originalKey = await context.events.queuedJourneyRetryKeys().filter { $0.id.hasPrefix("start:") }
        XCTAssertEqual(originalKey.count, 1)
        for _ in 0..<8 {
            clock.advance(by: 10)
            await context.service.onAppBecameActive()
            await context.events.drain()
        }
        let immediate = await MainActor.run { trace.attempts }
        let retainedKey = await context.events.queuedJourneyRetryKeys().filter { $0.id.hasPrefix("start:") }
        XCTAssertEqual(retainedKey, originalKey, "Repeated declines keep their original key and position")
        for (previous, next) in zip(immediate, immediate.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next - previous, 0.99, "Deadline inspection and availability callbacks must not reset backoff")
        }
        XCTAssertTrue(sleeper.pendingSleepDurations.isEmpty, "Availability parks never arm a deadline or retry sleeper")
        for _ in 0..<400 {
            if await MainActor.run(body: { trace.attempts.count >= 2 }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let declinedCount = await MainActor.run { trace.attempts.count }
        await MainActor.run {
            trace.surfaceFree = true
            context.presenter.available = false
            context.presenter.available = true
        }
        for _ in 0..<400 {
            if await MainActor.run(body: { trace.attempts.count > declinedCount }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await context.events.drain()
        let attempts = await MainActor.run { trace.attempts }
        XCTAssertEqual(attempts.count, declinedCount + 1)
        for (previous, next) in zip(attempts, attempts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next - previous, 0.99, "One attempt per queue interval")
        }
        let runs = try await context.journal.runs()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.id, admitted.id)
        XCTAssertNil(runs.first?.park)
        XCTAssertEqual(context.events.routedEvents.filter { $0.name == JourneyEvents.journeyStarted }.count, 1)
        await context.service.shutdown()
        await context.events.close()
    }


    func testDirectRouteOwnershipSurvivesFailedSubscriberDelivery() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = replacing(try await authenticatedRenderedSnapshot(fixture), steps: [
            .init(kind: .action, id: "present", action: ["type": .string("navigate"),
                "screenId": .string("screen_welcome")], outlets: [:], outcome: nil),
            // The routed signal satisfies this first wait. The next wait
            // needs a distinct event because this branch retains the signal
            // across controls; replay exclusion is checked by native reads.
            .init(kind: .action, id: "consume_continue", action: ["type": .string("wait_until"),
                "trigger": .object(["kind": .string("event"), "eventName": .string("continue")]),
                "condition": .object(["type": .string("Truthy"),
                    "value": .object(["type": .string("Boolean"), "value": .bool(true)])]),
                "maxTimeMs": .number(10_000)],
                outlets: ["satisfied": "wait", "timeout": "timed_out"], outcome: nil),
            .init(kind: .action, id: "wait", action: ["type": .string("wait_until"),
                "trigger": .object(["kind": .string("event"), "eventName": .string("finish")]),
                "condition": .object(["type": .string("Truthy"),
                    "value": .object(["type": .string("Boolean"), "value": .bool(true)])]),
                "maxTimeMs": .number(10_000)],
                outlets: ["satisfied": "done", "timeout": "timed_out"], outcome: nil),
            .init(kind: .complete, id: "done", action: nil, outlets: nil, outcome: "completed"),
            .init(kind: .complete, id: "timed_out", action: nil, outlets: nil, outcome: "timed_out"),
        ], routes: [.init(host: .init(kind: .screen, screenId: "screen_welcome"),
                         eventName: "continue", entryStepId: "consume_continue")])
        let clock = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1_000_000))
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let store = MockEventStore()
        let events = EventLog(identity: identity, dateProvider: clock, apiClient: MockNuxieApi(), store: store)
        let failReads = JourneyCompletionFlag()
        let repaired = JourneyCompletionFlag()
        let nativeReads = JourneyBeforeSendCallRecorder()
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
        let service = JourneyService(identity: identity, events: events, dateProvider: clock,
            sleepProvider: MockSleepProvider(), journalDirectory: directory, featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events), presenter: presenter,
            readNativeValues: { values in
                nativeReads.record()
                return try await values.journeyValues()
            }, readJournalRuns: { journal in
                if failReads.isCompleted, !repaired.isCompleted { throw JourneyExecutionError.invalidState }
                return try await journal.runs()
            }, pinnedReleaseAuthenticator: { _, _ in throw JourneyExecutionError.invalidState },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed))
        let reservation = events.reserveCommittedAdmission { service.eventAdmissionGeneration() }
        await events.subscribeAcknowledgingCommitted(reservation: reservation) { event, generation in
            await service.handleStoredEvent(event, admittedProfileGeneration: generation)
        }
        await service.prepareForEvents()
        let configuration = NuxieConfiguration(apiKey: "direct-route-retry-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        configuration.beforeSend = { event in
            NuxieEvent(id: event.id, name: event.name, distinctId: event.distinctId,
                       properties: event.properties, timestamp: clock.now())
        }
        try await events.configure(configuration: configuration)
        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await events.drain()
        let presented = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presented)
        let hold = await events.deferCommittedRouting()
        let accepted = await request.onEmissionBatch(presentationBatch(request: request,
            invocationId: "direct-route-followed-by-wait", emissions: [.init(
                id: "00000000-0000-7000-8000-000000000437", sequence: 0,
                occurredAt: "1970-01-12T13:46:40Z", name: "continue", payload: [:])]), nil)
        XCTAssertTrue(accepted)
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        for _ in 0..<200 {
            if try await journal.runs().first?.park != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let beforeFailure = try await journal.runs().first
        XCTAssertNotNil(beforeFailure?.park)
        XCTAssertEqual(beforeFailure?.stepId, "wait")
        XCTAssertGreaterThan(nativeReads.callCount, 0, "The owning run uses the native evaluation seam")
        failReads.finish()
        let released = await events.releaseCommittedRouting(ifGeneration: hold)
        XCTAssertFalse(released, "The event remains undelivered after the journal read fails")
        repaired.finish()
        let readsBeforeReplay = nativeReads.callCount
        let replayed = await events.replayPendingStableRoutes(distinctId: "customer")
        XCTAssertTrue(replayed)
        await events.drain()
        let afterReplay = try await journal.runs().first
        XCTAssertEqual(afterReplay?.park, beforeFailure?.park,
                       "Replay must still exclude the run that directly routed this publication")

        XCTAssertEqual(nativeReads.callCount, readsBeforeReplay,
                       "The publication's owning run must be excluded from replay evaluation")
        events.track("finish")
        // The refused publication keeps its place on the queue's timer, so
        // the later event follows it once its retry is delivered.
        for _ in 0..<400 where !store.storedEvents.contains(where: { $0.name == JourneyEvents.journeyCompleted }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await events.drain()
        let completion = store.storedEvents.last { $0.name == JourneyEvents.journeyCompleted }
        XCTAssertEqual(completion?.getPropertiesDict()["outcome"] as? String, "completed",
                       "A later independent event can satisfy the wait")
        await service.shutdown()
        await events.close()
    }

    func testDirectScreenRouteWinsItsCommittedSubscriberRace() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = replacing(
            base,
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
                    id: "wait",
                    action: [
                        "type": .string("wait_until"),
                        "trigger": .object([
                            "kind": .string("event"),
                            "eventName": .string("finish"),
                        ]),
                        "condition": .object([
                            "type": .string("Truthy"),
                            "value": .object([
                                "type": .string("Boolean"),
                                "value": .bool(true),
                            ]),
                        ]),
                        "maxTimeMs": .number(10_000),
                    ],
                    outlets: [
                        "satisfied": "subscriber_done",
                        "timeout": "timed_out",
                    ],
                    outcome: nil
                ),
                .init(
                    kind: .complete,
                    id: "subscriber_done",
                    action: nil,
                    outlets: nil,
                    outcome: "subscriber_resumed"
                ),
                .init(
                    kind: .complete,
                    id: "routed_done",
                    action: nil,
                    outlets: nil,
                    outcome: "screen_routed"
                ),
                .init(
                    kind: .complete,
                    id: "timed_out",
                    action: nil,
                    outlets: nil,
                    outcome: "timed_out"
                ),
            ],
            routes: [
                .init(
                    host: .init(kind: .screen, screenId: "screen_welcome"),
                    eventName: "continue",
                    entryStepId: "wait"
                ),
                .init(
                    host: .init(kind: .screen, screenId: "screen_welcome"),
                    eventName: "finish",
                    entryStepId: "routed_done"
                ),
            ],
            screens: [.init(
                id: "screen_welcome",
                defaultViewModelName: "WelcomeModel",
                defaultInstanceId: "welcome",
                responseCaptures: []
            )]
        )
        let eventDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-29T12:00:00Z")
        )
        let dateProvider = MockDateProvider(initialDate: eventDate)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: dateProvider,
            presenter: presenter
        )
        let admission = events.reserveCommittedAdmission {
            service.eventAdmissionGeneration()
        }
        await events.subscribeCommitted(
            where: nil,
            reservation: admission
        ) { event, generation in
            await service.handleStoredEvent(
                event,
                admittedProfileGeneration: generation
            )
        }

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let waitAccepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "enter-event-wait",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000435",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00Z",
                name: "continue",
                payload: [:]
            )]
        ), nil)
        XCTAssertTrue(waitAccepted)
        let journal = try await CustomerJourneyStore(
            directory: directory,
            distinctId: "customer"
        )
        for _ in 0..<100 {
            if try await journal.runs().first?.park != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let parkedRuns = try await journal.runs()
        let parked = try XCTUnwrap(parkedRuns.first)
        XCTAssertEqual(parked.stepId, "wait")
        XCTAssertNotNil(parked.park)

        let completionCommitted = expectation(
            description: "direct screen route completed"
        )
        events.addEventHandler(pattern: JourneyEvents.journeyCompleted) { _ in
            completionCommitted.fulfill()
        }
        let routeAccepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            batchSequence: 1,
            previousCommittedBatchSequence: 0,
            invocationId: "route-before-subscriber",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000436",
                sequence: 1,
                occurredAt: "2026-08-29T12:00:00.001Z",
                name: "finish",
                payload: [:]
            )]
        ), nil)
        XCTAssertTrue(routeAccepted)
        await fulfillment(of: [completionCommitted], timeout: 2)

        let completion = try XCTUnwrap(events.routedEvents.last {
            $0.name == JourneyEvents.journeyCompleted
        })
        XCTAssertEqual(
            completion.properties["outcome"] as? String,
            "screen_routed"
        )
    }



    func testForegroundProfileCommitDefersDuePresentedRunUntilBecameActive() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = replacing(
            base,
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
                    id: "delay",
                    action: [
                        "type": .string("delay"),
                        "durationMs": .number(1_000),
                    ],
                    outlets: ["next": "show_details"],
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
                entryStepId: "delay"
            )],
            screens: [
                .init(
                    id: "screen_welcome",
                    defaultViewModelName: "WelcomeModel",
                    defaultInstanceId: "welcome",
                    responseCaptures: []
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
        let dateProvider = MockDateProvider()
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: dateProvider,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let accepted = await request.onEmissionBatch(ScreenEmissionBatch(
            journeyId: request.owner.journeyId,
            executionOwnershipEpoch: 0,
            lifecycleGeneration: 0,
            presentationEpoch: 1,
            batchSequence: 0,
            previousCommittedBatchSequence: nil,
            invocationId: "park-invocation",
            source: .init(
                screenId: "screen_welcome",
                actionId: "continue",
                componentId: nil,
                instanceId: nil
            ),
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000303",
                sequence: 0,
                occurredAt: "2001-09-09T01:46:40Z",
                name: "continue",
                payload: [:]
            )]
        ), nil)
        XCTAssertTrue(accepted)
        let journal = try await CustomerJourneyStore(
            directory: directory,
            distinctId: "customer"
        )
        for _ in 0..<100 {
            if try await journal.runs().first?.park != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let parkedRun = try await journal.runs().first
        XCTAssertNotNil(parkedRun?.park)

        await service.onAppDidEnterBackground()
        await service.onAppWillEnterForeground()
        dateProvider.advance(by: 2)
        await service.profileDidCommit(snapshot, distinctId: "customer")

        let navigationBeforeActive = await MainActor.run {
            presenter.navigationScreenIds
        }
        XCTAssertEqual(navigationBeforeActive, ["screen_welcome"])

        await service.onAppBecameActive()

        // The deadline gated in the background keeps its queue entry; the
        // queue's timer, not the foreground callback, makes the next attempt.
        for _ in 0..<400 {
            let count = await MainActor.run { presenter.navigationScreenIds.count }
            if count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let navigationScreenIds = await MainActor.run {
            presenter.navigationScreenIds
        }
        XCTAssertEqual(navigationScreenIds, ["screen_welcome", "screen_details"])
        let presentationCount = await MainActor.run {
            presenter.presentationRequests.count
        }
        XCTAssertEqual(presentationCount, 1)
    }

    func testBackgroundEventKeepsRenderedWaitParkedUntilForeground() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = replacing(
            try await authenticatedRenderedSnapshot(fixture),
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
                    id: "wait",
                    action: [
                        "type": .string("wait_until"),
                        "trigger": .object([
                            "kind": .string("event"),
                            "eventName": .string("unlock"),
                        ]),
                        "condition": .object([
                            "type": .string("Truthy"),
                            "value": .object([
                                "type": .string("Event.Field"),
                                "key": .string("allowed"),
                            ]),
                        ]),
                        "maxTimeMs": .number(10_000),
                    ],
                    outlets: [
                        "satisfied": "show_details",
                        "timeout": "timed_out",
                    ],
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
                .init(
                    kind: .complete,
                    id: "timed_out",
                    action: nil,
                    outlets: nil,
                    outcome: "timed_out"
                ),
            ],
            routes: [.init(
                host: .init(kind: .screen, screenId: "screen_welcome"),
                eventName: "continue",
                entryStepId: "wait"
            )],
            screens: [
                .init(
                    id: "screen_welcome",
                    defaultViewModelName: "WelcomeModel",
                    defaultInstanceId: "welcome",
                    responseCaptures: []
                ),
                .init(
                    id: "screen_details",
                    defaultViewModelName: "DetailsModel",
                    defaultInstanceId: "details",
                    responseCaptures: []
                ),
            ]
        )
        let eventDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-29T12:00:00Z")
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let dateProvider = MockDateProvider(initialDate: eventDate)
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: dateProvider,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let enteredWait = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "enter-background-wait",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000501",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00Z",
                name: "continue",
                payload: [:]
            )]
        ), nil)
        XCTAssertTrue(enteredWait)
        let journal = try await CustomerJourneyStore(
            directory: directory,
            distinctId: "customer"
        )
        for _ in 0..<100 {
            if try await journal.runs().first?.park != nil { break }
            await Task.yield()
        }

        await service.onAppDidEnterBackground()
        await service.handleStoredEvent(NuxieEvent(
            name: "unlock",
            distinctId: "customer",
            properties: ["allowed": true],
            timestamp: eventDate.addingTimeInterval(0.001)
        ))

        let backgroundRuns = try await journal.runs()
        let backgroundRun = try XCTUnwrap(backgroundRuns.first)
        let retainedInput = try await journal.loggedInput(named: "unlock")
            XCTAssertEqual(retainedInput?.name, "unlock")
        let backgroundNavigation = await MainActor.run {
            presenter.navigationScreenIds
        }
        XCTAssertEqual(backgroundNavigation, ["screen_welcome"])

        await service.onAppWillEnterForeground()
        await service.onAppBecameActive()

        let foregroundNavigation = await MainActor.run {
            presenter.navigationScreenIds
        }
        XCTAssertEqual(
            foregroundNavigation,
            ["screen_welcome", "screen_details"]
        )
        let foregroundRuns = try await journal.runs()
        let foregroundRun = try XCTUnwrap(foregroundRuns.first)
        XCTAssertNil(foregroundRun.park)
        XCTAssertEqual(foregroundRun.stepId, "show_details")
    }

    func testBusyPresentationLeavesRenderedArmUnconsumedForRevalidation() async throws {
        let context = try await makeRenderedJourneyTestContext(
            presenterAvailable: false
        )
        defer { removeTemporaryDirectoryIfPresent(context.directory) }

        await context.service.profileDidCommit(
            context.snapshot,
            distinctId: "customer"
        )

        XCTAssertTrue(context.events.routedEvents.isEmpty)
        let declinedRuns = try await context.journal.runs()
        XCTAssertTrue(declinedRuns.isEmpty)

        let started = expectation(description: "state arm retried when capacity opened")
        context.events.addEventHandler(
            pattern: JourneyEvents.journeyStarted
        ) { _ in
            started.fulfill()
        }
        await MainActor.run { context.presenter.available = true }
        await fulfillment(of: [started], timeout: 5)
        for _ in 0..<100 {
            let presented = await MainActor.run {
                context.presenter.request != nil
            }
            if presented { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(context.events.routedEvents.map(\.name), [
            JourneyEvents.journeyStarted,
        ])
        let request = await MainActor.run { context.presenter.request }
        XCTAssertEqual(request?.screenId, "screen_welcome")
    }

    func testBackgroundedPresentationAttemptKeepsItsAdmittedArmForForegroundRetry() async throws {
        let context = try await makeRenderedJourneyTestContext()
        defer { removeTemporaryDirectoryIfPresent(context.directory) }
        let presentationGate = JourneyScreenCommitGate()
        await MainActor.run {
            context.presenter.presentHandler = { _ in
                await presentationGate.suspend()
                return .declined
            }
        }

        let publication = Task {
            await context.service.profileDidCommit(
                context.snapshot,
                distinctId: "customer"
            )
        }
        await presentationGate.waitUntilEntered()
        await context.service.onAppDidEnterBackground()
        await presentationGate.release()
        await publication.value

        let backgroundRuns = try await context.journal.runs()
        let backgroundRun = try XCTUnwrap(backgroundRuns.first)
        XCTAssertEqual(backgroundRun.stepId, "present")
        XCTAssertNotNil(backgroundRun.park)
        XCTAssertNotNil(backgroundRun.effectReceipts["present"])
        XCTAssertEqual(context.events.routedEvents.map(\.name), [
            JourneyEvents.journeyStarted,
        ])

        await MainActor.run {
            context.presenter.presentHandler = nil
            context.presenter.result = .shown
        }
        await context.service.onAppWillEnterForeground()
        await context.service.onAppBecameActive()
        for _ in 0..<400 {
            let attempts = await MainActor.run {
                context.presenter.presentationRequests.count
            }
            if attempts == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let foregroundRuns = try await context.journal.runs()
        let foregroundRun = try XCTUnwrap(foregroundRuns.first)
        XCTAssertNil(foregroundRun.park)
        XCTAssertEqual(
            foregroundRun.effectReceipts["present"],
            backgroundRun.effectReceipts["present"]
        )
        let presentationRequests = await MainActor.run {
            context.presenter.presentationRequests
        }
        XCTAssertEqual(presentationRequests.count, 2)
        XCTAssertEqual(context.events.routedEvents.map(\.name), [
            JourneyEvents.journeyStarted,
        ])
    }

    func testDeclinedEventArmWaitsForTheNextMatchingEventWithoutQueuing() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let eventEntry = JourneyEntryCondition(
            type: .event,
            eventName: "hello",
            segmentId: nil,
            member: nil,
            condition: nil
        )
        let snapshot = replacing(
            try await authenticatedRenderedSnapshot(fixture),
            entry: eventEntry
        )
        let context = try await makeRenderedJourneyTestContext(
            snapshot: snapshot,
            presenterAvailable: false
        )
        defer { removeTemporaryDirectoryIfPresent(context.directory) }

        await context.service.profileDidCommit(
            context.snapshot,
            distinctId: "customer"
        )
        await context.service.handleStoredEvent(NuxieEvent(
            name: "hello",
            distinctId: "customer",
            properties: [:]
        ))
        XCTAssertTrue(context.events.routedEvents.isEmpty)

        await MainActor.run { context.presenter.available = true }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(context.events.routedEvents.isEmpty)

        await context.service.handleStoredEvent(NuxieEvent(
            name: "hello",
            distinctId: "customer",
            properties: [:]
        ))

        XCTAssertEqual(context.events.routedEvents.map(\.name), [
            JourneyEvents.journeyStarted,
        ])
        let request = await MainActor.run { context.presenter.request }
        XCTAssertEqual(request?.screenId, "screen_welcome")
    }
}

@MainActor
private final class PresentationRetryTrace {
    var attempts: [TimeInterval] = []
    var surfaceFree = false
}
