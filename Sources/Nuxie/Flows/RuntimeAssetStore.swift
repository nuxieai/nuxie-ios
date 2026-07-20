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
            return "Runtime asset was not prepared for Rive asset: \(uniqueName)"
        case .downloadFailed(let path):
            return "Failed to download runtime asset: \(path)"
        case let .fileSizeMismatch(path, expected, actual):
            return "Runtime asset size mismatch for \(path): expected \(expected), got \(actual)"
        case let .sha256Mismatch(path, expected, actual):
            return "Runtime asset SHA-256 mismatch for \(path): expected \(expected), got \(actual)"
        }
    }
}

actor RuntimeAssetStore {
    private let cacheDirectory: URL
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared, cacheDirectory: URL? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = cacheDirectory ?? caches.appendingPathComponent("nuxie_runtime_assets")
        self.urlSession = urlSession
        try? FileManager.default.createDirectory(
            at: self.cacheDirectory,
            withIntermediateDirectories: true
        )
        LogDebug("RuntimeAssetStore initialized at: \(self.cacheDirectory.path)")
    }

    func cachedImageURL(
        for asset: FlowArtifactImageAsset,
        artifactDirectoryURL: URL
    ) async throws -> URL {
        try validateImageContentType(asset.contentType)
        let cacheURL = try imageCacheURL(for: asset)
        if try useVerifiedCachedFileIfPresent(
            at: cacheURL,
            path: cachePathDescription(cacheURL),
            expectedSize: nil,
            expectedSha256: asset.sha256
        ) {
            return cacheURL
        }

        let sourcePath = try FlowArtifactStore.validateRelativePath(asset.path)
        let sourceURL = artifactDirectoryURL.appendingPathComponent(sourcePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw RuntimeAssetStoreError.missingSourceAsset(sourcePath)
        }

        let data = try Data(contentsOf: sourceURL)
        try verify(
            data,
            path: sourcePath,
            expectedSize: nil,
            expectedSha256: asset.sha256
        )
        try write(data, to: cacheURL)
        return cacheURL
    }

    func cachedFontURL(for asset: FlowArtifactFontAsset) async throws -> URL {
        try validateFont(asset)
        let cacheURL = try fontCacheURL(for: asset)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            do {
                let cachedData = try Data(contentsOf: cacheURL)
                try verify(
                    cachedData,
                    path: cachePathDescription(cacheURL),
                    expectedSize: asset.sizeBytes,
                    expectedSha256: asset.sha256
                )
                try validateNativeFontData(cachedData, path: cachePathDescription(cacheURL))
                return cacheURL
            } catch {
                try? FileManager.default.removeItem(at: cacheURL)
                LogDebug("Removed invalid cached runtime font \(cacheURL.path): \(error)")
            }
        }

        guard let assetURL = URL(string: asset.assetUrl) else {
            throw RuntimeAssetStoreError.invalidAssetURL(asset.assetUrl)
        }

        let data = try await downloadData(
            from: assetURL,
            path: "font:\(asset.riveUniqueName)"
        )
        try verify(
            data,
            path: asset.assetUrl,
            expectedSize: asset.sizeBytes,
            expectedSha256: asset.sha256
        )
        try validateNativeFontData(data, path: asset.assetUrl)
        try write(data, to: cacheURL)
        return cacheURL
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
    func clearAll() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    private func downloadData(from url: URL, path: String) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url)
        }

        let (data, response) = try await urlSession.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            LogError("Failed to download runtime asset \(path): HTTP \(httpResponse.statusCode) (\(url))")
            throw RuntimeAssetStoreError.downloadFailed(path)
        }
        return data
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func useVerifiedCachedFileIfPresent(
        at url: URL,
        path: String,
        expectedSize: Int?,
        expectedSha256: String
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }

        do {
            let data = try Data(contentsOf: url)
            try verify(
                data,
                path: path,
                expectedSize: expectedSize,
                expectedSha256: expectedSha256
            )
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
            LogDebug("Removed invalid cached runtime asset \(url.path): \(error)")
            return false
        }
    }

    private func verify(
        _ data: Data,
        path: String,
        expectedSize: Int?,
        expectedSha256: String
    ) throws {
        if let expectedSize, data.count != expectedSize {
            throw RuntimeAssetStoreError.fileSizeMismatch(
                path: path,
                expected: expectedSize,
                actual: data.count
            )
        }

        let actualSha = FlowArtifactStore.sha256Hex(data)
        guard actualSha.caseInsensitiveCompare(expectedSha256) == .orderedSame else {
            throw RuntimeAssetStoreError.sha256Mismatch(
                path: path,
                expected: expectedSha256,
                actual: actualSha
            )
        }
    }

    private func validateImageContentType(_ contentType: String) throws {
        guard contentType.lowercased().hasPrefix("image/") else {
            throw RuntimeAssetStoreError.unsupportedContentType(
                kind: "image",
                contentType: contentType
            )
        }
    }

    private func validateFont(_ asset: FlowArtifactFontAsset) throws {
        _ = try Self.normalizedFontFormat(asset.format)
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
