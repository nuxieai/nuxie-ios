import Foundation

/// Limits shared by the ABI 1.5 session surface and the Swift host.
///
/// Swift validates these before allocating native request storage and again
/// while copying result-owned views. Rust remains the authority at the ABI
/// boundary; the duplicate checks keep malformed native views from becoming
/// unbounded Swift allocations.
enum ScreenSessionLimits {
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

enum ScreenSessionValueError: LocalizedError, Equatable {
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
struct ExperienceRuntimeInstanceID: RawRepresentable, Hashable, Comparable, Sendable {
    let rawValue: UInt64

    init?(rawValue: UInt64) {
        guard rawValue > 0 else { return nil }
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ExperienceRuntimePlayerKind: Equatable, Sendable {
    case stateMachine
    case linearAnimation
    case staticArtboard
}

enum ExperienceRuntimePlayerSelection: Equatable, Sendable {
    case explicitStateMachine
    case authoredDefaultStateMachine
    case firstStateMachine
    case firstAnimation
    case staticArtboard
}

struct ExperienceRuntimeArtboardBounds: Equatable, Sendable {
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
            throw ScreenSessionValueError.invalidValue(
                "Runtime returned invalid authored artboard bounds"
            )
        }
    }
}

struct ExperienceRuntimePlayerMetadata: Equatable, Sendable {
    let kind: ExperienceRuntimePlayerKind
    let selection: ExperienceRuntimePlayerSelection
    let index: UInt32?
    let artboardName: String?
    let playerName: String?
    let bounds: ExperienceRuntimeArtboardBounds
}

enum ExperienceRuntimeSchemaPropertyKind: Equatable, Sendable {
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

struct ExperienceRuntimeSchemaProperty: Equatable, Sendable {
    let schemaID: String
    let propertyID: String
    let name: String
    let kind: ExperienceRuntimeSchemaPropertyKind
    let enumValues: [String]
    let referencedSchemaID: String?

    init(
        schemaID: String,
        propertyID: String,
        name: String,
        kind: ExperienceRuntimeSchemaPropertyKind,
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

struct ExperienceRuntimeSchema: Equatable, Sendable {
    let id: String
    let name: String
    let properties: [ExperienceRuntimeSchemaProperty]
}

struct ExperienceRuntimeInstanceTemplate: Equatable, Sendable {
    let schemaID: String
    let authoredName: String?
    let authoredIndex: UInt32
}

struct ExperienceRuntimeInstance: Equatable, Sendable {
    let id: ExperienceRuntimeInstanceID
    let schemaID: String
    let name: String?
    let isRoot: Bool
    let valueRootIndex: Int?
}

struct ExperienceRuntimeCatalog: Equatable, Sendable {
    let schemas: [ExperienceRuntimeSchema]
    let templates: [ExperienceRuntimeInstanceTemplate]
    let instances: [ExperienceRuntimeInstance]

    var rootInstance: ExperienceRuntimeInstance? {
        instances.first(where: \.isRoot)
    }
}

enum ExperienceRuntimeScalarValue: Equatable, Sendable {
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
            guard value.utf8.count <= ScreenSessionLimits.stringBytes else {
                throw ScreenSessionValueError.limitExceeded(
                    "Runtime string exceeds the 1 MiB limit"
                )
            }
        case .number(let value):
            guard value.isFinite else {
                throw ScreenSessionValueError.invalidValue(
                    "Runtime number must be finite"
                )
            }
        case .null, .bool, .enumeration, .listIndex, .color, .image, .trigger:
            break
        }
    }
}

struct ExperienceRuntimeValueEdge: Equatable, Sendable {
    /// Object/view-model field name. Lists use `nil`.
    let key: String?
    let nodeIndex: Int
}

enum ExperienceRuntimeValue: Equatable, Sendable {
    case scalar(ExperienceRuntimeScalarValue)
    case object(schemaID: String?, fields: [ExperienceRuntimeValueEdge])
    case viewModel(
        schemaID: String?,
        instanceID: ExperienceRuntimeInstanceID?,
        fields: [ExperienceRuntimeValueEdge]
    )
    case list(items: [ExperienceRuntimeValueEdge])
}

struct ExperienceRuntimeValueNode: Equatable, Sendable {
    let value: ExperienceRuntimeValue
}

struct ExperienceRuntimeValueRoot: Equatable, Sendable {
    let instanceID: ExperienceRuntimeInstanceID
    let nodeIndex: Int
}

struct ExperienceRuntimeHostObjectField: Equatable, Sendable {
    let name: String
    let value: ExperienceRuntimeHostValue

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.value == rhs.value
    }
}

/// A host-facing object with one stable field order on every platform.
///
/// Rust emits object fields from a `BTreeMap`; Swift canonicalizes fake and
/// decoded values by UTF-8 bytes so equality, routing, and diagnostics never
/// depend on dictionary iteration order.
struct ExperienceRuntimeHostObject: Equatable, Sendable {
    static let empty = Self(fields: [])

    let fields: [ExperienceRuntimeHostObjectField]

    init(fields: [ExperienceRuntimeHostObjectField]) {
        var uniqueFields: [Data: ExperienceRuntimeHostObjectField] = [:]
        uniqueFields.reserveCapacity(fields.count)
        for field in fields {
            uniqueFields[Data(field.name.utf8)] = field
        }
        self.fields = Array(uniqueFields.values)
            .sorted { lhs, rhs in
                lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
            }
    }

    subscript(_ name: String) -> ExperienceRuntimeHostValue? {
        fields.first(where: { $0.name.utf8.elementsEqual(name.utf8) })?.value
    }
}

/// Closed value vocabulary for one-way Luau-to-host commands.
///
/// There is deliberately no null case. `nil` has call-specific meaning in
/// the Nuxie module: trigger payloads normalize to an empty object and
/// `response.set` with a top-level nil emits no command.
indirect enum ExperienceRuntimeHostValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ExperienceRuntimeHostValue])
    case object(ExperienceRuntimeHostObject)
}

/// Fully copied recursive arena. Composite values retain node indices so
/// aliases and stable list-row identity survive the C result lifetime.
struct ExperienceRuntimeValueArena: Equatable, Sendable {
    let nodes: [ExperienceRuntimeValueNode]
    let roots: [ExperienceRuntimeValueRoot]

    static let empty = Self(nodes: [], roots: [])

    func validate() throws {
        guard nodes.count <= ScreenSessionLimits.valueNodes else {
            throw ScreenSessionValueError.limitExceeded(
                "Runtime value node limit exceeded"
            )
        }
        guard roots.count <= ScreenSessionLimits.instances else {
            throw ScreenSessionValueError.limitExceeded(
                "Runtime value root limit exceeded"
            )
        }

        var aggregateEdges = 0
        var aggregateBytes = 0
        for node in nodes {
            let edges: [ExperienceRuntimeValueEdge]
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
                    throw ScreenSessionValueError.invalidGraph(
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
                guard items.count <= ScreenSessionLimits.listItems else {
                    throw ScreenSessionValueError.limitExceeded(
                        "Runtime list item limit exceeded"
                    )
                }
                guard items.allSatisfy({ $0.key == nil }) else {
                    throw ScreenSessionValueError.invalidGraph(
                        "Runtime list edge unexpectedly has a field key"
                    )
                }
                edges = items
            }

            aggregateEdges = try checkedPayloadSum(aggregateEdges, edges.count)
            guard aggregateEdges <= ScreenSessionLimits.valueEdges else {
                throw ScreenSessionValueError.limitExceeded(
                    "Runtime value edge limit exceeded"
                )
            }
            for edge in edges {
                guard nodes.indices.contains(edge.nodeIndex) else {
                    throw ScreenSessionValueError.invalidGraph(
                        "Runtime value edge references a missing node"
                    )
                }
            }
        }

        guard aggregateBytes <= ScreenSessionLimits.encodedPayloadBytes else {
            throw ScreenSessionValueError.limitExceeded(
                "Runtime value payload exceeds 4 MiB"
            )
        }

        var rootIDs = Set<ExperienceRuntimeInstanceID>()
        for root in roots {
            guard rootIDs.insert(root.instanceID).inserted else {
                throw ScreenSessionValueError.invalidGraph(
                    "Runtime value arena contains a duplicate instance root"
                )
            }
            guard nodes.indices.contains(root.nodeIndex) else {
                throw ScreenSessionValueError.invalidGraph(
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
    func hostValue(at nodeIndex: Int) throws -> ExperienceRuntimeHostValue {
        var seen = Set<Int>()
        return try hostValue(at: nodeIndex, depth: 1, seen: &seen)
    }

    private func hostValue(
        at nodeIndex: Int,
        depth: Int,
        seen: inout Set<Int>
    ) throws -> ExperienceRuntimeHostValue {
        guard nodes.indices.contains(nodeIndex) else {
            throw ScreenSessionValueError.invalidGraph(
                "Runtime host value references missing node \(nodeIndex)"
            )
        }
        guard depth <= ScreenSessionLimits.valueDepth else {
            throw ScreenSessionValueError.limitExceeded(
                "Runtime host value graph depth limit exceeded"
            )
        }
        guard seen.insert(nodeIndex).inserted else {
            throw ScreenSessionValueError.invalidGraph(
                "Runtime host value graph contains an alias or cycle"
            )
        }

        switch nodes[nodeIndex].value {
        case .scalar(.bool(let value)):
            return .bool(value)
        case .scalar(.number(let value)):
            guard value.isFinite else {
                throw ScreenSessionValueError.invalidValue(
                    "Runtime host value node \(nodeIndex) has a nonfinite number"
                )
            }
            return .number(value)
        case .scalar(.string(let value)):
            guard value.utf8.count <= ScreenSessionLimits.stringBytes else {
                throw ScreenSessionValueError.limitExceeded(
                    "Runtime host value string exceeds the 1 MiB limit"
                )
            }
            return .string(value)
        case .scalar:
            throw ScreenSessionValueError.invalidValue(
                "Runtime host value node \(nodeIndex) has unsupported scalar kind"
            )
        case .list(let items):
            guard items.count <= ScreenSessionLimits.listItems,
                  items.allSatisfy({ $0.key == nil }) else {
                throw ScreenSessionValueError.invalidGraph(
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
                throw ScreenSessionValueError.invalidValue(
                    "Runtime host object node \(nodeIndex) has a schema identity"
                )
            }
            var names = Set<Data>()
            var copiedFields: [ExperienceRuntimeHostObjectField] = []
            copiedFields.reserveCapacity(fields.count)
            for edge in fields {
                guard let name = edge.key,
                      !name.isEmpty,
                      names.insert(Data(name.utf8)).inserted else {
                    throw ScreenSessionValueError.invalidGraph(
                        "Runtime host object node \(nodeIndex) has a missing or duplicate field"
                    )
                }
                copiedFields.append(ExperienceRuntimeHostObjectField(
                    name: name,
                    value: try hostValue(
                        at: edge.nodeIndex,
                        depth: depth + 1,
                        seen: &seen
                    )
                ))
            }
            return .object(ExperienceRuntimeHostObject(fields: copiedFields))
        case .viewModel:
            throw ScreenSessionValueError.invalidValue(
                "Runtime host value node \(nodeIndex) cannot be a ViewModel"
            )
        }
    }

    private func validateDepth(
        nodeIndex: Int,
        depth: Int,
        visiting: inout Set<Int>
    ) throws {
        guard depth <= ScreenSessionLimits.valueDepth else {
            throw ScreenSessionValueError.limitExceeded(
                "Runtime value graph depth limit exceeded"
            )
        }
        guard visiting.insert(nodeIndex).inserted else {
            throw ScreenSessionValueError.invalidGraph(
                "Runtime value graph contains a cycle"
            )
        }
        defer { visiting.remove(nodeIndex) }

        let edges: [ExperienceRuntimeValueEdge]
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

struct ExperienceRuntimeBootstrap: Equatable, Sendable {
    let player: ExperienceRuntimePlayerMetadata
    let catalog: ExperienceRuntimeCatalog
    let values: ExperienceRuntimeValueArena
}

enum ExperienceRuntimePlayerInputKind: Equatable, Sendable {
    case bool
    case number
    case trigger
}

struct ExperienceRuntimePlayerInput: Equatable, Sendable {
    let name: String?
    let kind: ExperienceRuntimePlayerInputKind
    let value: ExperienceRuntimeScalarValue
}

enum ExperienceRuntimeInstanceReference: Hashable, Sendable {
    case existing(ExperienceRuntimeInstanceID)
    case new(localID: UInt32)
}

struct ExperienceRuntimeNewInstance: Equatable, Sendable {
    let localID: UInt32
    let schemaName: String
    let authoredInstanceName: String?
}

enum ExperienceRuntimeStateMutation: Equatable, Sendable {
    case setInputBool(name: String, value: Bool)
    case setInputNumber(name: String, value: Double)
    case fireInputTrigger(name: String)
    case setValue(
        instance: ExperienceRuntimeInstanceReference,
        path: String,
        value: ExperienceRuntimeScalarValue
    )
    case setViewModel(
        instance: ExperienceRuntimeInstanceReference,
        path: String,
        value: ExperienceRuntimeInstanceReference
    )
    case fireTrigger(instance: ExperienceRuntimeInstanceReference, path: String)
    case listInsert(
        instance: ExperienceRuntimeInstanceReference,
        path: String,
        index: UInt32,
        item: ExperienceRuntimeInstanceReference
    )
    case listRemove(instance: ExperienceRuntimeInstanceReference, path: String, index: UInt32)
    case listSwap(
        instance: ExperienceRuntimeInstanceReference,
        path: String,
        first: UInt32,
        second: UInt32
    )
    case listMove(
        instance: ExperienceRuntimeInstanceReference,
        path: String,
        from: UInt32,
        to: UInt32
    )
    case listSet(
        instance: ExperienceRuntimeInstanceReference,
        path: String,
        index: UInt32,
        item: ExperienceRuntimeInstanceReference
    )
    case listClear(instance: ExperienceRuntimeInstanceReference, path: String)
}

struct ExperienceRuntimeStateBatch: Equatable, Sendable {
    let hostMutationID: UInt64?
    let newInstances: [ExperienceRuntimeNewInstance]
    let mutations: [ExperienceRuntimeStateMutation]

    init(
        hostMutationID: UInt64? = nil,
        newInstances: [ExperienceRuntimeNewInstance] = [],
        mutations: [ExperienceRuntimeStateMutation]
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
struct ExperienceRuntimeTextRunMutation: Equatable, Sendable {
    let name: String
    let text: String
}

/// An atomic group of root-level text-run replacements.
struct ExperienceRuntimeTextRunBatch: Equatable, Sendable {
    let mutations: [ExperienceRuntimeTextRunMutation]
}

enum ExperienceRuntimePointerKind: Equatable, Sendable {
    case down
    case move
    case up
    case cancel
    case exit
}

struct ExperienceRuntimePointerEvent: Equatable, Sendable {
    let kind: ExperienceRuntimePointerKind
    let pointerID: Int32
    let x: Float
    let y: Float
    let timestampSeconds: TimeInterval

    init(
        kind: ExperienceRuntimePointerKind,
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

enum ExperienceRuntimeQuery: Equatable, Sendable {
    case bootstrap
    case values
    case catalog
    case playerInputs
}

struct ExperienceRuntimeCreatedInstance: Equatable, Sendable {
    let localID: UInt32
    let instanceID: ExperienceRuntimeInstanceID
}

struct ExperienceRuntimeEventProperty: Equatable, Sendable {
    let name: String?
    let value: ExperienceRuntimeScalarValue
}

/// Identity-bearing value for an outer ViewModel-reference change.
/// Descendant fields continue to arrive as their own ordered scalar changes.
struct ExperienceRuntimeViewModelReference: Equatable, Sendable {
    let schemaID: String
    let instanceID: ExperienceRuntimeInstanceID
}

struct ExperienceRuntimeStateChange: Equatable, Sendable {
    let instanceID: ExperienceRuntimeInstanceID?
    let path: String
    let value: ExperienceRuntimeScalarValue?
    let viewModelReference: ExperienceRuntimeViewModelReference?
    let originMutationID: UInt64?

    init(
        instanceID: ExperienceRuntimeInstanceID?,
        path: String,
        value: ExperienceRuntimeScalarValue?,
        viewModelReference: ExperienceRuntimeViewModelReference? = nil,
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
struct ExperienceRuntimeMutationEchoSuppressor: Sendable {
    struct Expected: Equatable, Sendable {
        let instanceID: ExperienceRuntimeInstanceID?
        let path: String
        let value: ExperienceRuntimeScalarValue?
        let viewModelReference: ExperienceRuntimeViewModelReference?

        init(
            instanceID: ExperienceRuntimeInstanceID?,
            path: String,
            value: ExperienceRuntimeScalarValue?,
            viewModelReference: ExperienceRuntimeViewModelReference? = nil
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

    mutating func shouldSuppress(_ change: ExperienceRuntimeStateChange) -> Bool {
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
        throw ScreenSessionValueError.invalidValue("Runtime returned an empty \(label)")
    }
    guard value.utf8.count <= ScreenSessionLimits.identifierBytes else {
        throw ScreenSessionValueError.limitExceeded("Runtime \(label) exceeds 4 KiB")
    }
}

private func checkedPayloadSum(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (value, overflowed) = lhs.addingReportingOverflow(rhs)
    guard !overflowed else {
        throw ScreenSessionValueError.limitExceeded(
            "Runtime value payload size overflowed"
        )
    }
    return value
}
