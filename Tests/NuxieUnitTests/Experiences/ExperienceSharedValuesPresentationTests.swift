#if canImport(UIKit) && NUXIE_HOSTED_INPUT_TESTS
import CryptoKit
import QuartzCore
import UIKit
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport
@testable import NuxieRuntime

@MainActor
final class ExperienceSharedValuesPresentationTests: XCTestCase {
    func testPublishedScriptTapIncrementsAndDrawsCount() async throws {
        let fixture = try await publishedScriptTapFixture()
        try await withPresentation(fixture: fixture) { presentations, _, _ in
            let screen = try await waitForScreen("scr_screens_stap", presentations: presentations)
            let surface = try XCTUnwrap(screen.view.subviews.compactMap { $0 as? ExperienceRuntimeSurfaceView }.first)
            let interactive = try XCTUnwrap(Mirror(reflecting: screen).children.first {
                $0.label == "interactiveScreen"
            }?.value as? ExperienceInteractiveScreen)
            let transform = try XCTUnwrap(ExperienceLayoutTransform(
                artboardBounds: interactive.artboardBounds, viewportBounds: surface.bounds))
            let rect = transform.viewportRect(fromArtboard: CGRect(x: 20, y: 20, width: 160, height: 60))
            let observer = try XCTUnwrap(surface.runtimeObserver)
            @MainActor func captureCount(_ expected: Int) async throws -> Data {
                let device = try await interactive.metalDevice().value
                let width = Int(surface.metalLayer.drawableSize.width)
                let height = Int(surface.metalLayer.drawableSize.height)
                let layer = CAMetalLayer()
                layer.device = device
                layer.pixelFormat = .bgra8Unorm
                layer.framebufferOnly = false
                layer.drawableSize = CGSize(width: width, height: height)
                let drawable = try XCTUnwrap(layer.nextDrawable())
                let stride = (width * 4 + 255) & ~255
                let buffer = try XCTUnwrap(device.makeBuffer(length: stride * height, options: .storageModeShared))
                let rendered = self.expectation(description: "F6 count frame")
                let frame = try await interactive.renderFrame(layoutScaleFactor: Float(surface.runtimeDisplayScale),
                    drawable: ExperienceInteractiveDrawable(drawable), clearColor: 0xffffffff,
                    capturesSemantics: false, readback: NuxieNativeFrameReadback(buffer: buffer, bytesPerRow: stride),
                    completion: { rendered.fulfill() })
                await self.fulfillment(of: [rendered], timeout: 5)
                XCTAssertEqual(frame.outcome.disposition, .presented)
                var pixels = Data()
                for row in 0..<height {
                    pixels.append(buffer.contents().assumingMemoryBound(to: UInt8.self) + row * stride, count: width * 4)
                }
                let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
                let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                let attachment = XCTAttachment(image: UIImage(cgImage: image))
                attachment.name = "F6-count-\(expected)"
                attachment.lifetime = .keepAlways
                self.add(attachment)
                return pixels
            }
            func count() async throws -> Float? {
                let snapshot = try await screen.runtimeSnapshot()
                guard case .referencedInstance(let state) = snapshot.values.first(where: {
                    $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "state"
                })?.value, case .number(let count) = snapshot.values.first(where: {
                    $0.ownerInstanceID == state && $0.name == "count"
                })?.value else { return nil }
                return count
            }
            let initial = try await count()
            XCTAssertEqual(initial, 0)
            var previousPixels = try await captureCount(0)
            for expected: Float in [1, 2, 3] {
                let pointer = NSObject()
                let now = ProcessInfo.processInfo.systemUptime
                observer.runtimeSurfaceViewDidReceivePointerEvents([
                    .init(source: ExperienceRuntimePointerSourceID(pointer), kind: .down,
                        location: CGPoint(x: rect.midX, y: rect.midY), timestampSeconds: now),
                    .init(source: ExperienceRuntimePointerSourceID(pointer), kind: .up,
                        location: CGPoint(x: rect.midX, y: rect.midY), timestampSeconds: now + 0.01),
                ])
                var actual = try await count()
                for _ in 0..<200 {
                    if actual == expected { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                    actual = try await count()
                }
                XCTAssertEqual(actual, expected, "A real tap must execute the published Luau action")
                try await Task.sleep(nanoseconds: 100_000_000)
                let pixels = try await captureCount(Int(expected))
                XCTAssertNotEqual(pixels, previousPixels, "The native count label redraws after the tap")
                previousPixels = pixels
            }
        }
    }

    private func publishedScriptTapFixture() async throws -> Fixture {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent().appendingPathComponent("script-tap")
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("profile-entry.json"))) as? [String: Any])
        let locator = try XCTUnwrap(entry["locator"] as? [String: Any])
        let envelope = try XCTUnwrap(entry["envelope"] as? [String: Any])
        let profile: [String: Any] = [
            "schemaVersion": "nuxie.journey-plane-profile.v2", "status": "ok",
            "delivery": ["renderBaseUrl": "https://shared-values.nuxie.test/", "assetBaseUrl": "https://shared-values.nuxie.test/"],
            "features": [], "facts": ["properties": [:], "memberships": [:], "assignments": [:]],
            "releases": [entry],
            "armedLegs": [["reference": ["experienceId": locator["experienceId"]!,
                "versionId": locator["experienceVersionId"]!, "legId": locator["legId"]!,
                "descriptorSha256": envelope["descriptorSha256"]!],
                "binding": ["type": "new"], "entryCondition": ["type": "app_foregrounded"],
                "context": ["event": [:], "responses": [:]]]],
        ]
        let keys = [JourneyPackageAuthorizationKey(keyID: "TEST_ONLY_DEV_KEYPAIR",
            ed25519PublicKeyBytes: try XCTUnwrap(Data(base64Encoded: "IVL40Zt5HSRFMkLhXy6rbLfP+ntqXtMAl5YOBpiB2xI=")))]
        let authority = ProfileDeliveryAuthority(appId: try XCTUnwrap(locator["appId"] as? String),
            environment: try XCTUnwrap(locator["environment"] as? String))
        let supported = JourneyReleaseRuntime.current
        let catalog = JourneyProfileCatalog(authorizationKeys: keys, supportedRuntime: supported,
            highWaterStore: InMemoryJourneyReleaseHighWaterStore())
        let decoded = try JourneyPlaneProfile.decode(JSONSerialization.data(withJSONObject: profile))
        let snapshot = try await catalog.prepare(decoded, authority: authority).snapshot
        return Fixture(scene: try Data(contentsOf: directory.appendingPathComponent("screen.riv")),
            assetDirectory: directory, snapshot: snapshot, authority: authority, keys: keys, supported: supported)
    }

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

    func testPublishedEnvironmentReceivesHostInsetsAndMotionBeforeAndAfterMount() async throws {
        let fixture = try await signedFixture(kind: .publishedRunValues)
        try await withPresentation(fixture: fixture) { presentations, _, _ in
            let tap = try await waitForScreen("tap", presentations: presentations)
            let fields = Mirror(reflecting: tap).children
            let artifact = try XCTUnwrap(fields.first { $0.label == "artifact" }?.value as? LoadedExperienceArtifact)
            let experience = try XCTUnwrap(fields.first { $0.label == "experience" }?.value as? Experience)
            let manifest = try XCTUnwrap(artifact.payload.renderPlan.screens.first { $0.screenId == "device" })
            let controller = ExperienceScreenViewController(experience: experience, artifact: artifact,
                screen: manifest, reduceMotion: true, delegate: nil)
            let view = EnvironmentInsetsView()
            view.testInsets = UIEdgeInsets(top: 59, left: 7, bottom: 34, right: 9)
            view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            controller.view = view
            try await controller.mountInteractiveScreen()
            do {
                let mounted = Mirror(reflecting: controller).children
                let screen = try XCTUnwrap(mounted.first { $0.label == "interactiveScreen" }?.value as? ExperienceInteractiveScreen)
                let loop = try XCTUnwrap(mounted.first { $0.label == "presentationLoop" }?.value as? ExperienceRuntimePresentationLoop)
                @MainActor func assertEnvironment(_ motion: Bool) async throws {
                    let result = try await screen.environmentSnapshot()
                    let snapshot = try XCTUnwrap(result)
                    XCTAssertEqual(snapshot.values.first { $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "reduceMotion" }?.value, .bool(motion))
                    guard case .referencedInstance(let owner) = snapshot.values.first(where: {
                        $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "safeArea"
                    })?.value else { return XCTFail("env has an authored safeArea instance") }
                    for (side, value) in [("top", view.testInsets.top), ("bottom", view.testInsets.bottom),
                                          ("left", view.testInsets.left), ("right", view.testInsets.right)] {
                        XCTAssertEqual(snapshot.values.first { $0.ownerInstanceID == owner && $0.name == side }?.value, .number(Float(value)))
                    }
                }
                try await assertEnvironment(true)
                await controller.updateReduceMotion(false)
                view.testInsets = UIEdgeInsets(top: 20, left: 3, bottom: 0, right: 4)
                for size in [CGSize.zero, CGSize(width: 393, height: 852), CGSize(width: 820, height: 1180)] {
                    view.frame = CGRect(origin: .zero, size: size)
                    controller.syncSafeAreaInsets(force: true)
                    try await loop.advanceZeroDelta()
                    try await assertEnvironment(false)
                }
                await controller.shutdownInteractiveScreen()
            } catch {
                await controller.shutdownInteractiveScreen()
                throw error
            }
        }
    }

    func testPublishedF5WaitedFailureThenRetryControlsItsJourney() async throws {
        let fixture = try await signedFixture(kind: .publishedForms)
        let first = expectation(description: "first awaited save sent")
        let second = expectation(description: "second awaited save sent")
        let transport = FormSaveTestTransport(started: [first, second])
        try await withPresentation(fixture: fixture, transport: transport) { presentations, _, events in
            let controller = try await waitForScreen("scr_screens_sfeedback", presentations: presentations)
            let surface = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? ExperienceRuntimeSurfaceView }.first)
            XCTAssertTrue(controller.applyValue(path: VmPathRef(path: "experience/responses:feedback/stars"),
                value: 4, screenId: controller.screenId, instanceId: "vmi_runtime_scr_screens_sfeedback"))
            func field(_ name: String) async throws -> ExperienceInteractiveViewModelValue? {
                let snapshot = try await controller.runtimeSnapshot()
                guard case .referencedInstance(let shared) = snapshot.values.first(where: {
                    $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "experience"
                })?.value, case .referencedInstance(let form) = snapshot.values.first(where: {
                    $0.ownerInstanceID == shared && $0.name == "responses:feedback"
                })?.value else { throw CocoaError(.coderInvalidValue) }
                return snapshot.values.first { $0.ownerInstanceID == form && $0.name == name }?.value
            }
            let interactive = try XCTUnwrap(Mirror(reflecting: controller).children.first {
                $0.label == "interactiveScreen"
            }?.value as? ExperienceInteractiveScreen)
            let transform = try XCTUnwrap(ExperienceLayoutTransform(
                artboardBounds: interactive.artboardBounds, viewportBounds: surface.bounds))
            // Measured on these published bytes by the isolated native listener proof.
            let point = transform.viewportPoint(fromArtboard: CGPoint(x: 121, y: 1))
            let pointer = NSObject()
            let observer = try XCTUnwrap(surface.runtimeObserver)
            @MainActor func send() {
                let now = ProcessInfo.processInfo.systemUptime
                observer.runtimeSurfaceViewDidReceivePointerEvents([
                    .init(source: ExperienceRuntimePointerSourceID(pointer), kind: .down,
                        location: point, timestampSeconds: now),
                    .init(source: ExperienceRuntimePointerSourceID(pointer), kind: .up,
                        location: point, timestampSeconds: now + 0.01),
                ])
            }
            for _ in 0..<200 {
                if try await field("valid") == .bool(true) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            send()
            await fulfillment(of: [first], timeout: 5)
            let sentFirst = await transport.requests()
            XCTAssertEqual(sentFirst.map(\.sequence), [1])
            XCTAssertEqual(sentFirst.first?.answers, ["stars": .number(4)])
            let saving = try await field("saving")
            XCTAssertEqual(saving, .bool(true))
            XCTAssertFalse(events.routedEvents.contains { $0.name == "sent" })
            await transport.release(sequence: 1, code: .saveUnavailable)
            for _ in 0..<200 {
                if try await field("saveError") == .bytes(Data("save_unavailable".utf8)) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let error = try await field("saveError")
            let stopped = try await field("saving")
            XCTAssertEqual(error, .bytes(Data("save_unavailable".utf8)))
            XCTAssertEqual(stopped, .bool(false))
            XCTAssertFalse(events.routedEvents.contains { $0.name == "sent" })
            send()
            await fulfillment(of: [second], timeout: 5)
            let retrySaving = try await field("saving")
            let retryError = try await field("saveError")
            XCTAssertEqual(retrySaving, .bool(true))
            XCTAssertEqual(retryError, .bytes(Data()))
            await transport.release(sequence: 2, code: .saved)
            for _ in 0..<200 {
                if events.routedEvents.contains(where: { $0.name == JourneyEvents.journeyCompleted }) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let completion = events.routedEvents.first { $0.name == JourneyEvents.journeyCompleted }
            XCTAssertEqual(completion?.properties["outcome"] as? String, "done", "Save confirmation must complete normally")
            XCTAssertEqual(events.routedEvents.filter { $0.name == "sent" }.count, 1)
            XCTAssertEqual(events.routedEvents.filter { $0.name == JourneyEvents.journeyCompleted }.count, 1)
            let requests = await transport.requests()
            XCTAssertEqual(requests.map(\.sequence), [1, 2])
        }
    }

    func testPublishedF5FormAnswerRoutesBothBranchesAndBoundary() async throws {
        for (days, eventName) in [(7.0, "short_trip"), (14.0, "short_trip"), (23.0, "long_trip")] {
            let fixture = try await signedFixture(kind: .publishedForms, formsScreen: "departure", publishedFormRoutes: true)
            let sent = expectation(description: "onboarding saved")
            let transport = FormSaveTestTransport(started: [sent])
            try await withPresentation(fixture: fixture, transport: transport) { presentations, _, events in
                let screen = try await waitForScreen("scr_screens_sdeparture", presentations: presentations)
                try await tapPublishedDepartureContinue(screen, days: days)
                await fulfillment(of: [sent], timeout: 5)
                _ = try await waitForScreen("scr_screens_sitalian-level", presentations: presentations)
                let routed = events.routedEvents.filter { ["short_trip", "long_trip"].contains($0.name) }
                XCTAssertEqual(routed.map(\.name), [eventName], "Published condition must select the expected branch")
                XCTAssertEqual(routed.first?.properties["trip_days"] as? Double, days)
                let saves = await transport.requests()
                XCTAssertEqual(saves.first?.answers, ["trip_days": .number(days)])
                await transport.release(sequence: 1, code: .saved)
            }
        }
    }

    func testPublishedF5BackgroundSaveAllowsCompletionBeforeReply() async throws {
        let fixture = try await signedFixture(kind: .publishedForms, formsScreen: "departure", formsEvent: "continue")
        let sent = expectation(description: "background save sent")
        let transport = FormSaveTestTransport(started: [sent])
        try await withPresentation(fixture: fixture, transport: transport) { presentations, _, events in
            let screen = try await waitForScreen("scr_screens_sdeparture", presentations: presentations)
            try await tapPublishedDepartureContinue(screen)
            await fulfillment(of: [sent], timeout: 5)
            for _ in 0..<200 {
                if events.routedEvents.contains(where: { $0.name == JourneyEvents.journeyCompleted }) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let requests = await transport.requests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.formName, "onboarding")
            XCTAssertEqual(requests.first?.answers, ["trip_days": .number(30)])
            XCTAssertEqual(events.routedEvents.filter { $0.name == "continue" }.count, 1)
            XCTAssertEqual(events.routedEvents.first { $0.name == JourneyEvents.journeyCompleted }?
                .properties["outcome"] as? String, "done")
            await transport.release(sequence: 1, code: .saved)
        }
    }

    func testUnacceptedPublishedSaveDoesNotRouteItsFollowingEmit() async throws {
        let fixture = try await signedFixture(kind: .publishedForms, formsScreen: "departure", formsEvent: "continue")
        try await withPresentation(fixture: fixture) { presentations, _, events in
            let screen = try await waitForScreen("scr_screens_sdeparture", presentations: presentations)
            try await tapPublishedDepartureContinue(screen, publishSynchronously: true)
            XCTAssertFalse(events.routedEvents.contains { $0.name == "continue" })
            XCTAssertFalse(events.routedEvents.contains { $0.name == JourneyEvents.journeyCompleted })
        }
    }

    private func tapPublishedDepartureContinue(_ screen: ExperienceScreenViewController, publishSynchronously: Bool = false, days: Double = 30) async throws {
        let surface = try XCTUnwrap(screen.view.subviews.compactMap { $0 as? ExperienceRuntimeSurfaceView }.first)
        let interactive = try XCTUnwrap(Mirror(reflecting: screen).children.first {
            $0.label == "interactiveScreen"
        }?.value as? ExperienceInteractiveScreen)
        let root = try await interactive.rootViewModel()
        _ = try await interactive.mutateState([.setNumber(root, path: "state/days", value: Float(days))])
        _ = try await interactive.step(elapsedSeconds: 0)
        // The source places Continue last in the column. Inspect its hit without releasing a click.
        let x = Float(surface.bounds.midX)
        var hit: CGPoint?
        for y in stride(from: Float(surface.bounds.maxY - 1), through: 1, by: -4) {
            let down = try await interactive.step(pointers: [.init(kind: .down, x: x, y: y)], elapsedSeconds: 0)
            let exit = try await interactive.step(pointers: [.init(kind: .exit, x: x, y: y)], elapsedSeconds: 0)
            XCTAssertTrue((down.effects + exit.effects).allSatisfy { $0.responseSave == nil })
            if down.pointerHits.contains(where: { $0 != .none }) {
                hit = CGPoint(x: CGFloat(x), y: CGFloat(y - 4))
                break
            }
        }
        let point = try XCTUnwrap(hit, "Published Continue must have a native hit")
        if publishSynchronously {
            let down = try await interactive.step(pointers: [.init(kind: .down, x: Float(point.x), y: Float(point.y))], elapsedSeconds: 0)
            let up = try await interactive.step(pointers: [.init(kind: .up, x: Float(point.x), y: Float(point.y))], elapsedSeconds: 0)
            let effects = down.effects + up.effects
            XCTAssertEqual(effects.compactMap(\.responseSave).count, 1)
            await screen.deliverStep(effects: effects)
            return
        }
        let pointer = NSObject()
        let observer = try XCTUnwrap(surface.runtimeObserver)
        let now = ProcessInfo.processInfo.systemUptime
        observer.runtimeSurfaceViewDidReceivePointerEvents([
            .init(source: ExperienceRuntimePointerSourceID(pointer), kind: .down, location: point, timestampSeconds: now),
            .init(source: ExperienceRuntimePointerSourceID(pointer), kind: .up, location: point, timestampSeconds: now + 0.01),
        ])
    }

    private func withPresentation(fixture: Fixture, transport: FormSaveTestTransport? = nil,
        body: (ExperiencePresentationService, JourneyService, MockEventLog) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shared-values-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: directory) }
        StubURLProtocol.register(matcher: { $0.url?.host == "shared-values.nuxie.test" }) { request in
            let url = try XCTUnwrap(request.url)
            let data = try fixture.assetDirectory.map { try Data(contentsOf: $0.appendingPathComponent(String(url.path.dropFirst()))) } ?? fixture.scene
            return (try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": url.pathExtension == "otf" ? "font/otf" : "application/vnd.nuxie.scene", "Content-Length": String(data.count)])), data)
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
            responseSaveDelivery: transport.map { JourneyResponseSaveDelivery(directory: directory,
                transport: $0, clock: SystemDateProvider(), sleeper: SystemSleepProvider()) },
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
            await transport?.finish()
            await journeys.shutdown()
        } catch {
            await transport?.finish()
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
        let assetDirectory: URL?
        let snapshot: JourneyProfileCatalog.Snapshot
        let authority: ProfileDeliveryAuthority
        let keys: [JourneyPackageAuthorizationKey]
        let supported: JourneyReleaseSupportedRuntime
    }

    private enum FixtureKind { case sharedValues, publishedRunValues, publishedForms }

    private func signedFixture(kind: FixtureKind = .sharedValues, formsScreen: String = "feedback", formsEvent: String = "sent", publishedFormRoutes: Bool = false) async throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ExperienceRuntimeHostApp/Fixtures/font-converter/profile.json"))) as? [String: Any])
        var profile = base
        var entry = try XCTUnwrap(XCTUnwrap(base["releases"] as? [[String: Any]]).first)
        let envelope = try XCTUnwrap(entry["envelope"] as? [String: Any])
        var descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: XCTUnwrap(envelope["descriptorBytesBase64"] as? String)))) as? [String: Any])
        let directory = kind == .sharedValues ? SharedValuesFixture.directory : kind == .publishedForms
            ? SharedValuesFixture.directory.deletingLastPathComponent().appendingPathComponent("forms-saves") : PublishedRunValuesFixture.directory
        let forms = kind == .publishedForms ? try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appendingPathComponent("release.json"))) as? [String: Any]) : nil
        let scene = try Data(contentsOf: directory.appendingPathComponent("screen.riv"))
        let provenance = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("provenance.json"))) as? [String: Any])
        let names: [String]
        if kind == .sharedValues { names = ["first", "long", "short"] }
        else if let forms {
            names = try XCTUnwrap(XCTUnwrap(forms["leg"] as? [String: Any])["screens"] as? [[String: Any]]).map { try XCTUnwrap($0["id"] as? String) }
        } else { names = try PublishedRunValuesFixture.expectations().screens }
        let entryScreen = kind == .publishedForms ? "scr_screens_s\(formsScreen)" : try XCTUnwrap(names.first)
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
        if let forms {
            leg["screens"] = try XCTUnwrap(forms["leg"] as? [String: Any])["screens"]
            leg["steps"] = [
                ["kind": "action", "id": "present", "action": ["type": "navigate", "screenId": entryScreen], "outlets": [:]],
                ["kind": "complete", "id": "done", "outcome": "done"]
            ]
            leg["routes"] = [["eventName": formsEvent, "host": ["kind": "screen", "screenId": entryScreen], "entryStepId": "done"]]
            if publishedFormRoutes {
                let publishedLeg = try XCTUnwrap(forms["leg"] as? [String: Any])
                // Keep every published route and action. Enter at its departure navigation.
                leg["steps"] = publishedLeg["steps"]
                leg["routes"] = publishedLeg["routes"]
                let steps = try XCTUnwrap(publishedLeg["steps"] as? [[String: Any]])
                leg["entryStepId"] = try XCTUnwrap(steps.first { step in
                    (step["action"] as? [String: Any])?["screenId"] as? String == entryScreen
                }?["id"] as? String)
            }
            for name in ["state", "responses", "ruleGroups"] { descriptor[name] = forms[name] }
        }
        descriptor["leg"] = leg
        descriptor["viewModelValues"] = []
        descriptor["screenBehaviors"] = names.sorted().map { ["screenId": $0, "controls": []] as [String: Any] }
        let hash = SHA256Provider.hexDigest(scene)
        descriptor["render"] = ["renderer": "nux", "nux": ["key": "renders/sha256/\(hash).nux", "sha256": hash, "sizeBytes": scene.count, "contentType": "application/vnd.nuxie.scene"],
            "assets": (try XCTUnwrap(provenance["fonts"] as? [[String: Any]])).map { $0.merging(["kind": "font"]) { _, new in new } },
            "screens": names.map { ["id": $0, "artboardId": $0, "artboardName": $0, "width": 393, "height": 852] as [String: Any] }, "transitions": [], "textInputs": []]
        if let forms { descriptor["render"] = forms["render"] }
        var requirements = try XCTUnwrap((forms ?? descriptor)["requirements"] as? [String: Any])
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
        return Fixture(scene: scene, assetDirectory: kind == .publishedForms ? directory : nil, snapshot: try await catalog.prepare(decoded, authority: authority).snapshot,
            authority: authority, keys: [.init(keyID: "TEST_ONLY_DEV_KEYPAIR", ed25519PublicKeyBytes: key.publicKey.rawRepresentation)], supported: supported)
    }
}
private actor FormSaveTestTransport: JourneyResponseSaveTransport {
    let started: [XCTestExpectation]
    private var sheets: [JourneyResponseSave] = []
    private var pending: [Int64: CheckedContinuation<JourneyResponseSaveReply, Never>] = [:]
    init(started: [XCTestExpectation]) { self.started = started }
    func requests() -> [JourneyResponseSave] { sheets }
    func sendResponseSave(_ sheet: JourneyResponseSave) async throws -> JourneyResponseSaveReply {
        sheets.append(sheet)
        if sheets.count <= started.count { started[sheets.count - 1].fulfill() }
        return await withCheckedContinuation { pending[sheet.sequence] = $0 }
    }
    func release(sequence: Int64, code: JourneyResponseSaveReply.Code) {
        pending.removeValue(forKey: sequence)?.resume(returning: .init(code: code, sequence: code == .saved ? sequence : nil))
    }
    func finish() {
        let waits = pending.values
        pending = [:]
        for wait in waits { wait.resume(returning: .noAnswer) }
    }
}
@MainActor
private final class EnvironmentInsetsView: UIView {
    var testInsets: UIEdgeInsets = .zero
    override var safeAreaInsets: UIEdgeInsets { testInsets }
}
#endif
