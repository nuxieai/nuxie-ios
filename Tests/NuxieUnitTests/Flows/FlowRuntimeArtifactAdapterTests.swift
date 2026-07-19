import Foundation
import XCTest
@testable import Nuxie

final class FlowRuntimeArtifactAdapterTests: XCTestCase {
    func testMaterializesContainerNeutralAssetsInManifestOrder() throws {
        let requiredBytes = Data([0x89, 0x50, 0x4e, 0x47])
        let requiredHash = FlowArtifactStore.sha256Hex(requiredBytes)
        let manifest = try Self.manifest(
            requiredHash: requiredHash,
            optionalHash: String(repeating: "b", count: 64)
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let requiredURL = temporaryDirectory.appendingPathComponent("hero.png")
        try requiredBytes.write(to: requiredURL)
        let rivURL = temporaryDirectory.appendingPathComponent("flow.riv")
        try Data([0x52, 0x49, 0x56]).write(to: rivURL)
        let evidence = FlowRuntimeAuthorizationEvidence(
            signedContentBytes: Data("exact manifest".utf8),
            signatureEnvelopeBytes: nil,
            selectedKey: nil
        )

        let request = try FlowRuntimeArtifactAdapter.makeImportRequest(
            artifactBytes: Data([0x52, 0x49, 0x56]),
            manifest: manifest,
            expectedIdentity: FlowRuntimeArtifactIdentity(
                flowId: "acquired-flow",
                buildId: "acquired-build"
            ),
            authorizationEvidence: evidence,
            assetURLsByRiveUniqueName: ["hero-7": requiredURL]
        )

        XCTAssertEqual(
            request.expectedIdentity,
            FlowRuntimeArtifactIdentity(
                flowId: "acquired-flow",
                buildId: "acquired-build"
            )
        )
        XCTAssertEqual(request.authorizationEvidence, evidence)
        XCTAssertEqual(request.externalAssets.map(\.riveUniqueName), ["hero-7", "badge-8"])
        XCTAssertEqual(
            request.externalAssets.map(\.content),
            [.bytes(requiredBytes), .omittedOptional]
        )
        XCTAssertEqual(request.externalAssets.map(\.required), [true, false])

        let acquisitionFlow = Flow(
            remoteFlow: RemoteFlow(
                id: "acquired-flow",
                flowArtifact: FlowArtifact(
                    url: temporaryDirectory.absoluteString,
                    buildId: "acquired-build",
                    manifest: BuildManifest(
                        totalFiles: 0,
                        totalSize: 0,
                        contentHash: "fixture",
                        files: []
                    )
                ),
                screens: []
            )
        )
        let loadedArtifact = LoadedFlowArtifact(
            flow: acquisitionFlow,
            directoryURL: temporaryDirectory,
            rivURL: rivURL,
            manifestURL: temporaryDirectory.appendingPathComponent("nuxie-manifest.json"),
            manifest: manifest,
            assetURLsByRiveUniqueName: ["hero-7": requiredURL],
            source: .cachedArtifact,
            authorizationEvidence: evidence
        )

        XCTAssertEqual(
            try FlowRuntimeArtifactAdapter.makeImportRequest(from: loadedArtifact)
                .expectedIdentity,
            FlowRuntimeArtifactIdentity(
                flowId: "acquired-flow",
                buildId: "acquired-build"
            )
        )
    }

    func testRejectsARequiredAssetThatWasNotPrepared() throws {
        let manifest = try Self.manifest(
            requiredHash: String(repeating: "a", count: 64),
            optionalHash: String(repeating: "b", count: 64)
        )

        XCTAssertThrowsError(
            try FlowRuntimeArtifactAdapter.makeImportRequest(
                artifactBytes: Data([0x52, 0x49, 0x56]),
                manifest: manifest,
                expectedIdentity: FlowRuntimeArtifactIdentity(
                    flowId: "flow-1",
                    buildId: "build-1"
                ),
                authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                    signedContentBytes: Data(),
                    signatureEnvelopeBytes: nil,
                    selectedKey: nil
                ),
                assetURLsByRiveUniqueName: [:]
            )
        ) { error in
            XCTAssertEqual(
                error as? FlowRuntimeArtifactAdapterError,
                .missingRequiredAsset("hero-7")
            )
        }
    }

    func testEnforcesTheRunningAssetBudgetBeforeFurtherHashing() throws {
        let firstBytes = Data([1, 2, 3])
        let secondBytes = Data([4, 5, 6])
        let manifest = try Self.manifest(
            requiredHash: FlowArtifactStore.sha256Hex(firstBytes),
            optionalHash: FlowArtifactStore.sha256Hex(secondBytes),
            secondRequired: true
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let firstURL = temporaryDirectory.appendingPathComponent("first.png")
        let secondURL = temporaryDirectory.appendingPathComponent("second.png")
        try firstBytes.write(to: firstURL)
        try secondBytes.write(to: secondURL)
        let arguments = (
            artifactBytes: Data([0x52, 0x49, 0x56]),
            expectedIdentity: FlowRuntimeArtifactIdentity(
                flowId: "flow-1",
                buildId: "build-1"
            ),
            evidence: FlowRuntimeAuthorizationEvidence(
                signedContentBytes: Data(),
                signatureEnvelopeBytes: nil,
                selectedKey: nil
            ),
            urls: ["hero-7": firstURL, "badge-8": secondURL]
        )

        XCTAssertNoThrow(
            try FlowRuntimeArtifactAdapter.makeImportRequest(
                artifactBytes: arguments.artifactBytes,
                manifest: manifest,
                expectedIdentity: arguments.expectedIdentity,
                authorizationEvidence: arguments.evidence,
                assetURLsByRiveUniqueName: arguments.urls,
                externalAssetByteLimit: 6
            )
        )
        XCTAssertThrowsError(
            try FlowRuntimeArtifactAdapter.makeImportRequest(
                artifactBytes: arguments.artifactBytes,
                manifest: manifest,
                expectedIdentity: arguments.expectedIdentity,
                authorizationEvidence: arguments.evidence,
                assetURLsByRiveUniqueName: arguments.urls,
                externalAssetByteLimit: 5
            )
        ) { error in
            XCTAssertEqual(
                error as? FlowRuntimeImportValidationError,
                .valueExceedsLimit(
                    field: "aggregate external asset bytes",
                    actual: 6,
                    limit: 5
                )
            )
        }
    }

    func testRejectsMoreAssetsThanTheNativeABIAllowsBeforePreparation() throws {
        let manifest = try Self.manifest(
            imageCount: FlowRuntimeImportLimits.externalAssetCount + 1
        )

        XCTAssertThrowsError(
            try FlowRuntimeArtifactAdapter.makeImportRequest(
                artifactBytes: Data([0x52, 0x49, 0x56]),
                manifest: manifest,
                expectedIdentity: FlowRuntimeArtifactIdentity(
                    flowId: "flow-1",
                    buildId: "build-1"
                ),
                authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                    signedContentBytes: Data(),
                    signatureEnvelopeBytes: nil,
                    selectedKey: nil
                ),
                assetURLsByRiveUniqueName: [:]
            )
        ) { error in
            XCTAssertEqual(
                error as? FlowRuntimeImportValidationError,
                .valueExceedsLimit(
                    field: "external asset count",
                    actual: FlowRuntimeImportLimits.externalAssetCount + 1,
                    limit: FlowRuntimeImportLimits.externalAssetCount
                )
            )
        }
    }

    func testNativeLimitAllowsExactlyOneThousandTwentyFourOptionalAssets() throws {
        let manifest = try Self.manifest(
            imageCount: FlowRuntimeImportLimits.externalAssetCount
        )

        let request = try FlowRuntimeArtifactAdapter.makeImportRequest(
            artifactBytes: Data([0x52, 0x49, 0x56]),
            manifest: manifest,
            expectedIdentity: FlowRuntimeArtifactIdentity(
                flowId: "flow-1",
                buildId: "build-1"
            ),
            authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                signedContentBytes: Data(),
                signatureEnvelopeBytes: nil,
                selectedKey: nil
            ),
            assetURLsByRiveUniqueName: [:]
        )

        XCTAssertEqual(request.externalAssets.count, FlowRuntimeImportLimits.externalAssetCount)
        XCTAssertTrue(request.externalAssets.allSatisfy { $0.content == .omittedOptional })
    }

    private static func manifest(
        requiredHash: String,
        optionalHash: String,
        secondRequired: Bool = false
    ) throws -> FlowArtifactManifest {
        let rivHash = String(repeating: "0", count: 64)
        let json = """
        {
          "version": 1,
          "flowId": "flow-1",
          "buildId": "build-1",
          "renderer": "rive",
          "riv": { "path": "flow.riv", "sha256": "\(rivHash)", "sizeBytes": 3 },
          "entry": { "screenId": "screen-1", "artboardId": "screen-1", "artboardName": "Entry", "width": 100, "height": 100 },
          "screens": [{ "screenId": "screen-1", "artboardId": "screen-1", "artboardName": "Entry", "width": 100, "height": 100 }],
          "assets": {
            "images": [
              {
                "riveAssetId": 7,
                "riveUniqueName": "hero-7",
                "sourceAssetKey": "hero",
                "path": "assets/images/hero.png",
                "sha256": "\(requiredHash)",
                "contentType": "image/png",
                "width": 1,
                "height": 1,
                "required": true
              },
              {
                "riveAssetId": 8,
                "riveUniqueName": "badge-8",
                "sourceAssetKey": "badge",
                "path": "assets/images/badge.png",
                "sha256": "\(optionalHash)",
                "contentType": "image/png",
                "width": 1,
                "height": 1,
                "required": \(secondRequired)
              }
            ],
            "fonts": []
          },
          "textInputs": []
        }
        """
        return try JSONDecoder().decode(FlowArtifactManifest.self, from: Data(json.utf8))
    }

    private static func manifest(imageCount: Int) throws -> FlowArtifactManifest {
        let images = (0..<imageCount).map { index in
            """
            {
              "riveAssetId": \(index),
              "riveUniqueName": "optional-\(index)",
              "sourceAssetKey": "source-\(index)",
              "path": "assets/images/optional-\(index).png",
              "sha256": "\(String(repeating: "a", count: 64))",
              "contentType": "image/png",
              "width": 1,
              "height": 1,
              "required": false
            }
            """
        }.joined(separator: ",")
        let json = """
        {
          "version": 1,
          "flowId": "flow-1",
          "buildId": "build-1",
          "renderer": "rive",
          "riv": { "path": "flow.riv", "sha256": "\(String(repeating: "0", count: 64))", "sizeBytes": 3 },
          "entry": { "screenId": "screen-1", "artboardId": "screen-1", "artboardName": "Entry", "width": 100, "height": 100 },
          "screens": [{ "screenId": "screen-1", "artboardId": "screen-1", "artboardName": "Entry", "width": 100, "height": 100 }],
          "assets": { "images": [\(images)], "fonts": [] },
          "textInputs": []
        }
        """
        return try JSONDecoder().decode(FlowArtifactManifest.self, from: Data(json.utf8))
    }
}
