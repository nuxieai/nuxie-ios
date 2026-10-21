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
/// delegate API. A configured external delegate owns billing completely;
/// these values therefore describe verified StoreKit evidence only.
enum PurchaseEvidenceAuthority: String, Codable, Equatable, Sendable {
    case nativeStoreKit
    case providerConnector
    /// Conflicting authenticated active Products for the same store identity.
    /// Recovery must wait rather than guessing who owns receipt processing.
    case ambiguous

    var durableProductAuthority: PurchaseEvidenceAuthority {
        switch self {
        case .providerConnector, .ambiguous:
            return self
        case .nativeStoreKit:
            return .nativeStoreKit
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "outcomeOnlyDelegate" {
            // Pre-unification external checkout markers are decoded only so
            // TransactionService can prune them. They must never regain native
            // receipt authority after an SDK upgrade.
            self = .providerConnector
            return
        }
        guard let authority = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown purchase evidence authority: \(value)"
            )
        }
        self = authority
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
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
    /// Stable identity for this native checkout's completion event.
    let checkoutCompletionEventId: String
    /// The original transaction ids the store already held for the product
    /// when this checkout began: its current entitlements and unfinished
    /// transactions. A purchase sharing one (an older purchase delivered
    /// again, a renewal of a subscription the customer already had) is never
    /// this checkout's purchase, so it never takes this binding.
    let priorOriginalTransactionIds: Set<String>

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
        priorOriginalTransactionIds: Set<String> = []
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
        self.priorOriginalTransactionIds = priorOriginalTransactionIds
    }

    private enum CodingKeys: String, CodingKey {
        case scope, distinctId, appAccountToken, commercialContext, recordedAt
        case productFeatureIds, localEntitlementGrants, state, evidenceAuthority
        case checkoutCompletionEventId, priorOriginalTransactionIds
    }

    /// A binding stored without the store's holdings reads as holding none,
    /// as Android reads a binding without its prior tokens.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try container.decode(PurchaseStorageScope.self, forKey: .scope)
        distinctId = try container.decode(String.self, forKey: .distinctId)
        appAccountToken = try container.decode(UUID.self, forKey: .appAccountToken)
        commercialContext = try container.decode(
            PurchaseCommercialContext.self,
            forKey: .commercialContext
        )
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        productFeatureIds = try container.decode([String].self, forKey: .productFeatureIds)
        localEntitlementGrants = try container.decode(
            [StoredLocalEntitlementGrant].self,
            forKey: .localEntitlementGrants
        )
        state = try container.decode(PendingPurchaseState.self, forKey: .state)
        evidenceAuthority = try container.decode(
            PurchaseEvidenceAuthority.self,
            forKey: .evidenceAuthority
        )
        checkoutCompletionEventId = try container.decode(
            String.self,
            forKey: .checkoutCompletionEventId
        )
        priorOriginalTransactionIds = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .priorOriginalTransactionIds
        ) ?? []
    }
}

/// Scope-isolated flat-file store under Application Support. A small JSON
/// dictionary is written atomically and uses iOS data protection. A corrupt
/// file is set aside and an empty store takes its place (see
/// `PurchaseStoreFile`).
final class PendingPurchaseStore: PendingPurchaseStoreProtocol {

    private let file: PurchaseStoreFile
    private var fileURL: URL { file.url }

    init(
        customStoragePath: URL? = nil,
        scope: PurchaseStorageScope = .testFixture,
        logger: NuxieLogger = .shared
    ) {
        let baseStoragePath = scope.storageDirectory(
            customStoragePath: customStoragePath
        )
        file = PurchaseStoreFile(
            url: baseStoragePath.appendingPathComponent("pending-purchases.json"),
            storeName: "PendingPurchaseStore",
            logger: logger
        )

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
        file.read { data in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([String: PendingPurchaseRecord].self, from: data)
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
