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

/// The product policy half of the module. It deliberately consumes generic
/// trees and declaration sets instead of legacy runtime bootstrap/output DTOs.
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
        case "$response_set":
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

/// Owns one authenticated screen's native objects, product interpretation,
/// and exactly-once ordering. Presentation code never receives a FlowSession
/// or runtime-host mirror.
actor ExperienceInteractiveScreen {
    private let runtime: NuxieNativeRuntime
    private let operationGate = ExperienceInteractiveOperationGate()
    private let screenID: String
    private let validScreenIDs: Set<String>
    private let declaredEventNames: Set<String>
    private let textInputs: [String: NuxPackageTextInput]
    private let viewModelsByIdentity:
        [ExperienceInteractiveViewModelIdentity: ExperienceInteractiveViewModelReference]
    private var router = ExperienceInteractiveEffectRouter()

    private init(
        runtime: NuxieNativeRuntime,
        screenID: String,
        validScreenIDs: Set<String>,
        declaredEventNames: Set<String>,
        textInputs: [String: NuxPackageTextInput],
        viewModelsByIdentity:
            [ExperienceInteractiveViewModelIdentity: ExperienceInteractiveViewModelReference]
    ) {
        self.runtime = runtime
        self.screenID = screenID
        self.validScreenIDs = validScreenIDs
        self.declaredEventNames = declaredEventNames
        self.textInputs = textInputs
        self.viewModelsByIdentity = viewModelsByIdentity
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

        let viewModelsByIdentity: [
            ExperienceInteractiveViewModelIdentity: ExperienceInteractiveViewModelReference
        ]
        do {
            viewModelsByIdentity = try await ExperienceInteractiveInitialState.apply(
                journey: payload.journey,
                screen: journeyScreen,
                manifest: payload.manifest,
                runtime: runtime
            )
        } catch {
            try? await runtime.close()
            throw error
        }

        var textInputs: [String: NuxPackageTextInput] = [:]
        for input in payload.manifest.textInputs where input.screenId == screenID {
            guard textInputs.updateValue(input, forKey: input.inputId) == nil else {
                try? await runtime.close()
                throw ExperienceInteractiveScreenError.invalidScreen(screenID)
            }
        }
        let manifestScreenIDs = Set(payload.manifest.screens.map(\.screenId))
        let journeyScreenIDs = Set(payload.journey.screens.map(\.id))
        return ExperienceInteractiveScreen(
            runtime: runtime,
            screenID: screenID,
            validScreenIDs: manifestScreenIDs.intersection(journeyScreenIDs),
            declaredEventNames: Set(
                payload.journey.events[screenID, default: []].map(\.eventName)
            ),
            textInputs: textInputs,
            viewModelsByIdentity: viewModelsByIdentity
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
            viewModelChanges: result.viewModelChanges.map(Self.viewModelChange),
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
        instanceName: String? = nil
    ) throws -> ExperienceInteractiveViewModelReference {
        let identity = ExperienceInteractiveViewModelIdentity(
            viewModelName: viewModelName,
            instanceID: instanceID,
            instanceName: instanceName
        )
        guard let reference = viewModelsByIdentity[identity] else {
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
        let reference = try await operationGate.withLock {
            try await runtime.makeViewModel(
                schemaIndex: schemaIndex,
                authoredInstanceIndex: authoredInstanceIndex
            )
        }
        return ExperienceInteractiveViewModelReference(rawValue: reference.rawValue)!
    }

    func mutateState(
        _ mutations: [ExperienceInteractiveStateMutation],
        correlationID: UInt64 = 0
    ) async throws -> ExperienceInteractiveMutationResult {
        let nativeMutations = mutations.map(Self.nativeMutation)
        let runtime = runtime
        return try await operationGate.withLock { [self] in
            let result = try await runtime.mutateViewModel(
                nativeMutations,
                correlationID: correlationID
            )
            return await projectMutation(result, correlationID: correlationID)
        }
    }

    private func projectMutation(
        _ result: NuxieNativeViewModelMutationResult,
        correlationID: UInt64
    ) -> ExperienceInteractiveMutationResult {
        let effects = router.project(
            reportedEvents: [],
            stateChanges: [],
            viewModelChanges: result.changes.map(Self.viewModelChange),
            hostCommands: [],
            declaredEventNames: declaredEventNames,
            validScreenIDs: validScreenIDs,
            correlationID: correlationID
        )
        return ExperienceInteractiveMutationResult(
            appliedCount: result.appliedCount,
            correlationID: result.correlationID,
            effects: effects
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
        clearColor: UInt32 = 0
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
                try await runtime.render(drawable: state, clearColor: clearColor)
            )
        }
    }

    func close() async throws {
        let runtime = runtime
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
    ) async throws -> [
        ExperienceInteractiveViewModelIdentity: ExperienceInteractiveViewModelReference
    ] {
        let sourceValues = journey.viewModelValues ?? []
        guard let requestedSchemaName = screen.defaultViewModelName else {
            guard sourceValues.isEmpty else {
                throw ExperienceInteractiveScreenError.stateContract(
                    "screen '\(screen.id)' supplies state without a default view model"
                )
            }
            return [:]
        }

        let catalog = try await runtime.viewModelCatalog()
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
        }

        let imageIDs = try ExperienceInteractiveImageIdentityMap.make(
            images: manifest.assets.images
        )
        var detachedMutations: [Selection: [NuxieNativeViewModelMutation]] = [:]
        var finalMutations: [Selection: [NuxieNativeViewModelMutation]] = [:]
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
                        imageIDs: imageIDs
                    )
                }
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
        return productReferences
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
        let values = dictionaryValue(dictionary["values"])
            ?? dictionary.filter { !referencedMetadataKeys.contains($0.key) }
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
        imageIDs: [String: UInt64]
    ) throws -> [NuxieNativeViewModelMutation] {
        try values.keys.sorted().map { path in
            guard let rawValue = values[path] else {
                throw ExperienceInteractiveScreenError.stateContract(path)
            }
            let property = try resolveProperty(path, schema: schema, catalog: catalog)
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
