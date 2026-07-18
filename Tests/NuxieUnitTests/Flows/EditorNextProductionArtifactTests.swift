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

    func testExactProductionEnvelopeLoadsNamedArtboardAndExternalImage() throws {
        guard let rootPath = ProcessInfo.processInfo.environment[
            Self.artifactRootEnvironmentKey
        ], !rootPath.isEmpty else {
            throw XCTSkip(
                "Run pnpm run editor-next:ios-artifact:test " +
                    "to provide an exact editor-next production envelope."
            )
        }

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let bundleURL = rootURL.appendingPathComponent("bundle", isDirectory: true)
        let envelopeData = try Data(
            contentsOf: rootURL.appendingPathComponent("production-envelope.json")
        )
        let sourcePayload = try Data(
            contentsOf: rootURL.appendingPathComponent("publish-snapshot.json")
        )
        let envelope = try JSONDecoder().decode(
            ProductionArtifactEnvelope.self,
            from: envelopeData
        )

        XCTAssertEqual(
            envelope.schemaVersion,
            "nuxie-rive-production-artifact-envelope.v1"
        )
        XCTAssertEqual(envelope.source.headSeq, 1801)
        XCTAssertEqual(
            envelope.source.snapshotR2Key,
            "publish-snapshots/editor-next-ios-production/snapshot-1801.json"
        )
        XCTAssertEqual(envelope.source.snapshotPayloadSizeBytes, sourcePayload.count)
        XCTAssertEqual(
            envelope.source.snapshotPayloadSha256,
            FlowArtifactStore.sha256Hex(sourcePayload)
        )
        XCTAssertEqual(envelope.transport.schemaVersion, "compiler-artifact-envelope.v1")
        XCTAssertEqual(envelope.transport.totalFiles, envelope.transport.files.count)

        let paths = try Self.recursiveFilePaths(in: bundleURL)
        XCTAssertEqual(paths, Set(envelope.transport.files.map(\.path)))

        var bytesByPath: [String: Data] = [:]
        for file in envelope.transport.files {
            let bytes = try Data(contentsOf: bundleURL.appendingPathComponent(file.path))
            bytesByPath[file.path] = bytes
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
            Self.canonicalTransportHash(files: envelope.transport.files, bytesByPath: bytesByPath)
        )

        XCTAssertEqual(envelope.manifest.path, "nuxie-manifest.json")
        XCTAssertEqual(envelope.riv.path, "flow.riv")
        XCTAssertNil(envelope.manifestSignature)
        let manifestBytes = try XCTUnwrap(bytesByPath[envelope.manifest.path])
        let manifest = try JSONDecoder().decode(FlowArtifactManifest.self, from: manifestBytes)
        XCTAssertEqual(manifest, envelope.manifest.value)
        XCTAssertEqual(manifest.flowId, "editor-next-ios-production")
        XCTAssertEqual(manifest.buildId, "editor-next-ios-production-build")
        XCTAssertEqual(manifest.renderer, "rive")
        XCTAssertEqual(manifest.riv.path, envelope.riv.path)

        let rivBytes = try XCTUnwrap(bytesByPath[envelope.riv.path])
        XCTAssertEqual(manifest.riv.sizeBytes, rivBytes.count)
        XCTAssertEqual(manifest.riv.sha256, FlowArtifactStore.sha256Hex(rivBytes))
        XCTAssertEqual(envelope.externalAssets.images.count, 1)
        XCTAssertTrue(envelope.externalAssets.fonts.isEmpty)

        let externalImage = try XCTUnwrap(envelope.externalAssets.images.first)
        let manifestImage = try XCTUnwrap(manifest.assets.images.first)
        XCTAssertEqual(externalImage.identity, manifestImage)
        XCTAssertEqual(externalImage.filePath, manifestImage.path)
        let externalImageBytes = try XCTUnwrap(bytesByPath[externalImage.filePath])
        XCTAssertEqual(externalImageBytes.count, 83)
        XCTAssertEqual(
            FlowArtifactStore.sha256Hex(externalImageBytes),
            externalImage.identity.sha256
        )

        var loadedAssetNames: [String] = []
        let file = try RiveFile(
            data: rivBytes,
            loadCdn: false,
            customAssetLoader: { asset, _, factory in
                let uniqueName = asset.uniqueName()
                guard let identity = manifest.assets.images.first(where: {
                    $0.riveUniqueName == uniqueName
                }), let bytes = bytesByPath[identity.path],
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
        try model.setArtboard(manifest.entry.artboardName)
        let artboard = try XCTUnwrap(model.artboard)
        XCTAssertEqual(Double(artboard.bounds().width), manifest.entry.width, accuracy: 0.001)
        XCTAssertEqual(Double(artboard.bounds().height), manifest.entry.height, accuracy: 0.001)

        let viewModel = RiveViewModel(
            model,
            animationName: nil,
            fit: .contain,
            alignment: .center,
            autoPlay: false,
            artboardName: manifest.entry.artboardName
        )
        let view = viewModel.createRiveView()
        view.frame = CGRect(
            x: 0,
            y: 0,
            width: manifest.entry.width,
            height: manifest.entry.height
        )
        // This fixture is static: these calls prove the exact artifact is
        // accepted by the native frame API, not observable animation parity.
        view.advance(delta: 0)
        view.advance(delta: 1 / 60)

        try Data("verified\n".utf8).write(
            to: rootURL.appendingPathComponent("ios-native-consumed.ok"),
            options: .atomic
        )
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
        let bundleURL = rootURL.appendingPathComponent("bundle", isDirectory: true)
        let envelope = try JSONDecoder().decode(
            ProductionArtifactEnvelope.self,
            from: Data(
                contentsOf: rootURL.appendingPathComponent("production-envelope.json")
            )
        )
        let buildManifest = BuildManifest(
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
        let flow = Flow(
            remoteFlow: RemoteFlow(
                id: envelope.manifest.value.flowId,
                flowArtifact: FlowArtifact(
                    url: bundleURL.absoluteString,
                    buildId: envelope.manifest.value.buildId,
                    manifest: buildManifest
                ),
                screens: envelope.manifest.value.screens.map { screen in
                    RemoteFlowScreen(id: screen.screenId)
                }
            )
        )

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

        let image = try XCTUnwrap(envelope.manifest.value.assets.images.first)
        let preparedImageURL = try XCTUnwrap(
            downloaded.localAssetURL(forRiveUniqueName: image.riveUniqueName)
        )
        XCTAssertEqual(
            try Data(contentsOf: preparedImageURL),
            try Data(contentsOf: bundleURL.appendingPathComponent(image.path))
        )

        let cached = try await artifactStore.getOrDownloadArtifact(for: flow)
        XCTAssertEqual(cached.source, .cachedArtifact)
        XCTAssertEqual(cached.manifest, downloaded.manifest)
        XCTAssertEqual(
            try Data(contentsOf: cached.rivURL),
            try Data(contentsOf: downloaded.rivURL)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: try XCTUnwrap(
                    cached.localAssetURL(forRiveUniqueName: image.riveUniqueName)
                )
            ),
            try Data(contentsOf: preparedImageURL)
        )

        let controller = try FlowScreenViewController(
            flow: flow,
            artifact: cached,
            screen: cached.manifest.entry,
            delegate: nil
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(
            x: 0,
            y: 0,
            width: cached.manifest.entry.width,
            height: cached.manifest.entry.height
        )
        controller.view.layoutIfNeeded()
        // This fixture is static: these calls prove the shipped controller
        // accepts frame advancement, not that time changes rendered state.
        controller.advance(delta: 0)
        controller.advance(delta: 1 / 60)

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
            Set([image.riveUniqueName])
        )

        try Data("verified\n".utf8).write(
            to: rootURL.appendingPathComponent("ios-sdk-pipeline-consumed.ok"),
            options: .atomic
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
