import Darwin
import Foundation
import NuxieRuntime

enum JourneyReleaseAcquisitionError: LocalizedError, Equatable, Sendable {
    case invalidProfileEntry
    case invalidDeliveryOrigin(String)
    case selectedScreenNotDeclared(String)
    case invalidRuntimeBinding(String)
    case aggregateLimitExceeded
    case objectSizeMismatch(key: String, expected: Int, actual: Int)
    case objectDigestMismatch(key: String, expected: String, actual: String)
    case objectContentTypeMismatch(key: String, expected: String, actual: String?)
    case redirectEscapedOrigin(String)
    case requiredObjectUnavailable(String)

    var contractCode: String {
        switch self {
        case .invalidProfileEntry: "journey_release.profile_entry.invalid"
        case .invalidDeliveryOrigin: "journey_release.delivery.invalid_origin"
        case .selectedScreenNotDeclared: "journey_release.render.screen_binding"
        case .invalidRuntimeBinding: "journey_release.render.runtime_binding"
        case .aggregateLimitExceeded: "journey_release.artifacts.aggregate_limit"
        case .objectSizeMismatch: "journey_release.artifact.size_mismatch"
        case .objectDigestMismatch: "journey_release.artifact.digest_mismatch"
        case .objectContentTypeMismatch: "journey_release.artifact.content_type_mismatch"
        case .redirectEscapedOrigin: "journey_release.delivery.redirect_origin"
        case .requiredObjectUnavailable: "journey_release.artifact.required_unavailable"
        }
    }

    var errorDescription: String? { contractCode }
}

private struct PreparedRuntimeRelease: Sendable {
    let payloadsByScreenID: [String: AuthenticatedRuntimePayload]
    let objectURLsByKey: [String: URL]
    let source: ExperienceArtifactSource
    let resourceMetrics: JourneyReleaseResourceMetrics

    func presentationArtifact(
        identity: AcquiredExperienceArtifact.Identity,
        provenance: String,
        initialScreenID: String,
        interactivePreparation suppliedPreparation: ExperienceInteractivePreparationHandle? = nil,
        products: [StoreProduct] = [],
        productsResolvedForScreenID: String? = nil,
        resourceMetrics suppliedResourceMetrics: JourneyReleaseResourceMetrics? = nil,
        productResolver: (@Sendable (String) async throws -> [StoreProduct])? = nil
    ) throws -> AcquiredExperienceArtifact {
        guard let payload = payloadsByScreenID[initialScreenID] else {
            throw JourneyReleaseAcquisitionError.selectedScreenNotDeclared(
                initialScreenID
            )
        }
        let assetURLs = Dictionary(uniqueKeysWithValues: payload.assets.compactMap {
            asset in objectURLsByKey[asset.sourceKey].map {
                (asset.riveUniqueName, $0)
            }
        })
        guard let sceneURL = objectURLsByKey[payload.renderPlan.scene.key] else {
            throw JourneyReleaseAcquisitionError.requiredObjectUnavailable(
                payload.renderPlan.scene.key
            )
        }
        let interactivePreparation = suppliedPreparation
            ?? ExperienceInteractivePreparationHandle(
                cache: ExperienceInteractivePreparationCache(),
                provenance: provenance,
                payload: payload
            )
        return AcquiredExperienceArtifact(
            identity: identity,
            sceneURL: sceneURL,
            sceneBytes: payload.sceneBytes,
            assetURLsByRiveUniqueName: assetURLs,
            source: source,
            payload: payload,
            interactivePreparation: interactivePreparation,
            products: products,
            productsResolvedForScreenID: productsResolvedForScreenID,
            resourceMetrics: suppliedResourceMetrics ?? resourceMetrics,
            productResolver: productResolver
        )
    }
}

struct PreparedJourneyPresentation: Sendable {
    let experience: Experience
    let artifactLoader: ExperienceArtifactLoader
}

/// Immutable source metadata used to copy one authenticated release's
/// renderer objects into the durable run journal before execution begins.
struct JourneyReleaseArtifactSource: Sendable {
    struct Object: Sendable {
        let sha256: String
        let sizeBytes: Int
        let required: Bool
    }

    let descriptorSHA256: String
    let objects: [Object]
    let cacheRoot: URL
}

/// Durable renderer objects owned by one live run. Presentation checks these
/// files before the evictable shared cache or network, so a parked run remains
/// resumable after profile replacement and process restart.
struct JourneyPinnedReleaseArtifacts: Sendable {
    let objectURLsBySHA256: [String: URL]
}

/// Keeps every required object for one authenticated Journey profile generation
/// protected from cache-budget eviction. The marker is installed before
/// acquisition begins and remains live while JourneyReleaseCatalog owns this value.
final class PreparedJourneyArtifacts: @unchecked Sendable {
    let releaseDescriptorSHA256s: Set<String>

    private let cacheRoot: URL
    private let objectsByReleaseDescriptorSHA256: [
        String: [JourneyReleaseArtifactSource.Object]
    ]
    private let protectionID: UUID?

    fileprivate init(
        releaseDescriptorSHA256s: Set<String>,
        objectsByReleaseDescriptorSHA256: [
            String: [JourneyReleaseArtifactSource.Object]
        ],
        protectedObjectSHA256s: Set<String>,
        cacheRoot: URL
    ) throws {
        self.releaseDescriptorSHA256s = releaseDescriptorSHA256s
        self.objectsByReleaseDescriptorSHA256 =
            objectsByReleaseDescriptorSHA256
        self.cacheRoot = cacheRoot
        protectionID = protectedObjectSHA256s.isEmpty
            ? nil
            : try JourneyReleaseCacheProtectionRegistry.shared.register(
                protectedObjectSHA256s,
                root: cacheRoot
            )
    }

    deinit {
        if let protectionID {
            JourneyReleaseCacheProtectionRegistry.shared.unregister(
                protectionID,
                root: cacheRoot
            )
        }
    }

    func source(
        for descriptorSHA256: String
    ) -> JourneyReleaseArtifactSource? {
        guard let objects = objectsByReleaseDescriptorSHA256[
            descriptorSHA256
        ] else { return nil }
        return JourneyReleaseArtifactSource(
            descriptorSHA256: descriptorSHA256,
            objects: objects,
            cacheRoot: cacheRoot
        )
    }
}

struct AuthenticatedJourneyReleaseID: Codable, Equatable, Hashable, Sendable {
    let identity: JourneyReleaseIdentity
    let descriptorSHA256: String
}

struct JourneyReleaseRuntime {
    /// Derived from the runtime module's authoritative build metadata.
    static let current = JourneyReleaseSupportedRuntime(
        currentSdkVersion: SDKVersion.current,
        supportedRuntimeRevisions: [NuxieEmbeddedRuntimeCompatibility.sourceRevision],
        supportedLuauRevisions: [
            NuxieEmbeddedRuntimeCompatibility.luauRevision:
                NuxieEmbeddedRuntimeCompatibility.luauBytecodeVersions
        ],
        sceneFormat: .init(
            major: NuxieEmbeddedRuntimeCompatibility.sceneFormatMajor,
            minor: NuxieEmbeddedRuntimeCompatibility.sceneFormatMinor
        ),
        timezoneDataRevision: "2026c",
        timezoneDataSHA256: SignedTimezoneBundle.sha256,
        supportedCapabilities: NuxieEmbeddedRuntimeCompatibility.capabilities
    )
}

private struct JourneyReleaseRenderDocument: Decodable {
    struct Artifact: Decodable, Hashable {
        let key: String
        let sha256: String
        let sizeBytes: Int
        let contentType: String
    }

    struct Screen: Decodable {
        struct Exit: Decodable {
            let completeEventName: String
            let durationMs: Int
        }

        let id: String
        let artboardId: String
        let artboardName: String
        let width: Double
        let height: Double
        let exit: Exit?
    }

    struct Transition: Decodable {
        struct Endpoint: Decodable { let completeEventName: String }
        struct Reverse: Decodable {
            let durationMs: Int?
            let incomingOnTop: Bool?
            let source: Endpoint
            let destination: Endpoint
        }

        let id: String
        let kind: String
        let sourceScreenId: String
        let destinationScreenId: String
        let durationMs: Int
        let incomingOnTop: Bool
        let source: Endpoint
        let destination: Endpoint
        let reverse: Reverse?
    }

    struct TextInput: Decodable {
        struct Geometry: Decodable {
            let xPath: String
            let yPath: String
            let widthPath: String
            let heightPath: String
            let rotationPath: String
            let scaleXPath: String
            let scaleYPath: String
        }

        struct Style: Decodable {
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

        let id: String
        let screenId: String
        let artboardId: String
        let viewNodeId: String
        let renderedNodeId: String
        let riveTextObjectKey: String
        let riveTextRunObjectKey: String
        let riveTextName: String
        let riveTextRunName: String
        let value: String
        let placeholder: String?
        let editable: Bool
        let geometry: Geometry
        let style: Style
        let keyboardType: String?
        let secureTextEntry: Bool?
        let multiline: Bool?
        let maxLength: Int?
        let responseFieldKey: String?
    }

    struct Asset: Decodable {
        let kind: String
        let key: String
        let sha256: String
        let sizeBytes: Int
        let contentType: String
        let riveAssetId: UInt64?
        let riveUniqueName: String?
        let family: String?
        let weight: String?
        let style: String?
        let format: String?
        let required: Bool

        var artifact: Artifact {
            Artifact(
                key: key,
                sha256: sha256,
                sizeBytes: sizeBytes,
                contentType: contentType
            )
        }
    }

    let renderer: String
    let riv: Artifact
    let screens: [Screen]
    let transitions: [Transition]
    let textInputs: [TextInput]
    let assets: [Asset]
}

private struct JourneyReleaseProvenanceDocument: Decodable {
    let compilerCommit: String
    let compilerVersion: String
}

private struct JourneyReleaseArtifactDocument: Decodable {
    struct Script: Decodable {
        let artifact: JourneyReleaseRenderDocument.Artifact?
    }

    let scripts: [String: [Script]]
}

private struct JourneyReleaseScreenBehaviorArtifactDocument: Decodable {
    struct Script: Decodable {
        let artifact: JourneyReleaseRenderDocument.Artifact
    }

    let script: Script?
}

struct JourneyReleaseProductDocument: Decodable, Equatable, Sendable {
    struct Store: Decodable, Equatable, Sendable {
        let platform: String
        let productId: String
        let productType: String
        let basePlanId: String?
        let purchaseOptionId: String?
    }

    struct Entitlement: Decodable, Equatable, Sendable {
        let id: String
        let featureId: String?
        let featureExternalId: String?
        let purchaseUsageFeatureIds: [String]
        let allowanceType: String?
        let allowance: Double?
        let interval: String?
    }

    struct Preview: Decodable, Equatable, Sendable {
        let name: String
        let description: String
        let price: String
        let period: String
        let periodCount: Int
        let periodLabel: String
        let hasTrial: Bool
        let trialLabel: String
        let introOfferLabel: String
        let renewalLabel: String
    }

    let id: String
    let type: String
    let store: Store
    let preview: Preview
    let entitlements: [Entitlement]
}

struct JourneyReleasePlacementDocument: Decodable, Equatable, Sendable {
    struct AppStore: Decodable, Equatable, Sendable {
        let introEligibility: AppStorePlacementOptions.IntroEligibility
        let billingPlan: StoreProduct.BillingPlan
    }

    struct GooglePlay: Decodable, Equatable, Sendable {
        let offerId: String
    }

    let id: String
    let productId: String
    let appStore: AppStore?
    let googlePlay: GooglePlay?

    var appStoreOptions: AppStorePlacementOptions {
        guard let appStore else { return .default }
        return AppStorePlacementOptions(
            introEligibility: appStore.introEligibility,
            billingPlan: appStore.billingPlan
        )
    }
}

private struct JourneyReleasePresentationDocument: Decodable {
    struct Sheet: Decodable {
        let detent: ExperienceBehaviorPresentation.Sheet.Detent
        let dismissible: Bool
    }

    struct Drawer: Decodable {
        let edge: ExperienceBehaviorPresentation.Drawer.Edge
        let extentRatio: Double
        let cornerRadius: Double
        let dismissible: Bool
    }

    let style: String
    let orientation: ExperienceBehaviorPresentationOrientation
    let backgroundColor: String
    let sheet: Sheet?
    let drawer: Drawer?

    func behaviorPresentation() throws -> ExperienceBehaviorPresentation {
        guard let style = ExperienceBehaviorPresentationStyle(rawValue: style) else {
            throw JourneyReleaseAcquisitionError.invalidProfileEntry
        }
        return ExperienceBehaviorPresentation(
            style: style,
            orientation: orientation,
            backgroundColor: backgroundColor,
            sheet: sheet.map {
                .init(detent: $0.detent, dismissible: $0.dismissible)
            },
            drawer: drawer.map {
                .init(
                    edge: $0.edge,
                    extentRatio: $0.extentRatio,
                    cornerRadius: $0.cornerRadius,
                    dismissible: $0.dismissible
                )
            }
        )
    }
}

protocol JourneyReleaseAcquiring: Sendable {
    /// Acquires and pins every required render object before a canonical
    /// profile can publish any of its Journey arms.
    func prepareJourneyArtifacts(
        for snapshot: JourneyProfileCatalog.Snapshot
    ) async throws -> PreparedJourneyArtifacts

    func preparePresentation(
        release: AuthenticatedJourneyRelease,
        delivery: JourneyReleaseDelivery,
        pinnedArtifacts: JourneyPinnedReleaseArtifacts?,
        productResolver:
            @escaping @Sendable (String) async throws -> [StoreProduct]
    ) async throws -> PreparedJourneyPresentation
}

enum JourneyReleasePreparationIntent: Equatable, Sendable {
    case profileAdmission
    case presentation

    var allowsConstrainedNetworkAccess: Bool {
        true
    }
}

/// Acquires the objects authorized by an authenticated Journey release into a
/// digest-addressed cache and produces the native renderer payload.
final class JourneyReleaseCacheProtectionRegistry: @unchecked Sendable {
    static let shared = JourneyReleaseCacheProtectionRegistry()

    private struct Marker: Codable {
        let processID: Int32
        let processStartTimeMicroseconds: UInt64
        let digests: [String]
    }

    private struct Protection {
        let digests: Set<String>
        let markerURL: URL
    }

    private let lock = NSLock()
    private var protections: [String: [UUID: Protection]] = [:]

    func register(_ digests: Set<String>, root: URL) throws -> UUID {
        let directory = CacheFilesystemLockScope(
            cacheRootURL: root
        ).protectionDirectoryURL
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let id = UUID()
        let markerURL = directory.appendingPathComponent(
            id.uuidString.lowercased() + ".json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let processStartTimeMicroseconds = Self.processStartTimeMicroseconds(
            getpid()
        ) else {
            throw JourneyReleaseAcquisitionError.invalidProfileEntry
        }
        try encoder.encode(Marker(
            processID: getpid(),
            processStartTimeMicroseconds: processStartTimeMicroseconds,
            digests: digests.sorted()
        )).write(to: markerURL, options: .atomic)
        lock.withLock {
            protections[directory.path, default: [:]][id] = Protection(
                digests: digests,
                markerURL: markerURL
            )
        }
        return id
    }

    func unregister(_ id: UUID, root: URL) {
        let directory = CacheFilesystemLockScope(
            cacheRootURL: root
        ).protectionDirectoryURL
        let markerURL = lock.withLock {
            let protection = protections[directory.path]?.removeValue(forKey: id)
            if protections[directory.path]?.isEmpty == true {
                protections.removeValue(forKey: directory.path)
            }
            return protection?.markerURL
        } ?? directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
        try? FileManager.default.removeItem(at: markerURL)
    }

    func protectedDigests(root: URL) throws -> Set<String> {
        let directory = CacheFilesystemLockScope(
            cacheRootURL: root
        ).protectionDirectoryURL
        var result = lock.withLock {
            protections[directory.path]?.values.reduce(into: Set<String>()) {
                $0.formUnion($1.digests)
            } ?? []
        }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return result
        }
        let markerURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        for markerURL in markerURLs {
            guard let data = try? Data(contentsOf: markerURL),
                  let marker = try? decoder.decode(Marker.self, from: data) else {
                // An interrupted writer or obsolete schema must not disable
                // cache-budget enforcement forever. It cannot represent a
                // trustworthy live protection, so discard it as stale.
                try? FileManager.default.removeItem(at: markerURL)
                continue
            }
            if Self.processOwns(marker) {
                result.formUnion(marker.digests)
            } else {
                try? FileManager.default.removeItem(at: markerURL)
            }
        }
        return result
    }

    private static func processOwns(_ marker: Marker) -> Bool {
        guard marker.processID > 0 else { return false }
        if kill(marker.processID, 0) == 0 {
            guard let start = processStartTimeMicroseconds(marker.processID) else {
                // If the platform refuses metadata for a live sibling process,
                // preserve its protection rather than risk active corruption.
                return true
            }
            return start == marker.processStartTimeMicroseconds
        }
        // A process that exists but is not signalable still owns its marker.
        return errno == EPERM
    }

    private static func processStartTimeMicroseconds(_ processID: Int32) -> UInt64? {
        var info = kinfo_proc()
        var query: [Int32] = [
            CTL_KERN,
            KERN_PROC,
            KERN_PROC_PID,
            processID,
        ]
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&query, UInt32(query.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_starttime.tv_sec >= 0,
              info.kp_proc.p_starttime.tv_usec >= 0 else {
            return nil
        }
        return UInt64(info.kp_proc.p_starttime.tv_sec) * 1_000_000
            + UInt64(info.kp_proc.p_starttime.tv_usec)
    }
}

actor JourneyReleaseAcquisitionStore: JourneyReleaseAcquiring {
    private struct ObjectResult {
        let url: URL
        let bytes: Data
        let downloaded: Bool
        let resourceMetrics: JourneyReleaseResourceMetrics
    }

    private struct ObjectAcquisitionFailure: Error {
        let underlying: Error
        let resourceMetrics: JourneyReleaseResourceMetrics
    }

    private struct ArtifactRequirement {
        let artifact: JourneyReleaseRenderDocument.Artifact
        let required: Bool
    }

    private struct RuntimeReleaseAuthority {
        let authenticatedKeyID: String
        let identity: JourneyReleaseIdentity
        let descriptorSHA256: String
        let render: [String: JourneyReleaseJSONValue]
        let screenBehaviors: [[String: JourneyReleaseJSONValue]]
        let definition: ExperienceDefinition
        let journey: JourneyDocument
    }

    private struct RuntimeReleaseManifest {
        let render: JourneyReleaseRenderDocument
        let requirements: [ArtifactRequirement]

        var protectedDigests: Set<String> {
            Set(requirements.map(\.artifact.sha256))
        }
    }

    private let cacheDirectory: URL
    private let cacheLockScope: CacheFilesystemLockScope
    private let maximumCacheBytes: Int
    private let urlSession: URLSession
    init(
        cacheDirectory: URL? = nil,
        maximumCacheBytes: Int = 256 * 1_024 * 1_024,
        urlSession: URLSession = .shared
    ) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let root = cacheDirectory
            ?? caches.appendingPathComponent(
                "nuxie_journey_release_objects",
                isDirectory: true
            )
        self.cacheDirectory = root
        cacheLockScope = CacheFilesystemLockScope(cacheRootURL: root)
        self.maximumCacheBytes = max(0, maximumCacheBytes)
        self.urlSession = urlSession
    }

    func prepareJourneyArtifacts(
        for snapshot: JourneyProfileCatalog.Snapshot
    ) async throws -> PreparedJourneyArtifacts {
        let releaseDescriptorSHA256s = Set(snapshot.releasesByDigest.keys)
        var authorities: [RuntimeReleaseAuthority] = []
        var objectsByReleaseDescriptorSHA256: [
            String: [JourneyReleaseArtifactSource.Object]
        ] = [:]
        var protectedObjectSHA256s: Set<String> = []

        for descriptorSHA256 in releaseDescriptorSHA256s.sorted() {
            guard let release = snapshot.releasesByDigest[descriptorSHA256],
                  release.descriptorSHA256 == descriptorSHA256 else {
                throw JourneyReleaseAcquisitionError.invalidProfileEntry
            }
            guard let authority = try Self.journeyRuntimeAuthority(release) else {
                objectsByReleaseDescriptorSHA256[descriptorSHA256] = []
                continue
            }
            let manifest = try Self.runtimeReleaseManifest(authority)
            authorities.append(authority)
            let objects = manifest.requirements.map {
                JourneyReleaseArtifactSource.Object(
                    sha256: $0.artifact.sha256,
                    sizeBytes: $0.artifact.sizeBytes,
                    required: $0.required
                )
            }
            objectsByReleaseDescriptorSHA256[descriptorSHA256] = objects
            protectedObjectSHA256s.formUnion(objects.map(\.sha256))
        }

        // Register the complete profile set before the first object is read or
        // downloaded. Per-release cache-budget enforcement can then never evict
        // an earlier leg while a later leg in the same generation is prepared.
        let prepared = try PreparedJourneyArtifacts(
            releaseDescriptorSHA256s: releaseDescriptorSHA256s,
            objectsByReleaseDescriptorSHA256:
                objectsByReleaseDescriptorSHA256,
            protectedObjectSHA256s: protectedObjectSHA256s,
            cacheRoot: cacheDirectory
        )
        for authority in authorities {
            try Task.checkCancellation()
            _ = try await prepareRuntimeRelease(
                authority,
                delivery: snapshot.profile.delivery,
                intent: .profileAdmission
            )
        }
        return prepared
    }

    private nonisolated static func journeyRuntimeAuthority(
        _ release: AuthenticatedJourneyRelease
    ) throws -> RuntimeReleaseAuthority? {
        guard SHA256Provider.hexDigest(release.exactDescriptorBytes)
                == release.descriptorSHA256 else {
            throw JourneyReleaseAcquisitionError.invalidProfileEntry
        }
        guard let render = release.descriptor.render else {
            guard release.descriptor.leg.screens.isEmpty else {
                throw JourneyReleaseAcquisitionError.invalidProfileEntry
            }
            return nil
        }
        let definition = try ExperienceDefinition(
            journeyDescriptor: release.descriptor
        )
        return RuntimeReleaseAuthority(
            authenticatedKeyID: release.authenticatedKeyID,
            identity: release.descriptor.identity,
            descriptorSHA256: release.descriptorSHA256,
            render: render,
            screenBehaviors: release.descriptor.screenBehaviors,
            definition: definition,
            journey: definition.renderShell
        )
    }

    private nonisolated static func runtimeReleaseManifest(
        _ authority: RuntimeReleaseAuthority
    ) throws -> RuntimeReleaseManifest {
        let render = try decode(
            JourneyReleaseRenderDocument.self,
            from: authority.render
        )
        guard render.renderer == "rive" else {
            throw JourneyReleaseAcquisitionError.invalidRuntimeBinding(
                render.renderer
            )
        }
        let journeyArtifacts = try JSONDecoder().decode(
            [JourneyReleaseScreenBehaviorArtifactDocument].self,
            from: JSONEncoder().encode(authority.screenBehaviors)
        ).compactMap { $0.script?.artifact }
        guard Set(render.screens.map(\.id))
                == Set(authority.journey.screens.map(\.id)) else {
            throw JourneyReleaseAcquisitionError.invalidRuntimeBinding(
                "screen_catalog"
            )
        }
        let requirements = try uniqueArtifacts(
            [ArtifactRequirement(artifact: render.riv, required: true)]
                + render.assets.map {
                    ArtifactRequirement(
                        artifact: $0.artifact,
                        required: $0.required
                    )
                }
                + journeyArtifacts.map {
                    ArtifactRequirement(artifact: $0, required: true)
                }
        )
        return RuntimeReleaseManifest(
            render: render,
            requirements: requirements
        )
    }

    private nonisolated static func selectedScreenID(
        requested: String?,
        renderScreenIDs: Set<String>,
        journeyScreenIDs: Set<String>
    ) throws -> String {
        let selected: String
        if let requested {
            selected = requested
        } else if renderScreenIDs.count == 1, let only = renderScreenIDs.first {
            selected = only
        } else {
            throw JourneyReleaseAcquisitionError.selectedScreenNotDeclared("ambiguous")
        }
        guard renderScreenIDs.contains(selected), journeyScreenIDs.contains(selected) else {
            throw JourneyReleaseAcquisitionError.selectedScreenNotDeclared(selected)
        }
        return selected
    }

    private func prepareRuntimeRelease(
        _ authority: RuntimeReleaseAuthority,
        delivery: JourneyReleaseDelivery,
        intent: JourneyReleasePreparationIntent,
        pinnedArtifacts: JourneyPinnedReleaseArtifacts? = nil
    ) async throws -> PreparedRuntimeRelease {
        let renderOrigin = try Self.validatedOrigin(delivery.renderBaseUrl)
        let assetOrigin = try Self.validatedOrigin(delivery.assetBaseUrl)
        let manifest = try Self.runtimeReleaseManifest(authority)
        let render = manifest.render
        let uniqueRequirements = manifest.requirements
        let protectedDigests = manifest.protectedDigests

        // Validate every signed object key before optionality is considered.
        // Optional means a safe acquisition failure may omit bytes; it never
        // permits an unsafe key or delivery-origin escape to be ignored.
        for requirement in uniqueRequirements {
            let artifact = requirement.artifact
            let origin = artifact.key.hasPrefix("renders/") ? renderOrigin : assetOrigin
            _ = try Self.compose(artifact.key, relativeTo: origin)
        }

        let protectionID = try JourneyReleaseCacheProtectionRegistry.shared.register(
            protectedDigests,
            root: cacheDirectory
        )
        defer {
            JourneyReleaseCacheProtectionRegistry.shared.unregister(
                protectionID,
                root: cacheDirectory
            )
        }

        var objectsByDigest: [String: ObjectResult] = [:]
        var failedObjectMetrics = JourneyReleaseResourceMetrics.zero
        var downloadedAny = false
        for requirement in uniqueRequirements {
            let artifact = requirement.artifact
            let origin = artifact.key.hasPrefix("renders/") ? renderOrigin : assetOrigin
            do {
                let result = try await acquireObject(
                    artifact,
                    origin: origin,
                    intent: intent,
                    protectedDigests: protectedDigests,
                    pinnedArtifacts: pinnedArtifacts
                )
                objectsByDigest[artifact.sha256] = result
                downloadedAny = downloadedAny || result.downloaded
            } catch {
                let underlying: Error
                if let failure = error as? ObjectAcquisitionFailure {
                    failedObjectMetrics = failedObjectMetrics.adding(
                        failure.resourceMetrics
                    )
                    underlying = failure.underlying
                } else {
                    underlying = error
                }
                guard !requirement.required else {
                    let completedMetrics = objectsByDigest.values.reduce(
                        failedObjectMetrics
                    ) { $0.adding($1.resourceMetrics) }
                    throw JourneyReleaseResourceFailure(
                        underlying: underlying,
                        resourceMetrics: completedMetrics
                    )
                }
                try Task.checkCancellation()
                if let urlError = underlying as? URLError,
                   urlError.code == .cancelled {
                    throw underlying
                }
                if let acquisitionError = underlying as? JourneyReleaseAcquisitionError,
                   case .redirectEscapedOrigin = acquisitionError {
                    throw underlying
                }
            }
        }
        var objectsByKey: [String: ObjectResult] = [:]
        for requirement in uniqueRequirements {
            let artifact = requirement.artifact
            objectsByKey[artifact.key] = objectsByDigest[artifact.sha256]
        }
        guard let scene = objectsByKey[render.riv.key] else {
            throw JourneyReleaseAcquisitionError.requiredObjectUnavailable(
                render.riv.key
            )
        }

        let runtimeAssets = try render.assets.compactMap { asset
            -> AuthenticatedRuntimeAsset? in
            guard asset.kind == "image" || asset.kind == "font" else { return nil }
            guard let authoredID64 = asset.riveAssetId,
                  let authoredID = UInt32(exactly: authoredID64),
                  let uniqueName = asset.riveUniqueName else {
                throw JourneyReleaseAcquisitionError.invalidRuntimeBinding(asset.key)
            }
            let object = objectsByKey[asset.key]
            guard object != nil || !asset.required else {
                throw JourneyReleaseAcquisitionError.requiredObjectUnavailable(asset.key)
            }
            return AuthenticatedRuntimeAsset(
                kind: asset.kind == "image" ? .image : .font,
                riveAssetID: authoredID,
                riveUniqueName: uniqueName,
                sourceKey: asset.key,
                contentType: asset.contentType,
                sha256: asset.sha256,
                required: asset.required,
                bytes: object?.bytes
            )
        }
        let payloadsByScreenID = try Dictionary(uniqueKeysWithValues: render.screens.map {
            screen in
            let renderPlan = try Self.runtimePlan(
                identity: authority.identity,
                render: render,
                initialScreenID: screen.id
            )
            return (screen.id, AuthenticatedRuntimePayload(
                authenticatedKeyID: authority.authenticatedKeyID,
                renderPlan: renderPlan,
                journey: authority.journey,
                definition: authority.definition,
                sceneBytes: scene.bytes,
                assets: runtimeAssets
            ))
        })
        return PreparedRuntimeRelease(
            payloadsByScreenID: payloadsByScreenID,
            objectURLsByKey: objectsByKey.mapValues(\.url),
            source: downloadedAny ? .download : .cache,
            resourceMetrics: objectsByDigest.values.reduce(failedObjectMetrics) {
                $0.adding($1.resourceMetrics)
            }
        )
    }

    func preparePresentation(
        release: AuthenticatedJourneyRelease,
        delivery: JourneyReleaseDelivery,
        pinnedArtifacts: JourneyPinnedReleaseArtifacts? = nil,
        productResolver:
            @escaping @Sendable (String) async throws -> [StoreProduct]
    ) async throws -> PreparedJourneyPresentation {
        guard let authority = try Self.journeyRuntimeAuthority(release) else {
            throw JourneyReleaseAcquisitionError.invalidProfileEntry
        }
        let definition = authority.definition
        let journey = authority.journey
        let render = try Self.decode(
            JourneyReleaseRenderDocument.self,
            from: authority.render
        )
        let renderScreenIDs = Set(render.screens.map(\.id))
        let journeyScreenIDs = Set(journey.screens.map(\.id))
        let identity = AcquiredExperienceArtifact.Identity(
            experienceId: release.descriptor.identity.experienceId,
            buildId: release.descriptor.identity.buildId
        )
        let provenance = release.descriptorSHA256
        let experience = try Self.journeyExperience(
            release: release,
            delivery: delivery,
            definition: definition,
            journey: journey,
            render: render
        )
        return PreparedJourneyPresentation(
            experience: experience,
            artifactLoader: { [weak self] _, _, requestedScreenID in
                guard let self else { throw CancellationError() }
                let screenID = try Self.selectedScreenID(
                    requested: requestedScreenID,
                    renderScreenIDs: renderScreenIDs,
                    journeyScreenIDs: journeyScreenIDs
                )
                // Keep cold network/cache acquisition in the ordinary artifact
                // loader. The presentation shell is installed before this
                // closure runs, so slow and failed acquisition retain the
                // signed loading and recovery surfaces.
                let prepared = try await self.prepareRuntimeRelease(
                    authority,
                    delivery: delivery,
                    intent: .presentation,
                    pinnedArtifacts: pinnedArtifacts
                )
                return try prepared.presentationArtifact(
                    identity: identity,
                    provenance: provenance,
                    initialScreenID: screenID,
                    productResolver: productResolver
                )
            }
        )
    }

    private func acquireObject(
        _ artifact: JourneyReleaseRenderDocument.Artifact,
        origin: URL,
        intent: JourneyReleasePreparationIntent,
        protectedDigests: Set<String>,
        pinnedArtifacts: JourneyPinnedReleaseArtifacts?
    ) async throws -> ObjectResult {
        let destination = cacheDirectory.appendingPathComponent(artifact.sha256)
        let result = try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: destination,
            lockScope: cacheLockScope
        ) {
            var rejectedCacheMetrics = JourneyReleaseResourceMetrics.zero
            if FileManager.default.fileExists(atPath: destination.path) {
                do {
                    let read = try BoundedFileIO.read(
                        at: destination,
                        maximumBytes: Self.limit(for: artifact)
                    )
                    do {
                        try Self.verify(read.digest, artifact: artifact)
                        try? FileManager.default.setAttributes(
                            [.modificationDate: Date()],
                            ofItemAtPath: destination.path
                        )
                        return ObjectResult(
                            url: destination,
                            bytes: read.data,
                            downloaded: false,
                            resourceMetrics: Self.objectResourceMetrics(
                                byteCount: read.data.count,
                                passCount: 1
                            )
                        )
                    } catch {
                        rejectedCacheMetrics = JourneyReleaseResourceMetrics(
                            readBytes: read.data.count,
                            hashedBytes: read.data.count,
                            parsedBytes: 0,
                            duplicateReadBytes: read.data.count,
                            duplicateHashBytes: read.data.count,
                            duplicateParseBytes: 0,
                            preloadBytes: 0,
                            unusedPreloadBytes: 0
                        )
                        throw error
                    }
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                }
            }

            if let pinnedURL = pinnedArtifacts?.objectURLsBySHA256[
                artifact.sha256
            ] {
                let read = try BoundedFileIO.read(
                    at: pinnedURL,
                    maximumBytes: Self.limit(for: artifact)
                )
                try Self.verify(read.digest, artifact: artifact)
                return ObjectResult(
                    url: pinnedURL,
                    bytes: read.data,
                    downloaded: false,
                    resourceMetrics: Self.objectResourceMetrics(
                        byteCount: read.data.count,
                        passCount: 1
                    )
                )
            }

            var resourceMetrics = rejectedCacheMetrics
            do {
                let sourceURL = try Self.compose(artifact.key, relativeTo: origin)
                let download = try await BoundedHTTPAcquisition.download(
                    from: sourceURL,
                    using: self.urlSession,
                    maximumBytes: Self.limit(for: artifact),
                    temporaryDirectory: self.cacheDirectory,
                    allowsConstrainedNetworkAccess: intent.allowsConstrainedNetworkAccess,
                    responseValidator: { response in
                        guard let finalURL = response.url,
                              Self.sameOrigin(finalURL, origin) else {
                            throw JourneyReleaseAcquisitionError.redirectEscapedOrigin(
                                response.url?.absoluteString ?? "missing"
                            )
                        }
                        let expected = artifact.contentType
                            .split(separator: ";", maxSplits: 1)[0]
                            .trimmingCharacters(in: .whitespaces)
                            .lowercased()
                        guard let mime = response.mimeType?.lowercased(),
                              mime == expected else {
                            throw JourneyReleaseAcquisitionError.objectContentTypeMismatch(
                                key: artifact.key,
                                expected: expected,
                                actual: response.mimeType
                            )
                        }
                    },
                    redirectValidator: { Self.sameOrigin($0, origin) }
                )
                defer { try? FileManager.default.removeItem(at: download.temporaryURL) }
                guard download.byteCount == artifact.sizeBytes else {
                    throw JourneyReleaseAcquisitionError.objectSizeMismatch(
                        key: artifact.key,
                        expected: artifact.sizeBytes,
                        actual: download.byteCount
                    )
                }
                do {
                    _ = try BoundedFileIO.copyVerified(
                        from: download.temporaryURL,
                        to: destination,
                        expectedSize: artifact.sizeBytes,
                        expectedSHA256: artifact.sha256,
                        maximumBytes: Self.limit(for: artifact)
                    )
                    resourceMetrics = resourceMetrics.adding(
                        Self.objectResourceMetrics(
                            byteCount: download.byteCount,
                            passCount: 1
                        )
                    )
                } catch BoundedFileVerificationError.sha256Mismatch(_, let actual) {
                    resourceMetrics = resourceMetrics.adding(
                        Self.objectResourceMetrics(
                            byteCount: download.byteCount,
                            passCount: 1
                        )
                    )
                    try? FileManager.default.removeItem(at: destination)
                    throw JourneyReleaseAcquisitionError.objectDigestMismatch(
                        key: artifact.key,
                        expected: artifact.sha256,
                        actual: actual
                    )
                } catch BoundedFileVerificationError.sizeMismatch(_, let actual) {
                    resourceMetrics = resourceMetrics.adding(
                        Self.objectResourceMetrics(
                            byteCount: download.byteCount,
                            passCount: 1
                        )
                    )
                    try? FileManager.default.removeItem(at: destination)
                    throw JourneyReleaseAcquisitionError.objectSizeMismatch(
                        key: artifact.key,
                        expected: artifact.sizeBytes,
                        actual: actual
                    )
                }
                let read = try BoundedFileIO.read(
                    at: destination,
                    maximumBytes: Self.limit(for: artifact)
                )
                resourceMetrics = resourceMetrics.adding(
                    JourneyReleaseResourceMetrics(
                        readBytes: read.data.count,
                        hashedBytes: read.data.count,
                        parsedBytes: 0,
                        duplicateReadBytes: read.data.count,
                        duplicateHashBytes: read.data.count,
                        duplicateParseBytes: 0,
                        preloadBytes: 0,
                        unusedPreloadBytes: 0
                    )
                )
                try Self.verify(read.digest, artifact: artifact)
                return ObjectResult(
                    url: destination,
                    bytes: read.data,
                    downloaded: true,
                    resourceMetrics: resourceMetrics
                )
            } catch let failure as ObjectAcquisitionFailure {
                throw failure
            } catch {
                throw ObjectAcquisitionFailure(
                    underlying: error,
                    resourceMetrics: resourceMetrics
                )
            }
        }
        try? await enforceCacheBudget(protecting: protectedDigests)
        return result
    }

    func enforceCacheBudget(protecting protectedDigests: Set<String>) async throws {
        let cacheDirectory = cacheDirectory
        let maximumCacheBytes = maximumCacheBytes
        let locallyProtectedDigests = protectedDigests
        try await CacheFilesystemLock.withExclusiveRootTransaction(
            scope: cacheLockScope
        ) {
            // Read cross-process markers only after the exclusive root lock is
            // held. A process that registered after an earlier snapshot could
            // otherwise acquire a shared target lock and begin assembly while
            // this pruning transaction waited, leaving its objects unprotected.
            let protectedDigests = try locallyProtectedDigests.union(
                JourneyReleaseCacheProtectionRegistry.shared.protectedDigests(
                    root: cacheDirectory
                )
            )
            let keys: Set<URLResourceKey> = [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
            ]
            let entries = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ).compactMap { url -> (url: URL, digest: String, size: Int, date: Date)? in
                let digest = url.lastPathComponent
                guard Self.isSHA256Digest(digest),
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let size = values.fileSize else {
                    return nil
                }
                return (url, digest, size, values.contentModificationDate ?? .distantPast)
            }
            var totalBytes = entries.reduce(0) { $0 + $1.size }
            guard totalBytes > maximumCacheBytes else { return }
            for entry in entries
                .filter({ !protectedDigests.contains($0.digest) })
                .sorted(by: {
                    if $0.date != $1.date { return $0.date < $1.date }
                    return $0.digest < $1.digest
                }) {
                try FileManager.default.removeItem(at: entry.url)
                totalBytes -= entry.size
                if totalBytes <= maximumCacheBytes { break }
            }
        }
    }

    private nonisolated static func isSHA256Digest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private nonisolated static func objectResourceMetrics(
        byteCount: Int,
        passCount: Int
    ) -> JourneyReleaseResourceMetrics {
        let totalBytes = byteCount * passCount
        let duplicateBytes = byteCount * max(0, passCount - 1)
        return JourneyReleaseResourceMetrics(
            readBytes: totalBytes,
            hashedBytes: totalBytes,
            parsedBytes: 0,
            duplicateReadBytes: duplicateBytes,
            duplicateHashBytes: duplicateBytes,
            duplicateParseBytes: 0,
            preloadBytes: 0,
            unusedPreloadBytes: 0
        )
    }

    private nonisolated static func uniqueArtifacts(
        _ requirements: [ArtifactRequirement]
    ) throws -> [ArtifactRequirement] {
        var byDigest: [String: ArtifactRequirement] = [:]
        var byKey: [String: JourneyReleaseRenderDocument.Artifact] = [:]
        for requirement in requirements {
            let artifact = requirement.artifact
            if let existing = byKey[artifact.key] {
                guard existing == artifact else {
                    throw JourneyReleaseAcquisitionError.invalidProfileEntry
                }
            } else {
                byKey[artifact.key] = artifact
            }
            if let existing = byDigest[artifact.sha256] {
                guard existing.artifact == artifact else {
                    throw JourneyReleaseAcquisitionError.invalidProfileEntry
                }
                byDigest[artifact.sha256] = ArtifactRequirement(
                    artifact: artifact,
                    required: existing.required || requirement.required
                )
                continue
            }
            byDigest[artifact.sha256] = requirement
        }
        let total = byDigest.values.reduce(into: 0) { result, requirement in
            let (next, overflow) = result.addingReportingOverflow(
                requirement.artifact.sizeBytes
            )
            result = overflow ? Int.max : next
        }
        guard total <= JourneyReleaseLimits.artifactAggregateBytes else {
            throw JourneyReleaseAcquisitionError.aggregateLimitExceeded
        }
        return byDigest.values.sorted { $0.artifact.key < $1.artifact.key }
    }

    private nonisolated static func verify(
        _ digest: BoundedFileDigest,
        artifact: JourneyReleaseRenderDocument.Artifact
    ) throws {
        guard digest.byteCount == artifact.sizeBytes else {
            throw JourneyReleaseAcquisitionError.objectSizeMismatch(
                key: artifact.key,
                expected: artifact.sizeBytes,
                actual: digest.byteCount
            )
        }
        guard digest.sha256 == artifact.sha256 else {
            throw JourneyReleaseAcquisitionError.objectDigestMismatch(
                key: artifact.key,
                expected: artifact.sha256,
                actual: digest.sha256
            )
        }
    }

    private nonisolated static func limit(
        for artifact: JourneyReleaseRenderDocument.Artifact
    ) -> Int {
        artifact.key.hasPrefix("renders/")
            ? JourneyReleaseLimits.rivArtifactBytes
            : JourneyReleaseLimits.externalAssetBytes
    }

    private nonisolated static func validatedOrigin(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              url.scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              value.hasSuffix("/") else {
            throw JourneyReleaseAcquisitionError.invalidDeliveryOrigin(value)
        }
        return url
    }

    private nonisolated static func compose(_ key: String, relativeTo origin: URL) throws
        -> URL
    {
        let root = key.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        let relativeKey: String
        if origin.path.hasSuffix("/\(root)/") {
            relativeKey = String(key.dropFirst(root.count + 1))
        } else {
            relativeKey = key
        }
        guard let result = URL(string: relativeKey, relativeTo: origin)?.absoluteURL,
              sameOrigin(result, origin) else {
            throw JourneyReleaseAcquisitionError.invalidDeliveryOrigin(
                origin.absoluteString
            )
        }
        return result
    }

    private nonisolated static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private nonisolated static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : nil)
    }

    private nonisolated static func decode<T: Decodable>(
        _ type: T.Type,
        from object: [String: JourneyReleaseJSONValue]
    ) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(object))
    }

    private nonisolated static func journeyExperience(
        release: AuthenticatedJourneyRelease,
        delivery: JourneyReleaseDelivery,
        definition: ExperienceDefinition,
        journey: JourneyDocument,
        render: JourneyReleaseRenderDocument
    ) throws -> Experience {
        let descriptor = release.descriptor
        let presentation = try decode(
            JourneyReleasePresentationDocument.self,
            from: descriptor.presentation
        )
        let identity = descriptor.identity
        return Experience(
            id: identity.experienceId,
            versionId: identity.experienceVersionId,
            buildId: identity.buildId,
            artifactContentHash: render.riv.sha256,
            authenticatedReleaseID: .init(
                identity: identity,
                descriptorSHA256: release.descriptorSHA256
            ),
            behaviorPresentation: try presentation.behaviorPresentation(),
            behaviorPresentationScreens: Dictionary(
                uniqueKeysWithValues: render.screens.map {
                    (
                        $0.id,
                        ExperienceBehaviorScreenGeometry(
                            width: $0.width,
                            height: $0.height
                        )
                    )
                }
            ),
            assetBaseURL: try validatedOrigin(delivery.assetBaseUrl),
            journey: journey,
            definition: definition,
            products: []
        )
    }

    private nonisolated static func runtimePlan(
        identity: JourneyReleaseIdentity,
        render: JourneyReleaseRenderDocument,
        initialScreenID: String
    ) throws -> NativeExperienceRenderPlan {
        let images = try render.assets.filter { $0.kind == "image" }.map {
            guard let id = $0.riveAssetId, let name = $0.riveUniqueName else {
                throw JourneyReleaseAcquisitionError.invalidRuntimeBinding($0.key)
            }
            return NativeExperienceImageAsset(
                location: .external(key: $0.key),
                riveAssetId: id,
                riveUniqueName: name,
                sha256: $0.sha256,
                sizeBytes: $0.sizeBytes,
                contentType: $0.contentType,
                required: $0.required
            )
        }
        let fonts = try render.assets.filter { $0.kind == "font" }.map {
            guard let id = $0.riveAssetId,
                  let name = $0.riveUniqueName,
                  let family = $0.family,
                  let weight = $0.weight,
                  let style = $0.style,
                  let format = $0.format else {
                throw JourneyReleaseAcquisitionError.invalidRuntimeBinding($0.key)
            }
            return NativeExperienceFontAsset(
                location: .external(key: $0.key),
                riveAssetId: id,
                riveUniqueName: name,
                family: family,
                weight: weight,
                style: style,
                sha256: $0.sha256,
                sizeBytes: $0.sizeBytes,
                contentType: $0.contentType,
                format: format,
                required: $0.required
            )
        }
        return NativeExperienceRenderPlan(
            identity: .init(
                experienceId: identity.experienceId,
                buildId: identity.buildId,
                appId: identity.appId,
                environment: identity.environment
            ),
            scene: .init(
                key: render.riv.key,
                sha256: render.riv.sha256,
                sizeBytes: render.riv.sizeBytes
            ),
            entry: .init(screenId: initialScreenID),
            screens: render.screens.map {
                NativeExperienceScreen(
                    screenId: $0.id,
                    artboardId: $0.artboardId,
                    artboardName: $0.artboardName,
                    width: $0.width,
                    height: $0.height,
                    exit: $0.exit.map {
                        NativeExperienceScreenExit(
                            completeEventName: $0.completeEventName,
                            durationMs: $0.durationMs
                        )
                    }
                )
            },
            transitions: render.transitions.map {
                NativeExperienceTransition(
                    id: $0.id,
                    sourceScreenId: $0.sourceScreenId,
                    destinationScreenId: $0.destinationScreenId,
                    durationMs: $0.durationMs,
                    incomingOnTop: $0.incomingOnTop,
                    source: .init(completeEventName: $0.source.completeEventName),
                    destination: .init(
                        completeEventName: $0.destination.completeEventName
                    ),
                    reverse: $0.reverse.map {
                        .init(
                            durationMs: $0.durationMs,
                            incomingOnTop: $0.incomingOnTop,
                            source: .init(
                                completeEventName: $0.source.completeEventName
                            ),
                            destination: .init(
                                completeEventName: $0.destination.completeEventName
                            )
                        )
                    }
                )
            },
            textInputs: render.textInputs.map {
                NativeExperienceTextInput(
                    inputId: $0.id,
                    screenId: $0.screenId,
                    artboardId: $0.artboardId,
                    viewNodeId: $0.viewNodeId,
                    renderedNodeId: $0.renderedNodeId,
                    riveTextObjectKey: $0.riveTextObjectKey,
                    riveTextRunObjectKey: $0.riveTextRunObjectKey,
                    riveTextName: $0.riveTextName,
                    riveTextRunName: $0.riveTextRunName,
                    value: $0.value,
                    placeholder: $0.placeholder,
                    editable: $0.editable,
                    geometry: .init(
                        xPath: $0.geometry.xPath,
                        yPath: $0.geometry.yPath,
                        widthPath: $0.geometry.widthPath,
                        heightPath: $0.geometry.heightPath,
                        rotationPath: $0.geometry.rotationPath,
                        scaleXPath: $0.geometry.scaleXPath,
                        scaleYPath: $0.geometry.scaleYPath
                    ),
                    style: .init(
                        fontFamily: $0.style.fontFamily,
                        fontWeight: $0.style.fontWeight,
                        fontStyle: $0.style.fontStyle,
                        fontSize: $0.style.fontSize,
                        lineHeight: $0.style.lineHeight,
                        letterSpacing: $0.style.letterSpacing,
                        color: $0.style.color,
                        fontAssetRiveUniqueName: $0.style.fontAssetRiveUniqueName,
                        textAlign: $0.style.textAlign
                    ),
                    keyboardType: $0.keyboardType,
                    secureTextEntry: $0.secureTextEntry,
                    multiline: $0.multiline,
                    maxLength: $0.maxLength,
                    responseFieldKey: $0.responseFieldKey
                )
            },
            images: images,
            fonts: fonts
        )
    }
}
