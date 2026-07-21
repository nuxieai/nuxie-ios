import FactoryKit
import Foundation

public protocol TriggerServiceProtocol: AnyObject {
  func trigger(
    _ event: String,
    properties: [String: Any]?,
    userProperties: [String: Any]?,
    userPropertiesSetOnce: [String: Any]?,
    handler: @escaping (TriggerUpdate) -> Void
  ) async
}

public extension TriggerServiceProtocol {
  func trigger(
    _ event: String,
    properties: [String: Any]? = nil,
    userProperties: [String: Any]? = nil,
    userPropertiesSetOnce: [String: Any]? = nil,
    handler: @escaping (TriggerUpdate) -> Void
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
  // Constructor-injected collaborators (Phase 4c composition root). The two
  // MainActor-isolated collaborators stay lazily injected until the finale.
  private let eventLog: EventLogProtocol
  private let journeyService: JourneyServiceProtocol
  private let featureService: FeatureServiceProtocol
  @Injected(\.flowPresentationService) private var flowPresentationService: FlowPresentationServiceProtocol
  private let triggerBroker: TriggerBrokerProtocol
  private let sleepProvider: SleepProviderProtocol
  private let dateProvider: DateProviderProtocol
  @Injected(\.featureInfo) private var featureInfo: FeatureInfo

  /// Container-resolving defaults are interim (final 4c slice removes them).
  init(
    eventLog: EventLogProtocol = Container.shared.eventLog(),
    journeys: JourneyServiceProtocol = Container.shared.journeyService(),
    features: FeatureServiceProtocol = Container.shared.featureService(),
    triggerBroker: TriggerBrokerProtocol = Container.shared.triggerBroker(),
    sleepProvider: SleepProviderProtocol = Container.shared.sleepProvider(),
    dateProvider: DateProviderProtocol = Container.shared.dateProvider()
  ) {
    self.eventLog = eventLog
    self.journeyService = journeys
    self.featureService = features
    self.triggerBroker = triggerBroker
    self.sleepProvider = sleepProvider
    self.dateProvider = dateProvider
  }

  public func trigger(
    _ event: String,
    properties: [String: Any]? = nil,
    userProperties: [String: Any]? = nil,
    userPropertiesSetOnce: [String: Any]? = nil,
    handler: @escaping (TriggerUpdate) -> Void
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
      var hasStartedJourney = false
      let shouldCompleteUpdate: (TriggerUpdate) -> Bool = { update in
        switch update {
        case .error:
          return true
        case .decision(let decision):
          switch decision {
          case .allowedImmediate, .deniedImmediate, .noMatch:
            return true
          case .suppressed:
            return gatePlan == nil && !hasStartedJourney
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
      hasStartedJourney = journeyResults.contains { result in
        if case .started = result { return true }
        return false
      }
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
    await presentFlow(flowId: flowId, eventId: eventId)
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
      let cached = await currentFeatureAccess(featureId: featureId)
      if hasAccess(cached, requiredBalance: plan.requiredBalance) {
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
      if hasAccess(access, requiredBalance: plan.requiredBalance) {
        await triggerBroker.emit(eventId: eventId, update: .entitlement(.allowed(source: .cache)))
        return
      }
    } catch {
      LogWarning("TriggerService: feature check failed \(error)")
    }

    await triggerBroker.emit(eventId: eventId, update: .entitlement(.pending))

    if let flowId = plan.flowId {
      await presentFlow(flowId: flowId, eventId: eventId)
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
      let access = await currentFeatureAccess(featureId: featureId)
      if hasAccess(access, requiredBalance: requiredBalance) {
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

  private func presentFlow(flowId: String, eventId: String) async {
    do {
      _ = try await flowPresentationService.presentFlow(flowId, from: nil, runtimeDelegate: nil)
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

  private func currentFeatureAccess(featureId: String) async -> FeatureAccess? {
    let info = featureInfo
    return await MainActor.run {
      info.feature(featureId)
    }
  }

  private func hasAccess(_ access: FeatureAccess?, requiredBalance: Int?) -> Bool {
    guard let access else { return false }
    if access.type == .boolean {
      return access.allowed
    }
    if access.unlimited {
      return true
    }
    let required = requiredBalance ?? 1
    return (access.balance ?? 0) >= required
  }
}
