#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation

enum JourneyRouteHostV2: Hashable, Sendable {
    case journey
    case screen(String)
}

struct JourneyRouteKeyV2: Hashable, Sendable {
    let host: JourneyRouteHostV2
    let eventName: String
}

struct JourneyRouteV2: Sendable {
    let key: JourneyRouteKeyV2
    let revisionSHA256: String
    let program: [ExperienceReleaseJSONValue]
}

struct JourneyExecutionCursorV2: Equatable, Sendable {
    let programPath: String
    let actionIndex: Int
}

struct JourneyExecutionRegionV2: Equatable, Sendable {
    let id: String
    let plane: JourneyPlane
    let entryCursor: JourneyExecutionCursorV2
    let actionPaths: [String]
}

struct JourneyExecutionHandoffEdgeV2: Equatable, Sendable {
    let id: String
    let fromRegionId: String
    let fromCursor: JourneyExecutionCursorV2
    let toRegionId: String
    let toCursor: JourneyExecutionCursorV2
    let direction: String
    let deviceClaimTimeoutMs: Int?
    let onDeviceUnavailableRegionId: String?
    let onDeviceUnavailableCursor: JourneyExecutionCursorV2?
}

struct JourneyExecutionPlanV2: Equatable, Sendable {
    let id: String
    let route: JourneyRouteKeyV2
    let revisionSHA256: String
    let startPlane: JourneyPlane
    let entryRegionId: String
    let entryCursor: JourneyExecutionCursorV2
    let deviceRegions: [JourneyExecutionRegionV2]
    let serverRegions: [JourneyExecutionRegionV2]
    let handoffEdges: [JourneyExecutionHandoffEdgeV2]

    var allRegions: [JourneyExecutionRegionV2] { deviceRegions + serverRegions }

    func region(id: String) -> JourneyExecutionRegionV2? {
        allRegions.first { $0.id == id }
    }

    func edge(fromRegionId: String, at cursor: JourneyExecutionCursorV2) -> JourneyExecutionHandoffEdgeV2? {
        handoffEdges.first {
            $0.fromRegionId == fromRegionId
                && $0.fromCursor == cursor
        }
    }
}

struct JourneyScreenV2: Sendable {
    let id: String
    let defaultViewModelName: String?
    let defaultInstanceId: String?
}

struct ExperienceDefinitionV2: Sendable {
    let entryRouteEventName: String
    let screens: [JourneyScreenV2]
    let viewModelValues: [JourneyViewModelValue]
    let routes: [JourneyRouteKeyV2: JourneyRouteV2]
    let executionPlans: [JourneyExecutionPlanV2]
    let responseSchema: PinnedResponseSessionSchema?
    let controlsByScreen: [String: [String: ScreenControlActionDefinition]]
    let appDefaultTimezone: TimeZone?

    init(
        entryRouteEventName: String,
        screens: [JourneyScreenV2],
        viewModelValues: [JourneyViewModelValue],
        routes: [JourneyRouteKeyV2: JourneyRouteV2],
        executionPlans: [JourneyExecutionPlanV2],
        responseSchema: PinnedResponseSessionSchema?,
        controlsByScreen: [String: [String: ScreenControlActionDefinition]],
        appDefaultTimezone: TimeZone? = nil
    ) {
        self.entryRouteEventName = entryRouteEventName
        self.screens = screens
        self.viewModelValues = viewModelValues
        self.routes = routes
        self.executionPlans = executionPlans
        self.responseSchema = responseSchema
        self.controlsByScreen = controlsByScreen
        self.appDefaultTimezone = appDefaultTimezone
    }

    init(descriptor: ExperienceReleaseDescriptorV2) throws {
        guard case .string(let entryRouteEventName) = descriptor.journey["entryRouteEventName"],
              case .array(let screenValues) = descriptor.journey["screens"],
              case .array(let viewModelValueValues) = descriptor.journey["viewModelValues"],
              case .array(let routeValues) = descriptor.journey["routes"],
              case .array(let planValues) = descriptor.journey["executionPlans"] else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        self.entryRouteEventName = entryRouteEventName
        if case .string(let identifier) = descriptor.metadata["appDefaultTimezone"] {
            self.appDefaultTimezone = TimeZone(identifier: identifier)
        } else {
            self.appDefaultTimezone = nil
        }
        screens = try screenValues.map { value in
            guard case .object(let screen) = value,
                  case .string(let id) = screen["id"] else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            return JourneyScreenV2(
                id: id,
                defaultViewModelName: screen["defaultViewModelName"]?.stringValue,
                defaultInstanceId: screen["defaultInstanceId"]?.stringValue
            )
        }
        viewModelValues = try viewModelValueValues.map { value in
            guard case .object(let entry) = value,
                  case .string(let viewModelName) = entry["viewModelName"],
                  case .string(let path) = entry["path"],
                  let value = entry["value"] else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            return JourneyViewModelValue(
                viewModelName: viewModelName,
                instanceId: entry["instanceId"]?.stringValue,
                instanceName: entry["instanceName"]?.stringValue,
                path: path,
                value: AnyCodable(value.foundationValue)
            )
        }
        var routeTable: [JourneyRouteKeyV2: JourneyRouteV2] = [:]
        for value in routeValues {
            guard case .object(let route) = value,
                  case .object(let host) = route["host"],
                  case .string(let kind) = host["kind"],
                  case .string(let eventName) = route["eventName"],
                  case .string(let revision) = route["revisionSha256"],
                  case .array(let program) = route["program"] else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            let routeHost: JourneyRouteHostV2
            switch kind {
            case "journey": routeHost = .journey
            case "screen":
                guard case .string(let screenId) = host["screenId"] else {
                    throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
                }
                routeHost = .screen(screenId)
            default:
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            let key = JourneyRouteKeyV2(host: routeHost, eventName: eventName)
            guard routeTable[key] == nil else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            routeTable[key] = JourneyRouteV2(
                key: key,
                revisionSHA256: revision,
                program: program
            )
        }
        routes = routeTable
        let parsedPlans = try planValues.map(Self.executionPlan)
        guard Set(parsedPlans.map(\.id)).count == parsedPlans.count,
              parsedPlans.allSatisfy({ plan in
                  routeTable[plan.route]?.revisionSHA256 == plan.revisionSHA256
              }) else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        executionPlans = parsedPlans
        responseSchema = try Self.responseSchema(
            descriptor.responseSchema,
            captures: descriptor.responseCaptures
        )
        controlsByScreen = try Self.controlActions(descriptor.screenBehaviors)
    }

    func route(host: JourneyRouteHostV2, eventName: String) -> JourneyRouteV2? {
        routes[JourneyRouteKeyV2(host: host, eventName: eventName)]
    }

    func executionPlan(
        for route: JourneyRouteV2,
        startPlane: JourneyPlane
    ) -> JourneyExecutionPlanV2? {
        executionPlans.first {
            $0.route == route.key
                && $0.revisionSHA256 == route.revisionSHA256
                && $0.startPlane == startPlane
        }
    }

    func executionPlan(id: String) -> JourneyExecutionPlanV2? {
        executionPlans.first { $0.id == id }
    }

    func routeProgram(
        _ route: JourneyRouteV2,
        at programPath: String
    ) -> [ExperienceReleaseJSONValue]? {
        guard programPath.hasPrefix("/") else { return nil }
        var value: ExperienceReleaseJSONValue = .object(["program": .array(route.program)])
        for segment in programPath.split(separator: "/", omittingEmptySubsequences: true) {
            let key = String(segment)
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            switch value {
            case .object(let object):
                guard let next = object[key] else { return nil }
                value = next
            case .array(let array):
                guard let index = Int(key), array.indices.contains(index) else { return nil }
                value = array[index]
            default:
                return nil
            }
        }
        guard case .array(let program) = value else { return nil }
        return program
    }

    func compiledProgram(
        _ route: JourneyRouteV2,
        at cursor: JourneyExecutionCursorV2
    ) throws -> [JourneyAction] {
        guard let values = routeProgram(route, at: cursor.programPath),
              cursor.actionIndex >= 0,
              cursor.actionIndex <= values.count else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        let suffix = Array(values.dropFirst(cursor.actionIndex))
        let bytes = try JSONSerialization.data(withJSONObject: suffix.map(\.foundationValue))
        return try JSONDecoder().decode([JourneyAction].self, from: bytes)
    }

    /// Materializes only the actions owned by a signed device region. The
    /// compiler's handoff edges are represented as internal actions at the
    /// exact cursor where ownership changes; authored route actions are never
    /// reinterpreted as handoffs.
    func compiledDeviceRegionProgram(
        _ route: JourneyRouteV2,
        plan: JourneyExecutionPlanV2,
        region: JourneyExecutionRegionV2
    ) throws -> [JourneyAction] {
        guard region.plane == .device else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        guard let source = routeProgram(route, at: region.entryCursor.programPath) else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        let projected = try projectProgram(
            .array(source),
            path: region.entryCursor.programPath,
            plan: plan,
            region: region,
            minimumIndex: region.entryCursor.actionIndex
        )
        let bytes = try JSONSerialization.data(withJSONObject: projected.map(\.foundationValue))
        return try JSONDecoder().decode([JourneyAction].self, from: bytes)
    }

    private func projectProgram(
        _ value: ExperienceReleaseJSONValue,
        path: String,
        plan: JourneyExecutionPlanV2,
        region: JourneyExecutionRegionV2,
        minimumIndex: Int = 0
    ) throws -> [ExperienceReleaseJSONValue] {
        guard case .array(let actions) = value else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        var result: [ExperienceReleaseJSONValue] = []
        for (index, action) in actions.enumerated() {
            if index < minimumIndex { continue }
            let actionPath = "\(path)/\(index)"
            guard case .object(let object) = action,
                  case .string(let type) = object["type"] else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            let cursor = JourneyExecutionCursorV2(
                programPath: path,
                actionIndex: index
            )
            if let edge = plan.edge(fromRegionId: region.id, at: cursor) {
                guard edge.direction == "device_to_server" else {
                    throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
                }
                result.append(.object([
                    "type": .string("handoff"),
                    "nodeId": .string(edge.id),
                    "edgeId": .string(edge.id),
                    "direction": .string(edge.direction),
                    "toRegionId": .string(edge.toRegionId),
                    "toNodeId": .string("\(edge.toCursor.programPath)/\(edge.toCursor.actionIndex)"),
                ]))
                continue
            }
            guard region.actionPaths.contains(actionPath) else { continue }
            result.append(try projectAction(
                .object(object),
                type: type,
                path: actionPath,
                plan: plan,
                region: region
            ))
        }
        let terminalCursor = JourneyExecutionCursorV2(
            programPath: path,
            actionIndex: actions.count
        )
        if let edge = plan.edge(fromRegionId: region.id, at: terminalCursor) {
            guard edge.direction == "device_to_server" else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            result.append(.object([
                "type": .string("handoff"),
                "nodeId": .string(edge.id),
                "edgeId": .string(edge.id),
                "direction": .string(edge.direction),
                "toRegionId": .string(edge.toRegionId),
                "toNodeId": .string("\(edge.toCursor.programPath)/\(edge.toCursor.actionIndex)"),
            ]))
        }
        return result
    }

    private func projectAction(
        _ value: ExperienceReleaseJSONValue,
        type: String,
        path: String,
        plan: JourneyExecutionPlanV2,
        region: JourneyExecutionRegionV2
    ) throws -> ExperienceReleaseJSONValue {
        guard case .object(var object) = value else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        let childKeys = [
            "onInside", "onSatisfied", "onTimeout", "defaultProgram",
            "onAvailable", "onUnavailable", "onCompleted", "onFailed",
            "onCancelled", "onRestored", "onNoPurchases", "onSucceeded"
        ]
        for key in childKeys {
            guard let child = object[key] else { continue }
            guard case .array = child else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            object[key] = .array(try projectProgram(
                child,
                path: "\(path)/\(key)",
                plan: plan,
                region: region
            ))
        }
        if case .array(let branches) = object["branches"] {
            object["branches"] = .array(try branches.enumerated().map { index, branch in
                guard case .object(var branchObject) = branch,
                      let program = branchObject["program"] else {
                    throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
                }
                branchObject["program"] = .array(try projectProgram(
                    program,
                    path: "\(path)/branches/\(index)/program",
                    plan: plan,
                    region: region
                ))
                return .object(branchObject)
            })
        }
        if case .array(let variants) = object["variants"] {
            object["variants"] = .array(try variants.enumerated().map { index, variant in
                guard case .object(var variantObject) = variant,
                      let program = variantObject["program"] else {
                    throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
                }
                variantObject["program"] = .array(try projectProgram(
                    program,
                    path: "\(path)/variants/\(index)/program",
                    plan: plan,
                    region: region
                ))
                return .object(variantObject)
            })
        }
        return .object(object)
    }

    func control(screenId: String, actionId: String) -> ScreenControlActionDefinition? {
        controlsByScreen[screenId]?[actionId]
    }

    func compiledProgram(for route: JourneyRouteV2) throws -> [JourneyAction] {
        try compiledProgram(
            route,
            at: JourneyExecutionCursorV2(programPath: "/program", actionIndex: 0)
        )
    }

    var renderShell: JourneyDocument {
        JourneyDocument(
            schemaVersion: 2,
            screens: screens.map {
                JourneyScreen(
                    id: $0.id,
                    defaultViewModelName: $0.defaultViewModelName,
                    defaultInstanceId: $0.defaultInstanceId
                )
            },
            viewModelValues: viewModelValues,
            responseSchemas: responseSchema.map {
                [JourneyResponseSchema(
                    responseSchemaId: $0.key,
                    responseSchemaVersionId: $0.versionId
                )]
            }
        )
    }

    private static func responseSchema(
        _ schema: [String: ExperienceReleaseJSONValue]?,
        captures: [[String: ExperienceReleaseJSONValue]]
    ) throws -> PinnedResponseSessionSchema? {
        guard let schema else { return nil }
        guard case .string(let key) = schema["key"],
              case .string(let versionId) = schema["responseSchemaVersionId"],
              case .number(let versionNumber) = schema["schemaVersion"],
              let version = UInt64(exactly: versionNumber),
              case .array(let fieldValues) = schema["fields"] else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        let fields = try fieldValues.map { value -> ResponseSessionField in
            guard case .object(let field) = value,
                  case .string(let key) = field["key"],
                  case .string(let rawType) = field["type"],
                  let type = ResponseSessionFieldType(rawValue: rawType),
                  case .bool(let required) = field["required"] else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            let options: [String]?
            if case .array(let values) = field["options"] {
                options = try values.map { value in
                    guard case .string(let option) = value else {
                        throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
                    }
                    return option
                }
            } else {
                options = nil
            }
            return ResponseSessionField(
                key: key,
                type: type,
                required: required,
                options: options,
                minimum: field["min"]?.numberValue,
                maximum: field["max"]?.numberValue
            )
        }
        var capturesByScreen: [String: Set<String>] = [:]
        for capture in captures {
            guard case .string(let screenId) = capture["screenId"],
                  case .array(let values) = capture["fields"] else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            capturesByScreen[screenId] = try Set(values.map { value in
                guard case .string(let field) = value else {
                    throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
                }
                return field
            })
        }
        return PinnedResponseSessionSchema(
            key: key,
            versionId: versionId,
            version: version,
            fields: fields,
            capturesByScreen: capturesByScreen
        )
    }

    private static func executionPlan(
        _ value: ExperienceReleaseJSONValue
    ) throws -> JourneyExecutionPlanV2 {
        guard case .object(let plan) = value,
              case .string(let id) = plan["id"],
              case .object(let route) = plan["route"],
              case .object(let host) = route["host"],
              case .string(let kind) = host["kind"],
              case .string(let eventName) = route["eventName"],
              case .string(let revision) = route["revisionSha256"],
              case .string(let rawPlane) = plan["startPlane"],
              let startPlane = JourneyPlane(rawValue: rawPlane),
              case .string(let entryRegionId) = plan["entryRegionId"],
              let entryCursor = try cursor(plan["entryCursor"]) else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        let routeHost: JourneyRouteHostV2
        switch kind {
        case "journey": routeHost = .journey
        case "screen":
            guard case .string(let screenId) = host["screenId"] else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            routeHost = .screen(screenId)
        default:
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        guard case .array(let deviceValues) = plan["deviceRegions"],
              case .array(let serverValues) = plan["serverRegions"],
              case .array(let edgeValues) = plan["handoffEdges"] else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        let deviceRegions = try deviceValues.map { try region($0, expectedPlane: .device) }
        let serverRegions = try serverValues.map { try region($0, expectedPlane: .server) }
        let edges = try edgeValues.map(edge)
        let regions = deviceRegions + serverRegions
        guard regions.contains(where: { $0.id == entryRegionId }),
              regions.first(where: { $0.id == entryRegionId })?.plane == startPlane,
              Set(regions.map(\.id)).count == regions.count,
              Set(edges.map(\.id)).count == edges.count,
              edges.allSatisfy({ edge in
                  guard let from = regions.first(where: { $0.id == edge.fromRegionId }),
                        let to = regions.first(where: { $0.id == edge.toRegionId }) else {
                      return false
                  }
                  guard (from.plane == .device && to.plane == .server && edge.direction == "device_to_server")
                      || (from.plane == .server && to.plane == .device && edge.direction == "server_to_device") else {
                      return false
                  }
                  let fallbackComplete = edge.deviceClaimTimeoutMs != nil
                      && edge.onDeviceUnavailableRegionId != nil
                      && edge.onDeviceUnavailableCursor != nil
                  guard !fallbackComplete || edge.direction == "server_to_device" else { return false }
                  if let fallbackRegionId = edge.onDeviceUnavailableRegionId {
                      guard let fallback = regions.first(where: { $0.id == fallbackRegionId }),
                            fallback.plane == .server else { return false }
                  }
                  return true
              }) else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        return JourneyExecutionPlanV2(
            id: id,
            route: JourneyRouteKeyV2(host: routeHost, eventName: eventName),
            revisionSHA256: revision,
            startPlane: startPlane,
            entryRegionId: entryRegionId,
            entryCursor: entryCursor,
            deviceRegions: deviceRegions,
            serverRegions: serverRegions,
            handoffEdges: edges
        )
    }

    private static func cursor(
        _ value: ExperienceReleaseJSONValue?
    ) throws -> JourneyExecutionCursorV2? {
        guard let value else { return nil }
        guard case .object(let cursor) = value,
              case .string(let path) = cursor["programPath"],
              case .number(let index) = cursor["actionIndex"],
              path.hasPrefix("/"),
              !path.contains("//"),
              index >= 0, index.rounded() == index,
              let actionIndex = Int(exactly: index) else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        return JourneyExecutionCursorV2(programPath: path, actionIndex: actionIndex)
    }

    private static func region(
        _ value: ExperienceReleaseJSONValue,
        expectedPlane: JourneyPlane
    ) throws -> JourneyExecutionRegionV2 {
        guard case .object(let region) = value,
              case .string(let id) = region["id"],
              case .string(let rawPlane) = region["plane"],
              let plane = JourneyPlane(rawValue: rawPlane),
              plane == expectedPlane,
              let entryCursor = try cursor(region["entryCursor"]),
              case .array(let pathValues) = region["actionPaths"] else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        let paths = try pathValues.map { value -> String in
            guard case .string(let path) = value,
                  path.hasPrefix("/"),
                  !path.contains("//") else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            return path
        }
        guard Set(paths).count == paths.count else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        return JourneyExecutionRegionV2(
            id: id,
            plane: plane,
            entryCursor: entryCursor,
            actionPaths: paths
        )
    }

    private static func edge(
        _ value: ExperienceReleaseJSONValue
    ) throws -> JourneyExecutionHandoffEdgeV2 {
        guard case .object(let edge) = value,
              case .string(let id) = edge["id"],
              case .string(let fromRegionId) = edge["fromRegionId"],
              let fromCursor = try cursor(edge["fromCursor"]),
              case .string(let toRegionId) = edge["toRegionId"],
              let toCursor = try cursor(edge["toCursor"]),
              case .string(let direction) = edge["direction"] else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        guard direction == "device_to_server" || direction == "server_to_device" else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        let timeout: Int?
        if case .number(let value) = edge["deviceClaimTimeoutMs"] {
            guard value > 0, value.rounded() == value, let parsed = Int(exactly: value) else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            timeout = parsed
        } else {
            timeout = nil
        }
        let fallbackRegion = edge["onDeviceUnavailableRegionId"]?.stringValue
        let fallbackCursor = try cursor(edge["onDeviceUnavailableCursor"])
        guard (timeout == nil && fallbackRegion == nil && fallbackCursor == nil)
                || (timeout != nil && fallbackRegion != nil && fallbackCursor != nil) else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        return JourneyExecutionHandoffEdgeV2(
            id: id,
            fromRegionId: fromRegionId,
            fromCursor: fromCursor,
            toRegionId: toRegionId,
            toCursor: toCursor,
            direction: direction,
            deviceClaimTimeoutMs: timeout,
            onDeviceUnavailableRegionId: fallbackRegion,
            onDeviceUnavailableCursor: fallbackCursor
        )
    }

    private static func controlActions(
        _ behaviors: [[String: ExperienceReleaseJSONValue]]
    ) throws -> [String: [String: ScreenControlActionDefinition]] {
        var result: [String: [String: ScreenControlActionDefinition]] = [:]
        for behavior in behaviors {
            guard case .string(let screenId) = behavior["screenId"],
                  case .array(let controls) = behavior["controls"] else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            var table: [String: ScreenControlActionDefinition] = [:]
            for value in controls {
                guard case .object(let control) = value,
                      case .string(let actionId) = control["actionId"],
                      case .object(let binding) = control["behavior"],
                      case .string(let kind) = binding["kind"] else {
                    throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
                }
                let compiled: ScreenControlActionBinding
                switch kind {
                case "script": compiled = .script
                case "declarative":
                    guard case .array(let actions) = binding["program"] else {
                        throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
                    }
                    compiled = .declarative(try actions.map(Self.declarativeAction))
                default:
                    throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
                }
                guard table[actionId] == nil else {
                    throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
                }
                table[actionId] = ScreenControlActionDefinition(
                    actionId: actionId,
                    binding: compiled
                )
            }
            result[screenId] = table
        }
        return result
    }

    private static func declarativeAction(
        _ value: ExperienceReleaseJSONValue
    ) throws -> DeclarativeScreenAction {
        guard case .object(let action) = value,
              case .string(let type) = action["type"] else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        switch type {
        case "emit":
            guard case .string(let eventName) = action["eventName"] else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            var payload: [String: DeclarativeScreenValueSource] = [:]
            if case .object(let values) = action["payload"] {
                for (key, value) in values {
                    payload[key] = try declarativeValueSource(value)
                }
            }
            return .emit(eventName: eventName, payload: payload)
        case "response_set":
            guard case .string(let field) = action["field"],
                  let value = action["value"] else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            return .responseSet(field: field, value: try declarativeValueSource(value))
        case "response_unset":
            guard case .string(let field) = action["field"] else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            return .responseUnset(field: field)
        default:
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
    }

    private static func declarativeValueSource(
        _ value: ExperienceReleaseJSONValue
    ) throws -> DeclarativeScreenValueSource {
        guard case .object(let source) = value,
              case .string(let kind) = source["source"] else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        switch kind {
        case "literal":
            guard let value = source["value"] else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            return .literal(value.screenEmissionValue)
        case "invocation_value": return .invocationValue
        case "component_id": return .componentId
        case "instance_id": return .instanceId
        default: throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
    }

}

private extension ExperienceReleaseJSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var screenEmissionValue: ScreenEmissionValue {
        switch self {
        case .null: .null
        case .bool(let value): .bool(value)
        case .number(let value): .number(value)
        case .string(let value): .string(value)
        case .array(let values): .array(values.map(\.screenEmissionValue))
        case .object(let values): .object(values.mapValues(\.screenEmissionValue))
        }
    }

    var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.foundationValue)
        case .object(let values): values.mapValues(\.foundationValue)
        }
    }
}
#endif
