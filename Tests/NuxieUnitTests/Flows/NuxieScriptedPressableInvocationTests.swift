import RiveRuntime
import XCTest

@testable import Nuxie

/// End-to-end coverage for the locked device-script attachment model: a
/// publish-pipeline-emitted `.riv` (see `Fixtures/README.md`) carries a
/// pressable whose generated state-machine press-release listener holds a
/// riv-native `ScriptedListenerAction` referencing the embedded script.
/// Pressing the pressable must run the script's `performAction`, which calls
/// `Nuxie.response.set("plan", "pro")` and `Nuxie.trigger("purchase_tapped")`
/// through the bridge.
final class NuxieScriptedPressableInvocationTests: XCTestCase {
    private static let artboardName = "Paywall"
    private static let stateMachineName = "Generated Nuxie Pressable Visual State"
    /// Center of the fixture's CTA (x:24 y:700 w:342 h:56) in artboard space.
    private static let ctaCenter = CGPoint(x: 195, y: 728)

    private func fixtureData() throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(
            forResource: "publish_scripted_pressable",
            withExtension: "riv",
            subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "publish_scripted_pressable", withExtension: "riv")
        return try Data(contentsOf: XCTUnwrap(url))
    }

    private func makePressedStateMachine(
        bridge: NuxieRiveScriptBridge
    ) throws -> RiveStateMachineInstance {
        let riveFile = try RiveFile(
            data: fixtureData(),
            loadCdn: false,
            scriptRuntime: bridge.scriptRuntime
        )
        let model = RiveModel(riveFile: riveFile)
        try model.setArtboard(Self.artboardName)
        try model.setStateMachine(Self.stateMachineName)
        let stateMachine = try XCTUnwrap(model.stateMachine)
        _ = stateMachine.advance(by: 0.016)

        let began = stateMachine.touchBegan(atLocation: Self.ctaCenter)
        _ = stateMachine.advance(by: 0.016)
        let ended = stateMachine.touchEnded(atLocation: Self.ctaCenter)
        _ = stateMachine.advance(by: 0.016)
        XCTAssertEqual(began, .hit)
        XCTAssertEqual(ended, .hit)
        return stateMachine
    }

    func testPressRunsBoundScriptThroughScriptedListenerAction() throws {
        let bridge = NuxieRiveScriptBridge()
        bridge.scriptRuntime.allowsUnverifiedScripts = true

        let stateMachine = try makePressedStateMachine(bridge: bridge)
        defer { _ = stateMachine }

        let events = bridge.drainEvents(currentScreenId: "screen_1")
        XCTAssertEqual(
            events.map(\.name).sorted(),
            [SystemEventNames.responseSet, "purchase_tapped"].sorted()
        )
        let responseSet = try XCTUnwrap(
            events.first { $0.name == SystemEventNames.responseSet }
        )
        XCTAssertEqual(responseSet.properties["field"] as? String, "plan")
        XCTAssertEqual(responseSet.properties["value"] as? String, "pro")
    }

    func testPressRunsNothingWithoutScriptOptIn() throws {
        let bridge = NuxieRiveScriptBridge()
        // allowsUnverifiedScripts stays NO — the artifact's manifest
        // signature did not verify, so the embedded script never registers
        // and the press must be inert.

        let stateMachine = try makePressedStateMachine(bridge: bridge)
        defer { _ = stateMachine }

        XCTAssertTrue(bridge.drainEvents(currentScreenId: "screen_1").isEmpty)
    }
}
