import Foundation

/// Environment settings
public enum Environment: String, Sendable {
    case production = "production"
    @_spi(Companion) case staging = "staging"
    case development = "development"

    var defaultEndpoint: URL {
        switch self {
        case .production:
            return URL(string: "https://i.nuxie.ai")!
        case .staging:
            return URL(string: "https://staging-i.nuxie.ai")!
        case .development:
            return URL(string: "https://dev-i.nuxie.ai")!
        }
    }
}

/// Log levels
public enum LogLevel: String, Sendable {
    case verbose = "verbose"
    case debug = "debug"
    case info = "info"
    case warning = "warning"
    case error = "error"
    case none = "none"
}

/// Test-only overrides for engine configuration that is intentionally absent
/// from the customer setup interface. Production defaults remain internal.
@_spi(Testing)
public struct NuxieTestingOverrides: Sendable {
    /// Overrides the selected environment's ingest endpoint.
    public var apiEndpoint: URL?

    /// Overrides the delivery retry limit (production default: 3).
    public var retryCount: Int?

    /// Overrides the base delivery retry delay in seconds (production default: 2).
    public var retryDelay: TimeInterval?

    /// Overrides the maximum number of events sent per batch (production default: 50).
    public var eventBatchSize: Int?

    /// Overrides the pending-event count that triggers a flush (production default: 20).
    public var flushAt: Int?

    /// Overrides the periodic flush interval in seconds (production default: 30).
    public var flushInterval: TimeInterval?

    /// Overrides the in-memory delivery queue capacity (production default: 1,000).
    public var maxQueueSize: Int?

    /// Overrides the root directory used by SDK persistence.
    public var customStoragePath: URL?

    /// Overrides the feature cache lifetime in seconds (production default: 300).
    public var featureCacheTTL: TimeInterval?

    /// Overrides the URL session used by SDK network clients.
    public var urlSession: URLSession?

    /// Suppresses SDK-owned periodic and startup work for deterministic tests.
    /// The production default is false, including when XCTest is attached.
    public var suppressBackgroundWork = false

    /// Enables accessibility diagnostics used by presentation qualification hosts.
    public var presentationDiagnosticsEnabled = false

    /// Creates an empty overlay that preserves every production default.
    public init() {}
}

/// Engine-owned defaults and test overrides. Keeping this value internal
/// prevents delivery/storage/cache tuning from leaking through the SDK facade.
struct NuxieInternalConfiguration: Sendable {
    let apiEndpointOverride: URL?
    let retryCount: Int
    let retryDelay: TimeInterval
    let eventBatchSize: Int
    let flushAt: Int
    let flushInterval: TimeInterval
    let maxQueueSize: Int
    let customStoragePath: URL?
    let featureCacheTTL: TimeInterval
    let urlSession: URLSession?
    let suppressBackgroundWork: Bool
    let presentationDiagnosticsEnabled: Bool

    init(testingOverrides: NuxieTestingOverrides = .init()) {
        apiEndpointOverride = testingOverrides.apiEndpoint
        retryCount = testingOverrides.retryCount ?? 3
        retryDelay = testingOverrides.retryDelay ?? 2
        eventBatchSize = testingOverrides.eventBatchSize ?? 50
        flushAt = testingOverrides.flushAt ?? 20
        flushInterval = testingOverrides.flushInterval ?? 30
        maxQueueSize = testingOverrides.maxQueueSize ?? 1_000
        customStoragePath = testingOverrides.customStoragePath
        featureCacheTTL = testingOverrides.featureCacheTTL ?? 5 * 60
        urlSession = testingOverrides.urlSession
        suppressBackgroundWork = testingOverrides.suppressBackgroundWork
        presentationDiagnosticsEnabled = testingOverrides.presentationDiagnosticsEnabled
    }
}

/// Configuration object for initializing Nuxie SDK
/// This builder is mutable only until `NuxieSDK.setup`. Setup snapshots every
/// value. Later mutations do not reconfigure a running SDK; use the explicit
/// runtime controls on `NuxieSDK` for locale and purchase behavior.
public class NuxieConfiguration {
    /// Required: API key for authentication
    public let apiKey: String

    /// Environment setting
    public var environment: Environment = .production

    /// Internal engine overrides exposed only to SDK test harnesses.
    @_spi(Testing)
    public var testingOverrides = NuxieTestingOverrides()

    /// Enables the isolated iOS-only Nuxie Test Store for local purchase qualification.
    ///
    /// Test Store mode is accepted only with a development environment and a
    /// `pk_test_` API key. It never uses StoreKit, a configured purchase
    /// delegate, or production purchase/reporting.
    public var testStoreEnabled: Bool = false
    
    /// Logging settings
    public var logLevel: LogLevel = .warning
    public var enableConsoleLogging: Bool = true
    /// Replaces interpolated identifiers, payloads, paths, and error details
    /// with process-stable HMAC-SHA-256 summaries in console logs. Disable only
    /// for an explicitly consented diagnostic session because raw values may
    /// be logged.
    public var redactSensitiveData: Bool = true
    
    /// Initial locale selected during `setup(with:)`.
    /// When nil, the SDK uses the device locale. After setup, call
    /// `NuxieSDK.setLocaleIdentifier(_:)` to change it for the next launch or
    /// foreground profile synchronization.
    public var localeIdentifier: String?

    /// Optional hook for event transformation and filtering.
    ///
    /// Application lifecycle events are always captured. Return nil here to
    /// drop any event, including `$app_installed`, `$app_updated`,
    /// `$app_opened`, or `$app_backgrounded`.
    public var beforeSend: (@Sendable (NuxieEvent) -> NuxieEvent?)?
    
    /// How the SDK handles StoreKit transactions it observes.
    public enum PurchaseHandlingMode: Sendable {
        /// Nuxie owns native transaction lifecycle: verified transactions are
        /// durably synced to the backend and finished (default).
        case full
        /// The host or its billing provider owns StoreKit finishing. Nuxie may
        /// still observe and durably sync native transactions, but never calls
        /// `Transaction.finish()`. A signed provider Connector remains the
        /// separate authority that suppresses Nuxie's receipt sync as well.
        case observer
    }

    /// Transaction finishing ownership (default: `.full`). Set `.observer`
    /// when your app or another SDK owns StoreKit finishing. Configuring a
    /// purchase delegate does not mutate this explicit ownership choice.
    public var purchaseHandlingMode: PurchaseHandlingMode = .full

    /// Optional purchase delegate for RevenueCat, Superwall, or custom checkout.
    /// When nil, Nuxie purchases and restores directly through StoreKit.
    public var purchaseDelegate: NuxiePurchaseDelegate?
    
    /// Creates the mutable setup builder with the required Nuxie API key.
    /// `NuxieSDK.setup(with:)` snapshots its values.
    /// - Parameter apiKey: The publishable key for the selected Nuxie app and environment.
    public init(apiKey: String) {
        self.apiKey = apiKey
    }
}

/// Validates the mutable public builder before any runtime state is published.
/// Keeping every numeric invariant at this seam prevents downstream delivery,
/// timer, and cache modules from each needing defensive configuration checks.
enum NuxieConfigurationValidator {
    static let maximumDeliveryCount = Int(Int32.max)
    private static let nanosecondsPerSecond: TimeInterval = 1_000_000_000
    private static let maximumSchedulableSeconds =
        TimeInterval(UInt64.max) / nanosecondsPerSecond

    static func validate(_ configuration: NuxieInternalConfiguration) throws {
        try requireSupportedDeliveryCount(
            configuration.eventBatchSize,
            field: "eventBatchSize"
        )
        try requireSupportedDeliveryCount(configuration.flushAt, field: "flushAt")
        try requireSupportedDeliveryCount(
            configuration.maxQueueSize,
            field: "maxQueueSize"
        )
        guard configuration.flushAt <= configuration.maxQueueSize else {
            throw NuxieError.invalidConfiguration(
                "flushAt must not exceed maxQueueSize"
            )
        }

        guard configuration.retryCount >= 0 else {
            throw NuxieError.invalidConfiguration("retryCount must be nonnegative")
        }
        try requireFiniteNonnegative(configuration.retryDelay, field: "retryDelay")
        try requireFinitePositive(configuration.flushInterval, field: "flushInterval")
        try requireFinitePositive(configuration.featureCacheTTL, field: "featureCacheTTL")

        guard configuration.flushInterval < maximumSchedulableSeconds else {
            throw NuxieError.invalidConfiguration(
                "flushInterval is too large to schedule safely"
            )
        }
        guard configuration.flushInterval * nanosecondsPerSecond >= 1 else {
            throw NuxieError.invalidConfiguration(
                "flushInterval is too small to schedule safely"
            )
        }

        let retryExponent = max(configuration.retryCount - 1, 0)
        let retryMultiplier = pow(2, TimeInterval(retryExponent))
        let maximumRetryDelay = configuration.retryDelay * retryMultiplier
        guard retryMultiplier.isFinite,
              maximumRetryDelay.isFinite,
              maximumRetryDelay < maximumSchedulableSeconds else {
            throw NuxieError.invalidConfiguration(
                "retryCount and retryDelay produce an unschedulable backoff"
            )
        }
    }

    private static func requireSupportedDeliveryCount(_ value: Int, field: String) throws {
        guard (1...maximumDeliveryCount).contains(value) else {
            throw NuxieError.invalidConfiguration(
                "\(field) must be between 1 and \(maximumDeliveryCount)"
            )
        }
    }

    private static func requireFiniteNonnegative(
        _ value: TimeInterval,
        field: String
    ) throws {
        guard value.isFinite, value >= 0 else {
            throw NuxieError.invalidConfiguration("\(field) must be finite and nonnegative")
        }
    }

    private static func requireFinitePositive(
        _ value: TimeInterval,
        field: String
    ) throws {
        guard value.isFinite, value > 0 else {
            throw NuxieError.invalidConfiguration("\(field) must be finite and greater than zero")
        }
    }
}

/// Immutable setup input shared by the internal service graph.
struct NuxieSetupConfiguration: Sendable {
    let apiKey: String
    let apiEndpoint: URL
    let environment: Environment
    let testStoreEnabled: Bool
    let logLevel: LogLevel
    let enableConsoleLogging: Bool
    let redactSensitiveData: Bool
    let beforeSend: (@Sendable (NuxieEvent) -> NuxieEvent?)?
    let internalConfiguration: NuxieInternalConfiguration

    init(_ configuration: NuxieConfiguration) {
        let internalConfiguration = NuxieInternalConfiguration(
            testingOverrides: configuration.testingOverrides
        )
        apiKey = configuration.apiKey
        environment = configuration.environment
        apiEndpoint = internalConfiguration.apiEndpointOverride
            ?? configuration.environment.defaultEndpoint
        testStoreEnabled = configuration.testStoreEnabled
        logLevel = configuration.logLevel
        enableConsoleLogging = configuration.enableConsoleLogging
        redactSensitiveData = configuration.redactSensitiveData
        beforeSend = configuration.beforeSend
        self.internalConfiguration = internalConfiguration
    }
}
