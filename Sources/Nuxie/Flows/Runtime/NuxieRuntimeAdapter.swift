#if canImport(NuxieRuntime)
import Foundation
import Metal
import QuartzCore
import NuxieRuntime

/// Swift names for the fixed-width status values in the C ABI.
enum NuxieRuntimeStatus: Equatable, Sendable {
    case ok
    case nullArgument
    case importError
    case notFound
    case runtimeError
    case invalidArgument
    case abiMismatch
    case surfaceError
    case unknown(UInt32)
}

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

/// The sole importer of `NuxieRuntime` in the SDK.
///
/// Every opaque handle and every C call is confined to one serial executor.
/// Native operations may wait for Rust's pinned worker, so none execute on the
/// main actor. The `@unchecked Sendable` boxes below are deliberately narrow:
/// their mutable fields are touched only inside `NuxieRuntimeSerialExecutor`.
final class NuxieRuntimeAdapter {
    @MainActor
    func makeContext(
        for request: FlowRuntimeImportRequest
    ) async throws -> FlowRuntimeContextDriverAttachment {
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

private struct NuxieRuntimeImportStorage: Sendable {
    struct AuthorizationKey: Sendable {
        let keyId: [UInt8]
        let publicKey: Data
    }

    struct ExternalAsset: Sendable {
        let kind: FlowRuntimeExternalAssetKind
        let assetId: UInt32
        let required: Bool
        let provided: Bool
        let uniqueName: [UInt8]
        let sourceKey: [UInt8]
        let expectedSHA256: [UInt8]
        let bytes: Data?
    }

    let artifactBytes: Data
    let expectedFlowId: [UInt8]?
    let expectedBuildId: [UInt8]?
    let manifestBytes: Data?
    let signatureEnvelopeBytes: Data?
    let authorizationKey: AuthorizationKey?
    let externalAssets: [ExternalAsset]

    init(_ request: FlowRuntimeImportRequest) {
        artifactBytes = request.artifactBytes
        expectedFlowId = request.expectedIdentity.map { Array($0.flowId.utf8) }
        expectedBuildId = request.expectedIdentity.map { Array($0.buildId.utf8) }
        manifestBytes = request.authorizationEvidence?.signedContentBytes
        signatureEnvelopeBytes = request.authorizationEvidence?.signatureEnvelopeBytes
        authorizationKey = request.authorizationEvidence?
            .selectedKey
            .map {
                AuthorizationKey(
                    keyId: Array($0.keyId.utf8),
                    publicKey: $0.ed25519PublicKeyBytes
                )
            }
        externalAssets = request.externalAssets.map { asset in
            let provided: Bool
            let bytes: Data?
            switch asset.content {
            case .bytes(let data):
                provided = true
                bytes = data
            case .omittedOptional:
                provided = false
                bytes = nil
            }
            return ExternalAsset(
                kind: asset.kind,
                assetId: asset.riveAssetId,
                required: asset.required,
                provided: provided,
                uniqueName: Array(asset.riveUniqueName.utf8),
                sourceKey: Array(asset.sourceKey.utf8),
                expectedSHA256: Array(asset.expectedSHA256.utf8),
                bytes: bytes
            )
        }
    }
}

private func withNuxieRuntimeImportRequest<T>(
    _ storage: NuxieRuntimeImportStorage,
    _ body: (UnsafePointer<NuxFlowImportRequest>) throws -> T
) rethrows -> T {
    let pinnedStorage = NuxieRuntimePinnedImportStorage(storage)
    return try pinnedStorage.withRequest(body)
}

/// Retains immutable Foundation byte storage while C borrows flat views into it.
///
/// `NSData.bytes` remains valid for the lifetime of the immutable object, so
/// importing 1,024 assets no longer requires 4,096 recursively nested Swift
/// `withUnsafeBytes` scopes. Bridging `Data` preserves its existing immutable
/// backing storage when Foundation can do so without a copy.
private final class NuxieRuntimePinnedBytes {
    private static let emptySentinel = Data([0]) as NSData

    private let storage: NSData
    let view: NuxByteView

    init(_ data: Data) {
        let storage = data as NSData
        self.storage = storage
        let pointer = data.isEmpty
            ? Self.emptySentinel.bytes.assumingMemoryBound(to: UInt8.self)
            : storage.bytes.assumingMemoryBound(to: UInt8.self)
        view = NuxByteView(data: pointer, len: UInt64(data.count))
    }

    convenience init(_ bytes: [UInt8]) {
        self.init(Data(bytes))
    }
}

private final class NuxieRuntimePinnedImportStorage {
    private struct AuthorizationKey {
        let keyId: NuxieRuntimePinnedBytes
        let publicKey: NuxieRuntimePinnedBytes

        var native: NuxFlowAuthorizationKey {
            NuxFlowAuthorizationKey(
                struct_size: UInt32(MemoryLayout<NuxFlowAuthorizationKey>.size),
                key_id: keyId.view,
                ed25519_public_key: publicKey.view
            )
        }
    }

    private struct ExternalAsset {
        let kind: FlowRuntimeExternalAssetKind
        let assetId: UInt32
        let required: Bool
        let provided: Bool
        let uniqueName: NuxieRuntimePinnedBytes
        let sourceKey: NuxieRuntimePinnedBytes
        let expectedSHA256: NuxieRuntimePinnedBytes
        let bytes: NuxieRuntimePinnedBytes?

        var native: NuxFlowExternalAsset {
            NuxFlowExternalAsset(
                struct_size: UInt32(MemoryLayout<NuxFlowExternalAsset>.size),
                kind: kind == .image
                    ? UInt32(NUX_FLOW_EXTERNAL_ASSET_KIND_IMAGE)
                    : UInt32(NUX_FLOW_EXTERNAL_ASSET_KIND_FONT),
                asset_id: assetId,
                required: required,
                provided: provided,
                unique_name: uniqueName.view,
                source_key: sourceKey.view,
                expected_sha256: expectedSHA256.view,
                bytes: bytes?.view ?? NuxByteView(data: nil, len: 0)
            )
        }
    }

    private let artifactBytes: NuxieRuntimePinnedBytes
    private let expectedFlowId: NuxieRuntimePinnedBytes?
    private let expectedBuildId: NuxieRuntimePinnedBytes?
    private let manifestBytes: NuxieRuntimePinnedBytes?
    private let signatureEnvelopeBytes: NuxieRuntimePinnedBytes?
    private let authorizationKey: AuthorizationKey?
    private let externalAssets: [ExternalAsset]

    init(_ storage: NuxieRuntimeImportStorage) {
        artifactBytes = NuxieRuntimePinnedBytes(storage.artifactBytes)
        expectedFlowId = storage.expectedFlowId.map(NuxieRuntimePinnedBytes.init)
        expectedBuildId = storage.expectedBuildId.map(NuxieRuntimePinnedBytes.init)
        manifestBytes = storage.manifestBytes.map(NuxieRuntimePinnedBytes.init)
        signatureEnvelopeBytes = storage.signatureEnvelopeBytes.map(
            NuxieRuntimePinnedBytes.init
        )
        authorizationKey = storage.authorizationKey.map {
            AuthorizationKey(
                keyId: NuxieRuntimePinnedBytes($0.keyId),
                publicKey: NuxieRuntimePinnedBytes($0.publicKey)
            )
        }
        externalAssets = storage.externalAssets.map {
            ExternalAsset(
                kind: $0.kind,
                assetId: $0.assetId,
                required: $0.required,
                provided: $0.provided,
                uniqueName: NuxieRuntimePinnedBytes($0.uniqueName),
                sourceKey: NuxieRuntimePinnedBytes($0.sourceKey),
                expectedSHA256: NuxieRuntimePinnedBytes($0.expectedSHA256),
                bytes: $0.bytes.map(NuxieRuntimePinnedBytes.init)
            )
        }
    }

    func withRequest<T>(
        _ body: (UnsafePointer<NuxFlowImportRequest>) throws -> T
    ) rethrows -> T {
        let nativeAssets = externalAssets.map(\.native)
        return try nativeAssets.withUnsafeBufferPointer { assetBuffer in
            if var nativeKey = authorizationKey?.native {
                return try withUnsafePointer(to: &nativeKey) { keyPointer in
                    try call(
                        selectedKey: keyPointer,
                        externalAssets: assetBuffer.baseAddress,
                        externalAssetCount: UInt64(assetBuffer.count),
                        body
                    )
                }
            }
            return try call(
                selectedKey: nil,
                externalAssets: assetBuffer.baseAddress,
                externalAssetCount: UInt64(assetBuffer.count),
                body
            )
        }
    }

    private func call<T>(
        selectedKey: UnsafePointer<NuxFlowAuthorizationKey>?,
        externalAssets: UnsafePointer<NuxFlowExternalAsset>?,
        externalAssetCount: UInt64,
        _ body: (UnsafePointer<NuxFlowImportRequest>) throws -> T
    ) rethrows -> T {
        var request = NuxFlowImportRequest(
            struct_size: UInt32(MemoryLayout<NuxFlowImportRequest>.size),
            artifact_bytes: artifactBytes.view,
            expected_flow_id: expectedFlowId?.view ?? NuxByteView(data: nil, len: 0),
            expected_build_id: expectedBuildId?.view ?? NuxByteView(data: nil, len: 0),
            manifest_bytes: manifestBytes?.view ?? NuxByteView(data: nil, len: 0),
            signature_envelope_bytes: signatureEnvelopeBytes?.view
                ?? NuxByteView(data: nil, len: 0),
            selected_key: selectedKey,
            external_assets: externalAssets,
            external_asset_count: externalAssetCount
        )
        return try withUnsafePointer(to: &request, body)
    }
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

func copyNuxieRuntimeResult(
    callStatus: UInt32,
    result: inout OpaquePointer?,
    renderRequested: Bool
) throws -> FlowRuntimeOperationResult {
    try copyNuxieRuntimeResultSnapshot(
        callStatus: callStatus,
        result: &result,
        renderRequested: renderRequested
    ).operationResult
}

private struct NuxieRuntimeResultSnapshot {
    let operationResult: FlowRuntimeOperationResult
    let scriptAuthorization: FlowRuntimeScriptAuthorization?
}

private func copyNuxieRuntimeResultSnapshot(
    callStatus: UInt32,
    result: inout OpaquePointer?,
    renderRequested: Bool
) throws -> NuxieRuntimeResultSnapshot {
    guard let ownedResult = result else {
        if callStatus != NUX_STATUS_OK {
            throw NuxieRuntimeAdapterError.callFailed(
                status: nuxieRuntimeStatus(callStatus),
                diagnostic: nuxieRuntimeDiagnostic(
                    status: callStatus,
                    message: "native runtime returned no diagnostic result"
                )
            )
        }
        throw NuxieRuntimeAdapterError.missingOperationResult
    }
    result = nil
    defer { nux_operation_result_free(ownedResult) }

    let resultStatus = nux_operation_result_status(ownedResult)
    let structuredDiagnostics = try copyNuxieRuntimeDiagnostics(from: ownedResult)
    let diagnosticMessage = copyNuxieRuntimeDiagnostic(from: ownedResult)
    let failureStatus = callStatus != NUX_STATUS_OK ? callStatus : resultStatus
    if failureStatus != NUX_STATUS_OK {
        throw NuxieRuntimeAdapterError.callFailed(
            status: nuxieRuntimeStatus(failureStatus),
            diagnostic: structuredDiagnostics.first
                ?? nuxieRuntimeDiagnostic(
                    status: failureStatus,
                    message: diagnosticMessage.isEmpty
                        ? "native runtime operation failed"
                        : diagnosticMessage
                )
        )
    }

    let disposition = nuxieRuntimeSurfaceDisposition(
        nux_operation_result_surface_disposition(ownedResult)
    )
    let changed = nux_operation_result_changed(ownedResult)
    let renderOutcome: FlowRuntimeRenderOutcome
    if !renderRequested {
        renderOutcome = .notRequested
    } else if disposition == .presented {
        renderOutcome = .presented
    } else {
        renderOutcome = .skipped
    }
    var diagnostics = structuredDiagnostics
    if diagnostics.isEmpty, !diagnosticMessage.isEmpty {
        diagnostics = [
            FlowRuntimeDiagnostic(
                severity: .debug,
                code: "nux_runtime.ok",
                message: diagnosticMessage
            )
        ]
    }

    return NuxieRuntimeResultSnapshot(
        operationResult: FlowRuntimeOperationResult(
            renderOutcome: renderOutcome,
            surfaceDisposition: disposition,
            isDirty: changed,
            isSettled: !changed,
            orderedOutputs: [],
            diagnostics: diagnostics
        ),
        scriptAuthorization: try copyNuxieRuntimeScriptAuthorization(
            from: ownedResult
        )
    )
}

private func copyNuxieRuntimeScriptAuthorization(
    from result: OpaquePointer
) throws -> FlowRuntimeScriptAuthorization? {
    switch nux_operation_result_script_authorization(result) {
    case UInt32(NUX_SCRIPT_AUTHORIZATION_NOT_APPLICABLE):
        return nil
    case UInt32(NUX_SCRIPT_AUTHORIZATION_VISUAL_ONLY):
        return .visualOnly
    case UInt32(NUX_SCRIPT_AUTHORIZATION_AUTHENTICATED):
        var keyIdView = NuxByteView(data: nil, len: 0)
        guard nux_operation_result_authenticated_key_id(result, &keyIdView)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "authenticated import omitted its key ID"
            )
        }
        let keyId = try copyNuxieRuntimeUTF8(
            keyIdView,
            label: "authenticated key ID"
        )
        guard !keyId.isEmpty else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "authenticated import returned an empty key ID"
            )
        }
        return .authorized(keyId: keyId)
    case let value:
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "unknown script authorization value \(value)"
        )
    }
}

private func copyNuxieRuntimeDiagnostics(
    from result: OpaquePointer
) throws -> [FlowRuntimeDiagnostic] {
    let count = nux_operation_result_diagnostic_count(result)
    guard count <= 1_024, count <= UInt64(Int.max) else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned too many diagnostics"
        )
    }
    var diagnostics: [FlowRuntimeDiagnostic] = []
    diagnostics.reserveCapacity(Int(count))
    var aggregateUTF8Bytes = 0
    for index in 0..<count {
        var view = NuxDiagnosticView(
            struct_size: UInt32(MemoryLayout<NuxDiagnosticView>.size),
            severity: UInt32(NUX_DIAGNOSTIC_SEVERITY_DEBUG),
            code: NuxByteView(data: nil, len: 0),
            message: NuxByteView(data: nil, len: 0)
        )
        guard nux_operation_result_diagnostic_at(result, index, &view)
            == NUX_STATUS_OK else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime diagnostic \(index) could not be read"
            )
        }
        let severity: FlowRuntimeDiagnostic.Severity
        switch view.severity {
        case UInt32(NUX_DIAGNOSTIC_SEVERITY_DEBUG):
            severity = .debug
        case UInt32(NUX_DIAGNOSTIC_SEVERITY_WARNING):
            severity = .warning
        case UInt32(NUX_DIAGNOSTIC_SEVERITY_FATAL):
            severity = .fatal
        default:
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime diagnostic \(index) has an unknown severity"
            )
        }
        let code = try copyNuxieRuntimeUTF8(view.code, label: "diagnostic code")
        guard !code.isEmpty else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime diagnostic \(index) has an empty code"
            )
        }
        let message = try copyNuxieRuntimeUTF8(
            view.message,
            label: "diagnostic message"
        )
        let (nextAggregate, overflowed) = aggregateUTF8Bytes.addingReportingOverflow(
            code.utf8.count + message.utf8.count
        )
        guard !overflowed, nextAggregate <= 8_388_608 else {
            throw NuxieRuntimeAdapterError.invalidNativeResult(
                "native runtime returned oversized aggregate diagnostics"
            )
        }
        aggregateUTF8Bytes = nextAggregate
        diagnostics.append(
            FlowRuntimeDiagnostic(
                severity: severity,
                code: code,
                message: message
            )
        )
    }
    return diagnostics
}

private func copyNuxieRuntimeUTF8(
    _ view: NuxByteView,
    label: String
) throws -> String {
    guard view.len <= UInt64(Int.max), view.len <= 4_194_304 else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned an oversized \(label)"
        )
    }
    guard view.len > 0 else { return "" }
    guard let bytes = view.data else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned a null \(label)"
        )
    }
    let data = Data(bytes: bytes, count: Int(view.len))
    guard let value = String(data: data, encoding: .utf8) else {
        throw NuxieRuntimeAdapterError.invalidNativeResult(
            "native runtime returned non-UTF-8 \(label)"
        )
    }
    return value
}

/// Copies the borrowed result view before `copyNuxieRuntimeResult` frees it.
private func copyNuxieRuntimeDiagnostic(from result: OpaquePointer) -> String {
    var view = NuxByteView(data: nil, len: 0)
    let status = nux_operation_result_diagnostic(result, &view)
    guard status == NUX_STATUS_OK else {
        return "native runtime diagnostic could not be read"
    }
    guard view.len > 0 else { return "" }
    guard let bytes = view.data,
          view.len <= UInt64(Int.max),
          view.len <= 4_194_304 else {
        return "native runtime returned an invalid diagnostic view"
    }
    let copiedBytes = Data(bytes: bytes, count: Int(view.len))
    return String(decoding: copiedBytes, as: UTF8.self)
}

private func nuxieRuntimeDiagnostic(
    status: UInt32,
    message: String
) -> FlowRuntimeDiagnostic {
    FlowRuntimeDiagnostic(
        severity: .fatal,
        code: "nux_runtime.\(nuxieRuntimeStatusCode(status))",
        message: message
    )
}

func nuxieRuntimeStatus(_ rawValue: UInt32) -> NuxieRuntimeStatus {
    switch rawValue {
    case NUX_STATUS_OK: .ok
    case NUX_STATUS_NULL_ARGUMENT: .nullArgument
    case NUX_STATUS_IMPORT_ERROR: .importError
    case NUX_STATUS_NOT_FOUND: .notFound
    case NUX_STATUS_RUNTIME_ERROR: .runtimeError
    case NUX_STATUS_INVALID_ARGUMENT: .invalidArgument
    case NUX_STATUS_ABI_MISMATCH: .abiMismatch
    case NUX_STATUS_SURFACE_ERROR: .surfaceError
    default: .unknown(rawValue)
    }
}

private func nuxieRuntimeStatusCode(_ rawValue: UInt32) -> String {
    switch nuxieRuntimeStatus(rawValue) {
    case .ok: "ok"
    case .nullArgument: "null_argument"
    case .importError: "import_error"
    case .notFound: "not_found"
    case .runtimeError: "runtime_error"
    case .invalidArgument: "invalid_argument"
    case .abiMismatch: "abi_mismatch"
    case .surfaceError: "surface_error"
    case .unknown(let value): "unknown_\(value)"
    }
}

func nuxieRuntimeSurfaceDisposition(
    _ rawValue: UInt32
) -> FlowRuntimeSurfaceDisposition {
    switch rawValue {
    case NUX_SURFACE_DISPOSITION_NONE: .none
    case NUX_SURFACE_DISPOSITION_PRESENTED: .presented
    case NUX_SURFACE_DISPOSITION_SKIPPED_ZERO_SIZE: .skippedZeroSize
    case NUX_SURFACE_DISPOSITION_SKIPPED_TIMEOUT: .skippedTimeout
    case NUX_SURFACE_DISPOSITION_SKIPPED_OCCLUDED: .skippedOccluded
    case NUX_SURFACE_DISPOSITION_RECONFIGURED: .reconfigured
    case NUX_SURFACE_DISPOSITION_RECREATED: .recreated
    case NUX_SURFACE_DISPOSITION_DEVICE_LOST: .deviceLost
    case NUX_SURFACE_DISPOSITION_OUT_OF_MEMORY: .outOfMemory
    case NUX_SURFACE_DISPOSITION_FATAL: .fatal
    default: .unknown(rawValue)
    }
}

#endif
