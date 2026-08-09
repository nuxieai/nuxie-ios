#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import Metal
import NuxieRuntime
import QuartzCore

/// Product-owned player policy. The native wrapper receives only the resolved
/// generic selector and never learns what a Nuxie screen means.
enum ExperienceInteractivePlayerSelection: Equatable, Sendable {
    case defaultScene
    case staticArtboard
    case stateMachine(String)
    case linearAnimation(String)
}

indirect enum ExperienceInteractiveValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case bytes(Data)
    case list([ExperienceInteractiveValue])
    case object([ExperienceInteractiveField])

    subscript(key: String) -> ExperienceInteractiveValue? {
        guard case .object(let fields) = self else { return nil }
        return fields.first(where: { $0.key == key })?.value
    }
}

struct ExperienceInteractiveField: Equatable, Sendable {
    let key: String
    let value: ExperienceInteractiveValue
}

struct ExperienceInteractiveReportedEvent: Equatable, Sendable {
    let localIndex: Int
    let coreType: UInt32
    let name: String
    let url: String
    let target: String
    let delay: Float
    let properties: [ExperienceInteractiveField]
}

struct ExperienceInteractiveStateChange: Equatable, Sendable {
    let layerIndex: Int
    let coreType: UInt32
    let globalID: UInt32?
}

enum ExperienceInteractiveViewModelValue: Equatable, Sendable {
    case unsupported
    case bytes(Data)
    case number(Float)
    case bool(Bool)
    case integer(UInt64)
    case referencedInstance(UInt64)
    case list([UInt64])
}

struct ExperienceInteractiveViewModelChange: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        case caller
        case runtime
    }

    let origin: Origin
    let correlationID: UInt64
    let ownerInstanceID: UInt64
    let propertyIndex: Int
    let value: ExperienceInteractiveViewModelValue
}

struct ExperienceInteractiveResolvedViewModelChange: Equatable, Sendable {
    let origin: ExperienceInteractiveViewModelChange.Origin
    let correlationID: UInt64
    let viewModelName: String
    let instanceID: String?
    let instanceName: String?
    let path: String
    let value: ExperienceInteractiveValue
    let isTrigger: Bool
}

struct ExperienceInteractiveViewModelReference: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt64

    init?(rawValue: UInt64) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

struct ExperienceInteractiveViewModelIdentity: Hashable, Sendable {
    let viewModelName: String
    let instanceID: String?
    let instanceName: String?

    init(
        viewModelName: String,
        instanceID: String?,
        instanceName: String? = nil
    ) {
        self.viewModelName = viewModelName
        self.instanceID = instanceID
        self.instanceName = instanceName
    }
}

enum ExperienceInteractiveStateMutation: Equatable, Sendable {
    case setString(ExperienceInteractiveViewModelReference, path: String, value: Data)
    case setNumber(ExperienceInteractiveViewModelReference, path: String, value: Float)
    case setBool(ExperienceInteractiveViewModelReference, path: String, value: Bool)
    case setColor(ExperienceInteractiveViewModelReference, path: String, value: UInt32)
    case setEnumeration(ExperienceInteractiveViewModelReference, path: String, value: UInt64)
    case fireTrigger(ExperienceInteractiveViewModelReference, path: String)
    case setListIndex(ExperienceInteractiveViewModelReference, path: String, value: UInt64)
    case setImage(ExperienceInteractiveViewModelReference, path: String, value: UInt64)
    case setViewModel(
        ExperienceInteractiveViewModelReference,
        path: String,
        value: ExperienceInteractiveViewModelReference
    )
    case listInsert(
        ExperienceInteractiveViewModelReference,
        path: String,
        index: Int,
        value: ExperienceInteractiveViewModelReference
    )
    case listRemove(ExperienceInteractiveViewModelReference, path: String, index: Int)
    case listSwap(
        ExperienceInteractiveViewModelReference,
        path: String,
        first: Int,
        second: Int
    )
    case listMove(
        ExperienceInteractiveViewModelReference,
        path: String,
        from: Int,
        to: Int
    )
    case listSet(
        ExperienceInteractiveViewModelReference,
        path: String,
        index: Int,
        value: ExperienceInteractiveViewModelReference
    )
    case listClear(ExperienceInteractiveViewModelReference, path: String)
}

struct ExperienceInteractiveMutationResult: Equatable, Sendable {
    let appliedCount: Int
    let correlationID: UInt64
    let effects: [ExperienceInteractiveEffect]
}

struct ExperienceInteractiveViewModelSnapshot: Equatable, Sendable {
    struct Instance: Equatable, Sendable {
        let id: UInt64
        let schemaIndex: Int
        let valueRange: Range<Int>
    }

    struct Value: Equatable, Sendable {
        let ownerInstanceID: UInt64
        let propertyIndex: Int
        let name: String
        let value: ExperienceInteractiveViewModelValue
    }

    let rootInstanceID: UInt64
    let instances: [Instance]
    let values: [Value]
}

struct ExperienceInteractiveHostCommand: Equatable, Sendable {
    let name: String
    let payload: ExperienceInteractiveValue
}

enum ExperienceInteractiveEffectKind: Equatable, Sendable {
    case reportedEvent(ExperienceInteractiveReportedEvent)
    case stateChange(ExperienceInteractiveStateChange)
    case viewModelChange(ExperienceInteractiveViewModelChange)
    case responseSet(field: String, value: ExperienceInteractiveValue)
    case journeyEvent(name: String, payload: ExperienceInteractiveValue)
    case navigate(screenID: String, transition: ExperienceInteractiveValue?)
    case hostCommand(name: String, payload: ExperienceInteractiveValue)
    case rejectedHostCommand(name: String, reason: String)
}

/// One monotonically ordered product effect. Callers route the returned array
/// only after the native transaction and the complete Swift projection both
/// succeed, preventing valid prefixes from escaping a failed operation.
struct ExperienceInteractiveEffect: Equatable, Sendable {
    let sequence: UInt64
    let correlationID: UInt64
    let kind: ExperienceInteractiveEffectKind
}

/// Serializes an async operation through its complete projection phase. An
/// actor alone is reentrant at `await`; this gate keeps a later native call
/// from overtaking the earlier call's product-side commit.
actor ExperienceInteractiveOperationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async rethrows -> Value {
        await acquire()
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}

struct ExperienceInteractiveStepResult: Equatable, Sendable {
    let keepGoing: Bool
    let pointerHits: [ExperienceInteractivePointerHit]
    let effects: [ExperienceInteractiveEffect]
}

enum ExperienceInteractiveInput: Equatable, Sendable {
    case bool(name: String, value: Bool)
    case number(name: String, value: Float)
    case trigger(name: String)
}

enum ExperienceInteractivePointerKind: Equatable, Sendable {
    case down
    case move
    case up
    case exit
}

struct ExperienceInteractivePointerEvent: Equatable, Sendable {
    let kind: ExperienceInteractivePointerKind
    let x: Float
    let y: Float
    let pointerID: Int32
    let timestamp: Float

    init(
        kind: ExperienceInteractivePointerKind,
        x: Float,
        y: Float,
        pointerID: Int32 = 0,
        timestamp: Float = 0
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.pointerID = pointerID
        self.timestamp = timestamp
    }
}

enum ExperienceInteractivePointerHit: Equatable, Sendable {
    case none
    case hit
    case opaque
}

struct ExperienceInteractiveMetalDevice: @unchecked Sendable {
    let value: any MTLDevice
}

struct ExperienceInteractiveDrawable: @unchecked Sendable {
    fileprivate let value: any CAMetalDrawable

    init(_ value: any CAMetalDrawable) {
        self.value = value
    }
}

enum ExperienceInteractiveRenderDisposition: Equatable, Sendable {
    case none
    case presented
    case skippedZeroSize
    case skippedTimeout
    case skippedOccluded
    case reconfigured
    case recreated
    case deviceLost
    case outOfMemory
}

enum ExperienceInteractiveRendererHealth: Equatable, Sendable {
    case healthy
    case deviceLost
    case outOfMemory
    case failed
}

struct ExperienceInteractiveRenderOutcome: Equatable, Sendable {
    let disposition: ExperienceInteractiveRenderDisposition
    let health: ExperienceInteractiveRendererHealth
    let pixelWidth: UInt32
    let pixelHeight: UInt32
    let drawCalls: UInt64
}

enum ExperienceInteractiveScreenError: Error, Equatable, Sendable {
    case screenNotFound(String)
    case journeyScreenNotFound(String)
    case invalidScreen(String)
    case assetContract(String)
    case stateContract(String)
    case textInputNotFound(String)
    case textInputNotEditable(String)
}

/// The product policy half of the module. It consumes generic native trees and
/// signed declaration sets without introducing a second protocol graph.
struct ExperienceInteractiveEffectRouter: Sendable {
    private(set) var nextSequence: UInt64 = 0

    mutating func project(
        reportedEvents: [ExperienceInteractiveReportedEvent],
        stateChanges: [ExperienceInteractiveStateChange] = [],
        viewModelChanges: [ExperienceInteractiveViewModelChange],
        hostCommands: [ExperienceInteractiveHostCommand],
        declaredEventNames: Set<String>,
        validScreenIDs: Set<String>,
        correlationID: UInt64
    ) -> [ExperienceInteractiveEffect] {
        var staged: [ExperienceInteractiveEffectKind] = []
        staged.reserveCapacity(
            reportedEvents.count + stateChanges.count
                + viewModelChanges.count + hostCommands.count
        )
        staged.append(contentsOf: reportedEvents.map {
            .reportedEvent($0)
        })
        staged.append(contentsOf: stateChanges.map {
            .stateChange($0)
        })
        staged.append(contentsOf: viewModelChanges.map {
            .viewModelChange($0)
        })
        staged.append(contentsOf: hostCommands.map {
            interpret(
                $0,
                declaredEventNames: declaredEventNames,
                validScreenIDs: validScreenIDs
            )
        })

        let firstSequence = nextSequence
        let effects = staged.enumerated().map { offset, kind in
            let effectCorrelation: UInt64
            if case .viewModelChange(let change) = kind {
                effectCorrelation = change.correlationID
            } else {
                effectCorrelation = correlationID
            }
            return ExperienceInteractiveEffect(
                sequence: firstSequence + UInt64(offset),
                correlationID: effectCorrelation,
                kind: kind
            )
        }
        nextSequence += UInt64(effects.count)
        return effects
    }

    private func interpret(
        _ command: ExperienceInteractiveHostCommand,
        declaredEventNames: Set<String>,
        validScreenIDs: Set<String>
    ) -> ExperienceInteractiveEffectKind {
        switch command.name {
        case SystemEventNames.responseSet:
            guard case .string(let field) = command.payload["field"],
                  !field.isEmpty,
                  let value = command.payload["value"] else {
                return .rejectedHostCommand(
                    name: command.name,
                    reason: "expected a non-empty string field and a value"
                )
            }
            return .responseSet(field: field, value: value)
        case "$navigate":
            guard case .string(let screenID) = command.payload["screenId"],
                  !screenID.isEmpty,
                  validScreenIDs.contains(screenID) else {
                return .rejectedHostCommand(
                    name: command.name,
                    reason: "expected a declared screenId"
                )
            }
            return .navigate(
                screenID: screenID,
                transition: command.payload["transition"]
            )
        default:
            if declaredEventNames.contains(command.name) {
                return .journeyEvent(name: command.name, payload: command.payload)
            }
            return .hostCommand(name: command.name, payload: command.payload)
        }
    }
}

struct ExperienceInteractiveListIdentity: Hashable, Sendable {
    let owner: ExperienceInteractiveViewModelReference
    let path: String
}

struct ExperienceInteractiveTrackedListPlanner: Sendable {
    private(set) var itemsByList:
        [ExperienceInteractiveListIdentity: [ExperienceInteractiveViewModelReference]]

    init(
        itemsByList:
            [ExperienceInteractiveListIdentity: [ExperienceInteractiveViewModelReference]] = [:]
    ) {
        self.itemsByList = itemsByList
    }

    mutating func replaceItems(
        _ replacements: [ExperienceInteractiveViewModelReference:
            ExperienceInteractiveViewModelReference],
        in identity: ExperienceInteractiveListIdentity
    ) {
        guard let items = itemsByList[identity] else { return }
        itemsByList[identity] = items.map { replacements[$0] ?? $0 }
    }

    mutating func replaceItems(
        _ replacements: [ExperienceInteractiveViewModelReference:
            ExperienceInteractiveViewModelReference]
    ) {
        var replaced: [ExperienceInteractiveListIdentity:
            [ExperienceInteractiveViewModelReference]] = [:]
        for (identity, items) in itemsByList {
            let newIdentity = ExperienceInteractiveListIdentity(
                owner: replacements[identity.owner] ?? identity.owner,
                path: identity.path
            )
            replaced[newIdentity] = items.map { replacements[$0] ?? $0 }
        }
        itemsByList = replaced
    }

    mutating func expand(
        _ mutations: [ExperienceInteractiveStateMutation],
        schemaIndexByReference: [ExperienceInteractiveViewModelReference: Int],
        listIndexPathsBySchema: [Int: [String]],
        settableReferences: Set<ExperienceInteractiveViewModelReference>
    ) throws -> [ExperienceInteractiveStateMutation] {
        var result: [ExperienceInteractiveStateMutation] = []
        for mutation in mutations {
            guard let update = try update(for: mutation) else {
                result.append(mutation)
                continue
            }
            result.append(update.mutation)
            itemsByList[update.identity] = update.items
            for (index, item) in update.items.enumerated() {
                guard let schemaIndex = schemaIndexByReference[item] else {
                    throw ExperienceInteractiveScreenError.stateContract(
                        "list row has no known view-model schema"
                    )
                }
                for path in listIndexPathsBySchema[schemaIndex, default: []] {
                    guard settableReferences.contains(item) else {
                        throw ExperienceInteractiveScreenError.stateContract(
                            "authored list row cannot be reindexed through the native API"
                        )
                    }
                    result.append(.setListIndex(item, path: path, value: UInt64(index)))
                }
            }
        }
        return result
    }

    private func update(
        for mutation: ExperienceInteractiveStateMutation
    ) throws -> (
        identity: ExperienceInteractiveListIdentity,
        items: [ExperienceInteractiveViewModelReference],
        mutation: ExperienceInteractiveStateMutation
    )? {
        let identity: ExperienceInteractiveListIdentity
        var items: [ExperienceInteractiveViewModelReference]
        var normalizedMutation = mutation
        switch mutation {
        case .listClear(let owner, let path):
            identity = ExperienceInteractiveListIdentity(owner: owner, path: path)
            items = []
        case .listInsert(let owner, let path, let index, let value):
            identity = ExperienceInteractiveListIdentity(owner: owner, path: path)
            items = try knownItems(identity)
            guard index >= 0, index <= items.count else { throw invalidIndex(path) }
            items.insert(value, at: index)
        case .listRemove(let owner, let path, let index):
            identity = ExperienceInteractiveListIdentity(owner: owner, path: path)
            items = try knownItems(identity)
            guard items.indices.contains(index) else { throw invalidIndex(path) }
            items.remove(at: index)
        case .listSwap(let owner, let path, let first, let second):
            identity = ExperienceInteractiveListIdentity(owner: owner, path: path)
            items = try knownItems(identity)
            guard items.indices.contains(first), items.indices.contains(second) else {
                throw invalidIndex(path)
            }
            items.swapAt(first, second)
        case .listMove(let owner, let path, let from, let to):
            identity = ExperienceInteractiveListIdentity(owner: owner, path: path)
            items = try knownItems(identity)
            guard items.indices.contains(from), to >= 0, to <= items.count else {
                throw invalidIndex(path)
            }
            let value = items.remove(at: from)
            let destination = min(to, items.count)
            items.insert(value, at: destination)
            normalizedMutation = .listMove(
                owner,
                path: path,
                from: from,
                to: destination
            )
        case .listSet(let owner, let path, let index, let value):
            identity = ExperienceInteractiveListIdentity(owner: owner, path: path)
            items = try knownItems(identity)
            guard items.indices.contains(index) else { throw invalidIndex(path) }
            items[index] = value
        case .setString, .setNumber, .setBool, .setColor, .setEnumeration,
             .fireTrigger, .setListIndex, .setImage, .setViewModel:
            return nil
        }
        return (identity, items, normalizedMutation)
    }

    private func knownItems(
        _ identity: ExperienceInteractiveListIdentity
    ) throws -> [ExperienceInteractiveViewModelReference] {
        guard let items = itemsByList[identity] else {
            throw ExperienceInteractiveScreenError.stateContract(
                "list '\(identity.path)' must be initialized or cleared before mutation"
            )
        }
        return items
    }

    private func invalidIndex(_ path: String) -> ExperienceInteractiveScreenError {
        .stateContract("list mutation index is out of range for '\(path)'")
    }
}

struct ExperienceInteractiveViewModelPropertyIdentity: Hashable, Sendable {
    let owner: ExperienceInteractiveViewModelReference
    let path: String
}

/// Carries caller-owned identities across the authoritative snapshot refresh
/// that follows a successful native transaction. Snapshot instance IDs are
/// runtime-local, so newly attached handles must be matched by their committed
/// inbound property rather than replaced with synthetic product identities.
struct ExperienceInteractiveMutationTopologyPreferences: Sendable {
    let viewModelsByProperty:
        [ExperienceInteractiveViewModelPropertyIdentity:
            ExperienceInteractiveViewModelReference]

    static let empty = ExperienceInteractiveMutationTopologyPreferences(
        viewModelsByProperty: [:]
    )

    private init(
        viewModelsByProperty:
            [ExperienceInteractiveViewModelPropertyIdentity:
                ExperienceInteractiveViewModelReference]
    ) {
        self.viewModelsByProperty = viewModelsByProperty
    }

    init(
        mutations: [ExperienceInteractiveStateMutation],
        snapshot: NuxieNativeViewModelSnapshot,
        topology: ExperienceInteractiveSnapshotTopology
    ) throws {
        var attachedByProperty:
            [ExperienceInteractiveViewModelPropertyIdentity:
                ExperienceInteractiveViewModelReference] = [:]
        for snapshotValue in snapshot.values {
            guard case .referencedInstance(let childSnapshotID) = snapshotValue.value,
                  let owner = topology.reference(forSnapshotID: snapshotValue.ownerInstanceID),
                  let child = topology.reference(forSnapshotID: childSnapshotID) else {
                continue
            }
            let identity = ExperienceInteractiveViewModelPropertyIdentity(
                owner: owner,
                path: snapshotValue.name
            )
            guard attachedByProperty.updateValue(child, forKey: identity) == nil else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "native snapshot repeats a view-model property path"
                )
            }
        }

        var viewModelsByProperty:
            [ExperienceInteractiveViewModelPropertyIdentity:
                ExperienceInteractiveViewModelReference] = [:]
        for mutation in mutations {
            guard case .setViewModel(let owner, let path, let value) = mutation else {
                continue
            }
            let segments = path.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard let leaf = segments.last,
                  !leaf.isEmpty,
                  !segments.contains(where: \.isEmpty) else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "view-model attachment has an invalid property path"
                )
            }
            var containingOwner = owner
            for segment in segments.dropLast() {
                let identity = ExperienceInteractiveViewModelPropertyIdentity(
                    owner: containingOwner,
                    path: segment
                )
                guard let nextOwner = attachedByProperty[identity] else {
                    throw ExperienceInteractiveScreenError.stateContract(
                        "view-model attachment path has no containing instance"
                    )
                }
                containingOwner = nextOwner
            }
            let identity = ExperienceInteractiveViewModelPropertyIdentity(
                owner: containingOwner,
                path: leaf
            )
            viewModelsByProperty[identity] = value
            attachedByProperty[identity] = value
        }
        self.viewModelsByProperty = viewModelsByProperty
    }
}

/// Rebuilds product list topology from the native graph after every committed
/// operation. Snapshot-local instance IDs are translated back to the stable
/// handles Swift owns; authored/runtime-created rows receive product-only
/// identities so index-based list operations can still target their owner.
struct ExperienceInteractiveSnapshotTopology: Sendable {
    private(set) var referenceBySnapshotID:
        [UInt64: ExperienceInteractiveViewModelReference] = [:]
    private var nextSyntheticReference = UInt64.max

    func snapshotID(
        for reference: ExperienceInteractiveViewModelReference
    ) -> UInt64? {
        referenceBySnapshotID.first(where: { $0.value == reference })?.key
    }

    func reference(
        forSnapshotID snapshotID: UInt64
    ) -> ExperienceInteractiveViewModelReference? {
        referenceBySnapshotID[snapshotID]
    }

    mutating func reconcile(
        snapshot: NuxieNativeViewModelSnapshot,
        rootReference: ExperienceInteractiveViewModelReference,
        preferredLists:
            [ExperienceInteractiveListIdentity: [ExperienceInteractiveViewModelReference]] = [:],
        preferredViewModels:
            [ExperienceInteractiveViewModelPropertyIdentity:
                ExperienceInteractiveViewModelReference] = [:],
        preservingReferences: Set<ExperienceInteractiveViewModelReference> = [],
        schemaIndexByReference:
            inout [ExperienceInteractiveViewModelReference: Int]
    ) throws -> ExperienceInteractiveTrackedListPlanner {
        var staged = self
        var stagedSchemas = schemaIndexByReference
        let result = try staged.reconcileInPlace(
            snapshot: snapshot,
            rootReference: rootReference,
            preferredLists: preferredLists,
            preferredViewModels: preferredViewModels,
            preservingReferences: preservingReferences,
            schemaIndexByReference: &stagedSchemas
        )
        self = staged
        schemaIndexByReference = stagedSchemas
        return result
    }

    private mutating func reconcileInPlace(
        snapshot: NuxieNativeViewModelSnapshot,
        rootReference: ExperienceInteractiveViewModelReference,
        preferredLists:
            [ExperienceInteractiveListIdentity: [ExperienceInteractiveViewModelReference]],
        preferredViewModels:
            [ExperienceInteractiveViewModelPropertyIdentity:
                ExperienceInteractiveViewModelReference],
        preservingReferences: Set<ExperienceInteractiveViewModelReference>,
        schemaIndexByReference:
            inout [ExperienceInteractiveViewModelReference: Int]
    ) throws -> ExperienceInteractiveTrackedListPlanner {
        var instances: [UInt64: NuxieNativeViewModelSnapshot.Instance] = [:]
        for instance in snapshot.instances {
            guard instances.updateValue(instance, forKey: instance.id) == nil else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "native snapshot repeats a view-model instance identity"
                )
            }
        }
        guard let root = instances[snapshot.rootInstanceID] else {
            throw ExperienceInteractiveScreenError.stateContract(
                "native snapshot omits its root view-model instance"
            )
        }

        let previous = referenceBySnapshotID
        referenceBySnapshotID = [snapshot.rootInstanceID: rootReference]
        try recordSchema(
            root.schemaIndex,
            for: rootReference,
            schemaIndexByReference: &schemaIndexByReference
        )

        var itemsByList:
            [ExperienceInteractiveListIdentity: [ExperienceInteractiveViewModelReference]] = [:]
        var visitedOwners: Set<UInt64> = []
        var madeProgress = true
        while madeProgress {
            madeProgress = false
            for value in snapshot.values {
                guard !visitedOwners.contains(value.ownerInstanceID),
                      let owner = referenceBySnapshotID[value.ownerInstanceID] else {
                    continue
                }
                let ownerValues = snapshot.values.filter {
                    $0.ownerInstanceID == value.ownerInstanceID
                }
                for ownerValue in ownerValues {
                    switch ownerValue.value {
                    case .referencedInstance(let snapshotID):
                        let identity = ExperienceInteractiveViewModelPropertyIdentity(
                            owner: owner,
                            path: ownerValue.name
                        )
                        _ = try resolve(
                            snapshotID,
                            preferred: preferredViewModels[identity],
                            previous: previous,
                            instances: instances,
                            schemaIndexByReference: &schemaIndexByReference
                        )
                    case .list(let snapshotIDs):
                        let identity = ExperienceInteractiveListIdentity(
                            owner: owner,
                            path: ownerValue.name
                        )
                        let preferred = preferredLists[identity]
                        let usePreferred = preferred?.count == snapshotIDs.count
                        itemsByList[identity] = try snapshotIDs.enumerated().map { index, id in
                            try resolve(
                                id,
                                preferred: usePreferred ? preferred?[index] : nil,
                                previous: previous,
                                instances: instances,
                                schemaIndexByReference: &schemaIndexByReference
                            )
                        }
                    case .unsupported, .bytes, .number, .bool, .integer:
                        break
                    }
                }
                visitedOwners.insert(value.ownerInstanceID)
                madeProgress = true
            }
        }
        let reachableReferences = Set(referenceBySnapshotID.values)
        schemaIndexByReference = schemaIndexByReference.filter { reference, _ in
            reachableReferences.contains(reference) || preservingReferences.contains(reference)
        }
        return ExperienceInteractiveTrackedListPlanner(itemsByList: itemsByList)
    }

    private mutating func resolve(
        _ snapshotID: UInt64,
        preferred: ExperienceInteractiveViewModelReference?,
        previous: [UInt64: ExperienceInteractiveViewModelReference],
        instances: [UInt64: NuxieNativeViewModelSnapshot.Instance],
        schemaIndexByReference:
            inout [ExperienceInteractiveViewModelReference: Int]
    ) throws -> ExperienceInteractiveViewModelReference {
        guard let instance = instances[snapshotID] else {
            throw ExperienceInteractiveScreenError.stateContract(
                "native snapshot references an unknown view-model instance"
            )
        }
        let reference: ExperienceInteractiveViewModelReference
        if let preferred {
            reference = preferred
        } else if let existing = referenceBySnapshotID[snapshotID] ?? previous[snapshotID],
                  schemaIndexByReference[existing] == nil
                    || schemaIndexByReference[existing] == instance.schemaIndex {
            reference = existing
        } else {
            reference = try makeSyntheticReference(
                excluding: Set(schemaIndexByReference.keys)
                    .union(referenceBySnapshotID.values)
            )
        }
        if let existing = referenceBySnapshotID[snapshotID], existing != reference {
            throw ExperienceInteractiveScreenError.stateContract(
                "native snapshot identity maps to conflicting product view models"
            )
        }
        referenceBySnapshotID[snapshotID] = reference
        try recordSchema(
            instance.schemaIndex,
            for: reference,
            schemaIndexByReference: &schemaIndexByReference
        )
        return reference
    }

    private mutating func makeSyntheticReference(
        excluding used: Set<ExperienceInteractiveViewModelReference>
    ) throws -> ExperienceInteractiveViewModelReference {
        while nextSyntheticReference > 0 {
            let rawValue = nextSyntheticReference
            nextSyntheticReference -= 1
            if let candidate = ExperienceInteractiveViewModelReference(rawValue: rawValue),
               !used.contains(candidate) {
                return candidate
            }
        }
        throw ExperienceInteractiveScreenError.stateContract(
            "product view-model identity space is exhausted"
        )
    }

    private func recordSchema(
        _ schemaIndex: Int,
        for reference: ExperienceInteractiveViewModelReference,
        schemaIndexByReference:
            inout [ExperienceInteractiveViewModelReference: Int]
    ) throws {
        if let existing = schemaIndexByReference[reference], existing != schemaIndex {
            throw ExperienceInteractiveScreenError.stateContract(
                "one product view-model identity maps to conflicting schemas"
            )
        }
        schemaIndexByReference[reference] = schemaIndex
    }
}

/// Keeps renderer-owned layout and text-input state inside the presentation
/// adapter. These identities are not product state, including dynamically
/// advertised descendants that have no stable Journey identity.
struct ExperienceInteractiveReservedChangeFilter: Sendable {
    private static let reservedRootProperties: Set<String> = [
        "safeArea",
        "nuxieTextInputs",
    ]

    private let rootInstanceID: UInt64
    private let rootPropertyIndexes: Set<Int>
    private var reservedInstanceIDs: Set<UInt64>

    init(
        snapshot: NuxieNativeViewModelSnapshot?,
        catalog: NuxieNativeViewModelCatalog
    ) {
        guard let snapshot,
              let root = snapshot.instances.first(where: {
                  $0.id == snapshot.rootInstanceID
              }) else {
            rootInstanceID = 0
            rootPropertyIndexes = []
            reservedInstanceIDs = []
            return
        }
        rootInstanceID = snapshot.rootInstanceID
        let reservedRootPropertyIndexes: Set<Int> = Set(
            catalog.properties.compactMap { property -> Int? in
                guard property.schemaIndex == root.schemaIndex,
                      Self.reservedRootProperties.contains(property.name) else {
                    return nil
                }
                return property.index
            }
        )
        rootPropertyIndexes = reservedRootPropertyIndexes

        var reserved: Set<UInt64> = []
        var pending: [UInt64] = snapshot.values
            .filter {
                $0.ownerInstanceID == snapshot.rootInstanceID
                    && reservedRootPropertyIndexes.contains($0.propertyIndex)
            }
            .flatMap { Self.childInstanceIDs(in: $0.value) }
        while let owner = pending.popLast() {
            guard reserved.insert(owner).inserted else { continue }
            pending.append(contentsOf: snapshot.values
                .filter { $0.ownerInstanceID == owner }
                .flatMap { Self.childInstanceIDs(in: $0.value) })
        }
        reservedInstanceIDs = reserved
    }

    mutating func shouldSuppress(
        _ change: ExperienceInteractiveViewModelChange
    ) -> Bool {
        let isReservedRootProperty = change.ownerInstanceID == rootInstanceID
            && rootPropertyIndexes.contains(change.propertyIndex)
        guard isReservedRootProperty
                || reservedInstanceIDs.contains(change.ownerInstanceID) else {
            return false
        }
        reservedInstanceIDs.formUnion(Self.childInstanceIDs(in: change.value))
        return true
    }

    private static func childInstanceIDs(
        in value: ExperienceInteractiveViewModelValue
    ) -> [UInt64] {
        switch value {
        case .referencedInstance(let id): [id]
        case .list(let ids): ids
        case .unsupported, .bytes, .number, .bool, .integer: []
        }
    }

    private static func childInstanceIDs(
        in value: NuxieNativeViewModelValue
    ) -> [UInt64] {
        switch value {
        case .referencedInstance(let id): [id]
        case .list(let ids): ids
        case .unsupported, .bytes, .number, .bool, .integer: []
        }
    }
}

/// Selects only the non-settable snapshot component that must be cloned to
/// materialize touched list rows. Settable instances are native-handle
/// boundaries: their inbound edges can be replaced atomically without cloning
/// their otherwise unrelated descendants.
struct ExperienceInteractiveSnapshotCloneScope {
    static func snapshotIDs(
        containing roots: Set<UInt64>,
        snapshot: NuxieNativeViewModelSnapshot,
        stoppingAt boundary: Set<UInt64>
    ) throws -> Set<UInt64> {
        let instances = Dictionary(uniqueKeysWithValues: snapshot.instances.map { ($0.id, $0) })
        var neighbors: [UInt64: Set<UInt64>] = [:]
        for value in snapshot.values {
            let children: [UInt64]
            switch value.value {
            case .referencedInstance(let child): children = [child]
            case .list(let values): children = values
            case .unsupported, .bytes, .number, .bool, .integer: children = []
            }
            for child in children {
                neighbors[value.ownerInstanceID, default: []].insert(child)
                neighbors[child, default: []].insert(value.ownerInstanceID)
            }
        }

        var selected: Set<UInt64> = []
        var pending = Array(roots)
        while let id = pending.popLast() {
            if boundary.contains(id) || selected.contains(id) { continue }
            guard instances[id] != nil else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "native snapshot graph references an unknown instance"
                )
            }
            selected.insert(id)
            pending.append(contentsOf: neighbors[id, default: []])
        }
        return selected
    }
}

/// Owns one authenticated screen's native objects, product interpretation,
/// and exactly-once ordering. Presentation code receives only the generic
/// screen actor and copied Swift values.
actor ExperienceInteractiveScreen {
    private let runtime: NuxieNativeRuntime
    private let fontScope: ExperienceRuntimeFontScope
    nonisolated let artboardBounds: CGRect
    private let operationGate = ExperienceInteractiveOperationGate()
    private let stateCommandGate = ExperienceInteractiveOperationGate()
    private let screenID: String
    private let validScreenIDs: Set<String>
    private let declaredEventNames: Set<String>
    private let textInputs: [String: NuxPackageTextInput]
    private let imageIDsByName: [String: UInt64]
    private var viewModelsByIdentity:
        [ExperienceInteractiveViewModelIdentity: ExperienceInteractiveViewModelReference]
    private var schemaIndexByViewModel: [ExperienceInteractiveViewModelReference: Int]
    private var settableViewModels: Set<ExperienceInteractiveViewModelReference>
    private let viewModelCatalog: NuxieNativeViewModelCatalog
    private let listIndexPathsBySchema: [Int: [String]]
    private let rootViewModelReference: ExperienceInteractiveViewModelReference?
    private var snapshotTopology: ExperienceInteractiveSnapshotTopology
    private var latestSnapshot: NuxieNativeViewModelSnapshot?
    private var trackedLists: ExperienceInteractiveTrackedListPlanner
    private var reservedChangeFilter: ExperienceInteractiveReservedChangeFilter
    private var router = ExperienceInteractiveEffectRouter()

    private init(
        runtime: NuxieNativeRuntime,
        fontScope: ExperienceRuntimeFontScope,
        artboardBounds: CGRect,
        screenID: String,
        validScreenIDs: Set<String>,
        declaredEventNames: Set<String>,
        textInputs: [String: NuxPackageTextInput],
        imageIDsByName: [String: UInt64],
        viewModelsByIdentity:
            [ExperienceInteractiveViewModelIdentity: ExperienceInteractiveViewModelReference],
        schemaIndexByViewModel: [ExperienceInteractiveViewModelReference: Int],
        settableViewModels: Set<ExperienceInteractiveViewModelReference>,
        viewModelCatalog: NuxieNativeViewModelCatalog,
        listIndexPathsBySchema: [Int: [String]],
        rootViewModelReference: ExperienceInteractiveViewModelReference?,
        snapshotTopology: ExperienceInteractiveSnapshotTopology,
        latestSnapshot: NuxieNativeViewModelSnapshot?,
        trackedLists: ExperienceInteractiveTrackedListPlanner
    ) {
        self.runtime = runtime
        self.fontScope = fontScope
        self.artboardBounds = artboardBounds
        self.screenID = screenID
        self.validScreenIDs = validScreenIDs
        self.declaredEventNames = declaredEventNames
        self.textInputs = textInputs
        self.imageIDsByName = imageIDsByName
        self.viewModelsByIdentity = viewModelsByIdentity
        self.schemaIndexByViewModel = schemaIndexByViewModel
        self.settableViewModels = settableViewModels
        self.viewModelCatalog = viewModelCatalog
        self.listIndexPathsBySchema = listIndexPathsBySchema
        self.rootViewModelReference = rootViewModelReference
        self.snapshotTopology = snapshotTopology
        self.latestSnapshot = latestSnapshot
        self.trackedLists = trackedLists
        self.reservedChangeFilter = ExperienceInteractiveReservedChangeFilter(
            snapshot: latestSnapshot,
            catalog: viewModelCatalog
        )
    }

    /// Opens exactly one screen from Swift-owned authenticated bytes. Asset
    /// inspection is script-inert; configured import happens only after the
    /// signed manifest and the authored C catalog agree one-to-one.
    static func open(
        payload: AuthenticatedRuntimePayload,
        screenID requestedScreenID: String? = nil,
        player: ExperienceInteractivePlayerSelection = .defaultScene,
        pixelWidth: UInt32,
        pixelHeight: UInt32
    ) async throws -> ExperienceInteractiveScreen {
        let screenID = requestedScreenID ?? payload.manifest.entry.screenId
        guard let manifestScreen = payload.manifest.screens.first(where: {
            $0.screenId == screenID
        }) else {
            throw ExperienceInteractiveScreenError.screenNotFound(screenID)
        }
        guard !manifestScreen.artboardName.isEmpty,
              manifestScreen.width.isFinite,
              manifestScreen.width > 0,
              manifestScreen.height.isFinite,
              manifestScreen.height > 0 else {
            throw ExperienceInteractiveScreenError.invalidScreen(screenID)
        }
        guard let journeyScreen = payload.journey.screens.first(where: {
            $0.id == screenID
        }) else {
            throw ExperienceInteractiveScreenError.journeyScreenNotFound(screenID)
        }

        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: payload.sceneBytes)
        let externalAssets = try ExperienceInteractiveAssetBinding.bind(
            manifest: payload.manifest,
            authenticatedAssets: payload.assets,
            catalog: catalog
        )
        let imageIDsByName = try ExperienceInteractiveImageIdentityMap.make(
            images: payload.manifest.assets.images
        )
        let runtime = try await NuxieNativeRuntime.open(
            bytes: payload.sceneBytes,
            artboardName: manifestScreen.artboardName,
            player: player.native,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            bindDefaultViewModel: journeyScreen.defaultViewModelName != nil,
            importMode: .configured(
                moduleName: "nuxie",
                expectedAssets: catalog,
                externalAssets: externalAssets
            )
        )
        let fontScope = ExperienceRuntimeFontScope()
        do {
            try ExperienceInteractiveExternalFontRegistration.register(
                manifest: payload.manifest,
                authenticatedAssets: payload.assets,
                in: fontScope
            )
        } catch {
            try? await runtime.close()
            fontScope.close()
            throw error
        }

        let initialState: ExperienceInteractiveInitialState.Result
        do {
            initialState = try await ExperienceInteractiveInitialState.apply(
                journey: payload.journey,
                screen: journeyScreen,
                manifest: payload.manifest,
                runtime: runtime
            )
        } catch {
            try? await runtime.close()
            fontScope.close()
            throw error
        }

        var textInputs: [String: NuxPackageTextInput] = [:]
        for input in payload.manifest.textInputs where input.screenId == screenID {
            guard textInputs.updateValue(input, forKey: input.inputId) == nil else {
                try? await runtime.close()
                fontScope.close()
                throw ExperienceInteractiveScreenError.invalidScreen(screenID)
            }
        }
        let manifestScreenIDs = Set(payload.manifest.screens.map(\.screenId))
        let journeyScreenIDs = Set(payload.journey.screens.map(\.id))
        var schemaIndexByViewModel = initialState.schemaIndexByViewModel
        var snapshotTopology = ExperienceInteractiveSnapshotTopology()
        var trackedLists = ExperienceInteractiveTrackedListPlanner()
        var latestSnapshot: NuxieNativeViewModelSnapshot?
        do {
            if let rootReference = initialState.rootReference {
                let snapshot = try await runtime.snapshot()
                latestSnapshot = snapshot
                trackedLists = try snapshotTopology.reconcile(
                    snapshot: snapshot,
                    rootReference: rootReference,
                    preferredLists: initialState.itemsByList,
                    preferredViewModels: initialState.viewModelsByProperty,
                    preservingReferences: Set(initialState.schemaIndexByViewModel.keys),
                    schemaIndexByReference: &schemaIndexByViewModel
                )
            }
        } catch {
            try? await runtime.close()
            fontScope.close()
            throw error
        }
        return ExperienceInteractiveScreen(
            runtime: runtime,
            fontScope: fontScope,
            artboardBounds: CGRect(
                x: 0,
                y: 0,
                width: manifestScreen.width,
                height: manifestScreen.height
            ),
            screenID: screenID,
            validScreenIDs: manifestScreenIDs.intersection(journeyScreenIDs),
            declaredEventNames: Set(
                payload.journey.events[screenID, default: []].map(\.eventName)
            ),
            textInputs: textInputs,
            imageIDsByName: imageIDsByName,
            viewModelsByIdentity: initialState.viewModelsByIdentity,
            schemaIndexByViewModel: schemaIndexByViewModel,
            settableViewModels: Set(initialState.schemaIndexByViewModel.keys),
            viewModelCatalog: initialState.catalog,
            listIndexPathsBySchema: initialState.listIndexPathsBySchema,
            rootViewModelReference: initialState.rootReference,
            snapshotTopology: snapshotTopology,
            latestSnapshot: latestSnapshot,
            trackedLists: trackedLists
        )
    }

    func step(
        inputs: [ExperienceInteractiveInput] = [],
        pointers: [ExperienceInteractivePointerEvent] = [],
        elapsedSeconds: Float,
        correlationID: UInt64 = 0
    ) async throws -> ExperienceInteractiveStepResult {
        let nativeInputs = inputs.map(Self.nativeInput)
        let nativePointers = pointers.map(Self.nativePointer)
        let runtime = runtime
        return try await operationGate.withLock { [self] in
            let result = try await runtime.step(
                inputs: nativeInputs,
                pointers: nativePointers,
                elapsedSeconds: elapsedSeconds,
                correlationID: correlationID
            )
            // Native step effects have committed. Topology is a recoverable
            // cache and must never turn that committed operation into a
            // product-visible failure that drops its exactly-once effects.
            try? await refreshTrackedTopology()
            return await projectStep(result, correlationID: correlationID)
        }
    }

    private func projectStep(
        _ result: NuxieNativePlayerStepResult,
        correlationID: UInt64
    ) -> ExperienceInteractiveStepResult {
        let effects = router.project(
            reportedEvents: result.events.map(Self.reportedEvent),
            stateChanges: result.stateChanges.map {
                ExperienceInteractiveStateChange(
                    layerIndex: $0.layerIndex,
                    coreType: $0.coreType,
                    globalID: $0.globalID
                )
            },
            viewModelChanges: publishableViewModelChanges(result.viewModelChanges),
            hostCommands: result.hostCommands.map(Self.hostCommand),
            declaredEventNames: declaredEventNames,
            validScreenIDs: validScreenIDs,
            correlationID: correlationID
        )
        return ExperienceInteractiveStepResult(
            keepGoing: result.keepGoing,
            pointerHits: result.pointerHits.map(Self.pointerHit),
            effects: effects
        )
    }

    func rootViewModel() async throws -> ExperienceInteractiveViewModelReference {
        let runtime = runtime
        let reference = try await operationGate.withLock {
            try await runtime.rootViewModelReference()
        }
        return ExperienceInteractiveViewModelReference(rawValue: reference.rawValue)!
    }

    func viewModel(
        named viewModelName: String,
        instanceID: String? = nil,
        instanceName: String? = nil,
        staged: [ExperienceInteractiveViewModelIdentity:
            ExperienceInteractiveViewModelReference] = [:]
    ) throws -> ExperienceInteractiveViewModelReference {
        let identity = ExperienceInteractiveViewModelIdentity(
            viewModelName: viewModelName,
            instanceID: instanceID,
            instanceName: instanceName
        )
        guard let reference = staged[identity] ?? viewModelsByIdentity[identity] else {
            throw ExperienceInteractiveScreenError.stateContract(
                "view model '\(viewModelName)' does not resolve instance '\(instanceID ?? "default")'"
            )
        }
        return reference
    }

    func makeViewModel(
        schemaIndex: Int,
        authoredInstanceIndex: Int? = nil
    ) async throws -> ExperienceInteractiveViewModelReference {
        let runtime = runtime
        return try await operationGate.withLock { [self] in
            let reference = try await runtime.makeViewModel(
                schemaIndex: schemaIndex,
                authoredInstanceIndex: authoredInstanceIndex
            )
            let productReference = ExperienceInteractiveViewModelReference(
                rawValue: reference.rawValue
            )!
            await recordSchema(schemaIndex, for: productReference)
            await recordSettable(productReference)
            return productReference
        }
    }

    private func recordSchema(
        _ schemaIndex: Int,
        for reference: ExperienceInteractiveViewModelReference
    ) {
        schemaIndexByViewModel[reference] = schemaIndex
    }

    private func recordSettable(_ reference: ExperienceInteractiveViewModelReference) {
        settableViewModels.insert(reference)
    }

    func mutateState(
        _ mutations: [ExperienceInteractiveStateMutation],
        correlationID: UInt64 = 0
    ) async throws -> ExperienceInteractiveMutationResult {
        let runtime = runtime
        return try await operationGate.withLock { [self] in
            try await refreshTrackedTopology()
            let materialization = try await materializeListRowsIfNeeded(for: mutations)
            do {
                let translated = mutations.map {
                    Self.replacingReferences($0, with: materialization.references)
                }
                let plan = try await planStateMutations(
                    translated,
                    startingWith: materialization.trackedLists
                )
                let committedMutations = materialization.prefixMutations + plan.mutations
                let topologyPreferences = try await mutationTopologyPreferences(
                    for: committedMutations
                )
                let result = try await runtime.mutateViewModel(
                    committedMutations.map(Self.nativeMutation),
                    correlationID: correlationID
                )
                await commitTrackedLists(plan.trackedLists)
                await commitIdentityReplacements(materialization.references)
                try? await refreshTrackedTopology(
                    preferredLists: plan.trackedLists.itemsByList,
                    preferredViewModels: topologyPreferences.viewModelsByProperty
                )
                return await projectMutation(
                    result,
                    ignoringPrefixCount: materialization.prefixMutations.count,
                    correlationID: correlationID
                )
            } catch {
                try? await releaseTemporaryViewModels(materialization.temporaryReferences)
                throw error
            }
        }
    }

    private func releaseTemporaryViewModels(
        _ references: [ExperienceInteractiveViewModelReference]
    ) async throws {
        defer {
            for reference in references {
                settableViewModels.remove(reference)
                schemaIndexByViewModel.removeValue(forKey: reference)
            }
        }
        try await runtime.releaseViewModels(references.compactMap {
            NuxieNativeViewModelReference(rawValue: $0.rawValue)
        })
    }

    private struct StateMutationPlan: Sendable {
        let mutations: [ExperienceInteractiveStateMutation]
        let trackedLists: ExperienceInteractiveTrackedListPlanner
    }

    private struct MaterializationPlan: Sendable {
        let prefixMutations: [ExperienceInteractiveStateMutation]
        let references: [ExperienceInteractiveViewModelReference:
            ExperienceInteractiveViewModelReference]
        let temporaryReferences: [ExperienceInteractiveViewModelReference]
        let trackedLists: ExperienceInteractiveTrackedListPlanner

        static func unchanged(
            _ trackedLists: ExperienceInteractiveTrackedListPlanner
        ) -> MaterializationPlan {
            MaterializationPlan(
                prefixMutations: [],
                references: [:],
                temporaryReferences: [],
                trackedLists: trackedLists
            )
        }
    }

    /// The pinned C ABI can mutate a list by owner/index but cannot recover a
    /// child handle from a snapshot identity. Before an SDK list edit needs to
    /// rewrite authored `listIndex` fields, clone only the touched non-settable
    /// components into equivalent retained handles. Every inbound edge from an
    /// existing settable instance is staged in the same native batch as the
    /// requested edit and index writes, preserving aliases and rollback.
    private func materializeListRowsIfNeeded(
        for mutations: [ExperienceInteractiveStateMutation]
    ) async throws -> MaterializationPlan {
        var finalTopology = trackedLists
        _ = try finalTopology.expand(
            mutations,
            schemaIndexByReference: schemaIndexByViewModel,
            listIndexPathsBySchema: [:],
            settableReferences: []
        )
        let touchedLists = Set(mutations.compactMap(Self.listIdentity))
        var listsToMaterialize: Set<ExperienceInteractiveListIdentity> = []
        for identity in touchedLists {
            let finalItems = finalTopology.itemsByList[identity, default: []]
            if finalItems.contains(where: { item in
                guard !settableViewModels.contains(item),
                      let schema = schemaIndexByViewModel[item] else { return false }
                return !listIndexPathsBySchema[schema, default: []].isEmpty
            }) {
                listsToMaterialize.insert(identity)
            }
        }
        guard !listsToMaterialize.isEmpty else { return .unchanged(trackedLists) }
        guard let latestSnapshot else {
            throw ExperienceInteractiveScreenError.stateContract(
                "authored list rows require an authoritative native snapshot"
            )
        }

        var touchedSnapshotIDs: Set<UInt64> = []
        for identity in listsToMaterialize {
            for item in finalTopology.itemsByList[identity, default: []]
            where !settableViewModels.contains(item) {
                guard let snapshotID = snapshotTopology.snapshotID(for: item) else {
                    throw ExperienceInteractiveScreenError.stateContract(
                        "authored list row is absent from the authoritative snapshot"
                    )
                }
                touchedSnapshotIDs.insert(snapshotID)
            }
        }
        let settableSnapshotIDs: Set<UInt64> = Set(
            latestSnapshot.instances.compactMap { instance -> UInt64? in
                guard let reference = snapshotTopology.reference(forSnapshotID: instance.id),
                      settableViewModels.contains(reference) else {
                    return nil
                }
                return instance.id
            }
        )
        let snapshotIDsToClone = try ExperienceInteractiveSnapshotCloneScope.snapshotIDs(
            containing: touchedSnapshotIDs,
            snapshot: latestSnapshot,
            stoppingAt: settableSnapshotIDs
        )
        let cloned = try await cloneSnapshotGraph(
            snapshotIDs: snapshotIDsToClone,
            snapshot: latestSnapshot
        )
        let materialized = cloned.references
        var replacements: [ExperienceInteractiveViewModelReference:
            ExperienceInteractiveViewModelReference] = [:]
        for (snapshotID, replacement) in materialized {
            guard let oldReference = snapshotTopology.reference(forSnapshotID: snapshotID),
                  !settableViewModels.contains(oldReference) else { continue }
            replacements[oldReference] = replacement
        }

        var preparedTopology = trackedLists
        preparedTopology.replaceItems(replacements)
        var prefix: [ExperienceInteractiveStateMutation] = []
        for value in latestSnapshot.values {
            guard let owner = snapshotTopology.reference(
                forSnapshotID: value.ownerInstanceID
            ), settableViewModels.contains(owner) else { continue }
            switch value.value {
            case .referencedInstance(let childID):
                guard let child = snapshotTopology.reference(forSnapshotID: childID),
                      let replacement = replacements[child] else { continue }
                prefix.append(.setViewModel(owner, path: value.name, value: replacement))
            case .list(let childIDs):
                for (index, childID) in childIDs.enumerated() {
                    guard let child = snapshotTopology.reference(forSnapshotID: childID),
                          let replacement = replacements[child] else { continue }
                    prefix.append(.listSet(
                        owner,
                        path: value.name,
                        index: index,
                        value: replacement
                    ))
                }
            case .unsupported, .bytes, .number, .bool, .integer:
                break
            }
        }
        guard !prefix.isEmpty else {
            try? await releaseTemporaryViewModels(cloned.allocated)
            throw ExperienceInteractiveScreenError.stateContract(
                "authored list graph has no replaceable inbound native edge"
            )
        }
        return MaterializationPlan(
            prefixMutations: prefix,
            references: replacements,
            temporaryReferences: cloned.allocated,
            trackedLists: preparedTopology
        )
    }

    private struct ClonedSnapshotGraph: Sendable {
        let references: [UInt64: ExperienceInteractiveViewModelReference]
        let allocated: [ExperienceInteractiveViewModelReference]
    }

    private func cloneSnapshotGraph(
        snapshotIDs: Set<UInt64>,
        snapshot: NuxieNativeViewModelSnapshot
    ) async throws -> ClonedSnapshotGraph {
        let instances = Dictionary(uniqueKeysWithValues: snapshot.instances.map { ($0.id, $0) })
        let valuesByOwner = Dictionary(grouping: snapshot.values, by: \.ownerInstanceID)
        var references: [UInt64: ExperienceInteractiveViewModelReference] = [:]
        for instance in snapshot.instances {
            guard let reference = snapshotTopology.reference(forSnapshotID: instance.id),
                  settableViewModels.contains(reference) else { continue }
            references[instance.id] = reference
        }
        var visiting: Set<UInt64> = []
        var visited: Set<UInt64> = []
        var postorder: [UInt64] = []
        func visit(_ id: UInt64) throws {
            guard snapshotIDs.contains(id) else { return }
            guard instances[id] != nil else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "native snapshot graph references an unknown instance"
                )
            }
            if visited.contains(id) { return }
            guard visiting.insert(id).inserted else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "native snapshot graph contains a view-model cycle"
                )
            }
            for value in valuesByOwner[id, default: []] {
                switch value.value {
                case .referencedInstance(let child):
                    try visit(child)
                case .list(let children):
                    for child in children { try visit(child) }
                case .unsupported, .bytes, .number, .bool, .integer:
                    break
                }
            }
            visiting.remove(id)
            visited.insert(id)
            postorder.append(id)
        }
        for root in snapshotIDs.sorted() { try visit(root) }

        var allocated: Set<UInt64> = []
        var allocatedReferences: [ExperienceInteractiveViewModelReference] = []
        do {
            for id in postorder {
                guard let instance = instances[id] else { continue }
                let native = try await runtime.makeViewModel(schemaIndex: instance.schemaIndex)
                guard let reference = ExperienceInteractiveViewModelReference(
                    rawValue: native.rawValue
                ) else {
                    throw ExperienceInteractiveScreenError.stateContract(
                        "materialized view model has an invalid identity"
                    )
                }
                references[id] = reference
                allocated.insert(id)
                allocatedReferences.append(reference)
                schemaIndexByViewModel[reference] = instance.schemaIndex
                settableViewModels.insert(reference)
            }
            for id in postorder where allocated.contains(id) {
                guard let reference = references[id],
                      let schemaIndex = schemaIndexByViewModel[reference] else { continue }
                let scalars = try valuesByOwner[id, default: []].compactMap {
                    try cloneScalarMutation(
                        $0,
                        owner: reference,
                        schemaIndex: schemaIndex
                    )
                }
                if !scalars.isEmpty {
                    _ = try await runtime.mutateViewModel(
                        scalars.map(Self.nativeMutation),
                        correlationID: 0
                    )
                }
            }
            for id in postorder where allocated.contains(id) {
                guard let owner = references[id] else { continue }
                var structural: [ExperienceInteractiveStateMutation] = []
                for value in valuesByOwner[id, default: []] {
                    switch value.value {
                    case .referencedInstance(let child):
                        guard let childReference = references[child] else {
                            throw ExperienceInteractiveScreenError.stateContract(
                                "materialized graph omits a referenced view model"
                            )
                        }
                        structural.append(.setViewModel(
                            owner,
                            path: value.name,
                            value: childReference
                        ))
                    case .list(let children):
                        structural.append(.listClear(owner, path: value.name))
                        for (index, child) in children.enumerated() {
                            guard let childReference = references[child] else {
                                throw ExperienceInteractiveScreenError.stateContract(
                                    "materialized graph omits a list row"
                                )
                            }
                            structural.append(.listInsert(
                                owner,
                                path: value.name,
                                index: index,
                                value: childReference
                            ))
                        }
                    case .unsupported, .bytes, .number, .bool, .integer:
                        break
                    }
                }
                if !structural.isEmpty {
                    _ = try await runtime.mutateViewModel(
                        structural.map(Self.nativeMutation),
                        correlationID: 0
                    )
                }
            }
        } catch {
            try? await releaseTemporaryViewModels(allocatedReferences)
            throw error
        }
        return ClonedSnapshotGraph(
            references: references,
            allocated: allocatedReferences
        )
    }

    private func cloneScalarMutation(
        _ value: NuxieNativeViewModelSnapshot.Value,
        owner: ExperienceInteractiveViewModelReference,
        schemaIndex: Int
    ) throws -> ExperienceInteractiveStateMutation? {
        guard let property = viewModelCatalog.properties.first(where: {
            $0.schemaIndex == schemaIndex && $0.index == value.propertyIndex
        }) else {
            throw ExperienceInteractiveScreenError.stateContract(
                "native snapshot property is absent from the authenticated catalog"
            )
        }
        switch (property.kind, value.value) {
        case (.string, .bytes(let bytes)):
            return .setString(owner, path: value.name, value: bytes)
        case (.number, .number(let number)):
            return .setNumber(owner, path: value.name, value: number)
        case (.bool, .bool(let bool)):
            return .setBool(owner, path: value.name, value: bool)
        case (.color, .integer(let integer)):
            guard let color = UInt32(exactly: integer) else {
                throw ExperienceInteractiveScreenError.stateContract(value.name)
            }
            return .setColor(owner, path: value.name, value: color)
        case (.enumeration, .integer(let integer)):
            return .setEnumeration(owner, path: value.name, value: integer)
        case (.listIndex, .integer(let integer)):
            return .setListIndex(owner, path: value.name, value: integer)
        case (.image, .integer(let integer)):
            return .setImage(owner, path: value.name, value: integer)
        case (.trigger, _), (.viewModel, .referencedInstance), (.list, .list),
             (.unsupported, _):
            return nil
        case (.font, _), (.blob, _), (.artboard, _):
            throw ExperienceInteractiveScreenError.stateContract(
                "authored list row contains a value the pinned native API cannot clone"
            )
        default:
            throw ExperienceInteractiveScreenError.stateContract(
                "native snapshot value disagrees with its authenticated catalog kind"
            )
        }
    }

    private static func listIdentity(
        _ mutation: ExperienceInteractiveStateMutation
    ) -> ExperienceInteractiveListIdentity? {
        switch mutation {
        case .listInsert(let owner, let path, _, _),
             .listRemove(let owner, let path, _),
             .listSwap(let owner, let path, _, _),
             .listMove(let owner, let path, _, _),
             .listSet(let owner, let path, _, _),
             .listClear(let owner, let path):
            return ExperienceInteractiveListIdentity(owner: owner, path: path)
        case .setString, .setNumber, .setBool, .setColor, .setEnumeration,
             .fireTrigger, .setListIndex, .setImage, .setViewModel:
            return nil
        }
    }

    private static func replacingReferences(
        _ mutation: ExperienceInteractiveStateMutation,
        with replacements: [ExperienceInteractiveViewModelReference:
            ExperienceInteractiveViewModelReference]
    ) -> ExperienceInteractiveStateMutation {
        func replacement(
            _ reference: ExperienceInteractiveViewModelReference
        ) -> ExperienceInteractiveViewModelReference {
            replacements[reference] ?? reference
        }
        switch mutation {
        case .setString(let owner, let path, let value):
            return .setString(replacement(owner), path: path, value: value)
        case .setNumber(let owner, let path, let value):
            return .setNumber(replacement(owner), path: path, value: value)
        case .setBool(let owner, let path, let value):
            return .setBool(replacement(owner), path: path, value: value)
        case .setColor(let owner, let path, let value):
            return .setColor(replacement(owner), path: path, value: value)
        case .setEnumeration(let owner, let path, let value):
            return .setEnumeration(replacement(owner), path: path, value: value)
        case .fireTrigger(let owner, let path):
            return .fireTrigger(replacement(owner), path: path)
        case .setListIndex(let owner, let path, let value):
            return .setListIndex(replacement(owner), path: path, value: value)
        case .setImage(let owner, let path, let value):
            return .setImage(replacement(owner), path: path, value: value)
        case .setViewModel(let owner, let path, let value):
            return .setViewModel(
                replacement(owner),
                path: path,
                value: replacement(value)
            )
        case .listInsert(let owner, let path, let index, let value):
            return .listInsert(
                replacement(owner),
                path: path,
                index: index,
                value: replacement(value)
            )
        case .listRemove(let owner, let path, let index):
            return .listRemove(replacement(owner), path: path, index: index)
        case .listSwap(let owner, let path, let first, let second):
            return .listSwap(
                replacement(owner),
                path: path,
                first: first,
                second: second
            )
        case .listMove(let owner, let path, let from, let to):
            return .listMove(
                replacement(owner),
                path: path,
                from: from,
                to: to
            )
        case .listSet(let owner, let path, let index, let value):
            return .listSet(
                replacement(owner),
                path: path,
                index: index,
                value: replacement(value)
            )
        case .listClear(let owner, let path):
            return .listClear(replacement(owner), path: path)
        }
    }

    private func planStateMutations(
        _ mutations: [ExperienceInteractiveStateMutation],
        startingWith initial: ExperienceInteractiveTrackedListPlanner
    ) throws -> StateMutationPlan {
        var staged = initial
        let expanded = try staged.expand(
            mutations,
            schemaIndexByReference: schemaIndexByViewModel,
            listIndexPathsBySchema: listIndexPathsBySchema,
            settableReferences: settableViewModels
        )
        return StateMutationPlan(mutations: expanded, trackedLists: staged)
    }

    private func mutationTopologyPreferences(
        for mutations: [ExperienceInteractiveStateMutation]
    ) throws -> ExperienceInteractiveMutationTopologyPreferences {
        guard rootViewModelReference != nil else { return .empty }
        let hasViewModelAttachment = mutations.contains { mutation in
            if case .setViewModel = mutation { return true }
            return false
        }
        guard hasViewModelAttachment else { return .empty }
        guard let latestSnapshot else {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model mutation requires an authoritative native snapshot"
            )
        }
        return try ExperienceInteractiveMutationTopologyPreferences(
            mutations: mutations,
            snapshot: latestSnapshot,
            topology: snapshotTopology
        )
    }

    private func commitTrackedLists(_ value: ExperienceInteractiveTrackedListPlanner) {
        trackedLists = value
    }

    private func commitIdentityReplacements(
        _ replacements: [ExperienceInteractiveViewModelReference:
            ExperienceInteractiveViewModelReference]
    ) {
        guard !replacements.isEmpty else { return }
        viewModelsByIdentity = viewModelsByIdentity.mapValues {
            replacements[$0] ?? $0
        }
    }

    private func refreshTrackedTopology(
        preferredLists:
            [ExperienceInteractiveListIdentity: [ExperienceInteractiveViewModelReference]] = [:],
        preferredViewModels:
            [ExperienceInteractiveViewModelPropertyIdentity:
                ExperienceInteractiveViewModelReference] = [:]
    ) async throws {
        guard let rootViewModelReference else { return }
        let snapshot = try await runtime.snapshot()
        trackedLists = try snapshotTopology.reconcile(
            snapshot: snapshot,
            rootReference: rootViewModelReference,
            preferredLists: preferredLists,
            preferredViewModels: preferredViewModels,
            preservingReferences: settableViewModels,
            schemaIndexByReference: &schemaIndexByViewModel
        )
        latestSnapshot = snapshot
        reservedChangeFilter = ExperienceInteractiveReservedChangeFilter(
            snapshot: snapshot,
            catalog: viewModelCatalog
        )
    }

    private func projectMutation(
        _ result: NuxieNativeViewModelMutationResult,
        ignoringPrefixCount prefixCount: Int,
        correlationID: UInt64
    ) -> ExperienceInteractiveMutationResult {
        let changes = result.changes.dropFirst(prefixCount)
        let effects = router.project(
            reportedEvents: [],
            stateChanges: [],
            viewModelChanges: publishableViewModelChanges(Array(changes)),
            hostCommands: [],
            declaredEventNames: declaredEventNames,
            validScreenIDs: validScreenIDs,
            correlationID: correlationID
        )
        return ExperienceInteractiveMutationResult(
            appliedCount: max(0, result.appliedCount - prefixCount),
            correlationID: result.correlationID,
            effects: effects
        )
    }

    private func publishableViewModelChanges(
        _ changes: [NuxieNativeViewModelChange]
    ) -> [ExperienceInteractiveViewModelChange] {
        changes.compactMap { change in
            let projected = Self.viewModelChange(change)
            return reservedChangeFilter.shouldSuppress(projected) ? nil : projected
        }
    }

    /// Resolves SDK-authored identities and values entirely in Swift, then
    /// commits one generic typed mutation batch through the native actor.
    func applyStateCommand(
        _ command: ExperienceInteractiveStateCommand,
        correlationID: UInt64 = 0
    ) async throws -> ExperienceInteractiveMutationResult {
        let gate = stateCommandGate
        return try await gate.withLock { [self] in
            try await applyStateCommandLocked(command, correlationID: correlationID)
        }
    }

    private func applyStateCommandLocked(
        _ command: ExperienceInteractiveStateCommand,
        correlationID: UInt64
    ) async throws -> ExperienceInteractiveMutationResult {
        let allocation = try await allocateUnknownViewModels(in: command)
        do {
            let mutations = try stateMutations(for: command, staged: allocation.identities)
            guard !mutations.isEmpty else {
                viewModelsByIdentity.merge(allocation.identities) { _, staged in staged }
                return ExperienceInteractiveMutationResult(
                    appliedCount: 0,
                    correlationID: correlationID,
                    effects: []
                )
            }
            let result = try await mutateState(mutations, correlationID: correlationID)
            viewModelsByIdentity.merge(allocation.identities) { _, staged in staged }
            return result
        } catch {
            try? await releaseTemporaryViewModels(allocation.references)
            throw error
        }
    }

    private struct StateIdentityAllocation: Sendable {
        let identities: [ExperienceInteractiveViewModelIdentity:
            ExperienceInteractiveViewModelReference]
        let references: [ExperienceInteractiveViewModelReference]
    }

    private func allocateUnknownViewModels(
        in command: ExperienceInteractiveStateCommand
    ) async throws -> StateIdentityAllocation {
        var requested = Set<ExperienceInteractiveViewModelIdentity>()
        func recordOwner(_ value: ExperienceInteractiveStateCommand.Value) throws {
            requested.insert(.init(
                viewModelName: value.viewModelName,
                instanceID: value.instanceID,
                instanceName: value.instanceName
            ))
            try collectReferencedIdentities(in: value.value, into: &requested)
        }
        switch command {
        case .snapshot(let values):
            for value in values { try recordOwner(value) }
        case .value(let value):
            try recordOwner(value)
        case let .trigger(viewModelName, instanceID, instanceName, _),
             let .list(viewModelName, instanceID, instanceName, _, .remove(_)),
             let .list(viewModelName, instanceID, instanceName, _, .swap(_, _)),
             let .list(viewModelName, instanceID, instanceName, _, .move(_, _)),
             let .list(viewModelName, instanceID, instanceName, _, .clear):
            requested.insert(.init(
                viewModelName: viewModelName,
                instanceID: instanceID,
                instanceName: instanceName
            ))
        case let .list(viewModelName, instanceID, instanceName, _, .insert(_, value)),
             let .list(viewModelName, instanceID, instanceName, _, .set(_, value)):
            requested.insert(.init(
                viewModelName: viewModelName,
                instanceID: instanceID,
                instanceName: instanceName
            ))
            try collectReferencedIdentities(in: value, into: &requested)
        }

        var staged: [ExperienceInteractiveViewModelIdentity:
            ExperienceInteractiveViewModelReference] = [:]
        var allocated: [ExperienceInteractiveViewModelReference] = []
        do {
            for identity in requested.sorted(by: Self.identityComesFirst) {
                guard viewModelsByIdentity[identity] == nil else { continue }
                let schemas = viewModelCatalog.schemas.filter {
                    $0.name == identity.viewModelName
                }
                guard schemas.count == 1, let schema = schemas.first else {
                    throw ExperienceInteractiveScreenError.stateContract(
                        "view model '\(identity.viewModelName)' does not resolve exactly once"
                    )
                }
                let authoredIndex: Int?
                if let instanceName = identity.instanceName {
                    let authored = viewModelCatalog.authoredInstances.filter {
                        $0.schemaIndex == schema.index && $0.name == instanceName
                    }
                    guard authored.count == 1 else {
                        throw ExperienceInteractiveScreenError.stateContract(
                            "authored instance '\(instanceName)' does not resolve exactly once"
                        )
                    }
                    authoredIndex = authored[0].index
                } else {
                    authoredIndex = nil
                }
                let reference = try await makeViewModel(
                    schemaIndex: schema.index,
                    authoredInstanceIndex: authoredIndex
                )
                staged[identity] = reference
                allocated.append(reference)
            }
            return StateIdentityAllocation(identities: staged, references: allocated)
        } catch {
            try? await releaseTemporaryViewModels(allocated)
            throw error
        }
    }

    private nonisolated static func identityComesFirst(
        _ lhs: ExperienceInteractiveViewModelIdentity,
        _ rhs: ExperienceInteractiveViewModelIdentity
    ) -> Bool {
        (lhs.viewModelName, lhs.instanceID ?? "", lhs.instanceName ?? "")
            < (rhs.viewModelName, rhs.instanceID ?? "", rhs.instanceName ?? "")
    }

    private func collectReferencedIdentities(
        in value: ExperienceInteractiveValue,
        into result: inout Set<ExperienceInteractiveViewModelIdentity>
    ) throws {
        switch value {
        case .object(let fields):
            let object = try uniqueStateObject(fields)
            if case .string(let viewModelName)? = object["viewModelId"] {
                let instanceID: String? = switch object["vmInstanceId"] ?? object["instanceId"] {
                case .string(let value): value
                default: nil
                }
                let instanceName: String? = switch object["instanceName"] {
                case .string(let value): value
                default: nil
                }
                result.insert(.init(
                    viewModelName: viewModelName,
                    instanceID: instanceID,
                    instanceName: instanceName
                ))
            }
            for field in fields {
                try collectReferencedIdentities(in: field.value, into: &result)
            }
        case .list(let values):
            for value in values {
                try collectReferencedIdentities(in: value, into: &result)
            }
        case .null, .bool, .number, .string, .bytes:
            break
        }
    }

    private func stateMutations(
        for command: ExperienceInteractiveStateCommand,
        staged: [ExperienceInteractiveViewModelIdentity:
            ExperienceInteractiveViewModelReference]
    ) throws -> [ExperienceInteractiveStateMutation] {
        switch command {
        case .snapshot(let values):
            return try normalizeSnapshotValues(values, staged: staged).flatMap {
                try mutations(for: $0, staged: staged)
            }
        case .value(let value):
            return try mutations(for: value, staged: staged)
        case let .trigger(viewModelName, instanceID, instanceName, path):
            return [.fireTrigger(
                try viewModel(
                    named: viewModelName,
                    instanceID: instanceID,
                    instanceName: instanceName,
                    staged: staged
                ),
                path: path
            )]
        case let .list(viewModelName, instanceID, instanceName, path, edit):
            let owner = try viewModel(
                named: viewModelName,
                instanceID: instanceID,
                instanceName: instanceName,
                staged: staged
            )
            let identity = ExperienceInteractiveListIdentity(owner: owner, path: path)
            let current = trackedLists.itemsByList[identity, default: []]
            switch edit {
            case .insert(let requestedIndex, let value):
                let index = max(0, min(requestedIndex ?? current.count, current.count))
                let row = try listRowMutations(
                    value,
                    owner: owner,
                    path: path,
                    staged: staged
                )
                return row.mutations + [.listInsert(
                    owner,
                    path: path,
                    index: index,
                    value: row.reference
                )]
            case .remove(let index):
                guard current.indices.contains(index) else {
                    throw ExperienceInteractiveScreenError.stateContract(
                        "list remove index \(index) is out of range"
                    )
                }
                return [.listRemove(owner, path: path, index: index)]
            case .swap(let first, let second):
                guard current.indices.contains(first), current.indices.contains(second) else {
                    throw ExperienceInteractiveScreenError.stateContract(
                        "list swap indexes \(first) and \(second) are out of range"
                    )
                }
                return [.listSwap(owner, path: path, first: first, second: second)]
            case .move(let from, let to):
                guard current.indices.contains(from), to >= 0, to <= current.count else {
                    throw ExperienceInteractiveScreenError.stateContract(
                        "list move indexes \(from) and \(to) are out of range"
                    )
                }
                return [.listMove(owner, path: path, from: from, to: to)]
            case .set(let index, let value):
                guard current.indices.contains(index) else {
                    throw ExperienceInteractiveScreenError.stateContract(
                        "list set index \(index) is out of range"
                    )
                }
                let row = try listRowMutations(
                    value,
                    owner: owner,
                    path: path,
                    staged: staged
                )
                if current[index] == row.reference {
                    return row.mutations
                }
                return row.mutations + [.listSet(
                    owner,
                    path: path,
                    index: index,
                    value: row.reference
                )]
            case .clear:
                return [.listClear(owner, path: path)]
            }
        }
    }

    private func listRowMutations(
        _ value: ExperienceInteractiveValue,
        owner: ExperienceInteractiveViewModelReference,
        path: String,
        staged: [ExperienceInteractiveViewModelIdentity:
            ExperienceInteractiveViewModelReference]
    ) throws -> (
        reference: ExperienceInteractiveViewModelReference,
        mutations: [ExperienceInteractiveStateMutation]
    ) {
        let reference = try referencedViewModel(from: value, staged: staged)
        guard let ownerSchemaIndex = schemaIndexByViewModel[owner],
              let property = try? property(at: path, startingWith: ownerSchemaIndex),
              property.kind == .list,
              let rowSchemaIndex = schemaIndexByViewModel[reference],
              property.referencedSchemaIndex == nil
                || property.referencedSchemaIndex == rowSchemaIndex else {
            throw ExperienceInteractiveScreenError.stateContract(
                "list item for '\(path)' has the wrong authenticated schema"
            )
        }
        guard case .object(let fields) = value else {
            throw ExperienceInteractiveScreenError.stateContract(
                "list items require a canonical view-model envelope"
            )
        }
        let rowMutations = try canonicalEnvelopeFields(fields).flatMap { field in
            try mutations(
                reference: reference,
                schemaIndex: rowSchemaIndex,
                path: field.key,
                value: field.value,
                staged: staged
            )
        }
        return (reference, rowMutations)
    }

    func resolveViewModelChange(
        _ change: ExperienceInteractiveViewModelChange
    ) throws -> ExperienceInteractiveResolvedViewModelChange {
        guard let reference = ExperienceInteractiveViewModelReference(
            rawValue: change.ownerInstanceID
        ),
        let schemaIndex = schemaIndexByViewModel[reference],
        let property = viewModelCatalog.properties.first(where: {
            $0.schemaIndex == schemaIndex && $0.index == change.propertyIndex
        }) else {
            throw ExperienceInteractiveScreenError.stateContract(
                "runtime view-model change is absent from the authenticated catalog"
            )
        }
        let identities = viewModelsByIdentity
            .filter { $0.value == reference }
            .map(\.key)
            .sorted {
                let lhs = ($0.instanceID ?? "", $0.instanceName ?? "")
                let rhs = ($1.instanceID ?? "", $1.instanceName ?? "")
                return lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            }
        guard let identity = identities.first else {
            throw ExperienceInteractiveScreenError.stateContract(
                "runtime view-model publisher has no stable product identity"
            )
        }
        var visiting = Set<ExperienceInteractiveViewModelReference>()
        let projected = try canonicalValue(
            change.value,
            property: property,
            includeCompositeValues: true,
            visiting: &visiting
        )
        return ExperienceInteractiveResolvedViewModelChange(
            origin: change.origin,
            correlationID: change.correlationID,
            viewModelName: identity.viewModelName,
            instanceID: identity.instanceID,
            instanceName: identity.instanceName,
            path: property.name,
            value: projected,
            isTrigger: property.kind == .trigger
        )
    }

    private func canonicalValue(
        _ value: ExperienceInteractiveViewModelValue,
        property: NuxieNativeViewModelCatalog.Property,
        includeCompositeValues: Bool,
        visiting: inout Set<ExperienceInteractiveViewModelReference>
    ) throws -> ExperienceInteractiveValue {
        switch (property.kind, value) {
        case (.string, .bytes(let bytes)):
            return String(data: bytes, encoding: .utf8).map(ExperienceInteractiveValue.string)
                ?? .bytes(bytes)
        case (.number, .number(let number)):
            return .number(Double(number))
        case (.bool, .bool(let bool)):
            return .bool(bool)
        case (.color, .integer(let integer)),
             (.listIndex, .integer(let integer)):
            return .number(Double(integer))
        case (.enumeration, .integer(let integer)):
            guard integer < UInt64(property.enumLabels.count) else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "runtime enumeration index is absent from the authenticated catalog"
                )
            }
            return .string(property.enumLabels[Int(integer)])
        case (.trigger, _):
            return .bool(true)
        case (.image, .integer(let imageID)):
            let names = imageIDsByName
                .filter { $0.value == imageID }
                .map(\.key)
                .sorted()
            return names.first.map(ExperienceInteractiveValue.string) ?? .number(Double(imageID))
        case (.viewModel, .referencedInstance(let instanceID)):
            return try canonicalIdentityValue(
                instanceID,
                includeValues: includeCompositeValues,
                visiting: &visiting
            )
        case (.list, .list(let instanceIDs)):
            return .list(try instanceIDs.map {
                try canonicalIdentityValue(
                    $0,
                    includeValues: includeCompositeValues,
                    visiting: &visiting
                )
            })
        default:
            throw ExperienceInteractiveScreenError.stateContract(
                "runtime value for '\(property.name)' does not match the authenticated property kind"
            )
        }
    }

    private func canonicalIdentityValue(
        _ rawValue: UInt64,
        includeValues: Bool,
        visiting: inout Set<ExperienceInteractiveViewModelReference>
    ) throws
        -> ExperienceInteractiveValue
    {
        guard let reference = ExperienceInteractiveViewModelReference(rawValue: rawValue),
              let schemaIndex = schemaIndexByViewModel[reference],
              let schema = viewModelCatalog.schemas.first(where: { $0.index == schemaIndex }) else {
            throw ExperienceInteractiveScreenError.stateContract(
                "runtime view-model reference is absent from the authenticated topology"
            )
        }
        guard let identity = (viewModelsByIdentity
            .filter { $0.value == reference }
            .map(\.key)
            .sorted {
                let lhs = ($0.instanceID ?? "", $0.instanceName ?? "")
                let rhs = ($1.instanceID ?? "", $1.instanceName ?? "")
                return lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            }
            .first) else {
            throw ExperienceInteractiveScreenError.stateContract(
                "runtime view-model reference has no stable product identity"
            )
        }
        var fields = [ExperienceInteractiveField(
            key: "viewModelId",
            value: .string(identity.viewModelName)
        )]
        if let instanceID = identity.instanceID {
            fields.append(.init(key: "vmInstanceId", value: .string(instanceID)))
        }
        if let instanceName = identity.instanceName {
            fields.append(.init(key: "instanceName", value: .string(instanceName)))
        }
        let expandsValues = includeValues && visiting.insert(reference).inserted
        defer {
            if expandsValues { visiting.remove(reference) }
        }
        if expandsValues {
            guard let snapshot = latestSnapshot,
                  let snapshotID = snapshotTopology.snapshotID(for: reference),
                  snapshot.instances.contains(where: {
                      $0.id == snapshotID && $0.schemaIndex == schema.index
                  }) else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "runtime view-model reference is absent from the authoritative snapshot"
                )
            }
            var values: [ExperienceInteractiveField] = []
            for value in snapshot.values where value.ownerInstanceID == snapshotID {
                guard let property = viewModelCatalog.properties.first(where: {
                    $0.schemaIndex == schema.index && $0.index == value.propertyIndex
                }) else {
                    throw ExperienceInteractiveScreenError.stateContract(
                        "snapshot value is absent from the authenticated catalog"
                    )
                }
                guard let projected = try canonicalSnapshotValue(
                    value.value,
                    property: property,
                    includeCompositeValues: true,
                    visiting: &visiting
                ) else { continue }
                values.append(.init(key: property.name, value: projected))
            }
            values.sort { $0.key < $1.key }
            fields.append(.init(key: "values", value: .object(values)))
        }
        return .object(fields.sorted { $0.key < $1.key })
    }

    private func canonicalSnapshotValue(
        _ value: NuxieNativeViewModelValue,
        property: NuxieNativeViewModelCatalog.Property,
        includeCompositeValues: Bool,
        visiting: inout Set<ExperienceInteractiveViewModelReference>
    ) throws -> ExperienceInteractiveValue? {
        switch (property.kind, value) {
        case (.viewModel, .referencedInstance(let snapshotID)):
            guard let reference = snapshotTopology.reference(forSnapshotID: snapshotID),
                  viewModelsByIdentity.values.contains(reference) else {
                return nil
            }
            guard schemaIndexByViewModel[reference] != nil else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "snapshot view-model reference is absent from the authenticated topology"
                )
            }
            return try canonicalIdentityValue(
                reference.rawValue,
                includeValues: includeCompositeValues,
                visiting: &visiting
            )
        case (.list, .list(let snapshotIDs)):
            let references = snapshotIDs.compactMap {
                snapshotTopology.reference(forSnapshotID: $0)
            }
            guard references.count == snapshotIDs.count,
                  references.allSatisfy({ viewModelsByIdentity.values.contains($0) }) else {
                return nil
            }
            return .list(try references.map { reference in
                try canonicalIdentityValue(
                    reference.rawValue,
                    includeValues: includeCompositeValues,
                    visiting: &visiting
                )
            })
        default:
            return try canonicalValue(
                Self.viewModelValue(value),
                property: property,
                includeCompositeValues: false,
                visiting: &visiting
            )
        }
    }

    private struct SnapshotEnvelopeKey: Hashable {
        let viewModelName: String
        let instanceID: String?
        let instanceName: String?
        let property: String
    }

    private func normalizeSnapshotValues(
        _ values: [ExperienceInteractiveStateCommand.Value],
        staged: [ExperienceInteractiveViewModelIdentity:
            ExperienceInteractiveViewModelReference]
    ) throws -> [ExperienceInteractiveStateCommand.Value] {
        var keysByIndex: [Int: SnapshotEnvelopeKey] = [:]
        var indexesByKey: [SnapshotEnvelopeKey: [Int]] = [:]
        var identityKeys = Set<SnapshotEnvelopeKey>()
        var directKeys = Set<SnapshotEnvelopeKey>()

        for (index, value) in values.enumerated() {
            let segments = value.path.split(separator: "/").map(String.init)
            guard let first = segments.first else { continue }
            let key = SnapshotEnvelopeKey(
                viewModelName: value.viewModelName,
                instanceID: value.instanceID,
                instanceName: value.instanceName,
                property: first
            )
            if segments.count == 1 {
                directKeys.insert(key)
                continue
            }
            let owner = try viewModel(
                named: value.viewModelName,
                instanceID: value.instanceID,
                instanceName: value.instanceName,
                staged: staged
            )
            guard let schemaIndex = schemaIndexByViewModel[owner],
                  let outer = viewModelCatalog.properties.first(where: {
                      $0.schemaIndex == schemaIndex && $0.name == first
                  }), outer.kind == .viewModel else {
                continue
            }
            keysByIndex[index] = key
            indexesByKey[key, default: []].append(index)
            if segments[1] == "vmInstanceId" || segments[1] == "instanceId" {
                identityKeys.insert(key)
            }
        }
        guard directKeys.isDisjoint(with: identityKeys) else {
            throw ExperienceInteractiveScreenError.stateContract(
                "snapshot contains direct and flattened values for one view-model property"
            )
        }

        var normalized: [ExperienceInteractiveStateCommand.Value] = []
        for (index, value) in values.enumerated() {
            guard let key = keysByIndex[index],
                  identityKeys.contains(key),
                  let grouped = indexesByKey[key] else {
                normalized.append(value)
                continue
            }
            guard grouped.first == index else { continue }
            var envelope: [String: ExperienceInteractiveValue] = [:]
            for groupedIndex in grouped {
                let item = values[groupedIndex]
                let suffix = item.path.split(separator: "/").dropFirst().map(String.init)
                try insertSnapshotValue(item.value, path: suffix, into: &envelope)
            }
            if envelope["viewModelId"] == nil {
                let owner = try viewModel(
                    named: key.viewModelName,
                    instanceID: key.instanceID,
                    instanceName: key.instanceName,
                    staged: staged
                )
                guard let ownerSchema = schemaIndexByViewModel[owner],
                      let property = viewModelCatalog.properties.first(where: {
                          $0.schemaIndex == ownerSchema && $0.name == key.property
                      }),
                      let childSchemaIndex = property.referencedSchemaIndex,
                      let childSchema = viewModelCatalog.schemas.first(where: {
                          $0.index == childSchemaIndex
                      }) else {
                    throw ExperienceInteractiveScreenError.stateContract(
                        "flattened view-model envelope has no authenticated schema"
                    )
                }
                envelope["viewModelId"] = .string(childSchema.name)
            }
            normalized.append(.init(
                viewModelName: key.viewModelName,
                instanceID: key.instanceID,
                instanceName: key.instanceName,
                path: key.property,
                value: .object(envelope.keys.sorted().map {
                    ExperienceInteractiveField(key: $0, value: envelope[$0] ?? .null)
                })
            ))
        }
        return normalized
    }

    private func insertSnapshotValue(
        _ value: ExperienceInteractiveValue,
        path: [String],
        into object: inout [String: ExperienceInteractiveValue]
    ) throws {
        guard let key = path.first, !key.isEmpty else {
            throw ExperienceInteractiveScreenError.stateContract(
                "flattened view-model envelope has an empty path"
            )
        }
        if path.count == 1 {
            guard object[key] == nil else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "flattened view-model envelope repeats '\(key)'"
                )
            }
            object[key] = value
            return
        }
        var nested: [String: ExperienceInteractiveValue]
        if case .object(let fields)? = object[key] {
            nested = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
        } else if object[key] == nil {
            nested = [:]
        } else {
            throw ExperienceInteractiveScreenError.stateContract(
                "flattened view-model envelope has conflicting '\(key)' values"
            )
        }
        try insertSnapshotValue(value, path: Array(path.dropFirst()), into: &nested)
        object[key] = .object(nested.keys.sorted().map {
            ExperienceInteractiveField(key: $0, value: nested[$0] ?? .null)
        })
    }

    private func mutations(
        for value: ExperienceInteractiveStateCommand.Value,
        staged: [ExperienceInteractiveViewModelIdentity:
            ExperienceInteractiveViewModelReference]
    ) throws -> [ExperienceInteractiveStateMutation] {
        let reference = try viewModel(
            named: value.viewModelName,
            instanceID: value.instanceID,
            instanceName: value.instanceName,
            staged: staged
        )
        guard let schemaIndex = schemaIndexByViewModel[reference] else {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model has no authenticated schema"
            )
        }
        return try mutations(
            reference: reference,
            schemaIndex: schemaIndex,
            path: value.path,
            value: value.value,
            staged: staged
        )
    }

    private func mutations(
        reference: ExperienceInteractiveViewModelReference,
        schemaIndex: Int,
        path: String,
        value: ExperienceInteractiveValue,
        staged: [ExperienceInteractiveViewModelIdentity:
            ExperienceInteractiveViewModelReference]
    ) throws -> [ExperienceInteractiveStateMutation] {
        if case .object(let fields) = value,
           (try? property(at: path, startingWith: schemaIndex)) == nil {
            return try fields.sorted { $0.key < $1.key }.flatMap { field in
                try mutations(
                    reference: reference,
                    schemaIndex: schemaIndex,
                    path: path.isEmpty ? field.key : "\(path)/\(field.key)",
                    value: field.value,
                    staged: staged
                )
            }
        }
        let property = try property(at: path, startingWith: schemaIndex)
        switch (property.kind, value) {
        case (.string, .string(let string)):
            return [.setString(reference, path: path, value: Data(string.utf8))]
        case (.string, .bytes(let bytes)):
            return [.setString(reference, path: path, value: bytes)]
        case (.number, .number(let number)) where number.isFinite:
            return [.setNumber(reference, path: path, value: Float(number))]
        case (.bool, .bool(let bool)):
            return [.setBool(reference, path: path, value: bool)]
        case (.color, .number(let number))
            where number.isFinite && number >= 0 && number <= Double(UInt32.max)
                && number.rounded() == number:
            return [.setColor(reference, path: path, value: UInt32(number))]
        case (.enumeration, .string(let label)):
            guard let index = property.enumLabels.firstIndex(of: label) else {
                throw ExperienceInteractiveScreenError.stateContract(path)
            }
            return [.setEnumeration(reference, path: path, value: UInt64(index))]
        case (.enumeration, .number(let number))
            where number.isFinite && number >= 0 && number.rounded() == number,
             (.listIndex, .number(let number))
            where number.isFinite && number >= 0 && number.rounded() == number:
            guard let integer = Self.exactUnsignedStateValue(number) else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "value for '\(path)' is outside the unsigned 64-bit range"
                )
            }
            return [property.kind == .enumeration
                ? .setEnumeration(reference, path: path, value: integer)
                : .setListIndex(reference, path: path, value: integer)]
        case (.trigger, .bool(true)):
            return [.fireTrigger(reference, path: path)]
        case (.trigger, .number(let number)) where number != 0:
            return [.fireTrigger(reference, path: path)]
        case (.image, .string(let name)):
            guard let imageID = imageIDsByName[name] else {
                throw ExperienceInteractiveScreenError.stateContract(path)
            }
            return [.setImage(reference, path: path, value: imageID)]
        case (.image, .number(let number))
            where number.isFinite && number >= 0 && number.rounded() == number:
            guard let imageID = Self.exactUnsignedStateValue(number) else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "image value for '\(path)' is outside the unsigned 64-bit range"
                )
            }
            return [.setImage(reference, path: path, value: imageID)]
        case (.viewModel, .object(let fields)):
            let child = try referencedViewModel(from: value, staged: staged)
            guard let childSchemaIndex = schemaIndexByViewModel[child],
                  property.referencedSchemaIndex == nil
                    || property.referencedSchemaIndex == childSchemaIndex else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "view-model value for '\(path)' has the wrong authenticated schema"
                )
            }
            var result: [ExperienceInteractiveStateMutation] = [
                .setViewModel(reference, path: path, value: child),
            ]
            for field in try canonicalEnvelopeFields(fields) {
                result.append(contentsOf: try mutations(
                    reference: child,
                    schemaIndex: childSchemaIndex,
                    path: field.key,
                    value: field.value,
                    staged: staged
                ))
            }
            return result
        case (.list, .list(let values)):
            var result: [ExperienceInteractiveStateMutation] = [
                .listClear(reference, path: path),
            ]
            for (index, item) in values.enumerated() {
                let child = try referencedViewModel(from: item, staged: staged)
                guard let childSchemaIndex = schemaIndexByViewModel[child],
                      property.referencedSchemaIndex == nil
                        || property.referencedSchemaIndex == childSchemaIndex else {
                    throw ExperienceInteractiveScreenError.stateContract(
                        "list item for '\(path)' has the wrong authenticated schema"
                    )
                }
                if case .object(let fields) = item {
                    for field in try canonicalEnvelopeFields(fields) {
                        result.append(contentsOf: try mutations(
                            reference: child,
                            schemaIndex: childSchemaIndex,
                            path: field.key,
                            value: field.value,
                            staged: staged
                        ))
                    }
                }
                result.append(.listInsert(
                    reference,
                    path: path,
                    index: index,
                    value: child
                ))
            }
            return result
        default:
            throw ExperienceInteractiveScreenError.stateContract(
                "value for '\(path)' does not match \(property.kind)"
            )
        }
    }

    private func uniqueStateObject(
        _ fields: [ExperienceInteractiveField]
    ) throws -> [String: ExperienceInteractiveValue] {
        var result: [String: ExperienceInteractiveValue] = [:]
        for field in fields {
            guard result.updateValue(field.value, forKey: field.key) == nil else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "view-model envelope repeats '\(field.key)'"
                )
            }
        }
        return result
    }

    private func canonicalEnvelopeFields(
        _ fields: [ExperienceInteractiveField]
    ) throws -> [ExperienceInteractiveField] {
        let object = try uniqueStateObject(fields)
        let metadata = Set([
            "viewModelId", "vmInstanceId", "instanceId", "instanceName", "values",
        ])
        var values = object.filter { !metadata.contains($0.key) }
        if let nested = object["values"] {
            guard case .object(let nestedFields) = nested else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "view-model envelope has non-object values"
                )
            }
            for (key, value) in try uniqueStateObject(nestedFields) {
                guard values.updateValue(value, forKey: key) == nil else {
                    throw ExperienceInteractiveScreenError.stateContract(
                        "view-model envelope conflicts on '\(key)'"
                    )
                }
            }
        }
        return values.keys.sorted().map {
            ExperienceInteractiveField(key: $0, value: values[$0] ?? .null)
        }
    }

    nonisolated static func exactUnsignedStateValue(_ number: Double) -> UInt64? {
        guard number.isFinite, number >= 0, number.rounded() == number else { return nil }
        return UInt64(exactly: number)
    }

    private func property(
        at path: String,
        startingWith initialSchemaIndex: Int
    ) throws -> NuxieNativeViewModelCatalog.Property {
        if let exact = viewModelCatalog.properties.first(where: {
            $0.schemaIndex == initialSchemaIndex && $0.name == path
        }) {
            return exact
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !segments.isEmpty, !segments.contains(where: \.isEmpty) else {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model property '\(path)' has an invalid path"
            )
        }
        var schemaIndex = initialSchemaIndex
        for (offset, segment) in segments.enumerated() {
            guard let property = viewModelCatalog.properties.first(where: {
                $0.schemaIndex == schemaIndex && $0.name == segment
            }) else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "view-model property '\(path)' is absent from the authenticated catalog"
                )
            }
            if offset == segments.count - 1 { return property }
            guard property.kind == .viewModel,
                  let referencedSchemaIndex = property.referencedSchemaIndex else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "view-model property '\(path)' crosses a non-composite value"
                )
            }
            schemaIndex = referencedSchemaIndex
        }
        throw ExperienceInteractiveScreenError.stateContract(path)
    }

    private func referencedViewModel(
        from value: ExperienceInteractiveValue,
        staged: [ExperienceInteractiveViewModelIdentity:
            ExperienceInteractiveViewModelReference]
    ) throws -> ExperienceInteractiveViewModelReference {
        guard case .object(let fields) = value else {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model references require an identity object"
            )
        }
        let object = try uniqueStateObject(fields)
        guard case .string(let viewModelName)? = object["viewModelId"] else {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model reference has no viewModelId"
            )
        }
        let instanceID: String? = switch object["vmInstanceId"] ?? object["instanceId"] {
        case .string(let value): value
        default: nil
        }
        let instanceName: String? = switch object["instanceName"] {
        case .string(let value): value
        default: nil
        }
        return try viewModel(
            named: viewModelName,
            instanceID: instanceID,
            instanceName: instanceName,
            staged: staged
        )
    }

    func snapshot() async throws -> ExperienceInteractiveViewModelSnapshot {
        let runtime = runtime
        let value = try await operationGate.withLock { try await runtime.snapshot() }
        return ExperienceInteractiveViewModelSnapshot(
            rootInstanceID: value.rootInstanceID,
            instances: value.instances.map {
                ExperienceInteractiveViewModelSnapshot.Instance(
                    id: $0.id,
                    schemaIndex: $0.schemaIndex,
                    valueRange: $0.valueRange
                )
            },
            values: value.values.map {
                ExperienceInteractiveViewModelSnapshot.Value(
                    ownerInstanceID: $0.ownerInstanceID,
                    propertyIndex: $0.propertyIndex,
                    name: $0.name,
                    value: Self.viewModelValue($0.value)
                )
            }
        )
    }

    /// Applies signed manifest text policy before mutating authored Rive runs.
    @discardableResult
    func setText(inputID: String, value: String) async throws -> Bool {
        guard let input = textInputs[inputID] else {
            throw ExperienceInteractiveScreenError.textInputNotFound(inputID)
        }
        guard input.editable else {
            throw ExperienceInteractiveScreenError.textInputNotEditable(inputID)
        }
        let limited = input.maxLength.map { String(value.prefix($0)) } ?? value
        let runtime = runtime
        return try await operationGate.withLock {
            try await runtime.setTextRuns([
                NuxieNativeTextRunMutation(
                    name: input.riveTextRunName,
                    text: Data(limited.utf8)
                )
            ])
        }
    }

    func metalDevice() async throws -> ExperienceInteractiveMetalDevice {
        ExperienceInteractiveMetalDevice(value: try await runtime.metalDevice().value)
    }

    func resize(pixelWidth: UInt32, pixelHeight: UInt32) async throws
        -> ExperienceInteractiveRenderOutcome
    {
        let runtime = runtime
        return try await operationGate.withLock {
            Self.renderOutcome(
                try await runtime.resize(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            )
        }
    }

    func render(
        drawable: ExperienceInteractiveDrawable?,
        isOccluded: Bool = false,
        clearColor: UInt32 = 0,
        completion: (@Sendable () -> Void)? = nil
    ) async throws -> ExperienceInteractiveRenderOutcome {
        let state: NuxieNativeDrawableState
        if let drawable {
            state = .available(NuxieNativeDrawable(drawable.value))
        } else {
            state = isOccluded ? .occluded : .timeout
        }
        let runtime = runtime
        return try await operationGate.withLock {
            Self.renderOutcome(
                try await runtime.render(
                    drawable: state,
                    clearColor: clearColor,
                    completion: completion
                )
            )
        }
    }

    func detachRenderer() async throws -> ExperienceInteractiveRenderOutcome {
        let runtime = runtime
        return try await operationGate.withLock {
            Self.renderOutcome(try await runtime.detachRenderer())
        }
    }

    func reattachRenderer(pixelWidth: UInt32, pixelHeight: UInt32) async throws
        -> ExperienceInteractiveRenderOutcome
    {
        let runtime = runtime
        return try await operationGate.withLock {
            Self.renderOutcome(try await runtime.reattachRenderer(
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            ))
        }
    }

    func resetPlayerRendererDomain() async throws {
        let runtime = runtime
        try await operationGate.withLock {
            try await runtime.resetPlayerRendererDomain()
        }
    }

    func close() async throws {
        let runtime = runtime
        defer { fontScope.close() }
        try await operationGate.withLock { try await runtime.close() }
    }

    private static func nativeInput(_ input: ExperienceInteractiveInput)
        -> NuxieNativePlayerInput
    {
        switch input {
        case .bool(let name, let value): .bool(name: name, value: value)
        case .number(let name, let value): .number(name: name, value: value)
        case .trigger(let name): .trigger(name: name)
        }
    }

    private static func nativePointer(_ pointer: ExperienceInteractivePointerEvent)
        -> NuxieNativePointerEvent
    {
        let kind: NuxieNativePointerKind = switch pointer.kind {
        case .down: .down
        case .move: .move
        case .up: .up
        case .exit: .exit
        }
        return NuxieNativePointerEvent(
            kind: kind,
            x: pointer.x,
            y: pointer.y,
            pointerID: pointer.pointerID,
            timestamp: pointer.timestamp
        )
    }

    private static func nativeMutation(_ mutation: ExperienceInteractiveStateMutation)
        -> NuxieNativeViewModelMutation
    {
        switch mutation {
        case .setString(let owner, let path, let value):
            .setString(instance: nativeReference(owner), path: path, value: value)
        case .setNumber(let owner, let path, let value):
            .setNumber(instance: nativeReference(owner), path: path, value: value)
        case .setBool(let owner, let path, let value):
            .setBool(instance: nativeReference(owner), path: path, value: value)
        case .setColor(let owner, let path, let value):
            .setColor(instance: nativeReference(owner), path: path, value: value)
        case .setEnumeration(let owner, let path, let value):
            .setEnumeration(instance: nativeReference(owner), path: path, value: value)
        case .fireTrigger(let owner, let path):
            .fireTrigger(instance: nativeReference(owner), path: path)
        case .setListIndex(let owner, let path, let value):
            .setListIndex(instance: nativeReference(owner), path: path, value: value)
        case .setImage(let owner, let path, let value):
            .setImage(instance: nativeReference(owner), path: path, value: value)
        case .setViewModel(let owner, let path, let value):
            .setViewModel(
                instance: nativeReference(owner),
                path: path,
                value: nativeReference(value)
            )
        case .listInsert(let owner, let path, let index, let value):
            .listInsert(
                instance: nativeReference(owner),
                path: path,
                index: index,
                value: nativeReference(value)
            )
        case .listRemove(let owner, let path, let index):
            .listRemove(instance: nativeReference(owner), path: path, index: index)
        case .listSwap(let owner, let path, let first, let second):
            .listSwap(
                instance: nativeReference(owner),
                path: path,
                first: first,
                second: second
            )
        case .listMove(let owner, let path, let from, let to):
            .listMove(
                instance: nativeReference(owner),
                path: path,
                from: from,
                to: to
            )
        case .listSet(let owner, let path, let index, let value):
            .listSet(
                instance: nativeReference(owner),
                path: path,
                index: index,
                value: nativeReference(value)
            )
        case .listClear(let owner, let path):
            .listClear(instance: nativeReference(owner), path: path)
        }
    }

    private static func nativeReference(_ reference: ExperienceInteractiveViewModelReference)
        -> NuxieNativeViewModelReference
    {
        NuxieNativeViewModelReference(rawValue: reference.rawValue)!
    }

    private static func pointerHit(_ hit: NuxieNativePointerHit)
        -> ExperienceInteractivePointerHit
    {
        switch hit {
        case .none: .none
        case .hit: .hit
        case .opaque: .opaque
        }
    }

    private static func renderOutcome(_ outcome: NuxieNativeRendererOutcome)
        -> ExperienceInteractiveRenderOutcome
    {
        let disposition: ExperienceInteractiveRenderDisposition = switch outcome.disposition {
        case .none: .none
        case .presented: .presented
        case .skippedZeroSize: .skippedZeroSize
        case .skippedTimeout: .skippedTimeout
        case .skippedOccluded: .skippedOccluded
        case .reconfigured: .reconfigured
        case .recreated: .recreated
        case .deviceLost: .deviceLost
        case .outOfMemory: .outOfMemory
        }
        let health: ExperienceInteractiveRendererHealth = switch outcome.health {
        case .healthy: .healthy
        case .deviceLost: .deviceLost
        case .outOfMemory: .outOfMemory
        case .failed: .failed
        }
        return ExperienceInteractiveRenderOutcome(
            disposition: disposition,
            health: health,
            pixelWidth: outcome.pixelWidth,
            pixelHeight: outcome.pixelHeight,
            drawCalls: outcome.drawCalls
        )
    }

    private static func reportedEvent(_ event: NuxieNativeEvent)
        -> ExperienceInteractiveReportedEvent
    {
        ExperienceInteractiveReportedEvent(
            localIndex: event.localIndex,
            coreType: event.coreType,
            name: event.name,
            url: event.url,
            target: event.target,
            delay: event.delay,
            properties: event.properties.map { property in
                ExperienceInteractiveField(
                    key: property.name,
                    value: eventValue(property.value)
                )
            }
        )
    }

    private static func eventValue(_ value: NuxieNativeEventPropertyValue)
        -> ExperienceInteractiveValue
    {
        switch value {
        case .number(let value): .number(Double(value))
        case .bool(let value): .bool(value)
        case .bytes(let value): .bytes(value)
        case .color(let value): .number(Double(value))
        case .enumeration(let value): .number(Double(value))
        case .trigger: .null
        }
    }

    private static func viewModelChange(_ change: NuxieNativeViewModelChange)
        -> ExperienceInteractiveViewModelChange
    {
        ExperienceInteractiveViewModelChange(
            origin: change.origin == .caller ? .caller : .runtime,
            correlationID: change.correlationID,
            ownerInstanceID: change.ownerInstanceID,
            propertyIndex: change.propertyIndex,
            value: viewModelValue(change.value)
        )
    }

    private static func viewModelValue(_ value: NuxieNativeViewModelValue)
        -> ExperienceInteractiveViewModelValue
    {
        switch value {
        case .unsupported: .unsupported
        case .bytes(let value): .bytes(value)
        case .number(let value): .number(value)
        case .bool(let value): .bool(value)
        case .integer(let value): .integer(value)
        case .referencedInstance(let value): .referencedInstance(value)
        case .list(let value): .list(value)
        }
    }

    private static func hostCommand(_ command: NuxieNativeHostCommand)
        -> ExperienceInteractiveHostCommand
    {
        ExperienceInteractiveHostCommand(
            name: command.name,
            payload: hostValue(command.value)
        )
    }

    private static func hostValue(_ value: NuxieNativeHostValue)
        -> ExperienceInteractiveValue
    {
        switch value {
        case .null: .null
        case .bool(let value): .bool(value)
        case .number(let value): .number(value)
        case .string(let value): .string(value)
        case .list(let values): .list(values.map(hostValue))
        case .object(let fields): .object(fields.map {
            ExperienceInteractiveField(key: $0.key, value: hostValue($0.value))
        })
        }
    }
}

private enum ExperienceInteractiveInitialState {
    struct Result {
        let rootReference: ExperienceInteractiveViewModelReference?
        let catalog: NuxieNativeViewModelCatalog
        let viewModelsByIdentity:
            [ExperienceInteractiveViewModelIdentity: ExperienceInteractiveViewModelReference]
        let viewModelsByProperty:
            [ExperienceInteractiveViewModelPropertyIdentity:
                ExperienceInteractiveViewModelReference]
        let schemaIndexByViewModel: [ExperienceInteractiveViewModelReference: Int]
        let listIndexPathsBySchema: [Int: [String]]
        let itemsByList:
            [ExperienceInteractiveListIdentity: [ExperienceInteractiveViewModelReference]]
    }

    private struct RemoteIdentity: Hashable {
        let viewModelName: String
        let instanceID: String
    }

    private struct AuthoredIdentity: Hashable {
        let viewModelName: String
        let instanceName: String?
    }

    private enum Selection: Hashable {
        case root
        case remote(RemoteIdentity)
        case authored(AuthoredIdentity)
    }

    private struct AllocationRequest {
        let selection: Selection
        let schema: NuxieNativeViewModelCatalog.Schema
        let instanceName: String?
    }

    private struct ReferencedInstance {
        let selection: Selection
        let schema: NuxieNativeViewModelCatalog.Schema
        let values: [String: Any]
    }

    private struct OuterViewModelKey: Hashable {
        let ownerName: String
        let ownerInstanceID: String?
        let ownerInstanceName: String?
        let propertyName: String
    }

    static func apply(
        journey: JourneyDocument,
        screen: JourneyScreen,
        manifest: NuxPackageManifestV1,
        runtime: NuxieNativeRuntime
    ) async throws -> Result {
        let sourceValues = journey.viewModelValues ?? []
        let catalog = try await runtime.viewModelCatalog()
        let listIndexPathsBySchema = Dictionary(grouping: catalog.properties.filter {
            $0.kind == .listIndex
        }, by: \.schemaIndex).mapValues { $0.map(\.name) }
        guard let requestedSchemaName = screen.defaultViewModelName else {
            guard sourceValues.isEmpty else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "screen '\(screen.id)' supplies state without a default view model"
                )
            }
            return Result(
                rootReference: nil,
                catalog: catalog,
                viewModelsByIdentity: [:],
                viewModelsByProperty: [:],
                schemaIndexByViewModel: [:],
                listIndexPathsBySchema: listIndexPathsBySchema,
                itemsByList: [:]
            )
        }

        let snapshot = try await runtime.snapshot()
        guard let root = snapshot.instances.first(where: {
            $0.id == snapshot.rootInstanceID
        }),
        let rootSchema = catalog.schemas.first(where: {
            $0.index == root.schemaIndex
        }),
        rootSchema.name == requestedSchemaName else {
            throw ExperienceInteractiveScreenError.stateContract(
                "screen '\(screen.id)' requests view model '\(requestedSchemaName)' "
                    + "but the authored root does not match"
            )
        }
        guard let nativeRoot = NuxieNativeViewModelReference(
            rawValue: snapshot.rootInstanceID
        ),
        let productRoot = ExperienceInteractiveViewModelReference(
            rawValue: snapshot.rootInstanceID
        ) else {
            throw ExperienceInteractiveScreenError.stateContract(
                "the authored root view model has an invalid identity"
            )
        }
        let values = try normalizeOuterViewModelEnvelopes(sourceValues, catalog: catalog)

        let rootIdentity = ExperienceInteractiveViewModelIdentity(
            viewModelName: requestedSchemaName,
            instanceID: nil,
            instanceName: nil
        )
        var productReferences = [rootIdentity: productRoot]
        var schemaIndexByReference = [productRoot: rootSchema.index]
        if let instanceID = screen.defaultInstanceId {
            productReferences[ExperienceInteractiveViewModelIdentity(
                viewModelName: requestedSchemaName,
                instanceID: instanceID,
                instanceName: nil
            )] = productRoot
        }
        let schemaHints = try schemaHintsByRemoteID(values, catalog: catalog)
        var requests: [Selection: AllocationRequest] = [:]
        var requestOrder: [Selection] = []
        for value in values {
            let schema = try resolveSchema(value.viewModelName, catalog: catalog)
            let selection = try ownerSelection(
                value,
                schema: schema,
                rootSchema: rootSchema,
                defaultInstanceID: screen.defaultInstanceId
            )
            try register(
                AllocationRequest(
                    selection: selection,
                    schema: schema,
                    instanceName: value.instanceName
                ),
                requests: &requests,
                order: &requestOrder
            )
            let property = try resolveProperty(
                value.path,
                schema: schema,
                catalog: catalog
            )
            if property.kind == .viewModel, !value.path.contains("/") {
                let referenced = try referencedInstance(
                    value.value.value,
                    expectedSchemaIndex: property.referencedSchemaIndex,
                    schemaHints: schemaHints,
                    catalog: catalog,
                    path: value.path
                )
                try register(
                    AllocationRequest(
                        selection: referenced.selection,
                        schema: referenced.schema,
                        instanceName: referencedInstanceName(value.value.value)
                    ),
                    requests: &requests,
                    order: &requestOrder
                )
            } else if property.kind == .list, !value.path.contains("/") {
                guard let rows = arrayValue(value.value.value) else {
                    throw stateValue(value.path)
                }
                for row in rows {
                    let referenced = try referencedInstance(
                        row,
                        expectedSchemaIndex: nil,
                        schemaHints: schemaHints,
                        catalog: catalog,
                        path: value.path
                    )
                    try register(
                        AllocationRequest(
                            selection: referenced.selection,
                            schema: referenced.schema,
                            instanceName: referencedInstanceName(row)
                        ),
                        requests: &requests,
                        order: &requestOrder
                    )
                }
            }
        }

        var nativeReferences: [Selection: NuxieNativeViewModelReference] = [.root: nativeRoot]
        for selection in requestOrder where selection != .root {
            guard let request = requests[selection] else { continue }
            let authoredIndex = try authoredInstanceIndex(
                request.instanceName,
                schema: request.schema,
                catalog: catalog
            )
            let reference = try await runtime.makeViewModel(
                schemaIndex: request.schema.index,
                authoredInstanceIndex: authoredIndex
            )
            nativeReferences[selection] = reference
            let identity: ExperienceInteractiveViewModelIdentity
            switch selection {
            case .root:
                continue
            case .remote(let remote):
                identity = ExperienceInteractiveViewModelIdentity(
                    viewModelName: remote.viewModelName,
                    instanceID: remote.instanceID
                )
            case .authored(let authored):
                identity = ExperienceInteractiveViewModelIdentity(
                    viewModelName: authored.viewModelName,
                    instanceID: nil,
                    instanceName: authored.instanceName
                )
            }
            productReferences[identity] = ExperienceInteractiveViewModelReference(
                rawValue: reference.rawValue
            )
            if let productReference = ExperienceInteractiveViewModelReference(
                rawValue: reference.rawValue
            ) {
                schemaIndexByReference[productReference] = request.schema.index
            }
        }

        let imageIDs = try ExperienceInteractiveImageIdentityMap.make(
            images: manifest.assets.images
        )
        var detachedMutations: [Selection: [NuxieNativeViewModelMutation]] = [:]
        var finalMutations: [Selection: [NuxieNativeViewModelMutation]] = [:]
        var viewModelsByProperty: [
            ExperienceInteractiveViewModelPropertyIdentity:
                ExperienceInteractiveViewModelReference
        ] = [:]
        var itemsByList: [
            ExperienceInteractiveListIdentity: [ExperienceInteractiveViewModelReference]
        ] = [:]
        for value in values {
            let schema = try resolveSchema(value.viewModelName, catalog: catalog)
            let owner = try ownerSelection(
                value,
                schema: schema,
                rootSchema: rootSchema,
                defaultInstanceID: screen.defaultInstanceId
            )
            guard let reference = nativeReferences[owner] else {
                throw ExperienceInteractiveScreenError.stateContract(value.path)
            }
            let property = try resolveProperty(value.path, schema: schema, catalog: catalog)
            switch property.kind {
            case .viewModel where !value.path.contains("/"):
                let referenced = try referencedInstance(
                    value.value.value,
                    expectedSchemaIndex: property.referencedSchemaIndex,
                    schemaHints: schemaHints,
                    catalog: catalog,
                    path: value.path
                )
                guard let child = nativeReferences[referenced.selection] else {
                    throw ExperienceInteractiveScreenError.stateContract(value.path)
                }
                finalMutations[owner, default: []].append(.setViewModel(
                    instance: reference,
                    path: value.path,
                    value: child
                ))
                guard let productOwner = ExperienceInteractiveViewModelReference(
                    rawValue: reference.rawValue
                ), let productChild = ExperienceInteractiveViewModelReference(
                    rawValue: child.rawValue
                ) else {
                    throw ExperienceInteractiveScreenError.stateContract(value.path)
                }
                viewModelsByProperty[ExperienceInteractiveViewModelPropertyIdentity(
                    owner: productOwner,
                    path: value.path
                )] = productChild
                detachedMutations[referenced.selection, default: []] += try scalarMutations(
                    referenced.values,
                    reference: child,
                    schema: referenced.schema,
                    catalog: catalog,
                    imageIDs: imageIDs
                )
            case .list where !value.path.contains("/"):
                guard let rows = arrayValue(value.value.value) else {
                    throw stateValue(value.path)
                }
                finalMutations[owner, default: []].append(.listClear(
                    instance: reference,
                    path: value.path
                ))
                var productRows: [ExperienceInteractiveViewModelReference] = []
                for (index, row) in rows.enumerated() {
                    let referenced = try referencedInstance(
                        row,
                        expectedSchemaIndex: nil,
                        schemaHints: schemaHints,
                        catalog: catalog,
                        path: value.path
                    )
                    guard let child = nativeReferences[referenced.selection] else {
                        throw ExperienceInteractiveScreenError.stateContract(value.path)
                    }
                    guard let productChild = ExperienceInteractiveViewModelReference(
                        rawValue: child.rawValue
                    ) else {
                        throw ExperienceInteractiveScreenError.stateContract(value.path)
                    }
                    productRows.append(productChild)
                    finalMutations[owner, default: []].append(.listInsert(
                        instance: reference,
                        path: value.path,
                        index: index,
                        value: child
                    ))
                    detachedMutations[referenced.selection, default: []]
                        += try scalarMutations(
                        referenced.values,
                        reference: child,
                        schema: referenced.schema,
                        catalog: catalog,
                        imageIDs: imageIDs,
                        includeListIndexes: false
                    )
                    detachedMutations[referenced.selection, default: []]
                        += ExperienceInteractiveListIndexPlanner.mutations(
                            reference: child,
                            schemaIndex: referenced.schema.index,
                            properties: catalog.properties,
                            index: index
                        )
                }
                guard let productOwner = ExperienceInteractiveViewModelReference(
                    rawValue: reference.rawValue
                ) else {
                    throw ExperienceInteractiveScreenError.stateContract(value.path)
                }
                itemsByList[ExperienceInteractiveListIdentity(
                    owner: productOwner,
                    path: value.path
                )] = productRows
            default:
                let prepared = try mutation(
                    reference: reference,
                    path: value.path,
                    property: property,
                    rawValue: value.value.value,
                    imageIDs: imageIDs
                )
                if owner == .root {
                    finalMutations[owner, default: []].append(prepared)
                } else {
                    detachedMutations[owner, default: []].append(prepared)
                }
            }
        }
        for selection in requestOrder where selection != .root {
            guard let mutations = detachedMutations[selection], !mutations.isEmpty else {
                continue
            }
            _ = try await runtime.mutateViewModel(mutations, correlationID: 0)
        }
        for selection in requestOrder where selection != .root {
            guard let mutations = finalMutations[selection], !mutations.isEmpty else {
                continue
            }
            _ = try await runtime.mutateViewModel(mutations, correlationID: 0)
        }
        if let mutations = finalMutations[.root], !mutations.isEmpty {
            _ = try await runtime.mutateViewModel(mutations, correlationID: 0)
        }
        return Result(
            rootReference: productRoot,
            catalog: catalog,
            viewModelsByIdentity: productReferences,
            viewModelsByProperty: viewModelsByProperty,
            schemaIndexByViewModel: schemaIndexByReference,
            listIndexPathsBySchema: listIndexPathsBySchema,
            itemsByList: itemsByList
        )
    }

    private static func ownerSelection(
        _ value: JourneyViewModelValue,
        schema: NuxieNativeViewModelCatalog.Schema,
        rootSchema: NuxieNativeViewModelCatalog.Schema,
        defaultInstanceID: String?
    ) throws -> Selection {
        if schema.index == rootSchema.index {
            if let instanceID = value.instanceId {
                if instanceID == defaultInstanceID { return .root }
            } else if value.instanceName == nil {
                return .root
            }
        }
        if let instanceID = value.instanceId {
            guard !instanceID.isEmpty else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "view-model instance identity cannot be empty"
                )
            }
            return .remote(RemoteIdentity(
                viewModelName: schema.name,
                instanceID: instanceID
            ))
        }
        return .authored(AuthoredIdentity(
            viewModelName: schema.name,
            instanceName: value.instanceName
        ))
    }

    private static func register(
        _ request: AllocationRequest,
        requests: inout [Selection: AllocationRequest],
        order: inout [Selection]
    ) throws {
        if case .remote(let remote) = request.selection,
           requests.keys.contains(where: {
               guard case .remote(let existing) = $0 else { return false }
               return existing.instanceID == remote.instanceID
                   && existing.viewModelName != remote.viewModelName
           }) {
            throw ExperienceInteractiveScreenError.stateContract(
                "instance '\(remote.instanceID)' names multiple view models"
            )
        }
        if let existing = requests[request.selection] {
            guard existing.schema.index == request.schema.index,
                  existing.instanceName == nil
                    || request.instanceName == nil
                    || existing.instanceName == request.instanceName else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "one view-model identity has conflicting authored instance selectors"
                )
            }
            if existing.instanceName == nil, request.instanceName != nil {
                requests[request.selection] = request
            }
            return
        }
        requests[request.selection] = request
        order.append(request.selection)
    }

    private static func resolveSchema(
        _ name: String,
        catalog: NuxieNativeViewModelCatalog
    ) throws -> NuxieNativeViewModelCatalog.Schema {
        let matches = catalog.schemas.filter { $0.name == name }
        guard matches.count == 1, let schema = matches.first else {
            throw ExperienceInteractiveScreenError.stateContract(
                "view model '\(name)' does not resolve exactly once"
            )
        }
        return schema
    }

    private static func resolveProperty(
        _ path: String,
        schema: NuxieNativeViewModelCatalog.Schema,
        catalog: NuxieNativeViewModelCatalog
    ) throws -> NuxieNativeViewModelCatalog.Property {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty, !segments.contains(where: \.isEmpty) else {
            throw ExperienceInteractiveScreenError.stateContract(
                "view model '\(schema.name)' has invalid path '\(path)'"
            )
        }
        var currentSchema = schema
        for (index, segment) in segments.enumerated() {
            let matches = catalog.properties.filter {
                $0.schemaIndex == currentSchema.index && $0.name == segment
            }
            guard matches.count == 1, let property = matches.first else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "view model '\(currentSchema.name)' does not resolve '\(segment)' exactly once"
                )
            }
            if index == segments.count - 1 { return property }
            guard property.kind == .viewModel,
                  let referenced = property.referencedSchemaIndex,
                  let next = catalog.schemas.first(where: { $0.index == referenced }) else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "view model path '\(path)' crosses a non-view-model property"
                )
            }
            currentSchema = next
        }
        preconditionFailure("validated nonempty path has no property")
    }

    private static func authoredInstanceIndex(
        _ instanceName: String?,
        schema: NuxieNativeViewModelCatalog.Schema,
        catalog: NuxieNativeViewModelCatalog
    ) throws -> Int? {
        guard let instanceName else { return nil }
        let matches = catalog.authoredInstances.filter {
            $0.schemaIndex == schema.index && $0.name == instanceName
        }
        guard matches.count == 1 else {
            throw ExperienceInteractiveScreenError.stateContract(
                "authored instance '\(instanceName)' does not resolve exactly once"
            )
        }
        return matches[0].index
    }

    private static func schemaHintsByRemoteID(
        _ values: [JourneyViewModelValue],
        catalog: NuxieNativeViewModelCatalog
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for value in values {
            guard let instanceID = value.instanceId else { continue }
            guard !instanceID.isEmpty else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "view-model instance identity cannot be empty"
                )
            }
            let schema = try resolveSchema(value.viewModelName, catalog: catalog)
            if let existing = result[instanceID], existing != schema.name {
                throw ExperienceInteractiveScreenError.stateContract(
                    "instance '\(instanceID)' names multiple view models"
                )
            }
            result[instanceID] = schema.name
        }
        return result
    }

    private static func referencedInstance(
        _ rawValue: Any,
        expectedSchemaIndex: Int?,
        schemaHints: [String: String],
        catalog: NuxieNativeViewModelCatalog,
        path: String
    ) throws -> ReferencedInstance {
        guard let dictionary = dictionaryValue(rawValue) else {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model reference at '\(path)' requires an object value"
            )
        }
        let vmInstanceID = dictionary["vmInstanceId"] as? String
        let instanceID = dictionary["instanceId"] as? String
        if let vmInstanceID, let instanceID, vmInstanceID != instanceID {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model reference at '\(path)' has conflicting stable identities"
            )
        }
        guard let remoteID = vmInstanceID ?? instanceID, !remoteID.isEmpty else {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model reference at '\(path)' requires a nonempty stable identity"
            )
        }

        let expectedSchema = expectedSchemaIndex.flatMap { expected in
            catalog.schemas.first(where: { $0.index == expected })
        }
        if expectedSchemaIndex != nil, expectedSchema == nil {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model reference at '\(path)' has no authored schema"
            )
        }
        let explicitName = dictionary["viewModelId"] as? String
        let hintedName = schemaHints[remoteID]
        if let explicitName, let hintedName, explicitName != hintedName {
            throw ExperienceInteractiveScreenError.stateContract(
                "instance '\(remoteID)' names multiple view models"
            )
        }
        let schema = try resolveSchema(
            explicitName ?? hintedName ?? expectedSchema?.name ?? "",
            catalog: catalog
        )
        if let expectedSchema, expectedSchema.index != schema.index {
            throw ExperienceInteractiveScreenError.stateContract(
                "view-model reference at '\(path)' names '\(schema.name)' instead of "
                    + "'\(expectedSchema.name)'"
            )
        }
        let values: [String: Any]
        if let rawValues = dictionary["values"] {
            guard let decoded = dictionaryValue(rawValues) else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "view-model reference at '\(path)' has non-object values"
                )
            }
            values = decoded
        } else {
            values = dictionary.filter { !referencedMetadataKeys.contains($0.key) }
        }
        return ReferencedInstance(
            selection: .remote(RemoteIdentity(
                viewModelName: schema.name,
                instanceID: remoteID
            )),
            schema: schema,
            values: values
        )
    }

    private static let referencedMetadataKeys: Set<String> = [
        "vmInstanceId", "instanceId", "viewModelId", "instanceName", "values",
    ]

    private static func referencedInstanceName(_ rawValue: Any) -> String? {
        dictionaryValue(rawValue)?["instanceName"] as? String
    }

    private static func scalarMutations(
        _ values: [String: Any],
        reference: NuxieNativeViewModelReference,
        schema: NuxieNativeViewModelCatalog.Schema,
        catalog: NuxieNativeViewModelCatalog,
        imageIDs: [String: UInt64],
        includeListIndexes: Bool = true
    ) throws -> [NuxieNativeViewModelMutation] {
        try values.keys.sorted().compactMap { path in
            guard let rawValue = values[path] else {
                throw ExperienceInteractiveScreenError.stateContract(path)
            }
            let property = try resolveProperty(path, schema: schema, catalog: catalog)
            if property.kind == .listIndex, !includeListIndexes { return nil }
            guard property.kind != .viewModel, property.kind != .list else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "nested structural state at '\(path)' is outside the initial-state contract"
                )
            }
            return try mutation(
                reference: reference,
                path: path,
                property: property,
                rawValue: rawValue,
                imageIDs: imageIDs
            )
        }
    }

    /// The publisher flattens object leaves. Reassemble one top-level
    /// identity-bearing ViewModel envelope so the native batch can allocate,
    /// hydrate, and link that replacement atomically.
    private static func normalizeOuterViewModelEnvelopes(
        _ values: [JourneyViewModelValue],
        catalog: NuxieNativeViewModelCatalog
    ) throws -> [JourneyViewModelValue] {
        var keyByIndex: [Int: OuterViewModelKey] = [:]
        var indexesByKey: [OuterViewModelKey: [Int]] = [:]
        var identityBearing = Set<OuterViewModelKey>()
        var direct = Set<OuterViewModelKey>()

        for (index, value) in values.enumerated() {
            let segments = value.path
                .split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)
            guard !segments.isEmpty, !segments.contains(where: \.isEmpty) else { continue }
            let schema = try resolveSchema(value.viewModelName, catalog: catalog)
            let matches = catalog.properties.filter {
                $0.schemaIndex == schema.index && $0.name == segments[0]
            }
            guard matches.count == 1, matches[0].kind == .viewModel else { continue }
            let key = OuterViewModelKey(
                ownerName: value.viewModelName,
                ownerInstanceID: value.instanceId,
                ownerInstanceName: value.instanceName,
                propertyName: segments[0]
            )
            if segments.count == 1 {
                direct.insert(key)
                continue
            }
            keyByIndex[index] = key
            indexesByKey[key, default: []].append(index)
            if segments.count == 2,
               segments[1] == "vmInstanceId" || segments[1] == "instanceId" {
                identityBearing.insert(key)
            }
        }
        guard direct.isDisjoint(with: identityBearing) else {
            throw ExperienceInteractiveScreenError.stateContract(
                "signed state contains both direct and flattened values for one view model"
            )
        }

        var result: [JourneyViewModelValue] = []
        result.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            guard let key = keyByIndex[index], identityBearing.contains(key) else {
                result.append(value)
                continue
            }
            guard indexesByKey[key]?.first == index,
                  let grouped = indexesByKey[key] else { continue }
            var envelope: [String: Any] = [:]
            for groupedIndex in grouped {
                let groupedValue = values[groupedIndex]
                let segments = groupedValue.path.split(separator: "/").map(String.init)
                try insertFlattenedValue(
                    unwrap(groupedValue.value.value),
                    path: Array(segments.dropFirst()),
                    into: &envelope,
                    propertyPath: key.propertyName
                )
            }
            let vmInstanceID = envelope["vmInstanceId"] as? String
            let instanceID = envelope["instanceId"] as? String
            if let vmInstanceID, let instanceID, vmInstanceID != instanceID {
                throw ExperienceInteractiveScreenError.stateContract(
                    "flattened view-model envelope '\(key.propertyName)' has conflicting identities"
                )
            }
            guard let stableID = vmInstanceID ?? instanceID, !stableID.isEmpty else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "flattened view-model envelope '\(key.propertyName)' has no stable identity"
                )
            }
            result.append(JourneyViewModelValue(
                viewModelName: value.viewModelName,
                instanceId: value.instanceId,
                instanceName: value.instanceName,
                path: key.propertyName,
                value: AnyCodable(envelope)
            ))
        }
        return result
    }

    private static func insertFlattenedValue(
        _ value: Any,
        path: [String],
        into envelope: inout [String: Any],
        propertyPath: String
    ) throws {
        guard let key = path.first, !key.isEmpty else {
            throw ExperienceInteractiveScreenError.stateContract(
                "flattened view-model envelope '\(propertyPath)' has an empty path"
            )
        }
        if path.count == 1 {
            guard envelope[key] == nil else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "flattened view-model envelope '\(propertyPath)' repeats '\(key)'"
                )
            }
            envelope[key] = value
            return
        }
        var child = dictionaryValue(envelope[key]) ?? [:]
        if envelope[key] != nil, dictionaryValue(envelope[key]) == nil {
            throw ExperienceInteractiveScreenError.stateContract(
                "flattened view-model envelope '\(propertyPath)' has conflicting '\(key)' values"
            )
        }
        try insertFlattenedValue(
            value,
            path: Array(path.dropFirst()),
            into: &child,
            propertyPath: propertyPath
        )
        envelope[key] = child
    }

    private static func dictionaryValue(_ rawValue: Any?) -> [String: Any]? {
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

    private static func arrayValue(_ rawValue: Any) -> [Any]? {
        let value = unwrap(rawValue)
        if let array = value as? [Any] { return array.map(unwrap) }
        if let array = value as? [AnyCodable] {
            return array.map { unwrap($0.value) }
        }
        return nil
    }

    private static func unwrap(_ rawValue: Any) -> Any {
        if let value = rawValue as? AnyCodable { return unwrap(value.value) }
        if let literal = rawValue as? [String: Any],
           literal.count == 1, let value = literal["literal"] {
            return unwrap(value)
        }
        return rawValue
    }

    private static func mutation(
        reference: NuxieNativeViewModelReference,
        path: String,
        property: NuxieNativeViewModelCatalog.Property,
        rawValue: Any,
        imageIDs: [String: UInt64]
    ) throws -> NuxieNativeViewModelMutation {
        let rawValue = unwrap(rawValue)
        switch property.kind {
        case .string:
            guard let value = rawValue as? String else { throw stateValue(path) }
            return .setString(instance: reference, path: path, value: Data(value.utf8))
        case .number:
            guard let value = number(rawValue), value.isFinite else { throw stateValue(path) }
            return .setNumber(instance: reference, path: path, value: Float(value))
        case .bool:
            guard let value = rawValue as? Bool else { throw stateValue(path) }
            return .setBool(instance: reference, path: path, value: value)
        case .color:
            guard let value = unsigned(rawValue), value <= UInt32.max else {
                throw stateValue(path)
            }
            return .setColor(instance: reference, path: path, value: UInt32(value))
        case .enumeration:
            let value: UInt64?
            if let label = rawValue as? String,
               let index = property.enumLabels.firstIndex(of: label) {
                value = UInt64(index)
            } else {
                value = unsigned(rawValue)
            }
            guard let value else { throw stateValue(path) }
            return .setEnumeration(instance: reference, path: path, value: value)
        case .trigger:
            guard (rawValue as? Bool) == true || unsigned(rawValue).map({ $0 != 0 }) == true else {
                throw stateValue(path)
            }
            return .fireTrigger(instance: reference, path: path)
        case .listIndex:
            guard let value = unsigned(rawValue) else { throw stateValue(path) }
            return .setListIndex(instance: reference, path: path, value: value)
        case .image:
            let value = (rawValue as? String).flatMap { imageIDs[$0] } ?? unsigned(rawValue)
            guard let value else { throw stateValue(path) }
            return .setImage(instance: reference, path: path, value: value)
        case .unsupported, .list, .viewModel, .font, .blob, .artboard:
            throw ExperienceInteractiveScreenError.stateContract(
                "signed initial state does not support '\(path)' of kind \(property.kind)"
            )
        }
    }

    private static func number(_ rawValue: Any) -> Double? {
        guard !(rawValue is Bool), let number = rawValue as? NSNumber else { return nil }
        return number.doubleValue
    }

    private static func unsigned(_ rawValue: Any) -> UInt64? {
        guard let number = number(rawValue), number.isFinite,
              number >= 0, number.rounded(.towardZero) == number,
              number < Double(UInt64.max) else { return nil }
        return UInt64(number)
    }

    private static func stateValue(_ path: String) -> ExperienceInteractiveScreenError {
        .stateContract("signed initial value for '\(path)' has the wrong type")
    }
}

enum ExperienceInteractiveListIndexPlanner {
    static func mutations(
        reference: NuxieNativeViewModelReference,
        schemaIndex: Int,
        properties: [NuxieNativeViewModelCatalog.Property],
        index: Int
    ) -> [NuxieNativeViewModelMutation] {
        properties.compactMap { property in
            guard property.schemaIndex == schemaIndex,
                  property.kind == .listIndex else { return nil }
            return .setListIndex(
                instance: reference,
                path: property.name,
                value: UInt64(index)
            )
        }
    }
}

enum ExperienceInteractiveImageIdentityMap {
    static func make(images: [NuxPackageImageAsset]) throws -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        for image in images {
            for key in [image.riveUniqueName, image.location.contentAddressedPath] {
                if let existing = result[key], existing != image.riveAssetId {
                    throw ExperienceInteractiveScreenError.stateContract(
                        "image identity '\(key)' maps to multiple authored assets"
                    )
                }
                result[key] = image.riveAssetId
            }
        }
        return result
    }
}

private enum ExperienceInteractiveExternalFontRegistration {
    static func register(
        manifest: NuxPackageManifestV1,
        authenticatedAssets: [AuthenticatedRuntimeAsset],
        in scope: ExperienceRuntimeFontScope
    ) throws {
        for font in manifest.assets.fonts {
            guard case .external = font.location else { continue }
            guard let authoredID = UInt32(exactly: font.riveAssetId),
                  let asset = authenticatedAssets.first(where: {
                      $0.kind == .font
                          && $0.riveAssetID == authoredID
                          && $0.riveUniqueName == font.riveUniqueName
                  }) else {
                throw ExperienceInteractiveScreenError.assetContract(font.riveUniqueName)
            }
            guard let bytes = asset.bytes else {
                if font.required {
                    throw ExperienceInteractiveScreenError.assetContract(
                        "required CoreText font registration failed: \(font.riveUniqueName)"
                    )
                }
                continue
            }
            guard ExperienceRuntimeFontRegistry.registerFont(
                riveUniqueName: font.riveUniqueName,
                data: bytes,
                in: scope
            ) != nil else {
                if font.required {
                    throw ExperienceInteractiveScreenError.assetContract(
                        "required CoreText font registration failed: \(font.riveUniqueName)"
                    )
                }
                continue
            }
        }
    }
}

private enum ExperienceInteractiveAssetBinding {
    private struct Key: Hashable {
        let kind: AuthenticatedRuntimeAsset.Kind
        let authoredID: UInt32
        let uniqueName: String
    }

    private struct Declaration {
        let sourceKey: String
        let contentType: String
        let sha256: String
        let required: Bool
        let isEmbedded: Bool
    }

    static func bind(
        manifest: NuxPackageManifestV1,
        authenticatedAssets: [AuthenticatedRuntimeAsset],
        catalog: [NuxieNativeFileAssetDescriptor]
    ) throws -> [Int: Data] {
        let declarations = try declarationMap(manifest)
        var authenticated: [Key: AuthenticatedRuntimeAsset] = [:]
        for asset in authenticatedAssets {
            let key = Key(
                kind: asset.kind,
                authoredID: asset.riveAssetID,
                uniqueName: asset.riveUniqueName
            )
            guard let declaration = declarations[key] else {
                throw ExperienceInteractiveScreenError.assetContract(asset.riveUniqueName)
            }
            let hasRequiredBytes = asset.bytes != nil
                || (!declaration.isEmbedded && !asset.required)
            guard declaration.sourceKey == asset.sourceKey,
                  declaration.contentType == asset.contentType,
                  declaration.sha256 == asset.sha256,
                  declaration.required == asset.required,
                  authenticated.updateValue(asset, forKey: key) == nil,
                  hasRequiredBytes
            else {
                throw ExperienceInteractiveScreenError.assetContract(asset.riveUniqueName)
            }
        }
        guard authenticated.count == declarations.count else {
            throw ExperienceInteractiveScreenError.assetContract(
                "authenticated assets do not exactly match the signed manifest"
            )
        }

        var consumed = Set<Key>()
        var externalAssets: [Int: Data] = [:]
        for descriptor in catalog {
            let kind: AuthenticatedRuntimeAsset.Kind
            switch descriptor.kind {
            case .image:
                kind = .image
            case .font:
                kind = .font
            case .script:
                continue
            case .audio where descriptor.isEmbedded:
                // Embedded audio is already authenticated by the signed scene
                // digest. It needs no external provider entry and remains
                // owned by the native file across renderer-domain resets.
                continue
            case .audio, .blob, .shader:
                throw ExperienceInteractiveScreenError.assetContract(
                    "unsupported authored asset kind at ordinal \(descriptor.ordinal)"
                )
            }
            guard let authoredID = descriptor.authoredID else {
                throw ExperienceInteractiveScreenError.assetContract(
                    "missing authored asset id at ordinal \(descriptor.ordinal)"
                )
            }
            let uniqueName = "\(descriptor.name)-\(authoredID)"
            let key = Key(kind: kind, authoredID: authoredID, uniqueName: uniqueName)
            guard let asset = authenticated[key],
                  let declaration = declarations[key],
                  declaration.isEmbedded == descriptor.isEmbedded,
                  consumed.insert(key).inserted else {
                throw ExperienceInteractiveScreenError.assetContract(uniqueName)
            }
            if !descriptor.isEmbedded, let bytes = asset.bytes {
                externalAssets[descriptor.ordinal] = bytes
            }
        }
        guard consumed.count == authenticated.count else {
            throw ExperienceInteractiveScreenError.assetContract(
                "the authored scene catalog does not exactly match authenticated assets"
            )
        }
        return externalAssets
    }

    private static func declarationMap(
        _ manifest: NuxPackageManifestV1
    ) throws -> [Key: Declaration] {
        var result: [Key: Declaration] = [:]
        for asset in manifest.assets.images {
            try append(
                kind: .image,
                riveAssetID: asset.riveAssetId,
                uniqueName: asset.riveUniqueName,
                location: asset.location,
                contentType: asset.contentType,
                sha256: asset.sha256,
                required: asset.required,
                to: &result
            )
        }
        for asset in manifest.assets.fonts {
            try append(
                kind: .font,
                riveAssetID: asset.riveAssetId,
                uniqueName: asset.riveUniqueName,
                location: asset.location,
                contentType: asset.contentType,
                sha256: asset.sha256,
                required: asset.required,
                to: &result
            )
        }
        return result
    }

    private static func append(
        kind: AuthenticatedRuntimeAsset.Kind,
        riveAssetID: UInt64,
        uniqueName: String,
        location: NuxPackageAssetLocation,
        contentType: String,
        sha256: String,
        required: Bool,
        to result: inout [Key: Declaration]
    ) throws {
        guard let authoredID = UInt32(exactly: riveAssetID) else {
            throw ExperienceInteractiveScreenError.assetContract(uniqueName)
        }
        let key = Key(kind: kind, authoredID: authoredID, uniqueName: uniqueName)
        let declaration = Declaration(
            sourceKey: location.contentAddressedPath,
            contentType: contentType,
            sha256: sha256,
            required: required,
            isEmbedded: {
                if case .embedded = location { return true }
                return false
            }()
        )
        guard result.updateValue(declaration, forKey: key) == nil else {
            throw ExperienceInteractiveScreenError.assetContract(uniqueName)
        }
    }
}

private extension ExperienceInteractivePlayerSelection {
    var native: NuxieNativePlayerSelection {
        switch self {
        case .defaultScene: .defaultScene
        case .staticArtboard: .staticArtboard
        case .stateMachine(let name): .stateMachine(name)
        case .linearAnimation(let name): .linearAnimation(name)
        }
    }
}
#endif
