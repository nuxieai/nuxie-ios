import Foundation

/// References the existing pin layout without copying descriptor or artifact bytes.
struct CustomerPinFileOwner: Sendable {
    let root: URL

    init(journalRoot: URL) {
        root = journalRoot.appendingPathComponent("release-pins", isDirectory: true)
    }

    static func relativePath(owner: CustomerStoreOwner, sha256: String, kind: CustomerReleasePin.Kind) -> String {
        let digest = owner.scope.customerDigest(distinctId: owner.userId)
        return "\(digest)/\(sha256).\(kind == .descriptor ? "json" : "artifact")"
    }

    func reference(owner: CustomerStoreOwner, sha256: String, kind: CustomerReleasePin.Kind) throws -> CustomerReleasePin {
        guard JourneyReleasePinStore.isLowercaseSHA256(sha256) else { throw CustomerStoreError.invalidRow }
        let path = Self.relativePath(owner: owner, sha256: sha256, kind: kind)
        let file = root.appendingPathComponent(path)
        let expected = root.resolvingSymlinksInPath().appendingPathComponent(path).standardizedFileURL
        guard file.resolvingSymlinksInPath().standardizedFileURL.path == expected.path else { throw CustomerStoreError.invalidRow }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else { throw CustomerStoreError.invalidRow }
        return CustomerReleasePin(objectSHA256: sha256, kind: kind, relativePath: path, sizeBytes: Int64(size))
    }

    func collectOrphans(in store: SQLiteEventStore) async throws -> [String] {
        try await store.customerAssertWriter()
        let journalRoot = root.deletingLastPathComponent()
        return try await SharedCachePathCoordinator.shared.withExclusiveRootAccess(
            to: journalRoot, lockScope: CacheFilesystemLockScope(cacheRootURL: journalRoot)
        ) {
            try await store.collectCustomerPinOrphans(files: self)
        }
    }

    /// The writer calls this synchronously after reading every committed reference.
    /// A failed query never reaches deletion. Unknown files are left alone.
    func collectOrphans(committedPaths: Set<String>) throws -> [String] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [] }
        var removed: [String] = []
        for directory in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  JourneyReleasePinStore.isLowercaseSHA256(directory.lastPathComponent) else { continue }
            for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      ["json", "artifact"].contains(file.pathExtension),
                      JourneyReleasePinStore.isLowercaseSHA256(file.deletingPathExtension().lastPathComponent) else { continue }
                let path = directory.lastPathComponent + "/" + file.lastPathComponent
                if !committedPaths.contains(path) {
                    try manager.removeItem(at: file)
                    removed.append(path)
                }
            }
        }
        return removed.sorted()
    }
}

extension SQLiteEventStore {
    func collectCustomerPinOrphans(files: CustomerPinFileOwner) throws -> [String] {
        try customerAssertWriter()
        return try files.collectOrphans(committedPaths: committedReleasePinPaths())
    }
}
