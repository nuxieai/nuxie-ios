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
        products: [ExperienceProduct] = [],
        productsResolvedForScreenID: String? = nil,
        resourceMetrics suppliedResourceMetrics: ExperienceReleaseResourceMetrics? = nil,
        productResolver: (@Sendable (String) async throws -> [ExperienceProduct])? = nil
    ) throws -> AcquiredExperienceArtifact {
        let acquired = try acquired(initialScreenID: initialScreenID)
        let assetURLs = Dictionary(uniqueKeysWithValues: acquired.payload.assets.compactMap {
            asset in acquired.objectURLsByKey[asset.sourceKey].map {
                (asset.riveUniqueName, $0)
            }
        })
        guard let sceneURL = acquired.objectURLsByKey[
            acquired.payload.renderPlan.scene.key
        ] else {
            throw ExperienceReleaseAcquisitionError.requiredObjectUnavailable(
                acquired.payload.renderPlan.scene.key
            )
        }
        let interactivePreparation = suppliedPreparation
            ?? ExperienceInteractivePreparationHandle(
                cache: ExperienceInteractivePreparationCache(),
                provenance: authenticatedDescriptor.descriptorSHA256,
                payload: acquired.payload
            )
        return AcquiredExperienceArtifact(
            identity: identity,
            sceneURL: sceneURL,
            sceneBytes: acquired.payload.sceneBytes,
            assetURLsByRiveUniqueName: assetURLs,
            source: acquired.source,
            payload: acquired.payload,
            interactivePreparation: interactivePreparation,
            products: products,
            productsResolvedForScreenID: productsResolvedForScreenID,
            resourceMetrics: suppliedResourceMetrics ?? resourceMetrics,
            productResolver: productResolver
        )
    }
}

struct AuthenticatedExperienceReleaseID: Codable, Equatable, Hashable, Sendable {
    let identity: ExperienceReleaseIdentityV1
    let descriptorSHA256: String
}

struct AuthenticatedExperienceReleaseDefinition: Sendable {
    let releaseID: AuthenticatedExperienceReleaseID
    let authenticatedDescriptor: AuthenticatedExperienceReleaseDescriptor
    let delivery: ExperienceReleaseDeliveryV1
    let mode: ExperienceReleaseAdmissionMode
    let behavior: ExperienceBehaviorDefinition
    let journey: JourneyDocument
    let screenIDs: Set<String>
    let appleProductIDs: [String]

    var reference: ExperienceReference { behavior.reference }
}

struct AuthenticatedExperienceReleaseCatalog: Sendable {
    let definitions: [AuthenticatedExperienceReleaseDefinition]
    let rejections: [ExperienceReleaseRejection]
    var references: [ExperienceReference] { definitions.map(\.reference) }
}

struct ExperienceReleaseRejection: Sendable {
    let locator: ExperienceReleaseIdentityV1
    let contractCode: String
}

struct ExperienceReleaseRuntimeCompatibility {
    /// Derived from the runtime module's single compatibility authority.
    static let current = ExperienceReleaseSupportedCompatibility(
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

private struct ExperienceReleaseCompatibilityDocument: Decodable {
    struct Luau: Decodable {
        let revision: String
        let bytecodeVersions: [Int]
    }
    struct SceneFormat: Decodable {
        let major: Int
        let minor: Int
    }

    let minimumSdkVersion: String
    let runtimeRevision: String
    let luau: Luau
    let sceneFormat: SceneFormat
    let requiredCapabilities: [String]
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

private struct ExperienceReleaseProductDocument: Decodable {
    let id: String
    let platform: String
}

private struct ExperienceReleasePresentationDocument: Decodable {
    struct Loading: Decodable {
        let style: ExperienceBehaviorLoadingStyle
        let backgroundColor: String
    }

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
    let loading: Loading
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
            loading: .init(
                style: loading.style,
                backgroundColor: loading.backgroundColor
            ),
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
        _ profile: ExperienceReleaseProfileV1
    ) async throws -> AuthenticatedExperienceReleaseCatalog

    func prepare(
        definition: AuthenticatedExperienceReleaseDefinition,
        intent: ExperienceReleasePreparationIntent
    ) async throws -> PreparedExperienceRelease
}

enum ExperienceReleasePreparationIntent: Equatable, Sendable {
    case preload
    case presentation

    var allowsConstrainedNetworkAccess: Bool {
        self == .presentation
    }
}

extension ExperienceReleaseAcquiring {
    func prepare(
        definition: AuthenticatedExperienceReleaseDefinition
    ) async throws -> PreparedExperienceRelease {
        try await prepare(definition: definition, intent: .presentation)
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
        let identity: ExperienceReleaseIdentityV1
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

    private let cacheDirectory: URL
    private let cacheLockScope: CacheFilesystemLockScope
    private let maximumCacheBytes: Int
    private let urlSession: URLSession
    private let authorizationKeys: [ExperiencePackageAuthorizationKey]
    private let supportedCompatibility: ExperienceReleaseSupportedCompatibility
    private let admission: ExperienceReleaseAdmission

    init(
        cacheDirectory: URL? = nil,
        maximumCacheBytes: Int = 256 * 1_024 * 1_024,
        urlSession: URLSession = .shared,
        authorizationKeys: [ExperiencePackageAuthorizationKey],
        supportedCompatibility: ExperienceReleaseSupportedCompatibility,
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
        self.supportedCompatibility = supportedCompatibility
        self.admission = admission
    }

    func authenticateProfile(
        _ profile: ExperienceReleaseProfileV1
    ) async throws -> AuthenticatedExperienceReleaseCatalog {
        _ = try Self.validatedOrigin(profile.delivery.renderBaseUrl)
        _ = try Self.validatedOrigin(profile.delivery.assetBaseUrl)
        let memberships: [(ExperienceReleaseProfileEntryV1, ExperienceReleaseAdmissionMode)] =
            profile.pinned.map {
                ($0, .pinned(
                    experienceVersionId: $0.locator.experienceVersionId,
                    buildId: $0.locator.buildId,
                    descriptorSHA256: $0.descriptorSha256
                ))
            } + profile.active.map { ($0, .active) }
        var acceptedMemberships: [
            (ExperienceReleaseProfileEntryV1, ExperienceReleaseAdmissionMode)
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
                    supportedCompatibility: supportedCompatibility,
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
        memberships: [(ExperienceReleaseProfileEntryV1, ExperienceReleaseAdmissionMode)],
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
        var byIdentity: [ExperienceReleaseIdentityV1: AuthenticatedMembership] = [:]
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
            if item.identity.publishedAtSeq > existing.identity.publishedAtSeq {
                highestByStream[key] = item
            } else if item.identity.publishedAtSeq == existing.identity.publishedAtSeq,
                      item.identity != existing.identity || item.digest != existing.digest {
                throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
            }
        }
        return Array(highestByStream.values)
    }

    private nonisolated static func routeKey(_ identity: ExperienceReleaseIdentityV1) -> RouteKey {
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
        entry: ExperienceReleaseProfileEntryV1,
        delivery: ExperienceReleaseDeliveryV1,
        mode: ExperienceReleaseAdmissionMode,
        initialScreenID: String? = nil
    ) async throws -> AcquiredExperienceRelease {
        _ = try Self.validatedOrigin(delivery.renderBaseUrl)
        _ = try Self.validatedOrigin(delivery.assetBaseUrl)
        let authenticated = try await admission.authenticateAndAdmit(
            envelopeBytes: try entry.exactEnvelopeBytes(),
            authorizationKeys: authorizationKeys,
            expectedIdentity: Self.expectation(entry.locator),
            supportedCompatibility: supportedCompatibility,
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
        delivery: ExperienceReleaseDeliveryV1,
        initialScreenID: String?
    ) async throws -> AcquiredExperienceRelease {
        let render = try Self.decode(
            ExperienceReleaseRenderDocument.self,
            from: authenticated.descriptor.render
        )
        let journey = try Self.decode(
            JourneyDocument.self,
            from: authenticated.descriptor.journey
        )
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
        delivery: ExperienceReleaseDeliveryV1,
        intent: ExperienceReleasePreparationIntent
    ) async throws -> PreparedExperienceRelease {
        let renderOrigin = try Self.validatedOrigin(delivery.renderBaseUrl)
        let assetOrigin = try Self.validatedOrigin(delivery.assetBaseUrl)

        let render = try Self.decode(
            ExperienceReleaseRenderDocument.self,
            from: authenticated.descriptor.render
        )
        guard render.renderer == "rive" else {
            throw ExperienceReleaseAcquisitionError.invalidRuntimeBinding(render.renderer)
        }
        let journey = try Self.decode(
            JourneyDocument.self,
            from: authenticated.descriptor.journey
        )
        // Standalone script artifacts are signed publication/integrity
        // evidence and are therefore always acquired and verified. Authored
        // listener bytecode executes from the ScriptAsset and
        // ScriptedListenerAction embedded in the authenticated RIV scene; it
        // must not be introduced as a second runtime execution input here.
        let journeyArtifacts = try Self.decode(
            ExperienceReleaseJourneyArtifactDocument.self,
            from: authenticated.descriptor.journey
        ).scripts.values.flatMap { $0 }.compactMap(\.artifact)
        let renderScreenIDs = Set(render.screens.map(\.id))
        let journeyScreenIDs = Set(journey.screens.map(\.id))
        guard renderScreenIDs == journeyScreenIDs else {
            throw ExperienceReleaseAcquisitionError.invalidRuntimeBinding(
                "screen_catalog"
            )
        }

        let requirements =
            [ArtifactRequirement(artifact: render.riv, required: true)]
            + render.assets.map {
                ArtifactRequirement(artifact: $0.artifact, required: $0.required)
            }
            + journeyArtifacts.map {
                ArtifactRequirement(artifact: $0, required: true)
            }
        let uniqueRequirements = try Self.uniqueArtifacts(requirements)
        let protectedDigests = Set(uniqueRequirements.map(\.artifact.sha256))

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
                    protectedDigests: protectedDigests
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
        for requirement in requirements {
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
                authenticated: authenticated,
                render: render,
                initialScreenID: screen.id
            )
            return (screen.id, AuthenticatedRuntimePayload(
                authenticatedKeyID: authenticated.authenticatedKeyID,
                renderPlan: renderPlan,
                journey: journey,
                sceneBytes: scene.bytes,
                assets: runtimeAssets
            ))
        })
        return PreparedExperienceRelease(
            authenticatedDescriptor: authenticated,
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

    private func acquireObject(
        _ artifact: ExperienceReleaseRenderDocument.Artifact,
        origin: URL,
        intent: ExperienceReleasePreparationIntent,
        protectedDigests: Set<String>
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
        _ identity: ExperienceReleaseIdentityV1
    ) -> ExperienceReleaseIdentityExpectation {
        ExperienceReleaseIdentityExpectation(
            appId: identity.appId,
            environment: identity.environment,
            experienceId: identity.experienceId,
            experienceVersionId: identity.experienceVersionId,
            buildId: identity.buildId,
            versionNumber: identity.versionNumber,
            publishedAt: identity.publishedAt,
            publishedAtSeq: identity.publishedAtSeq
        )
    }

    private nonisolated static func definition(
        entry: ExperienceReleaseProfileEntryV1,
        delivery: ExperienceReleaseDeliveryV1,
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
        let journey = try decode(JourneyDocument.self, from: descriptor.journey)
        guard Self.hasValidPrePresentationProgram(
            journey,
            render: render,
            enrollmentEventName: enrollment.trigger.eventName
        ) else {
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
        let products = try JSONDecoder().decode(
            [ExperienceReleaseProductDocument].self,
            from: JSONEncoder().encode(descriptor.products)
        )
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
        case "journey_start": conversionAnchor = "journey_start"
        case "last_experience_shown": conversionAnchor = "last_flow_shown"
        case "last_experience_interaction": conversionAnchor = "last_flow_interaction"
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
            publishedAt: identity.publishedAt,
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
            screenIDs: Set(render.screens.map(\.id)),
            appleProductIDs: products.compactMap {
                $0.platform == "apple_app_store" ? $0.id : nil
            }
        )
    }

    private nonisolated static func hasValidPrePresentationProgram(
        _ journey: JourneyDocument,
        render: ExperienceReleaseRenderDocument,
        enrollmentEventName: String?
    ) -> Bool {
        let handlers = (journey.handlers[JourneyDocument.journeyEventHostKey] ?? [])
            .enumerated().sorted { lhs, rhs in
                let left = lhs.element.order ?? lhs.offset
                let right = rhs.element.order ?? rhs.offset
                return left == right ? lhs.offset < rhs.offset : left < right
            }.map(\.element)
        let enabledNames = Set(handlers.filter { $0.enabled != false }.map(\.eventName))
        let entryName: String? = enabledNames.contains(SystemEventNames.journeyStarted)
            ? SystemEventNames.journeyStarted
            : enrollmentEventName.flatMap { enabledNames.contains($0) ? $0 : nil }
                ?? (enabledNames.contains(SystemEventNames.appOpened)
                    ? SystemEventNames.appOpened : nil)
        var rootNames = Set(
            (journey.events[JourneyDocument.journeyEventHostKey] ?? [])
                .map(\.eventName)
                .filter {
                    $0 != SystemEventNames.screenShown
                        && $0 != SystemEventNames.screenDismissed
                }
        )
        if let entryName { rootNames.insert(entryName) }
        let screens = Set(journey.screens.map(\.id))
            .intersection(render.screens.map(\.id))
        guard !screens.isEmpty else { return false }
        for eventName in rootNames {
            let actions = handlers.filter {
                $0.enabled != false && $0.eventName == eventName
            }.flatMap(\.actions)
            guard prePresentationSequenceIsValid(actions, screens: screens) else {
                return false
            }
        }
        return (journey.deviceRegions ?? []).allSatisfy {
            prePresentationSequenceIsValid($0.actions, screens: screens)
        }
    }

    private nonisolated static func prePresentationSequenceIsValid(
        _ actions: [JourneyAction],
        screens: Set<String>
    ) -> Bool {
        guard let first = actions.first else { return true }
        let rest = Array(actions.dropFirst())
        switch first {
        case .navigate(let navigate):
            return screens.contains(navigate.screenId)
        case .exit, .handoff:
            return true
        case .delay:
            return prePresentationSequenceIsValid(rest, screens: screens)
        case .condition(let condition):
            for branch in condition.branches {
                guard prePresentationSequenceIsValid(
                    branch.actions + rest,
                    screens: screens
                ) else { return false }
                if branch.condition == nil { return true }
            }
            return prePresentationSequenceIsValid(
                (condition.defaultActions ?? []) + rest,
                screens: screens
            )
        case .timeWindow(let window):
            return prePresentationSequenceIsValid(
                (window.successActions ?? []) + rest,
                screens: screens
            )
        case .waitUntil(let wait):
            guard prePresentationSequenceIsValid(
                (wait.successActions ?? []) + rest,
                screens: screens
            ) else { return false }
            if wait.condition != nil, wait.maxTimeMs != nil {
                return prePresentationSequenceIsValid(
                    (wait.timeoutActions ?? []) + rest,
                    screens: screens
                )
            }
            return true
        default:
            return false
        }
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
        authenticated: AuthenticatedExperienceReleaseDescriptor,
        render: ExperienceReleaseRenderDocument,
        initialScreenID: String
    ) throws -> NativeExperienceRenderPlan {
        let descriptor = authenticated.descriptor
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
                experienceId: descriptor.identity.experienceId,
                buildId: descriptor.identity.buildId,
                appId: descriptor.identity.appId,
                environment: descriptor.identity.environment
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
