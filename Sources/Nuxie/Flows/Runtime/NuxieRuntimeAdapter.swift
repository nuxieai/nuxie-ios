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
    ) async throws -> any FlowRenderSessionDriver {
        let sessionStorage = NuxieRuntimeHandleStorage()
        let artboardBytes = descriptor.artboardName.map { Array($0.utf8) }
        let stateMachineBytes = descriptor.stateMachineName.map { Array($0.utf8) }

        try await executor.call { [storage] in
            let context = try storage.requiredPointer(named: "runtime context")
            var result: OpaquePointer?
            var session: OpaquePointer?

            let callStatus = withOptionalNuxieRuntimeBytes(artboardBytes) { artboardName in
                withOptionalNuxieRuntimeBytes(stateMachineBytes) { stateMachineName in
                    var sessionDescriptor = NuxFlowSessionDescriptor(
                        struct_size: UInt32(MemoryLayout<NuxFlowSessionDescriptor>.size),
                        artboard_name: artboardName,
                        state_machine_name: stateMachineName
                    )
                    return nux_flow_render_session_create(
                        context,
                        &sessionDescriptor,
                        &session,
                        &result
                    )
                }
            }

            do {
                _ = try copyNuxieRuntimeResult(
                    callStatus: callStatus,
                    result: &result,
                    renderRequested: false
                )
                guard let session else {
                    throw NuxieRuntimeAdapterError.missingHandle("render session")
                }
                sessionStorage.pointer = session
            } catch {
                if let session {
                    nux_flow_render_session_free(session)
                }
                throw error
            }
        }

        return NuxieRuntimeSessionDriver(
            executor: executor,
            storage: sessionStorage,
            parent: self
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
        let frameTime: FlowRuntimeFrameTime
        let shouldRender: Bool
        switch operation {
        case .advance(let time):
            frameTime = time
            shouldRender = false
        case .advanceAndRender(let time):
            frameTime = time
            shouldRender = true
        }

        guard frameTime.delta.isFinite,
              frameTime.delta >= 0,
              frameTime.delta <= TimeInterval(Float.greatestFiniteMagnitude) else {
            throw NuxieRuntimeAdapterError.invalidFrameDelta(frameTime.delta)
        }
        let elapsedSeconds = Float(frameTime.delta)
        let drawableReference = drawable.map { NuxieRuntimeDrawableReference($0.drawable) }
        let drawableCompletion = drawable?.completion

        return try await executor.call { [storage] in
            let session = try storage.requiredPointer(named: "render session")
            let completionContext = drawableCompletion.map {
                Unmanaged.passRetained($0).toOpaque()
            }
            var operation = NuxFrameOperation(
                struct_size: UInt32(MemoryLayout<NuxFrameOperation>.size),
                elapsed_seconds: elapsedSeconds,
                render: shouldRender,
                apple_drawable: drawableReference?.opaquePointer,
                completion_context: completionContext,
                completion_callback: completionContext == nil
                    ? nil
                    : nuxieRuntimeFrameDidComplete
            )
            var result: OpaquePointer?
            let callStatus = nux_flow_render_session_advance(session, &operation, &result)
            return try copyNuxieRuntimeResult(
                callStatus: callStatus,
                result: &result,
                renderRequested: shouldRender
            )
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

    static func validate() throws {
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

#endif
