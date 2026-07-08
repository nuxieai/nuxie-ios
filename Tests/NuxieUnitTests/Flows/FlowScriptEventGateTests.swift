@testable import Nuxie
import XCTest

final class FlowScriptEventGateTests: XCTestCase {
    func testAllowsScriptDeclaredFlowDeclaredEvent() {
        let gate = FlowScriptEventGate(
            remoteFlow: makeRemoteFlow(
                eventNames: ["purchase_tapped"],
                scriptEventNames: ["purchase_tapped"]
            ),
            screenId: "screen_1"
        )

        XCTAssertTrue(gate.allows(event(named: "purchase_tapped")))
    }

    func testAllowsResponseSetBuiltInForEnabledListenerActionScript() {
        let gate = FlowScriptEventGate(
            remoteFlow: makeRemoteFlow(
                eventNames: [],
                scriptEventNames: []
            ),
            screenId: "screen_1"
        )

        XCTAssertTrue(gate.allows(event(named: SystemEventNames.responseSet)))
    }

    func testRejectsEventsNotDeclaredByScript() {
        let gate = FlowScriptEventGate(
            remoteFlow: makeRemoteFlow(
                eventNames: ["purchase_tapped"],
                scriptEventNames: ["other_event"]
            ),
            screenId: "screen_1"
        )

        let event = event(named: "purchase_tapped")
        XCTAssertFalse(gate.allows(event))
        XCTAssertEqual(gate.rejectionReason(for: event), "event_not_declared_by_script")
    }

    func testRejectsEventsNotDeclaredByFlow() {
        let gate = FlowScriptEventGate(
            remoteFlow: makeRemoteFlow(
                eventNames: [],
                scriptEventNames: ["purchase_tapped"]
            ),
            screenId: "screen_1"
        )

        let event = event(named: "purchase_tapped")
        XCTAssertFalse(gate.allows(event))
        XCTAssertEqual(gate.rejectionReason(for: event), "event_not_declared_by_flow")
    }

    func testRejectsDisabledScript() {
        let gate = FlowScriptEventGate(
            remoteFlow: makeRemoteFlow(
                eventNames: ["purchase_tapped"],
                scriptEventNames: ["purchase_tapped"],
                scriptEnabled: false
            ),
            screenId: "screen_1"
        )

        let event = event(named: "purchase_tapped")
        XCTAssertFalse(gate.allows(event))
        XCTAssertEqual(gate.rejectionReason(for: event), "script_disabled")
    }

    private func makeRemoteFlow(
        eventNames: [String],
        scriptEventNames: [String],
        scriptEnabled: Bool? = true
    ) -> RemoteFlow {
        RemoteFlow(
            id: "flow-1",
            flowArtifact: FlowArtifact(
                url: "https://example.com/flow",
                buildId: "build-1",
                manifest: BuildManifest(
                    totalFiles: 0,
                    totalSize: 0,
                    contentHash: "hash",
                    files: []
                )
            ),
            screens: [RemoteFlowScreen(id: "screen_1")],
            events: [
                "screen_1": eventNames.map {
                    EventDeclaration(id: "event-\($0)", eventName: $0)
                }
            ],
            handlers: [:],
            scripts: [
                "screen_1": ScreenScriptRef(
                    id: "script-ref-1",
                    scriptId: "script-1",
                    assetId: "asset-1",
                    protocol: "listenerAction",
                    enabled: scriptEnabled,
                    eventNames: scriptEventNames
                )
            ],
            viewModelValues: nil
        )
    }

    private func event(named name: String) -> FlowRendererEvent {
        FlowRendererEvent(
            name: name,
            properties: [:],
            screenId: "screen_1",
            componentId: nil,
            instanceId: nil
        )
    }
}
