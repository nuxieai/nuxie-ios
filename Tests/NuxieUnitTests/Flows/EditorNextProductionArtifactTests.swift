#if canImport(RiveRuntime) && canImport(UIKit)
import Foundation
import RiveRuntime
@testable import Nuxie
import UIKit
import XCTest

@MainActor
final class EditorNextProductionArtifactTests: XCTestCase {
    private static let artifactRootEnvironmentKey =
        "NUXIE_EDITOR_NEXT_IOS_PRODUCTION_ARTIFACT_DIR"

    func testExactProductionEnvelopeLoadsNamedArtboardAndRunsAuthoredStateMachine() throws {
        guard let rootPath = ProcessInfo.processInfo.environment[
            Self.artifactRootEnvironmentKey
        ], !rootPath.isEmpty else {
            throw XCTSkip(
                "Run pnpm run editor-next:ios-artifact:test " +
                    "to provide an exact editor-next production envelope."
            )
        }

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let entry = try Self.verifiedEntry(
            at: rootURL,
            expectedHeadSeq: 1801,
            expectedSourceR2Key:
                "publish-snapshots/editor-next-ios-production/snapshot-1801.json",
            expectedFlowId: "editor-next-ios-production",
            expectedBuildId: "editor-next-ios-production-build"
        )
        XCTAssertTrue(entry.envelope.externalAssets.images.isEmpty)
        XCTAssertTrue(entry.manifest.assets.images.isEmpty)
        XCTAssertTrue(entry.envelope.externalAssets.fonts.isEmpty)
        XCTAssertEqual(entry.manifest.entry.artboardName, "Timeline Screen")

        let rivBytes = try XCTUnwrap(entry.bytesByPath[entry.envelope.riv.path])
        let file = try RiveFile(data: rivBytes, loadCdn: false)

        let model = RiveModel(riveFile: file)
        try model.setArtboard(entry.manifest.entry.artboardName)
        let artboard = try XCTUnwrap(model.artboard)
        XCTAssertEqual(
            Double(artboard.bounds().width),
            entry.manifest.entry.width,
            accuracy: 0.001
        )
        XCTAssertEqual(
            Double(artboard.bounds().height),
            entry.manifest.entry.height,
            accuracy: 0.001
        )

        XCTAssertEqual(artboard.animationNames(), ["Fade Card", "Active Card"])
        XCTAssertEqual(artboard.stateMachineNames(), ["Card machine"])

        let viewModel = RiveViewModel(
            model,
            stateMachineName: "Card machine",
            fit: .contain,
            alignment: .center,
            autoPlay: false,
            artboardName: entry.manifest.entry.artboardName
        )
        let view = viewModel.createRiveView()
        view.frame = CGRect(
            x: 0,
            y: 0,
            width: entry.manifest.entry.width,
            height: entry.manifest.entry.height
        )
        let stateMachine = try XCTUnwrap(model.stateMachine)
        XCTAssertEqual(stateMachine.name(), "Card machine")
        XCTAssertEqual(stateMachine.inputNames(), ["Activate"])
        XCTAssertEqual(stateMachine.reportedEventCount(), 0)
        _ = stateMachine.advance(by: 0)

        let trigger = try XCTUnwrap(stateMachine.getTrigger("Activate"))
        XCTAssertTrue(trigger.isTrigger())
        trigger.fire()
        XCTAssertTrue(
            stateMachine.advance(by: 0),
            "The authored trigger transition must dirty the native render state."
        )
        XCTAssertEqual(stateMachine.reportedEventCount(), 1)
        let event = try XCTUnwrap(stateMachine.reportedEvent(at: 0))
        XCTAssertEqual(event.name(), "Done")
        XCTAssertEqual(event.delay(), 0, accuracy: 0.001)
        XCTAssertFalse(stateMachine.stateChanges().isEmpty)
        XCTAssertTrue(artboard.didChange)
        view.setNeedsDisplay()

        _ = stateMachine.advance(by: 0)
        XCTAssertEqual(
            stateMachine.reportedEventCount(),
            0,
            "Frame-scoped native events must not replay."
        )

        try Data("verified\n".utf8).write(
            to: rootURL.appendingPathComponent("ios-native-consumed.ok"),
            options: .atomic
        )
    }

    func testExactExternalImageCorpusLoadsManifestBytesThroughNativeAssetLoader() throws {
        guard let rootPath = ProcessInfo.processInfo.environment[
            Self.artifactRootEnvironmentKey
        ], !rootPath.isEmpty else {
            throw XCTSkip(
                "Run pnpm run editor-next:ios-artifact:test " +
                    "to provide an exact editor-next production envelope."
            )
        }

        let entry = try Self.verifiedEntry(
            at: URL(fileURLWithPath: rootPath, isDirectory: true)
                .appendingPathComponent("external-image", isDirectory: true),
            expectedHeadSeq: 1802,
            expectedSourceR2Key:
                "publish-snapshots/editor-next-ios-production-image/snapshot-1802.json",
            expectedFlowId: "editor-next-ios-production-image",
            expectedBuildId: "editor-next-ios-production-image-build"
        )
        let externalImage = try XCTUnwrap(entry.envelope.externalAssets.images.first)
        let manifestImage = try XCTUnwrap(entry.manifest.assets.images.first)
        XCTAssertEqual(entry.envelope.externalAssets.images.count, 1)
        XCTAssertEqual(externalImage.identity, manifestImage)
        XCTAssertEqual(externalImage.filePath, manifestImage.path)
        let externalImageBytes = try XCTUnwrap(entry.bytesByPath[externalImage.filePath])
        XCTAssertEqual(externalImageBytes.count, 83)
        XCTAssertEqual(
            FlowArtifactStore.sha256Hex(externalImageBytes),
            externalImage.identity.sha256
        )

        var loadedAssetNames: [String] = []
        let rivBytes = try XCTUnwrap(entry.bytesByPath[entry.envelope.riv.path])
        let file = try RiveFile(
            data: rivBytes,
            loadCdn: false,
            customAssetLoader: { asset, _, factory in
                let uniqueName = asset.uniqueName()
                guard let identity = entry.manifest.assets.images.first(where: {
                    $0.riveUniqueName == uniqueName
                }), let bytes = entry.bytesByPath[identity.path],
                let imageAsset = asset as? RiveImageAsset else {
                    return false
                }
                imageAsset.renderImage(factory.decodeImage(bytes))
                loadedAssetNames.append(uniqueName)
                return true
            }
        )
        XCTAssertEqual(loadedAssetNames, [manifestImage.riveUniqueName])

        let model = RiveModel(riveFile: file)
        try model.setArtboard(entry.manifest.entry.artboardName)
        let viewModel = RiveViewModel(
            model,
            animationName: nil,
            fit: .contain,
            alignment: .center,
            autoPlay: false,
            artboardName: entry.manifest.entry.artboardName
        )
        let view = viewModel.createRiveView()
        view.frame = CGRect(
            x: 0,
            y: 0,
            width: entry.manifest.entry.width,
            height: entry.manifest.entry.height
        )
        view.advance(delta: 0)
    }

    func testExactProductionEnvelopeTraversesShippedArtifactPipeline() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment[
            Self.artifactRootEnvironmentKey
        ], !rootPath.isEmpty else {
            throw XCTSkip(
                "Run pnpm run editor-next:ios-artifact:test " +
                    "to provide an exact editor-next production envelope."
            )
        }

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let entry = try Self.verifiedEntry(
            at: rootURL,
            expectedHeadSeq: 1801,
            expectedSourceR2Key:
                "publish-snapshots/editor-next-ios-production/snapshot-1801.json",
            expectedFlowId: "editor-next-ios-production",
            expectedBuildId: "editor-next-ios-production-build"
        )
        let envelope = entry.envelope
        let bundleURL = entry.bundleURL
        let flow = Self.flow(for: entry)

        XCTAssertTrue(URL(string: flow.url)?.isFileURL == true)
        XCTAssertEqual(flow.id, envelope.manifest.value.flowId)
        XCTAssertEqual(flow.remoteFlow.flowArtifact.buildId, envelope.manifest.value.buildId)
        XCTAssertEqual(flow.manifest.totalFiles, envelope.transport.totalFiles)
        XCTAssertEqual(flow.manifest.totalSize, envelope.transport.totalSize)
        XCTAssertEqual(flow.manifest.contentHash, envelope.transport.contentHash)
        XCTAssertEqual(
            flow.manifest.files,
            envelope.transport.files.map { file in
                BuildFile(
                    path: file.path,
                    size: file.sizeBytes,
                    contentType: file.contentType
                )
            }
        )

        let scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuxie-editor-next-sdk-pipeline")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchURL) }
        let artifactStore = FlowArtifactStore(
            cacheDirectory: scratchURL.appendingPathComponent("artifacts", isDirectory: true),
            runtimeAssetStore: RuntimeAssetStore(
                cacheDirectory: scratchURL.appendingPathComponent("assets", isDirectory: true)
            )
        )

        let downloaded = try await artifactStore.getOrDownloadArtifact(for: flow)
        XCTAssertEqual(downloaded.source, .downloadedArtifact)
        XCTAssertEqual(downloaded.flow.id, flow.id)
        XCTAssertEqual(downloaded.manifest, envelope.manifest.value)
        XCTAssertEqual(
            try Data(contentsOf: downloaded.rivURL),
            try Data(contentsOf: bundleURL.appendingPathComponent(envelope.riv.path))
        )
        XCTAssertEqual(
            try Data(contentsOf: downloaded.manifestURL),
            try Data(contentsOf: bundleURL.appendingPathComponent(envelope.manifest.path))
        )

        let cached = try await artifactStore.getOrDownloadArtifact(for: flow)
        XCTAssertEqual(cached.source, .cachedArtifact)
        XCTAssertEqual(cached.manifest, downloaded.manifest)
        XCTAssertEqual(
            try Data(contentsOf: cached.rivURL),
            try Data(contentsOf: downloaded.rivURL)
        )
        XCTAssertTrue(cached.manifest.assets.images.isEmpty)

        let imageEntry = try Self.verifiedEntry(
            at: rootURL.appendingPathComponent("external-image", isDirectory: true),
            expectedHeadSeq: 1802,
            expectedSourceR2Key:
                "publish-snapshots/editor-next-ios-production-image/snapshot-1802.json",
            expectedFlowId: "editor-next-ios-production-image",
            expectedBuildId: "editor-next-ios-production-image-build"
        )
        let imageFlow = Self.flow(for: imageEntry)
        let downloadedImage = try await artifactStore.getOrDownloadArtifact(for: imageFlow)
        XCTAssertEqual(downloadedImage.source, .downloadedArtifact)
        XCTAssertEqual(downloadedImage.manifest, imageEntry.manifest)
        XCTAssertEqual(
            try Data(contentsOf: downloadedImage.rivURL),
            try XCTUnwrap(imageEntry.bytesByPath[imageEntry.envelope.riv.path])
        )
        let image = try XCTUnwrap(imageEntry.manifest.assets.images.first)
        let preparedImageURL = try XCTUnwrap(
            downloadedImage.localAssetURL(forRiveUniqueName: image.riveUniqueName)
        )
        XCTAssertEqual(
            try Data(contentsOf: preparedImageURL),
            try XCTUnwrap(imageEntry.bytesByPath[image.path])
        )
        let cachedImage = try await artifactStore.getOrDownloadArtifact(for: imageFlow)
        XCTAssertEqual(cachedImage.source, .cachedArtifact)
        XCTAssertEqual(
            try Data(
                contentsOf: try XCTUnwrap(
                    cachedImage.localAssetURL(forRiveUniqueName: image.riveUniqueName)
                )
            ),
            try Data(contentsOf: preparedImageURL)
        )

        let behaviorDelegate = ProductionArtifactScreenDelegate()
        let controller = try FlowScreenViewController(
            flow: flow,
            artifact: cached,
            screen: cached.manifest.entry,
            delegate: behaviorDelegate
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(
            x: 0,
            y: 0,
            width: cached.manifest.entry.width,
            height: cached.manifest.entry.height
        )
        controller.view.layoutIfNeeded()
        XCTAssertNil(controller.activeAnimationName)
        XCTAssertEqual(controller.activeStateMachineName, "Card machine")
        XCTAssertEqual(controller.activeStateMachineInputNames, ["Activate"])
        controller.advance(delta: 0)
        XCTAssertTrue(controller.fireStateMachineTrigger(named: "Activate"))
        XCTAssertFalse(controller.fireStateMachineTrigger(named: "Missing"))
        XCTAssertFalse(controller.activeStateMachineStateChanges.isEmpty)
        XCTAssertTrue(controller.activeArtboardDidChange)
        XCTAssertTrue(behaviorDelegate.events.isEmpty)
        controller.advance(delta: 0)
        XCTAssertEqual(behaviorDelegate.events.map(\.name), ["Done"])
        controller.advance(delta: 0)
        XCTAssertEqual(
            behaviorDelegate.events.map(\.name),
            ["Done"],
            "Frame-scoped events must not replay through the shipped controller."
        )

        XCTAssertEqual(controller.screenId, cached.manifest.entry.screenId)
        XCTAssertEqual(
            controller.view.accessibilityIdentifier,
            "nuxie-screen-controller-\(cached.manifest.entry.screenId)"
        )
        let riveSurface = try XCTUnwrap(
            controller.view.subviews.first(where: {
                $0.accessibilityIdentifier == "nuxie-flow-surface"
            })
        )
        XCTAssertEqual(riveSurface.accessibilityLabel, cached.manifest.entry.screenId)
        XCTAssertFalse(riveSurface.isHidden)
        XCTAssertEqual(
            controller.activeArtboardName,
            cached.manifest.entry.artboardName
        )
        let artboardBounds = try XCTUnwrap(controller.activeArtboardBounds)
        XCTAssertEqual(
            Double(artboardBounds.width),
            cached.manifest.entry.width,
            accuracy: 0.001
        )
        XCTAssertEqual(
            Double(artboardBounds.height),
            cached.manifest.entry.height,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.loadedRiveAssetUniqueNames,
            []
        )

        let imageDelegate = ProductionArtifactScreenDelegate()
        let imageController = try FlowScreenViewController(
            flow: imageFlow,
            artifact: cachedImage,
            screen: cachedImage.manifest.entry,
            delegate: imageDelegate
        )
        imageController.loadViewIfNeeded()
        imageController.view.frame = CGRect(
            x: 0,
            y: 0,
            width: cachedImage.manifest.entry.width,
            height: cachedImage.manifest.entry.height
        )
        imageController.view.layoutIfNeeded()

        XCTAssertEqual(
            imageController.loadedRiveAssetUniqueNames,
            Set([image.riveUniqueName])
        )
        XCTAssertEqual(imageController.screenId, cachedImage.manifest.entry.screenId)
        XCTAssertEqual(
            imageController.activeArtboardName,
            cachedImage.manifest.entry.artboardName
        )
        let imageArtboardBounds = try XCTUnwrap(imageController.activeArtboardBounds)
        XCTAssertEqual(
            Double(imageArtboardBounds.width),
            cachedImage.manifest.entry.width,
            accuracy: 0.001
        )
        XCTAssertEqual(
            Double(imageArtboardBounds.height),
            cachedImage.manifest.entry.height,
            accuracy: 0.001
        )
        let imageSurface = try XCTUnwrap(
            imageController.view.subviews.first(where: {
                $0.accessibilityIdentifier == "nuxie-flow-surface"
            })
        )
        XCTAssertEqual(imageSurface.accessibilityLabel, cachedImage.manifest.entry.screenId)
        XCTAssertFalse(imageSurface.isHidden)
        XCTAssertEqual(imageSurface.frame, imageController.view.bounds)
        let imageAdvanceCount = imageDelegate.advanceCount
        imageController.advance(delta: 0)
        XCTAssertGreaterThan(imageDelegate.advanceCount, imageAdvanceCount)

        try Data("verified\n".utf8).write(
            to: rootURL.appendingPathComponent("ios-sdk-pipeline-consumed.ok"),
            options: .atomic
        )
    }

    private struct VerifiedEntry {
        let bundleURL: URL
        let envelope: ProductionArtifactEnvelope
        let manifest: FlowArtifactManifest
        let bytesByPath: [String: Data]
    }

    private static func verifiedEntry(
        at rootURL: URL,
        expectedHeadSeq: Int,
        expectedSourceR2Key: String,
        expectedFlowId: String,
        expectedBuildId: String
    ) throws -> VerifiedEntry {
        let bundleURL = rootURL.appendingPathComponent("bundle", isDirectory: true)
        let sourcePayload = try Data(
            contentsOf: rootURL.appendingPathComponent("publish-snapshot.json")
        )
        let envelope = try JSONDecoder().decode(
            ProductionArtifactEnvelope.self,
            from: Data(
                contentsOf: rootURL.appendingPathComponent("production-envelope.json")
            )
        )

        XCTAssertEqual(
            envelope.schemaVersion,
            "nuxie-rive-production-artifact-envelope.v1"
        )
        XCTAssertEqual(envelope.source.headSeq, expectedHeadSeq)
        XCTAssertEqual(envelope.source.snapshotR2Key, expectedSourceR2Key)
        XCTAssertEqual(envelope.source.snapshotPayloadSizeBytes, sourcePayload.count)
        XCTAssertEqual(
            envelope.source.snapshotPayloadSha256,
            FlowArtifactStore.sha256Hex(sourcePayload)
        )
        let sourceObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sourcePayload) as? [String: Any]
        )
        XCTAssertEqual(sourceObject["headSeq"] as? Int, envelope.source.headSeq)
        XCTAssertEqual(envelope.transport.schemaVersion, "compiler-artifact-envelope.v1")
        XCTAssertEqual(envelope.transport.manifestVersion, 1)
        XCTAssertEqual(envelope.transport.totalFiles, envelope.transport.files.count)
        XCTAssertEqual(
            try recursiveFilePaths(in: bundleURL),
            Set(envelope.transport.files.map(\.path))
        )

        var bytesByPath: [String: Data] = [:]
        for file in envelope.transport.files {
            let bytes = try Data(contentsOf: bundleURL.appendingPathComponent(file.path))
            XCTAssertNil(bytesByPath.updateValue(bytes, forKey: file.path), file.path)
            XCTAssertEqual(bytes.count, file.sizeBytes, file.path)
            XCTAssertEqual(FlowArtifactStore.sha256Hex(bytes), file.sha256, file.path)
            XCTAssertEqual(Data(base64Encoded: file.bytesBase64), bytes, file.path)
        }
        XCTAssertEqual(
            envelope.transport.totalSize,
            bytesByPath.values.reduce(0) { $0 + $1.count }
        )
        XCTAssertEqual(
            envelope.transport.contentHash,
            canonicalTransportHash(
                files: envelope.transport.files,
                bytesByPath: bytesByPath
            )
        )

        XCTAssertEqual(envelope.manifest.path, "nuxie-manifest.json")
        XCTAssertEqual(envelope.riv.path, "flow.riv")
        XCTAssertNil(envelope.manifestSignature)
        let manifestBytes = try XCTUnwrap(bytesByPath[envelope.manifest.path])
        let manifest = try JSONDecoder().decode(FlowArtifactManifest.self, from: manifestBytes)
        XCTAssertEqual(manifest, envelope.manifest.value)
        XCTAssertEqual(manifest.flowId, expectedFlowId)
        XCTAssertEqual(manifest.buildId, expectedBuildId)
        XCTAssertEqual(manifest.renderer, "rive")
        XCTAssertEqual(manifest.riv.path, envelope.riv.path)
        XCTAssertTrue(
            envelope.source.snapshotR2Key.hasPrefix("publish-snapshots/\(manifest.flowId)/")
        )
        XCTAssertTrue(
            envelope.source.snapshotR2Key.hasSuffix("-\(expectedHeadSeq).json")
        )

        let rivBytes = try XCTUnwrap(bytesByPath[envelope.riv.path])
        XCTAssertEqual(manifest.riv.sizeBytes, rivBytes.count)
        XCTAssertEqual(manifest.riv.sha256, FlowArtifactStore.sha256Hex(rivBytes))
        XCTAssertEqual(
            manifest.assets.images,
            envelope.externalAssets.images.map(\.identity)
        )
        XCTAssertEqual(manifest.assets.fonts, envelope.externalAssets.fonts)
        var claimedPaths = Set([envelope.manifest.path, envelope.riv.path])
        for image in envelope.externalAssets.images {
            XCTAssertEqual(image.filePath, image.identity.path)
            XCTAssertEqual(
                image.filePath,
                "assets/images/\(image.identity.sha256).png"
            )
            let bytes = try XCTUnwrap(bytesByPath[image.filePath])
            XCTAssertEqual(FlowArtifactStore.sha256Hex(bytes), image.identity.sha256)
            let transportFile = try XCTUnwrap(
                envelope.transport.files.first(where: { $0.path == image.filePath })
            )
            XCTAssertEqual(transportFile.sha256, image.identity.sha256)
            XCTAssertEqual(transportFile.contentType, image.identity.contentType)
            XCTAssertEqual(transportFile.sizeBytes, bytes.count)
            XCTAssertTrue(image.identity.required)
            XCTAssertTrue(claimedPaths.insert(image.filePath).inserted)
        }
        XCTAssertEqual(claimedPaths, Set(envelope.transport.files.map(\.path)))

        return VerifiedEntry(
            bundleURL: bundleURL,
            envelope: envelope,
            manifest: manifest,
            bytesByPath: bytesByPath
        )
    }

    private static func flow(for entry: VerifiedEntry) -> Flow {
        let envelope = entry.envelope
        return Flow(
            remoteFlow: RemoteFlow(
                id: entry.manifest.flowId,
                flowArtifact: FlowArtifact(
                    url: entry.bundleURL.absoluteString,
                    buildId: entry.manifest.buildId,
                    manifest: BuildManifest(
                        totalFiles: envelope.transport.totalFiles,
                        totalSize: envelope.transport.totalSize,
                        contentHash: envelope.transport.contentHash,
                        files: envelope.transport.files.map { file in
                            BuildFile(
                                path: file.path,
                                size: file.sizeBytes,
                                contentType: file.contentType
                            )
                        }
                    )
                ),
                screens: entry.manifest.screens.map { screen in
                    RemoteFlowScreen(id: screen.screenId)
                }
            )
        )
    }

    private static func recursiveFilePaths(in rootURL: URL) throws -> Set<String> {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys)
        ) else {
            XCTFail("Could not enumerate exact production bundle at \(rootURL.path)")
            return []
        }
        var paths: Set<String> = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: resourceKeys)
            guard values.isRegularFile == true else { continue }
            let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
            XCTAssertTrue(url.path.hasPrefix(prefix))
            paths.insert(String(url.path.dropFirst(prefix.count)))
        }
        return paths
    }

    private static func canonicalTransportHash(
        files: [ProductionArtifactEnvelope.Transport.File],
        bytesByPath: [String: Data]
    ) -> String {
        var canonical = Data("nuxie.compiler-artifact-content.v2\0".utf8)
        appendUInt64(UInt64(files.count), to: &canonical)
        for file in files.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            let path = Data(file.path.utf8)
            let bytes = bytesByPath[file.path] ?? Data()
            appendUInt64(UInt64(path.count), to: &canonical)
            canonical.append(path)
            appendUInt64(UInt64(bytes.count), to: &canonical)
            canonical.append(bytes)
        }
        return FlowArtifactStore.sha256Hex(canonical)
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

@MainActor
private final class ProductionArtifactScreenDelegate: FlowScreenViewControllerDelegate {
    private(set) var advanceCount = 0
    private(set) var events: [FlowRendererEvent] = []

    func flowScreenViewControllerDidAdvance(_ controller: FlowScreenViewController) {
        advanceCount += 1
    }

    func flowScreenViewController(
        _ controller: FlowScreenViewController,
        didEmitEvent event: FlowRendererEvent
    ) {
        events.append(event)
    }

    func flowScreenViewController(
        _ controller: FlowScreenViewController,
        didEmitViewModelChange change: FlowRendererViewModelChange
    ) {}

    func flowScreenViewController(
        _ controller: FlowScreenViewController,
        didRequestOpenLink request: FlowRendererOpenLinkRequest
    ) {}
}

private struct ProductionArtifactEnvelope: Decodable {
    struct Source: Decodable {
        let headSeq: Int?
        let snapshotR2Key: String
        let snapshotPayloadSha256: String
        let snapshotPayloadSizeBytes: Int
    }

    struct Transport: Decodable {
        struct File: Decodable {
            let path: String
            let sha256: String
            let sizeBytes: Int
            let contentType: String
            let bytesBase64: String
        }

        let schemaVersion: String
        let manifestVersion: Int?
        let contentHash: String
        let totalFiles: Int
        let totalSize: Int
        let files: [File]
    }

    struct ManifestRole: Decodable {
        let path: String
        let value: FlowArtifactManifest
    }

    struct FileRole: Decodable {
        let path: String
    }

    struct ExternalAssets: Decodable {
        struct Image: Decodable {
            let identity: FlowArtifactImageAsset
            let filePath: String
        }

        let images: [Image]
        let fonts: [FlowArtifactFontAsset]
    }

    let schemaVersion: String
    let source: Source
    let transport: Transport
    let manifest: ManifestRole
    let riv: FileRole
    let manifestSignature: FileRole?
    let externalAssets: ExternalAssets
}
#endif
