import Foundation

/// Limits shared by the ABI 1.5 session surface and the Swift host.
///
/// Swift validates these before allocating native request storage and again
/// while copying result-owned views. Rust remains the authority at the ABI
/// boundary; the duplicate checks keep malformed native views from becoming
/// unbounded Swift allocations.
enum FlowRuntimeSessionLimits {
    static let identifierBytes = 4_096
    static let pathBytes = 4_096
    static let stringBytes = 1_048_576
    static let batchItems = 4_096
    static let queryItems = 4_096
    static let outputs = 4_096
    static let instances = 4_096
    static let listItems = 4_096
    static let valueNodes = 4_096
    static let valueEdges = 16_384
    static let valueDepth = 32
    static let eventProperties = 256
    static let encodedPayloadBytes = 4_194_304
    static let pointerEvents = 32
}

enum FlowRuntimeSessionValueError: LocalizedError, Equatable {
    case limitExceeded(String)
    case invalidGraph(String)
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .limitExceeded(let message),
             .invalidGraph(let message),
             .invalidValue(let message):
            message
        }
    }
}

/// Positive identity allocated by Rust and stable for one session lifetime.
struct FlowRuntimeInstanceID: RawRepresentable, Hashable, Comparable, Sendable {
    let rawValue: UInt64

    init?(rawValue: UInt64) {
        guard rawValue > 0 else { return nil }
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum FlowRuntimePlayerKind: Equatable, Sendable {
    case stateMachine
    case linearAnimation
    case staticArtboard
}

enum FlowRuntimePlayerSelection: Equatable, Sendable {
    case explicitStateMachine
    case authoredDefaultStateMachine
    case firstStateMachine
    case firstAnimation
    case staticArtboard
}

struct FlowRuntimeArtboardBounds: Equatable, Sendable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }

    func validate() throws {
        guard minX.isFinite,
              minY.isFinite,
              maxX.isFinite,
              maxY.isFinite,
              maxX > minX,
              maxY > minY else {
            throw FlowRuntimeSessionValueError.invalidValue(
                "Runtime returned invalid authored artboard bounds"
            )
        }
    }
}

struct FlowRuntimePlayerMetadata: Equatable, Sendable {
    let kind: FlowRuntimePlayerKind
    let selection: FlowRuntimePlayerSelection
    let index: UInt32?
    let artboardName: String?
    let playerName: String?
    let bounds: FlowRuntimeArtboardBounds
}

enum FlowRuntimeSchemaPropertyKind: Equatable, Sendable {
    case null
    case string
    case number
    case bool
    case trigger
    case enumeration
    case listIndex
    case color
    case image
    case viewModel
    case list
    case object
}

struct FlowRuntimeSchemaProperty: Equatable, Sendable {
    let schemaID: String
    let propertyID: String
    let name: String
    let kind: FlowRuntimeSchemaPropertyKind
    let enumValues: [String]
    let referencedSchemaID: String?

    init(
        schemaID: String,
        propertyID: String,
        name: String,
        kind: FlowRuntimeSchemaPropertyKind,
        enumValues: [String] = [],
        referencedSchemaID: String? = nil
    ) {
        self.schemaID = schemaID
        self.propertyID = propertyID
        self.name = name
        self.kind = kind
        self.enumValues = enumValues
        self.referencedSchemaID = referencedSchemaID
    }
}

struct FlowRuntimeSchema: Equatable, Sendable {
    let id: String
    let name: String
    let properties: [FlowRuntimeSchemaProperty]
}

struct FlowRuntimeInstanceTemplate: Equatable, Sendable {
    let schemaID: String
    let authoredName: String?
    let authoredIndex: UInt32
}

struct FlowRuntimeInstance: Equatable, Sendable {
    let id: FlowRuntimeInstanceID
    let schemaID: String
    let name: String?
    let isRoot: Bool
    let valueRootIndex: Int?
}

struct FlowRuntimeCatalog: Equatable, Sendable {
    let schemas: [FlowRuntimeSchema]
    let templates: [FlowRuntimeInstanceTemplate]
    let instances: [FlowRuntimeInstance]

    var rootInstance: FlowRuntimeInstance? {
        instances.first(where: \.isRoot)
    }
}

enum FlowRuntimeScalarValue: Equatable, Sendable {
    case null
    case string(String)
    case number(Double)
    case bool(Bool)
    case enumeration(UInt64)
    case listIndex(UInt64)
    case color(UInt32)
    case image(UInt64)
    case trigger(UInt64)

    func validate() throws {
        switch self {
        case .string(let value):
            guard value.utf8.count <= FlowRuntimeSessionLimits.stringBytes else {
                throw FlowRuntimeSessionValueError.limitExceeded(
                    "Runtime string exceeds the 1 MiB limit"
                )
            }
        case .number(let value):
            guard value.isFinite else {
                throw FlowRuntimeSessionValueError.invalidValue(
                    "Runtime number must be finite"
                )
            }
        case .null, .bool, .enumeration, .listIndex, .color, .image, .trigger:
            break
        }
    }
}

struct FlowRuntimeValueEdge: Equatable, Sendable {
    /// Object/view-model field name. Lists use `nil`.
    let key: String?
    let nodeIndex: Int
}

enum FlowRuntimeValue: Equatable, Sendable {
    case scalar(FlowRuntimeScalarValue)
    case object(schemaID: String?, fields: [FlowRuntimeValueEdge])
    case viewModel(
        schemaID: String?,
        instanceID: FlowRuntimeInstanceID?,
        fields: [FlowRuntimeValueEdge]
    )
    case list(items: [FlowRuntimeValueEdge])
}

struct FlowRuntimeValueNode: Equatable, Sendable {
    let value: FlowRuntimeValue
}

struct FlowRuntimeValueRoot: Equatable, Sendable {
    let instanceID: FlowRuntimeInstanceID
    let nodeIndex: Int
}

struct FlowRuntimeHostObjectField: Equatable, Sendable {
    let name: String
    let value: FlowRuntimeHostValue

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.value == rhs.value
    }
}

/// A host-facing object with one stable field order on every platform.
///
/// Rust emits object fields from a `BTreeMap`; Swift canonicalizes fake and
/// decoded values by UTF-8 bytes so equality, routing, and diagnostics never
/// depend on dictionary iteration order.
struct FlowRuntimeHostObject: Equatable, Sendable {
    static let empty = Self(fields: [])

    let fields: [FlowRuntimeHostObjectField]

    init(fields: [FlowRuntimeHostObjectField]) {
        var uniqueFields: [Data: FlowRuntimeHostObjectField] = [:]
        uniqueFields.reserveCapacity(fields.count)
        for field in fields {
            uniqueFields[Data(field.name.utf8)] = field
        }
        self.fields = Array(uniqueFields.values)
            .sorted { lhs, rhs in
                lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
            }
    }

    subscript(_ name: String) -> FlowRuntimeHostValue? {
        fields.first(where: { $0.name.utf8.elementsEqual(name.utf8) })?.value
    }
}

/// Closed value vocabulary for one-way Luau-to-host commands.
///
/// There is deliberately no null case. `nil` has call-specific meaning in
/// the Nuxie module: trigger payloads normalize to an empty object and
/// `response.set` with a top-level nil emits no command.
indirect enum FlowRuntimeHostValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([FlowRuntimeHostValue])
    case object(FlowRuntimeHostObject)
}

/// Fully copied recursive arena. Composite values retain node indices so
/// aliases and stable list-row identity survive the C result lifetime.
struct FlowRuntimeValueArena: Equatable, Sendable {
    let nodes: [FlowRuntimeValueNode]
    let roots: [FlowRuntimeValueRoot]

    static let empty = Self(nodes: [], roots: [])

    func validate() throws {
        guard nodes.count <= FlowRuntimeSessionLimits.valueNodes else {
            throw FlowRuntimeSessionValueError.limitExceeded(
                "Runtime value node limit exceeded"
            )
        }
        guard roots.count <= FlowRuntimeSessionLimits.instances else {
            throw FlowRuntimeSessionValueError.limitExceeded(
                "Runtime value root limit exceeded"
            )
        }

        var aggregateEdges = 0
        var aggregateBytes = 0
        for node in nodes {
            let edges: [FlowRuntimeValueEdge]
            switch node.value {
            case .scalar(let value):
                try value.validate()
                if case .string(let string) = value {
                    aggregateBytes = try checkedPayloadSum(aggregateBytes, string.utf8.count)
                }
                edges = []
            case .object(let schemaID, let fields),
                 .viewModel(let schemaID, _, let fields):
                if let schemaID {
                    try validateIdentifier(schemaID, label: "value schema ID")
                    aggregateBytes = try checkedPayloadSum(aggregateBytes, schemaID.utf8.count)
                }
                guard fields.allSatisfy({ $0.key?.isEmpty == false }) else {
                    throw FlowRuntimeSessionValueError.invalidGraph(
                        "Runtime object edge is missing its field key"
                    )
                }
                for edge in fields {
                    if let key = edge.key {
                        try validateIdentifier(key, label: "value edge key")
                        aggregateBytes = try checkedPayloadSum(aggregateBytes, key.utf8.count)
                    }
                }
                edges = fields
            case .list(let items):
                guard items.count <= FlowRuntimeSessionLimits.listItems else {
                    throw FlowRuntimeSessionValueError.limitExceeded(
                        "Runtime list item limit exceeded"
                    )
                }
                guard items.allSatisfy({ $0.key == nil }) else {
                    throw FlowRuntimeSessionValueError.invalidGraph(
                        "Runtime list edge unexpectedly has a field key"
                    )
                }
                edges = items
            }

            aggregateEdges = try checkedPayloadSum(aggregateEdges, edges.count)
            guard aggregateEdges <= FlowRuntimeSessionLimits.valueEdges else {
                throw FlowRuntimeSessionValueError.limitExceeded(
                    "Runtime value edge limit exceeded"
                )
            }
            for edge in edges {
                guard nodes.indices.contains(edge.nodeIndex) else {
                    throw FlowRuntimeSessionValueError.invalidGraph(
                        "Runtime value edge references a missing node"
                    )
                }
            }
        }

        guard aggregateBytes <= FlowRuntimeSessionLimits.encodedPayloadBytes else {
            throw FlowRuntimeSessionValueError.limitExceeded(
                "Runtime value payload exceeds 4 MiB"
            )
        }

        var rootIDs = Set<FlowRuntimeInstanceID>()
        for root in roots {
            guard rootIDs.insert(root.instanceID).inserted else {
                throw FlowRuntimeSessionValueError.invalidGraph(
                    "Runtime value arena contains a duplicate instance root"
                )
            }
            guard nodes.indices.contains(root.nodeIndex) else {
                throw FlowRuntimeSessionValueError.invalidGraph(
                    "Runtime value root references a missing node"
                )
            }
            var visiting = Set<Int>()
            try validateDepth(
                nodeIndex: root.nodeIndex,
                depth: 0,
                visiting: &visiting
            )
        }
    }

    /// Copies a host-command value out of the session's existing value arena.
    /// Runtime-only identities and typed ViewModels cannot cross this seam.
    func hostValue(at nodeIndex: Int) throws -> FlowRuntimeHostValue {
        var seen = Set<Int>()
        return try hostValue(at: nodeIndex, depth: 1, seen: &seen)
    }

    private func hostValue(
        at nodeIndex: Int,
        depth: Int,
        seen: inout Set<Int>
    ) throws -> FlowRuntimeHostValue {
        guard nodes.indices.contains(nodeIndex) else {
            throw FlowRuntimeSessionValueError.invalidGraph(
                "Runtime host value references missing node \(nodeIndex)"
            )
        }
        guard depth <= FlowRuntimeSessionLimits.valueDepth else {
            throw FlowRuntimeSessionValueError.limitExceeded(
                "Runtime host value graph depth limit exceeded"
            )
        }
        guard seen.insert(nodeIndex).inserted else {
            throw FlowRuntimeSessionValueError.invalidGraph(
                "Runtime host value graph contains an alias or cycle"
            )
        }

        switch nodes[nodeIndex].value {
        case .scalar(.bool(let value)):
            return .bool(value)
        case .scalar(.number(let value)):
            guard value.isFinite else {
                throw FlowRuntimeSessionValueError.invalidValue(
                    "Runtime host value node \(nodeIndex) has a nonfinite number"
                )
            }
            return .number(value)
        case .scalar(.string(let value)):
            guard value.utf8.count <= FlowRuntimeSessionLimits.stringBytes else {
                throw FlowRuntimeSessionValueError.limitExceeded(
                    "Runtime host value string exceeds the 1 MiB limit"
                )
            }
            return .string(value)
        case .scalar:
            throw FlowRuntimeSessionValueError.invalidValue(
                "Runtime host value node \(nodeIndex) has unsupported scalar kind"
            )
        case .list(let items):
            guard items.count <= FlowRuntimeSessionLimits.listItems,
                  items.allSatisfy({ $0.key == nil }) else {
                throw FlowRuntimeSessionValueError.invalidGraph(
                    "Runtime host array node \(nodeIndex) has invalid edges"
                )
            }
            return .array(try items.map { edge in
                try hostValue(
                    at: edge.nodeIndex,
                    depth: depth + 1,
                    seen: &seen
                )
            })
        case .object(let schemaID, let fields):
            guard schemaID == nil else {
                throw FlowRuntimeSessionValueError.invalidValue(
                    "Runtime host object node \(nodeIndex) has a schema identity"
                )
            }
            var names = Set<Data>()
            var copiedFields: [FlowRuntimeHostObjectField] = []
            copiedFields.reserveCapacity(fields.count)
            for edge in fields {
                guard let name = edge.key,
                      !name.isEmpty,
                      names.insert(Data(name.utf8)).inserted else {
                    throw FlowRuntimeSessionValueError.invalidGraph(
                        "Runtime host object node \(nodeIndex) has a missing or duplicate field"
                    )
                }
                copiedFields.append(FlowRuntimeHostObjectField(
                    name: name,
                    value: try hostValue(
                        at: edge.nodeIndex,
                        depth: depth + 1,
                        seen: &seen
                    )
                ))
            }
            return .object(FlowRuntimeHostObject(fields: copiedFields))
        case .viewModel:
            throw FlowRuntimeSessionValueError.invalidValue(
                "Runtime host value node \(nodeIndex) cannot be a ViewModel"
            )
        }
    }

    private func validateDepth(
        nodeIndex: Int,
        depth: Int,
        visiting: inout Set<Int>
    ) throws {
        guard depth <= FlowRuntimeSessionLimits.valueDepth else {
            throw FlowRuntimeSessionValueError.limitExceeded(
                "Runtime value graph depth limit exceeded"
            )
        }
        guard visiting.insert(nodeIndex).inserted else {
            throw FlowRuntimeSessionValueError.invalidGraph(
                "Runtime value graph contains a cycle"
            )
        }
        defer { visiting.remove(nodeIndex) }

        let edges: [FlowRuntimeValueEdge]
        switch nodes[nodeIndex].value {
        case .scalar:
            edges = []
        case .object(_, let fields), .viewModel(_, _, let fields):
            edges = fields
        case .list(let items):
            edges = items
        }
        for edge in edges {
            try validateDepth(
                nodeIndex: edge.nodeIndex,
                depth: depth + 1,
                visiting: &visiting
            )
        }
    }
}

struct FlowRuntimeBootstrap: Equatable, Sendable {
    let player: FlowRuntimePlayerMetadata
    let catalog: FlowRuntimeCatalog
    let values: FlowRuntimeValueArena
}

enum FlowRuntimePlayerInputKind: Equatable, Sendable {
    case bool
    case number
    case trigger
}

struct FlowRuntimePlayerInput: Equatable, Sendable {
    let name: String?
    let kind: FlowRuntimePlayerInputKind
    let value: FlowRuntimeScalarValue
}

enum FlowRuntimeInstanceReference: Hashable, Sendable {
    case existing(FlowRuntimeInstanceID)
    case new(localID: UInt32)
}

struct FlowRuntimeNewInstance: Equatable, Sendable {
    let localID: UInt32
    let schemaName: String
    let authoredInstanceName: String?
}

enum FlowRuntimeStateMutation: Equatable, Sendable {
    case setInputBool(name: String, value: Bool)
    case setInputNumber(name: String, value: Double)
    case fireInputTrigger(name: String)
    case setValue(
        instance: FlowRuntimeInstanceReference,
        path: String,
        value: FlowRuntimeScalarValue
    )
    case setViewModel(
        instance: FlowRuntimeInstanceReference,
        path: String,
        value: FlowRuntimeInstanceReference
    )
    case fireTrigger(instance: FlowRuntimeInstanceReference, path: String)
    case listInsert(
        instance: FlowRuntimeInstanceReference,
        path: String,
        index: UInt32,
        item: FlowRuntimeInstanceReference
    )
    case listRemove(instance: FlowRuntimeInstanceReference, path: String, index: UInt32)
    case listSwap(
        instance: FlowRuntimeInstanceReference,
        path: String,
        first: UInt32,
        second: UInt32
    )
    case listMove(
        instance: FlowRuntimeInstanceReference,
        path: String,
        from: UInt32,
        to: UInt32
    )
    case listSet(
        instance: FlowRuntimeInstanceReference,
        path: String,
        index: UInt32,
        item: FlowRuntimeInstanceReference
    )
    case listClear(instance: FlowRuntimeInstanceReference, path: String)
}

struct FlowRuntimeStateBatch: Equatable, Sendable {
    let hostMutationID: UInt64?
    let newInstances: [FlowRuntimeNewInstance]
    let mutations: [FlowRuntimeStateMutation]

    init(
        hostMutationID: UInt64? = nil,
        newInstances: [FlowRuntimeNewInstance] = [],
        mutations: [FlowRuntimeStateMutation]
    ) {
        self.hostMutationID = hostMutationID
        self.newInstances = newInstances
        self.mutations = mutations
    }
}

/// One root-level authored `TextValueRun` replacement.
///
/// `name` and `text` are carried as their exact UTF-8 bytes by the native
/// adapter. Rust owns all validation and resolves the complete batch before
/// applying any replacement.
struct FlowRuntimeTextRunMutation: Equatable, Sendable {
    let name: String
    let text: String
}

/// An atomic group of root-level text-run replacements.
struct FlowRuntimeTextRunBatch: Equatable, Sendable {
    let mutations: [FlowRuntimeTextRunMutation]
}

enum FlowRuntimePointerKind: Equatable, Sendable {
    case down
    case move
    case up
    case cancel
    case exit
}

struct FlowRuntimePointerEvent: Equatable, Sendable {
    let kind: FlowRuntimePointerKind
    let pointerID: Int32
    let x: Float
    let y: Float
    let timestampSeconds: TimeInterval

    init(
        kind: FlowRuntimePointerKind,
        pointerID: Int32,
        x: Float,
        y: Float,
        timestampSeconds: TimeInterval = 0
    ) {
        self.kind = kind
        self.pointerID = pointerID
        self.x = x
        self.y = y
        self.timestampSeconds = timestampSeconds
    }
}

enum FlowRuntimeQuery: Equatable, Sendable {
    case bootstrap
    case values
    case catalog
    case playerInputs
}

struct FlowRuntimeCreatedInstance: Equatable, Sendable {
    let localID: UInt32
    let instanceID: FlowRuntimeInstanceID
}

struct FlowRuntimeEventProperty: Equatable, Sendable {
    let name: String?
    let value: FlowRuntimeScalarValue
}

/// Identity-bearing value for an outer ViewModel-reference change.
/// Descendant fields continue to arrive as their own ordered scalar changes.
struct FlowRuntimeViewModelReference: Equatable, Sendable {
    let schemaID: String
    let instanceID: FlowRuntimeInstanceID
}

struct FlowRuntimeStateChange: Equatable, Sendable {
    let instanceID: FlowRuntimeInstanceID?
    let path: String
    let value: FlowRuntimeScalarValue?
    let viewModelReference: FlowRuntimeViewModelReference?
    let originMutationID: UInt64?

    init(
        instanceID: FlowRuntimeInstanceID?,
        path: String,
        value: FlowRuntimeScalarValue?,
        viewModelReference: FlowRuntimeViewModelReference? = nil,
        originMutationID: UInt64?
    ) {
        self.instanceID = instanceID
        self.path = path
        self.value = value
        self.viewModelReference = viewModelReference
        self.originMutationID = originMutationID
    }
}

/// Matches only the direct echo Rust attaches to the exact host mutation.
/// Authored effects have no origin ID and therefore always pass through.
struct FlowRuntimeMutationEchoSuppressor: Sendable {
    struct Expected: Equatable, Sendable {
        let instanceID: FlowRuntimeInstanceID?
        let path: String
        let value: FlowRuntimeScalarValue?
        let viewModelReference: FlowRuntimeViewModelReference?

        init(
            instanceID: FlowRuntimeInstanceID?,
            path: String,
            value: FlowRuntimeScalarValue?,
            viewModelReference: FlowRuntimeViewModelReference? = nil
        ) {
            self.instanceID = instanceID
            self.path = path
            self.value = value
            self.viewModelReference = viewModelReference
        }
    }

    private var pending: [UInt64: [Expected]] = [:]

    mutating func register(mutationID: UInt64, expected: [Expected]) {
        pending[mutationID, default: []].append(contentsOf: expected)
    }

    mutating func shouldSuppress(_ change: FlowRuntimeStateChange) -> Bool {
        guard let mutationID = change.originMutationID,
              var expected = pending[mutationID],
              let index = expected.firstIndex(of: Expected(
                  instanceID: change.instanceID,
                  path: change.path,
                  value: change.value,
                  viewModelReference: change.viewModelReference
              )) else {
            return false
        }
        expected.remove(at: index)
        if expected.isEmpty {
            pending.removeValue(forKey: mutationID)
        } else {
            pending[mutationID] = expected
        }
        return true
    }

    mutating func finish(mutationID: UInt64) {
        pending.removeValue(forKey: mutationID)
    }
}

private func validateIdentifier(_ value: String, label: String) throws {
    guard !value.isEmpty else {
        throw FlowRuntimeSessionValueError.invalidValue("Runtime returned an empty \(label)")
    }
    guard value.utf8.count <= FlowRuntimeSessionLimits.identifierBytes else {
        throw FlowRuntimeSessionValueError.limitExceeded("Runtime \(label) exceeds 4 KiB")
    }
}

private func checkedPayloadSum(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (value, overflowed) = lhs.addingReportingOverflow(rhs)
    guard !overflowed else {
        throw FlowRuntimeSessionValueError.limitExceeded(
            "Runtime value payload size overflowed"
        )
    }
    return value
}
