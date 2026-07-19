import Foundation
import Metal
import Nimble
import Quick
import UIKit
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private enum FlowRuntimeDisplayHostTestError: Error {
    case failed
}

final class FlowRuntimeDisplayHostTests: AsyncSpec {
    override class func spec() {
        describe("FlowRuntimeDisplayHost lifecycle") {
            it("uses a nonblocking bounded drawable budget") { @MainActor in
                let gate = FlowRuntimeDrawableGate(capacity: 2)
                let first = gate.tryAcquire()
                let second = gate.tryAcquire()

                expect(first).notTo(beNil())
                expect(second).notTo(beNil())
                expect(gate.tryAcquire()).to(beNil())

                first?.release()
                expect(gate.tryAcquire()).notTo(beNil())
            }

            it("acquires and forwards drawables while reusing permits after presented and skipped frames") { @MainActor in
                let presented = FlowRuntimeOperationResult(
                    renderOutcome: .presented,
                    surfaceDisposition: .presented,
                    isDirty: true,
                    isSettled: false
                )
                let skipped = FlowRuntimeOperationResult(
                    renderOutcome: .skipped,
                    surfaceDisposition: .skippedTimeout,
                    isDirty: true,
                    isSettled: false
                )
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(presented),
                    .success(skipped),
                    .success(presented),
                ])
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                let gate = FlowRuntimeDrawableGate(capacity: 1)
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    drawableGate: gate,
                    usesSystemDisplayLink: false
                )
                try await host.start()
                guard let driver = adapter.contextDrivers.first?.sessionDrivers.first else {
                    fail("expected fake runtime session driver")
                    return
                }

                for (index, timestamp) in [1.0, 2.0, 3.0].enumerated() {
                    host.displayLinkDidFire(at: timestamp)
                    let completed = await waitForOperationCount(index + 1, driver: driver)
                    expect(completed).to(beTrue())
                }

                expect(driver.performedWithDrawable).to(equal([true, true, true]))
                _ = window
                await host.shutdown()
            }

            it("keeps a submitted drawable in flight when post-submit device health fails") { @MainActor in
                let deviceLost = FlowRuntimeOperationResult(
                    renderOutcome: .skipped,
                    surfaceDisposition: .deviceLost,
                    isDirty: true,
                    isSettled: false
                )
                let recorder = FakeFlowRuntimeLifecycleRecorder()
                let completionGate = FakeFlowRuntimeDrawableCompletionGate()
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [.success(deviceLost)],
                    lifecycleRecorder: recorder,
                    drawableCompletionGate: completionGate
                )
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                let gate = FlowRuntimeDrawableGate(capacity: 1)
                var receivedError = false
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    drawableGate: gate,
                    usesSystemDisplayLink: false,
                    onError: { _ in receivedError = true }
                )
                try await host.start()

                host.displayLinkDidFire(at: 1)
                await completionGate.waitUntilDrawableIsRetained()
                let failed = await waitUntil { receivedError }
                expect(failed).to(beTrue())
                expect(gate.tryAcquire()).to(beNil())

                let shutdown = Task { @MainActor in
                    await host.shutdown()
                }
                for _ in 0..<50 {
                    await Task.yield()
                }
                expect(recorder.events).notTo(contain(.surfaceDetached))

                completionGate.completeAll()
                await shutdown.value

                expect(recorder.events).to(contain(.surfaceDetached))
                let recoveredPermit = gate.tryAcquire()
                expect(recoveredPermit).notTo(beNil())
                recoveredPermit?.release()
                _ = window
            }

            it("releases its drawable permit when the runtime frame throws") { @MainActor in
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .failure(FlowRuntimeDisplayHostTestError.failed)
                ])
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                let gate = FlowRuntimeDrawableGate(capacity: 1)
                var receivedError = false
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    drawableGate: gate,
                    usesSystemDisplayLink: false,
                    onError: { _ in receivedError = true }
                )
                try await host.start()

                host.displayLinkDidFire(at: 1)
                let didReceiveError = await waitUntil { receivedError }
                expect(didReceiveError).to(beTrue())
                let recoveredPermit = gate.tryAcquire()
                expect(recoveredPermit).notTo(beNil())
                recoveredPermit?.release()

                _ = window
                await host.shutdown()
            }

            it("does not acquire a stale drawable for a zero-sized logical surface") { @MainActor in
                let skipped = FlowRuntimeOperationResult(
                    renderOutcome: .skipped,
                    surfaceDisposition: .skippedZeroSize,
                    isDirty: true,
                    isSettled: false
                )
                let recorder = FakeFlowRuntimeLifecycleRecorder()
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [.success(skipped)],
                    lifecycleRecorder: recorder
                )
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                let gate = FlowRuntimeDrawableGate(capacity: 1)
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    drawableGate: gate,
                    usesSystemDisplayLink: false
                )
                try await host.start()
                guard let driver = adapter.contextDrivers.first?.sessionDrivers.first else {
                    fail("expected fake runtime session driver")
                    return
                }

                view.bounds.size = .zero
                host.runtimeSurfaceViewGeometryDidChange()
                let resized = await waitUntil {
                    recorder.events.contains(
                        .surfaceResized(
                            FlowRuntimeSurfaceSize(pixelWidth: 0, pixelHeight: 0)
                        )
                    )
                }
                expect(resized).to(beTrue())

                host.displayLinkDidFire(at: 1)
                let completed = await waitForOperationCount(1, driver: driver)
                expect(completed).to(beTrue())
                expect(driver.performedWithDrawable).to(equal([false]))

                let untouchedPermit = gate.tryAcquire()
                expect(untouchedPermit).notTo(beNil())
                untouchedPermit?.release()

                _ = window
                await host.shutdown()
            }

            it("does not resurrect after shutdown races an in-progress start") { @MainActor in
                let gate = FakeFlowRuntimeSurfaceAttachmentGate()
                let recorder = FakeFlowRuntimeLifecycleRecorder()
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [],
                    lifecycleRecorder: recorder,
                    surfaceAttachmentGate: gate
                )
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
                let view = FlowRuntimeSurfaceView(frame: window.bounds)
                window.addSubview(view)
                window.isHidden = false
                let host = FlowRuntimeDisplayHost(session: session, surfaceView: view)

                let start = Task { @MainActor in
                    try await host.start()
                }
                await gate.waitUntilAttachmentIsSuspended()

                let shutdown = Task { @MainActor in
                    await host.shutdown()
                }
                await Task.yield()
                gate.resumeAttachment()

                await shutdown.value
                var startWasCancelled = false
                do {
                    try await start.value
                } catch is CancellationError {
                    startWasCancelled = true
                } catch {
                    fail("unexpected start error: \(error)")
                }

                expect(startWasCancelled).to(beTrue())
                expect(recorder.events.count).to(equal(2))
                guard let firstEvent = recorder.events.first,
                      case .surfaceAttached = firstEvent else {
                    fail("expected the suspended operation to finish attaching before disposal")
                    return
                }
                expect(recorder.events.last).to(equal(.surfaceDisposed))
            }

            it("coalesces concurrent starts into one attached surface") { @MainActor in
                let gate = FakeFlowRuntimeSurfaceAttachmentGate()
                let recorder = FakeFlowRuntimeLifecycleRecorder()
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [],
                    lifecycleRecorder: recorder,
                    surfaceAttachmentGate: gate
                )
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 160, height: 90))
                let view = FlowRuntimeSurfaceView(frame: window.bounds)
                window.addSubview(view)
                window.isHidden = false
                let host = FlowRuntimeDisplayHost(session: session, surfaceView: view)

                let first = Task { @MainActor in try await host.start() }
                await gate.waitUntilAttachmentIsSuspended()
                let second = Task { @MainActor in try await host.start() }
                await Task.yield()
                gate.resumeAttachment()

                try await first.value
                try await second.value
                let attachmentCount = recorder.events.filter { event in
                    if case .surfaceAttached = event { return true }
                    return false
                }.count
                expect(attachmentCount).to(equal(1))

                await host.shutdown()
            }
        }
    }
}

@MainActor
private func makeConfiguredMetalSurface() -> (UIWindow, FlowRuntimeSurfaceView)? {
    guard let device = MTLCreateSystemDefaultDevice() else {
        fail("Metal device is required for the display-host test")
        return nil
    }
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 64, height: 48))
    let view = FlowRuntimeSurfaceView(frame: window.bounds)
    window.addSubview(view)
    window.isHidden = false
    let scale = window.screen.scale
    view.metalLayer.device = device
    view.metalLayer.pixelFormat = .bgra8Unorm
    view.metalLayer.framebufferOnly = true
    view.metalLayer.maximumDrawableCount = 2
    view.metalLayer.allowsNextDrawableTimeout = true
    view.metalLayer.drawableSize = CGSize(
        width: view.bounds.width * scale,
        height: view.bounds.height * scale
    )
    return (window, view)
}

@MainActor
private func waitForOperationCount(
    _ count: Int,
    driver: FakeFlowRenderSessionDriver
) async -> Bool {
    await waitUntil { driver.performedOperations.count >= count }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<1_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
