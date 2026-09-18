#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieRuntime
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ExperienceVideoPlaybackTests: XCTestCase {
    @MainActor
    func testSharedDecoderBudgetWaitsForDisposalAcrossOwners() throws {
        let pool = ExperienceVideoDecoderPool(budget: {
            .init(maxPlayers: 1, managedPlayers: 1, hardwarePlayers: 0,
                managedPixelsPerSecond: 100, softwarePixelsPerSecond: 0)
        })
        let background = UUID(), foreground = UUID()
        let low: [Int: ExperienceVideoDecoderPool.Request] = [5: .init(pixelsPerSecond: 100, priority: 0, visible: true)]
        let high: [Int: ExperienceVideoDecoderPool.Request] = [5: .init(pixelsPerSecond: 100, priority: 10, visible: true)]
        XCTAssertEqual(try pool.update(owner: background, requests: low), [5])
        // Identical component IDs belong to different screens. A higher priority
        // request must wait while the previous owner still holds a real decoder.
        XCTAssertEqual(try pool.update(owner: foreground, requests: high), [])
        XCTAssertEqual(try pool.update(owner: background, requests: low), [])
        XCTAssertEqual(try pool.update(owner: foreground, requests: high), [])
        pool.release(owner: background, componentID: 5)
        XCTAssertEqual(try pool.update(owner: foreground, requests: high), [5])
        pool.remove(owner: foreground)
        XCTAssertEqual(try pool.update(owner: background, requests: low), [5])
    }

    @MainActor
    func testSharedDecoderBudgetRetainsRemovedAndResizedClaimsUntilDisposal() throws {
        let pool = ExperienceVideoDecoderPool(budget: {
            .init(maxPlayers: 3, managedPlayers: 3, hardwarePlayers: 0,
                managedPixelsPerSecond: 100, softwarePixelsPerSecond: 0)
        })
        let first = UUID(), second = UUID()
        XCTAssertEqual(try pool.update(owner: first, requests: [1: .init(pixelsPerSecond: 80, priority: 0, visible: true)]), [1])
        XCTAssertEqual(try pool.update(owner: first, requests: [:]), [])
        let next: [Int: ExperienceVideoDecoderPool.Request] = [2: .init(pixelsPerSecond: 30, priority: 10, visible: true)]
        XCTAssertEqual(try pool.update(owner: second, requests: next), [])
        pool.release(owner: first, componentID: 1)
        XCTAssertEqual(try pool.update(owner: second, requests: next), [2])
        let resized: [Int: ExperienceVideoDecoderPool.Request] = [2: .init(pixelsPerSecond: 60, priority: 10, visible: true)]
        XCTAssertEqual(try pool.update(owner: second, requests: resized), [])
        pool.release(owner: second, componentID: 2)
        XCTAssertEqual(try pool.update(owner: second, requests: resized), [2])
        XCTAssertEqual(try pool.update(owner: first, requests: [1: .init(pixelsPerSecond: 40, priority: 0, visible: true)]), [1])
    }

    func testBoundedVideoDecodeCost() async throws {
        XCTAssertEqual(try ExperienceVideoDecodeCost.pixelsPerSecond(width: 100, height: 10,
            durationUs: 1_000_000, timestamps: [0, 500_000, 550_000]), 20_000)
        XCTAssertEqual(try ExperienceVideoDecodeCost.pixelsPerSecond(width: 100, height: 10,
            durationUs: 1_000_000, timestamps: [990_000, 0]), 100_000)
        XCTAssertEqual(try ExperienceVideoDecodeCost.pixelsPerSecond(width: 100, height: 10,
            durationUs: 100_000, timestamps: [0]), 10_000)
        let invalidTimes: [[Int64]] = [[], [0, 0], [-1], [0, 1_000_000]]
        for times in invalidTimes {
            XCTAssertThrowsError(try ExperienceVideoDecodeCost.pixelsPerSecond(width: 100, height: 10,
                durationUs: 1_000_000, timestamps: times))
        }
        let cost = try await ExperienceVideoDecodeCost.read(url: videoFixtureDirectory().appendingPathComponent("captions.mp4"))
        XCTAssertEqual(cost, 64 * 32 * 31)
    }

    func testNativeVideoDecoderBudgetBridge() throws {
        let budget = NuxieNativeVideoDecoderBudget(maxPlayers: 2, managedPlayers: 1, hardwarePlayers: 1,
            managedPixelsPerSecond: 100, softwarePixelsPerSecond: 100)
        let requests = [
            NuxieNativeVideoDecoderRequest(id: 9, pixelsPerSecond: 100, priority: 0, visible: true,
                hardwareSupported: true, softwareSupported: true),
            NuxieNativeVideoDecoderRequest(id: 4, pixelsPerSecond: 100, priority: 10, visible: true,
                hardwareSupported: true, softwareSupported: true),
            NuxieNativeVideoDecoderRequest(id: 3, pixelsPerSecond: 100, priority: 10, visible: true),
            NuxieNativeVideoDecoderRequest(id: 1, pixelsPerSecond: 1, priority: 99, visible: false,
                hardwareSupported: true, softwareSupported: true),
        ]
        XCTAssertEqual(try NuxieNativeRuntime.allocateVideoDecoders(requests, budget: budget),
            [.poster, .hardware, .platformManaged, .poster])
        XCTAssertEqual(try NuxieNativeRuntime.allocateVideoDecoders([], budget: budget), [])
        XCTAssertThrowsError(try NuxieNativeRuntime.allocateVideoDecoders(requests + [requests[0]], budget: budget))
    }

    func testNativeVideoReclamationPreservesPausedPosition() async throws {
        let directory = try videoFixtureDirectory()
        let scene = try Data(contentsOf: directory.appendingPathComponent("greeting.nux"))
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        let runtime = try await NuxieNativeRuntime.open(bytes: scene, artboardName: "Video Frame", player: .defaultScene,
            pixelWidth: 320, pixelHeight: 640, importMode: .configured(moduleName: "nuxie", expectedAssets: catalog,
                externalAssets: [:], videoEnabled: true))
        defer { Task { try? await runtime.close() } }
        let videos = try await runtime.videos()
        let video = try XCTUnwrap(videos.first)
        _ = try await runtime.videoStep(componentID: video.componentID, observation: 1, generation: video.generation, value: 2.022)
        try await runtime.videoCommand(componentID: video.componentID, kind: 1, value: 0)
        try await runtime.videoCommand(componentID: video.componentID, kind: 2, value: 1.0)
        _ = try await runtime.videoStep(componentID: video.componentID, observation: 0, generation: video.generation)
        let oldVideos = try await runtime.videos()
        let oldGeneration = try XCTUnwrap(oldVideos.first).generation
        let denied = try await runtime.reclaimVideoDecoder(componentID: video.componentID, blocked: true)
        XCTAssertGreaterThan(denied, oldGeneration)
        let stale = try await runtime.videoStep(componentID: video.componentID, observation: 1, generation: oldGeneration, value: 2.022)
        XCTAssertTrue(stale.isEmpty)
        let reopened = try await runtime.reclaimVideoDecoder(componentID: video.componentID, blocked: false)
        XCTAssertGreaterThan(reopened, denied)
        let actions = try await runtime.videoStep(componentID: video.componentID, observation: 1, generation: reopened, value: 2.022)
        XCTAssertTrue(actions.contains { $0.kind == 2 && $0.value == 1.0 })
        XCTAssertFalse(actions.contains { $0.kind == 0 })
        let current = try await runtime.videos()
        XCTAssertFalse(try XCTUnwrap(current.first).wantsPlay)
        try await runtime.close()
    }

    func testMobileReleaseAdmissionAdvertisesVideo() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        XCTAssertTrue(JourneyReleaseRuntime.current.supportedCapabilities.contains("video.playback.v1"))
        #else
        XCTAssertFalse(JourneyReleaseRuntime.current.supportedCapabilities.contains("video.playback.v1"))
        #endif
    }

    private func videoFixtureDirectory() throws -> URL {
        if let bundled = Bundle(for: ExperienceVideoPlaybackTests.self).resourceURL?.appendingPathComponent("video"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("greeting.nux").path) {
            return bundled
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/video")
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("greeting.nux").path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return source
    }

    func testEmbeddedCaptionTrackIsReadFromVerifiedFile() async throws {
        let directory = try videoFixtureDirectory()
        let url = directory.appendingPathComponent("captions.mp4")
        let cues = try await ExperienceVideoCaptions.read(url: url,
            track: .init(streamIndex: 2, codec: "mov_text", language: "eng", title: nil))
        XCTAssertEqual(cues.map(\.text), ["Hello 👋", "Welcome"])
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(cues[0].endSeconds, 0.9, accuracy: 0.001)
        XCTAssertEqual(cues[1].startSeconds, 1, accuracy: 0.001)
        XCTAssertEqual(cues[1].endSeconds, 1.9, accuracy: 0.001)
        for index in [0, 1, 3] {
            do {
                _ = try await ExperienceVideoCaptions.read(url: url,
                    track: .init(streamIndex: index, codec: "mov_text", language: "eng", title: nil))
                XCTFail("An absent or non-text stream must not be admitted as captions")
            } catch {}
        }
    }

    func testVideoCaptionsFollowSeekAndRejectInvalidReplacement() async throws {
        let directory = try videoFixtureDirectory()
        let scene = try Data(contentsOf: directory.appendingPathComponent("greeting.nux"))
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        let runtime = try await NuxieNativeRuntime.open(bytes: scene, artboardName: "Video Frame", player: .defaultScene,
            pixelWidth: 320, pixelHeight: 640, importMode: .configured(moduleName: "nuxie", expectedAssets: catalog, externalAssets: [:], videoEnabled: true))
        defer { Task { try? await runtime.close() } }
        let videos = try await runtime.videos()
        let video = try XCTUnwrap(videos.first)
        XCTAssertEqual(video.componentName, "Video")
        XCTAssertEqual(video.priority, 0)
        XCTAssertEqual(video.readiness, 0)
        try await runtime.videoSetCaptions(componentID: video.componentID, language: "en", cues: [
            .init(startSeconds: 0, endSeconds: 1, text: "Hello 👋"),
            .init(startSeconds: 1, endSeconds: 2, text: "Welcome"),
        ])
        var caption = try await runtime.videoCaption(componentID: video.componentID)
        XCTAssertEqual(caption.language, "en")
        XCTAssertEqual(caption.text, "Hello 👋")
        do {
            try await runtime.videoSetCaptions(componentID: video.componentID, language: "fr", cues: [
                .init(startSeconds: .nan, endSeconds: 1, text: "Invalid"),
            ])
            XCTFail("Invalid cue must be rejected atomically")
        } catch {}
        caption = try await runtime.videoCaption(componentID: video.componentID)
        XCTAssertEqual(caption.language, "en")
        XCTAssertEqual(caption.text, "Hello 👋")
        for (seconds, expected) in [(1.0, "Welcome"), (0.0, "Hello 👋"), (2.0, "")] {
            try await runtime.videoCommand(componentID: video.componentID, kind: 2, value: seconds)
            _ = try await runtime.videoStep(componentID: video.componentID, observation: 0, generation: video.generation)
            caption = try await runtime.videoCaption(componentID: video.componentID)
            XCTAssertEqual(caption.text, expected)
        }
        try await runtime.videoSetCaptions(componentID: video.componentID, language: "", cues: [])
        caption = try await runtime.videoCaption(componentID: video.componentID)
        XCTAssertEqual(caption.language, "")
        XCTAssertEqual(caption.text, "")
        try await runtime.close()
    }

    @MainActor
    func testPublishedVideoDecodesIntoMetalScene() async throws {
        try await verifyPublishedVideo(sceneName: "greeting", artboardName: "Video Frame",
            viewNodeID: "clip-view", expectedOccurrences: 1, sampleX: 100, sampleY: 80)
    }

    @MainActor
    func testPublishedVideoWaitsForDecodedFirstFrame() async throws {
        try await verifyPublishedVideo(sceneName: "waiting", artboardName: "Video Frame",
            viewNodeID: "clip-view", expectedOccurrences: 1, sampleX: 100, sampleY: 80)
    }

    @MainActor
    func testRequiredVideoRejectsPresentationAtFirstFrameDeadline() async throws {
        try await verifyPublishedVideo(sceneName: "waiting", artboardName: "Video Frame",
            viewNodeID: "clip-view", expectedOccurrences: 1, sampleX: 100, sampleY: 80,
            forceFirstFrameTimeout: true)
    }

    @MainActor
    func testPublishedListVideosDecodeAndJourneyCommandsFanOut() async throws {
        try await verifyPublishedVideo(sceneName: "list", artboardName: "Screen",
            viewNodeID: "item-card", expectedOccurrences: 2, sampleX: 20, sampleY: 30)
    }

    @MainActor
    private func verifyPublishedVideo(sceneName: String, artboardName: String,
        viewNodeID: String, expectedOccurrences: Int, sampleX: Int, sampleY: Int,
        forceFirstFrameTimeout: Bool = false) async throws {
        let directory = try videoFixtureDirectory()
        let scene = try Data(contentsOf: directory.appendingPathComponent("\(sceneName).nux"))
        let url = directory.appendingPathComponent("captions.mp4")
        let media = try Data(contentsOf: url)
        let digest = SHA256Provider.hexDigest(media)
        let key = "assets/sha256/\(digest).mp4"
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        let authored = try XCTUnwrap(catalog.first { $0.kind == .video })
        let id = try XCTUnwrap(authored.authoredID)
        let name = "\(authored.name)-\(id)"
        let video = NativeExperienceVideoAsset(location: .external(key: key), sourceAssetKey: "asset:clip",
            riveAssetId: UInt64(id), riveUniqueName: name, sha256: digest, sizeBytes: media.count,
            width: 64, height: 32, durationMs: 2022, videoCodec: "avc1.42c00a", audioCodec: "mp4a.40.2", captionTracks: [.init(streamIndex: 2, codec: "mov_text", language: "eng", title: nil)], required: true)
        struct ExportedScreen: Decodable { let width: Int; let height: Int }
        struct ExportedTargets: Decodable {
            let videoElements: [NativeExperienceVideoElement]
            let screens: [ExportedScreen]
        }
        let exportedTargets = try JSONDecoder().decode(ExportedTargets.self,
            from: Data(contentsOf: directory.appendingPathComponent(sceneName == "greeting" ? "inventory.json" : "\(sceneName)-inventory.json")))
        let dimensions = try XCTUnwrap(exportedTargets.screens.first)
        let width = dimensions.width, height = dimensions.height
        let plan = NativeExperienceRenderPlan(identity: .init(experienceId: "video", buildId: "video", appId: "app", environment: "test"),
            scene: .init(key: "scene.nux", sha256: SHA256Provider.hexDigest(scene), sizeBytes: scene.count),
            entry: .init(screenId: "screen"), screens: [.init(screenId: "screen", artboardId: "screen", artboardName: artboardName, width: Double(width), height: Double(height), exit: nil)],
            transitions: [], textInputs: [], images: [], fonts: [], videos: [video], videoElements: exportedTargets.videoElements)
        let payload = AuthenticatedRuntimePayload(authenticatedKeyID: "test", renderPlan: plan,
            journey: JourneyDocument(screens: [.init(id: "screen")]), sceneBytes: scene,
            assets: [.init(kind: .video, riveAssetID: id, riveUniqueName: name, sourceKey: key, contentType: "video/mp4", sha256: digest, required: true, bytes: nil, fileURL: url)])
        let externalAssets = try ExperienceInteractiveAssetBinding.bind(renderPlan: plan,
            authenticatedAssets: payload.assets, catalog: catalog, systemFontCache: .shared).bytes
        XCTAssertTrue(externalAssets.isEmpty, "Published external video must bind without an in-memory payload")
        let runtime = try await NuxieNativeRuntime.open(bytes: scene, artboardName: artboardName, player: .defaultScene,
            pixelWidth: UInt32(width), pixelHeight: UInt32(height), bindDefaultViewModel: sceneName == "list", importMode: .configured(moduleName: "nuxie", expectedAssets: catalog, externalAssets: externalAssets, videoEnabled: true))
        var decoderSlots = UInt32(expectedOccurrences)
        let pool = ExperienceVideoDecoderPool(budget: {
            .init(maxPlayers: decoderSlots, managedPlayers: decoderSlots, hardwarePlayers: 0,
                managedPixelsPerSecond: 200_000, softwarePixelsPerSecond: 0)
        })
        let host = try await ExperienceVideoPlayback.open(runtime: runtime, payload: payload, decoderPool: pool)
        defer { host.close(); Task { try? await runtime.close() } }
        if sceneName == "waiting" {
            let initiallyReady = try await host.isReadyForPresentation()
            XCTAssertFalse(initiallyReady, "Opening a decoder is not a decoded first frame")
        }
        if forceFirstFrameTimeout {
            // Do not tick the decoder: admission must not accept an opened
            // media item when no frame has reached the runtime by the deadline.
            try await Task.sleep(nanoseconds: 2_100_000_000)
            do {
                _ = try await host.isReadyForPresentation()
                XCTFail("Required first frame must fail at the authored two-second deadline")
            } catch let error as ExperienceInteractiveScreenError {
                XCTAssertEqual(error, .assetContract("required video first frame unavailable"))
            }
            return
        }
        let device = try await runtime.metalDevice().value
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: width, height: height)
        let stride = width * 4
        let buffer = try XCTUnwrap(device.makeBuffer(length: stride * height, options: .storageModeShared))
        var sawRed = false, sawBlue = false
        var seenCaptions: Set<String> = []
        // Bound list rows materialize when the scene first advances. The host
        // must discover their players during its next tick after opening.
        _ = try await runtime.step(elapsedSeconds: 0)
        _ = try await host.tick()
        let videoOccurrences = try await runtime.videos()
        XCTAssertEqual(videoOccurrences.count, expectedOccurrences)
        XCTAssertEqual(Set(videoOccurrences.map(\.componentID)).count, expectedOccurrences)
        let target = try XCTUnwrap(exportedTargets.videoElements.first)
        for occurrence in videoOccurrences {
            XCTAssertEqual(occurrence.sourceArtboardIndex, Int(target.sourceArtboardIndex))
            XCTAssertEqual(occurrence.sourceComponentID, Int(target.componentId))
        }
        let videoComponent = try XCTUnwrap(videoOccurrences.first).componentID
        var phase = 0
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline && phase < 4 {
            _ = try await runtime.step(elapsedSeconds: 0.03)
            _ = try await host.tick()
            guard try await host.isReadyForPresentation() else {
                try await Task.sleep(nanoseconds: 30_000_000)
                continue
            }
            let caption = try await runtime.videoCaption(componentID: videoComponent)
            if !caption.text.isEmpty { seenCaptions.insert(caption.text) }
            guard let drawable = layer.nextDrawable() else { XCTFail("Metal drawable unavailable"); break }
            let completed = expectation(description: "video frame presented")
            _ = try await runtime.render(drawable: .available(.init(drawable)),
                readback: .init(buffer: buffer, bytesPerRow: stride), completion: { completed.fulfill() })
            await fulfillment(of: [completed], timeout: 2)
            let pixels = buffer.contents().assumingMemoryBound(to: UInt8.self)
            let offset = sampleY * stride + sampleX * 4
            let red = pixels[offset + 2] > 180 && pixels[offset] < 70
            let blue = pixels[offset] > 180 && pixels[offset + 2] < 70
            sawRed = sawRed || red
            sawBlue = sawBlue || blue
            if (phase % 2 == 0 && red) || (phase % 2 == 1 && blue) { phase += 1 }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(seenCaptions, ["Hello 👋", "Welcome"], "Authenticated file captions must follow native playback")
        XCTAssertTrue(sawRed, "Decoded red frame must reach the composed Metal scene")
        XCTAssertTrue(sawBlue, "Playback must advance to the decoded blue frame")
        XCTAssertEqual(phase, 4, "Two red/blue cycles must render across a runtime-owned loop seek: \(host.playbackDiagnostics)")
        let occurrences = try await runtime.videos()
        _ = try XCTUnwrap(occurrences.first)
        func command(_ type: String, view: String? = nil) throws -> JourneyVideoAction {
            try JourneyVideoAction(action: ["type": .string("video"),
                "target": .object(["artboardId": .string("screen"), "viewNodeId": .string(view ?? viewNodeID)]),
                "command": .object(["type": .string(type)])])
        }
        do {
            try await host.apply(command("pause", view: "missing"))
            XCTFail("An unknown authored target must not control another video")
        } catch {}
        try await host.apply(command("pause"))
        _ = try await host.tick()
        var current = try await runtime.videos()
        var paused = try XCTUnwrap(current.first)
        XCTAssertTrue(current.allSatisfy { !$0.wantsPlay }, "Journey pause reaches every live row")
        XCTAssertEqual(paused.state, 3)
        let previousGeneration = paused.generation
        decoderSlots = 0
        _ = try await host.tick()
        current = try await runtime.videos()
        let retired = try XCTUnwrap(current.first)
        XCTAssertGreaterThan(retired.generation, previousGeneration)
        XCTAssertTrue(current.allSatisfy { !$0.wantsPlay })
        XCTAssertTrue(host.playbackDiagnostics.isEmpty, "Denied decoders must be closed")
        decoderSlots = UInt32(expectedOccurrences)
        _ = try await host.tick()
        current = try await runtime.videos()
        XCTAssertGreaterThan(try XCTUnwrap(current.first).generation, retired.generation)
        XCTAssertTrue(current.allSatisfy { !$0.wantsPlay })
        try await host.apply(command("play"))
        _ = try await host.tick()
        try await host.setSuspended(reason: 2, enabled: true)
        current = try await runtime.videos()
        paused = try XCTUnwrap(current.first)
        XCTAssertTrue(paused.wantsPlay, "Background suspension must preserve requested playback")
        XCTAssertNotEqual(paused.state, 2)
        try await host.setSuspended(reason: 2, enabled: false)
        _ = try await host.tick()
        current = try await runtime.videos()
        XCTAssertTrue(current.allSatisfy(\.wantsPlay), "Journey play reaches every live row")
        host.close()
        let closedTick = try await host.tick()
        let closedCaptions = try await host.captions()
        XCTAssertFalse(closedTick, "A closed owner must never recreate AVPlayers")
        XCTAssertTrue(closedCaptions.isEmpty)
        XCTAssertTrue(host.playbackDiagnostics.isEmpty)
        try await host.setSuspended(reason: 2, enabled: false)
        do {
            try await host.apply(command("play"))
            XCTFail("A closed owner must reject playback commands")
        } catch {}
        try await runtime.close()
    }

    @MainActor
    func testUnplayableOptionalVideoDoesNotRejectScreen() async throws {
        let directory = try videoFixtureDirectory()
        let scene = try Data(contentsOf: directory.appendingPathComponent("waiting.nux"))
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        let authored = try XCTUnwrap(catalog.first { $0.kind == .video })
        let id = try XCTUnwrap(authored.authoredID)
        let name = "\(authored.name)-\(id)"
        let bytes = Data("authenticated but unsupported media".utf8)
        let digest = SHA256Provider.hexDigest(bytes)
        let key = "assets/sha256/\(digest).mp4"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        struct Inventory: Decodable { let videoElements: [NativeExperienceVideoElement] }
        let targets = try JSONDecoder().decode(Inventory.self,
            from: Data(contentsOf: directory.appendingPathComponent("waiting-inventory.json"))).videoElements
        for required in [false, true] {
            let video = NativeExperienceVideoAsset(location: .external(key: key), sourceAssetKey: "asset:clip",
                riveAssetId: UInt64(id), riveUniqueName: name, sha256: digest, sizeBytes: bytes.count,
                width: 64, height: 32, durationMs: 2000, videoCodec: "avc1.42c00a", audioCodec: nil,
                captionTracks: [], required: required)
            let plan = NativeExperienceRenderPlan(identity: .init(experienceId: "video", buildId: "video", appId: "app", environment: "test"),
                scene: .init(key: "scene.nux", sha256: SHA256Provider.hexDigest(scene), sizeBytes: scene.count),
                entry: .init(screenId: "screen"), screens: [], transitions: [], textInputs: [], images: [], fonts: [],
                videos: [video], videoElements: targets.map {
                    .init(sourceArtboardIndex: $0.sourceArtboardIndex, artboardId: $0.artboardId,
                        viewNodeId: $0.viewNodeId, renderedNodeId: $0.renderedNodeId, componentId: $0.componentId,
                        readinessTimeoutSeconds: $0.readinessTimeoutSeconds, optional: !required)
                })
            let payload = AuthenticatedRuntimePayload(authenticatedKeyID: "test", renderPlan: plan,
                journey: JourneyDocument(screens: []), sceneBytes: scene,
                assets: [.init(kind: .video, riveAssetID: id, riveUniqueName: name, sourceKey: key,
                    contentType: "video/mp4", sha256: digest, required: required, bytes: nil, fileURL: url)])
            let runtime = try await NuxieNativeRuntime.open(bytes: scene, artboardName: "Video Frame", player: .defaultScene,
                pixelWidth: 320, pixelHeight: 640,
                importMode: .configured(moduleName: "nuxie", expectedAssets: catalog, externalAssets: [:], videoEnabled: true))
            do {
                let host = try await ExperienceVideoPlayback.open(runtime: runtime, payload: payload)
                XCTAssertFalse(required, "Required unplayable media must reject screen admission")
                let occurrences = try await runtime.videos()
                XCTAssertEqual(occurrences.map(\.state), [7], "Optional failure is observable by scene scripts")
                XCTAssertTrue(host.playbackDiagnostics.isEmpty, "Unavailable media must not allocate a decoder")
                let ready = try await host.isReadyForPresentation()
                XCTAssertTrue(ready, "An optional failed first-frame wait admits its fallback immediately")
                let afterFallback = try await runtime.videos()
                XCTAssertEqual(afterFallback.map(\.state), [8], "Fallback retires playback so late frames cannot replace it")
                host.close()
            } catch {
                XCTAssertTrue(required, "Optional media failure must preserve the usable screen: \(error)")
            }
            try await runtime.close()
        }
    }

    func testVideoBindingRequiresExactSignedIdentityAndLocalFile() throws {
        let digest = String(repeating: "b", count: 64)
        let key = "assets/sha256/\(digest).mp4"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(digest)
        let video = NativeExperienceVideoAsset(location: .external(key: key), sourceAssetKey: "asset:greeting",
            riveAssetId: 1, riveUniqueName: "greeting-1", sha256: digest, sizeBytes: 100,
            width: 64, height: 32, durationMs: 2000, videoCodec: "avc1.42e01e", audioCodec: nil,
            captionTracks: [], required: true)
        let plan = NativeExperienceRenderPlan(identity: .init(experienceId: "experience", buildId: "build", appId: "app", environment: "test"),
            scene: .init(key: "scene.nux", sha256: digest, sizeBytes: 1), entry: .init(screenId: "screen"),
            screens: [], transitions: [], textInputs: [], images: [], fonts: [], videos: [video])
        let catalog = [NuxieNativeFileAssetDescriptor(ordinal: 0, kind: .video, authoredID: 1,
            name: "greeting", fileExtension: "mp4", isEmbedded: false, hasContentsRecord: false, requiredProviderFlags: 4)]
        func asset(fileURL: URL?, id: UInt32 = 1, sourceKey: String? = nil, bytes: Data? = nil) -> AuthenticatedRuntimeAsset {
            .init(kind: .video, riveAssetID: id, riveUniqueName: "greeting-1", sourceKey: sourceKey ?? key,
                  contentType: "video/mp4", sha256: digest, required: true, bytes: bytes, fileURL: fileURL)
        }
        XCTAssertTrue(try ExperienceInteractiveAssetBinding.bind(renderPlan: plan,
            authenticatedAssets: [asset(fileURL: url)], catalog: catalog, systemFontCache: .shared).bytes.isEmpty,
            "Video files must not be copied into the in-memory image/font provider")
        for invalid in [asset(fileURL: nil), asset(fileURL: nil, bytes: Data([1])),
                        asset(fileURL: URL(string: "https://provider.example/clip.mp4")),
                        asset(fileURL: url, id: 2), asset(fileURL: url, sourceKey: "assets/another.mp4")] {
            XCTAssertThrowsError(try ExperienceInteractiveAssetBinding.bind(renderPlan: plan,
                authenticatedAssets: [invalid], catalog: catalog, systemFontCache: .shared))
        }
        XCTAssertThrowsError(try ExperienceInteractiveAssetBinding.bind(renderPlan: plan,
            authenticatedAssets: [asset(fileURL: url)], catalog: [], systemFontCache: .shared))
        XCTAssertThrowsError(try ExperienceInteractiveAssetBinding.bind(renderPlan: plan,
            authenticatedAssets: [asset(fileURL: url)], catalog: catalog + catalog, systemFontCache: .shared))
    }

}
#endif
