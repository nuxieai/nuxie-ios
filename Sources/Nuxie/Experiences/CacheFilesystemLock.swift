import CryptoKit
import Darwin
import Foundation

enum CacheFilesystemLockError: LocalizedError {
    case openFailed(path: String, code: Int32)
    case lockFailed(path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case let .openFailed(path, code):
            "Could not open cache lock \(path): errno \(code)"
        case let .lockFailed(path, code):
            "Could not acquire cache lock \(path): errno \(code)"
        }
    }
}

/// Stable lock namespace for one cache root. Lock files live beside the cache
/// root, so deleting or replacing cached content never replaces a held lock's
/// inode or lets a second process enter the same transaction concurrently.
struct CacheFilesystemLockScope: Sendable {
    fileprivate let rootLockURL: URL
    fileprivate let stripeLockDirectoryURL: URL
    private let configuredRootURL: URL
    private let canonicalRootURL: URL

    init(cacheRootURL: URL) {
        let configuredRoot = cacheRootURL.standardizedFileURL
        let canonicalRoot = configuredRoot
            .resolvingSymlinksInPath()
        let rootIdentity = Self.sha256Hex(canonicalRoot.path)
        let namespaceURL = canonicalRoot.deletingLastPathComponent()
            .appendingPathComponent(".nuxie-cache-locks", isDirectory: true)
            .appendingPathComponent(rootIdentity, isDirectory: true)
        rootLockURL = namespaceURL.appendingPathComponent("root.lock")
        stripeLockDirectoryURL = namespaceURL.appendingPathComponent(
            "stripes",
            isDirectory: true
        )
        configuredRootURL = configuredRoot
        canonicalRootURL = canonicalRoot
    }

    fileprivate func targetLockURL(for targetURL: URL) -> URL {
        // A fixed stripe set bounds the lock namespace to 256 target files per
        // cache root. Hash collisions only serialize unrelated cache work.
        let targetPath = canonicalTargetPath(for: targetURL)
        let digest = SHA256.hash(data: Data(targetPath.utf8))
        let stripe = Array(digest)[0]
        return stripeLockDirectoryURL.appendingPathComponent(
            String(format: "%02x.lock", stripe)
        )
    }

    /// Resolving a missing target does not resolve a symlink in its parent on
    /// Darwin. Deriving the target from the already-canonical cache root keeps
    /// stores configured through different root aliases on the same stripe.
    private func canonicalTargetPath(for targetURL: URL) -> String {
        let target = targetURL.standardizedFileURL
        let configuredRootPath = configuredRootURL.path
        guard target.path != configuredRootPath else {
            return canonicalRootURL.path
        }
        let descendantPrefix = configuredRootPath == "/"
            ? "/"
            : configuredRootPath + "/"
        guard target.path.hasPrefix(descendantPrefix) else {
            return target.resolvingSymlinksInPath().path
        }
        let relativePath = String(target.path.dropFirst(descendantPrefix.count))
        return canonicalRootURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .path
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Cooperating cross-process cache transaction lock.
///
/// Normal path transactions hold a shared root lock plus an exclusive target
/// lock. Root mutations such as clear/remove take the root lock exclusively,
/// so they cannot race validation, publication, or invalidation of any target.
enum CacheFilesystemLock {
    static func withTargetTransaction<Value: Sendable>(
        scope: CacheFilesystemLockScope,
        targetURL: URL,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let rootLock = try await acquire(at: scope.rootLockURL, mode: .shared)
        defer { rootLock.release() }
        let targetLock = try await acquire(
            at: scope.targetLockURL(for: targetURL),
            mode: .exclusive
        )
        defer { targetLock.release() }
        return try await operation()
    }

    static func withExclusiveRootTransaction<Value: Sendable>(
        scope: CacheFilesystemLockScope,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let rootLock = try await acquire(at: scope.rootLockURL, mode: .exclusive)
        defer { rootLock.release() }
        return try await operation()
    }

    private enum Mode {
        case shared
        case exclusive

        var operation: Int32 {
            switch self {
            case .shared: LOCK_SH
            case .exclusive: LOCK_EX
            }
        }
    }

    private static func acquire(
        at url: URL,
        mode: Mode
    ) async throws -> HeldCacheFilesystemLock {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw CacheFilesystemLockError.openFailed(
                path: url.path,
                code: errno
            )
        }

        do {
            while flock(descriptor, mode.operation | LOCK_NB) != 0 {
                let code = errno
                guard code == EWOULDBLOCK || code == EAGAIN else {
                    throw CacheFilesystemLockError.lockFailed(
                        path: url.path,
                        code: code
                    )
                }
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try Task.checkCancellation()
            return HeldCacheFilesystemLock(descriptor: descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }
}

private final class HeldCacheFilesystemLock: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func release() {
        let descriptor = stateLock.withLock { () -> Int32? in
            defer { self.descriptor = nil }
            return self.descriptor
        }
        guard let descriptor else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }

    deinit {
        release()
    }
}
