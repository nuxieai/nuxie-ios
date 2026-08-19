import Foundation

enum StoredLocalPurchaseAccessState: String, Codable, Sendable {
    case active
    case revoked
}

struct StoredLocalPurchaseAccess: Codable, Equatable, Sendable {
    let transactionId: String
    let originalTransactionId: String
    let productId: String
    let distinctId: String
    let grants: [StoredLocalEntitlementGrant]
    let state: StoredLocalPurchaseAccessState
}

protocol LocalPurchaseAccessStoreProtocol: Sendable {
    func load() -> [String: StoredLocalPurchaseAccess]
    @discardableResult
    func save(_ entries: [String: StoredLocalPurchaseAccess]) -> Bool
    @discardableResult
    func removeRevokedGrants(
        distinctId: String,
        featureIds: Set<String>
    ) -> Bool
}

/// Durable, non-receipt local access state. Verified transaction JWS evidence
/// can be retired after backend acceptance while this minimal ledger remains
/// available for an offline relaunch. Revoked entries remain as fail-closed
/// tombstones so an older cached profile cannot restore access after process
/// death. StoreKit current entitlements reconcile the ledger before it is
/// projected into Feature Access.
final class LocalPurchaseAccessStore: LocalPurchaseAccessStoreProtocol {
    private let fileURL: URL
    private let lock = NSLock()

    init(customStoragePath: URL? = nil) {
        let base: URL
        if let customStoragePath {
            base = customStoragePath.appendingPathComponent("nuxie", isDirectory: true)
        } else {
            base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent("nuxie", isDirectory: true)
        }
        fileURL = base.appendingPathComponent("local-purchase-access.json")
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
    }

    func load() -> [String: StoredLocalPurchaseAccess] {
        lock.withLock { loadUnlocked() }
    }

    @discardableResult
    func save(_ entries: [String: StoredLocalPurchaseAccess]) -> Bool {
        lock.withLock { saveUnlocked(entries) }
    }

    func removeRevokedGrants(
        distinctId: String,
        featureIds: Set<String>
    ) -> Bool {
        lock.withLock {
            var entries = loadUnlocked()
            var changed = false
            let revoked = entries.filter {
                $0.value.distinctId == distinctId && $0.value.state == .revoked
            }
            for (transactionId, access) in revoked {
                let retained = access.grants.filter {
                    !featureIds.contains($0.featureExternalId ?? $0.featureId)
                }
                guard retained.count != access.grants.count else { continue }
                changed = true
                if retained.isEmpty {
                    entries.removeValue(forKey: transactionId)
                } else {
                    entries[transactionId] = StoredLocalPurchaseAccess(
                        transactionId: access.transactionId,
                        originalTransactionId: access.originalTransactionId,
                        productId: access.productId,
                        distinctId: access.distinctId,
                        grants: retained,
                        state: .revoked
                    )
                }
            }
            return !changed || saveUnlocked(entries)
        }
    }

    private func loadUnlocked() -> [String: StoredLocalPurchaseAccess] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode(
            [String: StoredLocalPurchaseAccess].self,
            from: data
        )) ?? [:]
    }

    private func saveUnlocked(
        _ entries: [String: StoredLocalPurchaseAccess]
    ) -> Bool {
        if entries.isEmpty {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch CocoaError.fileNoSuchFile {
                // An absent empty store is already durable.
            } catch {
                LogError("LocalPurchaseAccessStore: failed to clear access ledger")
                return false
            }
            return true
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else {
            LogError("LocalPurchaseAccessStore: failed to encode access ledger")
            return false
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            #if os(iOS)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
            #endif
            return true
        } catch {
            LogError("LocalPurchaseAccessStore: failed to persist access ledger")
            return false
        }
    }
}

final class InMemoryLocalPurchaseAccessStore:
    LocalPurchaseAccessStoreProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var entries: [String: StoredLocalPurchaseAccess] = [:]

    func load() -> [String: StoredLocalPurchaseAccess] {
        lock.withLock { entries }
    }

    @discardableResult
    func save(_ entries: [String: StoredLocalPurchaseAccess]) -> Bool {
        lock.withLock { self.entries = entries }
        return true
    }

    func removeRevokedGrants(
        distinctId: String,
        featureIds: Set<String>
    ) -> Bool {
        lock.withLock {
            let revoked = entries.filter {
                $0.value.distinctId == distinctId && $0.value.state == .revoked
            }
            for (transactionId, access) in revoked {
                let retained = access.grants.filter {
                    !featureIds.contains($0.featureExternalId ?? $0.featureId)
                }
                if retained.isEmpty {
                    entries.removeValue(forKey: transactionId)
                } else if retained.count != access.grants.count {
                    entries[transactionId] = StoredLocalPurchaseAccess(
                        transactionId: access.transactionId,
                        originalTransactionId: access.originalTransactionId,
                        productId: access.productId,
                        distinctId: access.distinctId,
                        grants: retained,
                        state: .revoked
                    )
                }
            }
        }
        return true
    }
}
