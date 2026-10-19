import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

/// An app event that arrives while the published setup is being fetched is
/// kept: once the copy arrives it can start Experiences, and no Journey takes
/// the same event twice (UNIV-4589).
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
                    await service.handleEvent(route.event, admittedProfileGeneration: route.generation)
                case "trigger":
                    await service.handleEvent(Self.event("trigger"),
                                              admittedProfileGeneration: service.eventAdmissionGeneration())
                default: XCTFail("\(vector.name): unknown operation \(operation)")
                }
                observed.append(starts(in: events))
            }
            XCTAssertEqual(observed, vector.expectedStarts, vector.name)
            await service.shutdown()
        }
    }

    /// A Journey already waiting for the event takes it at once during the
    /// gap. The copy that arrives offers the event only to its entry arms, so
    /// the waiting Journey never takes it a second time.
    func testWaitingJourneyTakesTheEventOnceAndTheArrivingCopyStartsFromIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let base = try await authenticatedSnapshot(fixture)
        let waitsForGo = Self.waitForGoSteps()
        let outcomes: [String: Journey.Boundary] = [
            "took_go": .init(eventFields: [], responseFields: []),
            "timed_out": .init(eventFields: [], responseFields: []),
        ]
        let savedCopy = replacing(base, entry: Self.eventEntry("start_waiting"),
                                  reentry: .init(type: .everyMatch, window: nil),
                                  completionOutputs: outcomes, entryStepId: "wait",
                                  steps: waitsForGo, routes: [])
        let freshCopy = replacing(base, entry: Self.eventEntry("go"),
                                  reentry: .init(type: .everyMatch, window: nil),
                                  completionOutputs: outcomes, entryStepId: "wait",
                                  steps: waitsForGo, routes: [])
        let pinnedRelease = try XCTUnwrap(savedCopy.releasesByDigest.values.first)
        let dateProvider = MockDateProvider()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity, events: events, directory: directory,
            dateProvider: dateProvider,
            pinnedReleaseAuthenticator: { _, _ in pinnedRelease }
        )
        await service.initialize()
        await service.profileDidCommit(savedCopy, distinctId: "customer")
        await service.handleEvent(Self.event("start_waiting", at: dateProvider.now()))
        XCTAssertEqual(starts(in: events), 1)
        XCTAssertEqual(completions(in: events), [], "The started Journey waits for go")

        await service.profileDidWithdraw(authority: nil, distinctId: "customer")
        await service.profileFetchDidBegin(distinctId: "customer")
        await service.handleEvent(Self.event("go", id: "00000000-0000-7000-8000-000000045892",
                                             at: dateProvider.now()))
        XCTAssertEqual(completions(in: events), ["took_go"],
                       "The waiting Journey carries on at once during the gap")

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

    /// A kept trigger is older than an event that routes while its copy is
    /// being installed, so it starts its Journey first.
    func testKeptTriggerStartsBeforeANewerEventThatRoutesDuringInstall() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let base = try await authenticatedSnapshot(fixture)
        let order: [String: JourneyReleaseJSONValue] = [
            "key": .string("order"), "type": .string("number"), "required": .bool(false),
        ]
        let outcomes: [String: Journey.Boundary] = [
            "took_go": .init(eventFields: [], responseFields: []),
            "timed_out": .init(eventFields: [], responseFields: []),
        ]
        // One Journey that waits up to a second for go: the saved copy starts
        // it on start_waiting, the fresh copy on trigger.
        let steps = Self.waitForGoSteps(maxTimeMs: 1_000)
        let savedCopy = replacing(base, entry: Self.eventEntry("start_waiting"),
                                  reentry: .init(type: .everyMatch, window: nil),
                                  inputs: .init(eventFields: [order], responseFields: []),
                                  completionOutputs: outcomes, entryStepId: "wait",
                                  steps: steps, routes: [])
        let freshCopy = replacing(base, entry: Self.eventEntry("trigger"),
                                  reentry: .init(type: .everyMatch, window: nil),
                                  inputs: .init(eventFields: [order], responseFields: []),
                                  completionOutputs: outcomes, entryStepId: "wait",
                                  steps: steps, routes: [])
        let pinnedRelease = try XCTUnwrap(savedCopy.releasesByDigest.values.first)
        let dateProvider = MockDateProvider()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(identity: identity, events: events, directory: directory,
                                  dateProvider: dateProvider,
                                  pinnedReleaseAuthenticator: { _, _ in pinnedRelease })
        await service.initialize()
        await service.profileDidCommit(savedCopy, distinctId: "customer")
        await service.handleEvent(Self.event("start_waiting", at: dateProvider.now()))

        // The language changes in the app and the fresh copy is fetched.
        await service.profileDidWithdraw(authority: nil, distinctId: "customer")
        await service.profileFetchDidBegin(distinctId: "customer")
        await service.handleEvent(Self.event("trigger", properties: ["order": 1],
                                             at: dateProvider.now()))

        // By the time the copy arrives the waiting Journey has timed out. Its
        // report is captured while the copy is installed, and a newer trigger
        // routes at that moment.
        dateProvider.advance(by: 2)
        let injected = SwitchOnce()
        let router = HoldAwareRouter(events: events, service: service)
        events.routedCaptureHandler = { [router, dateProvider] name, _ in
            guard name == JourneyEvents.journeyCompleted, await injected.claim() else { return }
            await router.route(Self.event("trigger", properties: ["order": 2],
                                          at: dateProvider.now()))
        }
        await service.profileDidCommit(freshCopy, distinctId: "customer")
        events.routedCaptureHandler = nil
        await router.deliverHeld()
        await service.profileFetchDidSettle(distinctId: "customer")

        let didInject = await injected.claimed
        XCTAssertTrue(didInject, "The newer trigger routed while the copy was installed")
        let runs = try await JourneyRunJournal(directory: directory, distinctId: "customer").runs()
        let startedBy = runs.sorted { $0.generation < $1.generation }.compactMap { run -> Int? in
            guard case .number(let value)? = run.context.event["order"] else { return nil }
            return Int(value)
        }
        XCTAssertEqual(startedBy, [1, 2], "The kept trigger starts its Journey first")
        await service.shutdown()
    }

    /// Events that route while kept events are offered are handled whole and
    /// in order afterwards: a Journey started by one of them still takes the
    /// event that follows it.
    func testEventsDuringTheKeptOfferAreHandledWholeAndInOrder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let base = try await authenticatedSnapshot(fixture)
        let outcomes: [String: Journey.Boundary] = [
            "took_go": .init(eventFields: [], responseFields: []),
            "timed_out": .init(eventFields: [], responseFields: []),
        ]
        let freshCopy = replacing(base, entry: Self.eventEntry("start_waiting"),
                                  reentry: .init(type: .everyMatch, window: nil),
                                  completionOutputs: outcomes, entryStepId: "wait",
                                  steps: Self.waitForGoSteps(), routes: [])
        let dateProvider = MockDateProvider()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(identity: identity, events: events, directory: directory,
                                  dateProvider: dateProvider)
        await service.initialize()
        await service.profileDidCommit(removingDeliveredReleases(from: freshCopy),
                                       distinctId: "customer")
        await service.profileDidWithdraw(authority: nil, distinctId: "customer")
        await service.profileFetchDidBegin(distinctId: "customer")
        await service.handleEvent(Self.event("start_waiting", at: dateProvider.now()))

        // While the kept trigger starts its Journey, the app sends another
        // start_waiting and then go.
        let injected = SwitchOnce()
        let router = HoldAwareRouter(events: events, service: service)
        events.routedCaptureHandler = { [router, dateProvider] name, _ in
            guard name == JourneyEvents.journeyStarted, await injected.claim() else { return }
            await router.route(Self.event("start_waiting", at: dateProvider.now()))
            await router.route(Self.event("go", at: dateProvider.now()))
        }
        await service.profileDidCommit(freshCopy, distinctId: "customer")
        events.routedCaptureHandler = nil
        await router.deliverHeld()
        await service.profileFetchDidSettle(distinctId: "customer")

        let didInject = await injected.claimed
        XCTAssertTrue(didInject)
        XCTAssertEqual(starts(in: events), 2)
        XCTAssertEqual(completions(in: events), ["took_go", "took_go"],
                       "Both Journeys took the go that followed them")
        await service.shutdown()
    }

    /// A second copy arriving while kept events are still being offered must
    /// not release routing early: events after them still wait their turn.
    func testASecondCopyDuringTheOfferKeepsRoutingHeldUntilItEnds() async throws {
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
        await service.initialize()
        await service.profileDidCommit(removingDeliveredReleases(from: freshCopy),
                                       distinctId: "customer")
        await service.profileDidWithdraw(authority: nil, distinctId: "customer")
        await service.profileFetchDidBegin(distinctId: "customer")
        await service.handleEvent(Self.event("start_waiting", at: dateProvider.now()))
        await service.handleEvent(Self.event("start_waiting", at: dateProvider.now()))

        // While the first kept trigger starts its Journey, a second copy
        // arrives, then the app sends another start_waiting and go.
        let injected = SwitchOnce()
        let router = HoldAwareRouter(events: events, service: service)
        events.routedCaptureHandler = { [service, router, dateProvider] name, _ in
            guard name == JourneyEvents.journeyStarted, await injected.claim() else { return }
            await service.profileDidCommit(freshCopy, distinctId: "customer")
            await router.route(Self.event("start_waiting", at: dateProvider.now()))
            await router.route(Self.event("go", at: dateProvider.now()))
        }
        await service.profileDidCommit(freshCopy, distinctId: "customer")
        events.routedCaptureHandler = nil
        await router.deliverHeld()
        await service.profileFetchDidSettle(distinctId: "customer")

        let didInject = await injected.claimed
        XCTAssertTrue(didInject)
        XCTAssertEqual(starts(in: events), 3)
        XCTAssertEqual(completions(in: events), ["took_go", "took_go", "took_go"])
        await service.shutdown()
    }

    /// However routing gets released before kept events are offered (journal
    /// recovery can release it), the next event offers them first, so the
    /// Journey a kept trigger starts still takes the event that follows.
    func testAnEventReleasedEarlyOffersKeptEventsBeforeItsOwnSignals() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let base = try await authenticatedSnapshot(fixture)
        // A Journey already waiting before the gap times out while the copy
        // is installed; its report marks the moment an early event arrives.
        let savedCopy = replacing(base, entry: Self.eventEntry("start_waiting"),
                                  reentry: .init(type: .everyMatch, window: nil),
                                  completionOutputs: Self.waitOutcomes, entryStepId: "wait",
                                  steps: Self.waitForGoSteps(maxTimeMs: 1_000), routes: [])
        let freshCopy = try await waitingCopy(fixture, entry: "start_waiting")
        let pinnedRelease = try XCTUnwrap(savedCopy.releasesByDigest.values.first)
        let dateProvider = MockDateProvider()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(identity: identity, events: events, directory: directory,
                                  dateProvider: dateProvider,
                                  pinnedReleaseAuthenticator: { _, _ in pinnedRelease })
        await service.initialize()
        await service.profileDidCommit(savedCopy, distinctId: "customer")
        await service.handleEvent(Self.event("start_waiting", at: dateProvider.now()))
        await service.profileDidWithdraw(authority: nil, distinctId: "customer")
        await service.profileFetchDidBegin(distinctId: "customer")
        await service.handleEvent(Self.event("start_waiting", at: dateProvider.now()))
        dateProvider.advance(by: 2)

        let injected = SwitchOnce()
        events.routedCaptureHandler = { [service, dateProvider] name, _ in
            guard name == JourneyEvents.journeyCompleted, await injected.claim() else { return }
            // Delivered past any hold, as a released route would be.
            await service.handleEvent(Self.event("go", at: dateProvider.now()))
        }
        await service.profileDidCommit(freshCopy, distinctId: "customer")
        events.routedCaptureHandler = nil
        await service.profileFetchDidSettle(distinctId: "customer")

        let didInject = await injected.claimed
        XCTAssertTrue(didInject)
        XCTAssertEqual(completions(in: events).sorted(), ["timed_out", "took_go"],
                       "The kept trigger's Journey took the go that followed it")
        await service.shutdown()
    }

    /// The user changes while an event of the previous user is still being
    /// routed. The new user's copy must not start a Journey from it.
    func testEventNeverStartsAnotherCustomersJourney() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let base = try await authenticatedSnapshot(fixture)
        let outcomes: [String: Journey.Boundary] = [
            "took_go": .init(eventFields: [], responseFields: []),
            "timed_out": .init(eventFields: [], responseFields: []),
        ]
        let waitingCopy = replacing(base, entry: Self.eventEntry("start_waiting"),
                                    reentry: .init(type: .everyMatch, window: nil),
                                    completionOutputs: outcomes, entryStepId: "wait",
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

    /// Delivers like EventLog's route worker: while routing is held, events
    /// wait and are delivered in order once it is released.
    private actor HoldAwareRouter {
        let events: MockEventLog
        let service: JourneyService
        private var held: [NuxieEvent] = []

        init(events: MockEventLog, service: JourneyService) {
            self.events = events
            self.service = service
        }

        func route(_ event: NuxieEvent) async {
            guard !events.routingDeferred, held.isEmpty else {
                held.append(event)
                return
            }
            await service.handleEvent(event)
        }

        func deliverHeld() async {
            while !held.isEmpty, !events.routingDeferred {
                await service.handleEvent(held.removeFirst())
            }
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
