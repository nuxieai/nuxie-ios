import _Concurrency
import Foundation

/// Progressive updates emitted by `trigger(...)`.
public enum TriggerUpdate: Equatable, Sendable {
  case decision(TriggerDecision)
  /// Feature-access evaluation progressed or reached a terminal outcome.
  case featureAccess(FeatureAccessUpdate)
  case journey(JourneyUpdate)
  case error(TriggerError)
}

/// High-level trigger decisions (experience-level).
public enum TriggerDecision: Equatable, Sendable {
  case noMatch
  case suppressed(SuppressReason)
  /// A journey started with the selected experience.
  case journeyStarted(ExperienceRef)
  /// The matched experience was successfully presented.
  case experienceShown(ExperienceRef)
  case allowedImmediate
  case deniedImmediate
}

/// Feature-access updates for gated experiences.
public enum FeatureAccessUpdate: Equatable, Sendable {
  /// Feature access is still being evaluated.
  case pending
  /// Feature access is allowed.
  case allowed
  /// Feature access is denied.
  case denied
}

/// Stable identity for an experience selected by a trigger.
public struct ExperienceRef: Equatable, Sendable {
  /// Stable experience definition identifier.
  public let experienceId: String
  /// Exact published experience version, when available.
  public let experienceVersion: String?
  /// Stable journey identifier, when the experience belongs to a journey.
  public let journeyId: String?

  /// Creates a reference to a selected experience.
  ///
  /// - Parameters:
  ///   - experienceId: Stable experience definition identifier.
  ///   - experienceVersion: Exact published version, when available.
  ///   - journeyId: Stable journey identifier, when available.
  public init(experienceId: String, experienceVersion: String?, journeyId: String?) {
    self.experienceId = experienceId
    self.experienceVersion = experienceVersion
    self.journeyId = journeyId
  }
}

/// Reasons a matched journey was not started.
public enum SuppressReason: Equatable, Sendable {
  /// The journey is already active.
  case alreadyActive
  /// The journey's reentry limit prevents another enrollment.
  case reentryLimited
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

/// An error produced while processing a trigger.
public struct TriggerError: Error, Equatable, Sendable {
  /// Stable machine-readable trigger error codes.
  public enum Code: String, Equatable, Sendable {
    /// The SDK has not been configured.
    case notConfigured = "not_configured"
    /// Trigger processing failed.
    case triggerFailed = "trigger_failed"
    /// The trigger response did not identify an experience to present.
    case experienceMissing = "experience_missing"
    /// The trigger response did not identify a feature to evaluate.
    case featureMissing = "feature_missing"
    /// Feature access was not granted before the configured timeout.
    case featureAccessTimeout = "feature_access_timeout"
    /// The selected experience could not be presented.
    case experiencePresentFailed = "experience_present_failed"
  }

  /// The stable machine-readable error code.
  public let code: Code
  /// A human-readable description of the failure.
  public let message: String

  init(code: Code, message: String) {
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
  /// Feature access is allowed.
  case allowed
  /// Access denied.
  case denied
  /// A journey ran to completion without a feature-access decision.
  case journeyCompleted(JourneyUpdate)
  /// The trigger failed.
  case error(TriggerError)

  /// Canonical wire encoding (fixtures/encodings/trigger-result.json) —
  /// the serialized shape RN/Flutter/Unity wrappers bind to.
  @_spi(Testing)
  public var wireValue: [String: String] {
    switch self {
    case .noMatch:
      return ["result": "no_match"]
    case .allowed:
      return ["result": "allowed"]
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
      return ["result": "error", "code": error.code.rawValue]
    }
  }
}
