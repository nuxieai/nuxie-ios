import Foundation

// MARK: - Segment reference collection

extension IRExpr {
  /// Segment ids referenced by `segment` nodes anywhere in this expression.
  /// Drives Phase 9 segment scoping: only segments an experience can actually
  /// observe are evaluated on-device.
  public var referencedSegmentIds: Set<String> {
    var ids = Set<String>()
    collectSegmentIds(into: &ids)
    return ids
  }

  private func collectSegmentIds(into ids: inout Set<String>) {
    switch self {
    case .bool, .number, .string, .timestamp, .duration, .timeNow,
      .timeWindow, .journeyId, .unknown:
      break

    case .list(let items):
      for item in items { item.collectSegmentIds(into: &ids) }

    case .and(let items), .or(let items), .predAnd(let items), .predOr(let items):
      for item in items { item.collectSegmentIds(into: &ids) }

    case .not(let inner):
      inner.collectSegmentIds(into: &ids)

    case .compare(_, let left, let right):
      left.collectSegmentIds(into: &ids)
      right.collectSegmentIds(into: &ids)

    case .user(_, _, let value), .event(_, _, let value), .pred(_, _, let value),
      .feature(_, _, let value):
      value?.collectSegmentIds(into: &ids)

    case .segment(_, let id, let within):
      ids.insert(id)
      within?.collectSegmentIds(into: &ids)

    case .eventsExists(_, let since, let until, let within, let where_),
      .eventsCount(_, let since, let until, let within, let where_):
      since?.collectSegmentIds(into: &ids)
      until?.collectSegmentIds(into: &ids)
      within?.collectSegmentIds(into: &ids)
      where_?.collectSegmentIds(into: &ids)

    case .eventsFirstTime(_, let where_), .eventsLastTime(_, let where_),
      .eventsLastAge(_, let where_):
      where_?.collectSegmentIds(into: &ids)

    case .eventsAggregate(_, _, _, let since, let until, let within, let where_):
      since?.collectSegmentIds(into: &ids)
      until?.collectSegmentIds(into: &ids)
      within?.collectSegmentIds(into: &ids)
      where_?.collectSegmentIds(into: &ids)

    case .eventsInOrder(let steps, let overallWithin, let perStepWithin, let since, let until):
      for step in steps { step.where_?.collectSegmentIds(into: &ids) }
      overallWithin?.collectSegmentIds(into: &ids)
      perStepWithin?.collectSegmentIds(into: &ids)
      since?.collectSegmentIds(into: &ids)
      until?.collectSegmentIds(into: &ids)

    case .eventsActivePeriods(_, _, _, _, let where_):
      where_?.collectSegmentIds(into: &ids)

    case .eventsStopped(_, let inactiveFor, let where_):
      inactiveFor.collectSegmentIds(into: &ids)
      where_?.collectSegmentIds(into: &ids)

    case .eventsRestarted(_, let inactiveFor, let within, let where_):
      inactiveFor.collectSegmentIds(into: &ids)
      within.collectSegmentIds(into: &ids)
      where_?.collectSegmentIds(into: &ids)

    case .timeAgo(let duration):
      duration.collectSegmentIds(into: &ids)
    }
  }
}

extension IREnvelope {
  public var referencedSegmentIds: Set<String> { expr.referencedSegmentIds }
}

extension Campaign {
  /// Every segment id this experience can observe: the trigger condition,
  /// plus goal configuration (segment goals and IR filters).
  public var referencedSegmentIds: Set<String> {
    var ids = Set<String>()
    switch trigger {
    case .event(let config):
      if let condition = config.condition {
        ids.formUnion(condition.referencedSegmentIds)
      }
    case .segment(let config):
      ids.formUnion(config.condition.referencedSegmentIds)
    }
    if let goal {
      if let segmentId = goal.segmentId {
        ids.insert(segmentId)
      }
      if let eventFilter = goal.eventFilter {
        ids.formUnion(eventFilter.referencedSegmentIds)
      }
      if let attributeExpr = goal.attributeExpr {
        ids.formUnion(attributeExpr.referencedSegmentIds)
      }
    }
    return ids
  }
}
