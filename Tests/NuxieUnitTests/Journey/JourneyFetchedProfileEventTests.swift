import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

/// An app event that arrives while the published setup is being fetched is
/// kept: it waits, untouched and in order, and once the copy arrives it is
/// handled whole, so it can start Experiences and no Journey takes it twice
/// (UNIV-4589).
final class JourneyFetchedProfileEventTests: JourneyTestCase {

    /// Basis's first launch: setup, then an immediate trigger, before any
    /// copy of the published setup exists on the device.
    func testFirstLaunchTriggerStartsOnceTheFirstProfileArrives() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: Self.eventEntry("onboarding_start"),
            reentry: .init(type: .everyMatch, window: nil)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let store = MockEventStore()
        let events = EventLog(identity: identity, dateProvider: MockDateProvider(),
                              apiClient: MockNuxieApi(), store: store)
        // Production starts without a journal namespace until the profile
        // transport authenticates the app.
        let service = JourneyService(
            identity: identity, events: events,
            dateProvider: MockDateProvider(), sleepProvider: MockSleepProvider(),
            journalDirectory: directory, storageScope: nil, featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            pinnedReleaseAuthenticator: { _, _ in throw JourneyJournalError.invalidState },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed)
        )
        let admission = events.reserveCommittedAdmission { service.eventAdmissionGeneration() }
        await events.subscribeAcknowledgingCommitted(reservation: admission) { event, generation in
            await service.handleEvent(event, admittedProfileGeneration: generation)
        }
        await service.prepareForEvents()
        let configuration = NuxieConfiguration(apiKey: "first-launch-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await events.configure(configuration: configuration)
        await service.initialize()

        events.track("onboarding_start")
        _ = await events.flushEvents()
        XCTAssertEqual(starts(in: store), 0, "No Journey can start before a copy exists")

        await service.profileFetchDidBegin(distinctId: "customer")
        await service.profileDidCommit(snapshot, artifacts: nil,
                                       authority: fixture.deliveryAuthority,
                                       admissionGeneration: 1, distinctId: "customer")
        await service.profileFetchDidSettle(distinctId: "customer")
        await events.drain()

        XCTAssertEqual(starts(in: store), 1)
        XCTAssertTrue(store.pendingStableRouteIds.isEmpty)
        await service.shutdown()
        await events.close()
    }

    /// The saved copy cannot be used (the language changed in the app) and a
    /// fresh one is fetched. A trigger and the event after it wait in
    /// EventLog, in order, and are handled whole once the copy arrives.
    func testEventsDuringTheFetchWaitInOrderAndRunOnceTheCopyArrives() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let freshCopy = try await waitingCopy(fixture, entry: "start_waiting")
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let store = MockEventStore()
        let events = EventLog(identity: identity, dateProvider: MockDateProvider(),
                              apiClient: MockNuxieApi(), store: store)
        // EventLog stamps tracked events with the wall clock; the Journey's
        // wait for go opens on the same clock.
        let journeys = JourneyService(
            identity: identity, events: events,
            dateProvider: MockDateProvider(initialDate: Date()), sleepProvider: MockSleepProvider(),
            journalDirectory: directory, featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            pinnedReleaseAuthenticator: { _, _ in throw JourneyJournalError.invalidState },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed)
        )
        let admission = events.reserveCommittedAdmission { journeys.eventAdmissionGeneration() }
        await events.subscribeAcknowledgingCommitted(reservation: admission) { event, generation in
            await journeys.handleEvent(event, admittedProfileGeneration: generation)
        }
        await journeys.prepareForEvents()
        let configuration = NuxieConfiguration(apiKey: "fetched-profile-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await events.configure(configuration: configuration)
        await journeys.initialize()
        await journeys.finishStartupRouting()
        await journeys.profileDidCommit(removingDeliveredReleases(from: freshCopy),
                                        distinctId: "customer")
        await journeys.profileDidWithdraw(authority: nil, distinctId: "customer")
        await journeys.profileFetchDidBegin(distinctId: "customer")

        events.track("start_waiting")
        events.track("go")
        _ = await events.flushEvents()
        XCTAssertEqual(starts(in: store), 0, "Both events wait for the fresh copy")

        await journeys.profileDidCommit(freshCopy, distinctId: "customer")
        await journeys.profileFetchDidSettle(distinctId: "customer")
        await events.drain()

        XCTAssertEqual(starts(in: store), 1)
        XCTAssertEqual(store.storedEvents.filter { $0.name == JourneyEvents.journeyCompleted }
            .compactMap { $0.getPropertiesDict()["outcome"] as? String }, ["took_go"],
            "The Journey the trigger started took the go that followed it, once")
        await journeys.shutdown()
        await events.close()
    }

    /// The shared contract, replayed operation by operation.
    func testFetchedProfileEventAdmissionVectors() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/sdk/fetched-profile-event-admission.json")
        let vectors = try JSONDecoder().decode(
            FetchedProfileEventVectors.self, from: Data(contentsOf: url)
        )
        XCTAssertFalse(vectors.cases.isEmpty)
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let armed = replacing(
            try await authenticatedSnapshot(fixture),
            entry: Self.eventEntry("trigger"),
            reentry: .init(type: .everyMatch, window: nil)
        )
        let empty = removingDeliveredReleases(from: armed)
        for vector in vectors.cases {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let identity = MockIdentityService()
            identity.setDistinctId("customer")
            let events = MockEventLog()
            events.identity = identity
            let service = makeService(identity: identity, events: events, directory: directory)
            let router = EventLogRouter(service: service)
            events.retryFailedRoutingHandler = { await router.retry() }
            await service.initialize()
            var captured: (event: NuxieEvent, generation: UInt64)?
            var observed: [Int] = []
            for operation in vector.operations {
                switch operation {
                case "commit-empty": await service.profileDidCommit(empty, distinctId: "customer")
                case "commit-armed": await service.profileDidCommit(armed, distinctId: "customer")
                case "withdraw": await service.profileDidWithdraw(authority: nil, distinctId: "customer")
                case "fetch-begin": await service.profileFetchDidBegin(distinctId: "customer")
                case "fetch-settle": await service.profileFetchDidSettle(distinctId: "customer")
                case "capture":
                    captured = (Self.event("trigger"), service.eventAdmissionGeneration())
                case "route-captured":
                    let route = try XCTUnwrap(captured, vector.name)
                    await router.route(route.event, admittedProfileGeneration: route.generation)
                case "trigger":
                    await router.route(Self.event("trigger"))
                default: XCTFail("\(vector.name): unknown operation \(operation)")
                }
                observed.append(starts(in: events))
            }
            XCTAssertEqual(observed, vector.expectedStarts, vector.name)
            await service.shutdown()
        }
    }

    /// A Journey already waiting for the event takes it once, after the gap,
    /// together with the Journey the arriving copy starts from it.
    func testWaitingJourneyTakesTheEventOnceAndTheArrivingCopyStartsFromIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let savedCopy = try await waitingCopy(fixture, entry: "start_waiting")
        let freshCopy = try await waitingCopy(fixture, entry: "go")
        let dateProvider = MockDateProvider()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(identity: identity, events: events, directory: directory,
                                  dateProvider: dateProvider)
        let router = EventLogRouter(service: service)
        events.retryFailedRoutingHandler = { await router.retry() }
        await service.initialize()
        await service.profileDidCommit(savedCopy, distinctId: "customer")
        await router.route(Self.event("start_waiting", at: dateProvider.now()))
        XCTAssertEqual(starts(in: events), 1)

        await service.profileDidWithdraw(authority: nil, distinctId: "customer")
        await service.profileFetchDidBegin(distinctId: "customer")
        await router.route(Self.event("go", at: dateProvider.now()))
        XCTAssertEqual(completions(in: events), [], "go waits for the fresh copy")

        await service.profileDidCommit(freshCopy, distinctId: "customer")
        await service.profileFetchDidSettle(distinctId: "customer")
        XCTAssertEqual(starts(in: events), 2, "The arriving copy starts its Journey from go")
        XCTAssertEqual(completions(in: events), ["took_go", "took_go"])
        let journeyIds = events.routedEvents
            .filter { $0.name == JourneyEvents.journeyCompleted }
            .compactMap { $0.properties["journey_id"] as? String }
        XCTAssertEqual(Set(journeyIds).count, 2, "Each Journey took go exactly once")
        await service.shutdown()
    }

    /// Rendered Journeys stay closed while the foreground copy is
    /// revalidated, so waiting events are retried only once the app is active.
    func testWaitingEventsAreRetriedOnlyOnceTheAppIsActive() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let freshCopy = replacing(try await authenticatedSnapshot(fixture),
                                  entry: Self.eventEntry("trigger"),
                                  reentry: .init(type: .everyMatch, window: nil))
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(identity: identity, events: events, directory: directory)
        let router = EventLogRouter(service: service)
        events.retryFailedRoutingHandler = { await router.retry() }
        await service.initialize()
        await service.profileDidCommit(removingDeliveredReleases(from: freshCopy),
                                       distinctId: "customer")
        // The language changed in the app; the next foreground fetches.
        await service.profileDidWithdraw(authority: nil, distinctId: "customer")
        await service.onAppDidEnterBackground()
        await service.onAppWillEnterForeground()
        await service.profileFetchDidBegin(distinctId: "customer")
        await router.route(Self.event("trigger"))
        await service.profileDidCommit(freshCopy, distinctId: "customer")
        await service.profileFetchDidSettle(distinctId: "customer")
        XCTAssertEqual(events.retryFailedRoutingRequests, 0)
        XCTAssertEqual(starts(in: events), 0)

        await service.onAppBecameActive()
        XCTAssertEqual(events.retryFailedRoutingRequests, 1)
        XCTAssertEqual(starts(in: events), 1)
        await service.shutdown()
    }

    /// A waiting trigger is older than an event that routes while its copy is
    /// being installed, so it starts its Journey first.
    func testAWaitingTriggerStartsBeforeANewerEventThatRoutesDuringInstall() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let base = try await authenticatedSnapshot(fixture)
        let order: [String: JourneyReleaseJSONValue] = [
            "key": .string("order"), "type": .string("number"), "required": .bool(false),
        ]
        // One Journey that waits up to a second for go: the saved copy starts
        // it on start_waiting, the fresh copy on trigger.
        let steps = Self.waitForGoSteps(maxTimeMs: 1_000)
        let savedCopy = replacing(base, entry: Self.eventEntry("start_waiting"),
                                  reentry: .init(type: .everyMatch, window: nil),
                                  inputs: .init(eventFields: [order], responseFields: []),
                                  completionOutputs: Self.waitOutcomes, entryStepId: "wait",
                                  steps: steps, routes: [])
        let freshCopy = replacing(base, entry: Self.eventEntry("trigger"),
                                  reentry: .init(type: .everyMatch, window: nil),
                                  inputs: .init(eventFields: [order], responseFields: []),
                                  completionOutputs: Self.waitOutcomes, entryStepId: "wait",
                                  steps: steps, routes: [])
        let dateProvider = MockDateProvider()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(identity: identity, events: events, directory: directory,
                                  dateProvider: dateProvider)
        let router = EventLogRouter(service: service)
        events.retryFailedRoutingHandler = { await router.retry() }
        await service.initialize()
        await service.profileDidCommit(savedCopy, distinctId: "customer")
        await router.route(Self.event("start_waiting", at: dateProvider.now()))

        await service.profileDidWithdraw(authority: nil, distinctId: "customer")
        await service.profileFetchDidBegin(distinctId: "customer")
        await router.route(Self.event("trigger", properties: ["order": 1], at: dateProvider.now()))

        // By the time the copy arrives the waiting Journey has timed out. Its
        // report is captured while the copy is installed, and a newer trigger
        // routes at that moment.
        dateProvider.advance(by: 2)
        let injected = SwitchOnce()
        events.routedCaptureHandler = { [router, dateProvider] name, _ in
            guard name == JourneyEvents.journeyCompleted, await injected.claim() else { return }
            await router.route(Self.event("trigger", properties: ["order": 2],
                                          at: dateProvider.now()))
        }
        await service.profileDidCommit(freshCopy, distinctId: "customer")
        events.routedCaptureHandler = nil
        await service.profileFetchDidSettle(distinctId: "customer")

        let didInject = await injected.claimed
        XCTAssertTrue(didInject, "The newer trigger routed while the copy was installed")
        let runs = try await JourneyRunJournal(directory: directory, distinctId: "customer").runs()
        let startedBy = runs.sorted { $0.generation < $1.generation }.compactMap { run -> Int? in
            guard case .number(let value)? = run.context.event["order"] else { return nil }
            return Int(value)
        }
        XCTAssertEqual(startedBy, [1, 2], "The waiting trigger starts its Journey first")
        await service.shutdown()
    }

    /// A second copy arriving while waiting events are being handled does not
    /// let later events overtake them.
    func testASecondCopyWhileWaitingEventsRunKeepsTheirOrder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let freshCopy = try await waitingCopy(fixture, entry: "start_waiting")
        let dateProvider = MockDateProvider()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(identity: identity, events: events, directory: directory,
                                  dateProvider: dateProvider)
        let router = EventLogRouter(service: service)
        events.retryFailedRoutingHandler = { await router.retry() }
        await service.initialize()
        await service.profileDidCommit(removingDeliveredReleases(from: freshCopy),
                                       distinctId: "customer")
        await service.profileDidWithdraw(authority: nil, distinctId: "customer")
        await service.profileFetchDidBegin(distinctId: "customer")
        await router.route(Self.event("start_waiting", at: dateProvider.now()))
        await router.route(Self.event("start_waiting", at: dateProvider.now()))

        // While the first waiting trigger starts its Journey, a second copy
        // arrives, then the app sends another start_waiting and go.
        let injected = SwitchOnce()
        events.routedCaptureHandler = { [service, router, dateProvider] name, _ in
            guard name == JourneyEvents.journeyStarted, await injected.claim() else { return }
            await service.profileDidCommit(freshCopy, distinctId: "customer")
            await router.route(Self.event("start_waiting", at: dateProvider.now()))
            await router.route(Self.event("go", at: dateProvider.now()))
        }
        await service.profileDidCommit(freshCopy, distinctId: "customer")
        events.routedCaptureHandler = nil
        await service.profileFetchDidSettle(distinctId: "customer")

        let didInject = await injected.claimed
        XCTAssertTrue(didInject)
        XCTAssertEqual(starts(in: events), 3)
        XCTAssertEqual(completions(in: events), ["took_go", "took_go", "took_go"])
        await service.shutdown()
    }

    /// The user changes while an event of the previous user is still being
    /// routed. The new user's copy must not start a Journey from it.
    func testEventNeverStartsAnotherCustomersJourney() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let base = try await authenticatedSnapshot(fixture)
        let waitingCopy = replacing(base, entry: Self.eventEntry("start_waiting"),
                                    reentry: .init(type: .everyMatch, window: nil),
                                    completionOutputs: Self.waitOutcomes, entryStepId: "wait",
                                    steps: Self.waitForGoSteps(), routes: [])
        let otherCopy = replacing(base, entry: Self.eventEntry("go"),
                                  reentry: .init(type: .everyMatch, window: nil))
        let dateProvider = MockDateProvider()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(identity: identity, events: events, directory: directory,
                                  dateProvider: dateProvider)
        await service.initialize()
        await service.profileDidCommit(waitingCopy, distinctId: "customer")
        await service.handleEvent(Self.event("start_waiting", at: dateProvider.now()))

        // While go is routed, the waiting Journey finishes and reports; at
        // that moment the app switches to another user whose copy arrives.
        let switched = SwitchOnce()
        events.routedCaptureHandler = { [service] name, _ in
            guard name == JourneyEvents.journeyCompleted, await switched.claim() else { return }
            identity.setDistinctId("other")
            await service.profileDidCommit(otherCopy, distinctId: "other")
        }
        await service.handleEvent(Self.event("go", at: dateProvider.now()))
        events.routedCaptureHandler = nil

        let switchedOver = await switched.claimed
        XCTAssertTrue(switchedOver, "The user switch happened while go was routed")
        XCTAssertEqual(events.routedEvents.filter {
            $0.name == JourneyEvents.journeyStarted && $0.distinctId == "other"
        }.count, 0)
        await service.shutdown()
    }

    // MARK: - Helpers

    private static let waitOutcomes: [String: Journey.Boundary] = [
        "took_go": .init(eventFields: [], responseFields: []),
        "timed_out": .init(eventFields: [], responseFields: []),
    ]

    /// A copy whose Journey starts on `entry` and waits a minute for go.
    private func waitingCopy(
        _ fixture: JourneyPlaneProfileTestFixture,
        entry: String
    ) async throws -> JourneyProfileCatalog.Snapshot {
        replacing(try await authenticatedSnapshot(fixture), entry: Self.eventEntry(entry),
                  reentry: .init(type: .everyMatch, window: nil),
                  completionOutputs: Self.waitOutcomes, entryStepId: "wait",
                  steps: Self.waitForGoSteps(), routes: [])
    }

    private static func eventEntry(_ name: String) -> JourneyEntryCondition {
        .init(type: .event, eventName: name, segmentId: nil, member: nil, condition: nil)
    }

    private static func event(
        _ name: String,
        id: String = UUID.v7().uuidString,
        properties: [String: Any] = [:],
        at timestamp: Date = Date()
    ) -> NuxieEvent {
        NuxieEvent(id: id, name: name, distinctId: "customer", properties: properties, timestamp: timestamp)
    }

    private static func waitForGoSteps(maxTimeMs: Double = 60_000) -> [Journey.Step] {
        [
            .init(
                kind: .action,
                id: "wait",
                action: [
                    "type": .string("wait_until"),
                    "trigger": .object([
                        "kind": .string("event"),
                        "eventName": .string("go"),
                    ]),
                    "condition": .object([
                        "type": .string("Truthy"),
                        "value": .object([
                            "type": .string("Boolean"),
                            "value": .bool(true),
                        ]),
                    ]),
                    "maxTimeMs": .number(maxTimeMs),
                ],
                outlets: ["satisfied": "took_go", "timeout": "timed_out"],
                outcome: nil
            ),
            .init(kind: .complete, id: "took_go", action: nil, outlets: nil, outcome: "took_go"),
            .init(kind: .complete, id: "timed_out", action: nil, outlets: nil, outcome: "timed_out"),
        ]
    }

    /// Delivers like EventLog's route worker: one event at a time and in
    /// order; a refused event is kept first with everything after it, until
    /// the service asks for the retry.
    private actor EventLogRouter {
        let service: JourneyService
        private var waiting: [(event: NuxieEvent, generation: UInt64?)] = []
        private var delivering = false
        private var refused = false

        init(service: JourneyService) {
            self.service = service
        }

        func route(_ event: NuxieEvent, admittedProfileGeneration: UInt64? = nil) async {
            waiting.append((event, admittedProfileGeneration))
            await deliver()
        }

        func retry() async {
            refused = false
            await deliver()
        }

        private func deliver() async {
            guard !delivering, !refused else { return }
            delivering = true
            while let next = waiting.first {
                guard await service.handleEvent(
                    next.event,
                    admittedProfileGeneration: next.generation
                ) else {
                    refused = true
                    break
                }
                waiting.removeFirst()
            }
            delivering = false
        }
    }

    private actor SwitchOnce {
        private(set) var claimed = false
        func claim() -> Bool {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    private struct FetchedProfileEventVectors: Decodable {
        struct Case: Decodable {
            let name: String
            let operations: [String]
            let expectedStarts: [Int]
        }
        let cases: [Case]
    }

    private func starts(in store: MockEventStore) -> Int {
        store.storedEvents.filter { $0.name == JourneyEvents.journeyStarted }.count
    }

    private func starts(in events: MockEventLog) -> Int {
        events.routedEvents.filter { $0.name == JourneyEvents.journeyStarted }.count
    }

    private func completions(in events: MockEventLog) -> [String] {
        events.routedEvents
            .filter { $0.name == JourneyEvents.journeyCompleted }
            .compactMap { $0.properties["outcome"] as? String }
    }
}
