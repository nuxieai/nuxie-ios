import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private actor RecoveredRouteRecorder {
    private var ids: [String] = []
    func append(_ id: String) { ids.append(id) }
    func snapshot() -> [String] { ids }
}

private final class RecoveryAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 1
    var value: UInt64 { lock.withLock { generation } }
    func advance() { lock.withLock { generation += 1 } }
}

final class CommittedRouteRecoveryTests: XCTestCase {
    func testStableBatchDeliveryAdmissionsAreAtomicAndNeverRefreshedOnRetry() async throws {
        for store: any EventStoreProtocol in [SQLiteEventStore(), MockEventStore()] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("stable-route-admission-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try await store.initialize(path: directory)
            let timestamp = Date()
            let events = try ["first", "second"].map {
                try StoredEvent(id: $0, name: "outcome", properties: [:],
                    timestamp: timestamp, distinctId: "customer-a")
            }
            func originalAdmission(_ id: String) -> CommittedRouteAdmission {
                .init(sessionId: "original", subscribers: [7: 1], stableRouteEventId: id)
            }
            // The first capture succeeds inside the transaction; staging the
            // second without a sequence must roll back both captures.
            let invalid = events.enumerated().map { index, event in
                StableEventCaptureRecord(eventId: event.id, event: event, recordedAt: timestamp,
                    routeAdmission: index == 0 ? nil : originalAdmission(event.id))
            }
            do {
                _ = try await store.commitStableCaptureBatchAndStageRoutes(invalid,
                    assigningCommitSequence: false, admission: nil)
                XCTFail("A batch with an unorderable local route must roll back")
            } catch {}
            let rolledBackCount = try await store.getEventCount()
            let rolledBackRoutes = try await store.queryPendingStableRoutes(distinctId: "customer-a", limit: 2)
            XCTAssertEqual(rolledBackCount, 0)
            XCTAssertTrue(rolledBackRoutes.isEmpty)
            let records = events.map {
                StableEventCaptureRecord(eventId: $0.id, event: $0, recordedAt: timestamp,
                    routeAdmission: originalAdmission($0.id))
            }
            let committed = try await store.commitStableCaptureBatchAndStageRoutes(records,
                assigningCommitSequence: true, admission: nil)
            XCTAssertEqual(committed.map(\.commitSequence), [0, 1])
            try await store.checkpointCommittedRoute(eventId: "first", sessionId: "original", nextSubscriber: 1)
            let replacement = CommittedRouteAdmission(sessionId: "replacement",
                subscribers: [7: 2], stableRouteEventId: "first")
            _ = try await store.commitStableCaptureAndStageRoute(eventId: "first", event: nil,
                recordedAt: timestamp, assigningCommitSequence: true, admission: nil,
                routeAdmission: replacement)
            let first = try await store.firstPendingCommittedRoute(sessionId: "original")
            let refreshed = try await store.firstPendingCommittedRoute(sessionId: "replacement")
            XCTAssertEqual(first?.event.id, "first")
            XCTAssertEqual(first?.admission, originalAdmission("first"))
            XCTAssertEqual(first?.nextSubscriber, 1)
            XCTAssertNil(refreshed)
            try await store.markStableRouteDelivered(eventId: "first")
            try await store.acknowledgeCommittedRoute(eventId: "first", sessionId: "original")
            let replay = try await store.commitStableCaptureAndStageRoute(eventId: "first", event: nil,
                recordedAt: timestamp, assigningCommitSequence: true, admission: nil,
                routeAdmission: replacement)
            XCTAssertFalse(replay.localRoutePending)
            let second = try await store.firstPendingCommittedRoute(sessionId: "original")
            let restaged = try await store.firstPendingCommittedRoute(sessionId: "replacement")
            XCTAssertEqual(second?.event.id, "second")
            XCTAssertNil(restaged)
            await store.close()
        }
    }

    func testHistoryPruningRetainsLocalDeliveryUntilAcknowledged() async throws {
        for pruneByAge in [true, false] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("route-retention-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = SQLiteEventStore()
            try await store.initialize(path: directory)
            let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
            _ = try await store.readOrInitializeHistoryCoverage(startingAt: timestamp)
            let ordinary = try StoredEvent(id: "ordinary", name: "outcome", properties: [:],
                timestamp: timestamp, distinctId: "customer-a")
            let stable = try StoredEvent(id: "stable", name: "outcome", properties: [:],
                timestamp: timestamp, distinctId: "customer-a")
            _ = try await store.insert(ordinary, deliveryState: .pending, origin: .device,
                assigningCommitSequence: true, routeAdmission: .init(
                    sessionId: "session", subscribers: [1: 1], stableRouteEventId: nil))
            _ = try await store.commitStableCaptureAndStageRoute(eventId: stable.id,
                event: stable, recordedAt: timestamp, assigningCommitSequence: true, admission: nil)
            try await store.markDelivered(ids: [ordinary.id, stable.id])
            let cutoff = pruneByAge ? timestamp.addingTimeInterval(1) : timestamp
            let keeping = pruneByAge ? 100 : 0
            let retained = try await store.pruneHistory(keeping: keeping, olderThan: cutoff)
            XCTAssertEqual(retained.ageDeleted + retained.countDeleted, 0)
            let pendingOrdinary = try await store.firstPendingCommittedRoute(sessionId: "session")
            let pendingStable = try await store.queryPendingStableRoutes(distinctId: "customer-a", limit: 1)
            XCTAssertEqual(pendingOrdinary?.event.id, ordinary.id)
            XCTAssertEqual(pendingStable.map(\.id), [stable.id])
            try await store.acknowledgeCommittedRoute(eventId: ordinary.id, sessionId: "session")
            try await store.markStableRouteDelivered(eventId: stable.id)
            let released = try await store.pruneHistory(keeping: keeping, olderThan: cutoff)
            XCTAssertEqual(released.ageDeleted + released.countDeleted, 2)
            await store.close()
        }
    }

    func testCommittedRouteAdmissionIsAtomicAndRetainsItsOriginalRetryPosition() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("route-checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteEventStore()
        try await store.initialize(path: directory)
        let event = try StoredEvent(id: "outcome", name: "outcome", properties: [:],
            timestamp: Date(), distinctId: "customer-a")
        let originalAdmission = CommittedRouteAdmission(
            sessionId: "original-session", subscribers: [7: UInt64.max], stableRouteEventId: nil
        )
        do {
            _ = try await store.insert(event, deliveryState: .pending, origin: .device,
                assigningCommitSequence: false, routeAdmission: originalAdmission)
            XCTFail("Routing without a commit sequence must roll back the event and inbox")
        } catch {}
        let rolledBackCount = try await store.getEventCount()
        let rolledBackInbox = try await store.pendingConversionOccurrences(distinctId: "customer-a")
        XCTAssertEqual(rolledBackCount, 0)
        XCTAssertTrue(rolledBackInbox.isEmpty)
        let inserted = try await store.insert(event, deliveryState: .pending, origin: .device,
            assigningCommitSequence: true, routeAdmission: originalAdmission)
        XCTAssertEqual(inserted.commitSequence, 0)
        let replacement = CommittedRouteAdmission(
            sessionId: "replacement-session", subscribers: [7: 2], stableRouteEventId: nil
        )
        let duplicate = try await store.insert(event, deliveryState: .pending, origin: .device,
            assigningCommitSequence: true, routeAdmission: replacement)
        XCTAssertFalse(duplicate.newlyDurable)
        let replacementRoute = try await store.firstPendingCommittedRoute(sessionId: replacement.sessionId)
        XCTAssertNil(replacementRoute)
        try await store.checkpointCommittedRoute(eventId: event.id,
            sessionId: originalAdmission.sessionId, nextSubscriber: 2)
        await store.close()
        let reopened = SQLiteEventStore()
        try await reopened.initialize(path: directory)
        let pending = try await reopened.firstPendingCommittedRoute(sessionId: originalAdmission.sessionId)
        XCTAssertEqual(pending?.admission, originalAdmission)
        XCTAssertEqual(pending?.nextSubscriber, 2)
        XCTAssertEqual(pending?.event.id, event.id)
        try await reopened.acknowledgeCommittedRoute(eventId: event.id, sessionId: replacement.sessionId)
        let stillPending = try await reopened.firstPendingCommittedRoute(sessionId: originalAdmission.sessionId)
        XCTAssertNotNil(stillPending)
        try await reopened.discardOtherCommittedRouteSessions(keeping: replacement.sessionId)
        let discarded = try await reopened.firstPendingCommittedRoute(sessionId: originalAdmission.sessionId)
        XCTAssertNil(discarded)
        let retainedEventCount = try await reopened.getEventCount()
        let retainedInbox = try await reopened.pendingConversionOccurrences(distinctId: "customer-a")
        XCTAssertEqual(retainedEventCount, 1)
        XCTAssertEqual(retainedInbox.map(\.event.id), [event.id])
        await reopened.close()
    }

    func testPagedVisitAcknowledgesTheEntireOriginalPrefixBeforeNewCaptures() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("route-pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteEventStore()
        try await store.initialize(path: directory.appendingPathComponent("events.sqlite"))
        let expected = (0..<205).map { "retained-\($0)" }
        for id in expected {
            let event = try StoredEvent(id: id, name: "retained", properties: [:],
                timestamp: Date(), distinctId: "customer-a")
            _ = try await store.commitStableCaptureAndStageRoute(
                eventId: id, event: event, recordedAt: event.timestamp,
                assigningCommitSequence: false, admission: nil
            )
        }
        let recorder = RecoveredRouteRecorder()
        let completed = try await store.visitPendingStableRoutes(distinctId: "customer-a") { event in
            await recorder.append(event.id)
            do {
                if event.id == "retained-99" {
                    let newer = try StoredEvent(id: "newer", name: "newer", properties: [:],
                        timestamp: Date(), distinctId: "customer-a")
                    _ = try await store.commitStableCaptureAndStageRoute(
                        eventId: newer.id, event: newer, recordedAt: newer.timestamp,
                        assigningCommitSequence: false, admission: nil
                    )
                }
                try await store.markStableRouteDelivered(eventId: event.id)
                return true
            } catch { return false }
        }
        XCTAssertTrue(completed)
        let visited = await recorder.snapshot()
        XCTAssertEqual(visited, expected)
        let pending = try await store.queryPendingStableRoutes(distinctId: "customer-a", limit: 10)
        XCTAssertEqual(pending.map(\.id), ["newer"])
        let refused = try await store.visitPendingStableRoutes(distinctId: "customer-a") { _ in false }
        XCTAssertFalse(refused)
        let stillPending = try await store.queryPendingStableRoutes(distinctId: "customer-a", limit: 10)
        XCTAssertEqual(stillPending.map(\.id), ["newer"])
        await store.close()
    }

    func testRecoveryKeepsAdmissionsAndCaptureOrderAcrossPages() async throws {
        try await assertPagedRecovery(interruptWithNewGate: false)
    }

    func testRecoveryStopsBeforeCrossingANewerRecoveryGate() async throws {
        try await assertPagedRecovery(interruptWithNewGate: true)
    }

    private func assertPagedRecovery(interruptWithNewGate: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("route-admissions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = SQLiteEventStore()
        try await original.initialize(path: directory)
        let retained = (0..<205).map { "retained-\($0)" }
        for id in retained {
            let event = try StoredEvent(id: id, name: "retained", properties: [:],
                timestamp: Date(), distinctId: "customer-a")
            _ = try await original.commitStableCaptureAndStageRoute(
                eventId: id, event: event, recordedAt: event.timestamp,
                assigningCommitSequence: false, admission: nil
            )
        }
        await original.close()
        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        configuration.testingOverrides.customStoragePath = directory
        configuration.testingOverrides.suppressBackgroundWork = true
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = SQLiteEventStore()
        let log = EventLog(identity: identity, dateProvider: MockDateProvider(),
            apiClient: MockNuxieApi(), store: store)
        _ = await log.deferCommittedRouting()
        let admissions = RecoveryAdmission()
        let recorder = RecoveredRouteRecorder()
        let reservation = log.reserveCommittedAdmission { admissions.value }
        await log.subscribeAcknowledgingCommitted(reservation: reservation) { [weak log] event, admission in
            await recorder.append("\(event.id):\(admission ?? 0)")
            if event.id == "retained-99" {
                admissions.advance()
                guard let captured = await log?.captureAndRouteSystemEvent(.init(
                    name: "newer", properties: nil, eventId: "newer", distinctId: "customer-a"
                )), captured.event.id == "newer" else { return false }
                if interruptWithNewGate { _ = await log?.deferCommittedRouting() }
            }
            return true
        }
        try await log.configure(configuration: configuration)
        let firstReplay = await log.replayPendingStableRoutes(distinctId: "customer-a")
        if interruptWithNewGate {
            XCTAssertFalse(firstReplay)
            let beforeReopening = await recorder.snapshot()
            XCTAssertEqual(beforeReopening, retained.prefix(100).map { "\($0):1" })
            let resumed = await log.replayPendingStableRoutes(distinctId: "customer-a")
            XCTAssertTrue(resumed)
        }
        await log.drain()
        let visited = await recorder.snapshot()
        let expected = retained.enumerated().map { index, id in
            "\(id):\(interruptWithNewGate && index >= 100 ? 2 : 1)"
        } + ["newer:2"]
        XCTAssertEqual(visited, expected)
        let drained = await log.replayPendingStableRoutes(distinctId: "customer-a")
        XCTAssertTrue(drained)
        let afterReplay = await recorder.snapshot()
        XCTAssertEqual(afterReplay, visited)
        await log.close()
    }

    func testFailedDeliverySurvivesSQLiteReopenWithoutCrossCustomerReplay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("route-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        configuration.testingOverrides.customStoragePath = directory
        configuration.testingOverrides.flushAt = 100
        configuration.testingOverrides.suppressBackgroundWork = true
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let originalStore = SQLiteEventStore()
        let original = EventLog(identity: identity, dateProvider: MockDateProvider(),
            apiClient: MockNuxieApi(), store: originalStore)
        let reservation = original.reserveCommittedAdmission { 1 }
        await original.subscribeAcknowledgingCommitted(reservation: reservation) { _, _ in false }
        try await original.configure(configuration: configuration)
        for id in ["entry", "goal"] {
            _ = await original.captureAndRouteSystemEvent(.init(
                name: id, properties: nil, eventId: id, distinctId: "customer-a"
            ))
        }
        let drained = await original.drainCommittedRouting()
        XCTAssertFalse(drained)
        let pendingBeforeClose = try await originalStore.queryPendingStableRoutes(distinctId: "customer-a", limit: 100)
        XCTAssertEqual(pendingBeforeClose.map(\.id), ["entry", "goal"])
        let firstPending = try await originalStore.queryPendingStableRoutes(
            distinctId: "customer-a", limit: 1
        )
        XCTAssertEqual(firstPending.map(\.id), ["entry"])
        let noRows = try await originalStore.queryPendingStableRoutes(
            distinctId: "customer-a", limit: 0
        )
        XCTAssertTrue(noRows.isEmpty)
        let firstPendingId = try await original.firstPendingStableRouteEventId(distinctId: "customer-a")
        XCTAssertEqual(firstPendingId, "entry")
        await original.close()

        identity.setDistinctId("customer-b")
        let reopenedStore = SQLiteEventStore()
        let reopened = EventLog(identity: identity, dateProvider: MockDateProvider(),
            apiClient: MockNuxieApi(), store: reopenedStore)
        let recovered = RecoveredRouteRecorder()
        let replayReservation = reopened.reserveCommittedAdmission { 2 }
        await reopened.subscribeAcknowledgingCommitted(reservation: replayReservation) { event, generation in
            guard generation == 2 else { return false }
            await recovered.append(event.id)
            return true
        }
        try await reopened.configure(configuration: configuration)
        let otherCustomer = await reopened.replayPendingStableRoutes(distinctId: "customer-b")
        XCTAssertTrue(otherCustomer)
        let otherCustomerRoutes = await recovered.snapshot()
        XCTAssertEqual(otherCustomerRoutes, [])
        let retained = try await reopenedStore.queryPendingStableRoutes(distinctId: "customer-a", limit: 100)
        XCTAssertEqual(retained.map(\.id), ["entry", "goal"])

        identity.setDistinctId("customer-a")
        let replayed = await reopened.replayPendingStableRoutes(distinctId: "customer-a")
        XCTAssertTrue(replayed)
        let recoveredIds = await recovered.snapshot()
        XCTAssertEqual(recoveredIds, ["entry", "goal"])
        let remaining = try await reopenedStore.queryPendingStableRoutes(distinctId: "customer-a", limit: 100)
        XCTAssertTrue(remaining.isEmpty)
        let deliveryCount = try await reopenedStore.getPendingDeliveryCount()
        XCTAssertEqual(deliveryCount, 2)
        let measurement = try await reopenedStore.pendingConversionOccurrences(distinctId: "customer-a")
        XCTAssertEqual(measurement.map(\.event.id), ["entry", "goal"])
        await reopened.close()
    }
}
