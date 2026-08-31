import Foundation

// Make DiskCache conform to CachedProfileStore when T == CachedProfile
extension DiskCache: CachedProfileStore where T == CachedProfile {
    @discardableResult
    func store(
        _ item: CachedProfile,
        forKey key: String,
        admission: ProfileSideEffectAdmission
    ) throws -> Bool {
        guard admission() else { return false }
        try store(item, forKey: key)
        return true
    }

    @discardableResult
    func remove(
        forKey key: String,
        admission: ProfileSideEffectAdmission
    ) -> Bool {
        guard admission() else { return false }
        remove(forKey: key)
        return true
    }
}
