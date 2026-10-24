#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@_spi(Testing) @testable import Nuxie
@testable import NuxieRuntime
#if SWIFT_PACKAGE || NUXIE_HOSTED_INPUT_TESTS
@testable import NuxieTestSupport
#endif

// Shared runtime payload and signed-fixture helpers for the native preparation
// tests. They live here rather than in NuxieTestSupport because that SwiftPM
// target does not depend on NuxieRuntime.

/// One lookup for a mounted Screen: resolve its root through the page list,
/// then return the binding and row-local snapshot, never the page-root snapshot.
struct FixturePageRow {
    let binding: ExperienceInteractiveScreen
    let snapshot: ExperienceInteractiveViewModelSnapshot

    static func resolve(_ page: ExperienceInteractivePage, screenID: String) async throws -> Self {
        let ids = await page.mountedScreenIDs
        let index = try XCTUnwrap(ids.firstIndex(of: screenID), "Screen is not mounted: \(screenID)")
        let native = try await page.runtime.snapshot()
        guard case .list(let roots) = native.values.first(where: {
            $0.ownerInstanceID == native.rootInstanceID && $0.name == "screens"
        })?.value, roots.indices.contains(index) else {
            throw ExperienceInteractiveScreenError.stateContract("Fixture page has no matching Screen list row")
        }
        let binding = try await page.binding(screenID: screenID)
        let row = try await binding.snapshot()
        XCTAssertEqual(row.rootInstanceID, roots[index])
        return Self(binding: binding, snapshot: row)
    }

    static func mount(_ page: ExperienceInteractivePage, screenID: String,
                      products: [StoreProduct] = []) async throws -> Self {
        _ = try await page.prepareRow(screenID: screenID, products: products)
        let index = await page.mountedScreenIDs.count
        try await page.insert(screenID: screenID, at: index)
        try await page.setPhases([(screenID, .entering)])
        _ = try await page.step(elapsedSeconds: 0)
        try await page.setPhases([(screenID, .active)])
        try await page.selectActiveRow(screenID)
        return try await resolve(page, screenID: screenID)
    }

    static func screenID(_ role: String?, in plan: NativeExperienceRenderPlan) throws -> String {
        guard let role else { return plan.entry.screenId }
        // Existing corpus roles may name the declared Screen or its authored label.
        // Read that association from the release; never synthesize artboard/model IDs.
        let exact = plan.screens.filter { $0.screenId == role }
        let candidates = exact.isEmpty ? plan.screens.filter { $0.artboardName == role } : exact
        XCTAssertEqual(candidates.count, 1, "Fixture role must resolve uniquely: \(role)")
        return try XCTUnwrap(candidates.count == 1 ? candidates.first?.screenId : nil)
    }
}

func fixtureRowReference(_ path: String, in snapshot: ExperienceInteractiveViewModelSnapshot) throws -> UInt64 {
    var owner = snapshot.rootInstanceID
    for name in path.split(separator: "/").map(String.init) {
        guard case .referencedInstance(let id) = snapshot.values.first(where: {
            $0.ownerInstanceID == owner && $0.name == name
        })?.value else { throw ExperienceInteractiveScreenError.stateContract("Missing row reference: \(path)") }
        owner = id
    }
    return owner
}

#if canImport(UIKit)
@MainActor
func fixturePageController(in host: UIViewController, screenID: String) throws -> ExperienceScreenViewController {
    func find(_ view: UIViewController) -> ExperienceScreenViewController? {
        if let page = view as? ExperienceScreenViewController, page.isPageController, page.screenId == screenID { return page }
        return view.presentedViewController.flatMap(find) ?? view.children.reversed().compactMap(find).first
    }
    return try XCTUnwrap(find(host), "No page owns active Screen \(screenID)")
}

@MainActor
func fixtureActivePageRow(_ controller: ExperienceScreenViewController) async throws -> FixturePageRow {
    guard let page = controller.interactivePage else {
        let binding = try XCTUnwrap(Mirror(reflecting: controller).children.first {
            $0.label == "interactiveScreen"
        }?.value as? ExperienceInteractiveScreen)
        return FixturePageRow(binding: binding, snapshot: try await controller.runtimeSnapshot())
    }
    let active = await page.activeScreenID
    XCTAssertEqual(active, controller.screenId)
    return try await FixturePageRow.resolve(page, screenID: controller.screenId)
}
#endif

/// Retain page ownership alongside bindings handed to existing geometry/event
/// oracles. Explicit close and XCTest teardown both release the same page once.
private actor FixturePageOwners {
    static let shared = FixturePageOwners()
    private var pages: [ObjectIdentifier: ExperienceInteractivePage] = [:]
    func retain(_ page: ExperienceInteractivePage, for row: ExperienceInteractiveScreen) {
        pages[ObjectIdentifier(row)] = page
    }
    func page(for row: ExperienceInteractiveScreen) -> ExperienceInteractivePage? { pages[ObjectIdentifier(row)] }
    func close(_ row: ExperienceInteractiveScreen) async throws {
        guard let page = pages[ObjectIdentifier(row)] else { try await row.close(); return }
        try await page.close()
        pages.removeValue(forKey: ObjectIdentifier(row))
    }
}

func closeFixturePageRow(_ row: ExperienceInteractiveScreen) async throws {
    try await FixturePageOwners.shared.close(row)
}

func fixtureEnvironmentSnapshot(_ row: ExperienceInteractiveScreen) async throws -> NuxieNativeViewModelSnapshot? {
    if let page = await FixturePageOwners.shared.page(for: row) { return try await page.environmentSnapshot() }
    return try await row.environmentSnapshot()
}

func updateFixtureEnvironment(_ row: ExperienceInteractiveScreen, reduceMotion: Bool? = nil,
                              safeArea: ExperienceSafeAreaInsets? = nil) async throws {
    if let page = await FixturePageOwners.shared.page(for: row) {
        try await page.updateEnvironment(reduceMotion: reduceMotion, safeArea: safeArea)
    } else {
        try await row.updateEnvironment(reduceMotion: reduceMotion, safeArea: safeArea)
    }
}

/// Use the ordinary signed catalog/acquisition path for pages with external resources.
func signedFixturePayload(at directory: URL) async throws -> AuthenticatedRuntimePayload {
    let (_, artifact) = try await authenticatedFixtureArtifact(at: directory,
        profileBytes: signedReleaseEntryProfileBytes(fixture: directory, host: "fixture-page.nuxie.test"))
    return artifact.payload
}

/// Producer declarations for an unsigned page scene. Test-authored signing
/// wrappers use these exact Screen roots, render objects and value policy.
struct FixturePageSceneDeclarations {
    let render: [String: Any]
    let screens: [[String: Any]]
    let valuePolicy: [String: Any]

    static func load(at directory: URL) throws -> Self {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appendingPathComponent("scene-declarations.json"))) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? String, "nuxie.sdk-page-scene.v1")
        let render = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appendingPathComponent("render.json"))) as? [String: Any])
        let embedded = try XCTUnwrap(object["render"] as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: render).isEqual(to: embedded), "Scene declarations and render table must agree")
        let screens = try XCTUnwrap(object["screens"] as? [[String: Any]])
        XCTAssertFalse(screens.isEmpty)
        return .init(render: render, screens: screens,
            valuePolicy: try XCTUnwrap(object["valuePolicy"] as? [String: Any]))
    }

    func applying(to template: [String: Any]) throws -> [String: Any] {
        var result = template
        result["render"] = render
        for name in ["state", "responses", "ruleGroups", "stateRules"] { result[name] = valuePolicy[name] }
        result["viewModelValues"] = []
        var leg = try XCTUnwrap(result["leg"] as? [String: Any])
        leg["screens"] = screens.map { $0.merging(["responseCaptures": []]) { old, _ in old } }
        let first = try XCTUnwrap(screens.first?["id"] as? String)
        leg["entryStepId"] = "present"
        leg["steps"] = [["kind": "action", "id": "present",
            "action": ["type": "navigate", "screenId": first], "outlets": [:]]]
        leg["routes"] = []
        result["leg"] = leg
        result["screenBehaviors"] = try screens.map {
            ["screenId": try XCTUnwrap($0["id"] as? String), "controls": []] as [String: Any]
        }.sorted { ($0["screenId"] as! String).utf16.lexicographicallyPrecedes(($1["screenId"] as! String).utf16) }
        var requirements = try XCTUnwrap(result["requirements"] as? [String: Any])
        let fonts = render["assets"] as? [[String: Any]] ?? []
        requirements["requiredCapabilities"] = fonts.contains { $0["location"] as? String == "system" }
            ? ["nux", "system-fonts"] : ["nux"]
        result["requirements"] = requirements
        return result
    }
}

/// Opens pages for page plans and the original scene sessions for scene-only
/// plans. Independent presentations can share an explicitly supplied Journey run.
struct FixturePagePreparation {
    let payload: AuthenticatedRuntimePayload
    let preparation: ExperienceInteractivePreparation
    let test: XCTestCase

    func prepareRunValues(_ values: ExperienceRunValues) async throws {
        try await preparation.prepareRunValues(values)
    }

    func metrics() async -> ExperienceInteractivePreparationMetrics { await preparation.metrics() }

    func openRow(screenID: String? = nil, runValues: ExperienceRunValues? = nil,
                 products: [StoreProduct] = [], pixelWidth: UInt32, pixelHeight: UInt32,
                 initialReduceMotion: Bool? = nil, initialFontScale: Double? = nil,
                 initialSafeArea: ExperienceSafeAreaInsets? = nil,
                 initialColorScheme: ExperienceColorScheme? = nil) async throws -> ExperienceInteractiveScreen {
        let id = try FixturePageRow.screenID(screenID, in: payload.renderPlan)
        guard payload.renderPlan.pageHost != nil else {
            let screen = try await preparation.openScreen(screenID: id, runValues: runValues, products: products,
                pixelWidth: pixelWidth, pixelHeight: pixelHeight, initialReduceMotion: initialReduceMotion,
                initialFontScale: initialFontScale, initialSafeArea: initialSafeArea, initialColorScheme: initialColorScheme)
            test.addTeardownBlock { try await screen.close() }
            return screen
        }
        let page = try await preparation.openPage(runValues: runValues, pixelWidth: pixelWidth,
            pixelHeight: pixelHeight, reduceMotion: initialReduceMotion ?? false,
            fontScale: initialFontScale, safeArea: initialSafeArea, colorScheme: initialColorScheme)
        test.addTeardownBlock { try await page.close() }
        let row = try await FixturePageRow.mount(page, screenID: id, products: products).binding
        await FixturePageOwners.shared.retain(page, for: row)
        test.addTeardownBlock { try await closeFixturePageRow(row) }
        return row
    }
}

extension XCTestCase {
    /// Read the published control's settled native geometry before sending input.
    func fixtureControlBounds(in capture: NuxieNativeSemanticCapture, label: String) throws -> CGRect {
        // HTML controls can publish a named tap target with role none. The
        // authored action and enabled/visible state authorize this lookup.
        let node = try XCTUnwrap(capture.tree.visibleReadingOrder.first {
            $0.actions & (1 << NuxieNativeSemanticAction.tap.rawValue) != 0
                && $0.stateFlags & NuxieNativeSemanticNode.disabled == 0
                && ($0.label == label || $0.value == label)
        }, "Published control must be exposed: \(label)")
        XCTAssertGreaterThan(node.bounds.width, 0)
        XCTAssertGreaterThan(node.bounds.height, 0)
        return node.bounds
    }

    func prepareFixturePage(payload: AuthenticatedRuntimePayload) async throws -> FixturePagePreparation {
        .init(payload: payload, preparation: try await ExperienceInteractivePreparation.prepare(payload: payload), test: self)
    }

    func openFixturePageRow(payload: AuthenticatedRuntimePayload, screenID: String? = nil,
                            pixelWidth: UInt32, pixelHeight: UInt32) async throws -> ExperienceInteractiveScreen {
        let fixture = try await prepareFixturePage(payload: payload)
        return try await fixture.openRow(screenID: screenID, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}

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
) throws {
    let descriptor: [String: Any]
    if FileManager.default.fileExists(atPath: fixture.appendingPathComponent("scene-declarations.json").path) {
        descriptor = ["render": try FixturePageSceneDeclarations.load(at: fixture).render]
    } else if let name = ["descriptor.json", "release.json"].first(where: {
        FileManager.default.fileExists(atPath: fixture.appendingPathComponent($0).path)
    }) {
        descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: fixture.appendingPathComponent(name))) as? [String: Any])
    } else {
        let profile = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: fixture.appendingPathComponent("profile.json"))) as? [String: Any])
        let entry = try XCTUnwrap((profile["releases"] as? [[String: Any]])?.first)
        let envelope = try XCTUnwrap(entry["envelope"] as? [String: Any])
        let bytes = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(envelope["descriptorBytesBase64"] as? String)))
        descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    let render = try XCTUnwrap(descriptor["render"] as? [String: Any])
    let scene = try XCTUnwrap((render["nux"] ?? render["rive"]) as? [String: Any])
    let assets = (render["assets"] as? [[String: Any]] ?? []).filter { $0["key"] != nil }
    let behaviors = (descriptor["screenBehaviors"] as? [[String: Any]] ?? []).compactMap {
        ($0["script"] as? [String: Any])?["artifact"] as? [String: Any]
    }
    let objects = [scene] + assets + behaviors
    var contentTypes: [String: String] = [:]
    for object in objects {
        let key = try XCTUnwrap(object["key"] as? String)
        let contentType = try XCTUnwrap(object["contentType"] as? String)
        if let previous = contentTypes.updateValue(contentType, forKey: key) {
            XCTAssertEqual(previous, contentType, "Shared immutable object must have one MIME type")
        }
    }
    let declaredContentTypes = contentTypes
    StubURLProtocol.register(matcher: { $0.url?.host == host }) { request in
        onRequest()
        let path = String(request.url!.path.dropFirst())
        let file = fixture.appendingPathComponent(path)
        let bytes = try Data(contentsOf: file)
        let contentType = try XCTUnwrap(declaredContentTypes[path], "Object is absent from the signed descriptor: \(path)")
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
/// `release-entry.json`, delivered from `host`. The arm repeats the signed
/// leg's own entry condition: a profile cannot rewrite the authored trigger.
func signedReleaseEntryProfileBytes(
    fixture: URL,
    host: String
) throws -> Data {
    let entry = try XCTUnwrap(JSONSerialization.jsonObject(with:
        Data(contentsOf: fixture.appendingPathComponent("release-entry.json"))) as? [String: Any])
    let locator = try XCTUnwrap(entry["locator"] as? [String: Any])
    let envelope = try XCTUnwrap(entry["envelope"] as? [String: Any])
    let descriptorBytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["descriptorBytesBase64"] as? String)))
    let descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: descriptorBytes) as? [String: Any])
    let entryCondition = try XCTUnwrap((descriptor["leg"] as? [String: Any])?["entryCondition"])
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
            "entryCondition": entryCondition,
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
    try serveSignedFixtureObjects(at: fixture, host: host, onRequest: onRequest)
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
    artboardName: String = "Artboard",
    width: Double = 100,
    height: Double = 100,
    definition: ExperienceDefinition? = nil
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
                width: width,
                height: height,
                exit: nil
            )],
            transitions: [],
            textInputs: [],
            images: images,
            fonts: fonts
        ),
        journey: journey,
        definition: definition,
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

#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
func interimLayerTransition() -> NativeExperienceTransition {
    .init(id: "transition.native-contract", kind: .layer,
        sourceScreenId: "screen_1", destinationScreenId: "screen_2", durationMs: 450,
        incomingOnTop: true, source: .init(completeEventName: "nx_exit_done:transition.native-contract"),
        destination: .init(completeEventName: "nx_enter_done:transition.native-contract"),
        reverse: .init(durationMs: 900, incomingOnTop: nil,
            source: .init(completeEventName: "nx_exit_done:transition.native-contract.reverse"),
            destination: .init(completeEventName: "nx_enter_done:transition.native-contract.reverse")))
}

func interimLayerPayload() async throws -> AuthenticatedRuntimePayload {
    let bytes = try Data(contentsOf: experiencePreparationRepositoryRoot()
        .appendingPathComponent("fixtures/runtime/layer-host-interim/layer-host.riv"))
    let base = try await statePayload(defaultViewModelName: nil, values: [], scene: bytes)
    let screens = [JourneyScreen(id: "screen_1", defaultViewModelName: "Runtime", defaultInstanceId: "row-a"),
                   JourneyScreen(id: "screen_2", defaultViewModelName: "Runtime_Upsell", defaultInstanceId: "row-b")]
    let definition = ExperienceDefinition(screens: screens, viewModelValues: [], controlsByScreen: [:])
    return AuthenticatedRuntimePayload(authenticatedKeyID: "TEST_ONLY_DEV_KEYPAIR",
        renderPlan: .init(identity: base.renderPlan.identity, scene: base.renderPlan.scene,
            entry: .init(screenId: "screen_1"), pageHost: .init(artboardName: "LayerList", listPath: "screens"),
            screens: [.init(screenId: "screen_1", artboardId: "screen_1", artboardName: "Paywall", width: 390, height: 844, exit: nil),
                      .init(screenId: "screen_2", artboardId: "screen_2", artboardName: "Upsell", width: 430, height: 932, exit: nil)],
            transitions: [interimLayerTransition()], textInputs: [], images: base.renderPlan.images, fonts: base.renderPlan.fonts),
        journey: definition.renderShell, definition: definition, sceneBytes: bytes, assets: base.assets)
}
#endif
