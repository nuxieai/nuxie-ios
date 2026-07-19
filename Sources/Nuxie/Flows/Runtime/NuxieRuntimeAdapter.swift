#if canImport(NuxieRuntime)
import Foundation
import Metal
import QuartzCore
import NuxieRuntime

enum NuxieRuntimeAdapterError: Error, Equatable {
    case incompatibleABI(
        requiredMajor: UInt16,
        minimumMinor: UInt16,
        actualMajor: UInt16,
        actualMinor: UInt16
    )
    case callFailed(status: NuxieRuntimeStatus, diagnostic: FlowRuntimeDiagnostic)
    case missingHandle(String)
    case missingOperationResult
    case invalidNativeResult(String)
    case invalidFrameTimestamp(TimeInterval)
    case invalidFrameDelta(TimeInterval)
}

/// The driver and lifecycle entry point in the SDK's focused `NuxieRuntime`
/// bridge group.
///
/// Every opaque handle and runtime operation call is confined to one serial executor.
/// Native operations may wait for Rust's pinned worker, so none execute on the
/// main actor. The `@unchecked Sendable` boxes below are deliberately narrow:
/// their mutable fields are touched only inside `NuxieRuntimeSerialExecutor`.
final class NuxieRuntimeAdapter {
    @MainActor
    func makeContext(
        for request: FlowRuntimeImportRequest
    ) async throws -> FlowRuntimeContextDriverAttachment {
        let request = request.normalizedForNativeAuthorizationLimits()
        try request.validateNativeLimits()
        let executor = NuxieRuntimeSerialExecutor()
        let storage = NuxieRuntimeHandleStorage()
        let importStorage = NuxieRuntimeImportStorage(request)

        let importResult = try await executor.call {
            try NuxieRuntimeABI.validate()

            var result: OpaquePointer?
            var context: OpaquePointer?
            let callStatus = withNuxieRuntimeImportRequest(importStorage) { importRequest in
                nux_flow_runtime_context_create(importRequest, &context, &result)
            }

            do {
                let copiedResult = try copyNuxieRuntimeResultSnapshot(
                    callStatus: callStatus,
                    result: &result,
                    renderRequested: false
                )
                guard let context else {
                    throw NuxieRuntimeAdapterError.missingHandle("runtime context")
                }
                guard let scriptAuthorization = copiedResult.scriptAuthorization else {
                    throw NuxieRuntimeAdapterError.invalidNativeResult(
                        "artifact import omitted its script authorization"
                    )
                }
                storage.pointer = context
                return FlowRuntimeImportResult(
                    scriptAuthorization: scriptAuthorization,
                    diagnostics: copiedResult.operationResult.diagnostics
                )
            } catch {
                if let context {
                    nux_flow_runtime_context_free(context)
                }
                throw error
            }
        }

        return FlowRuntimeContextDriverAttachment(
            driver: NuxieRuntimeContextDriver(executor: executor, storage: storage),
            importResult: importResult
        )
    }
}

private final class NuxieRuntimeContextDriver {
    private let executor: NuxieRuntimeSerialExecutor
    private let storage: NuxieRuntimeHandleStorage

    init(
        executor: NuxieRuntimeSerialExecutor,
        storage: NuxieRuntimeHandleStorage
    ) {
        self.executor = executor
        self.storage = storage
    }

    @MainActor
    func makeSession(
        descriptor: FlowRenderSessionDescriptor
    ) async throws -> FlowRuntimeSessionDriverAttachment {
        try validateNuxieRuntimeOptionalSelector(
            descriptor.artboardName,
            label: "artboard name"
        )
        try validateNuxieRuntimeOptionalSelector(
            descriptor.stateMachineName,
            label: "player name"
        )
        let sessionStorage = NuxieRuntimeHandleStorage()
        let artboardBytes = descriptor.artboardName.map { Array($0.utf8) }
        let stateMachineBytes = descriptor.stateMachineName.map { Array($0.utf8) }

        let bootstrap = try await executor.call { [storage] in
            try NuxieRuntimeABI.validate(minimumMinor: NuxieRuntimeABI.sessionMinimumMinor)
            let context = try storage.requiredPointer(named: "runtime context")
            var result: OpaquePointer?
            var session: OpaquePointer?

            let callStatus = withOptionalNuxieRuntimeBytes(artboardBytes) { artboardName in
                withOptionalNuxieRuntimeBytes(stateMachineBytes) { stateMachineName in
                    var sessionDescriptor = NuxFlowConfiguredSessionDescriptor(
                        struct_size: UInt32(
                            MemoryLayout<NuxFlowConfiguredSessionDescriptor>.size
                        ),
                        required_abi_major: NuxieRuntimeABI.major,
                        minimum_abi_minor: NuxieRuntimeABI.sessionMinimumMinor,
                        artboard_name: artboardName,
                        player_name: stateMachineName
                    )
                    return nux_flow_render_session_create_configured(
                        context,
                        &sessionDescriptor,
                        &session,
                        &result
                    )
                }
            }

            do {
                let copiedResult = try copyNuxieFlowSessionResult(
                    callStatus: callStatus,
                    result: &result,
                    renderRequested: false
                )
                guard let session else {
                    throw NuxieRuntimeAdapterError.missingHandle("render session")
                }
                guard let bootstrap = copiedResult.bootstrap else {
                    throw NuxieRuntimeAdapterError.invalidNativeResult(
                        "configured session creation omitted its bootstrap"
                    )
                }
                sessionStorage.pointer = session
                return bootstrap
            } catch {
                if let session {
                    nux_flow_render_session_free(session)
                }
                throw error
            }
        }

        return FlowRuntimeSessionDriverAttachment(
            driver: NuxieRuntimeSessionDriver(
                executor: executor,
                storage: sessionStorage,
                parent: self
            ),
            bootstrap: bootstrap
        )
    }

    func dispose() {
        executor.enqueue { [storage] in
            guard let context = storage.takePointer() else { return }
            nux_flow_runtime_context_free(context)
        }
    }

    deinit {
        dispose()
    }
}

private final class NuxieRuntimeSessionDriver {
    private let executor: NuxieRuntimeSerialExecutor
    private let storage: NuxieRuntimeHandleStorage
    private let parent: NuxieRuntimeContextDriver

    init(
        executor: NuxieRuntimeSerialExecutor,
        storage: NuxieRuntimeHandleStorage,
        parent: NuxieRuntimeContextDriver
    ) {
        self.executor = executor
        self.storage = storage
        self.parent = parent
    }

    @MainActor
    func perform(
        _ operation: FlowRuntimeOperation,
        drawable: FlowRuntimeAppleDrawableTarget?
    ) async throws -> FlowRuntimeOperationResult {
        let operationStorage = try NuxieRuntimeSessionOperationStorage(
            operation: operation,
            hasDrawable: drawable != nil
        )
        let shouldRender = operationStorage.renderRequested
        let drawableReference = drawable.map { NuxieRuntimeDrawableReference($0.drawable) }
        let drawableCompletion = drawable?.completion

        return try await executor.call { [storage] in
            let session = try storage.requiredPointer(named: "render session")
            let completionContext = drawableCompletion.map {
                Unmanaged.passRetained($0).toOpaque()
            }
            var result: OpaquePointer?
            return try operationStorage.withOperation(
                appleDrawable: drawableReference?.opaquePointer,
                completionContext: completionContext,
                completionCallback: completionContext == nil
                    ? nil
                    : nuxieRuntimeFrameDidComplete
            ) { nativeOperation in
                let callStatus = nux_flow_render_session_perform(
                    session,
                    nativeOperation,
                    &result
                )
                return try copyNuxieFlowSessionResult(
                    callStatus: callStatus,
                    result: &result,
                    renderRequested: shouldRender
                )
            }
        }
    }

    @MainActor
    func attachAppleSurface(
        to target: FlowRuntimeAppleSurfaceTarget
    ) async throws -> FlowRuntimeSurfaceDriverAttachment {
        let size = target.size
        let surfaceStorage = NuxieRuntimeSurfaceStorage()

        let (attachmentResult, deviceReference) = try await executor.call { [storage] in
            let session = try storage.requiredPointer(named: "render session")
            var descriptor = nuxieRuntimeSurfaceDescriptor(size: size)
            var result: OpaquePointer?
            var surface: OpaquePointer?
            let callStatus = nux_flow_render_session_attach_apple_surface(
                session,
                &descriptor,
                &surface,
                &result
            )

            do {
                let copiedResult = try copyNuxieRuntimeResult(
                    callStatus: callStatus,
                    result: &result,
                    renderRequested: false
                )
                guard let surface else {
                    throw NuxieRuntimeAdapterError.missingHandle("Apple surface")
                }
                let deviceReference = try copyNuxieRuntimeMetalDevice(from: surface)
                surfaceStorage.pointer = surface
                return (copiedResult, deviceReference)
            } catch {
                if let surface {
                    nux_apple_surface_free(surface)
                }
                throw error
            }
        }

        return FlowRuntimeSurfaceDriverAttachment(
            driver: NuxieRuntimeSurfaceDriver(
                executor: executor,
                storage: surfaceStorage,
                parent: self
            ),
            result: attachmentResult,
            configurator: NuxieRuntimeAppleSurfaceConfigurator(
                deviceReference: deviceReference
            )
        )
    }

    func dispose() {
        executor.enqueue { [storage] in
            guard let session = storage.takePointer() else { return }
            nux_flow_render_session_free(session)
        }
    }

    deinit {
        dispose()
        _ = parent
    }
}

private final class NuxieRuntimeSurfaceDriver {
    private let executor: NuxieRuntimeSerialExecutor
    private let storage: NuxieRuntimeSurfaceStorage
    private let parent: NuxieRuntimeSessionDriver

    init(
        executor: NuxieRuntimeSerialExecutor,
        storage: NuxieRuntimeSurfaceStorage,
        parent: NuxieRuntimeSessionDriver
    ) {
        self.executor = executor
        self.storage = storage
        self.parent = parent
    }

    @MainActor
    func resize(to size: FlowRuntimeSurfaceSize) async throws -> FlowRuntimeOperationResult {
        try await executor.call { [storage] in
            let surface = try storage.requiredPointer(named: "Apple surface")
            var result: OpaquePointer?
            let callStatus = nux_apple_surface_resize(
                surface,
                size.pixelWidth,
                size.pixelHeight,
                &result
            )
            return try copyNuxieRuntimeResult(
                callStatus: callStatus,
                result: &result,
                renderRequested: false
            )
        }
    }

    @MainActor
    func detach() async throws -> FlowRuntimeOperationResult {
        try await executor.call { [storage] in
            let surface = try storage.requiredPointer(named: "Apple surface")
            var result: OpaquePointer?
            let callStatus = nux_apple_surface_detach(surface, &result)
            let copiedResult = try copyNuxieRuntimeResult(
                callStatus: callStatus,
                result: &result,
                renderRequested: false
            )
            return copiedResult
        }
    }

    @MainActor
    func reattach(
        to target: FlowRuntimeAppleSurfaceTarget
    ) async throws -> FlowRuntimeOperationResult {
        let size = target.size

        return try await executor.call { [storage] in
            let surface = try storage.requiredPointer(named: "Apple surface")
            var descriptor = nuxieRuntimeSurfaceDescriptor(size: size)
            var result: OpaquePointer?
            let callStatus = nux_apple_surface_reattach(surface, &descriptor, &result)
            return try copyNuxieRuntimeResult(
                callStatus: callStatus,
                result: &result,
                renderRequested: false
            )
        }
    }

    func dispose() {
        executor.enqueue { [storage] in
            guard let surface = storage.takePointer() else { return }
            nux_apple_surface_free(surface)
        }
    }

    deinit {
        dispose()
        _ = parent
    }
}

extension NuxieRuntimeAdapter: FlowRuntimeAdapter {}
extension NuxieRuntimeContextDriver: FlowRuntimeContextDriver {}
extension NuxieRuntimeSessionDriver: FlowRenderSessionDriver {}
extension NuxieRuntimeSurfaceDriver: FlowRuntimeSurfaceDriver {}

private final class NuxieRuntimeSerialExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nuxie.runtime.apple")

    func call<T>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }

    func enqueue(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}

private class NuxieRuntimeHandleStorage: @unchecked Sendable {
    /// Access only on the associated `NuxieRuntimeSerialExecutor`.
    var pointer: OpaquePointer?

    func requiredPointer(named name: String) throws -> OpaquePointer {
        guard let pointer else {
            throw NuxieRuntimeAdapterError.missingHandle(name)
        }
        return pointer
    }

    func takePointer() -> OpaquePointer? {
        defer { pointer = nil }
        return pointer
    }
}

private final class NuxieRuntimeSurfaceStorage: NuxieRuntimeHandleStorage,
    @unchecked Sendable {}

private final class NuxieRuntimeDrawableReference: @unchecked Sendable {
    let drawable: any CAMetalDrawable

    init(_ drawable: any CAMetalDrawable) {
        self.drawable = drawable
    }

    var opaquePointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(drawable as AnyObject).toOpaque()
    }
}

private func nuxieRuntimeFrameDidComplete(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<FlowRuntimeDrawableCompletion>
        .fromOpaque(context)
        .takeRetainedValue()
        .complete()
}

private final class NuxieRuntimeMetalDeviceReference: @unchecked Sendable {
    let device: any MTLDevice

    init(_ device: any MTLDevice) {
        self.device = device
    }
}

@MainActor
private final class NuxieRuntimeAppleSurfaceConfigurator:
    FlowRuntimeAppleSurfaceConfigurator {
    private let deviceReference: NuxieRuntimeMetalDeviceReference

    init(deviceReference: NuxieRuntimeMetalDeviceReference) {
        self.deviceReference = deviceReference
    }

    func configure(_ target: FlowRuntimeAppleSurfaceTarget) {
        withoutLayerActions {
            let layer = target.layer
            layer.device = deviceReference.device
            layer.pixelFormat = .bgra8Unorm
            layer.framebufferOnly = true
            layer.isOpaque = false
            layer.maximumDrawableCount = FlowRuntimeAppleSurfacePolicy.maximumDrawableCount
            layer.allowsNextDrawableTimeout = true
            layer.presentsWithTransaction = false
            if target.size.pixelWidth > 0, target.size.pixelHeight > 0 {
                layer.drawableSize = CGSize(
                    width: CGFloat(target.size.pixelWidth),
                    height: CGFloat(target.size.pixelHeight)
                )
            }
        }
    }

    func unconfigure(_ target: FlowRuntimeAppleSurfaceTarget) {
        withoutLayerActions {
            if (target.layer.device as AnyObject?) === (deviceReference.device as AnyObject) {
                target.layer.device = nil
            }
        }
    }

    private func withoutLayerActions(_ operation: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        operation()
        CATransaction.commit()
    }
}

enum NuxieRuntimeABI {
    static let major: UInt16 = 1
    static let minimumMinor: UInt16 = 1
    static let sessionMinimumMinor: UInt16 = 2

    static func validate(minimumMinor: UInt16 = NuxieRuntimeABI.minimumMinor) throws {
        let actualMajor = nux_runtime_abi_major()
        let actualMinor = nux_runtime_abi_minor()
        let requireStatus = nux_runtime_require_abi(major, minimumMinor)
        guard actualMajor == major,
              actualMinor >= minimumMinor,
              requireStatus == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.incompatibleABI(
                requiredMajor: major,
                minimumMinor: minimumMinor,
                actualMajor: actualMajor,
                actualMinor: actualMinor
            )
        }
    }
}

private func nuxieRuntimeSurfaceDescriptor(
    size: FlowRuntimeSurfaceSize
) -> NuxAppleSurfaceDescriptor {
    NuxAppleSurfaceDescriptor(
        struct_size: UInt32(MemoryLayout<NuxAppleSurfaceDescriptor>.size),
        pixel_width: size.pixelWidth,
        pixel_height: size.pixelHeight
    )
}

private func copyNuxieRuntimeMetalDevice(
    from surface: OpaquePointer
) throws -> NuxieRuntimeMetalDeviceReference {
    var devicePointer: UnsafeMutableRawPointer?
    var result: OpaquePointer?
    let callStatus = nux_apple_surface_copy_metal_device(
        surface,
        &devicePointer,
        &result
    )
    _ = try copyNuxieRuntimeResult(
        callStatus: callStatus,
        result: &result,
        renderRequested: false
    )
    guard let devicePointer else {
        throw NuxieRuntimeAdapterError.missingHandle("Metal device")
    }
    let ownedObject = Unmanaged<AnyObject>.fromOpaque(devicePointer).takeRetainedValue()
    guard let device = ownedObject as? any MTLDevice else {
        throw NuxieRuntimeAdapterError.missingHandle("Metal device")
    }
    return NuxieRuntimeMetalDeviceReference(device)
}

private func withOptionalNuxieRuntimeBytes<T>(
    _ bytes: [UInt8]?,
    _ body: (NuxByteView) throws -> T
) rethrows -> T {
    guard let bytes else {
        return try body(NuxByteView(data: nil, len: 0))
    }
    if bytes.isEmpty {
        var sentinel: UInt8 = 0
        return try withUnsafePointer(to: &sentinel) { pointer in
            try body(NuxByteView(data: pointer, len: 0))
        }
    }
    return try bytes.withUnsafeBufferPointer { buffer in
        try body(
            NuxByteView(
                data: buffer.baseAddress,
                len: UInt64(buffer.count)
            )
        )
    }
}

private func validateNuxieRuntimeOptionalSelector(
    _ value: String?,
    label: String
) throws {
    guard let value else { return }
    guard !value.isEmpty else {
        throw FlowRuntimeSessionValueError.invalidValue(
            "Runtime \(label) must not be empty"
        )
    }
    guard value.utf8.count <= FlowRuntimeSessionLimits.identifierBytes else {
        throw FlowRuntimeSessionValueError.limitExceeded(
            "Runtime \(label) exceeds 4 KiB"
        )
    }
}

/// Owns every byte and C-array address selected by one ABI 1.2 operation.
///
/// Rust copies the complete request during the synchronous `perform` call.
/// Allocating nested arrays here avoids retaining pointers obtained from an
/// escaped `withUnsafeBytes` closure and makes those lifetimes explicit.
final class NuxieRuntimeSessionOperationStorage: @unchecked Sendable {
    typealias CompletionCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

    let renderRequested: Bool

    private enum Payload {
        case stateBatch
        case pointerBatch
        case advance(time: FlowRuntimeFrameTime, render: Bool)
        case queryBatch
    }

    private let payload: Payload
    private let bytes = NuxieRuntimeOwnedByteArena()
    private var valueNodes: NuxieRuntimeNativeBuffer<NuxFlowValueNode>?
    private var valueArena: NuxieRuntimeNativeBuffer<NuxFlowValueArena>?
    private var newInstances: NuxieRuntimeNativeBuffer<NuxFlowNewInstance>?
    private var mutations: NuxieRuntimeNativeBuffer<NuxFlowStateMutation>?
    private var stateBatch: NuxieRuntimeNativeBuffer<NuxFlowStateBatch>?
    private var pointerEvents: NuxieRuntimeNativeBuffer<NuxFlowPointerEvent>?
    private var pointerBatch: NuxieRuntimeNativeBuffer<NuxFlowPointerBatch>?
    private var queries: NuxieRuntimeNativeBuffer<NuxFlowQuery>?
    private var queryBatch: NuxieRuntimeNativeBuffer<NuxFlowQueryBatch>?

    init(operation: FlowRuntimeOperation, hasDrawable: Bool) throws {
        switch operation {
        case .stateBatch(let batch):
            guard !hasDrawable else {
                throw FlowRuntimeSessionValueError.invalidValue(
                    "A drawable is valid only for advance-and-render"
                )
            }
            renderRequested = false
            payload = .stateBatch
            try buildStateBatch(batch)

        case .pointerBatch(let events):
            guard !hasDrawable else {
                throw FlowRuntimeSessionValueError.invalidValue(
                    "A drawable is valid only for advance-and-render"
                )
            }
            renderRequested = false
            payload = .pointerBatch
            try buildPointerBatch(events)

        case .advance(let time):
            guard !hasDrawable else {
                throw FlowRuntimeSessionValueError.invalidValue(
                    "A non-rendering advance cannot carry a drawable"
                )
            }
            try Self.validateFrameTime(time)
            renderRequested = false
            payload = .advance(time: time, render: false)

        case .advanceAndRender(let time):
            try Self.validateFrameTime(time)
            renderRequested = true
            payload = .advance(time: time, render: true)

        case .query(let queries):
            guard !hasDrawable else {
                throw FlowRuntimeSessionValueError.invalidValue(
                    "A drawable is valid only for advance-and-render"
                )
            }
            renderRequested = false
            payload = .queryBatch
            try buildQueryBatch(queries)
        }
    }

    func withOperation<T>(
        appleDrawable: UnsafeMutableRawPointer?,
        completionContext: UnsafeMutableRawPointer?,
        completionCallback: CompletionCallback?,
        _ body: (UnsafePointer<NuxFlowSessionOperation>) throws -> T
    ) rethrows -> T {
        switch payload {
        case .stateBatch:
            var operation = nativeOperation(
                kind: UInt32(NUX_FLOW_SESSION_OPERATION_KIND_STATE_BATCH),
                stateBatch: stateBatch?.pointer
            )
            return try withUnsafePointer(to: &operation, body)

        case .pointerBatch:
            var operation = nativeOperation(
                kind: UInt32(NUX_FLOW_SESSION_OPERATION_KIND_POINTER_BATCH),
                pointerBatch: pointerBatch?.pointer
            )
            return try withUnsafePointer(to: &operation, body)

        case .advance(let time, let render):
            var advance = NuxFlowAdvanceOperation(
                struct_size: UInt32(MemoryLayout<NuxFlowAdvanceOperation>.size),
                timestamp_seconds: time.timestamp,
                delta_seconds: Float(time.delta),
                render: render ? 1 : 0,
                apple_drawable: appleDrawable,
                completion_context: completionContext,
                completion_callback: completionCallback
            )
            return try withUnsafePointer(to: &advance) { advancePointer in
                var operation = nativeOperation(
                    kind: UInt32(NUX_FLOW_SESSION_OPERATION_KIND_ADVANCE),
                    advance: advancePointer
                )
                return try withUnsafePointer(to: &operation, body)
            }

        case .queryBatch:
            var operation = nativeOperation(
                kind: UInt32(NUX_FLOW_SESSION_OPERATION_KIND_QUERY),
                queryBatch: queryBatch?.pointer
            )
            return try withUnsafePointer(to: &operation, body)
        }
    }

    private func nativeOperation(
        kind: UInt32,
        stateBatch: UnsafeMutablePointer<NuxFlowStateBatch>? = nil,
        pointerBatch: UnsafeMutablePointer<NuxFlowPointerBatch>? = nil,
        advance: UnsafePointer<NuxFlowAdvanceOperation>? = nil,
        queryBatch: UnsafeMutablePointer<NuxFlowQueryBatch>? = nil
    ) -> NuxFlowSessionOperation {
        NuxFlowSessionOperation(
            struct_size: UInt32(MemoryLayout<NuxFlowSessionOperation>.size),
            required_abi_major: NuxieRuntimeABI.major,
            minimum_abi_minor: NuxieRuntimeABI.sessionMinimumMinor,
            kind: kind,
            state_batch: stateBatch.map { UnsafePointer($0) },
            pointer_batch: pointerBatch.map { UnsafePointer($0) },
            advance: advance,
            query_batch: queryBatch.map { UnsafePointer($0) }
        )
    }

    private func buildStateBatch(_ batch: FlowRuntimeStateBatch) throws {
        let itemCount = try Self.checkedSum(
            batch.newInstances.count,
            batch.mutations.count,
            label: "state batch item count"
        )
        guard itemCount > 0 else {
            throw FlowRuntimeSessionValueError.invalidValue(
                "Runtime state batches must not be empty"
            )
        }
        guard itemCount <= FlowRuntimeSessionLimits.batchItems else {
            throw FlowRuntimeSessionValueError.limitExceeded(
                "Runtime state batch exceeds 4,096 combined items"
            )
        }

        var payloadBytes = 0
        func charge(_ count: Int, label: String) throws {
            payloadBytes = try Self.checkedSum(payloadBytes, count, label: label)
            guard payloadBytes <= FlowRuntimeSessionLimits.encodedPayloadBytes else {
                throw FlowRuntimeSessionValueError.limitExceeded(
                    "Runtime operation payload exceeds 4 MiB"
                )
            }
        }
        func requiredView(
            _ value: String,
            limit: Int,
            label: String,
            path: Bool = false
        ) throws -> NuxByteView {
            let encoded = Array(value.utf8)
            guard !encoded.isEmpty else {
                throw FlowRuntimeSessionValueError.invalidValue(
                    "Runtime \(label) must not be empty"
                )
            }
            guard encoded.count <= limit else {
                throw FlowRuntimeSessionValueError.limitExceeded(
                    "Runtime \(label) exceeds \(limit) UTF-8 bytes"
                )
            }
            if path, value.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty }) {
                throw FlowRuntimeSessionValueError.invalidValue(
                    "Runtime \(label) contains an empty path segment"
                )
            }
            try charge(encoded.count, label: label)
            return bytes.store(encoded)
        }
        func optionalView(_ value: String?, label: String) throws -> NuxByteView {
            guard let value else { return Self.nullByteView }
            return try requiredView(
                value,
                limit: FlowRuntimeSessionLimits.identifierBytes,
                label: label
            )
        }

        let declaredLocalIDs = Set(batch.newInstances.map(\.localID))
        guard declaredLocalIDs.count == batch.newInstances.count else {
            throw FlowRuntimeSessionValueError.invalidValue(
                "Runtime state batch contains duplicate new-instance local IDs"
            )
        }

        var nativeNewInstances: [NuxFlowNewInstance] = []
        nativeNewInstances.reserveCapacity(batch.newInstances.count)
        for instance in batch.newInstances {
            nativeNewInstances.append(
                NuxFlowNewInstance(
                    struct_size: UInt32(MemoryLayout<NuxFlowNewInstance>.size),
                    local_id: instance.localID,
                    schema_name: try requiredView(
                        instance.schemaName,
                        limit: FlowRuntimeSessionLimits.identifierBytes,
                        label: "new-instance schema name",
                        path: true
                    ),
                    authored_instance_name: try optionalView(
                        instance.authoredInstanceName,
                        label: "authored instance name"
                    )
                )
            )
        }

        var nativeNodes: [NuxFlowValueNode] = []
        nativeNodes.reserveCapacity(batch.mutations.count)
        func appendScalar(_ value: FlowRuntimeScalarValue) throws -> UInt32 {
            guard nativeNodes.count < FlowRuntimeSessionLimits.valueNodes else {
                throw FlowRuntimeSessionValueError.limitExceeded(
                    "Runtime state batch value-node limit exceeded"
                )
            }
            let kind: UInt32
            var number = 0.0
            var color: UInt32 = 0
            var bool: UInt32 = 0
            var identity: UInt64 = 0
            var string = Self.nullByteView
            switch value {
            case .null:
                kind = UInt32(NUX_FLOW_VALUE_KIND_NULL)
            case .string(let value):
                let encoded = Array(value.utf8)
                guard encoded.count <= FlowRuntimeSessionLimits.stringBytes else {
                    throw FlowRuntimeSessionValueError.limitExceeded(
                        "Runtime scalar string exceeds 1 MiB"
                    )
                }
                try charge(encoded.count, label: "scalar string")
                string = bytes.store(encoded)
                kind = UInt32(NUX_FLOW_VALUE_KIND_STRING)
            case .number(let value):
                guard value.isFinite,
                      abs(value) <= Double(Float.greatestFiniteMagnitude) else {
                    throw FlowRuntimeSessionValueError.invalidValue(
                        "Runtime scalar number must be finite and representable as Float"
                    )
                }
                number = value
                kind = UInt32(NUX_FLOW_VALUE_KIND_NUMBER)
            case .bool(let value):
                bool = value ? 1 : 0
                kind = UInt32(NUX_FLOW_VALUE_KIND_BOOL)
            case .enumeration(let value):
                identity = value
                kind = UInt32(NUX_FLOW_VALUE_KIND_ENUM)
            case .listIndex(let value):
                identity = value
                kind = UInt32(NUX_FLOW_VALUE_KIND_LIST_INDEX)
            case .color(let value):
                color = value
                kind = UInt32(NUX_FLOW_VALUE_KIND_COLOR)
            case .image(let value):
                identity = value
                kind = UInt32(NUX_FLOW_VALUE_KIND_IMAGE)
            case .trigger:
                throw FlowRuntimeSessionValueError.invalidValue(
                    "Trigger counts cannot be sent as scalar state values"
                )
            }
            let index = UInt32(nativeNodes.count)
            nativeNodes.append(
                NuxFlowValueNode(
                    struct_size: UInt32(MemoryLayout<NuxFlowValueNode>.size),
                    kind: kind,
                    number_value: number,
                    color_value: color,
                    bool_value: bool,
                    first_edge: 0,
                    edge_count: 0,
                    has_instance_id: 0,
                    instance_id: 0,
                    identity_value: identity,
                    string_value: string,
                    schema_id: Self.nullByteView
                )
            )
            return index
        }

        func nativeReference(
            _ reference: FlowRuntimeInstanceReference
        ) throws -> NuxFlowInstanceReference {
            switch reference {
            case .existing(let id):
                return NuxFlowInstanceReference(
                    kind: UInt32(NUX_FLOW_INSTANCE_REFERENCE_KIND_EXISTING),
                    local_id: 0,
                    instance_id: id.rawValue
                )
            case .new(let localID):
                guard declaredLocalIDs.contains(localID) else {
                    throw FlowRuntimeSessionValueError.invalidValue(
                        "Runtime mutation references undeclared new-instance local ID \(localID)"
                    )
                }
                return NuxFlowInstanceReference(
                    kind: UInt32(NUX_FLOW_INSTANCE_REFERENCE_KIND_NEW),
                    local_id: localID,
                    instance_id: 0
                )
            }
        }

        let zeroReference = NuxFlowInstanceReference(kind: 0, local_id: 0, instance_id: 0)
        var nativeMutations: [NuxFlowStateMutation] = []
        nativeMutations.reserveCapacity(batch.mutations.count)
        for mutation in batch.mutations {
            let kind: UInt32
            var instance = zeroReference
            var item = zeroReference
            var path = Self.nullByteView
            var inputName = Self.nullByteView
            var valueRootIndex = UInt32.max
            var index: UInt32 = 0
            var otherIndex: UInt32 = 0

            switch mutation {
            case .setInputBool(let name, let value):
                kind = UInt32(NUX_FLOW_STATE_MUTATION_KIND_SET_INPUT_BOOL)
                inputName = try requiredView(
                    name,
                    limit: FlowRuntimeSessionLimits.identifierBytes,
                    label: "player-input name",
                    path: true
                )
                valueRootIndex = try appendScalar(.bool(value))
            case .setInputNumber(let name, let value):
                kind = UInt32(NUX_FLOW_STATE_MUTATION_KIND_SET_INPUT_NUMBER)
                inputName = try requiredView(
                    name,
                    limit: FlowRuntimeSessionLimits.identifierBytes,
                    label: "player-input name",
                    path: true
                )
                valueRootIndex = try appendScalar(.number(value))
            case .fireInputTrigger(let name):
                kind = UInt32(NUX_FLOW_STATE_MUTATION_KIND_FIRE_INPUT_TRIGGER)
                inputName = try requiredView(
                    name,
                    limit: FlowRuntimeSessionLimits.identifierBytes,
                    label: "player-input name",
                    path: true
                )
            case .setValue(let reference, let propertyPath, let value):
                kind = UInt32(NUX_FLOW_STATE_MUTATION_KIND_SET)
                instance = try nativeReference(reference)
                path = try requiredView(
                    propertyPath,
                    limit: FlowRuntimeSessionLimits.pathBytes,
                    label: "property path",
                    path: true
                )
                valueRootIndex = try appendScalar(value)
            case .setViewModel(let reference, let propertyPath, let replacement):
                kind = UInt32(NUX_FLOW_STATE_MUTATION_KIND_SET_VIEW_MODEL)
                instance = try nativeReference(reference)
                item = try nativeReference(replacement)
                path = try requiredView(
                    propertyPath,
                    limit: FlowRuntimeSessionLimits.pathBytes,
                    label: "view-model property path",
                    path: true
                )
            case .fireTrigger(let reference, let propertyPath):
                kind = UInt32(NUX_FLOW_STATE_MUTATION_KIND_TRIGGER)
                instance = try nativeReference(reference)
                path = try requiredView(
                    propertyPath,
                    limit: FlowRuntimeSessionLimits.pathBytes,
                    label: "property path",
                    path: true
                )
            case .listInsert(let reference, let propertyPath, let position, let row):
                kind = UInt32(NUX_FLOW_STATE_MUTATION_KIND_LIST_INSERT)
                instance = try nativeReference(reference)
                item = try nativeReference(row)
                path = try requiredView(
                    propertyPath,
                    limit: FlowRuntimeSessionLimits.pathBytes,
                    label: "list path",
                    path: true
                )
                index = position
            case .listRemove(let reference, let propertyPath, let position):
                kind = UInt32(NUX_FLOW_STATE_MUTATION_KIND_LIST_REMOVE)
                instance = try nativeReference(reference)
                path = try requiredView(
                    propertyPath,
                    limit: FlowRuntimeSessionLimits.pathBytes,
                    label: "list path",
                    path: true
                )
                index = position
            case .listSwap(let reference, let propertyPath, let first, let second):
                kind = UInt32(NUX_FLOW_STATE_MUTATION_KIND_LIST_SWAP)
                instance = try nativeReference(reference)
                path = try requiredView(
                    propertyPath,
                    limit: FlowRuntimeSessionLimits.pathBytes,
                    label: "list path",
                    path: true
                )
                index = first
                otherIndex = second
            case .listMove(let reference, let propertyPath, let from, let to):
                kind = UInt32(NUX_FLOW_STATE_MUTATION_KIND_LIST_MOVE)
                instance = try nativeReference(reference)
                path = try requiredView(
                    propertyPath,
                    limit: FlowRuntimeSessionLimits.pathBytes,
                    label: "list path",
                    path: true
                )
                index = from
                otherIndex = to
            case .listSet(let reference, let propertyPath, let position, let row):
                kind = UInt32(NUX_FLOW_STATE_MUTATION_KIND_LIST_SET)
                instance = try nativeReference(reference)
                item = try nativeReference(row)
                path = try requiredView(
                    propertyPath,
                    limit: FlowRuntimeSessionLimits.pathBytes,
                    label: "list path",
                    path: true
                )
                index = position
            case .listClear(let reference, let propertyPath):
                kind = UInt32(NUX_FLOW_STATE_MUTATION_KIND_LIST_CLEAR)
                instance = try nativeReference(reference)
                path = try requiredView(
                    propertyPath,
                    limit: FlowRuntimeSessionLimits.pathBytes,
                    label: "list path",
                    path: true
                )
            }

            nativeMutations.append(
                NuxFlowStateMutation(
                    struct_size: UInt32(MemoryLayout<NuxFlowStateMutation>.size),
                    kind: kind,
                    instance: instance,
                    item: item,
                    path: path,
                    input_name: inputName,
                    value_root_index: valueRootIndex,
                    index: index,
                    other_index: otherIndex
                )
            )
        }

        let nodeBuffer = NuxieRuntimeNativeBuffer(nativeNodes)
        let arenaBuffer = NuxieRuntimeNativeBuffer([
            NuxFlowValueArena(
                struct_size: UInt32(MemoryLayout<NuxFlowValueArena>.size),
                nodes: nodeBuffer.constPointer,
                node_count: UInt64(nodeBuffer.count),
                edges: nil,
                edge_count: 0
            ),
        ])
        let instanceBuffer = NuxieRuntimeNativeBuffer(nativeNewInstances)
        let mutationBuffer = NuxieRuntimeNativeBuffer(nativeMutations)
        let batchBuffer = NuxieRuntimeNativeBuffer([
            NuxFlowStateBatch(
                struct_size: UInt32(MemoryLayout<NuxFlowStateBatch>.size),
                has_host_mutation_id: batch.hostMutationID == nil ? 0 : 1,
                host_mutation_id: batch.hostMutationID ?? 0,
                value_arena: arenaBuffer.constPointer,
                new_instances: instanceBuffer.constPointer,
                new_instance_count: UInt64(instanceBuffer.count),
                mutations: mutationBuffer.constPointer,
                mutation_count: UInt64(mutationBuffer.count)
            ),
        ])
        valueNodes = nodeBuffer
        valueArena = arenaBuffer
        newInstances = instanceBuffer
        mutations = mutationBuffer
        stateBatch = batchBuffer
    }

    private func buildPointerBatch(_ events: [FlowRuntimePointerEvent]) throws {
        guard !events.isEmpty else {
            throw FlowRuntimeSessionValueError.invalidValue(
                "Runtime pointer batches must not be empty"
            )
        }
        guard events.count <= FlowRuntimeSessionLimits.pointerEvents else {
            throw FlowRuntimeSessionValueError.limitExceeded(
                "Runtime pointer batch exceeds 32 events"
            )
        }
        let nativeEvents = try events.map { event in
            guard event.pointerID > 0 else {
                throw FlowRuntimeSessionValueError.invalidValue(
                    "Runtime pointer identities must be positive"
                )
            }
            guard event.x.isFinite, event.y.isFinite else {
                throw FlowRuntimeSessionValueError.invalidValue(
                    "Runtime pointer coordinates must be finite"
                )
            }
            let kind: UInt32 = switch event.kind {
            case .down: UInt32(NUX_FLOW_POINTER_EVENT_KIND_DOWN)
            case .move: UInt32(NUX_FLOW_POINTER_EVENT_KIND_MOVE)
            case .up: UInt32(NUX_FLOW_POINTER_EVENT_KIND_UP)
            case .cancel: UInt32(NUX_FLOW_POINTER_EVENT_KIND_CANCEL)
            case .exit: UInt32(NUX_FLOW_POINTER_EVENT_KIND_EXIT)
            }
            return NuxFlowPointerEvent(
                struct_size: UInt32(MemoryLayout<NuxFlowPointerEvent>.size),
                kind: kind,
                pointer_id: event.pointerID,
                x: event.x,
                y: event.y
            )
        }
        let eventBuffer = NuxieRuntimeNativeBuffer(nativeEvents)
        let batchBuffer = NuxieRuntimeNativeBuffer([
            NuxFlowPointerBatch(
                struct_size: UInt32(MemoryLayout<NuxFlowPointerBatch>.size),
                events: eventBuffer.constPointer,
                event_count: UInt64(eventBuffer.count)
            ),
        ])
        pointerEvents = eventBuffer
        pointerBatch = batchBuffer
    }

    private func buildQueryBatch(_ values: [FlowRuntimeQuery]) throws {
        guard !values.isEmpty else {
            throw FlowRuntimeSessionValueError.invalidValue(
                "Runtime query batches must not be empty"
            )
        }
        guard values.count <= FlowRuntimeSessionLimits.queryItems else {
            throw FlowRuntimeSessionValueError.limitExceeded(
                "Runtime query batch exceeds 4,096 items"
            )
        }
        let nativeQueries = values.map { value in
            let kind: UInt32 = switch value {
            case .bootstrap: UInt32(NUX_FLOW_QUERY_KIND_BOOTSTRAP)
            case .values: UInt32(NUX_FLOW_QUERY_KIND_VALUES)
            case .catalog: UInt32(NUX_FLOW_QUERY_KIND_CATALOG)
            case .playerInputs: UInt32(NUX_FLOW_QUERY_KIND_PLAYER_INPUTS)
            }
            return NuxFlowQuery(
                struct_size: UInt32(MemoryLayout<NuxFlowQuery>.size),
                kind: kind
            )
        }
        let valuesBuffer = NuxieRuntimeNativeBuffer(nativeQueries)
        let batchBuffer = NuxieRuntimeNativeBuffer([
            NuxFlowQueryBatch(
                struct_size: UInt32(MemoryLayout<NuxFlowQueryBatch>.size),
                queries: valuesBuffer.constPointer,
                query_count: UInt64(valuesBuffer.count)
            ),
        ])
        queries = valuesBuffer
        queryBatch = batchBuffer
    }

    private static func validateFrameTime(_ time: FlowRuntimeFrameTime) throws {
        guard time.timestamp.isFinite, time.timestamp >= 0 else {
            throw NuxieRuntimeAdapterError.invalidFrameTimestamp(time.timestamp)
        }
        guard time.delta.isFinite,
              time.delta >= 0,
              time.delta <= TimeInterval(Float.greatestFiniteMagnitude) else {
            throw NuxieRuntimeAdapterError.invalidFrameDelta(time.delta)
        }
    }

    private static func checkedSum(
        _ lhs: Int,
        _ rhs: Int,
        label: String
    ) throws -> Int {
        let (sum, overflowed) = lhs.addingReportingOverflow(rhs)
        guard !overflowed else {
            throw FlowRuntimeSessionValueError.limitExceeded(
                "Runtime \(label) overflowed"
            )
        }
        return sum
    }

    private static var nullByteView: NuxByteView {
        NuxByteView(data: nil, len: 0)
    }
}

private final class NuxieRuntimeOwnedByteArena: @unchecked Sendable {
    private var allocations: [(pointer: UnsafeMutablePointer<UInt8>, count: Int)] = []

    func store(_ value: [UInt8]) -> NuxByteView {
        guard !value.isEmpty else { return NuxByteView(data: nil, len: 0) }
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: value.count)
        value.withUnsafeBufferPointer { source in
            pointer.initialize(from: source.baseAddress!, count: source.count)
        }
        allocations.append((pointer, value.count))
        return NuxByteView(data: UnsafePointer(pointer), len: UInt64(value.count))
    }

    deinit {
        for allocation in allocations {
            allocation.pointer.deinitialize(count: allocation.count)
            allocation.pointer.deallocate()
        }
    }
}

private final class NuxieRuntimeNativeBuffer<Element>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Element>?
    let count: Int

    var constPointer: UnsafePointer<Element>? {
        pointer.map { UnsafePointer($0) }
    }

    init(_ elements: [Element]) {
        count = elements.count
        guard !elements.isEmpty else {
            pointer = nil
            return
        }
        let pointer = UnsafeMutablePointer<Element>.allocate(capacity: elements.count)
        for (index, element) in elements.enumerated() {
            pointer.advanced(by: index).initialize(to: element)
        }
        self.pointer = pointer
    }

    deinit {
        pointer?.deinitialize(count: count)
        pointer?.deallocate()
    }
}

#endif
