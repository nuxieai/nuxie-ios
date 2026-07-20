import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class FlowViewModelTelemetryTests: AsyncSpec {
    override class func spec() {
        var mockEventService: MockEventService!

        func makeFlow(id: String = "flow-telemetry", url: String = "https://cdn.example/flow/index.html") -> Flow {
            let remoteFlow = RemoteFlow(
                id: id,
                flowArtifact: FlowArtifact(
                    url: url,
                    manifest: BuildManifest(
                        totalFiles: 1,
                        totalSize: 100,
                        contentHash: "hash-\(id)",
                        files: [BuildFile(path: "flow.riv", size: 100, contentType: "application/octet-stream")]
                    )
                ),
                screens: [
                    RemoteFlowScreen(
                        id: "screen-1",
                        defaultViewModelName: nil,
                        defaultInstanceId: nil
                    ),
                ],
                viewModelValues: nil
            )
            return Flow(remoteFlow: remoteFlow, products: [])
        }

        beforeEach { @MainActor in
            let testConfig = NuxieConfiguration(apiKey: "test-api-key")
            Container.shared.sdkConfiguration.register { testConfig }
            mockEventService = MockEventService()
            Container.shared.eventService.register { mockEventService }
        }

        describe("artifact load telemetry") {
            it("ignores a superseded artifact load even when its loader finishes last") { @MainActor in
                let flow = makeFlow(id: "flow-superseded")
                let loader = ControlledFlowArtifactLoader()
                let viewModel = FlowViewModel(
                    flow: flow,
                    artifactStore: FlowArtifactStore(),
                    loadingTimeoutSeconds: 1,
                    artifactLoader: { flow in
                        try await loader.load(flow: flow)
                    }
                )
                var loadedBuildIDs: [String] = []
                var loadStartedCount = 0
                viewModel.onLoadStarted = {
                    loadStartedCount += 1
                }
                viewModel.onLoadArtifact = { artifact in
                    loadedBuildIDs.append(artifact.manifest.buildId)
                    viewModel.handleLoadingFinished()
                }

                viewModel.loadFlow()
                expect(loadStartedCount).to(equal(1))
                await expect { await loader.callCount }
                    .toEventually(equal(1), timeout: .seconds(1))

                viewModel.loadFlow()
                expect(loadStartedCount).to(equal(2))
                await expect { await loader.callCount }
                    .toEventually(equal(2), timeout: .seconds(1))

                await loader.succeed(
                    call: 1,
                    with: try makeLoadedArtifact(flow: flow, buildId: "new-build")
                )
                await expect { loadedBuildIDs }
                    .toEventually(equal(["new-build"]), timeout: .seconds(1))

                await loader.succeed(
                    call: 0,
                    with: try makeLoadedArtifact(flow: flow, buildId: "old-build")
                )
                await Task.yield()
                await Task.yield()

                expect(loadedBuildIDs).to(equal(["new-build"]))
                expect(viewModel.currentState).to(equal(.loaded))
                expect(mockEventService.trackedEvents.filter {
                    $0.name == JourneyEvents.flowArtifactLoadFailed
                }).to(beEmpty())
            }

            it("keeps a timed-out load failed when its artifact arrives later") { @MainActor in
                let flow = makeFlow(id: "flow-timeout")
                let loader = ControlledFlowArtifactLoader()
                let viewModel = FlowViewModel(
                    flow: flow,
                    artifactStore: FlowArtifactStore(),
                    loadingTimeoutSeconds: 0.01,
                    artifactLoader: { flow in
                        try await loader.load(flow: flow)
                    }
                )
                var loadedBuildIDs: [String] = []
                viewModel.onLoadArtifact = { artifact in
                    loadedBuildIDs.append(artifact.manifest.buildId)
                    viewModel.handleLoadingFinished()
                }

                viewModel.loadFlow()
                await expect { await loader.callCount }
                    .toEventually(equal(1), timeout: .seconds(1))
                await expect { viewModel.currentState }
                    .toEventually(equal(.error), timeout: .seconds(1))

                await loader.succeed(
                    call: 0,
                    with: try makeLoadedArtifact(flow: flow, buildId: "late-build")
                )
                await Task.yield()
                await Task.yield()

                expect(loadedBuildIDs).to(beEmpty())
                expect(viewModel.currentState).to(equal(.error))
                expect(mockEventService.trackedEvents.filter {
                    $0.name == JourneyEvents.flowArtifactLoadFailed
                }.count).to(equal(1))
            }

            it("cancels an active load idempotently and ignores its late result") { @MainActor in
                let flow = makeFlow(id: "flow-cancelled")
                let loader = ControlledFlowArtifactLoader()
                let viewModel = FlowViewModel(
                    flow: flow,
                    artifactStore: FlowArtifactStore(),
                    loadingTimeoutSeconds: 1,
                    artifactLoader: { flow in
                        try await loader.load(flow: flow)
                    }
                )
                var loadedBuildIDs: [String] = []
                viewModel.onLoadArtifact = { artifact in
                    loadedBuildIDs.append(artifact.manifest.buildId)
                }

                viewModel.loadFlow()
                await expect { await loader.callCount }
                    .toEventually(equal(1), timeout: .seconds(1))

                viewModel.cancelLoading()
                viewModel.cancelLoading()
                await loader.succeed(
                    call: 0,
                    with: try makeLoadedArtifact(flow: flow, buildId: "cancelled-build")
                )
                await Task.yield()
                await Task.yield()

                expect(loadedBuildIDs).to(beEmpty())
                expect(viewModel.currentState).to(equal(.loading))
                expect(mockEventService.trackedEvents.filter {
                    $0.name == JourneyEvents.flowArtifactLoadFailed
                }).to(beEmpty())
            }

            it("tracks success once per load attempt") { @MainActor in
                let viewModel = FlowViewModel(
                    flow: makeFlow(),
                    artifactStore: FlowArtifactStore(),
                    artifactTelemetryContext: FlowArtifactTelemetryContext(
                        artifactBuildId: "build-rive"
                    )
                )

                viewModel.handleLoadingFinished()
                viewModel.handleLoadingFinished()

                let successEvents = mockEventService.trackedEvents.filter {
                    $0.name == JourneyEvents.flowArtifactLoadSucceeded
                }
                expect(successEvents.count).to(equal(1))
                let properties = successEvents.first?.properties
                expect(properties?["artifact_build_id"] as? String).to(equal("build-rive"))
            }

            it("tracks failure when no valid content URL exists") { @MainActor in
                let viewModel = FlowViewModel(
                    flow: makeFlow(id: "flow-invalid", url: ""),
                    artifactStore: FlowArtifactStore()
                )

                viewModel.loadFlow()

                await expect {
                    mockEventService.trackedEvents.first {
                        $0.name == JourneyEvents.flowArtifactLoadFailed
                    }
                }.toEventuallyNot(beNil(), timeout: .seconds(2))

                let failureEvent = mockEventService.trackedEvents.first {
                    $0.name == JourneyEvents.flowArtifactLoadFailed
                }
                let properties = failureEvent?.properties
                expect(properties?["artifact_source"] as? String).to(equal("unavailable"))
                expect(properties?["error_message"] as? String).to(contain("Invalid flow artifact URL"))
            }
        }
    }
}

private actor ControlledFlowArtifactLoader {
    private var continuations: [Int: CheckedContinuation<LoadedFlowArtifact, Error>] = [:]
    private(set) var callCount = 0

    func load(flow: Flow) async throws -> LoadedFlowArtifact {
        _ = flow
        let call = callCount
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func succeed(call: Int, with artifact: LoadedFlowArtifact) {
        continuations.removeValue(forKey: call)?.resume(returning: artifact)
    }
}

@MainActor
private func makeLoadedArtifact(
    flow: Flow,
    buildId: String
) throws -> LoadedFlowArtifact {
    let manifestData = Data("""
    {
      "version": 1,
      "flowId": "\(flow.id)",
      "buildId": "\(buildId)",
      "renderer": "nuxie-runtime",
      "riv": {
        "path": "flow.riv",
        "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
        "sizeBytes": 1
      },
      "entry": {
        "screenId": "screen-1",
        "artboardId": "screen-1",
        "artboardName": "Screen 1",
        "width": 390,
        "height": 844
      },
      "screens": [
        {
          "screenId": "screen-1",
          "artboardId": "screen-1",
          "artboardName": "Screen 1",
          "width": 390,
          "height": 844
        }
      ],
      "assets": { "images": [], "fonts": [] },
      "textInputs": []
    }
    """.utf8)
    let manifest = try JSONDecoder().decode(FlowArtifactManifest.self, from: manifestData)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("flow-view-model-\(buildId)", isDirectory: true)
    return LoadedFlowArtifact(
        flow: flow,
        directoryURL: root,
        rivURL: root.appendingPathComponent("flow.riv"),
        manifestURL: root.appendingPathComponent("nuxie-manifest.json"),
        manifest: manifest,
        assetURLsByRiveUniqueName: [:],
        source: .cachedArtifact,
        authorizationEvidence: FlowRuntimeAuthorizationEvidence(
            signedContentBytes: manifestData,
            signatureEnvelopeBytes: nil,
            selectedKey: nil
        )
    )
}
