#if canImport(RiveRuntime) && canImport(UIKit)
import RiveRuntime
import UIKit
import XCTest

@MainActor
final class EditorNextE7ConformanceTests: XCTestCase {
    private static let artboardName = "Editor Next E7 Conformance"

    func testEditorNextBuildFixtureLoadsAndAdvancesNamedArtboard() throws {
        let bundle = Bundle(for: Self.self)
        let fixtureURL = bundle.url(
            forResource: "editor_next_e7_conformance",
            withExtension: "riv",
            subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "editor_next_e7_conformance", withExtension: "riv")
        let data = try Data(contentsOf: XCTUnwrap(fixtureURL))

        let file = try RiveFile(data: data, loadCdn: false)
        let model = RiveModel(riveFile: file)
        try model.setArtboard(Self.artboardName)
        XCTAssertNotNil(model.artboard)

        let viewModel = RiveViewModel(
            model,
            animationName: nil,
            fit: .contain,
            alignment: .center,
            autoPlay: false,
            artboardName: Self.artboardName
        )
        let view = viewModel.createRiveView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        view.advance(delta: 0)
        view.advance(delta: 1 / 60)
    }
}
#endif
