import Foundation

enum ExperiencePackageStoreError: LocalizedError, Sendable {
    case invalidPointer(String)
    case invalidAssetBaseURL(String)
    case packageSizeMismatch(expected: Int, actual: Int)
    case sha256Mismatch(source: String, expected: String, actual: String)
    case identityMismatch
    case trustRootsUnavailable
    case unsafeAssetKey(String)
    case missingEmbeddedAsset(String)
    case requiredAssetUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidPointer(let reason):
            "Invalid experience package pointer: \(reason)"
        case .invalidAssetBaseURL(let value):
            "Invalid experience asset base URL: \(value)"
        case let .packageSizeMismatch(expected, actual):
            "Experience package size mismatch: expected \(expected), got \(actual)"
        case let .sha256Mismatch(source, expected, actual):
            "SHA-256 mismatch for \(source): expected \(expected), got \(actual)"
        case .identityMismatch:
            "Experience package identity does not match its delivery pointer"
        case .trustRootsUnavailable:
            "No package trust roots are configured for this environment"
        case .unsafeAssetKey(let key):
            "Unsafe content-addressed asset key: \(key)"
        case .missingEmbeddedAsset(let member):
            "Embedded package asset is missing: \(member)"
        case .requiredAssetUnavailable(let key):
            "Required experience asset is unavailable: \(key)"
        }
    }
}

enum ExperiencePackageSource: String, Sendable {
    case cache = "cached_package"
    case download = "downloaded_package"
    case unavailable
    case unknown
}

struct LoadedExperiencePackage: Sendable {
    let remote: RemoteExperience
    let packageURL: URL
    let packageBytes: Data
    let manifest: NuxPackageManifestV1
    let journey: JourneyDocument
    let assetURLsByRiveUniqueName: [String: URL]
    let source: ExperiencePackageSource
    let authorizationKeys: [ExperienceRuntimeAuthorizationKey]

    func localImageURL(for asset: NuxPackageImageAsset) throws -> URL {
        try preparedAssetURL(forRiveUniqueName: asset.riveUniqueName)
    }

    func localFontURL(for asset: NuxPackageFontAsset) throws -> URL {
        try preparedAssetURL(forRiveUniqueName: asset.riveUniqueName)
    }

    func localAssetURL(forRiveUniqueName uniqueName: String) -> URL? {
        assetURLsByRiveUniqueName[uniqueName]
    }

    private func preparedAssetURL(forRiveUniqueName uniqueName: String) throws -> URL {
        guard let url = assetURLsByRiveUniqueName[uniqueName] else {
            throw ExperiencePackageStoreError.requiredAssetUnavailable(uniqueName)
        }
        return url
    }
}

actor ExperiencePackageStore {
    private struct PackageLoadKey: Hashable {
        let digest: String
        let experienceId: String
        let buildId: String
        let assetBaseURL: String
        let includeOptionalAssets: Bool
    }

    private let packageCacheDirectory: URL
    private let assetCacheDirectory: URL
    private let packageLockScope: CacheFilesystemLockScope
    private let assetLockScope: CacheFilesystemLockScope
    private let urlSession: URLSession
    private let authorizationKeys: [ExperienceRuntimeAuthorizationKey]
    private let configuredAssetBaseURL: URL?
    private var inFlight: [PackageLoadKey: Task<LoadedExperiencePackage, Error>] = [:]

    init(
        cacheDirectory: URL? = nil,
        assetCacheDirectory: URL? = nil,
        urlSession: URLSession = .shared,
        authorizationKeys: [ExperienceRuntimeAuthorizationKey] = [],
        configuredAssetBaseURL: URL? = nil
    ) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let packageRoot = cacheDirectory
            ?? caches.appendingPathComponent("nuxie_packages", isDirectory: true)
        let assetRoot = assetCacheDirectory
            ?? caches.appendingPathComponent("nuxie_assets", isDirectory: true)
        packageCacheDirectory = packageRoot
        self.assetCacheDirectory = assetRoot
        packageLockScope = CacheFilesystemLockScope(cacheRootURL: packageRoot)
        assetLockScope = CacheFilesystemLockScope(cacheRootURL: assetRoot)
        self.urlSession = urlSession
        self.authorizationKeys = authorizationKeys
        self.configuredAssetBaseURL = configuredAssetBaseURL
    }

    func preloadPackage(
        for remote: RemoteExperience,
        assetBaseURL: URL
    ) async {
        do {
            _ = try await getOrDownloadPackage(
                for: remote,
                assetBaseURL: assetBaseURL,
                includeOptionalAssets: false
            )
        } catch {
            LogError(
                "Failed to prefetch experience package \(remote.versionId): \(error)"
            )
        }
    }

    func getCachedPackage(
        for remote: RemoteExperience,
        assetBaseURL: URL
    ) async throws -> LoadedExperiencePackage? {
        try validate(remote)
        let packageURL = try cachedPackageURL(for: remote)
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            return nil
        }
        return try await loadCachedPackage(
            remote,
            packageURL: packageURL,
            assetBaseURL: effectiveAssetBaseURL(profileValue: assetBaseURL),
            source: .cache,
            includeOptionalAssets: true
        )
    }

    func getOrDownloadPackage(
        for remote: RemoteExperience,
        assetBaseURL: URL
    ) async throws -> LoadedExperiencePackage {
        try await getOrDownloadPackage(
            for: remote,
            assetBaseURL: assetBaseURL,
            includeOptionalAssets: true
        )
    }

    private func getOrDownloadPackage(
        for remote: RemoteExperience,
        assetBaseURL: URL,
        includeOptionalAssets: Bool
    ) async throws -> LoadedExperiencePackage {
        try validate(remote)
        let effectiveBaseURL = effectiveAssetBaseURL(profileValue: assetBaseURL)
        let key = PackageLoadKey(
            digest: remote.artifact.sha256.lowercased(),
            experienceId: remote.experienceId,
            buildId: remote.buildId,
            assetBaseURL: effectiveBaseURL.absoluteString,
            includeOptionalAssets: includeOptionalAssets
        )
        if let task = inFlight[key] {
            return try await task.value
        }

        let task = Task<LoadedExperiencePackage, Error> { [self] in
            let packageURL = try cachedPackageURL(for: remote)
            return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
                to: packageURL,
                lockScope: packageLockScope
            ) {
                if FileManager.default.fileExists(atPath: packageURL.path) {
                    do {
                        return try await self.loadCachedPackage(
                            remote,
                            packageURL: packageURL,
                            assetBaseURL: effectiveBaseURL,
                            source: .cache,
                            includeOptionalAssets: includeOptionalAssets
                        )
                    } catch {
                        try? FileManager.default.removeItem(at: packageURL)
                    }
                }
                return try await self.downloadAndLoadPackage(
                    remote,
                    packageURL: packageURL,
                    assetBaseURL: effectiveBaseURL,
                    includeOptionalAssets: includeOptionalAssets
                )
            }
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Removes packages not named by the current profile and assets not
    /// referenced by any retained package's signed manifest.
    func evictUnreferencedPackages(retaining remotes: [RemoteExperience]) async {
        let retainedPackageNames = Set(
            remotes.map { "\($0.artifact.sha256.lowercased()).nux" }
        )
        do {
            var retainedAssetNames = Set<String>()
            for remote in remotes {
                let packageURL = try cachedPackageURL(for: remote)
                guard FileManager.default.fileExists(atPath: packageURL.path),
                      let read = try? BoundedFileIO.read(
                        at: packageURL,
                        maximumBytes: NuxPackageLimits.packageBytes
                      ),
                      read.digest.sha256 == remote.artifact.sha256.lowercased(),
                      let contents = try? NuxPackageReader.read(read.data) else {
                    continue
                }
                for declaration in contents.manifest.assets.images {
                    retainedAssetNames.insert(
                        try cacheFileName(
                            sha256: declaration.sha256,
                            location: declaration.location
                        )
                    )
                }
                for declaration in contents.manifest.assets.fonts {
                    retainedAssetNames.insert(
                        try cacheFileName(
                            sha256: declaration.sha256,
                            location: declaration.location
                        )
                    )
                }
            }
            try await removeFiles(
                in: packageCacheDirectory,
                retaining: retainedPackageNames,
                lockScope: packageLockScope
            )
            try await removeFiles(
                in: assetCacheDirectory,
                retaining: retainedAssetNames,
                lockScope: assetLockScope
            )
        } catch {
            LogError("Failed to evict unreferenced experience packages: \(error)")
        }
    }

    func clearCache() async {
        do {
            try await CacheFilesystemLock.withExclusiveRootTransaction(
                scope: packageLockScope
            ) {
                try? FileManager.default.removeItem(at: self.packageCacheDirectory)
            }
            try await CacheFilesystemLock.withExclusiveRootTransaction(
                scope: assetLockScope
            ) {
                try? FileManager.default.removeItem(at: self.assetCacheDirectory)
            }
        } catch {
            LogError("Failed to clear experience package cache: \(error)")
        }
    }

    private func downloadAndLoadPackage(
        _ remote: RemoteExperience,
        packageURL: URL,
        assetBaseURL: URL,
        includeOptionalAssets: Bool
    ) async throws -> LoadedExperiencePackage {
        guard let sourceURL = URL(string: remote.artifact.url) else {
            throw ExperiencePackageStoreError.invalidPointer("artifact URL")
        }
        try FileManager.default.createDirectory(
            at: packageCacheDirectory,
            withIntermediateDirectories: true
        )

        if sourceURL.isFileURL {
            let digest = try BoundedFileIO.copyVerified(
                from: sourceURL,
                to: packageURL,
                expectedSize: remote.artifact.sizeBytes,
                expectedSHA256: remote.artifact.sha256,
                maximumBytes: NuxPackageLimits.packageBytes
            )
            guard digest.byteCount == remote.artifact.sizeBytes else {
                throw ExperiencePackageStoreError.packageSizeMismatch(
                    expected: remote.artifact.sizeBytes,
                    actual: digest.byteCount
                )
            }
        } else {
            let download = try await BoundedHTTPAcquisition.download(
                from: sourceURL,
                using: urlSession,
                maximumBytes: NuxPackageLimits.packageBytes,
                temporaryDirectory: packageCacheDirectory
            )
            defer { try? FileManager.default.removeItem(at: download.temporaryURL) }
            guard download.byteCount == remote.artifact.sizeBytes else {
                throw ExperiencePackageStoreError.packageSizeMismatch(
                    expected: remote.artifact.sizeBytes,
                    actual: download.byteCount
                )
            }
            _ = try BoundedFileIO.copyVerified(
                from: download.temporaryURL,
                to: packageURL,
                expectedSize: remote.artifact.sizeBytes,
                expectedSHA256: remote.artifact.sha256,
                maximumBytes: NuxPackageLimits.packageBytes
            )
        }

        return try await loadCachedPackage(
            remote,
            packageURL: packageURL,
            assetBaseURL: assetBaseURL,
            source: .download,
            includeOptionalAssets: includeOptionalAssets
        )
    }

    private func loadCachedPackage(
        _ remote: RemoteExperience,
        packageURL: URL,
        assetBaseURL: URL,
        source: ExperiencePackageSource,
        includeOptionalAssets: Bool
    ) async throws -> LoadedExperiencePackage {
        // Every open re-hashes the complete cached package before import.
        let read = try BoundedFileIO.read(
            at: packageURL,
            maximumBytes: NuxPackageLimits.packageBytes
        )
        guard read.digest.byteCount == remote.artifact.sizeBytes else {
            throw ExperiencePackageStoreError.packageSizeMismatch(
                expected: remote.artifact.sizeBytes,
                actual: read.digest.byteCount
            )
        }
        guard read.digest.sha256 == remote.artifact.sha256.lowercased() else {
            throw ExperiencePackageStoreError.sha256Mismatch(
                source: packageURL.path,
                expected: remote.artifact.sha256,
                actual: read.digest.sha256
            )
        }

        let contents = try NuxPackageReader.read(read.data)
        guard contents.manifest.identity.experienceId == remote.experienceId,
              contents.manifest.identity.buildId == remote.buildId else {
            throw ExperiencePackageStoreError.identityMismatch
        }
        guard !authorizationKeys.isEmpty else {
            throw ExperiencePackageStoreError.trustRootsUnavailable
        }
        try ExperienceRuntimePackageAdapter.validateManifestAssetBounds(
            contents.manifest
        )
        let assetURLs = try await prepareAssets(
            manifest: contents.manifest,
            contents: contents,
            baseURL: assetBaseURL,
            includeOptionalAssets: includeOptionalAssets
        )
        return LoadedExperiencePackage(
            remote: remote,
            packageURL: packageURL,
            packageBytes: read.data,
            manifest: contents.manifest,
            journey: contents.journey,
            assetURLsByRiveUniqueName: assetURLs,
            source: source,
            authorizationKeys: authorizationKeys
        )
    }

    private func prepareAssets(
        manifest: NuxPackageManifestV1,
        contents: NuxPackageContents,
        baseURL: URL,
        includeOptionalAssets: Bool
    ) async throws -> [String: URL] {
        var prepared: [String: URL] = [:]
        for declaration in manifest.assets.images
        where includeOptionalAssets || declaration.required {
            if let url = try await prepareAsset(
                location: declaration.location,
                sha256: declaration.sha256,
                sizeBytes: declaration.sizeBytes,
                required: declaration.required,
                contents: contents,
                baseURL: baseURL
            ) {
                prepared[declaration.riveUniqueName] = url
            }
        }
        for declaration in manifest.assets.fonts
        where includeOptionalAssets || declaration.required {
            if let url = try await prepareAsset(
                location: declaration.location,
                sha256: declaration.sha256,
                sizeBytes: declaration.sizeBytes,
                required: declaration.required,
                contents: contents,
                baseURL: baseURL
            ) {
                prepared[declaration.riveUniqueName] = url
            }
        }
        return prepared
    }

    private func prepareAsset(
        location: NuxPackageAssetLocation,
        sha256: String,
        sizeBytes: Int,
        required: Bool,
        contents: NuxPackageContents,
        baseURL: URL
    ) async throws -> URL? {
        do {
            guard sizeBytes >= 0, sizeBytes <= NuxPackageLimits.externalAssetBytes else {
                throw ExperiencePackageStoreError.invalidPointer("asset size")
            }
            let fileName = try cacheFileName(sha256: sha256, location: location)
            let destination = assetCacheDirectory.appendingPathComponent(fileName)
            return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
                to: destination,
                lockScope: assetLockScope
            ) {
                if FileManager.default.fileExists(atPath: destination.path) {
                    let digest = try BoundedFileIO.inspect(
                        at: destination,
                        maximumBytes: NuxPackageLimits.externalAssetBytes
                    )
                    if digest.byteCount == sizeBytes,
                       digest.sha256 == sha256.lowercased() {
                        return destination
                    }
                    try? FileManager.default.removeItem(at: destination)
                }

                switch location {
                case .embedded(let member):
                    guard let range = contents.members[member] else {
                        throw ExperiencePackageStoreError.missingEmbeddedAsset(member)
                    }
                    let bytes = contents.bytes.subdata(in: range)
                    let staging = FileManager.default.temporaryDirectory
                        .appendingPathComponent("nuxie-embedded-\(UUID().uuidString)")
                    try bytes.write(to: staging, options: .atomic)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    _ = try BoundedFileIO.copyVerified(
                        from: staging,
                        to: destination,
                        expectedSize: sizeBytes,
                        expectedSHA256: sha256,
                        maximumBytes: NuxPackageLimits.externalAssetBytes
                    )
                case .external(let key):
                    _ = try self.validateContentAddressedKey(key, sha256: sha256)
                    guard let sourceURL = URL(
                        string: key,
                        relativeTo: baseURL.appendingPathComponent("", isDirectory: true)
                    )?.absoluteURL else {
                        throw ExperiencePackageStoreError.invalidAssetBaseURL(
                            baseURL.absoluteString
                        )
                    }
                    if sourceURL.isFileURL {
                        _ = try BoundedFileIO.copyVerified(
                            from: sourceURL,
                            to: destination,
                            expectedSize: sizeBytes,
                            expectedSHA256: sha256,
                            maximumBytes: NuxPackageLimits.externalAssetBytes
                        )
                    } else {
                        let download = try await BoundedHTTPAcquisition.download(
                            from: sourceURL,
                            using: self.urlSession,
                            maximumBytes: NuxPackageLimits.externalAssetBytes,
                            temporaryDirectory: self.assetCacheDirectory
                        )
                        defer { try? FileManager.default.removeItem(at: download.temporaryURL) }
                        _ = try BoundedFileIO.copyVerified(
                            from: download.temporaryURL,
                            to: destination,
                            expectedSize: sizeBytes,
                            expectedSHA256: sha256,
                            maximumBytes: NuxPackageLimits.externalAssetBytes
                        )
                    }
                }
                return destination
            }
        } catch {
            if required {
                throw error
            }
            return nil
        }
    }

    private func validate(_ remote: RemoteExperience) throws {
        guard remote.artifact.packageVersion == 1 else {
            throw ExperiencePackageStoreError.invalidPointer("packageVersion")
        }
        guard remote.artifact.sizeBytes >= 0,
              remote.artifact.sizeBytes <= NuxPackageLimits.packageBytes else {
            throw ExperiencePackageStoreError.invalidPointer("sizeBytes")
        }
        _ = try normalizedSHA256(remote.artifact.sha256)
        guard !remote.experienceId.isEmpty,
              !remote.versionId.isEmpty,
              !remote.buildId.isEmpty else {
            throw ExperiencePackageStoreError.invalidPointer("identity")
        }
    }

    private func cachedPackageURL(for remote: RemoteExperience) throws -> URL {
        packageCacheDirectory.appendingPathComponent(
            "\(try normalizedSHA256(remote.artifact.sha256)).nux"
        )
    }

    private func effectiveAssetBaseURL(profileValue: URL) -> URL {
        configuredAssetBaseURL ?? profileValue
    }

    nonisolated private func cacheFileName(
        sha256: String,
        location: NuxPackageAssetLocation
    ) throws -> String {
        let normalized = try normalizedSHA256(sha256)
        let path = try validateContentAddressedKey(
            location.contentAddressedPath,
            sha256: normalized
        )
        return "\(normalized).\(URL(fileURLWithPath: path).pathExtension.lowercased())"
    }

    nonisolated private func validateContentAddressedKey(
        _ key: String,
        sha256: String
    ) throws -> String {
        let components = key.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "assets",
              components[1] == "sha256",
              !components[2].isEmpty,
              !key.contains("\\"),
              !key.contains("..") else {
            throw ExperiencePackageStoreError.unsafeAssetKey(key)
        }
        let file = String(components[2])
        let expectedPrefix = "\(try normalizedSHA256(sha256))."
        let allowed = Set(["png", "jpg", "jpeg", "webp", "ttf", "otf"])
        guard file.hasPrefix(expectedPrefix),
              allowed.contains(URL(fileURLWithPath: file).pathExtension.lowercased()) else {
            throw ExperiencePackageStoreError.unsafeAssetKey(key)
        }
        return key
    }

    nonisolated private func normalizedSHA256(_ value: String) throws -> String {
        let normalized = value.lowercased()
        guard normalized.count == 64,
              normalized.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            throw ExperiencePackageStoreError.invalidPointer("sha256")
        }
        return normalized
    }

    private func removeFiles(
        in directory: URL,
        retaining names: Set<String>,
        lockScope: CacheFilesystemLockScope
    ) async throws {
        try await CacheFilesystemLock.withExclusiveRootTransaction(scope: lockScope) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { return }
            for file in files where !names.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        // Kept as one shared test/support utility; production file verification
        // streams through BoundedFileIO.
        importCryptoKitSHA256(data)
    }
}

private func importCryptoKitSHA256(_ data: Data) -> String {
    // Isolated below so the store's acquisition path cannot accidentally use
    // an eager in-memory digest for downloads.
    SHA256Provider.hexDigest(data)
}
