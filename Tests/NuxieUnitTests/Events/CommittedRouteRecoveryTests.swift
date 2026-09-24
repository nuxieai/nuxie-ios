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
