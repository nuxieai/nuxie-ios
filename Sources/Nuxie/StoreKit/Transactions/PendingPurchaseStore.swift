import Foundation

/// Persistence seam for protected pre-checkout recovery context. Records are
/// created before StoreKit opens and retained when Ask-to-Buy/SCA defers the
/// result. The set is tiny but must survive process death so Transaction.updates
/// can recover exact commercial attribution on a later launch.
protocol PendingPurchaseStoreProtocol: Sendable {
    /// Load every persisted marker (scoped product key → record).
    func load() -> [String: PendingPurchaseRecord]

    /// Persist the full marker set, replacing whatever was stored.
    @discardableResult
    func save(_ entries: [String: PendingPurchaseRecord]) -> Bool
}

enum PendingPurchaseState: String, Codable, Equatable, Sendable {
    case checkout
    case pending
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

    init(
        scope: PurchaseStorageScope,
        distinctId: String,
        appAccountToken: UUID,
        commercialContext: PurchaseCommercialContext,
        recordedAt: Date,
        productFeatureIds: [String] = [],
        localEntitlementGrants: [StoredLocalEntitlementGrant],
        state: PendingPurchaseState
    ) {
        self.scope = scope
        self.distinctId = distinctId
        self.appAccountToken = appAccountToken
        self.commercialContext = commercialContext
        self.recordedAt = recordedAt
        self.productFeatureIds = productFeatureIds
        self.localEntitlementGrants = localEntitlementGrants
        self.state = state
    }
}

/// Scope-isolated flat-file store under Application Support. A small JSON
/// dictionary is written atomically and uses iOS data protection.
final class PendingPurchaseStore: PendingPurchaseStoreProtocol {

    private let fileURL: URL

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

    func load() -> [String: PendingPurchaseRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([String: PendingPurchaseRecord].self, from: data)
        } catch {
            // A corrupt marker file loses pending markers (degrades to the
            // pre-persistence behavior) rather than wedging every load.
            LogError("PendingPurchaseStore: failed to decode \(fileURL.lastPathComponent): \(error)")
            try? FileManager.default.removeItem(at: fileURL)
            return [:]
        }
    }

    @discardableResult
    func save(_ entries: [String: PendingPurchaseRecord]) -> Bool {
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

    func load() -> [String: PendingPurchaseRecord] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    @discardableResult
    func save(_ entries: [String: PendingPurchaseRecord]) -> Bool {
        lock.lock()
        self.entries = entries
        lock.unlock()
        return true
    }
}
