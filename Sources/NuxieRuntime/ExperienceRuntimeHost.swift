import Foundation
import Metal
import QuartzCore

package struct ExperienceRuntimeAuthorizationKey: Equatable, Sendable {
    package let keyId: String
    package let ed25519PublicKeyBytes: Data

    package init(keyId: String, ed25519PublicKeyBytes: Data) {
        self.keyId = keyId
        self.ed25519PublicKeyBytes = ed25519PublicKeyBytes
    }
}

/// Complete input to the package-native runtime ABI.
package struct ExperienceRuntimeImportRequest: Equatable, Sendable {
    package let packageBytes: Data
    package let expectedExperienceId: String
    package let expectedBuildId: String
    package let candidateKeys: [ExperienceRuntimeAuthorizationKey]
    package let externalAssets: [ExperienceRuntimeExternalAsset]

    package init(
        packageBytes: Data,
        expectedExperienceId: String,
        expectedBuildId: String,
        candidateKeys: [ExperienceRuntimeAuthorizationKey],
        externalAssets: [ExperienceRuntimeExternalAsset] = []
    ) {
        self.packageBytes = packageBytes
        self.expectedExperienceId = expectedExperienceId
        self.expectedBuildId = expectedBuildId
        self.candidateKeys = candidateKeys
        self.externalAssets = externalAssets
    }
}

package enum ExperienceRuntimeImportLimits {
    package static let packageBytes = 134_217_728
    package static let authorizationKeyIdBytes = 256
    package static let authorizationPublicKeyBytes = 32
    package static let externalAssetCount = 1_024
    package static let externalAssetTotalBytes = 134_217_728
    package static let selectorBytes = 4_096
    package static let assetSourceKeyBytes = 4_194_304
}

package enum ExperienceRuntimeImportValidationError: LocalizedError, Equatable {
    case valueExceedsLimit(field: String, actual: Int, limit: Int)
    case byteCountOverflow(field: String)

    package var errorDescription: String? {
        switch self {
        case let .valueExceedsLimit(field, actual, limit):
            "Runtime import \(field) is \(actual) bytes/items; the limit is \(limit)"
        case .byteCountOverflow(let field):
            "Runtime import \(field) byte count overflowed"
        }
    }
}

extension ExperienceRuntimeImportRequest {
    package func validateNativeLimits() throws {
        try Self.requireAtMost(
            packageBytes.count,
            ExperienceRuntimeImportLimits.packageBytes,
            field: "package"
        )
        guard !expectedExperienceId.isEmpty, !expectedBuildId.isEmpty,
              !candidateKeys.isEmpty else {
            throw ExperienceRuntimeImportValidationError.valueExceedsLimit(
                field: "required package authorization input",
                actual: 0,
                limit: 1
            )
        }
        try Self.requireAtMost(
            expectedExperienceId.utf8.count,
            ExperienceRuntimeImportLimits.selectorBytes,
            field: "expected experience ID"
        )
        try Self.requireAtMost(
            expectedBuildId.utf8.count,
            ExperienceRuntimeImportLimits.selectorBytes,
            field: "expected build ID"
        )
        for (index, key) in candidateKeys.enumerated() {
            try Self.requireAtMost(
                key.keyId.utf8.count,
                ExperienceRuntimeImportLimits.authorizationKeyIdBytes,
                field: "candidate key \(index) ID"
            )
            guard !key.keyId.isEmpty,
                  key.ed25519PublicKeyBytes.count
                    == ExperienceRuntimeImportLimits.authorizationPublicKeyBytes else {
                throw ExperienceRuntimeImportValidationError.valueExceedsLimit(
                    field: "candidate key \(index)",
                    actual: key.ed25519PublicKeyBytes.count,
                    limit: ExperienceRuntimeImportLimits.authorizationPublicKeyBytes
                )
            }
        }
        try Self.requireAtMost(
            externalAssets.count,
            ExperienceRuntimeImportLimits.externalAssetCount,
            field: "external asset count"
        )

        var totalAssetBytes = 0
        for (index, asset) in externalAssets.enumerated() {
            try Self.requireAtMost(
                asset.riveUniqueName.utf8.count,
                ExperienceRuntimeImportLimits.selectorBytes,
                field: "external asset \(index) unique name"
            )
            try Self.requireAtMost(
                asset.sourceKey.utf8.count,
                ExperienceRuntimeImportLimits.assetSourceKeyBytes,
                field: "external asset \(index) source key"
            )
            try Self.requireAtMost(
                asset.expectedSHA256.utf8.count,
                ExperienceRuntimeImportLimits.selectorBytes,
                field: "external asset \(index) SHA-256"
            )
            guard case .bytes(let bytes) = asset.content else { continue }
            try Self.requireAtMost(
                bytes.count,
                ExperienceRuntimeImportLimits.externalAssetTotalBytes,
                field: "external asset \(index) bytes"
            )
            let (nextTotal, overflowed) = totalAssetBytes.addingReportingOverflow(bytes.count)
            guard !overflowed else {
                throw ExperienceRuntimeImportValidationError.byteCountOverflow(
                    field: "aggregate external assets"
                )
            }
            totalAssetBytes = nextTotal
        }
        try Self.requireAtMost(
            totalAssetBytes,
            ExperienceRuntimeImportLimits.externalAssetTotalBytes,
            field: "aggregate external asset bytes"
        )
    }

    package static func requireAtMost(
        _ actual: Int,
        _ limit: Int,
        field: String
    ) throws {
        guard actual <= limit else {
            throw ExperienceRuntimeImportValidationError.valueExceedsLimit(
                field: field,
                actual: actual,
                limit: limit
            )
        }
    }
}

package enum ExperienceRuntimeExternalAssetKind: UInt32, Equatable, Sendable {
    case image = 1
    case font = 2
}

package enum ExperienceRuntimeExternalAssetContent: Equatable, Sendable {
    case bytes(Data)
    case omittedOptional
}

/// One manifest-declared asset prepared by Swift without exposing its URL.
package struct ExperienceRuntimeExternalAsset: Equatable, Sendable {
    package let kind: ExperienceRuntimeExternalAssetKind
    package let riveAssetId: UInt32
    package let riveUniqueName: String
    package let sourceKey: String
    package let expectedSHA256: String
    package let required: Bool
    package let content: ExperienceRuntimeExternalAssetContent

    package init(
        kind: ExperienceRuntimeExternalAssetKind,
        riveAssetId: UInt32,
        riveUniqueName: String,
        sourceKey: String,
        expectedSHA256: String,
        required: Bool,
        content: ExperienceRuntimeExternalAssetContent
    ) {
        self.kind = kind
        self.riveAssetId = riveAssetId
        self.riveUniqueName = riveUniqueName
        self.sourceKey = sourceKey
        self.expectedSHA256 = expectedSHA256
        self.required = required
        self.content = content
    }
}

/// Selects the independent mutable runtime state owned by one live screen.
package struct ScreenSessionDescriptor: Equatable, Sendable {
    package let artboardName: String?
    package let stateMachineName: String?

    package init(
        artboardName: String? = nil,
        stateMachineName: String? = nil
    ) {
        self.artboardName = artboardName
        self.stateMachineName = stateMachineName
    }
}

/// App-clock time supplied to one coarse runtime advance operation.
package struct ExperienceRuntimeFrameTime: Equatable, Sendable {
    package let timestamp: TimeInterval
    package let delta: TimeInterval

    package init(timestamp: TimeInterval, delta: TimeInterval) {
        self.timestamp = timestamp
        self.delta = delta
    }
}

/// The single typed operation seam for one live experience session.
package enum ExperienceRuntimeOperation: Equatable, Sendable {
    case stateBatch(ExperienceRuntimeStateBatch)
    case textRunBatch(ExperienceRuntimeTextRunBatch)
    case pointerBatch([ExperienceRuntimePointerEvent])
    case advance(ExperienceRuntimeFrameTime)
    case advanceAndRender(ExperienceRuntimeFrameTime)
    case query([ExperienceRuntimeQuery])
}

/// Observable phases from the Nuxie runtime host contract.
///
/// Raw values are significant: a valid batch may stay in a phase or move
/// forward, but must never move backward.
package enum ExperienceRuntimeOutputPhase: Int, Equatable, Sendable {
    case delayedEventCallbacks
    case reportedEvents
    case runtimeAdvance
    case viewModelChanges
    case hostWork
    case render
}

/// The operation output families Swift will eventually translate into Nuxie
/// events, canonical-state changes, platform intents, and render work.
package enum ExperienceRuntimeOutputKind: Equatable, Sendable {
    case delayedEvent
    case reportedEvent
    case stateChange
    case viewModelChange
    case hostCommand
    case renderRequest
    case runtimeAdvanced
}

package struct ExperienceRuntimeOpenURL: Equatable, Sendable {
    package let url: String
    package let target: String

    package init(url: String, target: String) {
        self.url = url
        self.target = target
    }
}

package enum ExperienceRuntimeOutputPayload: Equatable, Sendable {
    case delayedEvent
    case reportedEvent(
        name: String?,
        eventType: UInt32,
        delay: TimeInterval,
        properties: [ExperienceRuntimeEventProperty],
        openURL: ExperienceRuntimeOpenURL?
    )
    case stateChange(ExperienceRuntimeStateChange)
    case viewModelChange(ExperienceRuntimeStateChange)
    case hostCommand(name: String, payload: ExperienceRuntimeHostValue)
    case renderRequest
    case runtimeAdvanced(delta: TimeInterval)

    package var kind: ExperienceRuntimeOutputKind {
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
package struct ExperienceRuntimeOutput: Equatable, Sendable {
    package let sequence: UInt64
    package let cycle: UInt64
    package let phase: ExperienceRuntimeOutputPhase
    package let payload: ExperienceRuntimeOutputPayload

    package var kind: ExperienceRuntimeOutputKind { payload.kind }

    package init(
        sequence: UInt64,
        cycle: UInt64,
        phase: ExperienceRuntimeOutputPhase,
        payload: ExperienceRuntimeOutputPayload
    ) {
        self.sequence = sequence
        self.cycle = cycle
        self.phase = phase
        self.payload = payload
    }

    /// Convenience retained for host fakes that only exercise ordering.
    package init(
        sequence: UInt64,
        cycle: UInt64 = 0,
        phase: ExperienceRuntimeOutputPhase,
        kind: ExperienceRuntimeOutputKind
    ) {
        let emptyChange = ExperienceRuntimeStateChange(
            instanceID: nil,
            path: "",
            value: nil,
            originMutationID: nil
        )
        let payload: ExperienceRuntimeOutputPayload = switch kind {
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
            .hostCommand(name: "", payload: .object(.empty))
        case .renderRequest:
            .renderRequest
        case .runtimeAdvanced:
            .runtimeAdvanced(delta: 0)
        }
        self.init(sequence: sequence, cycle: cycle, phase: phase, payload: payload)
    }
}

package struct ExperienceRuntimeDiagnostic: Equatable, Sendable {
    package enum Severity: Equatable, Sendable {
        case debug
        case warning
        case fatal
    }

    package let severity: Severity
    package let code: String
    package let message: String

    package init(severity: Severity, code: String, message: String) {
        self.severity = severity
        self.code = code
        self.message = message
    }
}

package struct ExperienceRuntimeImportResult: Equatable, Sendable {
    package let authenticatedKeyId: String
    package let diagnostics: [ExperienceRuntimeDiagnostic]

    package init(
        authenticatedKeyId: String,
        diagnostics: [ExperienceRuntimeDiagnostic]
    ) {
        self.authenticatedKeyId = authenticatedKeyId
        self.diagnostics = diagnostics
    }

    package func validateAuthorizationBinding(
        to request: ExperienceRuntimeImportRequest
    ) throws {
        guard !authenticatedKeyId.isEmpty else {
            throw ExperienceRuntimeHostError.authenticatedImportMissingEvidence(
                reportedKeyId: authenticatedKeyId
            )
        }
        guard request.candidateKeys.contains(where: {
            $0.keyId == authenticatedKeyId
        }) else {
            throw ExperienceRuntimeHostError.authenticatedImportKeyMismatch(
                selectedKeyId: request.candidateKeys.map(\.keyId).joined(separator: ","),
                reportedKeyId: authenticatedKeyId
            )
        }
    }
}

package enum ExperienceRuntimeRenderOutcome: Equatable, Sendable {
    case notRequested
    case presented
    case skipped
}

/// Exact Apple-surface outcome reported by the native runtime.
///
/// Keeping this separate from `ExperienceRuntimeRenderOutcome` preserves recovery
/// information without making callers interpret C enum values.
package enum ExperienceRuntimeSurfaceDisposition: Equatable, Sendable {
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

package struct ExperienceRuntimeSurfaceSize: Equatable, Sendable {
    package let pixelWidth: UInt32
    package let pixelHeight: UInt32

    package init(pixelWidth: UInt32, pixelHeight: UInt32) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

package enum ExperienceRuntimeAppleSurfacePolicy {
    package static let maximumDrawableCount = 2
}

/// A main-actor-owned presentation target. Swift configures this layer with the
/// native runtime's Metal device; Rust never borrows or mutates the layer.
@MainActor
package struct ExperienceRuntimeAppleSurfaceTarget {
    package let layer: CAMetalLayer
    package let size: ExperienceRuntimeSurfaceSize

    package init(layer: CAMetalLayer, size: ExperienceRuntimeSurfaceSize) {
        self.layer = layer
        self.size = size
    }
}

/// One drawable retained by Swift for exactly one asynchronous native frame.
/// Acquisition and all `CAMetalLayer` mutation stay on the main actor.
@MainActor
package struct ExperienceRuntimeAppleDrawableTarget {
    package let drawable: any CAMetalDrawable
    package let completion: ExperienceRuntimeDrawableCompletion

    package init(
        drawable: any CAMetalDrawable,
        onCompleted: @escaping @Sendable () -> Void = {}
    ) {
        self.drawable = drawable
        completion = ExperienceRuntimeDrawableCompletion(onCompleted: onCompleted)
    }

    package nonisolated func complete() {
        completion.complete()
    }
}

package final class ExperienceRuntimeDrawableCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var onCompleted: (@Sendable () -> Void)?

    package init(onCompleted: @escaping @Sendable () -> Void) {
        self.onCompleted = onCompleted
    }

    package func complete() {
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
package struct ExperienceRuntimeOperationResult: Equatable, Sendable {
    package let renderOutcome: ExperienceRuntimeRenderOutcome
    package let surfaceDisposition: ExperienceRuntimeSurfaceDisposition
    package let isDirty: Bool
    package let isSettled: Bool
    package let wakeAfter: TimeInterval?
    package let orderedOutputs: [ExperienceRuntimeOutput]
    package let diagnostics: [ExperienceRuntimeDiagnostic]
    package let bootstrap: ExperienceRuntimeBootstrap?
    package let values: ExperienceRuntimeValueArena?
    package let catalog: ExperienceRuntimeCatalog?
    package let playerInputs: [ExperienceRuntimePlayerInput]?
    package let createdInstances: [ExperienceRuntimeCreatedInstance]

    package init(
        renderOutcome: ExperienceRuntimeRenderOutcome,
        surfaceDisposition: ExperienceRuntimeSurfaceDisposition = .none,
        isDirty: Bool,
        isSettled: Bool,
        wakeAfter: TimeInterval? = nil,
        orderedOutputs: [ExperienceRuntimeOutput] = [],
        diagnostics: [ExperienceRuntimeDiagnostic] = [],
        bootstrap: ExperienceRuntimeBootstrap? = nil,
        values: ExperienceRuntimeValueArena? = nil,
        catalog: ExperienceRuntimeCatalog? = nil,
        playerInputs: [ExperienceRuntimePlayerInput]? = nil,
        createdInstances: [ExperienceRuntimeCreatedInstance] = []
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

package enum ScreenSessionReadiness: Equatable {
    case waitingForFirstResult
    case ready
}

package enum ExperienceRuntimeSurfaceState: Equatable {
    case attached
    case detached
    case disposed
}

package enum ExperienceRuntimeHostError: Error, Equatable {
    case disposedSession
    case disposedSurface
    case surfaceAlreadyAttached
    case surfaceNotAttached
    case surfaceNotDetached
    case recoverableSurface(ExperienceRuntimeSurfaceDisposition)
    case unrecoverableSurface(ExperienceRuntimeSurfaceDisposition)
    case outputSequenceDidNotIncrease(previous: UInt64, current: UInt64)
    case outputCycleRegressed(previous: UInt64, current: UInt64)
    case outputPhaseRegressed(previous: ExperienceRuntimeOutputPhase, current: ExperienceRuntimeOutputPhase)
    case sessionCreationMissingBootstrap
    case requiredFontRegistrationFailed(String)
    case authenticatedImportMissingEvidence(reportedKeyId: String)
    case authenticatedImportKeyMismatch(selectedKeyId: String, reportedKeyId: String)
}

/// Classifies adapter failures that prove a session cannot safely process a
/// later operation. Operation-local validation and lookup failures remain at
/// the requesting host control instead of poisoning the whole display lane.
package protocol ScreenSessionFailureDisposition: Error {
    var invalidatesSession: Bool { get }
}

/// Keeps the fail-closed operation policy shared by every Swift owner of the
/// serialized session lane. Only errors that explicitly classify themselves
/// as operation-local may permit later work to continue.
package func screenSessionOperationFailureInvalidatesSession(_ error: Error) -> Bool {
    if error is ExperienceRuntimeHostError { return true }
    return (error as? any ScreenSessionFailureDisposition)?
        .invalidatesSession ?? true
}

/// The only runtime implementation seam used by the Swift host.
///
/// The focused `NuxieRuntime` bridge files implement this protocol and are the
/// only small group that imports the binary module. Drivers enqueue work on the
/// runtime's serial worker and never call back into Swift reentrantly.
package protocol ExperienceRuntimeAdapter: AnyObject {
    @MainActor
    func makeContext(
        for request: ExperienceRuntimeImportRequest
    ) async throws -> ExperienceRuntimeContextDriverAttachment
}

package struct ExperienceRuntimeContextDriverAttachment {
    package let driver: any ExperienceRuntimeContextDriver
    package let importResult: ExperienceRuntimeImportResult

    package init(
        driver: any ExperienceRuntimeContextDriver,
        importResult: ExperienceRuntimeImportResult
    ) {
        self.driver = driver
        self.importResult = importResult
    }
}

package protocol ExperienceRuntimeContextDriver: AnyObject {
    @MainActor
    func makeSession(
        descriptor: ScreenSessionDescriptor
    ) async throws -> ScreenSessionDriverAttachment

    /// Thread-safe and nonblocking. The implementation may enqueue destruction.
    func dispose()
}

package struct ScreenSessionDriverAttachment {
    package let driver: any ScreenSessionDriver
    package let creationResult: ExperienceRuntimeOperationResult

    package init(
        driver: any ScreenSessionDriver,
        creationResult: ExperienceRuntimeOperationResult
    ) {
        self.driver = driver
        self.creationResult = creationResult
    }
}

package protocol ScreenSessionDriver: AnyObject {
    @MainActor
    func perform(
        _ operation: ExperienceRuntimeOperation,
        drawable: ExperienceRuntimeAppleDrawableTarget?
    ) async throws -> ExperienceRuntimeOperationResult

    @MainActor
    func attachAppleSurface(
        to target: ExperienceRuntimeAppleSurfaceTarget
    ) async throws -> ExperienceRuntimeSurfaceDriverAttachment

    /// Thread-safe and nonblocking. The implementation may enqueue destruction.
    func dispose()
}

package struct ExperienceRuntimeSurfaceDriverAttachment {
    package let driver: any ExperienceRuntimeSurfaceDriver
    package let result: ExperienceRuntimeOperationResult
    package let configurator: any ExperienceRuntimeAppleSurfaceConfigurator

    package init(
        driver: any ExperienceRuntimeSurfaceDriver,
        result: ExperienceRuntimeOperationResult,
        configurator: any ExperienceRuntimeAppleSurfaceConfigurator
    ) {
        self.driver = driver
        self.result = result
        self.configurator = configurator
    }
}

/// A reattach may recreate the native Metal device while preserving the
/// logical surface handle. Returning fresh configuration with the lifecycle
/// result keeps Swift's layer ownership synchronized with that new device.
package struct ExperienceRuntimeSurfaceDriverReattachment {
    package let result: ExperienceRuntimeOperationResult
    package let configurator: any ExperienceRuntimeAppleSurfaceConfigurator

    package init(
        result: ExperienceRuntimeOperationResult,
        configurator: any ExperienceRuntimeAppleSurfaceConfigurator
    ) {
        self.result = result
        self.configurator = configurator
    }
}

/// Main-actor layer setup supplied by the concrete runtime adapter.
/// A fake can implement this without importing the native binary module.
@MainActor
package protocol ExperienceRuntimeAppleSurfaceConfigurator: AnyObject {
    func configure(_ target: ExperienceRuntimeAppleSurfaceTarget)
    func unconfigure(_ target: ExperienceRuntimeAppleSurfaceTarget)
}

package protocol ExperienceRuntimeSurfaceDriver: AnyObject {
    @MainActor
    func resize(to size: ExperienceRuntimeSurfaceSize) async throws -> ExperienceRuntimeOperationResult

    @MainActor
    func detach() async throws -> ExperienceRuntimeOperationResult

    @MainActor
    func reattach(
        to target: ExperienceRuntimeAppleSurfaceTarget
    ) async throws -> ExperienceRuntimeSurfaceDriverReattachment

    /// Thread-safe and nonblocking. The implementation may enqueue destruction.
    func dispose()
}

/// Creates a fresh context for each presentation while hiding runtime-specific
/// handles and import details from the experience UI.
@MainActor
package final class ExperienceRuntimeContextFactory {
    private let adapter: any ExperienceRuntimeAdapter

    package init(adapter: any ExperienceRuntimeAdapter) {
        self.adapter = adapter
    }

    package func makeContext(for request: ExperienceRuntimeImportRequest) async throws -> ExperienceRuntimeContext {
        // Native import authenticates the exact package and asset identities.
        // Do not hand untrusted font bytes to CoreText before this succeeds.
        let attachment = try await adapter.makeContext(for: request)
        do {
            try attachment.importResult.validateAuthorizationBinding(to: request)
        } catch {
            attachment.driver.dispose()
            throw error
        }

        let fontScope = ExperienceRuntimeFontScope()
        do {
            for asset in request.externalAssets {
                guard asset.kind == .font,
                      case .bytes(let data) = asset.content else {
                    continue
                }
                guard ExperienceRuntimeFontRegistry.registerFont(
                    riveUniqueName: asset.riveUniqueName,
                    data: data,
                    in: fontScope
                ) != nil else {
                    guard !asset.required else {
                        throw ExperienceRuntimeHostError.requiredFontRegistrationFailed(
                            asset.riveUniqueName
                        )
                    }
                    continue
                }
            }
            return ExperienceRuntimeContext(
                driver: attachment.driver,
                importResult: attachment.importResult,
                fontScope: fontScope
            )
        } catch {
            fontScope.close()
            attachment.driver.dispose()
            throw error
        }
    }
}

/// Shared immutable/rebuildable runtime resources for one presentation.
///
/// A session retains this object, making it impossible for ARC to destroy the
/// native context while a child session is alive.
@MainActor
package final class ExperienceRuntimeContext {
    // nonisolated(unsafe): MainActor-confined; also read by deinit, which has
    // exclusive access to the last reference.
    private nonisolated(unsafe) let driver: any ExperienceRuntimeContextDriver
    private let fontScope: ExperienceRuntimeFontScope
    package let importResult: ExperienceRuntimeImportResult

    fileprivate init(
        driver: any ExperienceRuntimeContextDriver,
        importResult: ExperienceRuntimeImportResult,
        fontScope: ExperienceRuntimeFontScope
    ) {
        self.driver = driver
        self.importResult = importResult
        self.fontScope = fontScope
    }

    package func makeSession(descriptor: ScreenSessionDescriptor) async throws -> ScreenSession {
        let attachment = try await driver.makeSession(descriptor: descriptor)
        do {
            return try ScreenSession(
                context: self,
                driver: attachment.driver,
                creationResult: attachment.creationResult
            )
        } catch {
            attachment.driver.dispose()
            throw error
        }
    }

    deinit {
        driver.dispose()
        fontScope.close()
    }
}

/// Independent mutable runtime state for one live experience screen.
@MainActor
package final class ScreenSession {
    private var context: ExperienceRuntimeContext?
    // nonisolated(unsafe): MainActor-confined; also read by deinit, which has
    // exclusive access to the last reference.
    private nonisolated(unsafe) var driver: (any ScreenSessionDriver)?
    private weak var surface: ScreenRenderSurface?
    private var lastOutputSequence: UInt64?
    private var lastOutputCycle: UInt64?
    private var lastOutputPhase: ExperienceRuntimeOutputPhase?

    package let bootstrap: ExperienceRuntimeBootstrap
    package let creationResult: ExperienceRuntimeOperationResult
    package private(set) var readiness: ScreenSessionReadiness = .waitingForFirstResult

    fileprivate init(
        context: ExperienceRuntimeContext,
        driver: any ScreenSessionDriver,
        creationResult: ExperienceRuntimeOperationResult
    ) throws {
        guard let bootstrap = creationResult.bootstrap else {
            throw ExperienceRuntimeHostError.sessionCreationMissingBootstrap
        }
        self.context = context
        self.driver = driver
        self.bootstrap = bootstrap
        self.creationResult = creationResult
        try validateOutputOrder(creationResult.orderedOutputs)
    }

    package func perform(
        _ operation: ExperienceRuntimeOperation,
        drawable: ExperienceRuntimeAppleDrawableTarget? = nil
    ) async throws -> ExperienceRuntimeOperationResult {
        guard let driver else {
            throw ExperienceRuntimeHostError.disposedSession
        }

        let result = try await driver.perform(operation, drawable: drawable)
        switch result.surfaceDisposition {
        case .deviceLost:
            // Native device-loss recovery is transactional: no authored
            // advance or output is committed. Reject the result before it can
            // mutate Swift's cross-operation ordering state.
            //
            // The concrete runtime reports device loss only from render
            // preflight. Enforce that contract here: treating a non-render
            // mutation as recoverable would complete its request with an error
            // while leaving higher-level state queues waiting for a terminal
            // callback that never arrives.
            guard case .advanceAndRender = operation else {
                throw ExperienceRuntimeHostError.unrecoverableSurface(.deviceLost)
            }
            throw ExperienceRuntimeHostError.recoverableSurface(.deviceLost)
        case .outOfMemory, .fatal, .unknown:
            throw ExperienceRuntimeHostError.unrecoverableSurface(result.surfaceDisposition)
        case .none, .presented, .skippedZeroSize, .skippedTimeout,
             .skippedOccluded, .reconfigured, .recreated:
            break
        }
        try validateOutputOrder(result.orderedOutputs)
        if result.renderOutcome == .presented {
            readiness = .ready
        }
        return result
    }

    package func attachAppleSurface(
        to target: ExperienceRuntimeAppleSurfaceTarget
    ) async throws -> ScreenRenderSurface {
        guard let driver else {
            throw ExperienceRuntimeHostError.disposedSession
        }
        guard surface == nil else {
            throw ExperienceRuntimeHostError.surfaceAlreadyAttached
        }

        let attachment = try await driver.attachAppleSurface(to: target)
        let surface = ScreenRenderSurface(
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
    package func dispose() {
        guard let driver else { return }
        surface?.dispose()
        self.driver = nil
        driver.dispose()
        context = nil
    }

    deinit {
        driver?.dispose()
    }

    private func validateOutputOrder(_ outputs: [ExperienceRuntimeOutput]) throws {
        var previousSequence = lastOutputSequence
        var previousCycle = lastOutputCycle
        var previousPhase = lastOutputPhase

        for current in outputs {
            if let previousSequence, current.sequence <= previousSequence {
                throw ExperienceRuntimeHostError.outputSequenceDidNotIncrease(
                    previous: previousSequence,
                    current: current.sequence
                )
            }

            if let previousCycle, current.cycle < previousCycle {
                throw ExperienceRuntimeHostError.outputCycleRegressed(
                    previous: previousCycle,
                    current: current.cycle
                )
            }

            if previousCycle == current.cycle,
               let previousPhase,
               current.phase.rawValue < previousPhase.rawValue {
                throw ExperienceRuntimeHostError.outputPhaseRegressed(
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

    fileprivate func releaseSurface(_ surface: ScreenRenderSurface) {
        if self.surface === surface {
            self.surface = nil
        }
    }
}

/// Prevents stale deferred teardown from unconfiguring a newer owner of the
/// same CAMetalLayer. The weak-key registry never extends the layer lifetime.
@MainActor
package final class ExperienceRuntimeSurfaceConfigurationOwner {
    private static let owners = NSMapTable<
        CAMetalLayer,
        ExperienceRuntimeSurfaceConfigurationOwner
    >.weakToWeakObjects()

    package func configure(
        _ target: ExperienceRuntimeAppleSurfaceTarget,
        with configurator: any ExperienceRuntimeAppleSurfaceConfigurator
    ) {
        Self.owners.setObject(self, forKey: target.layer)
        configurator.configure(target)
    }

    package func unconfigureIfOwned(
        _ target: ExperienceRuntimeAppleSurfaceTarget,
        with configurator: any ExperienceRuntimeAppleSurfaceConfigurator
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
package final class ExperienceRuntimeSurfaceDrawableTracker {
    private var inFlightCount = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var idleActions: [@MainActor () -> Void] = []

    package func beginFrame() {
        inFlightCount += 1
    }

    package func completeFrame() {
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

    package func waitUntilIdle() async {
        guard inFlightCount > 0 else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    package func whenIdle(_ action: @escaping @MainActor () -> Void) {
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
package final class ScreenRenderSurface {
    private var session: ScreenSession?
    // nonisolated(unsafe): MainActor-confined; also read by deinit, which has
    // exclusive access to the last reference.
    private nonisolated(unsafe) var driver: (any ExperienceRuntimeSurfaceDriver)?
    // nonisolated(unsafe): MainActor-confined; also read by deinit (see above).
    private nonisolated(unsafe) var configurator: any ExperienceRuntimeAppleSurfaceConfigurator
    private let configurationOwner = ExperienceRuntimeSurfaceConfigurationOwner()
    private let drawableTracker = ExperienceRuntimeSurfaceDrawableTracker()
    private var target: ExperienceRuntimeAppleSurfaceTarget?

    package let attachmentResult: ExperienceRuntimeOperationResult
    package private(set) var state: ExperienceRuntimeSurfaceState = .attached

    fileprivate init(
        session: ScreenSession,
        driver: any ExperienceRuntimeSurfaceDriver,
        attachmentResult: ExperienceRuntimeOperationResult,
        configurator: any ExperienceRuntimeAppleSurfaceConfigurator,
        target: ExperienceRuntimeAppleSurfaceTarget
    ) {
        self.session = session
        self.driver = driver
        self.attachmentResult = attachmentResult
        self.configurator = configurator
        self.target = target
        configurationOwner.configure(target, with: configurator)
    }

    package func resize(to size: ExperienceRuntimeSurfaceSize) async throws -> ExperienceRuntimeOperationResult {
        guard let driver else {
            throw ExperienceRuntimeHostError.disposedSurface
        }
        guard state == .attached else {
            throw ExperienceRuntimeHostError.surfaceNotAttached
        }
        let result = try await driver.resize(to: size)
        guard let target else {
            throw ExperienceRuntimeHostError.surfaceNotAttached
        }
        let resizedTarget = ExperienceRuntimeAppleSurfaceTarget(layer: target.layer, size: size)
        configurationOwner.configure(resizedTarget, with: configurator)
        self.target = resizedTarget
        return result
    }

    package func detach() async throws -> ExperienceRuntimeOperationResult {
        guard let driver else {
            throw ExperienceRuntimeHostError.disposedSurface
        }
        guard state == .attached else {
            throw ExperienceRuntimeHostError.surfaceNotAttached
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

    package func reattach(
        to target: ExperienceRuntimeAppleSurfaceTarget
    ) async throws -> ExperienceRuntimeOperationResult {
        guard let driver else {
            throw ExperienceRuntimeHostError.disposedSurface
        }
        guard state == .detached else {
            throw ExperienceRuntimeHostError.surfaceNotDetached
        }

        let attachment = try await driver.reattach(to: target)
        configurator = attachment.configurator
        configurationOwner.configure(target, with: attachment.configurator)
        self.target = target
        state = .attached
        return attachment.result
    }

    package func dispose() {
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

    package func makeDrawableTarget(
        _ drawable: any CAMetalDrawable,
        onCompleted: @escaping @Sendable () -> Void
    ) -> ExperienceRuntimeAppleDrawableTarget {
        drawableTracker.beginFrame()
        let drawableTracker = drawableTracker
        return ExperienceRuntimeAppleDrawableTarget(drawable: drawable) {
            onCompleted()
            Task { @MainActor in
                drawableTracker.completeFrame()
            }
        }
    }
}
