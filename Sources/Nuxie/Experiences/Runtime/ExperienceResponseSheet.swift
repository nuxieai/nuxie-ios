import Foundation
#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import NuxieRuntime

/// Reads one sheet from the native run at save time. Marking errors never filter answers.
enum ExperienceResponseSheet {
    static func read(form: String, declaration: JourneyReleaseValuePolicy.Form,
        snapshot: NuxieNativeViewModelSnapshot, catalog: NuxieNativeViewModelCatalog
    ) throws -> ExactJSONObject<JourneyReleaseJSONValue> {
        let values = Dictionary(grouping: snapshot.values, by: \.ownerInstanceID)
        func value(_ owner: UInt64, _ name: String) -> NuxieNativeViewModelValue? {
            values[owner]?.first { $0.name == name }?.value
        }
        guard case .referencedInstance(let owner) = value(snapshot.rootInstanceID, "responses:" + form),
              let instance = snapshot.instances.first(where: { $0.id == owner }),
              catalog.schemas.contains(where: { $0.index == instance.schemaIndex && $0.name == declaration.model }) else {
            throw invalid
        }
        var answers = ExactJSONObject<JourneyReleaseJSONValue>()
        for field in declaration.fields {
            guard let raw = value(owner, field.key) else { throw invalid }
            if ["number", "boolean"].contains(field.type) || (field.type == "enum" && field.multiple != true) {
                guard case .bool(let present) = value(owner, "isset:" + field.key) else { throw invalid }
                if !present { continue }
            }
            let answer: JourneyReleaseJSONValue
            switch (field.type, raw) {
            case ("number", .number(let number)) where number.isFinite:
                answer = .number(Double(number))
            case ("boolean", .bool(let flag)):
                answer = .bool(flag)
            case ("string", .bytes(let bytes)), ("date", .bytes(let bytes)):
                guard let text = String(data: bytes, encoding: .utf8) else { throw invalid }
                if text.isEmpty { continue }
                answer = .string(text)
            case ("enum", .integer(let index)) where field.multiple != true:
                guard let property = catalog.properties.first(where: {
                    $0.schemaIndex == instance.schemaIndex && $0.name == field.key
                }), property.kind == .enumeration, index < UInt64(property.enumLabels.count) else { throw invalid }
                answer = .string(property.enumLabels[Int(index)])
            case ("enum", .list(let children)) where field.multiple == true:
                var picked: [JourneyReleaseJSONValue] = []
                for child in children {
                    guard case .bool(let selected) = value(child, "picked") else { throw invalid }
                    if selected {
                        guard case .bytes(let bytes) = value(child, "value"),
                              let text = String(data: bytes, encoding: .utf8) else { throw invalid }
                        picked.append(.string(text))
                    }
                }
                if picked.isEmpty { continue }
                answer = .array(picked)
            default: throw invalid
            }
            answers[field.key] = answer
        }
        return answers
    }

    private static var invalid: ExperienceInteractiveScreenError {
        .stateContract("Native response form does not match its release")
    }
}
#endif
