import Foundation

enum StoreReadResult<Value> {
    case absent
    case value(Value)
    case unreadable

    var readableValue: Value? {
        guard case .value(let value) = self else { return nil }
        return value
    }

    /// Absent is legitimate emptiness; unreadable is not. For call sites
    /// where an absent store and an empty store are equivalent.
    func valueTreatingAbsentAsEmpty(_ empty: @autoclosure () -> Value) -> Value? {
        switch self {
        case .absent: return empty()
        case .value(let value): return value
        case .unreadable: return nil
        }
    }

    var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }
}

extension StoreReadResult: Sendable where Value: Sendable {}

final class StoreReadFailureLogger {
    private let lock = NSLock()
    private var didLog = false

    func shouldLog() -> Bool {
        lock.withLock {
            guard !didLog else { return false }
            didLog = true
            return true
        }
    }
}

extension StoreReadFailureLogger: @unchecked Sendable {}

/// A store entry that did not decode: its key and the field that failed,
/// never their values.
struct StoreEntryDecodingFailure: Error {
    let entryId: String
    let field: String
}

extension DecodingError {
    /// The coding path of the field that failed, by key names only.
    var failingKeyPath: [CodingKey] {
        switch self {
        case .typeMismatch(_, let context),
             .valueNotFound(_, let context),
             .dataCorrupted(let context):
            return context.codingPath
        case .keyNotFound(let key, let context):
            return context.codingPath + [key]
        @unknown default:
            return []
        }
    }
}

/// One purchase store's JSON file (transaction evidence, checkout bindings,
/// account ownership and the catalog mapping).
///
/// A file whose bytes were read but do not decode (invalid JSON, or a
/// current-format entry the decoder rejects) is corrupt. It is renamed aside
/// next to the store, as `<name>.unreadable-<epoch millis>.<extension>`, and
/// never read again; an empty store takes its place, so one corrupt record
/// cannot keep the purchase outbox off at every launch. StoreKit redelivers
/// what the store held: its unfinished transactions and current entitlements
/// at launch. Only the newest quarantined file of a store is kept.
///
/// A file that cannot be read right now (a file-system error, such as data
/// protection before the first unlock) is not corrupt. It is left as it is
/// and reads as unreadable, so the outbox is off for the session, and the
/// next launch reads it again.
final class PurchaseStoreFile: @unchecked Sendable {
    let url: URL
    private let storeName: String
    private let logger: NuxieLogger
    private let readFailureLogger = StoreReadFailureLogger()
    private let lock = NSLock()

    init(url: URL, storeName: String, logger: NuxieLogger = .shared) {
        self.url = url
        self.storeName = storeName
        self.logger = logger
    }

    /// The file name prefix of this store's quarantined files.
    var quarantinePrefix: String {
        url.deletingPathExtension().lastPathComponent + ".unreadable-"
    }

    /// Reads the file and decodes it with `decode`. A file that is not there
    /// is absent. A corrupt one is quarantined and reads as absent too; if it
    /// cannot be renamed aside it stays, and reads as unreadable.
    func read<Value>(_ decode: (Data) throws -> Value) -> StoreReadResult<Value> {
        lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                // No bytes were read: the file is not corrupt, only out of
                // reach for now.
                if readFailureLogger.shouldLog() {
                    logger.error(
                        "\(storeName, privacy: .publicValue): the store cannot be read now and is left as it is: \(error)"
                    )
                }
                return .unreadable
            }
            do {
                return .value(try decode(data))
            } catch {
                return quarantine(reason: Self.reason(error)) ? .absent : .unreadable
            }
        }
    }

    /// Renames the corrupt file aside, keeps only the newest quarantined file
    /// of this store, and logs the quarantine once.
    private func quarantine(reason: String) -> Bool {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        var stamp = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        var target = quarantineURL(stamp: stamp)
        while fileManager.fileExists(atPath: target.path) {
            stamp += 1
            target = quarantineURL(stamp: stamp)
        }
        do {
            try fileManager.moveItem(at: url, to: target)
        } catch {
            if readFailureLogger.shouldLog() {
                logger.error(
                    "\(storeName, privacy: .publicValue): the store does not decode (\(reason, privacy: .publicValue)) and could not be set aside, so it is left as it is: \(error)"
                )
            }
            return false
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names
        where name.hasPrefix(quarantinePrefix) && name != target.lastPathComponent {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        logger.warning(
            "\(storeName, privacy: .publicValue): the store does not decode (\(reason, privacy: .publicValue)); it is set aside as \(target.path, privacy: .publicValue) and an empty store takes its place"
        )
        return true
    }

    /// `<name>.unreadable-<epoch millis>.<extension>`, next to the store.
    private func quarantineURL(stamp: Int64) -> URL {
        let pathExtension = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(quarantinePrefix)\(stamp)\(pathExtension)")
    }

    /// Why a file did not decode: the entry and the field that failed, by key
    /// names only, never their values.
    private static func reason(_ error: Error) -> String {
        let failure: StoreEntryDecodingFailure
        if let entry = error as? StoreEntryDecodingFailure {
            failure = entry
        } else if let decoding = error as? DecodingError {
            let path = decoding.failingKeyPath
            guard let entry = path.first else {
                if case .dataCorrupted = decoding { return "the file is not valid JSON" }
                return "the file is not a set of entries"
            }
            failure = StoreEntryDecodingFailure(
                entryId: entry.stringValue,
                field: path.dropFirst().map(\.stringValue).joined(separator: ".")
            )
        } else {
            return "the file does not decode"
        }
        return failure.field.isEmpty
            ? "entry \(failure.entryId)"
            : "entry \(failure.entryId) at \(failure.field)"
    }
}
