#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieRuntime

/// Typed, source-independent state compiler shared by signed package state and
/// live host commands. Source policy is limited to trust-boundary differences;
/// catalog lookup, identity envelopes, paths, and scalar conversion stay common.
struct ExperienceInteractiveStateCompiler {
    enum Policy: Equatable, Sendable {
        case signedPackage
        case liveCommand

        var source: String {
            switch self {
            case .signedPackage: "signed initial state"
            case .liveCommand: "live state command"
            }
        }

        var acceptsBinaryStrings: Bool {
            switch self {
            case .signedPackage: false
            case .liveCommand: true
            }
        }
    }

    enum Scalar: Equatable, Sendable {
        case string(Data)
        case number(Float)
        case bool(Bool)
        case color(UInt32)
        case enumeration(UInt64)
        case trigger
        case listIndex(UInt64)
        case image(UInt64)
    }

    struct Envelope: Equatable, Sendable {
        let identity: ExperienceInteractiveViewModelIdentity
        let schema: NuxieNativeViewModelCatalog.Schema
        let values: [ExperienceInteractiveField]

        var instanceName: String? { identity.instanceName }
    }

    private struct FlattenedEnvelopeKey: Hashable {
        let owner: ExperienceInteractiveViewModelIdentity
        let property: String
    }

    let catalog: NuxieNativeViewModelCatalog
    let imageIDsByName: [String: UInt64]
    let policy: Policy

    init(
        catalog: NuxieNativeViewModelCatalog,
        imageIDsByName: [String: UInt64] = [:],
        policy: Policy
    ) {
        self.catalog = catalog
        self.imageIDsByName = imageIDsByName
        self.policy = policy
    }

    static func decode(_ rawValue: Any) throws -> ExperienceInteractiveValue {
        let rawValue = unwrap(rawValue)
        switch rawValue {
        case is NSNull:
            return .null
        case let value as String:
            return .string(value)
        case let value as Data:
            return .bytes(value)
        case let value as NSNumber:
            return CFGetTypeID(value) == CFBooleanGetTypeID()
                ? .bool(value.boolValue)
                : .number(value.doubleValue)
        case let value as Bool:
            return .bool(value)
        case let values as [Any]:
            return .list(try values.map(decode))
        case let values as [AnyCodable]:
            return .list(try values.map { try decode($0.value) })
        case let object as [String: Any]:
            return .object(try object.keys.sorted().map { key in
                ExperienceInteractiveField(
                    key: key,
                    value: try decode(object[key] ?? NSNull())
                )
            })
        case let object as [String: AnyCodable]:
            return .object(try object.keys.sorted().map { key in
                ExperienceInteractiveField(
                    key: key,
                    value: try decode(object[key]?.value ?? NSNull())
                )
            })
        default:
            throw ExperienceInteractiveScreenError.stateContract(
                "unsupported state value of type \(type(of: rawValue))"
            )
        }
    }

    static func signedValues(
        _ values: [JourneyViewModelValue]
    ) throws -> [ExperienceInteractiveStateCommand.Value] {
        try values.map { value in
            ExperienceInteractiveStateCommand.Value(
                viewModelName: value.viewModelName,
                instanceID: value.instanceId,
                instanceName: value.instanceName,
                path: value.path,
                value: try decode(value.value.value)
            )
        }
    }

    func schema(named name: String) throws -> NuxieNativeViewModelCatalog.Schema {
        let matches = catalog.schemas.filter { $0.name == name }
        guard matches.count == 1, let schema = matches.first else {
            throw ExperienceInteractiveScreenError.stateContract(
                "view model '\(name)' does not resolve exactly once"
            )
        }
        return schema
    }

    func property(
        at path: String,
        startingWith initialSchemaIndex: Int
    ) throws -> NuxieNativeViewModelCatalog.Property {
        let exactMatches = catalog.properties.filter {
            $0.schemaIndex == initialSchemaIndex && $0.name == path
        }
        if exactMatches.count == 1, let exact = exactMatches.first {
            return exact
        }
        if exactMatches.count > 1 {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model property '\(path)' is ambiguous in the authenticated catalog"
            )
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !segments.isEmpty, !segments.contains(where: \.isEmpty) else {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model property '\(path)' has an invalid path"
            )
        }
        var schemaIndex = initialSchemaIndex
        for (offset, segment) in segments.enumerated() {
            let matches = catalog.properties.filter {
                $0.schemaIndex == schemaIndex && $0.name == segment
            }
            guard matches.count == 1, let property = matches.first else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "view-model property '\(path)' is absent or ambiguous in the authenticated catalog"
                )
            }
            if offset == segments.count - 1 { return property }
            guard property.kind == .viewModel,
                  let referencedSchemaIndex = property.referencedSchemaIndex else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "view-model property '\(path)' crosses a non-composite value"
                )
            }
            schemaIndex = referencedSchemaIndex
        }
        throw ExperienceInteractiveScreenError.stateContract(path)
    }

    func normalizeFlattenedEnvelopes(
        _ values: [ExperienceInteractiveStateCommand.Value]
    ) throws -> [ExperienceInteractiveStateCommand.Value] {
        var keyByIndex: [Int: FlattenedEnvelopeKey] = [:]
        var indexesByKey: [FlattenedEnvelopeKey: [Int]] = [:]
        var identityKeys = Set<FlattenedEnvelopeKey>()
        var directKeys = Set<FlattenedEnvelopeKey>()

        for (index, value) in values.enumerated() {
            let segments = value.path
                .split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)
            guard !segments.isEmpty, !segments.contains(where: \.isEmpty) else { continue }
            let ownerSchema = try schema(named: value.viewModelName)
            let outerMatches = catalog.properties.filter {
                $0.schemaIndex == ownerSchema.index && $0.name == segments[0]
            }
            guard outerMatches.count == 1, outerMatches[0].kind == .viewModel else { continue }
            let key = FlattenedEnvelopeKey(
                owner: .init(
                    viewModelName: value.viewModelName,
                    instanceID: value.instanceID,
                    instanceName: value.instanceName
                ),
                property: segments[0]
            )
            if segments.count == 1 {
                directKeys.insert(key)
                continue
            }
            keyByIndex[index] = key
            indexesByKey[key, default: []].append(index)
            if segments.count == 2,
               segments[1] == "vmInstanceId" || segments[1] == "instanceId" {
                identityKeys.insert(key)
            }
        }
        guard directKeys.isDisjoint(with: identityKeys) else {
            throw ExperienceInteractiveScreenError.stateContract(
                "\(policy.source) contains direct and flattened values for one view-model property"
            )
        }

        var normalized: [ExperienceInteractiveStateCommand.Value] = []
        normalized.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            guard let key = keyByIndex[index], identityKeys.contains(key),
                  let grouped = indexesByKey[key] else {
                normalized.append(value)
                continue
            }
            guard grouped.first == index else { continue }
            var envelope: [String: ExperienceInteractiveValue] = [:]
            for groupedIndex in grouped {
                let item = values[groupedIndex]
                let suffix = item.path.split(separator: "/").dropFirst().map(String.init)
                try insert(
                    item.value,
                    path: suffix,
                    into: &envelope,
                    propertyPath: key.property
                )
            }
            if envelope["viewModelId"] == nil {
                let ownerSchema = try schema(named: key.owner.viewModelName)
                let property = try self.property(
                    at: key.property,
                    startingWith: ownerSchema.index
                )
                guard let childSchemaIndex = property.referencedSchemaIndex,
                      let childSchema = catalog.schemas.first(where: {
                          $0.index == childSchemaIndex
                      }) else {
                    throw ExperienceInteractiveScreenError.stateContract(
                        "flattened view-model envelope '\(key.property)' has no authenticated schema"
                    )
                }
                envelope["viewModelId"] = .string(childSchema.name)
            }
            _ = try identityFields(envelope, path: key.property)
            normalized.append(.init(
                viewModelName: key.owner.viewModelName,
                instanceID: key.owner.instanceID,
                instanceName: key.owner.instanceName,
                path: key.property,
                value: .object(envelope.keys.sorted().map {
                    ExperienceInteractiveField(key: $0, value: envelope[$0] ?? .null)
                })
            ))
        }
        return normalized
    }

    func envelope(
        from value: ExperienceInteractiveValue,
        expectedSchemaIndex: Int?,
        schemaHints: [String: String] = [:],
        path: String
    ) throws -> Envelope {
        guard case .object(let fields) = value else {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model reference at '\(path)' requires an object value"
            )
        }
        let object = try Self.uniqueObject(fields, label: "view-model envelope")
        let identity = try identityFields(object, path: path)
        let expectedSchema = expectedSchemaIndex.flatMap { expected in
            catalog.schemas.first(where: { $0.index == expected })
        }
        if expectedSchemaIndex != nil, expectedSchema == nil {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model reference at '\(path)' has no authored schema"
            )
        }
        let explicitName: String? = switch object["viewModelId"] {
        case .string(let name): name
        default: nil
        }
        let hintedName = identity.stableID.flatMap { schemaHints[$0] }
        if let explicitName, let hintedName, explicitName != hintedName {
            throw ExperienceInteractiveScreenError.stateContract(
                "instance '\(identity.stableID ?? "")' names multiple view models"
            )
        }
        let resolvedSchema = try schema(
            named: explicitName ?? hintedName ?? expectedSchema?.name ?? ""
        )
        if let expectedSchema, expectedSchema.index != resolvedSchema.index {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model reference at '\(path)' names '\(resolvedSchema.name)' instead of "
                    + "'\(expectedSchema.name)'"
            )
        }
        return Envelope(
            identity: .init(
                viewModelName: resolvedSchema.name,
                instanceID: identity.stableID,
                instanceName: identity.instanceName
            ),
            schema: resolvedSchema,
            values: try Self.canonicalEnvelopeFields(fields)
        )
    }

    func scalar(
        for property: NuxieNativeViewModelCatalog.Property,
        value: ExperienceInteractiveValue,
        path: String
    ) throws -> Scalar {
        switch (property.kind, value) {
        case (.string, .string(let value)):
            return .string(Data(value.utf8))
        case (.string, .bytes(let value)) where policy.acceptsBinaryStrings:
            return .string(value)
        case (.number, .number(let value)) where value.isFinite:
            let converted = Float(value)
            guard converted.isFinite else {
                throw invalidValue(path, kind: property.kind)
            }
            return .number(converted)
        case (.bool, .bool(let value)):
            return .bool(value)
        case (.color, .number(let value)):
            guard let value = Self.exactUnsigned(value), value <= UInt32.max else {
                throw invalidValue(path, kind: property.kind)
            }
            return .color(UInt32(value))
        case (.enumeration, .string(let label)):
            guard let index = property.enumLabels.firstIndex(of: label) else {
                throw invalidValue(path, kind: property.kind)
            }
            return .enumeration(UInt64(index))
        case (.enumeration, .number(let value)):
            guard let value = Self.exactUnsigned(value) else {
                throw invalidValue(path, kind: property.kind)
            }
            return .enumeration(value)
        case (.trigger, .bool(true)):
            return .trigger
        case (.trigger, .number(let value)):
            let shouldFire = switch policy {
            case .signedPackage:
                Self.exactUnsigned(value).map { $0 != 0 } == true
            case .liveCommand:
                value.isFinite && value != 0
            }
            guard shouldFire else {
                throw invalidValue(path, kind: property.kind)
            }
            return .trigger
        case (.listIndex, .number(let value)):
            guard let value = Self.exactUnsigned(value) else {
                throw invalidValue(path, kind: property.kind)
            }
            return .listIndex(value)
        case (.image, .string(let name)):
            guard let value = imageIDsByName[name] else {
                throw invalidValue(path, kind: property.kind)
            }
            return .image(value)
        case (.image, .number(let value)):
            guard let value = Self.exactUnsigned(value) else {
                throw invalidValue(path, kind: property.kind)
            }
            return .image(value)
        default:
            throw invalidValue(path, kind: property.kind)
        }
    }

    static func canonicalEnvelopeFields(
        _ fields: [ExperienceInteractiveField]
    ) throws -> [ExperienceInteractiveField] {
        let object = try uniqueObject(fields, label: "view-model envelope")
        let metadata = Set([
            "viewModelId", "vmInstanceId", "instanceId", "instanceName", "values",
        ])
        var values = object.filter { !metadata.contains($0.key) }
        if let nested = object["values"] {
            guard case .object(let nestedFields) = nested else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "view-model envelope has non-object values"
                )
            }
            for (key, value) in try uniqueObject(nestedFields, label: "view-model envelope") {
                guard values.updateValue(value, forKey: key) == nil else {
                    throw ExperienceInteractiveScreenError.stateContract(
                        "view-model envelope conflicts on '\(key)'"
                    )
                }
            }
        }
        return values.keys.sorted().map {
            ExperienceInteractiveField(key: $0, value: values[$0] ?? .null)
        }
    }

    static func uniqueObject(
        _ fields: [ExperienceInteractiveField],
        label: String
    ) throws -> [String: ExperienceInteractiveValue] {
        var result: [String: ExperienceInteractiveValue] = [:]
        for field in fields {
            guard result.updateValue(field.value, forKey: field.key) == nil else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "\(label) repeats '\(field.key)'"
                )
            }
        }
        return result
    }

    static func exactUnsigned(_ number: Double) -> UInt64? {
        guard number.isFinite, number >= 0, number.rounded() == number else { return nil }
        return UInt64(exactly: number)
    }

    private struct IdentityFields {
        let stableID: String?
        let instanceName: String?
    }

    private func identityFields(
        _ object: [String: ExperienceInteractiveValue],
        path: String
    ) throws -> IdentityFields {
        let vmInstanceID: String? = switch object["vmInstanceId"] {
        case .string(let value): value
        default: nil
        }
        let instanceID: String? = switch object["instanceId"] {
        case .string(let value): value
        default: nil
        }
        if let vmInstanceID, let instanceID, vmInstanceID != instanceID {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model reference at '\(path)' has conflicting stable identities"
            )
        }
        let stableID = vmInstanceID ?? instanceID
        if stableID?.isEmpty == true {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model reference at '\(path)' requires a nonempty stable identity"
            )
        }
        let instanceName: String? = switch object["instanceName"] {
        case .string(let value): value
        default: nil
        }
        if stableID == nil,
           !(policy == .liveCommand && instanceName?.isEmpty == false) {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model reference at '\(path)' requires a nonempty stable identity"
            )
        }
        return IdentityFields(stableID: stableID, instanceName: instanceName)
    }

    private func insert(
        _ value: ExperienceInteractiveValue,
        path: [String],
        into object: inout [String: ExperienceInteractiveValue],
        propertyPath: String
    ) throws {
        guard let key = path.first, !key.isEmpty else {
            throw ExperienceInteractiveScreenError.stateContract(
                "flattened view-model envelope '\(propertyPath)' has an empty path"
            )
        }
        if path.count == 1 {
            guard object[key] == nil else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "flattened view-model envelope '\(propertyPath)' repeats '\(key)'"
                )
            }
            object[key] = value
            return
        }
        var nested: [String: ExperienceInteractiveValue]
        if case .object(let fields)? = object[key] {
            nested = try Self.uniqueObject(fields, label: "flattened view-model envelope")
        } else if object[key] == nil {
            nested = [:]
        } else {
            throw ExperienceInteractiveScreenError.stateContract(
                "flattened view-model envelope '\(propertyPath)' has conflicting '\(key)' values"
            )
        }
        try insert(
            value,
            path: Array(path.dropFirst()),
            into: &nested,
            propertyPath: propertyPath
        )
        object[key] = .object(nested.keys.sorted().map {
            ExperienceInteractiveField(key: $0, value: nested[$0] ?? .null)
        })
    }

    private func invalidValue(
        _ path: String,
        kind: NuxieNativeViewModelPropertyKind
    ) -> ExperienceInteractiveScreenError {
        .stateContract(
            "\(policy.source) value for '\(path)' does not match \(kind)"
        )
    }

    private static func unwrap(_ rawValue: Any) -> Any {
        if let value = rawValue as? AnyCodable { return unwrap(value.value) }
        if let literal = rawValue as? [String: Any],
           literal.count == 1, let value = literal["literal"] {
            return unwrap(value)
        }
        return rawValue
    }
}
#endif
