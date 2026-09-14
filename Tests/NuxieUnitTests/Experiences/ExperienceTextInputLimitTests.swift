import Foundation
import XCTest
@testable import Nuxie

final class ExperienceTextInputLimitTests: XCTestCase {
    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures")
    }

    func testEveryOfficialUnicode16GraphemeBoundary() throws {
        let corpus = try String(contentsOf: fixtureRoot.appendingPathComponent("unicode/GraphemeBreakTest-16.0.0.txt"), encoding: .utf8)
        var cases = 0
        for (lineNumber, line) in corpus.components(separatedBy: .newlines).enumerated() {
            let content = line.components(separatedBy: "#")[0]
            let tokens = content.split(whereSeparator: { $0.isWhitespace })
            if tokens.isEmpty { continue }
            var text = ""
            var boundaries: [Int] = []
            for token in tokens {
                switch token {
                case "÷": boundaries.append(text.utf8.count)
                case "×": break
                default:
                    let scalar = try XCTUnwrap(UInt32(token, radix: 16).flatMap(UnicodeScalar.init))
                    text.unicodeScalars.append(scalar)
                }
            }
            let bytes = Array(text.utf8)
            for (maximum, end) in boundaries.enumerated() {
                XCTAssertEqual(Array(ExperienceTextInputLimit.apply(text, maximum: maximum).utf8),
                    Array(bytes.prefix(end)), "Unicode line \(lineNumber + 1), limit \(maximum)")
            }
            cases += 1
        }
        XCTAssertEqual(cases, 1093)
    }

    func testSharedOrdinaryReplacementAdmission() throws {
        let bytes = try Data(contentsOf: fixtureRoot.appendingPathComponent("journeys/planes/text-input-edits.json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 9)
        for item in cases {
            let current = try XCTUnwrap(item["current"] as? String)
            let start = try XCTUnwrap(item["start"] as? Int)
            let end = try XCTUnwrap(item["end"] as? Int)
            let range = try XCTUnwrap(Range(NSRange(location: start, length: end - start), in: current))
            let candidate = current.replacingCharacters(in: range, with: try XCTUnwrap(item["replacement"] as? String))
            let allowed = try XCTUnwrap(item["allowed"] as? Bool)
            let name = try XCTUnwrap(item["name"] as? String)
            XCTAssertEqual(ExperienceTextInputLimit.fits(candidate, maximum: item["maxLength"] as? Int), allowed, name)
        }
    }

    private struct Suite: Decodable { let cases: [Vector] }
    private struct Vector: Decodable {
        let name: String
        let text: String
        let maxLength: Int?
        let expected: String
    }

    func testSharedCommittedTextLimitsPreserveWholeGraphemes() throws {
        let bytes = try Data(contentsOf: fixtureRoot.appendingPathComponent("journeys/planes/text-input-limits.json"))
        let vectors = try JSONDecoder().decode(Suite.self, from: bytes).cases
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            let actual = ExperienceTextInputLimit.apply(vector.text, maximum: vector.maxLength)
            XCTAssertEqual(Array(actual.utf8), Array(vector.expected.utf8), vector.name)
        }
    }
}
