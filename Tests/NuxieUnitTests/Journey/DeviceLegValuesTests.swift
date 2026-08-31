import Foundation
import XCTest
@testable import Nuxie

final class DeviceLegValuesTests: XCTestCase {
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
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/journeys/planes/values.json")))
        for vector in vectors.values {
            let actual = DeviceLegValues.resolve(vector.expression, context: vectors.context)
            XCTAssertEqual(actual != nil, vector.known, vector.id)
            if let actual {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                XCTAssertEqual(try encoder.encode(actual), try encoder.encode(vector.expected), vector.id)
            }
        }
        for vector in vectors.conditions {
            XCTAssertEqual(DeviceLegValues.evaluate(vector.expression, context: vectors.context), vector.expected, vector.id)
        }
    }
}
