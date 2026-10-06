import Foundation
#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import NuxieRuntime
#endif

/// A timed wait's durable copy. Native instance identities never leave the process.
struct ExperienceRunSnapshot: Codable, Equatable, Sendable {
    struct Field: Codable, Equatable, Sendable {
        let path: String
        let kind: UInt32
        let value: Value
    }
    enum Value: Codable, Equatable, Sendable {
        case bytes(Data), number(Float), bool(Bool), integer(UInt64)
    }
    let fields: [Field]

    #if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
    init(native: NuxieNativeViewModelSnapshot, catalog: NuxieNativeViewModelCatalog) {
        let instances = Dictionary(uniqueKeysWithValues: native.instances.map { ($0.id, $0) })
        var fields: [Field] = []
        func visit(_ id: UInt64, prefix: String, ancestors: Set<UInt64>) {
            guard !ancestors.contains(id), let instance = instances[id] else { return }
            let ancestors = ancestors.union([id])
            for entry in native.values[instance.valueRange] {
                let path = prefix + entry.name
                guard let property = catalog.properties.first(where: {
                    $0.schemaIndex == instance.schemaIndex && $0.index == entry.propertyIndex
                }) else { continue }
                let value: Value
                switch entry.value {
                case .referencedInstance(let child):
                    visit(child, prefix: path + "/", ancestors: ancestors)
                    continue
                case .bytes(let data): value = .bytes(data)
                case .number(let number): value = .number(number)
                case .bool(let flag): value = .bool(flag)
                case .integer(let integer):
                    guard property.kind != .trigger else { continue }
                    value = .integer(integer)
                case .list, .unsupported: continue
                }
                fields.append(.init(path: path, kind: property.kind.rawValue, value: value))
            }
        }
        visit(native.rootInstanceID, prefix: "", ancestors: [])
        self.fields = fields
    }

    func mutations(for reference: NuxieNativeViewModelReference) throws -> [NuxieNativeViewModelMutation] {
        try fields.map { field in
            switch (NuxieNativeViewModelPropertyKind(rawValue: field.kind), field.value) {
            case (.string, .bytes(let value)): return .setString(instance: reference, path: field.path, value: value)
            case (.number, .number(let value)): return .setNumber(instance: reference, path: field.path, value: value)
            case (.bool, .bool(let value)): return .setBool(instance: reference, path: field.path, value: value)
            case (.color, .integer(let value)) where value <= UInt32.max:
                return .setColor(instance: reference, path: field.path, value: UInt32(value))
            case (.enumeration, .integer(let value)): return .setEnumeration(instance: reference, path: field.path, value: value)
            case (.listIndex, .integer(let value)): return .setListIndex(instance: reference, path: field.path, value: value)
            case (.image, .integer(let value)): return .setImage(instance: reference, path: field.path, value: value)
            default: throw ExperienceInteractiveScreenError.stateContract("Invalid run snapshot field")
            }
        }
    }
    #endif

    var journeyValues: ExactJSONObject<JourneyReleaseJSONValue> {
        var result = ExactJSONObject<JourneyReleaseJSONValue>()
        for field in fields {
            let value: JourneyReleaseJSONValue
            switch field.value {
            case .bytes(let data):
                guard let text = String(data: data, encoding: .utf8) else { continue }
                value = .string(text)
            case .number(let number): value = .number(Double(number))
            case .bool(let flag): value = .bool(flag)
            case .integer(let integer): value = .number(Double(integer))
            }
            result[field.path] = value
        }
        return result
    }
}
