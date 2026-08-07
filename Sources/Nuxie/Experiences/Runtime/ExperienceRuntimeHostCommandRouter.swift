import NuxieRuntime

enum ExperienceRuntimeHostCommandRouterError: Error, Equatable {
    case nonObjectPayload(name: String)
}

struct ExperienceRuntimeHostCommandMetadata: Equatable, Sendable {
    let sequence: UInt64
    let cycle: UInt64
    let phase: ExperienceRuntimeOutputPhase
}

/// Renderer-neutral event produced by a Nuxie Luau host command.
///
/// The output envelope remains attached for tracing and FIFO verification.
/// Payload metadata follows the aliases supported by the legacy bridge while
/// the full typed object remains intact for journey routing.
struct ExperienceRuntimeHostEvent: Equatable, Sendable {
    let metadata: ExperienceRuntimeHostCommandMetadata
    let name: String
    let properties: ExperienceRuntimeHostObject
    let screenID: String
    let componentID: String?
    let instanceID: String?
}

/// Queues completed native outputs without invoking host code reentrantly.
/// Creation-time and operation-time commands share the same FIFO.
struct ExperienceRuntimeHostCommandRouter: Sendable {
    private struct Pending: Sendable {
        let metadata: ExperienceRuntimeHostCommandMetadata
        let name: String
        let properties: ExperienceRuntimeHostObject
    }

    private var pending: [Pending] = []

    /// Enqueues one already ordered result batch transactionally. A malformed
    /// fake or substituted adapter cannot leak the valid prefix of a batch.
    mutating func enqueue(_ outputs: [ExperienceRuntimeOutput]) throws {
        var staged: [Pending] = []
        staged.reserveCapacity(outputs.count)
        for output in outputs {
            guard case .hostCommand(let name, let payload) = output.payload else {
                continue
            }
            guard case .object(let properties) = payload else {
                throw ExperienceRuntimeHostCommandRouterError.nonObjectPayload(name: name)
            }
            staged.append(Pending(
                metadata: ExperienceRuntimeHostCommandMetadata(
                    sequence: output.sequence,
                    cycle: output.cycle,
                    phase: output.phase
                ),
                name: name,
                properties: properties
            ))
        }
        pending.append(contentsOf: staged)
    }

    mutating func enqueue(_ result: ExperienceRuntimeOperationResult) throws {
        try enqueue(result.orderedOutputs)
    }

    mutating func drain(currentScreenID: String) -> [ExperienceRuntimeHostEvent] {
        let drained = pending
        pending.removeAll(keepingCapacity: true)
        return drained.map { command in
            ExperienceRuntimeHostEvent(
                metadata: command.metadata,
                name: command.name,
                properties: command.properties,
                screenID: stringProperty(
                    ["screenId", "screen_id"],
                    in: command.properties
                ) ?? currentScreenID,
                componentID: stringProperty(
                    ["componentId", "component_id", "elementId", "element_id"],
                    in: command.properties
                ),
                instanceID: stringProperty(
                    ["instanceId", "instance_id"],
                    in: command.properties
                )
            )
        }
    }

    private func stringProperty(
        _ names: [String],
        in object: ExperienceRuntimeHostObject
    ) -> String? {
        for name in names {
            guard case .string(let value) = object[name], !value.isEmpty else {
                continue
            }
            return value
        }
        return nil
    }
}
