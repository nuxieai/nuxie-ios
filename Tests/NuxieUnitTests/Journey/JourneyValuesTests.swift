import Foundation
import XCTest
@testable import Nuxie

final class JourneyValuesTests: XCTestCase {
    func testContainsHandlesLongRepeatedPrefixes() {
        let prefix = String(repeating: "a", count: 125_000)
        let context = ArmedJourney.Context(event: [:], responses: [:])
        XCTAssertEqual(JourneyValues.evaluate(.contains(collection: .string(prefix + prefix),
                                                         value: .string(prefix + "b")), context: context), false)
        XCTAssertEqual(JourneyValues.evaluate(.contains(collection: .string(prefix + prefix + "b"),
                                                         value: .string(prefix + "b")), context: context), true)
    }

    func testSharedValueAndThreeValuedConditionVectors() throws {
        struct Vectors: Decodable {
            struct Value: Decodable {
                let id: String
                let expression: JourneyValue
                let known: Bool
                let expected: JourneyReleaseJSONValue
            }
            struct Condition: Decodable {
                let id: String
                let expression: JourneyCondition
                let expected: Bool?
            }
            let context: ArmedJourney.Context
            let values: [Value]
            let conditions: [Condition]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let vectors = try ExactJSONCodec.decode(Vectors.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/journeys/planes/values.json")))
        for vector in vectors.values {
            let actual = JourneyValues.resolve(vector.expression, context: vectors.context)
            XCTAssertEqual(actual != nil, vector.known, vector.id)
            if let actual {
                XCTAssertEqual(try ExactJSONCodec.encode(actual), try ExactJSONCodec.encode(vector.expected), vector.id)
            }
        }
        for vector in vectors.conditions {
            XCTAssertEqual(JourneyValues.evaluate(vector.expression, context: vectors.context), vector.expected, vector.id)
        }
    }
}
