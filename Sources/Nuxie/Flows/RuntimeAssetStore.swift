import Foundation
#if canImport(CoreText)
import CoreText
#endif

enum RuntimeAssetStoreError: LocalizedError {
    case invalidContentHash(String)
    case invalidAssetURL(String)
    case unsupportedContentType(kind: String, contentType: String)
    case unsupportedFontFormat(String)
    case invalidFontData(path: String, reason: String)
    case missingSourceAsset(String)
    case missingPreparedAsset(String)
    case downloadFailed(String)
    case fileSizeMismatch(path: String, expected: Int, actual: Int)
    case sha256Mismatch(path: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidContentHash(let value):
            return "Invalid runtime asset content hash: \(value)"
        case .invalidAssetURL(let value):
            return "Invalid runtime asset URL: \(value)"
        case let .unsupportedContentType(kind, contentType):
            return "Unsupported \(kind) runtime asset content type: \(contentType)"
        case .unsupportedFontFormat(let format):
            return "Unsupported runtime font format: \(format)"
        case let .invalidFontData(path, reason):
            return "Invalid runtime font data for \(path): \(reason)"
        case .missingSourceAsset(let path):
            return "Runtime asset source file is missing: \(path)"
        case .missingPreparedAsset(let uniqueName):
            return "Runtime asset was not prepared for import: \(uniqueName)"
        case .downloadFailed(let path):
            return "Failed to download runtime asset: \(path)"
        case let .fileSizeMismatch(path, expected, actual):
            return "Runtime asset size mismatch for \(path): expected \(expected), got \(actual)"
        case let .sha256Mismatch(path, expected, actual):
            return "Runtime asset SHA-256 mismatch for \(path): expected \(expected), got \(actual)"
        }
    }
}

struct RuntimeAssetAcquisition {
    let url: URL
    let workByteCount: Int
}

struct MeasuredRuntimeAssetStoreError: Error {
    let underlyingError: Error
    let workByteCount: Int
}

actor RuntimeAssetStore {
    private let cacheDirectory: URL
    private let lockScope: CacheFilesystemLockScope
    private let urlSession: URLSession
    private let maximumAssetBytes: Int

    init(
        urlSession: URLSession = .shared,
        cacheDirectory: URL? = nil,
        maximumAssetBytes: Int = FlowRuntimeImportLimits.externalAssetTotalBytes
    ) {
        precondition(maximumAssetBytes >= 0)
        precondition(maximumAssetBytes <= FlowRuntimeImportLimits.externalAssetTotalBytes)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let resolvedCacheDirectory = cacheDirectory
            ?? caches.appendingPathComponent("nuxie_runtime_assets")
        try? FileManager.default.createDirectory(
            at: resolvedCacheDirectory,
            withIntermediateDirectories: true
        )
        let canonicalCacheDirectory = resolvedCacheDirectory.standardizedFileURL
            .resolvingSymlinksInPath()
        self.cacheDirectory = canonicalCacheDirectory
        self.lockScope = CacheFilesystemLockScope(cacheRootURL: canonicalCacheDirectory)
        self.urlSession = urlSession
        self.maximumAssetBytes = maximumAssetBytes
        LogDebug("RuntimeAssetStore initialized at: \(self.cacheDirectory.path)")
    }

    func cachedImageURL(
        for asset: FlowArtifactImageAsset,
        artifactDirectoryURL: URL,
        expectedSize: Int
    ) async throws -> URL {
        do {
            return try await acquireCachedImageURL(
                for: asset,
                artifactDirectoryURL: artifactDirectoryURL,
                expectedSize: expectedSize,
                maximumWorkBytes: maximumAssetBytes * 2
            ).url
        } catch let error as MeasuredRuntimeAssetStoreError {
            throw error.underlyingError
        }
    }

    func acquireCachedImageURL(
        for asset: FlowArtifactImageAsset,
        artifactDirectoryURL: URL,
        expectedSize: Int,
        maximumWorkBytes: Int
    ) async throws -> RuntimeAssetAcquisition {
        let cacheURL = try imageCacheURL(for: asset)
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: cacheURL,
            lockScope: lockScope
        ) { [self] in
            try await acquireCachedImageURLWithoutCoordination(
                for: asset,
                artifactDirectoryURL: artifactDirectoryURL,
                expectedSize: expectedSize,
                maximumWorkBytes: maximumWorkBytes,
                cacheURL: cacheURL
            )
        }
    }

    private func acquireCachedImageURLWithoutCoordination(
        for asset: FlowArtifactImageAsset,
        artifactDirectoryURL: URL,
        expectedSize: Int,
        maximumWorkBytes: Int,
        cacheURL: URL
    ) async throws -> RuntimeAssetAcquisition {
        try Self.validateImageDescriptor(
            asset,
            expectedSize: expectedSize,
            maximumAssetBytes: maximumAssetBytes
        )
        precondition(maximumWorkBytes >= 0)
        let cacheInspection = inspectVerifiedCachedFileIfPresent(
            at: cacheURL,
            path: cachePathDescription(cacheURL),
            expectedSize: expectedSize,
            expectedSha256: asset.sha256
        )
        if cacheInspection.isValid {
            guard cacheInspection.workByteCount <= maximumWorkBytes else {
                throw MeasuredRuntimeAssetStoreError(
                    underlyingError: FlowRuntimeImportValidationError.valueExceedsLimit(
                        field: "external asset acquisition bytes",
                        actual: cacheInspection.workByteCount,
                        limit: maximumWorkBytes
                    ),
                    workByteCount: cacheInspection.workByteCount
                )
            }
            return RuntimeAssetAcquisition(
                url: cacheURL,
                workByteCount: cacheInspection.workByteCount
            )
        }

        let sourcePath = try FlowArtifactStore.validateRelativePath(asset.path)
        let sourceURL = artifactDirectoryURL.appendingPathComponent(sourcePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw MeasuredRuntimeAssetStoreError(
                underlyingError: RuntimeAssetStoreError.missingSourceAsset(sourcePath),
                workByteCount: cacheInspection.workByteCount
            )
        }
        guard expectedSize <= maximumWorkBytes - cacheInspection.workByteCount else {
            throw MeasuredRuntimeAssetStoreError(
                underlyingError: FlowRuntimeImportValidationError.valueExceedsLimit(
                    field: "external asset acquisition bytes",
                    actual: cacheInspection.workByteCount + expectedSize,
                    limit: maximumWorkBytes
                ),
                workByteCount: cacheInspection.workByteCount
            )
        }

        do {
            let digest = try BoundedFileIO.copyVerified(
                from: sourceURL,
                to: cacheURL,
                expectedSize: expectedSize,
                expectedSHA256: asset.sha256,
                maximumBytes: expectedSize
            )
            return RuntimeAssetAcquisition(
                url: cacheURL,
                workByteCount: cacheInspection.workByteCount + digest.byteCount
            )
        } catch let error as BoundedFileIOError {
            switch error {
            case .valueExceedsLimit(let actual, _):
                throw MeasuredRuntimeAssetStoreError(
                    underlyingError: RuntimeAssetStoreError.fileSizeMismatch(
                        path: sourcePath,
                        expected: expectedSize,
                        actual: actual
                    ),
                    workByteCount: cacheInspection.workByteCount
                )
            }
        } catch let error as BoundedFileVerificationError {
            throw MeasuredRuntimeAssetStoreError(
                underlyingError: runtimeAssetError(error, path: sourcePath),
                workByteCount: cacheInspection.workByteCount
                    + measuredImageVerificationBytes(
                        error,
                        expectedSize: expectedSize
                    )
            )
        } catch {
            throw MeasuredRuntimeAssetStoreError(
                underlyingError: error,
                workByteCount: cacheInspection.workByteCount
            )
        }
    }

    func cachedFontURL(for asset: FlowArtifactFontAsset) async throws -> URL {
        do {
            return try await acquireCachedFontURL(
                for: asset,
                maximumWorkBytes: maximumAssetBytes * 2
            ).url
        } catch let error as MeasuredRuntimeAssetStoreError {
            throw error.underlyingError
        }
    }

    func acquireCachedFontURL(
        for asset: FlowArtifactFontAsset,
        maximumWorkBytes: Int
    ) async throws -> RuntimeAssetAcquisition {
        let cacheURL = try fontCacheURL(for: asset)
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: cacheURL,
            lockScope: lockScope
        ) { [self] in
            try await acquireCachedFontURLWithoutCoordination(
                for: asset,
                maximumWorkBytes: maximumWorkBytes,
                cacheURL: cacheURL
            )
        }
    }

    private func acquireCachedFontURLWithoutCoordination(
        for asset: FlowArtifactFontAsset,
        maximumWorkBytes: Int,
        cacheURL: URL
    ) async throws -> RuntimeAssetAcquisition {
        try Self.validateFontDescriptor(
            asset,
            maximumAssetBytes: maximumAssetBytes
        )
        precondition(maximumWorkBytes >= 0)
        var workByteCount = 0
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            var validCachedWorkByteCount: Int?
            do {
                let cachedPayload = try readFontFile(
                    at: cacheURL,
                    path: cachePathDescription(cacheURL),
                    expectedSize: asset.sizeBytes
                )
                try verify(
                    cachedPayload.digest,
                    path: cachePathDescription(cacheURL),
                    expectedSize: asset.sizeBytes,
                    expectedSha256: asset.sha256
                )
                try validateNativeFontData(
                    cachedPayload.data,
                    path: cachePathDescription(cacheURL)
                )
                validCachedWorkByteCount = cachedPayload.digest.byteCount
            } catch {
                workByteCount = max(
                    workByteCount,
                    measuredFontFailureBytes(
                        error,
                        expectedSize: asset.sizeBytes
                    )
                )
                try? FileManager.default.removeItem(at: cacheURL)
                LogDebug("Removed invalid cached runtime font \(cacheURL.path): \(error)")
            }
            if let validCachedWorkByteCount {
                guard validCachedWorkByteCount <= maximumWorkBytes else {
                    throw MeasuredRuntimeAssetStoreError(
                        underlyingError: FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "external asset acquisition bytes",
                            actual: validCachedWorkByteCount,
                            limit: maximumWorkBytes
                        ),
                        workByteCount: validCachedWorkByteCount
                    )
                }
                return RuntimeAssetAcquisition(
                    url: cacheURL,
                    workByteCount: validCachedWorkByteCount
                )
            }
        }

        guard asset.sizeBytes <= maximumWorkBytes - workByteCount else {
            throw MeasuredRuntimeAssetStoreError(
                underlyingError: FlowRuntimeImportValidationError.valueExceedsLimit(
                    field: "external asset acquisition bytes",
                    actual: workByteCount + asset.sizeBytes,
                    limit: maximumWorkBytes
                ),
                workByteCount: workByteCount
            )
        }

        guard let assetURL = URL(string: asset.assetUrl) else {
            throw MeasuredRuntimeAssetStoreError(
                underlyingError: RuntimeAssetStoreError.invalidAssetURL(asset.assetUrl),
                workByteCount: workByteCount
            )
        }

        let workBeforeDownload = workByteCount
        do {
            let payload = try await downloadFontFile(
                from: assetURL,
                path: "font:\(asset.riveUniqueName)",
                expectedSize: asset.sizeBytes
            )
            workByteCount += payload.digest.byteCount
            try verify(
                payload.digest,
                path: asset.assetUrl,
                expectedSize: asset.sizeBytes,
                expectedSha256: asset.sha256
            )
            try validateNativeFontData(payload.data, path: asset.assetUrl)
            try write(payload.data, to: cacheURL)
            return RuntimeAssetAcquisition(
                url: cacheURL,
                workByteCount: workByteCount
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MeasuredRuntimeAssetStoreError {
            throw MeasuredRuntimeAssetStoreError(
                underlyingError: error.underlyingError,
                workByteCount: workByteCount + error.workByteCount
            )
        } catch {
            let measuredBytes = measuredFontFailureBytes(
                error,
                expectedSize: asset.sizeBytes
            )
            throw MeasuredRuntimeAssetStoreError(
                underlyingError: error,
                workByteCount: max(
                    workByteCount,
                    workBeforeDownload + measuredBytes
                )
            )
        }
    }

    func imageCacheURL(for asset: FlowArtifactImageAsset) throws -> URL {
        let hash = try Self.normalizedSHA256(asset.sha256)
        let ext = Self.cacheExtension(
            pathExtension: URL(fileURLWithPath: asset.path).pathExtension,
            contentType: asset.contentType,
            fallback: "img"
        )
        return cacheDirectory
            .appendingPathComponent("images")
            .appendingPathComponent("\(hash).\(ext)")
    }

    func fontCacheURL(for asset: FlowArtifactFontAsset) throws -> URL {
        let hash = try Self.normalizedSHA256(asset.sha256)
        let format = try Self.normalizedFontFormat(asset.format)
        return cacheDirectory
            .appendingPathComponent("fonts")
            .appendingPathComponent("\(hash).\(format)")
    }

    /// Remove every cached runtime asset. Called from FlowService.clearCache
    /// so fonts/images no longer accrue until an OS cache purge — the store
    /// was previously excluded from every clear path.
    func clearAll() async {
        let directoryURL = cacheDirectory
        do {
            try await CacheFilesystemLock.withExclusiveRootTransaction(
                scope: lockScope
            ) {
                do {
                    try FileManager.default.removeItem(at: directoryURL)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    // A previously cleared cache is already in the desired state.
                }
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
            }
            LogInfo("Cleared all cached runtime assets")
        } catch is CancellationError {
            LogDebug("Cancelled clearing runtime asset cache")
        } catch {
            LogError("Failed to clear runtime asset cache: \(error)")
        }
    }

    private func downloadFontFile(
        from url: URL,
        path: String,
        expectedSize: Int
    ) async throws -> (data: Data, digest: BoundedFileDigest) {
        if url.isFileURL {
            return try readFontFile(
                at: url,
                path: path,
                expectedSize: expectedSize
            )
        }

        let download: BoundedHTTPDownload
        do {
            download = try await BoundedHTTPAcquisition.download(
                from: url,
                using: urlSession,
                maximumBytes: expectedSize
            )
        } catch let error as BoundedHTTPAcquisitionError {
            switch error {
            case .httpStatus(let statusCode):
                LogError("Failed to download runtime asset \(path): HTTP \(statusCode) (\(url))")
                throw MeasuredRuntimeAssetStoreError(
                    underlyingError: RuntimeAssetStoreError.downloadFailed(path),
                    workByteCount: 0
                )
            case .declaredValueExceedsLimit(let actual, _):
                throw MeasuredRuntimeAssetStoreError(
                    underlyingError: RuntimeAssetStoreError.fileSizeMismatch(
                        path: path,
                        expected: expectedSize,
                        actual: actual
                    ),
                    workByteCount: 0
                )
            case .valueExceedsLimit(let actual, _):
                throw MeasuredRuntimeAssetStoreError(
                    underlyingError: RuntimeAssetStoreError.fileSizeMismatch(
                        path: path,
                        expected: expectedSize,
                        actual: actual
                    ),
                    workByteCount: actual
                )
            }
        } catch let error as BoundedHTTPTransportError {
            throw MeasuredRuntimeAssetStoreError(
                underlyingError: error.underlyingError,
                workByteCount: error.receivedByteCount
            )
        }
        defer { try? FileManager.default.removeItem(at: download.temporaryURL) }
        return try readFontFile(
            at: download.temporaryURL,
            path: path,
            expectedSize: expectedSize
        )
    }

    private func readFontFile(
        at url: URL,
        path: String,
        expectedSize: Int
    ) throws -> (data: Data, digest: BoundedFileDigest) {
        do {
            return try BoundedFileIO.read(
                at: url,
                maximumBytes: expectedSize
            )
        } catch let error as BoundedFileIOError {
            switch error {
            case .valueExceedsLimit(let actual, _):
                throw RuntimeAssetStoreError.fileSizeMismatch(
                    path: path,
                    expected: expectedSize,
                    actual: actual
                )
            }
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func inspectVerifiedCachedFileIfPresent(
        at url: URL,
        path: String,
        expectedSize: Int?,
        expectedSha256: String
    ) -> (isValid: Bool, workByteCount: Int) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (false, 0)
        }

        var workByteCount = 0
        do {
            let digest = try BoundedFileIO.inspect(
                at: url,
                maximumBytes: expectedSize ?? maximumAssetBytes
            )
            workByteCount = digest.byteCount
            try verify(
                digest,
                path: path,
                expectedSize: expectedSize,
                expectedSha256: expectedSha256
            )
            return (true, workByteCount)
        } catch {
            try? FileManager.default.removeItem(at: url)
            LogDebug("Removed invalid cached runtime asset \(url.path): \(error)")
            return (false, workByteCount)
        }
    }

    private func verify(
        _ digest: BoundedFileDigest,
        path: String,
        expectedSize: Int?,
        expectedSha256: String
    ) throws {
        if let expectedSize, digest.byteCount != expectedSize {
            throw RuntimeAssetStoreError.fileSizeMismatch(
                path: path,
                expected: expectedSize,
                actual: digest.byteCount
            )
        }

        guard digest.sha256.caseInsensitiveCompare(expectedSha256) == .orderedSame else {
            throw RuntimeAssetStoreError.sha256Mismatch(
                path: path,
                expected: expectedSha256,
                actual: digest.sha256
            )
        }
    }

    private func measuredFontFailureBytes(
        _ error: Error,
        expectedSize: Int
    ) -> Int {
        guard let error = error as? RuntimeAssetStoreError else {
            return 0
        }
        switch error {
        case .sha256Mismatch, .invalidFontData:
            return expectedSize
        case .fileSizeMismatch(_, _, let actual) where actual < expectedSize:
            return max(actual, 0)
        case .invalidContentHash,
             .invalidAssetURL,
             .unsupportedContentType,
             .unsupportedFontFormat,
             .missingSourceAsset,
             .missingPreparedAsset,
             .downloadFailed,
             .fileSizeMismatch:
            return 0
        }
    }

    private func measuredImageVerificationBytes(
        _ error: BoundedFileVerificationError,
        expectedSize: Int
    ) -> Int {
        switch error {
        case .sizeMismatch(_, let actual):
            return max(actual, 0)
        case .sha256Mismatch:
            return expectedSize
        }
    }

    private func runtimeAssetError(
        _ error: BoundedFileVerificationError,
        path: String
    ) -> RuntimeAssetStoreError {
        switch error {
        case let .sizeMismatch(expected, actual):
            return .fileSizeMismatch(
                path: path,
                expected: expected,
                actual: actual
            )
        case let .sha256Mismatch(expected, actual):
            return .sha256Mismatch(
                path: path,
                expected: expected,
                actual: actual
            )
        }
    }

    static func validateImageDescriptor(
        _ asset: FlowArtifactImageAsset,
        expectedSize: Int,
        maximumAssetBytes: Int = FlowRuntimeImportLimits.externalAssetTotalBytes
    ) throws {
        guard expectedSize >= 0 else {
            throw RuntimeAssetStoreError.fileSizeMismatch(
                path: asset.path,
                expected: 0,
                actual: expectedSize
            )
        }
        try FlowRuntimeImportRequest.requireAtMost(
            expectedSize,
            maximumAssetBytes,
            field: "external asset bytes"
        )
        _ = try normalizedSHA256(asset.sha256)
        try validateImageContentType(asset.contentType)
    }

    private static func validateImageContentType(_ contentType: String) throws {
        guard contentType.lowercased().hasPrefix("image/") else {
            throw RuntimeAssetStoreError.unsupportedContentType(
                kind: "image",
                contentType: contentType
            )
        }
    }

    static func validateFontDescriptor(
        _ asset: FlowArtifactFontAsset,
        maximumAssetBytes: Int = FlowRuntimeImportLimits.externalAssetTotalBytes
    ) throws {
        guard asset.sizeBytes >= 0 else {
            throw RuntimeAssetStoreError.fileSizeMismatch(
                path: asset.assetUrl,
                expected: 0,
                actual: asset.sizeBytes
            )
        }
        try FlowRuntimeImportRequest.requireAtMost(
            asset.sizeBytes,
            maximumAssetBytes,
            field: "external asset bytes"
        )
        _ = try normalizedSHA256(asset.sha256)
        _ = try normalizedFontFormat(asset.format)
        let contentType = asset.contentType.lowercased()
        let allowedContentTypes: Set<String> = [
            "application/font-sfnt",
            "application/octet-stream",
            "application/vnd.ms-opentype",
            "application/x-font-opentype",
            "binary/octet-stream",
            "font/opentype",
            "font/otf",
            "font/sfnt",
            "font/ttf",
            "application/x-font-otf",
            "application/x-font-ttf"
        ]
        guard allowedContentTypes.contains(contentType) else {
            throw RuntimeAssetStoreError.unsupportedContentType(
                kind: "font",
                contentType: asset.contentType
            )
        }
    }

    private func validateNativeFontData(_ data: Data, path: String) throws {
        #if canImport(CoreText)
        guard let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider) else {
            throw RuntimeAssetStoreError.invalidFontData(
                path: path,
                reason: "CoreText could not decode a CGFont"
            )
        }

        var registerError: Unmanaged<CFError>?
        if CTFontManagerRegisterGraphicsFont(font, &registerError) {
            var unregisterError: Unmanaged<CFError>?
            _ = CTFontManagerUnregisterGraphicsFont(font, &unregisterError)
            return
        }

        if let error = registerError?.takeRetainedValue() {
            if Self.isDuplicateFontRegistrationError(error) {
                return
            }
            throw RuntimeAssetStoreError.invalidFontData(
                path: path,
                reason: CFErrorCopyDescription(error) as String
            )
        }

        throw RuntimeAssetStoreError.invalidFontData(
            path: path,
            reason: "CoreText registration failed"
        )
        #endif
    }

    private func cachePathDescription(_ url: URL) -> String {
        url.path.replacingOccurrences(of: cacheDirectory.path + "/", with: "")
    }

    #if canImport(CoreText)
    private static func isDuplicateFontRegistrationError(_ error: CFError) -> Bool {
        [105, 305].contains(CFErrorGetCode(error))
    }
    #endif

    private static func normalizedSHA256(_ value: String) throws -> String {
        let lowercased = value.lowercased()
        guard lowercased.count == 64,
              lowercased.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else {
            throw RuntimeAssetStoreError.invalidContentHash(value)
        }
        return lowercased
    }

    private static func normalizedFontFormat(_ value: String) throws -> String {
        let format = value.lowercased()
        guard format == "ttf" || format == "otf" else {
            throw RuntimeAssetStoreError.unsupportedFontFormat(value)
        }
        return format
    }

    private static func cacheExtension(
        pathExtension: String,
        contentType: String,
        fallback: String
    ) -> String {
        let normalized = pathExtension.lowercased()
        if normalized.range(of: #"^[a-z0-9]+$"#, options: .regularExpression) != nil {
            return normalized
        }

        switch contentType.lowercased() {
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/webp":
            return "webp"
        default:
            return fallback
        }
    }
}
