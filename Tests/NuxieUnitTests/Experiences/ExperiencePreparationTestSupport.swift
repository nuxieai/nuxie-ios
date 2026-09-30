#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieRuntime
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

// Shared runtime payload and signed-fixture helpers for the native preparation
// tests. They live here rather than in NuxieTestSupport because that SwiftPM
// target does not depend on NuxieRuntime.

private final class ExperiencePreparationTestBundleToken {}

/// Loads a unit-test resource from this test bundle, or from a sibling
/// resource bundle when SwiftPM packages resources separately.
func experiencePreparationTestResource(
    named name: String,
    extension fileExtension: String
) throws -> Data {
    let testBundle = Bundle(for: ExperiencePreparationTestBundleToken.self)
    if let url = testBundle.url(forResource: name, withExtension: fileExtension) {
        return try Data(contentsOf: url)
    }
    let siblings = try FileManager.default.contentsOfDirectory(
        at: testBundle.bundleURL.deletingLastPathComponent(),
        includingPropertiesForKeys: nil
    )
    for sibling in siblings where sibling.pathExtension == "bundle" {
        if let url = Bundle(url: sibling)?.url(
            forResource: name,
            withExtension: fileExtension
        ) {
            return try Data(contentsOf: url)
        }
    }
    throw CocoaError(.fileNoSuchFile)
}

/// The repository root, found from this source file.
func experiencePreparationRepositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

/// Serves a signed fixture's content-addressed objects from its directory
/// through StubURLProtocol, calling `onRequest` for every request.
func serveSignedFixtureObjects(
    at fixture: URL,
    host: String,
    onRequest: @escaping @Sendable () -> Void = {}
) {
    StubURLProtocol.register(matcher: { $0.url?.host == host }) { request in
        onRequest()
        let file = fixture.appendingPathComponent(String(request.url!.path.dropFirst()))
        let bytes = try Data(contentsOf: file)
        let contentType: String
        switch file.pathExtension {
        case "nux": contentType = "application/vnd.nuxie.scene"
        case "png": contentType = "image/png"
        case "ttf": contentType = "font/ttf"
        default: contentType = "application/octet-stream"
        }
        return (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": contentType,
                    "Content-Length": String(bytes.count),
                ]
            )!,
            bytes
        )
    }
}

/// A canonical profile that arms the single signed release in a fixture's
/// `release-entry.json`, delivered from `host`.
func signedReleaseEntryProfileBytes(
    fixture: URL,
    host: String
) throws -> Data {
    let entry = try XCTUnwrap(JSONSerialization.jsonObject(with:
        Data(contentsOf: fixture.appendingPathComponent("release-entry.json"))) as? [String: Any])
    let locator = try XCTUnwrap(entry["locator"] as? [String: Any])
    let envelope = try XCTUnwrap(entry["envelope"] as? [String: Any])
    let profile: [String: Any] = [
        "schemaVersion": "nuxie.journey-plane-profile.v2", "status": "ok",
        "delivery": ["renderBaseUrl": "https://\(host)/",
                     "assetBaseUrl": "https://\(host)/"],
        "features": [], "facts": ["properties": [:], "memberships": [:], "assignments": [:]],
        "armedLegs": [[
            "reference": [
                "experienceId": try XCTUnwrap(locator["experienceId"]),
                "versionId": try XCTUnwrap(locator["experienceVersionId"]),
                "legId": try XCTUnwrap(locator["legId"]),
                "descriptorSha256": try XCTUnwrap(envelope["descriptorSha256"]),
            ],
            "binding": ["type": "new"],
            "entryCondition": ["type": "app_foregrounded"],
            "context": ["event": [:], "responses": [:]],
        ]], "releases": [entry],
    ]
    return try JSONSerialization.data(withJSONObject: profile)
}

/// Authenticates a signed fixture profile through the ordinary catalog with
/// the development trust roots, and serves its objects through StubURLProtocol.
func authenticatedFixtureSnapshot(
    at fixture: URL,
    profileBytes suppliedProfileBytes: Data? = nil,
    onRequest: @escaping @Sendable () -> Void = {}
) async throws -> JourneyProfileCatalog.Snapshot {
    StubURLProtocol.reset()
    let profileBytes = try suppliedProfileBytes ?? Data(
        contentsOf: fixture.appendingPathComponent("profile.json")
    )
    let profile = try JourneyPlaneProfile.decode(profileBytes)
    let host = try XCTUnwrap(URL(string: profile.delivery.renderBaseUrl)?.host)
    serveSignedFixtureObjects(at: fixture, host: host, onRequest: onRequest)
    let catalog = JourneyProfileCatalog(
        authorizationKeys: try JourneyTrustRoots.keys(for: .development),
        supportedRuntime: JourneyReleaseRuntime.current,
        highWaterStore: InMemoryJourneyReleaseHighWaterStore()
    )
    let firstEntry = try XCTUnwrap(profile.releases.first)
    return try await catalog.prepare(
        profile,
        authority: ProfileDeliveryAuthority(
            appId: firstEntry.locator.appId,
            environment: firstEntry.locator.environment
        )
    ).snapshot
}

func authenticatedFixtureArtifact(
    at fixture: URL,
    profileBytes suppliedProfileBytes: Data? = nil
) async throws -> (Experience, LoadedExperienceArtifact) {
    let authenticated = try await authenticatedFixtureSnapshot(
        at: fixture,
        profileBytes: suppliedProfileBytes
    )
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
        "authenticated-fixture-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: cache,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: cache) }
    let store = JourneyReleaseAcquisitionStore(
        cacheDirectory: cache,
        urlSession: TestURLSessionProvider.createTestSession()
    )
    let release = try XCTUnwrap(authenticated.releasesByDigest.values.first)
    let screenID = try XCTUnwrap(release.descriptor.leg.screens.first?.id)
    let presentation = try await store.preparePresentation(
        release: release,
        delivery: authenticated.profile.delivery,
        pinnedArtifacts: nil,
        productResolver: { _ in [] }
    )
    return (presentation.experience, LoadedExperienceArtifact(acquired: try await presentation.artifactLoader(
        presentation.experience,
        nil,
        screenID
    )))
}

func twoScreenStatePayload() async throws -> (
    payload: AuthenticatedRuntimePayload,
    firstScreenID: String,
    secondScreenID: String
) {
    let base = try await statePayload(defaultViewModelName: "Test")
    let authoredScreen = try XCTUnwrap(base.renderPlan.screens.first)
    let secondScreen = NativeExperienceScreen(
        screenId: "state-screen-2",
        artboardId: authoredScreen.artboardId,
        artboardName: authoredScreen.artboardName,
        width: authoredScreen.width,
        height: authoredScreen.height,
        exit: authoredScreen.exit
    )
    return (
        AuthenticatedRuntimePayload(
            authenticatedKeyID: base.authenticatedKeyID,
            renderPlan: NativeExperienceRenderPlan(
                identity: base.renderPlan.identity,
                scene: base.renderPlan.scene,
                entry: base.renderPlan.entry,
                screens: base.renderPlan.screens + [secondScreen],
                transitions: base.renderPlan.transitions,
                textInputs: base.renderPlan.textInputs,
                images: base.renderPlan.images,
                fonts: base.renderPlan.fonts
            ),
            journey: JourneyDocument(
                screens: base.journey.screens + [JourneyScreen(
                    id: secondScreen.screenId,
                    defaultViewModelName: "Test",
                    defaultInstanceId: "root-sdk-id"
                )],
                viewModelValues: base.journey.viewModelValues
            ),
            sceneBytes: base.sceneBytes,
            assets: base.assets
        ),
        authoredScreen.screenId,
        secondScreen.screenId
    )
}

func statePayload(
    defaultViewModelName: String?,
    values: [JourneyViewModelValue]? = nil,
    scene suppliedScene: Data? = nil,
    artboardName: String = "Artboard"
) async throws -> AuthenticatedRuntimePayload {
    let scene = try suppliedScene ?? experiencePreparationTestResource(
        named: "data_binding_test",
        extension: "riv"
    )
    let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
    var images: [NativeExperienceImageAsset] = []
    var fonts: [NativeExperienceFontAsset] = []
    var assetMembers: [(String, Data)] = []
    for descriptor in catalog where descriptor.kind == .image || descriptor.kind == .font {
        guard descriptor.isEmbedded, let authoredID = descriptor.authoredID else {
            throw XCTSkip("State fixture requires only embedded identified assets")
        }
        let uniqueName = "\(descriptor.name)-\(authoredID)"
        let assetBytes = Data("asset-\(descriptor.ordinal)".utf8)
        let assetHash = SHA256Provider.hexDigest(assetBytes)
        let fileExtension = descriptor.kind == .image ? "png" : "ttf"
        let member = "assets/sha256/\(assetHash).\(fileExtension)"
        assetMembers.append((member, assetBytes))
        if descriptor.kind == .image {
            images.append(NativeExperienceImageAsset(
                location: .embedded(member: member),
                authoredAssetId: UInt64(authoredID),
                assetUniqueName: uniqueName,
                sha256: assetHash,
                sizeBytes: assetBytes.count,
                contentType: "image/png",
                required: true
            ))
        } else {
            fonts.append(NativeExperienceFontAsset(
                location: .embedded(member: member),
                authoredAssetId: UInt64(authoredID),
                assetUniqueName: uniqueName,
                family: "Inter",
                weight: "400",
                style: "normal",
                sha256: assetHash,
                sizeBytes: assetBytes.count,
                contentType: "font/ttf",
                format: "ttf",
                required: true
            ))
        }
    }
    let defaultValues: [JourneyViewModelValue]
    if let defaultViewModelName {
        defaultValues = [
            JourneyViewModelValue(
                viewModelName: defaultViewModelName,
                instanceId: "root-sdk-id",
                path: "Number",
                value: AnyCodable(23)
            ),
            JourneyViewModelValue(
                viewModelName: defaultViewModelName,
                instanceId: "root-sdk-id",
                path: "Boolean",
                value: AnyCodable(true)
            ),
            JourneyViewModelValue(
                viewModelName: defaultViewModelName,
                instanceId: "root-sdk-id",
                path: "String",
                value: AnyCodable("signed-state")
            ),
        ]
    } else {
        defaultValues = []
    }
    let journey = JourneyDocument(
        screens: [JourneyScreen(
            id: "state-screen",
            defaultViewModelName: defaultViewModelName,
            defaultInstanceId: defaultViewModelName == nil ? nil : "root-sdk-id"
        )],
        viewModelValues: values ?? defaultValues
    )
    let sceneHash = SHA256Provider.hexDigest(scene)
    let bytesByPath = Dictionary(uniqueKeysWithValues: assetMembers)
    let runtimeAssets = try images.map { image in
        AuthenticatedRuntimeAsset(
            kind: .image,
            authoredAssetID: try XCTUnwrap(UInt32(exactly: image.authoredAssetId)),
            assetUniqueName: image.assetUniqueName,
            sourceKey: image.location.contentAddressedPath,
            contentType: image.contentType,
            sha256: image.sha256,
            required: image.required,
            bytes: bytesByPath[image.location.contentAddressedPath]
        )
    } + fonts.map { font in
        AuthenticatedRuntimeAsset(
            kind: .font,
            authoredAssetID: try XCTUnwrap(UInt32(exactly: font.authoredAssetId)),
            assetUniqueName: font.assetUniqueName,
            sourceKey: font.location.contentAddressedPath,
            contentType: font.contentType,
            sha256: font.sha256,
            required: font.required,
            bytes: bytesByPath[font.location.contentAddressedPath]
        )
    }
    return AuthenticatedRuntimePayload(
        authenticatedKeyID: "TEST_ONLY_DEV_KEYPAIR",
        renderPlan: NativeExperienceRenderPlan(
            identity: .init(
                experienceId: "state-experience",
                buildId: "state-build",
                appId: "test-app",
                environment: "test"
            ),
            scene: .init(key: "scene.riv", sha256: sceneHash, sizeBytes: scene.count),
            entry: .init(screenId: "state-screen"),
            screens: [NativeExperienceScreen(
                screenId: "state-screen",
                artboardId: artboardName,
                artboardName: artboardName,
                width: 100,
                height: 100,
                exit: nil
            )],
            transitions: [],
            textInputs: [],
            images: images,
            fonts: fonts
        ),
        journey: journey,
        sceneBytes: scene,
        assets: runtimeAssets
    )
}

/// Gates native preparation (or acquisition) entries by key and records how
/// many run at once. A held entry waits until the test releases it; a
/// cancelled waiter throws CancellationError and is recorded.
actor ConcurrencyProbeGate {
    enum Holding: Sendable {
        case none
        case all
        case keys(Set<String>)
    }

    private struct Waiter {
        let id: UUID
        let key: String
        let continuation: CheckedContinuation<Void, Error>
    }

    private var holding: Holding
    private var releasedKeys: Set<String> = []
    private var waiters: [Waiter] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var startLog: [String] = []
    private(set) var cancelledKeys: [String] = []
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0

    init(holding: Holding = .none) {
        self.holding = holding
    }

    func enter(_ key: String) async throws {
        startLog.append(key)
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        resumeStartWaiters()
        guard holds(key) else { return }
        let id = UUID()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append(Waiter(id: id, key: key, continuation: continuation))
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        } catch {
            activeCount -= 1
            cancelledKeys.append(key)
            throw error
        }
    }

    func exit(_ key: String) {
        _ = key
        activeCount -= 1
    }

    /// Releases the oldest held entry, one at a time.
    func releaseNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    /// Stops holding `key` and releases its waiting entries.
    func release(_ key: String) {
        releasedKeys.insert(key)
        let released = waiters.filter { $0.key == key }
        waiters.removeAll { $0.key == key }
        released.forEach { $0.continuation.resume() }
    }

    /// Stops holding and releases every waiting entry.
    func open() {
        holding = .none
        let released = waiters
        waiters.removeAll()
        released.forEach { $0.continuation.resume() }
    }

    func waitForStarts(_ count: Int) async {
        guard startLog.count < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func startCount(of key: String) -> Int {
        startLog.filter { $0 == key }.count
    }

    var heldCount: Int { waiters.count }

    private func holds(_ key: String) -> Bool {
        guard !releasedKeys.contains(key) else { return false }
        switch holding {
        case .none: return false
        case .all: return true
        case .keys(let keys): return keys.contains(key)
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func resumeStartWaiters() {
        let ready = startWaiters.filter { startLog.count >= $0.count }
        startWaiters.removeAll { startLog.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

/// A native preparation cache whose preparer passes through `gate`, keyed by
/// the payload's experience id.
func probedPreparationCache(
    _ gate: ConcurrencyProbeGate
) -> ExperienceInteractivePreparationCache {
    ExperienceInteractivePreparationCache(preparePayload: { payload, catalog in
        let key = payload.renderPlan.identity.experienceId
        try await gate.enter(key)
        do {
            let preparation = try await ExperienceInteractivePreparation.prepare(
                payload: payload,
                inspectedCatalog: catalog
            )
            await gate.exit(key)
            return preparation
        } catch {
            await gate.exit(key)
            throw error
        }
    })
}

/// A fake release acquirer. It returns the runtime release registered for a
/// descriptor SHA-256, records every start, and passes each start through
/// `gate`, keyed by descriptor SHA-256.
actor RecordingJourneyReleaseAcquirer: JourneyReleaseAcquiring {
    struct Unsupported: Error {}

    private let runtimes: [String: PreparedRuntimeRelease]
    private let runtimesByStart: [String: [PreparedRuntimeRelease]]
    private let ignoresCancellation: Bool
    let gate: ConcurrencyProbeGate
    private(set) var starts: [String] = []
    private(set) var intents: [JourneyReleasePreparationIntent] = []

    /// `runtimesByStart` answers a descriptor's nth start with its nth
    /// entry (the last one after that), ahead of `runtimes`. With
    /// `ignoresCancellation`, a held start finishes once released even when
    /// its caller was cancelled, like a read that is already under way.
    init(
        runtimes: [String: PreparedRuntimeRelease],
        runtimesByStart: [String: [PreparedRuntimeRelease]] = [:],
        ignoresCancellation: Bool = false,
        gate: ConcurrencyProbeGate = ConcurrencyProbeGate()
    ) {
        self.runtimes = runtimes
        self.runtimesByStart = runtimesByStart
        self.ignoresCancellation = ignoresCancellation
        self.gate = gate
    }

    func prepareJourneyArtifacts(
        for snapshot: JourneyProfileCatalog.Snapshot
    ) async throws -> JourneyProfileArtifactPreparation {
        _ = snapshot
        throw Unsupported()
    }

    func prepareRuntimeRelease(
        release: AuthenticatedJourneyRelease,
        delivery: JourneyReleaseDelivery,
        intent: JourneyReleasePreparationIntent,
        pinnedArtifacts: JourneyPinnedReleaseArtifacts?
    ) async throws -> PreparedRuntimeRelease? {
        _ = delivery
        _ = pinnedArtifacts
        let descriptorSHA256 = release.descriptorSHA256
        starts.append(descriptorSHA256)
        intents.append(intent)
        let start = startCount(of: descriptorSHA256) - 1
        if ignoresCancellation {
            let gate = gate
            try await Task { try await gate.enter(descriptorSHA256) }.value
        } else {
            try await gate.enter(descriptorSHA256)
        }
        await gate.exit(descriptorSHA256)
        if let byStart = runtimesByStart[descriptorSHA256], let last = byStart.last {
            return start < byStart.count ? byStart[start] : last
        }
        return runtimes[descriptorSHA256]
    }

    func preparePresentation(
        release: AuthenticatedJourneyRelease,
        delivery: JourneyReleaseDelivery,
        pinnedArtifacts: JourneyPinnedReleaseArtifacts?,
        preparedReleases: JourneyPreparedReleaseStore?,
        productResolver: @escaping @Sendable (String) async throws -> [StoreProduct]
    ) async throws -> PreparedJourneyPresentation {
        throw Unsupported()
    }

    func startCount(of descriptorSHA256: String) -> Int {
        starts.filter { $0 == descriptorSHA256 }.count
    }
}
#endif
