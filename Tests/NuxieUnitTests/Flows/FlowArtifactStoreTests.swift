import Foundation
import Quick
import Nimble
@testable import Nuxie

final class FlowArtifactStoreTests: AsyncSpec {
    override class func spec() {
        func writeFixtureArtifact(
            flowId: String = "flow-artifact-store",
            buildId: String = "build-1",
            includeImageAsset: Bool = false,
            includeFontAsset: Bool = false,
            fontFormat: String = "ttf",
            fontContentType: String = "font/ttf",
            fontDataOverride: Data? = nil,
            manifestSignatureData: Data? = nil
        ) throws -> (
            baseURL: URL,
            flow: Flow,
            cacheURL: URL,
            runtimeCacheURL: URL,
            rivData: Data,
            imagePath: String?,
            imageData: Data?,
            fontData: Data?
        ) {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("nuxie-flow-artifact-store-tests")
                .appendingPathComponent(UUID().uuidString)
            let remoteURL = rootURL.appendingPathComponent("remote")
            let cacheURL = rootURL.appendingPathComponent("cache")
            let runtimeCacheURL = rootURL.appendingPathComponent("runtime-cache")
            try FileManager.default.createDirectory(at: remoteURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: runtimeCacheURL, withIntermediateDirectories: true)

            let rivData = Data("fake-riv-bytes".utf8)
            let rivSha = FlowArtifactStore.sha256Hex(rivData)
            try rivData.write(to: remoteURL.appendingPathComponent("flow.riv"))

            let imagePath = includeImageAsset ? "assets/images/test-image.bin" : nil
            let imageData = includeImageAsset ? Data("fake-image-bytes".utf8) : nil
            let imageSha = imageData.map(FlowArtifactStore.sha256Hex)
            if let imagePath, let imageData {
                let imageURL = remoteURL.appendingPathComponent(imagePath)
                try FileManager.default.createDirectory(
                    at: imageURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try imageData.write(to: imageURL)
            }

            let fontData: Data?
            if includeFontAsset {
                if let fontDataOverride {
                    fontData = fontDataOverride
                } else {
                    fontData = try publishedFixtureFontData()
                }
            } else {
                fontData = nil
            }
            let fontSha = fontData.map(FlowArtifactStore.sha256Hex)
            let fontURL = remoteURL
                .appendingPathComponent("external-fonts")
                .appendingPathComponent("test-font.\(fontFormat)")
            if let fontData {
                try FileManager.default.createDirectory(
                    at: fontURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fontData.write(to: fontURL)
            }

            var imageAssetEntries: [String] = []
            if let imagePath, let imageSha {
                imageAssetEntries.append("""
                {
                  "riveAssetId": 1,
                  "riveUniqueName": "test-image",
                  "sourceAssetKey": "test-image-source",
                  "path": "\(imagePath)",
                  "sha256": "\(imageSha)",
                  "contentType": "image/png",
                  "width": 1,
                  "height": 1,
                  "required": true
                }
                """)
            }

            var fontAssetEntries: [String] = []
            if let fontData, let fontSha {
                fontAssetEntries.append("""
                {
                  "riveAssetId": 2,
                  "riveUniqueName": "test-font",
                  "requestKey": "Inter:400:normal",
                  "family": "Inter",
                  "weight": "400",
                  "style": "normal",
                  "assetUrl": "\(fontURL.absoluteString)",
                  "sha256": "\(fontSha)",
                  "sizeBytes": \(fontData.count),
                  "contentType": "\(fontContentType)",
                  "format": "\(fontFormat)",
                  "required": true
                }
                """)
            }

            let assetsJSON = """
                {
                  "images": [\(imageAssetEntries.joined(separator: ","))],
                  "fonts": [\(fontAssetEntries.joined(separator: ","))]
                }
                """

            let manifestJSON = """
            {
              "version": 1,
              "flowId": "\(flowId)",
              "buildId": "\(buildId)",
              "renderer": "rive",
              "riv": {
                "path": "flow.riv",
                "sha256": "\(rivSha)",
                "sizeBytes": \(rivData.count)
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
              "assets": \(assetsJSON),
              "textInputs": []
            }
            """.data(using: .utf8)!
            try manifestJSON.write(to: remoteURL.appendingPathComponent("nuxie-manifest.json"))
            if let manifestSignatureData {
                try manifestSignatureData.write(
                    to: remoteURL.appendingPathComponent(FlowArtifactStore.manifestSignaturePath)
                )
            }

            var contentHashData = Data()
            contentHashData.append(rivData)
            contentHashData.append(manifestJSON)
            if let manifestSignatureData {
                contentHashData.append(manifestSignatureData)
            }
            if let imageData {
                contentHashData.append(imageData)
            }

            var buildFiles = [
                BuildFile(
                    path: "flow.riv",
                    size: rivData.count,
                    contentType: "application/octet-stream"
                ),
                BuildFile(
                    path: "nuxie-manifest.json",
                    size: manifestJSON.count,
                    contentType: "application/json"
                ),
            ]
            if let manifestSignatureData {
                buildFiles.append(
                    BuildFile(
                        path: FlowArtifactStore.manifestSignaturePath,
                        size: manifestSignatureData.count,
                        contentType: "application/json"
                    )
                )
            }
            if let imagePath, let imageData {
                buildFiles.append(
                    BuildFile(
                        path: imagePath,
                        size: imageData.count,
                        contentType: "image/png"
                    )
                )
            }

            let buildManifest = BuildManifest(
                totalFiles: buildFiles.count,
                totalSize: buildFiles.reduce(0) { $0 + $1.size },
                contentHash: FlowArtifactStore.sha256Hex(contentHashData),
                files: buildFiles
            )
            let remoteFlow = RemoteFlow(
                id: flowId,
                flowArtifact: FlowArtifact(
                    url: remoteURL.absoluteString,
                    buildId: buildId,
                    manifest: buildManifest
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
            return (
                baseURL: remoteURL,
                flow: Flow(remoteFlow: remoteFlow, products: []),
                cacheURL: cacheURL,
                runtimeCacheURL: runtimeCacheURL,
                rivData: rivData,
                imagePath: imagePath,
                imageData: imageData,
                fontData: fontData
            )
        }

        func publishedFixtureFontData() throws -> Data {
            let testFileURL = URL(fileURLWithPath: #filePath)
            let sdkRootURL = testFileURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let fontURL = sdkRootURL
                .appendingPathComponent("Tests")
                .appendingPathComponent("FlowRuntimeHostApp")
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("published-font")
                .appendingPathComponent("assets")
                .appendingPathComponent("fonts")
                .appendingPathComponent("inter-400-normal.ttf")
            return try Data(contentsOf: fontURL)
        }

        describe("FlowArtifactStore") {
            it("downloads and reuses a verified flow artifact") {
                let fixture = try writeFixtureArtifact()
                let runtimeAssetStore = RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: runtimeAssetStore
                )

                let downloaded = try await store.getOrDownloadArtifact(for: fixture.flow)

                expect(downloaded.source).to(equal(.downloadedArtifact))
                expect(downloaded.manifest.flowId).to(equal(fixture.flow.id))
                expect(downloaded.manifest.entry.artboardName).to(equal("Screen 1"))
                expect(try Data(contentsOf: downloaded.rivURL)).to(equal(fixture.rivData))

                let cached = try await store.getOrDownloadArtifact(for: fixture.flow)
                expect(cached.source).to(equal(.cachedArtifact))
                expect(cached.rivURL.path).to(equal(downloaded.rivURL.path))
            }

            it("downloads and exposes a listed manifest signature artifact") {
                let signatureData = Data(
                    """
                    {
                      "version": 1,
                      "signs": "nuxie-manifest.json",
                      "algorithm": "ed25519",
                      "keyId": "test",
                      "signatureBase64": "abc"
                    }
                    """.utf8
                )
                let fixture = try writeFixtureArtifact(manifestSignatureData: signatureData)
                let runtimeAssetStore = RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: runtimeAssetStore
                )

                let downloaded = try await store.getOrDownloadArtifact(for: fixture.flow)

                expect(downloaded.manifestSignatureURL).toNot(beNil())
                guard let manifestSignatureURL = downloaded.manifestSignatureURL else {
                    fail("Expected manifest signature URL")
                    return
                }
                expect(try Data(contentsOf: manifestSignatureURL)).to(equal(signatureData))
            }

            it("decodes editable text input runtime metadata") {
                let manifest = try JSONDecoder().decode(FlowArtifactManifest.self, from: """
                {
                  "version": 1,
                  "flowId": "flow-1",
                  "buildId": "build-1",
                  "renderer": "rive",
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
                  "textInputs": [
                    {
                      "inputId": "text-input/screen-1/email-input",
                      "screenId": "screen-1",
                      "artboardId": "screen-1",
                      "viewNodeId": "email-input",
                      "renderedNodeId": "email-input",
                      "riveTextObjectKey": "artboard/screen-1/email-input/text",
                      "riveTextRunObjectKey": "artboard/screen-1/email-input/text-run",
                      "riveTextName": "email-input",
                      "riveTextRunName": "email-input Run",
                      "geometry": {
                        "xPath": "nuxieTextInputs/input_email/x",
                        "yPath": "nuxieTextInputs/input_email/y",
                        "widthPath": "nuxieTextInputs/input_email/width",
                        "heightPath": "nuxieTextInputs/input_email/height",
                        "rotationPath": "nuxieTextInputs/input_email/rotation",
                        "scaleXPath": "nuxieTextInputs/input_email/scaleX",
                        "scaleYPath": "nuxieTextInputs/input_email/scaleY"
                      },
                      "style": {
                        "fontFamily": "Inter",
                        "fontWeight": "500",
                        "fontStyle": "normal",
                        "fontSize": 17,
                        "lineHeight": 24,
                        "letterSpacing": 0,
                        "color": 4279179050,
                        "fontAssetRiveUniqueName": "font-inter-500-normal-e57198b3-0",
                        "textAlign": "left"
                      },
                      "value": "levi@nuxie.dev",
                      "placeholder": "you@example.com",
                      "editable": true,
                      "keyboardType": "email-address",
                      "secureTextEntry": false,
                      "multiline": false,
                      "maxLength": 72
                    }
                  ]
                }
                """.data(using: .utf8)!)

                expect(manifest.textInputs).to(haveCount(1))
                expect(manifest.textInputs[0].riveTextRunName).to(equal("email-input Run"))
                expect(manifest.textInputs[0].geometry.xPath).to(equal("nuxieTextInputs/input_email/x"))
                expect(manifest.textInputs[0].style.color).to(equal(0xff0f172a))
                expect(manifest.textInputs[0].style.fontAssetRiveUniqueName).to(equal("font-inter-500-normal-e57198b3-0"))
            }

            it("reuses a shared runtime image cache when the artifact copy is missing") {
                let fixture = try writeFixtureArtifact(includeImageAsset: true)
                let runtimeAssetStore = RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: runtimeAssetStore
                )

                let downloaded = try await store.getOrDownloadArtifact(for: fixture.flow)
                guard let imagePath = fixture.imagePath,
                      let imageData = fixture.imageData,
                      let sharedImageURL = downloaded.localAssetURL(forRiveUniqueName: "test-image") else {
                    fail("Expected image fixture")
                    return
                }

                expect(sharedImageURL.path).to(contain(fixture.runtimeCacheURL.path))
                expect(try Data(contentsOf: sharedImageURL)).to(equal(imageData))

                let artifactImageURL = downloaded.directoryURL.appendingPathComponent(imagePath)
                expect(FileManager.default.fileExists(atPath: artifactImageURL.path)).to(beTrue())
                try FileManager.default.removeItem(at: artifactImageURL)

                let reloaded = try await store.getOrDownloadArtifact(for: fixture.flow)
                expect(reloaded.source).to(equal(.cachedArtifact))
                expect(reloaded.localAssetURL(forRiveUniqueName: "test-image")?.path).to(equal(sharedImageURL.path))
            }

            it("redownloads when a required image is missing from artifact and runtime caches") {
                let fixture = try writeFixtureArtifact(includeImageAsset: true)
                let runtimeAssetStore = RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: runtimeAssetStore
                )

                let downloaded = try await store.getOrDownloadArtifact(for: fixture.flow)
                guard let imagePath = fixture.imagePath,
                      let imageData = fixture.imageData,
                      let sharedImageURL = downloaded.localAssetURL(forRiveUniqueName: "test-image") else {
                    fail("Expected image fixture")
                    return
                }

                let artifactImageURL = downloaded.directoryURL.appendingPathComponent(imagePath)
                try FileManager.default.removeItem(at: artifactImageURL)
                try FileManager.default.removeItem(at: sharedImageURL)

                let reloaded = try await store.getOrDownloadArtifact(for: fixture.flow)
                expect(reloaded.source).to(equal(.downloadedArtifact))
                guard let reloadedImageURL = reloaded.localAssetURL(forRiveUniqueName: "test-image") else {
                    fail("Expected reloaded image URL")
                    return
                }
                expect(try Data(contentsOf: reloadedImageURL)).to(equal(imageData))
            }

            it("downloads manifest fonts into the shared runtime cache") {
                let fixture = try writeFixtureArtifact(includeFontAsset: true)
                let runtimeAssetStore = RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: runtimeAssetStore
                )

                let downloaded = try await store.getOrDownloadArtifact(for: fixture.flow)
                guard let fontData = fixture.fontData,
                      let sharedFontURL = downloaded.localAssetURL(forRiveUniqueName: "test-font") else {
                    fail("Expected font fixture")
                    return
                }

                expect(sharedFontURL.path).to(contain(fixture.runtimeCacheURL.path))
                expect(try Data(contentsOf: sharedFontURL)).to(equal(fontData))

                let cached = try await store.getOrDownloadArtifact(for: fixture.flow)
                expect(cached.source).to(equal(.cachedArtifact))
                expect(cached.localAssetURL(forRiveUniqueName: "test-font")?.path).to(equal(sharedFontURL.path))
            }

            it("rejects unsupported runtime font formats") {
                let fixture = try writeFixtureArtifact(
                    includeFontAsset: true,
                    fontFormat: "woff2",
                    fontContentType: "font/woff2"
                )
                let runtimeAssetStore = RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: runtimeAssetStore
                )

                await expect {
                    try await store.getOrDownloadArtifact(for: fixture.flow)
                }.to(throwError { error in
                    expect(error.localizedDescription).to(contain("Unsupported runtime font format"))
                })
            }

            it("rejects invalid TTF bytes") {
                let fixture = try writeFixtureArtifact(
                    includeFontAsset: true,
                    fontDataOverride: Data("fake-font-bytes".utf8)
                )
                let runtimeAssetStore = RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: runtimeAssetStore
                )

                await expect {
                    try await store.getOrDownloadArtifact(for: fixture.flow)
                }.to(throwError { error in
                    expect(error.localizedDescription).to(contain("Invalid runtime font data"))
                })
            }

            it("rejects unsafe manifest paths") {
                expect {
                    try FlowArtifactStore.validateRelativePath("../flow.riv")
                }.to(throwError())
            }
        }
    }
}
