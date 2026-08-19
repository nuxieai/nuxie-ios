import Foundation

struct StoredLocalEntitlementGrant: Codable, Equatable, Sendable {
    let featureId: String
    let featureExternalId: String?
    let allowanceType: String?
    let allowance: Double?
}

struct StoredTransactionEvidence: Codable, Equatable, Sendable {
    let transactionJws: String
    let transactionId: String
    let originalTransactionId: String
    let productId: String
    let distinctId: String
    let recordedAt: Date
    let localEntitlementGrants: [StoredLocalEntitlementGrant]
    let isRevoked: Bool
    let finishRequired: Bool

    init(
        transactionJws: String,
        transactionId: String,
        originalTransactionId: String,
        productId: String,
        distinctId: String,
        recordedAt: Date,
        localEntitlementGrants: [StoredLocalEntitlementGrant],
        isRevoked: Bool,
        finishRequired: Bool = false
    ) {
        self.transactionJws = transactionJws
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.productId = productId
        self.distinctId = distinctId
        self.recordedAt = recordedAt
        self.localEntitlementGrants = localEntitlementGrants
        self.isRevoked = isRevoked
        self.finishRequired = finishRequired
    }
}

protocol TransactionEvidenceStoreProtocol: Sendable {
    func load() -> [String: StoredTransactionEvidence]
    @discardableResult
    func save(_ entries: [String: StoredTransactionEvidence]) -> Bool
}

/// Protected, minimal transaction evidence retained until the backend accepts
/// it. This is deliberately separate from preferences, analytics, and Journey
/// state. The file uses iOS data protection when available.
final class TransactionEvidenceStore: TransactionEvidenceStoreProtocol {
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
        fileURL = base.appendingPathComponent("transaction-evidence.json")
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
    }

    func load() -> [String: StoredTransactionEvidence] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(
            [String: StoredTransactionEvidence].self,
            from: data
        )) ?? [:]
    }

    @discardableResult
    func save(_ entries: [String: StoredTransactionEvidence]) -> Bool {
        if entries.isEmpty {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch CocoaError.fileNoSuchFile {
                // There is nothing to remove; the empty store is durable.
            } catch {
                LogError("TransactionEvidenceStore: failed to clear evidence")
                return false
            }
            return true
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else {
            LogError("TransactionEvidenceStore: failed to encode evidence")
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
        } catch {
            LogError("TransactionEvidenceStore: failed to persist evidence")
            return false
        }
        return true
    }
}

final class InMemoryTransactionEvidenceStore:
    TransactionEvidenceStoreProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var entries: [String: StoredTransactionEvidence] = [:]

    func load() -> [String: StoredTransactionEvidence] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    @discardableResult
    func save(_ entries: [String: StoredTransactionEvidence]) -> Bool {
        lock.lock()
        self.entries = entries
        lock.unlock()
        return true
    }
}
