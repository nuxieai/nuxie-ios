#if canImport(UIKit)
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
        describe("FlowRuntimeDisplayHost lifecycle and input") {
            it("maps touch input through authored bounds and ends with one up event") { @MainActor in
                let operationResult = FlowRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: true,
                    isSettled: false
                )
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [
                        .success(operationResult),
                        .success(operationResult),
                    ],
                    bootstrap: pointerBootstrap(
                        bounds: FlowRuntimeArtboardBounds(
                            minX: 10,
                            minY: 20,
                            maxX: 110,
                            maxY: 120
                        )
                    )
                )
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface(
                    size: CGSize(width: 300, height: 200)
                ) else { return }
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    onResult: { _ in }
                )
                try await host.start()
                guard let driver = adapter.contextDrivers.first?.sessionDrivers.first else {
                    fail("expected fake runtime session driver")
                    return
                }
                let touch = NSObject()
                let source = FlowRuntimePointerSourceID(touch)

                host.runtimeSurfaceViewDidReceivePointerEvents([
                    FlowRuntimeViewPointerEvent(
                        source: source,
                        kind: .down,
                        location: CGPoint(x: 25, y: -10)
                    )
                ])
                let downCompleted = await waitForOperationCount(1, driver: driver)
                expect(downCompleted).to(beTrue())

                host.runtimeSurfaceViewDidReceivePointerEvents([
                    FlowRuntimeViewPointerEvent(
                        source: source,
                        kind: .up,
                        location: CGPoint(x: 325, y: 210)
                    )
                ])
                let upCompleted = await waitForOperationCount(2, driver: driver)
                expect(upCompleted).to(beTrue())

                guard case .pointerBatch(let down) = driver.performedOperations[0],
                      case .pointerBatch(let up) = driver.performedOperations[1] else {
                    fail("expected two pointer batches")
                    return
                }
                expect(down).to(equal([
                    FlowRuntimePointerEvent(
                        kind: .down,
                        pointerID: 1,
                        x: -2.5,
                        y: 15
                    )
                ]))
                expect(up).to(equal([
                    FlowRuntimePointerEvent(
                        kind: .up,
                        pointerID: 1,
                        x: 147.5,
                        y: 125
                    )
                ]))
                expect(driver.performedOperations.count).to(equal(2))

                _ = window
                await host.shutdown()
            }

            it("keeps pointer batches FIFO while giving a pending frame a turn") { @MainActor in
                let operationResult = FlowRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: true,
                    isSettled: false
                )
                let adapter = FakeFlowRuntimeAdapter(operationResults: Array(
                    repeating: .success(operationResult),
                    count: 4
                ))
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    onResult: { _ in }
                )
                try await host.start()
                guard let driver = adapter.contextDrivers.first?.sessionDrivers.first else {
                    fail("expected fake runtime session driver")
                    return
                }
                let firstSource = NSObject()
                let secondSource = NSObject()

                host.displayLinkDidFire(at: 1)
                host.displayLinkDidFire(at: 2)
                host.runtimeSurfaceViewDidReceivePointerEvents([
                    FlowRuntimeViewPointerEvent(
                        source: FlowRuntimePointerSourceID(firstSource),
                        kind: .down,
                        location: CGPoint(x: 32, y: 24)
                    )
                ])
                host.runtimeSurfaceViewDidReceivePointerEvents([
                    FlowRuntimeViewPointerEvent(
                        source: FlowRuntimePointerSourceID(secondSource),
                        kind: .move,
                        location: CGPoint(x: 44, y: 36)
                    )
                ])

                let completed = await waitForOperationCount(4, driver: driver)
                expect(completed).to(beTrue())
                guard driver.performedOperations.count == 4,
                      case .advanceAndRender(let firstFrame) = driver.performedOperations[0],
                      case .pointerBatch(let firstPointer) = driver.performedOperations[1],
                      case .advanceAndRender(let secondFrame) = driver.performedOperations[2],
                      case .pointerBatch(let secondPointer) = driver.performedOperations[3] else {
                    fail("expected frame, one pointer batch, the fair frame, then FIFO input")
                    return
                }
                expect(firstFrame).to(equal(FlowRuntimeFrameTime(timestamp: 1, delta: 0)))
                expect(firstPointer.map(\.kind)).to(equal([.down]))
                expect(firstPointer.map(\.pointerID)).to(equal([1]))
                expect(secondPointer.map(\.kind)).to(equal([.move]))
                expect(secondPointer.map(\.pointerID)).to(equal([2]))
                expect(secondFrame).to(equal(FlowRuntimeFrameTime(timestamp: 2, delta: 1)))

                _ = window
                await host.shutdown()
            }

            it("coalesces sustained pointer moves and gives a pending frame a turn") { @MainActor in
                let operationResult = FlowRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: true,
                    isSettled: false
                )
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: Array(
                        repeating: .success(operationResult),
                        count: 8
                    ),
                    bootstrap: pointerBootstrap(
                        bounds: FlowRuntimeArtboardBounds(
                            minX: 0,
                            minY: 0,
                            maxX: 64,
                            maxY: 48
                        )
                    )
                )
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    onResult: { _ in }
                )
                try await host.start()
                guard let driver = adapter.contextDrivers.first?.sessionDrivers.first else {
                    fail("expected fake runtime session driver")
                    return
                }
                let touch = NSObject()
                let source = FlowRuntimePointerSourceID(touch)

                host.runtimeSurfaceViewDidReceivePointerEvents([
                    FlowRuntimeViewPointerEvent(
                        source: source,
                        kind: .down,
                        location: CGPoint(x: 1, y: 1)
                    ),
                ])
                host.displayLinkDidFire(at: 1)
                for offset in 0..<1_000 {
                    host.runtimeSurfaceViewDidReceivePointerEvents([
                        FlowRuntimeViewPointerEvent(
                            source: source,
                            kind: .move,
                            location: CGPoint(
                                x: CGFloat(offset % 61),
                                y: CGFloat(offset % 41)
                            )
                        ),
                    ])
                }

                let completed = await waitForOperationCount(3, driver: driver)
                expect(completed).to(beTrue())
                guard driver.performedOperations.count >= 3,
                      case .pointerBatch(let down) = driver.performedOperations[0],
                      case .advanceAndRender = driver.performedOperations[1],
                      case .pointerBatch(let moves) = driver.performedOperations[2] else {
                    fail("expected down, the fair frame, then one coalesced move batch")
                    return
                }
                expect(down.map(\.kind)).to(equal([.down]))
                expect(moves).to(equal([
                    FlowRuntimePointerEvent(
                        kind: .move,
                        pointerID: 1,
                        x: 23,
                        y: 15
                    ),
                ]))

                _ = window
                await host.shutdown()
            }

            it("reserves bounded queue capacity for every admitted pointer terminal") { @MainActor in
                let operationResult = FlowRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: true,
                    isSettled: false
                )
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: Array(
                        repeating: .success(operationResult),
                        count: 10
                    ),
                    bootstrap: pointerBootstrap(
                        bounds: FlowRuntimeArtboardBounds(
                            minX: 0,
                            minY: 0,
                            maxX: 64,
                            maxY: 48
                        )
                    )
                )
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    onResult: { _ in }
                )
                try await host.start()
                guard let driver = adapter.contextDrivers.first?.sessionDrivers.first else {
                    fail("expected fake runtime session driver")
                    return
                }
                let sources = (0..<FlowRuntimeSessionLimits.pointerEvents).map { _ in
                    NSObject()
                }

                host.displayLinkDidFire(at: 1)
                let downs = sources.enumerated().map { index, source in
                    FlowRuntimeViewPointerEvent(
                        source: FlowRuntimePointerSourceID(source),
                        kind: .down,
                        location: CGPoint(x: CGFloat(index), y: CGFloat(index))
                    )
                }
                let moves = (0..<100).flatMap { offset in
                    sources.enumerated().map { index, source in
                        FlowRuntimeViewPointerEvent(
                            source: FlowRuntimePointerSourceID(source),
                            kind: .move,
                            location: CGPoint(
                                x: CGFloat(index + offset),
                                y: CGFloat(index + offset)
                            )
                        )
                    }
                }
                let terminals = sources.enumerated().map { index, source in
                    FlowRuntimeViewPointerEvent(
                        source: FlowRuntimePointerSourceID(source),
                        kind: .up,
                        location: CGPoint(
                            x: CGFloat(index + 100),
                            y: CGFloat(index + 100)
                        )
                    )
                }
                host.runtimeSurfaceViewDidReceivePointerEvents(
                    downs + moves + terminals
                )
                host.displayLinkDidFire(at: 2)

                let completed = await waitForOperationCount(4, driver: driver)
                expect(completed).to(beTrue())
                for _ in 0..<20 { await Task.yield() }
                guard driver.performedOperations.count == 4,
                      case .advanceAndRender(let firstFrame) = driver.performedOperations[0],
                      case .pointerBatch(let downs) = driver.performedOperations[1],
                      case .advanceAndRender(let fairFrame) = driver.performedOperations[2],
                      case .pointerBatch(let terminals) = driver.performedOperations[3] else {
                    fail("expected frame, all downs, fair frame, then all required terminals")
                    return
                }
                expect(firstFrame.timestamp).to(equal(1))
                expect(fairFrame.timestamp).to(equal(2))
                expect(downs.map(\.kind)).to(
                    equal(Array(repeating: .down, count: sources.count))
                )
                expect(terminals.map(\.kind)).to(
                    equal(Array(repeating: .up, count: sources.count))
                )
                expect(terminals.map(\.pointerID)).to(equal(downs.map(\.pointerID)))

                _ = window
                await host.shutdown()
            }

            it("fails once and flushes when noncoalescible lifecycle input exhausts the budget") { @MainActor in
                let operationResult = FlowRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: true,
                    isSettled: false
                )
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(operationResult),
                ])
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                var deliveredResultCount = 0
                var receivedErrors: [FlowRuntimeDisplayHostError] = []
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    onResult: { _ in deliveredResultCount += 1 },
                    onError: { error in
                        if let error = error as? FlowRuntimeDisplayHostError {
                            receivedErrors.append(error)
                        }
                    }
                )
                try await host.start()
                guard let driver = adapter.contextDrivers.first?.sessionDrivers.first else {
                    fail("expected fake runtime session driver")
                    return
                }
                let sources = (0...FlowRuntimeSessionLimits.pointerEvents).map { _ in
                    NSObject()
                }

                host.displayLinkDidFire(at: 1)
                for source in sources.prefix(FlowRuntimeSessionLimits.pointerEvents) {
                    let pointerSource = FlowRuntimePointerSourceID(source)
                    host.runtimeSurfaceViewDidReceivePointerEvents([
                        FlowRuntimeViewPointerEvent(
                            source: pointerSource,
                            kind: .down,
                            location: .zero
                        ),
                    ])
                    host.runtimeSurfaceViewDidReceivePointerEvents([
                        FlowRuntimeViewPointerEvent(
                            source: pointerSource,
                            kind: .up,
                            location: .zero
                        ),
                    ])
                }
                let overflowSource = FlowRuntimePointerSourceID(
                    sources[FlowRuntimeSessionLimits.pointerEvents]
                )
                host.runtimeSurfaceViewDidReceivePointerEvents([
                    FlowRuntimeViewPointerEvent(
                        source: overflowSource,
                        kind: .down,
                        location: .zero
                    ),
                ])
                host.runtimeSurfaceViewDidReceivePointerEvents([
                    FlowRuntimeViewPointerEvent(
                        source: overflowSource,
                        kind: .up,
                        location: .zero
                    ),
                ])

                let firstOperationCompleted = await waitUntil {
                    deliveredResultCount == 1
                }
                expect(firstOperationCompleted).to(beTrue())
                for _ in 0..<20 { await Task.yield() }
                expect(receivedErrors).to(equal([
                    .pendingPointerInputOverflow(
                        limit: FlowRuntimeSessionLimits.pointerEvents * 2
                    ),
                ]))
                expect(driver.performedOperations.count).to(equal(1))

                _ = window
                await host.shutdown()
            }

            it("delivers successful pointer and frame results once in completion order on MainActor") { @MainActor in
                let pointerResult = FlowRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: true,
                    isSettled: false,
                    diagnostics: [
                        FlowRuntimeDiagnostic(
                            severity: .debug,
                            code: "pointer-result",
                            message: "pointer"
                        ),
                    ]
                )
                let frameResult = FlowRuntimeOperationResult(
                    renderOutcome: .presented,
                    surfaceDisposition: .presented,
                    isDirty: false,
                    isSettled: true,
                    diagnostics: [
                        FlowRuntimeDiagnostic(
                            severity: .debug,
                            code: "frame-result",
                            message: "frame"
                        ),
                    ]
                )
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(pointerResult),
                    .success(frameResult),
                ])
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                var delivered: [FlowRuntimeOperationResult] = []
                var deliveryWasOnMainThread: [Bool] = []
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    onResult: { result in
                        delivered.append(result)
                        deliveryWasOnMainThread.append(Thread.isMainThread)
                    }
                )
                try await host.start()
                let touch = NSObject()

                host.runtimeSurfaceViewDidReceivePointerEvents([
                    FlowRuntimeViewPointerEvent(
                        source: FlowRuntimePointerSourceID(touch),
                        kind: .down,
                        location: CGPoint(x: 10, y: 10)
                    ),
                ])
                host.displayLinkDidFire(at: 1)

                let completed = await waitUntil { delivered.count == 2 }
                expect(completed).to(beTrue())
                for _ in 0..<20 { await Task.yield() }
                expect(delivered).to(equal([pointerResult, frameResult]))
                expect(deliveryWasOnMainThread).to(equal([true, true]))

                _ = window
                await host.shutdown()
            }

            it("detaches and reattaches the surface before draining queued input") { @MainActor in
                let operationResult = FlowRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: true,
                    isSettled: false
                )
                let recorder = FakeFlowRuntimeLifecycleRecorder()
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [
                        .success(operationResult),
                        .success(operationResult),
                        .success(operationResult),
                    ],
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
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    onResult: { _ in }
                )
                try await host.start()
                guard let driver = adapter.contextDrivers.first?.sessionDrivers.first else {
                    fail("expected fake runtime session driver")
                    return
                }
                let touch = NSObject()

                host.displayLinkDidFire(at: 1)
                host.runtimeSurfaceViewDidReceivePointerEvents([
                    FlowRuntimeViewPointerEvent(
                        source: FlowRuntimePointerSourceID(touch),
                        kind: .down,
                        location: CGPoint(x: 32, y: 24)
                    )
                ])
                host.setPresentationVisible(false)

                let detached = await waitUntil {
                    recorder.events.contains(.surfaceDetached)
                }
                expect(detached).to(beTrue())
                expect(driver.performedOperations.count).to(equal(1))

                host.runtimeSurfaceViewDidReceivePointerEvents([
                    FlowRuntimeViewPointerEvent(
                        source: FlowRuntimePointerSourceID(touch),
                        kind: .move,
                        location: CGPoint(x: 40, y: 30)
                    )
                ])

                host.setPresentationVisible(true)
                let inputCompleted = await waitForOperationCount(3, driver: driver)
                expect(inputCompleted).to(beTrue())
                expect(recorder.events).to(contain(.surfaceReattached(
                    FlowRuntimeSurfaceSize(
                        pixelWidth: UInt32(view.bounds.width * window.screen.scale),
                        pixelHeight: UInt32(view.bounds.height * window.screen.scale)
                    )
                )))
                guard case .pointerBatch(let down) = driver.performedOperations[1],
                      case .pointerBatch(let move) = driver.performedOperations[2] else {
                    fail("expected queued input after reattachment")
                    return
                }
                expect(down.map(\.kind)).to(equal([.down]))
                expect(move.map(\.kind)).to(equal([.move]))
                expect(move.map(\.pointerID)).to(equal(down.map(\.pointerID)))

                await host.shutdown()
            }

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
                    usesSystemDisplayLink: false,
                    onResult: { _ in }
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
                    onResult: { _ in },
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

            it("surfaces a failed operation once without delivering a result") { @MainActor in
                let recorder = FakeFlowRuntimeLifecycleRecorder()
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [
                        .failure(FlowRuntimeDisplayHostTestError.failed)
                    ],
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
                var deliveredResultCount = 0
                var receivedErrorCount = 0
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    drawableGate: gate,
                    usesSystemDisplayLink: false,
                    onResult: { _ in deliveredResultCount += 1 },
                    onError: { _ in receivedErrorCount += 1 }
                )
                try await host.start()

                host.displayLinkDidFire(at: 1)
                let didReceiveError = await waitUntil { receivedErrorCount == 1 }
                expect(didReceiveError).to(beTrue())
                host.displayLinkDidFire(at: 2)
                for _ in 0..<20 { await Task.yield() }
                expect(deliveredResultCount).to(equal(0))
                expect(receivedErrorCount).to(equal(1))
                expect(recorder.events).notTo(contain(.surfaceDetached))
                let recoveredPermit = gate.tryAcquire()
                expect(recoveredPermit).notTo(beNil())
                recoveredPermit?.release()

                _ = window
                await host.shutdown()
                expect(recorder.events).to(contain(.surfaceDetached))
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
                    usesSystemDisplayLink: false,
                    onResult: { _ in }
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
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    onResult: { _ in }
                )

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
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    onResult: { _ in }
                )

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
private func makeConfiguredMetalSurface(
    size: CGSize = CGSize(width: 64, height: 48)
) -> (UIWindow, FlowRuntimeSurfaceView)? {
    guard let device = MTLCreateSystemDefaultDevice() else {
        fail("Metal device is required for the display-host test")
        return nil
    }
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
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

private func pointerBootstrap(
    bounds: FlowRuntimeArtboardBounds
) -> FlowRuntimeBootstrap {
    FlowRuntimeBootstrap(
        player: FlowRuntimePlayerMetadata(
            kind: .staticArtboard,
            selection: .staticArtboard,
            index: nil,
            artboardName: nil,
            playerName: nil,
            bounds: bounds
        ),
        catalog: FlowRuntimeCatalog(schemas: [], templates: [], instances: []),
        values: .empty
    )
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
#endif
