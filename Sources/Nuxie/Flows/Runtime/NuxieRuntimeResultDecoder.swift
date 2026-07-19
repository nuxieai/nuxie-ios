#if canImport(NuxieRuntime)
import Foundation
import NuxieRuntime

/// Swift names for the fixed-width status values in the C ABI.
enum NuxieRuntimeStatus: Equatable, Sendable {
    case ok
    case nullArgument
    case importError
    case notFound
    case runtimeError
    case invalidArgument
    case abiMismatch
    case surfaceError
    case unknown(UInt32)
}

extension NuxieRuntimeAdapterError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .incompatibleABI(let requiredMajor, let minimumMinor, let actualMajor, let actualMinor):
            "NuxieRuntime ABI \(actualMajor).\(actualMinor) does not satisfy \(requiredMajor).\(minimumMinor)"
        case .callFailed(let status, let diagnostic):
            "NuxieRuntime call failed (\(status)): \(diagnostic.code): \(diagnostic.message)"
        case .missingHandle(let name):
            "NuxieRuntime omitted its \(name) handle"
        case .missingOperationResult:
            "NuxieRuntime omitted its operation result"
        case .invalidNativeResult(let message):
            "NuxieRuntime returned an invalid result: \(message)"
        case .invalidFrameTimestamp(let value):
            "NuxieRuntime frame timestamp is invalid: \(value)"
        case .invalidFrameDelta(let value):
            "NuxieRuntime frame delta is invalid: \(value)"
        }
    }
}

func copyNuxieRuntimeResult(
    callStatus: UInt32,
    result: inout OpaquePointer?,
    renderRequested: Bool
) throws -> FlowRuntimeOperationResult {
    try copyNuxieRuntimeResultSnapshot(
        callStatus: callStatus,
        result: &result,
        renderRequested: renderRequested
    ).operationResult
}

struct NuxieRuntimeResultSnapshot {
    let operationResult: FlowRuntimeOperationResult
    let scriptAuthorization: FlowRuntimeScriptAuthorization?
}

/// Copies every ABI 1.2 result-owned view before releasing the native handle.
///
/// The result pointer is consumed even when decoding fails. Nothing in the
/// returned Swift value borrows Rust-owned storage.
func copyNuxieFlowSessionResult(
    callStatus: UInt32,
    result: inout OpaquePointer?,
    renderRequested: Bool
) throws -> FlowRuntimeOperationResult {
    guard let ownedResult = result else {
        if callStatus != NUX_STATUS_OK {
            throw NuxieRuntimeAdapterError.callFailed(
                status: nuxieRuntimeStatus(callStatus),
                diagnostic: nuxieRuntimeDiagnostic(
                    status: callStatus,
                    message: "native runtime returned no session diagnostic result"
                )
            )
        }
        throw NuxieRuntimeAdapterError.missingOperationResult
    }
    result = nil
    defer { nux_flow_session_result_free(ownedResult) }

    var budget = NuxieFlowSessionCopyBudget()
    let diagnostics = try copyNuxieFlowSessionDiagnostics(
        from: ownedResult,
        budget: &budget
    )
    let resultStatus = nux_flow_session_result_status(ownedResult)
    guard callStatus == resultStatus else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native session call status \(callStatus) disagrees with result status \(resultStatus)"
        )
    }
    if resultStatus != NUX_STATUS_OK {
        throw NuxieRuntimeAdapterError.callFailed(
            status: nuxieRuntimeStatus(resultStatus),
            diagnostic: diagnostics.first
                ?? nuxieRuntimeDiagnostic(
                    status: resultStatus,
                    message: "native runtime session operation failed"
                )
        )
    }

    let disposition = try copyNuxieFlowSurfaceDisposition(
        nux_flow_session_result_surface_disposition(ownedResult)
    )
    let wakeAfter = try copyNuxieFlowWakeAfter(from: ownedResult)
    let arena = try copyNuxieFlowValueArena(
        from: ownedResult,
        budget: &budget
    )
    let catalog = try copyNuxieFlowCatalog(
        from: ownedResult,
        arena: arena,
        budget: &budget
    )
    let metadata = try copyNuxieFlowPlayerMetadata(
        from: ownedResult,
        budget: &budget
    )
    let playerInputs = try copyNuxieFlowPlayerInputs(
        from: ownedResult,
        arena: arena,
        budget: &budget
    )
    let outputs = try copyNuxieFlowOutputs(
        from: ownedResult,
        arena: arena,
        budget: &budget
    )
    let createdInstances = try copyNuxieFlowCreatedInstances(from: ownedResult)

    // ABI 1.2 exposes independent presence so a present-empty query response
    // is not conflated with a field that was not requested.
    let hasValues = nux_flow_session_result_has_values(ownedResult)
    let hasCatalog = nux_flow_session_result_has_catalog(ownedResult)
    let hasPlayerInputs = nux_flow_session_result_has_player_inputs(ownedResult)
    try validateNuxieFlowCatalogShape(catalog, isPresent: hasCatalog)
    // A values snapshot may be absent while the shared arena still owns typed
    // output payload nodes. Presence therefore constrains roots at correlation
    // time, not the arena's raw node count.
    if metadata != nil, (!hasValues || !hasCatalog) {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native bootstrap metadata omitted its catalog or value snapshot"
        )
    }
    if !hasPlayerInputs, !playerInputs.isEmpty {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native result returned player inputs without marking them present"
        )
    }
    if hasValues, hasCatalog {
        try validateNuxieFlowCatalogValueBindings(catalog: catalog, arena: arena)
    }

    let renderOutcome: FlowRuntimeRenderOutcome
    if !renderRequested {
        renderOutcome = .notRequested
    } else if disposition == .presented {
        renderOutcome = .presented
    } else {
        renderOutcome = .skipped
    }

    return FlowRuntimeOperationResult(
        renderOutcome: renderOutcome,
        surfaceDisposition: disposition,
        isDirty: nux_flow_session_result_is_dirty(ownedResult),
        isSettled: nux_flow_session_result_is_settled(ownedResult),
        wakeAfter: wakeAfter,
        orderedOutputs: outputs,
        diagnostics: diagnostics,
        bootstrap: metadata.map {
            FlowRuntimeBootstrap(player: $0, catalog: catalog, values: arena)
        },
        values: hasValues ? arena : nil,
        catalog: hasCatalog ? catalog : nil,
        playerInputs: hasPlayerInputs ? playerInputs : nil,
        createdInstances: createdInstances
    )
}

private struct NuxieFlowSessionCopyBudget {
    private(set) var bytes = 0

    mutating func copyData(
        _ view: NuxByteView,
        maximum: Int,
        label: String
    ) throws -> Data {
        let count = try nuxieFlowBoundedCount(view.len, maximum: maximum, label: label)
        guard count == 0 || view.data != nil else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime returned a null \(label) with nonzero length"
            )
        }
        let (nextBytes, overflowed) = bytes.addingReportingOverflow(count)
        guard !overflowed,
              nextBytes <= FlowRuntimeSessionLimits.encodedPayloadBytes else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native session result exceeds the aggregate 4 MiB payload limit"
            )
        }
        bytes = nextBytes
        guard count > 0, let data = view.data else { return Data() }
        return Data(bytes: data, count: count)
    }

    mutating func copyString(
        _ view: NuxByteView,
        maximum: Int,
        label: String
    ) throws -> String {
        let data = try copyData(view, maximum: maximum, label: label)
        guard let value = String(data: data, encoding: .utf8) else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime returned non-UTF-8 \(label)"
            )
        }
        return value
    }

    mutating func copyRequiredIdentifier(
        _ view: NuxByteView,
        label: String
    ) throws -> String {
        let value = try copyString(
            view,
            maximum: FlowRuntimeSessionLimits.identifierBytes,
            label: label
        )
        guard !value.isEmpty else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime returned an empty \(label)"
            )
        }
        return value
    }

    mutating func copyOptionalIdentifier(
        _ view: NuxByteView,
        label: String
    ) throws -> String? {
        let value = try copyString(
            view,
            maximum: FlowRuntimeSessionLimits.identifierBytes,
            label: label
        )
        return value.isEmpty ? nil : value
    }
}

private func nuxieFlowBoundedCount(
    _ count: UInt64,
    maximum: Int,
    label: String
) throws -> Int {
    guard count <= UInt64(maximum), count <= UInt64(Int.max) else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned too many \(label)"
        )
    }
    return Int(count)
}

private func nuxieFlowCheckedRange(
    start: UInt32,
    count: UInt32,
    upperBound: Int,
    label: String
) throws -> Range<Int> {
    let start = Int(start)
    let count = Int(count)
    let (end, overflowed) = start.addingReportingOverflow(count)
    guard !overflowed, end <= upperBound else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned an out-of-range \(label)"
        )
    }
    return start..<end
}

private func nuxieFlowPresence(
    _ flag: UInt32,
    label: String
) throws -> Bool {
    switch flag {
    case 0: false
    case 1: true
    default:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned noncanonical \(label) presence \(flag)"
        )
    }
}

private func nuxieFlowInstanceID(
    _ value: UInt64,
    label: String
) throws -> FlowRuntimeInstanceID {
    guard let identifier = FlowRuntimeInstanceID(rawValue: value) else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned reserved zero for \(label)"
        )
    }
    return identifier
}

private func copyNuxieFlowSurfaceDisposition(
    _ rawValue: UInt32
) throws -> FlowRuntimeSurfaceDisposition {
    let disposition = nuxieRuntimeSurfaceDisposition(rawValue)
    if case .unknown = disposition {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned unknown surface disposition \(rawValue)"
        )
    }
    return disposition
}

private func copyNuxieFlowWakeAfter(
    from result: OpaquePointer
) throws -> TimeInterval? {
    var seconds = 0.0
    switch nux_flow_session_result_wake_after_seconds(result, &seconds) {
    case NUX_STATUS_OK:
        guard seconds.isFinite, seconds >= 0 else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime returned an invalid wake deadline"
            )
        }
        return seconds
    case NUX_STATUS_NOT_FOUND:
        return nil
    case let status:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime wake deadline accessor failed with status \(status)"
        )
    }
}

private func copyNuxieFlowValueArena(
    from result: OpaquePointer,
    budget: inout NuxieFlowSessionCopyBudget
) throws -> FlowRuntimeValueArena {
    let nodeCount = try nuxieFlowBoundedCount(
        nux_flow_session_result_value_node_count(result),
        maximum: FlowRuntimeSessionLimits.valueNodes,
        label: "value nodes"
    )
    let edgeCount = try nuxieFlowBoundedCount(
        nux_flow_session_result_value_edge_count(result),
        maximum: FlowRuntimeSessionLimits.valueEdges,
        label: "value edges"
    )
    var edges: [FlowRuntimeValueEdge] = []
    edges.reserveCapacity(edgeCount)
    for index in 0..<edgeCount {
        var edge = NuxFlowValueEdge(
            struct_size: UInt32(MemoryLayout<NuxFlowValueEdge>.size),
            node_index: 0,
            key: NuxByteView(data: nil, len: 0)
        )
        guard nux_flow_session_result_value_edge_at(result, UInt64(index), &edge)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime value edge \(index) could not be read"
            )
        }
        guard Int(edge.node_index) < nodeCount else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime value edge \(index) references a missing node"
            )
        }
        let key = try budget.copyString(
            edge.key,
            maximum: FlowRuntimeSessionLimits.pathBytes,
            label: "value edge key"
        )
        edges.append(FlowRuntimeValueEdge(
            key: key.isEmpty ? nil : key,
            nodeIndex: Int(edge.node_index)
        ))
    }

    var nodes: [FlowRuntimeValueNode] = []
    nodes.reserveCapacity(nodeCount)
    for index in 0..<nodeCount {
        var node = NuxFlowValueNode(
            struct_size: UInt32(MemoryLayout<NuxFlowValueNode>.size),
            kind: UInt32(NUX_FLOW_VALUE_KIND_NULL),
            number_value: 0,
            color_value: 0,
            bool_value: 0,
            first_edge: 0,
            edge_count: 0,
            has_instance_id: 0,
            instance_id: 0,
            identity_value: 0,
            string_value: NuxByteView(data: nil, len: 0),
            schema_id: NuxByteView(data: nil, len: 0)
        )
        guard nux_flow_session_result_value_node_at(result, UInt64(index), &node)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime value node \(index) could not be read"
            )
        }
        nodes.append(try copyNuxieFlowValueNode(
            node,
            flatEdges: edges,
            index: index,
            budget: &budget
        ))
    }

    let rootCount = try nuxieFlowBoundedCount(
        nux_flow_session_result_value_root_count(result),
        maximum: FlowRuntimeSessionLimits.instances,
        label: "value roots"
    )
    var roots: [FlowRuntimeValueRoot] = []
    roots.reserveCapacity(rootCount)
    for index in 0..<rootCount {
        var root = NuxFlowValueRootView(
            struct_size: UInt32(MemoryLayout<NuxFlowValueRootView>.size),
            value_root_index: 0,
            instance_id: 0
        )
        guard nux_flow_session_result_value_root_at(result, UInt64(index), &root)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime value root \(index) could not be read"
            )
        }
        guard Int(root.value_root_index) < nodeCount else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime value root \(index) references a missing node"
            )
        }
        roots.append(FlowRuntimeValueRoot(
            instanceID: try nuxieFlowInstanceID(root.instance_id, label: "value root instance"),
            nodeIndex: Int(root.value_root_index)
        ))
    }

    let arena = FlowRuntimeValueArena(nodes: nodes, roots: roots)
    do {
        try arena.validate()
        try validateNuxieFlowEntireGraph(arena)
        try validateNuxieFlowValueRootBindings(arena)
    } catch {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned an invalid value arena: \(error.localizedDescription)"
        )
    }
    return arena
}

private func validateNuxieFlowValueRootBindings(
    _ arena: FlowRuntimeValueArena
) throws {
    for root in arena.roots {
        guard case .viewModel(_, let nodeInstanceID, _) = arena.nodes[root.nodeIndex].value,
              nodeInstanceID == root.instanceID else {
            throw FlowRuntimeSessionValueError.invalidGraph(
                "Runtime value root does not identify its view-model node"
            )
        }
    }
}

private func validateNuxieFlowCatalogValueBindings(
    catalog: FlowRuntimeCatalog,
    arena: FlowRuntimeValueArena
) throws {
    let rootsByInstance = Dictionary(
        uniqueKeysWithValues: arena.roots.map { ($0.instanceID, $0.nodeIndex) }
    )
    for instance in catalog.instances {
        guard instance.valueRootIndex == rootsByInstance[instance.id] else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native catalog instance \(instance.id.rawValue) disagrees with its value root"
            )
        }
        if let nodeIndex = instance.valueRootIndex {
            guard case .viewModel(let schemaID, let instanceID, _) = arena.nodes[nodeIndex].value,
                  schemaID == instance.schemaID,
                  instanceID == instance.id else {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native catalog instance \(instance.id.rawValue) disagrees with its value-root schema"
                )
            }
        }
    }
    let catalogIDs = Set(catalog.instances.map(\.id))
    guard Set(arena.roots.map(\.instanceID)).isSubset(of: catalogIDs) else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native value roots include an instance missing from the catalog"
        )
    }
}

/// Validates relationships that are otherwise lost when the ABI's flattened
/// catalog records become nested Swift values.
func validateNuxieFlowCatalogShape(
    _ catalog: FlowRuntimeCatalog,
    isPresent: Bool
) throws {
    if !isPresent {
        guard catalog.schemas.isEmpty,
              catalog.templates.isEmpty,
              catalog.instances.isEmpty else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native result returned catalog data without marking it present"
            )
        }
        return
    }

    var schemaIDs = Set<String>()
    for schema in catalog.schemas {
        guard schemaIDs.insert(schema.id).inserted else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native catalog returned duplicate schema ID \(schema.id)"
            )
        }
        // Property identity is scoped by schema in the ABI. The runtime's
        // canonical property ID is currently the authored property name, so
        // distinct schemas may intentionally reuse it.
        var propertyIDs = Set<String>()
        for property in schema.properties {
            guard property.schemaID == schema.id else {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native catalog property \(property.propertyID) references a missing schema"
                )
            }
            guard propertyIDs.insert(property.propertyID).inserted else {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native catalog returned duplicate property ID \(property.propertyID)"
                )
            }
        }
    }

    for template in catalog.templates where !schemaIDs.contains(template.schemaID) {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native catalog template references missing schema \(template.schemaID)"
        )
    }

    var rootCount = 0
    for instance in catalog.instances {
        guard schemaIDs.contains(instance.schemaID) else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native catalog instance \(instance.id.rawValue) references missing schema \(instance.schemaID)"
            )
        }
        if instance.isRoot {
            rootCount += 1
            guard rootCount == 1 else {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native catalog returned more than one root instance"
                )
            }
        }
    }
}

private func copyNuxieFlowValueNode(
    _ node: NuxFlowValueNode,
    flatEdges: [FlowRuntimeValueEdge],
    index: Int,
    budget: inout NuxieFlowSessionCopyBudget
) throws -> FlowRuntimeValueNode {
    let edgeRange = try nuxieFlowCheckedRange(
        start: node.first_edge,
        count: node.edge_count,
        upperBound: flatEdges.count,
        label: "edge range for value node \(index)"
    )
    guard node.edge_count > 0 || node.first_edge == 0 else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime value node \(index) has a noncanonical empty edge range"
        )
    }
    let stringValue = try budget.copyString(
        node.string_value,
        maximum: FlowRuntimeSessionLimits.stringBytes,
        label: "value node string"
    )
    let schemaID = try budget.copyOptionalIdentifier(
        node.schema_id,
        label: "value node schema ID"
    )
    let hasInstanceID = try nuxieFlowPresence(
        node.has_instance_id,
        label: "value node instance ID"
    )
    let instanceID: FlowRuntimeInstanceID?
    if hasInstanceID {
        instanceID = try nuxieFlowInstanceID(node.instance_id, label: "value node instance")
    } else {
        guard node.instance_id == 0 else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime returned an instance ID without its presence flag"
            )
        }
        instanceID = nil
    }
    let boolValue: Bool
    switch node.bool_value {
    case 0: boolValue = false
    case 1: boolValue = true
    default:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime value node \(index) has a noncanonical bool"
        )
    }

    let edges = Array(flatEdges[edgeRange])
    let numberIsCanonicalZero = node.number_value.bitPattern == 0
    let hasCanonicalCompositeScalars = numberIsCanonicalZero
        && node.color_value == 0
        && !boolValue
        && node.identity_value == 0
        && stringValue.isEmpty

    let value: FlowRuntimeValue
    switch node.kind {
    case UInt32(NUX_FLOW_VALUE_KIND_NULL):
        try requireNuxieFlowScalarShape(
            node: node,
            index: index,
            numberIsValid: numberIsCanonicalZero,
            stringIsValid: stringValue.isEmpty,
            allowsColor: false,
            allowsBool: false,
            allowsIdentity: false,
            edgeRange: edgeRange,
            schemaID: schemaID,
            instanceID: instanceID
        )
        value = .scalar(.null)
    case UInt32(NUX_FLOW_VALUE_KIND_STRING):
        try requireNuxieFlowScalarShape(
            node: node,
            index: index,
            numberIsValid: numberIsCanonicalZero,
            stringIsValid: true,
            allowsColor: false,
            allowsBool: false,
            allowsIdentity: false,
            edgeRange: edgeRange,
            schemaID: schemaID,
            instanceID: instanceID
        )
        value = .scalar(.string(stringValue))
    case UInt32(NUX_FLOW_VALUE_KIND_NUMBER):
        try requireNuxieFlowScalarShape(
            node: node,
            index: index,
            numberIsValid: node.number_value.isFinite
                && abs(node.number_value) <= Double(Float.greatestFiniteMagnitude),
            stringIsValid: stringValue.isEmpty,
            allowsColor: false,
            allowsBool: false,
            allowsIdentity: false,
            edgeRange: edgeRange,
            schemaID: schemaID,
            instanceID: instanceID
        )
        value = .scalar(.number(node.number_value))
    case UInt32(NUX_FLOW_VALUE_KIND_BOOL):
        try requireNuxieFlowScalarShape(
            node: node,
            index: index,
            numberIsValid: numberIsCanonicalZero,
            stringIsValid: stringValue.isEmpty,
            allowsColor: false,
            allowsBool: true,
            allowsIdentity: false,
            edgeRange: edgeRange,
            schemaID: schemaID,
            instanceID: instanceID
        )
        value = .scalar(.bool(boolValue))
    case UInt32(NUX_FLOW_VALUE_KIND_ENUM):
        try requireNuxieFlowScalarShape(
            node: node,
            index: index,
            numberIsValid: numberIsCanonicalZero,
            stringIsValid: stringValue.isEmpty,
            allowsColor: false,
            allowsBool: false,
            allowsIdentity: true,
            edgeRange: edgeRange,
            schemaID: schemaID,
            instanceID: instanceID
        )
        value = .scalar(.enumeration(node.identity_value))
    case UInt32(NUX_FLOW_VALUE_KIND_COLOR):
        try requireNuxieFlowScalarShape(
            node: node,
            index: index,
            numberIsValid: numberIsCanonicalZero,
            stringIsValid: stringValue.isEmpty,
            allowsColor: true,
            allowsBool: false,
            allowsIdentity: false,
            edgeRange: edgeRange,
            schemaID: schemaID,
            instanceID: instanceID
        )
        value = .scalar(.color(node.color_value))
    case UInt32(NUX_FLOW_VALUE_KIND_IMAGE):
        try requireNuxieFlowScalarShape(
            node: node,
            index: index,
            numberIsValid: numberIsCanonicalZero,
            stringIsValid: stringValue.isEmpty,
            allowsColor: false,
            allowsBool: false,
            allowsIdentity: true,
            edgeRange: edgeRange,
            schemaID: schemaID,
            instanceID: instanceID
        )
        value = .scalar(.image(node.identity_value))
    case UInt32(NUX_FLOW_VALUE_KIND_OBJECT):
        guard hasCanonicalCompositeScalars, instanceID == nil else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime object node \(index) has noncanonical scalar fields"
            )
        }
        try requireNuxieFlowNamedEdges(edges, nodeIndex: index)
        value = .object(schemaID: schemaID, fields: edges)
    case UInt32(NUX_FLOW_VALUE_KIND_VIEW_MODEL):
        guard hasCanonicalCompositeScalars else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime view-model node \(index) has noncanonical scalar fields"
            )
        }
        try requireNuxieFlowNamedEdges(edges, nodeIndex: index)
        value = .viewModel(schemaID: schemaID, instanceID: instanceID, fields: edges)
    case UInt32(NUX_FLOW_VALUE_KIND_LIST):
        guard hasCanonicalCompositeScalars,
              schemaID == nil,
              instanceID == nil,
              edges.allSatisfy({ $0.key == nil }) else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime list node \(index) has noncanonical fields"
            )
        }
        guard edges.count <= FlowRuntimeSessionLimits.listItems else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime list node \(index) exceeds the item limit"
            )
        }
        value = .list(items: edges)
    default:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime value node \(index) has unknown kind \(node.kind)"
        )
    }
    return FlowRuntimeValueNode(value: value)
}

private func requireNuxieFlowScalarShape(
    node: NuxFlowValueNode,
    index: Int,
    numberIsValid: Bool,
    stringIsValid: Bool,
    allowsColor: Bool,
    allowsBool: Bool,
    allowsIdentity: Bool,
    edgeRange: Range<Int>,
    schemaID: String?,
    instanceID: FlowRuntimeInstanceID?
) throws {
    guard numberIsValid,
          stringIsValid,
          allowsColor || node.color_value == 0,
          allowsBool || node.bool_value == 0,
          allowsIdentity || node.identity_value == 0,
          edgeRange.isEmpty,
          schemaID == nil,
          instanceID == nil else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime scalar node \(index) has noncanonical fields"
        )
    }
}

private func requireNuxieFlowNamedEdges(
    _ edges: [FlowRuntimeValueEdge],
    nodeIndex: Int
) throws {
    var keys = Set<String>()
    for edge in edges {
        guard let key = edge.key, keys.insert(key).inserted else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime composite node \(nodeIndex) has a missing or duplicate key"
            )
        }
    }
}

private func validateNuxieFlowEntireGraph(
    _ arena: FlowRuntimeValueArena
) throws {
    var state = Array(repeating: UInt8(0), count: arena.nodes.count)
    var heights = Array(repeating: 0, count: arena.nodes.count)

    func visit(_ index: Int, depth: Int) throws -> Int {
        guard depth <= FlowRuntimeSessionLimits.valueDepth else {
            throw FlowRuntimeSessionValueError.limitExceeded(
                "Runtime value graph depth limit exceeded"
            )
        }
        switch state[index] {
        case 1:
            throw FlowRuntimeSessionValueError.invalidGraph(
                "Runtime value graph contains a cycle"
            )
        case 2:
            return heights[index]
        default:
            state[index] = 1
        }
        let edges: [FlowRuntimeValueEdge]
        switch arena.nodes[index].value {
        case .scalar:
            edges = []
        case .object(_, let fields), .viewModel(_, _, let fields):
            edges = fields
        case .list(let items):
            edges = items
        }
        var height = 0
        for edge in edges {
            let childHeight = try visit(edge.nodeIndex, depth: depth + 1)
            height = max(height, childHeight + 1)
            guard height <= FlowRuntimeSessionLimits.valueDepth else {
                throw FlowRuntimeSessionValueError.limitExceeded(
                    "Runtime value graph depth limit exceeded"
                )
            }
        }
        state[index] = 2
        heights[index] = height
        return height
    }

    for index in arena.nodes.indices where state[index] == 0 {
        _ = try visit(index, depth: 0)
    }
}

private func copyNuxieFlowCatalog(
    from result: OpaquePointer,
    arena: FlowRuntimeValueArena,
    budget: inout NuxieFlowSessionCopyBudget
) throws -> FlowRuntimeCatalog {
    let propertyCount = try nuxieFlowBoundedCount(
        nux_flow_session_result_schema_property_count(result),
        maximum: FlowRuntimeSessionLimits.batchItems,
        label: "schema properties"
    )
    var properties: [FlowRuntimeSchemaProperty] = []
    properties.reserveCapacity(propertyCount)
    for index in 0..<propertyCount {
        var property = NuxFlowSchemaPropertyView(
            struct_size: UInt32(MemoryLayout<NuxFlowSchemaPropertyView>.size),
            kind: UInt32(NUX_FLOW_SCHEMA_PROPERTY_KIND_NULL),
            schema_id: NuxByteView(data: nil, len: 0),
            property_id: NuxByteView(data: nil, len: 0),
            name: NuxByteView(data: nil, len: 0)
        )
        guard nux_flow_session_result_schema_property_at(
            result,
            UInt64(index),
            &property
        ) == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime schema property \(index) could not be read"
            )
        }
        properties.append(FlowRuntimeSchemaProperty(
            schemaID: try budget.copyRequiredIdentifier(
                property.schema_id,
                label: "schema property schema ID"
            ),
            propertyID: try budget.copyRequiredIdentifier(
                property.property_id,
                label: "schema property ID"
            ),
            name: try budget.copyString(
                property.name,
                maximum: FlowRuntimeSessionLimits.identifierBytes,
                label: "schema property name"
            ),
            kind: try copyNuxieFlowSchemaPropertyKind(property.kind)
        ))
    }

    let schemaCount = try nuxieFlowBoundedCount(
        nux_flow_session_result_schema_count(result),
        maximum: FlowRuntimeSessionLimits.instances,
        label: "schemas"
    )
    var schemas: [FlowRuntimeSchema] = []
    schemas.reserveCapacity(schemaCount)
    var coveredPropertyIndexes = Set<Int>()
    for index in 0..<schemaCount {
        var schema = NuxFlowSchemaView(
            struct_size: UInt32(MemoryLayout<NuxFlowSchemaView>.size),
            first_property: 0,
            property_count: 0,
            schema_id: NuxByteView(data: nil, len: 0),
            name: NuxByteView(data: nil, len: 0)
        )
        guard nux_flow_session_result_schema_at(result, UInt64(index), &schema)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime schema \(index) could not be read"
            )
        }
        let schemaID = try budget.copyRequiredIdentifier(
            schema.schema_id,
            label: "schema ID"
        )
        let range = try nuxieFlowCheckedRange(
            start: schema.first_property,
            count: schema.property_count,
            upperBound: properties.count,
            label: "property range for schema \(index)"
        )
        for propertyIndex in range {
            guard coveredPropertyIndexes.insert(propertyIndex).inserted,
                  properties[propertyIndex].schemaID == schemaID else {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native runtime schema \(index) has overlapping or mismatched properties"
                )
            }
        }
        schemas.append(FlowRuntimeSchema(
            id: schemaID,
            name: try budget.copyString(
                schema.name,
                maximum: FlowRuntimeSessionLimits.identifierBytes,
                label: "schema name"
            ),
            properties: Array(properties[range])
        ))
    }
    guard coveredPropertyIndexes.count == properties.count else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned schema properties outside every schema"
        )
    }

    let templateCount = try nuxieFlowBoundedCount(
        nux_flow_session_result_instance_template_count(result),
        maximum: FlowRuntimeSessionLimits.instances,
        label: "instance templates"
    )
    var templates: [FlowRuntimeInstanceTemplate] = []
    templates.reserveCapacity(templateCount)
    for index in 0..<templateCount {
        var template = NuxFlowInstanceTemplateView(
            struct_size: UInt32(MemoryLayout<NuxFlowInstanceTemplateView>.size),
            authored_index: 0,
            schema_id: NuxByteView(data: nil, len: 0),
            authored_name: NuxByteView(data: nil, len: 0)
        )
        guard nux_flow_session_result_instance_template_at(
            result,
            UInt64(index),
            &template
        ) == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime instance template \(index) could not be read"
            )
        }
        templates.append(FlowRuntimeInstanceTemplate(
            schemaID: try budget.copyRequiredIdentifier(
                template.schema_id,
                label: "instance template schema ID"
            ),
            authoredName: try budget.copyOptionalIdentifier(
                template.authored_name,
                label: "instance template authored name"
            ),
            authoredIndex: template.authored_index
        ))
    }

    let instanceCount = try nuxieFlowBoundedCount(
        nux_flow_session_result_instance_count(result),
        maximum: FlowRuntimeSessionLimits.instances,
        label: "instances"
    )
    var instances: [FlowRuntimeInstance] = []
    instances.reserveCapacity(instanceCount)
    var instanceIDs = Set<FlowRuntimeInstanceID>()
    for index in 0..<instanceCount {
        var instance = NuxFlowInstanceView(
            struct_size: UInt32(MemoryLayout<NuxFlowInstanceView>.size),
            value_root_index: UInt32.max,
            is_root: 0,
            instance_id: 0,
            schema_id: NuxByteView(data: nil, len: 0),
            name: NuxByteView(data: nil, len: 0)
        )
        guard nux_flow_session_result_instance_at(result, UInt64(index), &instance)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime instance \(index) could not be read"
            )
        }
        let instanceID = try nuxieFlowInstanceID(
            instance.instance_id,
            label: "catalog instance"
        )
        guard instanceIDs.insert(instanceID).inserted else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime returned duplicate catalog instance ID \(instance.instance_id)"
            )
        }
        let isRoot = try nuxieFlowPresence(instance.is_root, label: "root instance")
        let valueRootIndex: Int?
        if instance.value_root_index == UInt32.max {
            valueRootIndex = nil
        } else {
            guard Int(instance.value_root_index) < arena.nodes.count else {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native runtime catalog instance \(index) references a missing value node"
                )
            }
            valueRootIndex = Int(instance.value_root_index)
        }
        instances.append(FlowRuntimeInstance(
            id: instanceID,
            schemaID: try budget.copyRequiredIdentifier(
                instance.schema_id,
                label: "catalog instance schema ID"
            ),
            name: try budget.copyOptionalIdentifier(
                instance.name,
                label: "catalog instance name"
            ),
            isRoot: isRoot,
            valueRootIndex: valueRootIndex
        ))
    }

    return FlowRuntimeCatalog(
        schemas: schemas,
        templates: templates,
        instances: instances
    )
}

private func copyNuxieFlowSchemaPropertyKind(
    _ rawValue: UInt32
) throws -> FlowRuntimeSchemaPropertyKind {
    switch rawValue {
    case UInt32(NUX_FLOW_SCHEMA_PROPERTY_KIND_NULL): .null
    case UInt32(NUX_FLOW_SCHEMA_PROPERTY_KIND_STRING): .string
    case UInt32(NUX_FLOW_SCHEMA_PROPERTY_KIND_NUMBER): .number
    case UInt32(NUX_FLOW_SCHEMA_PROPERTY_KIND_BOOL): .bool
    case UInt32(NUX_FLOW_SCHEMA_PROPERTY_KIND_TRIGGER): .trigger
    case UInt32(NUX_FLOW_SCHEMA_PROPERTY_KIND_ENUM): .enumeration
    case UInt32(NUX_FLOW_SCHEMA_PROPERTY_KIND_COLOR): .color
    case UInt32(NUX_FLOW_SCHEMA_PROPERTY_KIND_IMAGE): .image
    case UInt32(NUX_FLOW_SCHEMA_PROPERTY_KIND_VIEW_MODEL): .viewModel
    case UInt32(NUX_FLOW_SCHEMA_PROPERTY_KIND_LIST): .list
    case UInt32(NUX_FLOW_SCHEMA_PROPERTY_KIND_OBJECT): .object
    default:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned unknown schema property kind \(rawValue)"
        )
    }
}

private func copyNuxieFlowPlayerMetadata(
    from result: OpaquePointer,
    budget: inout NuxieFlowSessionCopyBudget
) throws -> FlowRuntimePlayerMetadata? {
    var metadata = NuxFlowPlayerMetadataView(
        struct_size: UInt32(MemoryLayout<NuxFlowPlayerMetadataView>.size),
        kind: UInt32(NUX_FLOW_PLAYER_KIND_STATIC),
        selection: UInt32(NUX_FLOW_PLAYER_SELECTION_STATIC),
        player_index: UInt32.max,
        artboard_name: NuxByteView(data: nil, len: 0),
        player_name: NuxByteView(data: nil, len: 0),
        min_x: 0,
        min_y: 0,
        max_x: 0,
        max_y: 0
    )
    switch nux_flow_session_result_player_metadata(result, &metadata) {
    case NUX_STATUS_NOT_FOUND:
        return nil
    case NUX_STATUS_OK:
        break
    case let status:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime player metadata accessor failed with status \(status)"
        )
    }

    let kind: FlowRuntimePlayerKind
    switch metadata.kind {
    case UInt32(NUX_FLOW_PLAYER_KIND_STATE_MACHINE): kind = .stateMachine
    case UInt32(NUX_FLOW_PLAYER_KIND_LINEAR_ANIMATION): kind = .linearAnimation
    case UInt32(NUX_FLOW_PLAYER_KIND_STATIC): kind = .staticArtboard
    default:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned unknown player kind \(metadata.kind)"
        )
    }
    let selection: FlowRuntimePlayerSelection
    switch metadata.selection {
    case UInt32(NUX_FLOW_PLAYER_SELECTION_EXPLICIT_STATE_MACHINE):
        selection = .explicitStateMachine
    case UInt32(NUX_FLOW_PLAYER_SELECTION_AUTHORED_DEFAULT_STATE_MACHINE):
        selection = .authoredDefaultStateMachine
    case UInt32(NUX_FLOW_PLAYER_SELECTION_FIRST_STATE_MACHINE):
        selection = .firstStateMachine
    case UInt32(NUX_FLOW_PLAYER_SELECTION_FIRST_ANIMATION):
        selection = .firstAnimation
    case UInt32(NUX_FLOW_PLAYER_SELECTION_STATIC):
        selection = .staticArtboard
    default:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned unknown player selection \(metadata.selection)"
        )
    }
    let index = metadata.player_index == UInt32.max ? nil : metadata.player_index
    let selectionIsConsistent: Bool = switch selection {
    case .explicitStateMachine, .authoredDefaultStateMachine, .firstStateMachine:
        kind == .stateMachine && index != nil
    case .firstAnimation:
        kind == .linearAnimation && index != nil
    case .staticArtboard:
        kind == .staticArtboard && index == nil
    }
    guard selectionIsConsistent else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned inconsistent player kind, selection, and index"
        )
    }

    let bounds = FlowRuntimeArtboardBounds(
        minX: Double(metadata.min_x),
        minY: Double(metadata.min_y),
        maxX: Double(metadata.max_x),
        maxY: Double(metadata.max_y)
    )
    do {
        try bounds.validate()
    } catch {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned invalid player bounds"
        )
    }
    return FlowRuntimePlayerMetadata(
        kind: kind,
        selection: selection,
        index: index,
        artboardName: try budget.copyOptionalIdentifier(
            metadata.artboard_name,
            label: "player artboard name"
        ),
        playerName: try budget.copyOptionalIdentifier(
            metadata.player_name,
            label: "player name"
        ),
        bounds: bounds
    )
}

private func copyNuxieFlowPlayerInputs(
    from result: OpaquePointer,
    arena: FlowRuntimeValueArena,
    budget: inout NuxieFlowSessionCopyBudget
) throws -> [FlowRuntimePlayerInput] {
    let count = try nuxieFlowBoundedCount(
        nux_flow_session_result_player_input_count(result),
        maximum: FlowRuntimeSessionLimits.batchItems,
        label: "player inputs"
    )
    var inputs: [FlowRuntimePlayerInput] = []
    inputs.reserveCapacity(count)
    for index in 0..<count {
        var input = NuxFlowPlayerInputView(
            struct_size: UInt32(MemoryLayout<NuxFlowPlayerInputView>.size),
            kind: UInt32(NUX_FLOW_PLAYER_INPUT_KIND_BOOL),
            value_root_index: 0,
            name: NuxByteView(data: nil, len: 0)
        )
        guard nux_flow_session_result_player_input_at(result, UInt64(index), &input)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime player input \(index) could not be read"
            )
        }
        let kind: FlowRuntimePlayerInputKind
        switch input.kind {
        case UInt32(NUX_FLOW_PLAYER_INPUT_KIND_BOOL): kind = .bool
        case UInt32(NUX_FLOW_PLAYER_INPUT_KIND_NUMBER): kind = .number
        case UInt32(NUX_FLOW_PLAYER_INPUT_KIND_TRIGGER): kind = .trigger
        default:
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime player input \(index) has unknown kind \(input.kind)"
            )
        }
        let value = try nuxieFlowScalarValue(
            at: input.value_root_index,
            in: arena,
            label: "player input \(index)"
        )
        let valueMatchesKind: Bool = switch (kind, value) {
        case (.bool, .bool), (.trigger, .bool), (.number, .number): true
        default: false
        }
        guard valueMatchesKind else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime player input \(index) has a mismatched value kind"
            )
        }
        inputs.append(FlowRuntimePlayerInput(
            name: try budget.copyOptionalIdentifier(
                input.name,
                label: "player input name"
            ),
            kind: kind,
            value: value
        ))
    }
    return inputs
}

private func nuxieFlowScalarValue(
    at rawIndex: UInt32,
    in arena: FlowRuntimeValueArena,
    label: String
) throws -> FlowRuntimeScalarValue {
    let index = Int(rawIndex)
    guard arena.nodes.indices.contains(index) else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime \(label) references a missing value node"
        )
    }
    guard case .scalar(let scalar) = arena.nodes[index].value else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime \(label) references a composite value"
        )
    }
    return scalar
}

private struct NuxieFlowCopiedEventProperty {
    let name: String?
    let valueRootIndex: UInt32?
    let triggerCount: UInt64?
}

private func copyNuxieFlowEventProperties(
    from result: OpaquePointer,
    budget: inout NuxieFlowSessionCopyBudget
) throws -> [NuxieFlowCopiedEventProperty] {
    let maximum = FlowRuntimeSessionLimits.outputs
        * FlowRuntimeSessionLimits.eventProperties
    let count = try nuxieFlowBoundedCount(
        nux_flow_session_result_event_property_count(result),
        maximum: maximum,
        label: "event properties"
    )
    var properties: [NuxieFlowCopiedEventProperty] = []
    properties.reserveCapacity(count)
    for index in 0..<count {
        var property = NuxFlowEventPropertyView(
            struct_size: UInt32(MemoryLayout<NuxFlowEventPropertyView>.size),
            value_root_index: UInt32.max,
            has_trigger_count: 0,
            trigger_count: 0,
            name: NuxByteView(data: nil, len: 0)
        )
        guard nux_flow_session_result_event_property_at(
            result,
            UInt64(index),
            &property
        ) == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime event property \(index) could not be read"
            )
        }
        let hasTrigger = try nuxieFlowPresence(
            property.has_trigger_count,
            label: "event property trigger count"
        )
        let hasValue = property.value_root_index != UInt32.max
        guard hasTrigger != hasValue else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime event property \(index) must carry exactly one value"
            )
        }
        if !hasTrigger, property.trigger_count != 0 {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime event property \(index) has a trigger count without presence"
            )
        }
        properties.append(NuxieFlowCopiedEventProperty(
            name: try budget.copyOptionalIdentifier(
                property.name,
                label: "event property name"
            ),
            valueRootIndex: hasValue ? property.value_root_index : nil,
            triggerCount: hasTrigger ? property.trigger_count : nil
        ))
    }
    return properties
}

private func copyNuxieFlowOutputs(
    from result: OpaquePointer,
    arena: FlowRuntimeValueArena,
    budget: inout NuxieFlowSessionCopyBudget
) throws -> [FlowRuntimeOutput] {
    let eventProperties = try copyNuxieFlowEventProperties(
        from: result,
        budget: &budget
    )
    let count = try nuxieFlowBoundedCount(
        nux_flow_session_result_output_count(result),
        maximum: FlowRuntimeSessionLimits.outputs,
        label: "outputs"
    )
    var outputs: [FlowRuntimeOutput] = []
    outputs.reserveCapacity(count)
    var priorSequence: UInt64?
    var priorCycleAndPhase: (UInt64, FlowRuntimeOutputPhase)?
    var coveredEventProperties = Set<Int>()

    for index in 0..<count {
        var output = NuxFlowOutputView(
            struct_size: UInt32(MemoryLayout<NuxFlowOutputView>.size),
            phase: UInt32(NUX_FLOW_OUTPUT_PHASE_DELAYED_EVENT_CALLBACKS),
            kind: UInt32(NUX_FLOW_OUTPUT_KIND_REPORTED_EVENT),
            payload_root_index: UInt32.max,
            has_origin_mutation_id: 0,
            has_instance_id: 0,
            sequence: 0,
            cycle: 0,
            origin_mutation_id: 0,
            instance_id: 0,
            event_type: 0,
            first_event_property: 0,
            event_property_count: 0,
            delay_seconds: 0,
            name: NuxByteView(data: nil, len: 0),
            path: NuxByteView(data: nil, len: 0),
            payload: NuxByteView(data: nil, len: 0)
        )
        guard nux_flow_session_result_output_at(result, UInt64(index), &output)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime output \(index) could not be read"
            )
        }
        if let priorSequence, output.sequence <= priorSequence {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime output sequence did not increase"
            )
        }
        priorSequence = output.sequence

        let phase = try copyNuxieFlowOutputPhase(output.phase)
        if let (priorCycle, priorPhase) = priorCycleAndPhase,
           output.cycle < priorCycle
            || (output.cycle == priorCycle && phase.rawValue < priorPhase.rawValue) {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime output cycle or phase regressed"
            )
        }
        priorCycleAndPhase = (output.cycle, phase)

        let hasOriginMutation = try nuxieFlowPresence(
            output.has_origin_mutation_id,
            label: "output origin mutation ID"
        )
        if !hasOriginMutation, output.origin_mutation_id != 0 {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime output has an origin mutation ID without presence"
            )
        }
        let originMutationID = hasOriginMutation ? output.origin_mutation_id : nil

        let hasInstance = try nuxieFlowPresence(
            output.has_instance_id,
            label: "output instance ID"
        )
        let instanceID: FlowRuntimeInstanceID?
        if hasInstance {
            instanceID = try nuxieFlowInstanceID(
                output.instance_id,
                label: "output instance"
            )
        } else {
            guard output.instance_id == 0 else {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native runtime output has an instance ID without presence"
                )
            }
            instanceID = nil
        }
        let payloadRoot = output.payload_root_index == UInt32.max
            ? nil
            : output.payload_root_index
        if let payloadRoot, Int(payloadRoot) >= arena.nodes.count {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime output \(index) references a missing payload node"
            )
        }
        guard output.delay_seconds.isFinite, output.delay_seconds >= 0 else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime output \(index) has an invalid delay"
            )
        }
        let name = try budget.copyString(
            output.name,
            maximum: FlowRuntimeSessionLimits.identifierBytes,
            label: "output name"
        )
        let path = try budget.copyString(
            output.path,
            maximum: FlowRuntimeSessionLimits.pathBytes,
            label: "output path"
        )
        let opaquePayload = try budget.copyData(
            output.payload,
            maximum: FlowRuntimeSessionLimits.encodedPayloadBytes,
            label: "output payload"
        )
        let propertyRange = try nuxieFlowCheckedRange(
            start: output.first_event_property,
            count: output.event_property_count,
            upperBound: eventProperties.count,
            label: "event-property range for output \(index)"
        )
        guard propertyRange.count <= FlowRuntimeSessionLimits.eventProperties else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime output \(index) exceeds the event-property limit"
            )
        }

        let payload: FlowRuntimeOutputPayload
        switch output.kind {
        case UInt32(NUX_FLOW_OUTPUT_KIND_REPORTED_EVENT):
            guard instanceID == nil,
                  originMutationID == nil,
                  payloadRoot == nil,
                  path.isEmpty,
                  opaquePayload.isEmpty else {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native runtime reported-event output \(index) has unrelated fields"
                )
            }
            var copiedProperties: [FlowRuntimeEventProperty] = []
            copiedProperties.reserveCapacity(propertyRange.count)
            for propertyIndex in propertyRange {
                guard coveredEventProperties.insert(propertyIndex).inserted else {
                    throw NuxieRuntimeAdapterError.invalidNativeResult(
                        "native runtime event property \(propertyIndex) is shared by outputs"
                    )
                }
                let property = eventProperties[propertyIndex]
                let value: FlowRuntimeScalarValue
                if let triggerCount = property.triggerCount {
                    value = .trigger(triggerCount)
                } else if let root = property.valueRootIndex {
                    value = try nuxieFlowScalarValue(
                        at: root,
                        in: arena,
                        label: "event property \(propertyIndex)"
                    )
                } else {
                    throw NuxieRuntimeAdapterError.invalidNativeResult(
                        "native runtime event property \(propertyIndex) omitted its value"
                    )
                }
                copiedProperties.append(FlowRuntimeEventProperty(
                    name: property.name,
                    value: value
                ))
            }
            payload = .reportedEvent(
                name: name.isEmpty ? nil : name,
                eventType: output.event_type,
                delay: TimeInterval(output.delay_seconds),
                properties: copiedProperties
            )
        case UInt32(NUX_FLOW_OUTPUT_KIND_STATE_CHANGE),
             UInt32(NUX_FLOW_OUTPUT_KIND_VIEW_MODEL_CHANGE):
            let isViewModel = output.kind == UInt32(NUX_FLOW_OUTPUT_KIND_VIEW_MODEL_CHANGE)
            guard !path.isEmpty,
                  name.isEmpty,
                  opaquePayload.isEmpty,
                  propertyRange.isEmpty,
                  output.event_type == 0,
                  output.delay_seconds.bitPattern == 0,
                  isViewModel == (instanceID != nil) else {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native runtime state-change output \(index) has inconsistent fields"
                )
            }
            let change = FlowRuntimeStateChange(
                instanceID: instanceID,
                path: path,
                value: try payloadRoot.map {
                    try nuxieFlowScalarValue(
                        at: $0,
                        in: arena,
                        label: "state-change output \(index)"
                    )
                },
                originMutationID: originMutationID
            )
            payload = isViewModel ? .viewModelChange(change) : .stateChange(change)
        case UInt32(NUX_FLOW_OUTPUT_KIND_HOST_COMMAND):
            guard !name.isEmpty,
                  path.isEmpty,
                  payloadRoot == nil,
                  propertyRange.isEmpty,
                  instanceID == nil,
                  originMutationID == nil,
                  output.event_type == 0,
                  output.delay_seconds.bitPattern == 0 else {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native runtime host-command output \(index) has inconsistent fields"
                )
            }
            payload = .hostCommand(name: name, payload: opaquePayload)
        case UInt32(NUX_FLOW_OUTPUT_KIND_RENDER_REQUEST):
            try requireNuxieFlowEmptyOutputFields(
                outputIndex: index,
                name: name,
                path: path,
                payload: opaquePayload,
                payloadRoot: payloadRoot,
                propertyRange: propertyRange,
                instanceID: instanceID,
                originMutationID: originMutationID,
                eventType: output.event_type,
                delay: output.delay_seconds
            )
            payload = .renderRequest
        case UInt32(NUX_FLOW_OUTPUT_KIND_RUNTIME_ADVANCED):
            guard name.isEmpty,
                  path.isEmpty,
                  opaquePayload.isEmpty,
                  payloadRoot == nil,
                  propertyRange.isEmpty,
                  instanceID == nil,
                  originMutationID == nil,
                  output.event_type == 0 else {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native runtime advance output \(index) has inconsistent fields"
                )
            }
            payload = .runtimeAdvanced(delta: TimeInterval(output.delay_seconds))
        default:
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime output \(index) has unknown kind \(output.kind)"
            )
        }
        try validateNuxieFlowOutputPhase(
            phase,
            payload: payload,
            outputIndex: index
        )
        outputs.append(FlowRuntimeOutput(
            sequence: output.sequence,
            cycle: output.cycle,
            phase: phase,
            payload: payload
        ))
    }
    guard coveredEventProperties.count == eventProperties.count else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned event properties outside every reported event"
        )
    }
    return outputs
}

func validateNuxieFlowOutputPhase(
    _ phase: FlowRuntimeOutputPhase,
    payload: FlowRuntimeOutputPayload,
    outputIndex: Int
) throws {
    let expectedPhase: FlowRuntimeOutputPhase = switch payload {
    case .delayedEvent:
        .delayedEventCallbacks
    case .reportedEvent:
        .reportedEvents
    case .runtimeAdvanced:
        .runtimeAdvance
    case .stateChange, .viewModelChange:
        .viewModelChanges
    case .hostCommand:
        .hostWork
    case .renderRequest:
        .render
    }
    guard phase == expectedPhase else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime output \(outputIndex) has phase \(phase) but its payload requires \(expectedPhase)"
        )
    }
}

private func copyNuxieFlowOutputPhase(
    _ rawValue: UInt32
) throws -> FlowRuntimeOutputPhase {
    switch rawValue {
    case UInt32(NUX_FLOW_OUTPUT_PHASE_DELAYED_EVENT_CALLBACKS): .delayedEventCallbacks
    case UInt32(NUX_FLOW_OUTPUT_PHASE_REPORTED_EVENTS): .reportedEvents
    case UInt32(NUX_FLOW_OUTPUT_PHASE_RUNTIME_ADVANCE): .runtimeAdvance
    case UInt32(NUX_FLOW_OUTPUT_PHASE_VIEW_MODEL_CHANGES): .viewModelChanges
    case UInt32(NUX_FLOW_OUTPUT_PHASE_HOST_WORK): .hostWork
    case UInt32(NUX_FLOW_OUTPUT_PHASE_RENDER): .render
    default:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned unknown output phase \(rawValue)"
        )
    }
}

private func requireNuxieFlowEmptyOutputFields(
    outputIndex: Int,
    name: String,
    path: String,
    payload: Data,
    payloadRoot: UInt32?,
    propertyRange: Range<Int>,
    instanceID: FlowRuntimeInstanceID?,
    originMutationID: UInt64?,
    eventType: UInt32,
    delay: Float
) throws {
    guard name.isEmpty,
          path.isEmpty,
          payload.isEmpty,
          payloadRoot == nil,
          propertyRange.isEmpty,
          instanceID == nil,
          originMutationID == nil,
          eventType == 0,
          delay.bitPattern == 0 else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime output \(outputIndex) has noncanonical unused fields"
        )
    }
}

private func copyNuxieFlowCreatedInstances(
    from result: OpaquePointer
) throws -> [FlowRuntimeCreatedInstance] {
    let count = try nuxieFlowBoundedCount(
        nux_flow_session_result_created_instance_count(result),
        maximum: FlowRuntimeSessionLimits.instances,
        label: "created instances"
    )
    var createdInstances: [FlowRuntimeCreatedInstance] = []
    createdInstances.reserveCapacity(count)
    var localIDs = Set<UInt32>()
    var stableIDs = Set<FlowRuntimeInstanceID>()
    for index in 0..<count {
        var created = NuxFlowCreatedInstanceView(
            struct_size: UInt32(MemoryLayout<NuxFlowCreatedInstanceView>.size),
            local_id: 0,
            instance_id: 0
        )
        guard nux_flow_session_result_created_instance_at(
            result,
            UInt64(index),
            &created
        ) == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime created instance \(index) could not be read"
            )
        }
        let instanceID = try nuxieFlowInstanceID(
            created.instance_id,
            label: "created instance"
        )
        guard localIDs.insert(created.local_id).inserted,
              stableIDs.insert(instanceID).inserted else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime returned duplicate created-instance identities"
            )
        }
        createdInstances.append(FlowRuntimeCreatedInstance(
            localID: created.local_id,
            instanceID: instanceID
        ))
    }
    return createdInstances
}

private func copyNuxieFlowSessionDiagnostics(
    from result: OpaquePointer,
    budget: inout NuxieFlowSessionCopyBudget
) throws -> [FlowRuntimeDiagnostic] {
    let count = try nuxieFlowBoundedCount(
        nux_flow_session_result_diagnostic_count(result),
        maximum: 1_024,
        label: "session diagnostics"
    )
    var diagnostics: [FlowRuntimeDiagnostic] = []
    diagnostics.reserveCapacity(count)
    for index in 0..<count {
        var diagnostic = NuxDiagnosticView(
            struct_size: UInt32(MemoryLayout<NuxDiagnosticView>.size),
            severity: UInt32(NUX_DIAGNOSTIC_SEVERITY_DEBUG),
            code: NuxByteView(data: nil, len: 0),
            message: NuxByteView(data: nil, len: 0)
        )
        guard nux_flow_session_result_diagnostic_at(
            result,
            UInt64(index),
            &diagnostic
        ) == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime session diagnostic \(index) could not be read"
            )
        }
        let severity: FlowRuntimeDiagnostic.Severity
        switch diagnostic.severity {
        case UInt32(NUX_DIAGNOSTIC_SEVERITY_DEBUG): severity = .debug
        case UInt32(NUX_DIAGNOSTIC_SEVERITY_WARNING): severity = .warning
        case UInt32(NUX_DIAGNOSTIC_SEVERITY_FATAL): severity = .fatal
        default:
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime session diagnostic \(index) has unknown severity"
            )
        }
        diagnostics.append(FlowRuntimeDiagnostic(
            severity: severity,
            code: try budget.copyRequiredIdentifier(
                diagnostic.code,
                label: "session diagnostic code"
            ),
            message: try budget.copyString(
                diagnostic.message,
                maximum: FlowRuntimeSessionLimits.stringBytes,
                label: "session diagnostic message"
            )
        ))
    }
    return diagnostics
}

func copyNuxieRuntimeResultSnapshot(
    callStatus: UInt32,
    result: inout OpaquePointer?,
    renderRequested: Bool
) throws -> NuxieRuntimeResultSnapshot {
    guard let ownedResult = result else {
        if callStatus != NUX_STATUS_OK {
            throw NuxieRuntimeAdapterError.callFailed(
                status: nuxieRuntimeStatus(callStatus),
                diagnostic: nuxieRuntimeDiagnostic(
                    status: callStatus,
                    message: "native runtime returned no diagnostic result"
                )
            )
        }
        throw NuxieRuntimeAdapterError.missingOperationResult
    }
    result = nil
    defer { nux_operation_result_free(ownedResult) }

    let resultStatus = nux_operation_result_status(ownedResult)
    let structuredDiagnostics = try copyNuxieRuntimeDiagnostics(from: ownedResult)
    let diagnosticMessage = copyNuxieRuntimeDiagnostic(from: ownedResult)
    let failureStatus = callStatus != NUX_STATUS_OK ? callStatus : resultStatus
    if failureStatus != NUX_STATUS_OK {
        throw NuxieRuntimeAdapterError.callFailed(
            status: nuxieRuntimeStatus(failureStatus),
            diagnostic: structuredDiagnostics.first
                ?? nuxieRuntimeDiagnostic(
                    status: failureStatus,
                    message: diagnosticMessage.isEmpty
                        ? "native runtime operation failed"
                        : diagnosticMessage
                )
        )
    }

    let disposition = nuxieRuntimeSurfaceDisposition(
        nux_operation_result_surface_disposition(ownedResult)
    )
    let changed = nux_operation_result_changed(ownedResult)
    let renderOutcome: FlowRuntimeRenderOutcome
    if !renderRequested {
        renderOutcome = .notRequested
    } else if disposition == .presented {
        renderOutcome = .presented
    } else {
        renderOutcome = .skipped
    }
    var diagnostics = structuredDiagnostics
    if diagnostics.isEmpty, !diagnosticMessage.isEmpty {
        diagnostics = [
            FlowRuntimeDiagnostic(
                severity: .debug,
                code: "nux_runtime.ok",
                message: diagnosticMessage
            )
        ]
    }

    return NuxieRuntimeResultSnapshot(
        operationResult: FlowRuntimeOperationResult(
            renderOutcome: renderOutcome,
            surfaceDisposition: disposition,
            isDirty: changed,
            isSettled: !changed,
            orderedOutputs: [],
            diagnostics: diagnostics
        ),
        scriptAuthorization: try copyNuxieRuntimeScriptAuthorization(
            from: ownedResult
        )
    )
}

private func copyNuxieRuntimeScriptAuthorization(
    from result: OpaquePointer
) throws -> FlowRuntimeScriptAuthorization? {
    switch nux_operation_result_script_authorization(result) {
    case UInt32(NUX_SCRIPT_AUTHORIZATION_NOT_APPLICABLE):
        return nil
    case UInt32(NUX_SCRIPT_AUTHORIZATION_VISUAL_ONLY):
        return .visualOnly
    case UInt32(NUX_SCRIPT_AUTHORIZATION_AUTHENTICATED):
        var keyIdView = NuxByteView(data: nil, len: 0)
        guard nux_operation_result_authenticated_key_id(result, &keyIdView)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "authenticated import omitted its key ID"
            )
        }
        let keyId = try copyNuxieRuntimeUTF8(
            keyIdView,
            label: "authenticated key ID"
        )
        guard !keyId.isEmpty else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "authenticated import returned an empty key ID"
            )
        }
        return .authorized(keyId: keyId)
    case let value:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "unknown script authorization value \(value)"
        )
    }
}

private func copyNuxieRuntimeDiagnostics(
    from result: OpaquePointer
) throws -> [FlowRuntimeDiagnostic] {
    let count = nux_operation_result_diagnostic_count(result)
    guard count <= 1_024, count <= UInt64(Int.max) else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned too many diagnostics"
        )
    }
    var diagnostics: [FlowRuntimeDiagnostic] = []
    diagnostics.reserveCapacity(Int(count))
    var aggregateUTF8Bytes = 0
    for index in 0..<count {
        var view = NuxDiagnosticView(
            struct_size: UInt32(MemoryLayout<NuxDiagnosticView>.size),
            severity: UInt32(NUX_DIAGNOSTIC_SEVERITY_DEBUG),
            code: NuxByteView(data: nil, len: 0),
            message: NuxByteView(data: nil, len: 0)
        )
        guard nux_operation_result_diagnostic_at(result, index, &view)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime diagnostic \(index) could not be read"
            )
        }
        let severity: FlowRuntimeDiagnostic.Severity
        switch view.severity {
        case UInt32(NUX_DIAGNOSTIC_SEVERITY_DEBUG):
            severity = .debug
        case UInt32(NUX_DIAGNOSTIC_SEVERITY_WARNING):
            severity = .warning
        case UInt32(NUX_DIAGNOSTIC_SEVERITY_FATAL):
            severity = .fatal
        default:
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime diagnostic \(index) has an unknown severity"
            )
        }
        let code = try copyNuxieRuntimeUTF8(view.code, label: "diagnostic code")
        guard !code.isEmpty else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime diagnostic \(index) has an empty code"
            )
        }
        let message = try copyNuxieRuntimeUTF8(
            view.message,
            label: "diagnostic message"
        )
        let (nextAggregate, overflowed) = aggregateUTF8Bytes.addingReportingOverflow(
            code.utf8.count + message.utf8.count
        )
        guard !overflowed, nextAggregate <= 8_388_608 else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime returned oversized aggregate diagnostics"
            )
        }
        aggregateUTF8Bytes = nextAggregate
        diagnostics.append(
            FlowRuntimeDiagnostic(
                severity: severity,
                code: code,
                message: message
            )
        )
    }
    return diagnostics
}

private func copyNuxieRuntimeUTF8(
    _ view: NuxByteView,
    label: String
) throws -> String {
    guard view.len <= UInt64(Int.max), view.len <= 4_194_304 else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned an oversized \(label)"
        )
    }
    guard view.len > 0 else { return "" }
    guard let bytes = view.data else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned a null \(label)"
        )
    }
    let data = Data(bytes: bytes, count: Int(view.len))
    guard let value = String(data: data, encoding: .utf8) else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned non-UTF-8 \(label)"
        )
    }
    return value
}

/// Copies the borrowed result view before `copyNuxieRuntimeResult` frees it.
private func copyNuxieRuntimeDiagnostic(from result: OpaquePointer) -> String {
    var view = NuxByteView(data: nil, len: 0)
    let status = nux_operation_result_diagnostic(result, &view)
    guard status == NUX_STATUS_OK else {
        return "native runtime diagnostic could not be read"
    }
    guard view.len > 0 else { return "" }
    guard let bytes = view.data,
          view.len <= UInt64(Int.max),
          view.len <= 4_194_304 else {
        return "native runtime returned an invalid diagnostic view"
    }
    let copiedBytes = Data(bytes: bytes, count: Int(view.len))
    return String(decoding: copiedBytes, as: UTF8.self)
}

private func nuxieRuntimeDiagnostic(
    status: UInt32,
    message: String
) -> FlowRuntimeDiagnostic {
    FlowRuntimeDiagnostic(
        severity: .fatal,
        code: "nux_runtime.\(nuxieRuntimeStatusCode(status))",
        message: message
    )
}

func nuxieRuntimeStatus(_ rawValue: UInt32) -> NuxieRuntimeStatus {
    switch rawValue {
    case NUX_STATUS_OK: .ok
    case NUX_STATUS_NULL_ARGUMENT: .nullArgument
    case NUX_STATUS_IMPORT_ERROR: .importError
    case NUX_STATUS_NOT_FOUND: .notFound
    case NUX_STATUS_RUNTIME_ERROR: .runtimeError
    case NUX_STATUS_INVALID_ARGUMENT: .invalidArgument
    case NUX_STATUS_ABI_MISMATCH: .abiMismatch
    case NUX_STATUS_SURFACE_ERROR: .surfaceError
    default: .unknown(rawValue)
    }
}

private func nuxieRuntimeStatusCode(_ rawValue: UInt32) -> String {
    switch nuxieRuntimeStatus(rawValue) {
    case .ok: "ok"
    case .nullArgument: "null_argument"
    case .importError: "import_error"
    case .notFound: "not_found"
    case .runtimeError: "runtime_error"
    case .invalidArgument: "invalid_argument"
    case .abiMismatch: "abi_mismatch"
    case .surfaceError: "surface_error"
    case .unknown(let value): "unknown_\(value)"
    }
}

func nuxieRuntimeSurfaceDisposition(
    _ rawValue: UInt32
) -> FlowRuntimeSurfaceDisposition {
    switch rawValue {
    case NUX_SURFACE_DISPOSITION_NONE: .none
    case NUX_SURFACE_DISPOSITION_PRESENTED: .presented
    case NUX_SURFACE_DISPOSITION_SKIPPED_ZERO_SIZE: .skippedZeroSize
    case NUX_SURFACE_DISPOSITION_SKIPPED_TIMEOUT: .skippedTimeout
    case NUX_SURFACE_DISPOSITION_SKIPPED_OCCLUDED: .skippedOccluded
    case NUX_SURFACE_DISPOSITION_RECONFIGURED: .reconfigured
    case NUX_SURFACE_DISPOSITION_RECREATED: .recreated
    case NUX_SURFACE_DISPOSITION_DEVICE_LOST: .deviceLost
    case NUX_SURFACE_DISPOSITION_OUT_OF_MEMORY: .outOfMemory
    case NUX_SURFACE_DISPOSITION_FATAL: .fatal
    default: .unknown(rawValue)
    }
}

#endif
