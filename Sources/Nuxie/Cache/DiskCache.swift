import CryptoKit
import Foundation

public struct DiskCacheOptions {
    /// Base directory to write under (e.g., Application Support or Caches)
    public var baseDirectory: URL
    /// Subdirectory created inside the base directory
    public var subdirectory: String
    /// Optional default TTL used by `retrieve(allowStale:) == false` and cleanup
    public var defaultTTL: TimeInterval?
    /// Optional maximum total bytes; if exceeded, oldest files are evicted
    public var maxTotalBytes: Int64?
    /// Whether to exclude the cache dir from backups (recommended true for caches)
    public var excludeFromBackup: Bool
    /// File protection; applied after each write on iOS/tvOS/watchOS
    public var fileProtection: FileProtectionType?

    public init(
        baseDirectory: URL,
        subdirectory: String,
        defaultTTL: TimeInterval? = nil,
        maxTotalBytes: Int64? = nil,
        excludeFromBackup: Bool = true,
        fileProtection: FileProtectionType? = .completeUntilFirstUserAuthentication
    ) {
        self.baseDirectory = baseDirectory
        self.subdirectory = subdirectory
        self.defaultTTL = defaultTTL
        self.maxTotalBytes = maxTotalBytes
        self.excludeFromBackup = excludeFromBackup
        self.fileProtection = fileProtection
    }
}

public struct DiskCacheMetadata: Sendable {
    public let key: String
    public let lastModified: Date
    public let size: Int64
    public let age: TimeInterval
}

public actor DiskCache<T: Codable> {

    // MARK: - State

    private let directory: URL
    private let options: DiskCacheOptions
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Init

    public init(options: DiskCacheOptions) throws {
        self.options = options
        self.directory = options.baseDirectory.appendingPathComponent(
            options.subdirectory, isDirectory: true)

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: nil)

        if options.excludeFromBackup {
            var mutableDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutableDirectory.setResourceValues(values)
        }
    }

    // MARK: - Public API

    /// Store an item. Overwrites if exists.
    public func store(_ item: T, forKey key: String) throws {
        let url = fileURL(forKey: key)
        let data = try encoder.encode(item)
        try data.write(to: url, options: .atomic)
        applyProtectionIfAvailable(at: url)
        try enforceMaxSizeIfNeeded()
    }

    /// Retrieve an item. If `allowStale == false`, honors `options.defaultTTL` if set.
    public func retrieve(forKey key: String, allowStale: Bool = true) -> T? {
        let url = fileURL(forKey: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        if !allowStale, let ttl = options.defaultTTL {
            if let meta = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                let mtime = meta.contentModificationDate,
                Date().timeIntervalSince(mtime) > ttl
            {
                return nil
            }
        }

        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(T.self, from: data)
        } catch {
            // If corrupted, remove the file.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Remove one key.
    public func remove(forKey key: String) {
        let url = fileURL(forKey: key)
        try? FileManager.default.removeItem(at: url)
    }

    /// Remove everything.
    public func clearAll() {
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [])
        {
            for url in urls where url.pathExtension == "json" {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Keys are hashed to filenames; this returns the hashed basenames (debugging/stat use).
    public func getAllKeys() -> [String] {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [])
        else {
            return []
        }
        return urls.filter { $0.pathExtension == "json" }.map {
            $0.deletingPathExtension().lastPathComponent
        }
    }

    public func getMetadata(forKey key: String) -> DiskCacheMetadata? {
        let url = fileURL(forKey: key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let modDate = attrs[.modificationDate] as? Date,
            let size = attrs[.size] as? NSNumber
        else { return nil }
        return DiskCacheMetadata(
            key: key,
            lastModified: modDate,
            size: size.int64Value,
            age: Date().timeIntervalSince(modDate)
        )
    }

    /// Removes expired files using `defaultTTL`. Returns count removed.
    @discardableResult
    public func cleanupExpired() -> Int {
        guard let ttl = options.defaultTTL else { return 0 }
        var removed = 0
        let fm = FileManager.default
        guard
            let urls = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [])
        else {
            return 0
        }
        for url in urls where url.pathExtension == "json" {
            guard
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            else { continue }
            if Date().timeIntervalSince(mtime) > ttl {
                try? fm.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }

    // MARK: - Helpers

    private func fileURL(forKey key: String) -> URL {
        let hex = sha256Hex(key) + ".json"
        return directory.appendingPathComponent(hex, isDirectory: false)
    }

    private func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func applyProtectionIfAvailable(at url: URL) {
        #if os(iOS) || os(tvOS) || os(watchOS)
            if let protection = options.fileProtection {
                try? FileManager.default.setAttributes(
                    [.protectionKey: protection], ofItemAtPath: url.path)
            }
        #endif
    }

    private func currentTotalBytes() throws -> Int64 {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [])
        var total: Int64 = 0
        for url in urls where url.pathExtension == "json" {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Enforce LRU (by mtime) when `maxTotalBytes` is set.
    private func enforceMaxSizeIfNeeded() throws {
        guard let max = options.maxTotalBytes else { return }
        let fm = FileManager.default
        var urls = try fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: []
        )
        .filter { $0.pathExtension == "json" }

        var total = try currentTotalBytes()
        if total <= max { return }

        urls.sort {
            let a =
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
            let b =
                (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
            return a < b  // oldest first
        }

        for url in urls {
            if total <= max { break }
            if let sz = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                try? fm.removeItem(at: url)
                total -= Int64(sz)
            } else {
                try? fm.removeItem(at: url)
            }
        }
    }
}
