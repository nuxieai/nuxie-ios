import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

/// An event captured before the installed copy of the published setup is not
/// dropped: it starts from the copy it is handled under, once (UNIV-4589).
final class JourneyEarlyEventAdmissionTests: JourneyTestCase {

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

        await service.profileDidCommit(snapshot, artifacts: nil,
                                       authority: fixture.deliveryAuthority,
                                       admissionGeneration: 1, distinctId: "customer")
        await events.drain()

        XCTAssertEqual(starts(in: store), 1)
        XCTAssertTrue(store.pendingStableRouteIds.isEmpty)
        await service.shutdown()
        await events.close()
    }

    /// A Journey left waiting by the previous launch takes an event held
    /// before this launch's first copy exactly once, and that copy also
    /// starts its own Journey from the event once.
    func testAWaitingJourneyTakesAHeldEventOnceAndTheFirstCopyStartsFromIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let savedCopy = try await waitingCopy(fixture, entry: "start_waiting")
        let firstCopy = try await waitingCopy(fixture, entry: "go")
        // EventLog stamps tracked events with the wall clock; the waits open
        // on the same clock.
        let dateProvider = MockDateProvider(initialDate: Date())
        let identity = MockIdentityService()
        identity.setDistinctId("customer")

        // The previous launch leaves a Journey waiting for go.
        let previous = JourneyService(
            identity: identity, events: MockEventLog(),
            dateProvider: dateProvider, sleepProvider: MockSleepProvider(),
            journalDirectory: directory,
            storageScope: JourneyStorageScope(authority: fixture.deliveryAuthority),
            featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: MockEventLog()),
            pinnedReleaseAuthenticator: { _, _ in throw JourneyJournalError.invalidState },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed)
        )
        await previous.initialize()
        await previous.profileDidCommit(savedCopy, distinctId: "customer")
        await previous.handleEvent(Self.event("start_waiting", at: dateProvider.now()))

        // This launch tracks go before its first copy arrives.
        let store = MockEventStore()
        let events = EventLog(identity: identity, dateProvider: dateProvider,
                              apiClient: MockNuxieApi(), store: store)
        let service = JourneyService(
            identity: identity, events: events,
            dateProvider: dateProvider, sleepProvider: MockSleepProvider(),
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
        let configuration = NuxieConfiguration(apiKey: "held-event-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await events.configure(configuration: configuration)
        await service.initialize()
        events.track("go")
        _ = await events.flushEvents()
        XCTAssertEqual(completions(in: store), [], "go waits for the first copy")

        await service.profileDidCommit(firstCopy, artifacts: nil,
                                       authority: fixture.deliveryAuthority,
                                       admissionGeneration: 1, distinctId: "customer")
        await events.drain()

        XCTAssertEqual(starts(in: store), 1, "The first copy starts its Journey from go")
        let completed = store.storedEvents.filter { $0.name == JourneyEvents.journeyCompleted }
        XCTAssertEqual(completed.compactMap { $0.getPropertiesDict()["outcome"] as? String },
                       ["took_go", "took_go"])
        XCTAssertEqual(Set(completed.compactMap { $0.getPropertiesDict()["journey_id"] as? String }).count, 2,
                       "The waiting Journey and the new one each took go exactly once")
        await service.shutdown()
        await events.close()
    }

    /// The shared contract, replayed operation by operation.
    func testEarlyEventAdmissionVectors() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/sdk/early-event-admission.json")
        let vectors = try JSONDecoder().decode(
            EarlyEventVectors.self, from: Data(contentsOf: url)
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
                case "capture":
                    captured = (Self.event("trigger"), service.eventAdmissionGeneration())
                case "route-captured":
                    let route = try XCTUnwrap(captured, vector.name)
                    await service.handleEvent(route.event, admittedProfileGeneration: route.generation)
                default: XCTFail("\(vector.name): unknown operation \(operation)")
                }
                observed.append(starts(in: events))
            }
            XCTAssertEqual(observed, vector.expectedStarts, vector.name)
            await service.shutdown()
        }
    }

    /// The user changes while an event of the previous user is still being
    /// routed. The new user's copy must not start a Journey from it.
    func testEventNeverStartsAnotherCustomersJourney() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let waitingCopy = try await waitingCopy(fixture, entry: "start_waiting")
        let otherCopy = replacing(try await authenticatedSnapshot(fixture),
                                  entry: Self.eventEntry("go"),
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
                  steps: Self.waitForGoSteps, routes: [])
    }

    private static func eventEntry(_ name: String) -> JourneyEntryCondition {
        .init(type: .event, eventName: name, segmentId: nil, member: nil, condition: nil)
    }

    private static func event(_ name: String, at timestamp: Date = Date()) -> NuxieEvent {
        NuxieEvent(name: name, distinctId: "customer", timestamp: timestamp)
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

    private actor SwitchOnce {
        private(set) var claimed = false
        func claim() -> Bool {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    private struct EarlyEventVectors: Decodable {
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

    private func completions(in store: MockEventStore) -> [String] {
        store.storedEvents
            .filter { $0.name == JourneyEvents.journeyCompleted }
            .compactMap { $0.getPropertiesDict()["outcome"] as? String }
    }

    private func starts(in events: MockEventLog) -> Int {
        events.routedEvents.filter { $0.name == JourneyEvents.journeyStarted }.count
    }
}
