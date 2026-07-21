import Foundation
import FactoryKit

/// Central place to build IR EvalContext + IRInterpreter consistently
final class IRRuntime {
  // Dependency for date only
  @Injected(\.dateProvider) private var dateProvider: DateProviderProtocol

  init() {}

  // MARK: - Config

  /// Per-evaluation customization knobs
  struct Config {
    /// Override "now" (defaults to dateProvider.now())
    var now: Date? = nil

    /// Provide event for predicate evaluation (e.g., trigger context)
    var event: NuxieEvent? = nil

    /// User property adapter
    var user: IRUserProps? = nil

    /// Event queries adapter
    var events: IREventQueries? = nil

    /// Segment queries adapter
    var segments: IRSegmentQueries? = nil

    /// Feature queries adapter
    var features: IRFeatureQueries? = nil

    /// Current journey ID for goal scoping
    var journeyId: String? = nil

    init(
      now: Date? = nil,
      event: NuxieEvent? = nil,
      user: IRUserProps? = nil,
      events: IREventQueries? = nil,
      segments: IRSegmentQueries? = nil,
      features: IRFeatureQueries? = nil,
      journeyId: String? = nil
    ) {
      self.now = now
      self.event = event
      self.user = user
      self.events = events
      self.segments = segments
      self.features = features
      self.journeyId = journeyId
    }
  }

  // MARK: - Factory

  /// Build a ready-to-use EvalContext (single code path used everywhere)
  func makeContext(_ cfg: Config = .init()) async -> EvalContext {
    return EvalContext(
      now: cfg.now ?? dateProvider.now(),
      user: cfg.user,
      events: cfg.events,
      segments: cfg.segments,
      features: cfg.features,
      event: cfg.event,
      journeyId: cfg.journeyId
    )
  }

  /// Convenience: build an interpreter directly
  func makeInterpreter(_ cfg: Config = .init()) async -> IRInterpreter {
    let ctx = await makeContext(cfg)
    return IRInterpreter(ctx: ctx)
  }

  /// One-liner: evaluate an envelope to Bool with optional config
  func eval(_ envelope: IREnvelope?, _ cfg: Config = .init()) async -> Bool {
    guard let envelope = envelope else { return true }
    do { 
      let interpreter = await makeInterpreter(cfg)
      return try await interpreter.evalBool(envelope.expr) 
    }
    catch {
      NuxieLogger.shared.error("IR evaluation failed: \(error)")
      return false
    }
  }
}

// MARK: - Config Helpers

extension IRRuntime.Config {
  /// Create config with just an event
  static func withEvent(_ event: NuxieEvent) -> Self { 
    .init(event: event) 
  }
  
  /// Create config with a specific date
  static func at(_ date: Date) -> Self { 
    .init(now: date) 
  }
  
  /// Create config with adapters
  static func withAdapters(
    user: IRUserProps? = nil,
    events: IREventQueries? = nil,
    segments: IRSegmentQueries? = nil,
    features: IRFeatureQueries? = nil
  ) -> Self {
    .init(user: user, events: events, segments: segments, features: features)
  }

  /// The standard four-adapter assembly over the live services. Every
  /// evaluation site uses this instead of hand-assembling adapters.
  /// Services resolve from the DI container until the Phase 4c composition
  /// root injects them; `segments` accepts an override so SegmentService can
  /// pass itself (direct-constructed instances in tests are not the
  /// container-resolved instance).
  static func standard(
    now: Date? = nil,
    event: NuxieEvent? = nil,
    journeyId: String? = nil,
    distinctId: String? = nil,
    additionalEvents: [StoredEvent] = [],
    segments segmentService: SegmentServiceProtocol? = nil
  ) -> Self {
    .init(
      now: now,
      event: event,
      user: IRUserPropsAdapter(identityService: Container.shared.identityService()),
      events: IREventQueriesAdapter(
        eventLog: Container.shared.eventLog(),
        distinctId: distinctId,
        additionalEvents: additionalEvents
      ),
      segments: IRSegmentQueriesAdapter(
        segmentService: segmentService ?? Container.shared.segmentService()
      ),
      features: IRFeatureQueriesAdapter(featureService: Container.shared.featureService()),
      journeyId: journeyId
    )
  }
}