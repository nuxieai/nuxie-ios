import Foundation
@testable import Nuxie

public actor InMemoryCachedProfileStore: CachedProfileStore {
    private struct Entry {
        var value: CachedProfile
        var mtime: Date
        var size: Int64 { // rough size estimate for stats
            // Not exact, but good enough for tests
            1 + Int64(
            value.response.campaigns.count
                + value.response.segments.count
            )
        }
    }
    
    private var storage: [String: Entry] = [:]
    private let ttl: TimeInterval? // nil => never expires
    
    public init(ttl: TimeInterval? = 24 * 60 * 60) {
        self.ttl = ttl
    }
    
    public func store(_ item: CachedProfile, forKey key: String) async throws {
        storage[key] = Entry(value: item, mtime: Date())
    }
    
    public func retrieve(forKey key: String, allowStale: Bool) async -> CachedProfile? {
        guard var entry = storage[key] else { return nil }
        // Non-stale read honors TTL (if set)
        if !allowStale, let ttl = ttl, Date().timeIntervalSince(entry.mtime) > ttl {
            return nil
        }
        // Touch mtime like an LRU (optional, helps tests that check ordering)
        entry.mtime = Date()
        storage[key] = entry
        return entry.value
    }
    
    public func remove(forKey key: String) async {
        storage.removeValue(forKey: key)
    }
    
    public func clearAll() async {
        storage.removeAll()
    }
    
    @discardableResult
    public func cleanupExpired() async -> Int {
        guard let ttl = ttl else { return 0 }
        let now = Date()
        let before = storage.count
        storage = storage.filter { _, e in now.timeIntervalSince(e.mtime) <= ttl }
        return before - storage.count
    }
    
    public func getAllKeys() async -> [String] {
        Array(storage.keys)
    }
    
    public func getMetadata(forKey key: String) async -> DiskCacheMetadata? {
        guard let e = storage[key] else { return nil }
        return DiskCacheMetadata(
            key: key,
            lastModified: e.mtime,
            size: e.size,
            age: Date().timeIntervalSince(e.mtime)
        )
    }
}

/// Sometimes you want to assert network-only behavior.
public actor NullCachedProfileStore: CachedProfileStore {
    public init() {}
    public func store(_ item: CachedProfile, forKey key: String) async throws {}
    public func retrieve(forKey key: String, allowStale: Bool) async -> CachedProfile? { nil }
    public func remove(forKey key: String) async {}
    public func clearAll() async {}
    public func cleanupExpired() async -> Int { 0 }
    public func getAllKeys() async -> [String] { [] }
    public func getMetadata(forKey key: String) async -> DiskCacheMetadata? { nil }
}
