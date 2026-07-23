#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import UIKit
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

@MainActor
final class EditorNextNativeArtifactTests: XCTestCase {
    private static let artifactRootEnvironmentKey =
        "NUXIE_EDITOR_NEXT_IOS_PRODUCTION_ARTIFACT_DIR"

    private static let expectedCorpusEntryIDs = [
        "animation-event",
        "external-image",
        "ordinary-assets",
        "font-converter",
        "projection",
        "multi-screen",
        "scripted-resources",
        "animation-operations",
    ]

    private static let expectedIOSExpectationsByEntryID: [String: Set<String>] = [
        "animation-event": [
            "import",
            "named-artboard",
            "mount",
            "positive-time-animation",
            "typed-trigger",
            "frame-scoped-event",
        ],
        "external-image": [
            "import",
            "named-artboard",
            "mount",
            "external-asset-bytes",
        ],
        "ordinary-assets": [
            "import",
            "named-artboard",
            "mount",
            "external-asset-bytes",
        ],
        "font-converter": [
            "import",
            "named-artboard",
            "mount",
            "view-model-write",
        ],
        "projection": [
            "import",
            "named-artboard",
            "mount",
            "view-model-write",
        ],
        "multi-screen": [
            "import",
            "named-artboard",
            "mount",
            "all-manifest-screens",
        ],
        "scripted-resources": [
            "import",
            "named-artboard",
            "mount",
            "ordinary-sibling-visible",
            "unsigned-script-disabled",
            "shader-package-only",
        ],
        "animation-operations": [
            "import",
            "named-artboard",
            "mount",
            "positive-time-animation",
            "all-animation-operations",
            "all-animation-easings",
        ],
    ]

    private static let expectedAnimationExpectations: [NativeAnimationExpectation] = [
        .operation("Operation / Fade In", key: "fade_in", properties: [18], minimumArea: 960),
        .operation("Operation / Fade Out", key: "fade_out", properties: [18], minimumArea: 960),
        .operation("Operation / Slide In", key: "slide_in", properties: [18, 13], minimumArea: 1_600),
        .operation("Operation / Slide Out", key: "slide_out", properties: [18, 13], minimumArea: 1_600),
        .operation("Operation / Grow In", key: "grow_in", properties: [16, 17, 18], minimumArea: 1_280),
        .operation("Operation / Grow Out", key: "grow_out", properties: [16, 17, 18], minimumArea: 1_280),
        .operation("Operation / Shrink In", key: "shrink_in", properties: [16, 17, 18], minimumArea: 1_280),
        .operation("Operation / Shrink Out", key: "shrink_out", properties: [16, 17, 18], minimumArea: 1_280),
        .operation("Operation / Spin In", key: "spin_in", properties: [16, 17, 15, 18], minimumArea: 800),
        .operation("Operation / Spin Out", key: "spin_out", properties: [16, 17, 15, 18], minimumArea: 800),
        .operation(
            "Operation / Move Then Scale In",
            key: "move_then_scale_in",
            properties: [14, 16, 17, 18],
            minimumArea: 1_280
        ),
        .operation(
            "Operation / Move Then Scale Out",
            key: "move_then_scale_out",
            properties: [14, 16, 17, 18],
            minimumArea: 1_280
        ),
        .operation("Operation / Move X", key: "move_x", properties: [13], minimumArea: 1_600),
        .operation("Operation / Move Y", key: "move_y", properties: [14], minimumArea: 1_600),
        .operation("Operation / Scale", key: "scale", properties: [16, 17], minimumArea: 1_280),
        .operation("Operation / Rotate", key: "rotate", properties: [15], minimumArea: 800),
        .operation("Operation / Opacity", key: "opacity", properties: [18], minimumArea: 960),
        .operation("Operation / Color", key: "color", properties: [37], minimumArea: 960),
        .operation("Operation / Resize", key: "resize", properties: [20, 21], minimumArea: 1_280),
        .operation(
            "Operation / Corner Radius",
            key: "corner_radius",
            properties: [31, 161, 163, 162],
            minimumArea: 60
        ),
        .operation("Operation / Stroke", key: "stroke", properties: [47], minimumArea: 120),
        .operation("Operation / Show", key: "show", properties: [18], minimumArea: 960),
        .operation("Operation / Hide", key: "hide", properties: [18], minimumArea: 960),
        .easing("linear", quarterProgressOpacity: 0.25),
        .easing("smooth", quarterProgressOpacity: 0.1291619310473209),
        .easing("natural", quarterProgressOpacity: 0.7648647190588675),
        .easing("slowDown", quarterProgressOpacity: 0.5775729278358209),
        .easing("accelerate", quarterProgressOpacity: 0.09862656137553785),
    ]

    func testExactP17CorpusImportsNamedArtboardsAndRenders() async throws {
        let rootURL = try Self.requiredArtifactRoot()
        let corpus = try Self.decode(
            NativeCorpusManifest.self,
            at: rootURL.appendingPathComponent("native-corpus-manifest.json")
        )
        XCTAssertEqual(corpus.schemaVersion, "nuxie-editor-next-native-corpus.v1")
        XCTAssertEqual(corpus.entries.map(\.id), Self.expectedCorpusEntryIDs)

        var failures: [String] = []
        for corpusEntry in corpus.entries {
            do {
                try await Self.consumeExactEntry(
                    corpusEntry,
                    artifactRootURL: rootURL
                )
                XCTContext.runActivity(
                    named: "Consumed exact entry: \(corpusEntry.id)"
                ) { _ in }
            } catch {
                let failure =
                    "\(corpusEntry.id): \(String(reflecting: error))"
                failures.append(failure)
                XCTContext.runActivity(
                    named: "Exact entry failed: \(failure)"
                ) { _ in }
            }
        }

        guard failures.isEmpty else {
            XCTFail(
                NativeArtifactFixtureError.corpusFailures(failures)
                    .localizedDescription
            )
            return
        }
        try Self.writeNativeConsumerSentinel(to: rootURL)
    }

    func testExactP17CorpusTraversesProductionSDKPipeline() async throws {
        let rootURL = try Self.requiredArtifactRoot()
        let corpus = try Self.decode(
            NativeCorpusManifest.self,
            at: rootURL.appendingPathComponent("native-corpus-manifest.json")
        )
        XCTAssertEqual(corpus.schemaVersion, "nuxie-editor-next-native-corpus.v1")
        XCTAssertEqual(corpus.entries.map(\.id), Self.expectedCorpusEntryIDs)

        var failures: [String] = []
        for corpusEntry in corpus.entries {
            do {
                try await Self.consumeExactEntryThroughSDKPipeline(
                    corpusEntry,
                    artifactRootURL: rootURL
                )
                XCTContext.runActivity(
                    named: "Consumed exact SDK pipeline entry: \(corpusEntry.id)"
                ) { _ in }
            } catch {
                let failure =
                    "\(corpusEntry.id): \(String(reflecting: error))"
                failures.append(failure)
                XCTContext.runActivity(
                    named: "Exact SDK pipeline entry failed: \(failure)"
                ) { _ in }
            }
        }

        guard failures.isEmpty else {
            XCTFail(
                NativeArtifactFixtureError.sdkPipelineFailures(failures)
                    .localizedDescription
            )
            return
        }
        try Self.writeConsumerSentinel(
            to: rootURL,
            filename: "ios-sdk-pipeline-consumed.ok",
            consumer: "ios-sdk-pipeline"
        )
    }

    private static func consumeExactEntry(
        _ corpusEntry: NativeCorpusEntry,
        artifactRootURL: URL
    ) async throws {
        guard let expectedIOSExpectations =
            expectedIOSExpectationsByEntryID[corpusEntry.id] else {
            throw NativeArtifactFixtureError.unsupportedCorpusEntry(corpusEntry.id)
        }
        XCTAssertEqual(
            Set(corpusEntry.consumerExpectations.ios),
            expectedIOSExpectations,
            "Unexpected iOS contract for \(corpusEntry.id)"
        )

        let artifact = try exactArtifact(
            for: corpusEntry,
            artifactRootURL: artifactRootURL
        )
        let manifest = artifact.manifest
        let roleBytesByPath = artifact.roleBytesByPath
        let manifestBytes = artifact.manifestBytes
        let artifactBytes = artifact.rivBytes

        let materializedAssets = try materializeExternalAssets(
            for: corpusEntry,
            manifest: manifest,
            roleBytesByPath: roleBytesByPath
        )
        defer { materializedAssets.remove() }

        let request = try FlowRuntimeArtifactAdapter.makeImportRequest(
            artifactBytes: artifactBytes,
            manifest: manifest,
            expectedIdentity: FlowRuntimeArtifactIdentity(
                flowId: manifest.flowId,
                buildId: manifest.buildId
            ),
            authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                signedContentBytes: manifestBytes,
                signatureEnvelopeBytes: nil,
                selectedKey: nil
            ),
            assetURLsByRiveUniqueName: materializedAssets.urlsByRiveUniqueName
        )
        assertExactExternalAssetBytes(
            request,
            manifest: manifest,
            roleBytesByPath: roleBytesByPath
        )

        let context = try await FlowRuntimeContextFactory(
            adapter: NuxieRuntimeAdapter()
        ).makeContext(for: request)
        XCTAssertEqual(context.importResult.scriptAuthorization, .visualOnly)
        XCTAssertFalse(
            context.importResult.diagnostics.contains(where: {
                $0.severity == .fatal
            })
        )
        XCTContext.runActivity(
            named: "Imported exact entry: \(corpusEntry.id)"
        ) { _ in }

        for screen in manifest.screens {
            try await Self.assertNamedScreenRenders(
                screen,
                entry: corpusEntry,
                manifest: manifest,
                in: context
            )
            XCTContext.runActivity(
                named: "Rendered exact screen: \(corpusEntry.id)/\(screen.screenId)"
            ) { _ in }
        }
    }

    private static func exactArtifact(
        for corpusEntry: NativeCorpusEntry,
        artifactRootURL: URL
    ) throws -> ExactNativeArtifact {
        let entryRoot = artifactRootURL.appendingPathComponent(
            corpusEntry.directory,
            isDirectory: true
        )
        let envelope = try decode(
            ProductionEnvelope.self,
            at: entryRoot.appendingPathComponent("production-envelope.json")
        )
        XCTAssertEqual(
            envelope.schemaVersion,
            "nuxie-rive-production-artifact-envelope.v1"
        )
        XCTAssertEqual(envelope.source.headSeq, corpusEntry.source.headSeq)
        XCTAssertEqual(
            envelope.source.snapshotR2Key,
            corpusEntry.source.snapshotR2Key
        )
        XCTAssertEqual(envelope.source.snapshotPayloadSha256.count, 64)
        XCTAssertGreaterThan(envelope.source.snapshotPayloadSizeBytes, 0)
        XCTAssertEqual(envelope.transport.schemaVersion, "compiler-artifact-envelope.v1")
        XCTAssertEqual(envelope.transport.manifestVersion, 1)
        XCTAssertEqual(envelope.transport.totalFiles, envelope.transport.files.count)
        XCTAssertEqual(
            envelope.transport.totalSize,
            envelope.transport.files.reduce(0) { $0 + $1.sizeBytes }
        )
        XCTAssertEqual(envelope.transport.contentHash.count, 64)
        XCTAssertNil(envelope.signature)

        var roleBytesByPath: [String: Data] = [:]
        for file in envelope.transport.files {
            XCTAssertNil(
                roleBytesByPath[file.path],
                "Production envelope contains duplicate role \(file.path)"
            )
            let bytes = try XCTUnwrap(
                Data(base64Encoded: file.bytesBase64),
                "Production envelope role \(file.path) is not base64"
            )
            XCTAssertEqual(bytes.count, file.sizeBytes)
            XCTAssertEqual(ExperienceArtifactStore.sha256Hex(bytes), file.sha256)
            roleBytesByPath[file.path] = bytes
        }

        let manifestBytes = try XCTUnwrap(
            roleBytesByPath[envelope.manifest.path]
        )
        let manifest = try JSONDecoder().decode(
            FlowArtifactManifest.self,
            from: manifestBytes
        )
        XCTAssertEqual(manifest, envelope.manifest.value)
        XCTAssertEqual(manifest.flowId, corpusEntry.source.flowId)
        XCTAssertEqual(manifest.buildId, corpusEntry.source.buildId)
        XCTAssertEqual(manifest.screens, corpusEntry.screens)

        let artifactBytes = try XCTUnwrap(roleBytesByPath[envelope.riv.path])
        XCTAssertEqual(artifactBytes.count, manifest.riv.sizeBytes)
        XCTAssertEqual(ExperienceArtifactStore.sha256Hex(artifactBytes), manifest.riv.sha256)

        let expectedRolePaths = Set(
            [envelope.manifest.path, envelope.riv.path]
                + manifest.assets.images.map(\.path)
                + manifest.assets.fonts.map(\.assetUrl)
        )
        XCTAssertEqual(
            Set(roleBytesByPath.keys),
            expectedRolePaths,
            "Unsupported production-envelope role for \(corpusEntry.id)"
        )

        return ExactNativeArtifact(
            entryRootURL: entryRoot,
            envelope: envelope,
            manifest: manifest,
            manifestBytes: manifestBytes,
            rivBytes: artifactBytes,
            roleBytesByPath: roleBytesByPath
        )
    }

    private static func consumeExactEntryThroughSDKPipeline(
        _ corpusEntry: NativeCorpusEntry,
        artifactRootURL: URL
    ) async throws {
        guard let expectedIOSExpectations =
            expectedIOSExpectationsByEntryID[corpusEntry.id] else {
            throw NativeArtifactFixtureError.unsupportedCorpusEntry(corpusEntry.id)
        }
        XCTAssertEqual(
            Set(corpusEntry.consumerExpectations.ios),
            expectedIOSExpectations,
            "Unexpected iOS contract for \(corpusEntry.id)"
        )

        let artifact = try exactArtifact(
            for: corpusEntry,
            artifactRootURL: artifactRootURL
        )
        let fixture = try ExactSDKPipelineFixture.make(
            entry: corpusEntry,
            artifact: artifact
        )
        defer { fixture.remove() }

        let downloaded = try await fixture.artifactStore.getOrDownloadArtifact(
            for: fixture.flow
        )
        XCTAssertEqual(downloaded.source, .downloadedArtifact)
        try assertExactLoadedArtifact(
            downloaded,
            artifact: artifact,
            entry: corpusEntry
        )

        let cached = try await fixture.artifactStore.getOrDownloadArtifact(
            for: fixture.flow
        )
        XCTAssertEqual(cached.source, .cachedArtifact)
        try assertExactLoadedArtifact(
            cached,
            artifact: artifact,
            entry: corpusEntry
        )
        XCTContext.runActivity(
            named: "Downloaded and cached exact entry: \(corpusEntry.id)"
        ) { _ in }

        try await assertProductionControllerMountsAllScreens(
            fixture: fixture,
            entry: corpusEntry
        )
    }

    private static func assertExactLoadedArtifact(
        _ loaded: LoadedFlowArtifact,
        artifact: ExactNativeArtifact,
        entry: NativeCorpusEntry
    ) throws {
        XCTAssertEqual(loaded.manifest, artifact.manifest)
        XCTAssertEqual(
            loaded.authorizationEvidence.signedContentBytes,
            artifact.manifestBytes
        )
        XCTAssertNil(loaded.authorizationEvidence.signatureEnvelopeBytes)
        XCTAssertNil(loaded.authorizationEvidence.selectedKey)

        for file in artifact.envelope.transport.files {
            let expected = try XCTUnwrap(artifact.roleBytesByPath[file.path])
            let cachedURL = loaded.directoryURL.appendingPathComponent(file.path)
            XCTAssertEqual(
                try Data(contentsOf: cachedURL),
                expected,
                "Artifact store changed exact role bytes for \(entry.id):\(file.path)"
            )
        }
        for image in artifact.manifest.assets.images {
            let preparedURL = try XCTUnwrap(
                loaded.localAssetURL(forRiveUniqueName: image.riveUniqueName)
            )
            XCTAssertEqual(
                try Data(contentsOf: preparedURL),
                artifact.roleBytesByPath[image.path],
                "Runtime asset store changed exact image bytes for "
                    + "\(entry.id):\(image.riveUniqueName)"
            )
        }
    }

    private static func assertProductionControllerMountsAllScreens(
        fixture: ExactSDKPipelineFixture,
        entry: NativeCorpusEntry
    ) async throws {
        let eventLog = MockEventLog()
        let productService = MockProductService()
        let controller = ExperienceViewController(
            flow: fixture.flow,
            artifactStore: fixture.artifactStore,
            eventLog: eventLog,
            loadingTimeoutSeconds: 15,
            transactionService: TransactionService(
                productService: productService,
                transactionObserver: MockTransactionObserver(),
                pendingPurchaseStore: InMemoryPendingPurchaseStore(),
                dateProvider: MockDateProvider(),
                configurationProvider: {
                    NuxieConfiguration(apiKey: "editor-next-native-artifact-tests")
                }
            ),
            productService: productService
        )
        let delegate = NativeSDKPipelineDelegate()
        controller.runtimeDelegate = delegate

        let window = UIWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()

        var operationError: Error?
        do {
            let becameReady = await waitForSDKPipeline {
                delegate.readyCount == 1 || !controller.errorView.isHidden
            }
            guard becameReady,
                  delegate.readyCount == 1,
                  controller.errorView.isHidden else {
                throw NativeArtifactFixtureError.controllerMountFailed(
                    entry: entry.id,
                    screen: fixture.artifact.manifest.entry.screenId
                )
            }

            for screen in fixture.artifact.manifest.screens {
                if screen.screenId != fixture.artifact.manifest.entry.screenId {
                    controller.navigate(
                        to: screen.screenId,
                        transition: ["type": "none"]
                    )
                    let navigated = await waitForSDKPipeline {
                        delegate.changedScreenIDs.last == screen.screenId
                            || !controller.errorView.isHidden
                    }
                    guard navigated,
                          delegate.changedScreenIDs.last == screen.screenId,
                          controller.errorView.isHidden else {
                        throw NativeArtifactFixtureError.controllerMountFailed(
                            entry: entry.id,
                            screen: screen.screenId
                        )
                    }
                }

                let surface: FlowRuntimeSurfaceView? =
                    await waitForSDKPipelineValue { () -> FlowRuntimeSurfaceView? in
                    findSurface(
                        screenID: screen.screenId,
                        in: controller.view
                    ).flatMap { candidate in
                        guard !candidate.isHidden,
                              candidate.window != nil,
                              candidate.metalLayer.device != nil,
                              candidate.metalLayer.drawableSize.width > 0,
                              candidate.metalLayer.drawableSize.height > 0 else {
                            return nil
                        }
                        return candidate
                    }
                }
                guard surface != nil else {
                    throw NativeArtifactFixtureError.controllerMountFailed(
                        entry: entry.id,
                        screen: screen.screenId
                    )
                }

                // Controller readiness precedes the asynchronous display-link
                // frame. Let that production frame settle, then fail on the
                // controller's terminal runtime state rather than treating a
                // configured layer as rendered proof.
                try await Task.sleep(nanoseconds: 100_000_000)
                guard controller.errorView.isHidden else {
                    throw NativeArtifactFixtureError.controllerMountFailed(
                        entry: entry.id,
                        screen: screen.screenId
                    )
                }
                XCTContext.runActivity(
                    named: "Mounted exact SDK screen: "
                        + "\(entry.id)/\(screen.screenId)"
                ) { _ in }
            }
        } catch {
            operationError = error
        }

        await controller.shutdownRuntime()
        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
        window.isHidden = true
        window.rootViewController = nil

        if let operationError {
            throw operationError
        }
    }

    private static func findSurface(
        screenID: String,
        in view: UIView
    ) -> FlowRuntimeSurfaceView? {
        if let surface = view as? FlowRuntimeSurfaceView,
           surface.accessibilityIdentifier == "nuxie-flow-surface",
           surface.accessibilityLabel == screenID {
            return surface
        }
        for child in view.subviews {
            if let match = findSurface(screenID: screenID, in: child) {
                return match
            }
        }
        return nil
    }

    private static func waitForSDKPipeline(
        attempts: Int = 300,
        _ predicate: () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    private static func waitForSDKPipelineValue<Value>(
        attempts: Int = 300,
        _ value: () -> Value?
    ) async -> Value? {
        for _ in 0..<attempts {
            if let resolved = value() { return resolved }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return value()
    }

    private static func assertNamedScreenRenders(
        _ screen: FlowArtifactScreen,
        entry: NativeCorpusEntry,
        manifest: FlowArtifactManifest,
        in context: FlowRuntimeContext
    ) async throws {
        let isEntryScreen = screen.screenId == manifest.entry.screenId
        let session = try await context.makeSession(
            descriptor: FlowRenderSessionDescriptor(
                artboardName: screen.artboardName,
                stateMachineName: isEntryScreen
                    ? entry.behaviorExpectations?.stateMachine?.stateMachineName
                    : nil
            )
        )
        XCTContext.runActivity(
            named: "Created exact session: \(entry.id)/\(screen.screenId)"
        ) { _ in }

        XCTAssertEqual(session.bootstrap.player.artboardName, screen.artboardName)
        XCTAssertEqual(
            session.bootstrap.player.bounds,
            FlowRuntimeArtboardBounds(
                minX: 0,
                minY: 0,
                maxX: screen.width,
                maxY: screen.height
            )
        )
        XCTAssertFalse(
            session.creationResult.diagnostics.contains(where: {
                $0.severity == .fatal
            })
        )

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 96, height: 96))
        let viewController = UIViewController()
        let surfaceView = FlowRuntimeSurfaceView(frame: window.bounds)
        viewController.view.addSubview(surfaceView)
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        surfaceView.layoutIfNeeded()

        let size = FlowRuntimeSurfaceSizing.pixels(
            width: surfaceView.bounds.width,
            height: surfaceView.bounds.height,
            scale: surfaceView.metalLayer.contentsScale
        )
        let surface = try await session.attachAppleSurface(
            to: FlowRuntimeAppleSurfaceTarget(
                layer: surfaceView.metalLayer,
                size: size
            )
        )
        do {
            _ = try await render(
                session: session,
                surfaceView: surfaceView,
                surface: surface,
                timestamp: 1,
                delta: 0
            )
            XCTContext.runActivity(
                named: "Presented exact first frame: \(entry.id)/\(screen.screenId)"
            ) { _ in }
            XCTAssertEqual(session.readiness, .ready)

            if isEntryScreen {
                try await assertDeclaredEntryBehavior(
                    entry,
                    session: session,
                    surfaceView: surfaceView,
                    surface: surface
                )
                XCTContext.runActivity(
                    named: "Exercised exact behavior: \(entry.id)/\(screen.screenId)"
                ) { _ in }
            }

            try await shutdown(
                surface: surface,
                session: session,
                window: window
            )
        } catch {
            let operationError = error
            do {
                try await shutdown(
                    surface: surface,
                    session: session,
                    window: window
                )
            } catch {
                throw NativeArtifactFixtureError.runtimeOperationAndShutdownFailed(
                    operation: String(reflecting: operationError),
                    shutdown: String(reflecting: error)
                )
            }
            throw operationError
        }
    }

    private static func shutdown(
        surface: FlowRenderSurface,
        session: FlowRenderSession,
        window: UIWindow
    ) async throws {
        var detachError: Error?
        if surface.state == .attached {
            do {
                _ = try await surface.detach()
            } catch {
                detachError = error
            }
        }
        surface.dispose()
        session.dispose()
        window.isHidden = true
        window.rootViewController = nil
        if let detachError {
            throw detachError
        }
    }

    private static func assertDeclaredEntryBehavior(
        _ entry: NativeCorpusEntry,
        session: FlowRenderSession,
        surfaceView: FlowRuntimeSurfaceView,
        surface: FlowRenderSurface
    ) async throws {
        let expectations = Set(entry.consumerExpectations.ios)

        if expectations.contains("positive-time-animation") {
            if entry.id == "animation-operations" {
                XCTAssertEqual(session.bootstrap.player.kind, .linearAnimation)
                XCTAssertNotNil(session.bootstrap.player.playerName)
            }
            let advanced = try await render(
                session: session,
                surfaceView: surfaceView,
                surface: surface,
                timestamp: 1.25,
                delta: 0.25
            )
            XCTAssertTrue(
                advanced.orderedOutputs.contains(where: { output in
                    guard case .runtimeAdvanced(let delta) = output.payload else {
                        return false
                    }
                    return abs(delta - 0.25) < 0.000_001
                }),
                "Positive-time runtime advance was not reported for \(entry.id)"
            )
        }

        if expectations.contains("all-animation-operations")
            || expectations.contains("all-animation-easings") {
            guard entry.animationExpectations == expectedAnimationExpectations else {
                throw NativeArtifactFixtureError.animationCorpusMismatch(
                    entry: entry.id,
                    expectedCount: expectedAnimationExpectations.count,
                    actualCount: entry.animationExpectations?.count ?? 0
                )
            }

            // The shipped ABI 1.5 configured-session contract accepts an
            // explicit state-machine name, but declares linear animations
            // fallback-only. One fallback animation advancing cannot prove
            // the exact 23 named operations and five named easing timelines.
            // Keep this unsupported runtime capability visible instead of
            // treating the fallback player as behavioral coverage.
            throw NativeArtifactFixtureError.namedLinearAnimationSelectionUnavailable(
                entry: entry.id,
                animationNames: expectedAnimationExpectations.map(\.name)
            )
        }

        if let stateMachine = entry.behaviorExpectations?.stateMachine {
            XCTAssertEqual(session.bootstrap.player.kind, .stateMachine)
            XCTAssertEqual(
                session.bootstrap.player.playerName,
                stateMachine.stateMachineName
            )
            let queriedInputs = try await session.perform(
                .query([.playerInputs])
            )
            XCTAssertTrue(
                queriedInputs.playerInputs?.contains(where: {
                    $0.name == "Activate" && $0.kind == .trigger
                }) == true,
                "Typed Activate trigger is missing from \(entry.id)"
            )

            let fired = try await session.perform(
                .stateBatch(
                    FlowRuntimeStateBatch(
                        mutations: [.fireInputTrigger(name: "Activate")]
                    )
                )
            )
            let transitioned = try await render(
                session: session,
                surfaceView: surfaceView,
                surface: surface,
                timestamp: 1.25,
                delta: 0
            )
            let delivered = try await render(
                session: session,
                surfaceView: surfaceView,
                surface: surface,
                timestamp: 1.26,
                delta: 0
            )
            let firstCycleEvents = reportedEventNames(
                in: fired.orderedOutputs
                    + transitioned.orderedOutputs
                    + delivered.orderedOutputs
            )
            XCTAssertEqual(
                firstCycleEvents.filter { $0 == stateMachine.eventName }.count,
                stateMachine.eventCount
            )

            for replayIndex in 0..<stateMachine.replayAdvanceCount {
                let replay = try await render(
                    session: session,
                    surfaceView: surfaceView,
                    surface: surface,
                    timestamp: 1.26 + Double(replayIndex + 1) * 0.01,
                    delta: 0
                )
                XCTAssertFalse(
                    reportedEventNames(in: replay.orderedOutputs)
                        .contains(stateMachine.eventName),
                    "Frame-scoped event replayed for \(entry.id)"
                )
            }
        }

        if let converter = entry.behaviorExpectations?.converter {
            try await assertViewModelWrites(
                [
                    NativeViewModelWrite(
                        path: converter.path,
                        value: .string(converter.input)
                    ),
                ],
                session: session,
                entryID: entry.id
            )
        }

        if let projection = entry.behaviorExpectations?.projection {
            try await assertViewModelWrites(
                projection.writes,
                session: session,
                entryID: entry.id
            )
        }

        if expectations.contains("unsigned-script-disabled") {
            let unsignedAdvance = try await session.perform(
                .advance(FlowRuntimeFrameTime(timestamp: 1.5, delta: 0))
            )
            XCTAssertFalse(
                unsignedAdvance.orderedOutputs.contains(where: {
                    if case .hostCommand = $0.payload { return true }
                    return false
                }),
                "Unsigned script executed host work for \(entry.id)"
            )
        }
    }

    private static func assertViewModelWrites(
        _ writes: [NativeViewModelWrite],
        session: FlowRenderSession,
        entryID: String
    ) async throws {
        let root = try XCTUnwrap(
            session.bootstrap.catalog.rootInstance,
            "Missing root ViewModel for \(entryID)"
        )
        let mutationID: UInt64 = 91
        let result = try await session.perform(
            .stateBatch(
                FlowRuntimeStateBatch(
                    hostMutationID: mutationID,
                    mutations: writes.map { write in
                        .setValue(
                            instance: .existing(root.id),
                            path: write.path,
                            value: write.value.runtimeValue
                        )
                    }
                )
            )
        )
        XCTAssertFalse(result.diagnostics.contains(where: { $0.severity == .fatal }))

        let query = try await session.perform(.query([.values]))
        let values = try XCTUnwrap(
            query.values,
            "Runtime values query was empty for \(entryID)"
        )
        for write in writes {
            XCTAssertEqual(
                scalarValue(
                    in: values,
                    instanceID: root.id,
                    path: write.path
                ),
                write.value.runtimeValue,
                "ViewModel write did not persist for \(entryID):\(write.path)"
            )
        }
    }

    private static func scalarValue(
        in arena: FlowRuntimeValueArena,
        instanceID: FlowRuntimeInstanceID,
        path: String
    ) -> FlowRuntimeScalarValue? {
        guard var nodeIndex = arena.roots.first(where: {
            $0.instanceID == instanceID
        })?.nodeIndex else {
            return nil
        }
        for component in path.split(separator: "/").map(String.init) {
            guard arena.nodes.indices.contains(nodeIndex) else { return nil }
            let fields: [FlowRuntimeValueEdge]
            switch arena.nodes[nodeIndex].value {
            case .object(_, let value), .viewModel(_, _, let value):
                fields = value
            case .scalar, .list:
                return nil
            }
            guard let next = fields.first(where: { $0.key == component }) else {
                return nil
            }
            nodeIndex = next.nodeIndex
        }
        guard arena.nodes.indices.contains(nodeIndex),
              case .scalar(let value) = arena.nodes[nodeIndex].value else {
            return nil
        }
        return value
    }

    private static func reportedEventNames(
        in outputs: [FlowRuntimeOutput]
    ) -> [String] {
        outputs.compactMap { output in
            guard case .reportedEvent(let name, _, _, _, _) = output.payload else {
                return nil
            }
            return name
        }
    }

    private static func render(
        session: FlowRenderSession,
        surfaceView: FlowRuntimeSurfaceView,
        surface: FlowRenderSurface,
        timestamp: TimeInterval,
        delta: TimeInterval
    ) async throws -> FlowRuntimeOperationResult {
        let drawable = try XCTUnwrap(
            surfaceView.metalLayer.nextDrawable(),
            "Shipped NuxieRuntime surface did not vend a drawable"
        )
        let frameCompletion = NativeFrameCompletion()
        let result = try await session.perform(
            .advanceAndRender(
                FlowRuntimeFrameTime(timestamp: timestamp, delta: delta)
            ),
            drawable: surface.makeDrawableTarget(drawable) {
                Task {
                    await frameCompletion.complete()
                }
            }
        )
        await frameCompletion.wait()
        XCTAssertEqual(result.renderOutcome, .presented)
        XCTAssertEqual(result.surfaceDisposition, .presented)
        XCTAssertFalse(result.diagnostics.contains(where: { $0.severity == .fatal }))
        return result
    }

    private static func materializeExternalAssets(
        for entry: NativeCorpusEntry,
        manifest: FlowArtifactManifest,
        roleBytesByPath: [String: Data]
    ) throws -> MaterializedNativeAssets {
        XCTAssertTrue(
            manifest.assets.fonts.isEmpty,
            "The exact P17 corpus declares embedded, not external, fonts"
        )

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "editor-next-native-assets-\(entry.id)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        var urlsByRiveUniqueName: [String: URL] = [:]
        do {
            for asset in manifest.assets.images {
                let bytes = try XCTUnwrap(
                    roleBytesByPath[asset.path],
                    "Missing exact image role \(asset.path) for \(entry.id)"
                )
                XCTAssertEqual(ExperienceArtifactStore.sha256Hex(bytes), asset.sha256)

                let url = rootURL.appendingPathComponent(asset.path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try bytes.write(to: url, options: .atomic)
                XCTAssertNil(urlsByRiveUniqueName[asset.riveUniqueName])
                urlsByRiveUniqueName[asset.riveUniqueName] = url
            }
        } catch {
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }

        return MaterializedNativeAssets(
            rootURL: rootURL,
            urlsByRiveUniqueName: urlsByRiveUniqueName
        )
    }

    private static func assertExactExternalAssetBytes(
        _ request: FlowRuntimeImportRequest,
        manifest: FlowArtifactManifest,
        roleBytesByPath: [String: Data]
    ) {
        XCTAssertEqual(request.externalAssets.count, manifest.assets.images.count)
        for image in manifest.assets.images {
            guard let runtimeAsset = request.externalAssets.first(where: {
                $0.riveUniqueName == image.riveUniqueName
            }) else {
                XCTFail("Missing runtime asset \(image.riveUniqueName)")
                continue
            }
            XCTAssertEqual(runtimeAsset.kind, .image)
            XCTAssertEqual(runtimeAsset.expectedSHA256, image.sha256)
            guard case .bytes(let bytes) = runtimeAsset.content else {
                XCTFail("Required runtime asset \(image.riveUniqueName) was omitted")
                continue
            }
            XCTAssertEqual(bytes, roleBytesByPath[image.path])
        }
    }

    private static func requiredArtifactRoot() throws -> URL {
        let environmentPath = ProcessInfo.processInfo.environment[
            artifactRootEnvironmentKey
        ].flatMap { $0.isEmpty ? nil : $0 }
        let pointerPath = try? String(
            contentsOf: artifactRootPointerURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard let path = environmentPath ?? pointerPath, !path.isEmpty else {
            throw XCTSkip(
                "Run make test-editor-next-production-artifact with "
                    + "\(artifactRootEnvironmentKey) set"
            )
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw NativeArtifactFixtureError.missingArtifactRoot(path)
        }
        return url
    }

    private static var artifactRootPointerURL: URL {
        var repoRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            repoRoot.deleteLastPathComponent()
        }
        return repoRoot
            .appendingPathComponent(".artifacts", isDirectory: true)
            .appendingPathComponent("editor-next-production-artifact-root")
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        at url: URL
    ) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private static func writeNativeConsumerSentinel(to rootURL: URL) throws {
        try writeConsumerSentinel(
            to: rootURL,
            filename: "ios-native-consumed.ok",
            consumer: "ios-native-runtime"
        )
    }

    private static func writeConsumerSentinel(
        to rootURL: URL,
        filename: String,
        consumer: String
    ) throws {
        let run = try decode(
            ArtifactRun.self,
            at: rootURL.appendingPathComponent("artifact-consumption-run.json")
        )
        XCTAssertEqual(run.schemaVersion, "nuxie-editor-next-ios-artifact-run.v1")
        XCTAssertEqual(
            run.sentinelSchemaVersion,
            "nuxie-editor-next-ios-artifact-consumer.v1"
        )
        XCTAssertTrue(
            run.consumers.contains(
                ArtifactConsumer(
                    filename: filename,
                    consumer: consumer
                )
            )
        )

        let sentinel = ArtifactSentinel(
            schemaVersion: run.sentinelSchemaVersion,
            runId: run.runId,
            consumer: consumer
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var bytes = try encoder.encode(sentinel)
        bytes.append(0x0a)
        try bytes.write(
            to: rootURL.appendingPathComponent(filename),
            options: .atomic
        )
    }
}

private enum NativeArtifactFixtureError: LocalizedError {
    case missingArtifactRoot(String)
    case unsupportedCorpusEntry(String)
    case corpusFailures([String])
    case sdkPipelineFailures([String])
    case controllerMountFailed(entry: String, screen: String)
    case runtimeOperationAndShutdownFailed(operation: String, shutdown: String)
    case animationCorpusMismatch(
        entry: String,
        expectedCount: Int,
        actualCount: Int
    )
    case namedLinearAnimationSelectionUnavailable(
        entry: String,
        animationNames: [String]
    )

    var errorDescription: String? {
        switch self {
        case .missingArtifactRoot(let path):
            "Exact Editor Next production artifact root is missing: \(path)"
        case .unsupportedCorpusEntry(let id):
            "Exact Editor Next corpus entry is unsupported: \(id)"
        case .corpusFailures(let failures):
            "Exact Editor Next corpus failures:\n\(failures.joined(separator: "\n"))"
        case .sdkPipelineFailures(let failures):
            "Exact Editor Next SDK pipeline failures:\n"
                + failures.joined(separator: "\n")
        case .controllerMountFailed(let entry, let screen):
            "Production controller failed to mount \(entry)/\(screen)"
        case .runtimeOperationAndShutdownFailed(let operation, let shutdown):
            "Runtime operation failed (\(operation)); exact shutdown also failed (\(shutdown))"
        case .animationCorpusMismatch(let entry, let expectedCount, let actualCount):
            "Exact animation corpus mismatch for \(entry): expected "
                + "\(expectedCount) records, got \(actualCount)"
        case .namedLinearAnimationSelectionUnavailable(let entry, let names):
            "Shipped runtime cannot explicitly select the named linear "
                + "animations required by \(entry): \(names.joined(separator: ", "))"
        }
    }
}

private struct NativeCorpusManifest: Decodable {
    let schemaVersion: String
    let entries: [NativeCorpusEntry]
}

private struct NativeCorpusEntry: Decodable {
    let id: String
    let directory: String
    let consumerExpectations: NativeConsumerExpectations
    let source: NativeCorpusSource
    let screens: [FlowArtifactScreen]
    let behaviorExpectations: NativeBehaviorExpectations?
    let animationExpectations: [NativeAnimationExpectation]?
}

private struct NativeConsumerExpectations: Decodable {
    let ios: [String]
}

private struct NativeCorpusSource: Decodable {
    let headSeq: Int
    let snapshotR2Key: String
    let flowId: String
    let buildId: String
}

private struct NativeBehaviorExpectations: Decodable {
    let stateMachine: NativeStateMachineExpectation?
    let converter: NativeConverterExpectation?
    let projection: NativeProjectionExpectation?
}

private struct NativeStateMachineExpectation: Decodable {
    let stateMachineName: String
    let eventName: String
    let eventCount: Int
    let replayAdvanceCount: Int
}

private struct NativeConverterExpectation: Decodable {
    let path: String
    let input: String
}

private struct NativeProjectionExpectation: Decodable {
    let writes: [NativeViewModelWrite]
}

private struct NativeViewModelWrite: Decodable {
    let path: String
    let value: NativeScalarValue

    init(path: String, value: NativeScalarValue) {
        self.path = path
        self.value = value
    }
}

private struct NativeAnimationExpectation: Decodable, Equatable {
    let name: String
    let operationKey: String
    let easing: String
    let kind: String
    let durationSeconds: Double
    let startSeconds: Double
    let endSeconds: Double
    let propertyKeys: [Int]
    let minimumChangedAreaAtOneX: Int
    let quarterProgressOpacity: Double?

    static func operation(
        _ name: String,
        key: String,
        properties: [Int],
        minimumArea: Int
    ) -> NativeAnimationExpectation {
        NativeAnimationExpectation(
            name: name,
            operationKey: key,
            easing: "smooth",
            kind: "operation",
            durationSeconds: 0.5,
            startSeconds: 0,
            endSeconds: 0.5,
            propertyKeys: properties,
            minimumChangedAreaAtOneX: minimumArea,
            quarterProgressOpacity: nil
        )
    }

    static func easing(
        _ easing: String,
        quarterProgressOpacity: Double
    ) -> NativeAnimationExpectation {
        NativeAnimationExpectation(
            name: "Easing / \(easing)",
            operationKey: "fade_in",
            easing: easing,
            kind: "easing",
            durationSeconds: 1,
            startSeconds: 0,
            endSeconds: 1,
            propertyKeys: [18],
            minimumChangedAreaAtOneX: 960,
            quarterProgressOpacity: quarterProgressOpacity
        )
    }
}

private enum NativeScalarValue: Decodable {
    case bool(Bool)
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a scalar ViewModel write"
            )
        }
    }

    var runtimeValue: FlowRuntimeScalarValue {
        switch self {
        case .bool(let value):
            .bool(value)
        case .number(let value):
            .number(value)
        case .string(let value):
            .string(value)
        }
    }
}

private struct ProductionEnvelope: Decodable {
    let schemaVersion: String
    let source: ProductionArtifactSource
    let transport: ProductionTransport
    let manifest: ProductionManifestRole
    let riv: ProductionRivRole
    let signature: ProductionSignatureRole?
}

private struct ProductionArtifactSource: Decodable {
    let headSeq: Int
    let snapshotR2Key: String
    let snapshotPayloadSha256: String
    let snapshotPayloadSizeBytes: Int
}

private struct ProductionTransport: Decodable {
    let schemaVersion: String
    let manifestVersion: Int
    let contentHash: String
    let totalFiles: Int
    let totalSize: Int
    let files: [ProductionTransportFile]
}

private struct ProductionTransportFile: Decodable {
    let path: String
    let sha256: String
    let sizeBytes: Int
    let contentType: String
    let bytesBase64: String
}

private struct ProductionManifestRole: Decodable {
    let path: String
    let value: FlowArtifactManifest
}

private struct ProductionRivRole: Decodable {
    let path: String
}

private struct ProductionSignatureRole: Decodable {
    let path: String
}

private struct MaterializedNativeAssets {
    let rootURL: URL
    let urlsByRiveUniqueName: [String: URL]

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private struct ExactNativeArtifact {
    let entryRootURL: URL
    let envelope: ProductionEnvelope
    let manifest: FlowArtifactManifest
    let manifestBytes: Data
    let rivBytes: Data
    let roleBytesByPath: [String: Data]
}

private struct ExactSDKPipelineFixture {
    let rootURL: URL
    let artifact: ExactNativeArtifact
    let flow: Experience
    let artifactStore: ExperienceArtifactStore

    static func make(
        entry: NativeCorpusEntry,
        artifact: ExactNativeArtifact
    ) throws -> ExactSDKPipelineFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "editor-next-sdk-pipeline-\(entry.id)-\(UUID().uuidString)",
                isDirectory: true
            )
        let sourceURL = rootURL.appendingPathComponent(
            "producer-roles",
            isDirectory: true
        )
        let cacheURL = rootURL.appendingPathComponent(
            "sdk-cache",
            isDirectory: true
        )
        let runtimeAssetURL = rootURL.appendingPathComponent(
            "runtime-assets",
            isDirectory: true
        )

        do {
            for file in artifact.envelope.transport.files {
                let bytes = try XCTUnwrap(
                    artifact.roleBytesByPath[file.path],
                    "Missing exact producer role \(entry.id):\(file.path)"
                )
                let destination = sourceURL.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try bytes.write(to: destination, options: .atomic)
            }

            let buildFiles = artifact.envelope.transport.files.map {
                BuildFile(
                    path: $0.path,
                    size: $0.sizeBytes,
                    contentType: $0.contentType
                )
            }
            let flow = Experience(
                screens: RemoteFlow(
                    id: artifact.manifest.flowId,
                    flowArtifact: FlowArtifact(
                        url: sourceURL.absoluteString,
                        buildId: artifact.manifest.buildId,
                        manifest: BuildManifest(
                            totalFiles: artifact.envelope.transport.totalFiles,
                            totalSize: artifact.envelope.transport.totalSize,
                            contentHash: artifact.envelope.transport.contentHash,
                            files: buildFiles
                        )
                    ),
                    screens: artifact.manifest.screens.map {
                        RemoteFlowScreen(id: $0.screenId)
                    }
                )
            )
            let store = ExperienceArtifactStore(
                cacheDirectory: cacheURL,
                runtimeAssetStore: RuntimeAssetStore(
                    cacheDirectory: runtimeAssetURL
                )
            )
            return ExactSDKPipelineFixture(
                rootURL: rootURL,
                artifact: artifact,
                flow: flow,
                artifactStore: store
            )
        } catch {
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

@MainActor
private final class NativeSDKPipelineDelegate: FlowRuntimeDelegate {
    private(set) var readyCount = 0
    private(set) var changedScreenIDs: [String] = []

    func flowViewControllerDidBecomeReady(
        _ controller: ExperienceViewController
    ) {
        readyCount += 1
    }

    func flowViewController(
        _ controller: ExperienceViewController,
        didChangeScreen screenId: String
    ) {
        changedScreenIDs.append(screenId)
    }

    func flowViewControllerDidRequestDismiss(
        _ controller: ExperienceViewController,
        reason: CloseReason
    ) {}
}

private actor NativeFrameCompletion {
    private var isComplete = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func complete() {
        guard !isComplete else { return }
        isComplete = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func wait() async {
        guard !isComplete else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private struct ArtifactRun: Decodable {
    let schemaVersion: String
    let runId: String
    let sentinelSchemaVersion: String
    let consumers: [ArtifactConsumer]
}

private struct ArtifactConsumer: Codable, Equatable {
    let filename: String
    let consumer: String
}

private struct ArtifactSentinel: Encodable {
    let schemaVersion: String
    let runId: String
    let consumer: String
}
#endif
