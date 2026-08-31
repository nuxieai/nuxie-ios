import Foundation
import XCTest
@testable import Nuxie

final class DeviceLegValuesTests: XCTestCase {
    func testContainsHandlesLongRepeatedPrefixes() {
        let prefix = String(repeating: "a", count: 125_000)
        let context = ArmedDeviceLeg.Context(event: [:], responses: [:])
        XCTAssertEqual(DeviceLegValues.evaluate(.contains(collection: .string(prefix + prefix),
                                                         value: .string(prefix + "b")), context: context), false)
        XCTAssertEqual(DeviceLegValues.evaluate(.contains(collection: .string(prefix + prefix + "b"),
                                                         value: .string(prefix + "b")), context: context), true)
    }

    func testSharedValueAndThreeValuedConditionVectors() throws {
        struct Vectors: Decodable {
            struct Value: Decodable {
                let id: String
                let expression: JourneyValue
                let known: Bool
                let expected: ExperienceReleaseJSONValue
            }
            struct Condition: Decodable {
                let id: String
                let expression: JourneyCondition
                let expected: Bool?
            }
            let context: ArmedDeviceLeg.Context
            let values: [Value]
            let conditions: [Condition]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let vectors = try ExactJSONCodec.decode(Vectors.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/journeys/planes/values.json")))
        for vector in vectors.values {
            let actual = DeviceLegValues.resolve(vector.expression, context: vectors.context)
            XCTAssertEqual(actual != nil, vector.known, vector.id)
            if let actual {
                XCTAssertEqual(try ExactJSONCodec.encode(actual), try ExactJSONCodec.encode(vector.expected), vector.id)
            }
        }
        for vector in vectors.conditions {
            XCTAssertEqual(DeviceLegValues.evaluate(vector.expression, context: vectors.context), vector.expected, vector.id)
        }
    }
}
