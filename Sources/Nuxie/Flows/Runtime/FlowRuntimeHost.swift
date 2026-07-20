import Foundation
import Metal
import QuartzCore

/// Nuxie-selected Ed25519 validation material, never an authorization decision.
struct FlowRuntimeAuthorizationKey: Equatable, Sendable {
    let keyId: String
    let ed25519PublicKeyBytes: Data
}

/// Exact content and detached signature evidence independently validated by Rust.
struct FlowRuntimeAuthorizationEvidence: Equatable, Sendable {
    let signedContentBytes: Data
    let signatureEnvelopeBytes: Data?
    let selectedKey: FlowRuntimeAuthorizationKey?
}

/// Container-neutral bytes used to create one runtime context for a flow presentation.
///
/// The runtime-facing API deliberately has no knowledge of `.riv` paths, CDN
/// URLs, or the future `.nux` container. It receives exact bytes, acquisition
/// identity, validation evidence, and ordered prepared asset inputs.
struct FlowRuntimeImportRequest: Equatable, Sendable {
    let artifactBytes: Data
    let expectedIdentity: FlowRuntimeArtifactIdentity?
    let authorizationEvidence: FlowRuntimeAuthorizationEvidence?
    let externalAssets: [FlowRuntimeExternalAsset]

    init(
        artifactBytes: Data,
        expectedIdentity: FlowRuntimeArtifactIdentity? = nil,
        authorizationEvidence: FlowRuntimeAuthorizationEvidence? = nil,
        externalAssets: [FlowRuntimeExternalAsset] = []
    ) {
        self.artifactBytes = artifactBytes
        self.expectedIdentity = expectedIdentity
        self.authorizationEvidence = authorizationEvidence
        self.externalAssets = externalAssets
    }
}

enum FlowRuntimeImportLimits {
    static let artifactBytes = 67_108_864
    static let manifestBytes = 4_194_304
    static let signatureEnvelopeBytes = 65_536
    static let authorizationKeyIdBytes = 256
    static let authorizationPublicKeyBytes = 32
    static let externalAssetCount = 1_024
    static let externalAssetTotalBytes = 134_217_728
    static let selectorBytes = 4_096
    static let assetSourceKeyBytes = manifestBytes
}

enum FlowRuntimeImportValidationError: LocalizedError, Equatable {
    case valueExceedsLimit(field: String, actual: Int, limit: Int)
    case byteCountOverflow(field: String)

    var errorDescription: String? {
        switch self {
        case let .valueExceedsLimit(field, actual, limit):
            "Runtime import \(field) is \(actual) bytes/items; the limit is \(limit)"
        case .byteCountOverflow(let field):
            "Runtime import \(field) byte count overflowed"
        }
    }
}

extension FlowRuntimeImportRequest {
    /// Keeps authorization-only transport defects from turning a visual import
    /// into a hard failure before Rust can make the authorization decision.
    ///
    /// The manifest remains exact because it also declares artifact integrity.
    /// Oversized signatures are represented as present-but-malformed evidence;
    /// unusable selected keys are omitted so Rust reports a visual-only result.
    func normalizedForNativeAuthorizationLimits() -> Self {
        guard let authorizationEvidence else { return self }

        let signatureEnvelopeBytes: Data?
        let selectedKey: FlowRuntimeAuthorizationKey?
        if let signature = authorizationEvidence.signatureEnvelopeBytes,
           signature.count > FlowRuntimeImportLimits.signatureEnvelopeBytes {
            signatureEnvelopeBytes = Data()
            selectedKey = nil
        } else {
            signatureEnvelopeBytes = authorizationEvidence.signatureEnvelopeBytes
            if let key = authorizationEvidence.selectedKey,
               !key.keyId.isEmpty,
               key.keyId.utf8.count <= FlowRuntimeImportLimits.authorizationKeyIdBytes,
               key.ed25519PublicKeyBytes.count
                   == FlowRuntimeImportLimits.authorizationPublicKeyBytes {
                selectedKey = key
            } else {
                selectedKey = nil
            }
        }

        return Self(
            artifactBytes: artifactBytes,
            expectedIdentity: expectedIdentity,
            authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                signedContentBytes: authorizationEvidence.signedContentBytes,
                signatureEnvelopeBytes: signatureEnvelopeBytes,
                selectedKey: selectedKey
            ),
            externalAssets: externalAssets
        )
    }

    func validateNativeLimits() throws {
        try Self.requireAtMost(
            artifactBytes.count,
            FlowRuntimeImportLimits.artifactBytes,
            field: "artifact"
        )
        if let expectedIdentity {
            try Self.requireAtMost(
                expectedIdentity.flowId.utf8.count,
                FlowRuntimeImportLimits.selectorBytes,
                field: "expected flow ID"
            )
            try Self.requireAtMost(
                expectedIdentity.buildId.utf8.count,
                FlowRuntimeImportLimits.selectorBytes,
                field: "expected build ID"
            )
        }
        if let authorizationEvidence {
            try Self.requireAtMost(
                authorizationEvidence.signedContentBytes.count,
                FlowRuntimeImportLimits.manifestBytes,
                field: "signed manifest"
            )
        }
        try Self.requireAtMost(
            externalAssets.count,
            FlowRuntimeImportLimits.externalAssetCount,
            field: "external asset count"
        )

        var totalAssetBytes = 0
        for (index, asset) in externalAssets.enumerated() {
            try Self.requireAtMost(
                asset.riveUniqueName.utf8.count,
                FlowRuntimeImportLimits.selectorBytes,
                field: "external asset \(index) unique name"
            )
            try Self.requireAtMost(
                asset.sourceKey.utf8.count,
                FlowRuntimeImportLimits.assetSourceKeyBytes,
                field: "external asset \(index) source key"
            )
            try Self.requireAtMost(
                asset.expectedSHA256.utf8.count,
                FlowRuntimeImportLimits.selectorBytes,
                field: "external asset \(index) SHA-256"
            )
            guard case .bytes(let bytes) = asset.content else { continue }
            try Self.requireAtMost(
                bytes.count,
                FlowRuntimeImportLimits.externalAssetTotalBytes,
                field: "external asset \(index) bytes"
            )
            let (nextTotal, overflowed) = totalAssetBytes.addingReportingOverflow(bytes.count)
            guard !overflowed else {
                throw FlowRuntimeImportValidationError.byteCountOverflow(
                    field: "aggregate external assets"
                )
            }
            totalAssetBytes = nextTotal
        }
        try Self.requireAtMost(
            totalAssetBytes,
            FlowRuntimeImportLimits.externalAssetTotalBytes,
            field: "aggregate external asset bytes"
        )
    }

    static func requireAtMost(
        _ actual: Int,
        _ limit: Int,
        field: String
    ) throws {
        guard actual <= limit else {
            throw FlowRuntimeImportValidationError.valueExceedsLimit(
                field: field,
                actual: actual,
                limit: limit
            )
        }
    }
}

/// Product identity expected by the acquisition layer for replay protection.
struct FlowRuntimeArtifactIdentity: Equatable, Sendable {
    let flowId: String
    let buildId: String
}

enum FlowRuntimeExternalAssetKind: UInt32, Equatable, Sendable {
    case image = 1
    case font = 2
}

enum FlowRuntimeExternalAssetContent: Equatable, Sendable {
    case bytes(Data)
    case omittedOptional
}

/// One manifest-declared asset prepared by Swift without exposing its URL.
struct FlowRuntimeExternalAsset: Equatable, Sendable {
    let kind: FlowRuntimeExternalAssetKind
    let riveAssetId: UInt32
    let riveUniqueName: String
    let sourceKey: String
    let expectedSHA256: String
    let required: Bool
    let content: FlowRuntimeExternalAssetContent
}

/// Selects the independent mutable runtime state owned by one live screen.
struct FlowRenderSessionDescriptor: Equatable, Sendable {
    let artboardName: String?
    let stateMachineName: String?

    init(
        artboardName: String? = nil,
        stateMachineName: String? = nil
    ) {
        self.artboardName = artboardName
        self.stateMachineName = stateMachineName
    }
}

/// App-clock time supplied to one coarse runtime advance operation.
struct FlowRuntimeFrameTime: Equatable, Sendable {
    let timestamp: TimeInterval
    let delta: TimeInterval
}

/// The single typed operation seam for one live flow session.
enum FlowRuntimeOperation: Equatable, Sendable {
    case stateBatch(FlowRuntimeStateBatch)
    case pointerBatch([FlowRuntimePointerEvent])
    case advance(FlowRuntimeFrameTime)
    case advanceAndRender(FlowRuntimeFrameTime)
    case query([FlowRuntimeQuery])
}

/// Observable phases from the current Rive-backed host contract.
///
/// Raw values are significant: a valid batch may stay in a phase or move
/// forward, but must never move backward.
enum FlowRuntimeOutputPhase: Int, Equatable, Sendable {
    case delayedEventCallbacks
    case reportedEvents
    case runtimeAdvance
    case viewModelChanges
    case hostWork
    case render
}

/// The operation output families Swift will eventually translate into Nuxie
/// events, canonical-state changes, platform intents, and render work.
enum FlowRuntimeOutputKind: Equatable, Sendable {
    case delayedEvent
    case reportedEvent
    case stateChange
    case viewModelChange
    case hostCommand
    case renderRequest
    case runtimeAdvanced
}

struct FlowRuntimeOpenURL: Equatable, Sendable {
    let url: String
    let target: String
}

enum FlowRuntimeOutputPayload: Equatable, Sendable {
    case delayedEvent
    case reportedEvent(
        name: String?,
        eventType: UInt32,
        delay: TimeInterval,
        properties: [FlowRuntimeEventProperty],
        openURL: FlowRuntimeOpenURL?
    )
    case stateChange(FlowRuntimeStateChange)
    case viewModelChange(FlowRuntimeStateChange)
    case hostCommand(name: String, payload: Data)
    case renderRequest
    case runtimeAdvanced(delta: TimeInterval)

    var kind: FlowRuntimeOutputKind {
        switch self {
        case .delayedEvent: .delayedEvent
        case .reportedEvent: .reportedEvent
        case .stateChange: .stateChange
        case .viewModelChange: .viewModelChange
        case .hostCommand: .hostCommand
        case .renderRequest: .renderRequest
        case .runtimeAdvanced: .runtimeAdvanced
        }
    }
}

/// One phase-tagged item in the exact order returned by the runtime.
struct FlowRuntimeOutput: Equatable, Sendable {
    let sequence: UInt64
    let cycle: UInt64
    let phase: FlowRuntimeOutputPhase
    let payload: FlowRuntimeOutputPayload

    var kind: FlowRuntimeOutputKind { payload.kind }

    init(
        sequence: UInt64,
        cycle: UInt64,
        phase: FlowRuntimeOutputPhase,
        payload: FlowRuntimeOutputPayload
    ) {
        self.sequence = sequence
        self.cycle = cycle
        self.phase = phase
        self.payload = payload
    }

    /// Convenience retained for host fakes that only exercise ordering.
    init(
        sequence: UInt64,
        cycle: UInt64 = 0,
        phase: FlowRuntimeOutputPhase,
        kind: FlowRuntimeOutputKind
    ) {
        let emptyChange = FlowRuntimeStateChange(
            instanceID: nil,
            path: "",
            value: nil,
            originMutationID: nil
        )
        let payload: FlowRuntimeOutputPayload = switch kind {
        case .delayedEvent:
            .delayedEvent
        case .reportedEvent:
            .reportedEvent(
                name: nil,
                eventType: 0,
                delay: 0,
                properties: [],
                openURL: nil
            )
        case .stateChange:
            .stateChange(emptyChange)
        case .viewModelChange:
            .viewModelChange(emptyChange)
        case .hostCommand:
            .hostCommand(name: "", payload: Data())
        case .renderRequest:
            .renderRequest
        case .runtimeAdvanced:
            .runtimeAdvanced(delta: 0)
        }
        self.init(sequence: sequence, cycle: cycle, phase: phase, payload: payload)
    }
}

struct FlowRuntimeDiagnostic: Equatable, Sendable {
    enum Severity: Equatable, Sendable {
        case debug
        case warning
        case fatal
    }

    let severity: Severity
    let code: String
    let message: String
}

enum FlowRuntimeScriptAuthorization: Equatable, Sendable {
    case visualOnly
    case authorized(keyId: String)
}

struct FlowRuntimeImportResult: Equatable, Sendable {
    let scriptAuthorization: FlowRuntimeScriptAuthorization
    let diagnostics: [FlowRuntimeDiagnostic]

    static let visualOnly = FlowRuntimeImportResult(
        scriptAuthorization: .visualOnly,
        diagnostics: []
    )

    /// Ensures an authenticated runtime result is bound to validation material
    /// selected by Nuxie's sealed trust policy for this exact import.
    ///
    /// Rust remains the cryptographic authority. This check prevents a buggy or
    /// substituted adapter from promoting an unbound key ID into executable
    /// script authorization at the product boundary.
    func validateAuthorizationBinding(
        to request: FlowRuntimeImportRequest
    ) throws {
        guard case .authorized(let reportedKeyId) = scriptAuthorization else {
            return
        }
        guard !reportedKeyId.isEmpty,
              let evidence = request.authorizationEvidence,
              !evidence.signedContentBytes.isEmpty,
              let signature = evidence.signatureEnvelopeBytes,
              !signature.isEmpty,
              let selectedKey = evidence.selectedKey,
              !selectedKey.keyId.isEmpty,
              selectedKey.ed25519PublicKeyBytes.count
                  == FlowRuntimeImportLimits.authorizationPublicKeyBytes else {
            throw FlowRuntimeHostError.authenticatedImportMissingEvidence(
                reportedKeyId: reportedKeyId
            )
        }
        guard selectedKey.keyId == reportedKeyId else {
            throw FlowRuntimeHostError.authenticatedImportKeyMismatch(
                selectedKeyId: selectedKey.keyId,
                reportedKeyId: reportedKeyId
            )
        }
    }
}

enum FlowRuntimeRenderOutcome: Equatable, Sendable {
    case notRequested
    case presented
    case skipped
}

/// Exact Apple-surface outcome reported by the native runtime.
///
/// Keeping this separate from `FlowRuntimeRenderOutcome` preserves recovery
/// information without making callers interpret C enum values.
enum FlowRuntimeSurfaceDisposition: Equatable, Sendable {
    case none
    case presented
    case skippedZeroSize
    case skippedTimeout
    case skippedOccluded
    case reconfigured
    case recreated
    case deviceLost
    case outOfMemory
    case fatal
    case unknown(UInt32)
}

struct FlowRuntimeSurfaceSize: Equatable, Sendable {
    let pixelWidth: UInt32
    let pixelHeight: UInt32
}

enum FlowRuntimeAppleSurfacePolicy {
    static let maximumDrawableCount = 2
}

/// A main-actor-owned presentation target. Swift configures this layer with the
/// native runtime's Metal device; Rust never borrows or mutates the layer.
@MainActor
struct FlowRuntimeAppleSurfaceTarget {
    let layer: CAMetalLayer
    let size: FlowRuntimeSurfaceSize
}

/// One drawable retained by Swift for exactly one asynchronous native frame.
/// Acquisition and all `CAMetalLayer` mutation stay on the main actor.
@MainActor
struct FlowRuntimeAppleDrawableTarget {
    let drawable: any CAMetalDrawable
    let completion: FlowRuntimeDrawableCompletion

    init(
        drawable: any CAMetalDrawable,
        onCompleted: @escaping @Sendable () -> Void = {}
    ) {
        self.drawable = drawable
        completion = FlowRuntimeDrawableCompletion(onCompleted: onCompleted)
    }

    nonisolated func complete() {
        completion.complete()
    }
}

final class FlowRuntimeDrawableCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var onCompleted: (@Sendable () -> Void)?

    init(onCompleted: @escaping @Sendable () -> Void) {
        self.onCompleted = onCompleted
    }

    func complete() {
        let callback = lock.withLock {
            defer { onCompleted = nil }
            return onCompleted
        }
        callback?()
    }

    deinit {
        complete()
    }
}

/// One owned response to a coarse operation.
///
/// The concrete runtime adapter copies the Rust result into this Swift value
/// before releasing the C result handle. Outputs remain ordered; callers must
/// not regroup them by kind.
struct FlowRuntimeOperationResult: Equatable, Sendable {
    let renderOutcome: FlowRuntimeRenderOutcome
    let surfaceDisposition: FlowRuntimeSurfaceDisposition
    let isDirty: Bool
    let isSettled: Bool
    let wakeAfter: TimeInterval?
    let orderedOutputs: [FlowRuntimeOutput]
    let diagnostics: [FlowRuntimeDiagnostic]
    let bootstrap: FlowRuntimeBootstrap?
    let values: FlowRuntimeValueArena?
    let catalog: FlowRuntimeCatalog?
    let playerInputs: [FlowRuntimePlayerInput]?
    let createdInstances: [FlowRuntimeCreatedInstance]

    init(
        renderOutcome: FlowRuntimeRenderOutcome,
        surfaceDisposition: FlowRuntimeSurfaceDisposition = .none,
        isDirty: Bool,
        isSettled: Bool,
        wakeAfter: TimeInterval? = nil,
        orderedOutputs: [FlowRuntimeOutput] = [],
        diagnostics: [FlowRuntimeDiagnostic] = [],
        bootstrap: FlowRuntimeBootstrap? = nil,
        values: FlowRuntimeValueArena? = nil,
        catalog: FlowRuntimeCatalog? = nil,
        playerInputs: [FlowRuntimePlayerInput]? = nil,
        createdInstances: [FlowRuntimeCreatedInstance] = []
    ) {
        self.renderOutcome = renderOutcome
        self.surfaceDisposition = surfaceDisposition
        self.isDirty = isDirty
        self.isSettled = isSettled
        self.wakeAfter = wakeAfter
        self.orderedOutputs = orderedOutputs
        self.diagnostics = diagnostics
        self.bootstrap = bootstrap
        self.values = values
        self.catalog = catalog
        self.playerInputs = playerInputs
        self.createdInstances = createdInstances
    }
}

enum FlowRuntimeSessionReadiness: Equatable {
    case waitingForFirstResult
    case ready
}

enum FlowRuntimeSurfaceState: Equatable {
    case attached
    case detached
    case disposed
}

enum FlowRuntimeHostError: Error, Equatable {
    case disposedSession
    case disposedSurface
    case surfaceAlreadyAttached
    case surfaceNotAttached
    case surfaceNotDetached
    case unrecoverableSurface(FlowRuntimeSurfaceDisposition)
    case outputSequenceDidNotIncrease(previous: UInt64, current: UInt64)
    case outputCycleRegressed(previous: UInt64, current: UInt64)
    case outputPhaseRegressed(previous: FlowRuntimeOutputPhase, current: FlowRuntimeOutputPhase)
    case requiredFontRegistrationFailed(String)
    case authenticatedImportMissingEvidence(reportedKeyId: String)
    case authenticatedImportKeyMismatch(selectedKeyId: String, reportedKeyId: String)
}

/// The only runtime implementation seam used by the Swift host.
///
/// The focused `NuxieRuntime` bridge files implement this protocol and are the
/// only small group that imports the binary module. Drivers enqueue work on the
/// runtime's serial worker and never call back into Swift reentrantly.
protocol FlowRuntimeAdapter: AnyObject {
    @MainActor
    func makeContext(
        for request: FlowRuntimeImportRequest
    ) async throws -> FlowRuntimeContextDriverAttachment
}

struct FlowRuntimeContextDriverAttachment {
    let driver: any FlowRuntimeContextDriver
    let importResult: FlowRuntimeImportResult
}

protocol FlowRuntimeContextDriver: AnyObject {
    @MainActor
    func makeSession(
        descriptor: FlowRenderSessionDescriptor
    ) async throws -> FlowRuntimeSessionDriverAttachment

    /// Thread-safe and nonblocking. The implementation may enqueue destruction.
    func dispose()
}

struct FlowRuntimeSessionDriverAttachment {
    let driver: any FlowRenderSessionDriver
    let bootstrap: FlowRuntimeBootstrap
}

protocol FlowRenderSessionDriver: AnyObject {
    @MainActor
    func perform(
        _ operation: FlowRuntimeOperation,
        drawable: FlowRuntimeAppleDrawableTarget?
    ) async throws -> FlowRuntimeOperationResult

    @MainActor
    func attachAppleSurface(
        to target: FlowRuntimeAppleSurfaceTarget
    ) async throws -> FlowRuntimeSurfaceDriverAttachment

    /// Thread-safe and nonblocking. The implementation may enqueue destruction.
    func dispose()
}

struct FlowRuntimeSurfaceDriverAttachment {
    let driver: any FlowRuntimeSurfaceDriver
    let result: FlowRuntimeOperationResult
    let configurator: any FlowRuntimeAppleSurfaceConfigurator
}

/// Main-actor layer setup supplied by the concrete runtime adapter.
/// A fake can implement this without importing the native binary module.
@MainActor
protocol FlowRuntimeAppleSurfaceConfigurator: AnyObject {
    func configure(_ target: FlowRuntimeAppleSurfaceTarget)
    func unconfigure(_ target: FlowRuntimeAppleSurfaceTarget)
}

protocol FlowRuntimeSurfaceDriver: AnyObject {
    @MainActor
    func resize(to size: FlowRuntimeSurfaceSize) async throws -> FlowRuntimeOperationResult

    @MainActor
    func detach() async throws -> FlowRuntimeOperationResult

    @MainActor
    func reattach(
        to target: FlowRuntimeAppleSurfaceTarget
    ) async throws -> FlowRuntimeOperationResult

    /// Thread-safe and nonblocking. The implementation may enqueue destruction.
    func dispose()
}

/// Creates a fresh context for each presentation while hiding runtime-specific
/// handles and import details from the flow UI.
@MainActor
final class FlowRuntimeContextFactory {
    private let adapter: any FlowRuntimeAdapter

    init(adapter: any FlowRuntimeAdapter) {
        self.adapter = adapter
    }

    func makeContext(for request: FlowRuntimeImportRequest) async throws -> FlowRuntimeContext {
        let fontScope = FlowRuntimeFontScope()
        do {
            let sanitizedAssets = try request.externalAssets.map { asset in
                guard asset.kind == .font,
                      case .bytes(let data) = asset.content else {
                    return asset
                }
                guard FlowRuntimeFontRegistry.registerFont(
                    riveUniqueName: asset.riveUniqueName,
                    data: data,
                    in: fontScope
                ) != nil else {
                    guard !asset.required else {
                        throw FlowRuntimeHostError.requiredFontRegistrationFailed(
                            asset.riveUniqueName
                        )
                    }
                    return FlowRuntimeExternalAsset(
                        kind: asset.kind,
                        riveAssetId: asset.riveAssetId,
                        riveUniqueName: asset.riveUniqueName,
                        sourceKey: asset.sourceKey,
                        expectedSHA256: asset.expectedSHA256,
                        required: asset.required,
                        content: .omittedOptional
                    )
                }
                return asset
            }
            let sanitizedRequest = FlowRuntimeImportRequest(
                artifactBytes: request.artifactBytes,
                expectedIdentity: request.expectedIdentity,
                authorizationEvidence: request.authorizationEvidence,
                externalAssets: sanitizedAssets
            ).normalizedForNativeAuthorizationLimits()
            let attachment = try await adapter.makeContext(for: sanitizedRequest)
            do {
                try attachment.importResult.validateAuthorizationBinding(
                    to: sanitizedRequest
                )
            } catch {
                attachment.driver.dispose()
                throw error
            }
            return FlowRuntimeContext(
                driver: attachment.driver,
                importResult: attachment.importResult,
                fontScope: fontScope
            )
        } catch {
            fontScope.close()
            throw error
        }
    }
}

/// Shared immutable/rebuildable runtime resources for one presentation.
///
/// A session retains this object, making it impossible for ARC to destroy the
/// native context while a child session is alive.
@MainActor
final class FlowRuntimeContext {
    private let driver: any FlowRuntimeContextDriver
    private let fontScope: FlowRuntimeFontScope
    let importResult: FlowRuntimeImportResult

    fileprivate init(
        driver: any FlowRuntimeContextDriver,
        importResult: FlowRuntimeImportResult,
        fontScope: FlowRuntimeFontScope
    ) {
        self.driver = driver
        self.importResult = importResult
        self.fontScope = fontScope
    }

    func makeSession(descriptor: FlowRenderSessionDescriptor) async throws -> FlowRenderSession {
        let attachment = try await driver.makeSession(descriptor: descriptor)
        return FlowRenderSession(
            context: self,
            driver: attachment.driver,
            bootstrap: attachment.bootstrap
        )
    }

    deinit {
        driver.dispose()
        fontScope.close()
    }
}

/// Independent mutable runtime state for one live flow screen.
@MainActor
final class FlowRenderSession {
    private var context: FlowRuntimeContext?
    private var driver: (any FlowRenderSessionDriver)?
    private weak var surface: FlowRenderSurface?
    private var lastOutputSequence: UInt64?
    private var lastOutputCycle: UInt64?
    private var lastOutputPhase: FlowRuntimeOutputPhase?

    let bootstrap: FlowRuntimeBootstrap
    private(set) var readiness: FlowRuntimeSessionReadiness = .waitingForFirstResult

    fileprivate init(
        context: FlowRuntimeContext,
        driver: any FlowRenderSessionDriver,
        bootstrap: FlowRuntimeBootstrap
    ) {
        self.context = context
        self.driver = driver
        self.bootstrap = bootstrap
    }

    func perform(
        _ operation: FlowRuntimeOperation,
        drawable: FlowRuntimeAppleDrawableTarget? = nil
    ) async throws -> FlowRuntimeOperationResult {
        guard let driver else {
            throw FlowRuntimeHostError.disposedSession
        }

        let result = try await driver.perform(operation, drawable: drawable)
        try validateOutputOrder(result.orderedOutputs)
        switch result.surfaceDisposition {
        case .deviceLost, .outOfMemory, .fatal, .unknown:
            throw FlowRuntimeHostError.unrecoverableSurface(result.surfaceDisposition)
        case .none, .presented, .skippedZeroSize, .skippedTimeout,
             .skippedOccluded, .reconfigured, .recreated:
            break
        }
        if result.renderOutcome == .presented {
            readiness = .ready
        }
        return result
    }

    func attachAppleSurface(
        to target: FlowRuntimeAppleSurfaceTarget
    ) async throws -> FlowRenderSurface {
        guard let driver else {
            throw FlowRuntimeHostError.disposedSession
        }
        guard surface == nil else {
            throw FlowRuntimeHostError.surfaceAlreadyAttached
        }

        let attachment = try await driver.attachAppleSurface(to: target)
        let surface = FlowRenderSurface(
            session: self,
            driver: attachment.driver,
            attachmentResult: attachment.result,
            configurator: attachment.configurator,
            target: target
        )
        self.surface = surface
        return surface
    }

    /// Deterministically submits child disposal before releasing the retained
    /// parent context. Repeated calls are harmless.
    func dispose() {
        guard let driver else { return }
        surface?.dispose()
        self.driver = nil
        driver.dispose()
        context = nil
    }

    deinit {
        driver?.dispose()
    }

    private func validateOutputOrder(_ outputs: [FlowRuntimeOutput]) throws {
        var previousSequence = lastOutputSequence
        var previousCycle = lastOutputCycle
        var previousPhase = lastOutputPhase

        for current in outputs {
            if let previousSequence, current.sequence <= previousSequence {
                throw FlowRuntimeHostError.outputSequenceDidNotIncrease(
                    previous: previousSequence,
                    current: current.sequence
                )
            }

            if let previousCycle, current.cycle < previousCycle {
                throw FlowRuntimeHostError.outputCycleRegressed(
                    previous: previousCycle,
                    current: current.cycle
                )
            }

            if previousCycle == current.cycle,
               let previousPhase,
               current.phase.rawValue < previousPhase.rawValue {
                throw FlowRuntimeHostError.outputPhaseRegressed(
                    previous: previousPhase,
                    current: current.phase
                )
            }

            previousSequence = current.sequence
            previousCycle = current.cycle
            previousPhase = current.phase
        }

        if let last = outputs.last {
            lastOutputSequence = last.sequence
            lastOutputCycle = last.cycle
            lastOutputPhase = last.phase
        }
    }

    fileprivate func releaseSurface(_ surface: FlowRenderSurface) {
        if self.surface === surface {
            self.surface = nil
        }
    }
}

/// Prevents stale deferred teardown from unconfiguring a newer owner of the
/// same CAMetalLayer. The weak-key registry never extends the layer lifetime.
@MainActor
final class FlowRuntimeSurfaceConfigurationOwner {
    private static let owners = NSMapTable<
        CAMetalLayer,
        FlowRuntimeSurfaceConfigurationOwner
    >.weakToWeakObjects()

    func configure(
        _ target: FlowRuntimeAppleSurfaceTarget,
        with configurator: any FlowRuntimeAppleSurfaceConfigurator
    ) {
        Self.owners.setObject(self, forKey: target.layer)
        configurator.configure(target)
    }

    func unconfigureIfOwned(
        _ target: FlowRuntimeAppleSurfaceTarget,
        with configurator: any FlowRuntimeAppleSurfaceConfigurator
    ) {
        guard Self.owners.object(forKey: target.layer) === self else { return }
        configurator.unconfigure(target)
        Self.owners.removeObject(forKey: target.layer)
    }
}

/// Keeps layer teardown behind every submitted drawable's Metal completion.
/// The runtime handle may be released earlier because Metal retains submitted
/// command resources independently; only UIKit-owned layer mutation waits.
@MainActor
final class FlowRuntimeSurfaceDrawableTracker {
    private var inFlightCount = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var idleActions: [@MainActor () -> Void] = []

    func beginFrame() {
        inFlightCount += 1
    }

    func completeFrame() {
        guard inFlightCount > 0 else { return }
        inFlightCount -= 1
        guard inFlightCount == 0 else { return }
        let waiters = idleWaiters
        let actions = idleActions
        idleWaiters.removeAll()
        idleActions.removeAll()
        waiters.forEach { $0.resume() }
        actions.forEach { $0() }
    }

    func waitUntilIdle() async {
        guard inFlightCount > 0 else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    func whenIdle(_ action: @escaping @MainActor () -> Void) {
        guard inFlightCount > 0 else {
            action()
            return
        }
        idleActions.append(action)
    }
}

/// One logical Apple presentation surface. Detach preserves the native
/// handle and its independent screen state; dispose releases it exactly once.
@MainActor
final class FlowRenderSurface {
    private var session: FlowRenderSession?
    private var driver: (any FlowRuntimeSurfaceDriver)?
    private let configurator: any FlowRuntimeAppleSurfaceConfigurator
    private let configurationOwner = FlowRuntimeSurfaceConfigurationOwner()
    private let drawableTracker = FlowRuntimeSurfaceDrawableTracker()
    private var target: FlowRuntimeAppleSurfaceTarget?

    let attachmentResult: FlowRuntimeOperationResult
    private(set) var state: FlowRuntimeSurfaceState = .attached

    fileprivate init(
        session: FlowRenderSession,
        driver: any FlowRuntimeSurfaceDriver,
        attachmentResult: FlowRuntimeOperationResult,
        configurator: any FlowRuntimeAppleSurfaceConfigurator,
        target: FlowRuntimeAppleSurfaceTarget
    ) {
        self.session = session
        self.driver = driver
        self.attachmentResult = attachmentResult
        self.configurator = configurator
        self.target = target
        configurationOwner.configure(target, with: configurator)
    }

    func resize(to size: FlowRuntimeSurfaceSize) async throws -> FlowRuntimeOperationResult {
        guard let driver else {
            throw FlowRuntimeHostError.disposedSurface
        }
        guard state == .attached else {
            throw FlowRuntimeHostError.surfaceNotAttached
        }
        let result = try await driver.resize(to: size)
        guard let target else {
            throw FlowRuntimeHostError.surfaceNotAttached
        }
        let resizedTarget = FlowRuntimeAppleSurfaceTarget(layer: target.layer, size: size)
        configurationOwner.configure(resizedTarget, with: configurator)
        self.target = resizedTarget
        return result
    }

    func detach() async throws -> FlowRuntimeOperationResult {
        guard let driver else {
            throw FlowRuntimeHostError.disposedSurface
        }
        guard state == .attached else {
            throw FlowRuntimeHostError.surfaceNotAttached
        }

        await drawableTracker.waitUntilIdle()
        let result = try await driver.detach()
        if let target {
            configurationOwner.unconfigureIfOwned(target, with: configurator)
            self.target = nil
        }
        state = .detached
        return result
    }

    func reattach(
        to target: FlowRuntimeAppleSurfaceTarget
    ) async throws -> FlowRuntimeOperationResult {
        guard let driver else {
            throw FlowRuntimeHostError.disposedSurface
        }
        guard state == .detached else {
            throw FlowRuntimeHostError.surfaceNotDetached
        }

        let result = try await driver.reattach(to: target)
        configurationOwner.configure(target, with: configurator)
        self.target = target
        state = .attached
        return result
    }

    func dispose() {
        guard let driver else { return }
        if let target {
            let configurationOwner = configurationOwner
            let configurator = configurator
            drawableTracker.whenIdle {
                configurationOwner.unconfigureIfOwned(target, with: configurator)
            }
            self.target = nil
        }
        self.driver = nil
        state = .disposed
        driver.dispose()
        session?.releaseSurface(self)
        session = nil
    }

    deinit {
        if let target {
            let configurator = configurator
            let configurationOwner = configurationOwner
            let drawableTracker = drawableTracker
            Task { @MainActor in
                await drawableTracker.waitUntilIdle()
                configurationOwner.unconfigureIfOwned(target, with: configurator)
            }
        }
        driver?.dispose()
    }

    func makeDrawableTarget(
        _ drawable: any CAMetalDrawable,
        onCompleted: @escaping @Sendable () -> Void
    ) -> FlowRuntimeAppleDrawableTarget {
        drawableTracker.beginFrame()
        let drawableTracker = drawableTracker
        return FlowRuntimeAppleDrawableTarget(drawable: drawable) {
            onCompleted()
            Task { @MainActor in
                drawableTracker.completeFrame()
            }
        }
    }
}
