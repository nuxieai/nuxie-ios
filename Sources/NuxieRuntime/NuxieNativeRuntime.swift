#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import Metal
import QuartzCore
import NuxieRuntimeC
import NuxieRuntimeSupport

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
    case staticArtboard
    case stateMachine(String)
    case linearAnimation(String)
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

package actor NuxieNativeRuntime {
    private let executor: NuxieRuntimePinnedThreadExecutor
    private var state: NuxieNativeRuntimeState?

    private init(executor: NuxieRuntimePinnedThreadExecutor, state: NuxieNativeRuntimeState) {
        self.executor = executor
        self.state = state
    }

    package static func open(
        bytes: Data,
        artboardName: String,
        player: NuxieNativePlayerSelection,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        bindDefaultViewModel: Bool = false
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
                    bindDefaultViewModel: bindDefaultViewModel
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
            try state.player.step(
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
        clearColor: UInt32 = 0
    ) async throws -> NuxieNativeRendererOutcome {
        let state = try requireState()
        return try await executor.call {
            try state.renderer.render(player: state.player, drawable: drawable, clearColor: clearColor)
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
        try await executor.callThenShutdown { try state.close() }
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
    let player: NuxieNativePlayerHandle
    let viewModel: NuxieNativeViewModelHandle?
    let renderer: NuxieNativeRendererHandle
    private var isClosed = false

    init(
        executor: NuxieRuntimePinnedThreadExecutor,
        bytes: Data,
        artboardName: String,
        selection: NuxieNativePlayerSelection,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        bindDefaultViewModel: Bool
    ) throws {
        let file = try NuxieNativeFileHandle(executor: executor, bytes: bytes)
        do {
            let artboard = try file.makeArtboard(named: artboardName)
            let viewModel: NuxieNativeViewModelHandle?
            if bindDefaultViewModel {
                viewModel = try artboard.makeDefaultViewModel()
                try artboard.bind(viewModel: viewModel!)
            } else {
                viewModel = nil
            }
            let player = try artboard.makePlayer(selection: selection)
            let renderer = try NuxieNativeRendererHandle(
                executor: executor,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
            self.file = file
            self.artboard = artboard
            self.player = player
            self.viewModel = viewModel
            self.renderer = renderer
        } catch {
            try? file.close()
            throw error
        }
    }

    func close() throws {
        guard !isClosed else { return }
        var firstError: Error?
        for operation in [
            { try self.renderer.close() },
            { try self.player.close() },
            { try self.viewModel?.close() },
            { try self.artboard.close() },
            { try self.file.close() },
        ] {
            do { try operation() } catch { firstError = firstError ?? error }
        }
        isClosed = true
        if let firstError { throw firstError }
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

private final class NuxieNativeFileHandle: @unchecked Sendable {
    private let executor: NuxieRuntimePinnedThreadExecutor
    private let owned: NuxieNativeOwnedHandle

    init(executor: NuxieRuntimePinnedThreadExecutor, bytes: Data) throws {
        var file: OpaquePointer?
        var result: OpaquePointer?
        let status = bytes.withUnsafeBytes { storage in
            nux_file_import_with_result(
                storage.bindMemory(to: UInt8.self).baseAddress,
                storage.count,
                &file,
                &result
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
                defaultAuthoredInstance: view.default_authored_instance == .max
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
                referencedSchemaIndex: view.referenced_schema_index == .max
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
            authoredIndex: value.index == .max ? nil : value.index,
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
        clearColor: UInt32
    ) throws -> NuxieNativeRendererOutcome {
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
        var outcome = NuxRendererOutcome()
        outcome.struct_size = UInt32(MemoryLayout<NuxRendererOutcome>.size)
        var result: OpaquePointer?
        let status = nux_renderer_render_player(
            try owned.require(),
            try player.require(),
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

    func close() throws { try owned.close() }
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
