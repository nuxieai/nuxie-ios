import Darwin
import Foundation
import NuxieRuntime

enum ExperienceReleaseAcquisitionError: LocalizedError, Equatable, Sendable {
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
        case .invalidProfileEntry: "experience_release.profile_entry.invalid"
        case .invalidDeliveryOrigin: "experience_release.delivery.invalid_origin"
        case .selectedScreenNotDeclared: "experience_release.render.screen_binding"
        case .invalidRuntimeBinding: "experience_release.render.runtime_binding"
        case .aggregateLimitExceeded: "experience_release.artifacts.aggregate_limit"
        case .objectSizeMismatch: "experience_release.artifact.size_mismatch"
        case .objectDigestMismatch: "experience_release.artifact.digest_mismatch"
        case .objectContentTypeMismatch: "experience_release.artifact.content_type_mismatch"
        case .redirectEscapedOrigin: "experience_release.delivery.redirect_origin"
        case .requiredObjectUnavailable: "experience_release.artifact.required_unavailable"
        }
    }

    var errorDescription: String? { contractCode }
}

/// A descriptor-authenticated release translated directly into the existing
/// native runtime input. `payload` is not a wire manifest: it is the in-memory
/// renderer plan consumed by the production native host.
struct AcquiredExperienceRelease: Sendable {
    let authenticatedDescriptor: AuthenticatedExperienceReleaseDescriptor
    let payload: AuthenticatedRuntimePayload
    let objectURLsByKey: [String: URL]
    let source: ExperienceArtifactSource
    let resourceMetrics: ExperienceReleaseResourceMetrics
}

/// Immutable, descriptor-authenticated bytes and render plans shared by every
/// fresh presentation session for one exact release provenance.
struct PreparedExperienceRelease: Sendable {
    let authenticatedDescriptor: AuthenticatedExperienceReleaseDescriptor
    let payloadsByScreenID: [String: AuthenticatedRuntimePayload]
    let objectURLsByKey: [String: URL]
    let source: ExperienceArtifactSource
    let resourceMetrics: ExperienceReleaseResourceMetrics

    func acquired(initialScreenID: String? = nil) throws -> AcquiredExperienceRelease {
        let selectedScreenID: String
        if let initialScreenID {
            selectedScreenID = initialScreenID
        } else if payloadsByScreenID.count == 1, let only = payloadsByScreenID.keys.first {
            selectedScreenID = only
        } else {
            throw ExperienceReleaseAcquisitionError.selectedScreenNotDeclared("ambiguous")
        }
        guard let payload = payloadsByScreenID[selectedScreenID] else {
            throw ExperienceReleaseAcquisitionError.selectedScreenNotDeclared(
                selectedScreenID
            )
        }
        return AcquiredExperienceRelease(
            authenticatedDescriptor: authenticatedDescriptor,
            payload: payload,
            objectURLsByKey: objectURLsByKey,
            source: source,
            resourceMetrics: resourceMetrics
        )
    }

    func presentationArtifact(
        identity: AcquiredExperienceArtifact.Identity,
        initialScreenID: String,
        interactivePreparation suppliedPreparation: ExperienceInteractivePreparationHandle? = nil,
        products: [StoreProduct] = [],
        productsResolvedForScreenID: String? = nil,
        resourceMetrics suppliedResourceMetrics: ExperienceReleaseResourceMetrics? = nil,
        productResolver: (@Sendable (String) async throws -> [StoreProduct])? = nil
    ) throws -> AcquiredExperienceArtifact {
        try PreparedRuntimeRelease(
            payloadsByScreenID: payloadsByScreenID,
            objectURLsByKey: objectURLsByKey,
            source: source,
            resourceMetrics: resourceMetrics
        ).presentationArtifact(
            identity: identity,
            provenance: authenticatedDescriptor.descriptorSHA256,
            initialScreenID: initialScreenID,
            interactivePreparation: suppliedPreparation,
            products: products,
            productsResolvedForScreenID: productsResolvedForScreenID,
            resourceMetrics: suppliedResourceMetrics,
            productResolver: productResolver
        )
    }
}

private struct PreparedRuntimeRelease: Sendable {
    let payloadsByScreenID: [String: AuthenticatedRuntimePayload]
    let objectURLsByKey: [String: URL]
    let source: ExperienceArtifactSource
    let resourceMetrics: ExperienceReleaseResourceMetrics

    func presentationArtifact(
        identity: AcquiredExperienceArtifact.Identity,
        provenance: String,
        initialScreenID: String,
        interactivePreparation suppliedPreparation: ExperienceInteractivePreparationHandle? = nil,
        products: [StoreProduct] = [],
        productsResolvedForScreenID: String? = nil,
        resourceMetrics suppliedResourceMetrics: ExperienceReleaseResourceMetrics? = nil,
        productResolver: (@Sendable (String) async throws -> [StoreProduct])? = nil
    ) throws -> AcquiredExperienceArtifact {
        guard let payload = payloadsByScreenID[initialScreenID] else {
            throw ExperienceReleaseAcquisitionError.selectedScreenNotDeclared(
                initialScreenID
            )
        }
        let assetURLs = Dictionary(uniqueKeysWithValues: payload.assets.compactMap {
            asset in objectURLsByKey[asset.sourceKey].map {
                (asset.riveUniqueName, $0)
            }
        })
        guard let sceneURL = objectURLsByKey[payload.renderPlan.scene.key] else {
            throw ExperienceReleaseAcquisitionError.requiredObjectUnavailable(
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

struct PreparedDeviceLegPresentation: Sendable {
    let experience: Experience
    let artifactLoader: ExperienceArtifactLoader
}

/// Immutable source metadata used to copy one authenticated release's
/// renderer objects into the durable run journal before execution begins.
struct DeviceLegReleaseArtifactSource: Sendable {
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
struct DeviceLegPinnedReleaseArtifacts: Sendable {
    let objectURLsBySHA256: [String: URL]
}

/// Keeps every required object for one authenticated device-profile generation
/// protected from cache-budget eviction. The marker is installed before
/// acquisition begins and remains live while ExperienceLoader owns this value.
final class PreparedDeviceLegArtifacts: @unchecked Sendable {
    let releaseDescriptorSHA256s: Set<String>

    private let cacheRoot: URL
    private let objectsByReleaseDescriptorSHA256: [
        String: [DeviceLegReleaseArtifactSource.Object]
    ]
    private let protectionID: UUID?

    fileprivate init(
        releaseDescriptorSHA256s: Set<String>,
        objectsByReleaseDescriptorSHA256: [
            String: [DeviceLegReleaseArtifactSource.Object]
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
            : try ExperienceReleaseCacheProtectionRegistry.shared.register(
                protectedObjectSHA256s,
                root: cacheRoot
            )
    }

    deinit {
        if let protectionID {
            ExperienceReleaseCacheProtectionRegistry.shared.unregister(
                protectionID,
                root: cacheRoot
            )
        }
    }

    func source(
        for descriptorSHA256: String
    ) -> DeviceLegReleaseArtifactSource? {
        guard let objects = objectsByReleaseDescriptorSHA256[
            descriptorSHA256
        ] else { return nil }
        return DeviceLegReleaseArtifactSource(
            descriptorSHA256: descriptorSHA256,
            objects: objects,
            cacheRoot: cacheRoot
        )
    }
}

struct AuthenticatedExperienceReleaseID: Codable, Equatable, Hashable, Sendable {
    let identity: ExperienceReleaseIdentity
    let descriptorSHA256: String
}

struct AuthenticatedExperienceReleaseDefinition: Sendable {
    let releaseID: AuthenticatedExperienceReleaseID
    let authenticatedDescriptor: AuthenticatedExperienceReleaseDescriptor
    let delivery: ExperienceReleaseDelivery
    let mode: ExperienceReleaseAdmissionMode
    let behavior: ExperienceBehaviorDefinition
    let journey: JourneyDocument
    let definition: ExperienceDefinition
    let screenIDs: Set<String>
    let products: [ExperienceReleaseProductDocument]
    let placements: [ExperienceReleasePlacementDocument]

    var reference: ExperienceReference { behavior.reference }
}

struct AuthenticatedExperienceReleaseCatalog: Sendable {
    let definitions: [AuthenticatedExperienceReleaseDefinition]
    let rejections: [ExperienceReleaseRejection]
    var references: [ExperienceReference] { definitions.map(\.reference) }
}

struct ExperienceReleaseRejection: Sendable {
    let locator: ExperienceReleaseIdentity
    let contractCode: String
}

struct ExperienceReleaseRuntime {
    /// Derived from the runtime module's authoritative build metadata.
    static let current = ExperienceReleaseSupportedRuntime(
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

private struct ExperienceReleaseRenderDocument: Decodable {
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

private struct ExperienceReleaseProvenanceDocument: Decodable {
    let compilerCommit: String
    let compilerVersion: String
}

private struct ExperienceReleaseJourneyArtifactDocument: Decodable {
    struct Script: Decodable {
        let artifact: ExperienceReleaseRenderDocument.Artifact?
    }

    let scripts: [String: [Script]]
}

private struct ExperienceReleaseScreenBehaviorArtifactDocument: Decodable {
    struct Script: Decodable {
        let artifact: ExperienceReleaseRenderDocument.Artifact
    }

    let script: Script?
}

private struct ExperienceReleaseMetadataDocument: Decodable {
    let name: String
    let experienceType: String?
}

private struct ExperienceReleaseEnrollmentDocument: Decodable {
    struct Trigger: Decodable {
        let type: String
        let eventName: String?
        let condition: [String: ExperienceReleaseJSONValue]?
    }
    let trigger: Trigger
}

private struct ExperienceReleaseLifecycleDocument: Decodable {
    struct Reentry: Decodable {
        let type: String
        let windowSeconds: Int?
    }
    struct Goal: Decodable {
        let type: String
        let eventName: String?
        let condition: [String: ExperienceReleaseJSONValue]?
        let milestoneId: String?
        let segmentId: String?
        let expression: [String: ExperienceReleaseJSONValue]?
        let windowSeconds: Int?
    }
    let reentry: Reentry
    let exitPolicy: String
    let conversionAnchor: String
    let goal: Goal?
    let timeLimitSeconds: Int?
}

struct ExperienceReleaseProductDocument: Decodable, Equatable, Sendable {
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

struct ExperienceReleasePlacementDocument: Decodable, Equatable, Sendable {
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

private struct ExperienceReleasePresentationDocument: Decodable {
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
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
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

protocol ExperienceReleaseAcquiring: Sendable {
    func authenticateProfile(
        _ profile: ExperienceReleaseProfile
    ) async throws -> AuthenticatedExperienceReleaseCatalog

    func prepare(
        definition: AuthenticatedExperienceReleaseDefinition,
        intent: ExperienceReleasePreparationIntent
    ) async throws -> PreparedExperienceRelease

    /// Acquires and pins every required render object before a canonical
    /// profile can publish any of its device-owned arms.
    func prepareDeviceLegArtifacts(
        for snapshot: DeviceLegProfileCatalog.Snapshot
    ) async throws -> PreparedDeviceLegArtifacts

    /// Returns Product authority from an exact descriptor that was previously
    /// authenticated and retained by digest. This keeps restore and startup
    /// independent of whichever releases happen to be active today.
    func cachedProducts(
        descriptorSHA256: String
    ) async -> [ExperienceReleaseProductDocument]?
}

enum ExperienceReleasePreparationIntent: Equatable, Sendable {
    case preload
    case profileAdmission
    case presentation

    var allowsConstrainedNetworkAccess: Bool {
        self != .preload
    }
}

extension ExperienceReleaseAcquiring {
    func prepare(
        definition: AuthenticatedExperienceReleaseDefinition
    ) async throws -> PreparedExperienceRelease {
        try await prepare(definition: definition, intent: .presentation)
    }

    func cachedProducts(
        descriptorSHA256: String
    ) async -> [ExperienceReleaseProductDocument]? {
        nil
    }

    func prepareDeviceLegArtifacts(
        for snapshot: DeviceLegProfileCatalog.Snapshot
    ) async throws -> PreparedDeviceLegArtifacts {
        _ = snapshot
        throw ExperienceReleaseAcquisitionError.invalidProfileEntry
    }
}

/// Authenticates a profile release before looking at behavior or object keys,
/// acquires every signed render object into a digest-addressed cache, and
/// produces the input already consumed by `NuxieNativeRuntime`.
final class ExperienceReleaseCacheProtectionRegistry: @unchecked Sendable {
    static let shared = ExperienceReleaseCacheProtectionRegistry()

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
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
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

actor ExperienceReleaseAcquisitionStore: ExperienceReleaseAcquiring {
    private struct RouteKey: Hashable {
        let appId: String
        let environment: String
        let experienceId: String
        let experienceVersionId: String
    }

    private struct ReplayStreamKey: Hashable {
        let appId: String
        let environment: String
        let experienceId: String
    }

    private struct LocalRouteKey: Hashable {
        let experienceId: String
        let experienceVersionId: String
    }

    private struct AuthenticatedMembership {
        let identity: ExperienceReleaseIdentity
        let digest: String
        let definition: AuthenticatedExperienceReleaseDefinition
    }
    private struct ObjectResult {
        let url: URL
        let bytes: Data
        let downloaded: Bool
        let resourceMetrics: ExperienceReleaseResourceMetrics
    }

    private struct ObjectAcquisitionFailure: Error {
        let underlying: Error
        let resourceMetrics: ExperienceReleaseResourceMetrics
    }

    private struct ArtifactRequirement {
        let artifact: ExperienceReleaseRenderDocument.Artifact
        let required: Bool
    }

    private struct RuntimeReleaseAuthority {
        let authenticatedKeyID: String
        let identity: ExperienceReleaseIdentity
        let descriptorSHA256: String
        let render: [String: ExperienceReleaseJSONValue]
        let screenBehaviors: [[String: ExperienceReleaseJSONValue]]
        let definition: ExperienceDefinition
        let journey: JourneyDocument
    }

    private struct RuntimeReleaseManifest {
        let render: ExperienceReleaseRenderDocument
        let requirements: [ArtifactRequirement]

        var protectedDigests: Set<String> {
            Set(requirements.map(\.artifact.sha256))
        }
    }

    private let cacheDirectory: URL
    private let cacheLockScope: CacheFilesystemLockScope
    private let maximumCacheBytes: Int
    private let urlSession: URLSession
    private let authorizationKeys: [ExperiencePackageAuthorizationKey]
    private let supportedRuntime: ExperienceReleaseSupportedRuntime
    private let admission: ExperienceReleaseAdmission

    init(
        cacheDirectory: URL? = nil,
        maximumCacheBytes: Int = 256 * 1_024 * 1_024,
        urlSession: URLSession = .shared,
        authorizationKeys: [ExperiencePackageAuthorizationKey],
        supportedRuntime: ExperienceReleaseSupportedRuntime,
        admission: ExperienceReleaseAdmission
    ) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let root = cacheDirectory
            ?? caches.appendingPathComponent("nuxie_release_objects", isDirectory: true)
        self.cacheDirectory = root
        cacheLockScope = CacheFilesystemLockScope(cacheRootURL: root)
        self.maximumCacheBytes = max(0, maximumCacheBytes)
        self.urlSession = urlSession
        self.authorizationKeys = authorizationKeys
        self.supportedRuntime = supportedRuntime
        self.admission = admission
    }

    func prepareDeviceLegArtifacts(
        for snapshot: DeviceLegProfileCatalog.Snapshot
    ) async throws -> PreparedDeviceLegArtifacts {
        let releaseDescriptorSHA256s = Set(snapshot.releasesByDigest.keys)
        var authorities: [RuntimeReleaseAuthority] = []
        var objectsByReleaseDescriptorSHA256: [
            String: [DeviceLegReleaseArtifactSource.Object]
        ] = [:]
        var protectedObjectSHA256s: Set<String> = []

        for descriptorSHA256 in releaseDescriptorSHA256s.sorted() {
            guard let release = snapshot.releasesByDigest[descriptorSHA256],
                  release.descriptorSHA256 == descriptorSHA256 else {
                throw ExperienceReleaseAcquisitionError.invalidProfileEntry
            }
            guard let authority = try Self.deviceLegRuntimeAuthority(release) else {
                objectsByReleaseDescriptorSHA256[descriptorSHA256] = []
                continue
            }
            let manifest = try Self.runtimeReleaseManifest(authority)
            authorities.append(authority)
            let objects = manifest.requirements.map {
                DeviceLegReleaseArtifactSource.Object(
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
        let prepared = try PreparedDeviceLegArtifacts(
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

    func authenticateProfile(
        _ profile: ExperienceReleaseProfile
    ) async throws -> AuthenticatedExperienceReleaseCatalog {
        _ = try Self.validatedOrigin(profile.delivery.renderBaseUrl)
        _ = try Self.validatedOrigin(profile.delivery.assetBaseUrl)
        let memberships: [(ExperienceReleaseProfileEntry, ExperienceReleaseAdmissionMode)] =
            profile.pinned.map {
                ($0, .pinned(
                    experienceVersionId: $0.locator.experienceVersionId,
                    buildId: $0.locator.buildId,
                    descriptorSHA256: $0.descriptorSha256
                ))
            } + profile.active.map { ($0, .active) }
        var acceptedMemberships: [
            (ExperienceReleaseProfileEntry, ExperienceReleaseAdmissionMode)
        ] = []
        var definitions: [AuthenticatedExperienceReleaseDefinition] = []
        var batches: [ExperienceReleaseAdmission.AuthenticatedBatch] = []
        var rejections: [ExperienceReleaseRejection] = []
        var firstRejectionError: Error?
        for membership in memberships {
            do {
                let candidate = ExperienceReleaseAdmission.Candidate(
                    envelopeBytes: try membership.0.exactEnvelopeBytes(),
                    authorizationKeys: authorizationKeys,
                    expectedIdentity: Self.expectation(membership.0.locator),
                    supportedRuntime: supportedRuntime,
                    mode: membership.1
                )
                let batch = try await admission.authenticate([candidate])
                let authenticated = batch.descriptors[0]
                let definition = try Self.definition(
                    entry: membership.0,
                    delivery: profile.delivery,
                    mode: membership.1,
                    authenticated: authenticated
                )
                acceptedMemberships.append(membership)
                definitions.append(definition)
                batches.append(batch)
            } catch {
                if firstRejectionError == nil { firstRejectionError = error }
                rejections.append(.init(
                    locator: membership.0.locator,
                    contractCode: Self.contractCode(error)
                ))
            }
        }
        if definitions.isEmpty, let firstRejectionError {
            throw firstRejectionError
        }
        let resolved = try Self.resolveMemberships(
            memberships: acceptedMemberships,
            definitions: definitions
        )
        try Self.validateUniqueLocalRoutes(resolved)
        try await admission.commit(batches)
        try persistAuthenticatedDescriptors(resolved)
        return AuthenticatedExperienceReleaseCatalog(
            definitions: resolved.sorted {
                if $0.reference.experienceId != $1.reference.experienceId {
                    return $0.reference.experienceId < $1.reference.experienceId
                }
                return $0.reference.versionId < $1.reference.versionId
            },
            rejections: rejections
        )
    }

    func cachedProducts(
        descriptorSHA256: String
    ) async -> [ExperienceReleaseProductDocument]? {
        guard Self.isSHA256Digest(descriptorSHA256) else { return nil }
        let url = authenticatedDescriptorDirectory.appendingPathComponent(
            descriptorSHA256 + ".json"
        )
        guard let bytes = try? Data(contentsOf: url),
              SHA256Provider.hexDigest(bytes) == descriptorSHA256,
              let descriptor = try? JSONDecoder().decode(
                  ExperienceReleaseDescriptor.self,
                  from: bytes
              ),
              let products = try? JSONDecoder().decode(
                  [ExperienceReleaseProductDocument].self,
                  from: JSONEncoder().encode(descriptor.products)
              ) else {
            return nil
        }
        return products
    }

    private var authenticatedDescriptorDirectory: URL {
        cacheDirectory.appendingPathComponent(
            // UNIV-2491 is a hard cache boundary for the final purchase
            // descriptor contract. Deliberately do not read or migrate the
            // pre-cutover namespace; current signed profiles rehydrate it.
            "authenticated_descriptors_purchase_v3",
            isDirectory: true
        )
    }

    private func persistAuthenticatedDescriptors(
        _ definitions: [AuthenticatedExperienceReleaseDefinition]
    ) throws {
        guard !definitions.isEmpty else { return }
        let directory = authenticatedDescriptorDirectory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        for definition in definitions {
            let authenticated = definition.authenticatedDescriptor
            guard Self.isSHA256Digest(authenticated.descriptorSHA256),
                  SHA256Provider.hexDigest(authenticated.exactDescriptorBytes)
                    == authenticated.descriptorSHA256 else {
                throw ExperienceReleaseAcquisitionError.invalidProfileEntry
            }
            let destination = directory.appendingPathComponent(
                authenticated.descriptorSHA256 + ".json"
            )
            if let existing = try? Data(contentsOf: destination),
               SHA256Provider.hexDigest(existing) == authenticated.descriptorSHA256 {
                continue
            }
            try authenticated.exactDescriptorBytes.write(
                to: destination,
                options: .atomic
            )
        }
    }

    private nonisolated static func contractCode(_ error: Error) -> String {
        if let error = error as? ExperienceReleaseDescriptorAuthenticationError {
            return error.contractCode
        }
        if let error = error as? ExperienceReleaseAcquisitionError {
            return error.contractCode
        }
        return "experience_release.profile_entry.invalid"
    }

    private nonisolated static func resolveMemberships(
        memberships: [(ExperienceReleaseProfileEntry, ExperienceReleaseAdmissionMode)],
        definitions: [AuthenticatedExperienceReleaseDefinition]
    ) throws -> [AuthenticatedExperienceReleaseDefinition] {
        let joined = zip(memberships, definitions).map { membership, definition in
            AuthenticatedMembership(
                identity: definition.authenticatedDescriptor.descriptor.identity,
                digest: membership.0.descriptorSha256,
                definition: definition
            )
        }
        let pinnedCount = memberships.prefix { if case .pinned = $0.1 { true } else { false } }.count
        let pinned = try resolveList(Array(joined.prefix(pinnedCount)))
        let active = try resolveActiveList(Array(joined.dropFirst(pinnedCount)))
        var selected = Dictionary(uniqueKeysWithValues: pinned.map { (routeKey($0.identity), $0) })
        for item in active {
            let key = routeKey(item.identity)
            if let existing = selected[key],
               existing.identity != item.identity || existing.digest != item.digest {
                throw ExperienceReleaseAcquisitionError.invalidProfileEntry
            }
            selected[key] = item // active wins only for the exact authenticated version.
        }
        return selected.values.map(\.definition)
    }

    private nonisolated static func resolveList(
        _ memberships: [AuthenticatedMembership]
    ) throws -> [AuthenticatedMembership] {
        var byIdentity: [ExperienceReleaseIdentity: AuthenticatedMembership] = [:]
        var byRoute: [RouteKey: AuthenticatedMembership] = [:]
        for item in memberships {
            if let existing = byIdentity[item.identity] {
                guard existing.digest == item.digest else {
                    throw ExperienceReleaseAcquisitionError.invalidProfileEntry
                }
                continue // exact duplicate is harmless.
            }
            let route = routeKey(item.identity)
            if let existing = byRoute[route],
               existing.identity != item.identity || existing.digest != item.digest {
                throw ExperienceReleaseAcquisitionError.invalidProfileEntry
            }
            byIdentity[item.identity] = item
            byRoute[route] = item
        }
        return Array(byIdentity.values)
    }

    private nonisolated static func resolveActiveList(
        _ memberships: [AuthenticatedMembership]
    ) throws -> [AuthenticatedMembership] {
        var highestByStream: [ReplayStreamKey: AuthenticatedMembership] = [:]
        for item in memberships {
            let key = ReplayStreamKey(
                appId: item.identity.appId,
                environment: item.identity.environment,
                experienceId: item.identity.experienceId
            )
            guard let existing = highestByStream[key] else {
                highestByStream[key] = item
                continue
            }
            if item.identity.releaseSequence > existing.identity.releaseSequence {
                highestByStream[key] = item
            } else if item.identity.releaseSequence == existing.identity.releaseSequence,
                      item.identity != existing.identity || item.digest != existing.digest {
                throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
            }
        }
        return Array(highestByStream.values)
    }

    private nonisolated static func routeKey(_ identity: ExperienceReleaseIdentity) -> RouteKey {
        RouteKey(
            appId: identity.appId,
            environment: identity.environment,
            experienceId: identity.experienceId,
            experienceVersionId: identity.experienceVersionId
        )
    }

    private nonisolated static func validateUniqueLocalRoutes(
        _ definitions: [AuthenticatedExperienceReleaseDefinition]
    ) throws {
        var releaseByRoute: [LocalRouteKey: AuthenticatedExperienceReleaseID] = [:]
        for definition in definitions {
            let route = LocalRouteKey(
                experienceId: definition.reference.experienceId,
                experienceVersionId: definition.reference.versionId
            )
            if let existing = releaseByRoute[route], existing != definition.releaseID {
                throw ExperienceReleaseAcquisitionError.invalidProfileEntry
            }
            releaseByRoute[route] = definition.releaseID
        }
    }

    func acquire(
        entry: ExperienceReleaseProfileEntry,
        delivery: ExperienceReleaseDelivery,
        mode: ExperienceReleaseAdmissionMode,
        initialScreenID: String? = nil
    ) async throws -> AcquiredExperienceRelease {
        _ = try Self.validatedOrigin(delivery.renderBaseUrl)
        _ = try Self.validatedOrigin(delivery.assetBaseUrl)
        let authenticated = try await admission.authenticateAndAdmit(
            envelopeBytes: try entry.exactEnvelopeBytes(),
            authorizationKeys: authorizationKeys,
            expectedIdentity: Self.expectation(entry.locator),
            supportedRuntime: supportedRuntime,
            mode: mode
        )
        guard authenticated.descriptorSHA256 == entry.descriptorSha256 else {
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }

        return try await acquireAuthenticated(
            authenticated,
            delivery: delivery,
            initialScreenID: initialScreenID
        )
    }

    func acquire(
        definition: AuthenticatedExperienceReleaseDefinition,
        initialScreenID: String? = nil
    ) async throws -> AcquiredExperienceRelease {
        try await acquireAuthenticated(
            definition.authenticatedDescriptor,
            delivery: definition.delivery,
            initialScreenID: initialScreenID
        )
    }

    private func acquireAuthenticated(
        _ authenticated: AuthenticatedExperienceReleaseDescriptor,
        delivery: ExperienceReleaseDelivery,
        initialScreenID: String?
    ) async throws -> AcquiredExperienceRelease {
        let render = try Self.decode(
            ExperienceReleaseRenderDocument.self,
            from: authenticated.descriptor.render
        )
        let definition = try ExperienceDefinition(
            descriptor: authenticated.descriptor
        )
        let journey = definition.renderShell
        let selectedScreenID = try Self.selectedScreenID(
            requested: initialScreenID,
            renderScreenIDs: Set(render.screens.map(\.id)),
            journeyScreenIDs: Set(journey.screens.map(\.id))
        )
        let prepared: PreparedExperienceRelease
        do {
            prepared = try await prepareAuthenticated(
                authenticated,
                delivery: delivery,
                intent: .presentation
            )
        } catch let failure as ExperienceReleaseResourceFailure {
            throw failure.underlying
        }
        return try prepared.acquired(initialScreenID: selectedScreenID)
    }

    private nonisolated static func deviceLegRuntimeAuthority(
        _ release: AuthenticatedDeviceLegRelease
    ) throws -> RuntimeReleaseAuthority? {
        guard SHA256Provider.hexDigest(release.exactDescriptorBytes)
                == release.descriptorSHA256 else {
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
        guard let render = release.descriptor.render else {
            guard release.descriptor.leg.screens.isEmpty else {
                throw ExperienceReleaseAcquisitionError.invalidProfileEntry
            }
            return nil
        }
        let definition = try ExperienceDefinition(
            deviceLegDescriptor: release.descriptor
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
            ExperienceReleaseRenderDocument.self,
            from: authority.render
        )
        guard render.renderer == "rive" else {
            throw ExperienceReleaseAcquisitionError.invalidRuntimeBinding(
                render.renderer
            )
        }
        let journeyArtifacts = try JSONDecoder().decode(
            [ExperienceReleaseScreenBehaviorArtifactDocument].self,
            from: JSONEncoder().encode(authority.screenBehaviors)
        ).compactMap { $0.script?.artifact }
        guard Set(render.screens.map(\.id))
                == Set(authority.journey.screens.map(\.id)) else {
            throw ExperienceReleaseAcquisitionError.invalidRuntimeBinding(
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
            throw ExperienceReleaseAcquisitionError.selectedScreenNotDeclared("ambiguous")
        }
        guard renderScreenIDs.contains(selected), journeyScreenIDs.contains(selected) else {
            throw ExperienceReleaseAcquisitionError.selectedScreenNotDeclared(selected)
        }
        return selected
    }

    private func prepareAuthenticated(
        _ authenticated: AuthenticatedExperienceReleaseDescriptor,
        delivery: ExperienceReleaseDelivery,
        intent: ExperienceReleasePreparationIntent
    ) async throws -> PreparedExperienceRelease {
        let definition = try ExperienceDefinition(
            descriptor: authenticated.descriptor
        )
        let prepared = try await prepareRuntimeRelease(
            RuntimeReleaseAuthority(
                authenticatedKeyID: authenticated.authenticatedKeyID,
                identity: authenticated.descriptor.identity,
                descriptorSHA256: authenticated.descriptorSHA256,
                render: authenticated.descriptor.render,
                screenBehaviors: authenticated.descriptor.screenBehaviors,
                definition: definition,
                journey: definition.renderShell
            ),
            delivery: delivery,
            intent: intent
        )
        return PreparedExperienceRelease(
            authenticatedDescriptor: authenticated,
            payloadsByScreenID: prepared.payloadsByScreenID,
            objectURLsByKey: prepared.objectURLsByKey,
            source: prepared.source,
            resourceMetrics: prepared.resourceMetrics
        )
    }

    private func prepareRuntimeRelease(
        _ authority: RuntimeReleaseAuthority,
        delivery: ExperienceReleaseDelivery,
        intent: ExperienceReleasePreparationIntent,
        pinnedArtifacts: DeviceLegPinnedReleaseArtifacts? = nil
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

        let protectionID = try ExperienceReleaseCacheProtectionRegistry.shared.register(
            protectedDigests,
            root: cacheDirectory
        )
        defer {
            ExperienceReleaseCacheProtectionRegistry.shared.unregister(
                protectionID,
                root: cacheDirectory
            )
        }

        var objectsByDigest: [String: ObjectResult] = [:]
        var failedObjectMetrics = ExperienceReleaseResourceMetrics.zero
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
                    throw ExperienceReleaseResourceFailure(
                        underlying: underlying,
                        resourceMetrics: completedMetrics
                    )
                }
                try Task.checkCancellation()
                if let urlError = underlying as? URLError,
                   urlError.code == .cancelled {
                    throw underlying
                }
                if let acquisitionError = underlying as? ExperienceReleaseAcquisitionError,
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
            throw ExperienceReleaseAcquisitionError.requiredObjectUnavailable(
                render.riv.key
            )
        }

        let runtimeAssets = try render.assets.compactMap { asset
            -> AuthenticatedRuntimeAsset? in
            guard asset.kind == "image" || asset.kind == "font" else { return nil }
            guard let authoredID64 = asset.riveAssetId,
                  let authoredID = UInt32(exactly: authoredID64),
                  let uniqueName = asset.riveUniqueName else {
                throw ExperienceReleaseAcquisitionError.invalidRuntimeBinding(asset.key)
            }
            let object = objectsByKey[asset.key]
            guard object != nil || !asset.required else {
                throw ExperienceReleaseAcquisitionError.requiredObjectUnavailable(asset.key)
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

    func prepare(
        definition: AuthenticatedExperienceReleaseDefinition,
        intent: ExperienceReleasePreparationIntent
    ) async throws -> PreparedExperienceRelease {
        try await prepareAuthenticated(
            definition.authenticatedDescriptor,
            delivery: definition.delivery,
            intent: intent
        )
    }

    func presentationArtifact(
        definition: AuthenticatedExperienceReleaseDefinition,
        initialScreenID: String
    ) async throws -> AcquiredExperienceArtifact {
        guard definition.screenIDs.contains(initialScreenID) else {
            throw ExperienceReleaseAcquisitionError.selectedScreenNotDeclared(
                initialScreenID
            )
        }
        let prepared: PreparedExperienceRelease
        do {
            prepared = try await prepare(
                definition: definition,
                intent: .presentation
            )
        } catch let failure as ExperienceReleaseResourceFailure {
            throw failure.underlying
        }
        return try prepared.presentationArtifact(
            identity: .init(
                experienceId: definition.reference.experienceId,
                buildId: definition.behavior.buildId
            ),
            initialScreenID: initialScreenID
        )
    }

    /// Prepares a partitioned Journey release without manufacturing a legacy
    /// full-release descriptor. The authenticated device release remains the
    /// sole authority for both behavior and renderer bytes.
    func preparePresentation(
        release: AuthenticatedDeviceLegRelease,
        delivery: ExperienceReleaseDelivery,
        pinnedArtifacts: DeviceLegPinnedReleaseArtifacts? = nil,
        productResolver:
            @escaping @Sendable (String) async throws -> [StoreProduct]
    ) async throws -> PreparedDeviceLegPresentation {
        guard let authority = try Self.deviceLegRuntimeAuthority(release) else {
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
        let definition = authority.definition
        let journey = authority.journey
        let render = try Self.decode(
            ExperienceReleaseRenderDocument.self,
            from: authority.render
        )
        let renderScreenIDs = Set(render.screens.map(\.id))
        let journeyScreenIDs = Set(journey.screens.map(\.id))
        let identity = AcquiredExperienceArtifact.Identity(
            experienceId: release.descriptor.identity.experienceId,
            buildId: release.descriptor.identity.buildId
        )
        let provenance = release.descriptorSHA256
        let experience = try Self.deviceLegExperience(
            release: release,
            delivery: delivery,
            definition: definition,
            journey: journey,
            render: render
        )
        return PreparedDeviceLegPresentation(
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
        _ artifact: ExperienceReleaseRenderDocument.Artifact,
        origin: URL,
        intent: ExperienceReleasePreparationIntent,
        protectedDigests: Set<String>,
        pinnedArtifacts: DeviceLegPinnedReleaseArtifacts?
    ) async throws -> ObjectResult {
        let destination = cacheDirectory.appendingPathComponent(artifact.sha256)
        let result = try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: destination,
            lockScope: cacheLockScope
        ) {
            var rejectedCacheMetrics = ExperienceReleaseResourceMetrics.zero
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
                        rejectedCacheMetrics = ExperienceReleaseResourceMetrics(
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
                            throw ExperienceReleaseAcquisitionError.redirectEscapedOrigin(
                                response.url?.absoluteString ?? "missing"
                            )
                        }
                        let expected = artifact.contentType
                            .split(separator: ";", maxSplits: 1)[0]
                            .trimmingCharacters(in: .whitespaces)
                            .lowercased()
                        guard let mime = response.mimeType?.lowercased(),
                              mime == expected else {
                            throw ExperienceReleaseAcquisitionError.objectContentTypeMismatch(
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
                    throw ExperienceReleaseAcquisitionError.objectSizeMismatch(
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
                    throw ExperienceReleaseAcquisitionError.objectDigestMismatch(
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
                    throw ExperienceReleaseAcquisitionError.objectSizeMismatch(
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
                    ExperienceReleaseResourceMetrics(
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
                ExperienceReleaseCacheProtectionRegistry.shared.protectedDigests(
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
    ) -> ExperienceReleaseResourceMetrics {
        let totalBytes = byteCount * passCount
        let duplicateBytes = byteCount * max(0, passCount - 1)
        return ExperienceReleaseResourceMetrics(
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
        var byKey: [String: ExperienceReleaseRenderDocument.Artifact] = [:]
        for requirement in requirements {
            let artifact = requirement.artifact
            if let existing = byKey[artifact.key] {
                guard existing == artifact else {
                    throw ExperienceReleaseAcquisitionError.invalidProfileEntry
                }
            } else {
                byKey[artifact.key] = artifact
            }
            if let existing = byDigest[artifact.sha256] {
                guard existing.artifact == artifact else {
                    throw ExperienceReleaseAcquisitionError.invalidProfileEntry
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
        guard total <= ExperienceReleaseDescriptorLimits.artifactAggregateBytes else {
            throw ExperienceReleaseAcquisitionError.aggregateLimitExceeded
        }
        return byDigest.values.sorted { $0.artifact.key < $1.artifact.key }
    }

    private nonisolated static func verify(
        _ digest: BoundedFileDigest,
        artifact: ExperienceReleaseRenderDocument.Artifact
    ) throws {
        guard digest.byteCount == artifact.sizeBytes else {
            throw ExperienceReleaseAcquisitionError.objectSizeMismatch(
                key: artifact.key,
                expected: artifact.sizeBytes,
                actual: digest.byteCount
            )
        }
        guard digest.sha256 == artifact.sha256 else {
            throw ExperienceReleaseAcquisitionError.objectDigestMismatch(
                key: artifact.key,
                expected: artifact.sha256,
                actual: digest.sha256
            )
        }
    }

    private nonisolated static func limit(
        for artifact: ExperienceReleaseRenderDocument.Artifact
    ) -> Int {
        artifact.key.hasPrefix("renders/")
            ? ExperienceReleaseDescriptorLimits.rivArtifactBytes
            : ExperienceReleaseDescriptorLimits.externalAssetBytes
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
            throw ExperienceReleaseAcquisitionError.invalidDeliveryOrigin(value)
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
            throw ExperienceReleaseAcquisitionError.invalidDeliveryOrigin(
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
        from object: [String: ExperienceReleaseJSONValue]
    ) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(object))
    }

    private nonisolated static func expectation(
        _ identity: ExperienceReleaseIdentity
    ) -> ExperienceReleaseIdentityExpectation {
        ExperienceReleaseIdentityExpectation(
            appId: identity.appId,
            environment: identity.environment,
            experienceId: identity.experienceId,
            experienceVersionId: identity.experienceVersionId,
            buildId: identity.buildId,
            versionNumber: identity.versionNumber,
            releaseCreatedAt: identity.releaseCreatedAt,
            releaseSequence: identity.releaseSequence
        )
    }

    private nonisolated static func deviceLegExperience(
        release: AuthenticatedDeviceLegRelease,
        delivery: ExperienceReleaseDelivery,
        definition: ExperienceDefinition,
        journey: JourneyDocument,
        render: ExperienceReleaseRenderDocument
    ) throws -> Experience {
        let descriptor = release.descriptor
        let metadata = try decode(
            ExperienceReleaseMetadataDocument.self,
            from: descriptor.metadata
        )
        let presentation = try decode(
            ExperienceReleasePresentationDocument.self,
            from: descriptor.presentation
        )
        let reentry: ExperienceReentry
        switch descriptor.leg.reentry.type {
        case .oneTime:
            reentry = .oneTime
        case .everyTime:
            reentry = .everyTime
        case .oncePerWindow:
            guard let seconds = descriptor.leg.reentry.windowSeconds else {
                throw ExperienceReleaseAcquisitionError.invalidProfileEntry
            }
            reentry = .oncePerWindow(.init(amount: seconds, unit: .second))
        }
        let identity = descriptor.identity
        let behavior = ExperienceBehaviorDefinition(
            reference: .init(
                experienceId: identity.experienceId,
                versionId: identity.experienceVersionId
            ),
            buildId: identity.buildId,
            artifactContentHash: render.riv.sha256,
            name: metadata.name,
            reentry: reentry,
            publishedAt: identity.publishedAt,
            trigger: nil,
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            timeLimitSeconds: nil,
            experienceType: metadata.experienceType,
            presentation: try presentation.behaviorPresentation(),
            presentationScreens: Dictionary(
                uniqueKeysWithValues: render.screens.map {
                    (
                        $0.id,
                        ExperienceBehaviorScreenGeometry(
                            width: $0.width,
                            height: $0.height
                        )
                    )
                }
            )
        )
        return Experience(
            behavior: behavior,
            journey: journey,
            definition: definition,
            assetBaseURL: try validatedOrigin(delivery.assetBaseUrl),
            authenticatedReleaseID: .init(
                identity: identity,
                descriptorSHA256: release.descriptorSHA256
            )
        )
    }

    private nonisolated static func definition(
        entry: ExperienceReleaseProfileEntry,
        delivery: ExperienceReleaseDelivery,
        mode: ExperienceReleaseAdmissionMode,
        authenticated: AuthenticatedExperienceReleaseDescriptor
    ) throws -> AuthenticatedExperienceReleaseDefinition {
        guard authenticated.descriptorSHA256 == entry.descriptorSha256 else {
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
        let descriptor = authenticated.descriptor
        let metadata = try decode(
            ExperienceReleaseMetadataDocument.self,
            from: descriptor.metadata
        )
        let enrollment = try decode(
            ExperienceReleaseEnrollmentDocument.self,
            from: descriptor.enrollment
        )
        let lifecycle = try decode(
            ExperienceReleaseLifecycleDocument.self,
            from: descriptor.lifecycle
        )
        let presentation = try decode(
            ExperienceReleasePresentationDocument.self,
            from: descriptor.presentation
        )
        let render = try decode(
            ExperienceReleaseRenderDocument.self,
            from: descriptor.render
        )
        let definition = try ExperienceDefinition(descriptor: descriptor)
        let journey = definition.renderShell
        guard Self.hasValidPrePresentationProgram(
            definition,
            render: render,
            enrollmentEventName: enrollment.trigger.eventName
        ) else {
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
        let products = try JSONDecoder().decode(
            [ExperienceReleaseProductDocument].self,
            from: JSONEncoder().encode(descriptor.products)
        )
        let placements = try JSONDecoder().decode(
            [ExperienceReleasePlacementDocument].self,
            from: JSONEncoder().encode(descriptor.placements)
        )
        try validatePurchasePlacements(in: definition, placements: placements)
        guard render.renderer == "rive" else {
            throw ExperienceReleaseAcquisitionError.invalidRuntimeBinding("release")
        }
        let trigger: ExperienceTrigger?
        switch enrollment.trigger.type {
        case "event":
            guard let eventName = enrollment.trigger.eventName else {
                throw ExperienceReleaseAcquisitionError.invalidProfileEntry
            }
            let condition = try enrollment.trigger.condition.map {
                try JSONDecoder().decode(IREnvelope.self, from: JSONEncoder().encode($0))
            }
            trigger = .event(.init(eventName: eventName, condition: condition))
        case "segment", "server_event", "api":
            // These releases are authenticated behavior authorities but are
            // started by server enrollment/mailbox orchestration, never by a
            // client-side trigger evaluation.
            trigger = nil
        default:
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
        let behaviorPresentation = try presentation.behaviorPresentation()
        let reentry: ExperienceReentry
        switch lifecycle.reentry.type {
        case "one_time": reentry = .oneTime
        case "every_time": reentry = .everyTime
        case "once_per_window":
            guard let seconds = lifecycle.reentry.windowSeconds else {
                throw ExperienceReleaseAcquisitionError.invalidProfileEntry
            }
            reentry = .oncePerWindow(.init(amount: seconds, unit: .second))
        default: throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
        let exitMode = ExitPolicy.Mode(rawValue: lifecycle.exitPolicy)
        let goal = try lifecycle.goal.map(goalConfig)
        let conversionAnchor: String
        switch lifecycle.conversionAnchor {
        case "journey_start", "last_experience_shown", "last_experience_interaction":
            conversionAnchor = lifecycle.conversionAnchor
        default: throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
        let identity = descriptor.identity
        let behavior = ExperienceBehaviorDefinition(
            reference: .init(
                experienceId: identity.experienceId,
                versionId: identity.experienceVersionId
            ),
            buildId: identity.buildId,
            artifactContentHash: render.riv.sha256,
            name: metadata.name,
            reentry: reentry,
            releaseCreatedAt: identity.releaseCreatedAt,
            trigger: trigger,
            goal: goal,
            exitPolicy: exitMode.map(ExitPolicy.init(mode:)),
            conversionAnchor: conversionAnchor,
            timeLimitSeconds: lifecycle.timeLimitSeconds,
            experienceType: metadata.experienceType,
            presentation: behaviorPresentation,
            presentationScreens: Dictionary(
                uniqueKeysWithValues: render.screens.map {
                    (
                        $0.id,
                        ExperienceBehaviorScreenGeometry(
                            width: $0.width,
                            height: $0.height
                        )
                    )
                }
            )
        )
        return AuthenticatedExperienceReleaseDefinition(
            releaseID: .init(
                identity: identity,
                descriptorSHA256: authenticated.descriptorSHA256
            ),
            authenticatedDescriptor: authenticated,
            delivery: delivery,
            mode: mode,
            behavior: behavior,
            journey: journey,
            definition: definition,
            screenIDs: Set(render.screens.map(\.id)),
            products: products,
            placements: placements
        )
    }

    private nonisolated static func validatePurchasePlacements(
        in definition: ExperienceDefinition,
        placements: [ExperienceReleasePlacementDocument]
    ) throws {
        let declared = Set(placements.map(\.id))
        func validate(_ values: [ExperienceReleaseJSONValue]) throws {
            for value in values {
                guard case .object(let action) = value else { continue }
                if case .string("purchase") = action["type"],
                   case .string(let placementId) = action["placementId"],
                   !declared.contains(placementId) {
                    throw ExperienceReleaseAcquisitionError.invalidProfileEntry
                }
                for nested in action.values {
                    if case .array(let values) = nested { try validate(values) }
                }
            }
        }
        for route in definition.routes.values { try validate(route.program) }
    }

    private nonisolated static func hasValidPrePresentationProgram(
        _ definition: ExperienceDefinition,
        render: ExperienceReleaseRenderDocument,
        enrollmentEventName: String?
    ) -> Bool {
        let eventNames = [
            definition.entryRouteEventName,
            enrollmentEventName,
            SystemEventNames.appOpened,
        ].compactMap { $0 }
        let renderScreens = Set(render.screens.map(\.id))
        for eventName in eventNames {
            guard let route = definition.route(host: .journey, eventName: eventName) else {
                continue
            }
            if programCanSelectRenderedScreen(route.program, renderScreens: renderScreens) {
                return true
            }
        }
        return false
    }

    private nonisolated static func programCanSelectRenderedScreen(
        _ program: [ExperienceReleaseJSONValue],
        renderScreens: Set<String>
    ) -> Bool {
        for value in program {
            guard case .object(let action) = value,
                  case .string(let type) = action["type"] else { return false }
            if type == "navigate",
               case .string(let screenId) = action["screenId"],
               renderScreens.contains(screenId) {
                return true
            }
            for field in [
                "onInside", "onSatisfied", "onTimeout", "defaultProgram",
                "onAvailable", "onUnavailable", "onCompleted", "onFailed",
                "onCancelled", "onRestored", "onNoPurchases", "onSucceeded",
            ] {
                if case .array(let nested) = action[field],
                   programCanSelectRenderedScreen(nested, renderScreens: renderScreens) {
                    return true
                }
            }
            for field in ["branches", "variants"] {
                guard case .array(let entries) = action[field] else { continue }
                for entry in entries {
                    if case .object(let object) = entry,
                       case .array(let nested) = object["program"],
                       programCanSelectRenderedScreen(nested, renderScreens: renderScreens) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private nonisolated static func goalConfig(
        _ goal: ExperienceReleaseLifecycleDocument.Goal
    ) throws -> GoalConfig {
        let condition = try goal.condition.map {
            try JSONDecoder().decode(IREnvelope.self, from: JSONEncoder().encode($0))
        }
        let expression = try goal.expression.map {
            try JSONDecoder().decode(IREnvelope.self, from: JSONEncoder().encode($0))
        }
        switch goal.type {
        case "event":
            return GoalConfig(
                kind: .event,
                eventName: goal.eventName,
                eventFilter: condition,
                window: goal.windowSeconds.map(TimeInterval.init)
            )
        case "milestone":
            return GoalConfig(
                kind: .milestone,
                milestoneId: goal.milestoneId,
                window: goal.windowSeconds.map(TimeInterval.init)
            )
        case "segment_enter", "segment_leave":
            return GoalConfig(
                kind: goal.type == "segment_enter" ? .segmentEnter : .segmentLeave,
                segmentId: goal.segmentId,
                window: goal.windowSeconds.map(TimeInterval.init)
            )
        case "attribute":
            return GoalConfig(
                kind: .attribute,
                attributeExpr: expression,
                window: goal.windowSeconds.map(TimeInterval.init)
            )
        default:
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
    }

    private nonisolated static func runtimePlan(
        identity: ExperienceReleaseIdentity,
        render: ExperienceReleaseRenderDocument,
        initialScreenID: String
    ) throws -> NativeExperienceRenderPlan {
        let images = try render.assets.filter { $0.kind == "image" }.map {
            guard let id = $0.riveAssetId, let name = $0.riveUniqueName else {
                throw ExperienceReleaseAcquisitionError.invalidRuntimeBinding($0.key)
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
                throw ExperienceReleaseAcquisitionError.invalidRuntimeBinding($0.key)
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
