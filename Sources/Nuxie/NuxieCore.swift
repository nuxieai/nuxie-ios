import FactoryKit
import Foundation

/// Composition root (cleanup Phase 4c). `NuxieSDK.setup` builds exactly one
/// `NuxieCore` per configuration; it resolves the object graph in explicit
/// dependency order and hands the facade typed references. During the
/// FactoryKit sunset the container still constructs the instances (so
/// `@Injected` sites and test registrations keep resolving the same
/// objects), but the facade reads services from here — never from the
/// container directly.
final class NuxieCore {
  let configuration: NuxieConfiguration

  // Built in dependency order: leaves first, then the event cluster the
  // rest of the graph observes, then the decision/services layer.
  let dateProvider: DateProviderProtocol
  let api: NuxieApiProtocol
  let identity: IdentityServiceProtocol
  let sessions: SessionServiceProtocol
  let eventLog: EventLogProtocol
  let profile: ProfileServiceProtocol
  let segments: SegmentServiceProtocol
  let journeys: JourneyServiceProtocol
  let features: FeatureServiceProtocol
  let flows: FlowServiceProtocol
  let triggers: TriggerServiceProtocol
  let transactionObserver: TransactionObserverProtocol
  let userTransitions: UserTransitionCoordinator

  /// Builds the graph for `configuration`. The configuration must already be
  /// registered with the container (setup does this first) so container-built
  /// services observe it.
  init(configuration: NuxieConfiguration) {
    self.configuration = configuration

    let container = Container.shared
    self.dateProvider = container.dateProvider()
    self.api = container.nuxieApi()
    self.identity = container.identityService()
    self.sessions = container.sessionService()
    self.eventLog = container.eventLog()
    self.profile = container.profileService()
    self.segments = container.segmentService()
    self.journeys = container.journeyService()
    self.features = container.featureService()
    self.flows = container.flowService()
    self.triggers = container.triggerService()
    self.transactionObserver = container.transactionObserver()
    self.userTransitions = container.userTransitionCoordinator()
  }
}
