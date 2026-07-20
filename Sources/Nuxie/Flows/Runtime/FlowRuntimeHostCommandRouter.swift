enum FlowRuntimeHostCommandRouterError: Error, Equatable {
    case nonObjectPayload(name: String)
}

struct FlowRuntimeHostCommandMetadata: Equatable, Sendable {
    let sequence: UInt64
    let cycle: UInt64
    let phase: FlowRuntimeOutputPhase
}

/// Renderer-neutral event produced by a Nuxie Luau host command.
///
/// The output envelope remains attached for tracing and FIFO verification.
/// Payload metadata follows the aliases supported by the legacy bridge while
/// the full typed object remains intact for journey routing.
struct FlowRuntimeHostEvent: Equatable, Sendable {
    let metadata: FlowRuntimeHostCommandMetadata
    let name: String
    let properties: FlowRuntimeHostObject
    let screenID: String
    let componentID: String?
    let instanceID: String?
}

/// Queues completed native outputs without invoking host code reentrantly.
/// Creation-time and operation-time commands share the same FIFO.
struct FlowRuntimeHostCommandRouter: Sendable {
    private struct Pending: Sendable {
        let metadata: FlowRuntimeHostCommandMetadata
        let name: String
        let properties: FlowRuntimeHostObject
    }

    private var pending: [Pending] = []

    /// Enqueues one already ordered result batch transactionally. A malformed
    /// fake or substituted adapter cannot leak the valid prefix of a batch.
    mutating func enqueue(_ outputs: [FlowRuntimeOutput]) throws {
        var staged: [Pending] = []
        staged.reserveCapacity(outputs.count)
        for output in outputs {
            guard case .hostCommand(let name, let payload) = output.payload else {
                continue
            }
            guard case .object(let properties) = payload else {
                throw FlowRuntimeHostCommandRouterError.nonObjectPayload(name: name)
            }
            staged.append(Pending(
                metadata: FlowRuntimeHostCommandMetadata(
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

    mutating func enqueue(_ result: FlowRuntimeOperationResult) throws {
        try enqueue(result.orderedOutputs)
    }

    mutating func drain(currentScreenID: String) -> [FlowRuntimeHostEvent] {
        let drained = pending
        pending.removeAll(keepingCapacity: true)
        return drained.map { command in
            FlowRuntimeHostEvent(
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
        in object: FlowRuntimeHostObject
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
