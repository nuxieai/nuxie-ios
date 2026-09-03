import Foundation

/// Mirrors the flat leg grammar before Codable can discard unknown fields.
/// Common render, commerce and action validation stays shared with the release
/// verifier; this grammar validates the complete current Journey release.
enum JourneyReleaseSchemaValidator {
    private typealias Common = JourneyReleaseSchemaPrimitives

    static func validate(_ value: [String: Any]) throws {
        let root = try object(value, required: ["schemaVersion", "identity", "metadata", "presentation", "leg",
            "products", "placements", "viewModelValues", "screenBehaviors", "render", "requirements", "provenance"])
        guard root["schemaVersion"] as? String == JourneyReleaseDescriptor.wireSchemaVersion else { throw invalid }
        try Common.validateMetadata(root)
        try Common.validatePresentation(root["presentation"])
        let placements = try Common.validateCommerce(root)
        try Common.validateProvenance(root)
        let screens = try validateLeg(root["leg"], placements: placements)
        try Common.validateResponseContract(schema: nil, captures: [], behaviors: root["screenBehaviors"], screenIDs: screens)
        if screens.isEmpty {
            guard root["render"] is NSNull, root["requirements"] is NSNull else { throw invalid }
        } else {
            try Common.validateRenderRequirements(root)
            let render = try dictionary(root["render"])
            let renderScreens = try array(render["screens"]).map { try identifier(dictionary($0)["id"]) }
            guard Set(renderScreens) == screens, Set(renderScreens).count == renderScreens.count else { throw invalid }
        }
        let products = try Set(array(root["products"]).map { try identifier(dictionary($0)["id"]) })
        let leg = try dictionary(root["leg"])
        let gate = try dictionary(leg["entitlementGate"])
        for product in try array(gate["products"]) {
            guard products.contains(try identifier(dictionary(product)["productId"])) else { throw invalid }
        }
        for item in try array(root["viewModelValues"]) {
            let value = try object(item, required: ["viewModelName", "path", "value"], optional: ["instanceId", "instanceName"])
            _ = try identifier(value["viewModelName"])
            guard value["path"] is String else { throw invalid }
            for key in ["instanceId", "instanceName"] where value[key] != nil { _ = try identifier(value[key]) }
        }
    }

    static func validateEntry(_ value: Any?) throws {
        let entry = try dictionary(value)
        switch entry["type"] as? String {
        case "app_foregrounded": _ = try object(entry, required: ["type"], optional: ["condition"])
        case "event":
            _ = try object(entry, required: ["type", "eventName"], optional: ["condition"])
            _ = try identifier(entry["eventName"])
        case "segment":
            _ = try object(entry, required: ["type", "segmentId", "member"], optional: ["condition"])
            _ = try identifier(entry["segmentId"])
            try boolean(entry["member"])
        default: throw invalid
        }
        if let condition = entry["condition"] {
            let bytes = try JSONSerialization.data(withJSONObject: condition)
            let envelope = try JSONDecoder().decode(IREnvelope.self, from: bytes)
            guard envelope.ir_version == 1, envelope.isSupportedByThisEngine else { throw invalid }
        }
    }

    private static func validateLeg(_ value: Any?, placements: Set<String>) throws -> Set<String> {
        let leg = try object(value, required: ["schemaVersion", "id", "entryCondition", "entryStepId", "steps", "routes",
            "screens", "reentry", "entitlementGate", "facts", "inputs", "outputs", "completionOutputs"])
        guard leg["schemaVersion"] as? String == "nuxie.experience-planes.v1" else { throw invalid }
        try digest(leg["id"])
        try validateEntry(leg["entryCondition"])
        let reentry = try dictionary(leg["reentry"])
        switch reentry["type"] as? String {
        case "one_time", "every_time": _ = try object(reentry, required: ["type"])
        case "once_per_window":
            _ = try object(reentry, required: ["type", "windowSeconds"])
            try integer(reentry["windowSeconds"], minimum: 1)
        default: throw invalid
        }
        let screenList = try array(leg["screens"])
        let screens = try Set(screenList.map { item -> String in
            let screen = try object(item, required: ["id", "responseCaptures"], optional: ["defaultViewModelName", "defaultInstanceId"])
            for key in ["defaultViewModelName", "defaultInstanceId"] where screen[key] != nil { _ = try identifier(screen[key]) }
            let captures = try identifiers(screen["responseCaptures"])
            guard captures == captures.sorted(by: utf16Precedes), Set(captures).count == captures.count else { throw invalid }
            return try identifier(screen["id"])
        })
        guard screens.count == screenList.count else { throw invalid }
        let steps = try array(leg["steps"])
        guard (1...10_000).contains(steps.count) else { throw invalid }
        let ids = try Set(steps.map { try identifier(dictionary($0)["id"]) })
        guard ids.count == steps.count, ids.contains(try identifier(leg["entryStepId"])) else { throw invalid }
        for item in steps {
            let step = try dictionary(item)
            switch step["kind"] as? String {
            case "complete":
                _ = try object(step, required: ["kind", "id", "outcome"])
                _ = try identifier(step["outcome"])
            case "action":
                _ = try object(step, required: ["kind", "id", "action", "outlets"])
                try operation(step["action"], screens: screens, placements: placements)
                for target in try dictionary(step["outlets"]).values {
                    guard ids.contains(try identifier(target)) else { throw invalid }
                }
            default: throw invalid
            }
        }
        var routeKeys = Set<[String]>()
        for item in try array(leg["routes"]) {
            let route = try object(item, required: ["host", "eventName", "entryStepId"])
            let host = try dictionary(route["host"])
            let hostKey: [String]
            switch host["kind"] as? String {
            case "journey":
                _ = try object(host, required: ["kind"])
                hostKey = ["journey"]
            case "screen":
                _ = try object(host, required: ["kind", "screenId"])
                let screen = try identifier(host["screenId"])
                guard screens.contains(screen) else { throw invalid }
                hostKey = ["screen", screen]
            default: throw invalid
            }
            if route["eventName"] as? String == "host_dismissed",
               let entry = steps.compactMap({ $0 as? [String: Any] }).first(where: { $0["id"] as? String == route["entryStepId"] as? String }),
               let action = entry["action"] as? [String: Any],
               let rawType = action["type"] as? String,
               JourneyActionType(rawValue: rawType)?.isPresentationOwned == true {
                throw invalid
            }
            guard ids.contains(try identifier(route["entryStepId"])),
                  routeKeys.insert(hostKey + [try identifier(route["eventName"])]).inserted else { throw invalid }
        }
        let gate = try object(leg["entitlementGate"], required: ["enabled", "products"])
        try boolean(gate["enabled"])
        for item in try array(gate["products"]) {
            let product = try object(item, required: ["productId", "featureIds"])
            _ = try identifier(product["productId"])
            _ = try identifiers(product["featureIds"])
        }
        try validateFacts(leg)
        try boundary(leg["inputs"])
        try fields(leg["outputs"], response: true)
        for (outcome, value) in try dictionary(leg["completionOutputs"]) {
            _ = try identifier(outcome)
            try boundary(value)
        }
        return screens
    }

    private static func operation(_ value: Any?, screens: Set<String>, placements: Set<String>) throws {
        let action = try dictionary(value)
        guard let rawType = action["type"] as? String,
              let type = JourneyActionType(rawValue: rawType) else {
            throw invalid
        }
        guard !type.isPresentationOwned || !screens.isEmpty else {
            throw invalid
        }
        switch type {
        case .connectorAction, .grantEntitlement, .deviceAvailable:
            throw invalid
        case .condition:
            _ = try object(action, required: ["type", "branches"])
            for item in try array(action["branches"]) {
                let branch = try object(item, required: ["id", "condition"])
                _ = try identifier(branch["id"])
                try Common.validateJourneyCondition(branch["condition"], path: "leg.condition")
            }
        case .experiment:
            _ = try object(
                action,
                required: ["type", "experimentId", "fallbackVariantId", "variants"]
            )
            _ = try identifier(action["experimentId"])
            let variants = try array(action["variants"])
            let variantIds = try variants.map { item -> String in
                let variant = try object(item, required: ["id", "isHoldout"])
                let id = try identifier(variant["id"])
                try boolean(variant["isHoldout"])
                return id
            }
            guard !variantIds.isEmpty,
                  Set(variantIds).count == variantIds.count,
                  variantIds.contains(try identifier(action["fallbackVariantId"])) else {
                throw invalid
            }
        case .timeWindow:
            _ = try object(action, required: ["type", "startTime", "endTime", "timezone", "daysOfWeek"])
            guard action["startTime"] is String, action["endTime"] is String else { throw invalid }
            try Common.validateJourneyTimezone(action["timezone"], path: "leg.timezone")
            for day in try array(action["daysOfWeek"]) { try integer(day, minimum: 0, maximum: 6) }
        case .waitUntil:
            _ = try object(action, required: ["type", "trigger", "condition", "maxTimeMs"])
            try Common.validateJourneyWaitTrigger(action["trigger"], path: "leg.trigger")
            if let payload = try dictionary(action["trigger"])["payloadSchema"] {
                let schema = try object(payload, required: ["type", "fields", "additionalProperties"])
                guard schema["type"] as? String == "object" else { throw invalid }
                try boolean(schema["additionalProperties"])
                let declared = try array(schema["fields"])
                guard declared.count <= 256 else { throw invalid }
                try fields(declared, response: false)
                let keys = try declared.map { try identifier(dictionary($0)["key"]) }
                guard keys == keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) else { throw invalid }
            }
            try Common.validateJourneyCondition(action["condition"], path: "leg.condition")
            try integer(action["maxTimeMs"], minimum: 0)
        case .purchase:
            _ = try object(action, required: ["type", "placementId"])
            try Common.validateJourneyPurchasePlacementId(action["placementId"], path: "leg.placementId", placementIDs: placements)
        case .restore:
            _ = try object(action, required: ["type"])
        case .sendEvent:
            try Common.validateCanonicalJourneyAction(
                action,
                path: "leg.action",
                screenIDs: screens,
                placementIDs: placements
            )
            guard let eventName = action["eventName"] as? String,
                  !eventName.hasPrefix("$") else {
                throw invalid
            }
        case .delay, .navigate, .back, .requestNotifications,
             .requestPermission, .requestTracking, .openLink, .dismiss,
             .updateCustomer, .milestone, .submitResponse, .appAction, .exit:
            try Common.validateCanonicalJourneyAction(action, path: "leg.action", screenIDs: screens, placementIDs: placements)
        }
    }

    private static func validateFacts(_ leg: [String: Any]) throws {
        let facts = try object(leg["facts"], required: ["propertyKeys", "segmentIds", "experimentIds"])
        var properties = ExactJSONObject<Bool>(), segments = ExactJSONObject<Bool>(), experiments = ExactJSONObject<Bool>()
        func walk(_ value: Any) throws {
            if let values = value as? [Any] { for value in values { try walk(value) }; return }
            guard let node = value as? [String: Any] else { return }
            if node["type"] as? String == "User", let key = node["key"] as? String { properties[key] = true }
            if node["type"] as? String == "Segment" {
                guard node["op"] as? String != "entered_within" else { throw invalid }
                if let id = node["id"] as? String { segments[id] = true }
            }
            if node["type"] as? String == "segment", let id = node["segmentId"] as? String { segments[id] = true }
            if node["type"] as? String == "experiment", let id = node["experimentId"] as? String { experiments[id] = true }
            for value in node.values { try walk(value) }
        }
        try walk(try dictionary(leg["entryCondition"]))
        try walk(try array(leg["steps"]))
        for (key, expected) in [("propertyKeys", properties), ("segmentIds", segments), ("experimentIds", experiments)] {
            guard try identifiers(facts[key]).map({ Array($0.utf16) }) == expected.keys.sorted(by: utf16Precedes).map({ Array($0.utf16) }) else { throw invalid }
        }
    }

    private static func boundary(_ value: Any?) throws {
        let boundary = try object(value, required: ["eventFields", "responseFields"])
        try fields(boundary["eventFields"], response: false)
        try fields(boundary["responseFields"], response: true)
    }

    private static func fields(_ value: Any?, response: Bool) throws {
        var keys = Set<[UInt16]>()
        for item in try array(value) {
            let field = try dictionary(item)
            let type = try identifier(field["type"])
            let optional: Set<String>
            switch type {
            case "number": optional = ["min", "max"]
            case "string" where !response: optional = ["enum"]
            case "text" where response, "date" where response: optional = []
            case "boolean": optional = []
            case "null" where !response, "json" where !response: optional = []
            case "enum" where response, "multi_enum" where response: optional = ["options"]
            default: throw invalid
            }
            _ = try object(field, required: ["key", "type", "required"], optional: optional)
            let key = try identifier(field["key"])
            guard key.utf8.count <= (response ? 128 : 256), keys.insert(Array(key.utf16)).inserted else { throw invalid }
            try boolean(field["required"])
            if type == "number" {
                for key in ["min", "max"] where field[key] != nil { _ = try number(field[key]) }
                if let min = field["min"], let max = field["max"] { guard try number(min) <= number(max) else { throw invalid } }
            }
            let enumKey = response ? "options" : "enum"
            if field[enumKey] != nil || ["enum", "multi_enum"].contains(type) {
                let options = try identifiers(field[enumKey])
                guard (1...256).contains(options.count), Set(options).count == options.count else { throw invalid }
            }
        }
    }

    private static var invalid: JourneyReleaseAuthenticationError { .invalidDescriptor }
    private static func dictionary(_ value: Any?) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw invalid }; return object
    }
    private static func object(_ value: Any?, required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        let object = try dictionary(value), keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else { throw invalid }; return object
    }
    private static func array(_ value: Any?) throws -> [Any] {
        guard let array = value as? [Any] else { throw invalid }; return array
    }
    private static func identifier(_ value: Any?) throws -> String {
        guard let value = value as? String, !value.isEmpty, value.utf16.count <= 256 else { throw invalid }; return value
    }
    private static func identifiers(_ value: Any?) throws -> [String] { try array(value).map(identifier) }
    private static func boolean(_ value: Any?) throws {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw invalid }
    }
    private static func number(_ value: Any?) throws -> Double {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { throw invalid }; return value.doubleValue
    }
    private static func integer(_ value: Any?, minimum: Double, maximum: Double = 9_007_199_254_740_991) throws {
        let value = try number(value)
        guard value.rounded() == value, (minimum...maximum).contains(value) else { throw invalid }
    }
    private static func digest(_ value: Any?) throws {
        let value = try identifier(value)
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw invalid }
    }
    private static func utf16Precedes(_ left: String, _ right: String) -> Bool { left.utf16.lexicographicallyPrecedes(right.utf16) }
}
