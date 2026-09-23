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
        let leg = try dictionary(root["leg"])
        for value in try array(leg["steps"]) {
            let step = try dictionary(value)
            guard step["kind"] as? String == "action",
                  let action = step["action"] as? [String: Any],
                  action["type"] as? String == "video" else { continue }
            let target = try dictionary(action["target"])
            let render = try dictionary(root["render"])
            let requirements = try dictionary(root["requirements"])
            guard (requirements["requiredCapabilities"] as? [String] ?? []).contains("video.playback.v1"),
                  let elements = render["videoElements"] as? [[String: Any]],
                  elements.contains(where: {
                      $0["artboardId"] as? String == target["artboardId"] as? String &&
                      $0["viewNodeId"] as? String == target["viewNodeId"] as? String
                  }) else { throw invalid }
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
            "screens", "policy", "offers", "facts", "inputs", "outputs", "completionOutputs"])
        guard leg["schemaVersion"] as? String == "nuxie.experience-planes.v1" else { throw invalid }
        try digest(leg["id"])
        try validateEntry(leg["entryCondition"])
        try validatePolicy(leg["policy"])
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
        var offerScreens = Set<String>()
        let routes = try array(leg["routes"]).map { try dictionary($0) }
        for item in try array(leg["offers"]) {
            let offer = try object(item, required: ["screenId", "placementIds", "alreadyEntitledStepId", "unknownStepId"])
            let screen = try identifier(offer["screenId"])
            guard screens.contains(screen), offerScreens.insert(screen).inserted else { throw invalid }
            let offeredPlacements = try identifiers(offer["placementIds"])
            guard !offeredPlacements.isEmpty, Set(offeredPlacements).count == offeredPlacements.count,
                  Set(offeredPlacements).isSubset(of: placements) else { throw invalid }
            for (key, event) in [("alreadyEntitledStepId", Journey.Offer.alreadyEntitledEvent),
                                 ("unknownStepId", Journey.Offer.accessUnknownEvent)] {
                let cursor = try identifier(offer[key])
                guard ids.contains(cursor), routes.contains(where: {
                    let host = $0["host"] as? [String: Any]
                    return host?["kind"] as? String == "screen" && host?["screenId"] as? String == screen &&
                        $0["eventName"] as? String == event && $0["entryStepId"] as? String == cursor
                }) else { throw invalid }
            }
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

    private static let policySystemEvents: Set<String> = [
        "$identify",
        "$app_installed",
        "$app_updated",
        "$app_opened",
        "$app_backgrounded",
        "$feature_used",
        "$products_unavailable",
        "$screen_shown",
        "$screen_dismissed",
        "$purchase_completed",
        "$purchase_failed",
        "$purchase_cancelled",
        "$purchase_pending",
        "$purchase_synced",
        "$restore_completed",
        "$restore_failed",
        "$restore_no_purchases",
        "$notifications_enabled",
        "$notifications_denied",
        "$permission_granted",
        "$permission_denied",
        "$tracking_authorized",
        "$tracking_denied",
        "$experience_shown",
        "$experience_dismissed",
        "$experience_errored",
        "$experience_artifact_load_succeeded",
        "$experience_artifact_load_failed",
        "$customer_updated",
        "$app_action_requested",
        "$experiment_exposure",
    ]

    private static func policyEvent(_ value: Any?) throws {
        let name = try identifier(value)
        guard name.utf8.count <= 128, !name.hasPrefix("$") || policySystemEvents.contains(name) else { throw invalid }
    }

    private static func policyIR(_ value: Any?) throws {
        guard let value else { return }
        let bytes = try JSONSerialization.data(withJSONObject: value)
        let ir = try JSONDecoder().decode(IREnvelope.self, from: bytes)
        guard ir.ir_version == 1, ir.isSupportedByThisEngine else { throw invalid }
        func check(_ value: Any) throws {
            if let values = value as? [Any] { for child in values { try check(child) } }
            if let node = value as? [String: Any] {
                if let type = node["type"] as? String, type.hasPrefix("Events.") {
                    if let name = node["name"] { try policyEvent(name) }
                    if type == "Events.InOrder", let steps = node["steps"] as? [[String: Any]] {
                        for step in steps { try policyEvent(step["name"]) }
                    }
                }
                for child in node.values { try check(child) }
            }
        }
        try check(value)
    }

    private static func policyDuration(_ value: Any?) throws -> Double {
        let duration = try object(value, required: ["amount", "unit"])
        try integer(duration["amount"], minimum: 1)
        let units: [String: Double] = ["minute": 60, "hour": 3600, "day": 86400, "week": 604800]
        guard let unit = duration["unit"] as? String, let multiplier = units[unit],
              let amount = duration["amount"] as? NSNumber else { throw invalid }
        let seconds = amount.doubleValue * multiplier
        guard seconds * 1000 <= 9_007_199_254_740_991 else { throw invalid }
        return seconds
    }

    private static func policyCriterion(_ value: Any?) throws {
        let criterion = try dictionary(value)
        switch criterion["type"] as? String {
        case "event":
            _ = try object(criterion, required: ["type", "eventName"], optional: ["condition"])
            try policyEvent(criterion["eventName"])
            try policyIR(criterion["condition"])
        case "segment_enter", "segment_leave":
            _ = try object(criterion, required: ["type", "segmentId"])
            _ = try identifier(criterion["segmentId"])
        default: throw invalid
        }
    }

    private static func validatePolicy(_ value: Any?) throws {
        let policy = try object(value, required: ["entry", "exitWhenAny"], optional: ["goal"])
        let entry = try object(policy["entry"], required: ["trigger", "frequency"], optional: ["eligibility"])
        let trigger = try dictionary(entry["trigger"])
        switch trigger["type"] as? String {
        case "api": _ = try object(trigger, required: ["type"])
        case "server_event":
            _ = try object(trigger, required: ["type", "connectorKey", "triggerKey"], optional: ["identityField", "condition"])
            for key in ["connectorKey", "triggerKey", "identityField"] where trigger[key] != nil { _ = try identifier(trigger[key]) }
            try policyIR(trigger["condition"])
        default: try policyCriterion(trigger)
        }
        try policyIR(entry["eligibility"])
        let frequency = try dictionary(entry["frequency"])
        switch frequency["type"] as? String {
        case "one_time", "every_match": _ = try object(frequency, required: ["type"])
        case "once_per_window":
            _ = try object(frequency, required: ["type", "window"])
            _ = try policyDuration(frequency["window"])
        default: throw invalid
        }
        if let value = policy["goal"] {
            let goal = try object(value, required: ["criterion", "attribution"])
            try policyCriterion(goal["criterion"])
            let attribution = try object(goal["attribution"], required: ["basis", "window"])
            guard ["first_shown", "entry"].contains(attribution["basis"] as? String ?? ""),
                  try policyDuration(attribution["window"]) <= 90 * 86400 else { throw invalid }
        }
        for value in try array(policy["exitWhenAny"]) {
            let exit = try dictionary(value)
            switch exit["type"] as? String {
            case "goal_met":
                _ = try object(exit, required: ["type"])
                guard policy["goal"] != nil else { throw invalid }
            case "eligibility_lost":
                _ = try object(exit, required: ["type"])
                guard entry["eligibility"] != nil else { throw invalid }
            default: try policyCriterion(exit)
            }
        }
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
        case .connectorAction:
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
        case .delay, .navigate, .back, .video, .requestNotifications,
             .requestPermission, .requestTracking, .openLink, .dismiss,
             .updateCustomer, .submitResponse, .appAction, .exit:
            try Common.validateCanonicalJourneyAction(action, path: "leg.action", screenIDs: screens, placementIDs: placements)
        }
    }

    private static func validateFacts(_ leg: [String: Any]) throws {
        let facts = try object(leg["facts"], required: ["propertyKeys", "segmentIds", "experimentIds"])
        var properties = ExactJSONObject<Bool>(), segments = ExactJSONObject<Bool>(), experiments = ExactJSONObject<Bool>()
        func walk(_ value: Any) throws {
            if let values = value as? [Any] { for value in values { try walk(value) }; return }
            guard let node = value as? [String: Any] else { return }
            if let type = node["type"] as? String, ["User", "Customer.Field"].contains(type), let key = node["key"] as? String { properties[key] = true }
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
