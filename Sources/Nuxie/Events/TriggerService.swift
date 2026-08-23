import Foundation

protocol TriggerServiceProtocol: AnyObject, Sendable {
  func captureSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> Bool
  func captureSystemEventOnly(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> Bool
  func captureAcceptedSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> Bool
  func trigger(
    _ event: String,
    properties: sending [String: Any]?,
    handler: @escaping @Sendable (TriggerUpdate) -> Void
  ) async
}

extension TriggerServiceProtocol {
  func captureAcceptedSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> Bool {
    await captureSystemEventOnly(
      event,
      properties: properties,
      eventId: eventId,
      distinctId: distinctId
    )
  }

  func captureSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> Bool {
    await trigger(event, properties: properties) { _ in }
    return true
  }

  func captureSystemEventOnly(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> Bool {
    await captureSystemEvent(
      event,
      properties: properties,
      eventId: eventId,
      distinctId: distinctId
    )
  }

  func trigger(
    _ event: String,
    properties: sending [String: Any]? = nil,
    handler: @escaping @Sendable (TriggerUpdate) -> Void
  ) async {
    await trigger(
      event,
      properties: properties,
      handler: handler
    )
  }
}

protocol PresentationAttemptTriggerServiceProtocol: AnyObject, Sendable {
  func trigger(
    _ event: String,
    properties: sending [String: Any]?,
    presentationAttempt: ExperiencePresentationAttempt,
    handler: @escaping @Sendable (TriggerUpdate) -> Void
  ) async
}

actor TriggerService: TriggerServiceProtocol {
  // Constructor-injected collaborators (Phase 4c composition root).
  private let eventLog: EventTriggerTracking
  private let journeyService: JourneyServiceProtocol
  private let featureService: FeatureServiceProtocol
  private let experiencePresentationService: ExperiencePresentationServiceProtocol
  private let triggerBroker: TriggerBrokerProtocol
  private let sleepProvider: SleepProviderProtocol
  private let dateProvider: DateProviderProtocol
  private let featureInfo: FeatureInfo
  private let presentationTrace: ExperiencePresentationTraceRecording

  init(
    eventLog: EventTriggerTracking,
    journeys: JourneyServiceProtocol,
    features: FeatureServiceProtocol,
    experiencePresentation: ExperiencePresentationServiceProtocol,
    featureInfo: FeatureInfo,
    triggerBroker: TriggerBrokerProtocol,
    sleepProvider: SleepProviderProtocol,
    dateProvider: DateProviderProtocol,
    presentationTrace: ExperiencePresentationTraceRecording = DisabledExperiencePresentationTrace()
  ) {
    self.eventLog = eventLog
    self.journeyService = journeys
    self.featureService = features
    self.experiencePresentationService = experiencePresentation
    self.featureInfo = featureInfo
    self.triggerBroker = triggerBroker
    self.sleepProvider = sleepProvider
    self.dateProvider = dateProvider
    self.presentationTrace = presentationTrace
  }

  public func trigger(
    _ event: String,
    properties: sending [String: Any]? = nil,
    handler: @escaping @Sendable (TriggerUpdate) -> Void
  ) async {
    await trigger(
      event,
      properties: properties,
      presentationAttempt: nil,
      handler: handler
    )
  }

  func captureSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> Bool {
    guard let capture = await eventLog.captureSystemEvent(
      event,
      properties: properties,
      eventId: eventId,
      distinctId: distinctId
    ) else { return false }

    // A durable beforeSend drop is terminal for this stable identity. It must
    // retire purchase evidence without network delivery or Journey actions.
    guard capture.routesLocally else { return true }

    // An active checkout may retry an already captured stable event while its
    // in-process Journey delivery is unresolved. Cold recovery uses
    // captureSystemEventOnly and never enters this routing path.
    guard let results = await journeyService.handleCapturedEventForTrigger(
      capture.event
    ) else { return false }
    _ = await emitJourneyDecisions(
      results: results,
      eventId: capture.event.id
    )
    return true
  }

  /// Cold transaction recovery preserves the canonical analytics event but
  /// must not resurrect Journey actions from a paywall whose process ended.
  func captureSystemEventOnly(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> Bool {
    await eventLog.captureSystemEvent(
      event,
      properties: properties,
      eventId: eventId,
      distinctId: distinctId
    ) != nil
  }

  func captureAcceptedSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> Bool {
    await eventLog.captureAcceptedSystemEvent(
      event,
      properties: properties,
      eventId: eventId,
      distinctId: distinctId
    )
  }

  private func trigger(
    _ event: String,
    properties: sending [String: Any]?,
    presentationAttempt: ExperiencePresentationAttempt?,
    handler: @escaping @Sendable (TriggerUpdate) -> Void
  ) async {
    let presentationTraceContext = presentationAttempt.map {
      ExperiencePresentationTraceContext(
        attempt: $0,
        recorder: presentationTrace
      )
    }
    defer { presentationTraceContext?.completeTriggerRouting() }
    do {
      let (nuxieEvent, response) = try await eventLog.trackForTrigger(
        event,
        properties: properties
      )

      let eventId = nuxieEvent.id
      if let presentationAttempt {
        presentationTrace.record(
          attempt: presentationAttempt,
          stage: .eventTracked(eventId: eventId),
          at: dateProvider.now()
        )
      }
      let gatePlan = response.gatePlan()
      let mode = mode(for: gatePlan)
      let hasDirectExperienceGate: Bool = {
        guard let gatePlan,
              case .showFlow = gatePlan.decision,
              gatePlan.flowId != nil else {
          return false
        }
        return true
      }()

      let broker = triggerBroker
      let journeyStartFlag = LockedFlag()
      let journeyErrorFlag = LockedFlag()
      let shouldCompleteUpdate: @Sendable (TriggerUpdate) -> Bool = { update in
        switch update {
        case .error:
          return true
        case .decision(let decision):
          switch decision {
          case .allowedImmediate, .deniedImmediate, .noMatch:
            return true
          case .suppressed:
            return gatePlan == nil && !journeyStartFlag.get() && !journeyErrorFlag.get()
          case .experienceShown(let ref):
            return hasDirectExperienceGate && ref.journeyId == nil
          default:
            return false
          }
        case .featureAccess(let featureAccess):
          switch featureAccess {
          case .allowed, .denied:
            return true
          case .pending:
            return false
          }
        case .journey:
          return mode == .experience
        }
      }

      await broker.register(eventId: eventId) { update in
        handler(update)
        if shouldCompleteUpdate(update) {
          Task { await broker.complete(eventId: eventId) }
        }
      }

      let journeyResults = await journeyService.handleEventForTrigger(
        nuxieEvent,
        presentationAttempt: presentationAttempt
      )
      let hasStartedJourney = journeyResults.contains { result in
        if case .started = result { return true }
        return false
      }
      let journeyStartFailed = journeyResults.contains { result in
        if case .error = result { return true }
        return false
      }
      journeyStartFlag.set(hasStartedJourney)
      journeyErrorFlag.set(journeyStartFailed)
      let emittedJourneyDecision = await emitJourneyDecisions(
        results: journeyResults,
        eventId: eventId
      )

      if journeyStartFailed {
        return
      }

      if gatePlan == nil && emittedJourneyDecision {
        return
      }

      if hasStartedJourney && mode == .experience {
        return
      }

      if let gatePlan {
        await handleGatePlan(
          gatePlan,
          eventId: eventId,
          presentationAttempt: presentationAttempt
        )
      } else {
        await broker.emit(eventId: eventId, update: .decision(.noMatch))
      }
    } catch is EventBeforeSendDropError {
      await MainActor.run {
        handler(.decision(.noMatch))
      }
    } catch {
      let triggerError = TriggerError(code: .triggerFailed, message: error.localizedDescription)
      await MainActor.run {
        handler(.error(triggerError))
      }
    }
  }

  // MARK: - Decisions

  private enum TriggerMode: Equatable {
    case immediate
    case experience
    case requireFeature
  }

  private func mode(for plan: GatePlan?) -> TriggerMode {
    guard let plan else { return .experience }
    switch plan.decision {
    case .allow, .deny:
      return .immediate
    case .showFlow:
      return .experience
    case .requireFeature:
      return .requireFeature
    }
  }

  private func emitJourneyDecisions(
    results: [JourneyTriggerResult],
    eventId: String
  ) async -> Bool {
    guard !results.isEmpty else { return false }
    var emitted = false

    for result in results {
      switch result {
      case .started(let journey):
        let ref = ExperienceRef(
          experienceId: journey.experienceId,
          experienceVersion: journey.experienceVersion,
          journeyId: journey.id
        )
        await triggerBroker.emit(eventId: eventId, update: .decision(.journeyStarted(ref)))
        emitted = true
      case .suppressed(let reason):
        await triggerBroker.emit(eventId: eventId, update: .decision(.suppressed(reason)))
        emitted = true
      case .error(let error):
        await triggerBroker.emit(eventId: eventId, update: .error(error))
        return true
      }
    }

    return emitted
  }

  private func handleGatePlan(
    _ plan: GatePlan,
    eventId: String,
    presentationAttempt: ExperiencePresentationAttempt?
  ) async {
    switch plan.decision {
    case .allow:
      await triggerBroker.emit(eventId: eventId, update: .decision(.allowedImmediate))
    case .deny:
      await triggerBroker.emit(eventId: eventId, update: .decision(.deniedImmediate))
    case .showFlow:
      await handleShowExperience(
        plan,
        eventId: eventId,
        presentationAttempt: presentationAttempt
      )
    case .requireFeature:
      await handleRequireFeature(
        plan,
        eventId: eventId,
        presentationAttempt: presentationAttempt
      )
    }
  }

  private func handleShowExperience(
    _ plan: GatePlan,
    eventId: String,
    presentationAttempt: ExperiencePresentationAttempt?
  ) async {
    guard let experienceVersionId = plan.flowId else {
      await triggerBroker.emit(
        eventId: eventId,
        update: .error(TriggerError(
          code: .experienceMissing,
          message: "Missing experience version for show_flow decision"
        ))
      )
      return
    }
    await presentExperience(
      experienceVersionId: experienceVersionId,
      eventId: eventId,
      presentationAttempt: presentationAttempt
    )
  }

  private func handleRequireFeature(
    _ plan: GatePlan,
    eventId: String,
    presentationAttempt: ExperiencePresentationAttempt?
  ) async {
    guard let featureId = plan.featureId else {
      await triggerBroker.emit(
        eventId: eventId,
        update: .error(TriggerError(
          code: .featureMissing,
          message: "Missing featureId for require_feature decision"
        ))
      )
      return
    }

    if plan.policy == .cacheOnly {
      let cached = await GatePlanEvaluation.cachedFeatureAccess(featureInfo, featureId: featureId)
      if GatePlanEvaluation.hasAccess(cached, requiredBalance: plan.requiredBalance) {
        await triggerBroker.emit(eventId: eventId, update: .featureAccess(.allowed))
      } else {
        await triggerBroker.emit(eventId: eventId, update: .featureAccess(.denied))
      }
      return
    }

    do {
      let access = try await featureService.checkWithCache(
        featureId: featureId,
        requiredBalance: plan.requiredBalance,
        entityId: plan.entityId,
        forceRefresh: false
      )
      if GatePlanEvaluation.hasAccess(access, requiredBalance: plan.requiredBalance) {
        await triggerBroker.emit(eventId: eventId, update: .featureAccess(.allowed))
        return
      }
    } catch {
      LogWarning("TriggerService: feature check failed \(error)")
    }

    await triggerBroker.emit(eventId: eventId, update: .featureAccess(.pending))

    if let experienceVersionId = plan.flowId {
      await presentExperience(
        experienceVersionId: experienceVersionId,
        eventId: eventId,
        presentationAttempt: presentationAttempt
      )
    }

    let timeoutMs = plan.timeoutMs ?? 30_000
    let allowed = await waitForFeatureAccess(
      featureId: featureId,
      requiredBalance: plan.requiredBalance,
      timeoutMs: timeoutMs
    )

    if allowed {
      await triggerBroker.emit(eventId: eventId, update: .featureAccess(.allowed))
    } else {
      await triggerBroker.emit(
        eventId: eventId,
        update: .error(TriggerError(
          code: .featureAccessTimeout,
          message: "Timed out waiting for feature access"
        ))
      )
    }
  }

  // MARK: - Feature Access Waiting

  private func waitForFeatureAccess(
    featureId: String,
    requiredBalance: Double?,
    timeoutMs: Int
  ) async -> Bool {
    let timeoutSeconds = max(Double(timeoutMs) / 1000.0, 0.1)
    let deadline = dateProvider.date(byAddingTimeInterval: timeoutSeconds, to: dateProvider.now())
    let interval: TimeInterval = 0.35
    var attempts = 0
    let maxAttempts = max(Int(timeoutSeconds / interval) + 2, 1)

    while dateProvider.now() < deadline && attempts < maxAttempts {
      let access = await GatePlanEvaluation.cachedFeatureAccess(featureInfo, featureId: featureId)
      if GatePlanEvaluation.hasAccess(access, requiredBalance: requiredBalance) {
        return true
      }

      do {
        try await sleepProvider.sleep(for: interval)
      } catch {
        break
      }
      attempts += 1
    }

    return false
  }

  private func presentExperience(
    experienceVersionId: String,
    eventId: String,
    presentationAttempt: ExperiencePresentationAttempt?
  ) async {
    do {
      let runtimeDelegate: DirectExperiencePresentationTraceDelegate?
      if let presentationAttempt {
        let requestedAt = ExperiencePresentationTimestamp.now(
          wallClock: dateProvider.now()
        )
        ExperiencePresentationTraceContext(
          attempt: presentationAttempt,
          recorder: presentationTrace
        ).recordPresentationRequested(
          experienceVersionId: experienceVersionId,
          route: .direct,
          at: requestedAt
        )
        runtimeDelegate = await MainActor.run {
          DirectExperiencePresentationTraceDelegate(
            attempt: presentationAttempt,
            trace: presentationTrace,
            dateProvider: dateProvider
          )
        }
      } else {
        runtimeDelegate = nil
      }
      let controller = try await experiencePresentationService.presentExperience(
        experienceVersionId,
        from: nil,
        runtimeDelegate: runtimeDelegate
      )
      let experience = await MainActor.run { controller.experience }
      let ref = ExperienceRef(
        experienceId: experience.id,
        experienceVersion: experience.versionId,
        journeyId: nil
      )
      await triggerBroker.emit(eventId: eventId, update: .decision(.experienceShown(ref)))
    } catch {
      if let presentationAttempt {
        presentationTrace.record(
          attempt: presentationAttempt,
          stage: .presentationFailed(
            route: .direct,
            errorCode: ExperiencePresentationTraceContext.errorCode(for: error)
          ),
          at: dateProvider.now()
        )
      }
      await triggerBroker.emit(
        eventId: eventId,
        update: .error(TriggerError(
          code: .experiencePresentFailed,
          message: error.localizedDescription
        ))
      )
    }
  }

}

extension TriggerService: PresentationAttemptTriggerServiceProtocol {
  func trigger(
    _ event: String,
    properties: sending [String: Any]?,
    presentationAttempt: ExperiencePresentationAttempt,
    handler: @escaping @Sendable (TriggerUpdate) -> Void
  ) async {
    await trigger(
      event,
      properties: properties,
      presentationAttempt: Optional(presentationAttempt),
      handler: handler
    )
  }
}

/// Lock-guarded flag shared between trigger routing and the broker's
/// `@Sendable` completion predicate.
// @unchecked Sendable: `value` is only accessed under `lock`.
private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set(_ newValue: Bool) {
    lock.withLock { value = newValue }
  }

  func get() -> Bool {
    lock.withLock { value }
  }
}
