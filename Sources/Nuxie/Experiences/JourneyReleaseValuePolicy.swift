import Foundation
import NuxieRuntime

/// Signed declarations and native rule records. These contain no live or starting values.
struct JourneyReleaseValuePolicy: Codable, Sendable {
    struct State: Codable, Sendable {
        let type: String
        let values: [String]?
        let multiple: Bool?
        let items: [String: State]?
    }
    struct Rule: Codable, Sendable {
        let model, property: String
        let kind, mode: UInt32
        let number_bound: Double
        let text: String
        let values: [String]
        let value_count: UInt32
        let picked_property: String
        let bound_flags, minimum, maximum: UInt32
        let code, message: String
    }
    struct Field: Codable, Sendable {
        let key, label, type: String
        let values: [String]?
        let multiple: Bool?
        let rules: [Rule]
    }
    struct Form: Codable, Sendable {
        let title, model: String
        let fields: [Field]
    }
    struct Member: Codable, Sendable {
        let property, errors_path, item_model, code_property, message_property: String
    }
    struct Group: Codable, Sendable {
        let model, valid: String
        let member_count: UInt32
        let members: [Member]
    }
    let state: [String: State]
    let responses: [String: Form]
    let ruleGroups: [Group]

    static func validate(_ root: [String: Any]) throws {
        // Check keys before Codable can discard them, including recursive state items.
        let state = try object(root["state"])
        for (key, value) in state { try name(key); try stateShape(value) }
        let forms = try object(root["responses"])
        for (key, value) in forms {
            try name(key)
            let form = try shape(value, ["title", "model", "fields"])
            for value in try array(form["fields"]) {
                let field = try shape(value, ["key", "label", "type", "rules"], ["values", "multiple"])
                for rule in try array(field["rules"]) {
                    _ = try shape(rule, ["model", "property", "kind", "mode", "number_bound", "text", "values",
                        "value_count", "picked_property", "bound_flags", "minimum", "maximum", "code", "message"])
                }
            }
        }
        for value in try array(root["ruleGroups"]) {
            let group = try shape(value, ["model", "valid", "member_count", "members"])
            for member in try array(group["members"]) {
                _ = try shape(member, ["property", "errors_path", "item_model", "code_property", "message_property"])
            }
        }
        let bytes = try JSONSerialization.data(withJSONObject: ["state": state, "responses": forms,
            "ruleGroups": try array(root["ruleGroups"])])
        let policy = try JSONDecoder().decode(Self.self, from: bytes)
        for value in policy.state.values { try validateState(value) }
        try policy.validateForms()
    }

    private func validateForms() throws {
        guard ruleGroups.count == responses.count, ruleGroups.count <= 4096 else { throw invalid }
        var models = Set<String>()
        var rules = 0, members = ruleGroups.count, ruleBytes = 0, groupBytes = 0
        for group in ruleGroups {
            guard models.insert(group.model).inserted, group.valid == "valid",
                  let form = responses.first(where: { "Responses:\($0.key)" == group.model })?.value,
                  group.members.count <= 4096, group.members.count == form.fields.count,
                  group.member_count == group.members.count else { throw invalid }
            groupBytes += 48 + group.model.utf8.count + group.valid.utf8.count
            members += group.members.count
            for (member, field) in zip(group.members, form.fields) {
                try Self.name(member.property)
                guard member.property == field.key, member.errors_path == "errors/\(member.property)",
                      member.item_model == "ResponseError", member.code_property == "rule",
                      member.message_property == "message" else { throw invalid }
                groupBytes += 80 + [member.property, member.errors_path, member.item_model,
                    member.code_property, member.message_property].reduce(0) { $0 + $1.utf8.count }
            }
        }
        for (name, form) in responses {
            guard form.model == "Responses:\(name)", models.contains(form.model), form.fields.count <= 4096,
                  Set(form.fields.map(\.key)).count == form.fields.count else { throw invalid }
            for field in form.fields {
                try Self.name(field.key)
                guard !["valid", "errors", "saving", "saved", "saveError"].contains(field.key),
                      ["string", "number", "boolean", "enum", "date"].contains(field.type),
                      (field.type == "enum") == (field.values != nil),
                      field.multiple == nil || (field.multiple == true && field.type == "enum"),
                      field.rules.count <= 4096 else { throw invalid }
                try Self.choices(field.values)
                for rule in field.rules {
                    try Self.validateRule(rule)
                    guard rule.model == form.model, rule.property == field.key else { throw invalid }
                    let allowed = rule.kind == 10
                        || (field.type == "number" && [1, 2].contains(rule.kind))
                        || (field.type == "string" && [8, 9, 11].contains(rule.kind))
                        || (field.type == "date" && [3, 4, 12].contains(rule.kind))
                        || (field.type == "enum" && rule.kind == (field.multiple == true ? 7 : 5))
                    guard allowed, rule.kind != 5 || rule.values == field.values else { throw invalid }
                    rules += 1
                    ruleBytes += 152 + [rule.model, rule.property, rule.text, rule.picked_property, rule.code,
                        rule.message].reduce(0) { $0 + $1.utf8.count }
                        + rule.values.reduce(0) { $0 + 16 + $1.utf8.count }
                }
            }
        }
        guard rules <= 4096, members <= 4096, ruleBytes <= 8 * 1024 * 1024,
              groupBytes <= 8 * 1024 * 1024 else { throw invalid }
    }

    private static func validateRule(_ r: Rule) throws {
        try name(r.property)
        try choices(r.values)
        guard !r.model.isEmpty, !r.code.isEmpty, !r.message.isEmpty,
              [1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12].contains(r.kind), r.mode <= 1,
              r.number_bound.isFinite, r.values.count <= 4096, r.value_count == r.values.count,
              r.bound_flags <= 2 else { throw invalid }
        let expected: [UInt32: (UInt32, String)] = [1: (0, "min"), 2: (1, "max"), 3: (0, "min"),
            4: (1, "max"), 5: (1, "values"), 10: (0, "required"), 11: (0, "format"), 12: (0, "date")]
        if let (mode, code) = expected[r.kind] {
            guard r.mode == mode, r.code == code else { throw invalid }
        }
        if [7, 8].contains(r.kind) {
            let minimum = r.bound_flags == 1
            let code = r.kind == 7 ? (minimum ? "minItems" : "maxItems") : (minimum ? "minLength" : "maxLength")
            guard r.bound_flags != 0, r.mode == (minimum ? 0 : 1), r.code == code,
                  minimum ? r.maximum == 0 : r.minimum == 0 else { throw invalid }
        } else if r.bound_flags != 0 || r.minimum != 0 || r.maximum != 0 { throw invalid }
        guard r.kind != 9 || (r.mode == 0 && ["format", "pattern"].contains(r.code)),
              [1, 2].contains(r.kind) || r.number_bound == 0,
              [3, 4, 9].contains(r.kind) || r.text.isEmpty,
              r.kind == 5 || r.values.isEmpty,
              r.picked_property == (r.kind == 7 ? "picked" : "") else { throw invalid }
    }

    private static func validateState(_ value: State) throws {
        guard ["string", "number", "boolean", "color", "enum", "date", "list", "trigger", "image"].contains(value.type),
              (value.type == "enum") == (value.values != nil), (value.type == "list") == (value.items != nil),
              value.multiple == nil || (value.multiple == true && value.type == "enum") else { throw invalid }
        try choices(value.values)
        if let items = value.items { for item in items.values { try validateState(item) } }
    }
    private static func choices(_ values: [String]?) throws {
        if let values, Set(values).count != values.count { throw invalid }
    }
    private static func stateShape(_ value: Any) throws {
        let state = try shape(value, ["type"], ["values", "multiple", "items"])
        if let items = state["items"] {
            for (key, item) in try object(items) { try name(key); try stateShape(item) }
        }
    }
    private static func name(_ value: String) throws {
        guard value.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
              !["true", "false", "null"].contains(value) else { throw invalid }
    }
    private static func object(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw invalid }; return value
    }
    private static func array(_ value: Any?) throws -> [Any] {
        guard let value = value as? [Any] else { throw invalid }; return value
    }
    private static func shape(_ value: Any?, _ required: Set<String>, _ optional: Set<String> = []) throws -> [String: Any] {
        let object = try object(value), keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)),
              !object.values.contains(where: { $0 is NSNull }) else { throw invalid }
        return object
    }
    private static var invalid: JourneyReleaseAuthenticationError { .invalidDescriptor }
    private var invalid: JourneyReleaseAuthenticationError { Self.invalid }
}

#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
extension JourneyReleaseValuePolicy {
    var native: NuxieNativeValuePolicy {
        .init(rules: responses.sorted { $0.key < $1.key }.flatMap { $0.value.fields }.flatMap(\.rules).map {
            .init(model: $0.model, property: $0.property, kind: $0.kind, mode: $0.mode,
                numberBound: $0.number_bound, text: $0.text, values: $0.values,
                pickedProperty: $0.picked_property, boundFlags: $0.bound_flags,
                minimum: Int($0.minimum), maximum: Int($0.maximum), code: $0.code, message: $0.message)
        }, groups: ruleGroups.map {
            .init(model: $0.model, valid: $0.valid, members: $0.members.map {
                .init(property: $0.property, errorsPath: $0.errors_path, itemModel: $0.item_model,
                    codeProperty: $0.code_property, messageProperty: $0.message_property)
            })
        })
    }
}
#endif
