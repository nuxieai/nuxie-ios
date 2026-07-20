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

private enum FlowRuntimeDisplayHostLocalTestError:
    FlowRuntimeSessionFailureDisposition {
    case failed

    var invalidatesSession: Bool { false }
}

private enum FlowRuntimeDisplayHostUnexpectedTestError: Error {
    case failed
}

final class FlowRuntimeDisplayHostTests: AsyncSpec {
    override class func spec() {
        describe("FlowRuntimeDisplayHost lifecycle and input") {
            it("coalesces byte-exact text runs in FIFO order before one zero-delta render") { @MainActor in
                let firstTextResult = FlowRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: true,
                    isSettled: false,
                    diagnostics: [
                        FlowRuntimeDiagnostic(
                            severity: .debug,
                            code: "first-text",
                            message: "first text"
                        ),
                    ]
                )
                let secondTextResult = FlowRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: true,
                    isSettled: false,
                    diagnostics: [
                        FlowRuntimeDiagnostic(
                            severity: .debug,
                            code: "second-text",
                            message: "second text"
                        ),
                    ]
                )
                let renderResult = FlowRuntimeOperationResult(
                    renderOutcome: .presented,
                    surfaceDisposition: .presented,
                    isDirty: false,
                    isSettled: true
                )
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(firstTextResult),
                    .success(secondTextResult),
                    .success(renderResult),
                ])
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                var completions: [FlowRuntimeOperationResult] = []
                var delivered: [FlowRuntimeOperationResult] = []
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    onResult: { delivered.append($0) }
                )
                let composed = "Caf\u{00e9}"
                let decomposed = "Cafe\u{0301}"

                host.setText("old", forRunNamed: composed) { result in
                    if case .success(let value) = result { completions.append(value) }
                }
                host.setText("latest", forRunNamed: composed) { result in
                    if case .success(let value) = result { completions.append(value) }
                }
                host.setText("distinct", forRunNamed: decomposed) { result in
                    if case .success(let value) = result { completions.append(value) }
                }
                try await host.start()
                guard let driver = adapter.contextDrivers.first?.sessionDrivers.first else {
                    fail("expected fake runtime session driver")
                    return
                }

                let completed = await waitForOperationCount(3, driver: driver)
                expect(completed).to(beTrue())
                guard driver.performedOperations.count == 3,
                      case .textRunBatch(let first) = driver.performedOperations[0],
                      case .textRunBatch(let second) = driver.performedOperations[1],
                      case .advanceAndRender(let renderTime) = driver.performedOperations[2]
                else {
                    fail("expected two attributed text writes followed by one render")
                    return
                }
                expect(first.mutations.map(\.text)).to(equal(["latest"]))
                expect(first.mutations.first.map { Array($0.name.utf8) }).to(
                    equal(Array(composed.utf8))
                )
                expect(second.mutations.map(\.text)).to(equal(["distinct"]))
                expect(second.mutations.first.map { Array($0.name.utf8) }).to(
                    equal(Array(decomposed.utf8))
                )
                expect(renderTime.delta).to(equal(0))
                expect(completions).to(equal([
                    firstTextResult,
                    firstTextResult,
                    secondTextResult,
                ]))
                expect(delivered).to(equal([
                    firstTextResult,
                    secondTextResult,
                    renderResult,
                ]))

                _ = window
                await host.shutdown()
            }

            it("delivers projected results through the one-argument result sink") { @MainActor in
                let original = FlowRuntimeOperationResult(
                    renderOutcome: .presented,
                    surfaceDisposition: .presented,
                    isDirty: true,
                    isSettled: false,
                    diagnostics: [
                        FlowRuntimeDiagnostic(
                            severity: .debug,
                            code: "original",
                            message: "original"
                        ),
                    ]
                )
                let projected = FlowRuntimeOperationResult(
                    renderOutcome: .presented,
                    surfaceDisposition: .presented,
                    isDirty: false,
                    isSettled: true,
                    diagnostics: [
                        FlowRuntimeDiagnostic(
                            severity: .debug,
                            code: "projected",
                            message: "projected"
                        ),
                    ]
                )
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(original),
                ])
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                var delivered: [FlowRuntimeOperationResult] = []
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    resultProjector: { _ in projected },
                    onResult: { delivered.append($0) }
                )

                try await host.start()
                guard let driver = adapter.contextDrivers.first?.sessionDrivers.first else {
                    fail("expected fake runtime session driver")
                    return
                }
                host.displayLinkDidFire(at: 1)
                let completed = await waitForOperationCount(1, driver: driver)
                expect(completed).to(beTrue())
                expect(delivered).to(equal([projected]))

                _ = window
                await host.shutdown()
            }

            it("keeps a failed text run control-local and continues before pointer and frame work") { @MainActor in
                let textResult = FlowRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: true,
                    isSettled: false
                )
                let renderResult = FlowRuntimeOperationResult(
                    renderOutcome: .presented,
                    surfaceDisposition: .presented,
                    isDirty: false,
                    isSettled: true
                )
                let pointerResult = FlowRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: true,
                    isSettled: false
                )
                let frameResult = FlowRuntimeOperationResult(
                    renderOutcome: .presented,
                    surfaceDisposition: .presented,
                    isDirty: false,
                    isSettled: true
                )
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .failure(FlowRuntimeDisplayHostLocalTestError.failed),
                    .success(textResult),
                    .success(renderResult),
                    .success(pointerResult),
                    .success(frameResult),
                ])
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                var missingFailed = false
                var existingSucceeded = false
                var terminalErrors = 0
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    onResult: { _ in },
                    onError: { _ in terminalErrors += 1 }
                )
                host.setText("missing", forRunNamed: "Missing") { result in
                    if case .failure = result { missingFailed = true }
                }
                host.setText("ready", forRunNamed: "Existing") { result in
                    if case .success = result { existingSucceeded = true }
                }
                try await host.start()
                guard let driver = adapter.contextDrivers.first?.sessionDrivers.first else {
                    fail("expected fake runtime session driver")
                    return
                }
                let touch = NSObject()
                host.runtimeSurfaceViewDidReceivePointerEvents([
                    FlowRuntimeViewPointerEvent(
                        source: FlowRuntimePointerSourceID(touch),
                        kind: .down,
                        location: CGPoint(x: 1, y: 1)
                    ),
                ])
                host.displayLinkDidFire(at: 1)

                let textAndPointerCompleted = await waitForOperationCount(4, driver: driver)
                expect(textAndPointerCompleted).to(beTrue())
                host.displayLinkDidFire(at: 2)
                let completed = await waitForOperationCount(5, driver: driver)
                expect(completed).to(beTrue())
                expect(missingFailed).to(beTrue())
                expect(existingSucceeded).to(beTrue())
                expect(terminalErrors).to(equal(0))
                guard driver.performedOperations.count == 5,
                      case .textRunBatch = driver.performedOperations[0],
                      case .textRunBatch = driver.performedOperations[1],
                      case .advanceAndRender(let textRender) = driver.performedOperations[2],
                      case .pointerBatch = driver.performedOperations[3],
                      case .advanceAndRender(let displayFrame) = driver.performedOperations[4]
                else {
                    fail("expected text writes and their render before pointer and frame work")
                    return
                }
                expect(textRender.delta).to(equal(0))
                expect(textRender.timestamp).to(equal(1))
                expect(displayFrame.timestamp).to(equal(2))
                expect(displayFrame.delta).to(equal(1))

                _ = window
                await host.shutdown()
            }

            it("poisons the lane only when a text failure proves the session terminal") { @MainActor in
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .failure(FlowRuntimeDisplayHostUnexpectedTestError.failed),
                ])
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                var completionFailures = 0
                var terminalFailures = 0
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    onResult: { _ in },
                    onError: { _ in terminalFailures += 1 }
                )
                for name in ["First", "Second"] {
                    host.setText("value", forRunNamed: name) { result in
                        if case .failure = result { completionFailures += 1 }
                    }
                }

                try await host.start()
                guard let driver = adapter.contextDrivers.first?.sessionDrivers.first else {
                    fail("expected fake runtime session driver")
                    return
                }
                let failed = await waitUntil {
                    completionFailures == 2 && terminalFailures == 1
                }
                expect(failed).to(beTrue())
                expect(driver.performedOperations).to(haveCount(1))

                host.setText("value", forRunNamed: "Third") { result in
                    if case .failure = result { completionFailures += 1 }
                }
                expect(completionFailures).to(equal(3))
                expect(driver.performedOperations).to(haveCount(1))

                _ = window
                await host.shutdown()
            }

            it("notifies the terminal owner before flushing unprepared queued completions") { @MainActor in
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .failure(FlowRuntimeDisplayHostUnexpectedTestError.failed),
                ])
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                var events: [String] = []
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    onResult: { _ in },
                    onError: { _ in events.append("terminal") }
                )
                host.performStateBatch(
                    prepare: {
                        events.append("first prepared")
                        return FlowRuntimeStateBatch(mutations: [])
                    },
                    completion: { result in
                        if case .failure = result { events.append("first completion") }
                    }
                )
                host.performStateBatch(
                    prepare: {
                        events.append("second prepared")
                        return FlowRuntimeStateBatch(mutations: [])
                    },
                    completion: { result in
                        if case .failure = result { events.append("second completion") }
                    }
                )

                try await host.start()
                let completed = await waitUntil { events.count == 4 }
                expect(completed).to(beTrue())
                expect(events).to(equal([
                    "first prepared",
                    "first completion",
                    "terminal",
                    "second completion",
                ]))

                _ = window
                await host.shutdown()
            }

            it("reports a terminal deferred state-preparation failure before draining the queue") { @MainActor in
                let adapter = FakeFlowRuntimeAdapter(operationResults: [])
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                var events: [String] = []
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    onResult: { _ in },
                    onError: { _ in events.append("terminal") }
                )
                host.performStateBatch(
                    prepare: {
                        events.append("first prepared")
                        throw FlowRuntimeDisplayHostUnexpectedTestError.failed
                    },
                    completion: { result in
                        if case .failure = result { events.append("first completion") }
                    }
                )
                host.performStateBatch(
                    prepare: {
                        events.append("second prepared")
                        return FlowRuntimeStateBatch(mutations: [])
                    },
                    completion: { result in
                        if case .failure = result { events.append("second completion") }
                    }
                )

                try await host.start()
                let completed = await waitUntil { events.count == 4 }
                expect(completed).to(beTrue())
                expect(events).to(equal([
                    "first prepared",
                    "first completion",
                    "terminal",
                    "second completion",
                ]))
                expect(
                    adapter.contextDrivers.first?.sessionDrivers.first?.performedOperations
                ).to(beEmpty())

                _ = window
                await host.shutdown()
            }

            it("continues after an explicitly local deferred state-preparation failure") { @MainActor in
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(FlowRuntimeOperationResult(
                        renderOutcome: .notRequested,
                        isDirty: false,
                        isSettled: true
                    )),
                ])
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                var events: [String] = []
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    onResult: { _, _, source in events.append("result:\(source)") },
                    onError: { _ in events.append("terminal") }
                )
                host.performStateBatch(
                    prepare: {
                        events.append("first prepared")
                        throw FlowRuntimeDisplayHostLocalTestError.failed
                    },
                    completion: { result in
                        if case .failure = result { events.append("first completion") }
                    }
                )
                host.performStateBatch(
                    prepare: {
                        events.append("second prepared")
                        return FlowRuntimeStateBatch(mutations: [])
                    },
                    completion: { result in
                        if case .success = result { events.append("second completion") }
                    }
                )

                try await host.start()
                let completed = await waitUntil { events.count == 5 }
                expect(completed).to(beTrue())
                expect(events).to(equal([
                    "first prepared",
                    "first completion",
                    "second prepared",
                    "result:stateBatch",
                    "second completion",
                ]))
                expect(
                    adapter.contextDrivers.first?.sessionDrivers.first?.performedOperations
                ).to(haveCount(1))

                _ = window
                await host.shutdown()
            }

            it("defers FIFO state preparation until earlier runtime results are delivered") { @MainActor in
                let frameResult = FlowRuntimeOperationResult(
                    renderOutcome: .presented,
                    surfaceDisposition: .presented,
                    isDirty: false,
                    isSettled: true,
                    diagnostics: [
                        FlowRuntimeDiagnostic(
                            severity: .debug,
                            code: "frame",
                            message: "frame"
                        ),
                    ]
                )
                let stateResult = FlowRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: true,
                    isSettled: false,
                    diagnostics: [
                        FlowRuntimeDiagnostic(
                            severity: .debug,
                            code: "state",
                            message: "state"
                        ),
                    ]
                )
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(frameResult),
                    .success(stateResult),
                ])
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                var events: [String] = []
                var prepared = false
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    resultProjector: { result in
                        events.append(
                            "project:\(result.diagnostics.first?.code ?? "result")"
                        )
                        return result
                    },
                    onResult: { result, projected, source in
                        expect(projected).to(equal(result))
                        events.append(
                            "\(source):\(result.diagnostics.first?.code ?? "result")"
                        )
                    }
                )
                try await host.start()
                guard let driver = adapter.contextDrivers.first?.sessionDrivers.first else {
                    fail("expected fake runtime session driver")
                    return
                }

                host.displayLinkDidFire(at: 1)
                host.performStateBatch(
                    prepare: {
                        prepared = true
                        events.append("prepare")
                        return FlowRuntimeStateBatch(mutations: [
                            .setInputBool(name: "enabled", value: true),
                        ])
                    },
                    completion: { result in
                        if case .success = result { events.append("completion") }
                    }
                )
                expect(prepared).to(beFalse())

                let completed = await waitForOperationCount(2, driver: driver)
                expect(completed).to(beTrue())
                expect(events).to(equal([
                    "project:frame",
                    "frame:frame",
                    "prepare",
                    "project:state",
                    "stateBatch:state",
                    "completion",
                ]))
                guard driver.performedOperations.count == 2,
                      case .advanceAndRender = driver.performedOperations[0],
                      case .stateBatch = driver.performedOperations[1] else {
                    fail("expected the selected frame before deferred state work")
                    return
                }

                _ = window
                await host.shutdown()
            }

            it("runs state and text work while detached but waits to render until reattached") { @MainActor in
                let mutationResult = FlowRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: true,
                    isSettled: false
                )
                let renderResult = FlowRuntimeOperationResult(
                    renderOutcome: .presented,
                    surfaceDisposition: .presented,
                    isDirty: false,
                    isSettled: true
                )
                let recorder = FakeFlowRuntimeLifecycleRecorder()
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [
                        .success(mutationResult),
                        .success(mutationResult),
                        .success(renderResult),
                    ],
                    lifecycleRecorder: recorder
                )
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
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

                host.setPresentationVisible(false)
                let detached = await waitUntil { recorder.events.contains(.surfaceDetached) }
                expect(detached).to(beTrue())
                host.performStateBatch(prepare: {
                    FlowRuntimeStateBatch(mutations: [
                        .setInputBool(name: "enabled", value: true),
                    ])
                })
                host.setText("ready", forRunNamed: "Headline")

                let mutated = await waitForOperationCount(2, driver: driver)
                expect(mutated).to(beTrue())
                for _ in 0..<20 { await Task.yield() }
                expect(driver.performedOperations.count).to(equal(2))
                guard case .stateBatch = driver.performedOperations[0],
                      case .textRunBatch = driver.performedOperations[1] else {
                    fail("expected detached state work before detached text work")
                    return
                }

                host.setPresentationVisible(true)
                let rendered = await waitForOperationCount(3, driver: driver)
                expect(rendered).to(beTrue())
                expect(recorder.events).to(contain(.surfaceReattached(
                    FlowRuntimeSurfaceSize(
                        pixelWidth: UInt32(view.bounds.width * window.screen.scale),
                        pixelHeight: UInt32(view.bounds.height * window.screen.scale)
                    )
                )))
                guard case .advanceAndRender(let frame) = driver.performedOperations[2] else {
                    fail("expected deferred text render after reattachment")
                    return
                }
                expect(frame.delta).to(equal(0))

                await host.shutdown()
            }

            it("bounds total queued host work including coalesced text completions") { @MainActor in
                let adapter = FakeFlowRuntimeAdapter(operationResults: [])
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                let view = FlowRuntimeSurfaceView(frame: .zero)
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    onResult: { _ in }
                )
                for index in 0..<FlowRuntimeSessionLimits.batchItems {
                    host.setText("\(index)", forRunNamed: "Headline")
                }
                var overflow: FlowRuntimeDisplayHostError?

                host.performStateBatch(
                    prepare: { FlowRuntimeStateBatch(mutations: []) },
                    completion: { result in
                        guard case .failure(let error) = result else { return }
                        overflow = error as? FlowRuntimeDisplayHostError
                    }
                )

                expect(overflow).to(equal(.pendingHostWorkOverflow(
                    limit: FlowRuntimeSessionLimits.batchItems
                )))
                if let overflow {
                    expect(flowRuntimeOperationFailureInvalidatesSession(overflow)).to(beFalse())
                }
                expect(
                    adapter.contextDrivers.first?.sessionDrivers.first?.performedOperations ?? []
                ).to(beEmpty())
                await host.shutdown()
            }

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

            it("drops saturated lifecycle input without poisoning later frames") { @MainActor in
                let operationResult = FlowRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: true,
                    isSettled: false
                )
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(operationResult),
                    .success(operationResult),
                    .success(operationResult),
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
                var terminalErrorCount = 0
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    onResult: { _ in deliveredResultCount += 1 },
                    onError: { _ in terminalErrorCount += 1 }
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
                let admittedSources = sources.prefix(FlowRuntimeSessionLimits.pointerEvents)
                host.runtimeSurfaceViewDidReceivePointerEvents(
                    admittedSources.map { source in
                        FlowRuntimeViewPointerEvent(
                            source: FlowRuntimePointerSourceID(source),
                            kind: .down,
                            location: .zero
                        )
                    } + admittedSources.map { source in
                        FlowRuntimeViewPointerEvent(
                            source: FlowRuntimePointerSourceID(source),
                            kind: .up,
                            location: .zero
                        )
                    }
                )
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

                let admittedInputCompleted = await waitForOperationCount(3, driver: driver)
                expect(admittedInputCompleted).to(beTrue())
                for _ in 0..<20 { await Task.yield() }
                guard driver.performedOperations.count == 3 else {
                    fail("unexpected pre-recovery operations: \(driver.performedOperations)")
                    return
                }
                expect(deliveredResultCount).to(equal(3))
                expect(terminalErrorCount).to(equal(0))
                let overflow = FlowRuntimeDisplayHostError.pendingPointerInputOverflow(
                    limit: FlowRuntimeSessionLimits.pointerEvents * 2
                )
                expect(flowRuntimeOperationFailureInvalidatesSession(overflow)).to(beFalse())

                host.displayLinkDidFire(at: 2)
                let recovered = await waitForOperationCount(4, driver: driver)
                expect(recovered).to(beTrue())
                expect(driver.performedOperations).to(haveCount(4))
                guard case .advanceAndRender = driver.performedOperations[0],
                      case .pointerBatch = driver.performedOperations[1],
                      case .pointerBatch = driver.performedOperations[2],
                      case .advanceAndRender = driver.performedOperations[3] else {
                    fail("expected admitted input and later display work to survive overflow")
                    return
                }

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
                        .failure(FlowRuntimeDisplayHostUnexpectedTestError.failed)
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

            it("fails startup and resolves queued work when its weak surface view disappears") { @MainActor in
                let adapter = FakeFlowRuntimeAdapter(operationResults: [])
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                var surfaceView: FlowRuntimeSurfaceView? = FlowRuntimeSurfaceView(frame: .zero)
                weak let releasedSurfaceView = surfaceView
                var reportedError: Error?
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: surfaceView!,
                    usesSystemDisplayLink: false,
                    onResult: { _ in },
                    onError: { reportedError = $0 }
                )
                var completionError: Error?
                host.performStateBatch(
                    prepare: { FlowRuntimeStateBatch(mutations: []) },
                    completion: { result in
                        guard case .failure(let error) = result else { return }
                        completionError = error
                    }
                )
                surfaceView = nil
                expect(releasedSurfaceView).to(beNil())

                var startError: Error?
                do {
                    try await host.start()
                } catch {
                    startError = error
                }

                expect(startError as? FlowRuntimeHostError).to(equal(.disposedSurface))
                expect(reportedError as? FlowRuntimeHostError).to(equal(.disposedSurface))
                expect(completionError as? FlowRuntimeHostError).to(equal(.disposedSurface))
            }

            it("reports an attachment failure and resolves every queued host request") { @MainActor in
                let adapter = FakeFlowRuntimeAdapter(operationResults: [])
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                guard let (window, view) = makeConfiguredMetalSurface() else { return }
                session.dispose()
                var reportedError: Error?
                var completionErrors: [Error] = []
                let host = FlowRuntimeDisplayHost(
                    session: session,
                    surfaceView: view,
                    usesSystemDisplayLink: false,
                    onResult: { _ in },
                    onError: { reportedError = $0 }
                )
                host.performStateBatch(
                    prepare: { FlowRuntimeStateBatch(mutations: []) },
                    completion: { result in
                        guard case .failure(let error) = result else { return }
                        completionErrors.append(error)
                    }
                )
                host.setText("ready", forRunNamed: "Headline") { result in
                    guard case .failure(let error) = result else { return }
                    completionErrors.append(error)
                }

                var startError: Error?
                do {
                    try await host.start()
                } catch {
                    startError = error
                }

                expect(startError as? FlowRuntimeHostError).to(equal(.disposedSession))
                expect(reportedError as? FlowRuntimeHostError).to(equal(.disposedSession))
                expect(completionErrors.compactMap { $0 as? FlowRuntimeHostError }).to(
                    equal([.disposedSession, .disposedSession])
                )
                _ = window
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
