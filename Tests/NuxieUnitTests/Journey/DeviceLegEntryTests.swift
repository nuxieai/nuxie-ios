import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie

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
        struct Suite: Decodable { let cases: [Vector] }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent("fixtures/journeys/planes/entry-evaluation.json"))
        for vector in try JSONDecoder().decode(Suite.self, from: bytes).cases {
            let event = vector.event.map {
                NuxieEvent(name: $0.name, distinctId: "person", properties: $0.properties.mapValues(\.value))
            }
            let matches = await DeviceLegEntryEvaluator.matches(
                vector.condition, facts: vector.facts, references: vector.references,
                foreground: vector.foreground, event: event, now: Date(timeIntervalSince1970: 1_800_000_000)
            )
            XCTAssertEqual(matches, vector.expected, vector.name)
        }
    }
}
