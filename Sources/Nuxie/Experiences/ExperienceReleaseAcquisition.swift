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
    let source: ExperiencePackageSource
}

struct AuthenticatedExperienceReleaseID: Equatable, Hashable, Sendable {
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
    let appleProductIDs: [String]

    var reference: ExperienceReference { behavior.reference }
}

struct AuthenticatedExperienceReleaseCatalog: Sendable {
    let definitions: [AuthenticatedExperienceReleaseDefinition]
    var references: [ExperienceReference] { definitions.map(\.reference) }
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
    let style: String
}

protocol ExperienceReleaseAcquiring: Sendable {
    func authenticateProfile(
        _ profile: ExperienceReleaseProfileV1
    ) async throws -> AuthenticatedExperienceReleaseCatalog

    func presentationPackage(
        definition: AuthenticatedExperienceReleaseDefinition
    ) async throws -> AcquiredExperiencePackage
}

/// Authenticates a profile release before looking at behavior or object keys,
/// acquires every signed render object into a digest-addressed cache, and
/// produces the input already consumed by `NuxieNativeRuntime`.
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
    }

    private struct ArtifactRequirement {
        let artifact: ExperienceReleaseRenderDocument.Artifact
        let required: Bool
    }

    private let cacheDirectory: URL
    private let cacheLockScope: CacheFilesystemLockScope
    private let urlSession: URLSession
    private let authorizationKeys: [ExperiencePackageAuthorizationKey]
    private let supportedCompatibility: ExperienceReleaseSupportedCompatibility
    private let admission: ExperienceReleaseAdmission

    init(
        cacheDirectory: URL? = nil,
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
        let candidates = try memberships.map { entry, mode in
            ExperienceReleaseAdmission.Candidate(
                envelopeBytes: try entry.exactEnvelopeBytes(),
                authorizationKeys: authorizationKeys,
                expectedIdentity: Self.expectation(entry.locator),
                supportedCompatibility: supportedCompatibility,
                mode: mode
            )
        }
        let batch = try await admission.authenticate(candidates)
        let definitions = try zip(memberships, batch.descriptors).map {
            membership, authenticated in
            try Self.definition(
                entry: membership.0,
                delivery: profile.delivery,
                mode: membership.1,
                authenticated: authenticated
            )
        }
        let resolved = try Self.resolveMemberships(
            memberships: memberships,
            definitions: definitions
        )
        try Self.validateUniqueLocalRoutes(resolved)
        try await admission.commit(batch)
        return AuthenticatedExperienceReleaseCatalog(
            definitions: resolved.sorted {
                if $0.reference.experienceId != $1.reference.experienceId {
                    return $0.reference.experienceId < $1.reference.experienceId
                }
                return $0.reference.versionId < $1.reference.versionId
            }
        )
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
                throw ExperienceReleaseAcquisitionError.invalidProfileEntry
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
        let renderOrigin = try Self.validatedOrigin(delivery.renderBaseUrl)
        let assetOrigin = try Self.validatedOrigin(delivery.assetBaseUrl)

        let render = try Self.decode(
            ExperienceReleaseRenderDocument.self,
            from: authenticated.descriptor.render
        )
        guard render.renderer == "rive" else {
            throw ExperienceReleaseAcquisitionError.invalidRuntimeBinding(render.renderer)
        }
        let selectedScreenID: String
        if let initialScreenID {
            selectedScreenID = initialScreenID
        } else if render.screens.count == 1, let only = render.screens.first {
            // UNIV-2065 owns pre-mount conditional journey entry resolution.
            // Until then, only an unambiguous one-screen release may mount.
            selectedScreenID = only.id
        } else {
            throw ExperienceReleaseAcquisitionError.selectedScreenNotDeclared("ambiguous")
        }
        guard render.screens.contains(where: { $0.id == selectedScreenID }) else {
            throw ExperienceReleaseAcquisitionError.selectedScreenNotDeclared(
                selectedScreenID
            )
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
        guard journey.screens.contains(where: { $0.id == selectedScreenID }) else {
            throw ExperienceReleaseAcquisitionError.selectedScreenNotDeclared(
                selectedScreenID
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

        // Validate every signed object key before optionality is considered.
        // Optional means a safe acquisition failure may omit bytes; it never
        // permits an unsafe key or delivery-origin escape to be ignored.
        for requirement in uniqueRequirements {
            let artifact = requirement.artifact
            let origin = artifact.key.hasPrefix("renders/") ? renderOrigin : assetOrigin
            _ = try Self.compose(artifact.key, relativeTo: origin)
        }

        var objectsByDigest: [String: ObjectResult] = [:]
        var downloadedAny = false
        for requirement in uniqueRequirements {
            let artifact = requirement.artifact
            let origin = artifact.key.hasPrefix("renders/") ? renderOrigin : assetOrigin
            do {
                let result = try await acquireObject(artifact, origin: origin)
                objectsByDigest[artifact.sha256] = result
                downloadedAny = downloadedAny || result.downloaded
            } catch {
                guard !requirement.required else { throw error }
                try Task.checkCancellation()
                if let urlError = error as? URLError,
                   urlError.code == .cancelled {
                    throw error
                }
                if let acquisitionError = error as? ExperienceReleaseAcquisitionError,
                   case .redirectEscapedOrigin = acquisitionError {
                    throw error
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

        let renderPlan = try Self.runtimePlan(
            authenticated: authenticated,
            render: render,
            initialScreenID: selectedScreenID
        )
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
        let payload = AuthenticatedRuntimePayload(
            authenticatedKeyID: authenticated.authenticatedKeyID,
            renderPlan: renderPlan,
            journey: journey,
            sceneBytes: scene.bytes,
            assets: runtimeAssets
        )
        return AcquiredExperienceRelease(
            authenticatedDescriptor: authenticated,
            payload: payload,
            objectURLsByKey: objectsByKey.mapValues(\.url),
            source: downloadedAny ? .download : .cache
        )
    }

    func presentationPackage(
        entry: ExperienceReleaseProfileEntryV1,
        delivery: ExperienceReleaseDeliveryV1,
        mode: ExperienceReleaseAdmissionMode,
        remote: RemoteExperience
    ) async throws -> AcquiredExperiencePackage {
        guard entry.locator.experienceId == remote.experienceId,
              entry.locator.experienceVersionId == remote.versionId,
              entry.locator.buildId == remote.buildId else {
            throw ExperienceReleaseDescriptorAuthenticationError.identityMismatch
        }
        let acquired = try await acquire(entry: entry, delivery: delivery, mode: mode)
        return try Self.presentationPackage(
            acquired: acquired,
            identity: .init(
                experienceId: remote.experienceId,
                buildId: remote.buildId
            ),
            authorizationKeys: authorizationKeys
        )
    }

    private nonisolated static func presentationPackage(
        acquired: AcquiredExperienceRelease,
        identity: AcquiredExperiencePackage.Identity,
        authorizationKeys: [ExperiencePackageAuthorizationKey]
    ) throws -> AcquiredExperiencePackage {
        let externalAssets = acquired.payload.assets.map { asset in
            NuxPackageAcquisitionExternalAsset(
                kind: asset.kind == .image ? .image : .font,
                riveAssetId: asset.riveAssetID,
                riveUniqueName: asset.riveUniqueName,
                key: asset.sourceKey,
                sha256: asset.sha256,
                sizeBytes: asset.bytes?.count ?? 0,
                required: asset.required
            )
        }
        let metadata = NuxPackageAcquisitionMetadataV1(
            contractVersion: NuxPackageLimits.acquisitionContractVersion,
            packageVersion: 1,
            identity: .init(
                experienceId: identity.experienceId,
                buildId: identity.buildId
            ),
            externalAssets: externalAssets
        )
        let assetURLs = Dictionary(uniqueKeysWithValues: acquired.payload.assets.compactMap {
            asset in acquired.objectURLsByKey[asset.sourceKey].map { (asset.riveUniqueName, $0) }
        })
        return AcquiredExperiencePackage(
            identity: identity,
            packageURL: acquired.objectURLsByKey[acquired.payload.renderPlan.scene.key]!,
            packageBytes: acquired.payload.sceneBytes,
            acquisition: NuxPackageAcquisition(bytes: acquired.payload.sceneBytes, metadata: metadata),
            assetURLsByRiveUniqueName: assetURLs,
            source: acquired.source,
            authorizationKeys: authorizationKeys,
            authenticatedPayload: acquired.payload
        )
    }

    func presentationPackage(
        definition: AuthenticatedExperienceReleaseDefinition
    ) async throws -> AcquiredExperiencePackage {
        let acquired = try await acquire(definition: definition)
        return try Self.presentationPackage(
            acquired: acquired,
            identity: .init(
                experienceId: definition.reference.experienceId,
                buildId: definition.behavior.buildId
            ),
            authorizationKeys: authorizationKeys
        )
    }

    private func acquireObject(
        _ artifact: ExperienceReleaseRenderDocument.Artifact,
        origin: URL
    ) async throws -> ObjectResult {
        let destination = cacheDirectory.appendingPathComponent(artifact.sha256)
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: destination,
            lockScope: cacheLockScope
        ) {
            if FileManager.default.fileExists(atPath: destination.path) {
                do {
                    let read = try BoundedFileIO.read(
                        at: destination,
                        maximumBytes: Self.limit(for: artifact)
                    )
                    try Self.verify(read.digest, artifact: artifact)
                    return ObjectResult(
                        url: destination,
                        bytes: read.data,
                        downloaded: false
                    )
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                }
            }

            let sourceURL = try Self.compose(artifact.key, relativeTo: origin)
            let download = try await BoundedHTTPAcquisition.download(
                from: sourceURL,
                using: self.urlSession,
                maximumBytes: Self.limit(for: artifact),
                temporaryDirectory: self.cacheDirectory,
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
            } catch BoundedFileVerificationError.sha256Mismatch(_, let actual) {
                try? FileManager.default.removeItem(at: destination)
                throw ExperienceReleaseAcquisitionError.objectDigestMismatch(
                    key: artifact.key,
                    expected: artifact.sha256,
                    actual: actual
                )
            } catch BoundedFileVerificationError.sizeMismatch(_, let actual) {
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
            try Self.verify(read.digest, artifact: artifact)
            return ObjectResult(url: destination, bytes: read.data, downloaded: true)
        }
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
        default:
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
        guard presentation.style == "full_screen" else {
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
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
            presentationStyle: .fullScreen
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
            appleProductIDs: products.compactMap {
                $0.platform == "apple_app_store" ? $0.id : nil
            }
        )
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
