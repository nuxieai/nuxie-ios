#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import UIKit
import XCTest
@testable import Nuxie

@MainActor
final class EditorNextNativeArtifactTests: XCTestCase {
    private static let artifactRootEnvironmentKey =
        "NUXIE_EDITOR_NEXT_IOS_PRODUCTION_ARTIFACT_DIR"

    func testExactP17MultiScreenEnvelopeImportsNamedArtboardsAndRenders() async throws {
        let rootURL = try Self.requiredArtifactRoot()
        let corpus = try Self.decode(
            NativeCorpusManifest.self,
            at: rootURL.appendingPathComponent("native-corpus-manifest.json")
        )
        XCTAssertEqual(corpus.schemaVersion, "nuxie-editor-next-native-corpus.v1")

        let corpusEntry = try XCTUnwrap(
            corpus.entries.first(where: { $0.id == "multi-screen" })
        )
        XCTAssertEqual(
            Set(corpusEntry.consumerExpectations.ios),
            ["import", "named-artboard", "mount", "all-manifest-screens"]
        )
        XCTAssertEqual(corpusEntry.screens.map(\.artboardName), ["One", "Two"])

        let entryRoot = rootURL.appendingPathComponent(
            corpusEntry.directory,
            isDirectory: true
        )
        let envelope = try Self.decode(
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
        XCTAssertTrue(manifest.assets.images.isEmpty)
        XCTAssertTrue(manifest.assets.fonts.isEmpty)

        let artifactBytes = try XCTUnwrap(roleBytesByPath[envelope.riv.path])
        XCTAssertEqual(artifactBytes.count, manifest.riv.sizeBytes)
        XCTAssertEqual(ExperienceArtifactStore.sha256Hex(artifactBytes), manifest.riv.sha256)

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
            assetURLsByRiveUniqueName: [:]
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

        for screen in manifest.screens {
            try await Self.assertNamedScreenRenders(
                screen,
                in: context
            )
        }

        try Self.writeNativeConsumerSentinel(to: rootURL)
    }

    private static func assertNamedScreenRenders(
        _ screen: FlowArtifactScreen,
        in context: FlowRuntimeContext
    ) async throws {
        let session = try await context.makeSession(
            descriptor: FlowRenderSessionDescriptor(
                artboardName: screen.artboardName
            )
        )
        defer { session.dispose() }

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
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

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
        defer { surface.dispose() }

        let drawable = try XCTUnwrap(
            surfaceView.metalLayer.nextDrawable(),
            "Shipped NuxieRuntime surface did not vend a drawable for \(screen.artboardName)"
        )
        let result = try await session.perform(
            .advanceAndRender(
                FlowRuntimeFrameTime(timestamp: 1, delta: 0)
            ),
            drawable: surface.makeDrawableTarget(drawable, onCompleted: {})
        )
        XCTAssertEqual(result.renderOutcome, .presented)
        XCTAssertEqual(result.surfaceDisposition, .presented)
        XCTAssertEqual(session.readiness, .ready)
        XCTAssertFalse(result.diagnostics.contains(where: { $0.severity == .fatal }))
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
                    filename: "ios-native-consumed.ok",
                    consumer: "ios-native-runtime"
                )
            )
        )

        let sentinel = ArtifactSentinel(
            schemaVersion: run.sentinelSchemaVersion,
            runId: run.runId,
            consumer: "ios-native-runtime"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var bytes = try encoder.encode(sentinel)
        bytes.append(0x0a)
        try bytes.write(
            to: rootURL.appendingPathComponent("ios-native-consumed.ok"),
            options: .atomic
        )
    }
}

private enum NativeArtifactFixtureError: LocalizedError {
    case missingArtifactRoot(String)

    var errorDescription: String? {
        switch self {
        case .missingArtifactRoot(let path):
            "Exact Editor Next production artifact root is missing: \(path)"
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

private struct ProductionEnvelope: Decodable {
    let schemaVersion: String
    let source: ProductionArtifactSource
    let transport: ProductionTransport
    let manifest: ProductionManifestRole
    let riv: ProductionRivRole
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
    let totalFiles: Int
    let totalSize: Int
    let files: [ProductionTransportFile]
}

private struct ProductionTransportFile: Decodable {
    let path: String
    let sha256: String
    let sizeBytes: Int
    let bytesBase64: String
}

private struct ProductionManifestRole: Decodable {
    let path: String
    let value: FlowArtifactManifest
}

private struct ProductionRivRole: Decodable {
    let path: String
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
