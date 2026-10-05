import Foundation
import XCTest
@testable import Nuxie

@MainActor
final class ExperienceLinkRoutingTests: XCTestCase {
    func testSharedTargetsUseExactlyOneOpener() async throws {
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
            var calls: [String] = []
            let opened = await ExperienceLinkRouting.open(urlString: vector.url, target: vector.target, parser: parser,
                inApp: { _ in calls.append("in_app"); return true },
                external: { _ in calls.append("external"); return true })
            XCTAssertEqual(calls, vector.destination.map { [$0] } ?? [], vector.url)
            XCTAssertEqual(opened, vector.destination != nil, vector.url)
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

    func testUnopenableURLIsNotReportedAsOpened() async {
        let opened = await ExperienceLinkRouting.open(urlString: "sampleapp://item", target: "_blank",
            inApp: { _ in XCTFail("Unexpected in-app route"); return false }, external: { _ in false })
        XCTAssertFalse(opened)
    }
}
