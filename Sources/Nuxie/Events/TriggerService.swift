import Foundation

public protocol TriggerServiceProtocol: AnyObject, Sendable {
  func trigger(
    _ event: String,
    properties: sending [String: Any]?,
    userProperties: sending [String: Any]?,
    userPropertiesSetOnce: sending [String: Any]?,
    handler: @escaping @Sendable (TriggerUpdate) -> Void
  ) async
}

public extension TriggerServiceProtocol {
  func trigger(
    _ event: String,
    properties: sending [String: Any]? = nil,
    userProperties: sending [String: Any]? = nil,
    userPropertiesSetOnce: sending [String: Any]? = nil,
    handler: @escaping @Sendable (TriggerUpdate) -> Void
  ) async {
    await trigger(
      event,
      properties: properties,
      userProperties: userProperties,
      userPropertiesSetOnce: userPropertiesSetOnce,
      handler: handler
    )
  }
}

public actor TriggerService: TriggerServiceProtocol {
  // Constructor-injected collaborators (Phase 4c composition root).
  private let eventLog: EventLogProtocol
  private let journeyService: JourneyServiceProtocol
  private let featureService: FeatureServiceProtocol
  private let flowPresentationService: ExperiencePresentationServiceProtocol
  private let triggerBroker: TriggerBrokerProtocol
  private let sleepProvider: SleepProviderProtocol
  private let dateProvider: DateProviderProtocol
  private let featureInfo: FeatureInfo

  init(
    eventLog: EventLogProtocol,
    journeys: JourneyServiceProtocol,
    features: FeatureServiceProtocol,
    flowPresentation: ExperiencePresentationServiceProtocol,
    featureInfo: FeatureInfo,
    triggerBroker: TriggerBrokerProtocol,
    sleepProvider: SleepProviderProtocol,
    dateProvider: DateProviderProtocol
  ) {
    self.eventLog = eventLog
    self.journeyService = journeys
    self.featureService = features
    self.flowPresentationService = flowPresentation
    self.featureInfo = featureInfo
    self.triggerBroker = triggerBroker
    self.sleepProvider = sleepProvider
    self.dateProvider = dateProvider
  }

  public func trigger(
    _ event: String,
    properties: sending [String: Any]? = nil,
    userProperties: sending [String: Any]? = nil,
    userPropertiesSetOnce: sending [String: Any]? = nil,
    handler: @escaping @Sendable (TriggerUpdate) -> Void
  ) async {
    do {
      let (nuxieEvent, response) = try await eventLog.trackForTrigger(
        event,
        properties: properties,
        userProperties: userProperties,
        userPropertiesSetOnce: userPropertiesSetOnce
      )

      let eventId = nuxieEvent.id
      let gatePlan = response.gatePlan()
      let mode = mode(for: gatePlan)
      let terminalGateFlowCampaignId: String? = {
        guard let gatePlan, case .showFlow = gatePlan.decision, let flowId = gatePlan.flowId else {
          return nil
        }
        return "flow:\(flowId)"
      }()

      let broker = triggerBroker
      let journeyStartFlag = JourneyStartFlag()
      let shouldCompleteUpdate: @Sendable (TriggerUpdate) -> Bool = { update in
        switch update {
        case .error:
          return true
        case .decision(let decision):
          switch decision {
          case .allowedImmediate, .deniedImmediate, .noMatch:
            return true
          case .suppressed:
            return gatePlan == nil && !journeyStartFlag.get()
          case .flowShown(let ref):
            return ref.campaignId == terminalGateFlowCampaignId
          default:
            return false
          }
        case .entitlement(let entitlement):
          switch entitlement {
          case .allowed, .denied:
            return true
          case .pending:
            return false
          }
        case .journey:
          return mode == .flow
        }
      }

      await broker.register(eventId: eventId) { update in
        handler(update)
        if shouldCompleteUpdate(update) {
          Task { await broker.complete(eventId: eventId) }
        }
      }

      let journeyResults = await journeyService.handleEventForTrigger(nuxieEvent)
      let hasStartedJourney = journeyResults.contains { result in
        if case .started = result { return true }
        return false
      }
      journeyStartFlag.set(hasStartedJourney)
      let emittedJourneyDecision = await emitJourneyDecisions(
        results: journeyResults,
        eventId: eventId
      )

      if gatePlan == nil && emittedJourneyDecision {
        return
      }

      if hasStartedJourney && mode == .flow {
        return
      }

      if let gatePlan {
        await handleGatePlan(gatePlan, eventId: eventId)
      } else {
        await broker.emit(eventId: eventId, update: .decision(.noMatch))
      }
    } catch {
      let triggerError = TriggerError(code: "trigger_failed", message: error.localizedDescription)
      await MainActor.run {
        handler(.error(triggerError))
      }
    }
  }

  // MARK: - Decisions

  private enum TriggerMode: Equatable {
    case immediate
    case flow
    case requireFeature
  }

  private func mode(for plan: GatePlan?) -> TriggerMode {
    guard let plan else { return .flow }
    switch plan.decision {
    case .allow, .deny:
      return .immediate
    case .showFlow:
      return .flow
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
        let ref = JourneyRef(
          journeyId: journey.id,
          campaignId: journey.campaignId,
          flowId: journey.flowId
        )
        await triggerBroker.emit(eventId: eventId, update: .decision(.journeyStarted(ref)))
        emitted = true
      case .suppressed(let reason):
        await triggerBroker.emit(eventId: eventId, update: .decision(.suppressed(reason)))
        emitted = true
      }
    }

    return emitted
  }

  private func handleGatePlan(_ plan: GatePlan, eventId: String) async {
    switch plan.decision {
    case .allow:
      await triggerBroker.emit(eventId: eventId, update: .decision(.allowedImmediate))
    case .deny:
      await triggerBroker.emit(eventId: eventId, update: .decision(.deniedImmediate))
    case .showFlow:
      await handleShowFlow(plan, eventId: eventId)
    case .requireFeature:
      await handleRequireFeature(plan, eventId: eventId)
    }
  }

  private func handleShowFlow(_ plan: GatePlan, eventId: String) async {
    guard let flowId = plan.flowId else {
      await triggerBroker.emit(
        eventId: eventId,
        update: .error(TriggerError(code: "flow_missing", message: "Missing flowId for show_flow decision"))
      )
      return
    }
    await presentExperience(flowId: flowId, eventId: eventId)
  }

  private func handleRequireFeature(_ plan: GatePlan, eventId: String) async {
    guard let featureId = plan.featureId else {
      await triggerBroker.emit(
        eventId: eventId,
        update: .error(TriggerError(code: "feature_missing", message: "Missing featureId for require_feature decision"))
      )
      return
    }

    if plan.policy == .cacheOnly {
      let cached = await GatePlanEvaluation.cachedFeatureAccess(featureInfo, featureId: featureId)
      if GatePlanEvaluation.hasAccess(cached, requiredBalance: plan.requiredBalance) {
        await triggerBroker.emit(eventId: eventId, update: .entitlement(.allowed(source: .cache)))
      } else {
        await triggerBroker.emit(eventId: eventId, update: .entitlement(.denied))
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
        await triggerBroker.emit(eventId: eventId, update: .entitlement(.allowed(source: .cache)))
        return
      }
    } catch {
      LogWarning("TriggerService: feature check failed \(error)")
    }

    await triggerBroker.emit(eventId: eventId, update: .entitlement(.pending))

    if let flowId = plan.flowId {
      await presentExperience(flowId: flowId, eventId: eventId)
    }

    let timeoutMs = plan.timeoutMs ?? 30_000
    let allowed = await waitForEntitlement(
      featureId: featureId,
      requiredBalance: plan.requiredBalance,
      timeoutMs: timeoutMs
    )

    if allowed {
      await triggerBroker.emit(eventId: eventId, update: .entitlement(.allowed(source: .purchase)))
    } else {
      await triggerBroker.emit(
        eventId: eventId,
        update: .error(TriggerError(code: "entitlement_timeout", message: "Timed out waiting for entitlement"))
      )
    }
  }

  // MARK: - Entitlement Waiting

  private func waitForEntitlement(
    featureId: String,
    requiredBalance: Int?,
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

  private func presentExperience(flowId: String, eventId: String) async {
    do {
      _ = try await flowPresentationService.presentExperience(flowId, from: nil, runtimeDelegate: nil)
      let ref = JourneyRef(
        journeyId: UUID.v7().uuidString,
        campaignId: "flow:\(flowId)",
        flowId: flowId
      )
      await triggerBroker.emit(eventId: eventId, update: .decision(.flowShown(ref)))
    } catch {
      await triggerBroker.emit(
        eventId: eventId,
        update: .error(TriggerError(code: "flow_present_failed", message: error.localizedDescription))
      )
    }
  }

}


/// Lock-guarded flag shared between the trigger flow and the @Sendable
/// completion predicate registered with the broker.
// @unchecked Sendable: `value` is only accessed under `lock`.
private final class JourneyStartFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set(_ newValue: Bool) {
    lock.withLock { value = newValue }
  }

  func get() -> Bool {
    lock.withLock { value }
  }
}

