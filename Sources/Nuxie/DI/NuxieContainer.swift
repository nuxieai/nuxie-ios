import FactoryKit
import Foundation

// MARK: - Container Extensions

extension Scope {
  /// All config-dependent services live in here. Reset this when setup/shutdown changes config.
  static let sdk = Cached()
}

extension Container {

  /// The active configuration injected by NuxieSDK.setup(...).
  /// Accessing this before setup should be a programmer error.
  var sdkConfiguration: Factory<NuxieConfiguration> {
    self { fatalError("NuxieSDK.setup(with:) must be called before resolving sdkConfiguration") }
      .scope(.sdk)
  }

  // MARK: - Core Services

  var nuxieApi: Factory<NuxieApiProtocol> {
    self {
      let config = self.sdkConfiguration()
      return NuxieApi(
        apiKey: config.apiKey,
        baseURL: config.apiEndpoint,
        useGzipCompression: false,
        urlSession: config.urlSession
      )
    }
    .scope(.sdk)
  }

  var identityService: Factory<IdentityServiceProtocol> {
    self { 
      let config = self.sdkConfiguration()
      return IdentityService(customStoragePath: config.customStoragePath)
    }
    .scope(.sdk)
  }

  var profileService: Factory<ProfileServiceProtocol> {
    self { 
      let config = self.sdkConfiguration()
      return ProfileService(customStoragePath: config.customStoragePath)
    }
    .scope(.sdk)
  }

  var sessionService: Factory<SessionServiceProtocol> {
    self { SessionService() }
      .scope(.sdk)
  }


  var eventLog: Factory<EventLogProtocol> {
    self {
      // Composition order is explicit (Phase 4c): the log's collaborators
      // are built before it and injected — no lazy resolution inside.
      EventLog(
        identity: self.identityService(),
        sessions: self.sessionService(),
        dateProvider: self.dateProvider(),
        apiClient: self.nuxieApi()
      )
    }
    .scope(.sdk)
  }

  var triggerBroker: Factory<TriggerBrokerProtocol> {
    self { TriggerBroker() }
      .scope(.sdk)
  }

  var triggerService: Factory<TriggerServiceProtocol> {
    self { TriggerService() }
      .scope(.sdk)
  }

  var segmentService: Factory<SegmentServiceProtocol> {
    self { SegmentService() }
      .scope(.sdk)
  }

  var flowService: Factory<FlowServiceProtocol> {
    self { FlowService() }
      .scope(.sdk)
  }

  var featureService: Factory<FeatureServiceProtocol> {
    self { FeatureService() }
      .scope(.sdk)
  }

  var featureInfo: Factory<FeatureInfo> {
    self { @MainActor in FeatureInfo() }
      .scope(.sdk)
  }

  var flowPresentationService: Factory<FlowPresentationServiceProtocol> {
    self { @MainActor in FlowPresentationService(windowProvider: nil) }
      .scope(.sdk)
  }

  // MARK: - Date Provider

  var dateProvider: Factory<DateProviderProtocol> {
    self { SystemDateProvider() }
      .scope(.sdk)
  }

  // MARK: - Sleep Provider

  var sleepProvider: Factory<SleepProviderProtocol> {
    self { SystemSleepProvider() }
      .scope(.sdk)
  }

  var goalEvaluator: Factory<GoalEvaluatorProtocol> {
    Factory(self) { GoalEvaluator() }
  }

  // MARK: - StoreKit Services

  var productService: Factory<ProductService> {
    self { ProductService() }
      .scope(.sdk)
  }

  var transactionService: Factory<TransactionService> {
    self { TransactionService() }
      .scope(.sdk)
  }

  var transactionObserver: Factory<TransactionObserverProtocol> {
    self { TransactionObserver() }
      .scope(.sdk)
  }

  var userTransitionCoordinator: Factory<UserTransitionCoordinator> {
    self { UserTransitionCoordinator() }
      .scope(.sdk)
  }

  // MARK: - Journey Services

  var journeyService: Factory<JourneyServiceProtocol> {
    self {
      let config = self.sdkConfiguration()
      return JourneyService(customStoragePath: config.customStoragePath)
    }
    .scope(.sdk)
  }

  /// Centralized IR runtime for context building and evaluation
  var irRuntime: Factory<IRRuntime> {
    Factory(self) { IRRuntime() }
      .scope(.sdk)
  }

}
