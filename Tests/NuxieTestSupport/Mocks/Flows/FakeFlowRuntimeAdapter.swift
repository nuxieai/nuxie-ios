import Foundation
@testable import Nuxie

enum FakeFlowRuntimeLifecycleEvent: Equatable {
    case surfaceAttached(FlowRuntimeSurfaceSize)
    case surfaceResized(FlowRuntimeSurfaceSize)
    case surfaceDetached
    case surfaceReattached(FlowRuntimeSurfaceSize)
    case surfaceDisposed
    case sessionDisposed
    case contextDisposed
}

final class FakeFlowRuntimeLifecycleRecorder {
    private let lock = NSLock()
    private var recordedEvents: [FakeFlowRuntimeLifecycleEvent] = []

    var events: [FakeFlowRuntimeLifecycleEvent] {
        lock.withLock { recordedEvents }
    }

    func record(_ event: FakeFlowRuntimeLifecycleEvent) {
        lock.withLock {
            recordedEvents.append(event)
        }
    }
}

final class FakeFlowRuntimeAdapter {
    private let operationResults: [Result<FlowRuntimeOperationResult, Error>]
    private let importResult: FlowRuntimeImportResult
    private let bootstrap: FlowRuntimeBootstrap
    private let surfaceAttachmentGate: FakeFlowRuntimeSurfaceAttachmentGate?
    private let drawableCompletionGate: FakeFlowRuntimeDrawableCompletionGate?

    let lifecycleRecorder: FakeFlowRuntimeLifecycleRecorder
    @MainActor private(set) var contextDrivers: [FakeFlowRuntimeContextDriver] = []
    @MainActor private(set) var importRequests: [FlowRuntimeImportRequest] = []

    init(
        operationResults: [Result<FlowRuntimeOperationResult, Error>],
        importResult: FlowRuntimeImportResult = .visualOnly,
        bootstrap: FlowRuntimeBootstrap = .fake,
        lifecycleRecorder: FakeFlowRuntimeLifecycleRecorder = FakeFlowRuntimeLifecycleRecorder(),
        surfaceAttachmentGate: FakeFlowRuntimeSurfaceAttachmentGate? = nil,
        drawableCompletionGate: FakeFlowRuntimeDrawableCompletionGate? = nil
    ) {
        self.operationResults = operationResults
        self.importResult = importResult
        self.bootstrap = bootstrap
        self.lifecycleRecorder = lifecycleRecorder
        self.surfaceAttachmentGate = surfaceAttachmentGate
        self.drawableCompletionGate = drawableCompletionGate
    }

    @MainActor
    func makeContext(
        for request: FlowRuntimeImportRequest
    ) async throws -> FlowRuntimeContextDriverAttachment {
        let driver = FakeFlowRuntimeContextDriver(
            operationResults: operationResults,
            bootstrap: bootstrap,
            lifecycleRecorder: lifecycleRecorder,
            surfaceAttachmentGate: surfaceAttachmentGate,
            drawableCompletionGate: drawableCompletionGate
        )
        importRequests.append(request)
        contextDrivers.append(driver)
        return FlowRuntimeContextDriverAttachment(
            driver: driver,
            importResult: importResult
        )
    }
}

final class FakeFlowRuntimeContextDriver {
    private let operationResults: [Result<FlowRuntimeOperationResult, Error>]
    private let lifecycleRecorder: FakeFlowRuntimeLifecycleRecorder
    private let bootstrap: FlowRuntimeBootstrap
    private let surfaceAttachmentGate: FakeFlowRuntimeSurfaceAttachmentGate?
    private let drawableCompletionGate: FakeFlowRuntimeDrawableCompletionGate?
    private let disposal = FakeFlowRuntimeDisposal()

    @MainActor private(set) var sessionDescriptors: [FlowRenderSessionDescriptor] = []
    @MainActor private(set) var sessionDrivers: [FakeFlowRenderSessionDriver] = []

    init(
        operationResults: [Result<FlowRuntimeOperationResult, Error>],
        bootstrap: FlowRuntimeBootstrap,
        lifecycleRecorder: FakeFlowRuntimeLifecycleRecorder,
        surfaceAttachmentGate: FakeFlowRuntimeSurfaceAttachmentGate?,
        drawableCompletionGate: FakeFlowRuntimeDrawableCompletionGate?
    ) {
        self.operationResults = operationResults
        self.bootstrap = bootstrap
        self.lifecycleRecorder = lifecycleRecorder
        self.surfaceAttachmentGate = surfaceAttachmentGate
        self.drawableCompletionGate = drawableCompletionGate
    }

    @MainActor
    func makeSession(
        descriptor: FlowRenderSessionDescriptor
    ) async throws -> FlowRuntimeSessionDriverAttachment {
        let driver = FakeFlowRenderSessionDriver(
            operationResults: operationResults,
            lifecycleRecorder: lifecycleRecorder,
            surfaceAttachmentGate: surfaceAttachmentGate,
            drawableCompletionGate: drawableCompletionGate
        )
        sessionDescriptors.append(descriptor)
        sessionDrivers.append(driver)
        return FlowRuntimeSessionDriverAttachment(
            driver: driver,
            bootstrap: bootstrap
        )
    }

    func dispose() {
        disposal.runOnce {
            lifecycleRecorder.record(.contextDisposed)
        }
    }
}

final class FakeFlowRenderSessionDriver {
    private var operationResults: [Result<FlowRuntimeOperationResult, Error>]
    private let lifecycleRecorder: FakeFlowRuntimeLifecycleRecorder
    private let surfaceAttachmentGate: FakeFlowRuntimeSurfaceAttachmentGate?
    private let drawableCompletionGate: FakeFlowRuntimeDrawableCompletionGate?
    private let disposal = FakeFlowRuntimeDisposal()

    @MainActor private(set) var performedOperations: [FlowRuntimeOperation] = []
    @MainActor private(set) var performedWithDrawable: [Bool] = []
    @MainActor private(set) var surfaceDrivers: [FakeFlowRuntimeSurfaceDriver] = []
    @MainActor private(set) var surfaceConfigurators: [FakeFlowRuntimeAppleSurfaceConfigurator] = []

    init(
        operationResults: [Result<FlowRuntimeOperationResult, Error>],
        lifecycleRecorder: FakeFlowRuntimeLifecycleRecorder,
        surfaceAttachmentGate: FakeFlowRuntimeSurfaceAttachmentGate?,
        drawableCompletionGate: FakeFlowRuntimeDrawableCompletionGate?
    ) {
        self.operationResults = operationResults
        self.lifecycleRecorder = lifecycleRecorder
        self.surfaceAttachmentGate = surfaceAttachmentGate
        self.drawableCompletionGate = drawableCompletionGate
    }

    @MainActor
    func perform(
        _ operation: FlowRuntimeOperation,
        drawable: FlowRuntimeAppleDrawableTarget?
    ) async throws -> FlowRuntimeOperationResult {
        let completesDrawableSynchronously = drawableCompletionGate == nil
        defer {
            if completesDrawableSynchronously {
                drawable?.complete()
            }
        }
        drawableCompletionGate?.retain(drawable)
        performedOperations.append(operation)
        performedWithDrawable.append(drawable != nil)
        guard !operationResults.isEmpty else {
            throw FakeFlowRuntimeError.noOperationResult
        }
        return try operationResults.removeFirst().get()
    }

    @MainActor
    func attachAppleSurface(
        to target: FlowRuntimeAppleSurfaceTarget
    ) async throws -> FlowRuntimeSurfaceDriverAttachment {
        await surfaceAttachmentGate?.waitBeforeAttaching()
        let driver = FakeFlowRuntimeSurfaceDriver(
            initialTarget: target,
            lifecycleRecorder: lifecycleRecorder
        )
        let configurator = FakeFlowRuntimeAppleSurfaceConfigurator()
        surfaceDrivers.append(driver)
        surfaceConfigurators.append(configurator)
        lifecycleRecorder.record(.surfaceAttached(target.size))
        return FlowRuntimeSurfaceDriverAttachment(
            driver: driver,
            result: FlowRuntimeOperationResult(
                renderOutcome: .notRequested,
                surfaceDisposition: .recreated,
                isDirty: false,
                isSettled: true
            ),
            configurator: configurator
        )
    }

    func dispose() {
        disposal.runOnce {
            lifecycleRecorder.record(.sessionDisposed)
        }
    }
}

final class FakeFlowRuntimeSurfaceDriver {
    private let lifecycleRecorder: FakeFlowRuntimeLifecycleRecorder
    private let disposal = FakeFlowRuntimeDisposal()

    @MainActor private(set) var target: FlowRuntimeAppleSurfaceTarget?

    @MainActor
    init(
        initialTarget: FlowRuntimeAppleSurfaceTarget,
        lifecycleRecorder: FakeFlowRuntimeLifecycleRecorder
    ) {
        target = initialTarget
        self.lifecycleRecorder = lifecycleRecorder
    }

    @MainActor
    func resize(to size: FlowRuntimeSurfaceSize) async throws -> FlowRuntimeOperationResult {
        guard let currentTarget = target else {
            throw FakeFlowRuntimeError.surfaceDetached
        }
        target = FlowRuntimeAppleSurfaceTarget(layer: currentTarget.layer, size: size)
        lifecycleRecorder.record(.surfaceResized(size))
        return surfaceResult(disposition: .reconfigured)
    }

    @MainActor
    func detach() async throws -> FlowRuntimeOperationResult {
        guard target != nil else {
            throw FakeFlowRuntimeError.surfaceDetached
        }
        target = nil
        lifecycleRecorder.record(.surfaceDetached)
        return surfaceResult(disposition: .none)
    }

    @MainActor
    func reattach(
        to target: FlowRuntimeAppleSurfaceTarget
    ) async throws -> FlowRuntimeOperationResult {
        guard self.target == nil else {
            throw FakeFlowRuntimeError.surfaceAttached
        }
        self.target = target
        lifecycleRecorder.record(.surfaceReattached(target.size))
        return surfaceResult(disposition: .recreated)
    }

    func dispose() {
        disposal.runOnce {
            lifecycleRecorder.record(.surfaceDisposed)
        }
    }

    private func surfaceResult(
        disposition: FlowRuntimeSurfaceDisposition
    ) -> FlowRuntimeOperationResult {
        FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            surfaceDisposition: disposition,
            isDirty: false,
            isSettled: true
        )
    }
}

@MainActor
final class FakeFlowRuntimeAppleSurfaceConfigurator:
    FlowRuntimeAppleSurfaceConfigurator {
    private(set) var configuredSizes: [FlowRuntimeSurfaceSize] = []
    private(set) var unconfiguredSizes: [FlowRuntimeSurfaceSize] = []

    func configure(_ target: FlowRuntimeAppleSurfaceTarget) {
        configuredSizes.append(target.size)
    }

    func unconfigure(_ target: FlowRuntimeAppleSurfaceTarget) {
        unconfiguredSizes.append(target.size)
    }
}

extension FakeFlowRuntimeAdapter: FlowRuntimeAdapter {}
extension FakeFlowRuntimeContextDriver: FlowRuntimeContextDriver {}
extension FakeFlowRenderSessionDriver: FlowRenderSessionDriver {}
extension FakeFlowRuntimeSurfaceDriver: FlowRuntimeSurfaceDriver {}

extension FlowRuntimeBootstrap {
    static let fake = FlowRuntimeBootstrap(
        player: FlowRuntimePlayerMetadata(
            kind: .staticArtboard,
            selection: .staticArtboard,
            index: nil,
            artboardName: nil,
            playerName: nil,
            bounds: FlowRuntimeArtboardBounds(
                minX: 0,
                minY: 0,
                maxX: 1,
                maxY: 1
            )
        ),
        catalog: FlowRuntimeCatalog(schemas: [], templates: [], instances: []),
        values: .empty
    )
}

@MainActor
final class FakeFlowRuntimeSurfaceAttachmentGate {
    private var attachmentContinuation: CheckedContinuation<Void, Never>?
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    func waitBeforeAttaching() async {
        await withCheckedContinuation { continuation in
            attachmentContinuation = continuation
            let waiters = waitingContinuations
            waitingContinuations.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilAttachmentIsSuspended() async {
        guard attachmentContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }

    func resumeAttachment() {
        let continuation = attachmentContinuation
        attachmentContinuation = nil
        continuation?.resume()
    }
}

@MainActor
final class FakeFlowRuntimeDrawableCompletionGate {
    private var retainedDrawables: [FlowRuntimeAppleDrawableTarget] = []
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    func retain(_ drawable: FlowRuntimeAppleDrawableTarget?) {
        guard let drawable else { return }
        retainedDrawables.append(drawable)
        let waiters = waitingContinuations
        waitingContinuations.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilDrawableIsRetained() async {
        guard retainedDrawables.isEmpty else { return }
        await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }

    func completeAll() {
        let drawables = retainedDrawables
        retainedDrawables.removeAll()
        drawables.forEach { $0.complete() }
    }
}

private enum FakeFlowRuntimeError: Error {
    case noOperationResult
    case surfaceAttached
    case surfaceDetached
}

private final class FakeFlowRuntimeDisposal {
    private let lock = NSLock()
    private var hasRun = false

    func runOnce(_ operation: () -> Void) {
        lock.withLock {
            guard !hasRun else { return }
            hasRun = true
            operation()
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
