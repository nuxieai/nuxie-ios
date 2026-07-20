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
}
