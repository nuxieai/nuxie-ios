import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class DeviceLegEntryTests: XCTestCase {
    private struct Vector: Decodable {
        struct Event: Decodable { let name: String; let properties: [String: AnyCodable] }
        let name: String
        let condition: DeviceLegEntryCondition
        let facts: DeviceLegFactTable
        let references: DeviceLegFactReferences
        let foreground: Bool
        let event: Event?
        let expected: Bool
        struct History: Decodable {
            struct Event: Decodable {
                let id: String
                let name: String
                let timestampMillis: Int64
                let properties: [String: AnyCodable]
            }
            let coverageStartMillis: Int64
            let events: [Event]
        }
        let history: History?
        let nowMillis: Int64?
    }

    func testHistoryPredicateUsesItsQueryEventWithoutAnEntryEvent() async {
        let events = IRTestEventLog()
        events.existsResult = true
        let condition = DeviceLegEntryCondition(type: .appForegrounded, eventName: nil, segmentId: nil, member: nil,
            condition: .init(ir_version: 1, engine_min: nil, compiled_at: nil,
                expr: .eventsExists(name: "purchase", since: nil, until: nil, within: nil,
                    where_: .pred(op: "is_set", key: "premium", value: nil))))
        let matches = await DeviceLegEntryEvaluator.matches(condition,
            facts: .init(properties: [:], memberships: [:], assignments: [:]),
            references: .init(propertyKeys: [], segmentIds: [], experimentIds: []),
            foreground: true, event: nil, now: Date(), events: events)
        XCTAssertTrue(matches)
    }

    func testSharedEntryEvaluationVectors() async throws {
        try await runVectors("entry-evaluation")
    }

    func testSharedOccurrenceEvaluationVectors() async throws {
        try await runVectors("occurrence-evaluation")
    }

    private func runVectors(_ fixture: String) async throws {
        struct Suite: Decodable { let cases: [Vector] }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent("fixtures/journeys/planes/\(fixture).json"))
        for vector in try JSONDecoder().decode(Suite.self, from: bytes).cases {
            let now = Date(timeIntervalSince1970: Double(vector.nowMillis ?? 1_800_000_000_000) / 1000)
            var queries: IREventQueriesAdapter?
            if let history = vector.history {
                let log = MockEventLog()
                log.historyCoverageResult = .retainedWindow(
                    startingAt: Date(timeIntervalSince1970: Double(history.coverageStartMillis) / 1000))
                for row in history.events {
                    _ = await log.route(NuxieEvent(id: row.id, name: row.name, distinctId: "person",
                        properties: row.properties.mapValues(\.value),
                        timestamp: Date(timeIntervalSince1970: Double(row.timestampMillis) / 1000)))
                }
                queries = IREventQueriesAdapter(eventLog: log, distinctId: "person", additionalEvents: [], now: { now })
            }
            let event = vector.event.map {
                NuxieEvent(name: $0.name, distinctId: "person", properties: $0.properties.mapValues(\.value))
            }
            let matches = await DeviceLegEntryEvaluator.matches(
                vector.condition, facts: vector.facts, references: vector.references,
                foreground: vector.foreground, event: event, now: now, events: queries
            )
            XCTAssertEqual(matches, vector.expected, vector.name)
        }
    }
}
