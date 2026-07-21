import Foundation

public struct FlowViewModelSnapshot: Codable {
    public let values: [RemoteFlowViewModelValue]

    public init(values: [RemoteFlowViewModelValue]) {
        self.values = values
    }

    public init(viewModelInstances: [ViewModelInstance]) {
        self.values = viewModelInstances.flatMap { instance in
            instance.values.map { path, value in
                RemoteFlowViewModelValue(
                    viewModelName: instance.viewModelId,
                    instanceId: instance.instanceId,
                    instanceName: instance.name,
                    path: path,
                    value: value
                )
            }
        }
    }

    public var viewModelInstances: [ViewModelInstance] {
        var grouped: [String: (viewModelName: String, instanceId: String, instanceName: String?, values: [String: AnyCodable])] = [:]
        for value in values {
            let instanceId = value.instanceId ?? "\(value.viewModelName):default"
            let key = "\(value.viewModelName)\u{1f}\(instanceId)"
            var entry = grouped[key] ?? (
                viewModelName: value.viewModelName,
                instanceId: instanceId,
                instanceName: value.instanceName,
                values: [:]
            )
            entry.values[value.path] = value.value
            grouped[key] = entry
        }
        return grouped.values
            .sorted {
                $0.viewModelName == $1.viewModelName
                    ? $0.instanceId < $1.instanceId
                    : $0.viewModelName < $1.viewModelName
            }
            .map {
                ViewModelInstance(
                    viewModelId: $0.viewModelName,
                    instanceId: $0.instanceId,
                    name: $0.instanceName,
                    values: $0.values
                )
            }
    }
}

private struct FlowViewModelValueKey: Hashable {
    let viewModelName: String
    let instanceId: String?
    let path: String
}

private struct ResolvedFlowPath {
    let viewModelName: String
    let instanceId: String?
    let instanceName: String?
    let path: String
    let key: FlowViewModelValueKey
}

private struct FlowViewModelScreenDefaults {
    let viewModelName: String?
    let instanceId: String?
}

/// Small SDK-owned path/value store used to evaluate flow-description values,
/// dispatch did-set behavior, and persist snapshots between renderer updates.
final class ExperienceViewModelStateCoordinator {
    private var values: [FlowViewModelValueKey: AnyCodable] = [:]
    private let screenDefaults: [String: FlowViewModelScreenDefaults]
    private let triggerPaths: Set<String>
    private var instanceNames: [String: String] = [:]
    private var instanceViewModelNames: [String: String] = [:]
    private var defaultInstanceByViewModelName: [String: String] = [:]
    private var firstViewModelName: String?

    init(screens: RemoteFlow) {
        self.screenDefaults = Dictionary(
            uniqueKeysWithValues: screens.screens.map {
                (
                    $0.id,
                    FlowViewModelScreenDefaults(
                        viewModelName: $0.defaultViewModelName,
                        instanceId: $0.defaultInstanceId
                    )
                )
            }
        )
        self.triggerPaths = Self.collectTriggerPaths(from: screens)
        hydrate(FlowViewModelSnapshot(values: screens.viewModelValues ?? []))
    }

    func getSnapshot() -> FlowViewModelSnapshot {
        let entries = values.map { key, value in
            RemoteFlowViewModelValue(
                viewModelName: key.viewModelName,
                instanceId: key.instanceId,
                instanceName: key.instanceId.flatMap { instanceNames[$0] },
                path: key.path,
                value: value
            )
        }
        return FlowViewModelSnapshot(
            values: entries.sorted {
                if $0.viewModelName != $1.viewModelName {
                    return $0.viewModelName < $1.viewModelName
                }
                if ($0.instanceId ?? "") != ($1.instanceId ?? "") {
                    return ($0.instanceId ?? "") < ($1.instanceId ?? "")
                }
                return $0.path < $1.path
            }
        )
    }

    func hydrate(_ snapshot: FlowViewModelSnapshot) {
        values.removeAll()
        instanceNames.removeAll()
        instanceViewModelNames.removeAll()
        defaultInstanceByViewModelName.removeAll()
        firstViewModelName = nil

        for defaults in screenDefaults.values {
            if firstViewModelName == nil, let viewModelName = defaults.viewModelName {
                firstViewModelName = viewModelName
            }
            if let viewModelName = defaults.viewModelName, let instanceId = defaults.instanceId {
                instanceViewModelNames[instanceId] = viewModelName
                defaultInstanceByViewModelName[viewModelName] = defaultInstanceByViewModelName[viewModelName] ?? instanceId
            }
        }

        for value in snapshot.values {
            recordMetadata(value)
            let key = FlowViewModelValueKey(
                viewModelName: value.viewModelName,
                instanceId: value.instanceId,
                path: value.path
            )
            values[key] = value.value
        }
    }

    func isTriggerPath(path: VmPathRef, screenId: String?) -> Bool {
        triggerPaths.contains(path.normalizedPath)
    }

    func setValue(
        path: VmPathRef,
        value: Any,
        screenId: String?,
        instanceId: String? = nil
    ) -> Bool {
        guard let resolved = resolve(path, screenId: screenId, instanceId: instanceId) else { return false }
        values[resolved.key] = AnyCodable(resolveLiteralValue(value))
        if let instanceId = resolved.instanceId {
            instanceViewModelNames[instanceId] = resolved.viewModelName
        }
        if firstViewModelName == nil {
            firstViewModelName = resolved.viewModelName
        }
        return true
    }

    func getValue(path: VmPathRef, screenId: String?, instanceId: String? = nil) -> Any? {
        guard let resolved = resolve(path, screenId: screenId, instanceId: instanceId) else { return nil }
        if let exact = values[resolved.key] {
            return exact.value
        }
        if resolved.instanceId != nil {
            let defaultKey = FlowViewModelValueKey(
                viewModelName: resolved.viewModelName,
                instanceId: nil,
                path: resolved.path
            )
            return values[defaultKey]?.value
        }
        if let defaultInstanceId = defaultInstanceByViewModelName[resolved.viewModelName] {
            let defaultKey = FlowViewModelValueKey(
                viewModelName: resolved.viewModelName,
                instanceId: defaultInstanceId,
                path: resolved.path
            )
            return values[defaultKey]?.value
        }
        return nil
    }

    func setListValue(
        path: VmPathRef,
        operation: String,
        payload: [String: Any],
        screenId: String?,
        instanceId: String? = nil
    ) -> Bool {
        guard let resolved = resolve(path, screenId: screenId, instanceId: instanceId) else { return false }
        let current = values[resolved.key]?.value
        var array = arrayValue(current)

        switch operation {
        case "insert":
            let value = payload["value"] ?? NSNull()
            if let index = payload["index"] as? Int {
                array.insert(value, at: max(0, min(index, array.count)))
            } else {
                array.append(value)
            }
        case "remove":
            guard let index = payload["index"] as? Int, index >= 0, index < array.count else { return false }
            array.remove(at: index)
        case "swap":
            guard let from = payload["from"] as? Int,
                  let to = payload["to"] as? Int,
                  from >= 0,
                  to >= 0,
                  from < array.count,
                  to < array.count
            else {
                return false
            }
            array.swapAt(from, to)
        case "move":
            guard let from = payload["from"] as? Int,
                  let to = payload["to"] as? Int,
                  from >= 0,
                  from < array.count,
                  to >= 0,
                  to <= array.count
            else {
                return false
            }
            let item = array.remove(at: from)
            array.insert(item, at: min(max(to, 0), array.count))
        case "set":
            guard let index = payload["index"] as? Int, index >= 0, index < array.count else { return false }
            array[index] = payload["value"] ?? NSNull()
        case "clear":
            array.removeAll()
        default:
            return false
        }

        values[resolved.key] = AnyCodable(array)
        return true
    }

    private func recordMetadata(_ value: RemoteFlowViewModelValue) {
        if firstViewModelName == nil {
            firstViewModelName = value.viewModelName
        }
        if let instanceId = value.instanceId {
            instanceViewModelNames[instanceId] = value.viewModelName
            defaultInstanceByViewModelName[value.viewModelName] = defaultInstanceByViewModelName[value.viewModelName] ?? instanceId
            if let instanceName = value.instanceName {
                instanceNames[instanceId] = instanceName
            }
        }
    }

    private func resolve(_ path: VmPathRef, screenId: String?, instanceId: String?) -> ResolvedFlowPath? {
        let defaults = screenId.flatMap { screenDefaults[$0] }
        let viewModelName =
            path.viewModelName ??
            instanceId.flatMap { instanceViewModelNames[$0] } ??
            defaults?.instanceId.flatMap { instanceViewModelNames[$0] } ??
            defaults?.viewModelName ??
            firstViewModelName
        guard let viewModelName, !path.path.isEmpty else { return nil }
        let screenDefaultInstanceId = defaults?.instanceId
        let screenDefaultViewModelName =
            screenDefaultInstanceId.flatMap { instanceViewModelNames[$0] } ??
            defaults?.viewModelName
        let screenDefaultInstanceForResolvedViewModel =
            screenDefaultViewModelName == viewModelName ? screenDefaultInstanceId : nil
        let resolvedInstanceId =
            instanceId ??
            screenDefaultInstanceForResolvedViewModel ??
            defaultInstanceByViewModelName[viewModelName]
        return ResolvedFlowPath(
            viewModelName: viewModelName,
            instanceId: resolvedInstanceId,
            instanceName: resolvedInstanceId.flatMap { instanceNames[$0] },
            path: path.path,
            key: FlowViewModelValueKey(
                viewModelName: viewModelName,
                instanceId: resolvedInstanceId,
                path: path.path
            )
        )
    }

    private func resolveLiteralValue(_ value: Any) -> Any {
        if let anyCodable = value as? AnyCodable {
            return resolveLiteralValue(anyCodable.value)
        }
        if let dict = value as? [String: Any], dict.count == 1, let literal = dict["literal"] {
            return literal
        }
        if let dict = value as? [String: AnyCodable], dict.count == 1, let literal = dict["literal"]?.value {
            return literal
        }
        return value
    }

    private func arrayValue(_ value: Any?) -> [Any] {
        if let array = value as? [Any] {
            return array.map { unwrap($0) }
        }
        if let array = value as? [AnyCodable] {
            return array.map { unwrap($0.value) }
        }
        return []
    }

    private func unwrap(_ value: Any) -> Any {
        if let anyCodable = value as? AnyCodable {
            return anyCodable.value
        }
        return value
    }

    private static func collectTriggerPaths(from screens: RemoteFlow) -> Set<String> {
        var paths = Set<String>()
        for handlers in screens.handlers.values {
            for handler in handlers {
                collectTriggerPaths(from: handler.actions, into: &paths)
            }
        }
        return paths
    }

    private static func collectTriggerPaths(
        from actions: [JourneyAction],
        into paths: inout Set<String>
    ) {
        for action in actions {
            switch action {
            case .fireTrigger(let action):
                paths.insert(action.path.normalizedPath)
            case .condition(let action):
                for branch in action.branches {
                    collectTriggerPaths(from: branch.actions, into: &paths)
                }
                if let defaultActions = action.defaultActions {
                    collectTriggerPaths(from: defaultActions, into: &paths)
                }
            case .experiment(let action):
                for variant in action.variants {
                    collectTriggerPaths(from: variant.actions, into: &paths)
                }
            case .timeWindow(let action):
                if let successActions = action.successActions {
                    collectTriggerPaths(from: successActions, into: &paths)
                }
            default:
                continue
            }
        }
    }
}
