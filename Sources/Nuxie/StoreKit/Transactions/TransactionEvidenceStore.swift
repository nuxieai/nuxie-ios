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
}

protocol TransactionEvidenceStoreProtocol: Sendable {
    func load() -> [String: StoredTransactionEvidence]
    func save(_ entries: [String: StoredTransactionEvidence])
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

    func save(_ entries: [String: StoredTransactionEvidence]) {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
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
        }
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

    func save(_ entries: [String: StoredTransactionEvidence]) {
        lock.lock()
        self.entries = entries
        lock.unlock()
    }
}
