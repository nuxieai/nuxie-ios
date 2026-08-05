#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import Metal
import QuartzCore
import NuxieRuntime

enum NuxieRuntimeAdapterError: Error, Equatable {
    case callFailed(status: NuxieRuntimeStatus, diagnostic: ExperienceRuntimeDiagnostic)
    case missingHandle(String)
    case missingOperationResult
    case invalidNativeResult(String)
    case invalidOperation(ScreenSessionValueError)
    case invalidFrameTimestamp(TimeInterval)
    case invalidFrameDelta(TimeInterval)
}

extension NuxieRuntimeAdapterError: ScreenSessionFailureDisposition {
    var invalidatesSession: Bool {
        switch self {
        case .missingHandle, .missingOperationResult, .invalidNativeResult:
            true
        case .callFailed(let status, _):
            switch status {
            case .notFound, .invalidArgument:
                false
            case .ok, .nullArgument, .importError, .runtimeError,
                 .runtimeIdentityMismatch, .surfaceError, .unknown:
                true
            }
        case .invalidOperation, .invalidFrameTimestamp, .invalidFrameDelta:
            false
        }
    }
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
        for request: ExperienceRuntimeImportRequest
    ) async throws -> ExperienceRuntimeContextDriverAttachment {
        try request.validateNativeLimits()
        let executor = NuxieRuntimeSerialExecutor()
        let storage = NuxieRuntimeHandleStorage()
        let importRequest = NuxieRuntimeImportRequest(
            packageBytes: request.packageBytes,
            expectedExperienceId: request.expectedExperienceId,
            expectedBuildId: request.expectedBuildId,
            candidateKeys: request.candidateKeys.map {
                NuxieRuntimeImportRequest.AuthorizationKey(
                    keyId: $0.keyId,
                    ed25519PublicKeyBytes: $0.ed25519PublicKeyBytes
                )
            },
            externalAssets: request.externalAssets.map { asset in
                let provided: Bool
                let bytes: Data
                switch asset.content {
                case .bytes(let data):
                    provided = true
                    bytes = data
                case .omittedOptional:
                    provided = false
                    bytes = Data()
                }
                return NuxieRuntimeImportRequest.ExternalAsset(
                    kind: asset.kind == .image ? .image : .font,
                    assetId: asset.riveAssetId,
                    required: asset.required,
                    provided: provided,
                    uniqueName: Data(asset.riveUniqueName.utf8),
                    sourceKey: Data(asset.sourceKey.utf8),
                    expectedSHA256: Data(asset.expectedSHA256.utf8),
                    bytes: bytes
                )
            }
        )

        let importResult = try await executor.call {
            var result: OpaquePointer?
            var context: OpaquePointer?
            let callStatus = withNuxieRuntimeFFIImportRequest(importRequest) { ffiRequest in
                nux_experience_context_create(ffiRequest, &context, &result)
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
                guard let authenticatedKeyId = copiedResult.authenticatedKeyId else {
                    throw NuxieRuntimeAdapterError.invalidNativeResult(
                        "package import omitted its authenticated key ID"
                    )
                }
                storage.pointer = context
                return ExperienceRuntimeImportResult(
                    authenticatedKeyId: authenticatedKeyId,
                    diagnostics: copiedResult.operationResult.diagnostics
                )
            } catch {
                if let context {
                    nux_experience_context_free(context)
                }
                throw error
            }
        }

        return ExperienceRuntimeContextDriverAttachment(
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
        descriptor: ScreenSessionDescriptor
    ) async throws -> ScreenSessionDriverAttachment {
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

        let creationResult = try await executor.call { [storage] in
            let context = try storage.requiredPointer(named: "runtime context")
            var result: OpaquePointer?
            var session: OpaquePointer?

            let callStatus = withOptionalNuxieRuntimeBytes(artboardBytes) { artboardName in
                withOptionalNuxieRuntimeBytes(stateMachineBytes) { stateMachineName in
                    var sessionDescriptor = NuxScreenConfiguredSessionDescriptor(
                        struct_size: UInt32(
                            MemoryLayout<NuxScreenConfiguredSessionDescriptor>.size
                        ),
                        player_kind: descriptor.stateMachineName == nil
                            ? UInt32(NUX_SCREEN_PLAYER_SELECTOR_KIND_DEFAULT)
                            : UInt32(NUX_SCREEN_PLAYER_SELECTOR_KIND_STATE_MACHINE),
                        artboard_name: artboardName,
                        player_name: stateMachineName
                    )
                    return nux_screen_session_create_configured(
                        context,
                        &sessionDescriptor,
                        &session,
                        &result
                    )
                }
            }

            do {
                let copiedResult = try copyNuxieScreenSessionSessionResult(
                    callStatus: callStatus,
                    result: &result,
                    renderRequested: false
                )
                guard let session else {
                    throw NuxieRuntimeAdapterError.missingHandle("render session")
                }
                guard copiedResult.bootstrap != nil else {
                    throw NuxieRuntimeAdapterError.invalidNativeResult(
                        "configured session creation omitted its bootstrap"
                    )
                }
                sessionStorage.pointer = session
                return copiedResult
            } catch {
                if let session {
                    nux_screen_session_free(session)
                }
                throw error
            }
        }

        return ScreenSessionDriverAttachment(
            driver: NuxieRuntimeSessionDriver(
                executor: executor,
                storage: sessionStorage,
                parent: self
            ),
            creationResult: creationResult
        )
    }

    func dispose() {
        executor.enqueue { [storage] in
            guard let context = storage.takePointer() else { return }
            nux_experience_context_free(context)
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
        _ operation: ExperienceRuntimeOperation,
        drawable: ExperienceRuntimeAppleDrawableTarget?
    ) async throws -> ExperienceRuntimeOperationResult {
        let operationStorage: NuxieRuntimeSessionOperationStorage
        do {
            operationStorage = try NuxieRuntimeSessionOperationStorage(
                operation: operation,
                hasDrawable: drawable != nil
            )
        } catch let validation as ScreenSessionValueError {
            // This validation describes Swift-owned request storage and occurs
            // before the serial native lane is entered. Keep it distinct from
            // the same value-error type used to reject malformed Rust results.
            throw NuxieRuntimeAdapterError.invalidOperation(validation)
        }
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
                let callStatus = nux_screen_session_perform(
                    session,
                    nativeOperation,
                    &result
                )
                return try copyNuxieScreenSessionSessionResult(
                    callStatus: callStatus,
                    result: &result,
                    renderRequested: shouldRender
                )
            }
        }
    }

    @MainActor
    func attachAppleSurface(
        to target: ExperienceRuntimeAppleSurfaceTarget
    ) async throws -> ExperienceRuntimeSurfaceDriverAttachment {
        let size = target.size
        let surfaceStorage = NuxieRuntimeSurfaceStorage()

        let (attachmentResult, deviceReference) = try await executor.call { [storage] in
            let session = try storage.requiredPointer(named: "render session")
            var descriptor = nuxieRuntimeSurfaceDescriptor(size: size)
            var result: OpaquePointer?
            var surface: OpaquePointer?
            let callStatus = nux_screen_session_attach_apple_surface(
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

        return ExperienceRuntimeSurfaceDriverAttachment(
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
            nux_screen_session_free(session)
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
    func resize(to size: ExperienceRuntimeSurfaceSize) async throws -> ExperienceRuntimeOperationResult {
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
    func detach() async throws -> ExperienceRuntimeOperationResult {
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
        to target: ExperienceRuntimeAppleSurfaceTarget
    ) async throws -> ExperienceRuntimeSurfaceDriverReattachment {
        let size = target.size

        let (result, deviceReference) = try await executor.call { [storage] in
            let surface = try storage.requiredPointer(named: "Apple surface")
            var descriptor = nuxieRuntimeSurfaceDescriptor(size: size)
            var result: OpaquePointer?
            let callStatus = nux_apple_surface_reattach(surface, &descriptor, &result)
            let copiedResult = try copyNuxieRuntimeResult(
                callStatus: callStatus,
                result: &result,
                renderRequested: false
            )
            // Reattach may rebuild the renderer on a different Metal device.
            // Copy it only after native recovery succeeds so the layer is
            // configured with the exact device that will submit future frames.
            let deviceReference = try copyNuxieRuntimeMetalDevice(from: surface)
            return (copiedResult, deviceReference)
        }
        return ExperienceRuntimeSurfaceDriverReattachment(
            result: result,
            configurator: NuxieRuntimeAppleSurfaceConfigurator(
                deviceReference: deviceReference
            )
        )
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

extension NuxieRuntimeAdapter: ExperienceRuntimeAdapter {}
extension NuxieRuntimeContextDriver: ExperienceRuntimeContextDriver {}
extension NuxieRuntimeSessionDriver: ScreenSessionDriver {}
extension NuxieRuntimeSurfaceDriver: ExperienceRuntimeSurfaceDriver {}

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
    Unmanaged<ExperienceRuntimeDrawableCompletion>
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
    ExperienceRuntimeAppleSurfaceConfigurator {
    private let deviceReference: NuxieRuntimeMetalDeviceReference

    init(deviceReference: NuxieRuntimeMetalDeviceReference) {
        self.deviceReference = deviceReference
    }

    func configure(_ target: ExperienceRuntimeAppleSurfaceTarget) {
        withoutLayerActions {
            let layer = target.layer
            layer.device = deviceReference.device
            layer.pixelFormat = .bgra8Unorm
            layer.framebufferOnly = true
            layer.isOpaque = false
            layer.maximumDrawableCount = ExperienceRuntimeAppleSurfacePolicy.maximumDrawableCount
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

    func unconfigure(_ target: ExperienceRuntimeAppleSurfaceTarget) {
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

private func nuxieRuntimeSurfaceDescriptor(
    size: ExperienceRuntimeSurfaceSize
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
        throw ScreenSessionValueError.invalidValue(
            "Runtime \(label) must not be empty"
        )
    }
    guard value.utf8.count <= ScreenSessionLimits.identifierBytes else {
        throw ScreenSessionValueError.limitExceeded(
            "Runtime \(label) exceeds 4 KiB"
        )
    }
}

/// Owns every byte and C-array address selected by one native operation.
///
/// Rust copies the complete request during the synchronous `perform` call.
/// Allocating nested arrays here avoids retaining pointers obtained from an
/// escaped `withUnsafeBytes` closure and makes those lifetimes explicit.
final class NuxieRuntimeSessionOperationStorage: @unchecked Sendable {
    typealias CompletionCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

    let renderRequested: Bool

    private enum Payload {
        case stateBatch
        case textRunBatch
        case pointerBatch
        case advance(time: ExperienceRuntimeFrameTime, render: Bool)
        case queryBatch
    }

    private let payload: Payload
    private let bytes = NuxieRuntimeOwnedByteArena()
    private var valueNodes: NuxieRuntimeNativeBuffer<NuxScreenValueNode>?
    private var valueArena: NuxieRuntimeNativeBuffer<NuxScreenValueArena>?
    private var newInstances: NuxieRuntimeNativeBuffer<NuxScreenNewInstance>?
    private var mutations: NuxieRuntimeNativeBuffer<NuxScreenStateMutation>?
    private var stateBatch: NuxieRuntimeNativeBuffer<NuxScreenStateBatch>?
    private var textRunMutations: NuxieRuntimeNativeBuffer<NuxScreenTextRunMutation>?
    private var textRunBatch: NuxieRuntimeNativeBuffer<NuxScreenTextRunBatch>?
    private var pointerEvents: NuxieRuntimeNativeBuffer<NuxScreenPointerEvent>?
    private var pointerBatch: NuxieRuntimeNativeBuffer<NuxScreenPointerBatch>?
    private var queries: NuxieRuntimeNativeBuffer<NuxScreenQuery>?
    private var queryBatch: NuxieRuntimeNativeBuffer<NuxScreenQueryBatch>?

    init(operation: ExperienceRuntimeOperation, hasDrawable: Bool) throws {
        switch operation {
        case .stateBatch(let batch):
            guard !hasDrawable else {
                throw ScreenSessionValueError.invalidValue(
                    "A drawable is valid only for advance-and-render"
                )
            }
            renderRequested = false
            payload = .stateBatch
            try buildStateBatch(batch)

        case .textRunBatch(let batch):
            guard !hasDrawable else {
                throw ScreenSessionValueError.invalidValue(
                    "A drawable is valid only for advance-and-render"
                )
            }
            renderRequested = false
            payload = .textRunBatch
            try buildTextRunBatch(batch)

        case .pointerBatch(let events):
            guard !hasDrawable else {
                throw ScreenSessionValueError.invalidValue(
                    "A drawable is valid only for advance-and-render"
                )
            }
            renderRequested = false
            payload = .pointerBatch
            try buildPointerBatch(events)

        case .advance(let time):
            guard !hasDrawable else {
                throw ScreenSessionValueError.invalidValue(
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
                throw ScreenSessionValueError.invalidValue(
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
        _ body: (UnsafePointer<NuxScreenSessionOperation>) throws -> T
    ) rethrows -> T {
        switch payload {
        case .stateBatch:
            var operation = nativeOperation(
                kind: UInt32(NUX_SCREEN_SESSION_OPERATION_KIND_STATE_BATCH),
                stateBatch: stateBatch?.pointer
            )
            return try withUnsafePointer(to: &operation, body)

        case .textRunBatch:
            var operation = nativeOperation(
                kind: UInt32(NUX_SCREEN_SESSION_OPERATION_KIND_TEXT_RUN_BATCH),
                textRunBatch: textRunBatch?.pointer
            )
            return try withUnsafePointer(to: &operation, body)

        case .pointerBatch:
            var operation = nativeOperation(
                kind: UInt32(NUX_SCREEN_SESSION_OPERATION_KIND_POINTER_BATCH),
                pointerBatch: pointerBatch?.pointer
            )
            return try withUnsafePointer(to: &operation, body)

        case .advance(let time, let render):
            var advance = NuxScreenAdvanceOperation(
                struct_size: UInt32(MemoryLayout<NuxScreenAdvanceOperation>.size),
                timestamp_seconds: time.timestamp,
                delta_seconds: Float(time.delta),
                render: render ? 1 : 0,
                apple_drawable: appleDrawable,
                completion_context: completionContext,
                completion_callback: completionCallback
            )
            return try withUnsafePointer(to: &advance) { advancePointer in
                var operation = nativeOperation(
                    kind: UInt32(NUX_SCREEN_SESSION_OPERATION_KIND_ADVANCE),
                    advance: advancePointer
                )
                return try withUnsafePointer(to: &operation, body)
            }

        case .queryBatch:
            var operation = nativeOperation(
                kind: UInt32(NUX_SCREEN_SESSION_OPERATION_KIND_QUERY),
                queryBatch: queryBatch?.pointer
            )
            return try withUnsafePointer(to: &operation, body)
        }
    }

    private func nativeOperation(
        kind: UInt32,
        stateBatch: UnsafeMutablePointer<NuxScreenStateBatch>? = nil,
        pointerBatch: UnsafeMutablePointer<NuxScreenPointerBatch>? = nil,
        advance: UnsafePointer<NuxScreenAdvanceOperation>? = nil,
        queryBatch: UnsafeMutablePointer<NuxScreenQueryBatch>? = nil,
        textRunBatch: UnsafeMutablePointer<NuxScreenTextRunBatch>? = nil
    ) -> NuxScreenSessionOperation {
        NuxScreenSessionOperation(
            struct_size: UInt32(MemoryLayout<NuxScreenSessionOperation>.size),
            kind: kind,
            state_batch: stateBatch.map { UnsafePointer($0) },
            pointer_batch: pointerBatch.map { UnsafePointer($0) },
            advance: advance,
            query_batch: queryBatch.map { UnsafePointer($0) },
            text_run_batch: textRunBatch.map { UnsafePointer($0) }
        )
    }

    private func buildTextRunBatch(_ batch: ExperienceRuntimeTextRunBatch) throws {
        guard batch.mutations.count <= ScreenSessionLimits.batchItems else {
            throw ScreenSessionValueError.limitExceeded(
                "Runtime text-run batch exceeds 4,096 mutations"
            )
        }
        var payloadBytes = 0
        for mutation in batch.mutations {
            let nameBytes = mutation.name.utf8.count
            guard nameBytes > 0 else {
                throw ScreenSessionValueError.invalidValue(
                    "Runtime text-run name must not be empty"
                )
            }
            guard nameBytes <= ScreenSessionLimits.identifierBytes else {
                throw ScreenSessionValueError.limitExceeded(
                    "Runtime text-run name exceeds 4 KiB"
                )
            }
            let textBytes = mutation.text.utf8.count
            guard textBytes <= ScreenSessionLimits.stringBytes else {
                throw ScreenSessionValueError.limitExceeded(
                    "Runtime text-run text exceeds 1 MiB"
                )
            }
            payloadBytes = try Self.checkedSum(
                payloadBytes,
                nameBytes,
                label: "text-run batch payload"
            )
            payloadBytes = try Self.checkedSum(
                payloadBytes,
                textBytes,
                label: "text-run batch payload"
            )
            guard payloadBytes <= ScreenSessionLimits.encodedPayloadBytes else {
                throw ScreenSessionValueError.limitExceeded(
                    "Runtime text-run batch payload exceeds 4 MiB"
                )
            }
        }

        let nativeMutations = batch.mutations.map { mutation in
            NuxScreenTextRunMutation(
                struct_size: UInt32(MemoryLayout<NuxScreenTextRunMutation>.size),
                name: bytes.store(Array(mutation.name.utf8)),
                text: bytes.store(Array(mutation.text.utf8))
            )
        }
        let mutationBuffer = NuxieRuntimeNativeBuffer(nativeMutations)
        let batchBuffer = NuxieRuntimeNativeBuffer([
            NuxScreenTextRunBatch(
                struct_size: UInt32(MemoryLayout<NuxScreenTextRunBatch>.size),
                mutations: mutationBuffer.constPointer,
                mutation_count: UInt64(mutationBuffer.count)
            ),
        ])
        textRunMutations = mutationBuffer
        textRunBatch = batchBuffer
    }

    private func buildStateBatch(_ batch: ExperienceRuntimeStateBatch) throws {
        let itemCount = try Self.checkedSum(
            batch.newInstances.count,
            batch.mutations.count,
            label: "state batch item count"
        )
        guard itemCount > 0 else {
            throw ScreenSessionValueError.invalidValue(
                "Runtime state batches must not be empty"
            )
        }
        guard itemCount <= ScreenSessionLimits.batchItems else {
            throw ScreenSessionValueError.limitExceeded(
                "Runtime state batch exceeds 4,096 combined items"
            )
        }

        var payloadBytes = 0
        func charge(_ count: Int, label: String) throws {
            payloadBytes = try Self.checkedSum(payloadBytes, count, label: label)
            guard payloadBytes <= ScreenSessionLimits.encodedPayloadBytes else {
                throw ScreenSessionValueError.limitExceeded(
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
                throw ScreenSessionValueError.invalidValue(
                    "Runtime \(label) must not be empty"
                )
            }
            guard encoded.count <= limit else {
                throw ScreenSessionValueError.limitExceeded(
                    "Runtime \(label) exceeds \(limit) UTF-8 bytes"
                )
            }
            if path, value.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty }) {
                throw ScreenSessionValueError.invalidValue(
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
                limit: ScreenSessionLimits.identifierBytes,
                label: label
            )
        }

        let declaredLocalIDs = Set(batch.newInstances.map(\.localID))
        guard declaredLocalIDs.count == batch.newInstances.count else {
            throw ScreenSessionValueError.invalidValue(
                "Runtime state batch contains duplicate new-instance local IDs"
            )
        }

        var nativeNewInstances: [NuxScreenNewInstance] = []
        nativeNewInstances.reserveCapacity(batch.newInstances.count)
        for instance in batch.newInstances {
            nativeNewInstances.append(
                NuxScreenNewInstance(
                    struct_size: UInt32(MemoryLayout<NuxScreenNewInstance>.size),
                    local_id: instance.localID,
                    schema_name: try requiredView(
                        instance.schemaName,
                        limit: ScreenSessionLimits.identifierBytes,
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

        var nativeNodes: [NuxScreenValueNode] = []
        nativeNodes.reserveCapacity(batch.mutations.count)
        func appendScalar(_ value: ExperienceRuntimeScalarValue) throws -> UInt32 {
            guard nativeNodes.count < ScreenSessionLimits.valueNodes else {
                throw ScreenSessionValueError.limitExceeded(
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
                kind = UInt32(NUX_SCREEN_VALUE_KIND_NULL)
            case .string(let value):
                let encoded = Array(value.utf8)
                guard encoded.count <= ScreenSessionLimits.stringBytes else {
                    throw ScreenSessionValueError.limitExceeded(
                        "Runtime scalar string exceeds 1 MiB"
                    )
                }
                try charge(encoded.count, label: "scalar string")
                string = bytes.store(encoded)
                kind = UInt32(NUX_SCREEN_VALUE_KIND_STRING)
            case .number(let value):
                guard value.isFinite,
                      abs(value) <= Double(Float.greatestFiniteMagnitude) else {
                    throw ScreenSessionValueError.invalidValue(
                        "Runtime scalar number must be finite and representable as Float"
                    )
                }
                number = value
                kind = UInt32(NUX_SCREEN_VALUE_KIND_NUMBER)
            case .bool(let value):
                bool = value ? 1 : 0
                kind = UInt32(NUX_SCREEN_VALUE_KIND_BOOL)
            case .enumeration(let value):
                identity = value
                kind = UInt32(NUX_SCREEN_VALUE_KIND_ENUM)
            case .listIndex(let value):
                identity = value
                kind = UInt32(NUX_SCREEN_VALUE_KIND_LIST_INDEX)
            case .color(let value):
                color = value
                kind = UInt32(NUX_SCREEN_VALUE_KIND_COLOR)
            case .image(let value):
                identity = value
                kind = UInt32(NUX_SCREEN_VALUE_KIND_IMAGE)
            case .trigger:
                throw ScreenSessionValueError.invalidValue(
                    "Trigger counts cannot be sent as scalar state values"
                )
            }
            let index = UInt32(nativeNodes.count)
            nativeNodes.append(
                NuxScreenValueNode(
                    struct_size: UInt32(MemoryLayout<NuxScreenValueNode>.size),
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
            _ reference: ExperienceRuntimeInstanceReference
        ) throws -> NuxScreenInstanceReference {
            switch reference {
            case .existing(let id):
                return NuxScreenInstanceReference(
                    kind: UInt32(NUX_SCREEN_INSTANCE_REFERENCE_KIND_EXISTING),
                    local_id: 0,
                    instance_id: id.rawValue
                )
            case .new(let localID):
                guard declaredLocalIDs.contains(localID) else {
                    throw ScreenSessionValueError.invalidValue(
                        "Runtime mutation references undeclared new-instance local ID \(localID)"
                    )
                }
                return NuxScreenInstanceReference(
                    kind: UInt32(NUX_SCREEN_INSTANCE_REFERENCE_KIND_NEW),
                    local_id: localID,
                    instance_id: 0
                )
            }
        }

        let zeroReference = NuxScreenInstanceReference(kind: 0, local_id: 0, instance_id: 0)
        var nativeMutations: [NuxScreenStateMutation] = []
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
                kind = UInt32(NUX_SCREEN_STATE_MUTATION_KIND_SET_INPUT_BOOL)
                inputName = try requiredView(
                    name,
                    limit: ScreenSessionLimits.identifierBytes,
                    label: "player-input name",
                    path: true
                )
                valueRootIndex = try appendScalar(.bool(value))
            case .setInputNumber(let name, let value):
                kind = UInt32(NUX_SCREEN_STATE_MUTATION_KIND_SET_INPUT_NUMBER)
                inputName = try requiredView(
                    name,
                    limit: ScreenSessionLimits.identifierBytes,
                    label: "player-input name",
                    path: true
                )
                valueRootIndex = try appendScalar(.number(value))
            case .fireInputTrigger(let name):
                kind = UInt32(NUX_SCREEN_STATE_MUTATION_KIND_FIRE_INPUT_TRIGGER)
                inputName = try requiredView(
                    name,
                    limit: ScreenSessionLimits.identifierBytes,
                    label: "player-input name",
                    path: true
                )
            case .setValue(let reference, let propertyPath, let value):
                kind = UInt32(NUX_SCREEN_STATE_MUTATION_KIND_SET)
                instance = try nativeReference(reference)
                path = try requiredView(
                    propertyPath,
                    limit: ScreenSessionLimits.pathBytes,
                    label: "property path",
                    path: true
                )
                valueRootIndex = try appendScalar(value)
            case .setViewModel(let reference, let propertyPath, let replacement):
                kind = UInt32(NUX_SCREEN_STATE_MUTATION_KIND_SET_VIEW_MODEL)
                instance = try nativeReference(reference)
                item = try nativeReference(replacement)
                path = try requiredView(
                    propertyPath,
                    limit: ScreenSessionLimits.pathBytes,
                    label: "view-model property path",
                    path: true
                )
            case .fireTrigger(let reference, let propertyPath):
                kind = UInt32(NUX_SCREEN_STATE_MUTATION_KIND_TRIGGER)
                instance = try nativeReference(reference)
                path = try requiredView(
                    propertyPath,
                    limit: ScreenSessionLimits.pathBytes,
                    label: "property path",
                    path: true
                )
            case .listInsert(let reference, let propertyPath, let position, let row):
                kind = UInt32(NUX_SCREEN_STATE_MUTATION_KIND_LIST_INSERT)
                instance = try nativeReference(reference)
                item = try nativeReference(row)
                path = try requiredView(
                    propertyPath,
                    limit: ScreenSessionLimits.pathBytes,
                    label: "list path",
                    path: true
                )
                index = position
            case .listRemove(let reference, let propertyPath, let position):
                kind = UInt32(NUX_SCREEN_STATE_MUTATION_KIND_LIST_REMOVE)
                instance = try nativeReference(reference)
                path = try requiredView(
                    propertyPath,
                    limit: ScreenSessionLimits.pathBytes,
                    label: "list path",
                    path: true
                )
                index = position
            case .listSwap(let reference, let propertyPath, let first, let second):
                kind = UInt32(NUX_SCREEN_STATE_MUTATION_KIND_LIST_SWAP)
                instance = try nativeReference(reference)
                path = try requiredView(
                    propertyPath,
                    limit: ScreenSessionLimits.pathBytes,
                    label: "list path",
                    path: true
                )
                index = first
                otherIndex = second
            case .listMove(let reference, let propertyPath, let from, let to):
                kind = UInt32(NUX_SCREEN_STATE_MUTATION_KIND_LIST_MOVE)
                instance = try nativeReference(reference)
                path = try requiredView(
                    propertyPath,
                    limit: ScreenSessionLimits.pathBytes,
                    label: "list path",
                    path: true
                )
                index = from
                otherIndex = to
            case .listSet(let reference, let propertyPath, let position, let row):
                kind = UInt32(NUX_SCREEN_STATE_MUTATION_KIND_LIST_SET)
                instance = try nativeReference(reference)
                item = try nativeReference(row)
                path = try requiredView(
                    propertyPath,
                    limit: ScreenSessionLimits.pathBytes,
                    label: "list path",
                    path: true
                )
                index = position
            case .listClear(let reference, let propertyPath):
                kind = UInt32(NUX_SCREEN_STATE_MUTATION_KIND_LIST_CLEAR)
                instance = try nativeReference(reference)
                path = try requiredView(
                    propertyPath,
                    limit: ScreenSessionLimits.pathBytes,
                    label: "list path",
                    path: true
                )
            }

            nativeMutations.append(
                NuxScreenStateMutation(
                    struct_size: UInt32(MemoryLayout<NuxScreenStateMutation>.size),
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
            NuxScreenValueArena(
                struct_size: UInt32(MemoryLayout<NuxScreenValueArena>.size),
                nodes: nodeBuffer.constPointer,
                node_count: UInt64(nodeBuffer.count),
                edges: nil,
                edge_count: 0
            ),
        ])
        let instanceBuffer = NuxieRuntimeNativeBuffer(nativeNewInstances)
        let mutationBuffer = NuxieRuntimeNativeBuffer(nativeMutations)
        let batchBuffer = NuxieRuntimeNativeBuffer([
            NuxScreenStateBatch(
                struct_size: UInt32(MemoryLayout<NuxScreenStateBatch>.size),
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

    private func buildPointerBatch(_ events: [ExperienceRuntimePointerEvent]) throws {
        guard !events.isEmpty else {
            throw ScreenSessionValueError.invalidValue(
                "Runtime pointer batches must not be empty"
            )
        }
        guard events.count <= ScreenSessionLimits.pointerEvents else {
            throw ScreenSessionValueError.limitExceeded(
                "Runtime pointer batch exceeds 32 events"
            )
        }
        let nativeEvents = try events.map { event in
            guard event.pointerID > 0 else {
                throw ScreenSessionValueError.invalidValue(
                    "Runtime pointer identities must be positive"
                )
            }
            guard event.x.isFinite, event.y.isFinite else {
                throw ScreenSessionValueError.invalidValue(
                    "Runtime pointer coordinates must be finite"
                )
            }
            guard event.timestampSeconds.isFinite, event.timestampSeconds >= 0 else {
                throw ScreenSessionValueError.invalidValue(
                    "Runtime pointer timestamps must be finite and nonnegative"
                )
            }
            let timestampSeconds = Float(event.timestampSeconds)
            guard timestampSeconds.isFinite else {
                throw ScreenSessionValueError.invalidValue(
                    "Runtime pointer timestamp exceeds the f32 ABI"
                )
            }
            let kind: UInt32 = switch event.kind {
            case .down: UInt32(NUX_SCREEN_POINTER_EVENT_KIND_DOWN)
            case .move: UInt32(NUX_SCREEN_POINTER_EVENT_KIND_MOVE)
            case .up: UInt32(NUX_SCREEN_POINTER_EVENT_KIND_UP)
            case .cancel: UInt32(NUX_SCREEN_POINTER_EVENT_KIND_CANCEL)
            case .exit: UInt32(NUX_SCREEN_POINTER_EVENT_KIND_EXIT)
            }
            return NuxScreenPointerEvent(
                struct_size: UInt32(MemoryLayout<NuxScreenPointerEvent>.size),
                kind: kind,
                pointer_id: event.pointerID,
                x: event.x,
                y: event.y,
                timestamp_seconds: timestampSeconds
            )
        }
        let eventBuffer = NuxieRuntimeNativeBuffer(nativeEvents)
        let batchBuffer = NuxieRuntimeNativeBuffer([
            NuxScreenPointerBatch(
                struct_size: UInt32(MemoryLayout<NuxScreenPointerBatch>.size),
                events: eventBuffer.constPointer,
                event_count: UInt64(eventBuffer.count)
            ),
        ])
        pointerEvents = eventBuffer
        pointerBatch = batchBuffer
    }

    private func buildQueryBatch(_ values: [ExperienceRuntimeQuery]) throws {
        guard !values.isEmpty else {
            throw ScreenSessionValueError.invalidValue(
                "Runtime query batches must not be empty"
            )
        }
        guard values.count <= ScreenSessionLimits.queryItems else {
            throw ScreenSessionValueError.limitExceeded(
                "Runtime query batch exceeds 4,096 items"
            )
        }
        let nativeQueries = values.map { value in
            let kind: UInt32 = switch value {
            case .bootstrap: UInt32(NUX_SCREEN_QUERY_KIND_BOOTSTRAP)
            case .values: UInt32(NUX_SCREEN_QUERY_KIND_VALUES)
            case .catalog: UInt32(NUX_SCREEN_QUERY_KIND_CATALOG)
            case .playerInputs: UInt32(NUX_SCREEN_QUERY_KIND_PLAYER_INPUTS)
            }
            return NuxScreenQuery(
                struct_size: UInt32(MemoryLayout<NuxScreenQuery>.size),
                kind: kind
            )
        }
        let valuesBuffer = NuxieRuntimeNativeBuffer(nativeQueries)
        let batchBuffer = NuxieRuntimeNativeBuffer([
            NuxScreenQueryBatch(
                struct_size: UInt32(MemoryLayout<NuxScreenQueryBatch>.size),
                queries: valuesBuffer.constPointer,
                query_count: UInt64(valuesBuffer.count)
            ),
        ])
        queries = valuesBuffer
        queryBatch = batchBuffer
    }

    private static func validateFrameTime(_ time: ExperienceRuntimeFrameTime) throws {
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
            throw ScreenSessionValueError.limitExceeded(
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
