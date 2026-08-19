import Foundation

struct StoredLocalPurchaseAccess: Codable, Equatable, Sendable {
    let transactionId: String
    let productId: String
    let distinctId: String
    let grants: [StoredLocalEntitlementGrant]
}

protocol LocalPurchaseAccessStoreProtocol: Sendable {
    func load() -> [String: StoredLocalPurchaseAccess]
    @discardableResult
    func save(_ entries: [String: StoredLocalPurchaseAccess]) -> Bool
}

/// Durable, non-receipt local access state. Verified transaction JWS evidence
/// can be retired after backend acceptance while this minimal ledger remains
/// available for an offline relaunch. StoreKit current entitlements reconcile
/// the ledger before it is projected into Feature Access.
final class LocalPurchaseAccessStore: LocalPurchaseAccessStoreProtocol {
    private let fileURL: URL

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
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode(
            [String: StoredLocalPurchaseAccess].self,
            from: data
        )) ?? [:]
    }

    @discardableResult
    func save(_ entries: [String: StoredLocalPurchaseAccess]) -> Bool {
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
}
