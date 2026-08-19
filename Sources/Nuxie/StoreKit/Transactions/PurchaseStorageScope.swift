import CryptoKit
import Foundation

enum PurchaseStoreEnvironment: String, Codable, Sendable {
    case appStore
    case testStore
}

/// Opaque namespace for every durable purchase artifact. The host app's stable
/// bundle identity is hashed before it reaches disk; environment and store mode
/// remain explicit so development Test Store state can never be replayed as
/// App Store state. A rotatable publishable API key is not app identity.
struct PurchaseStorageScope: Codable, Equatable, Hashable, Sendable {
    let appIdentifierHash: String
    let environment: String
    let storeEnvironment: PurchaseStoreEnvironment

    init(
        appIdentifier: String,
        environment: Environment,
        apiEndpoint: URL,
        testStoreEnabled: Bool
    ) {
        let digest = SHA256.hash(data: Data(appIdentifier.utf8))
        appIdentifierHash = digest.map { String(format: "%02x", $0) }.joined()
        self.environment = Self.environmentNamespace(
            environment: environment,
            apiEndpoint: apiEndpoint
        )
        storeEnvironment = testStoreEnabled ? .testStore : .appStore
    }

    init(
        appIdentifierHash: String,
        environment: String,
        storeEnvironment: PurchaseStoreEnvironment
    ) {
        self.appIdentifierHash = appIdentifierHash
        self.environment = environment
        self.storeEnvironment = storeEnvironment
    }

    static let testFixture = Self(
        appIdentifierHash: "test-fixture",
        environment: "test",
        storeEnvironment: .appStore
    )

    /// Named environments already identify a single Nuxie backend. Custom
    /// environments need the configured backend identity in the namespace so
    /// two independent deployments cannot share evidence or account tokens.
    private static func environmentNamespace(
        environment: Environment,
        apiEndpoint: URL
    ) -> String {
        guard environment == .custom else { return environment.rawValue }

        var components = URLComponents(
            url: apiEndpoint,
            resolvingAgainstBaseURL: false
        )
        let normalizedScheme = components?.scheme?.lowercased()
        let normalizedHost = components?.host?.lowercased()
        components?.scheme = normalizedScheme
        components?.host = normalizedHost
        components?.fragment = nil
        if (components?.scheme == "https" && components?.port == 443)
            || (components?.scheme == "http" && components?.port == 80) {
            components?.port = nil
        }
        if var path = components?.percentEncodedPath {
            while path.hasSuffix("/") { path.removeLast() }
            components?.percentEncodedPath = path
        }
        let normalizedEndpoint = components?.string ?? apiEndpoint.absoluteString
        let digest = SHA256.hash(data: Data(normalizedEndpoint.utf8))
        let endpointHash = digest.map { String(format: "%02x", $0) }.joined()
        return "custom-\(endpointHash)"
    }

    var storageComponents: [String] {
        [appIdentifierHash, environment, storeEnvironment.rawValue]
    }

    /// Stable, opaque StoreKit account token for one Nuxie customer in this
    /// exact app/environment/store namespace.
    func appAccountToken(distinctId: String) -> UUID {
        var bytes = Array(SHA256.hash(
            data: Data("\(appIdentifierHash)\u{0}\(environment)\u{0}\(storeEnvironment.rawValue)\u{0}\(distinctId)".utf8)
        ).prefix(16))
        // RFC 4122 variant + version bits make the derived value a conventional
        // UUID while retaining deterministic account correlation.
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }
        let value = "\(hex[0...3].joined())-\(hex[4...5].joined())-\(hex[6...7].joined())-\(hex[8...9].joined())-\(hex[10...15].joined())"
        return UUID(uuidString: value)!
    }

    func storageDirectory(customStoragePath: URL?) -> URL {
        let base = customStoragePath ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return storageComponents.reduce(
            base.appendingPathComponent("nuxie", isDirectory: true)
                .appendingPathComponent("purchases", isDirectory: true)
        ) { directory, component in
            directory.appendingPathComponent(component, isDirectory: true)
        }
    }
}

struct PurchaseCommercialContext: Codable, Equatable, Sendable {
    let release: AuthenticatedExperienceReleaseID
    let placementId: String
    let productId: String
    let storeProductId: String
    /// Localized StoreKit price shown on the exact purchased Placement.
    let displayPrice: String?
    /// Numeric StoreKit price used for analytics when the live product
    /// exposes one. Display remains authoritative for customer-facing copy.
    let price: Double?

    init(
        release: AuthenticatedExperienceReleaseID,
        placementId: String,
        productId: String,
        storeProductId: String,
        displayPrice: String? = nil,
        price: Double? = nil
    ) {
        self.release = release
        self.placementId = placementId
        self.productId = productId
        self.storeProductId = storeProductId
        self.displayPrice = displayPrice
        self.price = price
    }

    var appId: String { release.identity.appId }
    var environment: String { release.identity.environment }
    var experienceId: String { release.identity.experienceId }
}

/// The stable commercial success payload. Both the direct checkout callback
/// and StoreKit update/recovery paths capture this exact shape under the same
/// transaction event id, so scheduling cannot change analytics or Journey
/// predicates.
func purchaseCompletionProperties(
    context: PurchaseCommercialContext,
    transactionId: String?,
    testStore: Bool
) -> [String: Any] {
    var properties: [String: Any] = [
        "product_id": context.productId,
        "placement_id": context.placementId,
        "store_product_id": context.storeProductId,
        "experience_id": context.experienceId,
        "source": "purchase",
        "test_store": testStore,
    ]
    if let transactionId {
        properties["transaction_id"] = transactionId
    }
    if let displayPrice = context.displayPrice {
        properties["display_price"] = displayPrice
    }
    if let price = context.price {
        properties["price"] = price
    }
    return properties
}
