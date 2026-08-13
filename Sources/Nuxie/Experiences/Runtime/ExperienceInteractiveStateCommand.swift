import Foundation

/// A Swift-owned state edit addressed with publisher identities. The native
/// runtime sees only the resolved view-model handle and typed mutation.
enum ExperienceInteractiveStateCommand: Equatable, Sendable {
    struct Value: Equatable, Sendable {
        let viewModelName: String
        let instanceID: String?
        let instanceName: String?
        let path: String
        let value: ExperienceInteractiveValue
    }

    enum ListEdit: Equatable, Sendable {
        case insert(index: Int?, value: ExperienceInteractiveValue)
        case remove(index: Int)
        case swap(first: Int, second: Int)
        case move(from: Int, to: Int)
        case set(index: Int, value: ExperienceInteractiveValue)
        case clear
    }

    case snapshot([Value])
    case value(Value)
    case trigger(
        viewModelName: String,
        instanceID: String?,
        instanceName: String?,
        path: String
    )
    case list(
        viewModelName: String,
        instanceID: String?,
        instanceName: String?,
        path: String,
        edit: ListEdit
    )
}

enum ExperienceInteractiveStateCommandError: LocalizedError, Equatable {
    case invalidValue(String)
    case invalidListEdit(String)

    var errorDescription: String? {
        switch self {
        case .invalidValue(let message), .invalidListEdit(let message):
            message
        }
    }
}

extension ExperienceInteractiveStateCommand {
    /// Removes Journey-authored writes into namespaces owned by the native
    /// screen lifecycle. SDK lifecycle commands bypass this projection and
    /// continue to use the same typed mutation lane.
    func suppressingLifecycleReservedJourneyWrites(
        rootViewModelName: String?,
        rootInstanceID: String?
    ) -> Self? {
        switch self {
        case .snapshot(let values):
            let filtered = values.compactMap {
                Self.suppressingLifecycleReservedJourneyWrite(
                    $0, rootViewModelName: rootViewModelName, rootInstanceID: rootInstanceID
                )
            }
            return filtered.isEmpty ? nil : .snapshot(filtered)
        case .value(let value):
            return Self.suppressingLifecycleReservedJourneyWrite(
                value, rootViewModelName: rootViewModelName, rootInstanceID: rootInstanceID
            ).map { .value($0) }
        case .trigger(let viewModelName, let instanceID, let instanceName, let path):
            guard !Self.isLifecycleReserved(
                path: path,
                viewModelName: viewModelName,
                instanceID: instanceID,
                instanceName: instanceName,
                rootViewModelName: rootViewModelName,
                rootInstanceID: rootInstanceID
            ) else { return nil }
            return .trigger(
                viewModelName: viewModelName,
                instanceID: instanceID,
                instanceName: instanceName,
                path: path
            )
        case .list(let viewModelName, let instanceID, let instanceName, let path, let edit):
            guard !Self.isLifecycleReserved(
                path: path,
                viewModelName: viewModelName,
                instanceID: instanceID,
                instanceName: instanceName,
                rootViewModelName: rootViewModelName,
                rootInstanceID: rootInstanceID
            ) else { return nil }
            return .list(
                viewModelName: viewModelName,
                instanceID: instanceID,
                instanceName: instanceName,
                path: path,
                edit: edit
            )
        }
    }

    private static func suppressingLifecycleReservedJourneyWrite(
        _ value: Value,
        rootViewModelName: String?,
        rootInstanceID: String?
    ) -> Value? {
        guard !isLifecycleReserved(
            path: value.path,
            viewModelName: value.viewModelName,
            instanceID: value.instanceID,
            instanceName: value.instanceName,
            rootViewModelName: rootViewModelName,
            rootInstanceID: rootInstanceID
        ) else { return nil }
        guard value.path.isEmpty, case .object(let fields) = value.value else {
            return value
        }
        let filtered = fields.filter {
            !isLifecycleReserved(
                path: $0.key,
                viewModelName: value.viewModelName,
                instanceID: value.instanceID,
                instanceName: value.instanceName,
                rootViewModelName: rootViewModelName,
                rootInstanceID: rootInstanceID
            )
        }
        guard !filtered.isEmpty else { return nil }
        return Value(
            viewModelName: value.viewModelName,
            instanceID: value.instanceID,
            instanceName: value.instanceName,
            path: value.path,
            value: .object(filtered)
        )
    }

    private static func isLifecycleReserved(
        path: String,
        viewModelName: String,
        instanceID: String?,
        instanceName: String?,
        rootViewModelName: String?,
        rootInstanceID: String?
    ) -> Bool {
        // The lifecycle contract reserves screen/env only on the screen's
        // root ViewModel INSTANCE; other instances of the same schema (and
        // any named instance) legitimately own identical leading segments,
        // mirroring ExperienceInteractiveScreen.ownerSelection.
        guard let rootViewModelName, viewModelName == rootViewModelName,
              instanceName == nil else {
            return false
        }
        // A nil instanceID addresses the screen's default (root) instance;
        // an explicit id must match the root instance to be reserved.
        if let instanceID, let rootInstanceID, instanceID != rootInstanceID {
            return false
        }
        guard let root = path.split(separator: "/", omittingEmptySubsequences: false).first else {
            return false
        }
        return root == "screen" || root == "env"
    }

    @MainActor
    static func snapshot(_ snapshot: ExperienceViewModelSnapshot) throws -> Self {
        .snapshot(try snapshot.values.map {
            Value(
                viewModelName: $0.viewModelName,
                instanceID: $0.instanceId,
                instanceName: $0.instanceName,
                path: $0.path,
                value: try interactiveValue($0.value.value)
            )
        })
    }

    @MainActor
    static func value(
        path: VmPathRef,
        rawValue: Any,
        instanceID: String?,
        defaultViewModelName: String?
    ) throws -> Self {
        guard let viewModelName = path.viewModelName ?? defaultViewModelName else {
            throw ExperienceInteractiveStateCommandError.invalidValue(
                "State path '\(path.path)' has no view-model identity"
            )
        }
        return .value(Value(
            viewModelName: viewModelName,
            instanceID: instanceID,
            instanceName: nil,
            path: path.path,
            value: try interactiveValue(rawValue)
        ))
    }

    @MainActor
    static func list(
        operation: ExperienceViewModelListOperation,
        path: VmPathRef,
        payload: [String: Any],
        instanceID: String?,
        defaultViewModelName: String?
    ) throws -> Self {
        guard let viewModelName = path.viewModelName ?? defaultViewModelName else {
            throw ExperienceInteractiveStateCommandError.invalidValue(
                "List path '\(path.path)' has no view-model identity"
            )
        }
        let edit: ListEdit
        switch operation {
        case .insert:
            edit = .insert(
                index: try optionalInsertIndex(payload["index"]),
                value: try interactiveValue(payload["value"] ?? NSNull())
            )
        case .remove:
            edit = .remove(index: try requiredIndex(payload["index"], label: "remove"))
        case .swap:
            edit = .swap(
                first: try requiredIndex(
                    payload["from"] ?? payload["indexA"],
                    label: "swap source"
                ),
                second: try requiredIndex(
                    payload["to"] ?? payload["indexB"],
                    label: "swap destination"
                )
            )
        case .move:
            edit = .move(
                from: try requiredIndex(payload["from"], label: "move source"),
                to: try requiredIndex(payload["to"], label: "move destination")
            )
        case .set:
            edit = .set(
                index: try requiredIndex(payload["index"], label: "set"),
                value: try interactiveValue(payload["value"] ?? NSNull())
            )
        case .clear:
            guard payload.isEmpty else {
                throw ExperienceInteractiveStateCommandError.invalidListEdit(
                    "List clear does not accept a payload"
                )
            }
            edit = .clear
        }
        return .list(
            viewModelName: viewModelName,
            instanceID: instanceID,
            instanceName: nil,
            path: path.path,
            edit: edit
        )
    }

    @MainActor
    private static func interactiveValue(_ raw: Any) throws
        -> ExperienceInteractiveValue
    {
        do {
            return try ExperienceInteractiveStateCompiler.decode(raw)
        } catch ExperienceInteractiveScreenError.stateContract(let reason) {
            throw ExperienceInteractiveStateCommandError.invalidValue(
                "Unsupported interactive state value: \(reason)"
            )
        } catch {
            throw ExperienceInteractiveStateCommandError.invalidValue(
                "Unsupported interactive state value: \(String(describing: error))"
            )
        }
    }

    private static func requiredIndex(_ raw: Any?, label: String) throws -> Int {
        guard let value = try optionalIndex(raw) else {
            throw ExperienceInteractiveStateCommandError.invalidListEdit(
                "List \(label) index is required"
            )
        }
        return value
    }

    private static func optionalIndex(_ raw: Any?) throws -> Int? {
        guard let raw else { return nil }
        let value: Int?
        if let integer = raw as? Int {
            value = integer
        } else if let number = raw as? NSNumber {
            let double = number.doubleValue
            value = double.isFinite && double.rounded() == double
                ? Int(exactly: double)
                : nil
        } else {
            value = nil
        }
        guard let value, value >= 0 else {
            throw ExperienceInteractiveStateCommandError.invalidListEdit(
                "List index must be a non-negative integer"
            )
        }
        return value
    }

    private static func optionalInsertIndex(_ raw: Any?) throws -> Int? {
        guard let raw else { return nil }
        let value: Int?
        if let integer = raw as? Int {
            value = integer
        } else if let number = raw as? NSNumber {
            let double = number.doubleValue
            value = double.isFinite && double.rounded() == double
                ? Int(exactly: double)
                : nil
        } else {
            value = nil
        }
        guard let value else {
            throw ExperienceInteractiveStateCommandError.invalidListEdit(
                "List index must be an integer"
            )
        }
        return max(0, value)
    }
}
