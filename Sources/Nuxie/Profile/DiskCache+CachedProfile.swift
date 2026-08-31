import Foundation

// Make DiskCache conform to CachedProfileStore when T == CachedProfile
extension DiskCache: CachedProfileStore where T == CachedProfile {
    @discardableResult
    func store(
        _ item: CachedProfile,
        forKey key: String,
        admission: CachedProfileStoreAdmission
    ) throws -> Bool {
        guard admission() else { return false }
        try store(item, forKey: key)
        return true
    }

    @discardableResult
    func remove(
        forKey key: String,
        admission: CachedProfileStoreAdmission
    ) -> Bool {
        guard admission() else { return false }
        remove(forKey: key)
        return true
    }
}
