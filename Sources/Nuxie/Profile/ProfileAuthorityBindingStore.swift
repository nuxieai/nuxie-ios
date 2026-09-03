import Foundation

protocol ProfileAuthorityBindingStore: Sendable {
    func authority() async throws -> ProfileDeliveryAuthority?

    /// Bind only transport-authenticated network metadata. A different value
    /// is rejected rather than replacing the app authority for this credential.
    func bind(_ authority: ProfileDeliveryAuthority) async throws -> Bool
}

actor InMemoryProfileAuthorityBindingStore: ProfileAuthorityBindingStore {
    private var value: ProfileDeliveryAuthority?

    init(authority: ProfileDeliveryAuthority? = nil) {
        value = authority
    }

    func authority() -> ProfileDeliveryAuthority? {
        value
    }

    func bind(_ authority: ProfileDeliveryAuthority) -> Bool {
        guard authority.isValid else { return false }
        guard value == nil || value == authority else { return false }
        value = authority
        return true
    }
}

struct FileProfileAuthorityBindingStore: ProfileAuthorityBindingStore {
    private static let maximumBytes = 1_024

    private let file: URL
    private let lockScope: CacheFilesystemLockScope

    init(baseDirectory: URL, storageScope: ProfileStorageScope) throws {
        let directory = baseDirectory.appendingPathComponent(
            "profile-authorities-v1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        file = directory.appendingPathComponent(
            storageScope.authorityBindingFilename,
            isDirectory: false
        )
        lockScope = CacheFilesystemLockScope(cacheRootURL: directory)
    }

    func authority() async throws -> ProfileDeliveryAuthority? {
        let file = file
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: file,
            lockScope: lockScope
        ) {
            try Self.load(file)
        }
    }

    func bind(_ authority: ProfileDeliveryAuthority) async throws -> Bool {
        guard authority.isValid else { return false }
        let file = file
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: file,
            lockScope: lockScope
        ) {
            if let existing = try Self.load(file) {
                return existing == authority
            }
            let data = try ExactJSONCodec.encode(authority)
            guard data.count <= Self.maximumBytes else { return false }
            try data.write(
                to: file,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication,
                ]
            )
            return true
        }
    }

    private static func load(_ file: URL) throws -> ProfileDeliveryAuthority? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try BoundedFileIO.read(
            at: file,
            maximumBytes: maximumBytes
        ).data
        let authority = try ExactJSONCodec.decode(
            ProfileDeliveryAuthority.self,
            from: data
        )
        guard authority.isValid else {
            throw JourneyReleaseAuthenticationError.invalidDescriptor
        }
        return authority
    }
}
