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
        for parser in [ExperienceLinkRouting.parse, ExperienceLinkRouting.parseLegacy] {
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

    func testLegacyHostUsesIDNA() {
        XCTAssertEqual(ExperienceLinkRouting.parseLegacy("https://münich.example/path")?.host, "xn--mnich-kva.example")
    }

    func testUnopenableURLIsNotReportedAsOpened() async {
        let opened = await ExperienceLinkRouting.open(urlString: "sampleapp://item", target: "_blank",
            inApp: { _ in XCTFail("Unexpected in-app route"); return false }, external: { _ in false })
        XCTAssertFalse(opened)
    }
}
