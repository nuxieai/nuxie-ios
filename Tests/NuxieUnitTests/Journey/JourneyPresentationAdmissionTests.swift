import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class JourneyPresentationAdmissionTests: JourneyTestCase {


    func testDirectRouteOwnershipSurvivesFailedSubscriberDelivery() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = replacing(try await authenticatedRenderedSnapshot(fixture), steps: [
            .init(kind: .action, id: "present", action: ["type": .string("navigate"),
                "screenId": .string("screen_welcome")], outlets: [:], outcome: nil),
            .init(kind: .action, id: "wait", action: ["type": .string("wait_until"),
                "trigger": .object(["kind": .string("event"), "eventName": .string("continue")]),
                "condition": .object(["type": .string("Truthy"),
                    "value": .object(["type": .string("Boolean"), "value": .bool(true)])]),
                "maxTimeMs": .number(10_000)],
                outlets: ["satisfied": "done", "timeout": "timed_out"], outcome: nil),
            .init(kind: .complete, id: "done", action: nil, outlets: nil, outcome: "completed"),
            .init(kind: .complete, id: "timed_out", action: nil, outlets: nil, outcome: "timed_out"),
        ], routes: [.init(host: .init(kind: .screen, screenId: "screen_welcome"),
                         eventName: "continue", entryStepId: "wait")])
        let clock = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1_000_000))
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let store = MockEventStore()
        let events = EventLog(identity: identity, dateProvider: clock, apiClient: MockNuxieApi(), store: store)
        let failReads = JourneyCompletionFlag()
        let repaired = JourneyCompletionFlag()
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
        let service = JourneyService(identity: identity, events: events, dateProvider: clock,
            sleepProvider: MockSleepProvider(), journalDirectory: directory, featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events), presenter: presenter,
            readJournalRuns: { journal in
                if failReads.isCompleted, !repaired.isCompleted { throw JourneyJournalError.invalidState }
                return try await journal.runs()
            }, pinnedReleaseAuthenticator: { _, _ in throw JourneyJournalError.invalidState },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed))
        let reservation = events.reserveCommittedAdmission { service.eventAdmissionGeneration() }
        await events.subscribeAcknowledgingCommitted(reservation: reservation) { event, generation in
            await service.handleEvent(event, admittedProfileGeneration: generation)
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
        let journal = try JourneyRunJournal(directory: directory, distinctId: "customer")
        for _ in 0..<200 {
            if try await journal.runs().first?.park != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let beforeFailure = try await journal.runs().first
        XCTAssertNotNil(beforeFailure?.park)
        failReads.finish()
        let released = await events.releaseCommittedRouting(ifGeneration: hold)
        XCTAssertFalse(released, "The event remains undelivered after the journal read fails")
        repaired.finish()
        let replayed = await events.replayPendingStableRoutes(distinctId: "customer")
        XCTAssertTrue(replayed)
        await events.drain()
        let afterReplay = try await journal.runs().first
        XCTAssertEqual(afterReplay?.park, beforeFailure?.park,
                       "Replay must still exclude the run that directly routed this publication")
        XCTAssertNil(afterReplay?.completion)
        events.track("continue")
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
            await service.handleEvent(
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
        let journal = try JourneyRunJournal(
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
        let journal = try JourneyRunJournal(
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
        let journal = try JourneyRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        for _ in 0..<100 {
            if try await journal.runs().first?.park != nil { break }
            await Task.yield()
        }

        await service.onAppDidEnterBackground()
        await service.handleEvent(NuxieEvent(
            name: "unlock",
            distinctId: "customer",
            properties: ["allowed": true],
            timestamp: eventDate.addingTimeInterval(0.001)
        ))

        let backgroundRuns = try await journal.runs()
        let backgroundRun = try XCTUnwrap(backgroundRuns.first)
        XCTAssertEqual(backgroundRun.park?.pendingEvent?.name, "unlock")
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
        await fulfillment(of: [started], timeout: 2)
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
        for _ in 0..<100 {
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
        await context.service.handleEvent(NuxieEvent(
            name: "hello",
            distinctId: "customer",
            properties: [:]
        ))
        XCTAssertTrue(context.events.routedEvents.isEmpty)

        await MainActor.run { context.presenter.available = true }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(context.events.routedEvents.isEmpty)

        await context.service.handleEvent(NuxieEvent(
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
