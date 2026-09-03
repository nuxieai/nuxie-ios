import Foundation
import XCTest
@testable import Nuxie

final class JourneyHistoryCoverageTests: XCTestCase {
    private struct Suite: Decodable { let cases: [Vector] }
    private struct Vector: Decodable {
        struct Event: Decodable {
            let id: String
            let timestampMillis: Int64
            let delivery: String
            let origin: String
        }
        struct Step: Decodable {
            let op: String
            let keeping: Int?
            let olderThanMillis: Int64?
            let countDeleted: Int?
            let ageDeleted: Int?
            let coverageMillis: Int64?
            let ids: [String]?
            let toMillis: Int64?
            let atMillis: Int64?
            let sinceMillis: Int64?
            let known: Bool?
        }
        let name: String
        let originMillis: Int64
        let events: [Event]
        let steps: [Step]
    }

    func testSharedHistoryCoverageVectors() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent("fixtures/journeys/planes/history-coverage.json"))
        for vector in try JSONDecoder().decode(Suite.self, from: bytes).cases {
            try await run(vector)
        }
    }

    func testFractionalQueryBoundsDoNotWidenTheAuthoredWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteEventStore()
        try await store.initialize(path: directory)
        do {
            for ms in [1001, 1002] {
                _ = try await store.insert(StoredEvent(id: "row-\(ms)", name: "purchase",
                    timestamp: date(Int64(ms)), distinctId: "person"), deliveryState: .delivered)
            }
            let since = Date(timeIntervalSince1970: 1.0011)
            let count = try await store.countEvents(name: "purchase", distinctId: "person", since: since, until: nil)
            let first = try await store.getFirstEventTime(name: "purchase", distinctId: "person", since: since, until: nil)
            let rows = try await store.queryEventsForUser("person", name: "purchase", since: since, until: nil,
                ascending: true, limit: 10)
            XCTAssertEqual(count, 1)
            XCTAssertEqual(first, date(1002))
            XCTAssertEqual(rows.map(\.id), ["row-1002"])
            let exact = try await store.countEvents(name: "purchase", distinctId: "person", since: date(1001), until: date(1001))
            XCTAssertEqual(exact, 1, "Exact millisecond bounds remain inclusive")
            let absent = try await store.hasEvent(name: "purchase", distinctId: "person", since: Date(timeIntervalSince1970: 1.0021))
            XCTAssertFalse(absent)
            await store.close()
        } catch { await store.close(); throw error }
    }

    private func run(_ vector: Vector) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store = SQLiteEventStore()
        try await store.initialize(path: directory)
        do {
            let initial = try await store.readOrInitializeHistoryCoverage(startingAt: date(vector.originMillis))
            XCTAssertEqual(initial, date(vector.originMillis), vector.name)
            for event in vector.events {
                _ = try await store.insert(
                    StoredEvent(id: event.id, name: "purchase", timestamp: date(event.timestampMillis), distinctId: "person"),
                    deliveryState: event.delivery == "pending" ? .pending : .delivered,
                    origin: event.origin == "server" ? .server : .device,
                    assigningCommitSequence: false
                )
            }
            for step in vector.steps {
                switch step.op {
                case "prune":
                    let result = try await store.pruneHistory(
                        keeping: XCTUnwrap(step.keeping), olderThan: date(XCTUnwrap(step.olderThanMillis)))
                    XCTAssertEqual(result.countDeleted, step.countDeleted, vector.name)
                    XCTAssertEqual(result.ageDeleted, step.ageDeleted, vector.name)
                    XCTAssertEqual(result.coverageStartingAt, date(try XCTUnwrap(step.coverageMillis)), vector.name)
                    let remaining = try await store.queryEventsForUser("person", limit: 100)
                    XCTAssertEqual(Set(remaining.map(\.id)), Set(step.ids ?? []), vector.name)
                case "ack":
                    try await store.markDelivered(ids: XCTUnwrap(step.ids))
                case "advance":
                    let coverage = try await store.advanceHistoryCoverage(to: date(XCTUnwrap(step.toMillis)))
                    XCTAssertEqual(coverage, date(try XCTUnwrap(step.coverageMillis)), vector.name)
                case "reopen":
                    await store.close()
                    store = SQLiteEventStore()
                    try await store.initialize(path: directory)
                    let coverage = try await store.readOrInitializeHistoryCoverage(startingAt: date(XCTUnwrap(step.atMillis)))
                    XCTAssertEqual(coverage, date(try XCTUnwrap(step.coverageMillis)), vector.name)
                case "query":
                    let since = date(try XCTUnwrap(step.sinceMillis))
                    let coverage = try await store.historyCoverageStartingAt()
                    let known = since >= coverage
                    XCTAssertEqual(known, step.known, vector.name)
                    if known {
                        let rows = try await store.queryEventsForUser(
                            "person", name: "purchase", since: since, until: nil, ascending: true, limit: 100)
                        XCTAssertEqual(Set(rows.map(\.id)), Set(step.ids ?? []), vector.name)
                    }
                default: XCTFail("Unknown fixture operation: \(step.op)")
                }
            }
            await store.close()
        } catch {
            await store.close()
            throw error
        }
    }

    private func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
