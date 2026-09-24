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

final class CommittedRouteRecoveryTests: XCTestCase {
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
