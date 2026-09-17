#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation

/// Joins a native occurrence with its signed product identity using the graph
/// captured with the event frame. Retained handles alone do not prove liveness.
enum ExperienceInteractiveEventSource {
    static func project(
        _ event: ExperienceInteractiveReportedEvent,
        nativeID: UInt64?,
        rootID: UInt64?,
        liveIDs: Set<UInt64>,
        identities: [ExperienceInteractiveViewModelIdentity: ExperienceInteractiveViewModelReference]
    ) -> ExperienceInteractiveReportedEvent {
        guard let nativeID else { return event }
        func reject(_ reason: String) -> ExperienceInteractiveReportedEvent {
            var rejected = event
            rejected.sourceRejection = reason
            return rejected
        }
        guard liveIDs.contains(nativeID) else {
            return reject("event source is absent from the current view-model graph")
        }
        let aliases = Set(identities.compactMap { identity, reference in
            reference.rawValue == nativeID ? identity.instanceID : nil
        })
        guard aliases.count <= 1, aliases.count == 1 || nativeID == rootID else {
            return reject("event source has no unique authenticated instance identity")
        }
        let alias = aliases.first
        if let alias, identities.contains(where: {
            $0.key.instanceID == alias && $0.value.rawValue != nativeID
        }) {
            return reject("event source identity refers to multiple native instances")
        }
        let declared = event.properties.filter { ["instanceId", "instance_id"].contains($0.key) }
        guard declared.count <= 1 else {
            return reject("event source contains duplicate instance identities")
        }
        if let declared = declared.first {
            let value: String?
            switch declared.value {
            case .string(let text): value = text
            case .bytes(let bytes): value = String(data: bytes, encoding: .utf8)
            default: value = nil
            }
            guard let value, !value.isEmpty, value == alias else {
                return reject("event instance identity conflicts with its native source")
            }
        }
        guard declared.isEmpty, let alias else { return event }
        return ExperienceInteractiveReportedEvent(
            localIndex: event.localIndex, coreType: event.coreType, name: event.name,
            url: event.url, target: event.target, delay: event.delay,
            properties: event.properties + [.init(key: "instanceId", value: .string(alias))]
        )
    }
}
#endif
