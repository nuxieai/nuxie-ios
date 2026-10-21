import CryptoKit
import Foundation

enum PurchaseStoreEnvironment: String, Codable, Sendable {
    case appStore
    case testStore
}

/// Opaque namespace for every durable purchase artifact. The host app's stable
/// bundle identity is hashed before it reaches disk; environment and store mode
/// remain explicit so development Test Store state can never be replayed as
/// App Store state. A rotatable publishable API key is not app identity: only
/// its mode (live or test) takes part, so rotating a key keeps the namespace.
///
/// The environment component is the key's mode, never the SDK's service
/// environment or the transaction's StoreKit environment. The server derives
/// the expected account token from the key's mode too, so App Review's
/// Sandbox purchase on a live key carries the live token. Shared vectors in
/// `fixtures/purchases/app-account-token.json` pin both sides.
struct PurchaseStorageScope: Codable, Equatable, Hashable, Sendable {
    let appIdentifierHash: String
    let environment: String
    let storeEnvironment: PurchaseStoreEnvironment

    init(
        appIdentifier: String,
        apiKey: String,
        testStoreEnabled: Bool
    ) {
        let digest = SHA256.hash(data: Data(appIdentifier.utf8))
        appIdentifierHash = digest.map { String(format: "%02x", $0) }.joined()
        environment = Self.environment(forPublishableKey: apiKey)
        storeEnvironment = testStoreEnabled ? .testStore : .appStore
    }

    /// `production` for a live key, `development` for a test key. Nuxie issues
    /// only `pk_live_` and `pk_test_` keys, and a test key is the safe reading
    /// of anything else: it can never claim a Production transaction.
    static func environment(forPublishableKey apiKey: String) -> String {
        apiKey.hasPrefix("pk_live_") ? "production" : "development"
    }

    /// Whether this namespace belongs to a live key.
    var isLiveKey: Bool { environment == "production" }

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
    /// Checkout ownership, never populated by reusable catalog resolution.
    var journeyId: String?
    let release: AuthenticatedJourneyReleaseID
    let placementId: String
    let productId: String
    let storeProductId: String
    /// Localized StoreKit price shown on the exact purchased Placement.
    let displayPrice: String?
    /// Numeric StoreKit price used for analytics when the live product
    /// exposes one. Display remains authoritative for customer-facing copy.
    let price: Double?

    init(
        release: AuthenticatedJourneyReleaseID,
        placementId: String,
        productId: String,
        storeProductId: String,
        displayPrice: String? = nil,
        price: Double? = nil,
        journeyId: String? = nil
    ) {
        self.release = release
        self.placementId = placementId
        self.productId = productId
        self.storeProductId = storeProductId
        self.displayPrice = displayPrice
        self.price = price
        self.journeyId = journeyId
    }

    var appId: String { release.identity.appId }
    var environment: String { release.identity.environment }
    var experienceId: String { release.identity.experienceId }
}

/// The `environment` a signed StoreKit transaction names: "Production",
/// "Sandbox" or "Xcode". The SDK commits only transactions StoreKit verified,
/// so this is Apple's signed value. Nil when the payload cannot be read.
func storeKitEnvironment(ofSignedTransaction jws: String) -> String? {
    let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var base64 = parts[1]
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return payload["environment"] as? String
}

/// `$purchase_completed`'s `store_environment`. App Review buys with a
/// Sandbox account against the release build, so a live key's purchase can be
/// a StoreKit Sandbox one; the server admits it but keeps it out of revenue,
/// fees and conversions, and experiment metrics skip goal events marked
/// "sandbox". Only that purchase carries the property: a live key's
/// Production purchase, every test key's purchase and Test Store carry none.
func purchaseCompletionStoreEnvironment(
    storeKitEnvironment: String?,
    scope: PurchaseStorageScope
) -> String? {
    guard scope.storeEnvironment == .appStore,
          scope.isLiveKey,
          storeKitEnvironment == "Sandbox" else { return nil }
    return "sandbox"
}

/// The stable commercial success payload. Both the direct checkout callback
/// and StoreKit update/recovery paths capture this exact shape under the same
/// transaction event id, so scheduling cannot change analytics or Journey
/// predicates.
func purchaseCompletionProperties(
    context: PurchaseCommercialContext,
    transactionId: String?,
    testStore: Bool,
    storeEnvironment: String?,
    source: PurchaseOutcomeSource
) -> [String: Any] {
    var properties: [String: Any] = [
        "product_id": context.productId,
        "placement_id": context.placementId,
        "store_product_id": context.storeProductId,
        "experience_id": context.experienceId,
        "experience_version_id": context.release.identity.experienceVersionId,
        "source": source.rawValue,
        "test_store": testStore,
    ]
    if let transactionId {
        properties["transaction_id"] = transactionId
    }
    if let journeyId = context.journeyId {
        properties["journey_id"] = journeyId
    }
    if let displayPrice = context.displayPrice {
        properties["display_price"] = displayPrice
    }
    if let price = context.price {
        properties["price"] = price
    }
    if let storeEnvironment {
        properties["store_environment"] = storeEnvironment
    }
    return properties
}
