#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieRuntimeSupport
import NuxieRuntimeFFI

extension NuxieRuntimeAdapterError: LocalizedError {
    package var errorDescription: String? {
        switch self {
        case .callFailed(let status, let diagnostic):
            "NuxieRuntime call failed (\(status)): \(diagnostic.code): \(diagnostic.message)"
        case .missingHandle(let name):
            "NuxieRuntime omitted its \(name) handle"
        case .missingOperationResult:
            "NuxieRuntime omitted its operation result"
        case .invalidNativeResult(let message):
            "NuxieRuntime returned an invalid result: \(message)"
        case .invalidOperation(let error):
            "NuxieRuntime rejected an invalid Swift operation: \(error.localizedDescription)"
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
) throws -> ExperienceRuntimeOperationResult {
    try copyNuxieRuntimeResultSnapshot(
        callStatus: callStatus,
        result: &result,
        renderRequested: renderRequested
    ).operationResult
}

struct NuxieRuntimeResultSnapshot {
    let operationResult: ExperienceRuntimeOperationResult
    let authenticatedKeyId: String?
}

/// Copies every ABI 1.4+ result-owned view before releasing the native handle.
///
/// The result pointer is consumed even when decoding fails. Nothing in the
/// returned Swift value borrows Rust-owned storage.
func copyNuxieScreenSessionSessionResult(
    callStatus: UInt32,
    result: inout OpaquePointer?,
    renderRequested: Bool
) throws -> ExperienceRuntimeOperationResult {
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
    defer { nux_screen_session_result_free(ownedResult) }

    var budget = NuxieScreenSessionSessionCopyBudget()
    let diagnostics = try copyNuxieScreenSessionSessionDiagnostics(
        from: ownedResult,
        budget: &budget
    )
    let resultStatus = nux_screen_session_result_status(ownedResult)
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

    let disposition = try copyNuxieScreenSessionSurfaceDisposition(
        nux_screen_session_result_surface_disposition(ownedResult)
    )
    let wakeAfter = try copyNuxieScreenSessionWakeAfter(from: ownedResult)
    let arena = try copyNuxieScreenSessionValueArena(
        from: ownedResult,
        budget: &budget
    )
    let catalog = try copyNuxieScreenSessionCatalog(
        from: ownedResult,
        arena: arena,
        budget: &budget
    )
    let metadata = try copyNuxieScreenSessionPlayerMetadata(
        from: ownedResult,
        budget: &budget
    )
    let playerInputs = try copyNuxieScreenSessionPlayerInputs(
        from: ownedResult,
        arena: arena,
        budget: &budget
    )
    let outputs = try copyNuxieScreenSessionOutputs(
        from: ownedResult,
        arena: arena,
        budget: &budget
    )
    let createdInstances = try copyNuxieScreenSessionCreatedInstances(from: ownedResult)

    // ABI 1.4+ exposes independent presence so a present-empty query response
    // is not conflated with a field that was not requested.
    let hasValues = nux_screen_session_result_has_values(ownedResult)
    let hasCatalog = nux_screen_session_result_has_catalog(ownedResult)
    let hasPlayerInputs = nux_screen_session_result_has_player_inputs(ownedResult)
    try validateNuxieScreenSessionValuesPresence(arena, isPresent: hasValues)
    try validateNuxieScreenSessionCatalogShape(catalog, isPresent: hasCatalog)
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
        try validateNuxieScreenSessionCatalogValueBindings(catalog: catalog, arena: arena)
    }

    let renderOutcome: ExperienceRuntimeRenderOutcome
    if !renderRequested {
        renderOutcome = .notRequested
    } else if disposition == .presented {
        renderOutcome = .presented
    } else {
        renderOutcome = .skipped
    }

    return ExperienceRuntimeOperationResult(
        renderOutcome: renderOutcome,
        surfaceDisposition: disposition,
        isDirty: nux_screen_session_result_is_dirty(ownedResult),
        isSettled: nux_screen_session_result_is_settled(ownedResult),
        wakeAfter: wakeAfter,
        orderedOutputs: outputs,
        diagnostics: diagnostics,
        bootstrap: metadata.map {
            ExperienceRuntimeBootstrap(player: $0, catalog: catalog, values: arena)
        },
        values: hasValues ? arena : nil,
        catalog: hasCatalog ? catalog : nil,
        playerInputs: hasPlayerInputs ? playerInputs : nil,
        createdInstances: createdInstances
    )
}

private struct NuxieScreenSessionSessionCopyBudget {
    private(set) var bytes = 0

    mutating func copyData(
        _ view: NuxByteView,
        maximum: Int,
        label: String
    ) throws -> Data {
        let count = try nuxieRuntimeBoundedCount(view.len, maximum: maximum, label: label)
        guard count == 0 || view.data != nil else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime returned a null \(label) with nonzero length"
            )
        }
        let (nextBytes, overflowed) = bytes.addingReportingOverflow(count)
        guard !overflowed,
              nextBytes <= ScreenSessionLimits.encodedPayloadBytes else {
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
            maximum: ScreenSessionLimits.identifierBytes,
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
            maximum: ScreenSessionLimits.identifierBytes,
            label: label
        )
        return value.isEmpty ? nil : value
    }
}

private func nuxieRuntimeBoundedCount(
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

private func nuxieRuntimeCheckedRange(
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

private func nuxieRuntimePresence(
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

private func nuxieRuntimeInstanceID(
    _ value: UInt64,
    label: String
) throws -> ExperienceRuntimeInstanceID {
    guard let identifier = ExperienceRuntimeInstanceID(rawValue: value) else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned reserved zero for \(label)"
        )
    }
    return identifier
}

private func copyNuxieScreenSessionSurfaceDisposition(
    _ rawValue: UInt32
) throws -> ExperienceRuntimeSurfaceDisposition {
    let disposition = nuxieRuntimeSurfaceDisposition(rawValue)
    if case .unknown = disposition {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned unknown surface disposition \(rawValue)"
        )
    }
    return disposition
}

private func copyNuxieScreenSessionWakeAfter(
    from result: OpaquePointer
) throws -> TimeInterval? {
    var seconds = 0.0
    switch nux_screen_session_result_wake_after_seconds(result, &seconds) {
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

private func copyNuxieScreenSessionValueArena(
    from result: OpaquePointer,
    budget: inout NuxieScreenSessionSessionCopyBudget
) throws -> ExperienceRuntimeValueArena {
    let nodeCount = try nuxieRuntimeBoundedCount(
        nux_screen_session_result_value_node_count(result),
        maximum: ScreenSessionLimits.valueNodes,
        label: "value nodes"
    )
    let edgeCount = try nuxieRuntimeBoundedCount(
        nux_screen_session_result_value_edge_count(result),
        maximum: ScreenSessionLimits.valueEdges,
        label: "value edges"
    )
    var edges: [ExperienceRuntimeValueEdge] = []
    edges.reserveCapacity(edgeCount)
    for index in 0..<edgeCount {
        var edge = NuxScreenValueEdge(
            struct_size: UInt32(MemoryLayout<NuxScreenValueEdge>.size),
            node_index: 0,
            key: NuxByteView(data: nil, len: 0)
        )
        guard nux_screen_session_result_value_edge_at(result, UInt64(index), &edge)
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
            maximum: ScreenSessionLimits.pathBytes,
            label: "value edge key"
        )
        edges.append(ExperienceRuntimeValueEdge(
            key: key.isEmpty ? nil : key,
            nodeIndex: Int(edge.node_index)
        ))
    }

    var nodes: [ExperienceRuntimeValueNode] = []
    nodes.reserveCapacity(nodeCount)
    for index in 0..<nodeCount {
        var node = NuxScreenValueNode(
            struct_size: UInt32(MemoryLayout<NuxScreenValueNode>.size),
            kind: UInt32(NUX_SCREEN_VALUE_KIND_NULL),
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
        guard nux_screen_session_result_value_node_at(result, UInt64(index), &node)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime value node \(index) could not be read"
            )
        }
        nodes.append(try copyNuxieScreenSessionValueNode(
            node,
            flatEdges: edges,
            index: index,
            budget: &budget
        ))
    }

    let rootCount = try nuxieRuntimeBoundedCount(
        nux_screen_session_result_value_root_count(result),
        maximum: ScreenSessionLimits.instances,
        label: "value roots"
    )
    var roots: [ExperienceRuntimeValueRoot] = []
    roots.reserveCapacity(rootCount)
    for index in 0..<rootCount {
        var root = NuxScreenValueRootView(
            struct_size: UInt32(MemoryLayout<NuxScreenValueRootView>.size),
            value_root_index: 0,
            instance_id: 0
        )
        guard nux_screen_session_result_value_root_at(result, UInt64(index), &root)
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
        roots.append(ExperienceRuntimeValueRoot(
            instanceID: try nuxieRuntimeInstanceID(root.instance_id, label: "value root instance"),
            nodeIndex: Int(root.value_root_index)
        ))
    }

    let arena = ExperienceRuntimeValueArena(nodes: nodes, roots: roots)
    do {
        try arena.validate()
        try validateNuxieScreenSessionEntireGraph(arena)
        try validateNuxieScreenSessionValueRootBindings(arena)
    } catch {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned an invalid value arena: \(error.localizedDescription)"
        )
    }
    return arena
}

private func validateNuxieScreenSessionValueRootBindings(
    _ arena: ExperienceRuntimeValueArena
) throws {
    for root in arena.roots {
        guard case .viewModel(_, let nodeInstanceID, _) = arena.nodes[root.nodeIndex].value,
              nodeInstanceID == root.instanceID else {
            throw ScreenSessionValueError.invalidGraph(
                "Runtime value root does not identify its view-model node"
            )
        }
    }
}

private func validateNuxieScreenSessionCatalogValueBindings(
    catalog: ExperienceRuntimeCatalog,
    arena: ExperienceRuntimeValueArena
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

/// The result arena is shared by value snapshots and typed output payloads.
/// An absent values field may therefore retain nodes, but it cannot expose
/// instance roots because roots unambiguously constitute a value snapshot.
func validateNuxieScreenSessionValuesPresence(
    _ arena: ExperienceRuntimeValueArena,
    isPresent: Bool
) throws {
    guard isPresent || arena.roots.isEmpty else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native result returned value roots without marking them present"
        )
    }
}

/// Validates relationships that are otherwise lost when the ABI's flattened
/// catalog records become nested Swift values.
func validateNuxieScreenSessionCatalogShape(
    _ catalog: ExperienceRuntimeCatalog,
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
            if property.kind == .enumeration {
                guard Set(property.enumValues).count == property.enumValues.count else {
                    throw NuxieRuntimeAdapterError.invalidNativeResult(
                        "native catalog enum property \(property.propertyID) has duplicate authored labels"
                    )
                }
            } else if !property.enumValues.isEmpty {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native catalog non-enum property \(property.propertyID) has enum labels"
                )
            }
            if property.kind == .viewModel {
                guard property.referencedSchemaID != nil else {
                    throw NuxieRuntimeAdapterError.invalidNativeResult(
                        "native catalog view-model property \(property.propertyID) has no referenced schema"
                    )
                }
            } else if property.referencedSchemaID != nil {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native catalog non-view-model property \(property.propertyID) has a referenced schema"
                )
            }
        }
    }

    for schema in catalog.schemas {
        for property in schema.properties {
            if let referencedSchemaID = property.referencedSchemaID,
               !schemaIDs.contains(referencedSchemaID) {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native catalog property \(property.propertyID) references missing schema \(referencedSchemaID)"
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

private func copyNuxieScreenSessionValueNode(
    _ node: NuxScreenValueNode,
    flatEdges: [ExperienceRuntimeValueEdge],
    index: Int,
    budget: inout NuxieScreenSessionSessionCopyBudget
) throws -> ExperienceRuntimeValueNode {
    let edgeRange = try nuxieRuntimeCheckedRange(
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
        maximum: ScreenSessionLimits.stringBytes,
        label: "value node string"
    )
    let schemaID = try budget.copyOptionalIdentifier(
        node.schema_id,
        label: "value node schema ID"
    )
    let hasInstanceID = try nuxieRuntimePresence(
        node.has_instance_id,
        label: "value node instance ID"
    )
    let instanceID: ExperienceRuntimeInstanceID?
    if hasInstanceID {
        instanceID = try nuxieRuntimeInstanceID(node.instance_id, label: "value node instance")
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

    let value: ExperienceRuntimeValue
    switch node.kind {
    case UInt32(NUX_SCREEN_VALUE_KIND_NULL):
        try requireNuxieScreenSessionScalarShape(
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
    case UInt32(NUX_SCREEN_VALUE_KIND_STRING):
        try requireNuxieScreenSessionScalarShape(
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
    case UInt32(NUX_SCREEN_VALUE_KIND_NUMBER):
        try requireNuxieScreenSessionScalarShape(
            node: node,
            index: index,
            numberIsValid: nuxieRuntimeResultNumberIsValid(node.number_value),
            stringIsValid: stringValue.isEmpty,
            allowsColor: false,
            allowsBool: false,
            allowsIdentity: false,
            edgeRange: edgeRange,
            schemaID: schemaID,
            instanceID: instanceID
        )
        value = .scalar(.number(node.number_value))
    case UInt32(NUX_SCREEN_VALUE_KIND_BOOL):
        try requireNuxieScreenSessionScalarShape(
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
    case UInt32(NUX_SCREEN_VALUE_KIND_ENUM):
        try requireNuxieScreenSessionScalarShape(
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
    case UInt32(NUX_SCREEN_VALUE_KIND_LIST_INDEX):
        try requireNuxieScreenSessionScalarShape(
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
        value = .scalar(.listIndex(node.identity_value))
    case UInt32(NUX_SCREEN_VALUE_KIND_COLOR):
        try requireNuxieScreenSessionScalarShape(
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
    case UInt32(NUX_SCREEN_VALUE_KIND_IMAGE):
        try requireNuxieScreenSessionScalarShape(
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
    case UInt32(NUX_SCREEN_VALUE_KIND_OBJECT):
        guard hasCanonicalCompositeScalars, instanceID == nil else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime object node \(index) has noncanonical scalar fields"
            )
        }
        try requireNuxieScreenSessionNamedEdges(edges, nodeIndex: index)
        value = .object(schemaID: schemaID, fields: edges)
    case UInt32(NUX_SCREEN_VALUE_KIND_VIEW_MODEL):
        guard hasCanonicalCompositeScalars else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime view-model node \(index) has noncanonical scalar fields"
            )
        }
        try requireNuxieScreenSessionNamedEdges(edges, nodeIndex: index)
        value = .viewModel(schemaID: schemaID, instanceID: instanceID, fields: edges)
    case UInt32(NUX_SCREEN_VALUE_KIND_LIST):
        guard hasCanonicalCompositeScalars,
              schemaID == nil,
              instanceID == nil,
              edges.allSatisfy({ $0.key == nil }) else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime list node \(index) has noncanonical fields"
            )
        }
        guard edges.count <= ScreenSessionLimits.listItems else {
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
    return ExperienceRuntimeValueNode(value: value)
}

/// Result arenas use the ABI's f64 number domain. This is intentionally wider
/// than outbound state mutations, which remain bounded to the runtime's f32
/// property representation at the encoding seam.
func nuxieRuntimeResultNumberIsValid(_ value: Double) -> Bool {
    value.isFinite
}

private func requireNuxieScreenSessionScalarShape(
    node: NuxScreenValueNode,
    index: Int,
    numberIsValid: Bool,
    stringIsValid: Bool,
    allowsColor: Bool,
    allowsBool: Bool,
    allowsIdentity: Bool,
    edgeRange: Range<Int>,
    schemaID: String?,
    instanceID: ExperienceRuntimeInstanceID?
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

private func requireNuxieScreenSessionNamedEdges(
    _ edges: [ExperienceRuntimeValueEdge],
    nodeIndex: Int
) throws {
    var keys = Set<Data>()
    for edge in edges {
        guard let key = edge.key, keys.insert(Data(key.utf8)).inserted else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime composite node \(nodeIndex) has a missing or duplicate key"
            )
        }
    }
}

private func validateNuxieScreenSessionEntireGraph(
    _ arena: ExperienceRuntimeValueArena
) throws {
    var state = Array(repeating: UInt8(0), count: arena.nodes.count)
    var heights = Array(repeating: 0, count: arena.nodes.count)

    func visit(_ index: Int, depth: Int) throws -> Int {
        guard depth <= ScreenSessionLimits.valueDepth else {
            throw ScreenSessionValueError.limitExceeded(
                "Runtime value graph depth limit exceeded"
            )
        }
        switch state[index] {
        case 1:
            throw ScreenSessionValueError.invalidGraph(
                "Runtime value graph contains a cycle"
            )
        case 2:
            return heights[index]
        default:
            state[index] = 1
        }
        let edges: [ExperienceRuntimeValueEdge]
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
            guard height <= ScreenSessionLimits.valueDepth else {
                throw ScreenSessionValueError.limitExceeded(
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

private func copyNuxieScreenSessionCatalog(
    from result: OpaquePointer,
    arena: ExperienceRuntimeValueArena,
    budget: inout NuxieScreenSessionSessionCopyBudget
) throws -> ExperienceRuntimeCatalog {
    struct CopiedEnumLabel {
        let value: UInt32
        let label: String
    }

    let enumLabelCount = try nuxieRuntimeBoundedCount(
        nux_screen_session_result_enum_label_count(result),
        maximum: ScreenSessionLimits.batchItems,
        label: "enum labels"
    )
    var enumLabels: [CopiedEnumLabel] = []
    enumLabels.reserveCapacity(enumLabelCount)
    for index in 0..<enumLabelCount {
        var enumLabel = NuxScreenEnumLabelView(
            struct_size: UInt32(MemoryLayout<NuxScreenEnumLabelView>.size),
            value: 0,
            label: NuxByteView(data: nil, len: 0)
        )
        guard nux_screen_session_result_enum_label_at(
            result,
            UInt64(index),
            &enumLabel
        ) == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime enum label \(index) could not be read"
            )
        }
        enumLabels.append(CopiedEnumLabel(
            value: enumLabel.value,
            label: try budget.copyString(
                enumLabel.label,
                maximum: ScreenSessionLimits.stringBytes,
                label: "enum label"
            )
        ))
    }

    let propertyCount = try nuxieRuntimeBoundedCount(
        nux_screen_session_result_schema_property_count(result),
        maximum: ScreenSessionLimits.batchItems,
        label: "schema properties"
    )
    var properties: [ExperienceRuntimeSchemaProperty] = []
    properties.reserveCapacity(propertyCount)
    var coveredEnumLabelIndexes = Set<Int>()
    for index in 0..<propertyCount {
        var property = NuxScreenSchemaPropertyView(
            struct_size: UInt32(MemoryLayout<NuxScreenSchemaPropertyView>.size),
            kind: UInt32(NUX_SCREEN_SCHEMA_PROPERTY_KIND_NULL),
            schema_id: NuxByteView(data: nil, len: 0),
            property_id: NuxByteView(data: nil, len: 0),
            name: NuxByteView(data: nil, len: 0),
            referenced_schema_id: NuxByteView(data: nil, len: 0),
            first_enum_label: 0,
            enum_label_count: 0
        )
        guard nux_screen_session_result_schema_property_at(
            result,
            UInt64(index),
            &property
        ) == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime schema property \(index) could not be read"
            )
        }
        let kind = try copyNuxieScreenSessionSchemaPropertyKind(property.kind)
        let enumRange = try nuxieRuntimeCheckedRange(
            start: property.first_enum_label,
            count: property.enum_label_count,
            upperBound: enumLabels.count,
            label: "enum-label range for schema property \(index)"
        )
        if enumRange.isEmpty {
            guard property.first_enum_label == 0 else {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native runtime schema property \(index) has a noncanonical empty enum-label span"
                )
            }
        } else {
            guard kind == .enumeration else {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native runtime non-enum schema property \(index) has enum labels"
                )
            }
            for (offset, enumIndex) in enumRange.enumerated() {
                guard coveredEnumLabelIndexes.insert(enumIndex).inserted,
                      enumLabels[enumIndex].value == UInt32(offset) else {
                    throw NuxieRuntimeAdapterError.invalidNativeResult(
                        "native runtime schema property \(index) has overlapping or noncanonical enum labels"
                    )
                }
            }
        }
        properties.append(ExperienceRuntimeSchemaProperty(
            schemaID: try budget.copyRequiredIdentifier(
                property.schema_id,
                label: "schema property schema ID"
            ),
            propertyID: try budget.copyRequiredIdentifier(
                property.property_id,
                label: "schema property ID"
            ),
            name: try budget.copyRequiredIdentifier(
                property.name,
                label: "schema property name"
            ),
            kind: kind,
            enumValues: enumRange.map { enumLabels[$0].label },
            referencedSchemaID: try budget.copyOptionalIdentifier(
                property.referenced_schema_id,
                label: "referenced schema ID"
            )
        ))
    }
    guard coveredEnumLabelIndexes.count == enumLabels.count else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned enum labels outside every schema property"
        )
    }

    let schemaCount = try nuxieRuntimeBoundedCount(
        nux_screen_session_result_schema_count(result),
        maximum: ScreenSessionLimits.instances,
        label: "schemas"
    )
    var schemas: [ExperienceRuntimeSchema] = []
    schemas.reserveCapacity(schemaCount)
    var coveredPropertyIndexes = Set<Int>()
    for index in 0..<schemaCount {
        var schema = NuxScreenSchemaView(
            struct_size: UInt32(MemoryLayout<NuxScreenSchemaView>.size),
            first_property: 0,
            property_count: 0,
            schema_id: NuxByteView(data: nil, len: 0),
            name: NuxByteView(data: nil, len: 0)
        )
        guard nux_screen_session_result_schema_at(result, UInt64(index), &schema)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime schema \(index) could not be read"
            )
        }
        let schemaID = try budget.copyRequiredIdentifier(
            schema.schema_id,
            label: "schema ID"
        )
        let range = try nuxieRuntimeCheckedRange(
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
        schemas.append(ExperienceRuntimeSchema(
            id: schemaID,
            name: try budget.copyString(
                schema.name,
                maximum: ScreenSessionLimits.identifierBytes,
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

    let templateCount = try nuxieRuntimeBoundedCount(
        nux_screen_session_result_instance_template_count(result),
        maximum: ScreenSessionLimits.instances,
        label: "instance templates"
    )
    var templates: [ExperienceRuntimeInstanceTemplate] = []
    templates.reserveCapacity(templateCount)
    for index in 0..<templateCount {
        var template = NuxScreenInstanceTemplateView(
            struct_size: UInt32(MemoryLayout<NuxScreenInstanceTemplateView>.size),
            authored_index: 0,
            schema_id: NuxByteView(data: nil, len: 0),
            authored_name: NuxByteView(data: nil, len: 0)
        )
        guard nux_screen_session_result_instance_template_at(
            result,
            UInt64(index),
            &template
        ) == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime instance template \(index) could not be read"
            )
        }
        templates.append(ExperienceRuntimeInstanceTemplate(
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

    let instanceCount = try nuxieRuntimeBoundedCount(
        nux_screen_session_result_instance_count(result),
        maximum: ScreenSessionLimits.instances,
        label: "instances"
    )
    var instances: [ExperienceRuntimeInstance] = []
    instances.reserveCapacity(instanceCount)
    var instanceIDs = Set<ExperienceRuntimeInstanceID>()
    for index in 0..<instanceCount {
        var instance = NuxScreenInstanceView(
            struct_size: UInt32(MemoryLayout<NuxScreenInstanceView>.size),
            value_root_index: UInt32.max,
            is_root: 0,
            instance_id: 0,
            schema_id: NuxByteView(data: nil, len: 0),
            name: NuxByteView(data: nil, len: 0)
        )
        guard nux_screen_session_result_instance_at(result, UInt64(index), &instance)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime instance \(index) could not be read"
            )
        }
        let instanceID = try nuxieRuntimeInstanceID(
            instance.instance_id,
            label: "catalog instance"
        )
        guard instanceIDs.insert(instanceID).inserted else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime returned duplicate catalog instance ID \(instance.instance_id)"
            )
        }
        let isRoot = try nuxieRuntimePresence(instance.is_root, label: "root instance")
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
        instances.append(ExperienceRuntimeInstance(
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

    return ExperienceRuntimeCatalog(
        schemas: schemas,
        templates: templates,
        instances: instances
    )
}

private func copyNuxieScreenSessionSchemaPropertyKind(
    _ rawValue: UInt32
) throws -> ExperienceRuntimeSchemaPropertyKind {
    switch rawValue {
    case UInt32(NUX_SCREEN_SCHEMA_PROPERTY_KIND_NULL): .null
    case UInt32(NUX_SCREEN_SCHEMA_PROPERTY_KIND_STRING): .string
    case UInt32(NUX_SCREEN_SCHEMA_PROPERTY_KIND_NUMBER): .number
    case UInt32(NUX_SCREEN_SCHEMA_PROPERTY_KIND_BOOL): .bool
    case UInt32(NUX_SCREEN_SCHEMA_PROPERTY_KIND_TRIGGER): .trigger
    case UInt32(NUX_SCREEN_SCHEMA_PROPERTY_KIND_ENUM): .enumeration
    case UInt32(NUX_SCREEN_SCHEMA_PROPERTY_KIND_LIST_INDEX): .listIndex
    case UInt32(NUX_SCREEN_SCHEMA_PROPERTY_KIND_COLOR): .color
    case UInt32(NUX_SCREEN_SCHEMA_PROPERTY_KIND_IMAGE): .image
    case UInt32(NUX_SCREEN_SCHEMA_PROPERTY_KIND_VIEW_MODEL): .viewModel
    case UInt32(NUX_SCREEN_SCHEMA_PROPERTY_KIND_LIST): .list
    case UInt32(NUX_SCREEN_SCHEMA_PROPERTY_KIND_OBJECT): .object
    default:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned unknown schema property kind \(rawValue)"
        )
    }
}

private func copyNuxieScreenSessionPlayerMetadata(
    from result: OpaquePointer,
    budget: inout NuxieScreenSessionSessionCopyBudget
) throws -> ExperienceRuntimePlayerMetadata? {
    var metadata = NuxScreenPlayerMetadataView(
        struct_size: UInt32(MemoryLayout<NuxScreenPlayerMetadataView>.size),
        kind: UInt32(NUX_SCREEN_PLAYER_KIND_STATIC),
        selection: UInt32(NUX_SCREEN_PLAYER_SELECTION_STATIC),
        player_index: UInt32.max,
        artboard_name: NuxByteView(data: nil, len: 0),
        player_name: NuxByteView(data: nil, len: 0),
        min_x: 0,
        min_y: 0,
        max_x: 0,
        max_y: 0
    )
    switch nux_screen_session_result_player_metadata(result, &metadata) {
    case NUX_STATUS_NOT_FOUND:
        return nil
    case NUX_STATUS_OK:
        break
    case let status:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime player metadata accessor failed with status \(status)"
        )
    }

    let kind: ExperienceRuntimePlayerKind
    switch metadata.kind {
    case UInt32(NUX_SCREEN_PLAYER_KIND_STATE_MACHINE): kind = .stateMachine
    case UInt32(NUX_SCREEN_PLAYER_KIND_LINEAR_ANIMATION): kind = .linearAnimation
    case UInt32(NUX_SCREEN_PLAYER_KIND_STATIC): kind = .staticArtboard
    default:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned unknown player kind \(metadata.kind)"
        )
    }
    let selection: ExperienceRuntimePlayerSelection
    switch metadata.selection {
    case UInt32(NUX_SCREEN_PLAYER_SELECTION_EXPLICIT_STATE_MACHINE):
        selection = .explicitStateMachine
    case UInt32(NUX_SCREEN_PLAYER_SELECTION_AUTHORED_DEFAULT_STATE_MACHINE):
        selection = .authoredDefaultStateMachine
    case UInt32(NUX_SCREEN_PLAYER_SELECTION_FIRST_STATE_MACHINE):
        selection = .firstStateMachine
    case UInt32(NUX_SCREEN_PLAYER_SELECTION_FIRST_ANIMATION):
        selection = .firstAnimation
    case UInt32(NUX_SCREEN_PLAYER_SELECTION_STATIC):
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

    let bounds = ExperienceRuntimeArtboardBounds(
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
    return ExperienceRuntimePlayerMetadata(
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

private func copyNuxieScreenSessionPlayerInputs(
    from result: OpaquePointer,
    arena: ExperienceRuntimeValueArena,
    budget: inout NuxieScreenSessionSessionCopyBudget
) throws -> [ExperienceRuntimePlayerInput] {
    let count = try nuxieRuntimeBoundedCount(
        nux_screen_session_result_player_input_count(result),
        maximum: ScreenSessionLimits.batchItems,
        label: "player inputs"
    )
    var inputs: [ExperienceRuntimePlayerInput] = []
    inputs.reserveCapacity(count)
    for index in 0..<count {
        var input = NuxScreenPlayerInputView(
            struct_size: UInt32(MemoryLayout<NuxScreenPlayerInputView>.size),
            kind: UInt32(NUX_SCREEN_PLAYER_INPUT_KIND_BOOL),
            value_root_index: 0,
            name: NuxByteView(data: nil, len: 0)
        )
        guard nux_screen_session_result_player_input_at(result, UInt64(index), &input)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime player input \(index) could not be read"
            )
        }
        let kind: ExperienceRuntimePlayerInputKind
        switch input.kind {
        case UInt32(NUX_SCREEN_PLAYER_INPUT_KIND_BOOL): kind = .bool
        case UInt32(NUX_SCREEN_PLAYER_INPUT_KIND_NUMBER): kind = .number
        case UInt32(NUX_SCREEN_PLAYER_INPUT_KIND_TRIGGER): kind = .trigger
        default:
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime player input \(index) has unknown kind \(input.kind)"
            )
        }
        let value = try nuxieRuntimeScalarValue(
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
        inputs.append(ExperienceRuntimePlayerInput(
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

private func nuxieRuntimeScalarValue(
    at rawIndex: UInt32,
    in arena: ExperienceRuntimeValueArena,
    label: String
) throws -> ExperienceRuntimeScalarValue {
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

private struct NuxieScreenSessionCopiedEventProperty {
    let name: String?
    let valueRootIndex: UInt32?
    let triggerCount: UInt64?
}

private func copyNuxieScreenSessionEventProperties(
    from result: OpaquePointer,
    budget: inout NuxieScreenSessionSessionCopyBudget
) throws -> [NuxieScreenSessionCopiedEventProperty] {
    let maximum = ScreenSessionLimits.outputs
        * ScreenSessionLimits.eventProperties
    let count = try nuxieRuntimeBoundedCount(
        nux_screen_session_result_event_property_count(result),
        maximum: maximum,
        label: "event properties"
    )
    var properties: [NuxieScreenSessionCopiedEventProperty] = []
    properties.reserveCapacity(count)
    for index in 0..<count {
        var property = NuxScreenEventPropertyView(
            struct_size: UInt32(MemoryLayout<NuxScreenEventPropertyView>.size),
            value_root_index: UInt32.max,
            has_trigger_count: 0,
            trigger_count: 0,
            name: NuxByteView(data: nil, len: 0)
        )
        guard nux_screen_session_result_event_property_at(
            result,
            UInt64(index),
            &property
        ) == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime event property \(index) could not be read"
            )
        }
        let hasTrigger = try nuxieRuntimePresence(
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
        properties.append(NuxieScreenSessionCopiedEventProperty(
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

private func copyNuxieScreenSessionOutputs(
    from result: OpaquePointer,
    arena: ExperienceRuntimeValueArena,
    budget: inout NuxieScreenSessionSessionCopyBudget
) throws -> [ExperienceRuntimeOutput] {
    let eventProperties = try copyNuxieScreenSessionEventProperties(
        from: result,
        budget: &budget
    )
    let count = try nuxieRuntimeBoundedCount(
        nux_screen_session_result_output_count(result),
        maximum: ScreenSessionLimits.outputs,
        label: "outputs"
    )
    var outputs: [ExperienceRuntimeOutput] = []
    outputs.reserveCapacity(count)
    var priorSequence: UInt64?
    var priorCycleAndPhase: (UInt64, ExperienceRuntimeOutputPhase)?
    var coveredEventProperties = Set<Int>()

    for index in 0..<count {
        var output = NuxScreenOutputView(
            struct_size: UInt32(MemoryLayout<NuxScreenOutputView>.size),
            phase: UInt32(NUX_SCREEN_OUTPUT_PHASE_DELAYED_EVENT_CALLBACKS),
            kind: UInt32(NUX_SCREEN_OUTPUT_KIND_REPORTED_EVENT),
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
            payload: NuxByteView(data: nil, len: 0),
            has_open_url: 0,
            open_url: NuxByteView(data: nil, len: 0),
            open_url_target: NuxByteView(data: nil, len: 0)
        )
        guard nux_screen_session_result_output_at(result, UInt64(index), &output)
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

        let phase = try copyNuxieScreenSessionOutputPhase(output.phase)
        if let (priorCycle, priorPhase) = priorCycleAndPhase,
           output.cycle < priorCycle
            || (output.cycle == priorCycle && phase.rawValue < priorPhase.rawValue) {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime output cycle or phase regressed"
            )
        }
        priorCycleAndPhase = (output.cycle, phase)

        let hasOriginMutation = try nuxieRuntimePresence(
            output.has_origin_mutation_id,
            label: "output origin mutation ID"
        )
        if !hasOriginMutation, output.origin_mutation_id != 0 {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime output has an origin mutation ID without presence"
            )
        }
        let originMutationID = hasOriginMutation ? output.origin_mutation_id : nil

        let hasInstance = try nuxieRuntimePresence(
            output.has_instance_id,
            label: "output instance ID"
        )
        let instanceID: ExperienceRuntimeInstanceID?
        if hasInstance {
            instanceID = try nuxieRuntimeInstanceID(
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
            maximum: ScreenSessionLimits.identifierBytes,
            label: "output name"
        )
        let path = try budget.copyString(
            output.path,
            maximum: ScreenSessionLimits.pathBytes,
            label: "output path"
        )
        let opaquePayload = try budget.copyData(
            output.payload,
            maximum: ScreenSessionLimits.encodedPayloadBytes,
            label: "output payload"
        )
        let hasOpenURL = try nuxieRuntimePresence(
            output.has_open_url,
            label: "output OpenURL"
        )
        if !hasOpenURL,
           output.open_url.data != nil
            || output.open_url.len != 0
            || output.open_url_target.data != nil
            || output.open_url_target.len != 0 {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime output has OpenURL fields without presence"
            )
        }
        let openURL: ExperienceRuntimeOpenURL?
        if hasOpenURL {
            let target = try budget.copyString(
                output.open_url_target,
                maximum: ScreenSessionLimits.identifierBytes,
                label: "output OpenURL target"
            )
            try validateNuxieScreenSessionOpenURLTarget(target)
            openURL = ExperienceRuntimeOpenURL(
                url: try budget.copyString(
                    output.open_url,
                    maximum: ScreenSessionLimits.stringBytes,
                    label: "output OpenURL URL"
                ),
                target: target
            )
        } else {
            openURL = nil
        }
        if openURL != nil,
           output.kind != UInt32(NUX_SCREEN_OUTPUT_KIND_REPORTED_EVENT) {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime returned OpenURL fields on a non-event output"
            )
        }
        let propertyRange = try nuxieRuntimeCheckedRange(
            start: output.first_event_property,
            count: output.event_property_count,
            upperBound: eventProperties.count,
            label: "event-property range for output \(index)"
        )
        guard propertyRange.count <= ScreenSessionLimits.eventProperties else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime output \(index) exceeds the event-property limit"
            )
        }

        let payload: ExperienceRuntimeOutputPayload
        switch output.kind {
        case UInt32(NUX_SCREEN_OUTPUT_KIND_REPORTED_EVENT):
            guard instanceID == nil,
                  originMutationID == nil,
                  payloadRoot == nil,
                  path.isEmpty,
                  opaquePayload.isEmpty else {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native runtime reported-event output \(index) has unrelated fields"
                )
            }
            var copiedProperties: [ExperienceRuntimeEventProperty] = []
            copiedProperties.reserveCapacity(propertyRange.count)
            for propertyIndex in propertyRange {
                guard coveredEventProperties.insert(propertyIndex).inserted else {
                    throw NuxieRuntimeAdapterError.invalidNativeResult(
                        "native runtime event property \(propertyIndex) is shared by outputs"
                    )
                }
                let property = eventProperties[propertyIndex]
                let value: ExperienceRuntimeScalarValue
                if let triggerCount = property.triggerCount {
                    value = .trigger(triggerCount)
                } else if let root = property.valueRootIndex {
                    value = try nuxieRuntimeScalarValue(
                        at: root,
                        in: arena,
                        label: "event property \(propertyIndex)"
                    )
                } else {
                    throw NuxieRuntimeAdapterError.invalidNativeResult(
                        "native runtime event property \(propertyIndex) omitted its value"
                    )
                }
                copiedProperties.append(ExperienceRuntimeEventProperty(
                    name: property.name,
                    value: value
                ))
            }
            payload = .reportedEvent(
                name: name.isEmpty ? nil : name,
                eventType: output.event_type,
                delay: TimeInterval(output.delay_seconds),
                properties: copiedProperties,
                openURL: openURL
            )
        case UInt32(NUX_SCREEN_OUTPUT_KIND_STATE_CHANGE),
             UInt32(NUX_SCREEN_OUTPUT_KIND_VIEW_MODEL_CHANGE):
            let isViewModel = output.kind == UInt32(NUX_SCREEN_OUTPUT_KIND_VIEW_MODEL_CHANGE)
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
            let scalarValue: ExperienceRuntimeScalarValue?
            let viewModelReference: ExperienceRuntimeViewModelReference?
            if let payloadRoot {
                switch arena.nodes[Int(payloadRoot)].value {
                case .scalar:
                    scalarValue = try nuxieRuntimeScalarValue(
                        at: payloadRoot,
                        in: arena,
                        label: "state-change output \(index)"
                    )
                    viewModelReference = nil
                case .viewModel(let schemaID, let referencedInstanceID, let fields):
                    guard isViewModel,
                          let schemaID,
                          !schemaID.isEmpty,
                          let referencedInstanceID,
                          fields.isEmpty else {
                        throw NuxieRuntimeAdapterError.invalidNativeResult(
                            "native runtime ViewModel reference output \(index) is incomplete or expanded"
                        )
                    }
                    scalarValue = nil
                    viewModelReference = ExperienceRuntimeViewModelReference(
                        schemaID: schemaID,
                        instanceID: referencedInstanceID
                    )
                case .object(_, _), .list(_):
                    throw NuxieRuntimeAdapterError.invalidNativeResult(
                        "native runtime state-change output \(index) has a composite payload"
                    )
                }
            } else {
                scalarValue = nil
                viewModelReference = nil
            }
            let change = ExperienceRuntimeStateChange(
                instanceID: instanceID,
                path: path,
                value: scalarValue,
                viewModelReference: viewModelReference,
                originMutationID: originMutationID
            )
            payload = isViewModel ? .viewModelChange(change) : .stateChange(change)
        case UInt32(NUX_SCREEN_OUTPUT_KIND_HOST_COMMAND):
            guard !name.isEmpty,
                  path.isEmpty,
                  propertyRange.isEmpty,
                  instanceID == nil,
                  originMutationID == nil,
                  output.event_type == 0,
                  output.delay_seconds.bitPattern == 0 else {
                throw NuxieRuntimeAdapterError.invalidNativeResult(
                    "native runtime host-command output \(index) has inconsistent fields"
                )
            }
            payload = try decodeNuxieScreenSessionHostCommand(
                name: name,
                payloadRoot: payloadRoot,
                opaquePayload: opaquePayload,
                arena: arena,
                outputIndex: index
            )
        case UInt32(NUX_SCREEN_OUTPUT_KIND_RENDER_REQUEST):
            try requireNuxieScreenSessionEmptyOutputFields(
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
        case UInt32(NUX_SCREEN_OUTPUT_KIND_RUNTIME_ADVANCED):
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
        try validateNuxieScreenSessionOutputPhase(
            phase,
            payload: payload,
            outputIndex: index
        )
        outputs.append(ExperienceRuntimeOutput(
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

/// ABI 1.4+ carries host commands in the shared result-owned value arena. The
/// opaque byte payload is required to remain empty.
func decodeNuxieScreenSessionHostCommand(
    name: String,
    payloadRoot: UInt32?,
    opaquePayload: Data,
    arena: ExperienceRuntimeValueArena,
    outputIndex: Int
) throws -> ExperienceRuntimeOutputPayload {
    guard !name.isEmpty, let payloadRoot, opaquePayload.isEmpty else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime host-command output \(outputIndex) omitted its typed object root"
        )
    }
    let hostValue: ExperienceRuntimeHostValue
    do {
        hostValue = try arena.hostValue(at: Int(payloadRoot))
    } catch {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime host-command output \(outputIndex) has an invalid value root"
        )
    }
    guard case .object = hostValue else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime host-command output \(outputIndex) does not have an object root"
        )
    }
    return .hostCommand(name: name, payload: hostValue)
}

func validateNuxieScreenSessionOutputPhase(
    _ phase: ExperienceRuntimeOutputPhase,
    payload: ExperienceRuntimeOutputPayload,
    outputIndex: Int
) throws {
    let expectedPhase: ExperienceRuntimeOutputPhase = switch payload {
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

func validateNuxieScreenSessionOpenURLTarget(_ target: String) throws {
    switch target {
    case "", "_blank", "_parent", "_self", "_top":
        return
    default:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned unsupported OpenURL target \(target)"
        )
    }
}

private func copyNuxieScreenSessionOutputPhase(
    _ rawValue: UInt32
) throws -> ExperienceRuntimeOutputPhase {
    switch rawValue {
    case UInt32(NUX_SCREEN_OUTPUT_PHASE_DELAYED_EVENT_CALLBACKS): .delayedEventCallbacks
    case UInt32(NUX_SCREEN_OUTPUT_PHASE_REPORTED_EVENTS): .reportedEvents
    case UInt32(NUX_SCREEN_OUTPUT_PHASE_RUNTIME_ADVANCE): .runtimeAdvance
    case UInt32(NUX_SCREEN_OUTPUT_PHASE_VIEW_MODEL_CHANGES): .viewModelChanges
    case UInt32(NUX_SCREEN_OUTPUT_PHASE_HOST_WORK): .hostWork
    case UInt32(NUX_SCREEN_OUTPUT_PHASE_RENDER): .render
    default:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned unknown output phase \(rawValue)"
        )
    }
}

private func requireNuxieScreenSessionEmptyOutputFields(
    outputIndex: Int,
    name: String,
    path: String,
    payload: Data,
    payloadRoot: UInt32?,
    propertyRange: Range<Int>,
    instanceID: ExperienceRuntimeInstanceID?,
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

private func copyNuxieScreenSessionCreatedInstances(
    from result: OpaquePointer
) throws -> [ExperienceRuntimeCreatedInstance] {
    let count = try nuxieRuntimeBoundedCount(
        nux_screen_session_result_created_instance_count(result),
        maximum: ScreenSessionLimits.instances,
        label: "created instances"
    )
    var createdInstances: [ExperienceRuntimeCreatedInstance] = []
    createdInstances.reserveCapacity(count)
    var localIDs = Set<UInt32>()
    var stableIDs = Set<ExperienceRuntimeInstanceID>()
    for index in 0..<count {
        var created = NuxScreenCreatedInstanceView(
            struct_size: UInt32(MemoryLayout<NuxScreenCreatedInstanceView>.size),
            local_id: 0,
            instance_id: 0
        )
        guard nux_screen_session_result_created_instance_at(
            result,
            UInt64(index),
            &created
        ) == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime created instance \(index) could not be read"
            )
        }
        let instanceID = try nuxieRuntimeInstanceID(
            created.instance_id,
            label: "created instance"
        )
        guard localIDs.insert(created.local_id).inserted,
              stableIDs.insert(instanceID).inserted else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime returned duplicate created-instance identities"
            )
        }
        createdInstances.append(ExperienceRuntimeCreatedInstance(
            localID: created.local_id,
            instanceID: instanceID
        ))
    }
    return createdInstances
}

private func copyNuxieScreenSessionSessionDiagnostics(
    from result: OpaquePointer,
    budget: inout NuxieScreenSessionSessionCopyBudget
) throws -> [ExperienceRuntimeDiagnostic] {
    let count = try nuxieRuntimeBoundedCount(
        nux_screen_session_result_diagnostic_count(result),
        maximum: 1_024,
        label: "session diagnostics"
    )
    var diagnostics: [ExperienceRuntimeDiagnostic] = []
    diagnostics.reserveCapacity(count)
    for index in 0..<count {
        var diagnostic = NuxDiagnosticView(
            struct_size: UInt32(MemoryLayout<NuxDiagnosticView>.size),
            severity: UInt32(NUX_DIAGNOSTIC_SEVERITY_DEBUG),
            code: NuxByteView(data: nil, len: 0),
            message: NuxByteView(data: nil, len: 0)
        )
        guard nux_screen_session_result_diagnostic_at(
            result,
            UInt64(index),
            &diagnostic
        ) == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime session diagnostic \(index) could not be read"
            )
        }
        let severity: ExperienceRuntimeDiagnostic.Severity
        switch diagnostic.severity {
        case UInt32(NUX_DIAGNOSTIC_SEVERITY_DEBUG): severity = .debug
        case UInt32(NUX_DIAGNOSTIC_SEVERITY_WARNING): severity = .warning
        case UInt32(NUX_DIAGNOSTIC_SEVERITY_FATAL): severity = .fatal
        default:
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime session diagnostic \(index) has unknown severity"
            )
        }
        diagnostics.append(ExperienceRuntimeDiagnostic(
            severity: severity,
            code: try budget.copyRequiredIdentifier(
                diagnostic.code,
                label: "session diagnostic code"
            ),
            message: try budget.copyString(
                diagnostic.message,
                maximum: ScreenSessionLimits.stringBytes,
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
    let renderOutcome: ExperienceRuntimeRenderOutcome
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
            ExperienceRuntimeDiagnostic(
                severity: .debug,
                code: "nux_runtime.ok",
                message: diagnosticMessage
            )
        ]
    }

    return NuxieRuntimeResultSnapshot(
        operationResult: ExperienceRuntimeOperationResult(
            renderOutcome: renderOutcome,
            surfaceDisposition: disposition,
            isDirty: changed,
            isSettled: !changed,
            orderedOutputs: [],
            diagnostics: diagnostics
        ),
        authenticatedKeyId: try copyNuxieRuntimeAuthenticatedKeyId(
            from: ownedResult
        )
    )
}

private func copyNuxieRuntimeAuthenticatedKeyId(
    from result: OpaquePointer
) throws -> String? {
    var keyIdView = NuxByteView(data: nil, len: 0)
    switch nux_operation_result_authenticated_key_id(result, &keyIdView) {
    case NUX_STATUS_NOT_FOUND:
        return nil
    case NUX_STATUS_OK:
        let keyId = try copyNuxieRuntimeUTF8(
            keyIdView,
            label: "authenticated key ID"
        )
        guard !keyId.isEmpty else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "authenticated import returned an empty key ID"
            )
        }
        return keyId
    case let status:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "could not read authenticated key ID (status \(status))"
        )
    }
}

private func copyNuxieRuntimeDiagnostics(
    from result: OpaquePointer
) throws -> [ExperienceRuntimeDiagnostic] {
    let count = nux_operation_result_diagnostic_count(result)
    guard count <= 1_024, count <= UInt64(Int.max) else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned too many diagnostics"
        )
    }
    var diagnostics: [ExperienceRuntimeDiagnostic] = []
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
        let severity: ExperienceRuntimeDiagnostic.Severity
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
            ExperienceRuntimeDiagnostic(
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
) -> ExperienceRuntimeDiagnostic {
    ExperienceRuntimeDiagnostic(
        severity: .fatal,
        code: "nux_runtime.\(nuxieRuntimeStatusCode(status))",
        message: message
    )
}

private func nuxieRuntimeStatusCode(_ rawValue: UInt32) -> String {
    switch nuxieRuntimeStatus(rawValue) {
    case .ok: "ok"
    case .nullArgument: "null_argument"
    case .importError: "import_error"
    case .notFound: "not_found"
    case .runtimeError: "runtime_error"
    case .invalidArgument: "invalid_argument"
    case .runtimeIdentityMismatch: "runtime_identity_mismatch"
    case .surfaceError: "surface_error"
    case .unknown(let value): "unknown_\(value)"
    }
}

func nuxieRuntimeSurfaceDisposition(
    _ rawValue: UInt32
) -> ExperienceRuntimeSurfaceDisposition {
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
