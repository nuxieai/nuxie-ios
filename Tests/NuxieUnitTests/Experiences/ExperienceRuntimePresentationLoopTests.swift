#if canImport(UIKit) && canImport(QuartzCore)
import Metal
import QuartzCore
import XCTest
@testable import Nuxie

final class ExperienceRuntimePresentationLoopTests: XCTestCase {
    @MainActor
    func testConfiguresSwiftOwnedLayerAndCompletesOneNativeFrameExactlyOnce() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        let session = ExperienceRuntimePresentationSession { operation in
            try await recorder.perform(operation)
        }
        let (window, view) = makePresentationSurface()
        var deliveredStepCount = 0
        let loop = ExperienceRuntimePresentationLoop(
            session: session,
            surfaceView: view,
            usesSystemDisplayLink: false,
            onSessionResult: { deliveredStepCount += 1 }
        )

        try await loop.start()
        loop.displayLinkDidFire(at: 1)

        XCTAssertTrue(await recorder.waitForOperation(named: "render"))
        XCTAssertEqual(await recorder.operationNames(), ["metalDevice", "resize", "step", "render"])
        XCTAssertTrue(view.metalLayer.device === device)
        XCTAssertEqual(view.metalLayer.pixelFormat, .bgra8Unorm)
        XCTAssertTrue(view.metalLayer.framebufferOnly)
        XCTAssertEqual(deliveredStepCount, 1)
        XCTAssertEqual(await recorder.nativeCompletionCount(), 1)

        await loop.shutdown()
        _ = window
    }
}

private actor PresentationSessionRecorder {
    private let device: any MTLDevice
    private var names: [String] = []
    private var completionCount = 0

    init(device: any MTLDevice) {
        self.device = device
    }

    func perform(
        _ operation: ExperienceRuntimePresentationSessionOperation
    ) async throws -> ExperienceRuntimePresentationSessionResult {
        switch operation {
        case .copyMetalDevice:
            names.append("metalDevice")
            return .metalDevice(device)
        case .resize(let size):
            names.append("resize")
            return .renderer(ExperienceRuntimePresentationRenderOutcome(
                disposition: size.isZero ? .skippedZeroSize : .reconfigured,
                health: .healthy,
                pixelWidth: size.pixelWidth,
                pixelHeight: size.pixelHeight,
                drawCalls: 0
            ))
        case .step:
            names.append("step")
            return .session(keepsAnimating: false)
        case .render(_, let completion):
            names.append("render")
            completion.signalFromNative()
            completion.signalFromNative()
            completionCount += 1
            return .renderer(ExperienceRuntimePresentationRenderOutcome(
                disposition: .presented,
                health: .healthy,
                pixelWidth: 128,
                pixelHeight: 64,
                drawCalls: 1
            ))
        case .detach:
            names.append("detach")
            return .renderer(.detached)
        case .reattach(let size):
            names.append("reattach")
            return .renderer(.recreated(size))
        case .resetPlayerRendererDomain:
            names.append("reset")
            return .none
        case .close:
            names.append("close")
            return .none
        }
    }

    func operationNames() -> [String] { names }
    func nativeCompletionCount() -> Int { completionCount }

    func waitForOperation(named name: String) async -> Bool {
        for _ in 0..<200 {
            if names.contains(name) { return true }
            await Task.yield()
        }
        return false
    }
}

@MainActor
private func makePresentationSurface() -> (UIWindow, ExperienceRuntimeSurfaceView) {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 128, height: 64))
    let view = ExperienceRuntimeSurfaceView(frame: window.bounds)
    window.addSubview(view)
    window.isHidden = false
    view.layoutIfNeeded()
    return (window, view)
}
#endif
