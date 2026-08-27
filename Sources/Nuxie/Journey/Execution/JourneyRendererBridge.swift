import Foundation

/// Bridges renderer callbacks (ExperienceRuntimeDelegate + permission receivers)
/// onto the JourneyService actor. Pure plumbing: every callback hops onto the
/// service with the journey id it was created for. Extracted from
/// JourneyService (Phase 6).
// @unchecked Sendable: immutable identifiers plus a weak reference to the
// JourneyService actor (itself Sendable). Trace sequencing state is isolated
// to MainActor with every ExperienceRuntimeDelegate callback. The
// ExperienceRuntimeDelegate conformance lives in an extension so the @MainActor
// protocol does not infect the whole class with MainActor isolation — the
// nonisolated witnesses satisfy the MainActor requirements safely.
final class JourneyRendererBridge:
  NotificationPermissionEventReceiver,
  RequestPermissionEventReceiver,
  TrackingPermissionEventReceiver,
  @unchecked Sendable
{
  private weak var journeyService: JourneyService?
  private let journeyId: String
  private let distinctId: String
  private let dateProvider: DateProviderProtocol
  @MainActor private var presentationTraceToken: UUID?
  @MainActor private(set) var presentationTraceContext: ExperiencePresentationTraceContext?
  @MainActor private var presentationTraceForwardingTask: Task<Void, Never>?
  @MainActor private var activeScreenRun: ScreenControlRunScope?

  init(
    journeyId: String,
    distinctId: String,
    journeyService: JourneyService,
    dateProvider: DateProviderProtocol
  ) {
    self.journeyId = journeyId
    self.distinctId = distinctId
    self.journeyService = journeyService
    self.dateProvider = dateProvider
  }

  @MainActor
  func beginPresentationTrace(
    presentationToken: UUID?,
    context: ExperiencePresentationTraceContext?
  ) {
    // Renderer callbacks capture their token before joining the serialized
    // forwarding chain, so changing the active presentation here cannot
    // reattribute an already-enqueued stage. This handoff must remain
    // synchronous: a forwarded runtime-ready callback can re-enter
    // JourneyService and begin another presentation before its own task has
    // completed, and awaiting the forwarding tail here would self-deadlock.
    presentationTraceToken = presentationToken
    presentationTraceContext = context
    activeScreenRun = nil
  }

  @MainActor
  func clearPresentationTrace(ifMatching presentationToken: UUID) {
    guard self.presentationTraceToken == presentationToken else { return }
    self.presentationTraceToken = nil
    presentationTraceContext = nil
    activeScreenRun = nil
  }

  @MainActor
  func experienceViewControllerWillActivateInitialScreen(
    _ controller: ExperienceViewController
  ) async -> Bool {
    guard let journeyService else { return false }
    let accepted = await journeyService.handleWillActivateInitialScreen(
      journeyId: journeyId,
      controller: controller
    )
    activeScreenRun = accepted
      ? await journeyService.screenControlRunScope(journeyId: journeyId)
      : nil
    await controller.configureScreenEmissionRun(activeScreenRun)
    return accepted
  }

  @MainActor
  func experienceViewControllerWillDispatchInitialScreenLifecycle(
    _ controller: ExperienceViewController,
    screenId: String
  ) async -> Bool {
    guard let journeyService else { return false }
    return await journeyService.handleWillDispatchInitialScreenLifecycle(
      journeyId: journeyId,
      controller: controller,
      screenId: screenId
    )
  }

  @MainActor
  func experienceViewControllerDidBecomeReady(_ controller: ExperienceViewController) {
    enqueueRuntimeReady(controller, presentationToken: nil)
  }

  @MainActor
  private func enqueueRuntimeReady(
    _ controller: ExperienceViewController,
    presentationToken: UUID?
  ) {
    let timestamp = callbackTimestamp()
    enqueuePresentationTrace { [journeyId] journeyService in
      if let presentationToken {
        await journeyService.handlePresentationTraceStage(
          journeyId: journeyId,
          presentationToken: presentationToken,
          stage: .runtimeReady,
          timestamp: timestamp
        )
      }
      await journeyService.handleRuntimeReady(
        journeyId: journeyId,
        controller: controller
      )
    }
  }

  @MainActor
  func experienceViewControllerDidPresentShell(_ controller: ExperienceViewController) {}

  @MainActor
  func experienceViewControllerDidReveal(_ controller: ExperienceViewController) {}

  @MainActor
  func experienceViewController(
    _ controller: ExperienceViewController,
    didPresentDrawable drawable: ExperienceRuntimePresentedDrawable,
    screenId: String,
    frameNumber: UInt64
  ) {
    // Presentation tracing requires the immutable token supplied by the host.
  }

  @MainActor
  func experienceViewController(
    _ controller: ExperienceViewController,
    didAcceptPointerInput input: ExperienceRuntimeAcceptedPointerInput,
    screenId: String
  ) {
    // Presentation tracing requires the immutable token supplied by the host.
  }

  @MainActor
  func experienceViewControllerDidFinishPresentation(
    _ controller: ExperienceViewController
  ) {}

  @MainActor
  func experienceViewControllerDidFinishPresentation(
    _ controller: ExperienceViewController,
    traceToken: ExperiencePresentationTraceToken?
  ) {
    guard let finishedPresentationToken = traceToken?.id else { return }
    if presentationTraceToken == finishedPresentationToken {
      presentationTraceToken = nil
      presentationTraceContext = nil
      activeScreenRun = nil
    }
    let timestamp = callbackTimestamp()
    enqueuePresentationTrace { [journeyId] journeyService in
      await journeyService.handlePresentationTraceStage(
        journeyId: journeyId,
        presentationToken: finishedPresentationToken,
        stage: .presentationCleanupCompleted,
        timestamp: timestamp
      )
    }
  }

  @MainActor
  func experienceViewController(
    _ controller: ExperienceViewController,
    didChangeScreen screenId: String
  ) async {
    let persisted = await journeyService?.handleRendererScreenChanged(
      journeyId: journeyId,
      screenId: screenId
    ) ?? false
    activeScreenRun = persisted
      ? await journeyService?.screenControlRunScope(journeyId: journeyId)
      : nil
    await controller.configureScreenEmissionRun(activeScreenRun)
  }

  @MainActor
  func experienceViewController(
    _ controller: ExperienceViewController,
    didDismissScreen screenId: String,
    revealingScreenId: String?,
    method: String
  ) async {
    let persisted = await journeyService?.handleRendererScreenDismissed(
      journeyId: journeyId,
      screenId: screenId,
      revealingScreenId: revealingScreenId,
      method: method
    ) ?? false
    activeScreenRun = persisted
      ? await journeyService?.screenControlRunScope(journeyId: journeyId)
      : nil
    await controller.configureScreenEmissionRun(activeScreenRun)
  }

  func experienceViewController(
    _ controller: ExperienceViewController,
    didFailToResolveProductsFor screenId: String
  ) async {
    await journeyService?.handleRuntimeProductsUnavailable(
      journeyId: journeyId,
      screenId: screenId
    )
  }

  @MainActor
  func experienceViewController(
    _ controller: ExperienceViewController,
    didEmitScreenEmissionBatch batch: ScreenEmissionBatch
  ) async -> Bool {
    guard batch.journeyId == journeyId,
          let activeScreenRun,
          batch.source.screenId == activeScreenRun.screenId else {
      return false
    }
    return await journeyService?.handleRendererScreenEmissionBatch(batch) ?? false
  }

  func experienceViewController(
    _ controller: ExperienceViewController,
    didEmitViewModelChange change: ExperienceRendererViewModelChange
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleRendererViewModelChange(
        journeyId: journeyId,
        change: change
      )
    }
  }

  func experienceViewController(
    _ controller: ExperienceViewController,
    didRequestOpenLink request: ExperienceRendererOpenLinkRequest
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleRendererOpenLink(
        journeyId: journeyId,
        request: request
      )
    }
  }

  func experienceViewControllerDidRequestDismiss(_ controller: ExperienceViewController, reason: CloseReason) {
    Task { [weak journeyService] in
      await journeyService?.handleRuntimeDismiss(
        journeyId: journeyId,
        reason: reason,
        controller: controller
      )
    }
  }

  @MainActor
  func experienceViewControllerWillRequestHostDismiss(
    _ controller: ExperienceViewController
  ) async {
    await journeyService?.reserveHostDismissal(journeyId: journeyId)
  }

  @MainActor
  @discardableResult
  func experienceViewControllerDidRequestHostDismiss(
    _ controller: ExperienceViewController
  ) async -> Bool {
    guard let journeyService else { return false }
    return await journeyService.handleRuntimeHostDismiss(
      journeyId: journeyId,
      controller: controller
    )
  }

  func experienceViewController(
    _ controller: ExperienceViewController,
    didResolveNotificationPermissionEvent eventName: String,
    properties: sending [String: Any],
    journeyId: String
  ) {
    // Boxed to hand the write-once payload into the task.
    let propertiesBox = UncheckedSendable(properties)
    Task { [weak journeyService] in
      await journeyService?.handleScopedPermissionEvent(
        journeyId: journeyId,
        eventName: eventName,
        properties: propertiesBox.value,
        distinctId: distinctId
      )
    }
  }

  func experienceViewController(
    _ controller: ExperienceViewController,
    didResolveRequestPermissionEvent eventName: String,
    properties: sending [String: Any],
    journeyId: String
  ) {
    // Boxed to hand the write-once payload into the task.
    let propertiesBox = UncheckedSendable(properties)
    Task { [weak journeyService] in
      await journeyService?.handleScopedPermissionEvent(
        journeyId: journeyId,
        eventName: eventName,
        properties: propertiesBox.value,
        distinctId: distinctId
      )
    }
  }

  func experienceViewController(
    _ controller: ExperienceViewController,
    didIgnoreUnsupportedRequestPermissionType permissionType: String,
    journeyId: String
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleUnsupportedScopedRequestPermission(
        journeyId: journeyId,
        permissionType: permissionType,
        distinctId: distinctId
      )
    }
  }

  func experienceViewController(
    _ controller: ExperienceViewController,
    didResolveTrackingPermissionEvent eventName: String,
    properties: sending [String: Any],
    journeyId: String
  ) {
    // Boxed to hand the write-once payload into the task.
    let propertiesBox = UncheckedSendable(properties)
    Task { [weak journeyService] in
      await journeyService?.handleScopedPermissionEvent(
        journeyId: journeyId,
        eventName: eventName,
        properties: propertiesBox.value,
        distinctId: distinctId
      )
    }
  }

  @MainActor
  private func enqueuePresentationTraceStage(
    _ stage: ExperiencePresentationTraceStage,
    presentationToken: UUID,
    timestamp: ExperiencePresentationTimestamp? = nil
  ) {
    let timestamp = timestamp ?? callbackTimestamp()
    enqueuePresentationTrace { [journeyId] journeyService in
      await journeyService.handlePresentationTraceStage(
        journeyId: journeyId,
        presentationToken: presentationToken,
        stage: stage,
        timestamp: timestamp
      )
    }
  }

  @MainActor
  private func callbackTimestamp() -> ExperiencePresentationTimestamp {
    .now(wallClock: dateProvider.now())
  }

  @MainActor
  private func activePresentationToken(
    matching traceToken: ExperiencePresentationTraceToken?
  ) -> UUID? {
    guard let token = traceToken?.id,
          presentationTraceToken == token else {
      return nil
    }
    return token
  }

  @MainActor
  private func enqueuePresentationTrace(
    _ operation: @escaping @Sendable (JourneyService) async -> Void
  ) {
    let previousTask = presentationTraceForwardingTask
    presentationTraceForwardingTask = Task { [weak journeyService] in
      await previousTask?.value
      guard let journeyService else { return }
      await operation(journeyService)
    }
  }
}

extension JourneyRendererBridge: IntroEligibilityAuthorizationContextProviding {
  var introEligibilityAuthorizationContext: IntroEligibilityAuthorizationContext {
    IntroEligibilityAuthorizationContext(
      distinctId: distinctId,
      journeyId: journeyId
    )
  }
}

/// Pure mapping from the renderer's CloseReason to typed journey outcomes.
enum JourneyDismissalMapping {
  static func dismissMethod(for reason: CloseReason) -> String {
    ExperienceScreenDismissalMethod.value(for: reason)
  }

  static func exitReason(for reason: CloseReason) -> JourneyExitReason {
    switch reason {
    case .userDismissed:
      return .dismissed
    case .goalMet:
      return .goalMet
    case .hostDismissed:
      return .dismissed
    case .error:
      return .error
    }
  }
}

extension JourneyRendererBridge: ExperienceRuntimeDelegate {}

extension JourneyRendererBridge: ExperiencePresentationTraceContextProviding {}

extension JourneyRendererBridge: ExperiencePresentationScopedTraceDelegate {
  @MainActor
  var activePresentationTraceToken: ExperiencePresentationTraceToken? {
    presentationTraceToken.map(ExperiencePresentationTraceToken.init(id:))
  }

  @MainActor
  func experienceViewControllerDidBecomeReady(
    _ controller: ExperienceViewController,
    traceToken: ExperiencePresentationTraceToken?
  ) {
    guard let presentationToken = activePresentationToken(matching: traceToken) else {
      return
    }
    enqueueRuntimeReady(controller, presentationToken: presentationToken)
  }

  @MainActor
  func experienceViewControllerDidPresentShell(
    _ controller: ExperienceViewController,
    traceToken: ExperiencePresentationTraceToken?
  ) {
    guard let presentationToken = activePresentationToken(matching: traceToken) else { return }
    enqueuePresentationTraceStage(
      .shellPresented,
      presentationToken: presentationToken
    )
  }

  @MainActor
  func experienceViewControllerDidReveal(
    _ controller: ExperienceViewController,
    traceToken: ExperiencePresentationTraceToken?
  ) {
    guard let presentationToken = activePresentationToken(matching: traceToken) else { return }
    enqueuePresentationTraceStage(
      .revealed,
      presentationToken: presentationToken
    )
  }

  @MainActor
  func experienceViewController(
    _ controller: ExperienceViewController,
    didPresentDrawable drawable: ExperienceRuntimePresentedDrawable,
    screenId: String,
    frameNumber: UInt64,
    traceToken: ExperiencePresentationTraceToken?
  ) {
    guard let presentationToken = activePresentationToken(matching: traceToken) else { return }
    let observedAt = callbackTimestamp()
    enqueuePresentationTraceStage(
      .firstPresentedDrawable(
        screenId: screenId,
        frameNumber: frameNumber,
        pixels: UInt64(drawable.pixelWidth) * UInt64(drawable.pixelHeight),
        drawCalls: drawable.drawCalls,
        provenance: drawable.provenance
      ),
      presentationToken: presentationToken,
      timestamp: .anchored(
        monotonicTime: drawable.presentedTime,
        observedAt: observedAt
      )
    )
  }

  @MainActor
  func experienceViewController(
    _ controller: ExperienceViewController,
    didAcceptPointerInput input: ExperienceRuntimeAcceptedPointerInput,
    screenId: String,
    traceToken: ExperiencePresentationTraceToken?
  ) {
    guard let presentationToken = activePresentationToken(matching: traceToken) else { return }
    enqueuePresentationTraceStage(
      .firstAcceptedInput(screenId: screenId, eventCount: input.eventCount),
      presentationToken: presentationToken
    )
  }
}
