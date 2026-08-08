import Foundation
import NuxieRuntimeSupport
@testable import Nuxie

enum FakeExperienceRuntimeLifecycleEvent: Equatable {
    case surfaceAttached(ExperienceRuntimeSurfaceSize)
    case surfaceResized(ExperienceRuntimeSurfaceSize)
    case surfaceDetached
    case surfaceReattached(ExperienceRuntimeSurfaceSize)
    case surfaceDisposed
    case sessionDisposed
    case contextDisposed
}

final class FakeExperienceRuntimeLifecycleRecorder {
    private let lock = NSLock()
    private var recordedEvents: [FakeExperienceRuntimeLifecycleEvent] = []

    var events: [FakeExperienceRuntimeLifecycleEvent] {
        lock.withLock { recordedEvents }
    }

    func record(_ event: FakeExperienceRuntimeLifecycleEvent) {
        lock.withLock {
            recordedEvents.append(event)
        }
    }
}

final class FakeExperienceRuntimeAdapter {
    private let operationResults: [Result<ExperienceRuntimeOperationResult, Error>]
    private let operationResultsBySession: [
        [Result<ExperienceRuntimeOperationResult, Error>]
    ]?
    private let importResult: ExperienceRuntimeImportResult
    private let creationResult: ExperienceRuntimeOperationResult
    private let surfaceAttachmentGate: FakeExperienceRuntimeSurfaceAttachmentGate?
    private let surfaceDetachmentGate: FakeExperienceRuntimeSurfaceDetachmentGate?
    private let drawableCompletionGate: FakeExperienceRuntimeDrawableCompletionGate?

    let lifecycleRecorder: FakeExperienceRuntimeLifecycleRecorder
    @MainActor private(set) var contextDrivers: [FakeExperienceRuntimeContextDriver] = []
    @MainActor private(set) var importRequests: [ExperienceRuntimeImportRequest] = []

    init(
        operationResults: [Result<ExperienceRuntimeOperationResult, Error>],
        operationResultsBySession: [
            [Result<ExperienceRuntimeOperationResult, Error>]
        ]? = nil,
        importResult: ExperienceRuntimeImportResult = ExperienceRuntimeImportResult(
            authenticatedKeyId: "test-key",
            diagnostics: []
        ),
        bootstrap: ExperienceRuntimeBootstrap = .fake,
        creationResult: ExperienceRuntimeOperationResult? = nil,
        lifecycleRecorder: FakeExperienceRuntimeLifecycleRecorder = FakeExperienceRuntimeLifecycleRecorder(),
        surfaceAttachmentGate: FakeExperienceRuntimeSurfaceAttachmentGate? = nil,
        surfaceDetachmentGate: FakeExperienceRuntimeSurfaceDetachmentGate? = nil,
        drawableCompletionGate: FakeExperienceRuntimeDrawableCompletionGate? = nil
    ) {
        self.operationResults = operationResults
        self.operationResultsBySession = operationResultsBySession
        self.importResult = importResult
        self.creationResult = creationResult ?? ExperienceRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: false,
            bootstrap: bootstrap
        )
        self.lifecycleRecorder = lifecycleRecorder
        self.surfaceAttachmentGate = surfaceAttachmentGate
        self.surfaceDetachmentGate = surfaceDetachmentGate
        self.drawableCompletionGate = drawableCompletionGate
    }

    @MainActor
    func makeContext(
        for request: ExperienceRuntimeImportRequest
    ) async throws -> ExperienceRuntimeContextDriverAttachment {
        let driver = FakeExperienceRuntimeContextDriver(
            operationResults: operationResults,
            operationResultsBySession: operationResultsBySession,
            creationResult: creationResult,
            lifecycleRecorder: lifecycleRecorder,
            surfaceAttachmentGate: surfaceAttachmentGate,
            surfaceDetachmentGate: surfaceDetachmentGate,
            drawableCompletionGate: drawableCompletionGate
        )
        importRequests.append(request)
        contextDrivers.append(driver)
        return ExperienceRuntimeContextDriverAttachment(
            driver: driver,
            importResult: importResult
        )
    }
}

final class FakeExperienceRuntimeContextDriver {
    private let operationResults: [Result<ExperienceRuntimeOperationResult, Error>]
    private let operationResultsBySession: [
        [Result<ExperienceRuntimeOperationResult, Error>]
    ]?
    private let lifecycleRecorder: FakeExperienceRuntimeLifecycleRecorder
    private let creationResult: ExperienceRuntimeOperationResult
    private let surfaceAttachmentGate: FakeExperienceRuntimeSurfaceAttachmentGate?
    private let surfaceDetachmentGate: FakeExperienceRuntimeSurfaceDetachmentGate?
    private let drawableCompletionGate: FakeExperienceRuntimeDrawableCompletionGate?
    private let disposal = FakeExperienceRuntimeDisposal()

    @MainActor private(set) var sessionDescriptors: [ScreenSessionDescriptor] = []
    @MainActor private(set) var sessionDrivers: [FakeScreenSessionDriver] = []

    init(
        operationResults: [Result<ExperienceRuntimeOperationResult, Error>],
        operationResultsBySession: [
            [Result<ExperienceRuntimeOperationResult, Error>]
        ]?,
        creationResult: ExperienceRuntimeOperationResult,
        lifecycleRecorder: FakeExperienceRuntimeLifecycleRecorder,
        surfaceAttachmentGate: FakeExperienceRuntimeSurfaceAttachmentGate?,
        surfaceDetachmentGate: FakeExperienceRuntimeSurfaceDetachmentGate?,
        drawableCompletionGate: FakeExperienceRuntimeDrawableCompletionGate?
    ) {
        self.operationResults = operationResults
        self.operationResultsBySession = operationResultsBySession
        self.creationResult = creationResult
        self.lifecycleRecorder = lifecycleRecorder
        self.surfaceAttachmentGate = surfaceAttachmentGate
        self.surfaceDetachmentGate = surfaceDetachmentGate
        self.drawableCompletionGate = drawableCompletionGate
    }

    @MainActor
    func makeSession(
        descriptor: ScreenSessionDescriptor
    ) async throws -> ScreenSessionDriverAttachment {
        let sessionIndex = sessionDrivers.count
        let sessionOperationResults: [Result<ExperienceRuntimeOperationResult, Error>]
        if let operationResultsBySession,
           operationResultsBySession.indices.contains(sessionIndex) {
            sessionOperationResults = operationResultsBySession[sessionIndex]
        } else {
            sessionOperationResults = operationResults
        }
        let driver = FakeScreenSessionDriver(
            operationResults: sessionOperationResults,
            lifecycleRecorder: lifecycleRecorder,
            surfaceAttachmentGate: surfaceAttachmentGate,
            surfaceDetachmentGate: surfaceDetachmentGate,
            drawableCompletionGate: drawableCompletionGate
        )
        sessionDescriptors.append(descriptor)
        sessionDrivers.append(driver)
        return ScreenSessionDriverAttachment(
            driver: driver,
            creationResult: creationResult
        )
    }

    func dispose() {
        disposal.runOnce {
            lifecycleRecorder.record(.contextDisposed)
        }
    }
}

final class FakeScreenSessionDriver {
    private var operationResults: [Result<ExperienceRuntimeOperationResult, Error>]
    private let lifecycleRecorder: FakeExperienceRuntimeLifecycleRecorder
    private let surfaceAttachmentGate: FakeExperienceRuntimeSurfaceAttachmentGate?
    private let surfaceDetachmentGate: FakeExperienceRuntimeSurfaceDetachmentGate?
    private let drawableCompletionGate: FakeExperienceRuntimeDrawableCompletionGate?
    private let disposal = FakeExperienceRuntimeDisposal()

    @MainActor private(set) var performedOperations: [ExperienceRuntimeOperation] = []
    @MainActor private(set) var performedWithDrawable: [Bool] = []
    @MainActor private(set) var surfaceDrivers: [FakeExperienceRuntimeSurfaceDriver] = []
    @MainActor private(set) var surfaceConfigurators: [FakeExperienceRuntimeAppleSurfaceConfigurator] = []

    init(
        operationResults: [Result<ExperienceRuntimeOperationResult, Error>],
        lifecycleRecorder: FakeExperienceRuntimeLifecycleRecorder,
        surfaceAttachmentGate: FakeExperienceRuntimeSurfaceAttachmentGate?,
        surfaceDetachmentGate: FakeExperienceRuntimeSurfaceDetachmentGate?,
        drawableCompletionGate: FakeExperienceRuntimeDrawableCompletionGate?
    ) {
        self.operationResults = operationResults
        self.lifecycleRecorder = lifecycleRecorder
        self.surfaceAttachmentGate = surfaceAttachmentGate
        self.surfaceDetachmentGate = surfaceDetachmentGate
        self.drawableCompletionGate = drawableCompletionGate
    }

    @MainActor
    func perform(
        _ operation: ExperienceRuntimeOperation,
        drawable: ExperienceRuntimeAppleDrawableTarget?
    ) async throws -> ExperienceRuntimeOperationResult {
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
            throw FakeExperienceRuntimeError.noOperationResult
        }
        return try operationResults.removeFirst().get()
    }

    @MainActor
    func attachAppleSurface(
        to target: ExperienceRuntimeAppleSurfaceTarget
    ) async throws -> ExperienceRuntimeSurfaceDriverAttachment {
        await surfaceAttachmentGate?.waitBeforeAttaching()
        let driver = FakeExperienceRuntimeSurfaceDriver(
            initialTarget: target,
            lifecycleRecorder: lifecycleRecorder,
            detachmentGate: surfaceDetachmentGate
        )
        let configurator = FakeExperienceRuntimeAppleSurfaceConfigurator()
        surfaceDrivers.append(driver)
        surfaceConfigurators.append(configurator)
        lifecycleRecorder.record(.surfaceAttached(target.size))
        return ExperienceRuntimeSurfaceDriverAttachment(
            driver: driver,
            result: ExperienceRuntimeOperationResult(
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

final class FakeExperienceRuntimeSurfaceDriver {
    private let lifecycleRecorder: FakeExperienceRuntimeLifecycleRecorder
    private let detachmentGate: FakeExperienceRuntimeSurfaceDetachmentGate?
    private let disposal = FakeExperienceRuntimeDisposal()

    @MainActor private(set) var target: ExperienceRuntimeAppleSurfaceTarget?
    @MainActor private(set) var reattachConfigurators: [
        FakeExperienceRuntimeAppleSurfaceConfigurator
    ] = []

    @MainActor
    init(
        initialTarget: ExperienceRuntimeAppleSurfaceTarget,
        lifecycleRecorder: FakeExperienceRuntimeLifecycleRecorder,
        detachmentGate: FakeExperienceRuntimeSurfaceDetachmentGate?
    ) {
        target = initialTarget
        self.lifecycleRecorder = lifecycleRecorder
        self.detachmentGate = detachmentGate
    }

    @MainActor
    func resize(to size: ExperienceRuntimeSurfaceSize) async throws -> ExperienceRuntimeOperationResult {
        guard let currentTarget = target else {
            throw FakeExperienceRuntimeError.surfaceDetached
        }
        target = ExperienceRuntimeAppleSurfaceTarget(layer: currentTarget.layer, size: size)
        lifecycleRecorder.record(.surfaceResized(size))
        return surfaceResult(disposition: .reconfigured)
    }

    @MainActor
    func detach() async throws -> ExperienceRuntimeOperationResult {
        guard target != nil else {
            throw FakeExperienceRuntimeError.surfaceDetached
        }
        await detachmentGate?.waitBeforeDetaching()
        target = nil
        lifecycleRecorder.record(.surfaceDetached)
        return surfaceResult(disposition: .none)
    }

    @MainActor
    func reattach(
        to target: ExperienceRuntimeAppleSurfaceTarget
    ) async throws -> ExperienceRuntimeSurfaceDriverReattachment {
        guard self.target == nil else {
            throw FakeExperienceRuntimeError.surfaceAttached
        }
        self.target = target
        lifecycleRecorder.record(.surfaceReattached(target.size))
        let configurator = FakeExperienceRuntimeAppleSurfaceConfigurator()
        reattachConfigurators.append(configurator)
        return ExperienceRuntimeSurfaceDriverReattachment(
            result: surfaceResult(disposition: .recreated),
            configurator: configurator
        )
    }

    func dispose() {
        disposal.runOnce {
            lifecycleRecorder.record(.surfaceDisposed)
        }
    }

    private func surfaceResult(
        disposition: ExperienceRuntimeSurfaceDisposition
    ) -> ExperienceRuntimeOperationResult {
        ExperienceRuntimeOperationResult(
            renderOutcome: .notRequested,
            surfaceDisposition: disposition,
            isDirty: false,
            isSettled: true
        )
    }
}

@MainActor
final class FakeExperienceRuntimeAppleSurfaceConfigurator:
    ExperienceRuntimeAppleSurfaceConfigurator {
    private(set) var configuredSizes: [ExperienceRuntimeSurfaceSize] = []
    private(set) var unconfiguredSizes: [ExperienceRuntimeSurfaceSize] = []

    func configure(_ target: ExperienceRuntimeAppleSurfaceTarget) {
        configuredSizes.append(target.size)
    }

    func unconfigure(_ target: ExperienceRuntimeAppleSurfaceTarget) {
        unconfiguredSizes.append(target.size)
    }
}

extension FakeExperienceRuntimeAdapter: ExperienceRuntimeAdapter {}
extension FakeExperienceRuntimeContextDriver: ExperienceRuntimeContextDriver {}
extension FakeScreenSessionDriver: ScreenSessionDriver {}
extension FakeExperienceRuntimeSurfaceDriver: ExperienceRuntimeSurfaceDriver {}

extension ExperienceRuntimeBootstrap {
    static let fake = ExperienceRuntimeBootstrap(
        player: ExperienceRuntimePlayerMetadata(
            kind: .staticArtboard,
            selection: .staticArtboard,
            index: nil,
            artboardName: nil,
            playerName: nil,
            bounds: ExperienceRuntimeArtboardBounds(
                minX: 0,
                minY: 0,
                maxX: 1,
                maxY: 1
            )
        ),
        catalog: ExperienceRuntimeCatalog(schemas: [], templates: [], instances: []),
        values: .empty
    )
}

@MainActor
final class FakeExperienceRuntimeSurfaceAttachmentGate {
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
final class FakeExperienceRuntimeSurfaceDetachmentGate {
    private var detachmentContinuation: CheckedContinuation<Void, Never>?
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    func waitBeforeDetaching() async {
        await withCheckedContinuation { continuation in
            detachmentContinuation = continuation
            let waiters = waitingContinuations
            waitingContinuations.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilDetachmentIsSuspended() async {
        guard detachmentContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }

    func resumeDetachment() {
        let continuation = detachmentContinuation
        detachmentContinuation = nil
        continuation?.resume()
    }
}

@MainActor
final class FakeExperienceRuntimeDrawableCompletionGate {
    private var retainedDrawables: [ExperienceRuntimeAppleDrawableTarget] = []
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    func retain(_ drawable: ExperienceRuntimeAppleDrawableTarget?) {
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

private enum FakeExperienceRuntimeError: Error {
    case noOperationResult
    case surfaceAttached
    case surfaceDetached
}

private final class FakeExperienceRuntimeDisposal {
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
