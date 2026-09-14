import Foundation
import XCTest
@testable import Nuxie

final class ExperienceTextInputLimitTests: XCTestCase {
    private struct Suite: Decodable { let cases: [Vector] }
    private struct Vector: Decodable {
        let name: String
        let text: String
        let maxLength: Int?
        let expected: String
    }

    func testSharedCommittedTextLimitsPreserveWholeGraphemes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent("fixtures/journeys/planes/text-input-limits.json"))
        let vectors = try JSONDecoder().decode(Suite.self, from: bytes).cases
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            let actual = ExperienceTextInputLimit.apply(vector.text, maximum: vector.maxLength)
            XCTAssertEqual(Array(actual.utf8), Array(vector.expected.utf8), vector.name)
        }
    }
}
