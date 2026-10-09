#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)

package struct NuxieNativeValueMarker: Sendable, Equatable {
    package let model: String
    package let value: String
    package let marker: String

    package init(model: String, value: String, marker: String) {
        self.model = model
        self.value = value
        self.marker = marker
    }
}

package struct NuxieNativeValueRule: Sendable, Equatable {
    package let model: String
    package let property: String
    package let kind: UInt32
    package let mode: UInt32
    package let numberBound: Double
    package let text: String
    package let values: [String]
    package let pickedProperty: String
    package let boundFlags: UInt32
    package let minimum: Int
    package let maximum: Int
    package let code: String
    package let message: String

    package init(model: String, property: String, kind: UInt32, mode: UInt32, numberBound: Double, text: String, values: [String], pickedProperty: String, boundFlags: UInt32, minimum: Int, maximum: Int, code: String, message: String) {
        self.model = model
        self.property = property
        self.kind = kind
        self.mode = mode
        self.numberBound = numberBound
        self.text = text
        self.values = values
        self.pickedProperty = pickedProperty
        self.boundFlags = boundFlags
        self.minimum = minimum
        self.maximum = maximum
        self.code = code
        self.message = message
    }
}

package struct NuxieNativeRuleGroupMember: Sendable, Equatable {
    package let property: String
    package let errorsPath: String
    package let itemModel: String
    package let codeProperty: String
    package let messageProperty: String

    package init(property: String, errorsPath: String, itemModel: String, codeProperty: String, messageProperty: String) {
        self.property = property
        self.errorsPath = errorsPath
        self.itemModel = itemModel
        self.codeProperty = codeProperty
        self.messageProperty = messageProperty
    }
}

package struct NuxieNativeRuleGroup: Sendable, Equatable {
    package let model: String
    package let valid: String
    package let members: [NuxieNativeRuleGroupMember]

    package init(model: String, valid: String, members: [NuxieNativeRuleGroupMember]) {
        self.model = model
        self.valid = valid
        self.members = members
    }
}

package enum NuxieNativeValueRuleKind {
    package static let numberMinimum: UInt32 = 1
    package static let numberMaximum: UInt32 = 2
    package static let textMinimum: UInt32 = 3
    package static let textMaximum: UInt32 = 4
    package static let allowedValues: UInt32 = 5
    package static let itemCount: UInt32 = 6
    package static let pickedCount: UInt32 = 7
    package static let length: UInt32 = 8
    package static let pattern: UInt32 = 9
    package static let required: UInt32 = 10
    package static let url: UInt32 = 11
    package static let date: UInt32 = 12
}

package enum NuxieNativeValueRuleMode {
    package static let mark: UInt32 = 0
    package static let refuse: UInt32 = 1
}

package enum NuxieNativeValueRuleBounds {
    package static let minimum: UInt32 = 1
    package static let maximum: UInt32 = 2
}
#endif

#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
/// Installed on every fresh file before any instance, player or mutation exists.
package struct NuxieNativeValuePolicy: Sendable, Equatable {
    package let rules: [NuxieNativeValueRule]
    package let groups: [NuxieNativeRuleGroup]
    package static let empty = Self(rules: [], groups: [])

    package init(rules: [NuxieNativeValueRule], groups: [NuxieNativeRuleGroup]) {
        self.rules = rules
        self.groups = groups
    }

    package func groupsForInstallation(markers: [NuxieNativeValueMarker]) -> [NuxieNativeRuleGroup] {
        var installed: [String: Set<String>] = [:]
        for rule in rules { installed[rule.model, default: []].insert(rule.property) }
        for marker in markers { installed[marker.model, default: []].insert(marker.value) }
        // Native groups accept only ruled or marked members. Keep the declared table intact.
        return groups.map { group in
            NuxieNativeRuleGroup(model: group.model, valid: group.valid, members: group.members.filter {
                installed[group.model]?.contains($0.property) == true
            })
        }
    }

    package func markers(in catalog: NuxieNativeViewModelCatalog) throws -> [NuxieNativeValueMarker] {
        var result: [NuxieNativeValueMarker] = []
        for schema in catalog.schemas {
            let properties = catalog.properties.filter { $0.schemaIndex == schema.index }
            for value in properties where [.number, .bool, .color, .enumeration].contains(value.kind) {
                let markerName = value.name.hasPrefix("state:")
                    ? "state:isset:" + value.name.dropFirst("state:".count) : "isset:" + value.name
                guard let marker = properties.first(where: { $0.name == markerName }) else { continue }
                guard marker.kind == .bool else {
                    throw NuxieNativeRuntimeError.invalidNativeValue("value marker must be boolean")
                }
                result.append(.init(model: schema.name, value: value.name, marker: markerName))
            }
        }
        return result
    }
}
#endif
