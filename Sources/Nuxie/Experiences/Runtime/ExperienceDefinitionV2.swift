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
    let executionPlans: [[String: ExperienceReleaseJSONValue]]
    let responseSchema: PinnedResponseSessionSchema?
    let controlsByScreen: [String: [String: ScreenControlActionDefinition]]
    let appDefaultTimezone: TimeZone?

    init(
        entryRouteEventName: String,
        screens: [JourneyScreenV2],
        viewModelValues: [JourneyViewModelValue],
        routes: [JourneyRouteKeyV2: JourneyRouteV2],
        executionPlans: [[String: ExperienceReleaseJSONValue]],
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
        executionPlans = try planValues.map { value in
            guard case .object(let plan) = value else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            return plan
        }
        responseSchema = try Self.responseSchema(
            descriptor.responseSchema,
            captures: descriptor.responseCaptures
        )
        controlsByScreen = try Self.controlActions(descriptor.screenBehaviors)
    }

    func route(host: JourneyRouteHostV2, eventName: String) -> JourneyRouteV2? {
        routes[JourneyRouteKeyV2(host: host, eventName: eventName)]
    }

    func control(screenId: String, actionId: String) -> ScreenControlActionDefinition? {
        controlsByScreen[screenId]?[actionId]
    }

    func compiledProgram(for route: JourneyRouteV2) throws -> [JourneyAction] {
        // Route programs are already the signed canonical JourneyAction union.
        // Decode them directly; response schema identity is owned by the
        // pinned Response Session and is never authored on submit_response.
        let bytes = try JSONSerialization.data(withJSONObject: route.program.map(\.foundationValue))
        return try JSONDecoder().decode([JourneyAction].self, from: bytes)
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
