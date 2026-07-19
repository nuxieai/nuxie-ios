import Foundation
import Nimble
import Quick
@testable import Nuxie

final class FlowRuntimeArtifactAdapterTests: QuickSpec {
    override class func spec() {
        describe("FlowRuntimeArtifactAdapter") {
            it("materializes container-neutral assets in manifest order") {
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

                expect(request.expectedIdentity).to(
                    equal(
                        FlowRuntimeArtifactIdentity(
                            flowId: "acquired-flow",
                            buildId: "acquired-build"
                        )
                    )
                )
                expect(request.authorizationEvidence).to(equal(evidence))
                expect(request.externalAssets.map(\.riveUniqueName))
                    .to(equal(["hero-7", "badge-8"]))
                expect(request.externalAssets.map(\.content)).to(
                    equal([.bytes(requiredBytes), .omittedOptional])
                )
                expect(request.externalAssets.map(\.required)).to(equal([true, false]))

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
                    manifestURL: temporaryDirectory.appendingPathComponent(
                        "nuxie-manifest.json"
                    ),
                    manifest: manifest,
                    assetURLsByRiveUniqueName: ["hero-7": requiredURL],
                    source: .cachedArtifact,
                    authorizationEvidence: evidence
                )

                expect(
                    try FlowRuntimeArtifactAdapter.makeImportRequest(from: loadedArtifact)
                        .expectedIdentity
                ).to(
                    equal(
                        FlowRuntimeArtifactIdentity(
                            flowId: "acquired-flow",
                            buildId: "acquired-build"
                        )
                    )
                )
            }

            it("rejects a required asset that was not prepared") {
                let manifest = try Self.manifest(
                    requiredHash: String(repeating: "a", count: 64),
                    optionalHash: String(repeating: "b", count: 64)
                )

                expect {
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
                }.to(
                    throwError(
                        FlowRuntimeArtifactAdapterError.missingRequiredAsset("hero-7")
                    )
                )
            }

            it("enforces the running asset budget before further hashing") {
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

                expect {
                    try FlowRuntimeArtifactAdapter.makeImportRequest(
                        artifactBytes: arguments.artifactBytes,
                        manifest: manifest,
                        expectedIdentity: arguments.expectedIdentity,
                        authorizationEvidence: arguments.evidence,
                        assetURLsByRiveUniqueName: arguments.urls,
                        externalAssetByteLimit: 6
                    )
                }.notTo(throwError())
                expect {
                    try FlowRuntimeArtifactAdapter.makeImportRequest(
                        artifactBytes: arguments.artifactBytes,
                        manifest: manifest,
                        expectedIdentity: arguments.expectedIdentity,
                        authorizationEvidence: arguments.evidence,
                        assetURLsByRiveUniqueName: arguments.urls,
                        externalAssetByteLimit: 5
                    )
                }.to(
                    throwError(
                        FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "aggregate external asset bytes",
                            actual: 6,
                            limit: 5
                        )
                    )
                )
            }

            it("omits an oversized optional asset without starving a later required asset") {
                let optionalBytes = Data([1, 2, 3, 4])
                let requiredBytes = Data([5])
                let manifest = try Self.manifest(
                    requiredHash: FlowArtifactStore.sha256Hex(optionalBytes),
                    optionalHash: FlowArtifactStore.sha256Hex(requiredBytes),
                    firstRequired: false,
                    secondRequired: true
                )
                let temporaryDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: temporaryDirectory,
                    withIntermediateDirectories: true
                )
                defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
                let optionalURL = temporaryDirectory.appendingPathComponent("optional.png")
                let requiredURL = temporaryDirectory.appendingPathComponent("required.png")
                try optionalBytes.write(to: optionalURL)
                try requiredBytes.write(to: requiredURL)

                var request: FlowRuntimeImportRequest?
                expect {
                    request = try FlowRuntimeArtifactAdapter.makeImportRequest(
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
                        assetURLsByRiveUniqueName: [
                            "hero-7": optionalURL,
                            "badge-8": requiredURL,
                        ],
                        externalAssetByteLimit: 3
                    )
                }.notTo(throwError())
                expect(request?.externalAssets.map(\.riveUniqueName))
                    .to(equal(["hero-7", "badge-8"]))
                expect(request?.externalAssets.map(\.content))
                    .to(equal([.omittedOptional, .bytes(requiredBytes)]))
            }

            it("omits an oversized optional asset without starving a later optional asset") {
                let oversizedBytes = Data([1, 2, 3, 4])
                let validBytes = Data([5])
                let manifest = try Self.manifest(
                    requiredHash: FlowArtifactStore.sha256Hex(oversizedBytes),
                    optionalHash: FlowArtifactStore.sha256Hex(validBytes),
                    firstRequired: false,
                    secondRequired: false
                )
                let temporaryDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: temporaryDirectory,
                    withIntermediateDirectories: true
                )
                defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
                let oversizedURL = temporaryDirectory.appendingPathComponent("oversized.png")
                let validURL = temporaryDirectory.appendingPathComponent("valid.png")
                try oversizedBytes.write(to: oversizedURL)
                try validBytes.write(to: validURL)

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
                    assetURLsByRiveUniqueName: [
                        "hero-7": oversizedURL,
                        "badge-8": validURL,
                    ],
                    externalAssetByteLimit: 1
                )

                expect(request.externalAssets.map(\.content))
                    .to(equal([.omittedOptional, .bytes(validBytes)]))
            }

            it("omits an invalid optional asset without consuming the later optional content budget") {
                let invalidBytes = Data([1])
                let validBytes = Data([2])
                let manifest = try Self.manifest(
                    requiredHash: String(repeating: "0", count: 64),
                    optionalHash: FlowArtifactStore.sha256Hex(validBytes),
                    firstRequired: false,
                    secondRequired: false
                )
                let temporaryDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: temporaryDirectory,
                    withIntermediateDirectories: true
                )
                defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
                let invalidURL = temporaryDirectory.appendingPathComponent("invalid.png")
                let validURL = temporaryDirectory.appendingPathComponent("valid.png")
                try invalidBytes.write(to: invalidURL)
                try validBytes.write(to: validURL)

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
                    assetURLsByRiveUniqueName: [
                        "hero-7": invalidURL,
                        "badge-8": validURL,
                    ],
                    externalAssetByteLimit: 1
                )

                expect(request.externalAssets.map(\.content))
                    .to(equal([.omittedOptional, .bytes(validBytes)]))
            }

            it("omits an unreadable optional asset without starving a later required asset") {
                let requiredBytes = Data([5])
                let manifest = try Self.manifest(
                    requiredHash: String(repeating: "a", count: 64),
                    optionalHash: FlowArtifactStore.sha256Hex(requiredBytes),
                    firstRequired: false,
                    secondRequired: true
                )
                let temporaryDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: temporaryDirectory,
                    withIntermediateDirectories: true
                )
                defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
                let unreadableURL = temporaryDirectory.appendingPathComponent("missing.png")
                let requiredURL = temporaryDirectory.appendingPathComponent("required.png")
                try requiredBytes.write(to: requiredURL)

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
                    assetURLsByRiveUniqueName: [
                        "hero-7": unreadableURL,
                        "badge-8": requiredURL,
                    ],
                    externalAssetByteLimit: 1
                )

                expect(request.externalAssets.map(\.riveUniqueName))
                    .to(equal(["hero-7", "badge-8"]))
                expect(request.externalAssets.map(\.content))
                    .to(equal([.omittedOptional, .bytes(requiredBytes)]))
            }

            it("rejects more assets than the native ABI allows before preparation") {
                let manifest = try Self.manifest(
                    imageCount: FlowRuntimeImportLimits.externalAssetCount + 1
                )

                expect {
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
                }.to(
                    throwError(
                        FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "external asset count",
                            actual: FlowRuntimeImportLimits.externalAssetCount + 1,
                            limit: FlowRuntimeImportLimits.externalAssetCount
                        )
                    )
                )
            }

            it("rejects oversized asset metadata before opening asset files") {
                let oversizedName = String(
                    repeating: "n",
                    count: FlowRuntimeImportLimits.selectorBytes + 1
                )
                let manifest = try Self.manifest(
                    requiredHash: String(repeating: "a", count: 64),
                    optionalHash: String(repeating: "b", count: 64),
                    requiredUniqueName: oversizedName
                )
                let missingURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)

                expect {
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
                        assetURLsByRiveUniqueName: [oversizedName: missingURL]
                    )
                }.to(
                    throwError(
                        FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "external asset 0 unique name",
                            actual: FlowRuntimeImportLimits.selectorBytes + 1,
                            limit: FlowRuntimeImportLimits.selectorBytes
                        )
                    )
                )
            }

            it("allows exactly 1,024 optional assets at the native limit") {
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

                expect(request.externalAssets.count)
                    .to(equal(FlowRuntimeImportLimits.externalAssetCount))
                expect(request.externalAssets.allSatisfy { $0.content == .omittedOptional })
                    .to(beTrue())
            }
        }
    }

    private static func manifest(
        requiredHash: String,
        optionalHash: String,
        firstRequired: Bool = true,
        secondRequired: Bool = false,
        requiredUniqueName: String = "hero-7"
    ) throws -> FlowArtifactManifest {
        let rivHash = String(repeating: "0", count: 64)
        let json = """
        {
          "version": 1,
          "flowId": "flow-1",
          "buildId": "build-1",
          "renderer": "rive",
          "riv": { "path": "flow.riv", "sha256": "\(rivHash)", "sizeBytes": 3 },
          "entry": {
            "screenId": "screen-1", "artboardId": "screen-1",
            "artboardName": "Entry", "width": 100, "height": 100
          },
          "screens": [{
            "screenId": "screen-1", "artboardId": "screen-1",
            "artboardName": "Entry", "width": 100, "height": 100
          }],
          "assets": {
            "images": [
              {
                "riveAssetId": 7,
                "riveUniqueName": "\(requiredUniqueName)",
                "sourceAssetKey": "hero",
                "path": "assets/images/hero.png",
                "sha256": "\(requiredHash)",
                "contentType": "image/png",
                "width": 1,
                "height": 1,
                "required": \(firstRequired)
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
          "entry": {
            "screenId": "screen-1", "artboardId": "screen-1",
            "artboardName": "Entry", "width": 100, "height": 100
          },
          "screens": [{
            "screenId": "screen-1", "artboardId": "screen-1",
            "artboardName": "Entry", "width": 100, "height": 100
          }],
          "assets": { "images": [\(images)], "fonts": [] },
          "textInputs": []
        }
        """
        return try JSONDecoder().decode(FlowArtifactManifest.self, from: Data(json.utf8))
    }
}
