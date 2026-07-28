import _Concurrency
import Foundation

/// Progressive updates emitted by `trigger(...)`.
public enum TriggerUpdate: Equatable, Sendable {
  case decision(TriggerDecision)
  case entitlement(EntitlementUpdate)
  case journey(JourneyUpdate)
  case error(TriggerError)
}

/// High-level trigger decisions (experience-level).
public enum TriggerDecision: Equatable, Sendable {
  case noMatch
  case suppressed(SuppressReason)
  case journeyStarted(JourneyRef)
  case journeyResumed(JourneyRef)
  /// The matched experience was successfully presented.
  case experienceShown(JourneyRef)
  case allowedImmediate
  case deniedImmediate
}

/// Entitlement-specific updates for gated flows.
public enum EntitlementUpdate: Equatable, Sendable {
  case pending
  case allowed(source: GateSource)
  case denied
}

/// Stable identity for a journey and its selected experience version.
public struct JourneyRef: Equatable, Sendable {
  /// Stable journey identifier.
  public let journeyId: String
  /// Stable experience definition identifier.
  public let experienceId: String
  /// Exact published version selected for this journey, when available.
  public let experienceVersion: String?

  /// Creates a reference to a journey and its selected experience.
  ///
  /// - Parameters:
  ///   - journeyId: Stable journey identifier.
  ///   - experienceId: Stable experience definition identifier.
  ///   - experienceVersion: Exact published version, when available.
  public init(journeyId: String, experienceId: String, experienceVersion: String?) {
    self.journeyId = journeyId
    self.experienceId = experienceId
    self.experienceVersion = experienceVersion
  }
}

public enum SuppressReason: Equatable, Sendable {
  case alreadyActive
  case reentryLimited
  case holdout
  case noFlow
  case unknown(String)
}

/// Terminal journey details emitted by the trigger API.
public struct JourneyUpdate: Equatable, Sendable {
  /// Stable journey identifier.
  public let journeyId: String
  /// Stable experience definition identifier.
  public let experienceId: String
  /// Exact published version used by the journey, when available.
  public let experienceVersion: String?
  /// Reason execution ended.
  public let exitReason: JourneyExitReason
  /// Whether the journey met its conversion goal.
  public let goalMet: Bool

  /// Creates a terminal journey update.
  ///
  /// - Parameters:
  ///   - journeyId: Stable journey identifier.
  ///   - experienceId: Stable experience definition identifier.
  ///   - experienceVersion: Exact published version, when available.
  ///   - exitReason: Reason execution ended.
  ///   - goalMet: Whether the conversion goal was met.
  public init(
    journeyId: String,
    experienceId: String,
    experienceVersion: String?,
    exitReason: JourneyExitReason,
    goalMet: Bool
  ) {
    self.journeyId = journeyId
    self.experienceId = experienceId
    self.experienceVersion = experienceVersion
    self.exitReason = exitReason
    self.goalMet = goalMet
  }
}

public enum GateSource: Equatable, Sendable {
  case cache
  case purchase
  case restore
}

public struct TriggerError: Error, Equatable, Sendable {
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
public enum TriggerResult: Equatable, Sendable {
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
