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
    
    /// Logging settings
    public var logLevel: LogLevel = .warning
    public var enableConsoleLogging: Bool = true
    public var redactSensitiveData: Bool = true
    
    /// Network retry settings
    public var retryCount: Int = 3
    public var retryDelay: TimeInterval = 2
    
    /// Event batching settings
    public var eventBatchSize: Int = 50 // Maximum events per batch
    public var flushAt: Int = 20 // Number of events to trigger automatic flush
    public var flushInterval: TimeInterval = 30 // Time interval to trigger automatic flush in seconds
    public var maxQueueSize: Int = 1000 // Maximum pending events staged in memory
    
    /// Storage settings
    public var customStoragePath: URL?

    /// Overrides the profile-provided content-addressed asset base URL.
    ///
    /// Intended for development stacks. Production apps should leave this nil
    /// so the authenticated profile response selects the asset origin.
    public var packageAssetBaseURL: URL?

    /// Feature cache settings
    /// TTL for real-time feature check results (default: 5 minutes)
    public var featureCacheTTL: TimeInterval = 5 * 60
    
    /// Locale settings
    /// Override device locale for paywall content (e.g., "es_ES", "de_DE")
    /// When nil, uses device's current locale. Changing this requires calling refreshProfile().
    public var localeIdentifier: String?

    /// Automatically track $app_installed / $app_updated / $app_opened /
    /// $app_backgrounded lifecycle events (default: true)
    public var trackApplicationLifecycleEvents: Bool = true

    /// Optional beforeSend hook for event transformation/filtering
    /// Return nil to drop the event, or return a modified event
    public var beforeSend: (@Sendable (NuxieEvent) -> NuxieEvent?)?
    
    /// Custom URLSession for testing (if nil, a default one will be created)
    public var urlSession: URLSession?
    
    /// How the SDK handles StoreKit transactions it observes.
    public enum PurchaseHandlingMode: Sendable {
        /// Nuxie owns transaction lifecycle: verified transactions are synced
        /// to the backend and finished (default).
        case full
        /// Observer mode for apps with their own IAP code: Nuxie syncs
        /// verified transactions for entitlement tracking but NEVER calls
        /// transaction.finish() — your code retains full ownership. Use this
        /// whenever the host app (or another SDK) manages purchases.
        case observer
    }

    /// Transaction handling mode (default: .full). Set .observer if your app
    /// or another SDK owns StoreKit transaction finishing.
    public var purchaseHandlingMode: PurchaseHandlingMode = .full

    /// Purchase delegate for handling StoreKit purchases
    /// If not set, purchase operations will fail with notConfigured error
    public var purchaseDelegate: NuxiePurchaseDelegate?
    
    /// Initialize with API key
    public init(apiKey: String) {
        self.apiKey = apiKey
    }
}

/// Immutable setup input shared by the internal service graph.
struct NuxieSetupConfiguration: Sendable {
    let apiKey: String
    let apiEndpoint: URL
    let environment: Environment
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
    let packageAssetBaseURL: URL?
    let featureCacheTTL: TimeInterval
    let trackApplicationLifecycleEvents: Bool
    let beforeSend: (@Sendable (NuxieEvent) -> NuxieEvent?)?
    let urlSession: URLSession?

    init(_ configuration: NuxieConfiguration) {
        apiKey = configuration.apiKey
        apiEndpoint = configuration.apiEndpoint
        environment = configuration.environment
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
        packageAssetBaseURL = configuration.packageAssetBaseURL
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
        configuration.packageAssetBaseURL = packageAssetBaseURL
        configuration.featureCacheTTL = featureCacheTTL
        configuration.trackApplicationLifecycleEvents = trackApplicationLifecycleEvents
        configuration.beforeSend = beforeSend
        configuration.urlSession = urlSession
        return configuration
    }
}
