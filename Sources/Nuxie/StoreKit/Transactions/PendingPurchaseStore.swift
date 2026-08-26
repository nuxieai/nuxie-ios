import Foundation

/// Persistence seam for protected pre-checkout recovery context. Records are
/// created before StoreKit opens and retained when Ask-to-Buy/SCA defers the
/// result. The set is tiny but must survive process death so Transaction.updates
/// can recover exact commercial attribution on a later launch.
protocol PendingPurchaseStoreProtocol: Sendable {
    /// Load every persisted marker (scoped product key → record).
    func load() -> StoreReadResult<[String: PendingPurchaseRecord]>

    /// Persist the full marker set, replacing whatever was stored.
    @discardableResult
    func save(_ entries: [String: PendingPurchaseRecord]) -> Bool
}

enum PendingPurchaseState: String, Codable, Equatable, Sendable {
    case checkout
    case pending
}

/// Internal authority inferred before checkout. It never crosses the public
/// delegate API: signed connector state is definitive, while an outcome-only
/// delegate gets a short StoreKit correlation window.
enum PurchaseEvidenceAuthority: String, Codable, Equatable, Sendable {
    case nativeStoreKit
    case providerConnector
    case outcomeOnlyDelegate
    /// Conflicting authenticated active Products for the same store identity.
    /// Recovery must wait rather than guessing who owns receipt processing.
    case ambiguous

    var durableProductAuthority: PurchaseEvidenceAuthority {
        switch self {
        case .providerConnector, .ambiguous:
            return self
        case .nativeStoreKit, .outcomeOnlyDelegate:
            return .nativeStoreKit
        }
    }
}

struct PendingPurchaseRecord: Codable, Equatable, Sendable {
    let scope: PurchaseStorageScope
    let distinctId: String
    let appAccountToken: UUID
    let commercialContext: PurchaseCommercialContext
    let recordedAt: Date
    /// Internal and external Feature identifiers from the signed Product.
    /// Used only to choose evidence for an atomic server command; it never
    /// projects quota or credit balances locally.
    let productFeatureIds: [String]
    let localEntitlementGrants: [StoredLocalEntitlementGrant]
    let state: PendingPurchaseState
    let evidenceAuthority: PurchaseEvidenceAuthority
    /// Stable identity for this checkout's commercial completion. It exists
    /// before delegate invocation, so callback and StoreKit recovery can use
    /// the same durable EventLog key without a transaction identifier.
    let checkoutCompletionEventId: String
    /// Bounds commercial-context correlation for an ambiguous successful
    /// delegate outcome. Stable SDK account-token ownership survives expiry.
    let storeKitObservationDeadline: Date?
    /// Set after either race participant durably reports commercial
    /// completion. The other participant must not report it again.
    let completionReportedAt: Date?
    /// Set after verified evidence is durable so the callback and observer can
    /// race on the same transaction-scoped completion claim.
    let observedTransactionId: String?

    init(
        scope: PurchaseStorageScope,
        distinctId: String,
        appAccountToken: UUID,
        commercialContext: PurchaseCommercialContext,
        recordedAt: Date,
        productFeatureIds: [String] = [],
        localEntitlementGrants: [StoredLocalEntitlementGrant],
        state: PendingPurchaseState,
        evidenceAuthority: PurchaseEvidenceAuthority = .nativeStoreKit,
        checkoutCompletionEventId: String = UUID().uuidString.lowercased(),
        storeKitObservationDeadline: Date? = nil,
        completionReportedAt: Date? = nil,
        observedTransactionId: String? = nil
    ) {
        self.scope = scope
        self.distinctId = distinctId
        self.appAccountToken = appAccountToken
        self.commercialContext = commercialContext
        self.recordedAt = recordedAt
        self.productFeatureIds = productFeatureIds
        self.localEntitlementGrants = localEntitlementGrants
        self.state = state
        self.evidenceAuthority = evidenceAuthority
        self.checkoutCompletionEventId = checkoutCompletionEventId
        self.storeKitObservationDeadline = storeKitObservationDeadline
        self.completionReportedAt = completionReportedAt
        self.observedTransactionId = observedTransactionId
    }
}

/// Scope-isolated flat-file store under Application Support. A small JSON
/// dictionary is written atomically and uses iOS data protection.
final class PendingPurchaseStore: PendingPurchaseStoreProtocol {

    private let fileURL: URL
    private let readFailureLogger = StoreReadFailureLogger()

    init(
        customStoragePath: URL? = nil,
        scope: PurchaseStorageScope = .testFixture
    ) {
        let baseStoragePath = scope.storageDirectory(
            customStoragePath: customStoragePath
        )
        self.fileURL = baseStoragePath.appendingPathComponent("pending-purchases.json")

        do {
            try FileManager.default.createDirectory(
                at: baseStoragePath,
                withIntermediateDirectories: true
            )
        } catch {
            LogError("PendingPurchaseStore: failed to create storage directory: \(error)")
        }
    }

    func load() -> StoreReadResult<[String: PendingPurchaseRecord]> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .absent
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let data = try Data(contentsOf: fileURL)
            return .value(try decoder.decode(
                [String: PendingPurchaseRecord].self,
                from: data
            ))
        } catch {
            if readFailureLogger.shouldLog() {
                LogError("PendingPurchaseStore: markers are unreadable: \(error)")
            }
            return .unreadable
        }
    }

    @discardableResult
    func save(_ entries: [String: PendingPurchaseRecord]) -> Bool {
        guard !load().isUnreadable else { return false }
        if entries.isEmpty {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch CocoaError.fileNoSuchFile {
                // Already durably empty.
            } catch {
                LogError("PendingPurchaseStore: failed to clear markers: \(error)")
                return false
            }
            return true
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(entries)
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return true
        } catch {
            LogError("PendingPurchaseStore: failed to persist markers: \(error)")
            return false
        }
    }
}

/// In-memory marker store for tests and fixture hosts that do not model a
/// process kill.
final class InMemoryPendingPurchaseStore: PendingPurchaseStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: PendingPurchaseRecord] = [:]

    init() {}

    func load() -> StoreReadResult<[String: PendingPurchaseRecord]> {
        lock.lock()
        defer { lock.unlock() }
        return .value(entries)
    }

    @discardableResult
    func save(_ entries: [String: PendingPurchaseRecord]) -> Bool {
        lock.lock()
        self.entries = entries
        lock.unlock()
        return true
    }
}
