import Foundation
import Metal
import QuartzCore

/// Container-neutral bytes used to create one runtime context for a flow presentation.
///
/// Asset and trust evidence will be added here when the artifact adapter moves in
/// Slice 2. The runtime-facing API deliberately has no knowledge of `.riv` paths,
/// manifests, CDN URLs, or the future `.nux` container.
struct FlowRuntimeImportRequest: Equatable, Sendable {
    let artifactBytes: Data
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

/// Coarse operations supported by the initial visual-rendering tracer.
///
/// Typed state, pointer, and text operations can be added without exposing the
/// runtime's object graph to the rest of the SDK.
enum FlowRuntimeOperation: Equatable, Sendable {
    case advance(FlowRuntimeFrameTime)
    case advanceAndRender(FlowRuntimeFrameTime)
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
}

/// One phase-tagged item in the exact order returned by the runtime.
struct FlowRuntimeOutput: Equatable, Sendable {
    let sequence: UInt64
    let phase: FlowRuntimeOutputPhase
    let kind: FlowRuntimeOutputKind
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

    init(
        renderOutcome: FlowRuntimeRenderOutcome,
        surfaceDisposition: FlowRuntimeSurfaceDisposition = .none,
        isDirty: Bool,
        isSettled: Bool,
        wakeAfter: TimeInterval? = nil,
        orderedOutputs: [FlowRuntimeOutput] = [],
        diagnostics: [FlowRuntimeDiagnostic] = []
    ) {
        self.renderOutcome = renderOutcome
        self.surfaceDisposition = surfaceDisposition
        self.isDirty = isDirty
        self.isSettled = isSettled
        self.wakeAfter = wakeAfter
        self.orderedOutputs = orderedOutputs
        self.diagnostics = diagnostics
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
    case outputPhaseRegressed(previous: FlowRuntimeOutputPhase, current: FlowRuntimeOutputPhase)
}

/// The only runtime implementation seam used by the Swift host.
///
/// `NuxieRuntimeAdapter` will implement this protocol and will be the sole file
/// that imports the binary module. Drivers enqueue work on the runtime's serial
/// worker and never call back into Swift reentrantly.
protocol FlowRuntimeAdapter: AnyObject {
    @MainActor
    func makeContext(for request: FlowRuntimeImportRequest) async throws -> any FlowRuntimeContextDriver
}

protocol FlowRuntimeContextDriver: AnyObject {
    @MainActor
    func makeSession(
        descriptor: FlowRenderSessionDescriptor
    ) async throws -> any FlowRenderSessionDriver

    /// Thread-safe and nonblocking. The implementation may enqueue destruction.
    func dispose()
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
        let driver = try await adapter.makeContext(for: request)
        return FlowRuntimeContext(driver: driver)
    }
}

/// Shared immutable/rebuildable runtime resources for one presentation.
///
/// A session retains this object, making it impossible for ARC to destroy the
/// native context while a child session is alive.
@MainActor
final class FlowRuntimeContext {
    private let driver: any FlowRuntimeContextDriver

    fileprivate init(driver: any FlowRuntimeContextDriver) {
        self.driver = driver
    }

    func makeSession(descriptor: FlowRenderSessionDescriptor) async throws -> FlowRenderSession {
        let sessionDriver = try await driver.makeSession(descriptor: descriptor)
        return FlowRenderSession(context: self, driver: sessionDriver)
    }

    deinit {
        driver.dispose()
    }
}

/// Independent mutable runtime state for one live flow screen.
@MainActor
final class FlowRenderSession {
    private var context: FlowRuntimeContext?
    private var driver: (any FlowRenderSessionDriver)?
    private weak var surface: FlowRenderSurface?
    private var lastOutputSequence: UInt64?

    private(set) var readiness: FlowRuntimeSessionReadiness = .waitingForFirstResult

    fileprivate init(
        context: FlowRuntimeContext,
        driver: any FlowRenderSessionDriver
    ) {
        self.context = context
        self.driver = driver
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
        var previousPhase: FlowRuntimeOutputPhase?

        for current in outputs {
            if let previousSequence, current.sequence <= previousSequence {
                throw FlowRuntimeHostError.outputSequenceDidNotIncrease(
                    previous: previousSequence,
                    current: current.sequence
                )
            }

            if let previousPhase, current.phase.rawValue < previousPhase.rawValue {
                throw FlowRuntimeHostError.outputPhaseRegressed(
                    previous: previousPhase,
                    current: current.phase
                )
            }

            previousSequence = current.sequence
            previousPhase = current.phase
        }

        if let sequence = outputs.last?.sequence {
            lastOutputSequence = sequence
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
