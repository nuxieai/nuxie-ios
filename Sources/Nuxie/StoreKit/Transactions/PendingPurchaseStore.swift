import Foundation

/// Persistence seam for Ask-to-Buy/SCA deferred-purchase markers
/// (`TransactionService.pendingPurchases`). The marker set is tiny (rarely
/// more than one entry) but must survive a process kill: the deferred
/// transaction usually arrives via `Transaction.updates` in a LATER launch,
/// and only a surviving marker lets the observer emit `$purchase_completed`
/// (source: deferred_transaction) for it.
protocol PendingPurchaseStoreProtocol: Sendable {
    /// Load every persisted marker (productId → recordedAt).
    func load() -> [String: Date]

    /// Persist the full marker set, replacing whatever was stored.
    func save(_ entries: [String: Date])
}

/// Flat-file marker store under the same storage root as `JourneyStore`
/// (`<customStoragePath|Application Support>/nuxie/pending-purchases.json`).
/// A single small JSON dictionary keyed by product id, ISO-8601 dates,
/// written atomically.
final class PendingPurchaseStore: PendingPurchaseStoreProtocol {

    private let fileURL: URL

    init(customStoragePath: URL? = nil) {
        let baseStoragePath: URL
        if let customPath = customStoragePath {
            baseStoragePath = customPath.appendingPathComponent("nuxie", isDirectory: true)
        } else {
            baseStoragePath = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("nuxie", isDirectory: true)
        }
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

    func load() -> [String: Date] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([String: Date].self, from: data)
        } catch {
            // A corrupt marker file loses pending markers (degrades to the
            // pre-persistence behavior) rather than wedging every load.
            LogError("PendingPurchaseStore: failed to decode \(fileURL.lastPathComponent): \(error)")
            try? FileManager.default.removeItem(at: fileURL)
            return [:]
        }
    }

    func save(_ entries: [String: Date]) {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            LogError("PendingPurchaseStore: failed to persist markers: \(error)")
        }
    }
}

/// In-memory marker store for tests and fixture hosts that do not model a
/// process kill.
final class InMemoryPendingPurchaseStore: PendingPurchaseStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Date] = [:]

    init() {}

    func load() -> [String: Date] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func save(_ entries: [String: Date]) {
        lock.lock()
        self.entries = entries
        lock.unlock()
    }
}
