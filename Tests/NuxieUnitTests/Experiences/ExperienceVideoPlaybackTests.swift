#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import QuartzCore
import MediaAccessibility
#if canImport(UIKit)
import AVFAudio
import UIKit
#endif
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieRuntime
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ExperienceVideoPlaybackTests: XCTestCase {
    #if canImport(UIKit)
    @MainActor
    private func showVideoLayer(_ layer: CAMetalLayer, width: Int, height: Int) async throws
        -> (caption: UILabel, status: UILabel)? {
        // Unhosted unit tests intentionally use an offscreen surface. Device
        // qualification must visibly present the very drawable being asserted.
        guard Bundle(for: Self.self).bundleIdentifier == "com.nuxie.sdk.video-device-tests" else { return nil }
        func visibleWindow() -> UIWindow? {
            UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
                .first(where: { $0.isKeyWindow && !$0.isHidden && !$0.bounds.isEmpty })
        }
        let deadline = Date().addingTimeInterval(3)
        while visibleWindow() == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let window = try XCTUnwrap(visibleWindow(), "Device video qualification requires a visible app window")
        // Use the common window parent; SwiftUI owns its hosting view's children.
        let root = window
        root.viewWithTag(904_321)?.removeFromSuperview()
        let canvas = UIView(frame: root.bounds)
        canvas.tag = 904_321
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.backgroundColor = .systemBackground
        root.addSubview(canvas)
        let bounds = canvas.bounds.inset(by: window.safeAreaInsets)
        let available = bounds.insetBy(dx: 20, dy: 72)
        let scale = min(available.width / CGFloat(width), available.height / CGFloat(height))
        layer.frame = CGRect(x: bounds.midX - CGFloat(width) * scale / 2,
            y: bounds.midY - CGFloat(height) * scale / 2,
            width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        layer.drawableSize = CGSize(width: width, height: height)
        canvas.layer.addSublayer(layer)
        let status = UILabel(frame: CGRect(x: bounds.minX + 20, y: bounds.minY + 12,
            width: bounds.width - 40, height: 52))
        status.text = "Preparing composed video playback"
        status.numberOfLines = 2
        status.textAlignment = .center
        status.font = .preferredFont(forTextStyle: .headline)
        canvas.addSubview(status)
        let caption = UILabel(frame: CGRect(x: bounds.minX + 20, y: bounds.maxY - 66,
            width: bounds.width - 40, height: 54))
        caption.numberOfLines = 2
        caption.textAlignment = .center
        caption.font = .preferredFont(forTextStyle: .title2)
        canvas.addSubview(caption)
        return (caption, status)
    }
    #endif

    private struct VideoMeasurement {
        let file: String
        let width: Int
        let height: Int
        let cadence: Int
        let codec: String
        static let hd = Self(file: "captions-720p.mp4", width: 1280, height: 720, cadence: 31, codec: "avc1.42c01f")
        static let uhd = Self(file: "captions-4k60.mp4", width: 3840, height: 2160, cadence: 61, codec: "avc1.42c034")
    }

    func testCaptionLanguageSelectionContract() throws {
        struct Case: Decodable {
            let name: String
            let languages: [String?]
            let preferred: [String]
            let expected: Int?
        }
        struct Contract: Decodable { let cases: [Case] }
        let data = try Data(contentsOf: videoFixtureDirectory().appendingPathComponent("caption-selection.json"))
        for example in try JSONDecoder().decode(Contract.self, from: data).cases {
            XCTAssertEqual(ExperienceVideoCaptionSelection.index(languages: example.languages, preferred: example.preferred),
                example.expected, example.name)
        }
    }

    @MainActor
    func testProductionPoolBoundsOverlappingOwnersAndPixelWork() throws {
        let pool = ExperienceVideoDecoderPool.shared
        let owners = (0..<5).map { _ in UUID() }
        defer { for owner in owners { pool.remove(owner: owner) } }
        let small: [Int: ExperienceVideoDecoderPool.Request] = [1: .init(
            pixelsPerSecond: 1920 * 1080 * 31, priority: 0, visible: true)]
        for owner in owners.prefix(4) {
            XCTAssertEqual(try pool.update(owner: owner, requests: small), [1])
        }
        XCTAssertTrue(try pool.update(owner: owners[4], requests: small).isEmpty)
        pool.remove(owner: owners[0])
        XCTAssertEqual(try pool.update(owner: owners[4], requests: small), [1])
        for owner in owners { pool.remove(owner: owner) }
        let uhd: [Int: ExperienceVideoDecoderPool.Request] = [1: .init(
            pixelsPerSecond: 3840 * 2160 * 61, priority: 0, visible: true)]
        XCTAssertEqual(try pool.update(owner: owners[0], requests: uhd), [1])
        XCTAssertTrue(try pool.update(owner: owners[1], requests: small).isEmpty,
            "An available slot cannot exceed aggregate pixel workload")
    }

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
    func testPausedSeeksRedeliverDecodedBoundaryFrames() async throws {
        try await verifyPublishedVideo(sceneName: "greeting", artboardName: "Video Frame",
            viewNodeID: "clip-view", expectedOccurrences: 1, sampleX: 100, sampleY: 80,
            pausedSeekQualification: true)
    }

    @MainActor
    func testPublishedVideoDecodesIntoMetalScene() async throws {
        try await verifyPublishedVideo(sceneName: "greeting", artboardName: "Video Frame",
            viewNodeID: "clip-view", expectedOccurrences: 1, sampleX: 100, sampleY: 80)
    }

    @MainActor
    func testComposedVideoMatchesMediaClockAcrossSeekAndResume() async throws {
        try await verifyPublishedVideo(sceneName: "greeting", artboardName: "Video Frame",
            viewNodeID: "clip-view", expectedOccurrences: 1, sampleX: 100, sampleY: 80,
            clockQualification: true)
    }

    @MainActor
    func testPreferredFrenchTrackFollowsActualVideoPlayback() async throws {
        try await verifyPublishedVideo(sceneName: "greeting", artboardName: "Video Frame",
            viewNodeID: "clip-view", expectedOccurrences: 1, sampleX: 100, sampleY: 80, frenchCaptions: true)
    }

    @MainActor
    func testPreparedScreenRelinquishesSharedDecoderCapacity() async throws {
        try await verifyPublishedVideo(sceneName: "greeting", artboardName: "Video Frame",
            viewNodeID: "clip-view", expectedOccurrences: 1, sampleX: 100, sampleY: 80, preparedPool: true)
    }

    @MainActor
    func test4k60VideoDeliveryMeasurements() async throws {
        try await verifyPublishedVideo(sceneName: "greeting", artboardName: "Video Frame",
            viewNodeID: "clip-view", expectedOccurrences: 1, sampleX: 100, sampleY: 80, measurement: .uhd)
    }

    @MainActor
    func test720pVideoDeliveryMeasurements() async throws {
        try await verifyPublishedVideo(sceneName: "greeting", artboardName: "Video Frame",
            viewNodeID: "clip-view", expectedOccurrences: 1, sampleX: 100, sampleY: 80, measurement: .hd)
        try await verifyPublishedVideo(sceneName: "list", artboardName: "Screen",
            viewNodeID: "item-card", expectedOccurrences: 2, sampleX: 20, sampleY: 30, measurement: .hd)
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
    func testContentAddressedVideoFilePlaysWithCaptionsAndPool() async throws {
        try await verifyPublishedVideo(sceneName: "greeting", artboardName: "Video Frame",
            viewNodeID: "clip-view", expectedOccurrences: 1, sampleX: 100, sampleY: 80,
            preparedPool: true, contentAddressed: true)
    }

    @MainActor
    private func verifyPublishedVideo(sceneName: String, artboardName: String,
        viewNodeID: String, expectedOccurrences: Int, sampleX: Int, sampleY: Int,
        forceFirstFrameTimeout: Bool = false, frenchCaptions: Bool = false, measurement: VideoMeasurement? = nil, preparedPool: Bool = false, contentAddressed: Bool = false, clockQualification: Bool = false, pausedSeekQualification: Bool = false) async throws {
        let preparationStarted = CACurrentMediaTime()
        let mediaWidth = measurement?.width ?? 64
        let mediaHeight = measurement?.height ?? 32
        let directory = try videoFixtureDirectory()
        let scene = try Data(contentsOf: directory.appendingPathComponent("\(sceneName).nux"))
        var url = directory.appendingPathComponent(measurement?.file ?? (frenchCaptions ? "multilingual.mp4" : "captions.mp4"))
        let media = try Data(contentsOf: url)
        let digest = SHA256Provider.hexDigest(media)
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { if contentAddressed { try? FileManager.default.removeItem(at: cacheDirectory) } }
        if contentAddressed {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            url = cacheDirectory.appendingPathComponent(digest)
            try media.write(to: url)
        }

        let key = "assets/sha256/\(digest).mp4"
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        let authored = try XCTUnwrap(catalog.first { $0.kind == .video })
        let id = try XCTUnwrap(authored.authoredID)
        let name = "\(authored.name)-\(id)"
        var tracks: [NativeExperienceVideoAsset.CaptionTrack] = [.init(streamIndex: 2, codec: "mov_text", language: "eng", title: nil)]
        if frenchCaptions { tracks.append(.init(streamIndex: 3, codec: "mov_text", language: "fra", title: nil)) }
        let video = NativeExperienceVideoAsset(location: .external(key: key), sourceAssetKey: "asset:clip",
            authoredAssetId: UInt64(id), assetUniqueName: name, sha256: digest, sizeBytes: media.count,
            width: mediaWidth, height: mediaHeight, durationMs: 2022, videoCodec: measurement?.codec ?? "avc1.42c00a", audioCodec: "mp4a.40.2", captionTracks: tracks, required: true)
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
            assets: [.init(kind: .video, authoredAssetID: id, assetUniqueName: name, sourceKey: key, contentType: "video/mp4", sha256: digest, required: true, bytes: nil, fileURL: url)])
        if preparedPool {
            try await verifyPreparedScreenPool(payload: payload, width: width, height: height)
            return
        }
        let externalAssets = try ExperienceInteractiveAssetBinding.bind(renderPlan: plan,
            authenticatedAssets: payload.assets, catalog: catalog, systemFontCache: .shared).bytes
        XCTAssertTrue(externalAssets.isEmpty, "Published external video must bind without an in-memory payload")
        let runtime = try await NuxieNativeRuntime.open(bytes: scene, artboardName: artboardName, player: .defaultScene,
            pixelWidth: UInt32(width), pixelHeight: UInt32(height), bindDefaultViewModel: sceneName == "list", importMode: .configured(moduleName: "nuxie", expectedAssets: catalog, externalAssets: externalAssets, videoEnabled: true))
        var decoderSlots = UInt32(expectedOccurrences)
        let pool = ExperienceVideoDecoderPool(budget: {
            .init(maxPlayers: decoderSlots, managedPlayers: decoderSlots, hardwarePlayers: 0,
                managedPixelsPerSecond: UInt64(mediaWidth * mediaHeight * (measurement?.cadence ?? 31) * expectedOccurrences), softwarePixelsPerSecond: 0)
        })
        _ = try await runtime.step(elapsedSeconds: 0)
        var selectedCaptionLanguages = ["fr-CA", "en"]
        var captionPreferenceReads = 0
        let host = try await ExperienceVideoPlayback.open(runtime: runtime, payload: payload,
            artboardBounds: CGRect(x: 0, y: 0, width: width, height: height), decoderPool: pool,
            preferredCaptionLanguages: frenchCaptions ? nil : ["en"],
            systemCaptionLanguages: { captionPreferenceReads += 1; return selectedCaptionLanguages })
        defer { host.close(); Task { try? await runtime.close() } }
        if sceneName == "waiting" {
            let initiallyReady = try await host.isReadyForPresentation()
            XCTAssertFalse(initiallyReady, "Opening a decoder is not a decoded first frame")
        }
        if forceFirstFrameTimeout {
            try await host.resizeViewport(pixelWidth: 0, pixelHeight: 0)
            let hiddenReady = try await host.isReadyForPresentation()
            XCTAssertTrue(hiddenReady, "An offscreen video must not block presentation")
            try await Task.sleep(nanoseconds: 2_100_000_000)
            try await host.resizeViewport(pixelWidth: UInt32(width), pixelHeight: UInt32(height))
            let restoredReady = try await host.isReadyForPresentation()
            XCTAssertTrue(restoredReady, "A presented screen stays admitted while the restored video waits")
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
        #if canImport(UIKit)
        let display = try await showVideoLayer(layer, width: width, height: height)
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
            display?.status.text = "Playback check finished — see test results"
        }
        #endif
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
        if pausedSeekQualification {
            // The shared greeting fixture normally loops; qualify inclusive
            // end seeking without its authored wrap-to-start behavior.
            try await runtime.videoCommand(componentID: videoComponent, kind: 9, value: 0)
            try await runtime.videoCommand(componentID: videoComponent, kind: 1, value: 0)
            let initialDeadline = Date().addingTimeInterval(5)
            while host.deliveredFrames == 0 && Date() < initialDeadline {
                _ = try await host.tick()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertGreaterThan(host.deliveredFrames, 0, "Initial decoded frame is required")
            // Repeat the first and final decoded images under new seek owners.
            // Merely acknowledging currentTime is insufficient: pixels must be
            // uploaded again even when AVFoundation says no new buffer exists.
            for seconds in [0.0, 0.0, 1.99, 2.022, 0.0] {
                let before = host.deliveredFrames
                try await runtime.videoCommand(componentID: videoComponent, kind: 2, value: seconds)
                let deadline = Date().addingTimeInterval(3)
                while host.deliveredFrames == before && Date() < deadline {
                    _ = try await host.tick()
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertGreaterThan(host.deliveredFrames, before, "Paused seek to \(seconds) must present decoded pixels")
                guard let drawable = layer.nextDrawable() else { return XCTFail("Metal drawable unavailable") }
                let completed = expectation(description: "paused seek pixels")
                _ = try await runtime.render(drawable: .available(.init(drawable)),
                    readback: .init(buffer: buffer, bytesPerRow: stride), completion: { completed.fulfill() })
                await fulfillment(of: [completed], timeout: 2)
                let pixels = buffer.contents().assumingMemoryBound(to: UInt8.self)
                let offset = sampleY * stride + sampleX * 4
                if seconds < 1 {
                    XCTAssertGreaterThan(pixels[offset + 2], 180, "Red pixels at \(seconds): \(host.playbackDiagnostics)")
                    XCTAssertLessThan(pixels[offset], 70, "Red pixels at \(seconds): \(host.playbackDiagnostics)")
                } else {
                    XCTAssertGreaterThan(pixels[offset], 180, "Blue pixels at \(seconds): \(host.playbackDiagnostics)")
                    XCTAssertLessThan(pixels[offset + 2], 70, "Blue pixels at \(seconds): \(host.playbackDiagnostics)")
                }
                let delivered = host.deliveredFrames
                for _ in 0..<10 {
                    _ = try await host.tick()
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertEqual(host.deliveredFrames, delivered, "A paused seek uploads its image only once")
            }
            return
        }
        // The pixels are the independent timing oracle: this fixture changes
        // red to blue at 1s. Player time is sampled around actual composition,
        // never inferred from the frame timestamp sent back into the runtime.
        func mediaClock() throws -> Double {
            let tokens = host.playbackDiagnostics.split(separator: " ")
            let text = try XCTUnwrap(tokens.first { $0.hasPrefix("time=") })
            let value = try XCTUnwrap(Double(text.dropFirst(5)))
            XCTAssertTrue(value.isFinite)
            return value
        }
        var clockSamples = 0
        var stableColors: [String: Set<String>] = [:]
        var sampleBrackets: [Double] = []
        var transitionBrackets: [[String: Double]] = []
        var previousClockSample: (phase: String, before: Double, after: Double, red: Bool)?
        func recordClock(phase: String, before: Double, after: Double, red: Bool, blue: Bool) {
            guard clockQualification else { return }
            clockSamples += 1
            // A loop/seek discontinuity does not define a continuous clock interval.
            guard after >= before else { previousClockSample = nil; return }
            sampleBrackets.append((after - before) * 1000)
            if before >= 0.1 && after < 0.9 {
                XCTAssertTrue(red, "Composed frame must be red at media clock \(before)...\(after)")
                if red { stableColors[phase, default: []].insert("red") }
            }
            if before > 1.1 && after < 1.9 {
                XCTAssertTrue(blue, "Composed frame must be blue at media clock \(before)...\(after)")
                if blue { stableColors[phase, default: []].insert("blue") }
            }
            if let previous = previousClockSample, previous.phase == phase, previous.red, blue,
               before >= previous.after {
                transitionBrackets.append([
                    "earliestOffsetMs": (previous.before - 1) * 1000,
                    "latestOffsetMs": (after - 1) * 1000,
                    "uncertaintyMs": (after - previous.before) * 1000,
                ])
            }
            previousClockSample = (phase, before, after, red)
        }
        var phase = 0
        let measuringStarted = CACurrentMediaTime()
        let framesAtStart = host.deliveredFrames
        var firstDelivered: Double?
        var tickMilliseconds: [Double] = []
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline && phase < 4 {
            let cycleStarted = CACurrentMediaTime()
            _ = try await runtime.step(elapsedSeconds: 0.03)
            let tickStarted = CACurrentMediaTime()
            _ = try await host.tick()
            tickMilliseconds.append((CACurrentMediaTime() - tickStarted) * 1000)
            if firstDelivered == nil && host.deliveredFrames > 0 { firstDelivered = CACurrentMediaTime() }
            guard try await host.isReadyForPresentation() else {
                try await Task.sleep(nanoseconds: 30_000_000)
                continue
            }
            let caption = try await runtime.videoCaption(componentID: videoComponent)
            if !caption.text.isEmpty { seenCaptions.insert(caption.text) }
            #if canImport(UIKit)
            display?.caption.text = caption.text
            display?.status.text = "Playing • \(mediaWidth) × \(mediaHeight) • phase \(phase + 1)/4"
            #endif
            guard let drawable = layer.nextDrawable() else { XCTFail("Metal drawable unavailable"); break }
            let clockBefore = clockQualification ? try mediaClock() : 0
            let completed = expectation(description: "video frame presented")
            _ = try await runtime.render(drawable: .available(.init(drawable)),
                readback: .init(buffer: buffer, bytesPerRow: stride), completion: { completed.fulfill() })
            await fulfillment(of: [completed], timeout: 2)
            let clockAfter = clockQualification ? try mediaClock() : 0
            let pixels = buffer.contents().assumingMemoryBound(to: UInt8.self)
            let offset = sampleY * stride + sampleX * 4
            let red = pixels[offset + 2] > 180 && pixels[offset] < 70
            let blue = pixels[offset] > 180 && pixels[offset + 2] < 70
            recordClock(phase: "playback", before: clockBefore, after: clockAfter, red: red, blue: blue)
            sawRed = sawRed || red
            sawBlue = sawBlue || blue
            if (phase % 2 == 0 && red) || (phase % 2 == 1 && blue) { phase += 1 }
            let delay = measurement != nil ? max(0, 1.0 / 60.0 - (CACurrentMediaTime() - cycleStarted)) : 0.03
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
        if clockQualification {
            try await runtime.videoCommand(componentID: videoComponent, kind: 1, value: 0)
            _ = try await host.tick()
            let framesBeforeSeek = host.deliveredFrames
            try await runtime.videoCommand(componentID: videoComponent, kind: 2, value: 0.25)
            let seekDeadline = Date().addingTimeInterval(5)
            var seekReady = false
            while Date() < seekDeadline {
                _ = try await host.tick()
                let time = try mediaClock()
                if abs(time - 0.25) < 0.1 && !host.playbackDiagnostics.contains("seeking=true")
                    && host.deliveredFrames > framesBeforeSeek {
                    seekReady = true
                    break
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(seekReady, "Paused seek must deliver a new frame at 0.25s")
            previousClockSample = nil
            try await runtime.videoCommand(componentID: videoComponent, kind: 0, value: 0)
            let resumeDeadline = Date().addingTimeInterval(5)
            while Date() < resumeDeadline {
                _ = try await runtime.step(elapsedSeconds: 0.03)
                _ = try await host.tick()
                let before = try mediaClock()
                let drawable = try XCTUnwrap(layer.nextDrawable())
                let completed = expectation(description: "Seek/resume composed timing sample")
                _ = try await runtime.render(drawable: .available(.init(drawable)),
                    readback: .init(buffer: buffer, bytesPerRow: stride), completion: { completed.fulfill() })
                await fulfillment(of: [completed], timeout: 2)
                let after = try mediaClock()
                let pixel = buffer.contents().assumingMemoryBound(to: UInt8.self) + sampleY * stride + sampleX * 4
                recordClock(phase: "seek-resume", before: before, after: after,
                    red: pixel[2] > 180 && pixel[0] < 70, blue: pixel[0] > 180 && pixel[2] < 70)
                if after >= 1.4 { break }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            XCTAssertEqual(stableColors["playback"], ["red", "blue"])
            XCTAssertEqual(stableColors["seek-resume"], ["red", "blue"])
            XCTAssertGreaterThanOrEqual(transitionBrackets.count, 3,
                "Observe two playback boundaries and one boundary after seek/resume")
            let report: [String: Any] = [
                "clock": "AVPlayer.currentTime", "oracle": "GPU readback; red before0.9s, blue after1.1s",
                "samples": clockSamples, "seekSeconds": 0.25,
                "maxRenderClockBracketMs": sampleBrackets.max() ?? 0,
                "transitionOffsetBrackets": transitionBrackets,
                "measuresExternalSpeakerLatency": false,
                "includesForcedMetalReadback": true,
            ]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)
            print("NUXIE_VIDEO_MEDIA_CLOCK " + json)
            XCTContext.runActivity(named: "Composed video versus media clock") { activity in
                let attachment = XCTAttachment(string: json)
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
        }
        if measurement != nil {
            let elapsed = CACurrentMediaTime() - measuringStarted
            let ordered = tickMilliseconds.sorted()
            let metrics: [String: Any] = [
                "width": mediaWidth, "height": mediaHeight, "players": expectedOccurrences,
                "elapsedSeconds": elapsed, "deliveredFrames": host.deliveredFrames - framesAtStart,
                "aggregateDeliveredFps": Double(host.deliveredFrames - framesAtStart) / elapsed,
                "firstFrameFromPreparationMs": ((firstDelivered ?? CACurrentMediaTime()) - preparationStarted) * 1000,
                "tickP95Ms": ordered.isEmpty ? 0 : ordered[min(ordered.count - 1, Int(Double(ordered.count) * 0.95))],
                "deliveredRGBABytes": host.deliveredRGBABytes,
                "metalAllocatedBytes": device.currentAllocatedSize,
                "activeDecoders": host.activeDecoderCount,
                "includesForcedMetalReadback": true, "targetTickPeriodMs": 1000.0 / 60.0,
            ]
            let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
            let report = String(decoding: data, as: UTF8.self)
            print("NUXIE_VIDEO_MEASUREMENT " + report)
            XCTContext.runActivity(named: "SDK video delivery") { activity in
                let attachment = XCTAttachment(string: report)
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
        }
        XCTAssertEqual(seenCaptions, frenchCaptions ? ["Bonjour 👋", "Bienvenue"] : ["Hello 👋", "Welcome"], "Authenticated file captions must follow native playback")
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
        if frenchCaptions {
            let diagnostics = host.playbackDiagnostics
            let decoderCount = host.activeDecoderCount
            selectedCaptionLanguages = ["en"]
            CFNotificationCenterPostNotification(CFNotificationCenterGetLocalCenter(),
                CFNotificationName(kMACaptionAppearanceSettingsChangedNotification), nil, nil, true)
            let refreshDeadline = Date().addingTimeInterval(3)
            while try await runtime.videoCaption(componentID: videoComponent).language != "eng", Date() < refreshDeadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let english = try await runtime.videoCaption(componentID: videoComponent)
            XCTAssertEqual(english.language, "eng")
            XCTAssertTrue(["Hello 👋", "Welcome"].contains(english.text))
            XCTAssertEqual(host.playbackDiagnostics, diagnostics, "Caption selection cannot seek or recreate the paused decoder")
            XCTAssertEqual(host.activeDecoderCount, decoderCount)
            selectedCaptionLanguages = ["en"]
            CFNotificationCenterPostNotification(CFNotificationCenterGetLocalCenter(),
                CFNotificationName(kMACaptionAppearanceSettingsChangedNotification), nil, nil, true)
            selectedCaptionLanguages = ["fr"]
            CFNotificationCenterPostNotification(CFNotificationCenterGetLocalCenter(),
                CFNotificationName(kMACaptionAppearanceSettingsChangedNotification), nil, nil, true)
            let latestDeadline = Date().addingTimeInterval(3)
            while try await runtime.videoCaption(componentID: videoComponent).language != "fra", Date() < latestDeadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let french = try await runtime.videoCaption(componentID: videoComponent)
            XCTAssertEqual(french.language, "fra")
            XCTAssertTrue(["Bonjour 👋", "Bienvenue"].contains(french.text))
            XCTAssertEqual(host.playbackDiagnostics, diagnostics)
        }
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
        #if canImport(UIKit)
        try await host.handleAudioInterruption(.began, options: [])
        try await host.handleAudioInterruption(.ended, options: [])
        current = try await runtime.videos()
        XCTAssertTrue(current.allSatisfy { !$0.wantsPlay && $0.state != 2 },
            "An interruption without shouldResume must leave playback paused")
        try await host.apply(command("play"))
        let resumeDeadline = Date().addingTimeInterval(5)
        repeat {
            _ = try await host.tick()
            current = try await runtime.videos()
            if current.allSatisfy({ $0.wantsPlay && $0.state == 2 }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < resumeDeadline
        XCTAssertTrue(current.allSatisfy { $0.wantsPlay && $0.state == 2 },
            "Explicit play must recover after interruption ended without shouldResume: \(host.playbackDiagnostics)")
        #endif
        host.close()
        if frenchCaptions {
            let readsAtClose = captionPreferenceReads
            selectedCaptionLanguages = ["en"]
            CFNotificationCenterPostNotification(CFNotificationCenterGetLocalCenter(),
                CFNotificationName(kMACaptionAppearanceSettingsChangedNotification), nil, nil, true)
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(captionPreferenceReads, readsAtClose, "Closed owners must remove preference observers")
            try await host.refreshCaptionLanguages(["en"])
        }
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
    private func verifyPreparedScreenPool(payload: AuthenticatedRuntimePayload, width: Int, height: Int) async throws {
        let pool = ExperienceVideoDecoderPool.shared
        let screen = try await ExperienceInteractiveScreen.open(payload: payload,
            pixelWidth: UInt32(width), pixelHeight: UInt32(height), videoDecoderPool: pool)
        defer { Task { try? await screen.close() } }
        let device = try await screen.metalDevice().value
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: width, height: height)
        #if canImport(UIKit)
        let display = try await showVideoLayer(layer, width: width, height: height)
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
            display?.status.text = "Playback check finished — see test results"
        }
        #endif
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let stride = width * 4
        let buffer = try XCTUnwrap(device.makeBuffer(length: stride * height, options: .storageModeShared))
        func frame() async throws -> (red: Bool, blue: Bool, captions: [ExperienceInteractiveVideoCaption]) {
            _ = try await screen.step(elapsedSeconds: 0.03)
            let drawable = try XCTUnwrap(layer.nextDrawable())
            let completed = expectation(description: "prepared video presented")
            let result = try await screen.renderFrame(drawable: .init(drawable), capturesSemantics: false,
                capturesCaptions: true, completion: { completed.fulfill() })
            await fulfillment(of: [completed], timeout: 2)
            XCTAssertEqual(result.outcome.disposition, .presented)
            #if canImport(UIKit)
            display?.caption.text = (result.captions ?? []).map(\.text).joined(separator: "\n")
            display?.status.text = "Prepared screen • shared decoder pool"
            #endif
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
            blit.copy(from: drawable.texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: .init(x: 0, y: 0, z: 0), sourceSize: .init(width: width, height: height, depth: 1),
                to: buffer, destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * height)
            blit.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            XCTAssertNil(command.error)
            let pixels = buffer.contents().assumingMemoryBound(to: UInt8.self)
            let offset = 80 * stride + 100 * 4
            return (pixels[offset + 2] > 180 && pixels[offset] < 70,
                pixels[offset] > 180 && pixels[offset + 2] < 70, result.captions ?? [])
        }
        func awaitPlayback() async throws {
            var red = false, blue = false, captions = false
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline && !(red && blue && captions) {
                let value = try await frame()
                red = red || value.red
                blue = blue || value.blue
                captions = captions || value.captions.contains { !$0.text.isEmpty }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            XCTAssertTrue(red && blue && captions, "Prepared screen delivers both video colors and captions")
        }
        try await awaitPlayback()
        let other = UUID()
        let request: [Int: ExperienceVideoDecoderPool.Request] = [99: .init(
            pixelsPerSecond: ExperienceVideoDecoderPool.productionBudget.managedPixelsPerSecond, priority: UInt32.max, visible: true)]
        XCTAssertTrue(try pool.update(owner: other, requests: request).isEmpty,
            "The existing decoder holds its reservation until its owner retires it")
        _ = try await screen.step(elapsedSeconds: 0.03)
        XCTAssertEqual(try pool.update(owner: other, requests: request), [99])
        let suspended = try await frame()
        XCTAssertTrue(suspended.captions.isEmpty, "Resource suspension withdraws captions")
        pool.remove(owner: other)
        try await awaitPlayback()
        try await screen.setMediaVisible(false)
        XCTAssertEqual(try pool.update(owner: other, requests: request), [99],
            "Hiding releases capacity without another step or render")
        pool.remove(owner: other)
        try await screen.setMediaVisible(true)
        try await awaitPlayback()
        try await screen.close()
        XCTAssertEqual(try pool.update(owner: other, requests: request), [99], "Screen close releases its reservation")
        pool.remove(owner: other)
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
                authoredAssetId: UInt64(id), assetUniqueName: name, sha256: digest, sizeBytes: bytes.count,
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
                assets: [.init(kind: .video, authoredAssetID: id, assetUniqueName: name, sourceKey: key,
                    contentType: "video/mp4", sha256: digest, required: required, bytes: nil, fileURL: url)])
            let runtime = try await NuxieNativeRuntime.open(bytes: scene, artboardName: "Video Frame", player: .defaultScene,
                pixelWidth: 320, pixelHeight: 640,
                importMode: .configured(moduleName: "nuxie", expectedAssets: catalog, externalAssets: [:], videoEnabled: true))
            do {
                _ = try await runtime.step(elapsedSeconds: 0)
                let host = try await ExperienceVideoPlayback.open(runtime: runtime, payload: payload,
                    artboardBounds: CGRect(x: 0, y: 0, width: 320, height: 640))
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
            authoredAssetId: 1, assetUniqueName: "greeting-1", sha256: digest, sizeBytes: 100,
            width: 64, height: 32, durationMs: 2000, videoCodec: "avc1.42e01e", audioCodec: nil,
            captionTracks: [], required: true)
        let plan = NativeExperienceRenderPlan(identity: .init(experienceId: "experience", buildId: "build", appId: "app", environment: "test"),
            scene: .init(key: "scene.nux", sha256: digest, sizeBytes: 1), entry: .init(screenId: "screen"),
            screens: [], transitions: [], textInputs: [], images: [], fonts: [], videos: [video])
        let catalog = [NuxieNativeFileAssetDescriptor(ordinal: 0, kind: .video, authoredID: 1,
            name: "greeting", fileExtension: "mp4", isEmbedded: false, hasContentsRecord: false, requiredProviderFlags: 4)]
        func asset(fileURL: URL?, id: UInt32 = 1, sourceKey: String? = nil, bytes: Data? = nil) -> AuthenticatedRuntimeAsset {
            .init(kind: .video, authoredAssetID: id, assetUniqueName: "greeting-1", sourceKey: sourceKey ?? key,
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
