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
  func trigger(
    _ event: String,
    properties: sending [String: Any]?,
    handler: @escaping @Sendable (TriggerUpdate) -> Void
  ) async
}

extension TriggerServiceProtocol {
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
  private let triggerBroker: TriggerBrokerProtocol
  private let dateProvider: DateProviderProtocol
  private let presentationTrace: ExperiencePresentationTraceRecording

  init(
    eventLog: EventTriggerTracking,
    journeys: JourneyServiceProtocol,
    triggerBroker: TriggerBrokerProtocol,
    dateProvider: DateProviderProtocol,
    presentationTrace: ExperiencePresentationTraceRecording = DisabledExperiencePresentationTrace()
  ) {
    self.eventLog = eventLog
    self.journeyService = journeys
    self.triggerBroker = triggerBroker
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
      let (nuxieEvent, _) = try await eventLog.trackForTrigger(
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
      let broker = triggerBroker
      let journeyStartFlag = LockedFlag()
      let journeyErrorFlag = LockedFlag()
      let shouldCompleteUpdate: @Sendable (TriggerUpdate) -> Bool = { update in
        switch update {
        case .error:
          return true
        case .decision(let decision):
          switch decision {
          case .noMatch:
            return true
          case .suppressed:
            return !journeyStartFlag.get() && !journeyErrorFlag.get()
          case .experienceShown, .journeyStarted:
            return false
          }
        case .journey:
          return true
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

      if emittedJourneyDecision {
        return
      }

      await broker.emit(eventId: eventId, update: .decision(.noMatch))
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
