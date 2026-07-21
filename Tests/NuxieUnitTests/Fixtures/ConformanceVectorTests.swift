import Foundation
import XCTest
@testable import Nuxie

/// Runs the language-neutral conformance vectors in `fixtures/` (repo root).
///
/// These vectors — not this Swift implementation — are the contract shared
/// with the Android SDK (and future executors). Loading goes through the repo
/// checkout via #filePath so the same JSON files can be consumed verbatim by
/// other runners without resource-bundling gymnastics.
final class ConformanceVectorTests: XCTestCase {

    private static var fixturesRoot: URL {
        // Tests/NuxieUnitTests/Fixtures/ConformanceVectorTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // strip filename → Fixtures/
            .deletingLastPathComponent()  // NuxieUnitTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("fixtures")
    }

    private struct Suite: Decodable {
        let suite: String
        let version: Int
        let vectors: [Vector]
    }

    private struct Vector: Decodable {
        let name: String
        let event: EventInput
        let expect: [String: AnyDecodable]
    }

    private struct EventInput: Decodable {
        let id: String
        let name: String
        let distinct_id: String
        let timestamp: String
        let properties: [String: AnyDecodable]?
    }

    private struct AnyDecodable: Decodable {
        let value: Any
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Bool.self) { value = v }
            else if let v = try? c.decode(Int.self) { value = v }
            else if let v = try? c.decode(Double.self) { value = v }
            else if let v = try? c.decode(String.self) { value = v }
            else if let v = try? c.decode([String: AnyDecodable].self) { value = v.mapValues(\.value) }
            else if let v = try? c.decode([AnyDecodable].self) { value = v.map(\.value) }
            else { value = NSNull() }
        }
    }

    private func loadSuite(_ relativePath: String) throws -> Suite {
        let url = Self.fixturesRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let suite = try JSONDecoder().decode(Suite.self, from: data)
        XCTAssertEqual(suite.version, 1, "Unknown fixture version in \(suite.suite) — runners must fail, not skip")
        return suite
    }

    func testTriggerResultEncodingVectors() throws {
        struct EncodingSuite: Decodable {
            let suite: String
            let version: Int
            let vectors: [EncodingVector]
        }
        struct EncodingVector: Decodable {
            let name: String
            let result: [String: AnyDecodable]
            let expect: [String: AnyDecodable]
        }

        let url = Self.fixturesRoot.appendingPathComponent("encodings/trigger-result.json")
        let suite = try JSONDecoder().decode(EncodingSuite.self, from: Data(contentsOf: url))
        XCTAssertEqual(suite.version, 1)

        for vector in suite.vectors {
            let kind = vector.result["kind"]?.value as? String
            let result: TriggerResult
            switch kind {
            case "noMatch":
                result = .noMatch
            case "allowed":
                let source: GateSource? = switch vector.result["source"]?.value as? String {
                case "cache": .cache
                case "purchase": .purchase
                case "restore": .restore
                default: nil
                }
                result = .allowed(source: source)
            case "denied":
                result = .denied
            case "journeyCompleted":
                result = .journeyCompleted(JourneyUpdate(
                    journeyId: vector.result["journey_id"]?.value as? String ?? "",
                    campaignId: "c-1",
                    flowId: nil,
                    exitReason: JourneyExitReason(rawValue: vector.result["exit_reason"]?.value as? String ?? "") ?? .completed,
                    goalMet: vector.result["goal_met"]?.value as? Bool ?? false
                ))
            case "error":
                result = .error(TriggerError(code: vector.result["code"]?.value as? String ?? "", message: ""))
            default:
                XCTFail("[\(vector.name)] unknown result kind \(kind ?? "nil")"); continue
            }

            let wire = result.wireValue
            for (key, expected) in vector.expect {
                XCTAssertEqual(wire[key], expected.value as? String, "[\(vector.name)] \(key)")
            }
            // No extra keys beyond the expectation (lossless, stable projection)
            XCTAssertEqual(wire.count, vector.expect.count, "[\(vector.name)] extra wire keys")
        }
    }

    func testBatchItemEncodingVectors() throws {
        let suite = try loadSuite("events/batch-item-encoding.json")
        let iso = ISO8601DateFormatter()

        for vector in suite.vectors {
            let input = vector.event
            guard let timestamp = iso.date(from: input.timestamp) else {
                XCTFail("[\(vector.name)] unparseable timestamp \(input.timestamp)")
                continue
            }
            let event = NuxieEvent(
                id: input.id,
                name: input.name,
                distinctId: input.distinct_id,
                properties: input.properties?.mapValues(\.value) ?? [:],
                timestamp: timestamp
            )

            let item = BatchEventItem(event: event)

            for (key, expected) in vector.expect {
                switch key {
                case "event":
                    XCTAssertEqual(item.event, expected.value as? String, "[\(vector.name)] event")
                case "distinct_id":
                    XCTAssertEqual(item.distinctId, expected.value as? String, "[\(vector.name)] distinct_id")
                case "anon_distinct_id":
                    XCTAssertEqual(item.anonDistinctId, expected.value as? String, "[\(vector.name)] anon_distinct_id")
                case "idempotency_key":
                    XCTAssertEqual(item.idempotencyKey, expected.value as? String, "[\(vector.name)] idempotency_key")
                case "timestamp":
                    XCTAssertEqual(item.timestamp, expected.value as? String, "[\(vector.name)] timestamp")
                case "value":
                    let expectedDouble = (expected.value as? Int).map(Double.init) ?? expected.value as? Double
                    XCTAssertEqual(item.value, expectedDouble, "[\(vector.name)] value")
                case "entity_id":
                    XCTAssertEqual(item.entityId, expected.value as? String, "[\(vector.name)] entity_id")
                case "properties":
                    guard let expectedProps = expected.value as? [String: Any] else {
                        XCTFail("[\(vector.name)] malformed expected properties"); continue
                    }
                    for (propKey, propValue) in expectedProps {
                        let actual = item.properties?[propKey]?.value
                        XCTAssertEqual(
                            String(describing: actual ?? "nil"),
                            String(describing: propValue),
                            "[\(vector.name)] properties.\(propKey)"
                        )
                    }
                default:
                    XCTFail("[\(vector.name)] unhandled expectation key '\(key)' — extend the runner")
                }
            }
        }
    }

    // MARK: - IR eval vectors

    /// In-memory adapters serving fixture state to the interpreter.
    private struct FixtureUserProps: IRUserProps {
        let props: [String: Any]
        func userProperty(for key: String) async -> Any? { props[key] }
    }

    private struct FixtureEventRow {
        let name: String
        let timestamp: Date
        let properties: [String: Any]
    }

    private struct FixtureEvents: IREventQueries {
        let rows: [FixtureEventRow]

        private func matching(
            name: String, since: Date?, until: Date?, predicate: IRPredicate?
        ) -> [FixtureEventRow] {
            rows.filter { row in
                guard row.name == name else { return false }
                if let since, row.timestamp < since { return false }
                if let until, row.timestamp > until { return false }
                if let predicate, !PredicateEval.eval(predicate, props: row.properties) {
                    return false
                }
                return true
            }
        }

        func exists(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Bool {
            !matching(name: name, since: since, until: until, predicate: predicate).isEmpty
        }
        func count(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Int {
            matching(name: name, since: since, until: until, predicate: predicate).count
        }
        func firstTime(name: String, where predicate: IRPredicate?) async -> Date? {
            matching(name: name, since: nil, until: nil, predicate: predicate)
                .map(\.timestamp).min()
        }
        func lastTime(name: String, where predicate: IRPredicate?) async -> Date? {
            matching(name: name, since: nil, until: nil, predicate: predicate)
                .map(\.timestamp).max()
        }
        func aggregate(_ agg: Aggregate, name: String, prop: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Double? {
            let values = matching(name: name, since: since, until: until, predicate: predicate)
                .compactMap { Coercion.asNumber($0.properties[prop]) }
            guard !values.isEmpty else { return nil }
            switch agg {
            case .sum: return values.reduce(0, +)
            case .avg: return values.reduce(0, +) / Double(values.count)
            case .min: return values.min()
            case .max: return values.max()
            case .unique: return Double(Set(values).count)
            }
        }
        func inOrder(steps: [StepQuery], overallWithin: TimeInterval?, perStepWithin: TimeInterval?, since: Date?, until: Date?) async -> Bool { false }
        func activePeriods(name: String, period: Period, total: Int, min: Int, where predicate: IRPredicate?) async -> Bool { false }
        func stopped(name: String, inactiveFor: TimeInterval, where predicate: IRPredicate?) async -> Bool { false }
        func restarted(name: String, inactiveFor: TimeInterval, within: TimeInterval, where predicate: IRPredicate?) async -> Bool { false }
    }

    private struct FixtureSegments: IRSegmentQueries {
        let members: Set<String>
        let enteredAt: [String: Date]
        func isMember(_ segmentId: String) async -> Bool { members.contains(segmentId) }
        func enteredAt(_ segmentId: String) async -> Date? { enteredAt[segmentId] }
    }

    func testIREvalVectors() async throws {
        struct IRSuite: Decodable {
            let suite: String
            let version: Int
            let now: String
            let distinct_id: String
            let user: [String: AnyDecodable]
            let events: [IREventInput]
            let segments: IRSegmentState
            let trigger_event: IRTriggerEvent
            let vectors: [IRVector]
        }
        struct IREventInput: Decodable {
            let name: String
            let timestamp: String
            let properties: [String: AnyDecodable]
        }
        struct IRSegmentState: Decodable {
            let member_of: [String]
            let entered_at: [String: String]
        }
        struct IRTriggerEvent: Decodable {
            let name: String
            let properties: [String: AnyDecodable]
        }
        struct IRVector: Decodable {
            let name: String
            let envelope: IREnvelope
            let expect: Bool?
            let expect_supported: Bool?
        }

        let url = Self.fixturesRoot.appendingPathComponent("ir/eval-vectors.json")
        let suite = try JSONDecoder().decode(IRSuite.self, from: Data(contentsOf: url))
        XCTAssertEqual(suite.version, 1, "Unknown ir-eval fixture version — runners must fail, not skip")

        let iso = ISO8601DateFormatter()
        guard let now = iso.date(from: suite.now) else {
            XCTFail("unparseable suite now \(suite.now)"); return
        }

        let user = FixtureUserProps(props: suite.user.mapValues(\.value))
        let events = FixtureEvents(rows: try suite.events.map { input in
            guard let ts = iso.date(from: input.timestamp) else {
                throw NSError(domain: "fixture", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "unparseable event timestamp \(input.timestamp)"
                ])
            }
            return FixtureEventRow(
                name: input.name, timestamp: ts,
                properties: input.properties.mapValues(\.value))
        })
        let segments = FixtureSegments(
            members: Set(suite.segments.member_of),
            enteredAt: suite.segments.entered_at.compactMapValues(iso.date(from:))
        )
        let triggerEvent = NuxieEvent(
            name: suite.trigger_event.name,
            distinctId: suite.distinct_id,
            properties: suite.trigger_event.properties.mapValues(\.value),
            timestamp: now
        )

        for vector in suite.vectors {
            if let expectSupported = vector.expect_supported {
                XCTAssertEqual(
                    vector.envelope.isSupportedByThisEngine, expectSupported,
                    "[\(vector.name)] engine_min gate"
                )
                if !expectSupported { continue }
            }

            guard let expected = vector.expect else {
                XCTFail("[\(vector.name)] supported vector without an expectation")
                continue
            }

            let ctx = EvalContext(
                now: now,
                user: user,
                events: events,
                segments: segments,
                event: triggerEvent
            )
            let interpreter = IRInterpreter(ctx: ctx)
            let result = (try? await interpreter.evalBool(vector.envelope.expr)) ?? false
            XCTAssertEqual(result, expected, "[\(vector.name)]")
        }
    }
}
