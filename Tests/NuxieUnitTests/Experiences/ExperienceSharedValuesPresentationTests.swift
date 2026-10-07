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
        try await withPresentation(fixture: fixture) { presentations, journeys, _ in
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
        }
    }

    func testPublishedContinueTapRoutesWithItsNewRunValue() async throws {
        let expected = try PublishedRunValuesFixture.expectations()
        let fixture = try await signedFixture(kind: .publishedRunValues)
        try await withPresentation(fixture: fixture) { presentations, _, events in
            let tap = try await waitForScreen("tap", presentations: presentations)
            let before = try await tap.runtimeSnapshot()
            XCTAssertEqual(before.values.first { $0.name == "trip_days" }?.value, .number(expected.tap.before))
            let surface = try XCTUnwrap(tap.view.subviews.compactMap { $0 as? ExperienceRuntimeSurfaceView }.first)
            // Geometry inspection does not add an unqualified capability to the signed release.
            let interactive = try XCTUnwrap(Mirror(reflecting: tap).children.first {
                $0.label == "interactiveScreen"
            }?.value as? ExperienceInteractiveScreen)
            func hits(_ point: CGPoint) async throws -> Bool {
                let down = try await interactive.step(pointers: [.init(kind: .down,
                    x: Float(point.x), y: Float(point.y))], elapsedSeconds: 0)
                let exit = try await interactive.step(pointers: [.init(kind: .exit,
                    x: Float(point.x), y: Float(point.y))], elapsedSeconds: 0)
                XCTAssertTrue((down.effects + exit.effects).allSatisfy { effect in
                    if case .viewModelChange = effect.kind { return true }
                    return false
                },
                    "Geometry probes must not consume a native event or control action")
                return down.pointerHits.contains { $0 != .none }
            }
            let artboard = interactive.artboardBounds
            var hit: CGPoint?
            for y in stride(from: artboard.minY + 0.5, to: artboard.maxY, by: 4) {
                for x in stride(from: artboard.minX + 0.5, to: artboard.maxX, by: 4) {
                    let point = CGPoint(x: x, y: y)
                    if try await hits(point) { hit = point; break }
                }
                if hit != nil { break }
            }
            let inside = try XCTUnwrap(hit, "The published fixture's sole button has a native pointer hit")
            func edge(_ inside: CGFloat, _ outside: CGFloat,
                probe: (CGFloat) async throws -> Bool) async throws -> CGFloat {
                var yes = inside
                var no = outside
                for _ in 0..<20 {
                    let mid = (yes + no) / 2
                    if try await probe(mid) { yes = mid } else { no = mid }
                }
                return yes
            }
            let left = try await edge(inside.x, artboard.minX - 1) { try await hits(CGPoint(x: $0, y: inside.y)) }
            let right = try await edge(inside.x, artboard.maxX + 1) { try await hits(CGPoint(x: $0, y: inside.y)) }
            let top = try await edge(inside.y, artboard.minY - 1) { try await hits(CGPoint(x: inside.x, y: $0)) }
            let bottom = try await edge(inside.y, artboard.maxY + 1) { try await hits(CGPoint(x: inside.x, y: $0)) }
            let transform = try XCTUnwrap(ExperienceLayoutTransform(
                artboardBounds: artboard, viewportBounds: surface.bounds))
            let bounds = transform.viewportRect(fromArtboard: CGRect(x: left, y: top,
                width: right - left, height: bottom - top))
            let geometry = XCTAttachment(string: "F4 Continue native hit bounds: \(bounds)")
            geometry.lifetime = .keepAlways
            self.add(geometry)
            let probed = try await tap.runtimeSnapshot()
            XCTAssertEqual(probed.values.first { $0.name == "trip_days" }?.value, .number(expected.tap.before))
            XCTAssertFalse(events.routedEvents.contains { $0.name == "continue" })
            XCTAssertFalse(bounds.isEmpty)
            let point = CGPoint(x: bounds.midX, y: bounds.midY)
            let pointer = NSObject()
            let observer = try XCTUnwrap(surface.runtimeObserver)
            let now = ProcessInfo.processInfo.systemUptime
            // Same platform pointer seam as touchesBegan/touchesEnded, then the real native player.
            observer.runtimeSurfaceViewDidReceivePointerEvents([
                .init(source: ExperienceRuntimePointerSourceID(pointer), kind: .down, location: point, timestampSeconds: now),
                .init(source: ExperienceRuntimePointerSourceID(pointer), kind: .up, location: point, timestampSeconds: now + 0.01),
            ])
            let level = try await waitForScreen("level", presentations: presentations)
            let after = try await level.runtimeSnapshot()
            XCTAssertEqual(after.values.first { $0.name == "trip_days" }?.value, .number(expected.tap.after))
            XCTAssertEqual(before.values.first { $0.name == expected.property }?.value,
                after.values.first { $0.name == expected.property }?.value)
            XCTAssertEqual(events.routedEvents.filter { $0.name == "continue" }.count, 1,
                "The signed Journey admits exactly one real native emit without a publisher action id")
            XCTAssertFalse(events.routedEvents.contains { $0.name == JourneyEvents.journeyCompleted },
                "The route must read 30 before advancing; the stale-value branch completes instead")
        }
    }

    private func withPresentation(fixture: Fixture,
        body: (ExperiencePresentationService, JourneyService, MockEventLog) async throws -> Void) async throws {
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
            try await body(presentations, journeys, events)
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

    private enum FixtureKind { case sharedValues, publishedRunValues }

    private func signedFixture(kind: FixtureKind = .sharedValues) async throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ExperienceRuntimeHostApp/Fixtures/font-converter/profile.json"))) as? [String: Any])
        var profile = base
        var entry = try XCTUnwrap(XCTUnwrap(base["releases"] as? [[String: Any]]).first)
        let envelope = try XCTUnwrap(entry["envelope"] as? [String: Any])
        var descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: XCTUnwrap(envelope["descriptorBytesBase64"] as? String)))) as? [String: Any])
        let directory = kind == .sharedValues ? SharedValuesFixture.directory : PublishedRunValuesFixture.directory
        let scene = try Data(contentsOf: directory.appendingPathComponent("screen.riv"))
        let provenance = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("provenance.json"))) as? [String: Any])
        let names: [String]
        if kind == .sharedValues { names = ["first", "long", "short"] }
        else { names = try PublishedRunValuesFixture.expectations().screens }
        let entryScreen = try XCTUnwrap(names.first)
        let capabilities = ["nux", "system-fonts"]
        var leg = try XCTUnwrap(descriptor["leg"] as? [String: Any])
        leg["entryCondition"] = ["type": "app_foregrounded"]
        leg["entryStepId"] = "present"
        leg["steps"] = [["kind": "action", "id": "present", "action": ["type": "navigate", "screenId": entryScreen], "outlets": [:]]]
        leg["screens"] = names.map { ["id": $0, "defaultViewModelName": "Runtime \($0) scr_screens_s\($0)", "defaultInstanceId": "\($0)-root", "responseCaptures": []] as [String: Any] }
        leg["routes"] = []
        if kind == .publishedRunValues {
            let expected = try PublishedRunValuesFixture.expectations()
            leg["steps"] = [
                ["kind": "action", "id": "present", "action": ["type": "navigate", "screenId": "tap"], "outlets": [:]],
                ["kind": "action", "id": "read-new-value", "action": ["type": "condition", "branches": [
                    ["id": "changed", "condition": ["type": "Compare", "op": "==",
                        "left": ["type": "Response.Field", "key": "trip_days"],
                        "right": ["type": "Number", "value": expected.tap.after]]]
                ]], "outlets": ["changed": "level", "default": "stale"]],
                ["kind": "action", "id": "level", "action": ["type": "navigate", "screenId": "level"], "outlets": [:]],
                ["kind": "complete", "id": "stale", "outcome": "stale"]
            ]
            leg["routes"] = [["eventName": "continue", "host": ["kind": "screen", "screenId": "tap"], "entryStepId": "read-new-value"]]
        }
        descriptor["leg"] = leg
        descriptor["viewModelValues"] = []
        descriptor["screenBehaviors"] = names.sorted().map { ["screenId": $0, "controls": []] as [String: Any] }
        let hash = SHA256Provider.hexDigest(scene)
        descriptor["render"] = ["renderer": "nux", "nux": ["key": "renders/sha256/\(hash).nux", "sha256": hash, "sizeBytes": scene.count, "contentType": "application/vnd.nuxie.scene"],
            "assets": (try XCTUnwrap(provenance["fonts"] as? [[String: Any]])).map { $0.merging(["kind": "font"]) { _, new in new } },
            "screens": names.map { ["id": $0, "artboardId": $0, "artboardName": $0, "width": 393, "height": 852] as [String: Any] }, "transitions": [], "textInputs": []]
        var requirements = try XCTUnwrap(descriptor["requirements"] as? [String: Any])
        requirements["requiredCapabilities"] = capabilities
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
            supportedCapabilities: Set(capabilities))
        let catalog = JourneyProfileCatalog(authorizationKeys: [.init(keyID: "TEST_ONLY_DEV_KEYPAIR", ed25519PublicKeyBytes: key.publicKey.rawRepresentation)],
            supportedRuntime: supported, highWaterStore: InMemoryJourneyReleaseHighWaterStore())
        // The caller awaits authentication before installing this profile.
        return Fixture(scene: scene, snapshot: try await catalog.prepare(decoded, authority: authority).snapshot,
            authority: authority, keys: [.init(keyID: "TEST_ONLY_DEV_KEYPAIR", ed25519PublicKeyBytes: key.publicKey.rawRepresentation)], supported: supported)
    }
}
#endif
