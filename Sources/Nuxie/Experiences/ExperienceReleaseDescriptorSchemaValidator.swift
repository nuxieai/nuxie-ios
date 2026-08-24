import Foundation

/// Structural mirror of the canonical Zod grammar. This validator exists in
/// addition to Codable because dictionary-backed behavior sections would
/// otherwise silently discard the distinction between a known optional field
/// and a future field whose semantics this SDK does not understand.
enum ExperienceReleaseDescriptorSchemaValidator {
    static func validate(_ root: [String: Any]) throws {
        let root = try object(
            root,
            required: [
                "schemaVersion", "identity", "metadata", "enrollment", "lifecycle",
                "presentation", "products", "placements", "journey", "responseCaptures",
                "screenBehaviors", "render", "requirements", "provenance",
            ],
            optional: ["responseSchema"],
            path: "$"
        )
        _ = try object(
            root["identity"],
            required: [
                "appId", "environment", "experienceId", "experienceVersionId",
                "versionNumber", "buildId", "publishedAt", "publishedAtSeq",
            ],
            path: "identity"
        )
        _ = try object(
            root["metadata"],
            required: ["name", "appDefaultTimezone"],
            optional: ["experienceType", "description"],
            path: "metadata"
        )
        let metadata = root["metadata"] as! [String: Any]
        try boundedString(metadata["name"], minimum: 1, maximumUTF16: 256, path: "metadata.name")
        try identifier(metadata["appDefaultTimezone"], path: "metadata.appDefaultTimezone")
        if let value = metadata["experienceType"] { try boundedString(value, minimum: 1, maximumUTF16: 64, path: "metadata.experienceType") }
        if let value = metadata["description"] { try boundedString(value, minimum: 0, maximumUTF16: 2_048, path: "metadata.description") }
        try validateEnrollment(root["enrollment"])
        try validateLifecycle(root["lifecycle"])
        try validatePresentation(root["presentation"])
        let products = try array(root["products"], path: "products").enumerated().map { index, value in
            let path = "products[\(index)]"
            let product = try object(
                value,
                required: [
                    "id", "type", "providerFeatureAccess", "store", "preview",
                    "entitlements",
                ],
                path: path
            )
            try identifier(product["id"], path: "\(path).id")
            try enumeration(
                product["type"],
                values: ["subscription", "consumable", "nonConsumable"],
                path: "\(path).type"
            )
            if !(product["providerFeatureAccess"] is NSNull) {
                let access = try object(
                    product["providerFeatureAccess"],
                    required: ["provider"],
                    path: "\(path).providerFeatureAccess"
                )
                try enumeration(
                    access["provider"],
                    values: ["revenuecat", "superwall"],
                    path: "\(path).providerFeatureAccess.provider"
                )
            }
            let store = try object(
                product["store"],
                required: ["platform", "productId", "productType"],
                path: "\(path).store"
            )
            try boundedString(
                store["productId"],
                minimum: 1,
                maximumUTF16: 256,
                path: "\(path).store.productId"
            )
            guard let platform = store["platform"] as? String,
                  let productType = product["type"] as? String,
                  let storeProductType = store["productType"] as? String else {
                try invalid(path)
            }
            switch platform {
            case "apple_app_store":
                try enumeration(
                    storeProductType,
                    values: ["autoRenewable", "nonRenewing", "consumable", "nonConsumable"],
                    path: "\(path).store.productType"
                )
                let compatible = productType == "subscription"
                    ? ["autoRenewable", "nonRenewing"].contains(storeProductType)
                    : productType == storeProductType
                guard compatible else { try invalid("\(path).store.productType") }
            case "google_play":
                guard productType == storeProductType else {
                    try invalid("\(path).store.productType")
                }
            default:
                try invalid("\(path).store.platform")
            }
            let preview = try object(
                product["preview"],
                required: [
                    "name", "description", "price", "period", "periodCount",
                    "periodLabel", "hasTrial", "trialLabel", "introOfferLabel",
                    "renewalLabel",
                ],
                path: "\(path).preview"
            )
            try boundedString(
                preview["name"],
                minimum: 0,
                maximumUTF16: 512,
                path: "\(path).preview.name"
            )
            try boundedString(
                preview["description"],
                minimum: 0,
                maximumUTF16: 2_048,
                path: "\(path).preview.description"
            )
            try boundedString(
                preview["price"],
                minimum: 0,
                maximumUTF16: 128,
                path: "\(path).preview.price"
            )
            try boundedString(
                preview["period"],
                minimum: 0,
                maximumUTF16: 64,
                path: "\(path).preview.period"
            )
            try integer(
                preview["periodCount"],
                minimum: 0,
                maximum: 10_000,
                path: "\(path).preview.periodCount"
            )
            try boundedString(
                preview["periodLabel"],
                minimum: 0,
                maximumUTF16: 128,
                path: "\(path).preview.periodLabel"
            )
            guard isJSONBoolean(preview["hasTrial"]) else {
                try invalid("\(path).preview.hasTrial")
            }
            for field in ["trialLabel", "introOfferLabel", "renewalLabel"] {
                try boundedString(
                    preview[field],
                    minimum: 0,
                    maximumUTF16: 256,
                    path: "\(path).preview.\(field)"
                )
            }
            let entitlements = try array(product["entitlements"], path: "\(path).entitlements")
            guard entitlements.count <= 256 else { try invalid("\(path).entitlements") }
            let entitlementIDs = try entitlements.enumerated().map { entitlementIndex, value in
                let entitlementPath = "\(path).entitlements[\(entitlementIndex)]"
                let entitlement = try object(
                    value,
                    required: [
                        "id", "featureId", "featureExternalId", "allowanceType",
                        "purchaseUsageFeatureIds", "allowance", "interval",
                    ],
                    path: entitlementPath
                )
                try identifier(entitlement["id"], path: "\(entitlementPath).id")
                if !(entitlement["featureId"] is NSNull) {
                    try identifier(entitlement["featureId"], path: "\(entitlementPath).featureId")
                }
                if !(entitlement["featureExternalId"] is NSNull) {
                    try boundedString(
                        entitlement["featureExternalId"],
                        minimum: 1,
                        maximumUTF16: 256,
                        path: "\(entitlementPath).featureExternalId"
                    )
                }
                let purchaseUsageFeatureIds = try array(
                    entitlement["purchaseUsageFeatureIds"],
                    path: "\(entitlementPath).purchaseUsageFeatureIds"
                )
                guard purchaseUsageFeatureIds.count <= 256 else {
                    try invalid("\(entitlementPath).purchaseUsageFeatureIds")
                }
                let purchaseUsageFeatureIDStrings = try purchaseUsageFeatureIds
                    .enumerated().map { index, value -> String in
                        try boundedString(
                            value,
                            minimum: 1,
                            maximumUTF16: 256,
                            path: "\(entitlementPath).purchaseUsageFeatureIds[\(index)]"
                        )
                        return value as! String
                    }
                guard zip(
                    purchaseUsageFeatureIDStrings,
                    purchaseUsageFeatureIDStrings.dropFirst()
                ).allSatisfy({ javascriptStringPrecedes($0, $1) }) else {
                    try invalid("\(entitlementPath).purchaseUsageFeatureIds")
                }
                if !(entitlement["allowanceType"] is NSNull) {
                    try enumeration(
                        entitlement["allowanceType"],
                        values: ["fixed", "unlimited"],
                        path: "\(entitlementPath).allowanceType"
                    )
                }
                if !(entitlement["allowance"] is NSNull) {
                    try finiteNumber(
                        entitlement["allowance"],
                        minimum: 0,
                        maximum: Double.greatestFiniteMagnitude,
                        path: "\(entitlementPath).allowance"
                    )
                }
                if !(entitlement["interval"] is NSNull) {
                    try enumeration(
                        entitlement["interval"],
                        values: [
                            "lifetime", "minute", "hour", "day", "week", "month",
                            "quarter", "semiAnnual", "year",
                        ],
                        path: "\(entitlementPath).interval"
                    )
                }
                return entitlement["id"] as! String
            }
            guard zip(entitlementIDs, entitlementIDs.dropFirst()).allSatisfy({
                javascriptStringPrecedes($0, $1)
            }) else { try invalid("\(path).entitlements") }
            return (
                id: product["id"] as! String,
                storeKey: "\(platform)\u{0}\(store["productId"] as! String)"
            )
        }
        guard products.count <= ExperienceReleaseDescriptorLimits.productCount,
              zip(products, products.dropFirst()).allSatisfy({ lhs, rhs in
            javascriptStringPrecedes(lhs.id, rhs.id)
        }) else {
            try invalid("products")
        }
        guard Set(products.map { $0.storeKey }).count == products.count else {
            try invalid("products")
        }
        let productIDs = Set(products.map { $0.id })
        let placements = try array(root["placements"], path: "placements").enumerated().map {
            index, value in
            let path = "placements[\(index)]"
            let placement = try object(
                value,
                required: ["id", "productId"],
                optional: ["appStore"],
                path: path
            )
            try identifier(placement["id"], path: "\(path).id")
            try identifier(placement["productId"], path: "\(path).productId")
            guard productIDs.contains(placement["productId"] as! String) else {
                try invalid("\(path).productId")
            }
            if let appStoreValue = placement["appStore"] {
                let appStore = try object(
                    appStoreValue,
                    required: ["introEligibility", "billingPlan"],
                    path: "\(path).appStore"
                )
                try enumeration(
                    appStore["introEligibility"],
                    values: ["automatic", "alwaysEligible", "alwaysIneligible"],
                    path: "\(path).appStore.introEligibility"
                )
                try enumeration(
                    appStore["billingPlan"],
                    values: ["default", "upFront", "monthly"],
                    path: "\(path).appStore.billingPlan"
                )
            }
            return placement["id"] as! String
        }
        guard placements.count <= ExperienceReleaseDescriptorLimits.placementCount,
              zip(placements, placements.dropFirst()).allSatisfy({
                  javascriptStringPrecedes($0, $1)
              }) else { try invalid("placements") }
        let journeyScreenIDs = try validateJourney(
            root["journey"],
            placementIDs: Set(placements)
        )
        try validateResponseContract(
            schema: root["responseSchema"],
            captures: root["responseCaptures"],
            behaviors: root["screenBehaviors"],
            screenIDs: journeyScreenIDs
        )
        try validateRender(root["render"])
        let requirements = try object(
            root["requirements"],
            required: [
                "minimumSdkVersion", "runtimeRevision", "luau", "sceneFormat",
                "timezoneData", "requiredCapabilities",
            ],
            path: "requirements"
        )
        try semanticVersion(
            requirements["minimumSdkVersion"],
            path: "requirements.minimumSdkVersion"
        )
        try identifier(
            requirements["runtimeRevision"],
            path: "requirements.runtimeRevision"
        )
        let sceneFormat = try object(
            requirements["sceneFormat"],
            required: ["major", "minor"],
            path: "requirements.sceneFormat"
        )
        try integer(sceneFormat["major"], minimum: 0, maximum: 65_535, path: "requirements.sceneFormat.major")
        try integer(sceneFormat["minor"], minimum: 0, maximum: 65_535, path: "requirements.sceneFormat.minor")
        let luau = try object(
            requirements["luau"],
            required: ["revision", "bytecodeVersions"],
            path: "requirements.luau"
        )
        try identifier(luau["revision"], path: "requirements.luau.revision")
        let bytecodeVersions = try array(
            luau["bytecodeVersions"],
            path: "requirements.luau.bytecodeVersions"
        )
        guard (1...256).contains(bytecodeVersions.count) else {
            try invalid("requirements.luau.bytecodeVersions")
        }
        var previous: Double?
        for (index, version) in bytecodeVersions.enumerated() {
            try integer(
                version,
                minimum: 0,
                maximum: 65_535,
                path: "requirements.luau.bytecodeVersions[\(index)]"
            )
            let current = (version as! NSNumber).doubleValue
            guard previous.map({ current > $0 }) ?? true else {
                try invalid("requirements.luau.bytecodeVersions")
            }
            previous = current
        }
        _ = try array(
            requirements["requiredCapabilities"],
            path: "requirements.requiredCapabilities"
        )
        let timezone = try object(
            requirements["timezoneData"],
            required: ["format", "revision", "sha256"],
            path: "requirements.timezoneData"
        )
        guard timezone["format"] as? String == "iana-tzdb" else {
            try invalid("requirements.timezoneData.format")
        }
        try identifier(timezone["revision"], path: "requirements.timezoneData.revision")
        try lowercaseSHA256(timezone["sha256"], path: "requirements.timezoneData.sha256")
        _ = try object(
            root["provenance"],
            required: ["compilerCommit", "compilerVersion"],
            path: "provenance"
        )
        let provenance = root["provenance"] as! [String: Any]
        try identifier(provenance["compilerCommit"], path: "provenance.compilerCommit")
        try boundedString(provenance["compilerVersion"], minimum: 1, maximumUTF16: 64, path: "provenance.compilerVersion")
    }

    private static func validateEnrollment(_ value: Any?) throws {
        let enrollment = try object(
            value,
            required: ["trigger", "requiredPropertyKeys", "requiredSegmentIds"],
            path: "enrollment"
        )
        let trigger = try typedObject(enrollment["trigger"], path: "enrollment.trigger")
        switch trigger.type {
        case "event":
            _ = try object(
                trigger.object,
                required: ["type", "eventName"],
                optional: ["condition"],
                path: "enrollment.trigger"
            )
        case "segment":
            _ = try object(
                trigger.object,
                required: ["type", "condition"],
                path: "enrollment.trigger"
            )
        case "server_event":
            _ = try object(
                trigger.object,
                required: ["type", "connectorKey", "triggerKey"],
                optional: ["identityField", "condition"],
                path: "enrollment.trigger"
            )
        case "api":
            _ = try object(trigger.object, required: ["type"], path: "enrollment.trigger")
        default: try invalid("enrollment.trigger.type")
        }
        switch trigger.type {
        case "event": try identifier(trigger.object["eventName"], path: "enrollment.trigger.eventName")
        case "server_event":
            try identifier(trigger.object["connectorKey"], path: "enrollment.trigger.connectorKey")
            try identifier(trigger.object["triggerKey"], path: "enrollment.trigger.triggerKey")
            if let value = trigger.object["identityField"] { try identifier(value, path: "enrollment.trigger.identityField") }
        default: break
        }
        if let condition = trigger.object["condition"] { try validateJSONRecord(condition, path: "enrollment.trigger.condition") }
        try validateSortedIdentifiers(
            try array(enrollment["requiredPropertyKeys"], path: "enrollment.requiredPropertyKeys"),
            maximum: 256,
            path: "enrollment.requiredPropertyKeys"
        )
        try validateSortedIdentifiers(
            try array(enrollment["requiredSegmentIds"], path: "enrollment.requiredSegmentIds"),
            maximum: 256,
            path: "enrollment.requiredSegmentIds"
        )
    }

    private static func validateLifecycle(_ value: Any?) throws {
        let lifecycle = try object(
            value,
            required: ["reentry", "exitPolicy", "conversionAnchor"],
            optional: ["goal", "timeLimitSeconds"],
            path: "lifecycle"
        )
        let reentry = try typedObject(lifecycle["reentry"], path: "lifecycle.reentry")
        switch reentry.type {
        case "one_time", "every_time":
            _ = try object(reentry.object, required: ["type"], path: "lifecycle.reentry")
        case "once_per_window":
            _ = try object(
                reentry.object,
                required: ["type", "windowSeconds"],
                path: "lifecycle.reentry"
            )
        default: try invalid("lifecycle.reentry.type")
        }
        if reentry.type == "once_per_window" {
            try integer(reentry.object["windowSeconds"], minimum: 1, maximum: 366 * 24 * 60 * 60, path: "lifecycle.reentry.windowSeconds")
        }
        try enumeration(lifecycle["exitPolicy"], values: ["on_goal", "on_stop_matching", "on_goal_or_stop", "never"], path: "lifecycle.exitPolicy")
        try enumeration(lifecycle["conversionAnchor"], values: ["journey_start", "last_experience_shown", "last_experience_interaction"], path: "lifecycle.conversionAnchor")
        if let limit = lifecycle["timeLimitSeconds"] { try integer(limit, minimum: 1, maximum: 366 * 24 * 60 * 60, path: "lifecycle.timeLimitSeconds") }
        if let value = lifecycle["goal"] {
            let goal = try typedObject(value, path: "lifecycle.goal")
            let required: Set<String>
            let optional: Set<String>
            switch goal.type {
            case "event": required = ["type", "eventName"]; optional = ["condition", "windowSeconds"]
            case "milestone": required = ["type", "milestoneId"]; optional = ["windowSeconds"]
            case "segment_enter", "segment_leave": required = ["type", "segmentId"]; optional = ["windowSeconds"]
            case "attribute": required = ["type", "expression"]; optional = ["windowSeconds"]
            default: try invalid("lifecycle.goal.type")
            }
            _ = try object(goal.object, required: required, optional: optional, path: "lifecycle.goal")
            if let window = goal.object["windowSeconds"] { try integer(window, minimum: 1, maximum: 366 * 24 * 60 * 60, path: "lifecycle.goal.windowSeconds") }
            switch goal.type {
            case "event":
                try identifier(goal.object["eventName"], path: "lifecycle.goal.eventName")
                if let condition = goal.object["condition"] { try validateJSONRecord(condition, path: "lifecycle.goal.condition") }
            case "milestone": try identifier(goal.object["milestoneId"], path: "lifecycle.goal.milestoneId")
            case "segment_enter", "segment_leave": try identifier(goal.object["segmentId"], path: "lifecycle.goal.segmentId")
            case "attribute": try validateJSONRecord(goal.object["expression"], path: "lifecycle.goal.expression")
            default: break
            }
        }
    }

    private static func validatePresentation(_ value: Any?) throws {
        let raw = try dictionary(value, path: "presentation")
        guard let style = raw["style"] as? String else { try invalid("presentation.style") }
        let presentation: [String: Any]
        switch style {
        case "full_screen":
            presentation = try object(
                raw,
                required: ["style", "orientation", "backgroundColor"],
                path: "presentation"
            )
        case "sheet":
            presentation = try object(
                raw,
                required: ["style", "orientation", "backgroundColor", "sheet"],
                path: "presentation"
            )
            _ = try object(
                presentation["sheet"],
                required: ["detent", "dismissible"],
                path: "presentation.sheet"
            )
            let sheet = presentation["sheet"] as! [String: Any]
            try enumeration(
                sheet["detent"],
                values: ["medium", "large"],
                path: "presentation.sheet.detent"
            )
            guard isJSONBoolean(sheet["dismissible"]) else {
                try invalid("presentation.sheet.dismissible")
            }
        case "drawer":
            presentation = try object(
                raw,
                required: ["style", "orientation", "backgroundColor", "drawer"],
                path: "presentation"
            )
            _ = try object(
                presentation["drawer"],
                required: ["edge", "extentRatio", "cornerRadius", "dismissible"],
                path: "presentation.drawer"
            )
            let drawer = presentation["drawer"] as! [String: Any]
            try enumeration(
                drawer["edge"],
                values: ["bottom", "top", "leading", "trailing"],
                path: "presentation.drawer.edge"
            )
            try finiteNumber(
                drawer["extentRatio"],
                minimum: 0,
                maximum: 1,
                exclusiveMinimum: true,
                path: "presentation.drawer.extentRatio"
            )
            try finiteNumber(
                drawer["cornerRadius"],
                minimum: 0,
                maximum: 128,
                path: "presentation.drawer.cornerRadius"
            )
            guard isJSONBoolean(drawer["dismissible"]) else {
                try invalid("presentation.drawer.dismissible")
            }
        default: try invalid("presentation.style")
        }
        try enumeration(
            presentation["orientation"],
            values: ["portrait", "landscape", "any"],
            path: "presentation.orientation"
        )
        try color(presentation["backgroundColor"], path: "presentation.backgroundColor")
    }

    @discardableResult
    private static func validateJourney(
        _ value: Any?,
        placementIDs: Set<String>
    ) throws -> Set<String> {
        let journey = try object(
            value,
            required: ["entryRouteEventName", "screens", "viewModelValues", "routes", "executionPlans"],
            path: "journey"
        )
        try identifier(journey["entryRouteEventName"], path: "journey.entryRouteEventName")
        let screens = try array(journey["screens"], path: "journey.screens")
        guard !screens.isEmpty, screens.count <= 256 else { try invalid("journey.screens") }
        let screenIDs = try screens.enumerated().map { index, value -> String in
            let screen = try object(
                value,
                required: ["id"],
                optional: ["defaultViewModelName", "defaultInstanceId"],
                path: "journey.screens[\(index)]"
            )
            try identifier(screen["id"], path: "journey.screens[\(index)].id")
            if let name = screen["defaultViewModelName"] {
                try identifier(name, path: "journey.screens[\(index)].defaultViewModelName")
            }
            if let instance = screen["defaultInstanceId"] {
                try identifier(instance, path: "journey.screens[\(index)].defaultInstanceId")
            }
            return screen["id"] as! String
        }
        guard Set(screenIDs).count == screenIDs.count else { try invalid("journey.screens") }

        let values = try array(journey["viewModelValues"], path: "journey.viewModelValues")
        guard values.count <= 2_048 else { try invalid("journey.viewModelValues") }
        for (index, item) in values.enumerated() {
            let value = try object(
                item,
                required: ["viewModelName", "path", "value"],
                optional: ["instanceId", "instanceName"],
                path: "journey.viewModelValues[\(index)]"
            )
            try identifier(value["viewModelName"], path: "journey.viewModelValues[\(index)].viewModelName")
            try boundedString(value["path"], minimum: 0, maximumUTF16: 512, path: "journey.viewModelValues[\(index)].path")
        }

        let routes = try array(journey["routes"], path: "journey.routes")
        guard routes.count <= 4_096 else { try invalid("journey.routes") }
        var routeKeys: Set<String> = []
        for (index, item) in routes.enumerated() {
            let path = "journey.routes[\(index)]"
            let route = try object(
                item,
                required: ["host", "eventName", "program", "revisionSha256"],
                path: path
            )
            let host = try dictionary(route["host"], path: "\(path).host")
            guard let hostKind = host["kind"] as? String else { try invalid("\(path).host.kind") }
            let hostKey: String
            switch hostKind {
            case "journey":
                _ = try object(host, required: ["kind"], path: "\(path).host")
                hostKey = "journey"
            case "screen":
                _ = try object(host, required: ["kind", "screenId"], path: "\(path).host")
                try identifier(host["screenId"], path: "\(path).host.screenId")
                guard screenIDs.contains(host["screenId"] as! String) else {
                    try invalid("\(path).host.screenId")
                }
                hostKey = "screen:\(host["screenId"] as! String)"
            default: try invalid("\(path).host.kind")
            }
            try identifier(route["eventName"], path: "\(path).eventName")
            try lowercaseSHA256(route["revisionSha256"], path: "\(path).revisionSha256")
            try validateJourneyProgram(
                route["program"],
                path: "\(path).program",
                screenIDs: Set(screenIDs),
                placementIDs: placementIDs
            )
            let key = "\(hostKey)\u{0}\(route["eventName"] as! String)"
            guard routeKeys.insert(key).inserted else { try invalid(path) }
        }

        let plans = try array(journey["executionPlans"], path: "journey.executionPlans")
        guard plans.count <= 8_192 else { try invalid("journey.executionPlans") }
        for (index, item) in plans.enumerated() {
            let plan = try dictionary(item, path: "journey.executionPlans[\(index)]")
            guard Set(plan.keys) == [
                "id", "route", "startPlane", "entryCursor", "entryRegionId",
                "deviceRegions", "serverRegions", "handoffEdges",
            ] else { try invalid("journey.executionPlans[\(index)]") }
            try lowercaseSHA256(plan["id"], path: "journey.executionPlans[\(index)].id")
            try enumeration(plan["startPlane"], values: ["device", "server"], path: "journey.executionPlans[\(index)].startPlane")
        }
        return Set(screenIDs)
    }

    private static func validateJourneyProgram(
        _ value: Any?,
        path: String,
        screenIDs: Set<String>,
        placementIDs: Set<String>
    ) throws {
        let actions = try array(value, path: path)
        guard actions.count <= 256 else { try invalid(path) }
        for (index, item) in actions.enumerated() {
            try validateCanonicalJourneyAction(
                item,
                path: "\(path)[\(index)]",
                screenIDs: screenIDs,
                placementIDs: placementIDs
            )
        }
    }

    private static func validateCanonicalJourneyAction(
        _ value: Any?,
        path: String,
        screenIDs: Set<String>,
        placementIDs: Set<String>
    ) throws {
        let action = try dictionary(value, path: path)
        guard let type = action["type"] as? String else { try invalid("\(path).type") }
        let required: Set<String>
        let optional: Set<String>
        switch type {
        case "navigate": required = ["type", "screenId"]; optional = ["transition"]
        case "back": required = ["type"]; optional = ["steps", "transition"]
        case "delay": required = ["type", "durationMs"]; optional = []
        case "time_window": required = ["type", "startTime", "endTime", "timezone", "daysOfWeek", "onInside"]; optional = []
        case "wait_until": required = ["type", "trigger", "condition", "maxTimeMs", "onSatisfied", "onTimeout"]; optional = []
        case "condition": required = ["type", "branches", "defaultProgram"]; optional = []
        case "experiment": required = ["type", "experimentId", "name", "variants"]; optional = ["description", "hypothesis"]
        case "device_available": required = ["type", "claimWithinMs", "onAvailable", "onUnavailable"]; optional = []
        case "send_event": required = ["type", "eventName"]; optional = ["payload"]
        case "update_customer": required = ["type", "attributes"]; optional = []
        case "milestone": required = ["type", "milestoneId"]; optional = []
        case "submit_response": required = ["type"]; optional = []
        case "purchase": required = ["type", "placementId"]; optional = ["onCompleted", "onFailed", "onCancelled"]
        case "restore": required = ["type", "onRestored", "onNoPurchases", "onFailed"]; optional = []
        case "request_notifications": required = ["type"]; optional = []
        case "request_permission": required = ["type", "permissionType"]; optional = []
        case "request_tracking": required = ["type"]; optional = []
        case "open_link": required = ["type", "url", "target"]; optional = []
        case "dismiss", "exit": required = ["type"]; optional = ["reason"]
        case "app_action": required = ["type", "name"]; optional = ["nodeId", "payload"]
        case "connector_action": required = ["type", "accountRef", "toolKey", "payload", "timeoutMs", "onSucceeded", "onFailed", "onTimeout"]; optional = []
        case "grant_entitlement": required = ["type", "featureId", "onSucceeded", "onFailed", "onTimeout"]; optional = ["balance", "unlimited"]
        default: try invalid("\(path).type")
        }
        _ = try object(action, required: required, optional: optional, path: path)
        for field in ["screenId", "eventName", "experimentId", "milestoneId", "permissionType", "accountRef", "toolKey", "featureId", "nodeId"] where action[field] != nil {
            try identifier(action[field], path: "\(path).\(field)")
        }
        if type == "navigate", let screenID = action["screenId"] as? String, !screenIDs.contains(screenID) {
            try invalid("\(path).screenId")
        }
        if type == "grant_entitlement" { try identifier(action["featureId"], path: "\(path).featureId") }
        if let reason = action["reason"] { try boundedString(reason, minimum: 0, maximumUTF16: 256, path: "\(path).reason") }
        switch type {
        case "back": if let steps = action["steps"] { try integer(steps, minimum: 1, maximum: 256, path: "\(path).steps") }
        case "delay": try integer(action["durationMs"], minimum: 0, maximum: 366 * 24 * 60 * 60 * 1_000, path: "\(path).durationMs")
        case "time_window":
            try timeOfDay(action["startTime"], path: "\(path).startTime")
            try timeOfDay(action["endTime"], path: "\(path).endTime")
            try validateJourneyTimezone(action["timezone"], path: "\(path).timezone")
            let days = try array(action["daysOfWeek"], path: "\(path).daysOfWeek")
            guard days.count <= 7 else { try invalid("\(path).daysOfWeek") }
            for (index, day) in days.enumerated() { try integer(day, minimum: 0, maximum: 6, path: "\(path).daysOfWeek[\(index)]") }
            let weekdayValues = days.compactMap { ($0 as? NSNumber)?.intValue }
            guard weekdayValues.count == Set(weekdayValues).count else { try invalid("\(path).daysOfWeek") }
            try validateCanonicalProgramField(action["onInside"], path: "\(path).onInside", screenIDs: screenIDs, placementIDs: placementIDs)
        case "wait_until":
            try validateJourneyWaitTrigger(action["trigger"], path: "\(path).trigger")
            try validateJourneyCondition(action["condition"], path: "\(path).condition")
            try integer(action["maxTimeMs"], minimum: 1, maximum: 366 * 24 * 60 * 60 * 1_000, path: "\(path).maxTimeMs")
            try validateCanonicalProgramField(action["onSatisfied"], path: "\(path).onSatisfied", screenIDs: screenIDs, placementIDs: placementIDs)
            try validateCanonicalProgramField(action["onTimeout"], path: "\(path).onTimeout", screenIDs: screenIDs, placementIDs: placementIDs)
        case "condition":
            let branches = try array(action["branches"], path: "\(path).branches")
            guard !branches.isEmpty else { try invalid("\(path).branches") }
            for (index, branchValue) in branches.enumerated() {
                let branch = try object(branchValue, required: ["id", "condition", "program"], path: "\(path).branches[\(index)]")
                try identifier(branch["id"], path: "\(path).branches[\(index)].id")
                try validateJourneyCondition(branch["condition"], path: "\(path).branches[\(index)].condition")
                try validateCanonicalProgramField(branch["program"], path: "\(path).branches[\(index)].program", screenIDs: screenIDs, placementIDs: placementIDs)
            }
            try validateCanonicalProgramField(action["defaultProgram"], path: "\(path).defaultProgram", screenIDs: screenIDs, placementIDs: placementIDs)
        case "experiment":
            try boundedString(action["name"], minimum: 1, maximumUTF16: 256, path: "\(path).name")
            if let description = action["description"] { try boundedString(description, minimum: 0, maximumUTF16: 2_048, path: "\(path).description") }
            if let hypothesis = action["hypothesis"] { try boundedString(hypothesis, minimum: 0, maximumUTF16: 2_048, path: "\(path).hypothesis") }
            let variants = try array(action["variants"], path: "\(path).variants")
            guard variants.count >= 2, variants.count <= 5 else { try invalid("\(path).variants") }
            for (index, variantValue) in variants.enumerated() {
                let variant = try object(variantValue, required: ["id", "name", "percentage", "isHoldout", "program"], path: "\(path).variants[\(index)]")
                try identifier(variant["id"], path: "\(path).variants[\(index)].id")
                try boundedString(variant["name"], minimum: 1, maximumUTF16: 256, path: "\(path).variants[\(index)].name")
                try finiteNumber(variant["percentage"], minimum: 0, maximum: 100, path: "\(path).variants[\(index)].percentage")
                guard isJSONBoolean(variant["isHoldout"]) else { try invalid("\(path).variants[\(index)].isHoldout") }
                try validateCanonicalProgramField(variant["program"], path: "\(path).variants[\(index)].program", screenIDs: screenIDs, placementIDs: placementIDs)
            }
        case "device_available":
            try integer(action["claimWithinMs"], minimum: 1, maximum: 366 * 24 * 60 * 60 * 1_000, path: "\(path).claimWithinMs")
            try validateCanonicalProgramField(action["onAvailable"], path: "\(path).onAvailable", screenIDs: screenIDs, placementIDs: placementIDs)
            try validateCanonicalProgramField(action["onUnavailable"], path: "\(path).onUnavailable", screenIDs: screenIDs, placementIDs: placementIDs)
        case "send_event":
            if let payload = action["payload"] { try validateJourneyValueRecord(payload, path: "\(path).payload") }
        case "update_customer": try validateJourneyValueRecord(action["attributes"], path: "\(path).attributes")
        case "purchase":
            try validateJourneyPurchasePlacementId(
                action["placementId"],
                path: "\(path).placementId",
                placementIDs: placementIDs
            )
            for field in ["onCompleted", "onFailed", "onCancelled"] where action[field] != nil {
                try validateCanonicalProgramField(action[field], path: "\(path).\(field)", screenIDs: screenIDs, placementIDs: placementIDs)
            }
        case "restore":
            for field in ["onRestored", "onNoPurchases", "onFailed"] { try validateCanonicalProgramField(action[field], path: "\(path).\(field)", screenIDs: screenIDs, placementIDs: placementIDs) }
        case "request_permission": try boundedString(action["permissionType"], minimum: 1, maximumUTF16: 128, path: "\(path).permissionType")
        case "open_link":
            try validateJourneyStringValue(action["url"], path: "\(path).url")
            try enumeration(action["target"], values: ["external", "in_app"], path: "\(path).target")
        case "app_action":
            try boundedString(action["name"], minimum: 1, maximumUTF16: 2_048, path: "\(path).name")
            if let payload = action["payload"] { try validateJourneyValueRecord(payload, path: "\(path).payload") }
        case "connector_action":
            try validateJourneyValueRecord(action["payload"], path: "\(path).payload")
            try integer(action["timeoutMs"], minimum: 1, maximum: 366 * 24 * 60 * 60 * 1_000, path: "\(path).timeoutMs")
            for field in ["onSucceeded", "onFailed", "onTimeout"] { try validateCanonicalProgramField(action[field], path: "\(path).\(field)", screenIDs: screenIDs, placementIDs: placementIDs) }
        case "grant_entitlement":
            if let balance = action["balance"] { try finiteNumber(balance, minimum: 0, maximum: Double.greatestFiniteMagnitude, exclusiveMinimum: true, path: "\(path).balance") }
            if let unlimited = action["unlimited"] { guard isJSONBoolean(unlimited), (unlimited as! NSNumber).boolValue else { try invalid("\(path).unlimited") } }
            guard action["balance"] != nil || action["unlimited"] != nil else { try invalid(path) }
            for field in ["onSucceeded", "onFailed", "onTimeout"] { try validateCanonicalProgramField(action[field], path: "\(path).\(field)", screenIDs: screenIDs, placementIDs: placementIDs) }
        default: break
        }
        if let transition = action["transition"] { try validateJourneyTransition(transition, path: "\(path).transition") }
    }

    private static func validateCanonicalProgramField(
        _ value: Any?,
        path: String,
        screenIDs: Set<String>,
        placementIDs: Set<String>
    ) throws {
        try validateJourneyProgram(
            value,
            path: path,
            screenIDs: screenIDs,
            placementIDs: placementIDs
        )
    }

    private static func validateJourneyTimezone(_ value: Any?, path: String) throws {
        let timezone = try dictionary(value, path: path)
        guard let kind = timezone["kind"] as? String else { try invalid("\(path).kind") }
        switch kind {
        case "device", "app_default": _ = try object(timezone, required: ["kind"], path: path)
        case "iana": _ = try object(timezone, required: ["kind", "identifier"], path: path); try identifier(timezone["identifier"], path: "\(path).identifier")
        default: try invalid("\(path).kind")
        }
    }

    private static func validateJourneyTransition(_ value: Any?, path: String) throws {
        let transition = try dictionary(value, path: path)
        guard let type = transition["type"] as? String else { try invalid("\(path).type") }
        switch type {
        case "none", "push", "modal", "fade": _ = try object(transition, required: ["type"], path: path)
        case "custom": _ = try object(transition, required: ["type", "transitionId"], path: path); try identifier(transition["transitionId"], path: "\(path).transitionId")
        default: try invalid("\(path).type")
        }
    }

    private static func validateJourneyWaitTrigger(_ value: Any?, path: String) throws {
        let trigger = try dictionary(value, path: path)
        guard let kind = trigger["kind"] as? String else { try invalid("\(path).kind") }
        switch kind {
        case "response_change": _ = try object(trigger, required: ["kind"], path: path)
        case "event", "event_or_response_change":
            _ = try object(trigger, required: ["kind", "eventName"], optional: ["payloadSchema"], path: path)
            try identifier(trigger["eventName"], path: "\(path).eventName")
        default: try invalid("\(path).kind")
        }
    }

    private static func validateJourneyCondition(_ value: Any?, path: String) throws {
        let condition = try dictionary(value, path: path)
        guard let type = condition["type"] as? String else { try invalid("\(path).type") }
        switch type {
        case "Truthy": _ = try object(condition, required: ["type", "value"], path: path); try validateJourneyValue(condition["value"], path: "\(path).value")
        case "Compare": _ = try object(condition, required: ["type", "op", "left", "right"], path: path); try enumeration(condition["op"], values: ["==", "!=", "<", "<=", ">", ">="], path: "\(path).op"); try validateJourneyValue(condition["left"], path: "\(path).left"); try validateJourneyValue(condition["right"], path: "\(path).right")
        case "Contains": _ = try object(condition, required: ["type", "collection", "value"], path: path); try validateJourneyValue(condition["collection"], path: "\(path).collection"); try validateJourneyValue(condition["value"], path: "\(path).value")
        case "All", "Any": _ = try object(condition, required: ["type", "conditions"], path: path); for (index, item) in try array(condition["conditions"], path: "\(path).conditions").enumerated() { try validateJourneyCondition(item, path: "\(path).conditions[\(index)]") }
        case "Not": _ = try object(condition, required: ["type", "condition"], path: path); try validateJourneyCondition(condition["condition"], path: "\(path).condition")
        default: try invalid("\(path).type")
        }
    }

    private static func validateJourneyValueRecord(_ value: Any?, path: String) throws {
        for (key, nested) in try dictionary(value, path: path) { try identifier(key, path: "\(path).\(key)"); try validateJourneyValue(nested, path: "\(path).\(key)") }
    }

    private static func validateJourneyStringValue(_ value: Any?, path: String) throws { try validateJourneyValue(value, path: path, allowedTypes: ["String", "Event.Field", "Response.Field"]) }
    private static func validateJourneyNumberValue(_ value: Any?, path: String) throws { try validateJourneyValue(value, path: path, allowedTypes: ["Number", "Event.Field", "Response.Field"]) }

    private static func validateJourneyPurchasePlacementId(
        _ value: Any?,
        path: String,
        placementIDs: Set<String>? = nil
    ) throws {
        if let placementID = value as? String {
            try identifier(value, path: path)
            if let placementIDs, !placementIDs.contains(placementID) {
                try invalid(path)
            }
            return
        }
        let wrapped = try dictionary(value, path: path)
        if wrapped["literal"] != nil {
            _ = try object(wrapped, required: ["literal"], path: path)
            try identifier(wrapped["literal"], path: "\(path).literal")
            if let placementIDs,
               let placementID = wrapped["literal"] as? String,
               !placementIDs.contains(placementID) {
                try invalid("\(path).literal")
            }
            return
        }
        let referenceWrapper = try object(wrapped, required: ["ref"], path: path)
        let reference = try dictionary(referenceWrapper["ref"], path: "\(path).ref")
        switch reference["kind"] as? String {
        case "path":
            _ = try object(
                reference,
                required: ["kind", "path"],
                optional: ["viewModelName", "isRelative"],
                path: "\(path).ref"
            )
            try boundedString(reference["path"], minimum: 1, maximumUTF16: 512, path: "\(path).ref.path")
            guard let memberPath = reference["path"] as? String,
                  memberPath.split(whereSeparator: { $0 == "." || $0 == "/" }).last == "placementId" else {
                try invalid("\(path).ref.path")
            }
            if let viewModelName = reference["viewModelName"] {
                try identifier(viewModelName, path: "\(path).ref.viewModelName")
            }
            if let isRelative = reference["isRelative"], !isJSONBoolean(isRelative) {
                try invalid("\(path).ref.isRelative")
            }
        default:
            try invalid("\(path).ref.kind")
        }
    }

    private static func validateJourneyValue(_ value: Any?, path: String, allowedTypes: Set<String>? = nil) throws {
        let raw = try dictionary(value, path: path)
        guard let type = raw["type"] as? String, allowedTypes == nil || allowedTypes!.contains(type) else { try invalid("\(path).type") }
        switch type {
        case "Null": _ = try object(raw, required: ["type"], path: path)
        case "Boolean": _ = try object(raw, required: ["type", "value"], path: path); guard isJSONBoolean(raw["value"]) else { try invalid("\(path).value") }
        case "Number": _ = try object(raw, required: ["type", "value"], path: path); try finiteNumber(raw["value"], minimum: -Double.greatestFiniteMagnitude, maximum: Double.greatestFiniteMagnitude, path: "\(path).value")
        case "String": _ = try object(raw, required: ["type", "value"], path: path); try boundedString(raw["value"], minimum: 0, maximumUTF16: 65_535, path: "\(path).value")
        case "Array": _ = try object(raw, required: ["type", "items"], path: path); for (index, item) in try array(raw["items"], path: "\(path).items").enumerated() { try validateJourneyValue(item, path: "\(path).items[\(index)]") }
        case "Object": _ = try object(raw, required: ["type", "fields"], path: path); try validateJourneyValueRecord(raw["fields"], path: "\(path).fields")
        case "Event.Field", "Response.Field": _ = try object(raw, required: ["type", "key"], path: path); try identifier(raw["key"], path: "\(path).key")
        default: try invalid("\(path).type")
        }
    }

    private static func validateResponseContract(
        schema: Any?,
        captures: Any?,
        behaviors: Any?,
        screenIDs: Set<String>
    ) throws {
        var fieldKeys: Set<String> = []
        if let schema {
            let schema = try object(
                schema,
                required: ["key", "responseSchemaVersionId", "schemaVersion", "fields"],
                path: "responseSchema"
            )
            try identifier(schema["key"], path: "responseSchema.key")
            try identifier(schema["responseSchemaVersionId"], path: "responseSchema.responseSchemaVersionId")
            try integer(schema["schemaVersion"], minimum: 1, maximum: 65_535, path: "responseSchema.schemaVersion")
            for (index, item) in try array(schema["fields"], path: "responseSchema.fields").enumerated() {
                let field = try dictionary(item, path: "responseSchema.fields[\(index)]")
                try identifier(field["key"], path: "responseSchema.fields[\(index)].key")
                guard let key = field["key"] as? String, fieldKeys.insert(key).inserted else {
                    try invalid("responseSchema.fields")
                }
            }
        }
        for (index, item) in try array(captures, path: "responseCaptures").enumerated() {
            let capture = try object(item, required: ["screenId", "fields"], path: "responseCaptures[\(index)]")
            try identifier(capture["screenId"], path: "responseCaptures[\(index)].screenId")
            let fields = try array(capture["fields"], path: "responseCaptures[\(index)].fields")
            guard !fields.isEmpty else { try invalid("responseCaptures[\(index)].fields") }
            for field in fields {
                try identifier(field, path: "responseCaptures[\(index)].fields")
                guard let field = field as? String, fieldKeys.contains(field) else {
                    try invalid("responseCaptures[\(index)].fields")
                }
            }
        }
        let behaviorItems = try array(behaviors, path: "screenBehaviors")
        guard behaviorItems.count == screenIDs.count else { try invalid("screenBehaviors") }
        var seenScreens: Set<String> = []
        var previousScreenID: String?
        var scriptArtifactSizes: [String: Int] = [:]
        for (index, item) in behaviorItems.enumerated() {
            let behavior = try object(
                item,
                required: ["screenId", "controls"],
                optional: ["script"],
                path: "screenBehaviors[\(index)]"
            )
            try identifier(behavior["screenId"], path: "screenBehaviors[\(index)].screenId")
            let screenID = behavior["screenId"] as! String
            guard screenIDs.contains(screenID), seenScreens.insert(screenID).inserted else { try invalid("screenBehaviors[\(index)].screenId") }
            if let previousScreenID, !javascriptStringPrecedes(previousScreenID, screenID) { try invalid("screenBehaviors") }
            previousScreenID = screenID
            let controls = try array(behavior["controls"], path: "screenBehaviors[\(index)].controls")
            var seenActionIDs: Set<String> = []
            var previousActionID: String?
            var scriptedActionIDs: [String] = []
            for (controlIndex, item) in controls.enumerated() {
                let control = try object(item, required: ["actionId", "behavior"], path: "screenBehaviors[\(index)].controls[\(controlIndex)]")
                try identifier(control["actionId"], path: "screenBehaviors[\(index)].controls[\(controlIndex)].actionId")
                let actionID = control["actionId"] as! String
                guard seenActionIDs.insert(actionID).inserted else { try invalid("screenBehaviors[\(index)].controls") }
                if let previousActionID, !javascriptStringPrecedes(previousActionID, actionID) { try invalid("screenBehaviors[\(index)].controls") }
                previousActionID = actionID
                let binding = try dictionary(control["behavior"], path: "screenBehaviors[\(index)].controls[\(controlIndex)].behavior")
                guard let kind = binding["kind"] as? String else {
                    try invalid("screenBehaviors[\(index)].controls[\(controlIndex)].behavior.kind")
                }
                switch kind {
                case "declarative":
                    _ = try object(binding, required: ["kind", "program"], path: "screenBehaviors[\(index)].controls[\(controlIndex)].behavior")
                    try validateDeclarativeScreenProgram(binding["program"], path: "screenBehaviors[\(index)].controls[\(controlIndex)].behavior.program")
                case "script":
                    _ = try object(binding, required: ["kind"], path: "screenBehaviors[\(index)].controls[\(controlIndex)].behavior")
                    scriptedActionIDs.append(actionID)
                default: try invalid("screenBehaviors[\(index)].controls[\(controlIndex)].behavior.kind")
                }
            }
            if let script = behavior["script"] {
                guard !scriptedActionIDs.isEmpty else { try invalid("screenBehaviors[\(index)].script") }
                let script = try object(script, required: ["protocol", "artifact", "exportedActionIds"], path: "screenBehaviors[\(index)].script")
                guard script["protocol"] as? String == "screen-actions" else { try invalid("screenBehaviors[\(index)].script.protocol") }
                try validateScreenBehaviorArtifact(script["artifact"], path: "screenBehaviors[\(index)].script.artifact")
                let artifact = try dictionary(script["artifact"], path: "screenBehaviors[\(index)].script.artifact")
                scriptArtifactSizes[artifact["sha256"] as! String] = artifact["sizeBytes"] as! Int
                let exported = try array(script["exportedActionIds"], path: "screenBehaviors[\(index)].script.exportedActionIds")
                try validateSortedIdentifiers(exported, maximum: 256, path: "screenBehaviors[\(index)].script.exportedActionIds")
                let exportedIDs = Set(exported as! [String])
                guard exportedIDs == Set(scriptedActionIDs) else { try invalid("screenBehaviors[\(index)].script.exportedActionIds") }
            } else if !scriptedActionIDs.isEmpty {
                try invalid("screenBehaviors[\(index)].script")
            }
        }
        guard scriptArtifactSizes.values.reduce(0, +) <= 16 * 1024 * 1024 else {
            try invalid("screenBehaviors")
        }
    }

    private static func validateDeclarativeScreenProgram(_ value: Any?, path: String) throws {
        for (index, item) in try array(value, path: path).enumerated() {
            let action = try dictionary(item, path: "\(path)[\(index)]")
            guard let type = action["type"] as? String else { try invalid("\(path)[\(index)].type") }
            switch type {
            case "emit":
                _ = try object(action, required: ["type", "eventName"], optional: ["payload"], path: "\(path)[\(index)]")
                try identifier(action["eventName"], path: "\(path)[\(index)].eventName")
                if let payload = action["payload"] { try validateDeclarativePayload(payload, path: "\(path)[\(index)].payload") }
            case "response_set":
                _ = try object(action, required: ["type", "field", "value"], path: "\(path)[\(index)]")
                try identifier(action["field"], path: "\(path)[\(index)].field")
                try validateDeclarativeValueSource(action["value"], path: "\(path)[\(index)].value")
            case "response_unset":
                _ = try object(action, required: ["type", "field"], path: "\(path)[\(index)]")
                try identifier(action["field"], path: "\(path)[\(index)].field")
            default: try invalid("\(path)[\(index)].type")
            }
        }
    }

    private static func validateDeclarativePayload(_ value: Any?, path: String) throws {
        for (key, source) in try dictionary(value, path: path) {
            try identifier(key, path: "\(path).\(key)")
            try validateDeclarativeValueSource(source, path: "\(path).\(key)")
        }
    }

    private static func validateDeclarativeValueSource(_ value: Any?, path: String) throws {
        let source = try dictionary(value, path: path)
        guard let kind = source["source"] as? String else { try invalid("\(path).source") }
        switch kind {
        case "literal": _ = try object(source, required: ["source", "value"], path: path)
        case "invocation_value", "component_id", "instance_id": _ = try object(source, required: ["source"], path: path)
        default: try invalid("\(path).source")
        }
    }

    private static func validateScreenBehaviorArtifact(_ value: Any?, path: String) throws {
        let artifact = try object(value, required: ["key", "sha256", "sizeBytes", "contentType"], path: path)
        try validateArtifactSemantics(artifact, path: path, expectedPrefix: "screen-behavior/sha256/", expectedExtension: "bin", expectedContentTypes: ["application/octet-stream"])
        try integer(artifact["sizeBytes"], minimum: 1, maximum: 4 * 1024 * 1024, path: "\(path).sizeBytes")
    }

    private static func validateRender(_ value: Any?) throws {
        let render = try object(
            value,
            required: ["renderer", "riv", "screens", "transitions", "textInputs", "assets"],
            path: "render"
        )
        guard render["renderer"] as? String == "rive" else { try invalid("render.renderer") }
        try validateArtifact(render["riv"], path: "render.riv", includeKind: false)
        try validateArtifactSemantics(
            render["riv"],
            path: "render.riv",
            expectedPrefix: "renders/sha256/",
            expectedExtension: "riv",
            expectedContentTypes: ["application/vnd.rive"]
        )
        let screens = try array(render["screens"], path: "render.screens")
        guard (1...256).contains(screens.count) else { try invalid("render.screens") }
        let screenIDs = try screens.enumerated().map { index, item -> String in
            let screen = try object(
                item,
                required: ["id", "artboardId", "artboardName", "width", "height"],
                optional: ["exit"],
                path: "render.screens[\(index)]"
            )
            try identifier(screen["id"], path: "render.screens[\(index)].id")
            try identifier(screen["artboardId"], path: "render.screens[\(index)].artboardId")
            try boundedString(screen["artboardName"], minimum: 1, maximumUTF16: 256, path: "render.screens[\(index)].artboardName")
            try finiteNumber(screen["width"], minimum: 0, maximum: 16_384, exclusiveMinimum: true, path: "render.screens[\(index)].width")
            try finiteNumber(screen["height"], minimum: 0, maximum: 16_384, exclusiveMinimum: true, path: "render.screens[\(index)].height")
            if let exit = screen["exit"] {
                let exit = try object(exit, required: ["completeEventName", "durationMs"], path: "render.screens[\(index)].exit")
                try identifier(exit["completeEventName"], path: "render.screens[\(index)].exit.completeEventName")
                try integer(exit["durationMs"], minimum: 0, maximum: 60_000, path: "render.screens[\(index)].exit.durationMs")
            }
            return screen["id"] as! String
        }
        guard Set(screenIDs).count == screenIDs.count else { try invalid("render.screens") }
        let screenIDSet = Set(screenIDs)
        let transitions = try array(render["transitions"], path: "render.transitions")
        guard transitions.count <= 1_024 else { try invalid("render.transitions") }
        try transitions.enumerated().forEach { index, item in
            let transition = try object(
                item,
                required: [
                    "id", "kind", "sourceScreenId", "destinationScreenId", "durationMs",
                    "incomingOnTop", "source", "destination",
                ],
                optional: ["reverse"],
                path: "render.transitions[\(index)]"
            )
            try identifier(transition["id"], path: "render.transitions[\(index)].id")
            guard transition["kind"] as? String == "choreographed" else { try invalid("render.transitions[\(index)].kind") }
            for field in ["sourceScreenId", "destinationScreenId"] {
                try identifier(transition[field], path: "render.transitions[\(index)].\(field)")
                guard screenIDSet.contains(transition[field] as! String) else { try invalid("render.transitions[\(index)].\(field)") }
            }
            try integer(transition["durationMs"], minimum: 0, maximum: 60_000, path: "render.transitions[\(index)].durationMs")
            guard isJSONBoolean(transition["incomingOnTop"]) else { try invalid("render.transitions[\(index)].incomingOnTop") }
            try validateEndpoint(transition["source"], path: "render.transitions[\(index)].source")
            try validateEndpoint(transition["destination"], path: "render.transitions[\(index)].destination")
            if let reverse = transition["reverse"] {
                let reverse = try object(
                    reverse,
                    required: ["source", "destination"],
                    optional: ["durationMs", "incomingOnTop"],
                    path: "render.transitions[\(index)].reverse"
                )
                if let duration = reverse["durationMs"] { try integer(duration, minimum: 0, maximum: 60_000, path: "render.transitions[\(index)].reverse.durationMs") }
                if let incoming = reverse["incomingOnTop"], !isJSONBoolean(incoming) { try invalid("render.transitions[\(index)].reverse.incomingOnTop") }
                try validateEndpoint(reverse["source"], path: "render.transitions[\(index)].reverse.source")
                try validateEndpoint(reverse["destination"], path: "render.transitions[\(index)].reverse.destination")
            }
        }
        let textInputs = try array(render["textInputs"], path: "render.textInputs")
        guard textInputs.count <= 1_024 else { try invalid("render.textInputs") }
        try textInputs.enumerated().forEach { index, item in
            let input = try object(
                item,
                required: [
                    "id", "screenId", "artboardId", "viewNodeId", "renderedNodeId",
                    "riveTextObjectKey", "riveTextRunObjectKey", "riveTextName",
                    "riveTextRunName", "value", "editable", "geometry", "style",
                    "secureTextEntry", "multiline",
                ],
                optional: ["responseFieldKey", "placeholder", "keyboardType", "maxLength"],
                path: "render.textInputs[\(index)]"
            )
            for field in ["id", "screenId", "artboardId", "viewNodeId", "renderedNodeId", "riveTextObjectKey", "riveTextRunObjectKey"] { try identifier(input[field], path: "render.textInputs[\(index)].\(field)") }
            guard screenIDSet.contains(input["screenId"] as! String) else { try invalid("render.textInputs[\(index)].screenId") }
            try boundedString(input["riveTextName"], minimum: 1, maximumUTF16: 256, path: "render.textInputs[\(index)].riveTextName")
            try boundedString(input["riveTextRunName"], minimum: 1, maximumUTF16: 256, path: "render.textInputs[\(index)].riveTextRunName")
            try boundedString(input["value"], minimum: 0, maximumUTF16: 1_000_000, path: "render.textInputs[\(index)].value")
            if let value = input["responseFieldKey"] { try identifier(value, path: "render.textInputs[\(index)].responseFieldKey") }
            if let value = input["placeholder"] { try boundedString(value, minimum: 0, maximumUTF16: 1_024, path: "render.textInputs[\(index)].placeholder") }
            for field in ["editable", "secureTextEntry", "multiline"] where !isJSONBoolean(input[field]) { try invalid("render.textInputs[\(index)].\(field)") }
            if let value = input["keyboardType"] { try boundedString(value, minimum: 1, maximumUTF16: 64, path: "render.textInputs[\(index)].keyboardType") }
            if let value = input["maxLength"] { try integer(value, minimum: 1, maximum: 1_000_000, path: "render.textInputs[\(index)].maxLength") }
            let geometry = try object(
                input["geometry"],
                required: ["xPath", "yPath", "widthPath", "heightPath", "rotationPath", "scaleXPath", "scaleYPath"],
                path: "render.textInputs[\(index)].geometry"
            )
            for field in ["xPath", "yPath", "widthPath", "heightPath", "rotationPath", "scaleXPath", "scaleYPath"] { try boundedString(geometry[field], minimum: 1, maximumUTF16: 512, path: "render.textInputs[\(index)].geometry.\(field)") }
            let style = try object(
                input["style"],
                required: ["fontFamily", "fontWeight", "fontStyle", "fontSize", "lineHeight", "letterSpacing", "color", "fontAssetRiveUniqueName"],
                optional: ["textAlign"],
                path: "render.textInputs[\(index)].style"
            )
            try boundedString(style["fontFamily"], minimum: 1, maximumUTF16: 256, path: "text.style.fontFamily")
            try boundedString(style["fontWeight"], minimum: 1, maximumUTF16: 32, path: "text.style.fontWeight")
            try enumeration(style["fontStyle"], values: ["normal", "italic"], path: "text.style.fontStyle")
            try finiteNumber(style["fontSize"], minimum: 0, maximum: 2_048, exclusiveMinimum: true, path: "text.style.fontSize")
            try finiteNumber(style["lineHeight"], minimum: 0, maximum: 8_192, exclusiveMinimum: true, path: "text.style.lineHeight")
            try finiteNumber(style["letterSpacing"], minimum: -2_048, maximum: 2_048, path: "text.style.letterSpacing")
            try integer(style["color"], minimum: 0, maximum: Double(UInt32.max), path: "text.style.color")
            try identifier(style["fontAssetRiveUniqueName"], path: "text.style.fontAssetRiveUniqueName")
            if let value = style["textAlign"] { try boundedString(value, minimum: 1, maximumUTF16: 32, path: "text.style.textAlign") }
        }
        let assets = try array(render["assets"], path: "render.assets")
        guard assets.count <= 1_024 else { try invalid("render.assets") }
        try assets.enumerated().forEach { index, item in
            try validateRenderAsset(item, path: "render.assets[\(index)]")
        }
        let assetKeys = try assets.enumerated().map { index, value in
            let asset = try dictionary(value, path: "render.assets[\(index)]")
            guard let key = asset["key"] as? String else { try invalid("render.assets[\(index)].key") }
            return key
        }
        guard zip(assetKeys, assetKeys.dropFirst()).allSatisfy(javascriptStringPrecedes) else {
            try invalid("render.assets")
        }
    }

    private static func validateRenderAsset(_ value: Any, path: String) throws {
        let typed = try typedObject(value, path: path)
        switch typed.type {
        case "image":
            _ = try object(
                typed.object,
                required: ["kind", "key", "sha256", "sizeBytes", "contentType", "riveAssetId", "riveUniqueName", "width", "height", "required"],
                path: path
            )
            let contentType = typed.object["contentType"] as? String
            let expectedExtension: String
            switch contentType {
            case "image/png": expectedExtension = "png"
            case "image/jpeg": expectedExtension = "jpg"
            case "image/webp": expectedExtension = "webp"
            default: try invalid("\(path).contentType")
            }
            try validateArtifactSemantics(
                typed.object,
                path: path,
                expectedPrefix: "assets/sha256/",
                expectedExtension: expectedExtension,
                expectedContentTypes: [contentType!]
            )
            try integer(typed.object["riveAssetId"], minimum: 0, maximum: 9_007_199_254_740_991, path: "\(path).riveAssetId")
            try identifier(typed.object["riveUniqueName"], path: "\(path).riveUniqueName")
            try integer(typed.object["width"], minimum: 1, maximum: 65_535, path: "\(path).width")
            try integer(typed.object["height"], minimum: 1, maximum: 65_535, path: "\(path).height")
            guard isJSONBoolean(typed.object["required"]) else { try invalid("\(path).required") }
        case "font":
            _ = try object(
                typed.object,
                required: ["kind", "key", "sha256", "sizeBytes", "contentType", "riveAssetId", "riveUniqueName", "family", "weight", "style", "format", "required"],
                path: path
            )
            guard let contentType = typed.object["contentType"] as? String,
                  let format = typed.object["format"] as? String,
                  ["ttf", "otf"].contains(format) else { try invalid(path) }
            let expectedExtension: String
            switch contentType {
            case "font/ttf": expectedExtension = "ttf"
            case "font/otf": expectedExtension = "otf"
            case "application/octet-stream": expectedExtension = "bin"
            default: try invalid("\(path).contentType")
            }
            guard contentType == "application/octet-stream" || format == expectedExtension else {
                try invalid("\(path).format")
            }
            try validateArtifactSemantics(
                typed.object,
                path: path,
                expectedPrefix: "assets/sha256/",
                expectedExtension: expectedExtension,
                expectedContentTypes: [contentType]
            )
            try integer(typed.object["riveAssetId"], minimum: 0, maximum: 9_007_199_254_740_991, path: "\(path).riveAssetId")
            try identifier(typed.object["riveUniqueName"], path: "\(path).riveUniqueName")
            try boundedString(typed.object["family"], minimum: 1, maximumUTF16: 256, path: "\(path).family")
            try boundedString(typed.object["weight"], minimum: 1, maximumUTF16: 32, path: "\(path).weight")
            try enumeration(typed.object["style"], values: ["normal", "italic"], path: "\(path).style")
            try enumeration(typed.object["format"], values: ["ttf", "otf"], path: "\(path).format")
            guard isJSONBoolean(typed.object["required"]) else { try invalid("\(path).required") }
        case "script", "shader":
            _ = try object(
                typed.object,
                required: ["kind", "key", "sha256", "sizeBytes", "contentType", "required"],
                path: path
            )
            try validateArtifactSemantics(
                typed.object,
                path: path,
                expectedPrefix: "assets/sha256/",
                expectedExtension: "bin",
                expectedContentTypes: ["application/octet-stream"]
            )
            guard isJSONBoolean(typed.object["required"]) else { try invalid("\(path).required") }
        default: try invalid("\(path).kind")
        }
    }

    private static func validateArtifact(_ value: Any?, path: String, includeKind: Bool) throws {
        var required: Set<String> = ["key", "sha256", "sizeBytes", "contentType"]
        if includeKind { required.insert("kind") }
        _ = try object(value, required: required, path: path)
    }

    private static func validateArtifactSemantics(
        _ value: Any?,
        path: String,
        expectedPrefix: String,
        expectedExtension: String,
        expectedContentTypes: Set<String>
    ) throws {
        let artifact = try dictionary(value, path: path)
        guard let key = artifact["key"] as? String,
              let digest = artifact["sha256"] as? String,
              digest.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { try invalid(path) }
        guard key == "\(expectedPrefix)\(digest).\(expectedExtension)" else {
            throw ExperienceReleaseDescriptorAuthenticationError.unsafeArtifactKey(key)
        }
        guard let contentType = artifact["contentType"] as? String,
              expectedContentTypes.contains(contentType) else { try invalid(path) }
    }

    private static func validateEndpoint(_ value: Any?, path: String) throws {
        let endpoint = try object(value, required: ["completeEventName"], path: path)
        try identifier(endpoint["completeEventName"], path: "\(path).completeEventName")
    }

    private static func recordArrays(
        _ value: Any?,
        path: String,
        body: (Any, String) throws -> Void
    ) throws {
        for (key, value) in try dictionary(value, path: path) {
            try identifier(key, path: "\(path).key")
            let values = try array(value, path: "\(path).\(key)")
            guard values.count <= 256 else { try invalid("\(path).\(key)") }
            try values.enumerated().forEach { index, item in
                try body(item, "\(path).\(key)[\(index)]")
            }
        }
    }

    private static func typedObject(_ value: Any?, path: String) throws
        -> (object: [String: Any], type: String)
    {
        let object = try dictionary(value, path: path)
        guard let type = (object["type"] ?? object["kind"]) as? String else {
            try invalid("\(path).type")
        }
        return (object, type)
    }

    @discardableResult
    private static func object(
        _ value: Any?,
        required: Set<String>,
        optional: Set<String> = [],
        path: String
    ) throws -> [String: Any] {
        let value = try dictionary(value, path: path)
        guard required.isSubset(of: value.keys),
              Set(value.keys).isSubset(of: required.union(optional)) else {
            try invalid(path)
        }
        return value
    }

    private static func dictionary(_ value: Any?, path: String) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { try invalid(path) }
        return value
    }

    private static func array(_ value: Any?, path: String) throws -> [Any] {
        guard let value = value as? [Any] else { try invalid(path) }
        return value
    }

    private static func identifier(_ value: Any?, path: String) throws {
        guard let value = value as? String,
              !value.isEmpty,
              !value.contains("\u{0}"),
              value.utf16.count <= 128 else { try invalid(path) }
    }

    private static func enumeration(
        _ value: Any?,
        values: Set<String>,
        path: String
    ) throws {
        guard let value = value as? String, values.contains(value) else { try invalid(path) }
    }

    private static func boundedString(
        _ value: Any?,
        minimum: Int,
        maximumUTF16: Int,
        path: String
    ) throws {
        guard let value = value as? String,
              value.utf16.count >= minimum,
              value.utf16.count <= maximumUTF16 else { try invalid(path) }
    }

    private static func timeOfDay(_ value: Any?, path: String) throws {
        guard let value = value as? String else { try invalid(path) }
        let bytes = Array(value.utf8)
        guard bytes.count == 5,
              bytes[2] == 58,
              [bytes[0], bytes[1], bytes[3], bytes[4]].allSatisfy({
                  (48...57).contains($0)
              }),
              let hour = Int(String(decoding: bytes[0...1], as: UTF8.self)),
              let minute = Int(String(decoding: bytes[3...4], as: UTF8.self)),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            try invalid(path)
        }
    }

    private static func validateSortedIdentifiers(
        _ values: [Any],
        maximum: Int,
        path: String
    ) throws {
        guard values.count <= maximum else { try invalid(path) }
        let strings = try values.enumerated().map { index, value -> String in
            try identifier(value, path: "\(path)[\(index)]")
            return value as! String
        }
        guard zip(strings, strings.dropFirst()).allSatisfy({
            javascriptStringPrecedes($0, $1)
        }) else { try invalid(path) }
    }

    private static func validateJSONRecord(_ value: Any?, path: String) throws {
        for key in try dictionary(value, path: path).keys {
            guard !key.isEmpty, key.utf16.count <= 128 else { try invalid("\(path).key") }
        }
    }

    private static func finiteNumber(
        _ value: Any?,
        minimum: Double,
        maximum: Double,
        exclusiveMinimum: Bool = false,
        path: String
    ) throws {
        guard let value = value as? NSNumber,
              isJSONNumber(value),
              value.doubleValue.isFinite,
              value.doubleValue <= maximum,
              exclusiveMinimum
                ? value.doubleValue > minimum
                : value.doubleValue >= minimum else { try invalid(path) }
    }

    private static func color(_ value: Any?, path: String) throws {
        guard let value = value as? String,
              value.count == 9,
              value.first == "#",
              value.dropFirst().utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }) else { try invalid(path) }
    }

    private static func lowercaseSHA256(_ value: Any?, path: String) throws {
        guard let value = value as? String,
              value.utf8.count == 64,
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else { try invalid(path) }
    }

    private static func semanticVersion(_ value: Any?, path: String) throws {
        guard let value = value as? String, value.utf16.count <= 64 else { try invalid(path) }
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3 else { try invalid(path) }
        for component in core {
            guard let number = Int(component),
                  number <= 2_147_483_647,
                  String(number) == component else { try invalid(path) }
        }
        if parts.count == 2 {
            let prerelease = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard prerelease.allSatisfy({ token in
                !token.isEmpty && token.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0)
                        || (97...122).contains($0) || $0 == 45
                }) && !(token.count > 1 && token.first == "0" && token.allSatisfy(\.isNumber))
            }) else { try invalid(path) }
        }
    }

    private static func integer(
        _ value: Any?,
        minimum: Double,
        maximum: Double,
        path: String
    ) throws {
        let safeMaximum = min(maximum, 9_007_199_254_740_991)
        guard let value = value as? NSNumber,
              isJSONNumber(value),
              value.doubleValue.isFinite,
              value.doubleValue.rounded() == value.doubleValue,
              (minimum...safeMaximum).contains(value.doubleValue) else { try invalid(path) }
    }

    private static func isJSONNumber(_ value: NSNumber) -> Bool {
        CFGetTypeID(value) != CFBooleanGetTypeID()
    }

    private static func isJSONBoolean(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber else { return false }
        return CFGetTypeID(value) == CFBooleanGetTypeID()
    }

    private static func javascriptStringPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
    }

    private static func invalid(_ path: String) throws -> Never {
        throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
    }
}
