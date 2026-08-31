import Foundation

/// A synchronous admission predicate evaluated by the cache actor immediately
/// before it mutates durable state.
struct CachedProfileStoreAdmission: Sendable {
    private let isCurrent: @Sendable () -> Bool

    init(isCurrent: @escaping @Sendable () -> Bool) {
        self.isCurrent = isCurrent
    }

    func callAsFunction() -> Bool {
        isCurrent()
    }
}

/// Protocol specialized for caching `CachedProfile` items.
/// Keeping it non-generic avoids associatedtype headaches in DI.
protocol CachedProfileStore: Sendable {
    func store(_ item: CachedProfile, forKey key: String) async throws
    @discardableResult
    func store(
        _ item: CachedProfile,
        forKey key: String,
        admission: CachedProfileStoreAdmission
    ) async throws -> Bool
    func retrieve(forKey key: String, allowStale: Bool) async -> CachedProfile?
    func remove(forKey key: String) async
    @discardableResult
    func remove(
        forKey key: String,
        admission: CachedProfileStoreAdmission
    ) async -> Bool
    func clearAll() async
    @discardableResult
    func cleanupExpired() async -> Int
    func getAllKeys() async -> [String]
    func getMetadata(forKey key: String) async -> DiskCacheMetadata?
}
