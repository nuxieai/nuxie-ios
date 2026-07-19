import Foundation
import CryptoKit

enum FlowArtifactStoreError: LocalizedError {
    case invalidBaseURL(String)
    case unsafePath(String)
    case missingManifest
    case missingRivFile(String)
    case downloadFailed(String)
    case fileSizeMismatch(path: String, expected: Int, actual: Int)
    case sha256Mismatch(path: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            return "Invalid flow artifact URL: \(value)"
        case .unsafePath(let path):
            return "Unsafe flow artifact path: \(path)"
        case .missingManifest:
            return "Flow artifact manifest is missing"
        case .missingRivFile(let path):
            return "Flow artifact RIV file is missing: \(path)"
        case .downloadFailed(let path):
            return "Failed to download flow artifact file: \(path)"
        case let .fileSizeMismatch(path, expected, actual):
            return "Flow artifact file size mismatch for \(path): expected \(expected), got \(actual)"
        case let .sha256Mismatch(path, expected, actual):
            return "Flow artifact SHA-256 mismatch for \(path): expected \(expected), got \(actual)"
        }
    }
}

enum FlowArtifactSource: String {
    case cachedArtifact = "cached_artifact"
    case downloadedArtifact = "downloaded_artifact"
    case unavailable = "unavailable"
    case unknown = "unknown"
}

struct LoadedFlowArtifact {
    let flow: Flow
    let directoryURL: URL
    let rivURL: URL
    let manifestURL: URL
    let manifest: FlowArtifactManifest
    let assetURLsByRiveUniqueName: [String: URL]
    let source: FlowArtifactSource
    /// Exact artifact-level evidence retained for independent Rust validation.
    let authorizationEvidence: FlowRuntimeAuthorizationEvidence

    /// Transitional gate for the Rive-backed reference path only.
    ///
    /// Native import receives `authorizationEvidence` and never this Boolean.
    var scriptsEnabled: Bool {
        FlowManifestSignatureVerifier.verify(evidence: authorizationEvidence)
    }

    func localImageURL(for asset: FlowArtifactImageAsset) throws -> URL {
        try preparedAssetURL(forRiveUniqueName: asset.riveUniqueName)
    }

    func localFontURL(for asset: FlowArtifactFontAsset) throws -> URL {
        try preparedAssetURL(forRiveUniqueName: asset.riveUniqueName)
    }

    func localAssetURL(forRiveUniqueName uniqueName: String) -> URL? {
        assetURLsByRiveUniqueName[uniqueName]
    }

    private func preparedAssetURL(forRiveUniqueName uniqueName: String) throws -> URL {
        guard let url = assetURLsByRiveUniqueName[uniqueName] else {
            throw RuntimeAssetStoreError.missingPreparedAsset(uniqueName)
        }
        return url
    }
}

struct FlowArtifactManifest: Codable, Equatable {
    let version: Int
    let flowId: String
    let buildId: String
    let renderer: String
    let riv: FlowArtifactRivFile
    let entry: FlowArtifactScreen
    let screens: [FlowArtifactScreen]
    let assets: FlowArtifactAssets
    let textInputs: [FlowArtifactTextInput]

    private enum CodingKeys: String, CodingKey {
        case version
        case flowId
        case buildId
        case renderer
        case riv
        case entry
        case screens
        case assets
        case textInputs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        flowId = try container.decode(String.self, forKey: .flowId)
        buildId = try container.decode(String.self, forKey: .buildId)
        renderer = try container.decode(String.self, forKey: .renderer)
        riv = try container.decode(FlowArtifactRivFile.self, forKey: .riv)
        entry = try container.decode(FlowArtifactScreen.self, forKey: .entry)
        screens = try container.decode([FlowArtifactScreen].self, forKey: .screens)
        assets = try container.decodeIfPresent(FlowArtifactAssets.self, forKey: .assets) ?? FlowArtifactAssets()
        textInputs = try container.decodeIfPresent([FlowArtifactTextInput].self, forKey: .textInputs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(flowId, forKey: .flowId)
        try container.encode(buildId, forKey: .buildId)
        try container.encode(renderer, forKey: .renderer)
        try container.encode(riv, forKey: .riv)
        try container.encode(entry, forKey: .entry)
        try container.encode(screens, forKey: .screens)
        try container.encode(assets, forKey: .assets)
        try container.encode(textInputs, forKey: .textInputs)
    }
}

struct FlowArtifactScreen: Codable, Equatable {
    let screenId: String
    let artboardId: String
    let artboardName: String
    let width: Double
    let height: Double
}

struct FlowArtifactRivFile: Codable, Equatable {
    let path: String
    let sha256: String
    let sizeBytes: Int
}

struct FlowArtifactAssetIdentity: Codable, Equatable {
    let riveAssetId: Int
    let riveUniqueName: String
}

struct FlowArtifactImageAsset: Codable, Equatable {
    let riveAssetId: Int
    let riveUniqueName: String
    let sourceAssetKey: String
    let path: String
    let sha256: String
    let contentType: String
    let width: Int
    let height: Int
    let required: Bool
}

struct FlowArtifactFontAsset: Codable, Equatable {
    let riveAssetId: Int
    let riveUniqueName: String
    let requestKey: String
    let family: String
    let weight: String
    let style: String
    let assetUrl: String
    let sha256: String
    let sizeBytes: Int
    let contentType: String
    let format: String
    let required: Bool
}

struct FlowArtifactTextInput: Codable, Equatable {
    let inputId: String
    let screenId: String
    let artboardId: String
    let viewNodeId: String
    let renderedNodeId: String
    let riveTextObjectKey: String
    let riveTextRunObjectKey: String
    let riveTextName: String
    let riveTextRunName: String
    let geometry: FlowArtifactTextInputGeometry
    let style: FlowArtifactTextInputStyle
    let value: String
    let placeholder: String?
    let editable: Bool
    let keyboardType: String?
    let secureTextEntry: Bool?
    let multiline: Bool?
    let maxLength: Int?
    /// Response field the typed value maps to, resolved at publish from the
    /// input's onChangeText binding. Absent when the input has no response
    /// binding — typed text then stays display-only.
    let responseFieldKey: String?
}

struct FlowArtifactTextInputGeometry: Codable, Equatable {
    let xPath: String
    let yPath: String
    let widthPath: String
    let heightPath: String
    let rotationPath: String
    let scaleXPath: String
    let scaleYPath: String
}

struct FlowArtifactTextInputStyle: Codable, Equatable {
    let fontFamily: String
    let fontWeight: String
    let fontStyle: String
    let fontSize: Double
    let lineHeight: Double
    let letterSpacing: Double
    let color: UInt32
    let fontAssetRiveUniqueName: String
    let textAlign: String?
}

struct FlowArtifactAssets: Codable, Equatable {
    let images: [FlowArtifactImageAsset]
    let fonts: [FlowArtifactFontAsset]

    init(images: [FlowArtifactImageAsset] = [], fonts: [FlowArtifactFontAsset] = []) {
        self.images = images
        self.fonts = fonts
    }
}

actor FlowArtifactStore {
    static let manifestPath = "nuxie-manifest.json"
    static let manifestSignaturePath = FlowManifestSignatureVerifier.signaturePath

    private let cacheDirectory: URL
    private let urlSession: URLSession
    private let runtimeAssetStore: RuntimeAssetStore
    private let scriptTrustStore: FlowScriptTrustStore
    private var activeDownloads: [String: Task<LoadedFlowArtifact, Error>] = [:]

    init(
        urlSession: URLSession = .shared,
        cacheDirectory: URL? = nil,
        runtimeAssetStore: RuntimeAssetStore = RuntimeAssetStore(),
        scriptTrustStore: FlowScriptTrustStore = .production
    ) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = cacheDirectory ?? caches.appendingPathComponent("nuxie_flow_artifacts")
        self.urlSession = urlSession
        self.runtimeAssetStore = runtimeAssetStore
        self.scriptTrustStore = scriptTrustStore
        try? FileManager.default.createDirectory(
            at: self.cacheDirectory,
            withIntermediateDirectories: true
        )
        LogDebug("FlowArtifactStore initialized at: \(self.cacheDirectory.path)")
    }

    func preloadArtifact(for flow: Flow) async {
        do {
            _ = try await getOrDownloadArtifact(for: flow)
        } catch {
            LogError("Failed to preload flow artifact \(flow.id): \(error)")
        }
    }

    func getCachedArtifact(for flow: Flow) async throws -> LoadedFlowArtifact? {
        let directoryURL = canonicalDirectoryURL(for: flow)
        let manifestURL = directoryURL.appendingPathComponent(Self.manifestPath)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let (manifest, manifestData) = try decodeManifest(at: manifestURL)
        let rivURL = try verifyManifestFiles(manifest, directoryURL: directoryURL)
        let assetURLs = try await prepareRuntimeAssetURLs(
            manifest,
            directoryURL: directoryURL
        )

        return LoadedFlowArtifact(
            flow: flow,
            directoryURL: directoryURL,
            rivURL: rivURL,
            manifestURL: manifestURL,
            manifest: manifest,
            assetURLsByRiveUniqueName: assetURLs,
            source: .cachedArtifact,
            authorizationEvidence: authorizationEvidence(
                manifestData: manifestData,
                directoryURL: directoryURL
            )
        )
    }

    func getOrDownloadArtifact(for flow: Flow) async throws -> LoadedFlowArtifact {
        do {
            if let cached = try await getCachedArtifact(for: flow) {
                return cached
            }
        } catch {
            try? FileManager.default.removeItem(at: canonicalDirectoryURL(for: flow))
            LogDebug("Discarded invalid cached flow artifact for \(flow.id): \(error)")
        }

        let key = artifactCacheKey(for: flow)
        if let activeDownload = activeDownloads[key] {
            return try await activeDownload.value
        }

        let task = Task<LoadedFlowArtifact, Error> {
            try await downloadArtifact(for: flow)
        }
        activeDownloads[key] = task
        defer { activeDownloads[key] = nil }
        return try await task.value
    }

    func removeArtifact(for flowId: String) {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: nil
            )
            for url in contents where url.lastPathComponent.hasPrefix("\(flowId)_") {
                try? FileManager.default.removeItem(at: url)
                LogDebug("Removed flow artifact cache for flow \(flowId)")
            }
        } catch {
            LogError("Failed to remove flow artifact cache for flow \(flowId): \(error)")
        }
    }

    func clearAllArtifacts() {
        do {
            try FileManager.default.removeItem(at: cacheDirectory)
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            LogInfo("Cleared all cached flow artifacts")
        } catch {
            LogError("Failed to clear flow artifacts: \(error)")
        }
    }

    private func downloadArtifact(for flow: Flow) async throws -> LoadedFlowArtifact {
        let artifact = flow.remoteFlow.flowArtifact
        guard let baseURL = URL(string: artifact.url) else {
            throw FlowArtifactStoreError.invalidBaseURL(artifact.url)
        }

        let directoryURL = canonicalDirectoryURL(for: flow)
        try? FileManager.default.removeItem(at: directoryURL)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        for file in artifact.manifest.files {
            try await downloadBuildFile(file, baseURL: baseURL, directoryURL: directoryURL)
        }

        let manifestURL = directoryURL.appendingPathComponent(Self.manifestPath)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw FlowArtifactStoreError.missingManifest
        }

        let (manifest, manifestData) = try decodeManifest(at: manifestURL)
        let rivURL = try verifyManifestFiles(manifest, directoryURL: directoryURL)
        let assetURLs = try await prepareRuntimeAssetURLs(
            manifest,
            directoryURL: directoryURL
        )

        return LoadedFlowArtifact(
            flow: flow,
            directoryURL: directoryURL,
            rivURL: rivURL,
            manifestURL: manifestURL,
            manifest: manifest,
            assetURLsByRiveUniqueName: assetURLs,
            source: .downloadedArtifact,
            authorizationEvidence: authorizationEvidence(
                manifestData: manifestData,
                directoryURL: directoryURL
            )
        )
    }

    private func authorizationEvidence(
        manifestData: Data,
        directoryURL: URL
    ) -> FlowRuntimeAuthorizationEvidence {
        let signatureURL = directoryURL.appendingPathComponent(
            Self.manifestSignaturePath
        )
        let signatureData: Data?
        if FileManager.default.fileExists(atPath: signatureURL.path) {
            do {
                signatureData = try boundedSignatureEvidence(at: signatureURL)
            } catch {
                LogWarning("Flow manifest signature file could not be read: \(error)")
                signatureData = nil
            }
        } else {
            signatureData = nil
        }

        return scriptTrustStore.evidence(
            signedContentBytes: manifestData,
            signatureEnvelopeBytes: signatureData
        )
    }

    private func boundedSignatureEvidence(at url: URL) throws -> Data {
        let limit = FlowRuntimeImportLimits.signatureEnvelopeBytes
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard fileSize <= UInt64(limit) else {
            LogWarning("Flow manifest signature exceeds the runtime evidence limit")
            return Data()
        }

        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            LogWarning("Flow manifest signature grew beyond the runtime evidence limit")
            return Data()
        }
        return data
    }

    private func downloadBuildFile(
        _ file: BuildFile,
        baseURL: URL,
        directoryURL: URL
    ) async throws {
        let relativePath = try Self.validateRelativePath(file.path)
        let fileURL = baseURL.appendingPathComponent(relativePath)
        let localURL = directoryURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try await downloadData(from: fileURL, path: relativePath)
        if data.count != file.size {
            throw FlowArtifactStoreError.fileSizeMismatch(
                path: relativePath,
                expected: file.size,
                actual: data.count
            )
        }
        try data.write(to: localURL)
    }

    private func downloadData(from url: URL, path: String) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url)
        }

        let (data, response) = try await urlSession.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            LogError("Failed to download \(path): HTTP \(httpResponse.statusCode) (\(url))")
            throw FlowArtifactStoreError.downloadFailed(path)
        }
        return data
    }

    private func decodeManifest(at url: URL) throws -> (FlowArtifactManifest, Data) {
        let data = try Data(contentsOf: url)
        return (try JSONDecoder().decode(FlowArtifactManifest.self, from: data), data)
    }

    private func prepareRuntimeAssetURLs(
        _ manifest: FlowArtifactManifest,
        directoryURL: URL
    ) async throws -> [String: URL] {
        var urlsByRiveUniqueName: [String: URL] = [:]

        for image in manifest.assets.images {
            do {
                urlsByRiveUniqueName[image.riveUniqueName] = try await runtimeAssetStore.cachedImageURL(
                    for: image,
                    artifactDirectoryURL: directoryURL
                )
            } catch {
                if image.required {
                    throw error
                }
                LogDebug("Skipped optional image asset \(image.riveUniqueName): \(error)")
            }
        }

        for font in manifest.assets.fonts {
            do {
                urlsByRiveUniqueName[font.riveUniqueName] = try await runtimeAssetStore.cachedFontURL(for: font)
            } catch {
                if font.required {
                    throw error
                }
                LogDebug("Skipped optional font asset \(font.riveUniqueName): \(error)")
            }
        }

        return urlsByRiveUniqueName
    }

    private func verifyManifestFiles(
        _ manifest: FlowArtifactManifest,
        directoryURL: URL
    ) throws -> URL {
        let rivURL = try localURL(forRelativePath: manifest.riv.path, in: directoryURL)
        guard FileManager.default.fileExists(atPath: rivURL.path) else {
            throw FlowArtifactStoreError.missingRivFile(manifest.riv.path)
        }

        try verifyFile(
            at: rivURL,
            path: manifest.riv.path,
            expectedSize: manifest.riv.sizeBytes,
            expectedSha256: manifest.riv.sha256
        )

        return rivURL
    }

    private func verifyFile(
        at url: URL,
        path: String,
        expectedSize: Int?,
        expectedSha256: String
    ) throws {
        let data = try Data(contentsOf: url)
        if let expectedSize, data.count != expectedSize {
            throw FlowArtifactStoreError.fileSizeMismatch(
                path: path,
                expected: expectedSize,
                actual: data.count
            )
        }
        let actualSha = Self.sha256Hex(data)
        guard actualSha.caseInsensitiveCompare(expectedSha256) == .orderedSame else {
            throw FlowArtifactStoreError.sha256Mismatch(
                path: path,
                expected: expectedSha256,
                actual: actualSha
            )
        }
    }

    private func localURL(forRelativePath relativePath: String, in directoryURL: URL) throws -> URL {
        let path = try Self.validateRelativePath(relativePath)
        return directoryURL.appendingPathComponent(path)
    }

    private func canonicalDirectoryURL(for flow: Flow) -> URL {
        let key = artifactCacheKey(for: flow)
        return cacheDirectory.appendingPathComponent(key)
    }

    private func artifactCacheKey(for flow: Flow) -> String {
        let artifact = flow.remoteFlow.flowArtifact
        let raw = "\(flow.id)_\(artifact.buildId)_\(artifact.manifest.contentHash)"
        return raw.map { char in
            char.isLetter || char.isNumber || char == "_" || char == "-" ? char : "_"
        }.reduce(into: "") { $0.append($1) }
    }

    static func validateRelativePath(_ path: String) throws -> String {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\") else {
            throw FlowArtifactStoreError.unsafePath(path)
        }
        for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
            if segment.isEmpty || segment == "." || segment == ".." {
                throw FlowArtifactStoreError.unsafePath(path)
            }
        }
        return path
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
