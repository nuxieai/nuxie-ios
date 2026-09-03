#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation

/// Renderer-owned projection of one authenticated Journey.
///
/// Journey traversal, routes, waits, and outcomes belong to JourneyService.
/// The renderer receives only screens, view-model defaults, and declarative
/// screen controls.
struct ExperienceDefinition: Sendable {
    let screens: [JourneyScreen]
    let viewModelValues: [JourneyViewModelValue]
    let controlsByScreen: [String: [String: ScreenControlActionDefinition]]
    let declaredEventNamesByScreen: [String: Set<String>]
    let appDefaultTimezone: String?

    init(
        screens: [JourneyScreen],
        viewModelValues: [JourneyViewModelValue],
        controlsByScreen: [String: [String: ScreenControlActionDefinition]],
        declaredEventNamesByScreen: [String: Set<String>] = [:],
        appDefaultTimezone: String? = nil
    ) {
        self.screens = screens
        self.viewModelValues = viewModelValues
        self.controlsByScreen = controlsByScreen
        self.declaredEventNamesByScreen = declaredEventNamesByScreen
        self.appDefaultTimezone = appDefaultTimezone
    }

    init(journeyDescriptor descriptor: JourneyReleaseDescriptor) throws {
        screens = descriptor.leg.screens.map {
            JourneyScreen(
                id: $0.id,
                defaultViewModelName: $0.defaultViewModelName,
                defaultInstanceId: $0.defaultInstanceId
            )
        }
        viewModelValues = try descriptor.viewModelValues.map { entry in
            guard case .string(let viewModelName) = entry["viewModelName"],
                  case .string(let path) = entry["path"],
                  let value = entry["value"] else {
                throw JourneyReleaseAuthenticationError.invalidDescriptor
            }
            return JourneyViewModelValue(
                viewModelName: viewModelName,
                instanceId: entry["instanceId"]?.stringValue,
                instanceName: entry["instanceName"]?.stringValue,
                path: path,
                value: AnyCodable(value.foundationValue)
            )
        }
        controlsByScreen = try Self.controlActions(descriptor.screenBehaviors)
        var declaredEvents: [String: Set<String>] = [:]
        for route in descriptor.leg.routes where route.host.kind == .screen {
            guard let screenId = route.host.screenId else {
                throw JourneyReleaseAuthenticationError.invalidDescriptor
            }
            declaredEvents[screenId, default: []].insert(route.eventName)
        }
        declaredEventNamesByScreen = declaredEvents
        if case .string(let identifier) = descriptor.metadata["appDefaultTimezone"] {
            appDefaultTimezone = identifier
        } else {
            appDefaultTimezone = nil
        }
    }

    func control(
        screenId: String,
        actionId: String
    ) -> ScreenControlActionDefinition? {
        controlsByScreen[screenId]?[actionId]
    }

    var renderShell: JourneyDocument {
        JourneyDocument(
            schemaVersion: 1,
            screens: screens,
            viewModelValues: viewModelValues,
            responseSchemas: []
        )
    }

    private static func controlActions(
        _ behaviors: [[String: JourneyReleaseJSONValue]]
    ) throws -> [String: [String: ScreenControlActionDefinition]] {
        var result: [String: [String: ScreenControlActionDefinition]] = [:]
        for behavior in behaviors {
            guard case .string(let screenId) = behavior["screenId"],
                  case .array(let controls) = behavior["controls"] else {
                throw JourneyReleaseAuthenticationError.invalidDescriptor
            }
            var table: [String: ScreenControlActionDefinition] = [:]
            for value in controls {
                guard case .object(let control) = value,
                      case .string(let actionId) = control["actionId"],
                      case .object(let binding) = control["behavior"],
                      case .string(let kind) = binding["kind"],
                      kind == "declarative",
                      case .array(let actions) = binding["program"],
                      table[actionId] == nil else {
                    throw JourneyReleaseAuthenticationError.invalidDescriptor
                }
                table[actionId] = ScreenControlActionDefinition(
                    actionId: actionId,
                    binding: .declarative(try actions.map(declarativeAction))
                )
            }
            guard result[screenId] == nil else {
                throw JourneyReleaseAuthenticationError.invalidDescriptor
            }
            result[screenId] = table
        }
        return result
    }

    private static func declarativeAction(
        _ value: JourneyReleaseJSONValue
    ) throws -> DeclarativeScreenAction {
        guard case .object(let action) = value,
              case .string(let type) = action["type"] else {
            throw JourneyReleaseAuthenticationError.invalidDescriptor
        }
        switch type {
        case "emit":
            guard case .string(let eventName) = action["eventName"] else {
                throw JourneyReleaseAuthenticationError.invalidDescriptor
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
                throw JourneyReleaseAuthenticationError.invalidDescriptor
            }
            return .responseSet(
                field: field,
                value: try declarativeValueSource(value)
            )
        case "response_unset":
            guard case .string(let field) = action["field"] else {
                throw JourneyReleaseAuthenticationError.invalidDescriptor
            }
            return .responseUnset(field: field)
        default:
            throw JourneyReleaseAuthenticationError.invalidDescriptor
        }
    }

    private static func declarativeValueSource(
        _ value: JourneyReleaseJSONValue
    ) throws -> DeclarativeScreenValueSource {
        guard case .object(let source) = value,
              case .string(let kind) = source["source"] else {
            throw JourneyReleaseAuthenticationError.invalidDescriptor
        }
        switch kind {
        case "literal":
            guard let value = source["value"] else {
                throw JourneyReleaseAuthenticationError.invalidDescriptor
            }
            return .literal(value.screenEmissionValue)
        case "invocation_value":
            return .invocationValue
        case "component_id":
            return .componentId
        case "instance_id":
            return .instanceId
        default:
            throw JourneyReleaseAuthenticationError.invalidDescriptor
        }
    }
}

private extension JourneyReleaseJSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var screenEmissionValue: ScreenEmissionValue {
        switch self {
        case .null: .null
        case .bool(let value): .bool(value)
        case .number(let value): .number(value)
        case .string(let value): .string(value)
        case .array(let values): .array(values.map(\.screenEmissionValue))
        case .object(let values):
            .object(values.mapValues(\.screenEmissionValue).dictionary)
        }
    }

    var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.foundationValue)
        case .object(let values):
            values.mapValues(\.foundationValue).dictionary
        }
    }
}
#endif
