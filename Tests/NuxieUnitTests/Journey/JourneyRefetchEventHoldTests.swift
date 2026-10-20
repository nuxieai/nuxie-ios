import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

/// While a customer's copy of the published setup is being fetched, their
/// events wait, then replay against the copy when it lands (UNIV-5164).
/// Journeys already waiting take each event once, and no wait runs out for
/// the time spent waiting.
final class JourneyRefetchEventHoldTests: JourneyTestCase {

    /// identify(B) while B's copy is fetched: B's Journey left waiting by an
    /// earlier launch takes a go sent meanwhile exactly once, and B's copy
    /// starts its own Journey from that go once.
    func testIdentifyHoldsTheArrivingCustomersEventAndTheirWaitingJourneyTakesItOnce() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let savedCopy = try await waitingCopy(fixture, entry: "start_waiting")
        let arrivingCopy = try await waitingCopy(fixture, entry: "go")
        // EventLog stamps tracked events with the wall clock; the waits open
        // on the same clock.
        let dateProvider = MockDateProvider(initialDate: Date())

        // An earlier launch leaves customer B a Journey waiting for go.
        let earlierIdentity = MockIdentityService()
        earlierIdentity.setDistinctId("customer-b")
        let earlier = makeService(identity: earlierIdentity, events: MockEventLog(),
                                  directory: directory, dateProvider: dateProvider)
        await earlier.initialize()
        await earlier.profileDidCommit(savedCopy, distinctId: "customer-b")
        await earlier.handleEvent(NuxieEvent(name: "start_waiting", distinctId: "customer-b",
                                             timestamp: dateProvider.now()))

        // This launch has settled as customer A, then the app signs in B and
        // sends go before B's copy arrives.
        let launch = try await settledLaunch(directory: directory, distinctId: "customer-a",
                                             dateProvider: dateProvider,
                                             pinned: try pinnedRelease(savedCopy))
        launch.identity.setDistinctId("customer-b")
        await launch.journeys.handleUserChange(from: "customer-a", to: "customer-b")
        launch.events.track("go")
        await launch.routeWhatCanRoute()
        XCTAssertEqual(launch.outcomes(), [], "go waits for B's copy")

        await launch.journeys.profileDidCommit(arrivingCopy, distinctId: "customer-b")
        await launch.journeys.finishUserChangeRouting(to: "customer-b")
        await launch.events.drain()

        XCTAssertEqual(launch.starts(for: "customer-b"), 1, "B's copy starts its Journey from go")
        XCTAssertEqual(launch.outcomes(for: "customer-b"), ["took_go", "took_go"])
        XCTAssertEqual(launch.completedJourneys(for: "customer-b"), 2,
                       "The waiting Journey and the new one each took go exactly once")
        await launch.close()
    }

    /// The language changes in the app: the saved copy is withdrawn and the
    /// new language's copy fetched. A go sent meanwhile waits, then the
    /// waiting Journey takes it and the fresh copy starts its Journey from it.
    func testEventsDuringALocaleRefetchWaitAndReplayAgainstTheFreshCopy() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let savedCopy = try await waitingCopy(fixture, entry: "start_waiting")
        let freshCopy = try await waitingCopy(fixture, entry: "go")
        let launch = try await settledLaunch(directory: directory, distinctId: "customer",
                                             dateProvider: MockDateProvider(initialDate: Date()),
                                             pinned: try pinnedRelease(savedCopy))
        await launch.journeys.profileDidCommit(savedCopy, distinctId: "customer")
        launch.events.track("start_waiting")
        await launch.routeWhatCanRoute()
        XCTAssertEqual(launch.starts(), 1)

        await launch.journeys.profileRefetchWillBegin(distinctId: "customer")
        await launch.journeys.profileDidWithdraw(authority: nil, distinctId: "customer")
        launch.events.track("go")
        await launch.routeWhatCanRoute()
        XCTAssertEqual(launch.outcomes(), [], "go waits for the fresh copy")

        await launch.journeys.profileDidCommit(freshCopy, distinctId: "customer")
        await launch.journeys.profileRefetchDidSettle(distinctId: "customer")
        await launch.events.drain()

        XCTAssertEqual(launch.starts(), 2, "The fresh copy starts its Journey from go")
        XCTAssertEqual(launch.outcomes(), ["took_go", "took_go"])
        XCTAssertEqual(launch.completedJourneys(), 2, "Each Journey took go exactly once")
        await launch.close()
    }

    /// The waiting Journey's minute runs out while its go is held. Neither
    /// the app becoming active nor an earlier held event replaying first
    /// times it out: it takes the go it was sent in time.
    func testAWaitThatRunsOutDuringTheRefetchTakesTheEventSentInTime() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let savedCopy = try await waitingCopy(fixture, entry: "start_waiting")
        let dateProvider = MockDateProvider(initialDate: Date())
        let launch = try await settledLaunch(directory: directory, distinctId: "customer",
                                             dateProvider: dateProvider,
                                             pinned: try pinnedRelease(savedCopy))
        await launch.journeys.profileDidCommit(savedCopy, distinctId: "customer")
        launch.events.track("start_waiting")
        await launch.routeWhatCanRoute()

        await launch.journeys.profileRefetchWillBegin(distinctId: "customer")
        await launch.journeys.profileDidWithdraw(authority: nil, distinctId: "customer")
        launch.events.track("screen_viewed")
        launch.events.track("go")
        await launch.routeWhatCanRoute()
        dateProvider.advance(by: 70)
        await launch.journeys.onAppBecameActive()
        XCTAssertEqual(launch.outcomes(), [], "The wait stays open while its go is held")

        // The new language's copy has the same Journey.
        await launch.journeys.profileDidCommit(savedCopy, distinctId: "customer")
        await launch.journeys.profileRefetchDidSettle(distinctId: "customer")
        await launch.events.drain()

        XCTAssertEqual(launch.outcomes(), ["took_go"])
        await launch.close()
    }

    /// The app becomes active while the held events replay, after the
    /// wait's minute ran out. The wait still takes the go sent in time.
    func testActivationWhileHeldEventsReplayDoesNotTimeOutTheWait() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let savedCopy = try await waitingCopy(fixture, entry: "start_waiting")
        let dateProvider = MockDateProvider(initialDate: Date())
        let activated = ActivateOnce()
        let launch = try await settledLaunch(
            directory: directory, distinctId: "customer", dateProvider: dateProvider,
            pinned: try pinnedRelease(savedCopy)
        ) { name, journeys in
            guard name == "screen_viewed", await activated.claim() else { return }
            await journeys.onAppBecameActive()
        }
        await launch.journeys.profileDidCommit(savedCopy, distinctId: "customer")
        launch.events.track("start_waiting")
        await launch.routeWhatCanRoute()

        await launch.journeys.profileRefetchWillBegin(distinctId: "customer")
        await launch.journeys.profileDidWithdraw(authority: nil, distinctId: "customer")
        launch.events.track("screen_viewed")
        launch.events.track("go")
        await launch.routeWhatCanRoute()
        dateProvider.advance(by: 70)
        await launch.journeys.profileDidCommit(savedCopy, distinctId: "customer")
        await launch.journeys.profileRefetchDidSettle(distinctId: "customer")
        await launch.events.drain()

        let didActivate = await activated.claimed
        XCTAssertTrue(didActivate, "The app became active during the replay")
        XCTAssertEqual(launch.outcomes(), ["took_go"])
        await launch.close()
    }

    /// The fetch fails: the held go goes through without a copy, and the
    /// Journey already waiting takes it.
    func testAFailedRefetchLetsTheHeldEventsThroughWithoutACopy() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let savedCopy = try await waitingCopy(fixture, entry: "start_waiting")
        let launch = try await settledLaunch(directory: directory, distinctId: "customer",
                                             dateProvider: MockDateProvider(initialDate: Date()),
                                             pinned: try pinnedRelease(savedCopy))
        await launch.journeys.profileDidCommit(savedCopy, distinctId: "customer")
        launch.events.track("start_waiting")
        await launch.routeWhatCanRoute()

        await launch.journeys.profileRefetchWillBegin(distinctId: "customer")
        await launch.journeys.profileDidWithdraw(authority: nil, distinctId: "customer")
        launch.events.track("go")
        await launch.routeWhatCanRoute()
        XCTAssertEqual(launch.outcomes(), [])

        await launch.journeys.profileRefetchDidSettle(distinctId: "customer")
        await launch.events.drain()
        XCTAssertEqual(launch.outcomes(), ["took_go"])

        // Routing is live again.
        launch.events.track("start_waiting")
        await launch.events.drain()
        XCTAssertEqual(launch.starts(), 1, "No copy is installed, so nothing starts")
        await launch.journeys.profileDidCommit(savedCopy, distinctId: "customer")
        launch.events.track("start_waiting")
        await launch.events.drain()
        XCTAssertEqual(launch.starts(), 2)
        await launch.close()
    }

    /// An event captured before a wait's deadline but handled after it
    /// leaves that timeout to a pass at the current time, which still runs.
    func testALateEventDoesNotStrandAWaitThatIsDue() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let savedCopy = try await waitingCopy(fixture, entry: "start_waiting")
        let dateProvider = MockDateProvider(initialDate: Date())
        let sleeper = MockSleepProvider()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(identity: identity, events: events, directory: directory,
                                  dateProvider: dateProvider, sleepProvider: sleeper)
        await service.initialize()
        await service.profileDidCommit(savedCopy, distinctId: "customer")
        await service.handleEvent(NuxieEvent(name: "start_waiting", distinctId: "customer",
                                             timestamp: dateProvider.now()))
        let capturedAt = dateProvider.now().addingTimeInterval(30)
        dateProvider.advance(by: 70)

        await service.handleEvent(NuxieEvent(name: "screen_viewed", distinctId: "customer",
                                             timestamp: capturedAt))
        for _ in 0..<200 where !sleeper.pendingSleepDurations.contains(0) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(sleeper.pendingSleepDurations.contains(0), "A timeout pass is due at once")
        sleeper.completeSleeps(withDuration: 0)
        for _ in 0..<200 where completions(in: events).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(completions(in: events), ["timed_out"])
        await service.shutdown()
    }

    /// The shared contract, replayed operation by operation.
    func testRefetchEventHoldVectors() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/sdk/refetch-event-hold.json")
        let vectors = try JSONDecoder().decode(
            RefetchEventHoldVectors.self, from: Data(contentsOf: url)
        )
        XCTAssertFalse(vectors.cases.isEmpty)
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let savedCopy = try await waitingCopy(fixture, entry: "start_waiting")
        let freshCopy = try await waitingCopy(fixture, entry: "go")
        for vector in vectors.cases {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let dateProvider = MockDateProvider(initialDate: Date())
            let launch = try await settledLaunch(directory: directory, distinctId: "customer",
                                                 dateProvider: dateProvider,
                                                 pinned: try pinnedRelease(savedCopy))
            for step in vector.steps {
                switch step.op {
                case "commit-saved":
                    await launch.journeys.profileDidCommit(savedCopy, distinctId: "customer")
                case "commit-fresh":
                    await launch.journeys.profileDidCommit(freshCopy, distinctId: "customer")
                case "refetch-begin":
                    await launch.journeys.profileRefetchWillBegin(distinctId: "customer")
                case "refetch-settle":
                    await launch.journeys.profileRefetchDidSettle(distinctId: "customer")
                case "withdraw":
                    await launch.journeys.profileDidWithdraw(authority: nil, distinctId: "customer")
                case "advance-past-deadline":
                    dateProvider.advance(by: 70)
                case "app-active":
                    await launch.journeys.onAppBecameActive()
                case let op where op.hasPrefix("track "):
                    launch.events.track(String(op.dropFirst("track ".count)))
                default:
                    XCTFail("\(vector.name): unknown operation \(step.op)")
                }
                await launch.routeWhatCanRoute()
                let outcomes = launch.outcomes()
                XCTAssertEqual(
                    [launch.starts(), outcomes.filter { $0 == "took_go" }.count,
                     outcomes.filter { $0 == "timed_out" }.count],
                    [step.starts, step.tookGo, step.timedOut],
                    "\(vector.name) after \(step.op)"
                )
            }
            await launch.close()
        }
    }

    // MARK: - Helpers

    /// One launch: Journey subscribed to a real EventLog as NuxieSDK
    /// subscribes it, with the customer's journal open and routing live.
    private struct Launch {
        let identity: MockIdentityService
        let store: MockEventStore
        let events: EventLog
        let journeys: JourneyService

        /// Commits what the app sent and routes it, unless routing is held.
        func routeWhatCanRoute() async {
            _ = await events.flushEvents()
            _ = await events.drainCommittedRouting()
        }

        func starts(for distinctId: String = "customer") -> Int {
            store.storedEvents.filter {
                $0.name == JourneyEvents.journeyStarted && $0.distinctId == distinctId
            }.count
        }

        func outcomes(for distinctId: String = "customer") -> [String] {
            completions(for: distinctId).compactMap { $0.getPropertiesDict()["outcome"] as? String }
        }

        func completedJourneys(for distinctId: String = "customer") -> Int {
            Set(completions(for: distinctId).compactMap {
                $0.getPropertiesDict()["journey_id"] as? String
            }).count
        }

        private func completions(for distinctId: String) -> [StoredEvent] {
            store.storedEvents.filter {
                $0.name == JourneyEvents.journeyCompleted && $0.distinctId == distinctId
            }
        }

        func close() async {
            await journeys.shutdown()
            await events.close()
        }
    }

    /// `pinned` stands in for the release a parked Journey re-authenticates
    /// from its pin while no copy is installed. `beforeHandling` runs as
    /// each routed event reaches Journey.
    private func settledLaunch(
        directory: URL,
        distinctId: String,
        dateProvider: MockDateProvider,
        pinned: AuthenticatedJourneyRelease,
        beforeHandling: (@Sendable (String, JourneyService) async -> Void)? = nil
    ) async throws -> Launch {
        let identity = MockIdentityService()
        identity.setDistinctId(distinctId)
        let store = MockEventStore()
        let events = EventLog(identity: identity, dateProvider: dateProvider,
                              apiClient: MockNuxieApi(), store: store)
        let journeys = JourneyService(
            identity: identity, events: events,
            dateProvider: dateProvider, sleepProvider: MockSleepProvider(),
            journalDirectory: directory, featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            pinnedReleaseAuthenticator: { _, _ in pinned },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed)
        )
        let reservation = events.reserveCommittedAdmission { journeys.eventAdmissionGeneration() }
        await events.subscribeAcknowledgingCommitted(reservation: reservation) { event, admitted in
            await beforeHandling?(event.name, journeys)
            return await journeys.handleEvent(event, admittedProfileGeneration: admitted)
        }
        await journeys.prepareForEvents()
        let configuration = NuxieConfiguration(apiKey: "refetch-event-hold-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await events.configure(configuration: configuration)
        await journeys.initialize()
        await journeys.finishStartupRouting()
        await events.drain()
        return Launch(identity: identity, store: store, events: events, journeys: journeys)
    }

    /// Both copies run the same Journey, so they share one release.
    private func pinnedRelease(
        _ copy: JourneyProfileCatalog.Snapshot
    ) throws -> AuthenticatedJourneyRelease {
        try XCTUnwrap(copy.releasesByDigest.values.first)
    }

    private static let waitOutcomes: [String: Journey.Boundary] = [
        "took_go": .init(eventFields: [], responseFields: []),
        "timed_out": .init(eventFields: [], responseFields: []),
    ]

    /// A copy whose Journey starts on `entry` and waits a minute for go.
    private func waitingCopy(
        _ fixture: JourneyPlaneProfileTestFixture,
        entry: String
    ) async throws -> JourneyProfileCatalog.Snapshot {
        replacing(try await authenticatedSnapshot(fixture),
                  entry: .init(type: .event, eventName: entry, segmentId: nil, member: nil,
                               condition: nil),
                  reentry: .init(type: .everyMatch, window: nil),
                  completionOutputs: Self.waitOutcomes, entryStepId: "wait",
                  steps: Self.waitForGoSteps, routes: [])
    }

    private static let waitForGoSteps: [Journey.Step] = [
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
                "maxTimeMs": .number(60_000),
            ],
            outlets: ["satisfied": "took_go", "timeout": "timed_out"],
            outcome: nil
        ),
        .init(kind: .complete, id: "took_go", action: nil, outlets: nil, outcome: "took_go"),
        .init(kind: .complete, id: "timed_out", action: nil, outlets: nil, outcome: "timed_out"),
    ]

    private func completions(in events: MockEventLog) -> [String] {
        events.routedEvents
            .filter { $0.name == JourneyEvents.journeyCompleted }
            .compactMap { $0.properties["outcome"] as? String }
    }

    private actor ActivateOnce {
        private(set) var claimed = false
        func claim() -> Bool {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    private struct RefetchEventHoldVectors: Decodable {
        struct Case: Decodable {
            let name: String
            let steps: [Step]
        }
        struct Step: Decodable {
            let op: String
            let starts: Int
            let tookGo: Int
            let timedOut: Int
        }
        let cases: [Case]
    }
}
