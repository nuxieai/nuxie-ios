import CoreFoundation
import Foundation

/// Canonical state work accepted by one screen's Rust runtime replica.
enum FlowRuntimeCanonicalStateInput {
    case snapshot(FlowViewModelSnapshot)
    case value(path: VmPathRef, value: Any, instanceID: String?)
    case trigger(path: VmPathRef, instanceID: String?)
    case list(
        operation: FlowViewModelListOperation,
        path: VmPathRef,
        payload: [String: Any],
        instanceID: String?
    )
}

enum FlowRuntimeStateBridgeError: LocalizedError, Equatable {
    case operationPending
    case invalidInput(String)
    case inconsistentResult(String)

    var errorDescription: String? {
        switch self {
        case .operationPending:
            "A canonical state batch is still awaiting its runtime result"
        case .invalidInput(let message), .inconsistentResult(let message):
            message
        }
    }
}

/// Owns identity, typing, and echo policy for one screen session.
///
/// Callers prepare at most one state batch at a time, perform it through the
/// serial runtime host, then pass the owned result to `reconcile`. Rust is a
/// typed replica; the injected coordinator remains the canonical value owner.
final class FlowRuntimeStateBridge {
    private struct RemoteInstance: Hashable {
        let id: String
        let schemaID: String
    }

    private struct PendingBatch {
        let mutationID: UInt64
        let expectedEchoes: [PendingEcho]
        let newInstances: [PendingNewInstance]
        let listCommits: [PendingListCommit]
        let preparedRemoteToRuntime: [RemoteInstance: FlowRuntimeInstanceID]
    }

    private struct PendingEcho: Equatable {
        let instance: FlowRuntimeInstanceReference?
        let path: String
        let value: FlowRuntimeScalarValue?
        let viewModelReference: FlowRuntimeInstanceReference?
    }

    private struct PendingNewInstance: Equatable {
        let localID: UInt32
        let remote: RemoteInstance
        let authoredName: String?
    }

    private struct ListKey: Hashable {
        let owner: FlowRuntimeInstanceID
        let path: String
    }

    private struct PendingListCommit: Equatable {
        let key: ListKey
        let items: [FlowRuntimeInstanceReference]
    }

    private struct PreparedCanonicalChange {
        let path: VmPathRef
        let value: Any
        let screenID: String
        let remoteInstanceID: String?
        let isTrigger: Bool
    }

    private struct ResolvedProperty {
        let kind: FlowRuntimeSchemaPropertyKind
        let enumValues: [String]
        let referencedSchemaID: String?

        init(_ property: FlowRuntimeSchemaProperty) {
            kind = property.kind
            enumValues = property.enumValues
            referencedSchemaID = property.referencedSchemaID
        }

        init(inferredKind: FlowRuntimeSchemaPropertyKind) {
            kind = inferredKind
            enumValues = []
            referencedSchemaID = nil
        }
    }

    private struct SnapshotOuterViewModelKey: Hashable {
        let ownerSchemaID: String
        let ownerRemoteID: String?
        let propertyPath: String
    }

    private let remoteFlow: RemoteFlow
    private let screen: RemoteFlowScreen
    private let coordinator: FlowViewModelStateCoordinator
    private let bootstrap: FlowRuntimeBootstrap
    private let imageIdentityResolver: FlowRuntimeImageIdentityResolver?
    private let schemasByID: [String: FlowRuntimeSchema]
    private let schemasByName: [String: [FlowRuntimeSchema]]
    private var instancesByID: [FlowRuntimeInstanceID: FlowRuntimeInstance]
    private var remoteToRuntime: [RemoteInstance: FlowRuntimeInstanceID] = [:]
    private var nextMutationID: UInt64 = 1
    private var nextLocalID: UInt32 = 1
    private var listItemsByKey: [ListKey: [FlowRuntimeInstanceID]] = [:]
    private var activeSnapshotSchemaIDsByRemoteID: [String: String] = [:]
    private var pending: PendingBatch?

    init(
        remoteFlow: RemoteFlow,
        screenID: String,
        bootstrap: FlowRuntimeBootstrap,
        coordinator: FlowViewModelStateCoordinator,
        imageIdentityResolver: FlowRuntimeImageIdentityResolver? = nil
    ) throws {
        guard let screen = remoteFlow.screens.first(where: { $0.id == screenID }) else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Remote flow has no screen named '\(screenID)'"
            )
        }
        let schemasByID = Dictionary(grouping: bootstrap.catalog.schemas, by: \.id)
        guard schemasByID.values.allSatisfy({ $0.count == 1 }) else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Runtime catalog contains duplicate schema IDs"
            )
        }
        let instancesByID = Dictionary(grouping: bootstrap.catalog.instances, by: \.id)
        guard instancesByID.values.allSatisfy({ $0.count == 1 }) else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Runtime catalog contains duplicate instance IDs"
            )
        }
        let roots = bootstrap.catalog.instances.filter(\.isRoot)
        guard roots.count <= 1 else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Runtime catalog contains more than one root instance"
            )
        }

        self.remoteFlow = remoteFlow
        self.screen = screen
        self.coordinator = coordinator
        self.bootstrap = bootstrap
        self.imageIdentityResolver = imageIdentityResolver
        self.schemasByID = schemasByID.mapValues { $0[0] }
        self.schemasByName = Dictionary(grouping: bootstrap.catalog.schemas, by: \.name)
        self.instancesByID = instancesByID.mapValues { $0[0] }

        if let root = roots.first {
            let defaultIdentity = screen.defaultViewModelName ?? root.schemaID
            let defaultSchema = try Self.resolveSchema(
                defaultIdentity,
                schemasByID: self.schemasByID,
                schemasByName: self.schemasByName
            )
            guard defaultSchema.id == root.schemaID else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Screen '\(screenID)' defaults to schema '\(defaultIdentity)' but the runtime root uses '\(root.schemaID)'"
                )
            }
            if let remoteID = screen.defaultInstanceId {
                remoteToRuntime[RemoteInstance(id: remoteID, schemaID: defaultSchema.id)] = root.id
            }
        }
    }

    func prepare(_ input: FlowRuntimeCanonicalStateInput) throws -> FlowRuntimeStateBatch {
        guard pending == nil else {
            throw FlowRuntimeStateBridgeError.operationPending
        }
        let committedRemoteToRuntime = remoteToRuntime
        let priorSnapshotSchemaIDs = activeSnapshotSchemaIDsByRemoteID
        defer {
            remoteToRuntime = committedRemoteToRuntime
            activeSnapshotSchemaIDsByRemoteID = priorSnapshotSchemaIDs
        }
        if case .snapshot(let snapshot) = input {
            activeSnapshotSchemaIDsByRemoteID = try snapshotSchemaIDsByRemoteID(snapshot)
        }
        let mutationID = try takeMutationID()
        let mutations: [FlowRuntimeStateMutation]
        var newInstances: [FlowRuntimeNewInstance] = []
        var pendingNewInstances: [PendingNewInstance] = []
        var listCommits: [PendingListCommit] = []
        switch input {
        case .snapshot(let snapshot):
            var snapshotMutations: [FlowRuntimeStateMutation] = []
            let normalizedValues = try normalizeOuterViewModelEnvelopes(snapshot.values)
            let orderedValues = normalizedValues.enumerated().sorted { lhs, rhs in
                let lhsComposite = isCompositeSnapshotValue(lhs.element.value.value)
                let rhsComposite = isCompositeSnapshotValue(rhs.element.value.value)
                return lhsComposite == rhsComposite
                    ? lhs.offset < rhs.offset
                    : lhsComposite && !rhsComposite
            }.map(\.element)
            for value in orderedValues {
                let schema = try resolveSchema(value.viewModelName)
                let reference = try resolveSnapshotReference(
                    remoteID: value.instanceId,
                    authoredName: value.instanceName,
                    schema: schema,
                    newInstances: &newInstances,
                    pendingNewInstances: &pendingNewInstances
                )
                snapshotMutations.append(contentsOf: try prepareCanonicalValue(
                    value.value.value,
                    path: value.path,
                    schema: schema,
                    reference: reference,
                    newInstances: &newInstances,
                    pendingNewInstances: &pendingNewInstances,
                    listCommits: &listCommits
                ))
            }
            mutations = snapshotMutations
        case .value(let path, let value, let remoteInstanceID):
            let target = try resolveTarget(path: path, remoteInstanceID: remoteInstanceID)
            mutations = try prepareCanonicalValue(
                value,
                path: path.path,
                schema: target.schema,
                reference: .existing(target.instanceID),
                newInstances: &newInstances,
                pendingNewInstances: &pendingNewInstances,
                listCommits: &listCommits
            )
        case .trigger(let path, let remoteInstanceID):
            let target = try resolveTarget(path: path, remoteInstanceID: remoteInstanceID)
            guard target.property.kind == .trigger else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Runtime property '\(path.path)' is not a trigger"
                )
            }
            mutations = [
                .fireTrigger(instance: .existing(target.instanceID), path: path.path),
            ]
        case .list(let operation, let path, let payload, let remoteInstanceID):
            mutations = try prepareListOperation(
                operation,
                path: path,
                payload: payload,
                remoteInstanceID: remoteInstanceID,
                newInstances: &newInstances,
                pendingNewInstances: &pendingNewInstances,
                listCommits: &listCommits
            )
        }
        pending = PendingBatch(
            mutationID: mutationID,
            expectedEchoes: mutations.compactMap(expectedEcho),
            newInstances: pendingNewInstances,
            listCommits: listCommits,
            preparedRemoteToRuntime: remoteToRuntime
        )
        return FlowRuntimeStateBatch(
            hostMutationID: mutationID,
            newInstances: newInstances,
            mutations: mutations
        )
    }

    private func prepareCanonicalValue(
        _ rawValue: Any,
        path: String,
        schema: FlowRuntimeSchema,
        reference: FlowRuntimeInstanceReference,
        newInstances: inout [FlowRuntimeNewInstance],
        pendingNewInstances: inout [PendingNewInstance],
        listCommits: inout [PendingListCommit]
    ) throws -> [FlowRuntimeStateMutation] {
        let property = try resolvePropertyForPossiblyNewInstance(
            path: path,
            schema: schema,
            reference: reference
        )
        switch property.kind {
        case .trigger:
            guard boolValue(unwrap(rawValue)) == true
                || unsignedValue(unwrap(rawValue)).map({ $0 != 0 }) == true else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Trigger value at '\(path)' is not truthy"
                )
            }
            return [.fireTrigger(instance: reference, path: path)]
        case .object:
            guard let values = dictionaryValue(rawValue) else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Composite runtime property '\(path)' requires an object value"
                )
            }
            var mutations: [FlowRuntimeStateMutation] = []
            for key in values.keys.sorted() {
                guard let child = values[key] else { continue }
                mutations.append(contentsOf: try prepareCanonicalValue(
                    child,
                    path: "\(path)/\(key)",
                    schema: schema,
                    reference: reference,
                    newInstances: &newInstances,
                    pendingNewInstances: &pendingNewInstances,
                    listCommits: &listCommits
                ))
            }
            return mutations
        case .viewModel:
            guard !path.contains("/"), case .existing(let ownerID) = reference else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Only outer ViewModel properties on settled instances can be replaced; '\(path)' is unsupported"
                )
            }
            guard var replacement = dictionaryValue(rawValue),
                  let referencedSchemaID = property.referencedSchemaID,
                  let referencedSchema = schemasByID[referencedSchemaID] else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "View-model property '\(path)' has no resolvable referenced schema"
                )
            }
            if let explicitSchemaIdentity = replacement["viewModelId"] as? String {
                let explicitSchema = try resolveSchema(explicitSchemaIdentity)
                guard explicitSchema.id == referencedSchema.id else {
                    throw FlowRuntimeStateBridgeError.invalidInput(
                        "View-model replacement at '\(path)' uses schema '\(explicitSchemaIdentity)' instead of '\(referencedSchema.name)'"
                    )
                }
            }
            replacement["viewModelId"] = referencedSchema.id
            let prepared = try prepareReferencedInstance(
                replacement,
                preferredExisting: currentNestedViewModelInstance(
                    owner: ownerID,
                    path: path
                ),
                newInstances: &newInstances,
                pendingNewInstances: &pendingNewInstances
            )
            return prepared.mutations + [
                .setViewModel(
                    instance: reference,
                    path: path,
                    value: prepared.reference
                ),
            ]
        case .list:
            guard case .existing(let ownerID) = reference else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "A new instance cannot own a list before settlement"
                )
            }
            guard let values = arrayValue(rawValue) else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Runtime list '\(path)' requires an array value"
                )
            }
            let key = ListKey(owner: ownerID, path: path)
            let current = try currentListItems(for: key)
            var finalItems: [FlowRuntimeInstanceReference] = []
            var mutations: [FlowRuntimeStateMutation] = [
                .listClear(instance: reference, path: path),
            ]
            for (index, value) in values.enumerated() {
                let preferred: FlowRuntimeInstanceID? = if current.indices.contains(index) {
                    if case .existing(let value) = current[index] { value } else { nil }
                } else {
                    nil
                }
                let item = try prepareReferencedInstance(
                    value,
                    preferredExisting: preferred,
                    newInstances: &newInstances,
                    pendingNewInstances: &pendingNewInstances
                )
                mutations.append(contentsOf: item.mutations)
                finalItems.append(item.reference)
                mutations.append(.listInsert(
                    instance: reference,
                    path: path,
                    index: UInt32(index),
                    item: item.reference
                ))
            }
            mutations.append(contentsOf: try listIndexMutations(
                for: finalItems,
                pendingNewInstances: pendingNewInstances
            ))
            listCommits.append(PendingListCommit(key: key, items: finalItems))
            return mutations
        case .string, .number, .bool, .enumeration, .listIndex, .color, .image:
            return [.setValue(
                instance: reference,
                path: path,
                value: try scalarValue(rawValue, property: property, path: path)
            )]
        case .null:
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Null runtime property '\(path)' cannot be assigned"
            )
        }
    }

    private func isCompositeSnapshotValue(_ rawValue: Any) -> Bool {
        dictionaryValue(rawValue) != nil || arrayValue(rawValue) != nil
    }

    private func currentNestedViewModelInstance(
        owner: FlowRuntimeInstanceID,
        path: String
    ) -> FlowRuntimeInstanceID? {
        guard let root = bootstrap.values.roots.first(where: {
            $0.instanceID == owner
        }), let nodeIndex = valueNodeIndex(
            path: path,
            rootIndex: root.nodeIndex,
            in: bootstrap.values
        ), case .viewModel(_, let instanceID, _) = bootstrap.values.nodes[nodeIndex].value else {
            return nil
        }
        return instanceID
    }

    private func snapshotSchemaIDsByRemoteID(
        _ snapshot: FlowViewModelSnapshot
    ) throws -> [String: String] {
        var schemaIDsByRemoteID: [String: String] = [:]
        for value in snapshot.values {
            guard let remoteID = value.instanceId else { continue }
            guard !remoteID.isEmpty else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Snapshot instance identity cannot be empty"
                )
            }
            let schemaID = try resolveSchema(value.viewModelName).id
            if let existing = schemaIDsByRemoteID[remoteID], existing != schemaID {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Snapshot instance '\(remoteID)' is associated with multiple schemas"
                )
            }
            schemaIDsByRemoteID[remoteID] = schemaID
        }
        return schemaIDsByRemoteID
    }

    /// The current publisher flattens every object leaf. Reassemble only a
    /// top-level authored ViewModel reference envelope so the outer property
    /// remains one identity-bearing replacement. Inner replacement cascades
    /// are deliberately outside this migration slice.
    private func normalizeOuterViewModelEnvelopes(
        _ values: [RemoteFlowViewModelValue]
    ) throws -> [RemoteFlowViewModelValue] {
        var keyByIndex: [Int: SnapshotOuterViewModelKey] = [:]
        var indexesByKey: [SnapshotOuterViewModelKey: [Int]] = [:]
        var identityBearingKeys = Set<SnapshotOuterViewModelKey>()
        var directValueKeys = Set<SnapshotOuterViewModelKey>()

        for (index, value) in values.enumerated() {
            let segments = value.path
                .split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)
            guard !segments.isEmpty, !segments.contains(where: \.isEmpty) else {
                continue
            }
            let schema = try resolveSchema(value.viewModelName)
            let matches = schema.properties.filter {
                $0.propertyID == segments[0] || $0.name == segments[0]
            }
            guard matches.count == 1, matches[0].kind == .viewModel else {
                continue
            }
            let key = SnapshotOuterViewModelKey(
                ownerSchemaID: schema.id,
                ownerRemoteID: value.instanceId,
                propertyPath: segments[0]
            )
            if segments.count == 1 {
                directValueKeys.insert(key)
                continue
            }
            keyByIndex[index] = key
            indexesByKey[key, default: []].append(index)
            if segments.count == 2,
               (segments[1] == "vmInstanceId" || segments[1] == "instanceId") {
                identityBearingKeys.insert(key)
            }
        }
        guard directValueKeys.isDisjoint(with: identityBearingKeys) else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Snapshot contains both direct and flattened values for one outer ViewModel property"
            )
        }

        var normalized: [RemoteFlowViewModelValue] = []
        normalized.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            guard let key = keyByIndex[index], identityBearingKeys.contains(key) else {
                normalized.append(value)
                continue
            }
            guard indexesByKey[key]?.first == index,
                  let groupedIndexes = indexesByKey[key] else {
                continue
            }

            let ownerNames = Set(groupedIndexes.map { values[$0].instanceName })
            guard ownerNames.count == 1 else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Flattened ViewModel envelope '\(key.propertyPath)' has conflicting owner names"
                )
            }
            var envelope: [String: Any] = [:]
            for groupedIndex in groupedIndexes {
                let grouped = values[groupedIndex]
                let segments = grouped.path.split(separator: "/").map(String.init)
                try insertFlattenedEnvelopeValue(
                    unwrap(grouped.value.value),
                    path: Array(segments.dropFirst()),
                    into: &envelope,
                    propertyPath: key.propertyPath
                )
            }
            let vmInstanceID = envelope["vmInstanceId"] as? String
            let instanceID = envelope["instanceId"] as? String
            if let vmInstanceID, let instanceID, vmInstanceID != instanceID {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Flattened ViewModel envelope '\(key.propertyPath)' has conflicting identities"
                )
            }
            guard let replacementID = vmInstanceID ?? instanceID,
                  !replacementID.isEmpty else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Flattened ViewModel envelope '\(key.propertyPath)' has no stable identity"
                )
            }
            normalized.append(RemoteFlowViewModelValue(
                viewModelName: value.viewModelName,
                instanceId: value.instanceId,
                instanceName: value.instanceName,
                path: key.propertyPath,
                value: AnyCodable(envelope)
            ))
        }
        return normalized
    }

    private func insertFlattenedEnvelopeValue(
        _ value: Any,
        path: [String],
        into envelope: inout [String: Any],
        propertyPath: String
    ) throws {
        guard let key = path.first, !key.isEmpty else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Flattened ViewModel envelope '\(propertyPath)' has an empty path"
            )
        }
        if path.count == 1 {
            guard envelope[key] == nil else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Flattened ViewModel envelope '\(propertyPath)' repeats '\(key)'"
                )
            }
            envelope[key] = value
            return
        }

        var nested: [String: Any]
        if let existing = envelope[key] {
            guard let dictionary = existing as? [String: Any] else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Flattened ViewModel envelope '\(propertyPath)' has conflicting '\(key)' values"
                )
            }
            nested = dictionary
        } else {
            nested = [:]
        }
        try insertFlattenedEnvelopeValue(
            value,
            path: Array(path.dropFirst()),
            into: &nested,
            propertyPath: propertyPath
        )
        envelope[key] = nested
    }

    private func resolveSnapshotReference(
        remoteID: String?,
        authoredName: String?,
        schema: FlowRuntimeSchema,
        newInstances: inout [FlowRuntimeNewInstance],
        pendingNewInstances: inout [PendingNewInstance]
    ) throws -> FlowRuntimeInstanceReference {
        guard let remoteID else {
            return .existing(try resolveInstance(remoteID: nil, schema: schema))
        }
        guard !remoteID.isEmpty else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Snapshot instance identity cannot be empty"
            )
        }
        let remote = RemoteInstance(id: remoteID, schemaID: schema.id)
        if let existing = remoteToRuntime[remote] {
            return .existing(existing)
        }
        if let pending = pendingNewInstances.first(where: { $0.remote == remote }) {
            return .new(localID: pending.localID)
        }
        guard !remoteToRuntime.keys.contains(where: {
            $0.id == remoteID && $0.schemaID != schema.id
        }), !pendingNewInstances.contains(where: {
            $0.remote.id == remoteID && $0.remote.schemaID != schema.id
        }) else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Remote instance '\(remoteID)' is associated with another schema"
            )
        }

        let unclaimed = instancesByID.values.filter {
            $0.schemaID == schema.id && !remoteToRuntime.values.contains($0.id)
        }
        if unclaimed.count == 1, let existing = unclaimed.first {
            remoteToRuntime[remote] = existing.id
            return .existing(existing.id)
        }

        let localID = try takeLocalID()
        let templateName = try authoredTemplateName(authoredName, schemaID: schema.id)
        newInstances.append(FlowRuntimeNewInstance(
            localID: localID,
            schemaName: schema.name,
            authoredInstanceName: templateName
        ))
        pendingNewInstances.append(PendingNewInstance(
            localID: localID,
            remote: remote,
            authoredName: templateName
        ))
        return .new(localID: localID)
    }

    private func prepareListOperation(
        _ operation: FlowViewModelListOperation,
        path: VmPathRef,
        payload: [String: Any],
        remoteInstanceID: String?,
        newInstances: inout [FlowRuntimeNewInstance],
        pendingNewInstances: inout [PendingNewInstance],
        listCommits: inout [PendingListCommit]
    ) throws -> [FlowRuntimeStateMutation] {
        let target = try resolveTarget(path: path, remoteInstanceID: remoteInstanceID)
        guard target.property.kind == .list else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Runtime property '\(path.path)' is not a list"
            )
        }
        let owner = FlowRuntimeInstanceReference.existing(target.instanceID)
        let key = ListKey(owner: target.instanceID, path: path.path)
        var items = try currentListItems(for: key)
        var mutations: [FlowRuntimeStateMutation] = []

        switch operation {
        case .insert:
            let preparedItem = try prepareReferencedInstance(
                payload["value"],
                newInstances: &newInstances,
                pendingNewInstances: &pendingNewInstances
            )
            mutations.append(contentsOf: preparedItem.mutations)
            let requested = try optionalInteger(payload["index"], label: "list insert index")
            let index = min(max(requested ?? items.count, 0), items.count)
            items.insert(preparedItem.reference, at: index)
            mutations.append(.listInsert(
                instance: owner,
                path: path.path,
                index: UInt32(index),
                item: preparedItem.reference
            ))
        case .remove:
            let index = try requiredInteger(payload["index"], label: "list remove index")
            guard items.indices.contains(index) else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "List remove index \(index) is out of range"
                )
            }
            items.remove(at: index)
            mutations.append(.listRemove(
                instance: owner,
                path: path.path,
                index: UInt32(index)
            ))
        case .swap:
            let first = try requiredInteger(
                payload["from"] ?? payload["indexA"],
                label: "list swap first index"
            )
            let second = try requiredInteger(
                payload["to"] ?? payload["indexB"],
                label: "list swap second index"
            )
            guard items.indices.contains(first), items.indices.contains(second) else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "List swap indexes \(first) and \(second) are out of range"
                )
            }
            items.swapAt(first, second)
            mutations.append(.listSwap(
                instance: owner,
                path: path.path,
                first: UInt32(first),
                second: UInt32(second)
            ))
        case .move:
            let from = try requiredInteger(payload["from"], label: "list move source index")
            let to = try requiredInteger(payload["to"], label: "list move destination index")
            guard items.indices.contains(from), to >= 0, to <= items.count else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "List move indexes \(from) and \(to) are out of range"
                )
            }
            let item = items.remove(at: from)
            let runtimeDestination = min(to, items.count)
            items.insert(item, at: runtimeDestination)
            mutations.append(.listMove(
                instance: owner,
                path: path.path,
                from: UInt32(from),
                to: UInt32(runtimeDestination)
            ))
        case .set:
            let index = try requiredInteger(payload["index"], label: "list set index")
            guard items.indices.contains(index) else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "List set index \(index) is out of range"
                )
            }
            let preparedItem = try prepareReferencedInstance(
                payload["value"],
                newInstances: &newInstances,
                pendingNewInstances: &pendingNewInstances
            )
            mutations.append(contentsOf: preparedItem.mutations)
            items[index] = preparedItem.reference
            mutations.append(.listSet(
                instance: owner,
                path: path.path,
                index: UInt32(index),
                item: preparedItem.reference
            ))
        case .clear:
            guard payload.isEmpty else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "List clear does not accept a payload"
                )
            }
            items.removeAll()
            mutations.append(.listClear(instance: owner, path: path.path))
        }
        mutations.append(contentsOf: try listIndexMutations(
            for: items,
            pendingNewInstances: pendingNewInstances
        ))
        listCommits.append(PendingListCommit(key: key, items: items))
        return mutations
    }

    private func listIndexMutations(
        for items: [FlowRuntimeInstanceReference],
        pendingNewInstances: [PendingNewInstance]
    ) throws -> [FlowRuntimeStateMutation] {
        var mutations: [FlowRuntimeStateMutation] = []
        for (index, reference) in items.enumerated() {
            let schemaID: String
            switch reference {
            case .existing(let instanceID):
                guard let instance = instancesByID[instanceID] else {
                    throw FlowRuntimeStateBridgeError.invalidInput(
                        "List item references unknown runtime instance \(instanceID.rawValue)"
                    )
                }
                schemaID = instance.schemaID
            case .new(let localID):
                guard let pending = pendingNewInstances.first(where: {
                    $0.localID == localID
                }) else {
                    throw FlowRuntimeStateBridgeError.invalidInput(
                        "List item references unknown transaction-local instance \(localID)"
                    )
                }
                schemaID = pending.remote.schemaID
            }
            guard let schema = schemasByID[schemaID] else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "List item schema '\(schemaID)' is missing from the runtime catalog"
                )
            }
            for property in schema.properties where property.kind == .listIndex {
                mutations.append(.setValue(
                    instance: reference,
                    path: property.name,
                    value: .listIndex(UInt64(index))
                ))
            }
        }
        return mutations
    }

    private func prepareReferencedInstance(
        _ rawValue: Any?,
        preferredExisting: FlowRuntimeInstanceID? = nil,
        newInstances: inout [FlowRuntimeNewInstance],
        pendingNewInstances: inout [PendingNewInstance]
    ) throws -> (
        reference: FlowRuntimeInstanceReference,
        mutations: [FlowRuntimeStateMutation]
    ) {
        guard let dictionary = dictionaryValue(rawValue),
              let remoteID = (dictionary["vmInstanceId"] as? String)
                ?? (dictionary["instanceId"] as? String),
              !remoteID.isEmpty else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "ViewModel references require a nonempty vmInstanceId for stable identity"
            )
        }
        if let vmInstanceID = dictionary["vmInstanceId"] as? String,
           let instanceID = dictionary["instanceId"] as? String,
           vmInstanceID != instanceID {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "ViewModel reference has conflicting stable identities"
            )
        }
        let hintedSchemaID = try schemaIDHint(for: remoteID)
        if let explicitSchemaIdentity = dictionary["viewModelId"] as? String,
           let hintedSchemaID,
           try resolveSchema(explicitSchemaIdentity).id != hintedSchemaID {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Remote instance '\(remoteID)' is associated with another schema"
            )
        }
        guard let schemaIdentity = (dictionary["viewModelId"] as? String)
            ?? hintedSchemaID else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "ViewModel reference '\(remoteID)' has no viewModelId"
            )
        }
        let schema = try resolveSchema(schemaIdentity)
        let remote = RemoteInstance(id: remoteID, schemaID: schema.id)
        let reference: FlowRuntimeInstanceReference
        if let existing = remoteToRuntime[remote] {
            reference = .existing(existing)
        } else if let pending = pendingNewInstances.first(where: { $0.remote == remote }) {
            reference = .new(localID: pending.localID)
        } else if let preferredExisting,
                  instancesByID[preferredExisting]?.schemaID == schema.id,
                  !remoteToRuntime.values.contains(preferredExisting) {
            remoteToRuntime[remote] = preferredExisting
            reference = .existing(preferredExisting)
        } else {
            guard !remoteToRuntime.keys.contains(where: {
                $0.id == remoteID && $0.schemaID != schema.id
            }), !pendingNewInstances.contains(where: {
                $0.remote.id == remoteID && $0.remote.schemaID != schema.id
            }) else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Remote ViewModel reference '\(remoteID)' is associated with another schema"
                )
            }
            let localID = try takeLocalID()
            let authoredName = try authoredTemplateName(
                dictionary["instanceName"] as? String,
                schemaID: schema.id
            )
            newInstances.append(FlowRuntimeNewInstance(
                localID: localID,
                schemaName: schema.name,
                authoredInstanceName: authoredName
            ))
            pendingNewInstances.append(PendingNewInstance(
                localID: localID,
                remote: remote,
                authoredName: authoredName
            ))
            reference = .new(localID: localID)
        }

        let values = dictionaryValue(dictionary["values"] ?? dictionary) ?? [:]
        let metadataKeys: Set<String> = [
            "vmInstanceId", "instanceId", "viewModelId", "instanceName",
        ]
        var mutations: [FlowRuntimeStateMutation] = []
        for path in values.keys.filter({ !metadataKeys.contains($0) }).sorted() {
            guard let raw = values[path] else { continue }
            let property = try resolvePropertyForPossiblyNewInstance(
                path: path,
                schema: schema,
                reference: reference
            )
            if property.kind == .trigger {
                guard boolValue(unwrap(raw)) == true
                    || unsignedValue(unwrap(raw)).map({ $0 != 0 }) == true else {
                    throw FlowRuntimeStateBridgeError.invalidInput(
                        "Trigger value on referenced ViewModel at '\(path)' is not truthy"
                    )
                }
                mutations.append(.fireTrigger(instance: reference, path: path))
            } else {
                mutations.append(.setValue(
                    instance: reference,
                    path: path,
                    value: try scalarValue(raw, property: property, path: path)
                ))
            }
        }
        return (reference, mutations)
    }

    private func schemaIDHint(for remoteID: String) throws -> String? {
        var schemaIDs = Set<String>()
        if let snapshotSchemaID = activeSnapshotSchemaIDsByRemoteID[remoteID] {
            schemaIDs.insert(snapshotSchemaID)
        }
        for value in remoteFlow.viewModelValues ?? [] where value.instanceId == remoteID {
            schemaIDs.insert(try resolveSchema(value.viewModelName).id)
        }
        guard schemaIDs.count <= 1 else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Remote instance '\(remoteID)' is associated with multiple schemas"
            )
        }
        return schemaIDs.first
    }

    private func resolvePropertyForPossiblyNewInstance(
        path: String,
        schema: FlowRuntimeSchema,
        reference: FlowRuntimeInstanceReference
    ) throws -> ResolvedProperty {
        switch reference {
        case .existing(let instanceID):
            return try resolveProperty(path: path, schema: schema, instanceID: instanceID)
        case .new:
            guard !path.contains("/") else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "A newly created instance cannot validate nested path '\(path)' before settlement"
                )
            }
            let matches = schema.properties.filter {
                $0.propertyID == path || $0.name == path
            }
            guard matches.count == 1, let property = matches.first else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Schema '\(schema.name)' does not resolve property '\(path)' exactly once"
                )
            }
            return ResolvedProperty(property)
        }
    }

    private func authoredTemplateName(
        _ requested: String?,
        schemaID: String
    ) throws -> String? {
        guard let requested, !requested.isEmpty else { return nil }
        let matches = bootstrap.catalog.templates.filter {
            $0.schemaID == schemaID && $0.authoredName == requested
        }
        guard matches.count <= 1 else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Authored instance name '\(requested)' is ambiguous in schema '\(schemaID)'"
            )
        }
        return matches.isEmpty ? nil : requested
    }

    private func currentListItems(
        for key: ListKey
    ) throws -> [FlowRuntimeInstanceReference] {
        if let cached = listItemsByKey[key] {
            return cached.map(FlowRuntimeInstanceReference.existing)
        }
        guard let root = bootstrap.values.roots.first(where: {
            $0.instanceID == key.owner
        }), let nodeIndex = valueNodeIndex(
            path: key.path,
            rootIndex: root.nodeIndex,
            in: bootstrap.values
        ) else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Runtime list '\(key.path)' has no value snapshot"
            )
        }
        guard case .list(let edges) = bootstrap.values.nodes[nodeIndex].value else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Runtime value at '\(key.path)' is not a list"
            )
        }
        let identities = try edges.map { edge -> FlowRuntimeInstanceID in
            guard case .viewModel(_, let instanceID, _) = bootstrap.values.nodes[edge.nodeIndex].value,
                  let instanceID else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Runtime list '\(key.path)' contains an item without stable identity"
                )
            }
            return instanceID
        }
        listItemsByKey[key] = identities
        return identities.map(FlowRuntimeInstanceReference.existing)
    }

    private func valueNodeIndex(
        path: String,
        rootIndex: Int,
        in arena: FlowRuntimeValueArena
    ) -> Int? {
        guard arena.nodes.indices.contains(rootIndex) else { return nil }
        var nodeIndex = rootIndex
        for segment in path.split(separator: "/").map(String.init) {
            let edges: [FlowRuntimeValueEdge]
            switch arena.nodes[nodeIndex].value {
            case .object(_, let fields), .viewModel(_, _, let fields):
                edges = fields
            case .list(let items):
                guard let index = Int(segment), items.indices.contains(index) else { return nil }
                nodeIndex = items[index].nodeIndex
                guard arena.nodes.indices.contains(nodeIndex) else { return nil }
                continue
            case .scalar:
                return nil
            }
            guard let edge = edges.first(where: { $0.key == segment }) else { return nil }
            nodeIndex = edge.nodeIndex
            guard arena.nodes.indices.contains(nodeIndex) else { return nil }
        }
        return nodeIndex
    }

    private func dictionaryValue(_ rawValue: Any?) -> [String: Any]? {
        guard let rawValue else { return nil }
        let value = unwrap(rawValue)
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(unwrap)
        }
        if let dictionary = value as? [String: AnyCodable] {
            return dictionary.mapValues { unwrap($0.value) }
        }
        return nil
    }

    private func arrayValue(_ rawValue: Any) -> [Any]? {
        let value = unwrap(rawValue)
        if let array = value as? [Any] {
            return array.map(unwrap)
        }
        if let array = value as? [AnyCodable] {
            return array.map { unwrap($0.value) }
        }
        return nil
    }

    private func requiredInteger(_ rawValue: Any?, label: String) throws -> Int {
        guard let value = try optionalInteger(rawValue, label: label) else {
            throw FlowRuntimeStateBridgeError.invalidInput("\(label) is required")
        }
        return value
    }

    private func optionalInteger(_ rawValue: Any?, label: String) throws -> Int? {
        guard let rawValue else { return nil }
        let value = unwrap(rawValue)
        if value is Bool {
            throw FlowRuntimeStateBridgeError.invalidInput("\(label) must be an integer")
        }
        if let value = value as? Int { return value }
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue.rounded(.towardZero) == number.doubleValue,
           number.doubleValue >= Double(Int.min),
           number.doubleValue <= Double(Int.max) {
            return number.intValue
        }
        throw FlowRuntimeStateBridgeError.invalidInput("\(label) must be an integer")
    }

    private func takeLocalID() throws -> UInt32 {
        let value = nextLocalID
        guard value != 0 else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Transaction-local instance identity space is exhausted"
            )
        }
        nextLocalID = value == UInt32.max ? 0 : value + 1
        return value
    }

    /// Applies state-bearing outputs in their runtime order and returns the
    /// renderer-neutral changes that should be fanned out to journey handling.
    /// Exact direct echoes from the outstanding host batch are consumed once.
    func reconcile(
        _ result: FlowRuntimeOperationResult
    ) throws -> [FlowRendererViewModelChange] {
        let consumedPending = pending
        pending = nil

        var stagedInstancesByID = instancesByID
        var stagedRemoteToRuntime = consumedPending?.preparedRemoteToRuntime
            ?? remoteToRuntime
        var stagedListItemsByKey = listItemsByKey
        let settlements = try validateSettlements(
            result.createdInstances,
            pending: consumedPending,
            instancesByID: stagedInstancesByID
        )
        try stageSettlements(
            settlements,
            pending: consumedPending,
            instancesByID: &stagedInstancesByID,
            remoteToRuntime: &stagedRemoteToRuntime,
            listItemsByKey: &stagedListItemsByKey
        )
        var expected = consumedPending?.expectedEchoes ?? []
        var prepared: [PreparedCanonicalChange] = []
        prepared.reserveCapacity(result.orderedOutputs.count)

        for output in result.orderedOutputs {
            let change: FlowRuntimeStateChange
            switch output.payload {
            case .stateChange(let value), .viewModelChange(let value):
                change = value
            case .delayedEvent, .reportedEvent, .hostCommand, .renderRequest, .runtimeAdvanced:
                continue
            }

            if let mutationID = consumedPending?.mutationID,
               change.originMutationID == mutationID,
               let echoIndex = expected.firstIndex(where: {
                   exactEcho(
                       $0,
                       settlements: settlements,
                       instancesByID: stagedInstancesByID,
                       matches: change
                   )
               }) {
                expected.remove(at: echoIndex)
                continue
            }

            let firstSegment = change.path.split(separator: "/", maxSplits: 1)
                .first.map(String.init)
            if firstSegment == "safeArea" || firstSegment == "nuxieTextInputs" {
                continue
            }
            prepared.append(try prepareCanonicalChange(
                change,
                authoritativeValues: result.values,
                instancesByID: stagedInstancesByID,
                remoteToRuntime: stagedRemoteToRuntime,
                listItemsByKey: &stagedListItemsByKey
            ))
        }

        let snapshotBeforeApplying = coordinator.getSnapshot()
        var emitted: [FlowRendererViewModelChange] = []
        emitted.reserveCapacity(prepared.count)
        for change in prepared {
            guard coordinator.setValue(
                path: change.path,
                value: change.value,
                screenId: change.screenID,
                instanceId: change.remoteInstanceID
            ) else {
                coordinator.hydrate(snapshotBeforeApplying)
                throw FlowRuntimeStateBridgeError.inconsistentResult(
                    "Canonical coordinator rejected runtime path '\(change.path.path)'"
                )
            }
            emitted.append(FlowRendererViewModelChange(
                path: change.path,
                value: change.value,
                source: "runtime",
                screenId: change.screenID,
                instanceId: change.remoteInstanceID,
                isTrigger: change.isTrigger
            ))
        }
        instancesByID = stagedInstancesByID
        remoteToRuntime = stagedRemoteToRuntime
        listItemsByKey = stagedListItemsByKey
        return emitted
    }

    private func validateSettlements(
        _ created: [FlowRuntimeCreatedInstance],
        pending: PendingBatch?,
        instancesByID: [FlowRuntimeInstanceID: FlowRuntimeInstance]
    ) throws -> [UInt32: FlowRuntimeInstanceID] {
        let requested = pending?.newInstances ?? []
        let requestedIDs = Set(requested.map(\.localID))
        let createdIDs = Set(created.map(\.localID))
        guard requestedIDs.count == requested.count,
              createdIDs.count == created.count,
              requestedIDs == createdIDs else {
            throw FlowRuntimeStateBridgeError.inconsistentResult(
                "Runtime created-instance settlement does not match the pending state batch"
            )
        }
        let runtimeIDs = Set(created.map(\.instanceID))
        guard runtimeIDs.count == created.count,
              runtimeIDs.allSatisfy({ instancesByID[$0] == nil }) else {
            throw FlowRuntimeStateBridgeError.inconsistentResult(
                "Runtime created-instance settlement reuses a stable instance identity"
            )
        }
        return Dictionary(uniqueKeysWithValues: created.map {
            ($0.localID, $0.instanceID)
        })
    }

    private func stageSettlements(
        _ settlements: [UInt32: FlowRuntimeInstanceID],
        pending: PendingBatch?,
        instancesByID: inout [FlowRuntimeInstanceID: FlowRuntimeInstance],
        remoteToRuntime: inout [RemoteInstance: FlowRuntimeInstanceID],
        listItemsByKey: inout [ListKey: [FlowRuntimeInstanceID]]
    ) throws {
        guard let pending else { return }
        for requested in pending.newInstances {
            guard let runtimeID = settlements[requested.localID],
                  let schema = schemasByID[requested.remote.schemaID],
                  remoteToRuntime[requested.remote] == nil,
                  !remoteToRuntime.keys.contains(where: {
                      $0.id == requested.remote.id && $0.schemaID != requested.remote.schemaID
                  }) else {
                throw FlowRuntimeStateBridgeError.inconsistentResult(
                    "Created runtime instance could not settle remote identity '\(requested.remote.id)'"
                )
            }
            instancesByID[runtimeID] = FlowRuntimeInstance(
                id: runtimeID,
                schemaID: schema.id,
                name: requested.authoredName,
                isRoot: false,
                valueRootIndex: nil
            )
            remoteToRuntime[requested.remote] = runtimeID
        }
        for commit in pending.listCommits {
            listItemsByKey[commit.key] = try commit.items.map { reference in
                switch reference {
                case .existing(let instanceID):
                    return instanceID
                case .new(let localID):
                    guard let instanceID = settlements[localID] else {
                        throw FlowRuntimeStateBridgeError.inconsistentResult(
                            "List settlement references missing local instance \(localID)"
                        )
                    }
                    return instanceID
                }
            }
        }
    }

    /// Releases bridge bookkeeping after a state operation fails before
    /// returning an owned runtime result. The runtime batch is atomic, so no
    /// identity or canonical value can have settled in this case.
    func abandonPendingBatch() {
        pending = nil
    }

    private func expectedEcho(
        for mutation: FlowRuntimeStateMutation
    ) -> PendingEcho? {
        switch mutation {
        case .setValue(let instance, let path, let value):
            PendingEcho(
                instance: instance,
                path: path,
                value: value,
                viewModelReference: nil
            )
        case .setViewModel(let instance, let path, let replacement):
            PendingEcho(
                instance: instance,
                path: path,
                value: nil,
                viewModelReference: replacement
            )
        case .fireTrigger(let instance, let path):
            PendingEcho(
                instance: instance,
                path: path,
                value: nil,
                viewModelReference: nil
            )
        case .listInsert(let instance, let path, _, _),
             .listRemove(let instance, let path, _),
             .listSwap(let instance, let path, _, _),
             .listMove(let instance, let path, _, _),
             .listSet(let instance, let path, _, _),
             .listClear(let instance, let path):
            PendingEcho(
                instance: instance,
                path: path,
                value: nil,
                viewModelReference: nil
            )
        case .setInputBool(let name, let value):
            PendingEcho(
                instance: nil,
                path: name,
                value: .bool(value),
                viewModelReference: nil
            )
        case .setInputNumber(let name, let value):
            PendingEcho(
                instance: nil,
                path: name,
                value: .number(runtimeNumber(value) ?? value),
                viewModelReference: nil
            )
        case .fireInputTrigger(let name):
            PendingEcho(
                instance: nil,
                path: name,
                value: nil,
                viewModelReference: nil
            )
        }
    }

    private func exactEcho(
        _ expected: PendingEcho,
        settlements: [UInt32: FlowRuntimeInstanceID],
        instancesByID: [FlowRuntimeInstanceID: FlowRuntimeInstance],
        matches change: FlowRuntimeStateChange
    ) -> Bool {
        let expectedInstanceID = settledInstanceID(
            expected.instance,
            settlements: settlements
        )
        let expectedViewModelInstanceID = settledInstanceID(
            expected.viewModelReference,
            settlements: settlements
        )
        return expectedInstanceID == change.instanceID
            && expected.path == change.path
            && expected.value == change.value
            && expectedViewModelInstanceID == change.viewModelReference?.instanceID
            && (
                expectedViewModelInstanceID.map {
                    instancesByID[$0]?.schemaID == change.viewModelReference?.schemaID
                } ?? (change.viewModelReference == nil)
            )
    }

    private func settledInstanceID(
        _ reference: FlowRuntimeInstanceReference?,
        settlements: [UInt32: FlowRuntimeInstanceID]
    ) -> FlowRuntimeInstanceID? {
        switch reference {
        case .existing(let value):
            value
        case .new(let localID):
            settlements[localID]
        case .none:
            nil
        }
    }

    private func prepareCanonicalChange(
        _ change: FlowRuntimeStateChange,
        authoritativeValues: FlowRuntimeValueArena?,
        instancesByID: [FlowRuntimeInstanceID: FlowRuntimeInstance],
        remoteToRuntime: [RemoteInstance: FlowRuntimeInstanceID],
        listItemsByKey: inout [ListKey: [FlowRuntimeInstanceID]]
    ) throws -> PreparedCanonicalChange {
        let runtimeInstance: FlowRuntimeInstance
        if let instanceID = change.instanceID {
            guard let instance = instancesByID[instanceID] else {
                throw FlowRuntimeStateBridgeError.inconsistentResult(
                    "Runtime change references unknown instance \(instanceID.rawValue)"
                )
            }
            runtimeInstance = instance
        } else {
            let roots = instancesByID.values.filter(\.isRoot)
            guard roots.count == 1, let root = roots.first else {
                throw FlowRuntimeStateBridgeError.inconsistentResult(
                    "Instance-free runtime change has no unambiguous root"
                )
            }
            runtimeInstance = root
        }
        guard let schema = schemasByID[runtimeInstance.schemaID] else {
            throw FlowRuntimeStateBridgeError.inconsistentResult(
                "Runtime instance \(runtimeInstance.id.rawValue) has unknown schema '\(runtimeInstance.schemaID)'"
            )
        }
        let property = try resolveProperty(
            path: change.path,
            schema: schema,
            instanceID: runtimeInstance.id
        )
        let remoteMatches = remoteToRuntime.filter { $0.value == runtimeInstance.id }
            .map(\.key)
        guard remoteMatches.count <= 1 else {
            throw FlowRuntimeStateBridgeError.inconsistentResult(
                "Runtime instance \(runtimeInstance.id.rawValue) maps to multiple remote identities"
            )
        }
        let remote = remoteMatches.first
        let canonicalPath = VmPathRef(
            viewModelName: remote?.schemaID ?? schema.name,
            path: change.path
        )
        let remoteInstanceID = remote?.id
            ?? (runtimeInstance.isRoot ? screen.defaultInstanceId : nil)
        let value: Any
        let isTrigger = property.kind == .trigger
        if let reference = change.viewModelReference {
            guard change.value == nil else {
                throw FlowRuntimeStateBridgeError.inconsistentResult(
                    "Runtime ViewModel change at '\(change.path)' also carries a scalar value"
                )
            }
            guard property.kind == .viewModel,
                  !change.path.contains("/"),
                  property.referencedSchemaID == reference.schemaID else {
                throw FlowRuntimeStateBridgeError.inconsistentResult(
                    "Runtime ViewModel reference at '\(change.path)' does not match the outer catalog property"
                )
            }
            guard let referencedInstance = instancesByID[reference.instanceID],
                  referencedInstance.schemaID == reference.schemaID else {
                throw FlowRuntimeStateBridgeError.inconsistentResult(
                    "Runtime ViewModel reference at '\(change.path)' uses an unknown or mismatched instance"
                )
            }
            guard let authoritativeValues else {
                throw FlowRuntimeStateBridgeError.inconsistentResult(
                    "Runtime ViewModel change at '\(change.path)' requires an authoritative value snapshot"
                )
            }
            try requireAuthoritativeViewModelReference(
                owner: runtimeInstance.id,
                path: change.path,
                reference: reference,
                values: authoritativeValues
            )
            let referencedRemoteMatches = remoteToRuntime.filter {
                $0.value == reference.instanceID
            }.map(\.key)
            guard referencedRemoteMatches.count == 1,
                  let referencedRemote = referencedRemoteMatches.first,
                  referencedRemote.schemaID == reference.schemaID else {
                throw FlowRuntimeStateBridgeError.inconsistentResult(
                    "Runtime ViewModel reference at '\(change.path)' has no single stable canonical identity"
                )
            }
            var envelope: [String: Any] = [
                "vmInstanceId": referencedRemote.id,
                "viewModelId": referencedRemote.schemaID,
            ]
            if let authoredName = referencedInstance.name {
                envelope["instanceName"] = authoredName
            }
            value = envelope
        } else if isTrigger {
            value = true
        } else if let scalar = change.value {
            value = try canonicalValue(scalar, expectedProperty: property, path: change.path)
        } else if property.kind == .list {
            guard let authoritativeValues else {
                throw FlowRuntimeStateBridgeError.inconsistentResult(
                    "Runtime list change at '\(change.path)' requires an authoritative value snapshot"
                )
            }
            let identities = try authoritativeListIdentities(
                owner: runtimeInstance.id,
                path: change.path,
                values: authoritativeValues,
                instancesByID: instancesByID
            )
            value = try canonicalListRows(
                identities: identities,
                path: canonicalPath,
                remoteInstanceID: remoteInstanceID,
                remoteToRuntime: remoteToRuntime
            )
            listItemsByKey[ListKey(owner: runtimeInstance.id, path: change.path)] = identities
        } else {
            throw FlowRuntimeStateBridgeError.inconsistentResult(
                "Runtime composite change at '\(change.path)' requires a value snapshot"
            )
        }

        return PreparedCanonicalChange(
            path: canonicalPath,
            value: value,
            screenID: screen.id,
            remoteInstanceID: remoteInstanceID,
            isTrigger: isTrigger
        )
    }

    private func requireAuthoritativeViewModelReference(
        owner: FlowRuntimeInstanceID,
        path: String,
        reference: FlowRuntimeViewModelReference,
        values: FlowRuntimeValueArena
    ) throws {
        let roots = values.roots.filter { $0.instanceID == owner }
        guard roots.count == 1,
              let root = roots.first,
              let nodeIndex = valueNodeIndex(
                  path: path,
                  rootIndex: root.nodeIndex,
                  in: values
              ),
              values.nodes.indices.contains(nodeIndex),
              case .viewModel(let schemaID, let instanceID, _) = values.nodes[nodeIndex].value,
              schemaID == reference.schemaID,
              instanceID == reference.instanceID else {
            throw FlowRuntimeStateBridgeError.inconsistentResult(
                "Authoritative runtime values do not match ViewModel reference '\(path)' for instance \(owner.rawValue)"
            )
        }
    }

    private func authoritativeListIdentities(
        owner: FlowRuntimeInstanceID,
        path: String,
        values: FlowRuntimeValueArena,
        instancesByID: [FlowRuntimeInstanceID: FlowRuntimeInstance]
    ) throws -> [FlowRuntimeInstanceID] {
        let roots = values.roots.filter { $0.instanceID == owner }
        guard roots.count == 1,
              let root = roots.first,
              let nodeIndex = valueNodeIndex(
                  path: path,
                  rootIndex: root.nodeIndex,
                  in: values
              ),
              case .list(let items) = values.nodes[nodeIndex].value else {
            throw FlowRuntimeStateBridgeError.inconsistentResult(
                "Authoritative runtime values do not contain list '\(path)' for instance \(owner.rawValue)"
            )
        }
        return try items.map { edge in
            guard values.nodes.indices.contains(edge.nodeIndex),
                  case .viewModel(let schemaID, let instanceID, _) = values.nodes[edge.nodeIndex].value,
                  let instanceID,
                  let instance = instancesByID[instanceID],
                  schemaID == nil || schemaID == instance.schemaID else {
                throw FlowRuntimeStateBridgeError.inconsistentResult(
                    "Authoritative runtime list '\(path)' contains an unknown or untyped instance"
                )
            }
            return instanceID
        }
    }

    private func canonicalListRows(
        identities: [FlowRuntimeInstanceID],
        path: VmPathRef,
        remoteInstanceID: String?,
        remoteToRuntime: [RemoteInstance: FlowRuntimeInstanceID]
    ) throws -> [[String: Any]] {
        guard let current = coordinator.getValue(
            path: path,
            screenId: screen.id,
            instanceId: remoteInstanceID
        ), let rawRows = arrayValue(current) else {
            if identities.isEmpty { return [] }
            throw FlowRuntimeStateBridgeError.inconsistentResult(
                "Canonical list '\(path.path)' has no rows to reconcile with runtime identities"
            )
        }

        var rowsByRemoteID: [String: [[String: Any]]] = [:]
        for rawRow in rawRows {
            guard let row = dictionaryValue(rawRow),
                  let remoteID = (row["vmInstanceId"] as? String)
                    ?? (row["instanceId"] as? String),
                  !remoteID.isEmpty else {
                throw FlowRuntimeStateBridgeError.inconsistentResult(
                    "Canonical list '\(path.path)' contains a row without stable identity"
                )
            }
            rowsByRemoteID[remoteID, default: []].append(row)
        }

        var rows: [[String: Any]] = []
        rows.reserveCapacity(identities.count)
        for identity in identities {
            let remoteMatches = remoteToRuntime.filter { $0.value == identity }
                .map(\.key)
            guard remoteMatches.count == 1, let remote = remoteMatches.first,
                  var candidates = rowsByRemoteID[remote.id], !candidates.isEmpty else {
                throw FlowRuntimeStateBridgeError.inconsistentResult(
                    "Runtime list '\(path.path)' references identity \(identity.rawValue) without one canonical row"
                )
            }
            rows.append(candidates.removeFirst())
            rowsByRemoteID[remote.id] = candidates
        }
        return rows
    }

    private func canonicalValue(
        _ value: FlowRuntimeScalarValue,
        expectedProperty: ResolvedProperty,
        path: String
    ) throws -> Any {
        switch (expectedProperty.kind, value) {
        case (.string, .string(let value)):
            return value
        case (.number, .number(let value)) where value.isFinite:
            return value
        case (.listIndex, .listIndex(let value)):
            return Double(value)
        case (.bool, .bool(let value)):
            return value
        case (.enumeration, .enumeration(let value)):
            guard value < UInt64(expectedProperty.enumValues.count) else {
                throw FlowRuntimeStateBridgeError.inconsistentResult(
                    "Runtime enum identity at '\(path)' has no authored label"
                )
            }
            return expectedProperty.enumValues[Int(value)]
        case (.image, .image(let value)):
            guard let lookupKey = imageIdentityResolver?.canonicalLookupKey(for: value) else {
                throw FlowRuntimeStateBridgeError.inconsistentResult(
                    "Runtime image identity at '\(path)' has no canonical authored key"
                )
            }
            return lookupKey
        case (.color, .color(let value)):
            return Int(value)
        case (.null, .null):
            return NSNull()
        default:
            throw FlowRuntimeStateBridgeError.inconsistentResult(
                "Runtime value at '\(path)' does not match catalog property kind '\(expectedProperty.kind)'"
            )
        }
    }

    private func takeMutationID() throws -> UInt64 {
        let value = nextMutationID
        guard value != 0 else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Host mutation identity space is exhausted"
            )
        }
        nextMutationID = value == UInt64.max ? 0 : value + 1
        return value
    }

    private func resolveSchema(_ identity: String) throws -> FlowRuntimeSchema {
        try Self.resolveSchema(
            identity,
            schemasByID: schemasByID,
            schemasByName: schemasByName
        )
    }

    private static func resolveSchema(
        _ identity: String,
        schemasByID: [String: FlowRuntimeSchema],
        schemasByName: [String: [FlowRuntimeSchema]]
    ) throws -> FlowRuntimeSchema {
        var matches: [FlowRuntimeSchema] = []
        if let byID = schemasByID[identity] {
            matches.append(byID)
        }
        matches.append(contentsOf: schemasByName[identity] ?? [])
        let unique = Dictionary(grouping: matches, by: \.id).values.compactMap(\.first)
        guard unique.count == 1, let schema = unique.first else {
            if unique.isEmpty {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Runtime catalog has no schema matching '\(identity)'"
                )
            }
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Runtime schema identity '\(identity)' is ambiguous"
            )
        }
        return schema
    }

    private func resolveInstance(
        remoteID: String?,
        schema: FlowRuntimeSchema
    ) throws -> FlowRuntimeInstanceID {
        if let remoteID,
           let existing = remoteToRuntime[RemoteInstance(id: remoteID, schemaID: schema.id)] {
            return existing
        }
        if let remoteID,
           remoteToRuntime.keys.contains(where: { $0.id == remoteID && $0.schemaID != schema.id }) {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Remote instance '\(remoteID)' was already associated with another schema"
            )
        }
        let candidates = instancesByID.values.filter {
            guard $0.schemaID == schema.id else { return false }
            return remoteID == nil || !remoteToRuntime.values.contains($0.id)
        }
        guard candidates.count == 1, let instance = candidates.first else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Schema '\(schema.name)' does not resolve to one live runtime instance"
            )
        }
        if let remoteID {
            remoteToRuntime[RemoteInstance(id: remoteID, schemaID: schema.id)] = instance.id
        }
        return instance.id
    }

    private func resolveTarget(
        path: VmPathRef,
        remoteInstanceID: String?
    ) throws -> (
        schema: FlowRuntimeSchema,
        instanceID: FlowRuntimeInstanceID,
        property: ResolvedProperty
    ) {
        let schemaIdentity: String
        if let explicit = path.viewModelName {
            schemaIdentity = explicit
        } else if let remoteInstanceID,
                  let hinted = remoteFlow.viewModelValues?.first(where: {
                      $0.instanceId == remoteInstanceID
                  })?.viewModelName {
            schemaIdentity = hinted
        } else if let screenDefault = screen.defaultViewModelName {
            schemaIdentity = screenDefault
        } else if let root = bootstrap.catalog.rootInstance {
            schemaIdentity = root.schemaID
        } else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Relative runtime path '\(path.path)' has no schema context"
            )
        }
        let schema = try resolveSchema(schemaIdentity)
        let instanceID = try resolveInstance(remoteID: remoteInstanceID, schema: schema)
        let property = try resolveProperty(
            path: path.path,
            schema: schema,
            instanceID: instanceID
        )
        return (schema, instanceID, property)
    }

    private func resolveProperty(
        path: String,
        schema: FlowRuntimeSchema,
        instanceID: FlowRuntimeInstanceID
    ) throws -> ResolvedProperty {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !segments.isEmpty, !segments.contains(where: \.isEmpty) else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Runtime property path '\(path)' is empty or malformed"
            )
        }
        let firstMatches = schema.properties.filter {
            $0.propertyID == segments[0] || $0.name == segments[0]
        }
        guard firstMatches.count == 1, let property = firstMatches.first else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Schema '\(schema.name)' does not resolve property '\(segments[0])' exactly once"
            )
        }
        if segments.count == 1 {
            return ResolvedProperty(property)
        }

        if let catalogProperty = resolveCatalogProperty(
            segments: segments,
            rootSchema: schema
        ) {
            return ResolvedProperty(catalogProperty)
        }

        guard let root = bootstrap.values.roots.first(where: {
            $0.instanceID == instanceID
        }) else {
            throw FlowRuntimeStateBridgeError.invalidInput(
                "Runtime instance \(instanceID.rawValue) has no value graph for nested path '\(path)'"
            )
        }
        var nodeIndex = root.nodeIndex
        for segment in segments {
            let edges: [FlowRuntimeValueEdge]
            switch bootstrap.values.nodes[nodeIndex].value {
            case .object(_, let fields), .viewModel(_, _, let fields):
                edges = fields
            case .list(let items):
                guard let index = Int(segment), items.indices.contains(index) else {
                    throw FlowRuntimeStateBridgeError.invalidInput(
                        "Runtime list path segment '\(segment)' is out of range in '\(path)'"
                    )
                }
                nodeIndex = items[index].nodeIndex
                continue
            case .scalar:
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Runtime path '\(path)' descends through a scalar value"
                )
            }
            let matches = edges.filter { $0.key == segment }
            guard matches.count == 1, let edge = matches.first else {
                throw FlowRuntimeStateBridgeError.invalidInput(
                    "Runtime value graph does not resolve '\(path)' exactly once"
                )
            }
            nodeIndex = edge.nodeIndex
        }
        return ResolvedProperty(
            inferredKind: propertyKind(for: bootstrap.values.nodes[nodeIndex].value)
        )
    }

    private func resolveCatalogProperty(
        segments: [String],
        rootSchema: FlowRuntimeSchema
    ) -> FlowRuntimeSchemaProperty? {
        var schema = rootSchema
        for (index, segment) in segments.enumerated() {
            let matches = schema.properties.filter {
                $0.propertyID == segment || $0.name == segment
            }
            guard matches.count == 1, let property = matches.first else {
                return nil
            }
            if index == segments.count - 1 {
                return property
            }
            guard property.kind == .viewModel,
                  let referencedSchemaID = property.referencedSchemaID,
                  let referencedSchema = schemasByID[referencedSchemaID] else {
                return nil
            }
            schema = referencedSchema
        }
        return nil
    }

    private func propertyKind(
        for value: FlowRuntimeValue
    ) -> FlowRuntimeSchemaPropertyKind {
        switch value {
        case .scalar(let scalar):
            switch scalar {
            case .null: .null
            case .string: .string
            case .number: .number
            case .bool: .bool
            case .enumeration: .enumeration
            case .listIndex: .listIndex
            case .color: .color
            case .image: .image
            case .trigger: .trigger
            }
        case .object: .object
        case .viewModel: .viewModel
        case .list: .list
        }
    }

    private func scalarValue(
        _ rawValue: Any,
        property: ResolvedProperty,
        path: String
    ) throws -> FlowRuntimeScalarValue {
        let value = unwrap(rawValue)
        switch property.kind {
        case .string:
            guard let value = value as? String else { break }
            return .string(value)
        case .number:
            guard let value = numberValue(value),
                  let runtimeValue = runtimeNumber(value) else { break }
            return .number(runtimeValue)
        case .bool:
            guard let value = boolValue(value) else { break }
            return .bool(value)
        case .enumeration:
            guard let label = value as? String else { break }
            let matches = property.enumValues.indices.filter {
                property.enumValues[$0] == label
            }
            guard matches.count == 1, let index = matches.first else { break }
            return .enumeration(UInt64(index))
        case .listIndex:
            guard let value = unsignedValue(value) else { break }
            return .listIndex(value)
        case .color:
            guard let value = unsignedValue(value), value <= UInt64(UInt32.max) else { break }
            return .color(UInt32(value))
        case .image:
            guard let lookupKey = value as? String,
                  let assetID = imageIdentityResolver?.resolve(lookupKey) else { break }
            return .image(assetID)
        case .trigger, .null, .viewModel, .list, .object:
            break
        }
        throw FlowRuntimeStateBridgeError.invalidInput(
            "Value at '\(path)' does not match runtime property kind '\(property.kind)'"
        )
    }

    private func unwrap(_ rawValue: Any) -> Any {
        if let value = rawValue as? AnyCodable {
            return unwrap(value.value)
        }
        if let literal = rawValue as? [String: Any],
           literal.count == 1,
           let value = literal["literal"] {
            return unwrap(value)
        }
        return rawValue
    }

    private func numberValue(_ value: Any) -> Double? {
        if value is Bool { return nil }
        return switch value {
        case let value as Int: Double(value)
        case let value as Int8: Double(value)
        case let value as Int16: Double(value)
        case let value as Int32: Double(value)
        case let value as Int64: Double(value)
        case let value as UInt: Double(value)
        case let value as UInt8: Double(value)
        case let value as UInt16: Double(value)
        case let value as UInt32: Double(value)
        case let value as UInt64: Double(value)
        case let value as Float: Double(value)
        case let value as Double: value
        case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID():
            value.doubleValue
        default: nil
        }
    }

    private func runtimeNumber(_ value: Double) -> Double? {
        let runtimeValue = Float(value)
        guard runtimeValue.isFinite else { return nil }
        return Double(runtimeValue)
    }

    private func boolValue(_ value: Any) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber,
           CFGetTypeID(value) == CFBooleanGetTypeID() {
            return value.boolValue
        }
        return nil
    }

    private func unsignedValue(_ value: Any) -> UInt64? {
        if value is Bool { return nil }
        return switch value {
        case let value as UInt64: value
        case let value as UInt: UInt64(value)
        case let value as UInt32: UInt64(value)
        case let value as UInt16: UInt64(value)
        case let value as UInt8: UInt64(value)
        case let value as Int where value >= 0: UInt64(value)
        case let value as Int64 where value >= 0: UInt64(value)
        case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID()
            && value.int64Value >= 0
            && value.doubleValue.rounded(.towardZero) == value.doubleValue:
            UInt64(value.int64Value)
        default: nil
        }
    }
}
