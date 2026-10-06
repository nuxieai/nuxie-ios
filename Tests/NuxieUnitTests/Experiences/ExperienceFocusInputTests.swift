#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import Nuxie
@testable import NuxieRuntime

final class ExperienceFocusInputTests: XCTestCase {
    func testEmptyTextAndMultibyteBoundaryArePreserved() {
        var queue = ExperienceFocusInputQueue()
        queue.append(.text(""))
        let prefix = String(repeating: "a", count: 1_048_575)
        queue.append(.text(prefix + "éb"))
        XCTAssertEqual(queue.takeBatch(), [.text(""), .text(prefix), .text("éb")])
    }

    func testUnicode16GraphemeConformance() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/input/unicode16/GraphemeBreakTest.txt")
        var cases = 0
        for (lineNumber, line) in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").enumerated() {
            let body = line.components(separatedBy: "#")[0]
            let tokens = body.split(whereSeparator: \.isWhitespace)
            guard !tokens.isEmpty else { continue }
            var expected: [String] = []
            var cluster = ""
            for token in tokens {
                if token == "÷" {
                    if !cluster.isEmpty { expected.append(cluster); cluster = "" }
                } else if token != "×" {
                    let scalar = try XCTUnwrap(UInt32(token, radix: 16).flatMap(UnicodeScalar.init))
                    cluster.unicodeScalars.append(scalar)
                }
            }
            var actual: [String] = []
            let text = expected.joined()
            ExperienceGrapheme.forEachCluster(in: text) { range, _ in actual.append(String(text.unicodeScalars[range])) }
            XCTAssertEqual(actual.map { Array($0.utf8) }, expected.map { Array($0.utf8) }, "Unicode conformance line \(lineNumber + 1)")
            cases += 1
        }
        XCTAssertEqual(cases, 1_093)
    }

    func testTextBoundariesMatchSharedOracle() throws {
        struct Piece: Decodable {
            let text: String
            let `repeat`: Int
            var expanded: String { String(repeating: text, count: `repeat`) }
        }
        struct Case: Decodable { let name: String; let input: [Piece]; let chunks: [[Piece]] }
        struct Vector: Decodable { let cases: [Case] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/input/text-boundaries.json")
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
        XCTAssertEqual(vector.cases.count, 8)
        for item in vector.cases {
            var queue = ExperienceFocusInputQueue()
            queue.append(.text(item.input.map(\.expanded).joined()))
            let expected = item.chunks.map { Array($0.map(\.expanded).joined().utf8) }
            let actual = queue.takeBatch().map { input -> [UInt8]? in
                guard case .text(let text) = input else { return nil }
                return Array(text.utf8)
            }
            XCTAssertEqual(actual, expected.map(Optional.some), item.name)
            XCTAssertTrue(queue.isEmpty, item.name)
        }
    }

    func testLargePasteSplitsWithoutChangingUnicode() {
        var queue = ExperienceFocusInputQueue()
        let text = String(repeating: "🙂", count: 786_432)
        queue.append(.text(text))
        let chunk = String(repeating: "🙂", count: 262_144)
        XCTAssertEqual(queue.takeBatch(), [.text(chunk), .text(chunk), .text(chunk)])
        XCTAssertTrue(queue.isEmpty)
    }

    func testStepTextBudgetAndKeyOrder() {
        var queue = ExperienceFocusInputQueue()
        let chunk = String(repeating: "a", count: 1_048_576)
        queue.append(.text(String(repeating: chunk, count: 5)))
        XCTAssertEqual(queue.takeBatch(), Array(repeating: .text(chunk), count: 4))
        XCTAssertEqual(queue.takeBatch(), [.text(chunk)])
        let keys = (0..<5_000).map { NuxieNativeFocusInput.key(code: UInt16($0), modifiers: 0, pressed: true, repeated: false) }
        for key in keys { queue.append(key) }
        XCTAssertEqual(queue.takeBatch(), Array(keys[0..<4_096]))
        XCTAssertEqual(queue.takeBatch(), Array(keys[4_096..<5_000]))
        XCTAssertTrue(queue.isEmpty)
    }


}
#endif
