import Foundation

/// Explicit service overrides for tests. Any nil field builds the real
/// implementation. This is the only injection seam — there is no service
/// locator.
struct NuxieCoreOverrides {
  var dateProvider: DateProviderProtocol?
  var sleepProvider: SleepProviderProtocol?
  var api: NuxieApiProtocol?
  var identity: IdentityServiceProtocol?
  var eventLog: EventLogProtocol?
  var irRuntime: IRRuntime?
  var segments: SegmentServiceProtocol?
  var experiences: ExperienceServiceProtocol?
  var profile: ProfileServiceProtocol?
  var featureInfo: FeatureInfo?
  var featureUseCommandStore: FeatureUseCommandStoring?
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
  var deviceLegPresentation: (any DeviceLegPresenting)?
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
  let eventLog: EventLogProtocol
  let irRuntime: IRRuntime
  let segments: SegmentServiceProtocol
  let experiences: ExperienceServiceProtocol
  let deviceLegProfiles: DeviceLegProfileCatalog
  let deviceLegs: (any DeviceLegServiceProtocol)?
  let profile: ProfileServiceProtocol
  let featureInfo: FeatureInfo
  let featureUseCommands: FeatureUseCommandQueue
  let features: FeatureServiceProtocol
  let triggerBroker: TriggerBrokerProtocol
  let experiencePresentation: ExperiencePresentationServiceProtocol
  let deviceLegPresentation: any DeviceLegPresenting
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
    let eventLog = overrides.eventLog ?? EventLog(
      identity: identity,
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
    let builtTransactionObserver = LateBound<TransactionObserverProtocol>()
    let builtTriggerService = LateBound<TriggerServiceProtocol>()
    let builtFeatureService = LateBound<FeatureServiceProtocol>()
    let systemEvents = overrides.systemEvents ?? TriggerSystemEventSink(
      routedEvents: eventLog,
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
    let deviceLegProfiles = DeviceLegProfileCatalog(
      authorizationKeys: authorizationKeys,
      supportedRuntime: ExperienceReleaseRuntime.current,
      highWaterStore: highWaterStore
    )
    let profileStorageScope = ProfileStorageScope(
      apiKey: configuration.apiKey,
      environment: configuration.environment
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
    let triggerBroker = overrides.triggerBroker ?? TriggerBroker()
    let defaultExperiencePresentation = ExperiencePresentationService(
      windowProvider: nil,
      experiences: experiences,
      eventLog: eventLog,
      triggerBroker: triggerBroker,
      dateProvider: dateProvider
    )
    let experiencePresentation = overrides.experiencePresentation
      ?? defaultExperiencePresentation
    let deviceLegPresentation = overrides.deviceLegPresentation
      ?? defaultExperiencePresentation
    let deviceLegs: (any DeviceLegServiceProtocol)?
    if let timezones = SignedTimezoneBundle.installed {
      deviceLegs = DeviceLegService(
        identity: identity,
        events: eventLog,
        dateProvider: dateProvider,
        sleepProvider: sleepProvider,
        journalDirectory: releasePaths.admission,
        // The profile transport supplies the stable authenticated app scope.
        // The publishable key is rotatable and must not address durable runs.
        storageScope: nil,
        featureAccess: { featureId in
          await builtFeatureService.get().getCached(
            featureId: featureId,
            entityId: nil
          )
        },
        storeEntitlements: {
          guard !configuration.testStoreEnabled else { return [] }
          return await builtTransactionObserver.get().currentEntitledStoreProductIds()
        },
        dispatcher: DeviceLegEffectDispatcher(
          identity: identity,
          events: eventLog,
          appActionHandler: appActionHandler
        ),
        presenter: deviceLegPresentation,
        pinnedReleaseAuthenticator: { entry, reference in
          try await deviceLegProfiles.authenticatePinnedRelease(
            entry,
            reference: reference
          )
        },
        timezones: timezones
      )
    } else {
      LogError("Device-leg runtime unavailable: signed timezone bundle missing")
      deviceLegs = nil
    }
    let profile = overrides.profile ?? ProfileService(
      identity: identity,
      api: api,
      segments: segments,
      experiences: experiences,
      deviceLegProfiles: deviceLegProfiles,
      deviceLegRuntime: deviceLegs,
      eventLog: eventLog,
      dateProvider: dateProvider,
      sleepProvider: sleepProvider,
      localeProvider: localeProvider,
      storageScope: profileStorageScope,
      customStoragePath: internalConfiguration.customStoragePath
    )
    let featureInfo = overrides.featureInfo ?? FeatureInfo()
    let projectionPublicationEpoch = UUID()
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        featureInfo.beginOptimisticProjectionPublication(
          epoch: projectionPublicationEpoch,
          distinctId: identity.getDistinctId()
        )
      }
    } else {
      DispatchQueue.main.sync {
        featureInfo.beginOptimisticProjectionPublication(
          epoch: projectionPublicationEpoch,
          distinctId: identity.getDistinctId()
        )
      }
    }
    let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
    let featureUseCommands = FeatureUseCommandQueue(
      api: api,
      identity: identity,
      eventLog: eventLog,
      featureInfo: featureInfo,
      dateProvider: dateProvider,
      store: overrides.featureUseCommandStore ?? FeatureUseCommandStore(
        customStoragePath: internalConfiguration.customStoragePath,
        appIdentifier: appIdentifier,
        environment: configuration.environment
      )
    )
    let purchaseStorageScope = PurchaseStorageScope(
      appIdentifier: appIdentifier,
      environment: configuration.environment,
      testStoreEnabled: configuration.testStoreEnabled
    )
    let features = overrides.features ?? FeatureService(
      api: api,
      identity: identity,
      profile: profile,
      dateProvider: dateProvider,
      featureInfo: featureInfo,
      cacheTTL: internalConfiguration.featureCacheTTL
    )
    builtFeatureService.set(features)

    // Set-once wiring for the segments → irRuntime → features cycle.
    irRuntime.wire(
      identity: identity, eventLog: eventLog,
      segments: segments, features: features)

    let goalEvaluator = overrides.goalEvaluator ?? GoalEvaluator(
      eventLog: eventLog,
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
      triggerBroker: triggerBroker,
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
      descriptorAllowanceProvider: { evidence in
        await experiences.optimisticEntitlementAllowances(
          releaseDescriptorSHA256: evidence.commercialContext?
            .release.descriptorSHA256,
          productId: evidence.commercialContext?.productId,
          storeProductId: evidence.productId
        )
      },
      projectionPublisher: { evidence, allowances, distinctId, generation in
        await MainActor.run {
          featureInfo.replaceOptimisticProjection(
            evidence: evidence,
            descriptorAllowances: allowances,
            distinctId: distinctId,
            publicationEpoch: projectionPublicationEpoch,
            publicationGeneration: generation
          )
        }
      },
      purchaseStorageScope: purchaseStorageScope,
      dateProvider: dateProvider,
      recoverySources: overrides.transactionRecoverySources
    )
    builtTransactionObserver.set(transactionObserver)
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
      eventLog: eventLog,
      features: features,
      experiences: experiences,
      deviceLegs: deviceLegs,
      journeysProvider: { journeys }
    )

    self.dateProvider = dateProvider
    self.sleepProvider = sleepProvider
    self.api = api
    self.identity = identity
    self.eventLog = eventLog
    self.irRuntime = irRuntime
    self.segments = segments
    self.experiences = experiences
    self.deviceLegProfiles = deviceLegProfiles
    self.deviceLegs = deviceLegs
    self.profile = profile
    self.featureInfo = featureInfo
    self.featureUseCommands = featureUseCommands
    self.features = features
    self.triggerBroker = triggerBroker
    self.experiencePresentation = experiencePresentation
    self.deviceLegPresentation = deviceLegPresentation
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
