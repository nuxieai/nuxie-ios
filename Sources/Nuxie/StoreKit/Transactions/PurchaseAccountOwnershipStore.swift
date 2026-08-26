import Foundation

struct StoredPurchaseAccountOwnership: Codable, Equatable, Sendable {
    let scope: PurchaseStorageScope
    let appAccountToken: UUID
    let distinctId: String
    let productAuthorities: [String: PurchaseEvidenceAuthority]

    init(
        scope: PurchaseStorageScope,
        appAccountToken: UUID,
        distinctId: String,
        productAuthorities: [String: PurchaseEvidenceAuthority] = [:]
    ) {
        self.scope = scope
        self.appAccountToken = appAccountToken
        self.distinctId = distinctId
        self.productAuthorities = productAuthorities
    }
}

protocol PurchaseAccountOwnershipStoreProtocol: Sendable {
    func load() -> StoreReadResult<
        [String: StoredPurchaseAccountOwnership]
    >

    func owner(
        for appAccountToken: UUID,
        scope: PurchaseStorageScope
    ) -> String?

    func evidenceAuthority(
        for appAccountToken: UUID,
        productId: String,
        scope: PurchaseStorageScope
    ) -> PurchaseEvidenceAuthority?

    @discardableResult
    func upsert(_ ownership: StoredPurchaseAccountOwnership) -> Bool
}

/// Long-lived account ownership is deliberately separate from one-shot
/// checkout attribution. Subscription renewals retain `appAccountToken` after
/// their originating Experience and Placement context has been retired.
final class PurchaseAccountOwnershipStore:
    PurchaseAccountOwnershipStoreProtocol,
    @unchecked Sendable
{
    private let fileURL: URL
    private let lock = NSLock()
    private let readFailureLogger = StoreReadFailureLogger()

    init(
        customStoragePath: URL? = nil,
        scope: PurchaseStorageScope = .testFixture
    ) {
        let base = scope.storageDirectory(customStoragePath: customStoragePath)
        fileURL = base.appendingPathComponent("account-ownership.json")
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
    }

    func owner(
        for appAccountToken: UUID,
        scope: PurchaseStorageScope
    ) -> String? {
        lock.withLock {
            guard case .value(let entries) = loadResultUnlocked(
                absentValue: [:]
            ) else { return nil }
            let ownership = entries[appAccountToken.uuidString]
            guard ownership?.scope == scope else { return nil }
            return ownership?.distinctId
        }
    }

    func evidenceAuthority(
        for appAccountToken: UUID,
        productId: String,
        scope: PurchaseStorageScope
    ) -> PurchaseEvidenceAuthority? {
        lock.withLock {
            guard case .value(let entries) = loadResultUnlocked(
                absentValue: [:]
            ) else { return nil }
            let ownership = entries[appAccountToken.uuidString]
            guard ownership?.scope == scope else { return nil }
            return ownership?.productAuthorities[productId]
        }
    }

    func upsert(_ ownership: StoredPurchaseAccountOwnership) -> Bool {
        lock.withLock {
            guard case .value(var entries) = loadResultUnlocked(
                absentValue: [:]
            ) else { return false }
            let key = ownership.appAccountToken.uuidString
            let retainedAuthorities = entries[key]?.scope == ownership.scope
                ? entries[key]?.productAuthorities ?? [:]
                : [:]
            entries[key] = StoredPurchaseAccountOwnership(
                scope: ownership.scope,
                appAccountToken: ownership.appAccountToken,
                distinctId: ownership.distinctId,
                productAuthorities: retainedAuthorities.merging(
                    ownership.productAuthorities,
                    uniquingKeysWith: { _, new in new }
                )
            )
            return saveUnlocked(entries)
        }
    }

    func load() -> StoreReadResult<[String: StoredPurchaseAccountOwnership]> {
        lock.withLock { loadResultUnlocked() }
    }

    private func loadResultUnlocked(
        absentValue: [String: StoredPurchaseAccountOwnership]? = nil
    ) -> StoreReadResult<[String: StoredPurchaseAccountOwnership]> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if let absentValue { return .value(absentValue) }
            return .absent
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return .value(try JSONDecoder().decode(
                [String: StoredPurchaseAccountOwnership].self,
                from: data
            ))
        } catch {
            if readFailureLogger.shouldLog() {
                LogError(
                    "PurchaseAccountOwnershipStore: ownership is unreadable: \(error)"
                )
            }
            return .unreadable
        }
    }

    private func saveUnlocked(
        _ entries: [String: StoredPurchaseAccountOwnership]
    ) -> Bool {
        guard !loadResultUnlocked().isUnreadable else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else {
            LogError("PurchaseAccountOwnershipStore: failed to encode ownership")
            return false
        }
        do {
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return true
        } catch {
            LogError("PurchaseAccountOwnershipStore: failed to persist ownership")
            return false
        }
    }
}

final class InMemoryPurchaseAccountOwnershipStore:
    PurchaseAccountOwnershipStoreProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var entries: [String: StoredPurchaseAccountOwnership] = [:]

    func load() -> StoreReadResult<[String: StoredPurchaseAccountOwnership]> {
        lock.withLock { .value(entries) }
    }

    func owner(
        for appAccountToken: UUID,
        scope: PurchaseStorageScope
    ) -> String? {
        lock.withLock {
            let ownership = entries[appAccountToken.uuidString]
            guard ownership?.scope == scope else { return nil }
            return ownership?.distinctId
        }
    }

    func evidenceAuthority(
        for appAccountToken: UUID,
        productId: String,
        scope: PurchaseStorageScope
    ) -> PurchaseEvidenceAuthority? {
        lock.withLock {
            let ownership = entries[appAccountToken.uuidString]
            guard ownership?.scope == scope else { return nil }
            return ownership?.productAuthorities[productId]
        }
    }

    func upsert(_ ownership: StoredPurchaseAccountOwnership) -> Bool {
        lock.withLock {
            let key = ownership.appAccountToken.uuidString
            let retainedAuthorities = entries[key]?.scope == ownership.scope
                ? entries[key]?.productAuthorities ?? [:]
                : [:]
            entries[key] = StoredPurchaseAccountOwnership(
                scope: ownership.scope,
                appAccountToken: ownership.appAccountToken,
                distinctId: ownership.distinctId,
                productAuthorities: retainedAuthorities.merging(
                    ownership.productAuthorities,
                    uniquingKeysWith: { _, new in new }
                )
            )
        }
        return true
    }
}
