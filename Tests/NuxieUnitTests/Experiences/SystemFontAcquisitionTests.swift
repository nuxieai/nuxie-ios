#if os(iOS)
import CryptoKit
import Foundation
import NuxieRuntime
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class SystemFontAcquisitionTests: XCTestCase {
    func testSignedSystemReleaseAcquiresNoFontAndPreparesOffline() async throws {
        try await verifyAcquisition(mixed: false)
    }

    func testSignedMixedReleaseDownloadsOnlyCDNFontAndPreparesOffline() async throws {
        try await verifyAcquisition(mixed: true)
    }

    private func verifyAcquisition(mixed: Bool) async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ExperienceRuntimeHostApp/Fixtures/font-converter")
        let profile = try JourneyPlaneProfile.decode(Data(contentsOf: fixture.appendingPathComponent("profile.json")))
        let entry = try XCTUnwrap(profile.releases.first)
        let original = try XCTUnwrap(Data(base64Encoded: entry.envelope.descriptorBytesBase64))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var render = try XCTUnwrap(root["render"] as? [String: Any])
        var fonts = try XCTUnwrap(render["assets"] as? [[String: Any]])
        let index = try XCTUnwrap(fonts.firstIndex { $0["kind"] as? String == "font" })
        var name = try XCTUnwrap(fonts[index]["riveUniqueName"] as? String)
        var mixedScene: Data?
        var mixedSceneKey: String?
        fonts[index] = ["kind": "font", "location": "system", "family": "System", "weight": "400",
            "style": "normal", "required": true, "riveAssetId": try XCTUnwrap(fonts[index]["riveAssetId"]), "riveUniqueName": name]
        if mixed {
            let candidates = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("fixtures/runtime/system-font-axes")
            let provenance = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
                candidates.appendingPathComponent("provenance.json"))) as? [String: Any])
            let scenes = try XCTUnwrap(provenance["scenes"] as? [[String: Any]])
            let evidence = try XCTUnwrap(scenes.first { $0["name"] as? String == "mixed" })
            let declarations = try XCTUnwrap(evidence["fonts"] as? [[String: Any]])
            var system = try XCTUnwrap(declarations.first { $0["location"] as? String == "system" })
            system["kind"] = "font"
            name = try XCTUnwrap(system["riveUniqueName"] as? String)
            let cdn = try XCTUnwrap(declarations.first { $0["location"] as? String == "cdn" })
            let originalRender = try XCTUnwrap((JSONSerialization.jsonObject(with: original) as? [String: Any])?["render"] as? [String: Any])
            var downloadable = try XCTUnwrap((originalRender["assets"] as? [[String: Any]])?.first { $0["kind"] as? String == "font" })
            XCTAssertEqual(downloadable["sha256"] as? String, evidence["cdnFontSha256"] as? String)
            downloadable["riveAssetId"] = cdn["riveAssetId"]
            downloadable["riveUniqueName"] = cdn["riveUniqueName"]
            fonts = [downloadable, system]
            let sceneBytes = try Data(contentsOf: candidates.appendingPathComponent("mixed.nux"))
            let hash = SHA256Provider.hexDigest(sceneBytes)
            XCTAssertEqual(hash, evidence["sha256"] as? String)
            let key = "renders/sha256/\(hash).riv"
            mixedScene = sceneBytes
            mixedSceneKey = key
            render["riv"] = ["key": key, "sha256": hash, "sizeBytes": sceneBytes.count, "contentType": "application/vnd.rive"]
            var screens = try XCTUnwrap(render["screens"] as? [[String: Any]])
            screens[0]["artboardName"] = "One"
            screens[0]["width"] = 320
            screens[0]["height"] = 640
            render["screens"] = screens
        }
        render["assets"] = fonts.sorted {
            ($0["key"] as? String ?? "system-font:\($0["riveUniqueName"]!)")
                < ($1["key"] as? String ?? "system-font:\($1["riveUniqueName"]!)")
        }
        root["render"] = render
        var requirements = try XCTUnwrap(root["requirements"] as? [String: Any])
        var capabilities = try XCTUnwrap(requirements["requiredCapabilities"] as? [String])
        capabilities.append("system-fonts")
        requirements["requiredCapabilities"] = capabilities.sorted()
        root["requirements"] = requirements
        let bytes = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        let envelope = JourneyReleaseEnvelope(
            mediaType: JourneyReleaseDescriptor.mediaType, encoding: "base64",
            descriptorSha256: SHA256Provider.hexDigest(bytes), descriptorSizeBytes: bytes.count,
            descriptorBytesBase64: bytes.base64EncodedString(), signature: .init(version: 1, algorithm: "ed25519",
                keyId: "TEST_ONLY_DEV_KEYPAIR", signatureBase64: try key.signature(for: Data(JourneyReleaseDescriptor.signatureDomain.utf8) + bytes).base64EncodedString()))
        let luau = try XCTUnwrap(requirements["luau"] as? [String: Any])
        let scene = try XCTUnwrap(requirements["sceneFormat"] as? [String: Any])
        let timezone = try XCTUnwrap(requirements["timezoneData"] as? [String: Any])
        let supported = JourneyReleaseSupportedRuntime(
            currentSdkVersion: try XCTUnwrap(requirements["minimumSdkVersion"] as? String),
            supportedRuntimeRevisions: [try XCTUnwrap(requirements["runtimeRevision"] as? String)],
            supportedLuauRevisions: [try XCTUnwrap(luau["revision"] as? String): Set(try XCTUnwrap(luau["bytecodeVersions"] as? [Int]))],
            sceneFormat: .init(major: try XCTUnwrap(scene["major"] as? Int), minor: try XCTUnwrap(scene["minor"] as? Int)),
            timezoneDataRevision: try XCTUnwrap(timezone["revision"] as? String),
            timezoneDataSHA256: try XCTUnwrap(timezone["sha256"] as? String), supportedCapabilities: Set(capabilities))
        let identity = try JSONDecoder().decode(JourneyReleaseIdentity.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(root["identity"])))
        let leg = try XCTUnwrap(root["leg"] as? [String: Any])
        let release = try JourneyReleaseVerifier().authenticateJourney(
            envelopeBytes: JSONEncoder().encode(envelope),
            authorizationKeys: [JourneyPackageAuthorizationKey(keyID: "TEST_ONLY_DEV_KEYPAIR", ed25519PublicKeyBytes: key.publicKey.rawRepresentation)],
            expectedIdentity: identity, expectedLegId: try XCTUnwrap(leg["id"] as? String), supportedRuntime: supported,
            replayPolicy: .active(minimumPublishedAtSeq: 0))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("system-font-acquisition-\(UUID())")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache); StubURLProtocol.reset() }
        StubURLProtocol.reset()
        StubURLProtocol.register(matcher: { _ in true }) { request in
            let file = fixture.appendingPathComponent(String(request.url!.path.dropFirst()))
            let path = String(request.url!.path.dropFirst())
            let downloadableKeys = Set(fonts.compactMap { $0["key"] as? String })
            if ["ttf", "otf"].contains(file.pathExtension) {
                XCTAssertTrue(mixed && downloadableKeys.contains(path), "Only the authenticated CDN font may download")
                guard mixed && downloadableKeys.contains(path) else { throw URLError(.resourceUnavailable) }
            }
            let data: Data
            if path == mixedSceneKey { data = try XCTUnwrap(mixedScene) }
            else { data = try Data(contentsOf: file) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Length": String(data.count),
                    "Content-Type": file.pathExtension == "riv" ? "application/vnd.rive" : "font/ttf"])!, data)
        }
        let fontCache = ExperienceRuntimeSystemFontCache()
        for offline in [false, true] {
            if offline {
                StubURLProtocol.reset()
                StubURLProtocol.register(matcher: { _ in true }) { _ in
                    XCTFail("Offline acquisition should use cached downloadable artifacts")
                    throw URLError(.notConnectedToInternet)
                }
            }
            let store = JourneyReleaseAcquisitionStore(cacheDirectory: cache, urlSession: TestURLSessionProvider.createTestSession())
            let presentation = try await store.preparePresentation(release: release, delivery: profile.delivery, productResolver: { _ in [] })
            let screenID = try XCTUnwrap(release.descriptor.leg.screens.first?.id)
            let acquired = try await presentation.artifactLoader(presentation.experience, nil, screenID)
            XCTAssertEqual(acquired.payload.renderPlan.fonts.count, mixed ? 1 : 0)
            XCTAssertEqual(acquired.payload.renderPlan.systemFonts.map(\.riveUniqueName), [name])
            XCTAssertEqual(acquired.payload.assets.filter { $0.kind == .font }.count, mixed ? 1 : 0)
            if mixed {
                let cdn = try XCTUnwrap(acquired.payload.assets.first { $0.kind == .font })
                XCTAssertNotEqual(cdn.riveUniqueName, name)
                XCTAssertEqual(SHA256Provider.hexDigest(try XCTUnwrap(cdn.bytes)), cdn.sha256)
                XCTAssertEqual(cdn.sha256, "b481b059ee94961c7b18585a596935aaa7cc44b68879c096d2cd06922e0431b1")
            }
            let prepared = try await ExperienceInteractivePreparation.prepare(payload: acquired.payload, systemFontCache: fontCache)
            let screen = try await prepared.openScreen(pixelWidth: 320, pixelHeight: 240)
            _ = try await screen.step(elapsedSeconds: 0)
            try await screen.close()
            let cacheIdentity = try ExperienceRuntimeSystemFontProvider.requestIdentity(weight: "400", style: "normal")
            struct CacheMiss: Error {}
            XCTAssertNoThrow(try fontCache.candidate(for: cacheIdentity) { throw CacheMiss() },
                "Successful configured native import must admit the candidate")
            if !offline {
                let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: acquired.payload.sceneBytes)
                let invalidScene = AuthenticatedRuntimePayload(authenticatedKeyID: acquired.payload.authenticatedKeyID,
                    requiredCapabilities: acquired.payload.requiredCapabilities, renderPlan: acquired.payload.renderPlan,
                    journey: acquired.payload.journey, definition: acquired.payload.definition,
                    sceneBytes: Data([0]), assets: acquired.payload.assets)
                do {
                    _ = try await ExperienceInteractivePreparation.prepare(payload: invalidScene,
                        inspectedCatalog: catalog, systemFontCache: fontCache)
                    XCTFail("Native import must reject the invalid scene")
                } catch {
                    XCTAssertThrowsError(try fontCache.candidate(for: cacheIdentity) { throw CacheMiss() },
                        "Failed native import must evict participating font data")
                }
            }
            if !offline {
                let requirement = try XCTUnwrap(acquired.payload.renderPlan.systemFonts.first)
                for declarations in [
                    [], [requirement, requirement],
                    [.init(riveAssetId: requirement.riveAssetId, riveUniqueName: "wrong-name", weight: "400", style: "normal")],
                ] as [[NativeExperienceSystemFontRequirement]] {
                    do {
                        _ = try await ExperienceInteractivePreparation.prepare(payload: replacingSystemFonts(acquired.payload, declarations))
                        XCTFail("Missing, duplicate, or mismatched System declarations must fail")
                    } catch let error as ExperienceInteractiveScreenError {
                        guard case .assetContract = error else { return XCTFail("Unexpected error: \(error)") }
                    }
                }
                let invalid = NativeExperienceSystemFontRequirement(riveAssetId: requirement.riveAssetId,
                    riveUniqueName: requirement.riveUniqueName, weight: "450", style: "normal")
                do {
                    _ = try await ExperienceInteractivePreparation.prepare(payload: replacingSystemFonts(acquired.payload, [invalid]))
                    XCTFail("Unusable System request must fail preparation")
                } catch let error as ExperienceInteractiveScreenError {
                    XCTAssertEqual(error, .systemFontPreparation(name, .unsupportedRequest))
                }
                if !mixed {
                    try await verifyProviderFailureMount(
                        acquired: acquired,
                        experience: presentation.experience,
                        payload: replacingSystemFonts(acquired.payload, [invalid]),
                        expected: .systemFontPreparation(name, .unsupportedRequest)
                    )
                }
            }
        }
    }

    @MainActor
    private func verifyProviderFailureMount(
        acquired: AcquiredExperienceArtifact,
        experience: Experience,
        payload: AuthenticatedRuntimePayload,
        expected: ExperienceInteractiveScreenError
    ) async throws {
        // The signed acquisition above is valid. Exercise the provider's failure
        // boundary by changing only its request after acquisition; do not weaken
        // release admission to manufacture an invalid signed weight.
        let handle = ExperienceInteractivePreparationHandle(
            cache: ExperienceInteractivePreparationCache(),
            provenance: "system-font-provider-mount-failure",
            payload: payload
        )
        let artifact = AcquiredExperienceArtifact(
            identity: acquired.identity, sceneURL: acquired.sceneURL,
            sceneBytes: acquired.sceneBytes, assetURLsByRiveUniqueName: acquired.assetURLsByRiveUniqueName,
            source: acquired.source, payload: payload, interactivePreparation: handle,
            products: acquired.products, resourceMetrics: acquired.resourceMetrics
        )
        let screen = try XCTUnwrap(payload.renderPlan.screens.first)
        let controller = ExperienceScreenViewController(
            experience: experience, artifact: LoadedExperienceArtifact(acquired: artifact),
            screen: screen, reduceMotion: false, delegate: nil
        )
        for _ in 0..<2 {
            do {
                try await controller.mountInteractiveScreen()
                XCTFail("A provider failure must reject real screen mounting")
            } catch let error as ExperienceInteractiveScreenError {
                XCTAssertEqual(error, expected)
                XCTAssertEqual(error.systemFontFailureCode, "system_font.unsupported_request")
            }
            let status = await handle.status()
            XCTAssertEqual(status, .miss, "Failed preparation must not be retained")
            XCTAssertEqual(controller.lifecyclePhase, .hidden)
        }
        // Failure never publishes an interactive screen or leaves shutdown work
        // behind; repeated cleanup uses the ordinary controller path.
        await controller.shutdownInteractiveScreen()
        await controller.shutdownInteractiveScreen()
        XCTAssertEqual(controller.lifecyclePhase, .hidden)

        let eventLog = MockEventLog()
        let failed = expectation(description: "real controller records provider failure")
        eventLog.capturedEventObserver = { event in
            if event.name == JourneyEvents.experienceArtifactLoadFailed { failed.fulfill() }
        }
        let products = MockProductService()
        let sink = DiscardingSystemEventSink()
        let transactions = TransactionService(
            productService: products, transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: MockFactory.shared.dateProvider,
            settings: NuxieRuntimeSettings(configuration: NuxieConfiguration(apiKey: "test-api-key")),
            eventSink: sink
        )
        let experienceController = ExperienceViewController(
            experience: experience, artifactLoader: { _, _, _ in artifact }, eventLog: eventLog,
            transactionService: transactions, productService: products, systemEventSink: sink
        )
        experienceController.loadViewIfNeeded()
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertFalse(experienceController.errorView.isHidden)
        XCTAssertTrue(experienceController.loadingView.isHidden)
        XCTAssertTrue(experienceController.children.isEmpty, "Failed mounting must remove child screens")
        await experienceController.shutdownRuntime()
        await experienceController.shutdownRuntime()
        let failures = eventLog.trackedEvents.filter { $0.name == JourneyEvents.experienceArtifactLoadFailed }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.properties?["error_code"] as? String, "system_font.unsupported_request")
        XCTAssertFalse(eventLog.trackedEvents.contains { $0.name == JourneyEvents.experienceArtifactLoadSucceeded })
    }

    private func replacingSystemFonts(_ payload: AuthenticatedRuntimePayload, _ fonts: [NativeExperienceSystemFontRequirement]) -> AuthenticatedRuntimePayload {
        let plan = payload.renderPlan
        return AuthenticatedRuntimePayload(authenticatedKeyID: payload.authenticatedKeyID,
            requiredCapabilities: payload.requiredCapabilities,
            renderPlan: .init(identity: plan.identity, scene: plan.scene, entry: plan.entry,
                screens: plan.screens, transitions: plan.transitions, textInputs: plan.textInputs,
                images: plan.images, fonts: plan.fonts, systemFonts: fonts),
            journey: payload.journey, definition: payload.definition, sceneBytes: payload.sceneBytes, assets: payload.assets)
    }
}
#endif
