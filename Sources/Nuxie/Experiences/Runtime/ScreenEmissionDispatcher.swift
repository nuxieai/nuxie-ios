#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation

indirect enum ScreenEmissionValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ScreenEmissionValue])
    case object([String: ScreenEmissionValue])

    init(rendererValue value: Any) {
        if value is NSNull { self = .null }
        else if let value = value as? Bool { self = .bool(value) }
        else if let value = value as? NSNumber { self = .number(value.doubleValue) }
        else if let value = value as? String { self = .string(value) }
        else if let value = value as? [Any] {
            self = .array(value.map(Self.init(rendererValue:)))
        } else if let value = value as? [String: Any] {
            self = .object(value.mapValues(Self.init(rendererValue:)))
        } else {
            self = .null
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([ScreenEmissionValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: ScreenEmissionValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

struct ScreenEmissionRun: Equatable, Sendable {
    let journeyId: String
    let executionOwnershipEpoch: UInt64
    let lifecycleGeneration: UInt64
    let presentationEpoch: UInt64
}

struct ScreenActionInvocation: Equatable, Sendable {
    let actionId: String
    let value: ScreenEmissionValue?
    let componentId: String?
    let instanceId: String?

    init(
        actionId: String,
        value: ScreenEmissionValue? = nil,
        componentId: String? = nil,
        instanceId: String? = nil
    ) {
        self.actionId = actionId
        self.value = value
        self.componentId = componentId
        self.instanceId = instanceId
    }
}

enum DeclarativeScreenValueSource: Equatable, Sendable {
    case literal(ScreenEmissionValue)
    case invocationValue
    case componentId
    case instanceId
}

enum DeclarativeScreenAction: Equatable, Sendable {
    case emit(
        eventName: String,
        payload: [String: DeclarativeScreenValueSource]
    )
    case responseSet(field: String, value: DeclarativeScreenValueSource)
    case responseUnset(field: String)
}

enum ScreenControlActionBinding: Equatable, Sendable {
    case declarative([DeclarativeScreenAction])
    case script
}

struct ScreenControlActionDefinition: Equatable, Sendable {
    let actionId: String
    let binding: ScreenControlActionBinding
}

enum ScreenEmissionDraft: Equatable, Sendable {
    case event(name: String, payload: [String: ScreenEmissionValue])
    case responseSet(field: String, value: ScreenEmissionValue)
    case responseUnset(field: String)
}

struct ScreenScriptActionInput: Equatable, Sendable {
    let screenId: String
    let actionId: String
    let invocation: ScreenActionInvocation
}

struct ScreenEmissionSource: Equatable, Sendable {
    let screenId: String
    let actionId: String
    let componentId: String?
    let instanceId: String?
}

struct ScreenEmission: Equatable, Sendable {
    let id: String
    let sequence: UInt64
    let occurredAt: String
    let name: String
    let payload: [String: ScreenEmissionValue]
}

struct ScreenEmissionBatch: Equatable, Sendable {
    let journeyId: String
    let executionOwnershipEpoch: UInt64
    let lifecycleGeneration: UInt64
    let presentationEpoch: UInt64
    let batchSequence: UInt64
    let previousCommittedBatchSequence: UInt64?
    let invocationId: String
    let source: ScreenEmissionSource
    let emissions: [ScreenEmission]
}

enum ScreenEmissionDispatchError: Error, Equatable, Sendable {
    case actionIdentityMismatch(expected: String, received: String)
    case declarativeSourceMissing(source: String)
    case invalidEventName(eventName: String)
    case reservedEventName(eventName: String)
    case scriptActionMissing(actionId: String)
    case scriptExecutionFailed(message: String)
}

final class ScreenEmissionDispatcher: Sendable {
    typealias ScriptExecutor = @Sendable (
        ScreenScriptActionInput
    ) async throws -> [ScreenEmissionDraft]

    private let gate = ExperienceInteractiveOperationGate()
    private let state: ScreenEmissionDispatcherState

    init(
        createId: @escaping @Sendable () -> String,
        now: @escaping @Sendable () -> String,
        executeScriptAction: @escaping ScriptExecutor
    ) {
        state = ScreenEmissionDispatcherState(
            createId: createId,
            now: now,
            executeScriptAction: executeScriptAction
        )
    }

    func dispatch(
        run: ScreenEmissionRun,
        screenId: String,
        definition: ScreenControlActionDefinition,
        invocation: ScreenActionInvocation
    ) async -> Result<ScreenEmissionBatch, ScreenEmissionDispatchError> {
        await gate.withLock { [state] in
            await state.dispatch(
                run: run,
                screenId: screenId,
                definition: definition,
                invocation: invocation
            )
        }
    }
}

private actor ScreenEmissionDispatcherState {
    private let createId: @Sendable () -> String
    private let now: @Sendable () -> String
    private let executeScriptAction: ScreenEmissionDispatcher.ScriptExecutor
    private var nextBatchSequence: [String: UInt64] = [:]
    private var nextEmissionSequence: [String: UInt64] = [:]
    private var lastCommittedBatchSequence: [String: UInt64] = [:]

    init(
        createId: @escaping @Sendable () -> String,
        now: @escaping @Sendable () -> String,
        executeScriptAction: @escaping ScreenEmissionDispatcher.ScriptExecutor
    ) {
        self.createId = createId
        self.now = now
        self.executeScriptAction = executeScriptAction
    }

    func dispatch(
        run: ScreenEmissionRun,
        screenId: String,
        definition: ScreenControlActionDefinition,
        invocation: ScreenActionInvocation
    ) async -> Result<ScreenEmissionBatch, ScreenEmissionDispatchError> {
        let batchSequence = nextBatchSequence[run.journeyId, default: 0]
        nextBatchSequence[run.journeyId] = batchSequence + 1
        let invocationId = createId()

        guard definition.actionId == invocation.actionId else {
            return .failure(.actionIdentityMismatch(
                expected: definition.actionId,
                received: invocation.actionId
            ))
        }

        let drafts: [ScreenEmissionDraft]
        do {
            switch definition.binding {
            case .declarative(let actions):
                drafts = try executeDeclarative(actions, invocation: invocation)
            case .script:
                drafts = try await executeScriptAction(ScreenScriptActionInput(
                    screenId: screenId,
                    actionId: definition.actionId,
                    invocation: invocation
                ))
            }
            try validate(drafts)
        } catch let error as ScreenEmissionDispatchError {
            return .failure(error)
        } catch {
            return .failure(.scriptExecutionFailed(message: String(describing: error)))
        }

        let firstSequence = nextEmissionSequence[run.journeyId, default: 0]
        let emissions = drafts.enumerated().map { offset, draft in
            materialize(
                draft,
                sequence: firstSequence + UInt64(offset)
            )
        }
        let batch = ScreenEmissionBatch(
            journeyId: run.journeyId,
            executionOwnershipEpoch: run.executionOwnershipEpoch,
            lifecycleGeneration: run.lifecycleGeneration,
            presentationEpoch: run.presentationEpoch,
            batchSequence: batchSequence,
            previousCommittedBatchSequence: lastCommittedBatchSequence[run.journeyId],
            invocationId: invocationId,
            source: ScreenEmissionSource(
                screenId: screenId,
                actionId: definition.actionId,
                componentId: invocation.componentId,
                instanceId: invocation.instanceId
            ),
            emissions: emissions
        )
        nextEmissionSequence[run.journeyId] = firstSequence + UInt64(emissions.count)
        lastCommittedBatchSequence[run.journeyId] = batchSequence
        return .success(batch)
    }

    private func executeDeclarative(
        _ actions: [DeclarativeScreenAction],
        invocation: ScreenActionInvocation
    ) throws -> [ScreenEmissionDraft] {
        try actions.map { action in
            switch action {
            case .emit(let eventName, let payload):
                return .event(
                    name: eventName,
                    payload: try payload.mapValues {
                        try resolve($0, invocation: invocation)
                    }
                )
            case .responseSet(let field, let source):
                return .responseSet(
                    field: field,
                    value: try resolve(source, invocation: invocation)
                )
            case .responseUnset(let field):
                return .responseUnset(field: field)
            }
        }
    }

    private func resolve(
        _ source: DeclarativeScreenValueSource,
        invocation: ScreenActionInvocation
    ) throws -> ScreenEmissionValue {
        switch source {
        case .literal(let value): return value
        case .invocationValue:
            guard let value = invocation.value else {
                throw ScreenEmissionDispatchError.declarativeSourceMissing(
                    source: "invocation_value"
                )
            }
            return value
        case .componentId:
            guard let value = invocation.componentId, !value.isEmpty else {
                throw ScreenEmissionDispatchError.declarativeSourceMissing(
                    source: "component_id"
                )
            }
            return .string(value)
        case .instanceId:
            guard let value = invocation.instanceId, !value.isEmpty else {
                throw ScreenEmissionDispatchError.declarativeSourceMissing(
                    source: "instance_id"
                )
            }
            return .string(value)
        }
    }

    private func validate(_ drafts: [ScreenEmissionDraft]) throws {
        for draft in drafts {
            if case .event(let name, _) = draft {
                if name.isEmpty {
                    throw ScreenEmissionDispatchError.invalidEventName(eventName: name)
                }
                if name.hasPrefix("$") {
                    throw ScreenEmissionDispatchError.reservedEventName(eventName: name)
                }
            }
        }
    }

    private func materialize(
        _ draft: ScreenEmissionDraft,
        sequence: UInt64
    ) -> ScreenEmission {
        let name: String
        let payload: [String: ScreenEmissionValue]
        switch draft {
        case .event(let eventName, let eventPayload):
            name = eventName
            payload = eventPayload
        case .responseSet(let field, let value):
            name = SystemEventNames.responseSet
            payload = ["field": .string(field), "value": value]
        case .responseUnset(let field):
            name = SystemEventNames.responseUnset
            payload = ["field": .string(field)]
        }
        return ScreenEmission(
            id: createId(),
            sequence: sequence,
            occurredAt: now(),
            name: name,
            payload: payload
        )
    }
}
#endif
