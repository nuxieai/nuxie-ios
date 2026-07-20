#if canImport(RiveRuntime) && canImport(UIKit)
import RiveRuntime
@testable import Nuxie
import UIKit
import XCTest

@MainActor
final class PublishedRuntimeFixtureLoadTests: XCTestCase {
    func testPublishedRuntimeFixturesLoadThroughRiveViewModel() throws {
        for fixtureName in ["published-font", "text-input-motion"] {
            try XCTContext.runActivity(named: fixtureName) { _ in
                let root = try Self.fixtureURL(named: fixtureName)
                let data = try Data(contentsOf: root.appendingPathComponent("flow.riv"))
                let file = try RiveFile(
                    data: data,
                    loadCdn: false,
                    customAssetLoader: { asset, _, factory in
                        let assetURL = root
                            .appendingPathComponent("assets", isDirectory: true)
                            .appendingPathComponent("fonts", isDirectory: true)
                            .appendingPathComponent("inter-400-normal.ttf")
                        guard let fontAsset = asset as? RiveFontAsset,
                              let fontData = try? Data(contentsOf: assetURL) else {
                            return false
                        }
                        fontAsset.font(factory.decodeFont(fontData))
                        return true
                    }
                )
                let model = RiveModel(riveFile: file)
                let viewModel = RiveViewModel(
                    model,
                    animationName: nil,
                    fit: .contain,
                    alignment: .center,
                    autoPlay: true,
                    artboardName: "Paywall"
                )
                let view = viewModel.createRiveView()
                view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                let bridge = FlowViewModelBridge(model: model)
                XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())
                let initialX = try bridge.numberValue(
                    path: "nuxieTextInputs/input_email_input_60a86a84/x"
                )
                view.advance(delta: 0)
                view.advance(delta: 1 / 60)
                bridge.updateBoundListeners()
                XCTAssertGreaterThan(
                    try bridge.numberValue(path: "nuxieTextInputs/input_email_input_60a86a84/width"),
                    0
                )
                if fixtureName == "text-input-motion" {
                    view.advance(delta: 1)
                    bridge.updateBoundListeners()
                    XCTAssertGreaterThan(
                        try bridge.numberValue(path: "nuxieTextInputs/input_email_input_60a86a84/x"),
                        initialX + 16
                    )
                }
            }
        }
    }

    func testPublishedRuntimeFixturesMountThroughFixtureHost() throws {
        for fixtureName in ["published-font", "text-input-motion"] {
            try XCTContext.runActivity(named: fixtureName) { _ in
                let root = try Self.fixtureURL(named: fixtureName)
                let cacheRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("nuxie-published-runtime-fixture-tests", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                let viewController = try FlowRuntimeFixtureHost.makeViewController(
                    fixtureBaseURL: root,
                    cacheRootURL: cacheRoot
                )
                viewController.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                viewController.loadViewIfNeeded()

                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline,
                      Self.findSubview(identifier: "nuxie-flow-surface", in: viewController.view) == nil {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }

                XCTAssertNotNil(
                    Self.findSubview(identifier: "nuxie-flow-surface", in: viewController.view),
                    "Expected \(fixtureName) to mount through FlowRuntimeFixtureHost"
                )
            }
        }
    }

    private static func fixtureURL(named fixtureName: String) throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        return url
            .appendingPathComponent("FlowRuntimeHostApp", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(fixtureName, isDirectory: true)
    }

    private static func findSubview(identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = findSubview(identifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }
}
#endif
