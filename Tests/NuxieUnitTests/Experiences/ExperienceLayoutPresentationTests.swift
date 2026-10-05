#if canImport(UIKit) && canImport(QuartzCore)
import Metal
import QuartzCore
import XCTest
@testable import Nuxie

final class ExperienceLayoutPresentationTests: XCTestCase {
    @MainActor
    func testFirstFrameAndResizeSetPointSizeBeforeZeroStepAndScaledRender() async throws {
        guard #available(iOS 17, *) else { throw XCTSkip("Display-scale overrides require iOS 17") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal is unavailable") }
        let recorder = LayoutSessionRecorder(device: device)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.traitOverrides.displayScale = 3
        let view = ExperienceRuntimeSurfaceView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        let loop = ExperienceRuntimePresentationLoop(
            session: .init(perform: { try await recorder.perform($0) }),
            surfaceView: view, usesSystemDisplayLink: false,
            acquireDrawable: { _ in nil }, onError: { XCTFail("\($0)") })
        try await loop.start()
        loop.displayLinkDidFire(at: 1)
        let first = await recorder.waitForRenders(1)
        XCTAssertTrue(first)
        var events = await recorder.recordedEvents()
        XCTAssertEqual(events, ["size:393.0,852.0", "step:0.0", "render:3.0"])
        view.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        loop.displayLinkDidFire(at: 2)
        let second = await recorder.waitForRenders(2)
        XCTAssertTrue(second)
        events = await recorder.recordedEvents()
        XCTAssertEqual(Array(events.suffix(3)), ["size:375.0,667.0", "step:0.0", "render:3.0"])
        await loop.shutdown()
        window.isHidden = true
    }

    @MainActor
    func testResizeDuringStepSettlesNewSizeBeforeDrawing() async throws {
        guard #available(iOS 17, *) else { throw XCTSkip("Display-scale overrides require iOS 17") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal is unavailable") }
        let recorder = LayoutSessionRecorder(device: device)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.traitOverrides.displayScale = 3
        let view = ExperienceRuntimeSurfaceView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        let loop = ExperienceRuntimePresentationLoop(
            session: .init(perform: { try await recorder.perform($0) }),
            surfaceView: view, usesSystemDisplayLink: false,
            acquireDrawable: { _ in nil }, onError: { XCTFail("\($0)") })
        try await loop.start()
        await recorder.holdNextStep()
        loop.displayLinkDidFire(at: 1)
        let held = await recorder.waitForHeldStep()
        XCTAssertTrue(held)
        view.frame.size = CGSize(width: 375, height: 667)
        view.layoutIfNeeded()
        await recorder.releaseStep()
        let rendered = await recorder.waitForRenders(1)
        XCTAssertTrue(rendered)
        let events = await recorder.recordedEvents()
        XCTAssertEqual(events, ["size:393.0,852.0", "step:0.0", "size:375.0,667.0", "step:0.0", "render:3.0"])
        await loop.shutdown()
        window.isHidden = true
    }
    @MainActor
    func testScaleChangeWithIdenticalPixelsStillSettlesPointSize() async throws {
        guard #available(iOS 17, *) else { throw XCTSkip("Display-scale overrides require iOS 17") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal is unavailable") }
        let recorder = LayoutSessionRecorder(device: device)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.traitOverrides.displayScale = 3
        let view = ExperienceRuntimeSurfaceView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        let loop = ExperienceRuntimePresentationLoop(
            session: .init(perform: { try await recorder.perform($0) }),
            surfaceView: view, usesSystemDisplayLink: false,
            acquireDrawable: { _ in nil }, onError: { XCTFail("\($0)") })
        try await loop.start()
        loop.displayLinkDidFire(at: 1)
        let first = await recorder.waitForRenders(1)
        XCTAssertTrue(first)
        window.traitOverrides.displayScale = 2
        view.frame.size = CGSize(width: 589.5, height: 1278)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        loop.displayLinkDidFire(at: 2)
        let second = await recorder.waitForRenders(2)
        XCTAssertTrue(second)
        let events = await recorder.recordedEvents()
        XCTAssertEqual(Array(events.suffix(3)), ["size:589.5,1278.0", "step:0.0", "render:2.0"])
        await loop.shutdown()
        window.isHidden = true
    }

    @MainActor
    func testUnattachedViewDoesNotDrawAndZeroScaleHasNoPixelExtent() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal is unavailable") }
        let recorder = LayoutSessionRecorder(device: device)
        let view = ExperienceRuntimeSurfaceView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        XCTAssertNil(view.window)
        XCTAssertEqual(ExperienceRuntimeSurfaceSizing.pixels(width: 393, height: 852, scale: 0),
            ExperienceRuntimeSurfaceSize(pixelWidth: 0, pixelHeight: 0, layoutScaleFactor: 0))
        let loop = ExperienceRuntimePresentationLoop(
            session: .init(perform: { try await recorder.perform($0) }),
            surfaceView: view, usesSystemDisplayLink: false,
            acquireDrawable: { _ in XCTFail("Unattached views must not acquire a drawable"); return nil },
            onError: { XCTFail("\($0)") })
        try await loop.start()
        loop.displayLinkDidFire(at: 1)
        await loop.shutdown()
        let events = await recorder.recordedEvents()
        XCTAssertFalse(events.contains { $0.hasPrefix("render:") || $0.hasPrefix("step:") })
    }

}

private actor LayoutSessionRecorder {
    let device: any MTLDevice
    private var events: [String] = []
    private var size = ExperienceRuntimeSurfaceSize(pixelWidth: 0, pixelHeight: 0, layoutScaleFactor: 0)
    private var renders = 0
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(device: any MTLDevice) { self.device = device }
    func recordedEvents() -> [String] { events }
    func holdNextStep() { hold = true }
    func releaseStep() { continuation?.resume(); continuation = nil }
    func waitForHeldStep() async -> Bool {
        for _ in 0..<200 {
            if continuation != nil { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
    func waitForRenders(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if renders >= count { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
    func perform(_ operation: ExperienceRuntimePresentationSessionOperation) async throws -> ExperienceRuntimePresentationSessionResult {
        switch operation {
        case .copyMetalDevice: return .metalDevice(device)
        case .resize(let next):
            size = next
            events.append("size:\(Float(next.pixelWidth) / next.layoutScaleFactor),\(Float(next.pixelHeight) / next.layoutScaleFactor)")
            return .renderer(outcome(.reconfigured))
        case .step(let step):
            events.append("step:\(step.elapsedSeconds)")
            if hold { hold = false; await withCheckedContinuation { continuation = $0 } }
            return .session {}
        case .render(_, let scale, let completion):
            events.append("render:\(scale)")
            renders += 1
            completion.signalFromNative()
            return .renderer(outcome(.skippedTimeout))
        case .queued(let work): return try await work.perform()
        case .setMediaVisible, .close: return .none
        }
    }
    private func outcome(_ disposition: ExperienceRuntimePresentationRenderOutcome.Disposition) -> ExperienceRuntimePresentationRenderOutcome {
        .init(disposition: disposition, health: .healthy, pixelWidth: size.pixelWidth, pixelHeight: size.pixelHeight, drawCalls: 0)
    }
}
#endif
