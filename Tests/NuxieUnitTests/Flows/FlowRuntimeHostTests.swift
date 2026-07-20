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
            it("preserves the complete import request and Rust authorization result") { @MainActor in
                let authorization = FlowRuntimeAuthorizationEvidence(
                    signedContentBytes: Data("manifest".utf8),
                    signatureEnvelopeBytes: Data("signature".utf8),
                    selectedKey: FlowRuntimeAuthorizationKey(
                        keyId: "staging-2026-01",
                        ed25519PublicKeyBytes: Data(repeating: 0x2a, count: 32)
                    )
                )
                let request = FlowRuntimeImportRequest(
                    artifactBytes: Data([0x52, 0x49, 0x56]),
                    expectedIdentity: FlowRuntimeArtifactIdentity(
                        flowId: "flow-1",
                        buildId: "build-1"
                    ),
                    authorizationEvidence: authorization,
                    externalAssets: [
                        FlowRuntimeExternalAsset(
                            kind: .image,
                            riveAssetId: 7,
                            riveUniqueName: "hero-7",
                            sourceKey: "hero",
                            expectedSHA256: String(repeating: "a", count: 64),
                            required: true,
                            content: .bytes(Data([1, 2, 3]))
                        )
                    ]
                )
                let importResult = FlowRuntimeImportResult(
                    scriptAuthorization: .authorized(keyId: "staging-2026-01"),
                    diagnostics: [
                        FlowRuntimeDiagnostic(
                            severity: .debug,
                            code: "nux_runtime.import.authorized",
                            message: "artifact signature verified"
                        )
                    ]
                )
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [],
                    importResult: importResult
                )

                let context = try await FlowRuntimeContextFactory(adapter: adapter)
                    .makeContext(for: request)

                expect(adapter.importRequests).to(equal([request]))
                expect(context.importResult).to(equal(importResult))
            }

            it("keeps ordinary unsigned visual imports usable") { @MainActor in
                let request = FlowRuntimeImportRequest(
                    artifactBytes: Data([0x52, 0x49, 0x56]),
                    expectedIdentity: FlowRuntimeArtifactIdentity(
                        flowId: "visual-flow",
                        buildId: "visual-build"
                    ),
                    authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                        signedContentBytes: Data(
                            "{\"flowId\":\"visual-flow\",\"buildId\":\"visual-build\"}".utf8
                        ),
                        signatureEnvelopeBytes: nil,
                        selectedKey: nil
                    )
                )
                let adapter = FakeFlowRuntimeAdapter(operationResults: [])

                let context = try await FlowRuntimeContextFactory(adapter: adapter)
                    .makeContext(for: request)

                expect(adapter.importRequests).to(equal([request]))
                expect(context.importResult).to(equal(.visualOnly))
            }

            it("rejects authenticated outcomes without selected trust evidence") { @MainActor in
                let lifecycle = FakeFlowRuntimeLifecycleRecorder()
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [],
                    importResult: FlowRuntimeImportResult(
                        scriptAuthorization: .authorized(keyId: "unbound-key"),
                        diagnostics: []
                    ),
                    lifecycleRecorder: lifecycle
                )

                await expect {
                    try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                        for: FlowRuntimeImportRequest(
                            artifactBytes: Data([0x52, 0x49, 0x56])
                        )
                    )
                }.to(
                    throwError(
                        FlowRuntimeHostError.authenticatedImportMissingEvidence(
                            reportedKeyId: "unbound-key"
                        )
                    )
                )
                expect(lifecycle.events).to(equal([.contextDisposed]))
            }

            it("validates outcomes against evidence after native normalization") { @MainActor in
                let lifecycle = FakeFlowRuntimeLifecycleRecorder()
                let oversizedSignature = Data(
                    repeating: 0x2a,
                    count: FlowRuntimeImportLimits.signatureEnvelopeBytes + 1
                )
                let request = FlowRuntimeImportRequest(
                    artifactBytes: Data([0x52, 0x49, 0x56]),
                    expectedIdentity: FlowRuntimeArtifactIdentity(
                        flowId: "flow-1",
                        buildId: "build-1"
                    ),
                    authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                        signedContentBytes: Data("manifest".utf8),
                        signatureEnvelopeBytes: oversizedSignature,
                        selectedKey: FlowRuntimeAuthorizationKey(
                            keyId: "selected-key",
                            ed25519PublicKeyBytes: Data(repeating: 0x2a, count: 32)
                        )
                    )
                )
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [],
                    importResult: FlowRuntimeImportResult(
                        scriptAuthorization: .authorized(keyId: "selected-key"),
                        diagnostics: []
                    ),
                    lifecycleRecorder: lifecycle
                )

                await expect {
                    try await FlowRuntimeContextFactory(adapter: adapter)
                        .makeContext(for: request)
                }.to(
                    throwError(
                        FlowRuntimeHostError.authenticatedImportMissingEvidence(
                            reportedKeyId: "selected-key"
                        )
                    )
                )
                expect(adapter.importRequests.first?.authorizationEvidence).to(
                    equal(
                        FlowRuntimeAuthorizationEvidence(
                            signedContentBytes: Data("manifest".utf8),
                            signatureEnvelopeBytes: Data(),
                            selectedKey: nil
                        )
                    )
                )
                expect(lifecycle.events).to(equal([.contextDisposed]))
            }

            it("rejects authenticated outcomes for a different selected key") { @MainActor in
                let lifecycle = FakeFlowRuntimeLifecycleRecorder()
                let request = FlowRuntimeImportRequest(
                    artifactBytes: Data([0x52, 0x49, 0x56]),
                    authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                        signedContentBytes: Data("manifest".utf8),
                        signatureEnvelopeBytes: Data("signature".utf8),
                        selectedKey: FlowRuntimeAuthorizationKey(
                            keyId: "selected-key",
                            ed25519PublicKeyBytes: Data(repeating: 0x2a, count: 32)
                        )
                    )
                )
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [],
                    importResult: FlowRuntimeImportResult(
                        scriptAuthorization: .authorized(keyId: "different-key"),
                        diagnostics: []
                    ),
                    lifecycleRecorder: lifecycle
                )

                await expect {
                    try await FlowRuntimeContextFactory(adapter: adapter)
                        .makeContext(for: request)
                }.to(
                    throwError(
                        FlowRuntimeHostError.authenticatedImportKeyMismatch(
                            selectedKeyId: "selected-key",
                            reportedKeyId: "different-key"
                        )
                    )
                )
                expect(lifecycle.events).to(equal([.contextDisposed]))
            }

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

            it("retains creation outputs and seeds cross-operation sequence validation") { @MainActor in
                let creationOutput = FlowRuntimeOutput(
                    sequence: 10,
                    cycle: 0,
                    phase: .hostWork,
                    payload: .hostCommand(name: "created", payload: .object(.empty))
                )
                let creationResult = FlowRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: true,
                    isSettled: false,
                    orderedOutputs: [creationOutput],
                    bootstrap: .fake
                )
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [
                        .success(FlowRuntimeOperationResult(
                            renderOutcome: .notRequested,
                            isDirty: false,
                            isSettled: true,
                            orderedOutputs: [
                                FlowRuntimeOutput(
                                    sequence: 10,
                                    cycle: 1,
                                    phase: .hostWork,
                                    payload: .hostCommand(
                                        name: "duplicate",
                                        payload: .object(.empty)
                                    )
                                ),
                            ]
                        )),
                    ],
                    creationResult: creationResult
                )
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor()
                )

                expect(session.creationResult).to(equal(creationResult))
                expect(session.bootstrap).to(equal(.fake))
                await expect {
                    try await session.perform(
                        .advance(FlowRuntimeFrameTime(timestamp: 1, delta: 0))
                    )
                }.to(
                    throwError(
                        FlowRuntimeHostError.outputSequenceDidNotIncrease(
                            previous: 10,
                            current: 10
                        )
                    )
                )
            }

            it("rejects and disposes a session whose creation result omits bootstrap") { @MainActor in
                let lifecycle = FakeFlowRuntimeLifecycleRecorder()
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [],
                    creationResult: FlowRuntimeOperationResult(
                        renderOutcome: .notRequested,
                        isDirty: false,
                        isSettled: true
                    ),
                    lifecycleRecorder: lifecycle
                )
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )

                await expect {
                    try await context.makeSession(descriptor: FlowRenderSessionDescriptor())
                }.to(throwError(FlowRuntimeHostError.sessionCreationMissingBootstrap))
                expect(lifecycle.events).to(equal([.sessionDisposed]))
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

            it("allows output phases to restart only when the runtime cycle advances") { @MainActor in
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(
                        FlowRuntimeOperationResult(
                            renderOutcome: .notRequested,
                            isDirty: true,
                            isSettled: false,
                            orderedOutputs: [
                                FlowRuntimeOutput(
                                    sequence: 20,
                                    cycle: 4,
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
                                    cycle: 5,
                                    phase: .delayedEventCallbacks,
                                    kind: .delayedEvent
                                ),
                                FlowRuntimeOutput(
                                    sequence: 22,
                                    cycle: 5,
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

            it("allows a phase restart within one result when its cycle advances") { @MainActor in
                let outputs = [
                    FlowRuntimeOutput(
                        sequence: 30,
                        cycle: 8,
                        phase: .render,
                        kind: .renderRequest
                    ),
                    FlowRuntimeOutput(
                        sequence: 31,
                        cycle: 9,
                        phase: .delayedEventCallbacks,
                        kind: .delayedEvent
                    ),
                ]
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(
                        FlowRuntimeOperationResult(
                            renderOutcome: .notRequested,
                            isDirty: true,
                            isSettled: false,
                            orderedOutputs: outputs
                        )
                    ),
                ])
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(descriptor: FlowRenderSessionDescriptor())

                let result = try await session.perform(
                    .advance(FlowRuntimeFrameTime(timestamp: 4, delta: 1.0 / 60.0))
                )

                expect(result.orderedOutputs).to(equal(outputs))
            }

            it("rejects an output cycle regression across operation batches") { @MainActor in
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(
                        FlowRuntimeOperationResult(
                            renderOutcome: .notRequested,
                            isDirty: true,
                            isSettled: false,
                            orderedOutputs: [
                                FlowRuntimeOutput(
                                    sequence: 40,
                                    cycle: 12,
                                    phase: .runtimeAdvance,
                                    kind: .runtimeAdvanced
                                ),
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
                                    sequence: 41,
                                    cycle: 11,
                                    phase: .render,
                                    kind: .renderRequest
                                ),
                            ]
                        )
                    ),
                ])
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(descriptor: FlowRenderSessionDescriptor())
                let frameTime = FlowRuntimeFrameTime(timestamp: 5, delta: 1.0 / 60.0)

                _ = try await session.perform(.advance(frameTime))

                await expect {
                    try await session.perform(.advance(frameTime))
                }.to(
                    throwError(
                        FlowRuntimeHostError.outputCycleRegressed(
                            previous: 12,
                            current: 11
                        )
                    )
                )
            }

            it("rejects a phase regression when an operation continues the same cycle") { @MainActor in
                let adapter = FakeFlowRuntimeAdapter(operationResults: [
                    .success(
                        FlowRuntimeOperationResult(
                            renderOutcome: .notRequested,
                            isDirty: true,
                            isSettled: false,
                            orderedOutputs: [
                                FlowRuntimeOutput(
                                    sequence: 50,
                                    cycle: 14,
                                    phase: .render,
                                    kind: .renderRequest
                                ),
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
                                    sequence: 51,
                                    cycle: 14,
                                    phase: .reportedEvents,
                                    kind: .reportedEvent
                                ),
                            ]
                        )
                    ),
                ])
                let context = try await FlowRuntimeContextFactory(adapter: adapter).makeContext(
                    for: FlowRuntimeImportRequest(artifactBytes: Data([0x52, 0x49, 0x56]))
                )
                let session = try await context.makeSession(descriptor: FlowRenderSessionDescriptor())
                let frameTime = FlowRuntimeFrameTime(timestamp: 6, delta: 1.0 / 60.0)

                _ = try await session.perform(.advance(frameTime))

                await expect {
                    try await session.perform(.advance(frameTime))
                }.to(
                    throwError(
                        FlowRuntimeHostError.outputPhaseRegressed(
                            previous: .render,
                            current: .reportedEvents
                        )
                    )
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

            #if canImport(UIKit)
            it("releases registered fonts with their runtime context") { @MainActor in
                let data = try Self.fontFixtureData()
                let uniqueName = "context-font-\(UUID().uuidString)"
                let contentSHA256 = FlowArtifactStore.sha256Hex(data)
                let request = FlowRuntimeImportRequest(
                    artifactBytes: Data([0x52, 0x49, 0x56]),
                    externalAssets: [
                        FlowRuntimeExternalAsset(
                            kind: .font,
                            riveAssetId: 7,
                            riveUniqueName: uniqueName,
                            sourceKey: "font-request",
                            expectedSHA256: contentSHA256,
                            required: true,
                            content: .bytes(data)
                        )
                    ]
                )
                var context: FlowRuntimeContext? = try await FlowRuntimeContextFactory(
                    adapter: FakeFlowRuntimeAdapter(operationResults: [])
                ).makeContext(for: request)

                expect(
                    FlowRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: contentSHA256,
                        size: 16
                    )
                ).notTo(beNil())

                context = nil

                expect(context).to(beNil())
                expect(
                    FlowRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: contentSHA256,
                        size: 16
                    )
                ).to(beNil())
            }

            it("releases earlier fonts when context font setup fails") { @MainActor in
                let data = try Self.fontFixtureData()
                let validName = "valid-context-font-\(UUID().uuidString)"
                let invalidName = "invalid-context-font-\(UUID().uuidString)"
                let contentSHA256 = FlowArtifactStore.sha256Hex(data)
                let recorder = FakeFlowRuntimeLifecycleRecorder()
                let adapter = FakeFlowRuntimeAdapter(
                    operationResults: [],
                    lifecycleRecorder: recorder
                )
                let request = FlowRuntimeImportRequest(
                    artifactBytes: Data([0x52, 0x49, 0x56]),
                    externalAssets: [
                        FlowRuntimeExternalAsset(
                            kind: .font,
                            riveAssetId: 7,
                            riveUniqueName: validName,
                            sourceKey: "valid-font-request",
                            expectedSHA256: contentSHA256,
                            required: true,
                            content: .bytes(data)
                        ),
                        FlowRuntimeExternalAsset(
                            kind: .font,
                            riveAssetId: 8,
                            riveUniqueName: invalidName,
                            sourceKey: "invalid-font-request",
                            expectedSHA256: String(repeating: "0", count: 64),
                            required: true,
                            content: .bytes(Data([0x00, 0x01]))
                        ),
                    ]
                )

                await expect {
                    try await FlowRuntimeContextFactory(adapter: adapter)
                        .makeContext(for: request)
                }.to(
                    throwError(
                        FlowRuntimeHostError.requiredFontRegistrationFailed(invalidName)
                    )
                )
                expect(adapter.importRequests).to(beEmpty())
                expect(adapter.contextDrivers).to(beEmpty())
                expect(recorder.events).to(beEmpty())
                expect(
                    FlowRuntimeFontRegistry.font(
                        forRiveUniqueName: validName,
                        contentSHA256: contentSHA256,
                        size: 16
                    )
                ).to(beNil())
            }

            it("omits an optional font from native import when registration fails") { @MainActor in
                let uniqueName = "omitted-context-font-\(UUID().uuidString)"
                let invalidData = Data([0x00, 0x01])
                let contentSHA256 = FlowArtifactStore.sha256Hex(invalidData)
                let asset = FlowRuntimeExternalAsset(
                    kind: .font,
                    riveAssetId: 7,
                    riveUniqueName: uniqueName,
                    sourceKey: "omitted-font-request",
                    expectedSHA256: contentSHA256,
                    required: false,
                    content: .bytes(invalidData)
                )
                let request = FlowRuntimeImportRequest(
                    artifactBytes: Data([0x52, 0x49, 0x56]),
                    externalAssets: [asset]
                )
                let adapter = FakeFlowRuntimeAdapter(operationResults: [])

                var context: FlowRuntimeContext? = try await FlowRuntimeContextFactory(
                    adapter: adapter
                ).makeContext(for: request)

                expect(adapter.importRequests).to(haveCount(1))
                expect(adapter.importRequests.first?.externalAssets).to(equal([
                    FlowRuntimeExternalAsset(
                        kind: asset.kind,
                        riveAssetId: asset.riveAssetId,
                        riveUniqueName: asset.riveUniqueName,
                        sourceKey: asset.sourceKey,
                        expectedSHA256: asset.expectedSHA256,
                        required: asset.required,
                        content: .omittedOptional
                    ),
                ]))
                expect(
                    FlowRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: contentSHA256,
                        size: 16
                    )
                ).to(beNil())
                context = nil
                expect(context).to(beNil())
            }

            it("releases pre-registered fonts when native context import fails") { @MainActor in
                let data = try Self.fontFixtureData()
                let uniqueName = "rejected-context-font-\(UUID().uuidString)"
                let contentSHA256 = FlowArtifactStore.sha256Hex(data)
                let request = FlowRuntimeImportRequest(
                    artifactBytes: Data([0x52, 0x49, 0x56]),
                    externalAssets: [
                        FlowRuntimeExternalAsset(
                            kind: .font,
                            riveAssetId: 7,
                            riveUniqueName: uniqueName,
                            sourceKey: "rejected-font-request",
                            expectedSHA256: contentSHA256,
                            required: true,
                            content: .bytes(data)
                        )
                    ]
                )
                let adapter = RejectingFlowRuntimeAdapter(
                    expectedFontUniqueName: uniqueName,
                    expectedFontSHA256: contentSHA256
                )

                await expect {
                    try await FlowRuntimeContextFactory(adapter: adapter)
                        .makeContext(for: request)
                }.to(throwError(RejectingFlowRuntimeAdapter.ImportError.rejected))
                expect(adapter.observedRegisteredFont).to(beTrue())
                expect(
                    FlowRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: contentSHA256,
                        size: 16
                    )
                ).to(beNil())
            }
            #endif

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

    private static func fontFixtureData() throws -> Data {
        guard let fixtureRoot = Bundle(for: Self.self).url(
            forResource: "published-font",
            withExtension: nil
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(
            contentsOf: fixtureRoot
                .appendingPathComponent("assets/fonts")
                .appendingPathComponent("inter-400-normal.ttf")
        )
    }
}

#if canImport(UIKit)
private final class RejectingFlowRuntimeAdapter: FlowRuntimeAdapter {
    enum ImportError: Error, Equatable {
        case rejected
    }

    private let expectedFontUniqueName: String
    private let expectedFontSHA256: String
    @MainActor private(set) var observedRegisteredFont = false

    init(
        expectedFontUniqueName: String,
        expectedFontSHA256: String
    ) {
        self.expectedFontUniqueName = expectedFontUniqueName
        self.expectedFontSHA256 = expectedFontSHA256
    }

    @MainActor
    func makeContext(
        for request: FlowRuntimeImportRequest
    ) async throws -> FlowRuntimeContextDriverAttachment {
        observedRegisteredFont = FlowRuntimeFontRegistry.font(
            forRiveUniqueName: expectedFontUniqueName,
            contentSHA256: expectedFontSHA256,
            size: 16
        ) != nil
        throw ImportError.rejected
    }
}
#endif
