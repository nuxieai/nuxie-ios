#if canImport(UIKit) && NUXIE_HOSTED_INPUT_TESTS
import CryptoKit
import UIKit
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

@MainActor
final class ExperienceSharedValuesPresentationTests: XCTestCase {
    func testNextScreenFirstPresentationReadsRunWrite() async throws {
        let fixture = try await signedFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shared-values-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: directory) }
        StubURLProtocol.register(matcher: { $0.url?.host == "shared-values.nuxie.test" }) { request in
            (try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/vnd.nuxie.scene", "Content-Length": String(fixture.scene.count)])), fixture.scene)
        }
        let identity = MockIdentityService()
        identity.setDistinctId("shared-owner")
        let events = MockEventLog()
        events.identity = identity
        let configuration = NuxieConfiguration(apiKey: "shared-values-test")
        configuration.testingOverrides.customStoragePath = directory
        configuration.testingOverrides.suppressBackgroundWork = true
        let products = ProductService()
        let transactions = TransactionService(productService: products, transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: PendingPurchaseStore(customStoragePath: directory), dateProvider: SystemDateProvider(),
            settings: NuxieRuntimeSettings(configuration: configuration), eventSink: DiscardingSystemEventSink())
        let acquisition = JourneyReleaseAcquisitionStore(cacheDirectory: directory.appendingPathComponent("assets"),
            urlSession: TestURLSessionProvider.createTestSession())
        let experiences = ExperienceService(productService: products, eventLog: events,
            transactionServiceProvider: { transactions }, systemEventSink: DiscardingSystemEventSink(), releaseStore: acquisition)
        let presentations = ExperiencePresentationService(experiences: experiences, eventLog: events, identity: identity)
        let journeys = JourneyService(identity: identity, events: events, dateProvider: SystemDateProvider(),
            sleepProvider: SystemSleepProvider(), journalDirectory: directory, storageScope: .init(authority: fixture.authority),
            featureAccess: { _ in nil }, dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            presenter: presentations, pinnedReleaseAuthenticator: { entry, reference in
                try JourneyReleaseVerifier().authenticateJourney(envelopeBytes: JSONEncoder().encode(entry.envelope),
                    authorizationKeys: fixture.keys, expectedIdentity: entry.locator.identity, expectedLegId: reference.legId,
                    supportedRuntime: fixture.supported, replayPolicy: .pinned(experienceVersionId: reference.versionId,
                        buildId: entry.locator.buildId, descriptorSHA256: reference.descriptorSha256))
            }, timezones: try XCTUnwrap(SignedTimezoneBundle.installed))
        do {
            let prepared = try await experiences.prepareJourneyProfile(fixture.snapshot)
            _ = await experiences.commitJourneyProfile(prepared, generation: 1, admission: nil)
            await journeys.initialize()
            presentations.onAppBecameActive()
            await journeys.profileDidCommit(fixture.snapshot, artifacts: prepared.artifacts,
                authority: fixture.authority, admissionGeneration: 1, distinctId: "shared-owner")
            await journeys.onAppBecameActive()
            let first = try await waitForScreen("first", presentations: presentations)
            let firstRoot = try await first.runtimeSnapshot()
            let vmPath = VmPathRef(path: "experience/trip_days")
            XCTAssertTrue(first.applyValue(path: vmPath, value: 30, screenId: "first", instanceId: "first-root"))
            for _ in 0..<200 {
                if try await first.runtimeSnapshot().values.first(where: { $0.name == "trip_days" })?.value == .number(30) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            presentations.onAppDidEnterBackground()
            await journeys.onAppDidEnterBackground()
            presentations.onAppBecameActive()
            await journeys.onAppBecameActive()
            let resumed = try await first.runtimeSnapshot()
            XCTAssertEqual(resumed.values.first { $0.name == "trip_days" }?.value, .number(30))
            let controller = try XCTUnwrap(presentations.currentExperienceViewController)
            let result = await controller.navigateAndWaitResult(to: "long", transition: nil)
            XCTAssertTrue(result.reachedTarget)
            let next = try await waitForScreen("long", presentations: presentations)
            let nextRoot = try await next.runtimeSnapshot()
            XCTAssertEqual(nextRoot.values.first { $0.name == "trip_days" }?.value, .number(30))
            XCTAssertEqual(firstRoot.values.first { $0.name == "experience" }?.value,
                nextRoot.values.first { $0.name == "experience" }?.value)
            await journeys.shutdown()
        } catch {
            await journeys.shutdown()
            throw error
        }
    }

    private func waitForScreen(_ id: String, presentations: ExperiencePresentationService) async throws -> ExperienceScreenViewController {
        func find(_ controller: UIViewController) -> ExperienceScreenViewController? {
            if let screen = controller as? ExperienceScreenViewController, screen.screenId == id { return screen }
            return controller.children.compactMap(find).first
                ?? controller.presentedViewController.flatMap(find)
        }
        for _ in 0..<400 {
            if let controller = presentations.currentExperienceViewController, let screen = find(controller),
               screen.view.window != nil, screen.hasPresentedRuntimeFrame {
                return screen
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw NSError(domain: "SharedValuesTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Screen \(id) did not present"])
    }

    private struct Fixture: Sendable {
        let scene: Data
        let snapshot: JourneyProfileCatalog.Snapshot
        let authority: ProfileDeliveryAuthority
        let keys: [JourneyPackageAuthorizationKey]
        let supported: JourneyReleaseSupportedRuntime
    }

    private func signedFixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ExperienceRuntimeHostApp/Fixtures/font-converter/profile.json"))) as? [String: Any])
        var profile = base
        var entry = try XCTUnwrap(XCTUnwrap(base["releases"] as? [[String: Any]]).first)
        let envelope = try XCTUnwrap(entry["envelope"] as? [String: Any])
        var descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: XCTUnwrap(envelope["descriptorBytesBase64"] as? String)))) as? [String: Any])
        let scene = try Data(contentsOf: SharedValuesFixture.directory.appendingPathComponent("screen.riv"))
        let provenance = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: SharedValuesFixture.directory.appendingPathComponent("provenance.json"))) as? [String: Any])
        let names = ["first", "long", "short"]
        var leg = try XCTUnwrap(descriptor["leg"] as? [String: Any])
        leg["entryCondition"] = ["type": "app_foregrounded"]
        leg["entryStepId"] = "present"
        leg["steps"] = [["kind": "action", "id": "present", "action": ["type": "navigate", "screenId": "first"], "outlets": [:]]]
        leg["screens"] = names.map { ["id": $0, "defaultViewModelName": "Runtime \($0) scr_screens_s\($0)", "defaultInstanceId": "\($0)-root", "responseCaptures": []] as [String: Any] }
        leg["routes"] = []
        descriptor["leg"] = leg
        descriptor["viewModelValues"] = []
        descriptor["screenBehaviors"] = names.map { ["screenId": $0, "controls": []] as [String: Any] }
        let hash = SHA256Provider.hexDigest(scene)
        descriptor["render"] = ["renderer": "nux", "nux": ["key": "renders/sha256/\(hash).nux", "sha256": hash, "sizeBytes": scene.count, "contentType": "application/vnd.nuxie.scene"],
            "assets": (try XCTUnwrap(provenance["fonts"] as? [[String: Any]])).map { $0.merging(["kind": "font"]) { _, new in new } },
            "screens": names.map { ["id": $0, "artboardId": $0, "artboardName": $0, "width": 393, "height": 852] as [String: Any] }, "transitions": [], "textInputs": []]
        var requirements = try XCTUnwrap(descriptor["requirements"] as? [String: Any])
        requirements["requiredCapabilities"] = ["nux", "system-fonts"]
        descriptor["requirements"] = requirements
        let bytes = try JSONSerialization.data(withJSONObject: descriptor, options: .sortedKeys)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        let signed = JourneyReleaseEnvelope(mediaType: JourneyReleaseDescriptor.mediaType, encoding: "base64",
            descriptorSha256: SHA256Provider.hexDigest(bytes), descriptorSizeBytes: bytes.count,
            descriptorBytesBase64: bytes.base64EncodedString(), signature: .init(version: 1, algorithm: "ed25519", keyId: "TEST_ONLY_DEV_KEYPAIR",
                signatureBase64: try key.signature(for: Data(JourneyReleaseDescriptor.signatureDomain.utf8) + bytes).base64EncodedString()))
        entry["envelope"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(signed))
        profile["releases"] = [entry]
        var arm = try XCTUnwrap(XCTUnwrap(profile["armedLegs"] as? [[String: Any]]).first)
        var reference = try XCTUnwrap(arm["reference"] as? [String: Any])
        reference["descriptorSha256"] = signed.descriptorSha256
        arm["reference"] = reference
        arm["entryCondition"] = ["type": "app_foregrounded"]
        profile["armedLegs"] = [arm]
        profile["delivery"] = ["renderBaseUrl": "https://shared-values.nuxie.test/", "assetBaseUrl": "https://shared-values.nuxie.test/"]
        let decoded = try JourneyPlaneProfile.decode(JSONSerialization.data(withJSONObject: profile))
        let releaseIdentity = try JSONDecoder().decode(JourneyReleaseIdentity.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(descriptor["identity"])))
        let authority = ProfileDeliveryAuthority(appId: releaseIdentity.appId, environment: releaseIdentity.environment)
        let luau = try XCTUnwrap(requirements["luau"] as? [String: Any]), format = try XCTUnwrap(requirements["sceneFormat"] as? [String: Any]), tz = try XCTUnwrap(requirements["timezoneData"] as? [String: Any])
        let supported = JourneyReleaseSupportedRuntime(currentSdkVersion: try XCTUnwrap(requirements["minimumSdkVersion"] as? String),
            supportedRuntimeRevisions: [try XCTUnwrap(requirements["runtimeRevision"] as? String)],
            supportedLuauRevisions: [try XCTUnwrap(luau["revision"] as? String): Set(try XCTUnwrap(luau["bytecodeVersions"] as? [Int]))],
            sceneFormat: .init(major: try XCTUnwrap(format["major"] as? Int), minor: try XCTUnwrap(format["minor"] as? Int)),
            timezoneDataRevision: try XCTUnwrap(tz["revision"] as? String), timezoneDataSHA256: try XCTUnwrap(tz["sha256"] as? String),
            supportedCapabilities: ["nux", "system-fonts"])
        let catalog = JourneyProfileCatalog(authorizationKeys: [.init(keyID: "TEST_ONLY_DEV_KEYPAIR", ed25519PublicKeyBytes: key.publicKey.rawRepresentation)],
            supportedRuntime: supported, highWaterStore: InMemoryJourneyReleaseHighWaterStore())
        // The caller awaits authentication before installing this profile.
        return Fixture(scene: scene, snapshot: try await catalog.prepare(decoded, authority: authority).snapshot,
            authority: authority, keys: [.init(keyID: "TEST_ONLY_DEV_KEYPAIR", ed25519PublicKeyBytes: key.publicKey.rawRepresentation)], supported: supported)
    }
}
#endif
