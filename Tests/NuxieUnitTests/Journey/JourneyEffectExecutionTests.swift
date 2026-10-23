import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class JourneyEffectExecutionTests: JourneyTestCase {
    func testOpenedLinkUsesTheSharedRunRecord() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/events/runtime-link-opened.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let record = try XCTUnwrap(fixture["record"] as? [String: Any])
        let properties = try XCTUnwrap(record["properties"] as? [String: Any])
        let snapshot = try await authenticatedSnapshot(JourneyPlaneProfileTestFixture.load())
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[arm.reference.descriptorSha256])
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let identityFence = try XCTUnwrap(identity.performWithCurrentIdentityFence("customer", { _ in () }))
        let fence = JourneyProfileFence()
        let events = MockEventLog()
        let dispatcher = JourneyEffectDispatcher(identity: identity, events: events)
        let request = JourneyDispatchRequest(runId: "run", journeyId: "journey", generation: 2,
            reference: .init(experienceId: "experience", versionId: "version", legId: "leg",
                descriptorSha256: arm.reference.descriptorSha256), release: release, stepId: "open",
            action: [:], context: .init(event: [:], responses: [:]), effectId: UUID().uuidString,
            distinctId: "customer", identityFence: identityFence.token, executionFence: fence,
            executionFenceToken: fence.token())
        let link = ExperienceRendererOpenLinkRequest(urlString: try XCTUnwrap(properties["url"] as? String),
            target: properties["target"] as? String, screenId: properties["screen_id"] as? String,
            instanceId: properties["instance_id"] as? String, destination: try XCTUnwrap(properties["destination"] as? String))
        let captured = await dispatcher.captureLinkOpened(link, request: request)
        XCTAssertTrue(captured)
        XCTAssertEqual(events.routedEvents.count, 1)
        let event = try XCTUnwrap(events.routedEvents.first)
        XCTAssertEqual(event.name, record["name"] as? String)
        XCTAssertEqual(NSDictionary(dictionary: event.properties), NSDictionary(dictionary: properties))
        let activity = try XCTUnwrap(ActivityCuration.activity(internalName: event.name, properties: event.properties))
        XCTAssertEqual(activity.wireName, "link_opened")
        XCTAssertEqual(activity.wireProperties["destination"], .string("in_app"))
        XCTAssertEqual(activity.wireProperties["url"], .string(link.urlString))
    }

    func testBufferedStartupEventWaitsForJournalRecovery() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = replacing(
            try await authenticatedSnapshot(JourneyPlaneProfileTestFixture.load()),
            entry: .init(type: .event, eventName: "startup_trigger", segmentId: nil, member: nil, condition: nil),
            reentry: .init(type: .everyMatch, window: nil)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let store = MockEventStore()
        let events = EventLog(identity: identity, dateProvider: MockDateProvider(),
                              apiClient: MockNuxieApi(), store: store)
        let service = JourneyService(
            identity: identity, events: events,
            dateProvider: MockDateProvider(), sleepProvider: MockSleepProvider(),
            journalDirectory: directory, featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            pinnedReleaseAuthenticator: { _, _ in throw JourneyExecutionError.invalidState },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed)
        )
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await events.subscribeCommitted { event in await service.handleStoredEvent(event) }
        events.track("startup_trigger")
        await service.prepareForEvents()
        let configuration = NuxieConfiguration(apiKey: "startup-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await events.configure(configuration: configuration)
        // Storage can accept the event, but only Journey recovery may release
        // it: an empty EventLog outbox says nothing about a warm journal.
        _ = await events.flushEvents()
        XCTAssertEqual(store.storedEvents.filter {
            $0.name == JourneyEvents.journeyStarted
        }.count, 0)
        await service.initialize()
        await events.drain()
        XCTAssertEqual(store.storedEvents.filter {
            $0.name == JourneyEvents.journeyStarted
        }.count, 1)
        await service.shutdown()
        await events.close()
    }

    func testWarmJournalOutboxIsStagedBeforeBufferedTriggerEffects() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = replacing(
            try await authenticatedSnapshot(JourneyPlaneProfileTestFixture.load()),
            entry: .init(type: .event, eventName: "startup_trigger", segmentId: nil, member: nil, condition: nil),
            reentry: .init(type: .everyMatch, window: nil)
        )
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        let retained = try await journal.admit(
            arm: XCTUnwrap(snapshot.profile.armedLegs.first),
            release: XCTUnwrap(snapshot.profile.releases.first),
            executionSnapshot: .init(delivery: snapshot.profile.delivery,
                                     assignments: snapshot.profile.facts.assignments),
            reentry: .init(type: .everyMatch, window: nil),
            entryStepId: "entry", at: Date(timeIntervalSince1970: 1_000)
        )
        let oldRun = try XCTUnwrap(retained)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let store = MockEventStore()
        let events = EventLog(identity: identity, dateProvider: MockDateProvider(),
                              apiClient: MockNuxieApi(), store: store)
        let service = JourneyService(
            identity: identity, events: events,
            dateProvider: MockDateProvider(), sleepProvider: MockSleepProvider(),
            journalDirectory: directory, featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            pinnedReleaseAuthenticator: { _, _ in throw JourneyExecutionError.invalidState },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed)
        )
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await events.subscribeCommitted { event in await service.handleStoredEvent(event) }
        events.track("startup_trigger")
        await service.prepareForEvents()
        let configuration = NuxieConfiguration(apiKey: "warm-outbox-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await events.configure(configuration: configuration)
        await service.initialize()
        await events.drain()
        let persisted = store.storedEvents
        let newerStart = try XCTUnwrap(persisted.firstIndex {
            $0.name == JourneyEvents.journeyStarted && $0.id != oldRun.startedEventId
        })
        XCTAssertLessThan(try XCTUnwrap(persisted.firstIndex { $0.id == oldRun.startedEventId }), newerStart)
        XCTAssertLessThan(try XCTUnwrap(persisted.firstIndex { $0.id == oldRun.completedEventId }), newerStart)
        await service.shutdown()
        await events.close()
    }

    func testRetainedRouteWaitsForAuthenticatedProfileOnProductionStartup() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: .init(type: .event, eventName: "retained_trigger", segmentId: nil, member: nil, condition: nil),
            reentry: .init(type: .everyMatch, window: nil)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let store = MockEventStore()
        let events = EventLog(identity: identity, dateProvider: MockDateProvider(),
                              apiClient: MockNuxieApi(), store: store)
        let retained = try StoredEvent(id: "retained-before-profile", name: "retained_trigger",
                                       properties: [:], timestamp: Date(), distinctId: "customer")
        _ = try await store.commitStableCaptureAndStageRoute(
            eventId: retained.id, event: retained, recordedAt: retained.timestamp,
            assigningCommitSequence: false, admission: nil
        )
        let service = JourneyService(
            identity: identity, events: events,
            dateProvider: MockDateProvider(), sleepProvider: MockSleepProvider(),
            journalDirectory: directory, storageScope: nil, featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            pinnedReleaseAuthenticator: { _, _ in throw JourneyExecutionError.invalidState },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed)
        )
        await events.deferCommittedRouting()
        await events.subscribeCommitted { event in await service.handleStoredEvent(event) }
        await service.prepareForEvents()
        let configuration = NuxieConfiguration(apiKey: "startup-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await events.configure(configuration: configuration)
        await service.initialize()
        events.track("newer-analytics")
        _ = await events.flushEvents()
        XCTAssertTrue(store.pendingStableRouteIds.contains(retained.id))
        XCTAssertFalse(store.storedEvents.contains { $0.name == JourneyEvents.journeyStarted })
        // Offline prefetch settles without authority: release live routing,
        // but keep the retained receipt for a later authenticated profile.
        await service.finishStartupRouting()
        await events.drain()
        XCTAssertTrue(store.pendingStableRouteIds.contains(retained.id))
        await service.profileDidCommit(snapshot, artifacts: nil,
                                       authority: fixture.deliveryAuthority,
                                       admissionGeneration: 1, distinctId: "customer")
        await events.drain()
        XCTAssertFalse(store.pendingStableRouteIds.contains(retained.id))
        XCTAssertEqual(store.storedEvents.filter { $0.name == JourneyEvents.journeyStarted }.count, 1)
        await service.shutdown()
        await events.close()
    }

    func testTriggerRightAfterIdentifyStartsFromTheArrivingCustomersProfile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = replacing(
            try await authenticatedSnapshot(JourneyPlaneProfileTestFixture.load()),
            entry: .init(type: .event, eventName: "signed_in_trigger", segmentId: nil, member: nil, condition: nil),
            reentry: .init(type: .everyMatch, window: nil)
        )
        let (identity, store, events, service) = try await settledCustomerA(directory: directory, snapshot: snapshot)

        // identify(B) once the SDK has settled: the transition runs before B's
        // profile arrives, and the app sends its trigger straight away.
        identity.setDistinctId("customer-b")
        await service.handleUserChange(from: "customer-a", to: "customer-b")
        events.track("signed_in_trigger")
        // Commit the trigger and route whatever may route now, before B's
        // profile arrives.
        _ = await events.flushEvents()
        _ = await events.drainCommittedRouting()
        XCTAssertEqual(startedJourneys(in: store, for: "customer-b"), 0)

        await service.profileDidCommit(snapshot, distinctId: "customer-b")
        await service.finishUserChangeRouting(to: "customer-b")
        await events.drain()
        XCTAssertEqual(startedJourneys(in: store, for: "customer-b"), 1)
        await service.shutdown()
        await events.close()
    }

    func testUserChangeWithoutAProfileReleasesRoutingAndKeepsTheJournalLive() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = replacing(
            try await authenticatedSnapshot(JourneyPlaneProfileTestFixture.load()),
            entry: .init(type: .event, eventName: "signed_in_trigger", segmentId: nil, member: nil, condition: nil),
            reentry: .init(type: .everyMatch, window: nil)
        )
        let (identity, store, events, service) = try await settledCustomerA(directory: directory, snapshot: snapshot)

        identity.setDistinctId("customer-b")
        await service.handleUserChange(from: "customer-a", to: "customer-b")
        events.track("signed_in_trigger")
        // B's profile refresh fails. Routing is released and B's journal
        // opens without a profile, so the held trigger starts nothing, as
        // after an offline startup.
        await service.finishUserChangeRouting(to: "customer-b")
        await events.drain()
        XCTAssertEqual(startedJourneys(in: store, for: "customer-b"), 0)

        // A profile that arrives later finds a healthy journal and live
        // routing: the next trigger starts.
        await service.profileDidCommit(snapshot, distinctId: "customer-b")
        events.track("signed_in_trigger")
        await events.drain()
        XCTAssertEqual(startedJourneys(in: store, for: "customer-b"), 1)
        await service.shutdown()
        await events.close()
    }

    func testIdentifyAfterTheCachedProfileStartsFromTheArrivingCustomersProfile() async throws {
        try await assertIdentifyDuringStartup(cachedProfileCommitsBeforeStartup: false)
    }

    func testIdentifyBeforeStartupStartsFromTheArrivingCustomersProfile() async throws {
        try await assertIdentifyDuringStartup(cachedProfileCommitsBeforeStartup: true)
    }

    func testTriggerRoutedBeforeTheTransitionStartsFromTheArrivingCustomersProfile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = replacing(
            try await authenticatedSnapshot(JourneyPlaneProfileTestFixture.load()),
            entry: .init(type: .event, eventName: "signed_in_trigger", segmentId: nil, member: nil, condition: nil),
            reentry: .init(type: .everyMatch, window: nil)
        )
        let (identity, store, events, service) = try await settledCustomerA(directory: directory, snapshot: snapshot)

        // identify(B); track(): the trigger routes before B's transition has
        // run, while A's journal and profile are still installed.
        identity.setDistinctId("customer-b")
        events.track("signed_in_trigger")
        _ = await events.flushEvents()
        _ = await events.drainCommittedRouting()
        XCTAssertEqual(startedJourneys(in: store, for: "customer-b"), 0)

        await service.handleUserChange(from: "customer-a", to: "customer-b")
        await service.profileDidCommit(snapshot, distinctId: "customer-b")
        await service.finishUserChangeRouting(to: "customer-b")
        let started = try await waitForStartedJourneys(1, in: store, for: "customer-b", events: events)
        XCTAssertEqual(started, 1)
        await service.shutdown()
        await events.close()
    }

    func testTriggerBeforeAnyProfileAuthorityStartsWithTheFirstProfile() async throws {
        // An offline first run: startup settled with no profile, so no
        // journal scope exists when the customer is identified.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: .init(type: .event, eventName: "signed_in_trigger", segmentId: nil, member: nil, condition: nil),
            reentry: .init(type: .everyMatch, window: nil)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("anonymous")
        let store = MockEventStore()
        let events = EventLog(identity: identity, dateProvider: MockDateProvider(),
                              apiClient: MockNuxieApi(), store: store)
        let service = JourneyService(
            identity: identity, events: events,
            dateProvider: MockDateProvider(), sleepProvider: MockSleepProvider(),
            journalDirectory: directory, storageScope: nil, featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            pinnedReleaseAuthenticator: { _, _ in throw JourneyExecutionError.invalidState },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed)
        )
        await subscribeLikeTheSDK(events, service)
        await service.prepareForEvents()
        let configuration = NuxieConfiguration(apiKey: "no-scope-identify-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await events.configure(configuration: configuration)
        await service.initialize()
        await service.finishStartupRouting()

        identity.setDistinctId("customer-b")
        await service.handleUserChange(from: "anonymous", to: "customer-b")
        events.track("signed_in_trigger")
        _ = await events.flushEvents()
        _ = await events.drainCommittedRouting()
        XCTAssertEqual(startedJourneys(in: store, for: "customer-b"), 0)

        await service.profileDidCommit(snapshot, artifacts: nil,
                                       authority: fixture.deliveryAuthority,
                                       admissionGeneration: 1, distinctId: "customer-b")
        await service.finishUserChangeRouting(to: "customer-b")
        let started = try await waitForStartedJourneys(1, in: store, for: "customer-b", events: events)
        XCTAssertEqual(started, 1)
        await service.shutdown()
        await events.close()
    }

    /// Waits a bounded time for routing to deliver, since drain() would never
    /// return if routing stayed held.
    private func waitForStartedJourneys(
        _ expected: Int, in store: MockEventStore, for distinctId: String, events: EventLog
    ) async throws -> Int {
        var started = 0
        for _ in 0..<100 {
            _ = await events.drainCommittedRouting()
            started = startedJourneys(in: store, for: distinctId)
            if started >= expected { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return started
    }

    func testAnUnsettledTransitionKeepsTheTriggerForTheProfileStillComing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = replacing(
            try await authenticatedSnapshot(JourneyPlaneProfileTestFixture.load()),
            entry: .init(type: .event, eventName: "signed_in_trigger", segmentId: nil, member: nil, condition: nil),
            reentry: .init(type: .everyMatch, window: nil)
        )
        let (identity, store, events, service) = try await settledCustomerA(directory: directory, snapshot: snapshot)

        identity.setDistinctId("customer-b")
        await service.handleUserChange(from: "customer-a", to: "customer-b")
        events.track("signed_in_trigger")
        _ = await events.flushEvents()
        _ = await events.drainCommittedRouting()
        // Every refresh was superseded: B's profile may still arrive, so the
        // transition finishes without opening B's journal without it.
        await service.finishUserChangeRouting(to: "customer-b", profileSettled: false)
        _ = await events.drainCommittedRouting()
        XCTAssertEqual(startedJourneys(in: store, for: "customer-b"), 0)

        // The newer refresh brings the profile: the kept trigger starts.
        await service.profileDidCommit(snapshot, distinctId: "customer-b")
        let started = try await waitForStartedJourneys(1, in: store, for: "customer-b", events: events)
        XCTAssertEqual(started, 1)
        await service.shutdown()
        await events.close()
    }

    func testAnObsoleteTransitionLeavesRoutingHeldForTheQueuedCustomer() async throws {
        // A fresh install starting up: routing is held until a journal opens.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MockIdentityService()
        identity.setDistinctId("anonymous")
        let store = MockEventStore()
        let events = EventLog(identity: identity, dateProvider: MockDateProvider(),
                              apiClient: MockNuxieApi(), store: store)
        let service = JourneyService(
            identity: identity, events: events,
            dateProvider: MockDateProvider(), sleepProvider: MockSleepProvider(),
            journalDirectory: directory, storageScope: nil, featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            pinnedReleaseAuthenticator: { _, _ in throw JourneyExecutionError.invalidState },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed)
        )
        let routed = RoutedEventNames()
        await subscribeLikeTheSDK(events, service) { name in await routed.append(name) }
        await service.prepareForEvents()
        let configuration = NuxieConfiguration(apiKey: "queued-identify-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await events.configure(configuration: configuration)
        await service.initialize()

        // identify(B), then identify(C): B's transition runs once the
        // identity is already C, so it must leave C's events held.
        identity.setDistinctId("customer-c")
        await service.handleUserChange(from: "anonymous", to: "customer-b")
        await service.finishUserChangeRouting(to: "customer-b")
        events.track("signed_in_trigger")
        _ = await events.flushEvents()
        _ = await events.drainCommittedRouting()
        let whileQueued = await routed.names
        XCTAssertFalse(whileQueued.contains("signed_in_trigger"))

        // C's own transition finishes (no profile came) and releases them.
        await service.handleUserChange(from: "customer-b", to: "customer-c")
        await service.finishUserChangeRouting(to: "customer-c")
        // The release reaches EventLog's route worker asynchronously. Poll
        // with a bound: drain() would never return if routing stayed held.
        var afterFinish: [String] = []
        for _ in 0..<100 where !afterFinish.contains("signed_in_trigger") {
            _ = await events.drainCommittedRouting()
            afterFinish = await routed.names
            if !afterFinish.contains("signed_in_trigger") {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        XCTAssertTrue(afterFinish.contains("signed_in_trigger"))
        await service.shutdown()
        await events.close()
    }

    /// The cached customer A, then identify(B) while the SDK is starting, in
    /// production mode: the storage scope comes from A's profile authority.
    private func assertIdentifyDuringStartup(
        cachedProfileCommitsBeforeStartup: Bool
    ) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: .init(type: .event, eventName: "signed_in_trigger", segmentId: nil, member: nil, condition: nil),
            reentry: .init(type: .everyMatch, window: nil)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = MockEventStore()
        let events = EventLog(identity: identity, dateProvider: MockDateProvider(),
                              apiClient: MockNuxieApi(), store: store)
        let service = JourneyService(
            identity: identity, events: events,
            dateProvider: MockDateProvider(), sleepProvider: MockSleepProvider(),
            journalDirectory: directory, storageScope: nil, featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            pinnedReleaseAuthenticator: { _, _ in throw JourneyExecutionError.invalidState },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed)
        )
        await subscribeLikeTheSDK(events, service)
        let configuration = NuxieConfiguration(apiKey: "startup-identify-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        if cachedProfileCommitsBeforeStartup {
            // A's cached profile and identify(B), with its transition, all
            // land before the SDK prepares its journal.
            await service.profileDidCommit(snapshot, artifacts: nil,
                                           authority: fixture.deliveryAuthority,
                                           admissionGeneration: 1, distinctId: "customer-a")
            identity.setDistinctId("customer-b")
            await service.handleUserChange(from: "customer-a", to: "customer-b")
            await service.prepareForEvents()
            try await events.configure(configuration: configuration)
            await service.initialize()
            // The startup profile fetch settles without B's profile (the
            // transition's refresh superseded it): routing stays held for B.
            await service.finishStartupRouting()
        } else {
            // A's cached profile goes live, then identify(B) lands before
            // initialize() and before its transition runs.
            await service.prepareForEvents()
            try await events.configure(configuration: configuration)
            await service.profileDidCommit(snapshot, artifacts: nil,
                                           authority: fixture.deliveryAuthority,
                                           admissionGeneration: 1, distinctId: "customer-a")
            identity.setDistinctId("customer-b")
            await service.initialize()
            await service.handleUserChange(from: "customer-a", to: "customer-b")
        }
        events.track("signed_in_trigger")
        _ = await events.flushEvents()
        _ = await events.drainCommittedRouting()
        XCTAssertEqual(startedJourneys(in: store, for: "customer-b"), 0)

        await service.profileDidCommit(snapshot, artifacts: nil,
                                       authority: fixture.deliveryAuthority,
                                       admissionGeneration: 2, distinctId: "customer-b")
        await events.drain()
        XCTAssertEqual(startedJourneys(in: store, for: "customer-b"), 1)
        XCTAssertEqual(startedJourneys(in: store, for: "customer-a"), 0)
        await service.shutdown()
        await events.close()
    }

    /// Customer A's profile and journal are live and EventLog routes freely,
    /// as once the SDK has settled after launch.
    private func settledCustomerA(
        directory: URL,
        snapshot: JourneyProfileCatalog.Snapshot
    ) async throws -> (MockIdentityService, MockEventStore, EventLog, JourneyService) {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = MockEventStore()
        let events = EventLog(identity: identity, dateProvider: MockDateProvider(),
                              apiClient: MockNuxieApi(), store: store)
        let service = JourneyService(
            identity: identity, events: events,
            dateProvider: MockDateProvider(), sleepProvider: MockSleepProvider(),
            journalDirectory: directory, featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            pinnedReleaseAuthenticator: { _, _ in throw JourneyExecutionError.invalidState },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed)
        )
        await service.profileDidCommit(snapshot, distinctId: "customer-a")
        await subscribeLikeTheSDK(events, service)
        await service.prepareForEvents()
        let configuration = NuxieConfiguration(apiKey: "user-change-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await events.configure(configuration: configuration)
        await service.initialize()
        await service.finishStartupRouting()
        await events.drain()
        return (identity, store, events, service)
    }

    /// Subscribes Journey the way NuxieSDK does: an acknowledging route, so
    /// an event Journey cannot handle yet stays pending for a retry.
    private func subscribeLikeTheSDK(
        _ events: EventLog,
        _ service: JourneyService,
        observe: (@Sendable (String) async -> Void)? = nil
    ) async {
        let reservation = events.reserveCommittedAdmission {
            service.eventAdmissionGeneration()
        }
        await events.subscribeAcknowledgingCommitted(reservation: reservation) { event, admitted in
            await observe?(event.name)
            return await service.handleStoredEvent(event, admittedProfileGeneration: admitted)
        }
    }

    private func startedJourneys(in store: MockEventStore, for distinctId: String) -> Int {
        store.storedEvents.filter {
            $0.name == JourneyEvents.journeyStarted && $0.distinctId == distinctId
        }.count
    }

    func testProfileChangesWaitForRetainedRouteRecovery() async throws {
        for change in ["replace", "withdraw", "clear", "clearAll"] {
            try await assertProfileChangeWaitsForRetainedRouteRecovery(change)
        }
    }

    private func assertProfileChangeWaitsForRetainedRouteRecovery(_ change: String) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try await authenticatedSnapshot(JourneyPlaneProfileTestFixture.load())
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        let service = makeService(identity: identity, events: events, directory: directory)
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await service.prepareForEvents()
        let retainedGeneration = service.eventAdmissionGeneration()
        let gate = JourneyNthRoutedCaptureGate(eventName: "replay", suspendedCall: 1)
        let replayStarted = expectation(description: "retained replay begins")
        events.replayPendingRoutesHandler = {
            replayStarted.fulfill()
            await gate.intercept(event: "replay")
            return true
        }
        let startup = Task { await service.initialize() }
        await fulfillment(of: [replayStarted], timeout: 2)
        let replacementCompleted = expectation(description: "replacement must wait")
        replacementCompleted.isInverted = true
        let replacement = Task {
            switch change {
            case "withdraw": await service.profileDidWithdraw(authority: nil, distinctId: "customer")
            case "clear": await service.profileDidClear(distinctId: "customer")
            case "clearAll": await service.profileDidClearAll()
            default: await service.profileDidCommit(snapshot, distinctId: "customer")
            }
            replacementCompleted.fulfill()
        }
        await fulfillment(of: [replacementCompleted], timeout: 0.2)
        XCTAssertEqual(service.eventAdmissionGeneration(), retainedGeneration,
                       "Retained routes must keep their admitted profile until recovery completes")
        await gate.release()
        await startup.value
        await replacement.value
        XCTAssertGreaterThan(service.eventAdmissionGeneration(), retainedGeneration)
        await service.shutdown()
    }

    func testFailedRecoveryReleasesRoutingAfterPrefetchAlreadySettled() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try await authenticatedSnapshot(JourneyPlaneProfileTestFixture.load())
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        let service = makeService(identity: identity, events: events, directory: directory)
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await service.prepareForEvents()
        events.replayPendingRoutesHandler = {
            await service.finishStartupRouting()
            return false
        }
        let routingResumed = expectation(description: "failed recovery releases live routing")
        events.resumeRoutingHandler = { routingResumed.fulfill() }
        await service.initialize()
        await fulfillment(of: [routingResumed], timeout: 0.2)
        await service.shutdown()
    }

    func testInitializationRetriesJoinedFailedJournalRecovery() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = try await authenticatedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        let gate = JourneyNthRoutedCaptureGate(eventName: "replay", suspendedCall: 1)
        let replayStarted = expectation(description: "first recovery begins")
        replayStarted.assertForOverFulfill = false
        events.replayPendingRoutesHandler = {
            replayStarted.fulfill()
            await gate.intercept(event: "replay")
            return await gate.observationCount() > 1
        }
        let service = makeService(identity: identity, events: events,
                                  directory: directory, storageScope: nil)
        await service.prepareForEvents()
        let profile = Task {
            await service.profileDidCommit(snapshot, artifacts: nil,
                                           authority: fixture.deliveryAuthority,
                                           admissionGeneration: 1, distinctId: "customer")
        }
        await fulfillment(of: [replayStarted], timeout: 2)
        let startupCompleted = expectation(description: "startup joins active recovery")
        startupCompleted.isInverted = true
        let startup = Task {
            await service.initialize()
            startupCompleted.fulfill()
        }
        await fulfillment(of: [startupCompleted], timeout: 0.2)
        await gate.release()
        await profile.value
        await startup.value
        let recoveryCount = await gate.observationCount()
        XCTAssertEqual(recoveryCount, 2, "A failed joined operation must not masquerade as a recovered journal")
        await service.shutdown()
    }

    func testInitializationJoinsCachedProfileJournalRecovery() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = try await authenticatedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        let gate = JourneyNthRoutedCaptureGate(eventName: "replay", suspendedCall: 1)
        let replayStarted = expectation(description: "profile starts journal recovery")
        replayStarted.assertForOverFulfill = false
        events.replayPendingRoutesHandler = {
            replayStarted.fulfill()
            await gate.intercept(event: "replay")
            return true
        }
        let service = makeService(identity: identity, events: events,
                                  directory: directory, storageScope: nil)
        await service.prepareForEvents()
        let profile = Task {
            await service.profileDidCommit(snapshot, artifacts: nil,
                                           authority: fixture.deliveryAuthority,
                                           admissionGeneration: 1, distinctId: "customer")
        }
        await fulfillment(of: [replayStarted], timeout: 2)
        let startup = Task { await service.initialize() }
        await gate.release()
        await profile.value
        await startup.value
        let recoveryCount = await gate.observationCount()
        XCTAssertEqual(recoveryCount, 1, "Initialization must join the profile's recovery, including a just-completed recovery")
        await service.shutdown()
    }

    func testSendEventRoutesTheDurableCaptureToCommittedSubscribers() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = try await authenticatedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let identityFence = try XCTUnwrap(identity.performWithCurrentIdentityFence(
            "customer",
            { _ in () }
        ))
        let executionFence = JourneyProfileFence()
        let executionGeneration = executionFence.advance()
        let executionFenceToken = try XCTUnwrap(executionFence.token(
            ifCurrent: executionGeneration
        ))
        let events = CaptureOnlyJourneyEvents()
        let dispatcher = JourneyEffectDispatcher(
            identity: identity,
            events: events
        )

        let result = await dispatcher.dispatch(.init(
            runId: "journey:0",
            journeyId: "journey",
            generation: 0,
            reference: arm.reference,
            release: release,
            stepId: "send",
            action: [
                "type": .string("send_event"),
                "eventName": .string("inventory_checked"),
            ],
            context: .init(event: [:], responses: [:]),
            effectId: "00000000-0000-7000-8000-000000000203",
            distinctId: "customer",
            identityFence: identityFence.token,
            executionFence: executionFence,
            executionFenceToken: executionFenceToken
        ))

        XCTAssertEqual(result, .outlet("next"))
        let routedNames = await events.routedNames()
        XCTAssertEqual(routedNames, ["inventory_checked"])
    }

    func testDurableEventEffectsDoNotCommitAcrossExecutionRevocation() async throws {
        let cases: [(action: [String: JourneyReleaseJSONValue], id: String)] = [
            (
                action: [
                    "type": .string("send_event"),
                    "eventName": .string("inventory_checked"),
                ],
                id: "00000000-0000-7000-8000-000000000211"
            ),
            (
                action: [
                    "type": .string("app_action"),
                    "name": .string("open_inventory"),
                ],
                id: "00000000-0000-7000-8000-000000000213"
            ),
        ]

        for fixture in cases {
            try await assertDurableEventCommitIsRejected(
                action: fixture.action,
                effectId: fixture.id,
                revocation: .execution
            )
        }
    }

    func testDurableEventEffectDoesNotCommitAcrossIdentityRevocation() async throws {
        try await assertDurableEventCommitIsRejected(
            action: [
                "type": .string("send_event"),
                "eventName": .string("inventory_checked"),
            ],
            effectId: "00000000-0000-7000-8000-000000000214",
            revocation: .identity
        )
    }

    func testLocalEffectIsClaimedBeforeDispatchAndAdvancesItsSelectedOutlet() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let effect = Journey.Step(
            kind: .action,
            id: "effect",
            action: ["type": .string("submit_response")],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = Journey.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "effect",
            steps: [effect, complete]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let dispatcher = InspectingJourneyDispatcher(
            directory: directory,
            distinctId: "customer"
        )
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dispatcher: dispatcher
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        let dispatchedRequest = await dispatcher.onlyRequest()
        let request = try XCTUnwrap(dispatchedRequest)
        XCTAssertEqual(request.stepId, "effect")
        XCTAssertFalse(request.effectId.isEmpty)
        let observedDurableClaim = await dispatcher.observedDurableClaim()
        XCTAssertTrue(observedDurableClaim)
        XCTAssertEqual(
            events.routedEvents.map(\.name).filter {
                $0 == JourneyEvents.journeyStarted
                    || $0 == JourneyEvents.journeyCompleted
            },
            [JourneyEvents.journeyStarted, JourneyEvents.journeyCompleted]
        )
        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "continue"
        )
    }

    func testSendEventResolvesLegContextAndCompletesAfterDurableCapture() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let eventField: [String: JourneyReleaseJSONValue] = [
            "key": .string("sku"),
            "type": .string("string"),
            "required": .bool(true),
        ]
        let send = Journey.Step(
            kind: .action,
            id: "send",
            action: [
                "type": .string("send_event"),
                "eventName": .string("inventory_checked"),
                "payload": .object([
                    "sku": .object([
                        "type": .string("Event.Field"),
                        "key": .string("sku"),
                    ]),
                ]),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = Journey.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: .init(
                type: .event,
                eventName: "check_inventory",
                segmentId: nil,
                member: nil,
                condition: nil
            ),
            reentry: .init(type: .everyMatch, window: nil),
            inputs: .init(eventFields: [eventField], responseFields: []),
            entryStepId: "send",
            steps: [send, complete]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await service.handleStoredEvent(NuxieEvent(
            id: "00000000-0000-7000-8000-000000000201",
            name: "check_inventory",
            distinctId: "customer",
            properties: ["sku": "pro", "ignored": true],
            timestamp: Date(timeIntervalSince1970: 1_001)
        ))

        let authored = try XCTUnwrap(events.routedEvents.first {
            $0.name == "inventory_checked"
        })
        XCTAssertEqual(authored.properties["sku"] as? String, "pro")
        XCTAssertNil(authored.properties["ignored"])
        XCTAssertNotNil(authored.properties["journey_id"] as? String)
        XCTAssertEqual(
            authored.properties["experience_id"] as? String,
            "experience_golden"
        )
        XCTAssertEqual(
            authored.properties["leg_id"] as? String,
            snapshot.profile.armedLegs[0].reference.legId
        )
        XCTAssertEqual(authored.properties["leg_generation"] as? Int, 0)
        let origin = try XCTUnwrap(authored.journeyOrigin)
        XCTAssertEqual(origin.journeyId, authored.properties["journey_id"] as? String)
        XCTAssertEqual(origin.experienceId, "experience_golden")
        XCTAssertEqual(origin.versionId, snapshot.profile.armedLegs[0].reference.versionId)
        XCTAssertEqual(origin.legId, snapshot.profile.armedLegs[0].reference.legId)
        XCTAssertEqual(origin.generation, 0)
        XCTAssertEqual(origin.source, .deviceAction)
        XCTAssertEqual(origin.occurrenceId, authored.id)
        XCTAssertFalse(try XCTUnwrap(origin.stepId).isEmpty)

        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "continue"
        )
    }

    func testExitCompletesWithTheAuthoredOutcomeWithoutAnOutlet() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let exit = Journey.Step(
            kind: .action,
            id: "exit",
            action: [
                "type": .string("exit"),
                "reason": .string("opted_out"),
            ],
            outlets: [:],
            outcome: nil
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            completionOutputs: [:],
            entryStepId: "exit",
            steps: [exit]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "opted_out"
        )
        let journal = try await CustomerJourneyStore(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        XCTAssertTrue(runs.isEmpty)
    }

    func testExitWithAnEmptyReasonUsesTheDefaultCompletedOutcome() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let exit = Journey.Step(
            kind: .action,
            id: "exit",
            action: [
                "type": .string("exit"),
                "reason": .string(""),
            ],
            outlets: [:],
            outcome: nil
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            completionOutputs: [:],
            entryStepId: "exit",
            steps: [exit]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "completed"
        )
        let journal = try await CustomerJourneyStore(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        XCTAssertTrue(runs.isEmpty)
    }

    func testLocalEffectsResolveContextWithoutResponseSessionSynchronization() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let eventField: [String: JourneyReleaseJSONValue] = [
            "key": .string("sku"),
            "type": .string("string"),
            "required": .bool(true),
        ]
        let eventValue: JourneyReleaseJSONValue = .object([
            "type": .string("Event.Field"),
            "key": .string("sku"),
        ])
        let steps = [
            Journey.Step(
                kind: .action,
                id: "update",
                action: [
                    "type": .string("update_customer"),
                    "attributes": .object(["plan": eventValue]),
                ],
                outlets: ["next": "submit"],
                outcome: nil
            ),
            Journey.Step(
                kind: .action,
                id: "submit",
                action: ["type": .string("submit_response")],
                outlets: ["next": "app-action"],
                outcome: nil
            ),
            Journey.Step(
                kind: .action,
                id: "app-action",
                action: [
                    "type": .string("app_action"),
                    "name": .string("open_inventory"),
                    "payload": .object(["sku": eventValue]),
                ],
                outlets: ["next": "report"],
                outcome: nil
            ),
            Journey.Step(
                kind: .complete,
                id: "report",
                action: nil,
                outlets: nil,
                outcome: "continue"
            ),
        ]
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: .init(
                type: .event,
                eventName: "check_inventory",
                segmentId: nil,
                member: nil,
                condition: nil
            ),
            reentry: .init(type: .everyMatch, window: nil),
            inputs: .init(eventFields: [eventField], responseFields: []),
            entryStepId: "update",
            steps: steps
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let appActions = await MainActor.run { JourneyAppActionRecorder() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dispatcher: JourneyEffectDispatcher(
                identity: identity,
                events: events,
                appActionHandler: { action in appActions.record(action) }
            )
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await service.handleStoredEvent(NuxieEvent(
            id: "00000000-0000-7000-8000-000000000202",
            name: "check_inventory",
            distinctId: "customer",
            properties: ["sku": "pro"],
            timestamp: Date(timeIntervalSince1970: 1_002)
        ))

        XCTAssertEqual(identity.getUserProperties()["plan"] as? String, "pro")
        XCTAssertEqual(
            events.routedEvents.map(\.name),
            [
                JourneyEvents.journeyStarted,
                JourneyEvents.customerUpdated,
                JourneyEvents.appActionRequested,
                JourneyEvents.journeyCompleted,
            ],
            "submit_response must remain a local cursor advance"
        )
        let customerUpdated = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.customerUpdated
        })
        XCTAssertEqual(
            customerUpdated.properties["attributes_updated"] as? [String],
            ["plan"]
        )
        XCTAssertEqual(
            customerUpdated.properties["leg_id"] as? String,
            snapshot.profile.armedLegs[0].reference.legId
        )
        let deliveredAction = await MainActor.run { appActions.onlyAction() }
        let action = try XCTUnwrap(deliveredAction)
        XCTAssertEqual(action.name, "open_inventory")
        XCTAssertEqual(action.payload?["sku"], .string("pro"))
        XCTAssertEqual(action.experience.experienceId, "experience_golden")
        XCTAssertEqual(action.experience.experienceVersion, snapshot.profile.armedLegs[0].reference.versionId)
        XCTAssertEqual(
            action.experience.journeyId,
            customerUpdated.properties["journey_id"] as? String
        )
        let appActionRequested = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.appActionRequested
        })
        XCTAssertEqual(appActionRequested.properties["name"] as? String, "open_inventory")
        XCTAssertEqual(
            (appActionRequested.properties["payload"] as? [String: String])?["sku"],
            "pro"
        )
        XCTAssertEqual(
            appActionRequested.properties["leg_generation"] as? Int,
            0
        )
    }

    func testAppActionDoesNotPublishAcrossAnIdentityFenceChange() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let action = Journey.Step(
            kind: .action,
            id: "app-action",
            action: [
                "type": .string("app_action"),
                "name": .string("open_inventory"),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let report = Journey.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "app-action",
            steps: [action, report]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        identity.changeDistinctIdAfterNextFencedWork(to: "replacement")
        let events = MockEventLog()
        events.identity = identity
        let appActions = await MainActor.run { JourneyAppActionRecorder() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dispatcher: JourneyEffectDispatcher(
                identity: identity,
                events: events,
                appActionHandler: { value in appActions.record(value) }
            )
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        let delivered = await MainActor.run { appActions.onlyAction() }
        XCTAssertNil(delivered)
        XCTAssertFalse(events.routedEvents.contains {
            $0.name == JourneyEvents.appActionRequested
        })
        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "abandoned"
        )
    }

    func testAdmittedAppActionCompletesAcrossProfileRevalidation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let action = Journey.Step(
            kind: .action,
            id: "app-action",
            action: [
                "type": .string("app_action"),
                "name": .string("open_inventory"),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let report = Journey.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "app-action",
            steps: [action, report]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let appActions = await MainActor.run { JourneyAppActionRecorder() }
        let suspended = SuspendedJourneyDispatcher(
            underlying: JourneyEffectDispatcher(
                identity: identity,
                events: events,
                appActionHandler: { value in appActions.record(value) }
            )
        )
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dispatcher: suspended
        )

        await service.initialize()
        let firstCommit = Task {
            await service.profileDidCommit(snapshot, distinctId: "customer")
        }
        await suspended.waitUntilEntered()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await suspended.resume()
        await firstCommit.value

        let delivered = await MainActor.run { appActions.onlyAction() }
        XCTAssertEqual(delivered?.name, "open_inventory")
        XCTAssertTrue(events.routedEvents.contains {
            $0.name == JourneyEvents.appActionRequested
        })
        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "continue"
        )
    }

    func testCanonicalForegroundArmCompletesOnceAcrossProfileRevalidation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            reentry: .init(type: .everyMatch, window: nil)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let now = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1_000))
        let service = JourneyService(
            identity: identity,
            events: events,
            dateProvider: now,
            sleepProvider: MockSleepProvider(),
            journalDirectory: directory,
            featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(
                identity: identity,
                events: events
            ),
            pinnedReleaseAuthenticator: {
                _, _ in throw JourneyExecutionError.invalidState
            },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed),
            currentDeviceTimezone: TimeZone(secondsFromGMT: 0)!
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertEqual(
            events.routedEvents.map(\.name).filter {
                $0 == JourneyEvents.journeyStarted
                    || $0 == JourneyEvents.journeyCompleted
            },
            [JourneyEvents.journeyStarted, JourneyEvents.journeyCompleted]
        )
        let journal = try await CustomerJourneyStore(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        XCTAssertTrue(runs.isEmpty)
        let mark = try await journal.checkmark(experienceId: "experience_golden")
        XCTAssertEqual(mark?.outcome, "continue")
    }

    func testProfileArmedInBackgroundStartsWhenForegroundLatchOpens() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = try await authenticatedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = JourneyService(
            identity: identity,
            events: events,
            dateProvider: MockDateProvider(),
            sleepProvider: MockSleepProvider(),
            journalDirectory: directory,
            featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(
                identity: identity,
                events: events
            ),
            pinnedReleaseAuthenticator: {
                _, _ in throw JourneyExecutionError.invalidState
            },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed),
            currentDeviceTimezone: TimeZone(secondsFromGMT: 0)!
        )

        await service.initialize()
        await service.onAppDidEnterBackground()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        XCTAssertTrue(events.routedEvents.isEmpty)

        await service.onAppWillEnterForeground()
        XCTAssertTrue(events.routedEvents.isEmpty)

        await service.onAppBecameActive()

        XCTAssertEqual(
            events.routedEvents.map(\.name).filter {
                $0 == JourneyEvents.journeyStarted
                    || $0 == JourneyEvents.journeyCompleted
            },
            [JourneyEvents.journeyStarted, JourneyEvents.journeyCompleted]
        )
    }
}

private actor RoutedEventNames {
    private(set) var names: [String] = []

    func append(_ name: String) {
        names.append(name)
    }
}
