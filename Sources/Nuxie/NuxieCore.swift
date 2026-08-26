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
  var experiences: ExperienceServiceProtocol?
  var profile: ProfileServiceProtocol?
  var featureInfo: FeatureInfo?
  var features: FeatureServiceProtocol?
  var triggerBroker: TriggerBrokerProtocol?
  var experiencePresentation: ExperiencePresentationServiceProtocol?
  var goalEvaluator: GoalEvaluatorProtocol?
  var journeyStore: JourneyStoreProtocol?
  var journeys: JourneyServiceProtocol?
  var triggers: TriggerServiceProtocol?
  var productService: ProductService?
  var transactionObserver: TransactionObserverProtocol?
  var transactionRecoverySources: StoreTransactionRecoverySources?
  var pendingPurchaseStore: PendingPurchaseStoreProtocol?
  var purchaseAccountOwnershipStore: PurchaseAccountOwnershipStoreProtocol?
  var transactionService: TransactionService?
  var userTransitions: UserTransitionCoordinator?
  var systemEvents: SystemEventSink?
  var localeProvider: LocaleIdentifierProviding?
  var purchaseSettings: PurchaseSettingsProviding?
  var presentationTrace: ExperiencePresentationTraceRecording?
  /// Explicit test-host control. Nil preserves the legacy qualification-host
  /// behavior for callers that install a presentation trace recorder.
  var presentationDiagnosticsEnabled: Bool?
  /// Qualification-only correlation installed before lifecycle restoration
  /// begins so a relaunched presentation remains attributable to the current
  /// user-observed retry attempt.
  var restoredPresentationAttempt: ExperiencePresentationAttempt?
  var experienceWarmLoadsInitiallySuspended = false

  init(presentationDiagnosticsEnabled: Bool? = nil) {
    self.presentationDiagnosticsEnabled = presentationDiagnosticsEnabled
  }
}

/// Composition root (cleanup Phase 4c). `NuxieSDK.setup` builds exactly one
/// `NuxieCore` per configuration; it constructs the object graph directly in
/// explicit dependency order — leaves first, then the event cluster the rest
/// of the graph observes, then the decision/services layer.
// @unchecked Sendable: every stored property is an immutable `let` assigned
// once during init; the referenced services manage their own thread safety.
final class NuxieCore: @unchecked Sendable {
  let configuration: NuxieSetupConfiguration
  let runtimeSettings: NuxieRuntimeSettings

  let dateProvider: DateProviderProtocol
  let sleepProvider: SleepProviderProtocol
  let api: NuxieApiProtocol
  let identity: IdentityServiceProtocol
  let sessions: SessionServiceProtocol
  let eventLog: EventLogProtocol
  let irRuntime: IRRuntime
  let segments: SegmentServiceProtocol
  let experiences: ExperienceServiceProtocol
  let profile: ProfileServiceProtocol
  let featureInfo: FeatureInfo
  let features: FeatureServiceProtocol
  let triggerBroker: TriggerBrokerProtocol
  let experiencePresentation: ExperiencePresentationServiceProtocol
  let goalEvaluator: GoalEvaluatorProtocol
  let journeyStore: JourneyStoreProtocol
  let journeys: JourneyServiceProtocol
  let triggers: TriggerServiceProtocol
  let productService: ProductService
  let transactionObserver: TransactionObserverProtocol
  let transactionService: TransactionService
  let userTransitions: UserTransitionCoordinator
  let systemEvents: SystemEventSink
  let presentationTrace: ExperiencePresentationTraceRecording

  init(
    configuration: NuxieSetupConfiguration,
    runtimeSettings: NuxieRuntimeSettings,
    appActionHandler: @escaping @MainActor @Sendable (AppAction) -> Void = { _ in },
    overrides: NuxieCoreOverrides = .init()
  ) {
    self.configuration = configuration
    self.runtimeSettings = runtimeSettings

    let internalConfiguration = configuration.internalConfiguration
    let dateProvider = overrides.dateProvider ?? SystemDateProvider()
    let sleepProvider = overrides.sleepProvider ?? SystemSleepProvider()
    let presentationTrace = overrides.presentationTrace
      ?? DisabledExperiencePresentationTrace()
    let api = overrides.api ?? NuxieApi(
      apiKey: configuration.apiKey,
      baseURL: configuration.apiEndpoint,
      useGzipCompression: false,
      urlSession: internalConfiguration.urlSession
    )
    let identity = overrides.identity
      ?? IdentityService(customStoragePath: internalConfiguration.customStoragePath)
    let sessions = overrides.sessions ?? SessionService()
    let eventLog = overrides.eventLog ?? EventLog(
      identity: identity,
      sessions: sessions,
      dateProvider: dateProvider,
      apiClient: api
    )
    let irRuntime = overrides.irRuntime ?? IRRuntime(dateProvider: dateProvider)
    let segments = overrides.segments ?? SegmentService()

    // Deferred references break the two construction cycles in the graph
    // (experiences → transactionService → observer → features → profile → experiences,
    // and observer ↔ transactionService). The box is set at the end of init
    // and only read after init completes.
    let builtTransactionService = LateBound<TransactionService>()
    let builtTriggerService = LateBound<TriggerServiceProtocol>()
    let systemEvents = overrides.systemEvents ?? TriggerSystemEventSink(
      triggerProvider: { builtTriggerService.get() }
    )
    let localeProvider = overrides.localeProvider ?? runtimeSettings
    let purchaseSettings = overrides.purchaseSettings ?? runtimeSettings

    let productService = overrides.productService ?? ProductService()
    let introEligibilityTokenProvider = AppStoreIntroEligibilityTokenProvider(
      api: api
    )
    let introEligibilityOverrideHealth = IntroEligibilityOverrideHealth()
    let authorizationKeys: [ExperiencePackageAuthorizationKey]
    do {
      authorizationKeys = try ExperienceTrustRoots.keys(
        for: configuration.environment
      )
    } catch {
      LogError("Experience package trust roots unavailable: \(error)")
      authorizationKeys = []
    }
    let releasePaths = ExperienceReleaseStoragePaths.resolve(
      customStoragePath: internalConfiguration.customStoragePath,
      cachesDirectory: FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory,
      applicationSupportDirectory: FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    )
    let highWaterStore: any ExperienceReleaseHighWaterStore
    if let admissionDirectory = releasePaths.admission {
      do {
        highWaterStore = try PersistentExperienceReleaseHighWaterStore(
          directory: admissionDirectory
        )
      } catch {
        LogError("Experience release replay store unavailable: \(error)")
        highWaterStore = UnavailableExperienceReleaseHighWaterStore()
      }
    } else {
      LogError("Experience release replay store unavailable: Application Support directory missing")
      highWaterStore = UnavailableExperienceReleaseHighWaterStore()
    }
    let releaseStore = ExperienceReleaseAcquisitionStore(
      cacheDirectory: releasePaths.objects,
      urlSession: internalConfiguration.urlSession ?? .shared,
      authorizationKeys: authorizationKeys,
      supportedRuntime: ExperienceReleaseRuntime.current,
      admission: ExperienceReleaseAdmission(store: highWaterStore)
    )
    let experiences = overrides.experiences ?? ExperienceService(
      productService: productService,
      introEligibilityTokenProvider: introEligibilityTokenProvider,
      introEligibilityOverrideHealth: introEligibilityOverrideHealth,
      eventLog: eventLog,
      transactionServiceProvider: { builtTransactionService.get() },
      systemEventSink: systemEvents,
      releaseStore: releaseStore,
      presentationDiagnosticsEnabled:
        internalConfiguration.presentationDiagnosticsEnabled
          || (overrides.presentationDiagnosticsEnabled
            ?? (overrides.presentationTrace != nil)),
      warmLoadsInitiallySuspended: overrides.experienceWarmLoadsInitiallySuspended,
      testStoreEnabled: configuration.testStoreEnabled
    )
    let profile = overrides.profile ?? ProfileService(
      identity: identity,
      api: api,
      segments: segments,
      experiences: experiences,
      eventLog: eventLog,
      dateProvider: dateProvider,
      sleepProvider: sleepProvider,
      localeProvider: localeProvider,
      customStoragePath: internalConfiguration.customStoragePath
    )
    let featureInfo = overrides.featureInfo ?? FeatureInfo()
    let purchaseStorageScope = PurchaseStorageScope(
      appIdentifier: Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app",
      environment: configuration.environment,
      testStoreEnabled: configuration.testStoreEnabled
    )
    let localPurchaseAccessStore = LocalPurchaseAccessStore(
      customStoragePath: internalConfiguration.customStoragePath,
      scope: purchaseStorageScope
    )
    let features = overrides.features ?? FeatureService(
      api: api,
      identity: identity,
      profile: profile,
      dateProvider: dateProvider,
      featureInfo: featureInfo,
      cacheTTL: internalConfiguration.featureCacheTTL,
      localPurchaseAccessStore: localPurchaseAccessStore
    )

    // Set-once wiring for the segments → irRuntime → features cycle.
    irRuntime.wire(
      identity: identity, eventLog: eventLog,
      segments: segments, features: features)

    let triggerBroker = overrides.triggerBroker ?? TriggerBroker()
    let experiencePresentation = overrides.experiencePresentation ?? ExperiencePresentationService(
      windowProvider: nil,
      experiences: experiences,
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
      customStoragePath: internalConfiguration.customStoragePath,
      dateProvider: dateProvider
    )
    let journeys = overrides.journeys ?? JourneyService(
      journeyStore: journeyStore,
      experiences: experiences,
      profile: profile,
      identity: identity,
      segments: segments,
      features: features,
      experiencePresentation: experiencePresentation,
      featureInfo: featureInfo,
      eventLog: eventLog,
      triggerBroker: triggerBroker,
      dateProvider: dateProvider,
      sleepProvider: sleepProvider,
      goalEvaluator: goalEvaluator,
      irRuntime: irRuntime,
      api: api,
      appActionHandler: appActionHandler,
      presentationTrace: presentationTrace,
      restoredPresentationAttempt: overrides.restoredPresentationAttempt
    )
    let triggers = overrides.triggers ?? TriggerService(
      eventLog: eventLog,
      journeys: journeys,
      features: features,
      experiencePresentation: experiencePresentation,
      featureInfo: featureInfo,
      triggerBroker: triggerBroker,
      sleepProvider: sleepProvider,
      dateProvider: dateProvider,
      presentationTrace: presentationTrace
    )
    builtTriggerService.set(triggers)
    let transactionObserver = overrides.transactionObserver ?? TransactionObserver(
      api: api,
      features: features,
      identity: identity,
      settings: purchaseSettings,
      eventSink: systemEvents,
      transactionServiceProvider: { builtTransactionService.get() },
      evidenceStore: TransactionEvidenceStore(
        customStoragePath: internalConfiguration.customStoragePath,
        scope: purchaseStorageScope
      ),
      localAccessStore: localPurchaseAccessStore,
      purchaseStorageScope: purchaseStorageScope,
      dateProvider: dateProvider,
      recoverySources: overrides.transactionRecoverySources
    )
    let pendingPurchaseStore = overrides.pendingPurchaseStore ?? PendingPurchaseStore(
      customStoragePath: internalConfiguration.customStoragePath,
      scope: purchaseStorageScope
    )
    let accountOwnershipStore = overrides.purchaseAccountOwnershipStore
      ?? PurchaseAccountOwnershipStore(
        customStoragePath: internalConfiguration.customStoragePath,
        scope: purchaseStorageScope
      )
    let testStore: (any NuxieTestStorePurchasing)? = configuration.testStoreEnabled
      ? NuxieTestStore()
      : nil
    let transactionService = overrides.transactionService ?? TransactionService(
      productService: productService,
      transactionObserver: transactionObserver,
      pendingPurchaseStore: pendingPurchaseStore,
      accountOwnershipStore: accountOwnershipStore,
      dateProvider: dateProvider,
      settings: purchaseSettings,
      eventSink: systemEvents,
      purchaseStorageScope: purchaseStorageScope,
      identityService: identity,
      introEligibilityTokenProvider: introEligibilityTokenProvider,
      introEligibilityOverrideHealth: introEligibilityOverrideHealth,
      featureService: features,
      testStore: testStore,
      activeProductEvidenceAuthority: { storeProductId in
        await experiences.purchaseEvidenceAuthority(
          storeProductId: storeProductId
        )
      }
    )
    builtTransactionService.set(transactionService)
    experiences.setProductAuthorityChangeHandler { [weak transactionObserver] in
      guard let transactionObserver else { return }
      Task { [weak transactionObserver] in
        await transactionObserver?.retryAfterProfileReady()
      }
    }
    let userTransitions = overrides.userTransitions ?? UserTransitionCoordinator(
      profile: profile,
      segments: segments,
      eventLog: eventLog,
      features: features,
      experiences: experiences,
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
    self.experiences = experiences
    self.profile = profile
    self.featureInfo = featureInfo
    self.features = features
    self.triggerBroker = triggerBroker
    self.experiencePresentation = experiencePresentation
    self.goalEvaluator = goalEvaluator
    self.journeyStore = journeyStore
    self.journeys = journeys
    self.triggers = triggers
    self.productService = productService
    self.transactionObserver = transactionObserver
    self.transactionService = transactionService
    self.userTransitions = userTransitions
    self.systemEvents = systemEvents
    self.presentationTrace = presentationTrace
  }

  convenience init(
    configuration: NuxieConfiguration,
    appActionHandler: @escaping @MainActor @Sendable (AppAction) -> Void = { _ in },
    overrides: NuxieCoreOverrides = .init()
  ) {
    self.init(
      configuration: NuxieSetupConfiguration(configuration),
      runtimeSettings: NuxieRuntimeSettings(configuration: configuration),
      appActionHandler: appActionHandler,
      overrides: overrides
    )
  }
}
