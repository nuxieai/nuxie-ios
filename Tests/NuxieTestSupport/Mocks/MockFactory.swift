import Foundation
@testable import Nuxie

private final class InMemoryFeatureUseCommandStore:
    FeatureUseCommandStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var commands: [FeatureUseCommand] = []

    func load() throws -> [FeatureUseCommand] {
        lock.withLock { commands }
    }

    func save(_ commands: [FeatureUseCommand]) throws {
        lock.withLock { self.commands = commands }
    }

    func reset() {
        lock.withLock { commands = [] }
    }
}

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
    private lazy var _profileService = MockProfileService()
    private lazy var _eventLog: MockEventLog = {
        let log = MockEventLog()
        log.identity = self._identityService
        return log
    }()
    private lazy var _eventStore = MockEventStore()
    private lazy var _nuxieApi = MockNuxieApi()
    private lazy var _experienceService = MockExperienceService()
    private lazy var _experiencePresentationService = MockExperiencePresentationService()
    private lazy var _dateProvider = MockDateProvider()
    private lazy var _sleepProvider = MockSleepProvider()
    private lazy var _productService = MockProductService()
    private lazy var _featureUseCommandStore = InMemoryFeatureUseCommandStore()
    
    // Public accessors
    public var identityService: MockIdentityService { Self.markUsed(); return _identityService }
    public var profileService: MockProfileService { Self.markUsed(); return _profileService }
    public var eventLog: MockEventLog { Self.markUsed(); return _eventLog }
    public var eventStore: MockEventStore { Self.markUsed(); return _eventStore }
    public var nuxieApi: MockNuxieApi { Self.markUsed(); return _nuxieApi }
    var experienceService: MockExperienceService { Self.markUsed(); return _experienceService }
    var experiencePresentationService: MockExperiencePresentationService { Self.markUsed(); return _experiencePresentationService }
    public var dateProvider: MockDateProvider { Self.markUsed(); return _dateProvider }
    public var sleepProvider: MockSleepProvider { Self.markUsed(); return _sleepProvider }
    public var productService: MockProductService { Self.markUsed(); return _productService }
    
    /// Reset all mock services to their initial state
    public func resetAll() async {
        Self.markUsed()
        identityService.reset()
        profileService.reset()
        eventLog.reset()
        await eventStore.reset()
        await nuxieApi.reset()
        experienceService.reset()
        await experiencePresentationService.reset()
        dateProvider.reset()
        sleepProvider.reset()
        productService.reset()
        _featureUseCommandStore.reset()
    }
    
    /// Overrides that replace every collaborator with the shared mocks.
    /// Pass to `NuxieSDK.shared.setup(with:overrides:)` or `NuxieCore(configuration:overrides:)`.
    func unitTestOverrides() -> NuxieCoreOverrides {
        Self.markUsed()
        var overrides = NuxieCoreOverrides()
        overrides.identity = identityService
        overrides.profile = profileService
        overrides.eventLog = eventLog
        overrides.api = nuxieApi
        overrides.experiences = experienceService
        overrides.experiencePresentation = experiencePresentationService
        overrides.dateProvider = dateProvider
        overrides.sleepProvider = sleepProvider
        overrides.productService = productService
        overrides.featureUseCommandStore = _featureUseCommandStore
        return overrides
    }

    /// Overrides for integration tests - mocks external dependencies but keeps
    /// the real presentation service (and other real business logic) running.
    func integrationOverrides() -> NuxieCoreOverrides {
        var overrides = unitTestOverrides()
        // Let the real implementation run for integration tests.
        overrides.experiencePresentation = nil
        return overrides
    }

}
