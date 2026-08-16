#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import CoreGraphics
import ImageIO
import Metal
import QuartzCore
@_implementationOnly import NuxieRuntimeC

package enum NuxieNativeStatus: UInt32, Equatable, Sendable {
    case ok = 0
    case nullArgument = 1
    case importError = 2
    case notFound = 3
    case runtimeError = 4
    case invalidArgument = 5
    case abiMismatch = 6
    case wrongThread = 7
    case invalidStructSize = 8
    case handleMismatch = 9
    case reentrantCall = 10
    case limitExceeded = 11
}

package struct NuxieNativeDiagnostic: Equatable, Sendable {
    package let status: NuxieNativeStatus?
    package let code: String
    package let message: String
}

package enum NuxieNativeRuntimeError: Error, Equatable, Sendable {
    case closed
    case missingHandle(String)
    case invalidNativeValue(String)
    case callFailed(NuxieNativeDiagnostic)
}

extension NuxieNativeRuntimeError: LocalizedError {
    package var errorDescription: String? {
        switch self {
        case .closed:
            "The native runtime is closed."
        case .missingHandle(let name):
            "The native runtime did not publish its \(name) handle."
        case .invalidNativeValue(let message):
            "The native runtime returned an invalid value: \(message)"
        case .callFailed(let diagnostic):
            "Native runtime call failed (\(diagnostic.status.map(String.init(describing:)) ?? "unknown")): "
                + "\(diagnostic.code): \(diagnostic.message)"
        }
    }
}

package enum NuxieNativePlayerSelection: Equatable, Sendable {
    case defaultScene
    case allStateMachines
    case staticArtboard
    case stateMachine(String)
    case linearAnimation(String)
}

/// Chooses only the product-neutral native import capability. The caller
/// supplies the authored module name; the runtime never assigns SDK meaning
/// to command names or payloads.
package enum NuxieNativeImportMode: Equatable, Sendable {
    case portable
    case trustedHostCommands(moduleName: String)
    case configured(
        moduleName: String,
        expectedAssets: [NuxieNativeFileAssetDescriptor],
        externalAssets: [Int: Data]
    )
}

package enum NuxieNativeFileAssetKind: UInt32, Equatable, Sendable {
    case image = 0
    case font = 1
    case audio = 2
    case blob = 3
    case script = 4
    case shader = 5
}

/// Product-neutral identity copied from the inert import's authored asset
/// catalog. Supplying the same catalog to configured import closes the gap
/// between inspection and installation of platform callbacks.
package struct NuxieNativeFileAssetDescriptor: Equatable, Sendable {
    package let ordinal: Int
    package let kind: NuxieNativeFileAssetKind
    package let authoredID: UInt32?
    package let name: String
    package let fileExtension: String
    package let isEmbedded: Bool
    package let hasContentsRecord: Bool
    package let requiredProviderFlags: UInt32
}

package enum NuxieNativePlayerKind: UInt32, Equatable, Sendable {
    case staticArtboard = 0
    case stateMachine = 1
    case linearAnimation = 2
}

package struct NuxieNativePlayerInfo: Equatable, Sendable {
    package let kind: NuxieNativePlayerKind
    package let authoredIndex: Int?
    package let name: String
}

package struct NuxieNativeArtboardInfo: Equatable, Sendable {
    package let index: Int
    package let name: String
    package let stateMachines: [String]
    package let animations: [String]
}

package enum NuxieNativeViewModelPropertyKind: UInt32, Equatable, Sendable {
    case unsupported = 0
    case string = 1
    case number = 2
    case bool = 3
    case color = 4
    case enumeration = 5
    case trigger = 6
    case listIndex = 7
    case list = 8
    case viewModel = 9
    case image = 10
    case font = 11
    case blob = 12
    case artboard = 13
}

package struct NuxieNativeViewModelCatalog: Equatable, Sendable {
    package struct Schema: Equatable, Sendable {
        package let index: Int
        package let name: String
        package let propertyRange: Range<Int>
        package let authoredInstanceRange: Range<Int>
        package let defaultAuthoredInstance: Int?
        package let isGlobal: Bool
    }

    package struct Property: Equatable, Sendable {
        package let schemaIndex: Int
        package let index: Int
        package let name: String
        package let kind: NuxieNativeViewModelPropertyKind
        package let referencedSchemaIndex: Int?
        package let enumLabels: [String]
    }

    package struct AuthoredInstance: Equatable, Sendable {
        package let schemaIndex: Int
        package let index: Int
        package let name: String?
    }

    package let schemas: [Schema]
    package let properties: [Property]
    package let authoredInstances: [AuthoredInstance]
}

package enum NuxieNativePlayerInput: Equatable, Sendable {
    case bool(name: String, value: Bool)
    case number(name: String, value: Float)
    case trigger(name: String)
}

package enum NuxieNativePointerKind: UInt32, Equatable, Sendable {
    case down = 0
    case move = 1
    case up = 2
    case exit = 3
}

package struct NuxieNativePointerEvent: Equatable, Sendable {
    package let kind: NuxieNativePointerKind
    package let x: Float
    package let y: Float
    package let pointerID: Int32
    package let timestamp: Float

    package init(
        kind: NuxieNativePointerKind,
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

package enum NuxieNativePointerHit: UInt32, Equatable, Sendable {
    case none = 0
    case hit = 1
    case opaque = 2
}

package enum NuxieNativeEventPropertyValue: Equatable, Sendable {
    case number(Float)
    case bool(Bool)
    case bytes(Data)
    case color(UInt32)
    case enumeration(UInt64)
    case trigger
}

package struct NuxieNativeEventProperty: Equatable, Sendable {
    package let name: String
    package let value: NuxieNativeEventPropertyValue
}

package struct NuxieNativeEvent: Equatable, Sendable {
    package let localIndex: Int
    package let coreType: UInt32
    package let name: String
    package let url: String
    package let target: String
    package let delay: Float
    package let properties: [NuxieNativeEventProperty]
}

package indirect enum NuxieNativeHostValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case list([NuxieNativeHostValue])
    case object([NuxieNativeHostField])
}

package struct NuxieNativeHostField: Equatable, Sendable {
    package let key: String
    package let value: NuxieNativeHostValue
}

package struct NuxieNativeHostCommand: Equatable, Sendable {
    package let name: String
    package let value: NuxieNativeHostValue
}

package enum NuxieNativeViewModelValue: Equatable, Sendable {
    case unsupported
    case bytes(Data)
    case number(Float)
    case bool(Bool)
    case integer(UInt64)
    case referencedInstance(UInt64)
    case list([UInt64])
}

package struct NuxieNativeViewModelChange: Equatable, Sendable {
    package enum Origin: UInt32, Equatable, Sendable {
        case caller = 0
        case runtime = 1
    }

    package let origin: Origin
    package let correlationID: UInt64
    package let ownerInstanceID: UInt64
    package let propertyIndex: Int
    package let value: NuxieNativeViewModelValue
}

package struct NuxieNativePlayerStepResult: Equatable, Sendable {
    package let keepGoing: Bool
    package let pointerHits: [NuxieNativePointerHit]
    package let stateChanges: [(layerIndex: Int, coreType: UInt32, globalID: UInt32?)]
    package let events: [NuxieNativeEvent]
    package let hostCommands: [NuxieNativeHostCommand]
    package let viewModelChanges: [NuxieNativeViewModelChange]

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keepGoing == rhs.keepGoing
            && lhs.pointerHits == rhs.pointerHits
            && lhs.stateChanges.elementsEqual(rhs.stateChanges) {
                $0.layerIndex == $1.layerIndex
                    && $0.coreType == $1.coreType
                    && $0.globalID == $1.globalID
            }
            && lhs.events == rhs.events
            && lhs.hostCommands == rhs.hostCommands
            && lhs.viewModelChanges == rhs.viewModelChanges
    }
}

package struct NuxieNativeViewModelSnapshot: Equatable, Sendable {
    package struct Instance: Equatable, Sendable {
        package let id: UInt64
        package let schemaIndex: Int
        package let valueRange: Range<Int>
    }

    package struct Value: Equatable, Sendable {
        package let ownerInstanceID: UInt64
        package let propertyIndex: Int
        package let name: String
        package let value: NuxieNativeViewModelValue
    }

    package let rootInstanceID: UInt64
    package let instances: [Instance]
    package let values: [Value]
}

package struct NuxieNativeViewModelMutationResult: Equatable, Sendable {
    package let appliedCount: Int
    package let correlationID: UInt64
    package let changes: [NuxieNativeViewModelChange]
}

/// Runtime-owned identity for one retained ViewModel handle. The opaque C
/// pointer never crosses the actor seam.
package struct NuxieNativeViewModelReference: RawRepresentable, Hashable, Sendable {
    package let rawValue: UInt64

    package init?(rawValue: UInt64) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

/// Product-neutral atomic ViewModel operations supported by ABI v3.
package enum NuxieNativeViewModelMutation: Equatable, Sendable {
    case setString(instance: NuxieNativeViewModelReference, path: String, value: Data)
    case setNumber(instance: NuxieNativeViewModelReference, path: String, value: Float)
    case setBool(instance: NuxieNativeViewModelReference, path: String, value: Bool)
    case setColor(instance: NuxieNativeViewModelReference, path: String, value: UInt32)
    case setEnumeration(instance: NuxieNativeViewModelReference, path: String, value: UInt64)
    case fireTrigger(instance: NuxieNativeViewModelReference, path: String)
    case setListIndex(instance: NuxieNativeViewModelReference, path: String, value: UInt64)
    case setImage(instance: NuxieNativeViewModelReference, path: String, value: UInt64)
    case setViewModel(
        instance: NuxieNativeViewModelReference,
        path: String,
        value: NuxieNativeViewModelReference
    )
    case listInsert(
        instance: NuxieNativeViewModelReference,
        path: String,
        index: Int,
        value: NuxieNativeViewModelReference
    )
    case listRemove(instance: NuxieNativeViewModelReference, path: String, index: Int)
    case listSwap(
        instance: NuxieNativeViewModelReference,
        path: String,
        first: Int,
        second: Int
    )
    case listMove(instance: NuxieNativeViewModelReference, path: String, from: Int, to: Int)
    case listSet(
        instance: NuxieNativeViewModelReference,
        path: String,
        index: Int,
        value: NuxieNativeViewModelReference
    )
    case listClear(instance: NuxieNativeViewModelReference, path: String)
}

package struct NuxieNativeTextRunMutation: Equatable, Sendable {
    package let name: String
    package let text: Data

    package init(name: String, text: Data) {
        self.name = name
        self.text = text
    }
}

package struct NuxieNativeMetalDevice: @unchecked Sendable {
    package let value: any MTLDevice
}

package struct NuxieNativeDrawable: @unchecked Sendable {
    fileprivate let value: any CAMetalDrawable

    package init(_ value: any CAMetalDrawable) {
        self.value = value
    }
}

package enum NuxieNativeDrawableState: Equatable, Sendable {
    case available(NuxieNativeDrawable)
    case timeout
    case occluded

    package static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.available, .available), (.timeout, .timeout), (.occluded, .occluded): true
        default: false
        }
    }
}

package enum NuxieNativeRendererDisposition: UInt32, Equatable, Sendable {
    case none = 0
    case presented = 1
    case skippedZeroSize = 2
    case skippedTimeout = 3
    case skippedOccluded = 4
    case reconfigured = 5
    case recreated = 6
    case deviceLost = 7
    case outOfMemory = 8
}

package enum NuxieNativeRendererHealth: UInt32, Equatable, Sendable {
    case healthy = 0
    case deviceLost = 1
    case outOfMemory = 2
    case failed = 3
}

package struct NuxieNativeRendererOutcome: Equatable, Sendable {
    package let disposition: NuxieNativeRendererDisposition
    package let health: NuxieNativeRendererHealth
    package let pixelWidth: UInt32
    package let pixelHeight: UInt32
    package let drawCalls: UInt64
}

package struct NuxieNativePreparedFileMetrics: Equatable, Sendable {
    package let fileImportCount: Int
    package let openedSessionCount: Int
}

/// One immutable native file import that can vend fresh mutable runtime
/// sessions. Every session retains this owner so cache eviction cannot close
/// the file while a presentation is still using it.
package actor NuxieNativePreparedFile {
    private let executor: NuxieRuntimePinnedThreadExecutor
    private let file: NuxieNativeFileHandle
    private var openedSessionCount = 0

    private init(
        executor: NuxieRuntimePinnedThreadExecutor,
        file: NuxieNativeFileHandle
    ) {
        self.executor = executor
        self.file = file
    }

    package static func prepare(
        bytes: Data,
        importMode: NuxieNativeImportMode = .portable
    ) async throws -> NuxieNativePreparedFile {
        let executor = NuxieRuntimePinnedThreadExecutor()
        do {
            let file = try await executor.call {
                try NuxieNativeFileHandle(
                    executor: executor,
                    bytes: bytes,
                    importMode: importMode
                )
            }
            return NuxieNativePreparedFile(executor: executor, file: file)
        } catch {
            executor.shutdown()
            throw error
        }
    }

    package func openSession(
        artboardName: String,
        player: NuxieNativePlayerSelection,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        bindDefaultViewModel: Bool = false
    ) async throws -> NuxieNativeRuntime {
        let executor = self.executor
        let file = self.file
        let state = try await executor.call {
            try NuxieNativeRuntimeState(
                executor: executor,
                file: file,
                artboardName: artboardName,
                selection: player,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                bindDefaultViewModel: bindDefaultViewModel
            )
        }
        openedSessionCount += 1
        return NuxieNativeRuntime(
            executor: executor,
            state: state,
            preparedFile: self
        )
    }

    package func metrics() -> NuxieNativePreparedFileMetrics {
        NuxieNativePreparedFileMetrics(
            fileImportCount: 1,
            openedSessionCount: openedSessionCount
        )
    }

    deinit {
        let file = file
        executor.enqueue { try? file.close() }
    }
}

package actor NuxieNativeRuntime {
    private let executor: NuxieRuntimePinnedThreadExecutor
    private let preparedFile: NuxieNativePreparedFile?
    private var state: NuxieNativeRuntimeState?

    fileprivate init(
        executor: NuxieRuntimePinnedThreadExecutor,
        state: NuxieNativeRuntimeState,
        preparedFile: NuxieNativePreparedFile? = nil
    ) {
        self.executor = executor
        self.state = state
        self.preparedFile = preparedFile
    }

    /// Copies the authored asset catalog through the script-inert import path.
    /// Product code can authenticate and bind its assets before opening the
    /// configured runtime that installs script and Apple platform hooks.
    package static func inspectAssets(bytes: Data) async throws
        -> [NuxieNativeFileAssetDescriptor]
    {
        let executor = NuxieRuntimePinnedThreadExecutor()
        do {
            return try await executor.callThenShutdown {
                let file = try NuxieNativeFileHandle(
                    executor: executor,
                    bytes: bytes,
                    importMode: .portable
                )
                do {
                    let assets = try file.assets()
                    try file.close()
                    return assets
                } catch {
                    try? file.close()
                    throw error
                }
            }
        } catch {
            executor.shutdown()
            throw error
        }
    }

    package static func open(
        bytes: Data,
        artboardName: String,
        player: NuxieNativePlayerSelection,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        bindDefaultViewModel: Bool = false,
        importMode: NuxieNativeImportMode = .portable
    ) async throws -> NuxieNativeRuntime {
        let executor = NuxieRuntimePinnedThreadExecutor()
        do {
            let state = try await executor.call {
                try NuxieNativeRuntimeState(
                    executor: executor,
                    bytes: bytes,
                    artboardName: artboardName,
                    selection: player,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    bindDefaultViewModel: bindDefaultViewModel,
                    importMode: importMode
                )
            }
            return NuxieNativeRuntime(executor: executor, state: state)
        } catch {
            executor.shutdown()
            throw error
        }
    }

    deinit {
        guard let state else { return }
        executor.enqueue { try? state.close() }
    }

    package func artboards() async throws -> [NuxieNativeArtboardInfo] {
        let state = try requireState()
        return try await executor.call { try state.file.artboards() }
    }

    package func viewModelCatalog() async throws -> NuxieNativeViewModelCatalog {
        let state = try requireState()
        return try await executor.call { try state.file.viewModelCatalog() }
    }

    package func playerInfo() async throws -> NuxieNativePlayerInfo {
        let state = try requireState()
        return try await executor.call { try state.player.info() }
    }

    package func metalDevice() async throws -> NuxieNativeMetalDevice {
        let state = try requireState()
        return try await executor.call { try state.renderer.copyDevice() }
    }

    package func step(
        inputs: [NuxieNativePlayerInput] = [],
        pointers: [NuxieNativePointerEvent] = [],
        elapsedSeconds: Float,
        correlationID: UInt64 = 0
    ) async throws -> NuxieNativePlayerStepResult {
        let state = try requireState()
        return try await executor.call {
            try state.step(
                inputs: inputs,
                pointers: pointers,
                elapsedSeconds: elapsedSeconds,
                correlationID: correlationID
            )
        }
    }

    package func snapshot() async throws -> NuxieNativeViewModelSnapshot {
        let state = try requireState()
        guard let viewModel = state.viewModel else {
            throw NuxieNativeRuntimeError.missingHandle("view model")
        }
        return try await executor.call { try viewModel.snapshot() }
    }

    package func rootViewModelReference() async throws -> NuxieNativeViewModelReference {
        let state = try requireState()
        return try await executor.call { try state.rootViewModelReference() }
    }

    package func makeViewModel(
        schemaIndex: Int,
        authoredInstanceIndex: Int? = nil
    ) async throws -> NuxieNativeViewModelReference {
        let state = try requireState()
        return try await executor.call {
            try state.makeViewModel(
                schemaIndex: schemaIndex,
                authoredInstanceIndex: authoredInstanceIndex
            )
        }
    }

    /// Releases retained detached instances that a higher-level atomic plan
    /// abandoned before attaching them to the runtime graph.
    package func releaseViewModels(
        _ references: [NuxieNativeViewModelReference]
    ) async throws {
        let state = try requireState()
        try await executor.call { try state.releaseViewModels(references) }
    }

    package func mutateViewModel(
        _ mutations: [NuxieNativeViewModelMutation],
        correlationID: UInt64 = 0
    ) async throws -> NuxieNativeViewModelMutationResult {
        let state = try requireState()
        return try await executor.call {
            try state.mutateViewModel(mutations, correlationID: correlationID)
        }
    }

    package func setTextRuns(_ mutations: [NuxieNativeTextRunMutation]) async throws -> Bool {
        let state = try requireState()
        return try await executor.call { try state.artboard.setTextRuns(mutations) }
    }

    package func setNumber(
        _ value: Float,
        path: String,
        correlationID: UInt64 = 0
    ) async throws -> NuxieNativeViewModelMutationResult {
        let state = try requireState()
        guard let viewModel = state.viewModel else {
            throw NuxieNativeRuntimeError.missingHandle("view model")
        }
        return try await executor.call {
            try viewModel.setNumber(value, path: path, correlationID: correlationID)
        }
    }

    package func resize(pixelWidth: UInt32, pixelHeight: UInt32) async throws
        -> NuxieNativeRendererOutcome
    {
        let state = try requireState()
        return try await executor.call {
            try state.renderer.resize(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }
    }

    package func render(
        drawable: NuxieNativeDrawableState,
        clearColor: UInt32 = 0,
        completion: (@Sendable () -> Void)? = nil
    ) async throws -> NuxieNativeRendererOutcome {
        let state: NuxieNativeRuntimeState
        do {
            state = try requireState()
        } catch {
            // Once presentation creates a frame token, the renderer boundary
            // owns consuming it on every path. Calls that reach C transfer the
            // callback pair to the ABI; this preflight failure is the only path
            // that remains Swift-owned.
            completion?()
            throw error
        }
        return try await executor.call {
            try state.renderer.render(
                player: state.player,
                drawable: drawable,
                clearColor: clearColor,
                completion: completion
            )
        }
    }

    package func detachRenderer() async throws -> NuxieNativeRendererOutcome {
        let state = try requireState()
        return try await executor.call { try state.renderer.detach() }
    }

    package func reattachRenderer(
        pixelWidth: UInt32,
        pixelHeight: UInt32
    ) async throws -> NuxieNativeRendererOutcome {
        let state = try requireState()
        return try await executor.call {
            try state.renderer.reattach(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }
    }

    package func resetPlayerRendererDomain() async throws {
        let state = try requireState()
        try await executor.call {
            try state.renderer.resetPlayerDomain(player: state.player)
        }
    }

    package func executorThreadIdentity() async throws -> UInt64 {
        _ = try requireState()
        return try await executor.call {
            UInt64(pthread_mach_thread_np(pthread_self()))
        }
    }

    package func close() async throws {
        guard let state else { return }
        self.state = nil
        if preparedFile == nil {
            try await executor.callThenShutdown { try state.close() }
        } else {
            try await executor.call { try state.close() }
        }
    }

    private func requireState() throws -> NuxieNativeRuntimeState {
        guard let state else { throw NuxieNativeRuntimeError.closed }
        return state
    }
}

private final class NuxieNativeOwnedHandle: @unchecked Sendable {
    typealias Free = (OpaquePointer?) -> UInt32

    private final class FreeOperation: @unchecked Sendable {
        let call: Free

        init(_ call: @escaping Free) {
            self.call = call
        }
    }

    private let executor: NuxieRuntimePinnedThreadExecutor
    private let name: String
    private let free: FreeOperation
    private var handle: OpaquePointer?

    init(
        _ handle: OpaquePointer,
        name: String,
        executor: NuxieRuntimePinnedThreadExecutor,
        free: @escaping Free
    ) {
        self.handle = handle
        self.name = name
        self.executor = executor
        self.free = FreeOperation(free)
    }

    deinit {
        guard let handle else { return }
        let address = UInt(bitPattern: handle)
        let free = self.free
        executor.enqueue { _ = free.call(OpaquePointer(bitPattern: address)) }
    }

    func require() throws -> OpaquePointer {
        guard let handle else { throw NuxieNativeRuntimeError.missingHandle(name) }
        return handle
    }

    func close() throws {
        guard let handle else { return }
        let status = free.call(handle)
        if status == NUX_STATUS_OK.rawValue {
            self.handle = nil
            return
        }
        // ABI v3 consumes a registered handle once destruction begins, even
        // when a destructor panic is contained as RUNTIME_ERROR. Other
        // failures happen before destruction and leave ownership with Swift.
        if status == NUX_STATUS_RUNTIME_ERROR.rawValue {
            self.handle = nil
        }
        throw nativeFailure(status: status, operation: "free \(name)")
    }
}

private final class NuxieNativeRuntimeState: @unchecked Sendable {
    let file: NuxieNativeFileHandle
    let artboard: NuxieNativeArtboardHandle
    let players: [NuxieNativePlayerHandle]
    var player: NuxieNativePlayerHandle { players[0] }
    let viewModel: NuxieNativeViewModelHandle?
    let renderer: NuxieNativeRendererHandle
    private let closesFile: Bool
    private var retainedViewModels: [UInt64: NuxieNativeViewModelHandle] = [:]
    private var isClosed = false

    init(
        executor: NuxieRuntimePinnedThreadExecutor,
        bytes: Data,
        artboardName: String,
        selection: NuxieNativePlayerSelection,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        bindDefaultViewModel: Bool,
        importMode: NuxieNativeImportMode
    ) throws {
        let file = try NuxieNativeFileHandle(
            executor: executor,
            bytes: bytes,
            importMode: importMode
        )
        do {
            let artboard = try file.makeArtboard(named: artboardName)
            let viewModel: NuxieNativeViewModelHandle?
            if bindDefaultViewModel {
                let defaultViewModel = try artboard.makeDefaultViewModel()
                try artboard.bind(viewModel: defaultViewModel)
                viewModel = defaultViewModel
            } else {
                viewModel = nil
            }
            let players = try Self.makePlayers(
                file: file,
                artboard: artboard,
                artboardName: artboardName,
                selection: selection
            )
            let renderer = try NuxieNativeRendererHandle(
                executor: executor,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
            self.file = file
            self.artboard = artboard
            self.players = players
            self.viewModel = viewModel
            self.renderer = renderer
            self.closesFile = true
        } catch {
            try? file.close()
            throw error
        }
    }

    init(
        executor: NuxieRuntimePinnedThreadExecutor,
        file: NuxieNativeFileHandle,
        artboardName: String,
        selection: NuxieNativePlayerSelection,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        bindDefaultViewModel: Bool
    ) throws {
        let artboard = try file.makeArtboard(named: artboardName)
        do {
            let viewModel: NuxieNativeViewModelHandle?
            if bindDefaultViewModel {
                let defaultViewModel = try artboard.makeDefaultViewModel()
                try artboard.bind(viewModel: defaultViewModel)
                viewModel = defaultViewModel
            } else {
                viewModel = nil
            }
            let players = try Self.makePlayers(
                file: file,
                artboard: artboard,
                artboardName: artboardName,
                selection: selection
            )
            let renderer = try NuxieNativeRendererHandle(
                executor: executor,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
            self.file = file
            self.artboard = artboard
            self.players = players
            self.viewModel = viewModel
            self.renderer = renderer
            self.closesFile = false
        } catch {
            try? artboard.close()
            throw error
        }
    }

    func close() throws {
        guard !isClosed else { return }
        var firstError: Error?
        for viewModel in retainedViewModels.values {
            do { try viewModel.close() } catch { firstError = firstError ?? error }
        }
        retainedViewModels.removeAll()
        var operations: [() throws -> Void] = [{ try self.renderer.close() }]
        operations.append(contentsOf: players.reversed().map { player in
            { try player.close() }
        })
        operations.append(contentsOf: [
            { try self.viewModel?.close() },
            { try self.artboard.close() },
        ])
        if closesFile {
            operations.append { try self.file.close() }
        }
        for operation in operations {
            do { try operation() } catch { firstError = firstError ?? error }
        }
        isClosed = true
        if let firstError { throw firstError }
    }

    func step(
        inputs: [NuxieNativePlayerInput],
        pointers: [NuxieNativePointerEvent],
        elapsedSeconds: Float,
        correlationID: UInt64
    ) throws -> NuxieNativePlayerStepResult {
        var keepGoing = false
        var pointerHits = Array(repeating: NuxieNativePointerHit.none, count: pointers.count)
        var stateChanges: [(layerIndex: Int, coreType: UInt32, globalID: UInt32?)] = []
        var events: [NuxieNativeEvent] = []
        var hostCommands: [NuxieNativeHostCommand] = []
        var viewModelChanges: [NuxieNativeViewModelChange] = []

        for player in players {
            let result = try player.step(
                inputs: inputs,
                pointers: pointers,
                elapsedSeconds: elapsedSeconds,
                correlationID: correlationID
            )
            keepGoing = keepGoing || result.keepGoing
            for (index, hit) in result.pointerHits.enumerated() where index < pointerHits.count {
                if hit.precedence > pointerHits[index].precedence {
                    pointerHits[index] = hit
                }
            }
            stateChanges.append(contentsOf: result.stateChanges)
            events.append(contentsOf: result.events)
            hostCommands.append(contentsOf: result.hostCommands)
            viewModelChanges.append(contentsOf: result.viewModelChanges)
        }

        return NuxieNativePlayerStepResult(
            keepGoing: keepGoing,
            pointerHits: pointerHits,
            stateChanges: stateChanges,
            events: events,
            hostCommands: hostCommands,
            viewModelChanges: viewModelChanges
        )
    }

    private static func makePlayers(
        file: NuxieNativeFileHandle,
        artboard: NuxieNativeArtboardHandle,
        artboardName: String,
        selection: NuxieNativePlayerSelection
    ) throws -> [NuxieNativePlayerHandle] {
        guard selection == .allStateMachines else {
            return [try artboard.makePlayer(selection: selection)]
        }
        guard let declaration = try file.artboards().first(where: { $0.name == artboardName }) else {
            throw NuxieNativeRuntimeError.invalidNativeValue(
                "opened artboard \(artboardName) is missing from the file catalog"
            )
        }
        let selections: [NuxieNativePlayerSelection] = declaration.stateMachines.isEmpty
            ? [.staticArtboard]
            : declaration.stateMachines.map(NuxieNativePlayerSelection.stateMachine)
        var players: [NuxieNativePlayerHandle] = []
        do {
            for selection in selections {
                do {
                    players.append(try artboard.makePlayer(selection: selection))
                } catch let NuxieNativeRuntimeError.callFailed(diagnostic)
                    where diagnostic.status == .notFound {
                    // Some valid RIVs retain catalog entries that the native
                    // player factory cannot instantiate. Keep advancing every
                    // playable authored machine instead of making the SDK's
                    // default scene less capable than the runtime default.
                    continue
                }
            }
            guard !players.isEmpty else {
                return [try artboard.makePlayer(selection: .defaultScene)]
            }
            return players
        } catch {
            for player in players.reversed() { try? player.close() }
            throw error
        }
    }

    func rootViewModelReference() throws -> NuxieNativeViewModelReference {
        guard let viewModel else {
            throw NuxieNativeRuntimeError.missingHandle("view model")
        }
        return try viewModel.reference()
    }

    func makeViewModel(
        schemaIndex: Int,
        authoredInstanceIndex: Int?
    ) throws -> NuxieNativeViewModelReference {
        let handle = try file.makeViewModel(
            schemaIndex: schemaIndex,
            authoredInstanceIndex: authoredInstanceIndex
        )
        let reference = try handle.reference()
        guard retainedViewModels[reference.rawValue] == nil else {
            try? handle.close()
            throw NuxieNativeRuntimeError.invalidNativeValue(
                "duplicate view model identity \(reference.rawValue)"
            )
        }
        retainedViewModels[reference.rawValue] = handle
        return reference
    }

    func releaseViewModels(
        _ references: [NuxieNativeViewModelReference]
    ) throws {
        var firstError: Error?
        for reference in references {
            guard let handle = retainedViewModels[reference.rawValue] else { continue }
            do {
                try handle.close()
                retainedViewModels.removeValue(forKey: reference.rawValue)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    func mutateViewModel(
        _ mutations: [NuxieNativeViewModelMutation],
        correlationID: UInt64
    ) throws -> NuxieNativeViewModelMutationResult {
        let rootReference = try viewModel?.reference()
        func resolve(_ reference: NuxieNativeViewModelReference) throws
            -> NuxieNativeViewModelHandle
        {
            if let rootReference, reference == rootReference, let viewModel {
                return viewModel
            }
            guard let handle = retainedViewModels[reference.rawValue] else {
                throw NuxieNativeRuntimeError.missingHandle(
                    "view model \(reference.rawValue)"
                )
            }
            return handle
        }
        return try NuxieNativeViewModelHandle.mutate(
            mutations,
            correlationID: correlationID,
            resolve: resolve
        )
    }
}

private extension NuxieNativePointerHit {
    var precedence: Int {
        switch self {
        case .none: 0
        case .hit: 1
        case .opaque: 2
        }
    }
}

private final class NuxieNativeCapiResultHandle {
    private var result: OpaquePointer?

    init(_ result: OpaquePointer) {
        self.result = result
    }

    deinit {
        if let result { _ = nux_capi_result_free(result) }
    }

    func diagnostic() throws -> NuxieNativeDiagnostic {
        guard let result else {
            throw NuxieNativeRuntimeError.missingHandle("diagnostic result")
        }
        var view = NuxCapiDiagnosticView()
        view.struct_size = UInt32(MemoryLayout<NuxCapiDiagnosticView>.size)
        let status = nux_capi_result_diagnostic(result, &view)
        guard status == NUX_STATUS_OK.rawValue else {
            throw nativeFailure(status: status, operation: "read diagnostic")
        }
        return try copyDiagnostic(view)
    }

    func close() throws {
        guard let result else { return }
        let status = nux_capi_result_free(result)
        if status == NUX_STATUS_OK.rawValue || status == NUX_STATUS_RUNTIME_ERROR.rawValue {
            self.result = nil
        }
        try requireOK(status, operation: "free diagnostic result")
    }

    static func consume(callStatus: UInt32, result: inout OpaquePointer?) throws {
        guard let pointer = result else {
            throw NuxieNativeRuntimeError.invalidNativeValue(
                "native call omitted its owned diagnostic result for status \(callStatus)"
            )
        }
        result = nil
        let owned = NuxieNativeCapiResultHandle(pointer)
        let diagnostic = try owned.diagnostic()
        try owned.close()
        guard callStatus == NUX_STATUS_OK.rawValue else {
            throw NuxieNativeRuntimeError.callFailed(diagnostic)
        }
    }
}

private func makeHostCommandImportConfig() -> NuxHostCommandImportConfig {
    var config = NuxHostCommandImportConfig()
    config.struct_size = UInt32(MemoryLayout<NuxHostCommandImportConfig>.size)
    config.max_script_memory_bytes = 64 * 1_024 * 1_024
    config.max_script_interrupts_per_callback = 50_000
    config.max_commands_per_step = 256
    config.max_value_depth = 32
    config.max_value_nodes = 4_096
    config.max_identifier_bytes = 4_096
    config.max_string_bytes = 1_024 * 1_024
    config.max_value_bytes = 4 * 1_024 * 1_024
    config.max_command_bytes_per_step = 4 * 1_024 * 1_024
    return config
}

/// All callbacks are synchronous during configured import. This context keeps
/// authenticated external bytes and decoded pixel owners alive across each
/// native retain/copy/release cycle without installing a foreign callback in
/// the live player.
private final class NuxieNativeAppleAssetImportContext {
    let externalAssets: [Int: NSData]
    var decodedImages: [NSMutableData] = []

    init(externalAssets: [Int: Data]) {
        self.externalAssets = externalAssets.mapValues { $0 as NSData }
    }
}

private func retainNativeAssetBytes(_ owner: UnsafeMutableRawPointer?) {
    guard let owner else { return }
    _ = Unmanaged<NSData>.fromOpaque(owner).retain()
}

private func releaseNativeAssetBytes(_ owner: UnsafeMutableRawPointer?) {
    guard let owner else { return }
    Unmanaged<NSData>.fromOpaque(owner).release()
}

private func retainedNativeAssetBytes(_ data: NSData) -> NuxRetainedBytes {
    var retained = NuxRetainedBytes()
    retained.struct_size = UInt32(MemoryLayout<NuxRetainedBytes>.size)
    retained.data = data.length == 0
        ? nil
        : data.bytes.assumingMemoryBound(to: UInt8.self)
    retained.len = data.length
    retained.owner = Unmanaged.passUnretained(data).toOpaque()
    retained.retain = retainNativeAssetBytes
    retained.release = releaseNativeAssetBytes
    return retained
}

private func lookupNativeExternalAsset(
    _ rawContext: UnsafeMutableRawPointer?,
    _ request: UnsafePointer<NuxExternalAssetRequest>?,
    _ outBytes: UnsafeMutablePointer<NuxRetainedBytes>?
) -> UInt32 {
    guard let rawContext, let request, let outBytes else {
        return UInt32(NUX_ASSET_CALLBACK_STATUS_FAILED)
    }
    let context = Unmanaged<NuxieNativeAppleAssetImportContext>
        .fromOpaque(rawContext).takeUnretainedValue()
    guard let data = context.externalAssets[request.pointee.asset_index] else {
        return UInt32(NUX_ASSET_CALLBACK_STATUS_NOT_FOUND)
    }
    outBytes.pointee = retainedNativeAssetBytes(data)
    return UInt32(NUX_ASSET_CALLBACK_STATUS_OK)
}

private func decodeNativeImage(
    _ rawContext: UnsafeMutableRawPointer?,
    _ request: UnsafePointer<NuxImageDecodeRequest>?,
    _ outImage: UnsafeMutablePointer<NuxDecodedImage>?
) -> UInt32 {
    guard let rawContext, let request, let outImage,
          let encodedBytes = request.pointee.encoded.data else {
        return UInt32(NUX_ASSET_CALLBACK_STATUS_FAILED)
    }
    let encoded = Data(bytes: encodedBytes, count: request.pointee.encoded.len)
    guard let source = CGImageSourceCreateWithData(encoded as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width > 0,
          image.height > 0,
          image.width <= Int(request.pointee.maximum_dimension),
          image.height <= Int(request.pointee.maximum_dimension) else {
        return UInt32(NUX_ASSET_CALLBACK_STATUS_FAILED)
    }
    let (rowBytes, rowOverflow) = image.width.multipliedReportingOverflow(by: 4)
    let (byteCount, countOverflow) = rowBytes.multipliedReportingOverflow(by: image.height)
    guard !rowOverflow, !countOverflow,
          byteCount <= request.pointee.maximum_decoded_bytes,
          let colors = CGColorSpace(name: CGColorSpace.sRGB),
          let pixels = NSMutableData(length: byteCount),
          let bitmap = CGContext(
            data: pixels.mutableBytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: colors,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
          ) else {
        return UInt32(NUX_ASSET_CALLBACK_STATUS_FAILED)
    }
    bitmap.draw(
        image,
        in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
    let context = Unmanaged<NuxieNativeAppleAssetImportContext>
        .fromOpaque(rawContext).takeUnretainedValue()
    context.decodedImages.append(pixels)
    var decoded = NuxDecodedImage()
    decoded.struct_size = UInt32(MemoryLayout<NuxDecodedImage>.size)
    decoded.width = UInt32(image.width)
    decoded.height = UInt32(image.height)
    decoded.row_bytes = UInt32(rowBytes)
    decoded.pixel_format = UInt32(NUX_PIXEL_FORMAT_RGBA8_PREMULTIPLIED_SRGB)
    decoded.pixels = retainedNativeAssetBytes(pixels)
    outImage.pointee = decoded
    return UInt32(NUX_ASSET_CALLBACK_STATUS_OK)
}

private enum NuxieNativeAppleAssetImporter {
    static func importFile(
        bytes: Data,
        moduleName: String,
        expectedAssets: [NuxieNativeFileAssetDescriptor],
        externalAssets: [Int: Data],
        outFile: inout OpaquePointer?,
        outResult: inout OpaquePointer?
    ) throws -> UInt32 {
        guard expectedAssets.enumerated().allSatisfy({ index, asset in
            asset.ordinal == index
        }), externalAssets.keys.allSatisfy({ expectedAssets.indices.contains($0) }) else {
            throw NuxieNativeRuntimeError.invalidNativeValue(
                "configured assets must use a complete ordered catalog"
            )
        }
        let borrowed = NuxieNativeBorrowedStorage()
        let nativeAssets = expectedAssets.map { asset -> NuxExpectedFileAssetDescriptor in
            var native = NuxExpectedFileAssetDescriptor()
            native.struct_size = UInt32(MemoryLayout<NuxExpectedFileAssetDescriptor>.size)
            native.ordinal = asset.ordinal
            native.kind = asset.kind.rawValue
            native.has_authored_id = asset.authoredID == nil ? 0 : 1
            native.authored_id = asset.authoredID ?? 0
            native.name = borrowed.stringView(asset.name)
            native.file_extension = borrowed.stringView(asset.fileExtension)
            native.is_embedded = asset.isEmbedded ? 1 : 0
            native.has_contents_record = asset.hasContentsRecord ? 1 : 0
            native.required_provider_flags = asset.requiredProviderFlags
            return native
        }
        let callbackContext = NuxieNativeAppleAssetImportContext(
            externalAssets: externalAssets
        )
        var hooks = NuxAppleAssetHooks()
        hooks.struct_size = UInt32(MemoryLayout<NuxAppleAssetHooks>.size)
        hooks.context = Unmanaged.passUnretained(callbackContext).toOpaque()
        hooks.lookup_external_asset = lookupNativeExternalAsset
        hooks.decode_image = decodeNativeImage
        hooks.maximum_external_asset_bytes = 32 * 1_024 * 1_024
        hooks.maximum_total_external_asset_bytes = 128 * 1_024 * 1_024
        hooks.maximum_image_dimension = 8_192
        hooks.maximum_decoded_image_bytes = 256 * 1_024 * 1_024
        hooks.maximum_total_decoded_image_bytes = 512 * 1_024 * 1_024
        var host = makeHostCommandImportConfig()
        var config = NuxFileImportConfig()
        config.struct_size = UInt32(MemoryLayout<NuxFileImportConfig>.size)
        return withStringView(moduleName) { moduleView in
            host.module_name = moduleView
            return nativeAssets.withUnsafeBufferPointer { assetsPointer in
                withUnsafePointer(to: &host) { hostPointer in
                    withUnsafePointer(to: &hooks) { hooksPointer in
                        config.host_commands = hostPointer
                        config.apple_assets = hooksPointer
                        config.expected_assets = assetsPointer.baseAddress
                        config.expected_asset_count = assetsPointer.count
                        return bytes.withUnsafeBytes { rawBytes in
                            nux_product_file_import_configured(
                                rawBytes.bindMemory(to: UInt8.self).baseAddress,
                                rawBytes.count,
                                &config,
                                &outFile,
                                &outResult
                            )
                        }
                    }
                }
            }
        }
    }
}

private final class NuxieNativeFileHandle: @unchecked Sendable {
    private let executor: NuxieRuntimePinnedThreadExecutor
    private let owned: NuxieNativeOwnedHandle

    init(
        executor: NuxieRuntimePinnedThreadExecutor,
        bytes: Data,
        importMode: NuxieNativeImportMode
    ) throws {
        var file: OpaquePointer?
        var result: OpaquePointer?
        let status: UInt32
        switch importMode {
        case .portable:
            status = bytes.withUnsafeBytes { storage in
                nux_file_import_with_result(
                    storage.bindMemory(to: UInt8.self).baseAddress,
                    storage.count,
                    &file,
                    &result
                )
            }
        case .trustedHostCommands(let moduleName):
            var config = makeHostCommandImportConfig()
            status = withStringView(moduleName) { moduleNameView in
                config.module_name = moduleNameView
                return bytes.withUnsafeBytes { storage in
                    nux_file_import_trusted_with_host_commands(
                        storage.bindMemory(to: UInt8.self).baseAddress,
                        storage.count,
                        &config,
                        &file,
                        &result
                    )
                }
            }
        case .configured(let moduleName, let expectedAssets, let externalAssets):
            status = try NuxieNativeAppleAssetImporter.importFile(
                bytes: bytes,
                moduleName: moduleName,
                expectedAssets: expectedAssets,
                externalAssets: externalAssets,
                outFile: &file,
                outResult: &result
            )
        }
        try NuxieNativeCapiResultHandle.consume(callStatus: status, result: &result)
        guard let file else { throw NuxieNativeRuntimeError.missingHandle("file") }
        self.executor = executor
        self.owned = NuxieNativeOwnedHandle(
            file,
            name: "file",
            executor: executor,
            free: nux_file_free
        )
    }

    func assets() throws -> [NuxieNativeFileAssetDescriptor] {
        let file = try owned.require()
        var count = 0
        try requireOK(nux_file_asset_count(file, &count), operation: "count file assets")
        return try (0..<count).map { index in
            var view = NuxFileAssetDescriptorView()
            view.struct_size = UInt32(MemoryLayout<NuxFileAssetDescriptorView>.size)
            try requireOK(
                nux_file_asset_descriptor(file, index, &view),
                operation: "read file asset descriptor"
            )
            guard let kind = NuxieNativeFileAssetKind(rawValue: view.kind) else {
                throw NuxieNativeRuntimeError.invalidNativeValue(
                    "unknown file asset kind \(view.kind)"
                )
            }
            return NuxieNativeFileAssetDescriptor(
                ordinal: view.ordinal,
                kind: kind,
                authoredID: view.has_authored_id == 0 ? nil : view.authored_id,
                name: try copyString(view.name, label: "file asset name"),
                fileExtension: try copyString(
                    view.file_extension,
                    label: "file asset extension"
                ),
                isEmbedded: view.is_embedded != 0,
                hasContentsRecord: view.has_contents_record != 0,
                requiredProviderFlags: view.required_provider_flags
            )
        }
    }

    func artboards() throws -> [NuxieNativeArtboardInfo] {
        let file = try owned.require()
        var count = 0
        try requireOK(nux_file_artboard_count(file, &count), operation: "count artboards")
        return try (0..<count).map { index in
            var name = NuxStringView()
            try requireOK(nux_file_artboard_name(file, index, &name), operation: "read artboard name")
            let copiedName = try copyString(name, label: "artboard name")
            var stateMachineCount = 0
            try requireOK(
                nux_file_artboard_state_machine_count(file, index, &stateMachineCount),
                operation: "count state machines"
            )
            let stateMachines = try (0..<stateMachineCount).map { stateMachineIndex in
                var value = NuxStringView()
                try requireOK(
                    nux_file_artboard_state_machine_name(file, index, stateMachineIndex, &value),
                    operation: "read state machine name"
                )
                return try copyString(value, label: "state machine name")
            }
            var animationCount = 0
            try requireOK(
                nux_file_artboard_animation_count(file, index, &animationCount),
                operation: "count animations"
            )
            let animations = try (0..<animationCount).map { animationIndex in
                var value = NuxStringView()
                try requireOK(
                    nux_file_artboard_animation_name(file, index, animationIndex, &value),
                    operation: "read animation name"
                )
                return try copyString(value, label: "animation name")
            }
            return NuxieNativeArtboardInfo(
                index: index,
                name: copiedName,
                stateMachines: stateMachines,
                animations: animations
            )
        }
    }

    func viewModelCatalog() throws -> NuxieNativeViewModelCatalog {
        var catalog: OpaquePointer?
        try requireOK(
            nux_file_view_model_catalog(try owned.require(), &catalog),
            operation: "create view model catalog"
        )
        guard let catalog else {
            throw NuxieNativeRuntimeError.missingHandle("view model catalog")
        }
        let ownedCatalog = NuxieNativeViewModelCatalogHandle(catalog)
        defer { try? ownedCatalog.close() }
        return try ownedCatalog.copy()
    }

    func makeArtboard(named name: String) throws -> NuxieNativeArtboardHandle {
        var artboard: OpaquePointer?
        var result: OpaquePointer?
        let status = try withStringView(name) { view in
            nux_artboard_instance_new_named_with_result(
                try owned.require(),
                view,
                &artboard,
                &result
            )
        }
        try NuxieNativeCapiResultHandle.consume(callStatus: status, result: &result)
        guard let artboard else { throw NuxieNativeRuntimeError.missingHandle("artboard") }
        return NuxieNativeArtboardHandle(executor: executor, handle: artboard)
    }

    func makeViewModel(
        schemaIndex: Int,
        authoredInstanceIndex: Int?
    ) throws -> NuxieNativeViewModelHandle {
        guard schemaIndex >= 0,
              authoredInstanceIndex.map({ $0 >= 0 }) ?? true else {
            throw NuxieNativeRuntimeError.invalidNativeValue(
                "view model indices must be nonnegative"
            )
        }
        var viewModel: OpaquePointer?
        let status: UInt32
        if let authoredInstanceIndex {
            status = nux_view_model_instance_new_authored(
                try owned.require(),
                schemaIndex,
                authoredInstanceIndex,
                &viewModel
            )
        } else {
            status = nux_view_model_instance_new_schema_default(
                try owned.require(),
                schemaIndex,
                &viewModel
            )
        }
        try requireOK(status, operation: "create view model")
        guard let viewModel else {
            throw NuxieNativeRuntimeError.missingHandle("view model")
        }
        return NuxieNativeViewModelHandle(executor: executor, handle: viewModel)
    }

    func close() throws { try owned.close() }
}

private final class NuxieNativeViewModelCatalogHandle {
    private var catalog: OpaquePointer?

    init(_ catalog: OpaquePointer) {
        self.catalog = catalog
    }

    deinit {
        if let catalog { _ = nux_view_model_catalog_free(catalog) }
    }

    func copy() throws -> NuxieNativeViewModelCatalog {
        guard let catalog else {
            throw NuxieNativeRuntimeError.missingHandle("view model catalog")
        }
        var info = NuxViewModelCatalogInfo()
        info.struct_size = UInt32(MemoryLayout<NuxViewModelCatalogInfo>.size)
        try requireOK(
            nux_view_model_catalog_info(catalog, &info),
            operation: "read view model catalog info"
        )
        let schemas = try (0..<info.schema_count).map { index in
            var view = NuxViewModelSchemaView()
            view.struct_size = UInt32(MemoryLayout<NuxViewModelSchemaView>.size)
            try requireOK(
                nux_view_model_catalog_schema(catalog, index, &view),
                operation: "read view model schema"
            )
            return NuxieNativeViewModelCatalog.Schema(
                index: view.schema_index,
                name: try copyString(view.name, label: "view model schema name"),
                propertyRange: view.first_property..<(try checkedEnd(
                    start: view.first_property,
                    count: view.property_count
                )),
                authoredInstanceRange: view.first_authored_instance..<(try checkedEnd(
                    start: view.first_authored_instance,
                    count: view.authored_instance_count
                )),
                defaultAuthoredInstance: view.default_authored_instance < 0
                    ? nil
                    : view.default_authored_instance,
                isGlobal: view.is_global != 0
            )
        }
        let properties = try (0..<info.property_count).map { index in
            var view = NuxViewModelPropertyView()
            view.struct_size = UInt32(MemoryLayout<NuxViewModelPropertyView>.size)
            try requireOK(
                nux_view_model_catalog_property(catalog, index, &view),
                operation: "read view model property"
            )
            guard let kind = NuxieNativeViewModelPropertyKind(rawValue: view.kind) else {
                throw NuxieNativeRuntimeError.invalidNativeValue(
                    "unknown view model property kind \(view.kind)"
                )
            }
            let labelEnd = try checkedEnd(
                start: view.first_enum_label,
                count: view.enum_label_count
            )
            let labels = try (view.first_enum_label..<labelEnd).map { labelIndex in
                var label = NuxStringView()
                try requireOK(
                    nux_view_model_catalog_enum_label(catalog, labelIndex, &label),
                    operation: "read view model enum label"
                )
                return try copyString(label, label: "view model enum label")
            }
            return NuxieNativeViewModelCatalog.Property(
                schemaIndex: view.schema_index,
                index: view.property_index,
                name: try copyString(view.name, label: "view model property name"),
                kind: kind,
                referencedSchemaIndex: view.referenced_schema_index < 0
                    ? nil
                    : view.referenced_schema_index,
                enumLabels: labels
            )
        }
        let authoredInstances = try (0..<info.authored_instance_count).map { index in
            var view = NuxViewModelAuthoredInstanceView()
            view.struct_size = UInt32(MemoryLayout<NuxViewModelAuthoredInstanceView>.size)
            try requireOK(
                nux_view_model_catalog_authored_instance(catalog, index, &view),
                operation: "read authored view model instance"
            )
            return NuxieNativeViewModelCatalog.AuthoredInstance(
                schemaIndex: view.schema_index,
                index: view.instance_index,
                name: view.name.data == nil && view.name.len == 0
                    ? nil
                    : try copyString(view.name, label: "authored view model instance name")
            )
        }
        return NuxieNativeViewModelCatalog(
            schemas: schemas,
            properties: properties,
            authoredInstances: authoredInstances
        )
    }

    func close() throws {
        guard let catalog else { return }
        let status = nux_view_model_catalog_free(catalog)
        if status == NUX_STATUS_OK.rawValue || status == NUX_STATUS_RUNTIME_ERROR.rawValue {
            self.catalog = nil
        }
        try requireOK(status, operation: "free view model catalog")
    }
}

private final class NuxieNativeArtboardHandle: @unchecked Sendable {
    private let executor: NuxieRuntimePinnedThreadExecutor
    fileprivate let owned: NuxieNativeOwnedHandle

    init(executor: NuxieRuntimePinnedThreadExecutor, handle: OpaquePointer) {
        self.executor = executor
        self.owned = NuxieNativeOwnedHandle(
            handle,
            name: "artboard",
            executor: executor,
            free: nux_artboard_instance_free
        )
    }

    func makePlayer(selection: NuxieNativePlayerSelection) throws -> NuxieNativePlayerHandle {
        var player: OpaquePointer?
        var result: OpaquePointer?
        let artboard = try owned.require()
        let status: UInt32
        switch selection {
        case .defaultScene:
            status = nux_player_new_default_with_result(artboard, &player, &result)
        case .allStateMachines:
            throw NuxieNativeRuntimeError.invalidNativeValue(
                "all state machines must be resolved before creating a native player"
            )
        case .staticArtboard:
            status = nux_player_new_static_with_result(artboard, &player, &result)
        case .stateMachine(let name):
            status = withStringView(name) { view in
                nux_player_new_state_machine_named_with_result(artboard, view, &player, &result)
            }
        case .linearAnimation(let name):
            status = withStringView(name) { view in
                nux_player_new_linear_animation_named_with_result(artboard, view, &player, &result)
            }
        }
        try NuxieNativeCapiResultHandle.consume(callStatus: status, result: &result)
        guard let player else { throw NuxieNativeRuntimeError.missingHandle("player") }
        return NuxieNativePlayerHandle(executor: executor, handle: player)
    }

    func makeDefaultViewModel() throws -> NuxieNativeViewModelHandle {
        var viewModel: OpaquePointer?
        let status = nux_view_model_instance_new_default(try owned.require(), &viewModel)
        try requireOK(status, operation: "create default view model")
        guard let viewModel else { throw NuxieNativeRuntimeError.missingHandle("view model") }
        return NuxieNativeViewModelHandle(executor: executor, handle: viewModel)
    }

    func bind(viewModel: NuxieNativeViewModelHandle) throws {
        try requireOK(
            nux_artboard_instance_bind_view_model(
                try owned.require(),
                try viewModel.owned.require()
            ),
            operation: "bind view model"
        )
    }

    func setTextRuns(_ mutations: [NuxieNativeTextRunMutation]) throws -> Bool {
        let storage = NuxieNativeBorrowedStorage()
        let native = mutations.map { mutation in
            NuxTextRunMutation(
                name: storage.stringView(mutation.name),
                text: storage.byteView(mutation.text)
            )
        }
        return try native.withUnsafeBufferPointer { buffer in
            var batch = NuxTextRunMutationBatch()
            batch.struct_size = UInt32(MemoryLayout<NuxTextRunMutationBatch>.size)
            batch.mutations = buffer.baseAddress
            batch.mutation_count = buffer.count
            var changed: UInt32 = 0
            try requireOK(
                nux_artboard_instance_set_text_runs(try owned.require(), &batch, &changed),
                operation: "set text runs"
            )
            guard changed == 0 || changed == 1 else {
                throw NuxieNativeRuntimeError.invalidNativeValue(
                    "non-canonical text mutation result"
                )
            }
            return changed == 1
        }
    }

    func close() throws { try owned.close() }
}

private final class NuxieNativePlayerHandle: @unchecked Sendable {
    private let owned: NuxieNativeOwnedHandle

    init(executor: NuxieRuntimePinnedThreadExecutor, handle: OpaquePointer) {
        self.owned = NuxieNativeOwnedHandle(
            handle,
            name: "player",
            executor: executor,
            free: nux_player_free
        )
    }

    func info() throws -> NuxieNativePlayerInfo {
        var value = NuxPlayerInfo()
        value.struct_size = UInt32(MemoryLayout<NuxPlayerInfo>.size)
        try requireOK(nux_player_info(try owned.require(), &value), operation: "read player info")
        guard let kind = NuxieNativePlayerKind(rawValue: value.kind) else {
            throw NuxieNativeRuntimeError.invalidNativeValue("unknown player kind \(value.kind)")
        }
        return NuxieNativePlayerInfo(
            kind: kind,
            authoredIndex: value.index < 0 ? nil : value.index,
            name: try copyString(value.name, label: "player name")
        )
    }

    func step(
        inputs: [NuxieNativePlayerInput],
        pointers: [NuxieNativePointerEvent],
        elapsedSeconds: Float,
        correlationID: UInt64
    ) throws -> NuxieNativePlayerStepResult {
        try withNativeInputChanges(inputs) { nativeInputs in
            let nativePointers = pointers.map {
                NuxPlayerPointerEvent(
                    kind: $0.kind.rawValue,
                    x: $0.x,
                    y: $0.y,
                    pointer_id: $0.pointerID,
                    timestamp_seconds: $0.timestamp
                )
            }
            return try nativeInputs.withUnsafeBufferPointer { inputBuffer in
                try nativePointers.withUnsafeBufferPointer { pointerBuffer in
                    var step = NuxPlayerStep()
                    step.struct_size = UInt32(MemoryLayout<NuxPlayerStep>.size)
                    step.inputs = inputBuffer.baseAddress
                    step.input_count = inputBuffer.count
                    step.pointers = pointerBuffer.baseAddress
                    step.pointer_count = pointerBuffer.count
                    step.elapsed_seconds = elapsedSeconds
                    step.correlation_id = correlationID
                    var result: OpaquePointer?
                    let status = nux_player_step(try owned.require(), &step, &result)
                    guard let result else {
                        throw nativeFailure(status: status, operation: "step player")
                    }
                    let ownedResult = NuxieNativePlayerStepResultHandle(result)
                    defer { try? ownedResult.close() }
                    return try ownedResult.copy(callStatus: status)
                }
            }
        }
    }

    func close() throws { try owned.close() }
    fileprivate func require() throws -> OpaquePointer { try owned.require() }
}

private final class NuxieNativePlayerStepResultHandle {
    private var result: OpaquePointer?

    init(_ result: OpaquePointer) { self.result = result }

    deinit {
        if let result { _ = nux_player_step_result_free(result) }
    }

    func copy(callStatus: UInt32) throws -> NuxieNativePlayerStepResult {
        guard let result else { throw NuxieNativeRuntimeError.missingHandle("player step result") }
        var resultStatus = NUX_STATUS_RUNTIME_ERROR.rawValue
        try requireOK(
            nux_player_step_result_status(result, &resultStatus),
            operation: "read player step status"
        )
        guard callStatus == resultStatus else {
            throw NuxieNativeRuntimeError.invalidNativeValue("player step status disagreement")
        }
        if resultStatus != NUX_STATUS_OK.rawValue {
            var diagnostic = NuxCapiDiagnosticView()
            diagnostic.struct_size = UInt32(MemoryLayout<NuxCapiDiagnosticView>.size)
            try requireOK(
                nux_player_step_result_diagnostic(result, &diagnostic),
                operation: "read player step diagnostic"
            )
            throw NuxieNativeRuntimeError.callFailed(try copyDiagnostic(diagnostic))
        }

        var info = NuxPlayerStepInfo()
        info.struct_size = UInt32(MemoryLayout<NuxPlayerStepInfo>.size)
        try requireOK(nux_player_step_result_info(result, &info), operation: "read player step info")

        let pointerHits = try (0..<info.pointer_result_count).map { index in
            var raw: UInt32 = 0
            try requireOK(
                nux_player_step_result_pointer(result, index, &raw),
                operation: "read pointer result"
            )
            guard let hit = NuxieNativePointerHit(rawValue: raw) else {
                throw NuxieNativeRuntimeError.invalidNativeValue("unknown pointer result \(raw)")
            }
            return hit
        }
        let stateChanges = try (0..<info.state_change_count).map { index in
            var view = NuxPlayerStateChangeView()
            view.struct_size = UInt32(MemoryLayout<NuxPlayerStateChangeView>.size)
            try requireOK(
                nux_player_step_result_state_change(result, index, &view),
                operation: "read state change"
            )
            return (
                layerIndex: view.layer_index,
                coreType: view.state_core_type,
                globalID: view.state_global_id == .max ? nil : view.state_global_id
            )
        }
        let events = try (0..<info.event_count).map { index in
            var view = NuxPlayerEventView()
            view.struct_size = UInt32(MemoryLayout<NuxPlayerEventView>.size)
            try requireOK(
                nux_player_step_result_event(result, index, &view),
                operation: "read player event"
            )
            let properties = try (0..<view.property_count).map { propertyIndex in
                var property = NuxPlayerEventPropertyView()
                property.struct_size = UInt32(MemoryLayout<NuxPlayerEventPropertyView>.size)
                try requireOK(
                    nux_player_step_result_event_property(result, index, propertyIndex, &property),
                    operation: "read player event property"
                )
                let value: NuxieNativeEventPropertyValue
                switch property.kind {
                case NUX_PLAYER_EVENT_PROPERTY_KIND_NUMBER.rawValue:
                    value = .number(property.number_value)
                case NUX_PLAYER_EVENT_PROPERTY_KIND_BOOL.rawValue:
                    value = .bool(property.bool_value)
                case NUX_PLAYER_EVENT_PROPERTY_KIND_STRING.rawValue:
                    value = .bytes(try copyData(property.string_value, label: "event string"))
                case NUX_PLAYER_EVENT_PROPERTY_KIND_COLOR.rawValue:
                    value = .color(property.color_value)
                case NUX_PLAYER_EVENT_PROPERTY_KIND_ENUM.rawValue:
                    value = .enumeration(property.integer_value)
                case NUX_PLAYER_EVENT_PROPERTY_KIND_TRIGGER.rawValue:
                    value = .trigger
                default:
                    throw NuxieNativeRuntimeError.invalidNativeValue(
                        "unknown event property kind \(property.kind)"
                    )
                }
                return NuxieNativeEventProperty(
                    name: try copyString(property.name, label: "event property name"),
                    value: value
                )
            }
            return NuxieNativeEvent(
                localIndex: view.event_local_index,
                coreType: view.event_core_type,
                name: try copyString(view.name, label: "event name"),
                url: try copyString(view.url, label: "event URL"),
                target: try copyString(view.target, label: "event target"),
                delay: view.seconds_delay,
                properties: properties
            )
        }
        let hostCommands = try (0..<info.host_command_count).map { index in
            var view = NuxHostCommandView()
            view.struct_size = UInt32(MemoryLayout<NuxHostCommandView>.size)
            try requireOK(
                nux_player_step_result_host_command(result, index, &view),
                operation: "read host command"
            )
            return NuxieNativeHostCommand(
                name: try copyString(view.name, label: "host command name"),
                value: try copyHostValue(result: result, index: view.root_value_index, depth: 0)
            )
        }
        let viewModelChanges = try (0..<info.view_model_change_count).map { index in
            try copyViewModelChange(
                result: result,
                index: index,
                read: nux_player_step_result_view_model_change,
                readListItem: nux_player_step_result_view_model_change_list_item
            )
        }
        return NuxieNativePlayerStepResult(
            keepGoing: info.keep_going,
            pointerHits: pointerHits,
            stateChanges: stateChanges,
            events: events,
            hostCommands: hostCommands,
            viewModelChanges: viewModelChanges
        )
    }

    func close() throws {
        guard let result else { return }
        let status = nux_player_step_result_free(result)
        if status == NUX_STATUS_OK.rawValue || status == NUX_STATUS_RUNTIME_ERROR.rawValue {
            self.result = nil
        }
        try requireOK(status, operation: "free player step result")
    }
}

private final class NuxieNativeViewModelHandle: @unchecked Sendable {
    fileprivate let owned: NuxieNativeOwnedHandle

    init(executor: NuxieRuntimePinnedThreadExecutor, handle: OpaquePointer) {
        self.owned = NuxieNativeOwnedHandle(
            handle,
            name: "view model",
            executor: executor,
            free: nux_view_model_instance_free
        )
    }

    func reference() throws -> NuxieNativeViewModelReference {
        var identity: UInt64 = 0
        try requireOK(
            nux_view_model_instance_identity(try owned.require(), &identity),
            operation: "read view model identity"
        )
        guard let reference = NuxieNativeViewModelReference(rawValue: identity) else {
            throw NuxieNativeRuntimeError.invalidNativeValue(
                "view model identity must be positive"
            )
        }
        return reference
    }

    func snapshot() throws -> NuxieNativeViewModelSnapshot {
        var snapshot: OpaquePointer?
        try requireOK(
            nux_view_model_instance_snapshot(try owned.require(), &snapshot),
            operation: "snapshot view model"
        )
        guard let snapshot else { throw NuxieNativeRuntimeError.missingHandle("view model snapshot") }
        defer { _ = nux_view_model_snapshot_free(snapshot) }
        var info = NuxViewModelSnapshotInfo()
        info.struct_size = UInt32(MemoryLayout<NuxViewModelSnapshotInfo>.size)
        try requireOK(
            nux_view_model_snapshot_info(snapshot, &info),
            operation: "read view model snapshot info"
        )
        let instances = try (0..<info.instance_count).map { index in
            var view = NuxViewModelSnapshotInstanceView()
            view.struct_size = UInt32(MemoryLayout<NuxViewModelSnapshotInstanceView>.size)
            try requireOK(
                nux_view_model_snapshot_instance(snapshot, index, &view),
                operation: "read view model snapshot instance"
            )
            let end = try checkedEnd(start: view.first_value, count: view.value_count)
            return NuxieNativeViewModelSnapshot.Instance(
                id: view.instance_id,
                schemaIndex: view.schema_index,
                valueRange: view.first_value..<end
            )
        }
        let values = try (0..<info.value_count).map { index in
            var view = NuxViewModelSnapshotValueView()
            view.struct_size = UInt32(MemoryLayout<NuxViewModelSnapshotValueView>.size)
            try requireOK(
                nux_view_model_snapshot_value(snapshot, index, &view),
                operation: "read view model snapshot value"
            )
            let listItems = try (0..<view.list_item_count).map { itemOffset in
                let itemIndex = try checkedEnd(start: view.first_list_item, count: itemOffset)
                var identity: UInt64 = 0
                try requireOK(
                    nux_view_model_snapshot_list_item(snapshot, itemIndex, &identity),
                    operation: "read view model list item"
                )
                return identity
            }
            return NuxieNativeViewModelSnapshot.Value(
                ownerInstanceID: view.owner_instance_id,
                propertyIndex: view.property_index,
                name: try copyString(view.name, label: "view model property name"),
                value: try copyViewModelValue(
                    kind: view.kind,
                    bytes: view.bytes_value,
                    number: view.number_value,
                    integer: view.integer_value,
                    bool: view.bool_value,
                    referencedInstance: view.referenced_instance_id,
                    listItems: listItems
                )
            )
        }
        return NuxieNativeViewModelSnapshot(
            rootInstanceID: info.root_instance_id,
            instances: instances,
            values: values
        )
    }

    func setNumber(
        _ value: Float,
        path: String,
        correlationID: UInt64
    ) throws -> NuxieNativeViewModelMutationResult {
        try withStringView(path) { pathView in
            var mutation = NuxViewModelMutation()
            mutation.kind = NUX_VIEW_MODEL_MUTATION_KIND_SET_NUMBER.rawValue
            mutation.instance = try owned.require()
            mutation.path = pathView
            mutation.number_value = value
            return try withUnsafePointer(to: &mutation) { mutationPointer in
                var batch = NuxViewModelMutationBatch()
                batch.struct_size = UInt32(MemoryLayout<NuxViewModelMutationBatch>.size)
                batch.mutations = mutationPointer
                batch.mutation_count = 1
                batch.correlation_id = correlationID
                var result: OpaquePointer?
                let callStatus = nux_view_model_mutate(&batch, &result)
                guard let result else {
                    throw nativeFailure(status: callStatus, operation: "mutate view model")
                }
                defer { _ = nux_view_model_mutation_result_free(result) }
                var info = NuxViewModelMutationResultInfo()
                info.struct_size = UInt32(MemoryLayout<NuxViewModelMutationResultInfo>.size)
                try requireOK(
                    nux_view_model_mutation_result_info(result, &info),
                    operation: "read mutation result"
                )
                guard callStatus == info.status else {
                    throw NuxieNativeRuntimeError.invalidNativeValue("mutation status disagreement")
                }
                if callStatus != NUX_STATUS_OK.rawValue {
                    throw NuxieNativeRuntimeError.callFailed(
                        NuxieNativeDiagnostic(
                            status: NuxieNativeStatus(rawValue: info.status),
                            code: try copyString(info.code, label: "mutation code"),
                            message: try copyString(info.message, label: "mutation message")
                        )
                    )
                }
                let changes = try (0..<info.change_count).map { index in
                    try copyViewModelChange(
                        result: result,
                        index: index,
                        read: nux_view_model_mutation_result_change,
                        readListItem: nux_view_model_mutation_result_change_list_item
                    )
                }
                return NuxieNativeViewModelMutationResult(
                    appliedCount: info.applied_count,
                    correlationID: info.correlation_id,
                    changes: changes
                )
            }
        }
    }

    static func mutate(
        _ mutations: [NuxieNativeViewModelMutation],
        correlationID: UInt64,
        resolve: (NuxieNativeViewModelReference) throws -> NuxieNativeViewModelHandle
    ) throws -> NuxieNativeViewModelMutationResult {
        let storage = NuxieNativeBorrowedStorage()
        var native: [NuxViewModelMutation] = []
        native.reserveCapacity(mutations.count)

        for mutation in mutations {
            var item = NuxViewModelMutation()
            let instance: NuxieNativeViewModelReference
            let path: String
            switch mutation {
            case .setString(let owner, let propertyPath, let value):
                instance = owner
                path = propertyPath
                item.kind = NUX_VIEW_MODEL_MUTATION_KIND_SET_STRING.rawValue
                item.bytes_value = storage.byteView(value)
            case .setNumber(let owner, let propertyPath, let value):
                instance = owner
                path = propertyPath
                item.kind = NUX_VIEW_MODEL_MUTATION_KIND_SET_NUMBER.rawValue
                item.number_value = value
            case .setBool(let owner, let propertyPath, let value):
                instance = owner
                path = propertyPath
                item.kind = NUX_VIEW_MODEL_MUTATION_KIND_SET_BOOL.rawValue
                item.bool_value = value ? 1 : 0
            case .setColor(let owner, let propertyPath, let value):
                instance = owner
                path = propertyPath
                item.kind = NUX_VIEW_MODEL_MUTATION_KIND_SET_COLOR.rawValue
                item.integer_value = UInt64(value)
            case .setEnumeration(let owner, let propertyPath, let value):
                instance = owner
                path = propertyPath
                item.kind = NUX_VIEW_MODEL_MUTATION_KIND_SET_ENUM.rawValue
                item.integer_value = value
            case .fireTrigger(let owner, let propertyPath):
                instance = owner
                path = propertyPath
                item.kind = NUX_VIEW_MODEL_MUTATION_KIND_FIRE_TRIGGER.rawValue
            case .setListIndex(let owner, let propertyPath, let value):
                instance = owner
                path = propertyPath
                item.kind = NUX_VIEW_MODEL_MUTATION_KIND_SET_LIST_INDEX.rawValue
                item.integer_value = value
            case .setImage(let owner, let propertyPath, let value):
                instance = owner
                path = propertyPath
                item.kind = NUX_VIEW_MODEL_MUTATION_KIND_SET_IMAGE.rawValue
                item.integer_value = value
            case .setViewModel(let owner, let propertyPath, let value):
                instance = owner
                path = propertyPath
                item.kind = NUX_VIEW_MODEL_MUTATION_KIND_SET_VIEW_MODEL.rawValue
                item.related_instance = try resolve(value).owned.require()
            case .listInsert(let owner, let propertyPath, let index, let value):
                instance = owner
                path = propertyPath
                item.kind = NUX_VIEW_MODEL_MUTATION_KIND_LIST_INSERT.rawValue
                item.index = index
                item.related_instance = try resolve(value).owned.require()
            case .listRemove(let owner, let propertyPath, let index):
                instance = owner
                path = propertyPath
                item.kind = NUX_VIEW_MODEL_MUTATION_KIND_LIST_REMOVE.rawValue
                item.index = index
            case .listSwap(let owner, let propertyPath, let first, let second):
                instance = owner
                path = propertyPath
                item.kind = NUX_VIEW_MODEL_MUTATION_KIND_LIST_SWAP.rawValue
                item.index = first
                item.second_index = second
            case .listMove(let owner, let propertyPath, let from, let to):
                instance = owner
                path = propertyPath
                item.kind = NUX_VIEW_MODEL_MUTATION_KIND_LIST_MOVE.rawValue
                item.index = from
                item.second_index = to
            case .listSet(let owner, let propertyPath, let index, let value):
                instance = owner
                path = propertyPath
                item.kind = NUX_VIEW_MODEL_MUTATION_KIND_LIST_SET.rawValue
                item.index = index
                item.related_instance = try resolve(value).owned.require()
            case .listClear(let owner, let propertyPath):
                instance = owner
                path = propertyPath
                item.kind = NUX_VIEW_MODEL_MUTATION_KIND_LIST_CLEAR.rawValue
            }
            guard item.index >= 0, item.second_index >= 0 else {
                throw NuxieNativeRuntimeError.invalidNativeValue(
                    "view model list indices must be nonnegative"
                )
            }
            item.instance = try resolve(instance).owned.require()
            item.path = storage.stringView(path)
            native.append(item)
        }

        return try native.withUnsafeBufferPointer { buffer in
            var batch = NuxViewModelMutationBatch()
            batch.struct_size = UInt32(MemoryLayout<NuxViewModelMutationBatch>.size)
            batch.mutations = buffer.baseAddress
            batch.mutation_count = buffer.count
            batch.correlation_id = correlationID
            var result: OpaquePointer?
            let callStatus = nux_view_model_mutate(&batch, &result)
            guard let result else {
                throw nativeFailure(status: callStatus, operation: "mutate view model")
            }
            defer { _ = nux_view_model_mutation_result_free(result) }
            var info = NuxViewModelMutationResultInfo()
            info.struct_size = UInt32(MemoryLayout<NuxViewModelMutationResultInfo>.size)
            try requireOK(
                nux_view_model_mutation_result_info(result, &info),
                operation: "read mutation result"
            )
            guard callStatus == info.status else {
                throw NuxieNativeRuntimeError.invalidNativeValue(
                    "mutation status disagreement"
                )
            }
            if callStatus != NUX_STATUS_OK.rawValue {
                throw NuxieNativeRuntimeError.callFailed(
                    NuxieNativeDiagnostic(
                        status: NuxieNativeStatus(rawValue: info.status),
                        code: try copyString(info.code, label: "mutation code"),
                        message: try copyString(info.message, label: "mutation message")
                    )
                )
            }
            let changes = try (0..<info.change_count).map { index in
                try copyViewModelChange(
                    result: result,
                    index: index,
                    read: nux_view_model_mutation_result_change,
                    readListItem: nux_view_model_mutation_result_change_list_item
                )
            }
            return NuxieNativeViewModelMutationResult(
                appliedCount: info.applied_count,
                correlationID: info.correlation_id,
                changes: changes
            )
        }
    }

    func close() throws { try owned.close() }
}

private final class NuxieNativeRendererHandle: @unchecked Sendable {
    private let owned: NuxieNativeOwnedHandle

    init(
        executor: NuxieRuntimePinnedThreadExecutor,
        pixelWidth: UInt32,
        pixelHeight: UInt32
    ) throws {
        var renderer: OpaquePointer?
        var result: OpaquePointer?
        let status = nux_renderer_new_metal(pixelWidth, pixelHeight, &renderer, &result)
        try NuxieNativeCapiResultHandle.consume(callStatus: status, result: &result)
        guard let renderer else { throw NuxieNativeRuntimeError.missingHandle("Metal renderer") }
        self.owned = NuxieNativeOwnedHandle(
            renderer,
            name: "Metal renderer",
            executor: executor,
            free: nux_renderer_free
        )
    }

    func copyDevice() throws -> NuxieNativeMetalDevice {
        var rawDevice: UnsafeMutableRawPointer?
        var result: OpaquePointer?
        let status = nux_renderer_copy_metal_device(try owned.require(), &rawDevice, &result)
        try NuxieNativeCapiResultHandle.consume(callStatus: status, result: &result)
        guard let rawDevice else { throw NuxieNativeRuntimeError.missingHandle("Metal device") }
        let object = Unmanaged<AnyObject>.fromOpaque(rawDevice).takeRetainedValue()
        guard let device = object as? any MTLDevice else {
            throw NuxieNativeRuntimeError.invalidNativeValue("copied device is not an MTLDevice")
        }
        return NuxieNativeMetalDevice(value: device)
    }

    func resize(pixelWidth: UInt32, pixelHeight: UInt32) throws -> NuxieNativeRendererOutcome {
        var outcome = NuxRendererOutcome()
        outcome.struct_size = UInt32(MemoryLayout<NuxRendererOutcome>.size)
        var result: OpaquePointer?
        let status = nux_renderer_resize(
            try owned.require(),
            pixelWidth,
            pixelHeight,
            &outcome,
            &result
        )
        try NuxieNativeCapiResultHandle.consume(callStatus: status, result: &result)
        return try copyRendererOutcome(outcome)
    }

    func render(
        player: NuxieNativePlayerHandle,
        drawable: NuxieNativeDrawableState,
        clearColor: UInt32,
        completion: (@Sendable () -> Void)?
    ) throws -> NuxieNativeRendererOutcome {
        let renderer = try owned.require()
        let player = try player.require()
        var operation = NuxMetalRenderOperation()
        operation.struct_size = UInt32(MemoryLayout<NuxMetalRenderOperation>.size)
        switch drawable {
        case .available(let drawable):
            operation.drawable_state = UInt32(NUX_METAL_DRAWABLE_STATE_AVAILABLE)
            operation.drawable = Unmanaged.passUnretained(drawable.value as AnyObject).toOpaque()
        case .timeout:
            operation.drawable_state = UInt32(NUX_METAL_DRAWABLE_STATE_TIMEOUT)
        case .occluded:
            operation.drawable_state = UInt32(NUX_METAL_DRAWABLE_STATE_OCCLUDED)
        }
        operation.clear_color = clearColor
        operation.fit = UInt32(NUX_RENDERER_FIT_CONTAIN_CENTER)
        if let completion {
            let box = Unmanaged.passRetained(NuxieNativeRendererCompletion(completion))
            operation.completion_context = box.toOpaque()
            operation.completion_callback = { context in
                guard let context else { return }
                Unmanaged<NuxieNativeRendererCompletion>
                    .fromOpaque(context)
                    .takeRetainedValue()
                    .call()
            }
        }
        var outcome = NuxRendererOutcome()
        outcome.struct_size = UInt32(MemoryLayout<NuxRendererOutcome>.size)
        var result: OpaquePointer?
        let status = nux_renderer_render_player(
            renderer,
            player,
            &operation,
            &outcome,
            &result
        )
        if status == NUX_STATUS_OK.rawValue {
            guard result == nil else {
                defer { _ = nux_capi_result_free(result) }
                throw NuxieNativeRuntimeError.invalidNativeValue(
                    "successful renderer call unexpectedly allocated a result"
                )
            }
        } else {
            try NuxieNativeCapiResultHandle.consume(callStatus: status, result: &result)
        }
        return try copyRendererOutcome(outcome)
    }

    func detach() throws -> NuxieNativeRendererOutcome {
        var outcome = NuxRendererOutcome()
        outcome.struct_size = UInt32(MemoryLayout<NuxRendererOutcome>.size)
        var result: OpaquePointer?
        let status = nux_renderer_detach(try owned.require(), &outcome, &result)
        try NuxieNativeCapiResultHandle.consume(callStatus: status, result: &result)
        return try copyRendererOutcome(outcome)
    }

    func reattach(pixelWidth: UInt32, pixelHeight: UInt32) throws
        -> NuxieNativeRendererOutcome
    {
        var outcome = NuxRendererOutcome()
        outcome.struct_size = UInt32(MemoryLayout<NuxRendererOutcome>.size)
        var result: OpaquePointer?
        let status = nux_renderer_reattach(
            try owned.require(),
            pixelWidth,
            pixelHeight,
            &outcome,
            &result
        )
        try NuxieNativeCapiResultHandle.consume(callStatus: status, result: &result)
        return try copyRendererOutcome(outcome)
    }

    func resetPlayerDomain(player: NuxieNativePlayerHandle) throws {
        var result: OpaquePointer?
        let status = nux_renderer_reset_player_domain(
            try owned.require(),
            try player.require(),
            &result
        )
        try NuxieNativeCapiResultHandle.consume(callStatus: status, result: &result)
    }

    func close() throws { try owned.close() }
}

private final class NuxieNativeRendererCompletion: @unchecked Sendable {
    private let callback: @Sendable () -> Void

    init(_ callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    func call() {
        callback()
    }
}

private func nativeFailure(status: UInt32, operation: String) -> NuxieNativeRuntimeError {
    NuxieNativeRuntimeError.callFailed(
        NuxieNativeDiagnostic(
            status: NuxieNativeStatus(rawValue: status),
            code: "nux_capi.\(operation.replacingOccurrences(of: " ", with: "_"))",
            message: "\(operation) returned status \(status)"
        )
    )
}

private func requireOK(_ status: UInt32, operation: String) throws {
    guard status == NUX_STATUS_OK.rawValue else {
        throw nativeFailure(status: status, operation: operation)
    }
}

private func copyDiagnostic(_ view: NuxCapiDiagnosticView) throws -> NuxieNativeDiagnostic {
    NuxieNativeDiagnostic(
        status: NuxieNativeStatus(rawValue: view.status),
        code: try copyString(view.code, label: "diagnostic code"),
        message: try copyString(view.message, label: "diagnostic message")
    )
}

private func copyString(_ view: NuxStringView, label: String) throws -> String {
    guard view.len == 0 || view.data != nil else {
        throw NuxieNativeRuntimeError.invalidNativeValue("null \(label) with nonzero length")
    }
    guard let data = view.data, view.len > 0 else { return "" }
    let bytes = UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self)
    guard let value = String(
        bytes: UnsafeBufferPointer(start: bytes, count: view.len),
        encoding: .utf8
    ) else {
        throw NuxieNativeRuntimeError.invalidNativeValue("non-UTF-8 \(label)")
    }
    return value
}

private func copyData(_ view: NuxByteView, label: String) throws -> Data {
    guard view.len == 0 || view.data != nil else {
        throw NuxieNativeRuntimeError.invalidNativeValue("null \(label) with nonzero length")
    }
    guard let bytes = view.data, view.len > 0 else { return Data() }
    return Data(bytes: bytes, count: view.len)
}

private func withStringView<T>(
    _ value: String,
    _ operation: (NuxStringView) throws -> T
) rethrows -> T {
    try value.utf8CString.withUnsafeBufferPointer { buffer in
        let count = max(0, buffer.count - 1)
        return try operation(NuxStringView(data: buffer.baseAddress, len: count))
    }
}

/// Owns the buffers borrowed by one synchronous fixed-stride C batch.
private final class NuxieNativeBorrowedStorage {
    private var strings: [UnsafeMutablePointer<CChar>] = []
    private var bytes: [UnsafeMutablePointer<UInt8>] = []

    deinit {
        strings.forEach { $0.deallocate() }
        bytes.forEach { $0.deallocate() }
    }

    func stringView(_ value: String) -> NuxStringView {
        let source = Array(value.utf8)
        guard !source.isEmpty else { return NuxStringView(data: nil, len: 0) }
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: source.count)
        for (index, byte) in source.enumerated() {
            pointer[index] = CChar(bitPattern: byte)
        }
        strings.append(pointer)
        return NuxStringView(data: UnsafePointer(pointer), len: source.count)
    }

    func byteView(_ value: Data) -> NuxByteView {
        guard !value.isEmpty else { return NuxByteView(data: nil, len: 0) }
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: value.count)
        value.copyBytes(to: pointer, count: value.count)
        bytes.append(pointer)
        return NuxByteView(data: UnsafePointer(pointer), len: value.count)
    }
}

private func withNativeInputChanges<T>(
    _ inputs: [NuxieNativePlayerInput],
    _ operation: ([NuxPlayerInputChange]) throws -> T
) rethrows -> T {
    var native = Array(repeating: NuxPlayerInputChange(), count: inputs.count)

    func bind(_ index: Int) throws -> T {
        guard index < inputs.count else { return try operation(native) }
        let name: String
        switch inputs[index] {
        case .bool(let value, _), .number(let value, _), .trigger(let value): name = value
        }
        return try withStringView(name) { view in
            native[index].name = view
            switch inputs[index] {
            case .bool(_, let value):
                native[index].kind = NUX_PLAYER_INPUT_KIND_BOOL.rawValue
                native[index].bool_value = value ? 1 : 0
            case .number(_, let value):
                native[index].kind = NUX_PLAYER_INPUT_KIND_NUMBER.rawValue
                native[index].number_value = value
            case .trigger:
                native[index].kind = NUX_PLAYER_INPUT_KIND_TRIGGER.rawValue
            }
            return try bind(index + 1)
        }
    }

    return try bind(0)
}

private func checkedEnd(start: Int, count: Int) throws -> Int {
    let (end, overflow) = start.addingReportingOverflow(count)
    guard !overflow else {
        throw NuxieNativeRuntimeError.invalidNativeValue("native range overflow")
    }
    return end
}

private func copyHostValue(
    result: OpaquePointer,
    index: Int,
    depth: Int
) throws -> NuxieNativeHostValue {
    guard depth <= 64 else {
        throw NuxieNativeRuntimeError.invalidNativeValue("host value exceeds maximum depth")
    }
    var view = NuxHostValueView()
    view.struct_size = UInt32(MemoryLayout<NuxHostValueView>.size)
    try requireOK(
        nux_player_step_result_host_value(result, index, &view),
        operation: "read host value"
    )
    switch view.kind {
    case NUX_HOST_VALUE_KIND_NULL.rawValue:
        return .null
    case NUX_HOST_VALUE_KIND_BOOL.rawValue:
        return .bool(view.bool_value)
    case NUX_HOST_VALUE_KIND_NUMBER.rawValue:
        return .number(view.number_value)
    case NUX_HOST_VALUE_KIND_STRING.rawValue:
        return .string(try copyString(view.string_value, label: "host string"))
    case NUX_HOST_VALUE_KIND_LIST.rawValue:
        let children = try (0..<view.child_count).map { childIndex -> NuxieNativeHostValue in
            var child = NuxHostValueChildView()
            child.struct_size = UInt32(MemoryLayout<NuxHostValueChildView>.size)
            try requireOK(
                nux_player_step_result_host_value_child(result, index, childIndex, &child),
                operation: "read host list child"
            )
            return try copyHostValue(result: result, index: child.value_index, depth: depth + 1)
        }
        return .list(children)
    case NUX_HOST_VALUE_KIND_OBJECT.rawValue:
        let fields = try (0..<view.child_count).map { childIndex -> NuxieNativeHostField in
            var child = NuxHostValueChildView()
            child.struct_size = UInt32(MemoryLayout<NuxHostValueChildView>.size)
            try requireOK(
                nux_player_step_result_host_value_child(result, index, childIndex, &child),
                operation: "read host object child"
            )
            return NuxieNativeHostField(
                key: try copyString(child.key, label: "host object key"),
                value: try copyHostValue(result: result, index: child.value_index, depth: depth + 1)
            )
        }
        return .object(fields)
    default:
        throw NuxieNativeRuntimeError.invalidNativeValue("unknown host value kind \(view.kind)")
    }
}

private typealias ReadViewModelChange = (
    OpaquePointer?,
    Int,
    UnsafeMutablePointer<NuxViewModelChangeView>?
) -> UInt32

private typealias ReadViewModelChangeListItem = (
    OpaquePointer?,
    Int,
    Int,
    UnsafeMutablePointer<UInt64>?
) -> UInt32

private func copyViewModelChange(
    result: OpaquePointer,
    index: Int,
    read: ReadViewModelChange,
    readListItem: ReadViewModelChangeListItem
) throws -> NuxieNativeViewModelChange {
    var view = NuxViewModelChangeView()
    view.struct_size = UInt32(MemoryLayout<NuxViewModelChangeView>.size)
    try requireOK(read(result, index, &view), operation: "read view model change")
    guard let origin = NuxieNativeViewModelChange.Origin(rawValue: view.origin) else {
        throw NuxieNativeRuntimeError.invalidNativeValue("unknown view model change origin")
    }
    let listItems = try (0..<view.list_item_count).map { itemIndex in
        var identity: UInt64 = 0
        try requireOK(
            readListItem(result, index, itemIndex, &identity),
            operation: "read changed list item"
        )
        return identity
    }
    return NuxieNativeViewModelChange(
        origin: origin,
        correlationID: view.correlation_id,
        ownerInstanceID: view.owner_instance_id,
        propertyIndex: view.property_index,
        value: try copyViewModelValue(
            kind: view.kind,
            bytes: view.bytes_value,
            number: view.number_value,
            integer: view.integer_value,
            bool: view.bool_value,
            referencedInstance: view.referenced_instance_id,
            listItems: listItems
        )
    )
}

private func copyViewModelValue(
    kind: UInt32,
    bytes: NuxByteView,
    number: Float,
    integer: UInt64,
    bool: UInt32,
    referencedInstance: UInt64,
    listItems: [UInt64]
) throws -> NuxieNativeViewModelValue {
    switch kind {
    case NUX_VIEW_MODEL_VALUE_KIND_UNSUPPORTED.rawValue:
        return .unsupported
    case NUX_VIEW_MODEL_VALUE_KIND_STRING.rawValue,
         NUX_VIEW_MODEL_VALUE_KIND_BLOB.rawValue:
        return .bytes(try copyData(bytes, label: "view model bytes"))
    case NUX_VIEW_MODEL_VALUE_KIND_NUMBER.rawValue:
        return .number(number)
    case NUX_VIEW_MODEL_VALUE_KIND_BOOL.rawValue:
        guard bool == 0 || bool == 1 else {
            throw NuxieNativeRuntimeError.invalidNativeValue("non-canonical view model boolean")
        }
        return .bool(bool == 1)
    case NUX_VIEW_MODEL_VALUE_KIND_VIEW_MODEL.rawValue:
        return .referencedInstance(referencedInstance)
    case NUX_VIEW_MODEL_VALUE_KIND_LIST.rawValue:
        return .list(listItems)
    case NUX_VIEW_MODEL_VALUE_KIND_COLOR.rawValue,
         NUX_VIEW_MODEL_VALUE_KIND_ENUM.rawValue,
         NUX_VIEW_MODEL_VALUE_KIND_TRIGGER.rawValue,
         NUX_VIEW_MODEL_VALUE_KIND_LIST_INDEX.rawValue,
         NUX_VIEW_MODEL_VALUE_KIND_IMAGE.rawValue,
         NUX_VIEW_MODEL_VALUE_KIND_FONT.rawValue,
         NUX_VIEW_MODEL_VALUE_KIND_ARTBOARD.rawValue:
        return .integer(integer)
    default:
        throw NuxieNativeRuntimeError.invalidNativeValue(
            "unknown view model value kind \(kind)"
        )
    }
}

private func copyRendererOutcome(_ view: NuxRendererOutcome) throws
    -> NuxieNativeRendererOutcome
{
    guard let disposition = NuxieNativeRendererDisposition(rawValue: view.disposition) else {
        throw NuxieNativeRuntimeError.invalidNativeValue(
            "unknown renderer disposition \(view.disposition)"
        )
    }
    guard let health = NuxieNativeRendererHealth(rawValue: view.health) else {
        throw NuxieNativeRuntimeError.invalidNativeValue("unknown renderer health \(view.health)")
    }
    return NuxieNativeRendererOutcome(
        disposition: disposition,
        health: health,
        pixelWidth: view.pixel_width,
        pixelHeight: view.pixel_height,
        drawCalls: view.draw_calls
    )
}

#endif
