import Foundation

@MainActor
final class DirectExperiencePresentationTraceDelegate {
    private let attempt: ExperiencePresentationAttempt
    private let trace: ExperiencePresentationTraceRecording
    private let dateProvider: DateProviderProtocol
    private let traceToken = ExperiencePresentationTraceToken(id: UUID())
    private var didRecordRuntimeReady = false
    private var didRecordShellPresented = false
    private var didRecordReveal = false
    private var didRecordDrawable = false
    private var didRecordInput = false
    private var didRecordCompletion = false

    init(
        attempt: ExperiencePresentationAttempt,
        trace: ExperiencePresentationTraceRecording,
        dateProvider: DateProviderProtocol
    ) {
        self.attempt = attempt
        self.trace = trace
        self.dateProvider = dateProvider
    }

    private func record(_ stage: ExperiencePresentationTraceStage) {
        trace.record(
            attempt: attempt,
            stage: stage,
            timestamp: .now(wallClock: dateProvider.now())
        )
    }
}

extension DirectExperiencePresentationTraceDelegate: ExperiencePresentationScopedTraceDelegate {
    var activePresentationTraceToken: ExperiencePresentationTraceToken? {
        traceToken
    }

    func experienceViewControllerDidBecomeReady(
        _ controller: ExperienceViewController,
        traceToken: ExperiencePresentationTraceToken?
    ) {
        guard traceToken == self.traceToken else { return }
        experienceViewControllerDidBecomeReady(controller)
    }

    func experienceViewControllerDidPresentShell(
        _ controller: ExperienceViewController,
        traceToken: ExperiencePresentationTraceToken?
    ) {
        guard traceToken == self.traceToken else { return }
        experienceViewControllerDidPresentShell(controller)
    }

    func experienceViewControllerDidReveal(
        _ controller: ExperienceViewController,
        traceToken: ExperiencePresentationTraceToken?
    ) {
        guard traceToken == self.traceToken else { return }
        experienceViewControllerDidReveal(controller)
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didPresentDrawable drawable: ExperienceRuntimePresentedDrawable,
        screenId: String,
        frameNumber: UInt64,
        traceToken: ExperiencePresentationTraceToken?
    ) {
        guard traceToken == self.traceToken else { return }
        experienceViewController(
            controller,
            didPresentDrawable: drawable,
            screenId: screenId,
            frameNumber: frameNumber
        )
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didAcceptPointerInput input: ExperienceRuntimeAcceptedPointerInput,
        screenId: String,
        traceToken: ExperiencePresentationTraceToken?
    ) {
        guard traceToken == self.traceToken else { return }
        experienceViewController(
            controller,
            didAcceptPointerInput: input,
            screenId: screenId
        )
    }

    func experienceViewControllerDidFinishPresentation(
        _ controller: ExperienceViewController,
        traceToken: ExperiencePresentationTraceToken?
    ) {
        guard traceToken == self.traceToken else { return }
        experienceViewControllerDidFinishPresentation(controller)
    }
}

extension DirectExperiencePresentationTraceDelegate: ExperiencePresentationTraceContextProviding {
    var presentationTraceContext: ExperiencePresentationTraceContext? {
        ExperiencePresentationTraceContext(attempt: attempt, recorder: trace)
    }
}

extension DirectExperiencePresentationTraceDelegate: ExperienceRuntimeDelegate {
    func experienceViewControllerDidBecomeReady(_ controller: ExperienceViewController) {
        guard !didRecordRuntimeReady else { return }
        didRecordRuntimeReady = true
        record(.runtimeReady)
    }

    func experienceViewControllerDidPresentShell(_ controller: ExperienceViewController) {
        guard !didRecordShellPresented else { return }
        didRecordShellPresented = true
        record(.shellPresented)
    }

    func experienceViewControllerDidReveal(_ controller: ExperienceViewController) {
        guard !didRecordReveal else { return }
        didRecordReveal = true
        record(.revealed)
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didPresentDrawable drawable: ExperienceRuntimePresentedDrawable,
        screenId: String,
        frameNumber: UInt64
    ) {
        guard drawable.isComplete, !didRecordDrawable else { return }
        didRecordDrawable = true
        let observedAt = ExperiencePresentationTimestamp.now(
            wallClock: dateProvider.now()
        )
        trace.record(
            attempt: attempt,
            stage: .firstPresentedDrawable(
                screenId: screenId,
                frameNumber: frameNumber,
                pixels: UInt64(drawable.pixelWidth) * UInt64(drawable.pixelHeight),
                drawCalls: drawable.drawCalls,
                provenance: drawable.provenance
            ),
            timestamp: .anchored(
                monotonicTime: drawable.presentedTime,
                observedAt: observedAt
            )
        )
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didAcceptPointerInput input: ExperienceRuntimeAcceptedPointerInput,
        screenId: String
    ) {
        guard !didRecordInput else { return }
        didRecordInput = true
        record(.firstAcceptedInput(screenId: screenId, eventCount: input.eventCount))
    }

    func experienceViewControllerDidFinishPresentation(
        _ controller: ExperienceViewController
    ) {
        guard !didRecordCompletion else { return }
        didRecordCompletion = true
        record(.presentationCleanupCompleted)
    }

    func experienceViewControllerDidRequestDismiss(
        _ controller: ExperienceViewController,
        reason: CloseReason
    ) {
        guard reason == .userDismissed, !didRecordReveal else { return }
        record(.presentationAbandoned(route: .direct, reason: "user_dismissed"))
    }
}
