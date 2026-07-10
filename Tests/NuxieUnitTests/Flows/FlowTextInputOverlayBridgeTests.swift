#if canImport(RiveRuntime) && canImport(UIKit)
import RiveRuntime
@testable import Nuxie
import UIKit
import XCTest

/// Overlay commit + response mapping coverage on the real runtime: binds the
/// bridge against the `text-input-motion` publish fixture and drives the
/// UIKit editing delegate entry points directly.
@MainActor
final class FlowTextInputOverlayBridgeTests: XCTestCase {
    @MainActor
    private struct Harness {
        let bridge: FlowTextInputOverlayBridge
        let riveView: RiveView
        let riveViewModel: RiveViewModel
        let viewModelBridge: FlowViewModelBridge
        let artifact: LoadedFlowArtifact

        func control(forInputId inputId: String) -> UIView? {
            riveView.subviews.first {
                $0.accessibilityIdentifier == "nuxie-text-input-\(inputId)"
            }
        }

        func rebind() {
            bridge.bind(
                screenId: "screen_1",
                artifact: artifact,
                riveView: riveView,
                riveViewModel: riveViewModel,
                viewModelBridge: viewModelBridge
            )
        }
    }

    private var commits: [(input: FlowArtifactTextInput, text: String)] = []

    override func setUp() {
        super.setUp()
        commits = []
    }

    func testEndEditingCommitsChangedTextOnce() throws {
        let harness = try makeHarness()
        let field = try XCTUnwrap(
            harness.control(forInputId: "text-input/screen_1/email_input") as? UITextField
        )

        field.text = "typed@nuxie.dev"
        harness.bridge.textFieldDidEndEditing(field)

        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.input.inputId, "text-input/screen_1/email_input")
        XCTAssertEqual(commits.first?.input.responseFieldKey, "email")
        XCTAssertEqual(commits.first?.text, "typed@nuxie.dev")

        // Same value again: no duplicate commit.
        harness.bridge.textFieldDidEndEditing(field)
        XCTAssertEqual(commits.count, 1)
    }

    func testEndEditingWithoutChangeCommitsNothing() throws {
        let harness = try makeHarness()
        let field = try XCTUnwrap(
            harness.control(forInputId: "text-input/screen_1/email_input") as? UITextField
        )

        // The seeded manifest value is the committed baseline.
        harness.bridge.textFieldDidEndEditing(field)

        XCTAssertTrue(commits.isEmpty)
    }

    func testCommittedBaselineSurvivesRebind() throws {
        let harness = try makeHarness()
        let field = try XCTUnwrap(
            harness.control(forInputId: "text-input/screen_1/email_input") as? UITextField
        )
        field.text = "typed@nuxie.dev"
        harness.bridge.textFieldDidEndEditing(field)
        XCTAssertEqual(commits.count, 1)

        // Rebind on the same build (screen re-entry): the typed value is
        // seeded back and blur-without-change stays silent.
        harness.rebind()
        let reboundField = try XCTUnwrap(
            harness.control(forInputId: "text-input/screen_1/email_input") as? UITextField
        )
        XCTAssertEqual(reboundField.text, "typed@nuxie.dev")
        harness.bridge.textFieldDidEndEditing(reboundField)
        XCTAssertEqual(commits.count, 1)
    }

    func testWebSearchKeyboardTypeMapsToNativeKeyboard() throws {
        let harness = try makeHarness()
        let field = try XCTUnwrap(
            harness.control(forInputId: "text-input/screen_1/search_input") as? UITextField
        )
        XCTAssertEqual(field.keyboardType, .webSearch)
    }

    func testKeyboardShiftMath() {
        // Control fully above the keyboard: no shift.
        XCTAssertEqual(
            FlowTextInputOverlayBridge.keyboardShift(
                controlFrameInWindow: CGRect(x: 0, y: 100, width: 300, height: 50),
                currentShift: 0,
                keyboardMinY: 500,
                padding: 12
            ),
            0
        )
        // Control under the keyboard: shift by the overlap plus padding.
        XCTAssertEqual(
            FlowTextInputOverlayBridge.keyboardShift(
                controlFrameInWindow: CGRect(x: 0, y: 480, width: 300, height: 50),
                currentShift: 0,
                keyboardMinY: 500,
                padding: 12
            ),
            42
        )
        // Already-shifted render: the current shift is undone before
        // comparing, so the result is absolute, not cumulative.
        XCTAssertEqual(
            FlowTextInputOverlayBridge.keyboardShift(
                controlFrameInWindow: CGRect(x: 0, y: 440, width: 300, height: 50),
                currentShift: 40,
                keyboardMinY: 500,
                padding: 12
            ),
            42
        )
    }

    func testResponseSetEventMapsCommittedValues() throws {
        let harness = try makeHarness()
        let bound = try XCTUnwrap(
            harness.artifact.manifest.textInputs.first {
                $0.inputId == "text-input/screen_1/email_input"
            }
        )
        let event = try XCTUnwrap(
            FlowScreenViewController.responseSetEvent(for: bound, text: "typed@nuxie.dev")
        )
        XCTAssertEqual(event.name, SystemEventNames.responseSet)
        XCTAssertEqual(event.properties["field"] as? String, "email")
        XCTAssertEqual(event.properties["value"] as? String, "typed@nuxie.dev")
        XCTAssertEqual(event.screenId, "screen_1")
        XCTAssertEqual(event.componentId, "text-input/screen_1/email_input")

        // Inputs without a response binding stay display-only.
        let unbound = try XCTUnwrap(
            harness.artifact.manifest.textInputs.first {
                $0.inputId == "text-input/screen_1/search_input"
            }
        )
        XCTAssertNil(FlowScreenViewController.responseSetEvent(for: unbound, text: "query"))
    }

    // MARK: Harness

    private var harnessRetainer: [Any] = []

    private func makeHarness() throws -> Harness {
        let root = try Self.fixtureURL(named: "text-input-motion")
        let rivData = try Data(contentsOf: root.appendingPathComponent("flow.riv"))
        let file = try RiveFile(
            data: rivData,
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
        let riveViewModel = RiveViewModel(
            model,
            animationName: nil,
            fit: .contain,
            alignment: .center,
            autoPlay: true,
            artboardName: "Paywall"
        )
        let riveView = riveViewModel.createRiveView()
        riveView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let viewModelBridge = FlowViewModelBridge(model: model)
        _ = try viewModelBridge.bindDefaultInstanceForActiveArtboard()

        let manifest = try JSONDecoder().decode(
            FlowArtifactManifest.self,
            from: Self.manifestJSON.data(using: .utf8)!
        )
        let remoteFlow = RemoteFlow(
            id: "flow-overlay-tests",
            flowArtifact: FlowArtifact(
                url: "https://example.com/flow-overlay-tests",
                buildId: "build-overlay-tests",
                manifest: BuildManifest(
                    totalFiles: 1,
                    totalSize: rivData.count,
                    contentHash: "test",
                    files: [
                        BuildFile(
                            path: "flow.riv",
                            size: rivData.count,
                            contentType: "application/octet-stream"
                        ),
                    ]
                )
            ),
            screens: [
                RemoteFlowScreen(id: "screen_1", defaultViewModelName: nil, defaultInstanceId: nil),
            ],
            viewModelValues: nil
        )
        let artifact = LoadedFlowArtifact(
            flow: Flow(remoteFlow: remoteFlow, products: []),
            directoryURL: root,
            rivURL: root.appendingPathComponent("flow.riv"),
            manifestURL: root.appendingPathComponent("nuxie-manifest.json"),
            manifest: manifest,
            assetURLsByRiveUniqueName: [:],
            source: .cachedArtifact,
            scriptsEnabled: false
        )

        let bridge = FlowTextInputOverlayBridge()
        bridge.onCommitText = { [weak self] input, text in
            self?.commits.append((input, text))
        }
        let harness = Harness(
            bridge: bridge,
            riveView: riveView,
            riveViewModel: riveViewModel,
            viewModelBridge: viewModelBridge,
            artifact: artifact
        )
        harnessRetainer.append(model)
        harness.rebind()
        return harness
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

    private static let manifestJSON = """
    {
      "version": 1,
      "flowId": "flow-overlay-tests",
      "buildId": "build-overlay-tests",
      "renderer": "rive",
      "riv": {
        "path": "flow.riv",
        "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
        "sizeBytes": 1
      },
      "entry": {
        "screenId": "screen_1",
        "artboardId": "screen_1",
        "artboardName": "Paywall",
        "width": 390,
        "height": 844
      },
      "screens": [
        {
          "screenId": "screen_1",
          "artboardId": "screen_1",
          "artboardName": "Paywall",
          "width": 390,
          "height": 844
        }
      ],
      "assets": { "images": [], "fonts": [] },
      "textInputs": [
        {
          "inputId": "text-input/screen_1/email_input",
          "screenId": "screen_1",
          "artboardId": "screen_1",
          "viewNodeId": "email_input",
          "renderedNodeId": "email_input",
          "riveTextObjectKey": "artboard/screen_1/email_input/text",
          "riveTextRunObjectKey": "artboard/screen_1/email_input/text-run",
          "riveTextName": "email_input",
          "riveTextRunName": "email_input Run",
          "geometry": {
            "xPath": "nuxieTextInputs/input_email_input_60a86a84/x",
            "yPath": "nuxieTextInputs/input_email_input_60a86a84/y",
            "widthPath": "nuxieTextInputs/input_email_input_60a86a84/width",
            "heightPath": "nuxieTextInputs/input_email_input_60a86a84/height",
            "rotationPath": "nuxieTextInputs/input_email_input_60a86a84/rotation",
            "scaleXPath": "nuxieTextInputs/input_email_input_60a86a84/scaleX",
            "scaleYPath": "nuxieTextInputs/input_email_input_60a86a84/scaleY"
          },
          "style": {
            "fontFamily": "Inter",
            "fontWeight": "400",
            "fontStyle": "normal",
            "fontSize": 17,
            "lineHeight": 24,
            "letterSpacing": 0,
            "color": 4279179050,
            "fontAssetRiveUniqueName": "font-inter-400-normal-f5eccb28-0",
            "textAlign": "left"
          },
          "value": "levi@nuxie.dev",
          "placeholder": "you@example.com",
          "editable": true,
          "keyboardType": "email-address",
          "responseFieldKey": "email"
        },
        {
          "inputId": "text-input/screen_1/search_input",
          "screenId": "screen_1",
          "artboardId": "screen_1",
          "viewNodeId": "search_input",
          "renderedNodeId": "search_input",
          "riveTextObjectKey": "artboard/screen_1/search_input/text",
          "riveTextRunObjectKey": "artboard/screen_1/search_input/text-run",
          "riveTextName": "search_input",
          "riveTextRunName": "search_input Run",
          "geometry": {
            "xPath": "nuxieTextInputs/input_email_input_60a86a84/x",
            "yPath": "nuxieTextInputs/input_email_input_60a86a84/y",
            "widthPath": "nuxieTextInputs/input_email_input_60a86a84/width",
            "heightPath": "nuxieTextInputs/input_email_input_60a86a84/height",
            "rotationPath": "nuxieTextInputs/input_email_input_60a86a84/rotation",
            "scaleXPath": "nuxieTextInputs/input_email_input_60a86a84/scaleX",
            "scaleYPath": "nuxieTextInputs/input_email_input_60a86a84/scaleY"
          },
          "style": {
            "fontFamily": "Inter",
            "fontWeight": "400",
            "fontStyle": "normal",
            "fontSize": 17,
            "lineHeight": 24,
            "letterSpacing": 0,
            "color": 4279179050,
            "fontAssetRiveUniqueName": "font-inter-400-normal-f5eccb28-0"
          },
          "value": "",
          "editable": true,
          "keyboardType": "web-search"
        }
      ]
    }
    """
}
#endif
