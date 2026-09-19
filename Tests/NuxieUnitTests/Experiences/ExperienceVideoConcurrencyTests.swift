#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import Metal
import QuartzCore
import UIKit
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieRuntime

/// Qualifies actual composed frames against the SDK's process-wide admission
/// budget. Four admissions are a workload policy, not a hardware capacity claim.
final class ExperienceVideoConcurrencyTests: XCTestCase {
    @MainActor
    func testProductionPoolSaturationHandsDecoderToWaitingRuntime() async throws {
        let payload = try await fixturePayload()
        let scene = payload.sceneBytes
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        let bundle = Bundle(for: Self.self)
        var runtimes: [NuxieNativeRuntime] = []
        var hosts: [ExperienceVideoPlayback] = []
        var layers: [CAMetalLayer] = []
        var buffers: [MTLBuffer] = []
        defer {
            for host in hosts { host.close() }
            for runtime in runtimes { Task { try? await runtime.close() } }
        }
        var canvas: UIView?
        var label: UILabel?
        if bundle.bundleIdentifier == "com.nuxie.sdk.video-device-tests" {
            func window() -> UIWindow? {
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows).first { $0.isKeyWindow && !$0.isHidden }
            }
            let deadline = Date().addingTimeInterval(3)
            while window() == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            let window = try XCTUnwrap(window())
            window.viewWithTag(904_321)?.removeFromSuperview()
            let view = UIView(frame: window.bounds)
            view.tag = 904_321
            view.backgroundColor = .systemBackground
            window.addSubview(view)
            let status = UILabel(frame: CGRect(x: 12, y: window.safeAreaInsets.top + 8, width: view.bounds.width - 24, height: 50))
            status.text = "Four 720p videos playing • fifth waiting"
            status.numberOfLines = 2
            status.textAlignment = .center
            view.addSubview(status)
            canvas = view
            label = status
        }
        let idleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimer }
        for index in 0..<5 {
            let runtime = try await NuxieNativeRuntime.open(bytes: scene, artboardName: "Video Frame", player: .defaultScene,
                pixelWidth: 320, pixelHeight: 640, importMode: .configured(moduleName: "nuxie",
                    expectedAssets: catalog, externalAssets: [:], videoEnabled: true))
            runtimes.append(runtime)
            _ = try await runtime.step(elapsedSeconds: 0)
            let occurrences = try await runtime.videos()
            let component = try XCTUnwrap(occurrences.first).componentID
            try await runtime.videoCommand(componentID: component, kind: 5, value: 1)
            try await runtime.videoCommand(componentID: component, kind: 9, value: 1)
            let host = try await ExperienceVideoPlayback.open(runtime: runtime, payload: payload,
                artboardBounds: CGRect(x: 0, y: 0, width: 320, height: 640), decoderPool: .shared)
            hosts.append(host)
            let device = try await runtime.metalDevice().value
            let layer = CAMetalLayer()
            layer.device = device
            layer.pixelFormat = .bgra8Unorm
            layer.framebufferOnly = false
            if let canvas {
                let area = canvas.bounds.inset(by: canvas.safeAreaInsets).insetBy(dx: 12, dy: 72)
                let cellWidth = area.width / 2, cellHeight = area.height / 3
                let width = min(cellWidth - 8, cellHeight / 2)
                layer.frame = CGRect(x: area.minX + CGFloat(index % 2) * cellWidth,
                    y: area.minY + CGFloat(index / 2) * cellHeight, width: width, height: width * 2)
                canvas.layer.addSublayer(layer)
            }
            layer.drawableSize = CGSize(width: 320, height: 640)
            layers.append(layer)
            buffers.append(try XCTUnwrap(device.makeBuffer(length: 320 * 640 * 4, options: .storageModeShared)))
        }
        var colors = Array(repeating: Set<String>(), count: 5)
        var retired = false
        let deadline = Date().addingTimeInterval(15)
        let started = Date()
        while Date() < deadline {
            for index in (retired ? 1 : 0)..<5 {
                _ = try await runtimes[index].step(elapsedSeconds: 0.03)
                _ = try await hosts[index].tick()
                let drawable = try XCTUnwrap(layers[index].nextDrawable())
                let completed = expectation(description: "Composed frame \(index)")
                _ = try await runtimes[index].render(drawable: .available(.init(drawable)),
                    readback: .init(buffer: buffers[index], bytesPerRow: 320 * 4), completion: { completed.fulfill() })
                await fulfillment(of: [completed], timeout: 2)
                let pixel = buffers[index].contents().assumingMemoryBound(to: UInt8.self) + (80 * 320 + 100) * 4
                if pixel[2] > 180 && pixel[0] < 70 { colors[index].insert("red") }
                if pixel[0] > 180 && pixel[2] < 70 { colors[index].insert("blue") }
            }
            XCTAssertLessThanOrEqual(hosts.reduce(0) { $0 + $1.activeDecoderCount }, 4,
                "Production pool must bound actual AVPlayer owners")
            if !retired {
                XCTAssertEqual(hosts[4].activeDecoderCount, 0)
                XCTAssertEqual(hosts[4].deliveredFrames, 0, "Fifth runtime must wait for an actual decoder disposal")
                if colors.prefix(4).allSatisfy({ $0.count == 2 }) && Date().timeIntervalSince(started) >= 3 {
                    hosts[0].close()
                    try await runtimes[0].close()
                    layers[0].removeFromSuperlayer()
                    retired = true
                    colors = Array(repeating: [], count: 5)
                    label?.text = "First video released • fifth now playing"
                }
            } else if colors.dropFirst().allSatisfy({ $0.count == 2 }) { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertTrue(retired, "Four independent runtime lanes must compose red and blue before handoff")
        XCTAssertTrue(colors.dropFirst().allSatisfy({ $0.count == 2 }), "Waiting runtime and retained lanes must compose both colors after handoff")
        XCTAssertGreaterThan(hosts[4].deliveredFrames, 0)
        label?.text = retired && colors.dropFirst().allSatisfy({ $0.count == 2 })
            ? "Passed: four live videos, fifth admitted after release"
            : "Video concurrency check failed — see test results"
        print("VIDEO_CONCURRENCY lanes=5 simultaneous=4 source=1280x720 policy=production handedOff=\(retired) frames=\(hosts.map(\.deliveredFrames)) colors=\(colors)")
        for host in hosts { host.close() }
        XCTAssertEqual(hosts.reduce(0) { $0 + $1.activeDecoderCount }, 0)
    }
    @MainActor
    private func fixturePayload() async throws -> AuthenticatedRuntimePayload {
        let bundle = Bundle(for: Self.self)
        let directory: URL
        if let bundled = bundle.resourceURL?.appendingPathComponent("video"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("greeting.nux").path) {
            directory = bundled
        } else {
            directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("fixtures/video")
        }
        let scene = try Data(contentsOf: directory.appendingPathComponent("greeting.nux"))
        let url = directory.appendingPathComponent("captions-720p.mp4")
        let bytes = try Data(contentsOf: url)
        let digest = SHA256Provider.hexDigest(bytes)
        let key = "assets/sha256/\(digest).mp4"
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        let authored = try XCTUnwrap(catalog.first { $0.kind == .video })
        let id = try XCTUnwrap(authored.authoredID)
        let name = "\(authored.name)-\(id)"
        struct Inventory: Decodable { let videoElements: [NativeExperienceVideoElement] }
        let inventory = try JSONDecoder().decode(Inventory.self,
            from: Data(contentsOf: directory.appendingPathComponent("inventory.json")))
        let video = NativeExperienceVideoAsset(location: .external(key: key), sourceAssetKey: "asset:clip",
            authoredAssetId: UInt64(id), assetUniqueName: name, sha256: digest, sizeBytes: bytes.count,
            width: 1280, height: 720, durationMs: 2022, videoCodec: "avc1.42c01f",
            audioCodec: "mp4a.40.2", captionTracks: [], required: true)
        let plan = NativeExperienceRenderPlan(identity: .init(experienceId: "video", buildId: "concurrency", appId: "app", environment: "test"),
            scene: .init(key: "scene.nux", sha256: SHA256Provider.hexDigest(scene), sizeBytes: scene.count),
            entry: .init(screenId: "screen"), screens: [.init(screenId: "screen", artboardId: "screen",
                artboardName: "Video Frame", width: 320, height: 640, exit: nil)],
            transitions: [], textInputs: [], images: [], fonts: [], videos: [video], videoElements: inventory.videoElements)
        let payload = AuthenticatedRuntimePayload(authenticatedKeyID: "test", renderPlan: plan,
            journey: JourneyDocument(screens: [.init(id: "screen")]), sceneBytes: scene,
            assets: [.init(kind: .video, authoredAssetID: id, assetUniqueName: name, sourceKey: key,
                contentType: "video/mp4", sha256: digest, required: true, bytes: nil, fileURL: url)])
        return payload
    }

    @MainActor
    func testRepeatedPlaybackRetiresResourcesAndReusesPool() async throws {
        let payload = try await fixturePayload()
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: payload.sceneBytes)
        let idleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimer }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow && !$0.isHidden }
        let canvas = UIView(frame: window?.bounds ?? CGRect(x: 0, y: 0, width: 320, height: 640))
        canvas.backgroundColor = .black
        window?.addSubview(canvas)
        defer { canvas.removeFromSuperview() }
        let status = UILabel(frame: CGRect(x: 12, y: 60, width: canvas.bounds.width - 24, height: 50))
        status.textColor = .white
        canvas.addSubview(status)

        func cycle(_ index: Int) async throws {
            let runtime = try await NuxieNativeRuntime.open(bytes: payload.sceneBytes, artboardName: "Video Frame", player: .defaultScene,
                pixelWidth: 320, pixelHeight: 640, importMode: .configured(moduleName: "nuxie",
                    expectedAssets: catalog, externalAssets: [:], videoEnabled: true))
            var runtimeClosed = false
            defer { if !runtimeClosed { Task { try? await runtime.close() } } }
            _ = try await runtime.step(elapsedSeconds: 0)
            let occurrences = try await runtime.videos()
            let component = try XCTUnwrap(occurrences.first).componentID
            try await runtime.videoCommand(componentID: component, kind: 5, value: 1)
            try await runtime.videoCommand(componentID: component, kind: 9, value: 1)
            let host = try await ExperienceVideoPlayback.open(runtime: runtime, payload: payload,
                artboardBounds: CGRect(x: 0, y: 0, width: 320, height: 640), decoderPool: .shared)
            defer { host.close() }
            let device = try await runtime.metalDevice().value
            let layer = CAMetalLayer()
            layer.device = device
            layer.pixelFormat = .bgra8Unorm
            layer.framebufferOnly = false
            layer.frame = CGRect(x: 0, y: 120, width: canvas.bounds.width, height: canvas.bounds.width * 2)
            layer.drawableSize = CGSize(width: 320, height: 640)
            canvas.layer.addSublayer(layer)
            defer { layer.removeFromSuperlayer() }
            let buffer = try XCTUnwrap(device.makeBuffer(length: 320 * 640 * 4, options: .storageModeShared))
            var colors = Set<String>()
            let deadline = Date().addingTimeInterval(10)
            status.text = "Playback session \(index + 1) / 10"
            while colors.count < 2 && Date() < deadline {
                _ = try await runtime.step(elapsedSeconds: 0.03)
                _ = try await host.tick()
                let drawable = try XCTUnwrap(layer.nextDrawable())
                let completed = expectation(description: "Lifecycle composed frame")
                _ = try await runtime.render(drawable: .available(.init(drawable)),
                    readback: .init(buffer: buffer, bytesPerRow: 320 * 4), completion: { completed.fulfill() })
                await fulfillment(of: [completed], timeout: 2)
                let pixel = buffer.contents().assumingMemoryBound(to: UInt8.self) + (80 * 320 + 100) * 4
                if pixel[2] > 180 && pixel[0] < 70 { colors.insert("red") }
                if pixel[0] > 180 && pixel[2] < 70 { colors.insert("blue") }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            XCTAssertEqual(colors.count, 2, "Every new session must actually compose both video phases")
            XCTAssertEqual(host.activeDecoderCount, 1)
            try await runtime.videoCommand(componentID: component, kind: 1, value: 0)
            _ = try await host.tick()
            host.close()
            XCTAssertEqual(host.activeDecoderCount, 0)
            try await runtime.close()
            runtimeClosed = true
        }
        var residentBytes: [UInt64] = []
        for index in 0..<10 {
            try await cycle(index)
            let owner = UUID()
            let requests = Dictionary(uniqueKeysWithValues: (0..<4).map {
                ($0, ExperienceVideoDecoderPool.Request(pixelsPerSecond: 1280 * 720 * 31, priority: 0, visible: true))
            })
            defer { ExperienceVideoDecoderPool.shared.remove(owner: owner) }
            XCTAssertEqual(try ExperienceVideoDecoderPool.shared.update(owner: owner, requests: requests).count, 4,
                "All four production reservations must be reusable after each session closes")
            ExperienceVideoDecoderPool.shared.remove(owner: owner)
            try await Task.sleep(nanoseconds: 100_000_000)
            var info = mach_task_basic_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            XCTAssertEqual(result, KERN_SUCCESS)
            residentBytes.append(UInt64(info.resident_size))
        }
        let warmed = residentBytes.dropFirst(2)
        print("VIDEO_LIFECYCLE cycles=10 closedDecoderCount=0 reusableSlots=4 rssBytes=\(residentBytes) warmedMin=\(warmed.min() ?? 0) warmedMax=\(warmed.max() ?? 0) measurement=processRSS_notGPU localFixture=noNetwork")
        status.text = "Passed: ten playback sessions released"
    }

}
#endif
