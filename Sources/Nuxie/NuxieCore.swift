import Foundation

/// Explicit service overrides for tests. Any nil field builds the real
/// implementation. This is the only injection seam — there is no service
/// locator.
struct NuxieCoreOverrides {
  var dateProvider: DateProviderProtocol?
  var sleepProvider: SleepProviderProtocol?
  var api: NuxieApiProtocol?
  var identity: IdentityServiceProtocol?
  var sessions: SessionServiceProtocol?
  var eventLog: EventLogProtocol?
  var irRuntime: IRRuntime?
  var segments: SegmentServiceProtocol?
  var flows: ExperienceServiceProtocol?
  var profile: ProfileServiceProtocol?
  var featureInfo: FeatureInfo?
  var features: FeatureServiceProtocol?
  var triggerBroker: TriggerBrokerProtocol?
  var flowPresentation: ExperiencePresentationServiceProtocol?
  var goalEvaluator: GoalEvaluatorProtocol?
  var journeyStore: JourneyStoreProtocol?
  var journeys: JourneyServiceProtocol?
  var triggers: TriggerServiceProtocol?
  var productService: ProductService?
  var transactionObserver: TransactionObserverProtocol?
  var pendingPurchaseStore: PendingPurchaseStoreProtocol?
  var transactionService: TransactionService?
  var userTransitions: UserTransitionCoordinator?

  init() {}
}

/// Composition root (cleanup Phase 4c). `NuxieSDK.setup` builds exactly one
/// `NuxieCore` per configuration; it constructs the object graph directly in
/// explicit dependency order — leaves first, then the event cluster the rest
/// of the graph observes, then the decision/services layer.
final class NuxieCore {
  let configuration: NuxieConfiguration

  let dateProvider: DateProviderProtocol
  let sleepProvider: SleepProviderProtocol
  let api: NuxieApiProtocol
  let identity: IdentityServiceProtocol
  let sessions: SessionServiceProtocol
  let eventLog: EventLogProtocol
  let irRuntime: IRRuntime
  let segments: SegmentServiceProtocol
  let flows: ExperienceServiceProtocol
  let profile: ProfileServiceProtocol
  let featureInfo: FeatureInfo
  let features: FeatureServiceProtocol
  let triggerBroker: TriggerBrokerProtocol
  let flowPresentation: ExperiencePresentationServiceProtocol
  let goalEvaluator: GoalEvaluatorProtocol
  let journeyStore: JourneyStoreProtocol
  let journeys: JourneyServiceProtocol
  let triggers: TriggerServiceProtocol
  let productService: ProductService
  let transactionObserver: TransactionObserverProtocol
  let transactionService: TransactionService
  let userTransitions: UserTransitionCoordinator

  init(configuration: NuxieConfiguration, overrides: NuxieCoreOverrides = .init()) {
    self.configuration = configuration

    let dateProvider = overrides.dateProvider ?? SystemDateProvider()
    let sleepProvider = overrides.sleepProvider ?? SystemSleepProvider()
    let api = overrides.api ?? NuxieApi(
      apiKey: configuration.apiKey,
      baseURL: configuration.apiEndpoint,
      useGzipCompression: false,
      urlSession: configuration.urlSession
    )
    let identity = overrides.identity
      ?? IdentityService(customStoragePath: configuration.customStoragePath)
    let sessions = overrides.sessions ?? SessionService()
    let eventLog = overrides.eventLog ?? EventLog(
      identity: identity,
      sessions: sessions,
      dateProvider: dateProvider,
      apiClient: api
    )
    let irRuntime = overrides.irRuntime ?? IRRuntime(dateProvider: dateProvider)
    let segments = overrides.segments ?? SegmentService(
      identity: identity,
      dateProvider: dateProvider,
      irRuntime: irRuntime
    )

    // Deferred references break the two construction cycles in the graph
    // (flows → transactionService → observer → features → profile → flows,
    // and observer ↔ transactionService). The closures are only invoked
    // after init completes.
    var builtTransactionService: TransactionService!

    let productService = overrides.productService ?? ProductService()
    let flows = overrides.flows ?? ExperienceService(
      api: api,
      productService: productService,
      eventLog: eventLog,
      transactionServiceProvider: { builtTransactionService }
    )
    let profile = overrides.profile ?? ProfileService(
      identity: identity,
      api: api,
      segments: segments,
      flows: flows,
      dateProvider: dateProvider,
      sleepProvider: sleepProvider,
      customStoragePath: configuration.customStoragePath
    )
    let featureInfo = overrides.featureInfo ?? FeatureInfo()
    let features = overrides.features ?? FeatureService(
      api: api,
      identity: identity,
      profile: profile,
      dateProvider: dateProvider,
      featureInfo: featureInfo,
      configProvider: { configuration }
    )

    // Set-once wiring for the segments → irRuntime → features cycle.
    irRuntime.wire(
      identity: identity, eventLog: eventLog,
      segments: segments, features: features)

    let triggerBroker = overrides.triggerBroker ?? TriggerBroker()
    let flowPresentation = overrides.flowPresentation ?? ExperiencePresentationService(
      windowProvider: nil,
      flows: flows,
      eventLog: eventLog,
      triggerBroker: triggerBroker,
      dateProvider: dateProvider
    )
    let goalEvaluator = overrides.goalEvaluator ?? GoalEvaluator(
      eventLog: eventLog,
      segments: segments,
      features: features,
      identity: identity,
      dateProvider: dateProvider,
      irRuntime: irRuntime
    )
    let journeyStore = overrides.journeyStore ?? JourneyStore(
      customStoragePath: configuration.customStoragePath,
      dateProvider: dateProvider
    )
    let journeys = overrides.journeys ?? JourneyService(
      journeyStore: journeyStore,
      flows: flows,
      profile: profile,
      identity: identity,
      segments: segments,
      features: features,
      flowPresentation: flowPresentation,
      featureInfo: featureInfo,
      eventLog: eventLog,
      triggerBroker: triggerBroker,
      dateProvider: dateProvider,
      sleepProvider: sleepProvider,
      goalEvaluator: goalEvaluator,
      irRuntime: irRuntime,
      api: api
    )
    let triggers = overrides.triggers ?? TriggerService(
      eventLog: eventLog,
      journeys: journeys,
      features: features,
      flowPresentation: flowPresentation,
      featureInfo: featureInfo,
      triggerBroker: triggerBroker,
      sleepProvider: sleepProvider,
      dateProvider: dateProvider
    )
    let transactionObserver = overrides.transactionObserver ?? TransactionObserver(
      api: api,
      features: features,
      identity: identity,
      configurationProvider: { configuration },
      transactionServiceProvider: { builtTransactionService }
    )
    let pendingPurchaseStore = overrides.pendingPurchaseStore ?? PendingPurchaseStore(
      customStoragePath: configuration.customStoragePath
    )
    let transactionService = overrides.transactionService ?? TransactionService(
      productService: productService,
      transactionObserver: transactionObserver,
      pendingPurchaseStore: pendingPurchaseStore,
      dateProvider: dateProvider,
      configurationProvider: { configuration }
    )
    builtTransactionService = transactionService
    let userTransitions = overrides.userTransitions ?? UserTransitionCoordinator(
      profile: profile,
      segments: segments,
      eventLog: eventLog,
      features: features,
      flows: flows,
      journeysProvider: { journeys }
    )

    self.dateProvider = dateProvider
    self.sleepProvider = sleepProvider
    self.api = api
    self.identity = identity
    self.sessions = sessions
    self.eventLog = eventLog
    self.irRuntime = irRuntime
    self.segments = segments
    self.flows = flows
    self.profile = profile
    self.featureInfo = featureInfo
    self.features = features
    self.triggerBroker = triggerBroker
    self.flowPresentation = flowPresentation
    self.goalEvaluator = goalEvaluator
    self.journeyStore = journeyStore
    self.journeys = journeys
    self.triggers = triggers
    self.productService = productService
    self.transactionObserver = transactionObserver
    self.transactionService = transactionService
    self.userTransitions = userTransitions
  }
}
