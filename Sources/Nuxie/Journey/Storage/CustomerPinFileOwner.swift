import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// References the existing pin layout without copying descriptor or artifact bytes.
struct CustomerPinFileOwner: Sendable {
    let root: URL

    init(journalRoot: URL) {
        root = journalRoot.appendingPathComponent("release-pins", isDirectory: true)
    }

    /// Preparation and collection share this lock. Prepared references stay
    /// protected until admission commits, without holding the lock over hooks.
    func withExclusiveAccess<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let journalRoot = root.deletingLastPathComponent()
        return try await SharedCachePathCoordinator.shared.withExclusiveRootAccess(
            to: journalRoot, lockScope: CacheFilesystemLockScope(cacheRootURL: journalRoot),
            operation: operation
        )
    }

    func protectPreparedPins(_ pins: [CustomerReleasePin]) -> CustomerPinPreparation {
        CustomerPinPreparation(root: root, paths: Set(pins.map(\.relativePath)))
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

    /// Admission makes file bytes and their directory entries durable before referencing them.
    func synchronize(_ pins: [CustomerReleasePin]) throws {
        let files = pins.map { root.appendingPathComponent($0.relativePath) }
        let directories = Set(files.map { $0.deletingLastPathComponent() }).union([root, root.deletingLastPathComponent(), root.deletingLastPathComponent().deletingLastPathComponent()])
        for file in files + directories.sorted(by: { $0.path > $1.path }) {
            let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { close(descriptor) }
            guard fsync(descriptor) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
    }

    func collectOrphans(in store: SQLiteEventStore) async throws -> [String] {
        try await store.customerAssertWriter()
        return try await withExclusiveAccess {
            try await store.collectCustomerPinOrphans(files: self)
        }
    }

    /// Call only while holding withExclusiveAccess, after reading every committed reference.
    /// A failed query never reaches deletion. Unknown files are left alone.
    func collectOrphans(committedPaths: Set<String>) throws -> [String] {
        let committedPaths = committedPaths.union(CustomerPinPreparation.paths(in: root))
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
            if try manager.contentsOfDirectory(atPath: directory.path).isEmpty {
                try manager.removeItem(at: directory)
            }
        }
        return removed.sorted()
    }
}

/// The single customer writer can suspend admission without exposing its files
/// to collection in this process. SQL references take over before release.
final class CustomerPinPreparation: Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: [UUID: Set<String>]] = [:]
    }

    private static let registry = Registry()
    private let root: String
    private let id = UUID()

    init(root: URL, paths: Set<String>) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath().path
        Self.registry.lock.withLock {
            Self.registry.entries[self.root, default: [:]][id] = paths
        }
    }

    static func paths(in root: URL) -> Set<String> {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        return registry.lock.withLock {
            Set(registry.entries[key, default: [:]].values.flatMap { $0 })
        }
    }

    /// The root lock also protects collection's snapshot of SQL references.
    func release() {
        Self.registry.lock.withLock {
            Self.registry.entries[root]?[id] = nil
            if Self.registry.entries[root]?.isEmpty == true {
                Self.registry.entries[root] = nil
            }
        }
    }
}

extension SQLiteEventStore {
    func collectCustomerPinOrphans(files: CustomerPinFileOwner) throws -> [String] {
        try customerAssertWriter()
        return try files.collectOrphans(committedPaths: committedReleasePinPaths())
    }
}
