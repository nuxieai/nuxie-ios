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
        let raw = unwrap(raw)
        switch raw {
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as String:
            return .string(value)
        case let value as Data:
            return .bytes(value)
        case let value as NSNumber:
            return .number(value.doubleValue)
        case let values as [Any]:
            return .list(try values.map(interactiveValue))
        case let values as [AnyCodable]:
            return .list(try values.map { try interactiveValue($0.value) })
        case let object as [String: Any]:
            return .object(try object.keys.sorted().map { key in
                ExperienceInteractiveField(
                    key: key,
                    value: try interactiveValue(object[key] ?? NSNull())
                )
            })
        case let object as [String: AnyCodable]:
            return .object(try object.keys.sorted().map { key in
                ExperienceInteractiveField(
                    key: key,
                    value: try interactiveValue(object[key]?.value ?? NSNull())
                )
            })
        default:
            throw ExperienceInteractiveStateCommandError.invalidValue(
                "Unsupported interactive state value of type \(type(of: raw))"
            )
        }
    }

    private static func unwrap(_ raw: Any) -> Any {
        if let value = raw as? AnyCodable { return unwrap(value.value) }
        if let literal = raw as? [String: Any],
           literal.count == 1,
           let value = literal["literal"] {
            return unwrap(value)
        }
        return raw
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
