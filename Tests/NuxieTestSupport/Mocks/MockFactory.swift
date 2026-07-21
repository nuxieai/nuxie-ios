import Foundation
import FactoryKit
@testable import Nuxie

/// Factory for creating and managing shared mock instances
public class MockFactory {
    public static let shared = MockFactory()

    private static let usageLock = NSLock()
    private static var _wasUsed = false
    
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
    private lazy var _eventLog = MockEventLog()
    private lazy var _eventStore = MockEventStore()
    private lazy var _nuxieApi = MockNuxieApi()
    private lazy var _flowService = MockExperienceService()
    private lazy var _flowPresentationService = MockExperiencePresentationService()
    private lazy var _triggerBroker = TriggerBroker()
    private lazy var _triggerService = TriggerService()
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
    public var triggerService: TriggerService { Self.markUsed(); return _triggerService }
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
    
    /// Register all services with mocks using Factory
    public func registerAll() {
        Self.markUsed()
        // Register test configuration (required for any services that depend on sdkConfiguration)
        let testConfig = NuxieConfiguration(apiKey: "test-api-key")
        Container.shared.sdkConfiguration.register { testConfig }

        Container.shared.identityService.register { self.identityService }
        Container.shared.segmentService.register { self.segmentService }
        // journeyStore is injected directly into JourneyService via constructor
        Container.shared.profileService.register { self.profileService }
        Container.shared.eventLog.register { self.eventLog }
        Container.shared.nuxieApi.register { self.nuxieApi }
        Container.shared.flowService.register { self.flowService }
        Container.shared.flowPresentationService.register { self.flowPresentationService }
        Container.shared.triggerBroker.register { self.triggerBroker }
        Container.shared.triggerService.register { self.triggerService }
        Container.shared.dateProvider.register { self.dateProvider }
        Container.shared.sleepProvider.register { self.sleepProvider }
        Container.shared.productService.register { self.productService }
    }
    
    /// Register services for integration tests - mocks external dependencies but uses real business logic
    public func registerForIntegrationTests() {
        Self.markUsed()
        // Register test configuration (required for any services that depend on sdkConfiguration)
        let testConfig = NuxieConfiguration(apiKey: "test-api-key")
        Container.shared.sdkConfiguration.register { testConfig }

        Container.shared.identityService.register { self.identityService }
        Container.shared.segmentService.register { self.segmentService }
        // journeyStore is injected directly into JourneyService via constructor
        Container.shared.profileService.register { self.profileService }
        Container.shared.eventLog.register { self.eventLog }
        Container.shared.nuxieApi.register { self.nuxieApi }
        Container.shared.flowService.register { self.flowService }
        // DON'T register flowPresentationService - let real implementation run for integration tests
        Container.shared.triggerBroker.register { self.triggerBroker }
        Container.shared.triggerService.register { self.triggerService }
        Container.shared.dateProvider.register { self.dateProvider }
        Container.shared.sleepProvider.register { self.sleepProvider }
        Container.shared.productService.register { self.productService }
    }
    
    /// Reset all Factory registrations
    public func resetAllFactories() {
        Self.markUsed()
        Container.shared.reset()
    }
}
