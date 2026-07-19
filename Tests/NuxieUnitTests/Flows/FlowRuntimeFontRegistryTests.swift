import Foundation
import XCTest
@testable import Nuxie

final class FlowRuntimeFontRegistryTests: XCTestCase {
    #if canImport(UIKit)
    func testRegistryKeepsContentBackedRevisionsWithTheSamePostScriptName() throws {
        let bundle = Bundle(for: Self.self)
        guard let fixtureRoot = bundle.url(
            forResource: "published-font",
            withExtension: nil
        ) else {
            XCTFail("published font fixture is missing")
            return
        }
        let fontURL = fixtureRoot
            .appendingPathComponent("assets/fonts")
            .appendingPathComponent("inter-400-normal.ttf")
        let original = try Data(contentsOf: fontURL)
        var revised = original
        revised.append(0)
        let uniqueName = "font-revision-\(UUID().uuidString)"

        let firstName = FlowRuntimeFontRegistry.registerFont(
            riveUniqueName: uniqueName,
            data: original
        )
        let secondName = FlowRuntimeFontRegistry.registerFont(
            riveUniqueName: uniqueName,
            data: revised
        )

        XCTAssertNotNil(firstName)
        XCTAssertEqual(secondName, firstName)
        XCTAssertNotNil(
            FlowRuntimeFontRegistry.font(
                forRiveUniqueName: uniqueName,
                contentSHA256: FlowArtifactStore.sha256Hex(original),
                size: 16
            )
        )
        XCTAssertNotNil(
            FlowRuntimeFontRegistry.font(
                forRiveUniqueName: uniqueName,
                contentSHA256: FlowArtifactStore.sha256Hex(revised),
                size: 16
            )
        )
    }
    #endif

    func testCatalogKeepsTwoBuildsWithTheSameUniqueNameContentScoped() {
        var catalog = FlowRuntimeRegisteredFontCatalog()

        catalog.record(
            riveUniqueName: "font-inter-400",
            contentSHA256: "AAAA",
            postScriptName: "Inter-Regular-v1"
        )
        catalog.record(
            riveUniqueName: "font-inter-400",
            contentSHA256: "BBBB",
            postScriptName: "Inter-Regular-v2"
        )

        XCTAssertEqual(
            catalog.postScriptName(
                forRiveUniqueName: "font-inter-400",
                contentSHA256: "aaaa"
            ),
            "Inter-Regular-v1"
        )
        XCTAssertEqual(
            catalog.postScriptName(
                forRiveUniqueName: "font-inter-400",
                contentSHA256: "bbbb"
            ),
            "Inter-Regular-v2"
        )
        XCTAssertNil(
            catalog.postScriptName(
                forRiveUniqueName: "font-inter-400",
                contentSHA256: "cccc"
            )
        )
    }
}
