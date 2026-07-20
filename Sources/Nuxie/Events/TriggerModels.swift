import _Concurrency
import Foundation

/// Progressive updates emitted by `trigger(...)`.
public enum TriggerUpdate: Equatable {
  case decision(TriggerDecision)
  case entitlement(EntitlementUpdate)
  case journey(JourneyUpdate)
  case error(TriggerError)
}

/// High-level trigger decisions (campaign-level).
public enum TriggerDecision: Equatable {
  case noMatch
  case suppressed(SuppressReason)
  case journeyStarted(JourneyRef)
  case journeyResumed(JourneyRef)
  case flowShown(JourneyRef)
  case allowedImmediate
  case deniedImmediate
}

/// Entitlement-specific updates for gated flows.
public enum EntitlementUpdate: Equatable {
  case pending
  case allowed(source: GateSource)
  case denied
}

public struct JourneyRef: Equatable {
  public let journeyId: String
  public let campaignId: String
  public let flowId: String?

  public init(journeyId: String, campaignId: String, flowId: String?) {
    self.journeyId = journeyId
    self.campaignId = campaignId
    self.flowId = flowId
  }
}

public enum SuppressReason: Equatable {
  case alreadyActive
  case reentryLimited
  case holdout
  case noFlow
  case unknown(String)
}

public struct JourneyUpdate: Equatable {
  public let journeyId: String
  public let campaignId: String
  public let flowId: String?
  public let exitReason: JourneyExitReason
  public let goalMet: Bool

  public init(
    journeyId: String,
    campaignId: String,
    flowId: String?,
    exitReason: JourneyExitReason,
    goalMet: Bool
  ) {
    self.journeyId = journeyId
    self.campaignId = campaignId
    self.flowId = flowId
    self.exitReason = exitReason
    self.goalMet = goalMet
  }
}

public enum GateSource: Equatable {
  case cache
  case purchase
  case restore
}

public struct TriggerError: Error, Equatable {
  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

/// Terminal outcome of a trigger — the single answer to "what ultimately
/// happened". Use `triggerAndWait(...)` to await it, or the progress callback
/// on `trigger(...)` for intermediate journey-lifecycle updates.
public enum TriggerResult: Equatable {
  /// No experience matched; the event was tracked.
  case noMatch
  /// Access allowed (already entitled, or granted during the journey).
  case allowed(source: GateSource?)
  /// Access denied.
  case denied
  /// A journey ran to completion without an entitlement decision.
  case journeyCompleted(JourneyUpdate)
  /// The trigger failed.
  case error(TriggerError)

  /// Canonical wire encoding (fixtures/encodings/trigger-result.json) —
  /// the serialized shape RN/Flutter/Unity wrappers bind to.
  public var wireValue: [String: String] {
    switch self {
    case .noMatch:
      return ["result": "no_match"]
    case .allowed(let source):
      var v = ["result": "allowed"]
      if let source { v["source"] = String(describing: source) }
      return v
    case .denied:
      return ["result": "denied"]
    case .journeyCompleted(let update):
      return [
        "result": "journey_completed",
        "journey_id": update.journeyId,
        "exit_reason": update.exitReason.rawValue,
        "goal_met": update.goalMet ? "true" : "false",
      ]
    case .error(let error):
      return ["result": "error", "code": error.code]
    }
  }
}
