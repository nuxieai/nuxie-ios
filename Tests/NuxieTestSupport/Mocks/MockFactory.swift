import Foundation
@testable import Nuxie

/// Factory for creating and managing shared mock instances
// @unchecked Sendable: the lazy mock instances are created during
// single-threaded test setup and are themselves thread-safe; the usage flag
// is guarded by `usageLock`.
public final class MockFactory: @unchecked Sendable {
    public static let shared = MockFactory()

    private static let usageLock = NSLock()
    // nonisolated(unsafe): only accessed under `usageLock`.
    private nonisolated(unsafe) static var _wasUsed = false
    
    private init() {}

    static func resetUsageFlag() {
        usageLock.lock()
        _wasUsed = false
        usageLock.unlock()
    }

    static func markUsed() {
        usageLock.lock()
        _wasUsed = true
        usageLock.unlock()
    }

    static var wasUsed: Bool {
        usageLock.lock()
        defer { usageLock.unlock() }
        return _wasUsed
    }
    
    // Lazy instances - these will use the individual mock files
    private lazy var _identityService = MockIdentityService()
    private lazy var _segmentService = MockSegmentService()
    private lazy var _journeyStore = MockJourneyStore()
    private lazy var _profileService = MockProfileService()
    private lazy var _eventLog: MockEventLog = {
        let log = MockEventLog()
        log.identity = self._identityService
        return log
    }()
    private lazy var _eventStore = MockEventStore()
    private lazy var _nuxieApi = MockNuxieApi()
    private lazy var _flowService = MockExperienceService()
    private lazy var _flowPresentationService: MockExperiencePresentationService = {
        let service = MockExperiencePresentationService()
        service.eventLog = self._eventLog
        return service
    }()
    private lazy var _triggerBroker = TriggerBroker()
    private lazy var _dateProvider = MockDateProvider()
    private lazy var _sleepProvider = MockSleepProvider()
    private lazy var _productService = MockProductService()
    
    // Public accessors
    public var identityService: MockIdentityService { Self.markUsed(); return _identityService }
    public var segmentService: MockSegmentService { Self.markUsed(); return _segmentService }
    public var journeyStore: MockJourneyStore { Self.markUsed(); return _journeyStore }
    public var profileService: MockProfileService { Self.markUsed(); return _profileService }
    public var eventLog: MockEventLog { Self.markUsed(); return _eventLog }
    public var eventStore: MockEventStore { Self.markUsed(); return _eventStore }
    public var nuxieApi: MockNuxieApi { Self.markUsed(); return _nuxieApi }
    public var flowService: MockExperienceService { Self.markUsed(); return _flowService }
    public var flowPresentationService: MockExperiencePresentationService { Self.markUsed(); return _flowPresentationService }
    public var triggerBroker: TriggerBroker { Self.markUsed(); return _triggerBroker }
    public var dateProvider: MockDateProvider { Self.markUsed(); return _dateProvider }
    public var sleepProvider: MockSleepProvider { Self.markUsed(); return _sleepProvider }
    public var productService: MockProductService { Self.markUsed(); return _productService }
    
    /// Reset all mock services to their initial state
    public func resetAll() async {
        Self.markUsed()
        identityService.reset()
        await segmentService.reset()
        journeyStore.reset()
        profileService.reset()
        eventLog.reset()
        await eventStore.reset()
        await nuxieApi.reset()
        flowService.reset()
        flowPresentationService.reset()
        await triggerBroker.reset()
        dateProvider.reset()
        sleepProvider.reset()
        productService.reset()
    }
    
    /// Overrides that replace every collaborator with the shared mocks.
    /// Pass to `NuxieSDK.shared.setup(with:overrides:)` or `NuxieCore(configuration:overrides:)`.
    func unitTestOverrides() -> NuxieCoreOverrides {
        Self.markUsed()
        var overrides = NuxieCoreOverrides()
        overrides.identity = identityService
        overrides.segments = segmentService
        overrides.profile = profileService
        overrides.eventLog = eventLog
        overrides.api = nuxieApi
        overrides.flows = flowService
        overrides.flowPresentation = flowPresentationService
        overrides.triggerBroker = triggerBroker
        overrides.dateProvider = dateProvider
        overrides.sleepProvider = sleepProvider
        overrides.productService = productService
        return overrides
    }

    /// Overrides for integration tests - mocks external dependencies but keeps
    /// the real presentation service (and other real business logic) running.
    func integrationOverrides() -> NuxieCoreOverrides {
        var overrides = unitTestOverrides()
        // Let the real implementation run for integration tests.
        overrides.flowPresentation = nil
        return overrides
    }

    /// Builds a real JourneyService over the shared mocks, plus a real
    /// feature service / goal evaluator / IR runtime. Mirrors the collaborator
    /// graph journey tests previously received from container defaults.
    func makeJourneyService(
        journeyStore: JourneyStoreProtocol,
        flowPresentation: ExperiencePresentationServiceProtocol? = nil
    ) -> JourneyService {
        Self.markUsed()
        let config = NuxieConfiguration(apiKey: "test-api-key")
        let featureInfo = FeatureInfo()
        let irRuntime = IRRuntime(dateProvider: dateProvider)
        let features = FeatureService(
            api: nuxieApi,
            identity: identityService,
            profile: profileService,
            dateProvider: dateProvider,
            featureInfo: featureInfo,
            configProvider: { config }
        )
        irRuntime.wire(
            identity: identityService,
            eventLog: eventLog,
            segments: segmentService,
            features: features
        )
        let goalEvaluator = GoalEvaluator(
            eventLog: eventLog,
            segments: segmentService,
            features: features,
            identity: identityService,
            dateProvider: dateProvider,
            irRuntime: irRuntime
        )
        return JourneyService(
            journeyStore: journeyStore,
            flows: flowService,
            profile: profileService,
            identity: identityService,
            segments: segmentService,
            features: features,
            flowPresentation: flowPresentation ?? flowPresentationService,
            featureInfo: featureInfo,
            eventLog: eventLog,
            triggerBroker: triggerBroker,
            dateProvider: dateProvider,
            sleepProvider: sleepProvider,
            goalEvaluator: goalEvaluator,
            irRuntime: irRuntime,
            api: nuxieApi
        )
    }
}
