import Foundation
import QuartzCore
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class FlowRuntimeHostTests: AsyncSpec {
    override class func spec() {
        describe("FlowRuntimeHost") {
            it("becomes ready only after receiving its first valid operation result") { @MainActor in
                let firstResult = FlowRuntimeOperationResult(
                    renderOutcome: .presented,
                    isDirty: false,
                    isSettled: true
                )
                let adapter = FakeFlowRuntimeAdapter(operationResults: [.success(firstResult)])
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor(artboardName: "Entry")
                )

                expect(session.readiness).to(equal(.waitingForFirstResult))

                let received = try await session.perform(
                    .advanceAndRender(FlowRuntimeFrameTime(timestamp: 1, delta: 0))
                )

                expect(received).to(equal(firstResult))
                expect(session.readiness).to(equal(.ready))
            }

            it("keeps waiting when a valid operation does not present a frame") { @MainActor in
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(
                        FlowRuntimeOperationResult(
                            renderOutcome: .notRequested,
                            isDirty: false,
                            isSettled: true,
                            orderedOutputs: [
                                FlowRuntimeOutput(
                                    sequence: 1,
                                    phase: .runtimeAdvance,
                                    kind: .stateChange
                                )
                            ]
                        )
                    )
                ])
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(descriptor: FlowRenderSessionDescriptor())

                _ = try await session.perform(
                    .advance(FlowRuntimeFrameTime(timestamp: 1, delta: 1.0 / 60.0))
                )

                expect(session.readiness).to(equal(.waitingForFirstResult))
            }

            it("fails the operation for an unrecoverable native surface outcome") { @MainActor in
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(
                        FlowRuntimeOperationResult(
                            renderOutcome: .skipped,
                            surfaceDisposition: .deviceLost,
                            isDirty: false,
                            isSettled: true
                        )
                    )
                ])
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )

                await expect {
                    try await session.perform(
                        .advanceAndRender(FlowRuntimeFrameTime(timestamp: 1, delta: 0))
                    )
                }.to(throwError(FlowRuntimeHostError.unrecoverableSurface(.deviceLost)))
            }

            it("delivers phase-tagged outputs in runtime sequence order") { @MainActor in
                let authoredOutputs = [
                    FlowRuntimeOutput(sequence: 40, phase: .reportedEvents, kind: .reportedEvent),
                    FlowRuntimeOutput(sequence: 41, phase: .runtimeAdvance, kind: .stateChange),
                    FlowRuntimeOutput(sequence: 42, phase: .viewModelChanges, kind: .viewModelChange),
                    FlowRuntimeOutput(sequence: 43, phase: .hostWork, kind: .hostCommand),
                    FlowRuntimeOutput(sequence: 44, phase: .render, kind: .renderRequest),
                ]
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(
                        FlowRuntimeOperationResult(
                            renderOutcome: .presented,
                            isDirty: true,
                            isSettled: false,
                            orderedOutputs: authoredOutputs
                        )
                    )
                ])
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(descriptor: FlowRenderSessionDescriptor())

                let result = try await session.perform(
                    .advance(FlowRuntimeFrameTime(timestamp: 2, delta: 1.0 / 60.0))
                )

                expect(result.orderedOutputs).to(equal(authoredOutputs))
            }

            it("rejects an output sequence regression across operation batches") { @MainActor in
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(
                        FlowRuntimeOperationResult(
                            renderOutcome: .notRequested,
                            isDirty: true,
                            isSettled: false,
                            orderedOutputs: [
                                FlowRuntimeOutput(
                                    sequence: 10,
                                    phase: .render,
                                    kind: .renderRequest
                                )
                            ]
                        )
                    ),
                    .success(
                        FlowRuntimeOperationResult(
                            renderOutcome: .notRequested,
                            isDirty: false,
                            isSettled: true,
                            orderedOutputs: [
                                FlowRuntimeOutput(
                                    sequence: 9,
                                    phase: .delayedEventCallbacks,
                                    kind: .delayedEvent
                                )
                            ]
                        )
                    ),
                ])
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(descriptor: FlowRenderSessionDescriptor())
                let frameTime = FlowRuntimeFrameTime(timestamp: 2, delta: 1.0 / 60.0)

                _ = try await session.perform(.advance(frameTime))

                await expect {
                    try await session.perform(.advance(frameTime))
                }.to(
                    throwError(
                        FlowRuntimeHostError.outputSequenceDidNotIncrease(
                            previous: 10,
                            current: 9
                        )
                    )
                )
            }

            it("allows output phases to restart for each operation batch") { @MainActor in
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(
                        FlowRuntimeOperationResult(
                            renderOutcome: .notRequested,
                            isDirty: true,
                            isSettled: false,
                            orderedOutputs: [
                                FlowRuntimeOutput(
                                    sequence: 20,
                                    phase: .render,
                                    kind: .renderRequest
                                )
                            ]
                        )
                    ),
                    .success(
                        FlowRuntimeOperationResult(
                            renderOutcome: .notRequested,
                            isDirty: false,
                            isSettled: true,
                            orderedOutputs: [
                                FlowRuntimeOutput(
                                    sequence: 21,
                                    phase: .delayedEventCallbacks,
                                    kind: .delayedEvent
                                ),
                                FlowRuntimeOutput(
                                    sequence: 22,
                                    phase: .runtimeAdvance,
                                    kind: .stateChange
                                ),
                            ]
                        )
                    ),
                ])
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(descriptor: FlowRenderSessionDescriptor())
                let frameTime = FlowRuntimeFrameTime(timestamp: 3, delta: 1.0 / 60.0)

                _ = try await session.perform(.advance(frameTime))
                let result = try await session.perform(.advance(frameTime))

                expect(result.orderedOutputs.map(\.phase)).to(
                    equal([.delayedEventCallbacks, .runtimeAdvance])
                )
            }

            it("owns one surface through resize, detach, and reattach") { @MainActor in
                let recorder = FakeFlowRuntimeLifecycleRecorder()
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [],
                    lifecycleRecorder: recorder
                )
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                let initialSize = FlowRuntimeSurfaceSize(pixelWidth: 200, pixelHeight: 120)
                let resized = FlowRuntimeSurfaceSize(pixelWidth: 300, pixelHeight: 180)
                let reattached = FlowRuntimeSurfaceSize(pixelWidth: 400, pixelHeight: 240)
                let firstLayer = CAMetalLayer()
                let secondLayer = CAMetalLayer()

                let surface = try await session.attachAppleSurface(
                    to: FlowRuntimeAppleSurfaceTarget(layer: firstLayer, size: initialSize)
                )

                expect(surface.state).to(equal(.attached))
                expect(surface.attachmentResult.surfaceDisposition).to(equal(.recreated))

                let resizeResult = try await surface.resize(to: resized)
                expect(resizeResult.surfaceDisposition).to(equal(.reconfigured))

                _ = try await surface.detach()
                expect(surface.state).to(equal(.detached))

                await expect {
                    try await surface.resize(to: resized)
                }.to(throwError(FlowRuntimeHostError.surfaceNotAttached))

                _ = try await surface.reattach(
                    to: FlowRuntimeAppleSurfaceTarget(layer: secondLayer, size: reattached)
                )
                expect(surface.state).to(equal(.attached))
                expect(recorder.events).to(equal([
                    .surfaceAttached(initialSize),
                    .surfaceResized(resized),
                    .surfaceDetached,
                    .surfaceReattached(reattached),
                ]))
                guard let configurator = adapter.contextDrivers.first?
                    .sessionDrivers.first?.surfaceConfigurators.first else {
                    fail("expected the fake surface configurator")
                    return
                }
                expect(configurator.configuredSizes).to(equal([
                    initialSize,
                    resized,
                    reattached,
                ]))
                expect(configurator.unconfiguredSizes).to(equal([resized]))
            }

            it("does not let stale teardown unconfigure a replacement layer owner") { @MainActor in
                let layer = CAMetalLayer()
                let target = FlowRuntimeAppleSurfaceTarget(
                    layer: layer,
                    size: FlowRuntimeSurfaceSize(pixelWidth: 40, pixelHeight: 20)
                )
                let staleOwner = FlowRuntimeSurfaceConfigurationOwner()
                let replacementOwner = FlowRuntimeSurfaceConfigurationOwner()
                let staleConfigurator = FakeFlowRuntimeAppleSurfaceConfigurator()
                let replacementConfigurator = FakeFlowRuntimeAppleSurfaceConfigurator()

                staleOwner.configure(target, with: staleConfigurator)
                replacementOwner.configure(target, with: replacementConfigurator)
                staleOwner.unconfigureIfOwned(target, with: staleConfigurator)

                expect(staleConfigurator.unconfiguredSizes).to(beEmpty())
                expect(replacementConfigurator.configuredSizes).to(equal([target.size]))

                replacementOwner.unconfigureIfOwned(target, with: replacementConfigurator)
                expect(replacementConfigurator.unconfiguredSizes).to(equal([target.size]))
            }

            it("holds detach waiters and teardown actions until the final drawable completes") { @MainActor in
                let tracker = FlowRuntimeSurfaceDrawableTracker()
                var detachWaiterResumed = false
                var teardownRan = false

                tracker.beginFrame()
                let detachWaiter = Task { @MainActor in
                    await tracker.waitUntilIdle()
                    detachWaiterResumed = true
                }
                tracker.whenIdle {
                    teardownRan = true
                }

                await Task.yield()
                expect(detachWaiterResumed).to(beFalse())
                expect(teardownRan).to(beFalse())

                tracker.completeFrame()
                await detachWaiter.value

                expect(detachWaiterResumed).to(beTrue())
                expect(teardownRan).to(beTrue())
            }

            it("rejects a second live surface and allows replacement after disposal") { @MainActor in
                let adapter = FakeFlowRuntimeAdapter(operationResults: [])
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                let target = FlowRuntimeAppleSurfaceTarget(
                    layer: CAMetalLayer(),
                    size: FlowRuntimeSurfaceSize(pixelWidth: 20, pixelHeight: 10)
                )
                let first = try await session.attachAppleSurface(to: target)

                await expect {
                    try await session.attachAppleSurface(to: target)
                }.to(throwError(FlowRuntimeHostError.surfaceAlreadyAttached))

                first.dispose()
                let second = try await session.attachAppleSurface(to: target)
                expect(second.state).to(equal(.attached))
            }

            it("disposes surface, session, and context in child-first order") { @MainActor in
                let recorder = FakeFlowRuntimeLifecycleRecorder()
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [],
                    lifecycleRecorder: recorder
                )
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                var context: FlowRuntimeContext? = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                var session: FlowRenderSession? = try await context?.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )
                var surface: FlowRenderSurface? = try await session?.attachAppleSurface(
                    to: FlowRuntimeAppleSurfaceTarget(
                        layer: CAMetalLayer(),
                        size: FlowRuntimeSurfaceSize(pixelWidth: 20, pixelHeight: 10)
                    )
                )

                context = nil
                session?.dispose()
                session = nil
                surface = nil

                expect(surface).to(beNil())
                expect(recorder.events).to(equal([
                    .surfaceAttached(FlowRuntimeSurfaceSize(pixelWidth: 20, pixelHeight: 10)),
                    .surfaceDisposed,
                    .sessionDisposed,
                    .contextDisposed,
                ]))
            }

            it("disposes a retained session before the context it keeps alive") { @MainActor in
                let recorder = FakeFlowRuntimeLifecycleRecorder()
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [],
                    lifecycleRecorder: recorder
                )
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                var context: FlowRuntimeContext? = try await factory.makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                var session: FlowRenderSession? = try await context?.makeSession(
                    descriptor: FlowRenderSessionDescriptor(artboardName: "Entry")
                )
                weak var weakContext = context

                context = nil

                expect(weakContext).notTo(beNil())
                expect(recorder.events).to(beEmpty())

                session = nil

                expect(session).to(beNil())
                expect(weakContext).to(beNil())
                expect(recorder.events).to(equal([.sessionDisposed, .contextDisposed]))
            }
        }
    }
}
