import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ActivityForwardingPipelineTests: XCTestCase {
    func testHostDismissalForwardsHostReason() async {
        let now = Date()
        let capture = CommittedCapture(
            canonicalName: JourneyEvents.experienceDismissed,
            event: NuxieEvent(
                id: "host-dismissal-1",
                name: JourneyEvents.experienceDismissed,
                distinctId: "user-1",
                properties: [
                    "experience_id": "experience-1",
                    "experience_version": "v1",
                    "journey_id": "journey-1",
                    "reason": "host",
                ],
                timestamp: now
            ),
            occurredAt: now,
            receivedAt: now
        )

        let activity = await ActivityForwardingPipeline().activity(for: capture)

        guard case .experienceDismissed(_, reason: .host) = activity else {
            return XCTFail("expected a host-attributed dismissal activity")
        }
    }

    func testScriptedJourneyActivitiesPreserveRequiredCaptureOrder() async throws {
        let store = MockEventStore()
        let log = makeEventLog(store: store)
        let recorder = CommittedCaptureRecorder()
        await log.subscribeCommitted(when: { true }) { capture in
            await recorder.append(capture)
        }
        try await log.configure(configuration: NuxieConfiguration(apiKey: "test-api-key"))

        let experience: [String: Any] = [
            "experience_id": "exp-1",
            "experience_version": "v1",
            "journey_id": "journey-1",
        ]
        log.track(
            JourneyEvents.experienceShown,
            properties: experience,
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
        log.track(
            JourneyEvents.experimentExposure,
            properties: experience.merging([
                "experiment_key": "pricing",
                "variant_key": "control",
                "is_holdout": false,
            ]) { _, replacement in replacement },
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
        _ = await log.captureSystemEvent(
            SystemEventNames.purchaseCompleted,
            properties: [
                "product_id": "pro",
                "store_product_id": "com.example.pro",
                "test_store": false,
            ],
            eventId: "purchase-completed-1",
            distinctId: "user-1"
        )
        _ = await log.captureSystemEvent(
            SystemEventNames.purchaseSynced,
            properties: [
                "transaction_id": "tx-1",
                "product_id": "pro",
            ],
            eventId: "purchase-synced-1",
            distinctId: "user-1"
        )
        log.track(
            JourneyEvents.experienceDismissed,
            properties: experience.merging(["reason": "purchase"]) {
                _, replacement in replacement
            },
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
        log.track(
            JourneyEvents.journeyExited,
            properties: ["journey_id": "journey-1", "reason": "cancelled"],
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
        await log.drain()

        let orderedCaptures = await recorder.values
        let pipeline = ActivityForwardingPipeline()
        var names: [String] = []
        for capture in orderedCaptures {
            if let activity = await pipeline.activity(for: capture) {
                names.append(activity.wireName)
            }
        }
        XCTAssertEqual(names, [
            "experience_shown",
            "experiment_exposure",
            "purchase_completed",
            "purchase_synced",
            "experience_dismissed",
            "journey_ended",
        ])
        await log.close()
    }

    func testTransientPermissionAnnounceReachesSubscribers() async throws {
        let store = MockEventStore()
        let log = makeEventLog(store: store)
        let recorder = CommittedCaptureRecorder()
        await log.subscribeCommitted(when: { true }) { capture in
            await recorder.append(capture)
        }
        try await log.configure(configuration: NuxieConfiguration(apiKey: "test-api-key"))

        // Permission resolutions are transient (never history-persisted);
        // the explicit announce is their only route to forwarding.
        await log.announceTransientActivity(
            canonicalName: SystemEventNames.notificationsEnabled,
            event: NuxieEvent(
                name: SystemEventNames.notificationsEnabled,
                distinctId: "customer-a",
                properties: ["journey_id": "journey-1"]
            )
        )

        await log.drain()
        var names: [String] = []
        for _ in 0..<50 {
            names = await recorder.values.map(\.canonicalName)
            if names.contains(SystemEventNames.notificationsEnabled) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let allCaptures = await recorder.values.map(\.canonicalName)
        XCTAssertTrue(
            names.contains(SystemEventNames.notificationsEnabled),
            "captures=\(allCaptures) stored=\(store.storedEvents.map(\.name))"
        )
        XCTAssertTrue(store.storedEvents.isEmpty, "transient announce must not persist")
    }

    func testUnknownJourneySummaryDoesNotForward() async {
        let now = Date()
        let capture = CommittedCapture(
            canonicalName: JourneyEvents.journeyExited,
            event: NuxieEvent(
                id: "unknown-journey-exit",
                name: JourneyEvents.journeyExited,
                distinctId: "user-1",
                properties: ["journey_id": "unknown", "reason": "cancelled"],
                timestamp: now
            ),
            occurredAt: now,
            receivedAt: now
        )

        let activity = await ActivityForwardingPipeline().activity(for: capture)

        XCTAssertNil(activity)
    }

    func testDurableCommitLanePreventsLaterCaptureFromOvertakingSlowStableInsert() async throws {
        let store = MockEventStore()
        store.stableCaptureDelayNanoseconds = 100_000_000
        let log = makeEventLog(store: store)
        let recorder = CommittedCaptureRecorder()
        await log.subscribeCommitted(when: { true }) { capture in
            await recorder.append(capture)
        }
        try await log.configure(configuration: NuxieConfiguration(apiKey: "test-api-key"))

        let slowCapture = Task {
            await log.captureSystemEvent(
                SystemEventNames.purchaseCompleted,
                properties: [
                    "product_id": "pro",
                    "store_product_id": "com.example.pro",
                    "test_store": false,
                ],
                eventId: "slow-stable",
                distinctId: "user-1"
            )
        }
        while store.stableCaptureCommitCallCount == 0 { await Task.yield() }
        log.track(
            SystemEventNames.appOpened,
            properties: nil,
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
        _ = await slowCapture.value
        await log.drain()

        let delayedCaptures = await recorder.values
        let capturedNames = delayedCaptures.map(\.canonicalName)
        XCTAssertEqual(capturedNames, [
            SystemEventNames.purchaseCompleted,
            SystemEventNames.appOpened,
        ])
        await log.close()
    }

    func testBeforeSendDropSuppressesCommitAndRenameKeepsCanonicalCase() async throws {
        let store = MockEventStore()
        let log = makeEventLog(store: store)
        let recorder = CommittedCaptureRecorder()
        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        configuration.beforeSend = { event in
            if event.name == JourneyEvents.experienceTimedOut { return nil }
            guard event.name == JourneyEvents.experienceShown else { return event }
            return NuxieEvent(
                id: event.id,
                name: "host_renamed_event",
                distinctId: event.distinctId,
                properties: event.properties,
                timestamp: event.timestamp
            )
        }
        await log.subscribeCommitted(when: { true }) { capture in
            await recorder.append(capture)
        }
        try await log.configure(configuration: configuration)

        let properties: [String: Any] = [
            "experience_id": "exp-1",
            "experience_version": "v1",
            "journey_id": "journey-1",
        ]
        log.track(
            JourneyEvents.experienceShown,
            properties: properties,
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
        log.track(
            JourneyEvents.experienceTimedOut,
            properties: properties,
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
        await log.drain()

        let captures = await recorder.values
        XCTAssertEqual(captures.count, 1)
        let capture = try XCTUnwrap(captures.first)
        XCTAssertEqual(capture.canonicalName, JourneyEvents.experienceShown)
        XCTAssertEqual(capture.event.name, "host_renamed_event")
        guard case .experienceShown = ActivityCuration.activity(
            canonicalName: capture.canonicalName,
            properties: capture.event.properties
        ) else {
            return XCTFail("renamed committed capture lost its canonical activity case")
        }
        XCTAssertFalse(store.storedEvents.contains {
            $0.name == JourneyEvents.experienceTimedOut
        })
        await log.close()
    }

    func testBeforeSendDropSuppressesServerFactForwardingButNotCommitOrRouting() async throws {
        let store = MockEventStore()
        let log = makeEventLog(store: store)
        let recorder = CommittedCaptureRecorder()
        let journeyService = MockJourneyService()
        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        configuration.beforeSend = { _ in nil }
        await log.subscribeCommitted(when: { true }) { capture in
            await recorder.append(capture)
        }
        await log.subscribeCommitted { event in
            await journeyService.handleEvent(event)
        }
        try await log.configure(configuration: configuration)

        let fact = JourneyDownFact(
            id: "conversion-drop",
            event: .converted,
            timestamp: Date(timeIntervalSince1970: 1_900_000_100),
            properties: JourneyConvertedProperties(
                journeyId: "journey-drop",
                at: Date(timeIntervalSince1970: 1_900_000_090),
                sourceFactRef: "source-drop"
            )
        )
        await log.commitServerFacts([fact], distinctId: "user-1")
        await log.drain()

        let captures = await recorder.values
        XCTAssertTrue(captures.isEmpty, "beforeSend nil must suppress host forwarding")
        let stored = try XCTUnwrap(store.storedEvents.first { $0.id == fact.id })
        XCTAssertEqual(stored.name, JourneyEvents.journeyConverted)
        let handled = await journeyService.handledEvents.filter { $0.id == fact.id }
        XCTAssertEqual(handled.count, 1)
        XCTAssertEqual(handled.first?.name, JourneyEvents.journeyConverted)
        await log.close()
    }

    func testBeforeSendRenameDoesNotChangeCanonicalServerFactRouting() async throws {
        let store = MockEventStore()
        let log = makeEventLog(store: store)
        let recorder = CommittedCaptureRecorder()
        let journeyService = MockJourneyService()
        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        configuration.beforeSend = { event in
            NuxieEvent(
                id: event.id,
                name: "host_renamed_conversion",
                distinctId: "hijacked-user",
                properties: ["journey_id": "hijacked-journey"],
                timestamp: event.timestamp.addingTimeInterval(60)
            )
        }
        await log.subscribeCommitted(when: { true }) { capture in
            await recorder.append(capture)
        }
        await log.subscribeCommitted { event in
            await journeyService.handleEvent(event)
        }
        try await log.configure(configuration: configuration)

        let fact = JourneyDownFact(
            id: "conversion-rename",
            event: .converted,
            timestamp: Date(timeIntervalSince1970: 1_900_000_200),
            properties: JourneyConvertedProperties(
                journeyId: "journey-rename",
                at: Date(timeIntervalSince1970: 1_900_000_190),
                sourceFactRef: "source-rename"
            )
        )
        await log.commitServerFacts([fact], distinctId: "user-1")
        await log.drain()

        let stored = try XCTUnwrap(store.storedEvents.first { $0.id == fact.id })
        XCTAssertEqual(stored.name, JourneyEvents.journeyConverted)
        XCTAssertEqual(stored.distinctId, "user-1")
        XCTAssertEqual(
            stored.getPropertiesDict()["journey_id"] as? String,
            "journey-rename"
        )
        let handled = await journeyService.handledEvents.filter { $0.id == fact.id }
        XCTAssertEqual(handled.count, 1)
        XCTAssertEqual(handled.first?.name, JourneyEvents.journeyConverted)
        XCTAssertEqual(handled.first?.distinctId, "user-1")
        XCTAssertEqual(
            handled.first?.properties["journey_id"] as? String,
            "journey-rename"
        )
        let captures = await recorder.values
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.canonicalName, JourneyEvents.journeyConverted)
        XCTAssertEqual(captures.first?.event.name, JourneyEvents.journeyConverted)
        await log.close()
    }

    func testStableCaptureAndServerFactEmitExactlyOnceWithCorrectTimes() async throws {
        let store = MockEventStore()
        let receivedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let dateProvider = MockDateProvider(initialDate: receivedAt)
        let log = makeEventLog(store: store, dateProvider: dateProvider)
        let recorder = CommittedCaptureRecorder()
        await log.subscribeCommitted(when: { true }) { capture in
            await recorder.append(capture)
        }
        try await log.configure(configuration: NuxieConfiguration(apiKey: "test-api-key"))

        let purchaseProperties: [String: Any] = [
            "product_id": "product-1",
            "store_product_id": "store.product.1",
            "test_store": false,
        ]
        _ = await log.captureSystemEvent(
            SystemEventNames.purchaseCompleted,
            properties: purchaseProperties,
            eventId: "purchase-event-1",
            distinctId: "user-1"
        )
        _ = await log.captureSystemEvent(
            SystemEventNames.purchaseCompleted,
            properties: purchaseProperties,
            eventId: "purchase-event-1",
            distinctId: "user-1"
        )

        let convertedAt = Date(timeIntervalSince1970: 1_900_000_000)
        let factTimestamp = Date(timeIntervalSince1970: 1_900_000_001)
        let fact = JourneyDownFact(
            id: "conversion-fact-1",
            event: .converted,
            timestamp: factTimestamp,
            properties: JourneyConvertedProperties(
                journeyId: "journey-1",
                at: convertedAt,
                sourceFactRef: "purchase-event-1"
            )
        )
        await log.commitServerFacts([fact, fact], distinctId: "user-1")
        await log.drain()

        let captures = await recorder.values
        XCTAssertEqual(captures.filter {
            $0.canonicalName == SystemEventNames.purchaseCompleted
        }.count, 1)
        let conversion = try XCTUnwrap(captures.first {
            $0.canonicalName == JourneyEvents.journeyConverted
        })
        XCTAssertEqual(conversion.occurredAt, convertedAt)
        XCTAssertEqual(conversion.receivedAt, receivedAt)
        XCTAssertEqual(conversion.event.timestamp, factTimestamp)
        XCTAssertEqual(captures.filter {
            $0.canonicalName == JourneyEvents.journeyConverted
        }.count, 1)
        await log.close()
    }

    func testServerFactDeduplicationPersistsAcrossLogsAndIncludesGoal() async throws {
        let store = MockEventStore()
        let firstLog = makeEventLog(store: store)
        let firstRecorder = CommittedCaptureRecorder()
        await firstLog.subscribeCommitted(when: { true }) { capture in
            await firstRecorder.append(capture)
        }
        try await firstLog.configure(configuration: NuxieConfiguration(apiKey: "test-api-key"))

        let original = JourneyDownFact(
            id: "conversion-goal-a-1",
            event: .converted,
            timestamp: Date(timeIntervalSince1970: 1_900_000_010),
            properties: JourneyConvertedProperties(
                journeyId: "journey-1",
                at: Date(timeIntervalSince1970: 1_900_000_000),
                sourceFactRef: "purchase-1",
                goal: AnyCodable(["kind": "event", "name": "checkout"])
            )
        )
        await firstLog.commitServerFacts([original], distinctId: "user-1")
        await firstLog.drain()
        let firstCaptures = await firstRecorder.values
        XCTAssertEqual(firstCaptures.count, 1)
        await firstLog.close()

        store.isClosed = false
        let secondLog = makeEventLog(store: store)
        let secondRecorder = CommittedCaptureRecorder()
        await secondLog.subscribeCommitted(when: { true }) { capture in
            await secondRecorder.append(capture)
        }
        try await secondLog.configure(configuration: NuxieConfiguration(apiKey: "test-api-key"))

        let redeliveredSameGoal = JourneyDownFact(
            id: "conversion-goal-a-2",
            event: .converted,
            timestamp: Date(timeIntervalSince1970: 1_900_000_020),
            properties: JourneyConvertedProperties(
                journeyId: "journey-1",
                at: Date(timeIntervalSince1970: 1_900_000_001),
                sourceFactRef: "purchase-2",
                goal: AnyCodable(["name": "checkout", "kind": "event"])
            )
        )
        let differentGoal = JourneyDownFact(
            id: "conversion-goal-b",
            event: .converted,
            timestamp: Date(timeIntervalSince1970: 1_900_000_030),
            properties: JourneyConvertedProperties(
                journeyId: "journey-1",
                at: Date(timeIntervalSince1970: 1_900_000_002),
                sourceFactRef: "purchase-3",
                goal: AnyCodable(["kind": "event", "name": "upgrade"])
            )
        )
        await secondLog.commitServerFacts(
            [redeliveredSameGoal, differentGoal],
            distinctId: "user-after-identity-change"
        )
        await secondLog.drain()

        let secondCaptures = await secondRecorder.values
        XCTAssertEqual(secondCaptures.map(\.event.id), ["conversion-goal-b"])
        await secondLog.close()
    }

    func testPendingRehydrationAndPersistenceFailureDoNotForward() async throws {
        let store = MockEventStore()
        let firstLog = makeEventLog(store: store)
        try await firstLog.configure(configuration: NuxieConfiguration(apiKey: "test-api-key"))
        firstLog.track(
            SystemEventNames.appOpened,
            properties: nil,
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
        await firstLog.drain()
        XCTAssertEqual(store.pendingIds.count, 1)
        await firstLog.close()

        store.isClosed = false
        let secondApi = MockNuxieApi()
        let secondLog = makeEventLog(store: store, api: secondApi)
        let recorder = CommittedCaptureRecorder()
        await secondLog.subscribeCommitted(when: { true }) { capture in
            await recorder.append(capture)
        }
        try await secondLog.configure(configuration: NuxieConfiguration(apiKey: "test-api-key"))
        await secondLog.drain()
        var received = await recorder.values
        XCTAssertTrue(received.isEmpty)
        let didFlush = await secondLog.flushEvents()
        let batchCalls = await secondApi.sendBatchCallCount
        let sentEvents = await secondApi.sentEvents
        XCTAssertTrue(didFlush)
        XCTAssertEqual(batchCalls, 1)
        XCTAssertTrue(sentEvents.contains {
            $0.name == SystemEventNames.appOpened
        })

        store.shouldFailStore = true
        secondLog.track(
            SystemEventNames.appBackgrounded,
            properties: nil,
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
        await secondLog.drain()
        received = await recorder.values
        XCTAssertTrue(received.isEmpty)
        await secondLog.close()
    }

    private func makeEventLog(
        store: MockEventStore,
        dateProvider: MockDateProvider = MockDateProvider(),
        api: MockNuxieApi = MockNuxieApi()
    ) -> EventLog {
        let identity = MockIdentityService()
        identity.setDistinctId("user-1")
        return EventLog(
            identity: identity,
            sessions: MockSessionService(),
            dateProvider: dateProvider,
            apiClient: api,
            store: store
        )
    }
}

private actor CommittedCaptureRecorder {
    private(set) var values: [CommittedCapture] = []

    func append(_ capture: CommittedCapture) {
        values.append(capture)
    }
}
