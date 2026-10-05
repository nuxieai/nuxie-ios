import Foundation
import XCTest
@testable import Nuxie

@MainActor
final class ExperienceLinkRoutingTests: XCTestCase {
    func testSharedTargetsUseProductionRoute() throws {
        struct Fixture: Decodable {
            struct Case: Decodable { let url: String; let target: String?; let destination: String? }
            let cases: [Case]
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/events/runtime-link-targets.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for parser in [ExperienceLinkRouting.parse, { value in
            ExperienceLinkRouting.parseLegacy(value, parser: { escaped in
                if #available(iOS 17, macOS 14, *) { return URL(string: escaped, encodingInvalidCharacters: false) }
                return URL(string: escaped)
            })
        }] {
            for vector in fixture.cases {
                let route = ExperienceLinkRouting.route(urlString: vector.url, target: vector.target,
                    state: .settled, parser: parser)
                XCTAssertEqual(route?.destination, vector.destination, vector.url)
            }
        }
    }

    func testLegacyEscapesInvalidPercentBracketsAndRepeatedFragmentMarkers() {
        for (raw, escaped) in [
            ("https://example.test/a%", "https://example.test/a%25"),
            ("https://example.test/%xy", "https://example.test/%25xy"),
            ("https://example.test/a[b]?x=[v]", "https://example.test/a%5Bb%5D?x=%5Bv%5D"),
            ("https://example.test/#one#two", "https://example.test/#one%23two")
        ] {
            _ = ExperienceLinkRouting.parseLegacy(raw, parser: { value in
                XCTAssertEqual(value, escaped)
                if #available(iOS 17, macOS 14, *) { return URL(string: value, encodingInvalidCharacters: false) }
                return URL(string: value)
            })
        }
    }

    func testLegacyHostUsesIDNA() {
        XCTAssertEqual(ExperienceLinkRouting.parseLegacy("https://münich.example/path")?.host, "xn--mnich-kva.example")
    }
}
