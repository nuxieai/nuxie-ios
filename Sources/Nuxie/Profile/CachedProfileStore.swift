import Foundation

/// Protocol specialized for caching `CachedProfile` items.
/// Keeping it non-generic avoids associatedtype headaches in DI.
protocol CachedProfileStore: Sendable {
    func store(_ item: CachedProfile, forKey key: String) async throws
    func retrieve(forKey key: String, allowStale: Bool) async -> CachedProfile?
    func remove(forKey key: String) async
    func clearAll() async
    @discardableResult
    func cleanupExpired() async -> Int
    func getAllKeys() async -> [String]
    func getMetadata(forKey key: String) async -> DiskCacheMetadata?
}
