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
/// their originating Experience and Placement context has been retired. A
/// corrupt file is set aside and an empty store takes its place (see
/// `PurchaseStoreFile`).
final class PurchaseAccountOwnershipStore:
    PurchaseAccountOwnershipStoreProtocol,
    @unchecked Sendable
{
    private let file: PurchaseStoreFile
    private var fileURL: URL { file.url }
    private let lock = NSLock()

    init(
        customStoragePath: URL? = nil,
        scope: PurchaseStorageScope = .testFixture,
        logger: NuxieLogger = .shared
    ) {
        let base = scope.storageDirectory(customStoragePath: customStoragePath)
        file = PurchaseStoreFile(
            url: base.appendingPathComponent("account-ownership.json"),
            storeName: "PurchaseAccountOwnershipStore",
            logger: logger
        )
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
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
        let result = file.read { data in
            try JSONDecoder().decode(
                [String: StoredPurchaseAccountOwnership].self,
                from: data
            )
        }
        if case .absent = result, let absentValue { return .value(absentValue) }
        return result
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
