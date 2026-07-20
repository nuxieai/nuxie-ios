import Foundation
import CryptoKit

enum FlowArtifactStoreError: LocalizedError {
    case invalidBaseURL(String)
    case unsafePath(String)
    case missingManifest
    case missingRivFile(String)
    case downloadFailed(String)
    case buildManifestFileCountMismatch(declared: Int, actual: Int)
    case buildManifestTotalSizeMismatch(declared: Int, actual: Int)
    case duplicateBuildFilePath(String)
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
        case let .buildManifestFileCountMismatch(declared, actual):
            return "Build manifest file count mismatch: declared \(declared), got \(actual)"
        case let .buildManifestTotalSizeMismatch(declared, actual):
            return "Build manifest total size mismatch: declared \(declared), got \(actual)"
        case .duplicateBuildFilePath(let path):
            return "Build manifest contains a duplicate path: \(path)"
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

private struct FlowArtifactAssetAcquisitionPlan {
    var omittedOptionalUniqueNames: Set<String>
    let imagePathsToDownload: Set<String>
    let requiredImagePaths: Set<String>
    let optionalImageNamesByPath: [String: Set<String>]
    let imageSizesByPath: [String: Int]
    let imageDescriptorsByPath: [String: [FlowArtifactImageAsset]]
}

private struct PreparedRuntimeAsset {
    let url: URL
    let byteCount: Int
}

enum FlowArtifactAcquisitionIdentity {
    static func imageAttempt(descriptorIndex: Int, path: String) -> String {
        "image-descriptor:\(descriptorIndex):\(path)"
    }
}

/// Tracks the logical external-asset envelope independently from filesystem
/// implementation passes. Accepted bytes follow the native request and are
/// charged per descriptor. Work is charged per acquisition attempt until exact
/// content has been verified; only then may later descriptors reuse that
/// content without another attempt. Missing files, HTTP errors, and header-only
/// rejections contribute zero bytes while payload failures remain chargeable.
struct FlowArtifactAcquisitionBudget {
    let acceptedByteLimit: Int
    let workByteLimit: Int
    private(set) var acceptedBytes = 0
    private(set) var workBytes = 0
    private var workBytesByAttempt: [String: Int] = [:]
    private var acceptedIdentities = Set<String>()

    init(
        acceptedByteLimit: Int = FlowRuntimeImportLimits.externalAssetTotalBytes
    ) throws {
        precondition(acceptedByteLimit >= 0)
        self.acceptedByteLimit = acceptedByteLimit
        let (workByteLimit, overflowed) = acceptedByteLimit
            .addingReportingOverflow(acceptedByteLimit)
        guard !overflowed else {
            throw FlowRuntimeImportValidationError.byteCountOverflow(
                field: "external asset acquisition byte limit"
            )
        }
        self.workByteLimit = workByteLimit
    }

    var remainingAcceptedBytes: Int {
        acceptedByteLimit - acceptedBytes
    }

    var remainingWorkBytes: Int {
        workByteLimit - workBytes
    }

    func permitsAccepted(byteCount: Int) -> Bool {
        byteCount >= 0 && byteCount <= remainingAcceptedBytes
    }

    func permitsWork(identity: String, totalByteCount: Int) -> Bool {
        guard totalByteCount >= 0 else { return false }
        let existingWorkBytes = workBytesByAttempt[identity] ?? 0
        let additionalWorkBytes = max(totalByteCount - existingWorkBytes, 0)
        return additionalWorkBytes <= remainingWorkBytes
    }

    /// The largest total byte count a measured attempt may report without
    /// exceeding the aggregate work envelope. An attempt that has already
    /// consumed bytes can safely report that prefix again because
    /// `recordWork` only charges its increase.
    func workAllowance(for identity: String) -> Int {
        (workBytesByAttempt[identity] ?? 0) + remainingWorkBytes
    }

    func permitsAttempt(identity: String, expectedBytes: Int) -> Bool {
        permitsAccepted(byteCount: expectedBytes)
            && permitsWork(identity: identity, totalByteCount: expectedBytes)
    }

    mutating func recordWork(identity: String, byteCount: Int) throws {
        let existingBytes = workBytesByAttempt[identity] ?? 0
        guard byteCount >= 0 else {
            throw FlowRuntimeImportValidationError.valueExceedsLimit(
                field: "external asset acquisition bytes",
                actual: byteCount,
                limit: workByteLimit
            )
        }
        guard byteCount >= existingBytes else { return }
        let additionalBytes = byteCount - existingBytes
        let (nextBytes, overflowed) = workBytes.addingReportingOverflow(additionalBytes)
        guard !overflowed, nextBytes <= workByteLimit else {
            throw FlowRuntimeImportValidationError.valueExceedsLimit(
                field: "external asset acquisition bytes",
                actual: overflowed ? Int.max : nextBytes,
                limit: workByteLimit
            )
        }
        workBytesByAttempt[identity] = byteCount
        workBytes = nextBytes
    }

    func hasRecordedWork(for identity: String) -> Bool {
        workBytesByAttempt[identity] != nil
    }

    func recordedWorkBytes(for identity: String) -> Int {
        workBytesByAttempt[identity] ?? 0
    }

    mutating func recordAccepted(identity: String, byteCount: Int) throws {
        guard !acceptedIdentities.contains(identity) else { return }
        let (nextBytes, overflowed) = acceptedBytes.addingReportingOverflow(byteCount)
        guard byteCount >= 0, !overflowed, nextBytes <= acceptedByteLimit else {
            throw FlowRuntimeImportValidationError.valueExceedsLimit(
                field: "aggregate external asset bytes",
                actual: overflowed ? Int.max : nextBytes,
                limit: acceptedByteLimit
            )
        }
        acceptedIdentities.insert(identity)
        acceptedBytes = nextBytes
    }
}

private struct ActiveFlowArtifactDownload {
    let id: UUID
    let flowId: String
    let task: Task<LoadedFlowArtifact, Error>
}

private struct MeasuredFlowArtifactAcquisitionError: Error {
    let underlyingError: Error
    let workByteCount: Int
}

private struct MeasuredFlowArtifactDownload {
    let digest: BoundedFileDigest
    let workByteCount: Int
}

actor FlowArtifactStore {
    static let manifestPath = "nuxie-manifest.json"
    static let manifestSignaturePath = FlowManifestSignatureVerifier.signaturePath

    /// One entry per native external asset, plus the manifest, RIV, and signature.
    static let maximumBuildFileCount = FlowRuntimeImportLimits.externalAssetCount + 3
    /// The complete declared acquisition envelope: RIV, manifest, signature, and external assets.
    static let maximumBuildDeclaredBytes = FlowRuntimeImportLimits.artifactBytes
        + FlowRuntimeImportLimits.manifestBytes
        + FlowRuntimeImportLimits.signatureEnvelopeBytes
        + FlowRuntimeImportLimits.externalAssetTotalBytes

    private let cacheDirectory: URL
    private let lockScope: CacheFilesystemLockScope
    private let urlSession: URLSession
    private let runtimeAssetStore: RuntimeAssetStore
    private let scriptTrustPolicy: FlowScriptTrustPolicy
    private var activeDownloads: [String: ActiveFlowArtifactDownload] = [:]

    init(
        urlSession: URLSession = .shared,
        cacheDirectory: URL? = nil,
        runtimeAssetStore: RuntimeAssetStore = RuntimeAssetStore(),
        scriptTrustPolicy: FlowScriptTrustPolicy = .production
    ) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let resolvedCacheDirectory = cacheDirectory
            ?? caches.appendingPathComponent("nuxie_flow_artifacts")
        try? FileManager.default.createDirectory(
            at: resolvedCacheDirectory,
            withIntermediateDirectories: true
        )
        let canonicalCacheDirectory = resolvedCacheDirectory.standardizedFileURL
            .resolvingSymlinksInPath()
        self.cacheDirectory = canonicalCacheDirectory
        self.lockScope = CacheFilesystemLockScope(cacheRootURL: canonicalCacheDirectory)
        self.urlSession = urlSession
        self.runtimeAssetStore = runtimeAssetStore
        self.scriptTrustPolicy = scriptTrustPolicy
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
        let canonicalURL = canonicalDirectoryURL(for: flow)
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: canonicalURL,
            lockScope: lockScope
        ) { [self] in
            try await getCachedArtifactWithoutCoordination(for: flow)
        }
    }

    private func getCachedArtifactWithoutCoordination(
        for flow: Flow
    ) async throws -> LoadedFlowArtifact? {
        let directoryURL = canonicalDirectoryURL(for: flow)
        let manifestURL = directoryURL.appendingPathComponent(Self.manifestPath)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        try validateBuildManifest(flow.remoteFlow.flowArtifact.manifest)
        let declaredManifestFile = flow.remoteFlow.flowArtifact.manifest.files.first(where: {
            $0.path == Self.manifestPath
        })
        if let declaredManifestFile {
            try validateDeclaredBuildFile(
                declaredManifestFile,
                maximumBytes: FlowRuntimeImportLimits.manifestBytes,
                field: "manifest"
            )
        }
        let (manifest, manifestData) = try decodeManifest(
            at: manifestURL,
            expectedSize: declaredManifestFile?.size
        )
        try validateCachedBuildSidecars(
            flow.remoteFlow.flowArtifact.manifest,
            artifactManifest: manifest,
            directoryURL: directoryURL
        )
        try validateRivDeclarations(
            manifest: manifest,
            buildManifest: flow.remoteFlow.flowArtifact.manifest
        )
        let acquisitionPlan = try makeAssetAcquisitionPlan(
            manifest: manifest,
            buildManifest: flow.remoteFlow.flowArtifact.manifest
        )
        var acquisitionBudget = try FlowArtifactAcquisitionBudget()
        let rivURL = try verifyManifestFiles(manifest, directoryURL: directoryURL)
        let assetURLs = try await prepareRuntimeAssetURLs(
            manifest,
            directoryURL: directoryURL,
            acquisitionPlan: acquisitionPlan,
            acquisitionBudget: &acquisitionBudget
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
        let key = artifactCacheKey(for: flow)
        if let activeDownload = activeDownloads[key] {
            return try await activeDownload.task.value
        }

        let downloadId = UUID()
        let stagingDirectoryURL = cacheDirectory.appendingPathComponent(
            ".\(key).\(downloadId.uuidString).download",
            isDirectory: true
        )
        let task = Task<LoadedFlowArtifact, Error> {
            let canonicalURL = canonicalDirectoryURL(for: flow)
            return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
                to: canonicalURL,
                lockScope: lockScope
            ) { [self] in
                try await loadOrDownloadArtifactWithoutCoordination(
                    for: flow,
                    stagingDirectoryURL: stagingDirectoryURL
                )
            }
        }
        activeDownloads[key] = ActiveFlowArtifactDownload(
            id: downloadId,
            flowId: flow.id,
            task: task
        )
        defer {
            if activeDownloads[key]?.id == downloadId {
                activeDownloads[key] = nil
            }
        }
        return try await task.value
    }

    private func loadOrDownloadArtifactWithoutCoordination(
        for flow: Flow,
        stagingDirectoryURL: URL
    ) async throws -> LoadedFlowArtifact {
        do {
            if let cached = try await getCachedArtifactWithoutCoordination(for: flow) {
                return cached
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: canonicalDirectoryURL(for: flow))
            LogDebug("Discarded invalid cached flow artifact for \(flow.id): \(error)")
        }

        return try await downloadArtifact(
            for: flow,
            stagingDirectoryURL: stagingDirectoryURL
        )
    }

    func removeArtifact(for flowId: String) async {
        cancelActiveDownloads { $0.flowId == flowId }
        let directoryURL = cacheDirectory
        do {
            let removedCount = try await CacheFilesystemLock.withExclusiveRootTransaction(
                scope: lockScope
            ) {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: nil
                )
                var removedCount = 0
                for url in contents where url.lastPathComponent.hasPrefix("\(flowId)_") {
                    do {
                        try FileManager.default.removeItem(at: url)
                        removedCount += 1
                    } catch let error as CocoaError where error.code == .fileNoSuchFile {
                        continue
                    }
                }
                return removedCount
            }
            if removedCount > 0 {
                LogDebug("Removed flow artifact cache for flow \(flowId)")
            }
        } catch is CancellationError {
            LogDebug("Cancelled removal of flow artifact cache for flow \(flowId)")
        } catch {
            LogError("Failed to remove flow artifact cache for flow \(flowId): \(error)")
        }
    }

    func clearAllArtifacts() async {
        cancelActiveDownloads { _ in true }
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
            LogInfo("Cleared all cached flow artifacts")
        } catch is CancellationError {
            LogDebug("Cancelled clearing flow artifact cache")
        } catch {
            LogError("Failed to clear flow artifacts: \(error)")
        }
    }

    private func downloadArtifact(
        for flow: Flow,
        stagingDirectoryURL directoryURL: URL
    ) async throws -> LoadedFlowArtifact {
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try Task.checkCancellation()
        let artifact = flow.remoteFlow.flowArtifact
        try validateBuildManifest(artifact.manifest)
        guard let baseURL = URL(string: artifact.url) else {
            throw FlowArtifactStoreError.invalidBaseURL(artifact.url)
        }

        try? FileManager.default.removeItem(at: directoryURL)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        guard let manifestFile = artifact.manifest.files.first(where: {
            $0.path == Self.manifestPath
        }) else {
            throw FlowArtifactStoreError.missingManifest
        }
        try await downloadBuildFile(
            manifestFile,
            baseURL: baseURL,
            directoryURL: directoryURL,
            maximumBytes: FlowRuntimeImportLimits.manifestBytes,
            field: "manifest"
        )
        try Task.checkCancellation()

        let manifestURL = directoryURL.appendingPathComponent(Self.manifestPath)
        let (manifest, manifestData) = try decodeManifest(
            at: manifestURL,
            expectedSize: manifestFile.size
        )
        try validateRivDeclarations(
            manifest: manifest,
            buildManifest: artifact.manifest
        )
        var acquisitionPlan = try makeAssetAcquisitionPlan(
            manifest: manifest,
            buildManifest: artifact.manifest
        )
        var acquisitionBudget = try FlowArtifactAcquisitionBudget()
        let declaredImagePaths = Set(manifest.assets.images.map(\.path))

        for file in artifact.manifest.files
        where file.path != Self.manifestPath {
            try Task.checkCancellation()
            guard !declaredImagePaths.contains(file.path) else {
                continue
            }
            if file.path == Self.manifestSignaturePath {
                try await downloadSignatureBuildFile(
                    file,
                    baseURL: baseURL,
                    directoryURL: directoryURL
                )
            } else if file.path == manifest.riv.path {
                try await downloadBuildFile(
                    file,
                    baseURL: baseURL,
                    directoryURL: directoryURL,
                    maximumBytes: FlowRuntimeImportLimits.artifactBytes,
                    field: "artifact"
                )
            } else {
                try await downloadBuildFile(
                    file,
                    baseURL: baseURL,
                    directoryURL: directoryURL,
                    maximumBytes: Self.maximumBuildDeclaredBytes,
                    field: "build sidecar \(file.path)"
                )
            }
        }

        var stagedImageURLsByIdentity: [String: URL] = [:]
        for required in [true, false] {
            for file in artifact.manifest.files
            where declaredImagePaths.contains(file.path)
                && acquisitionPlan.requiredImagePaths.contains(file.path) == required {
                try Task.checkCancellation()
                guard acquisitionPlan.imagePathsToDownload.contains(file.path),
                      let descriptors = acquisitionPlan.imageDescriptorsByPath[file.path] else {
                    continue
                }
                let attemptID = "image-file:\(file.path)"
                let optionalNames = acquisitionPlan.optionalImageNamesByPath[file.path] ?? []
                var usableDescriptors: [FlowArtifactImageAsset] = []
                for descriptor in descriptors {
                    do {
                        try RuntimeAssetStore.validateImageDescriptor(
                            descriptor,
                            expectedSize: file.size
                        )
                        usableDescriptors.append(descriptor)
                    } catch {
                        if descriptor.required {
                            throw error
                        }
                        acquisitionPlan.omittedOptionalUniqueNames.insert(
                            descriptor.riveUniqueName
                        )
                    }
                }
                guard !usableDescriptors.isEmpty else { continue }

                let expectedHashes = Set(
                    usableDescriptors.map { $0.sha256.lowercased() }
                )
                if expectedHashes.count == 1,
                   let expectedSHA256 = expectedHashes.first,
                   let stagedURL = stagedImageURLsByIdentity[
                       "image:\(expectedSHA256)"
                   ] {
                    let destinationURL = try localURL(
                        forRelativePath: file.path,
                        in: directoryURL
                    )
                    do {
                        if stagedURL != destinationURL {
                            let digest = try BoundedFileIO.copyVerified(
                                from: stagedURL,
                                to: destinationURL,
                                expectedSize: file.size,
                                expectedSHA256: expectedSHA256,
                                maximumBytes: file.size
                            )
                            try acquisitionBudget.recordWork(
                                identity: attemptID,
                                byteCount: digest.byteCount
                            )
                        }
                        continue
                    } catch {
                        if required {
                            throw error
                        }
                        acquisitionPlan.omittedOptionalUniqueNames.formUnion(optionalNames)
                        LogDebug(
                            "Skipped optional reused image file \(file.path): \(error)"
                        )
                        continue
                    }
                }
                guard acquisitionBudget.permitsWork(
                    identity: attemptID,
                    totalByteCount: file.size
                ) else {
                    if required {
                        throw FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "external asset acquisition bytes",
                            actual: acquisitionBudget.workBytes + file.size,
                            limit: acquisitionBudget.workByteLimit
                        )
                    }
                    acquisitionPlan.omittedOptionalUniqueNames.formUnion(optionalNames)
                    continue
                }

                do {
                    let download = try await downloadBuildFileMeasuringWork(
                        file,
                        baseURL: baseURL,
                        directoryURL: directoryURL,
                        maximumBytes: FlowRuntimeImportLimits.externalAssetTotalBytes,
                        field: "build file \(file.path)"
                    )
                    try acquisitionBudget.recordWork(
                        identity: attemptID,
                        byteCount: download.workByteCount
                    )
                    let matchingDescriptors = usableDescriptors.filter {
                        $0.sha256.caseInsensitiveCompare(download.digest.sha256) == .orderedSame
                    }
                    for descriptor in usableDescriptors where !matchingDescriptors.contains(
                        where: { $0.riveUniqueName == descriptor.riveUniqueName }
                    ) {
                        if descriptor.required {
                            throw FlowArtifactStoreError.sha256Mismatch(
                                path: file.path,
                                expected: descriptor.sha256,
                                actual: download.digest.sha256
                            )
                        }
                        acquisitionPlan.omittedOptionalUniqueNames.insert(
                            descriptor.riveUniqueName
                        )
                    }
                    guard !matchingDescriptors.isEmpty else { continue }
                    stagedImageURLsByIdentity[
                        "image:\(download.digest.sha256.lowercased())"
                    ] = try localURL(
                        forRelativePath: file.path,
                        in: directoryURL
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as MeasuredFlowArtifactAcquisitionError {
                    try acquisitionBudget.recordWork(
                        identity: attemptID,
                        byteCount: error.workByteCount
                    )
                    if required {
                        throw error.underlyingError
                    }
                    acquisitionPlan.omittedOptionalUniqueNames.formUnion(optionalNames)
                    LogDebug(
                        "Skipped optional image file \(file.path): "
                            + "\(error.underlyingError)"
                    )
                } catch {
                    try acquisitionBudget.recordWork(identity: attemptID, byteCount: 0)
                    if required {
                        throw error
                    }
                    acquisitionPlan.omittedOptionalUniqueNames.formUnion(optionalNames)
                    LogDebug("Skipped optional image file \(file.path): \(error)")
                }
            }
        }

        _ = try verifyManifestFiles(manifest, directoryURL: directoryURL)
        let assetURLs = try await prepareRuntimeAssetURLs(
            manifest,
            directoryURL: directoryURL,
            acquisitionPlan: acquisitionPlan,
            acquisitionBudget: &acquisitionBudget
        )

        try Task.checkCancellation()
        let authorizationEvidence = authorizationEvidence(
            manifestData: manifestData,
            directoryURL: directoryURL
        )
        let canonicalDirectoryURL = canonicalDirectoryURL(for: flow)
        if FileManager.default.fileExists(atPath: canonicalDirectoryURL.path),
           let winner = try await getCachedArtifactWithoutCoordination(for: flow) {
            return winner
        }
        do {
            try FileManager.default.moveItem(
                at: directoryURL,
                to: canonicalDirectoryURL
            )
        } catch {
            // A different process may have won after the existence check.
            // Accept it only after running the complete cache verification.
            if let winner = try await getCachedArtifactWithoutCoordination(for: flow) {
                return winner
            }
            throw error
        }
        let canonicalManifestURL = canonicalDirectoryURL.appendingPathComponent(
            Self.manifestPath
        )
        let canonicalRivURL = try localURL(
            forRelativePath: manifest.riv.path,
            in: canonicalDirectoryURL
        )

        return LoadedFlowArtifact(
            flow: flow,
            directoryURL: canonicalDirectoryURL,
            rivURL: canonicalRivURL,
            manifestURL: canonicalManifestURL,
            manifest: manifest,
            assetURLsByRiveUniqueName: assetURLs,
            source: .downloadedArtifact,
            authorizationEvidence: authorizationEvidence
        )
    }

    private func cancelActiveDownloads(
        where predicate: (ActiveFlowArtifactDownload) -> Bool
    ) {
        let keys = activeDownloads.compactMap { key, download in
            predicate(download) ? key : nil
        }
        for key in keys {
            activeDownloads[key]?.task.cancel()
            activeDownloads[key] = nil
        }
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

        return scriptTrustPolicy.evidence(
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
        directoryURL: URL,
        maximumBytes: Int,
        field: String
    ) async throws {
        do {
            _ = try await downloadBuildFileMeasuringWork(
                file,
                baseURL: baseURL,
                directoryURL: directoryURL,
                maximumBytes: maximumBytes,
                field: field
            )
        } catch let error as MeasuredFlowArtifactAcquisitionError {
            throw error.underlyingError
        }
    }

    private func downloadBuildFileMeasuringWork(
        _ file: BuildFile,
        baseURL: URL,
        directoryURL: URL,
        maximumBytes: Int,
        field: String
    ) async throws -> MeasuredFlowArtifactDownload {
        try validateDeclaredBuildFile(
            file,
            maximumBytes: maximumBytes,
            field: field
        )
        let relativePath = try Self.validateRelativePath(file.path)
        let fileURL = baseURL.appendingPathComponent(relativePath)
        let localURL = directoryURL.appendingPathComponent(relativePath)

        let sourceURL: URL
        let removesSourceAfterCopy: Bool
        let downloadedByteCount: Int?
        if fileURL.isFileURL {
            sourceURL = fileURL
            removesSourceAfterCopy = false
            downloadedByteCount = nil
        } else {
            do {
                let download = try await BoundedHTTPAcquisition.download(
                    from: fileURL,
                    using: urlSession,
                    maximumBytes: file.size
                )
                sourceURL = download.temporaryURL
                removesSourceAfterCopy = true
                downloadedByteCount = download.byteCount
            } catch let error as BoundedHTTPAcquisitionError {
                let mappedError: Error
                let workByteCount: Int
                switch error {
                case .httpStatus(let statusCode):
                    LogError("Failed to download \(relativePath): HTTP \(statusCode) (\(fileURL))")
                    mappedError = FlowArtifactStoreError.downloadFailed(relativePath)
                    workByteCount = 0
                case .declaredValueExceedsLimit(let actual, _):
                    mappedError = FlowArtifactStoreError.fileSizeMismatch(
                        path: relativePath,
                        expected: file.size,
                        actual: actual
                    )
                    workByteCount = 0
                case .valueExceedsLimit(let actual, _):
                    mappedError = FlowArtifactStoreError.fileSizeMismatch(
                        path: relativePath,
                        expected: file.size,
                        actual: actual
                    )
                    workByteCount = actual
                }
                throw MeasuredFlowArtifactAcquisitionError(
                    underlyingError: mappedError,
                    workByteCount: workByteCount
                )
            } catch let error as BoundedHTTPTransportError {
                throw MeasuredFlowArtifactAcquisitionError(
                    underlyingError: error.underlyingError,
                    workByteCount: error.receivedByteCount
                )
            }
        }
        defer {
            if removesSourceAfterCopy {
                try? FileManager.default.removeItem(at: sourceURL)
            }
        }

        try Task.checkCancellation()
        do {
            let digest = try BoundedFileIO.copy(
                from: sourceURL,
                to: localURL,
                maximumBytes: file.size
            )
            guard digest.byteCount == file.size else {
                throw MeasuredFlowArtifactAcquisitionError(
                    underlyingError: FlowArtifactStoreError.fileSizeMismatch(
                        path: relativePath,
                        expected: file.size,
                        actual: digest.byteCount
                    ),
                    workByteCount: downloadedByteCount ?? digest.byteCount
                )
            }
            return MeasuredFlowArtifactDownload(
                digest: digest,
                workByteCount: downloadedByteCount ?? digest.byteCount
            )
        } catch let error as BoundedFileIOError {
            try? FileManager.default.removeItem(at: localURL)
            switch error {
            case .valueExceedsLimit(let actual, _):
                throw MeasuredFlowArtifactAcquisitionError(
                    underlyingError: FlowArtifactStoreError.fileSizeMismatch(
                        path: relativePath,
                        expected: file.size,
                        actual: actual
                    ),
                    workByteCount: downloadedByteCount ?? 0
                )
            }
        } catch let error as MeasuredFlowArtifactAcquisitionError {
            try? FileManager.default.removeItem(at: localURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: localURL)
            throw MeasuredFlowArtifactAcquisitionError(
                underlyingError: error,
                workByteCount: downloadedByteCount ?? 0
            )
        }
    }

    private func downloadSignatureBuildFile(
        _ file: BuildFile,
        baseURL: URL,
        directoryURL: URL
    ) async throws {
        guard file.size >= 0,
              file.size <= FlowRuntimeImportLimits.signatureEnvelopeBytes else {
            do {
                try writeMalformedSignatureMarker(file, directoryURL: directoryURL)
            } catch {
                LogWarning("Could not retain malformed signature evidence: \(error)")
            }
            return
        }
        do {
            try await downloadBuildFile(
                file,
                baseURL: baseURL,
                directoryURL: directoryURL,
                maximumBytes: FlowRuntimeImportLimits.signatureEnvelopeBytes,
                field: "signature envelope"
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let relativePath = try? Self.validateRelativePath(file.path) {
                try? FileManager.default.removeItem(
                    at: directoryURL.appendingPathComponent(relativePath)
                )
            }
            LogWarning("Flow manifest signature could not be acquired: \(error)")
        }
    }

    private func writeMalformedSignatureMarker(
        _ file: BuildFile,
        directoryURL: URL
    ) throws {
        let relativePath = try Self.validateRelativePath(file.path)
        let localURL = directoryURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: localURL, options: .atomic)
    }

    private func decodeManifest(
        at url: URL,
        expectedSize: Int?
    ) throws -> (FlowArtifactManifest, Data) {
        let maximumBytes = min(
            expectedSize ?? FlowRuntimeImportLimits.manifestBytes,
            FlowRuntimeImportLimits.manifestBytes
        )
        do {
            let payload = try BoundedFileIO.read(
                at: url,
                maximumBytes: maximumBytes
            )
            if let expectedSize, payload.digest.byteCount != expectedSize {
                throw FlowArtifactStoreError.fileSizeMismatch(
                    path: Self.manifestPath,
                    expected: expectedSize,
                    actual: payload.digest.byteCount
                )
            }
            return (
                try JSONDecoder().decode(FlowArtifactManifest.self, from: payload.data),
                payload.data
            )
        } catch let error as BoundedFileIOError {
            switch error {
            case .valueExceedsLimit(let actual, _):
                if actual > FlowRuntimeImportLimits.manifestBytes {
                    throw FlowRuntimeImportValidationError.valueExceedsLimit(
                        field: "manifest",
                        actual: actual,
                        limit: FlowRuntimeImportLimits.manifestBytes
                    )
                }
                throw FlowArtifactStoreError.fileSizeMismatch(
                    path: Self.manifestPath,
                    expected: expectedSize ?? maximumBytes,
                    actual: actual
                )
            }
        }
    }

    private func validateDeclaredBuildFile(
        _ file: BuildFile,
        maximumBytes: Int,
        field: String
    ) throws {
        guard file.size >= 0 else {
            throw FlowArtifactStoreError.fileSizeMismatch(
                path: file.path,
                expected: 0,
                actual: file.size
            )
        }
        try FlowRuntimeImportRequest.requireAtMost(
            file.size,
            maximumBytes,
            field: field
        )
    }

    private func validateBuildManifest(_ manifest: BuildManifest) throws {
        try FlowRuntimeImportRequest.requireAtMost(
            manifest.files.count,
            Self.maximumBuildFileCount,
            field: "build manifest file count"
        )
        guard manifest.totalFiles == manifest.files.count else {
            throw FlowArtifactStoreError.buildManifestFileCountMismatch(
                declared: manifest.totalFiles,
                actual: manifest.files.count
            )
        }
        guard manifest.totalSize >= 0 else {
            throw FlowArtifactStoreError.buildManifestTotalSizeMismatch(
                declared: manifest.totalSize,
                actual: 0
            )
        }
        try FlowRuntimeImportRequest.requireAtMost(
            manifest.totalSize,
            Self.maximumBuildDeclaredBytes,
            field: "build manifest declared bytes"
        )

        var paths = Set<String>()
        paths.reserveCapacity(manifest.files.count)
        var declaredBytes = 0
        for file in manifest.files {
            _ = try Self.validateRelativePath(file.path)
            guard paths.insert(file.path).inserted else {
                throw FlowArtifactStoreError.duplicateBuildFilePath(file.path)
            }
            guard file.size >= 0 else {
                throw FlowArtifactStoreError.fileSizeMismatch(
                    path: file.path,
                    expected: 0,
                    actual: file.size
                )
            }
            let (nextDeclaredBytes, overflowed) = declaredBytes.addingReportingOverflow(file.size)
            guard !overflowed else {
                throw FlowRuntimeImportValidationError.byteCountOverflow(
                    field: "build manifest declared bytes"
                )
            }
            try FlowRuntimeImportRequest.requireAtMost(
                nextDeclaredBytes,
                Self.maximumBuildDeclaredBytes,
                field: "build manifest declared bytes"
            )
            declaredBytes = nextDeclaredBytes
        }

        guard manifest.totalSize == declaredBytes else {
            throw FlowArtifactStoreError.buildManifestTotalSizeMismatch(
                declared: manifest.totalSize,
                actual: declaredBytes
            )
        }
    }

    /// BuildManifest sidecars have no content digest, but the cache must still
    /// remain a complete realization of the declared envelope. Exact regular-
    /// file size checks are bounded metadata operations; files with stronger
    /// manifest contracts (the RIV and external images) are subsequently
    /// opened and content-verified by their dedicated paths.
    private func validateCachedBuildSidecars(
        _ buildManifest: BuildManifest,
        artifactManifest: FlowArtifactManifest,
        directoryURL: URL
    ) throws {
        var contentPaths: Set<String> = [
            Self.manifestPath,
            Self.manifestSignaturePath,
            artifactManifest.riv.path,
        ]
        contentPaths.formUnion(artifactManifest.assets.images.map(\.path))

        for file in buildManifest.files where !contentPaths.contains(file.path) {
            let url = try localURL(forRelativePath: file.path, in: directoryURL)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            } catch {
                throw FlowArtifactStoreError.downloadFailed(file.path)
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw FlowArtifactStoreError.downloadFailed(file.path)
            }
            let actualSize = (attributes[.size] as? NSNumber)?.intValue ?? -1
            guard actualSize == file.size else {
                throw FlowArtifactStoreError.fileSizeMismatch(
                    path: file.path,
                    expected: file.size,
                    actual: actualSize
                )
            }
        }
    }

    private func validateRivDeclarations(
        manifest: FlowArtifactManifest,
        buildManifest: BuildManifest
    ) throws {
        guard manifest.riv.sizeBytes >= 0 else {
            throw FlowArtifactStoreError.fileSizeMismatch(
                path: manifest.riv.path,
                expected: 0,
                actual: manifest.riv.sizeBytes
            )
        }
        try FlowRuntimeImportRequest.requireAtMost(
            manifest.riv.sizeBytes,
            FlowRuntimeImportLimits.artifactBytes,
            field: "artifact"
        )
        if let rivBuildFile = buildManifest.files.first(where: {
            $0.path == manifest.riv.path
        }) {
            try validateDeclaredBuildFile(
                rivBuildFile,
                maximumBytes: FlowRuntimeImportLimits.artifactBytes,
                field: "artifact"
            )
        }
    }

    private func prepareRuntimeAssetURLs(
        _ manifest: FlowArtifactManifest,
        directoryURL: URL,
        acquisitionPlan: FlowArtifactAssetAcquisitionPlan,
        acquisitionBudget: inout FlowArtifactAcquisitionBudget
    ) async throws -> [String: URL] {
        var urlsByRiveUniqueName: [String: URL] = [:]
        var preparedAssetsByIdentity: [String: PreparedRuntimeAsset] = [:]

        for required in [true, false] {
            for (descriptorIndex, image) in manifest.assets.images.enumerated()
            where image.required == required {
                guard !acquisitionPlan.omittedOptionalUniqueNames.contains(
                    image.riveUniqueName
                ) else {
                    continue
                }
                guard let expectedSize = acquisitionPlan.imageSizesByPath[image.path] else {
                    if image.required {
                        throw RuntimeAssetStoreError.missingSourceAsset(image.path)
                    }
                    continue
                }
                do {
                    try RuntimeAssetStore.validateImageDescriptor(
                        image,
                        expectedSize: expectedSize
                    )
                } catch {
                    if image.required { throw error }
                    LogDebug(
                        "Skipped optional image asset \(image.riveUniqueName): \(error)"
                    )
                    continue
                }

                let contentIdentity = "image:\(image.sha256.lowercased())"
                let descriptorIdentity = "image-descriptor:\(descriptorIndex)"
                let attemptIdentity = FlowArtifactAcquisitionIdentity.imageAttempt(
                    descriptorIndex: descriptorIndex,
                    path: image.path
                )
                guard acquisitionBudget.permitsAccepted(byteCount: expectedSize) else {
                    if image.required {
                        throw FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "aggregate external asset bytes",
                            actual: acquisitionBudget.acceptedBytes + expectedSize,
                            limit: acquisitionBudget.acceptedByteLimit
                        )
                    }
                    continue
                }
                if let preparedAsset = preparedAssetsByIdentity[contentIdentity] {
                    guard preparedAsset.byteCount == expectedSize else {
                        let error = RuntimeAssetStoreError.fileSizeMismatch(
                            path: image.path,
                            expected: expectedSize,
                            actual: preparedAsset.byteCount
                        )
                        if image.required { throw error }
                        LogDebug(
                            "Skipped optional image asset \(image.riveUniqueName): \(error)"
                        )
                        continue
                    }
                    try acquisitionBudget.recordAccepted(
                        identity: descriptorIdentity,
                        byteCount: expectedSize
                    )
                    urlsByRiveUniqueName[image.riveUniqueName] = preparedAsset.url
                    continue
                }
                guard acquisitionBudget.permitsWork(
                    identity: attemptIdentity,
                    totalByteCount: expectedSize
                ) else {
                    if image.required {
                        throw FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "external asset acquisition bytes",
                            actual: acquisitionBudget.workBytes + expectedSize,
                            limit: acquisitionBudget.workByteLimit
                        )
                    }
                    continue
                }
                do {
                    let acquisition = try await runtimeAssetStore.acquireCachedImageURL(
                        for: image,
                        artifactDirectoryURL: directoryURL,
                        expectedSize: expectedSize,
                        maximumWorkBytes: acquisitionBudget.workAllowance(
                            for: attemptIdentity
                        )
                    )
                    try acquisitionBudget.recordWork(
                        identity: attemptIdentity,
                        byteCount: acquisition.workByteCount
                    )
                    try acquisitionBudget.recordAccepted(
                        identity: descriptorIdentity,
                        byteCount: expectedSize
                    )
                    preparedAssetsByIdentity[contentIdentity] = PreparedRuntimeAsset(
                        url: acquisition.url,
                        byteCount: expectedSize
                    )
                    urlsByRiveUniqueName[image.riveUniqueName] = acquisition.url
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as MeasuredRuntimeAssetStoreError {
                    try acquisitionBudget.recordWork(
                        identity: attemptIdentity,
                        byteCount: error.workByteCount
                    )
                    if image.required {
                        throw error.underlyingError
                    }
                    LogDebug(
                        "Skipped optional image asset \(image.riveUniqueName): "
                            + "\(error.underlyingError)"
                    )
                } catch {
                    try acquisitionBudget.recordWork(
                        identity: attemptIdentity,
                        byteCount: max(
                            acquisitionBudget.recordedWorkBytes(for: attemptIdentity),
                            measuredAssetFailureBytes(error, expectedSize: expectedSize)
                        )
                    )
                    if image.required {
                        throw error
                    }
                    LogDebug("Skipped optional image asset \(image.riveUniqueName): \(error)")
                }
            }

            for (descriptorIndex, font) in manifest.assets.fonts.enumerated()
            where font.required == required {
                guard !acquisitionPlan.omittedOptionalUniqueNames.contains(
                    font.riveUniqueName
                ) else {
                    continue
                }
                do {
                    try RuntimeAssetStore.validateFontDescriptor(font)
                } catch {
                    if font.required { throw error }
                    LogDebug(
                        "Skipped optional font asset \(font.riveUniqueName): \(error)"
                    )
                    continue
                }

                let contentIdentity = "font:\(font.sha256.lowercased())"
                let descriptorIdentity = "font-descriptor:\(descriptorIndex)"
                let attemptIdentity = descriptorIdentity
                guard acquisitionBudget.permitsAccepted(byteCount: font.sizeBytes) else {
                    if font.required {
                        throw FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "aggregate external asset bytes",
                            actual: acquisitionBudget.acceptedBytes + font.sizeBytes,
                            limit: acquisitionBudget.acceptedByteLimit
                        )
                    }
                    continue
                }
                if let preparedAsset = preparedAssetsByIdentity[contentIdentity] {
                    guard preparedAsset.byteCount == font.sizeBytes else {
                        let error = RuntimeAssetStoreError.fileSizeMismatch(
                            path: font.assetUrl,
                            expected: font.sizeBytes,
                            actual: preparedAsset.byteCount
                        )
                        if font.required { throw error }
                        LogDebug(
                            "Skipped optional font asset \(font.riveUniqueName): \(error)"
                        )
                        continue
                    }
                    try acquisitionBudget.recordAccepted(
                        identity: descriptorIdentity,
                        byteCount: font.sizeBytes
                    )
                    urlsByRiveUniqueName[font.riveUniqueName] = preparedAsset.url
                    continue
                }
                guard acquisitionBudget.permitsWork(
                    identity: attemptIdentity,
                    totalByteCount: font.sizeBytes
                ) else {
                    if font.required {
                        throw FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "external asset acquisition bytes",
                            actual: acquisitionBudget.workBytes + font.sizeBytes,
                            limit: acquisitionBudget.workByteLimit
                        )
                    }
                    continue
                }
                do {
                    let acquisition = try await runtimeAssetStore.acquireCachedFontURL(
                        for: font,
                        maximumWorkBytes: acquisitionBudget.workAllowance(
                            for: attemptIdentity
                        )
                    )
                    try acquisitionBudget.recordWork(
                        identity: attemptIdentity,
                        byteCount: acquisition.workByteCount
                    )
                    try acquisitionBudget.recordAccepted(
                        identity: descriptorIdentity,
                        byteCount: font.sizeBytes
                    )
                    preparedAssetsByIdentity[contentIdentity] = PreparedRuntimeAsset(
                        url: acquisition.url,
                        byteCount: font.sizeBytes
                    )
                    urlsByRiveUniqueName[font.riveUniqueName] = acquisition.url
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as MeasuredRuntimeAssetStoreError {
                    try acquisitionBudget.recordWork(
                        identity: attemptIdentity,
                        byteCount: error.workByteCount
                    )
                    if font.required {
                        throw error.underlyingError
                    }
                    LogDebug(
                        "Skipped optional font asset \(font.riveUniqueName): "
                            + "\(error.underlyingError)"
                    )
                } catch {
                    try acquisitionBudget.recordWork(
                        identity: attemptIdentity,
                        byteCount: max(
                            acquisitionBudget.recordedWorkBytes(for: attemptIdentity),
                            measuredAssetFailureBytes(error, expectedSize: font.sizeBytes)
                        )
                    )
                    if font.required {
                        throw error
                    }
                    LogDebug("Skipped optional font asset \(font.riveUniqueName): \(error)")
                }
            }
        }

        return urlsByRiveUniqueName
    }

    private func measuredAssetFailureBytes(
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

    private func makeAssetAcquisitionPlan(
        manifest: FlowArtifactManifest,
        buildManifest: BuildManifest
    ) throws -> FlowArtifactAssetAcquisitionPlan {
        let (assetCount, assetCountOverflowed) = manifest.assets.images.count
            .addingReportingOverflow(manifest.assets.fonts.count)
        guard !assetCountOverflowed else {
            throw FlowRuntimeImportValidationError.byteCountOverflow(
                field: "external asset count"
            )
        }
        try FlowRuntimeImportRequest.requireAtMost(
            assetCount,
            FlowRuntimeImportLimits.externalAssetCount,
            field: "external asset count"
        )

        let buildFilesByPath = Dictionary(
            uniqueKeysWithValues: buildManifest.files.map { ($0.path, $0) }
        )
        var descriptors: [(uniqueName: String, required: Bool, size: Int?)] = []
        descriptors.reserveCapacity(assetCount)
        for image in manifest.assets.images {
            descriptors.append((
                uniqueName: image.riveUniqueName,
                required: image.required,
                size: buildFilesByPath[image.path]?.size
            ))
        }
        for font in manifest.assets.fonts {
            descriptors.append((
                uniqueName: font.riveUniqueName,
                required: font.required,
                size: font.sizeBytes
            ))
        }

        var omittedOptionalUniqueNames = Set<String>()
        var requiredContentBytes = 0
        for required in [true, false] {
            for descriptor in descriptors where descriptor.required == required {
                guard let size = descriptor.size else {
                    if !required {
                        omittedOptionalUniqueNames.insert(descriptor.uniqueName)
                    }
                    continue
                }
                guard size >= 0 else {
                    if required {
                        throw FlowArtifactStoreError.fileSizeMismatch(
                            path: descriptor.uniqueName,
                            expected: 0,
                            actual: size
                        )
                    }
                    omittedOptionalUniqueNames.insert(descriptor.uniqueName)
                    continue
                }

                let (nextRequiredContentBytes, contentOverflowed) = requiredContentBytes
                    .addingReportingOverflow(size)
                if size > FlowRuntimeImportLimits.externalAssetTotalBytes
                    || (required && (contentOverflowed
                        || nextRequiredContentBytes > FlowRuntimeImportLimits.externalAssetTotalBytes)) {
                    if required {
                        throw FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "aggregate external asset bytes",
                            actual: contentOverflowed ? Int.max : nextRequiredContentBytes,
                            limit: FlowRuntimeImportLimits.externalAssetTotalBytes
                        )
                    }
                    omittedOptionalUniqueNames.insert(descriptor.uniqueName)
                    continue
                }

                if required {
                    requiredContentBytes = nextRequiredContentBytes
                }
            }
        }

        var imagePathsToDownload = Set<String>()
        var requiredImagePaths = Set<String>()
        var optionalImageNamesByPath: [String: Set<String>] = [:]
        var imageSizesByPath: [String: Int] = [:]
        var imageDescriptorsByPath: [String: [FlowArtifactImageAsset]] = [:]
        for image in manifest.assets.images {
            if image.required {
                requiredImagePaths.insert(image.path)
            } else {
                optionalImageNamesByPath[image.path, default: []].insert(image.riveUniqueName)
            }
            if !omittedOptionalUniqueNames.contains(image.riveUniqueName) {
                imagePathsToDownload.insert(image.path)
            }
            if let size = buildFilesByPath[image.path]?.size {
                imageSizesByPath[image.path] = size
            }
            imageDescriptorsByPath[image.path, default: []].append(image)
        }

        return FlowArtifactAssetAcquisitionPlan(
            omittedOptionalUniqueNames: omittedOptionalUniqueNames,
            imagePathsToDownload: imagePathsToDownload,
            requiredImagePaths: requiredImagePaths,
            optionalImageNamesByPath: optionalImageNamesByPath,
            imageSizesByPath: imageSizesByPath,
            imageDescriptorsByPath: imageDescriptorsByPath
        )
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
            expectedSha256: manifest.riv.sha256,
            maximumBytes: FlowRuntimeImportLimits.artifactBytes
        )

        return rivURL
    }

    private func verifyFile(
        at url: URL,
        path: String,
        expectedSize: Int?,
        expectedSha256: String,
        maximumBytes: Int
    ) throws {
        let inspectionLimit = min(expectedSize ?? maximumBytes, maximumBytes)
        let digest: BoundedFileDigest
        do {
            digest = try BoundedFileIO.inspect(
                at: url,
                maximumBytes: inspectionLimit
            )
        } catch let error as BoundedFileIOError {
            switch error {
            case .valueExceedsLimit(let actual, _):
                if actual > maximumBytes {
                    throw FlowRuntimeImportValidationError.valueExceedsLimit(
                        field: "artifact",
                        actual: actual,
                        limit: maximumBytes
                    )
                }
                throw FlowArtifactStoreError.fileSizeMismatch(
                    path: path,
                    expected: expectedSize ?? inspectionLimit,
                    actual: actual
                )
            }
        }
        if let expectedSize, digest.byteCount != expectedSize {
            throw FlowArtifactStoreError.fileSizeMismatch(
                path: path,
                expected: expectedSize,
                actual: digest.byteCount
            )
        }
        guard digest.sha256.caseInsensitiveCompare(expectedSha256) == .orderedSame else {
            throw FlowArtifactStoreError.sha256Mismatch(
                path: path,
                expected: expectedSha256,
                actual: digest.sha256
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
