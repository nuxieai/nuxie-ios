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
        let waitsForGo = Self.waitForGoSteps
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

    // MARK: - Helpers

    private static func eventEntry(_ name: String) -> JourneyEntryCondition {
        .init(type: .event, eventName: name, segmentId: nil, member: nil, condition: nil)
    }

    private static func event(
        _ name: String,
        id: String = UUID.v7().uuidString,
        at timestamp: Date = Date()
    ) -> NuxieEvent {
        NuxieEvent(id: id, name: name, distinctId: "customer", timestamp: timestamp)
    }

    private static var waitForGoSteps: [Journey.Step] {
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
                    "maxTimeMs": .number(60_000),
                ],
                outlets: ["satisfied": "took_go", "timeout": "timed_out"],
                outcome: nil
            ),
            .init(kind: .complete, id: "took_go", action: nil, outlets: nil, outcome: "took_go"),
            .init(kind: .complete, id: "timed_out", action: nil, outlets: nil, outcome: "timed_out"),
        ]
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
