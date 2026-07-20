import Foundation

/// Environment settings
public enum Environment: String {
    case production = "production"
    case staging = "staging"
    case development = "development"
    case custom = "custom"
    
    var defaultEndpoint: URL {
        switch self {
        case .production:
            return URL(string: "https://i.nuxie.ai")!
        case .staging:
            return URL(string: "https://staging-i.nuxie.ai")!
        case .development:
            return URL(string: "https://dev-i.nuxie.ai")!
        case .custom:
            return URL(string: "https://i.nuxie.ai")!
        }
    }
}

/// Log levels
public enum LogLevel: String {
    case verbose = "verbose"
    case debug = "debug"
    case info = "info"
    case warning = "warning"
    case error = "error"
    case none = "none"
}

/// Event linking policy for handling anonymous to identified user transitions
public enum EventLinkingPolicy {
    /// Keep anonymous and identified events separate
    case keepSeparate
    
    /// Migrate anonymous events to identified user on identify (default)
    case migrateOnIdentify
}

/// Configuration object for initializing Nuxie SDK
public class NuxieConfiguration {
    /// Required: API key for authentication
    public let apiKey: String
    
    /// API endpoint (defaults to production)
    public var apiEndpoint: URL = URL(string: "https://i.nuxie.ai")!
    
    /// Environment setting
    public var environment: Environment = .production {
        didSet {
            // Update endpoint if using default
            if apiEndpoint == oldValue.defaultEndpoint {
                apiEndpoint = environment.defaultEndpoint
            }
        }
    }
    
    /// Logging settings
    public var logLevel: LogLevel = .warning
    public var enableConsoleLogging: Bool = true
    public var redactSensitiveData: Bool = true
    
    /// Network settings
    public var requestTimeout: TimeInterval = 30
    public var retryCount: Int = 3
    public var retryDelay: TimeInterval = 2
    public var syncInterval: TimeInterval = 3600 // 1 hour
    public var enableCompression: Bool = true
    
    /// Event batching settings
    public var eventBatchSize: Int = 50 // Maximum events per batch
    public var flushAt: Int = 20 // Number of events to trigger automatic flush
    public var flushInterval: TimeInterval = 30 // Time interval to trigger automatic flush in seconds
    public var maxQueueSize: Int = 1000 // Maximum events to keep in queue
    
    /// Storage settings
    public var maxCacheSize: Int64 = 100 * 1024 * 1024 // 100 MB
    public var cacheExpiration: TimeInterval = 7 * 24 * 3600 // 7 days
    public var enableEncryption: Bool = true
    public var customStoragePath: URL?

    /// Feature cache settings
    /// TTL for real-time feature check results (default: 5 minutes)
    public var featureCacheTTL: TimeInterval = 5 * 60
    
    /// Behavior settings
    public var defaultPaywallTimeout: TimeInterval = 10
    public var respectDoNotTrack: Bool = true
    public var eventLinkingPolicy: EventLinkingPolicy = .migrateOnIdentify

    /// Locale settings
    /// Override device locale for paywall content (e.g., "es_ES", "de_DE")
    /// When nil, uses device's current locale. Changing this requires calling refreshProfile().
    public var localeIdentifier: String?

    /// Debug mode - when true, bypasses flow cache for fresh fetches
    /// Useful for testing locale changes and flow updates during development
    public var isDebugMode: Bool = false

    /// Automatically track $app_installed / $app_updated / $app_opened /
    /// $app_backgrounded lifecycle events (default: true)
    public var trackApplicationLifecycleEvents: Bool = true

    /// Event system settings
    public var propertiesSanitizer: NuxiePropertiesSanitizer?
    
    /// Optional beforeSend hook for event transformation/filtering
    /// Return nil to drop the event, or return a modified event
    public var beforeSend: ((NuxieEvent) -> NuxieEvent?)?
    
    /// Flow caching settings
    public var maxFlowCacheSize: Int64 = 500 * 1024 * 1024 // 500 MB
    public var flowCacheExpiration: TimeInterval = 7 * 24 * 3600 // 7 days
    public var maxConcurrentFlowDownloads: Int = 4
    public var flowDownloadTimeout: TimeInterval = 30
    public var flowCacheDirectory: URL?
    
    /// Custom URLSession for testing (if nil, a default one will be created)
    public var urlSession: URLSession?
    
    /// Purchase delegate for handling StoreKit purchases
    /// If not set, purchase operations will fail with notConfigured error
    public var purchaseDelegate: NuxiePurchaseDelegate?
    
    /// Initialize with API key
    public init(apiKey: String) {
        self.apiKey = apiKey
    }
}
