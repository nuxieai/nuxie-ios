import Foundation
import XCTest
@testable import Nuxie

final class ExperienceLinkRoutingTests: XCTestCase {
    func testSharedTargetsUseExactlyOneOpener() throws {
        struct Fixture: Decodable {
            struct Case: Decodable { let url: String; let target: String?; let destination: String? }
            let cases: [Case]
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/events/runtime-link-targets.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for vector in fixture.cases {
            var calls: [String] = []
            let opened = ExperienceLinkRouting.open(urlString: vector.url, target: vector.target,
                inApp: { _ in calls.append("in_app"); return true },
                external: { _ in calls.append("external"); return true })
            XCTAssertEqual(calls, vector.destination.map { [$0] } ?? [], vector.url)
            XCTAssertEqual(opened, vector.destination != nil, vector.url)
        }
    }

    func testUnopenableURLIsNotReportedAsOpened() {
        XCTAssertFalse(ExperienceLinkRouting.open(urlString: "sampleapp://item", target: "_blank",
            inApp: { _ in XCTFail("Unexpected in-app route"); return false }, external: { _ in false }))
    }

    func testRejectedSourceDoesNotRejectItsLink() {
        var event = ExperienceInteractiveReportedEvent(localIndex: 0, coreType: 131,
            name: "", url: "https://example.test", target: "_self", delay: 0, properties: [])
        event.sourceRejection = "source absent"
        var router = ExperienceInteractiveEffectRouter()
        let effects = router.project(reportedEvents: [event], viewModelChanges: [],
            hostCommands: [], declaredEventNames: [], correlationID: 1)
        guard case .reportedEvent(let projected) = effects.first?.kind else {
            return XCTFail("Source validation discarded a link")
        }
        var opens = 0
        XCTAssertTrue(ExperienceLinkRouting.open(urlString: projected.url, target: projected.target,
            inApp: { _ in opens += 1; return true }, external: { _ in opens += 1; return true }))
        XCTAssertEqual(opens, 1)
    }
}
