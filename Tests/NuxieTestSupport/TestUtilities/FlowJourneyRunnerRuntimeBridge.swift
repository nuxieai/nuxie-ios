import Foundation
@testable import Nuxie

/// Serializes native renderer callbacks onto a single execution context,
/// mirroring production (JourneyService is an actor).
actor FlowJourneyRunnerRuntimeBridge {
    private let runner: JourneyRunner
    private let distinctId: String
    private var didHandleReady = false
    private var currentScreenId: String?

    init(runner: JourneyRunner, distinctId: String = "test-user") {
        self.runner = runner
        self.distinctId = distinctId
    }

    func handleReady() async {
        guard !didHandleReady else { return }
        didHandleReady = true
        _ = await runner.handleRuntimeReady()
    }

    func handleScreenChanged(_ screenId: String) async {
        currentScreenId = screenId
        _ = await runner.handleScreenChanged(screenId)
    }

    func handleEvent(_ event: ExperienceRendererEvent) async {
        let runtimeEvent = NuxieEvent(
            name: event.name,
            distinctId: distinctId,
            properties: event.properties
        )
        _ = await runner.dispatchScreenEvent(
            runtimeEvent,
            screenId: event.screenId ?? currentScreenId,
            componentId: event.componentId,
            instanceId: event.instanceId
        )
    }

    func handleViewModelChange(_ change: ExperienceRendererViewModelChange) async {
        _ = await runner.handleDidSet(
            path: change.path,
            value: change.value,
            source: change.source,
            screenId: change.screenId ?? currentScreenId,
            instanceId: change.instanceId,
            isTrigger: change.isTrigger
        )
    }
}

final class FlowJourneyRunnerRuntimeDelegate: FlowRuntimeDelegate {
    typealias OnEvent = (_ type: String, _ payload: [String: Any]) -> Void

    private let bridge: FlowJourneyRunnerRuntimeBridge
    private let onEvent: OnEvent?
    private let traceRecorder: FlowRuntimeTraceRecorder?

    init(
        bridge: FlowJourneyRunnerRuntimeBridge,
        onEvent: OnEvent? = nil,
        traceRecorder: FlowRuntimeTraceRecorder? = nil
    ) {
        self.bridge = bridge
        self.onEvent = onEvent
        self.traceRecorder = traceRecorder
    }

    func flowViewControllerDidBecomeReady(_ controller: ExperienceViewController) {
        onEvent?("renderer/ready", [:])
        Task { [bridge] in
            await bridge.handleReady()
        }
    }

    func flowViewController(
        _ controller: ExperienceViewController,
        didChangeScreen screenId: String
    ) {
        traceRecorder?.recordRendererScreenChanged(screenId: screenId)
        onEvent?("renderer/screen_changed", ["screenId": screenId])
        Task { [bridge] in
            await bridge.handleScreenChanged(screenId)
        }
    }

    func flowViewController(
        _ controller: ExperienceViewController,
        didEmitEvent event: ExperienceRendererEvent
    ) {
        var payload = event.properties
        payload["name"] = event.name
        if let screenId = event.screenId {
            payload["screenId"] = screenId
        }
        if let componentId = event.componentId {
            payload["componentId"] = componentId
        }
        if let instanceId = event.instanceId {
            payload["instanceId"] = instanceId
        }
        traceRecorder?.recordEvent(name: event.name, properties: event.properties)
        onEvent?("renderer/event", payload)
        Task { [bridge] in
            await bridge.handleEvent(event)
        }
    }

    func flowViewController(
        _ controller: ExperienceViewController,
        didEmitViewModelChange change: ExperienceRendererViewModelChange
    ) {
        traceRecorder?.recordRendererBindingChange(
            screenId: change.screenId,
            path: change.path.normalizedPath,
            value: change.value,
            source: change.source,
            instanceId: change.instanceId
        )
        onEvent?(
            "renderer/view_model_change",
            [
                "value": change.value,
                "source": change.source as Any,
                "screenId": change.screenId as Any,
                "instanceId": change.instanceId as Any
            ]
        )
        Task { [bridge] in
            await bridge.handleViewModelChange(change)
        }
    }

    func flowViewControllerDidRequestDismiss(_ controller: ExperienceViewController, reason: CloseReason) {
        // Not used in these E2E tests.
    }

}
