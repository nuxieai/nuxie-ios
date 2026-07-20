import FactoryKit
import Foundation

// MARK: - Goal Evaluator Protocol

/// Protocol for evaluating journey goals
public protocol GoalEvaluatorProtocol {
  /// Check if a journey's goal has been met
  /// - Parameters:
  ///   - journey: The journey to evaluate
  ///   - campaign: The campaign containing the flow
  /// - Returns: Tuple of (met: whether goal was met, at: when it was met)
  func isGoalMet(
    journey: Journey,
    campaign: Campaign,
    transientEvents: [StoredEvent]
  ) async -> (met: Bool, at: Date?)
}

public extension GoalEvaluatorProtocol {
  func isGoalMet(journey: Journey, campaign: Campaign) async -> (met: Bool, at: Date?) {
    await isGoalMet(journey: journey, campaign: campaign, transientEvents: [])
  }
}

private final class EventHistoryCache {
  var events: [StoredEvent]?

  init(events: [StoredEvent]? = nil) {
    self.events = events
  }
}

// MARK: - Goal Evaluator Implementation

/// Service for evaluating journey goals against user behavior
public actor GoalEvaluator: GoalEvaluatorProtocol {

  // MARK: - Dependencies

  @Injected(\.eventService) private var eventService: EventServiceProtocol
  @Injected(\.segmentService) private var segmentService: SegmentServiceProtocol
  @Injected(\.featureService) private var featureService: FeatureServiceProtocol
  @Injected(\.identityService) private var identityService: IdentityServiceProtocol
  @Injected(\.dateProvider) private var dateProvider: DateProviderProtocol
  @Injected(\.irRuntime) private var irRuntime: IRRuntime

  // MARK: - Initialization

  public init() {}

  // MARK: - Public Methods

  /// Check if a journey's goal has been met
  public func isGoalMet(
    journey: Journey,
    campaign: Campaign,
    transientEvents: [StoredEvent]
  ) async -> (met: Bool, at: Date?) {
    guard let goal = journey.goalSnapshot else {
      // No goal configured - never met
      return (false, nil)
    }

    let anchor = journey.conversionAnchorAt

    // Evaluate based on goal type
    switch goal.kind {
    case .event:
      return await evaluateEventGoal(goal, journey: journey, anchor: anchor, transientEvents: transientEvents)

    case .segmentEnter:
      return await evaluateSegmentEnterGoal(goal, journey: journey, anchor: anchor)

    case .segmentLeave:
      return await evaluateSegmentLeaveGoal(goal, journey: journey, anchor: anchor)

    case .attribute:
      return await evaluateAttributeGoal(goal, journey: journey, anchor: anchor, transientEvents: transientEvents)
    }
  }

  // MARK: - Private Methods

  private func evaluateEventGoal(
    _ goal: GoalConfig,
    journey: Journey,
    anchor: Date,
    transientEvents: [StoredEvent] = []
  ) async -> (
    met: Bool, at: Date?
  ) {
    guard let eventName = goal.eventName else {
      LogError("Event goal missing event name")
      return (false, nil)
    }

    LogDebug("[GoalEvaluator] Evaluating event goal '\(eventName)' for journey \(journey.id)")
    LogDebug("[GoalEvaluator] Journey anchor: \(anchor), window: \(journey.conversionWindow)")
    LogDebug("[GoalEvaluator] Journey.convertedAt: \(String(describing: journey.convertedAt))")

    // Event-time semantics:
    // - We only care whether the qualifying event's *timestamp* lies within the window.
    // - We do NOT reject just because "now" is past the window (late evaluation is OK).

    // If already latched by JourneyService, trust that.
    if let convertedAt = journey.convertedAt {
      LogDebug("[GoalEvaluator] Already converted at \(convertedAt), returning true")
      return (true, convertedAt)
    }

    let lastEventTime = await findLastMatchingEventTime(
      name: eventName,
      filter: goal.eventFilter,
      journey: journey,
      anchor: anchor,
      additionalEvents: transientEvents
    )
    guard let lastEventTime else {
      LogDebug("[GoalEvaluator] No qualifying event found within window, returning false")
      return (false, nil)
    }

    LogDebug("[GoalEvaluator] Goal met! Returning true with time \(lastEventTime)")
    return (true, lastEventTime)
  }

  private func evaluateSegmentEnterGoal(_ goal: GoalConfig, journey: Journey, anchor: Date) async
    -> (met: Bool, at: Date?)
  {
    guard let segmentId = goal.segmentId else {
      LogError("Segment enter goal missing segment ID")
      return (false, nil)
    }

    // Check if we're within the conversion window for segment goals
    let now = dateProvider.now()
    if journey.conversionWindow > 0 {
      let windowEnd = anchor.addingTimeInterval(journey.conversionWindow)
      if now > windowEnd {
        LogDebug(
          "Segment enter goal evaluation outside conversion window for journey \(journey.id)")
        return (false, nil)
      }
    }

    // Segment memberships are tracked for the CURRENT user only. A journey
    // belonging to a previous identity (e.g. during a logout/login window)
    // must not convert on the new user's membership.
    guard journey.distinctId == identityService.getDistinctId() else {
      return (false, nil)
    }

    let isMember = await segmentService.isInSegment(segmentId)

    if isMember {
      return (true, now)
    }

    return (false, nil)
  }

  private func evaluateSegmentLeaveGoal(_ goal: GoalConfig, journey: Journey, anchor: Date) async
    -> (met: Bool, at: Date?)
  {
    guard let segmentId = goal.segmentId else {
      LogError("Segment leave goal missing segment ID")
      return (false, nil)
    }

    // Check if we're within the conversion window for segment goals
    let now = dateProvider.now()
    if journey.conversionWindow > 0 {
      let windowEnd = anchor.addingTimeInterval(journey.conversionWindow)
      if now > windowEnd {
        LogDebug(
          "Segment leave goal evaluation outside conversion window for journey \(journey.id)")
        return (false, nil)
      }
    }

    // Segment memberships are tracked for the CURRENT user only. A journey
    // belonging to a previous identity (e.g. during a logout/login window)
    // must not convert on the new user's membership.
    guard journey.distinctId == identityService.getDistinctId() else {
      return (false, nil)
    }

    let isMember = await segmentService.isInSegment(segmentId)

    if !isMember {
      return (true, now)
    }

    return (false, nil)
  }

  private func evaluateAttributeGoal(
    _ goal: GoalConfig,
    journey: Journey,
    anchor: Date,
    transientEvents: [StoredEvent] = []
  ) async -> (
    met: Bool, at: Date?
  ) {
    guard let attributeExpr = goal.attributeExpr else {
      LogError("Attribute goal missing expression")
      return (false, nil)
    }

    LogDebug("[GoalEvaluator] Evaluating attribute goal for journey \(journey.id)")
    LogDebug("[GoalEvaluator] Journey anchor: \(anchor), window: \(journey.conversionWindow)")

    if let eventOnlyResult = await evaluateEventOnlyAttributeExpr(
      attributeExpr.expr,
      journey: journey,
      anchor: anchor,
      transientEvents: transientEvents
    ) {
      if eventOnlyResult.met {
        LogDebug("[GoalEvaluator] Event-only attribute goal met at \(String(describing: eventOnlyResult.at))")
      }
      return eventOnlyResult
    }

    // Check if we're within the conversion window for attribute goals
    let now = dateProvider.now()
    if journey.conversionWindow > 0 {
      let windowEnd = anchor.addingTimeInterval(journey.conversionWindow)
      LogDebug("[GoalEvaluator] Window end: \(windowEnd), now: \(now)")
      if now > windowEnd {
        LogDebug("[GoalEvaluator] Attribute goal evaluation outside conversion window")
        LogDebug("Attribute goal evaluation outside conversion window for journey \(journey.id)")
        return (false, nil)
      }
    }

    // Use centralized IR runtime for evaluation with adapters
    let userAdapter = IRUserPropsAdapter(identityService: identityService)
    let eventsAdapter = IREventQueriesAdapter(
      eventService: eventService,
      distinctId: journey.distinctId,
      additionalEvents: transientEvents
    )
    let segmentsAdapter = IRSegmentQueriesAdapter(segmentService: segmentService)
    let featuresAdapter = IRFeatureQueriesAdapter(featureService: featureService)

    let config = IRRuntime.Config(
      user: userAdapter,
      events: eventsAdapter,
      segments: segmentsAdapter,
      features: featuresAdapter,
      journeyId: journey.id
    )

    LogDebug("[GoalEvaluator] Evaluating IR expression: \(attributeExpr)")
    let result = await irRuntime.eval(attributeExpr, config)
    LogDebug("[GoalEvaluator] IR evaluation result: \(result)")
    
    if result {
      LogDebug("[GoalEvaluator] Attribute goal met! Returning true with time \(now)")
      return (true, now)
    }

    LogDebug("[GoalEvaluator] Attribute goal not met, returning false")
    return (false, nil)
  }

  private func windowEnd(for journey: Journey, anchor: Date) -> Date? {
    journey.conversionWindow > 0 ? anchor.addingTimeInterval(journey.conversionWindow) : nil
  }

  private func findLastMatchingEventTime(
    name: String,
    filter: IREnvelope?,
    journey: Journey,
    anchor: Date,
    allEvents: [StoredEvent]? = nil,
    additionalEvents: [StoredEvent] = []
  ) async -> Date? {
    let windowEnd = windowEnd(for: journey, anchor: anchor)
    if filter == nil {
      let persistedLastEventTime = await eventService.getLastEventTime(
        name: name,
        distinctId: journey.distinctId,
        since: anchor,
        until: windowEnd
      )
      let transientLastEventTime = additionalEvents
        .filter { $0.name == name }
        .filter { event in
          if event.timestamp < anchor { return false }
          if let end = windowEnd, event.timestamp > end { return false }
          return true
        }
        .map(\.timestamp)
        .max()

      switch (persistedLastEventTime, transientLastEventTime) {
      case let (.some(persisted), .some(transient)):
        return max(persisted, transient)
      case let (.some(persisted), nil):
        return persisted
      case let (nil, .some(transient)):
        return transient
      case (nil, nil):
        return nil
      }
    }

    let baseEvents: [StoredEvent]
    if let allEvents {
      baseEvents = allEvents
    } else {
      baseEvents = await eventService.getEventsForUser(journey.distinctId, limit: 1000)
    }
    let candidateEvents = mergeEvents(
      primary: baseEvents,
      secondary: additionalEvents
    )

    guard let filter else { return nil }

    let matchingEvents = candidateEvents
      .filter { $0.name == name }
      .filter { event in
        if event.timestamp < anchor { return false }
        if let end = windowEnd, event.timestamp > end { return false }
        return true
      }
      .sorted { $0.timestamp > $1.timestamp }

    for storedEvent in matchingEvents {
      let nuxieEvent = NuxieEvent(
        name: storedEvent.name,
        distinctId: storedEvent.distinctId,
        properties: storedEvent.getPropertiesDict(),
        timestamp: storedEvent.timestamp
      )

      let config = IRRuntime.Config(
        event: nuxieEvent,
        journeyId: journey.id
      )

      let filterMatches = await irRuntime.eval(filter, config)

      if filterMatches {
        return storedEvent.timestamp
      }
    }

    return nil
  }

  private func evaluateEventOnlyAttributeExpr(
    _ expr: IRExpr,
    journey: Journey,
    anchor: Date,
    eventCache: EventHistoryCache = EventHistoryCache(),
    transientEvents: [StoredEvent] = []
  ) async -> (met: Bool, at: Date?)? {
    func getCachedEvents() async -> [StoredEvent] {
      if let cachedEvents = eventCache.events {
        return cachedEvents
      }
      let loadedEvents = mergeEvents(
        primary: await eventService.getEventsForUser(journey.distinctId, limit: 1000),
        secondary: transientEvents
      )
      eventCache.events = loadedEvents
      return loadedEvents
    }

    switch expr {
    case .and(let args):
      var times: [Date] = []
      for arg in args {
        guard let result = await evaluateEventOnlyAttributeExpr(
          arg,
          journey: journey,
          anchor: anchor,
          eventCache: eventCache,
          transientEvents: transientEvents
        ) else {
          return nil
        }
        guard result.met else {
          return (false, nil)
        }
        if let at = result.at {
          times.append(at)
        }
      }
      return (true, times.max())

    case .or(let args):
      var times: [Date] = []
      for arg in args {
        guard let result = await evaluateEventOnlyAttributeExpr(
          arg,
          journey: journey,
          anchor: anchor,
          eventCache: eventCache,
          transientEvents: transientEvents
        ) else {
          return nil
        }
        if let at = result.at, result.met {
          times.append(at)
        }
      }
      if let firstMetAt = times.min() {
        return (true, firstMetAt)
      }
      return (false, nil)

    case .eventsExists(let name, let since, let until, let within, let where_):
      guard since == nil, until == nil, within == nil else {
        return nil
      }
      let filter = IREnvelope(
        ir_version: 1,
        engine_min: nil,
        compiled_at: nil,
        expr: where_ ?? .bool(true)
      )
      let lastEventTime = await findLastMatchingEventTime(
        name: name,
        filter: filter,
        journey: journey,
        anchor: anchor,
        allEvents: await getCachedEvents()
      )
      if let lastEventTime {
        return (true, lastEventTime)
      }
      return (false, nil)

    default:
      return nil
    }
  }

  private func mergeEvents(primary: [StoredEvent], secondary: [StoredEvent]) -> [StoredEvent] {
    guard !secondary.isEmpty else { return primary }
    var seen = Set<String>()
    var merged: [StoredEvent] = []
    for event in primary + secondary {
      if seen.insert(event.id).inserted {
        merged.append(event)
      }
    }
    return merged
  }
}
