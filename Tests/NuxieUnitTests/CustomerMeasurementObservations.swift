import Foundation
import SQLite3
import XCTest
@testable import Nuxie
@testable import NuxieTestSupport

extension SQLiteEventStore {
    /// Measurement observations read canonical event rows, including unbound captures for storage assertions.
    func measurementInputs(distinctId: String, limit: Int = 100, throughEventId: String? = nil) throws -> [PendingConversionOccurrence] {
        let scope = try conversionScope()
        var sql = "SELECT id,accepted_at FROM events WHERE scope=? AND user_id=? AND measurement_state='pending'"
        var values: [CustomerSQLValue] = [.text(scope), .text(distinctId)]
        if let throughEventId { sql += " AND capture_sequence<=(SELECT capture_sequence FROM events WHERE id=?)"; values.append(.text(throughEventId)) }
        sql += " ORDER BY timestamp,id LIMIT ?;"
        values.append(.integer(Int64(limit)))
        let rows: [(String, Int64)] = try customerQuery(sql, values) { statement in
            var rows: [(String, Int64)] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return rows }
                guard code == SQLITE_ROW else { throw CustomerStoreError.invalidRow }
                rows.append((try rowText(statement, 0), sqlite3_column_int64(statement, 1)))
            }
        }
        return try rows.map { id, accepted in
            guard let event = try queryEvent(id: id) else { throw CustomerStoreError.invalidRow }
            return .init(event: event, acceptedAt: JourneyTime.date(accepted))
        }
    }

    func acknowledgeMeasurement(eventId: String, distinctId: String) throws {
        let namespace = try conversionScope()
        guard namespace.hasPrefix("authority-") else { return }
        let owner = CustomerStoreOwner(scope: .init(namespaceHash: String(namespace.dropFirst("authority-".count))), userId: distinctId)
        guard try customerExists("SELECT 1 FROM events WHERE id=? AND scope=? AND user_id=?;", [.text(eventId)] + ownerValues(owner)) else { return }
        let scope = try customerScope(owner: owner)
        if scope == nil { try putCustomerScope(.init(owner: owner, executionEpoch: 0, executionRevoked: false, openedStateVersion: CustomerStoreSchema.stateVersion)) }
        let watches = try customerWatches(owner: owner)
        let digest = SHA256Provider.hexDigest(try ExactJSONCodec.canonicalize(ExactJSONCodec.encode(watches)))
        _ = try executeCustomerCommand(.init(owner: owner, epoch: scope?.executionEpoch ?? 0, mutation: .measure(eventId: eventId, watches: watches, expectedDigest: digest)))
    }

    func expireMeasurement(at now: Date, distinctId: String = "customer") throws -> Int {
        let namespace = try conversionScope()
        guard namespace.hasPrefix("authority-") else { return 0 }
        let owner = CustomerStoreOwner(scope: .init(namespaceHash: String(namespace.dropFirst("authority-".count))), userId: distinctId)
        if try customerScope(owner: owner) == nil { try putCustomerScope(.init(owner: owner, executionEpoch: 0, executionRevoked: false, openedStateVersion: CustomerStoreSchema.stateVersion)) }
        let before = try measurementInputs(distinctId: distinctId, limit: 1000).count
        _ = try executeCustomerCommand(.init(owner: owner, epoch: 0, mutation: .expireMeasurement(cutoffAcceptedAt: Int64(JourneyConversionWatch.millis(now)) - Int64(PendingConversionOccurrence.retentionMillis))))
        return before - (try measurementInputs(distinctId: distinctId, limit: 1000).count)
    }
}


extension MockEventLog {
    func measurementInputs(distinctId: String, limit: Int, throughEventId: String?) async throws -> [PendingConversionOccurrence] {
        guard let store = await customerStore() as? SQLiteEventStore else { return [] }
        return try await store.measurementInputs(distinctId: distinctId, limit: limit, throughEventId: throughEventId)
    }
}
