import Foundation

/// Environment settings
public enum Environment: String, Sendable {
    case production = "production"
    case staging = "staging"
    case development = "development"
    case custom = "custom"

    var defaultEndpoint: URL? {
        switch self {
        case .production:
            return URL(string: "https://i.nuxie.ai")!
        case .staging:
            return URL(string: "https://staging-i.nuxie.ai")!
        case .development:
            return URL(string: "https://dev-i.nuxie.ai")!
        case .custom:
            // .custom has no default — the integrator must set apiEndpoint.
            return nil
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

/// Configuration object for initializing Nuxie SDK
/// This builder is mutable only until `NuxieSDK.setup`. Setup snapshots every
/// value. Later mutations do not reconfigure a running SDK; use the explicit
/// runtime controls on `NuxieSDK` for locale and purchase behavior.
public class NuxieConfiguration {
    /// Required: API key for authentication
    public let apiKey: String
    
    /// API endpoint. Reads the environment's default unless explicitly set;
    /// assignment order of `environment` and `apiEndpoint` does not matter.
    /// `.custom` requires setting this explicitly (setup throws otherwise).
    public var apiEndpoint: URL {
        get {
            explicitApiEndpoint
                ?? environment.defaultEndpoint
                ?? URL(string: "https://i.nuxie.ai")!
        }
        set { explicitApiEndpoint = newValue }
    }

    /// Whether apiEndpoint was explicitly provided (required for .custom)
    var hasExplicitApiEndpoint: Bool { explicitApiEndpoint != nil }

    private var explicitApiEndpoint: URL?

    /// Environment setting
    public var environment: Environment = .production

    /// Enables the isolated iOS-only Nuxie Test Store for local commerce qualification.
    ///
    /// Test Store mode is accepted only with a development environment and a
    /// `pk_test_` API key. It never uses StoreKit, a configured purchase
    /// delegate, or production commerce/reporting.
    public var testStoreEnabled: Bool = false
    
    /// Logging settings
    public var logLevel: LogLevel = .warning
    public var enableConsoleLogging: Bool = true
    public var redactSensitiveData: Bool = true
    
    /// Number of failures over which the retry delay increases exponentially
    /// before it caps. Zero and one both keep the base delay; delivery itself
    /// continues retrying on later flush opportunities. Must be nonnegative
    /// and, together with `retryDelay`, produce a finite schedulable backoff.
    public var retryCount: Int = 3
    /// Base retry delay in seconds. Must be finite and nonnegative.
    public var retryDelay: TimeInterval = 2
    
    /// Event batching settings
    /// Maximum events per batch. Must be in `1...Int32.max`.
    public var eventBatchSize: Int = 50
    /// Pending-event count that triggers automatic flush. Must be in `1...Int32.max`.
    public var flushAt: Int = 20
    /// Automatic flush interval in seconds. Must be finite, positive, and
    /// representable by Swift concurrency's nanosecond sleep clock.
    public var flushInterval: TimeInterval = 30
    /// Maximum pending events staged in memory. Must be in `1...Int32.max`.
    public var maxQueueSize: Int = 1000
    
    /// Storage settings
    public var customStoragePath: URL?

    /// Feature cache settings
    /// TTL for real-time feature check results (default: 5 minutes). Must be
    /// finite and greater than zero.
    public var featureCacheTTL: TimeInterval = 5 * 60
    
    /// Initial locale selected during `setup(with:)`.
    /// When nil, the SDK uses the device locale. After setup, call
    /// `NuxieSDK.setLocaleIdentifier(_:)` to change it and refresh the profile.
    public var localeIdentifier: String?

    /// Automatically track $app_installed / $app_updated / $app_opened /
    /// $app_backgrounded lifecycle events (default: true)
    public var trackApplicationLifecycleEvents: Bool = true

    /// Optional beforeSend hook for event transformation/filtering
    /// Return nil to drop the event, or return a modified event
    public var beforeSend: (@Sendable (NuxieEvent) -> NuxieEvent?)?
    
    /// Internal transport-injection seam used by the SDK's tests.
    var urlSession: URLSession?
    
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

    static func validate(_ configuration: NuxieConfiguration) throws {
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
    let retryCount: Int
    let retryDelay: TimeInterval
    let eventBatchSize: Int
    let flushAt: Int
    let flushInterval: TimeInterval
    let maxQueueSize: Int
    let customStoragePath: URL?
    let featureCacheTTL: TimeInterval
    let trackApplicationLifecycleEvents: Bool
    let beforeSend: (@Sendable (NuxieEvent) -> NuxieEvent?)?
    let urlSession: URLSession?

    init(_ configuration: NuxieConfiguration) {
        apiKey = configuration.apiKey
        apiEndpoint = configuration.apiEndpoint
        environment = configuration.environment
        testStoreEnabled = configuration.testStoreEnabled
        logLevel = configuration.logLevel
        enableConsoleLogging = configuration.enableConsoleLogging
        redactSensitiveData = configuration.redactSensitiveData
        retryCount = configuration.retryCount
        retryDelay = configuration.retryDelay
        eventBatchSize = configuration.eventBatchSize
        flushAt = configuration.flushAt
        flushInterval = configuration.flushInterval
        maxQueueSize = configuration.maxQueueSize
        customStoragePath = configuration.customStoragePath
        featureCacheTTL = configuration.featureCacheTTL
        trackApplicationLifecycleEvents = configuration.trackApplicationLifecycleEvents
        beforeSend = configuration.beforeSend
        urlSession = configuration.urlSession
    }

    /// Compatibility copy for public protocols that still accept the mutable
    /// pre-1.0 builder. This instance never escapes the composition root.
    func eventLogConfiguration() -> NuxieConfiguration {
        let configuration = NuxieConfiguration(apiKey: apiKey)
        configuration.environment = environment
        configuration.testStoreEnabled = testStoreEnabled
        configuration.apiEndpoint = apiEndpoint
        configuration.logLevel = logLevel
        configuration.enableConsoleLogging = enableConsoleLogging
        configuration.redactSensitiveData = redactSensitiveData
        configuration.retryCount = retryCount
        configuration.retryDelay = retryDelay
        configuration.eventBatchSize = eventBatchSize
        configuration.flushAt = flushAt
        configuration.flushInterval = flushInterval
        configuration.maxQueueSize = maxQueueSize
        configuration.customStoragePath = customStoragePath
        configuration.featureCacheTTL = featureCacheTTL
        configuration.trackApplicationLifecycleEvents = trackApplicationLifecycleEvents
        configuration.beforeSend = beforeSend
        configuration.urlSession = urlSession
        return configuration
    }
}
