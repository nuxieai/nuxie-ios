import Foundation
@testable import Nuxie

/// Serializes native renderer callbacks onto a single execution context,
/// mirroring production (JourneyService is an actor).
actor ExperienceJourneyRunnerRuntimeBridge {
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

    func handleBatch(_ batch: ScreenEmissionBatch) async {
        for event in batch.emissions where !event.name.hasPrefix("$") {
            let runtimeEvent = NuxieEvent(
                id: event.id,
                name: event.name,
                distinctId: distinctId,
                properties: event.payload.mapValues(\.foundationValue)
            )
            _ = await runner.dispatchScreenEvent(
                runtimeEvent,
                screenId: batch.source.screenId,
                componentId: batch.source.componentId,
                instanceId: batch.source.instanceId
            )
        }
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

final class ExperienceJourneyRunnerRuntimeDelegate: ExperienceRuntimeDelegate {
    typealias OnEvent = (_ type: String, _ payload: [String: Any]) -> Void

    private let bridge: ExperienceJourneyRunnerRuntimeBridge
    private let onEvent: OnEvent?
    private let traceRecorder: ExperienceRuntimeTraceRecorder?

    init(
        bridge: ExperienceJourneyRunnerRuntimeBridge,
        onEvent: OnEvent? = nil,
        traceRecorder: ExperienceRuntimeTraceRecorder? = nil
    ) {
        self.bridge = bridge
        self.onEvent = onEvent
        self.traceRecorder = traceRecorder
    }

    func experienceViewControllerDidBecomeReady(_ controller: ExperienceViewController) {
        onEvent?("renderer/ready", [:])
        Task { [bridge] in
            await bridge.handleReady()
        }
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didChangeScreen screenId: String
    ) async {
        traceRecorder?.recordRendererScreenChanged(screenId: screenId)
        onEvent?("renderer/screen_changed", ["screenId": screenId])
        await bridge.handleScreenChanged(screenId)
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didEmitScreenEmissionBatch batch: ScreenEmissionBatch
    ) async -> Bool {
        for event in batch.emissions {
            let properties = event.payload.mapValues(\.foundationValue)
            traceRecorder?.recordEvent(name: event.name, properties: properties)
            onEvent?("renderer/event", [
                "name": event.name,
                "screenId": batch.source.screenId,
                "componentId": batch.source.componentId as Any,
                "instanceId": batch.source.instanceId as Any,
            ].merging(properties) { _, value in value })
        }
        await bridge.handleBatch(batch)
        return true
    }

    func experienceViewController(
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

    func experienceViewControllerDidRequestDismiss(_ controller: ExperienceViewController, reason: CloseReason) {
        // Not used in these E2E tests.
    }

}
