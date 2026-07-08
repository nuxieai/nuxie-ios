import Foundation

struct FlowScriptEventGate {
    private let screenId: String
    private let script: ScreenScriptRef?
    private let declaredEventNames: Set<String>

    init(remoteFlow: RemoteFlow, screenId: String) {
        self.screenId = screenId
        self.script = remoteFlow.scripts[screenId]
        self.declaredEventNames = Set(
            remoteFlow.events[screenId, default: []].map(\.eventName)
        )
    }

    func allows(_ event: FlowRendererEvent) -> Bool {
        guard let script,
              script.enabled != false,
              script.protocol == "listenerAction" else {
            return false
        }

        if event.name == SystemEventNames.responseSet {
            return true
        }

        let scriptEventNames = Set(script.eventNames ?? [])
        guard !scriptEventNames.isEmpty,
              scriptEventNames.contains(event.name) else {
            return false
        }

        return declaredEventNames.contains(event.name)
    }

    func rejectionReason(for event: FlowRendererEvent) -> String {
        guard let script else {
            return "missing_script_ref"
        }
        if script.enabled == false {
            return "script_disabled"
        }
        if script.protocol != "listenerAction" {
            return "unsupported_protocol"
        }
        if event.name == SystemEventNames.responseSet {
            return "allowed"
        }
        let scriptEventNames = Set(script.eventNames ?? [])
        if !scriptEventNames.contains(event.name) {
            return "event_not_declared_by_script"
        }
        if !declaredEventNames.contains(event.name) {
            return "event_not_declared_by_flow"
        }
        return "allowed"
    }
}
