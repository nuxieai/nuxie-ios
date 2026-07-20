import CryptoKit
import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private final class FlowArtifactDownloadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var started = false

    var didStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func startAndWait() {
        lock.lock()
        started = true
        lock.unlock()
        semaphore.wait()
    }

    func release() {
        semaphore.signal()
    }
}

private actor CacheFilesystemLockGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor CacheFilesystemLockObservation {
    private var enteredNames = Set<String>()

    func recordEntry(_ name: String) {
        enteredNames.insert(name)
    }

    func didEnter(_ name: String) -> Bool {
        enteredNames.contains(name)
    }
}

final class FlowArtifactStoreTests: AsyncSpec {
    override class func spec() {
        func writeFixtureArtifact(
            flowId: String = "flow-artifact-store",
            buildId: String = "build-1",
            includeImageAsset: Bool = false,
            imageRequired: Bool = true,
            imageDataOverride: Data? = nil,
            includeFontAsset: Bool = false,
            fontRequired: Bool = true,
            fontFormat: String = "ttf",
            fontContentType: String = "font/ttf",
            fontDataOverride: Data? = nil,
            fontSizeBytesOverride: Int? = nil,
            rivSizeBytesOverride: Int? = nil,
            signManifest: ((Data) throws -> Data)? = nil
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
            let rivSizeBytes = rivSizeBytesOverride ?? rivData.count
            try rivData.write(to: remoteURL.appendingPathComponent("flow.riv"))

            let imagePath = includeImageAsset ? "assets/images/test-image.bin" : nil
            let imageData = includeImageAsset
                ? (imageDataOverride ?? Data("fake-image-bytes".utf8))
                : nil
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
            let fontSizeBytes = fontSizeBytesOverride ?? fontData?.count
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
                  "required": \(imageRequired)
                }
                """)
            }

            var fontAssetEntries: [String] = []
            if fontData != nil, let fontSha, let fontSizeBytes {
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
                  "sizeBytes": \(fontSizeBytes),
                  "contentType": "\(fontContentType)",
                  "format": "\(fontFormat)",
                  "required": \(fontRequired)
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
                  "sizeBytes": \(rivSizeBytes)
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
            let manifestSignatureJSON = try signManifest?(manifestJSON)
            if let manifestSignatureJSON {
                try manifestSignatureJSON.write(
                    to: remoteURL.appendingPathComponent("nuxie-manifest.sig.json")
                )
            }

            var contentHashData = Data()
            contentHashData.append(rivData)
            contentHashData.append(manifestJSON)
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
            if let manifestSignatureJSON {
                buildFiles.append(
                    BuildFile(
                        path: "nuxie-manifest.sig.json",
                        size: manifestSignatureJSON.count,
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

        func truncateFile(at url: URL, toByteCount byteCount: Int) throws {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(byteCount))
        }

        func replacingBuildFileSize(
            in flow: Flow,
            path: String,
            size: Int
        ) -> Flow {
            let artifact = flow.remoteFlow.flowArtifact
            let files = artifact.manifest.files.map { file in
                guard file.path == path else { return file }
                return BuildFile(
                    path: file.path,
                    size: size,
                    contentType: file.contentType
                )
            }
            let buildManifest = BuildManifest(
                totalFiles: artifact.manifest.totalFiles,
                totalSize: files.reduce(0) { $0 + $1.size },
                contentHash: artifact.manifest.contentHash,
                files: files
            )
            let remoteFlow = flow.remoteFlow
            return Flow(
                remoteFlow: RemoteFlow(
                    id: remoteFlow.id,
                    flowArtifact: FlowArtifact(
                        url: artifact.url,
                        buildId: artifact.buildId,
                        manifest: buildManifest,
                        status: artifact.status
                    ),
                    screens: remoteFlow.screens,
                    events: remoteFlow.events,
                    handlers: remoteFlow.handlers,
                    scripts: remoteFlow.scripts,
                    viewModelValues: remoteFlow.viewModelValues,
                    responseSchemas: remoteFlow.responseSchemas
                ),
                products: flow.products
            )
        }

        func appendingBuildFile(
            to flow: Flow,
            file: BuildFile
        ) -> Flow {
            let artifact = flow.remoteFlow.flowArtifact
            let files = artifact.manifest.files + [file]
            let buildManifest = BuildManifest(
                totalFiles: files.count,
                totalSize: files.reduce(0) { $0 + $1.size },
                contentHash: artifact.manifest.contentHash,
                files: files
            )
            let remoteFlow = flow.remoteFlow
            return Flow(
                remoteFlow: RemoteFlow(
                    id: remoteFlow.id,
                    flowArtifact: FlowArtifact(
                        url: artifact.url,
                        buildId: artifact.buildId,
                        manifest: buildManifest,
                        status: artifact.status
                    ),
                    screens: remoteFlow.screens,
                    events: remoteFlow.events,
                    handlers: remoteFlow.handlers,
                    scripts: remoteFlow.scripts,
                    viewModelValues: remoteFlow.viewModelValues,
                    responseSchemas: remoteFlow.responseSchemas
                ),
                products: flow.products
            )
        }

        func replacingBuildManifest(
            in flow: Flow,
            with buildManifest: BuildManifest,
            baseURL: URL? = nil
        ) -> Flow {
            let remoteFlow = flow.remoteFlow
            let artifact = remoteFlow.flowArtifact
            return Flow(
                remoteFlow: RemoteFlow(
                    id: remoteFlow.id,
                    flowArtifact: FlowArtifact(
                        url: (baseURL ?? URL(string: artifact.url)!).absoluteString,
                        buildId: artifact.buildId,
                        manifest: buildManifest,
                        status: artifact.status
                    ),
                    screens: remoteFlow.screens,
                    events: remoteFlow.events,
                    handlers: remoteFlow.handlers,
                    scripts: remoteFlow.scripts,
                    viewModelValues: remoteFlow.viewModelValues,
                    responseSchemas: remoteFlow.responseSchemas
                ),
                products: flow.products
            )
        }

        func rewritingRemoteManifest(
            in flow: Flow,
            at remoteURL: URL,
            mutate: (inout [String: Any]) throws -> Void
        ) throws -> Flow {
            let manifestURL = remoteURL.appendingPathComponent(
                FlowArtifactStore.manifestPath
            )
            let originalData = try Data(contentsOf: manifestURL)
            guard var object = try JSONSerialization.jsonObject(with: originalData)
                as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try mutate(&object)
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            try data.write(to: manifestURL)
            return replacingBuildFileSize(
                in: flow,
                path: FlowArtifactStore.manifestPath,
                size: data.count
            )
        }

        describe("FlowArtifactStore") {
            it("serializes independent filesystem transactions for the same cache target") {
                let containerURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                let rootURL = containerURL.appendingPathComponent("cache", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: containerURL) }
                try FileManager.default.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true
                )
                let holderScope = CacheFilesystemLockScope(cacheRootURL: rootURL)
                let contenderScope = CacheFilesystemLockScope(cacheRootURL: rootURL)
                let targetURL = rootURL.appendingPathComponent("artifact", isDirectory: true)
                let gate = CacheFilesystemLockGate()
                let observation = CacheFilesystemLockObservation()

                let holder = Task {
                    try await CacheFilesystemLock.withTargetTransaction(
                        scope: holderScope,
                        targetURL: targetURL
                    ) {
                        await observation.recordEntry("holder")
                        await gate.wait()
                    }
                }
                await expect { await observation.didEnter("holder") }
                    .toEventually(beTrue(), timeout: .seconds(2))

                let contender = Task {
                    try await CacheFilesystemLock.withTargetTransaction(
                        scope: contenderScope,
                        targetURL: targetURL
                    ) {
                        await observation.recordEntry("contender")
                    }
                }
                try await Task.sleep(nanoseconds: 50_000_000)
                let contenderEnteredWhileHeld = await observation.didEnter("contender")
                expect(contenderEnteredWhileHeld).to(beFalse())

                await gate.open()
                try await holder.value
                try await contender.value
                let contenderEventuallyEntered = await observation.didEnter("contender")
                expect(contenderEventuallyEntered).to(beTrue())
            }

            it("canonicalizes cache-root aliases before striping target transactions") {
                let containerURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                let rootURL = containerURL.appendingPathComponent("cache", isDirectory: true)
                let aliasURL = containerURL.appendingPathComponent("cache-alias", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: containerURL) }
                try FileManager.default.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(
                    at: aliasURL,
                    withDestinationURL: rootURL
                )

                var realTargetURL: URL?
                var aliasTargetURL: URL?
                for index in 0..<1_024 {
                    let name = "artifact-\(index)"
                    let candidateRealURL = rootURL.appendingPathComponent(name)
                    let candidateAliasURL = aliasURL.appendingPathComponent(name)
                    let realStripe = Array(SHA256.hash(
                        data: Data(candidateRealURL.standardizedFileURL.path.utf8)
                    ))[0]
                    let aliasStripe = Array(SHA256.hash(
                        data: Data(candidateAliasURL.standardizedFileURL.path.utf8)
                    ))[0]
                    guard realStripe != aliasStripe else { continue }
                    realTargetURL = candidateRealURL
                    aliasTargetURL = candidateAliasURL
                    break
                }
                guard let realTargetURL, let aliasTargetURL else {
                    fail("Expected target aliases with distinct unnormalized stripes")
                    return
                }

                let realScope = CacheFilesystemLockScope(cacheRootURL: rootURL)
                let aliasScope = CacheFilesystemLockScope(cacheRootURL: aliasURL)
                let gate = CacheFilesystemLockGate()
                let observation = CacheFilesystemLockObservation()
                let holder = Task {
                    try await CacheFilesystemLock.withTargetTransaction(
                        scope: realScope,
                        targetURL: realTargetURL
                    ) {
                        await observation.recordEntry("alias-holder")
                        await gate.wait()
                    }
                }
                await expect { await observation.didEnter("alias-holder") }
                    .toEventually(beTrue(), timeout: .seconds(2))

                let contender = Task {
                    try await CacheFilesystemLock.withTargetTransaction(
                        scope: aliasScope,
                        targetURL: aliasTargetURL
                    ) {
                        await observation.recordEntry("alias-contender")
                    }
                }
                try await Task.sleep(nanoseconds: 50_000_000)
                let contenderEnteredWhileHeld = await observation.didEnter("alias-contender")
                expect(contenderEnteredWhileHeld).to(beFalse())

                await gate.open()
                try await holder.value
                try await contender.value
            }

            it("cancels a process-local cache waiter without waiting for the owner") {
                let containerURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                let rootURL = containerURL.appendingPathComponent("cache", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: containerURL) }
                try FileManager.default.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true
                )
                let targetURL = rootURL.appendingPathComponent("artifact", isDirectory: true)
                let scope = CacheFilesystemLockScope(cacheRootURL: rootURL)
                let gate = CacheFilesystemLockGate()
                let observation = CacheFilesystemLockObservation()

                let holder = Task {
                    try await SharedCachePathCoordinator.shared.withExclusiveAccess(
                        to: targetURL,
                        lockScope: scope
                    ) {
                        await observation.recordEntry("local-holder")
                        await gate.wait()
                    }
                }
                await expect { await observation.didEnter("local-holder") }
                    .toEventually(beTrue(), timeout: .seconds(2))

                let waiter = Task {
                    do {
                        try await SharedCachePathCoordinator.shared.withExclusiveAccess(
                            to: targetURL,
                            lockScope: scope
                        ) {
                            await observation.recordEntry("cancelled-operation")
                        }
                    } catch is CancellationError {
                        await observation.recordEntry("waiter-cancelled")
                    }
                }
                try await Task.sleep(nanoseconds: 50_000_000)
                waiter.cancel()
                await expect { await observation.didEnter("waiter-cancelled") }
                    .toEventually(beTrue(), timeout: .seconds(1))
                let cancellationWasPrompt = await observation.didEnter("waiter-cancelled")

                await gate.open()
                try await holder.value
                try await waiter.value

                expect(cancellationWasPrompt).to(beTrue())
                let cancelledOperationRan = await observation.didEnter("cancelled-operation")
                expect(cancelledOperationRan).to(beFalse())
            }

            it("makes a root mutation wait for an active target transaction") {
                let containerURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                let rootURL = containerURL.appendingPathComponent("cache", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: containerURL) }
                try FileManager.default.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true
                )
                let targetScope = CacheFilesystemLockScope(cacheRootURL: rootURL)
                let rootScope = CacheFilesystemLockScope(cacheRootURL: rootURL)
                let targetURL = rootURL.appendingPathComponent("artifact", isDirectory: true)
                let gate = CacheFilesystemLockGate()
                let observation = CacheFilesystemLockObservation()

                let targetTransaction = Task {
                    try await CacheFilesystemLock.withTargetTransaction(
                        scope: targetScope,
                        targetURL: targetURL
                    ) {
                        await observation.recordEntry("target")
                        await gate.wait()
                    }
                }
                await expect { await observation.didEnter("target") }
                    .toEventually(beTrue(), timeout: .seconds(2))

                let rootMutation = Task {
                    try await CacheFilesystemLock.withExclusiveRootTransaction(
                        scope: rootScope
                    ) {
                        await observation.recordEntry("root")
                    }
                }
                try await Task.sleep(nanoseconds: 50_000_000)
                let rootEnteredWhileTargetHeld = await observation.didEnter("root")
                expect(rootEnteredWhileTargetHeld).to(beFalse())

                await gate.open()
                try await targetTransaction.value
                try await rootMutation.value
                let rootEventuallyEntered = await observation.didEnter("root")
                expect(rootEventuallyEntered).to(beTrue())
            }

            it("rejects more build files than the fixed build-envelope limit") {
                let fixture = try writeFixtureArtifact()
                let fileLimit = FlowRuntimeImportLimits.externalAssetCount + 3
                let files = (0...fileLimit).map { index in
                    BuildFile(
                        path: "unused-\(index).bin",
                        size: 0,
                        contentType: "application/octet-stream"
                    )
                }
                let flow = replacingBuildManifest(
                    in: fixture.flow,
                    with: BuildManifest(
                        totalFiles: files.count,
                        totalSize: 0,
                        contentHash: "fixture",
                        files: files
                    )
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                await expect {
                    try await store.getOrDownloadArtifact(for: flow)
                }.to(
                    throwError(
                        FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "build manifest file count",
                            actual: fileLimit + 1,
                            limit: fileLimit
                        )
                    )
                )
            }

            it("rejects inconsistent build-manifest file metadata") {
                let fixture = try writeFixtureArtifact()
                let manifest = fixture.flow.remoteFlow.flowArtifact.manifest
                let flow = replacingBuildManifest(
                    in: fixture.flow,
                    with: BuildManifest(
                        totalFiles: manifest.files.count + 1,
                        totalSize: manifest.totalSize,
                        contentHash: manifest.contentHash,
                        files: manifest.files
                    )
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                await expect {
                    try await store.getOrDownloadArtifact(for: flow)
                }.to(
                    throwError(
                        FlowArtifactStoreError.buildManifestFileCountMismatch(
                            declared: manifest.files.count + 1,
                            actual: manifest.files.count
                        )
                    )
                )
            }

            it("rejects inconsistent build-manifest aggregate size metadata") {
                let fixture = try writeFixtureArtifact()
                let manifest = fixture.flow.remoteFlow.flowArtifact.manifest
                let flow = replacingBuildManifest(
                    in: fixture.flow,
                    with: BuildManifest(
                        totalFiles: manifest.totalFiles,
                        totalSize: manifest.totalSize + 1,
                        contentHash: manifest.contentHash,
                        files: manifest.files
                    )
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                await expect {
                    try await store.getOrDownloadArtifact(for: flow)
                }.to(
                    throwError(
                        FlowArtifactStoreError.buildManifestTotalSizeMismatch(
                            declared: manifest.totalSize + 1,
                            actual: manifest.totalSize
                        )
                    )
                )
            }

            it("rejects aggregate declared bytes over the fixed build envelope") {
                let fixture = try writeFixtureArtifact()
                let oversizedFile = BuildFile(
                    path: "unused.bin",
                    size: FlowArtifactStore.maximumBuildDeclaredBytes + 1,
                    contentType: "application/octet-stream"
                )
                let flow = replacingBuildManifest(
                    in: fixture.flow,
                    with: BuildManifest(
                        totalFiles: 1,
                        totalSize: oversizedFile.size,
                        contentHash: "fixture",
                        files: [oversizedFile]
                    )
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                await expect {
                    try await store.getOrDownloadArtifact(for: flow)
                }.to(
                    throwError(
                        FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "build manifest declared bytes",
                            actual: oversizedFile.size,
                            limit: FlowArtifactStore.maximumBuildDeclaredBytes
                        )
                    )
                )
            }

            it("rejects duplicate build paths before making a remote request") {
                let fixture = try writeFixtureArtifact()
                let manifest = fixture.flow.remoteFlow.flowArtifact.manifest
                let duplicate = manifest.files[0]
                let files = manifest.files + [duplicate]
                let remoteURL = URL(string: "https://artifacts.nuxie.test/build/")!
                var requestCount = 0
                StubURLProtocol.reset()
                defer { StubURLProtocol.reset() }
                StubURLProtocol.register(
                    matcher: { $0.url?.host == remoteURL.host },
                    handler: { request in
                        requestCount += 1
                        throw URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: request.url!])
                    }
                )
                let flow = replacingBuildManifest(
                    in: fixture.flow,
                    with: BuildManifest(
                        totalFiles: files.count,
                        totalSize: files.reduce(0) { $0 + $1.size },
                        contentHash: manifest.contentHash,
                        files: files
                    ),
                    baseURL: remoteURL
                )
                let store = FlowArtifactStore(
                    urlSession: TestURLSessionProvider.createTestSession(),
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                await expect {
                    try await store.getOrDownloadArtifact(for: flow)
                }.to(throwError(FlowArtifactStoreError.duplicateBuildFilePath(duplicate.path)))
                expect(requestCount).to(equal(0))
            }

            it("rejects unsafe build paths before acquisition") {
                let fixture = try writeFixtureArtifact()
                let file = BuildFile(
                    path: "../manifest.json",
                    size: 0,
                    contentType: "application/json"
                )
                let flow = replacingBuildManifest(
                    in: fixture.flow,
                    with: BuildManifest(
                        totalFiles: 1,
                        totalSize: 0,
                        contentHash: "fixture",
                        files: [file]
                    )
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                await expect {
                    try await store.getOrDownloadArtifact(for: flow)
                }.to(throwError(FlowArtifactStoreError.unsafePath(file.path)))
            }

            it("rejects an oversized declared manifest before reading its remote file") {
                let fixture = try writeFixtureArtifact()
                let flow = replacingBuildFileSize(
                    in: fixture.flow,
                    path: FlowArtifactStore.manifestPath,
                    size: FlowRuntimeImportLimits.manifestBytes + 1
                )
                try FileManager.default.removeItem(
                    at: fixture.baseURL.appendingPathComponent(FlowArtifactStore.manifestPath)
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                await expect {
                    try await store.getOrDownloadArtifact(for: flow)
                }.to(
                    throwError(
                        FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "manifest",
                            actual: FlowRuntimeImportLimits.manifestBytes + 1,
                            limit: FlowRuntimeImportLimits.manifestBytes
                        )
                    )
                )
            }

            it("cancels a remote build-file response when its body exceeds its declaration") {
                let fixture = try writeFixtureArtifact()
                let remoteURL = URL(string: "https://artifacts.nuxie.test/build/")!
                let manifest = fixture.flow.remoteFlow.flowArtifact.manifest
                let manifestData = try Data(
                    contentsOf: fixture.baseURL.appendingPathComponent(FlowArtifactStore.manifestPath)
                )
                let oversizedRivData = fixture.rivData + Data([0])
                StubURLProtocol.reset()
                defer { StubURLProtocol.reset() }
                StubURLProtocol.registerSuccess(
                    path: remoteURL.appendingPathComponent(FlowArtifactStore.manifestPath).path,
                    data: manifestData,
                    headers: ["Content-Type": "application/json"]
                )
                StubURLProtocol.registerSuccess(
                    path: remoteURL.appendingPathComponent("flow.riv").path,
                    data: oversizedRivData,
                    headers: ["Content-Type": "application/octet-stream"]
                )
                let flow = replacingBuildManifest(
                    in: fixture.flow,
                    with: manifest,
                    baseURL: remoteURL
                )
                let store = FlowArtifactStore(
                    urlSession: TestURLSessionProvider.createTestSession(),
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                await expect {
                    try await store.getOrDownloadArtifact(for: flow)
                }.to(throwError { error in
                    expect(error.localizedDescription).to(contain(
                        "expected \(fixture.rivData.count), got \(oversizedRivData.count)"
                    ))
                })
            }

            it("keeps visual import available when a listed signature file is missing") {
                let fixture = try writeFixtureArtifact()
                let flow = appendingBuildFile(
                    to: fixture.flow,
                    file: BuildFile(
                        path: FlowArtifactStore.manifestSignaturePath,
                        size: 128,
                        contentType: "application/json"
                    )
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                let loaded = try await store.getOrDownloadArtifact(for: flow)

                expect(loaded.scriptsEnabled).to(beFalse())
                expect(loaded.authorizationEvidence.signatureEnvelopeBytes).to(beNil())
            }

            it("acquires every declared build-manifest sidecar") {
                let fixture = try writeFixtureArtifact()
                let sidecar = Data("retained-sidecar".utf8)
                try sidecar.write(
                    to: fixture.baseURL.appendingPathComponent("unused-sidecar.bin")
                )
                let flow = appendingBuildFile(
                    to: fixture.flow,
                    file: BuildFile(
                        path: "unused-sidecar.bin",
                        size: sidecar.count,
                        contentType: "application/octet-stream"
                    )
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                let loaded = try await store.getOrDownloadArtifact(for: flow)

                expect(loaded.source).to(equal(.downloadedArtifact))
                expect(
                    try Data(
                        contentsOf: loaded.directoryURL
                            .appendingPathComponent("unused-sidecar.bin")
                    )
                ).to(equal(sidecar))
            }

            it("redownloads a cached artifact when a declared sidecar disappears") {
                let fixture = try writeFixtureArtifact()
                defer {
                    try? FileManager.default.removeItem(
                        at: fixture.cacheURL.deletingLastPathComponent()
                    )
                }
                let sidecar = Data("retained-sidecar".utf8)
                try sidecar.write(
                    to: fixture.baseURL.appendingPathComponent("unused-sidecar.bin")
                )
                let flow = appendingBuildFile(
                    to: fixture.flow,
                    file: BuildFile(
                        path: "unused-sidecar.bin",
                        size: sidecar.count,
                        contentType: "application/octet-stream"
                    )
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(
                        cacheDirectory: fixture.runtimeCacheURL
                    )
                )

                let downloaded = try await store.getOrDownloadArtifact(for: flow)
                try FileManager.default.removeItem(
                    at: downloaded.directoryURL
                        .appendingPathComponent("unused-sidecar.bin")
                )

                let repaired = try await store.getOrDownloadArtifact(for: flow)

                expect(repaired.source).to(equal(.downloadedArtifact))
                expect(
                    try Data(
                        contentsOf: repaired.directoryURL
                            .appendingPathComponent("unused-sidecar.bin")
                    )
                ).to(equal(sidecar))
            }

            it("rejects an oversized declared RIV before reading its remote file") {
                let fixture = try writeFixtureArtifact(
                    rivSizeBytesOverride: FlowRuntimeImportLimits.artifactBytes + 1
                )
                try FileManager.default.removeItem(
                    at: fixture.baseURL.appendingPathComponent("flow.riv")
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                await expect {
                    try await store.getOrDownloadArtifact(for: fixture.flow)
                }.to(
                    throwError(
                        FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "artifact",
                            actual: FlowRuntimeImportLimits.artifactBytes + 1,
                            limit: FlowRuntimeImportLimits.artifactBytes
                        )
                    )
                )
            }

            it("rejects an oversized RIV build file before reading its remote file") {
                let fixture = try writeFixtureArtifact()
                let flow = replacingBuildFileSize(
                    in: fixture.flow,
                    path: "flow.riv",
                    size: FlowRuntimeImportLimits.artifactBytes + 1
                )
                try FileManager.default.removeItem(
                    at: fixture.baseURL.appendingPathComponent("flow.riv")
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                await expect {
                    try await store.getOrDownloadArtifact(for: flow)
                }.to(
                    throwError(
                        FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "artifact",
                            actual: FlowRuntimeImportLimits.artifactBytes + 1,
                            limit: FlowRuntimeImportLimits.artifactBytes
                        )
                    )
                )
            }

            it("rejects an oversized required image before reading its remote file") {
                let fixture = try writeFixtureArtifact(includeImageAsset: true)
                guard let imagePath = fixture.imagePath else {
                    fail("Expected image fixture")
                    return
                }
                let flow = replacingBuildFileSize(
                    in: fixture.flow,
                    path: imagePath,
                    size: FlowRuntimeImportLimits.externalAssetTotalBytes + 1
                )
                try FileManager.default.removeItem(
                    at: fixture.baseURL.appendingPathComponent(imagePath)
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                await expect {
                    try await store.getOrDownloadArtifact(for: flow)
                }.to(
                    throwError(
                        FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "aggregate external asset bytes",
                            actual: FlowRuntimeImportLimits.externalAssetTotalBytes + 1,
                            limit: FlowRuntimeImportLimits.externalAssetTotalBytes
                        )
                    )
                )
            }

            it("omits an oversized optional image without reading its remote file") {
                let fixture = try writeFixtureArtifact(
                    includeImageAsset: true,
                    imageRequired: false
                )
                guard let imagePath = fixture.imagePath else {
                    fail("Expected image fixture")
                    return
                }
                let flow = replacingBuildFileSize(
                    in: fixture.flow,
                    path: imagePath,
                    size: FlowRuntimeImportLimits.externalAssetTotalBytes + 1
                )
                try FileManager.default.removeItem(
                    at: fixture.baseURL.appendingPathComponent(imagePath)
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                let loaded = try await store.getOrDownloadArtifact(for: flow)

                expect(loaded.source).to(equal(.downloadedArtifact))
                expect(loaded.localAssetURL(forRiveUniqueName: "test-image")).to(beNil())
            }

            it("continues to a valid optional font after omitting an oversized optional image") {
                let fixture = try writeFixtureArtifact(
                    includeImageAsset: true,
                    imageRequired: false,
                    includeFontAsset: true,
                    fontRequired: false
                )
                guard let imagePath = fixture.imagePath else {
                    fail("Expected image fixture")
                    return
                }
                let flow = replacingBuildFileSize(
                    in: fixture.flow,
                    path: imagePath,
                    size: FlowRuntimeImportLimits.externalAssetTotalBytes + 1
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                let loaded = try await store.getOrDownloadArtifact(for: flow)

                expect(loaded.localAssetURL(forRiveUniqueName: "test-image")).to(beNil())
                expect(loaded.localAssetURL(forRiveUniqueName: "test-font")).notTo(beNil())
            }

            it("continues after a full-budget optional image fails acquisition") {
                let fixture = try writeFixtureArtifact(
                    includeImageAsset: true,
                    imageRequired: false,
                    includeFontAsset: true,
                    fontRequired: false
                )
                guard let imagePath = fixture.imagePath else {
                    fail("Expected image fixture")
                    return
                }
                let flow = replacingBuildFileSize(
                    in: fixture.flow,
                    path: imagePath,
                    size: FlowRuntimeImportLimits.externalAssetTotalBytes
                )
                try FileManager.default.removeItem(
                    at: fixture.baseURL.appendingPathComponent(imagePath)
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                let loaded = try await store.getOrDownloadArtifact(for: flow)

                expect(loaded.localAssetURL(forRiveUniqueName: "test-image")).to(beNil())
                expect(loaded.localAssetURL(forRiveUniqueName: "test-font")).notTo(beNil())
            }

            it("measures failed optional work instead of reserving declarations") {
                let limit = FlowRuntimeImportLimits.externalAssetTotalBytes
                var budget = try FlowArtifactAcquisitionBudget(
                    acceptedByteLimit: limit
                )

                expect(
                    budget.permitsAttempt(
                        identity: "missing-a",
                        expectedBytes: limit
                    )
                ).to(beTrue())
                try budget.recordWork(identity: "missing-a", byteCount: 0)
                expect(
                    budget.permitsAttempt(
                        identity: "missing-b",
                        expectedBytes: limit
                    )
                ).to(beTrue())
                try budget.recordWork(identity: "missing-b", byteCount: 0)
                expect(
                    budget.permitsAttempt(
                        identity: "valid-byte",
                        expectedBytes: 1
                    )
                ).to(beTrue())
                try budget.recordWork(identity: "valid-byte", byteCount: 1)
                try budget.recordAccepted(identity: "valid-byte", byteCount: 1)

                expect(budget.workBytes).to(equal(1))
                expect(budget.acceptedBytes).to(equal(1))
                expect(budget.workByteLimit).to(equal(limit * 2))
            }

            it("counts accepted bytes per descriptor even when content is shared") {
                var budget = try FlowArtifactAcquisitionBudget(acceptedByteLimit: 4)

                try budget.recordAccepted(identity: "image-descriptor:1:first", byteCount: 2)
                try budget.recordAccepted(identity: "image-descriptor:2:second", byteCount: 2)
                try budget.recordAccepted(identity: "image-descriptor:2:second", byteCount: 2)

                expect(budget.acceptedBytes).to(equal(4))
                expect(budget.permitsAccepted(byteCount: 1)).to(beFalse())
            }

            it("charges repeated failed image descriptors at the same path independently") {
                var budget = try FlowArtifactAcquisitionBudget(acceptedByteLimit: 2)
                let firstAttempt = FlowArtifactAcquisitionIdentity.imageAttempt(
                    descriptorIndex: 1,
                    path: "assets/shared.png"
                )
                let secondAttempt = FlowArtifactAcquisitionIdentity.imageAttempt(
                    descriptorIndex: 2,
                    path: "assets/shared.png"
                )
                let thirdAttempt = FlowArtifactAcquisitionIdentity.imageAttempt(
                    descriptorIndex: 3,
                    path: "assets/shared.png"
                )

                expect(firstAttempt).notTo(equal(secondAttempt))
                try budget.recordWork(identity: firstAttempt, byteCount: 2)
                try budget.recordWork(identity: secondAttempt, byteCount: 2)

                expect(budget.workBytes).to(equal(4))
                expect(
                    budget.permitsWork(
                        identity: thirdAttempt,
                        totalByteCount: 1
                    )
                ).to(beFalse())
            }

            it("rejects an oversized required image source at the asset-store read seam") {
                let fixture = try writeFixtureArtifact(
                    includeImageAsset: true,
                    imageDataOverride: Data(repeating: 0x41, count: 9)
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(
                        cacheDirectory: fixture.runtimeCacheURL,
                        maximumAssetBytes: 8
                    )
                )

                await expect {
                    try await store.getOrDownloadArtifact(for: fixture.flow)
                }.to(
                    throwError(
                        FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "external asset bytes",
                            actual: 9,
                            limit: 8
                        )
                    )
                )
            }

            it("omits an oversized optional image at the asset-store read seam") {
                let fixture = try writeFixtureArtifact(
                    includeImageAsset: true,
                    imageRequired: false,
                    imageDataOverride: Data(repeating: 0x41, count: 9)
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(
                        cacheDirectory: fixture.runtimeCacheURL,
                        maximumAssetBytes: 8
                    )
                )

                let loaded = try await store.getOrDownloadArtifact(for: fixture.flow)

                expect(loaded.source).to(equal(.downloadedArtifact))
                expect(loaded.localAssetURL(forRiveUniqueName: "test-image")).to(beNil())
            }

            it("rejects an oversized declared required font before reading its remote file") {
                let fixture = try writeFixtureArtifact(
                    includeFontAsset: true,
                    fontSizeBytesOverride: FlowRuntimeImportLimits.externalAssetTotalBytes + 1
                )
                let fontURL = fixture.baseURL
                    .appendingPathComponent("external-fonts/test-font.ttf")
                try FileManager.default.removeItem(at: fontURL)
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                await expect {
                    try await store.getOrDownloadArtifact(for: fixture.flow)
                }.to(
                    throwError(
                        FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "aggregate external asset bytes",
                            actual: FlowRuntimeImportLimits.externalAssetTotalBytes + 1,
                            limit: FlowRuntimeImportLimits.externalAssetTotalBytes
                        )
                    )
                )
            }

            it("omits an oversized declared optional font without reading its remote file") {
                let fixture = try writeFixtureArtifact(
                    includeFontAsset: true,
                    fontRequired: false,
                    fontSizeBytesOverride: FlowRuntimeImportLimits.externalAssetTotalBytes + 1
                )
                let fontURL = fixture.baseURL
                    .appendingPathComponent("external-fonts/test-font.ttf")
                try FileManager.default.removeItem(at: fontURL)
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                let loaded = try await store.getOrDownloadArtifact(for: fixture.flow)

                expect(loaded.source).to(equal(.downloadedArtifact))
                expect(loaded.localAssetURL(forRiveUniqueName: "test-font")).to(beNil())
            }

            it("rejects an oversized cached manifest before materializing it") {
                let fixture = try writeFixtureArtifact()
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )
                let downloaded = try await store.getOrDownloadArtifact(for: fixture.flow)
                try truncateFile(
                    at: downloaded.manifestURL,
                    toByteCount: FlowRuntimeImportLimits.manifestBytes + 1
                )

                await expect {
                    try await store.getCachedArtifact(for: fixture.flow)
                }.to(
                    throwError(
                        FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "manifest",
                            actual: FlowRuntimeImportLimits.manifestBytes + 1,
                            limit: FlowRuntimeImportLimits.manifestBytes
                        )
                    )
                )
            }

            it("rejects an oversized cached RIV before hashing it") {
                let fixture = try writeFixtureArtifact()
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )
                let downloaded = try await store.getOrDownloadArtifact(for: fixture.flow)
                try truncateFile(
                    at: downloaded.rivURL,
                    toByteCount: FlowRuntimeImportLimits.artifactBytes + 1
                )

                await expect {
                    try await store.getCachedArtifact(for: fixture.flow)
                }.to(
                    throwError(
                        FlowRuntimeImportValidationError.valueExceedsLimit(
                            field: "artifact",
                            actual: FlowRuntimeImportLimits.artifactBytes + 1,
                            limit: FlowRuntimeImportLimits.artifactBytes
                        )
                    )
                )
            }

            it("bounds an oversized shared image cache before hashing it") {
                let imageData = Data(repeating: 0x41, count: 8)
                let fixture = try writeFixtureArtifact(
                    includeImageAsset: true,
                    imageDataOverride: imageData
                )
                let runtimeAssetStore = RuntimeAssetStore(
                    cacheDirectory: fixture.runtimeCacheURL,
                    maximumAssetBytes: imageData.count
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: runtimeAssetStore
                )
                let downloaded = try await store.getOrDownloadArtifact(for: fixture.flow)
                guard let image = downloaded.manifest.assets.images.first,
                      let cachedImageURL = downloaded.localAssetURL(
                          forRiveUniqueName: image.riveUniqueName
                      ) else {
                    fail("Expected cached image fixture")
                    return
                }
                try truncateFile(at: cachedImageURL, toByteCount: imageData.count + 1)
                try FileManager.default.removeItem(
                    at: downloaded.directoryURL.appendingPathComponent(image.path)
                )

                await expect {
                    try await runtimeAssetStore.cachedImageURL(
                        for: image,
                        artifactDirectoryURL: downloaded.directoryURL,
                        expectedSize: imageData.count
                    )
                }.to(throwError { error in
                    expect(error.localizedDescription).to(contain("source file is missing"))
                })
                expect(FileManager.default.fileExists(atPath: cachedImageURL.path)).to(beFalse())
            }

            it("rejects a shared image cache whose exact build size changed") {
                let imageData = Data(repeating: 0x41, count: 8)
                let fixture = try writeFixtureArtifact(
                    includeImageAsset: true,
                    imageDataOverride: imageData
                )
                guard let imagePath = fixture.imagePath else {
                    fail("Expected image fixture")
                    return
                }
                let runtimeAssetStore = RuntimeAssetStore(
                    cacheDirectory: fixture.runtimeCacheURL
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: runtimeAssetStore
                )
                _ = try await store.getOrDownloadArtifact(for: fixture.flow)
                let changedFlow = replacingBuildFileSize(
                    in: fixture.flow,
                    path: imagePath,
                    size: 1
                )

                await expect {
                    try await store.getCachedArtifact(for: changedFlow)
                }.to(throwError { error in
                    expect(error.localizedDescription).to(contain("expected 1, got 8"))
                })
            }

            it("removes a newly copied image cache entry when verification fails") {
                let rootURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: rootURL) }
                let artifactURL = rootURL.appendingPathComponent("artifact", isDirectory: true)
                let cacheURL = rootURL.appendingPathComponent("cache", isDirectory: true)
                let imagePath = "assets/image.png"
                let sourceURL = artifactURL.appendingPathComponent(imagePath)
                try FileManager.default.createDirectory(
                    at: sourceURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data([1, 2, 3]).write(to: sourceURL)
                let runtimeAssetStore = RuntimeAssetStore(cacheDirectory: cacheURL)
                let asset = FlowArtifactImageAsset(
                    riveAssetId: 1,
                    riveUniqueName: "invalid-image",
                    sourceAssetKey: "invalid-image-source",
                    path: imagePath,
                    sha256: String(repeating: "0", count: 64),
                    contentType: "image/png",
                    width: 1,
                    height: 1,
                    required: true
                )
                let expectedCacheURL = try await runtimeAssetStore.imageCacheURL(for: asset)

                await expect {
                    try await runtimeAssetStore.cachedImageURL(
                        for: asset,
                        artifactDirectoryURL: artifactURL,
                        expectedSize: 3
                    )
                }.to(throwError { error in
                    expect(error.localizedDescription).to(contain("SHA-256 mismatch"))
                })
                expect(FileManager.default.fileExists(atPath: expectedCacheURL.path)).to(beFalse())
            }

            it("coordinates invalid image-cache replacement across store actors") {
                let rootURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: rootURL) }
                let artifactURL = rootURL.appendingPathComponent("artifact", isDirectory: true)
                let cacheURL = rootURL.appendingPathComponent("cache", isDirectory: true)
                let imagePath = "assets/image.png"
                let sourceURL = artifactURL.appendingPathComponent(imagePath)
                let expectedData = Data([1, 2, 3, 4])
                try FileManager.default.createDirectory(
                    at: sourceURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try expectedData.write(to: sourceURL)
                let asset = FlowArtifactImageAsset(
                    riveAssetId: 1,
                    riveUniqueName: "coordinated-image",
                    sourceAssetKey: "coordinated-image-source",
                    path: imagePath,
                    sha256: FlowArtifactStore.sha256Hex(expectedData),
                    contentType: "image/png",
                    width: 1,
                    height: 1,
                    required: true
                )
                let firstStore = RuntimeAssetStore(cacheDirectory: cacheURL)
                let secondStore = RuntimeAssetStore(cacheDirectory: cacheURL)
                let sharedCacheURL = try await firstStore.imageCacheURL(for: asset)
                try FileManager.default.createDirectory(
                    at: sharedCacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data([9, 9, 9, 9]).write(to: sharedCacheURL)

                async let first = firstStore.cachedImageURL(
                    for: asset,
                    artifactDirectoryURL: artifactURL,
                    expectedSize: expectedData.count
                )
                async let second = secondStore.cachedImageURL(
                    for: asset,
                    artifactDirectoryURL: artifactURL,
                    expectedSize: expectedData.count
                )
                let urls = try await [first, second]

                expect(urls[0].path).to(equal(urls[1].path))
                expect(try Data(contentsOf: sharedCacheURL)).to(equal(expectedData))
            }

            it("bounds an oversized shared font cache before materializing it") {
                let fixture = try writeFixtureArtifact(includeFontAsset: true)
                guard let fontData = fixture.fontData else {
                    fail("Expected font fixture")
                    return
                }
                let runtimeAssetStore = RuntimeAssetStore(
                    cacheDirectory: fixture.runtimeCacheURL,
                    maximumAssetBytes: fontData.count + 1
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: runtimeAssetStore
                )
                let downloaded = try await store.getOrDownloadArtifact(for: fixture.flow)
                guard let font = downloaded.manifest.assets.fonts.first,
                      let cachedFontURL = downloaded.localAssetURL(
                          forRiveUniqueName: font.riveUniqueName
                      ) else {
                    fail("Expected cached font fixture")
                    return
                }
                try truncateFile(at: cachedFontURL, toByteCount: fontData.count + 1)
                try FileManager.default.removeItem(
                    at: fixture.baseURL.appendingPathComponent("external-fonts/test-font.ttf")
                )

                await expect {
                    try await runtimeAssetStore.cachedFontURL(for: font)
                }.to(throwError())
                expect(FileManager.default.fileExists(atPath: cachedFontURL.path)).to(beFalse())
            }

            it("coordinates invalid font-cache replacement across store actors") {
                let rootURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: rootURL) }
                let cacheURL = rootURL.appendingPathComponent("cache", isDirectory: true)
                let sourceURL = rootURL.appendingPathComponent("font.ttf")
                let expectedData = try publishedFixtureFontData()
                try FileManager.default.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true
                )
                try expectedData.write(to: sourceURL)
                let asset = FlowArtifactFontAsset(
                    riveAssetId: 1,
                    riveUniqueName: "coordinated-font",
                    requestKey: "Inter:400:normal",
                    family: "Inter",
                    weight: "400",
                    style: "normal",
                    assetUrl: sourceURL.absoluteString,
                    sha256: FlowArtifactStore.sha256Hex(expectedData),
                    sizeBytes: expectedData.count,
                    contentType: "font/ttf",
                    format: "ttf",
                    required: true
                )
                let firstStore = RuntimeAssetStore(cacheDirectory: cacheURL)
                let secondStore = RuntimeAssetStore(cacheDirectory: cacheURL)
                let sharedCacheURL = try await firstStore.fontCacheURL(for: asset)
                try FileManager.default.createDirectory(
                    at: sharedCacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(repeating: 0, count: expectedData.count).write(to: sharedCacheURL)

                async let first = firstStore.cachedFontURL(for: asset)
                async let second = secondStore.cachedFontURL(for: asset)
                let urls = try await [first, second]

                expect(urls[0].path).to(equal(urls[1].path))
                expect(try Data(contentsOf: sharedCacheURL)).to(equal(expectedData))
            }

            it("does not delete a valid font cache when the work budget is exhausted") {
                let rootURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: rootURL) }
                let sourceURL = rootURL.appendingPathComponent("font.ttf")
                let data = try publishedFixtureFontData()
                try FileManager.default.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true
                )
                try data.write(to: sourceURL)
                let asset = FlowArtifactFontAsset(
                    riveAssetId: 1,
                    riveUniqueName: "budgeted-font",
                    requestKey: "Inter:400:normal",
                    family: "Inter",
                    weight: "400",
                    style: "normal",
                    assetUrl: sourceURL.absoluteString,
                    sha256: FlowArtifactStore.sha256Hex(data),
                    sizeBytes: data.count,
                    contentType: "font/ttf",
                    format: "ttf",
                    required: false
                )
                let store = RuntimeAssetStore(
                    cacheDirectory: rootURL.appendingPathComponent("cache")
                )
                let cachedURL = try await store.cachedFontURL(for: asset)

                await expect {
                    try await store.acquireCachedFontURL(
                        for: asset,
                        maximumWorkBytes: 0
                    )
                }.to(throwError())

                expect(FileManager.default.fileExists(atPath: cachedURL.path)).to(beTrue())
                expect(try Data(contentsOf: cachedURL)).to(equal(data))
            }

            it("bounds a downloaded font response by its declared size") {
                let fontURL = URL(string: "https://assets.nuxie.test/font.ttf")!
                let fontData = Data(repeating: 0x42, count: 9)
                StubURLProtocol.reset()
                defer { StubURLProtocol.reset() }
                StubURLProtocol.registerSuccess(
                    path: fontURL.path,
                    data: fontData,
                    headers: ["Content-Type": "font/ttf"]
                )
                let cacheURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: cacheURL) }
                let runtimeAssetStore = RuntimeAssetStore(
                    urlSession: TestURLSessionProvider.createTestSession(),
                    cacheDirectory: cacheURL,
                    maximumAssetBytes: 8
                )
                let asset = FlowArtifactFontAsset(
                    riveAssetId: 1,
                    riveUniqueName: "downloaded-font",
                    requestKey: "Inter:400:normal",
                    family: "Inter",
                    weight: "400",
                    style: "normal",
                    assetUrl: fontURL.absoluteString,
                    sha256: FlowArtifactStore.sha256Hex(fontData),
                    sizeBytes: 8,
                    contentType: "font/ttf",
                    format: "ttf",
                    required: true
                )

                await expect {
                    try await runtimeAssetStore.cachedFontURL(for: asset)
                }.to(throwError { error in
                    expect(error.localizedDescription).to(contain("expected 8, got 9"))
                })
            }

            it("rejects an oversized font Content-Length before receiving its body") {
                let fontURL = URL(string: "https://assets.nuxie.test/font-header.ttf")!
                StubURLProtocol.reset()
                defer { StubURLProtocol.reset() }
                StubURLProtocol.registerSuccess(
                    path: fontURL.path,
                    data: Data(),
                    headers: [
                        "Content-Length": "9",
                        "Content-Type": "font/ttf",
                    ]
                )
                let cacheURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: cacheURL) }
                let runtimeAssetStore = RuntimeAssetStore(
                    urlSession: TestURLSessionProvider.createTestSession(),
                    cacheDirectory: cacheURL,
                    maximumAssetBytes: 8
                )
                let asset = FlowArtifactFontAsset(
                    riveAssetId: 1,
                    riveUniqueName: "header-font",
                    requestKey: "Inter:400:normal",
                    family: "Inter",
                    weight: "400",
                    style: "normal",
                    assetUrl: fontURL.absoluteString,
                    sha256: String(repeating: "0", count: 64),
                    sizeBytes: 8,
                    contentType: "font/ttf",
                    format: "ttf",
                    required: true
                )

                await expect {
                    try await runtimeAssetStore.cachedFontURL(for: asset)
                }.to(throwError { error in
                    expect(error.localizedDescription).to(contain("expected 8, got 9"))
                })
            }

            it("preserves HTTP failure mapping for bounded font downloads") {
                let fontURL = URL(string: "https://assets.nuxie.test/missing-font.ttf")!
                StubURLProtocol.reset()
                defer { StubURLProtocol.reset() }
                var observedConfigurationHeader: String?
                StubURLProtocol.register(
                    matcher: { $0.url?.path == fontURL.path },
                    handler: { request in
                        observedConfigurationHeader = request.value(
                            forHTTPHeaderField: "X-Nuxie-Download-Test"
                        )
                        return (
                            HTTPURLResponse(
                                url: request.url!,
                                statusCode: 404,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "font/ttf"]
                            )!,
                            Data()
                        )
                    }
                )
                let cacheURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: cacheURL) }
                let runtimeAssetStore = RuntimeAssetStore(
                    urlSession: TestURLSessionProvider.createTestSession(
                        additionalHeaders: ["X-Nuxie-Download-Test": "preserved"]
                    ),
                    cacheDirectory: cacheURL,
                    maximumAssetBytes: 8
                )
                let asset = FlowArtifactFontAsset(
                    riveAssetId: 1,
                    riveUniqueName: "missing-font",
                    requestKey: "Inter:400:normal",
                    family: "Inter",
                    weight: "400",
                    style: "normal",
                    assetUrl: fontURL.absoluteString,
                    sha256: String(repeating: "0", count: 64),
                    sizeBytes: 8,
                    contentType: "font/ttf",
                    format: "ttf",
                    required: true
                )

                await expect {
                    try await runtimeAssetStore.cachedFontURL(for: asset)
                }.to(throwError { error in
                    expect(error.localizedDescription).to(contain("Failed to download runtime asset"))
                })
                expect(observedConfigurationHeader).to(equal("preserved"))
            }

            it("omits an optional font whose source exceeds its declared size") {
                let fixture = try writeFixtureArtifact(
                    includeFontAsset: true,
                    fontRequired: false,
                    fontDataOverride: Data(repeating: 0x42, count: 9),
                    fontSizeBytesOverride: 8
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                let loaded = try await store.getOrDownloadArtifact(for: fixture.flow)

                expect(loaded.localAssetURL(forRiveUniqueName: "test-font")).to(beNil())
            }

            it("does not let a missing optional image poison valid content with the same hash") {
                let fixture = try writeFixtureArtifact(
                    includeImageAsset: true,
                    imageRequired: false
                )
                guard let imagePath = fixture.imagePath,
                      let imageData = fixture.imageData else {
                    fail("Expected image fixture")
                    return
                }
                let missingFirstPath = "assets/images/missing-first.bin"
                let duplicateRemoteURL = fixture.baseURL.appendingPathComponent(
                    missingFirstPath
                )
                try FileManager.default.createDirectory(
                    at: duplicateRemoteURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try imageData.write(to: duplicateRemoteURL)
                var flow = try rewritingRemoteManifest(
                    in: fixture.flow,
                    at: fixture.baseURL
                ) { object in
                    var assets = object["assets"] as! [String: Any]
                    let existingImages = assets["images"] as! [[String: Any]]
                    let firstImage: [String: Any] = [
                        "riveAssetId": 3,
                        "riveUniqueName": "missing-first-image",
                        "sourceAssetKey": "missing-first-source",
                        "path": missingFirstPath,
                        "sha256": FlowArtifactStore.sha256Hex(imageData),
                        "contentType": "image/png",
                        "width": 1,
                        "height": 1,
                        "required": false,
                    ]
                    assets["images"] = [firstImage] + existingImages
                    object["assets"] = assets
                }
                flow = appendingBuildFile(
                    to: flow,
                    file: BuildFile(
                        path: missingFirstPath,
                        size: imageData.count,
                        contentType: "image/png"
                    )
                )
                let runtimeAssetStore = RuntimeAssetStore(
                    cacheDirectory: fixture.runtimeCacheURL
                )
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: runtimeAssetStore
                )
                let downloaded = try await store.getOrDownloadArtifact(for: flow)
                guard let sharedRuntimeURL = downloaded.localAssetURL(
                    forRiveUniqueName: "test-image"
                ) else {
                    fail("Expected initially prepared image")
                    return
                }
                try FileManager.default.removeItem(
                    at: downloaded.directoryURL.appendingPathComponent(missingFirstPath)
                )
                try FileManager.default.removeItem(at: sharedRuntimeURL)

                let cached = try await store.getCachedArtifact(for: flow)

                expect(
                    cached?.localAssetURL(forRiveUniqueName: "missing-first-image")
                ).to(beNil())
                guard let validURL = cached?.localAssetURL(
                    forRiveUniqueName: "test-image"
                ) else {
                    fail("Expected valid image after the earlier optional failure")
                    return
                }
                expect(try Data(contentsOf: validURL)).to(equal(imageData))
                expect(
                    FileManager.default.fileExists(
                        atPath: downloaded.directoryURL.appendingPathComponent(imagePath).path
                    )
                ).to(beTrue())
            }

            it("does not let a bad optional font poison valid content with the same hash") {
                let fixture = try writeFixtureArtifact(
                    includeFontAsset: true,
                    fontRequired: false
                )
                guard let fontData = fixture.fontData else {
                    fail("Expected font fixture")
                    return
                }
                let validFontURL = fixture.baseURL
                    .appendingPathComponent("external-fonts/test-font.ttf")
                let missingFontURL = fixture.baseURL
                    .appendingPathComponent("external-fonts/missing-first.ttf")
                let flow = try rewritingRemoteManifest(
                    in: fixture.flow,
                    at: fixture.baseURL
                ) { object in
                    var assets = object["assets"] as! [String: Any]
                    let existingFonts = assets["fonts"] as! [[String: Any]]
                    let firstFont: [String: Any] = [
                        "riveAssetId": 3,
                        "riveUniqueName": "bad-first-font",
                        "requestKey": "Inter:400:bad-first",
                        "family": "Inter",
                        "weight": "400",
                        "style": "normal",
                        "assetUrl": missingFontURL.absoluteString,
                        "sha256": FlowArtifactStore.sha256Hex(fontData),
                        "sizeBytes": fontData.count,
                        "contentType": "font/ttf",
                        "format": "ttf",
                        "required": false,
                    ]
                    assets["fonts"] = [firstFont] + existingFonts
                    object["assets"] = assets
                }
                expect(FileManager.default.fileExists(atPath: validFontURL.path)).to(beTrue())
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(
                        cacheDirectory: fixture.runtimeCacheURL
                    )
                )

                let loaded = try await store.getOrDownloadArtifact(for: flow)

                expect(loaded.localAssetURL(forRiveUniqueName: "bad-first-font")).to(beNil())
                guard let validURL = loaded.localAssetURL(
                    forRiveUniqueName: "test-font"
                ) else {
                    fail("Expected valid font after the earlier optional failure")
                    return
                }
                expect(try Data(contentsOf: validURL)).to(equal(fontData))
            }

            it("validates each image descriptor before reusing verified content") {
                let fixture = try writeFixtureArtifact(
                    includeImageAsset: true,
                    imageRequired: false
                )
                guard let imageData = fixture.imageData,
                      let imagePath = fixture.imagePath else {
                    fail("Expected image fixture")
                    return
                }
                let flow = try rewritingRemoteManifest(
                    in: fixture.flow,
                    at: fixture.baseURL
                ) { object in
                    var assets = object["assets"] as! [String: Any]
                    var images = assets["images"] as! [[String: Any]]
                    images.append([
                        "riveAssetId": 3,
                        "riveUniqueName": "invalid-reused-image",
                        "sourceAssetKey": "invalid-reused-image-source",
                        "path": imagePath,
                        "sha256": FlowArtifactStore.sha256Hex(imageData),
                        "contentType": "application/octet-stream",
                        "width": 1,
                        "height": 1,
                        "required": false,
                    ])
                    assets["images"] = images
                    object["assets"] = assets
                }
                let loaded = try await FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(
                        cacheDirectory: fixture.runtimeCacheURL
                    )
                ).getOrDownloadArtifact(for: flow)

                expect(loaded.localAssetURL(forRiveUniqueName: "test-image")).notTo(beNil())
                expect(
                    loaded.localAssetURL(forRiveUniqueName: "invalid-reused-image")
                ).to(beNil())
            }

            it("validates font size format and content type before content reuse") {
                let fixture = try writeFixtureArtifact(
                    includeFontAsset: true,
                    fontRequired: false
                )
                guard let fontData = fixture.fontData else {
                    fail("Expected font fixture")
                    return
                }
                let validFontURL = fixture.baseURL
                    .appendingPathComponent("external-fonts/test-font.ttf")
                let hash = FlowArtifactStore.sha256Hex(fontData)
                let flow = try rewritingRemoteManifest(
                    in: fixture.flow,
                    at: fixture.baseURL
                ) { object in
                    var assets = object["assets"] as! [String: Any]
                    var fonts = assets["fonts"] as! [[String: Any]]
                    func descriptor(
                        id: Int,
                        name: String,
                        size: Int,
                        contentType: String,
                        format: String
                    ) -> [String: Any] {
                        [
                            "riveAssetId": id,
                            "riveUniqueName": name,
                            "requestKey": "Inter:400:\(name)",
                            "family": "Inter",
                            "weight": "400",
                            "style": "normal",
                            "assetUrl": validFontURL.absoluteString,
                            "sha256": hash,
                            "sizeBytes": size,
                            "contentType": contentType,
                            "format": format,
                            "required": false,
                        ]
                    }
                    fonts.append(descriptor(
                        id: 3,
                        name: "wrong-sized-reused-font",
                        size: fontData.count - 1,
                        contentType: "font/ttf",
                        format: "ttf"
                    ))
                    fonts.append(descriptor(
                        id: 4,
                        name: "bad-format-reused-font",
                        size: fontData.count,
                        contentType: "font/ttf",
                        format: "woff"
                    ))
                    fonts.append(descriptor(
                        id: 5,
                        name: "bad-content-type-reused-font",
                        size: fontData.count,
                        contentType: "text/plain",
                        format: "ttf"
                    ))
                    assets["fonts"] = fonts
                    object["assets"] = assets
                }
                let loaded = try await FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(
                        cacheDirectory: fixture.runtimeCacheURL
                    )
                ).getOrDownloadArtifact(for: flow)

                expect(loaded.localAssetURL(forRiveUniqueName: "test-font")).notTo(beNil())
                expect(
                    loaded.localAssetURL(forRiveUniqueName: "wrong-sized-reused-font")
                ).to(beNil())
                expect(
                    loaded.localAssetURL(forRiveUniqueName: "bad-format-reused-font")
                ).to(beNil())
                expect(
                    loaded.localAssetURL(forRiveUniqueName: "bad-content-type-reused-font")
                ).to(beNil())
            }

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

            it("coalesces a caller that arrives after the manifest is downloaded") {
                let fixture = try writeFixtureArtifact()
                let baseURL = URL(string: "https://flows.nuxie.test/coalesced")!
                let flow = replacingBuildManifest(
                    in: fixture.flow,
                    with: fixture.flow.remoteFlow.flowArtifact.manifest,
                    baseURL: baseURL
                )
                let manifestData = try Data(
                    contentsOf: fixture.baseURL.appendingPathComponent("nuxie-manifest.json")
                )
                let gate = FlowArtifactDownloadGate()
                StubURLProtocol.reset()
                defer {
                    gate.release()
                    StubURLProtocol.reset()
                }
                StubURLProtocol.registerSuccess(
                    path: "/coalesced/nuxie-manifest.json",
                    data: manifestData,
                    headers: ["Content-Length": "\(manifestData.count)"]
                )
                StubURLProtocol.register(
                    matcher: { $0.url?.path == "/coalesced/flow.riv" },
                    handler: { request in
                        gate.startAndWait()
                        let response = HTTPURLResponse(
                            url: request.url!,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: [
                                "Content-Length": "\(fixture.rivData.count)",
                            ]
                        )!
                        return (response, fixture.rivData)
                    }
                )
                let store = FlowArtifactStore(
                    urlSession: TestURLSessionProvider.createTestSession(),
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(
                        cacheDirectory: fixture.runtimeCacheURL
                    )
                )

                let first = Task {
                    try await store.getOrDownloadArtifact(for: flow)
                }
                await expect { gate.didStart }
                    .toEventually(beTrue(), timeout: .seconds(2))
                let second = Task {
                    try await store.getOrDownloadArtifact(for: flow)
                }
                try await Task.sleep(nanoseconds: 50_000_000)
                gate.release()

                let firstArtifact = try await first.value
                let secondArtifact = try await second.value
                expect(firstArtifact.manifestURL.path).to(equal(secondArtifact.manifestURL.path))
                expect(FileManager.default.fileExists(atPath: firstArtifact.manifestURL.path))
                    .to(beTrue())
                let cachedArtifact = try await store.getCachedArtifact(for: flow)
                expect(cachedArtifact).notTo(beNil())
            }

            it("coordinates publication across independent stores sharing a cache") {
                let fixture = try writeFixtureArtifact()
                let baseURL = URL(string: "https://flows.nuxie.test/shared-store-cache")!
                let flow = replacingBuildManifest(
                    in: fixture.flow,
                    with: fixture.flow.remoteFlow.flowArtifact.manifest,
                    baseURL: baseURL
                )
                let manifestData = try Data(
                    contentsOf: fixture.baseURL.appendingPathComponent(
                        FlowArtifactStore.manifestPath
                    )
                )
                let gate = FlowArtifactDownloadGate()
                let requestLock = NSLock()
                var rivRequestCount = 0
                StubURLProtocol.reset()
                defer {
                    gate.release()
                    StubURLProtocol.reset()
                }
                StubURLProtocol.registerSuccess(
                    path: "/shared-store-cache/\(FlowArtifactStore.manifestPath)",
                    data: manifestData,
                    headers: ["Content-Length": "\(manifestData.count)"]
                )
                StubURLProtocol.register(
                    matcher: { $0.url?.path == "/shared-store-cache/flow.riv" },
                    handler: { request in
                        let shouldWait = requestLock.withLock {
                            rivRequestCount += 1
                            return rivRequestCount == 1
                        }
                        if shouldWait {
                            gate.startAndWait()
                        }
                        let response = HTTPURLResponse(
                            url: request.url!,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: [
                                "Content-Length": "\(fixture.rivData.count)",
                            ]
                        )!
                        return (response, fixture.rivData)
                    }
                )
                let session = TestURLSessionProvider.createTestSession()
                let firstStore = FlowArtifactStore(
                    urlSession: session,
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(
                        cacheDirectory: fixture.runtimeCacheURL
                    )
                )
                let secondStore = FlowArtifactStore(
                    urlSession: session,
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(
                        cacheDirectory: fixture.runtimeCacheURL
                    )
                )

                async let first = firstStore.getOrDownloadArtifact(for: flow)
                await expect { gate.didStart }
                    .toEventually(beTrue(), timeout: .seconds(2))
                async let second = secondStore.getOrDownloadArtifact(for: flow)
                try await Task.sleep(nanoseconds: 50_000_000)
                gate.release()

                let artifacts = try await [first, second]
                expect(artifacts[0].manifestURL.path).to(equal(artifacts[1].manifestURL.path))
                expect(artifacts.map(\.source)).to(contain(.downloadedArtifact, .cachedArtifact))
                let observedRivRequests = requestLock.withLock { rivRequestCount }
                expect(observedRivRequests).to(equal(1))
            }

            it("cancels and cleans a matching active download when removed") {
                let fixture = try writeFixtureArtifact()
                let baseURL = URL(string: "https://flows.nuxie.test/remove-active")!
                let flow = replacingBuildManifest(
                    in: fixture.flow,
                    with: fixture.flow.remoteFlow.flowArtifact.manifest,
                    baseURL: baseURL
                )
                let manifestData = try Data(
                    contentsOf: fixture.baseURL.appendingPathComponent(
                        FlowArtifactStore.manifestPath
                    )
                )
                let gate = FlowArtifactDownloadGate()
                StubURLProtocol.reset()
                defer {
                    gate.release()
                    StubURLProtocol.reset()
                }
                StubURLProtocol.registerSuccess(
                    path: "/remove-active/\(FlowArtifactStore.manifestPath)",
                    data: manifestData,
                    headers: ["Content-Length": "\(manifestData.count)"]
                )
                StubURLProtocol.register(
                    matcher: { $0.url?.path == "/remove-active/flow.riv" },
                    handler: { request in
                        gate.startAndWait()
                        let response = HTTPURLResponse(
                            url: request.url!,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: [
                                "Content-Length": "\(fixture.rivData.count)",
                            ]
                        )!
                        return (response, fixture.rivData)
                    }
                )
                let store = FlowArtifactStore(
                    urlSession: TestURLSessionProvider.createTestSession(),
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(
                        cacheDirectory: fixture.runtimeCacheURL
                    )
                )
                let download = Task {
                    try await store.getOrDownloadArtifact(for: flow)
                }
                await expect { gate.didStart }
                    .toEventually(beTrue(), timeout: .seconds(2))

                await store.removeArtifact(for: flow.id)
                gate.release()

                await expect {
                    try await download.value
                }.to(throwError(CancellationError()))
                expect(
                    try FileManager.default.contentsOfDirectory(
                        at: fixture.cacheURL,
                        includingPropertiesForKeys: nil
                    )
                ).to(beEmpty())
            }

            it("cancels and cleans every active download when cleared") {
                let fixture = try writeFixtureArtifact()
                let baseURL = URL(string: "https://flows.nuxie.test/clear-active")!
                let flow = replacingBuildManifest(
                    in: fixture.flow,
                    with: fixture.flow.remoteFlow.flowArtifact.manifest,
                    baseURL: baseURL
                )
                let manifestData = try Data(
                    contentsOf: fixture.baseURL.appendingPathComponent(
                        FlowArtifactStore.manifestPath
                    )
                )
                let gate = FlowArtifactDownloadGate()
                StubURLProtocol.reset()
                defer {
                    gate.release()
                    StubURLProtocol.reset()
                }
                StubURLProtocol.registerSuccess(
                    path: "/clear-active/\(FlowArtifactStore.manifestPath)",
                    data: manifestData,
                    headers: ["Content-Length": "\(manifestData.count)"]
                )
                StubURLProtocol.register(
                    matcher: { $0.url?.path == "/clear-active/flow.riv" },
                    handler: { request in
                        gate.startAndWait()
                        let response = HTTPURLResponse(
                            url: request.url!,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: [
                                "Content-Length": "\(fixture.rivData.count)",
                            ]
                        )!
                        return (response, fixture.rivData)
                    }
                )
                let store = FlowArtifactStore(
                    urlSession: TestURLSessionProvider.createTestSession(),
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(
                        cacheDirectory: fixture.runtimeCacheURL
                    )
                )
                let download = Task {
                    try await store.getOrDownloadArtifact(for: flow)
                }
                await expect { gate.didStart }
                    .toEventually(beTrue(), timeout: .seconds(2))

                await store.clearAllArtifacts()
                gate.release()

                await expect {
                    try await download.value
                }.to(throwError(CancellationError()))
                expect(
                    try FileManager.default.contentsOfDirectory(
                        at: fixture.cacheURL,
                        includingPropertiesForKeys: nil
                    )
                ).to(beEmpty())
            }

            it("clears the canonical cache without replacing a configured root symlink") {
                let fixture = try writeFixtureArtifact()
                let rootURL = fixture.cacheURL.deletingLastPathComponent()
                let aliasURL = rootURL.appendingPathComponent("cache-alias")
                defer { try? FileManager.default.removeItem(at: rootURL) }
                try FileManager.default.createSymbolicLink(
                    at: aliasURL,
                    withDestinationURL: fixture.cacheURL
                )
                let store = FlowArtifactStore(
                    cacheDirectory: aliasURL,
                    runtimeAssetStore: RuntimeAssetStore(
                        cacheDirectory: fixture.runtimeCacheURL
                    )
                )
                _ = try await store.getOrDownloadArtifact(for: fixture.flow)

                await store.clearAllArtifacts()

                let aliasAttributes = try FileManager.default.attributesOfItem(
                    atPath: aliasURL.path
                )
                expect(aliasAttributes[.type] as? FileAttributeType)
                    .to(equal(.typeSymbolicLink))
                expect(
                    try FileManager.default.contentsOfDirectory(
                        at: fixture.cacheURL,
                        includingPropertiesForKeys: nil
                    )
                ).to(beEmpty())

                let freshStore = FlowArtifactStore(
                    cacheDirectory: aliasURL,
                    runtimeAssetStore: RuntimeAssetStore(
                        cacheDirectory: fixture.runtimeCacheURL
                    )
                )
                let reloaded = try await freshStore.getOrDownloadArtifact(
                    for: fixture.flow
                )
                expect(reloaded.source).to(equal(.downloadedArtifact))
                expect(reloaded.directoryURL.path.hasPrefix(fixture.cacheURL.path))
                    .to(beTrue())
            }

            it("enables device scripts only for artifacts with a verified manifest signature") {
                let signingKey = Curve25519.Signing.PrivateKey()
                let keyring = [
                    "test-key-1": signingKey.publicKey.rawRepresentation.base64EncodedString()
                ]
                let fixture = try writeFixtureArtifact(signManifest: { manifestData in
                    let signature = try signingKey.signature(for: manifestData)
                    return try JSONEncoder().encode(
                        FlowManifestSignature(
                            version: 1,
                            signs: "nuxie-manifest.json",
                            algorithm: "ed25519",
                            keyId: "test-key-1",
                            signatureBase64: signature.base64EncodedString()
                        )
                    )
                })
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL),
                    scriptTrustPolicy: FlowScriptTrustPolicy.ephemeral(
                        publicKeysBase64ByKeyId: keyring
                    )
                )

                let downloaded = try await store.getOrDownloadArtifact(for: fixture.flow)
                let exactManifestBytes = try Data(
                    contentsOf: fixture.baseURL.appendingPathComponent("nuxie-manifest.json")
                )
                let exactSignatureBytes = try Data(
                    contentsOf: fixture.baseURL.appendingPathComponent("nuxie-manifest.sig.json")
                )
                expect(downloaded.scriptsEnabled).to(beTrue())
                expect(downloaded.authorizationEvidence.signedContentBytes)
                    .to(equal(exactManifestBytes))
                expect(downloaded.authorizationEvidence.signatureEnvelopeBytes)
                    .to(equal(exactSignatureBytes))
                expect(downloaded.authorizationEvidence.selectedKey?.keyId)
                    .to(equal("test-key-1"))
                expect(downloaded.authorizationEvidence.selectedKey?.ed25519PublicKeyBytes)
                    .to(equal(signingKey.publicKey.rawRepresentation))

                let cached = try await store.getOrDownloadArtifact(for: fixture.flow)
                expect(cached.source).to(equal(.cachedArtifact))
                expect(cached.scriptsEnabled).to(beTrue())
                expect(cached.authorizationEvidence).to(
                    equal(downloaded.authorizationEvidence)
                )
            }

            it("keeps device scripts disabled for unsigned artifacts") {
                let fixture = try writeFixtureArtifact()
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL),
                    scriptTrustPolicy: FlowScriptTrustPolicy.ephemeral(
                        publicKeysBase64ByKeyId: [
                            "test-key-1": Curve25519.Signing.PrivateKey()
                                .publicKey.rawRepresentation.base64EncodedString()
                        ]
                    )
                )

                let downloaded = try await store.getOrDownloadArtifact(for: fixture.flow)
                expect(downloaded.scriptsEnabled).to(beFalse())
                expect(downloaded.authorizationEvidence.signedContentBytes).to(
                    equal(
                        try Data(
                            contentsOf: fixture.baseURL.appendingPathComponent(
                                "nuxie-manifest.json"
                            )
                        )
                    )
                )
                expect(downloaded.authorizationEvidence.signatureEnvelopeBytes).to(beNil())
                expect(downloaded.authorizationEvidence.selectedKey).to(beNil())
            }

            it("keeps device scripts disabled when the signature key is not pinned") {
                let signingKey = Curve25519.Signing.PrivateKey()
                let fixture = try writeFixtureArtifact(signManifest: { manifestData in
                    let signature = try signingKey.signature(for: manifestData)
                    return try JSONEncoder().encode(
                        FlowManifestSignature(
                            version: 1,
                            signs: "nuxie-manifest.json",
                            algorithm: "ed25519",
                            keyId: "unknown-key",
                            signatureBase64: signature.base64EncodedString()
                        )
                    )
                })
                // Default production keyring: empty until provisioned.
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(cacheDirectory: fixture.runtimeCacheURL)
                )

                let downloaded = try await store.getOrDownloadArtifact(for: fixture.flow)
                expect(downloaded.scriptsEnabled).to(beFalse())
                expect(downloaded.authorizationEvidence.signatureEnvelopeBytes).to(
                    equal(
                        try Data(
                            contentsOf: fixture.baseURL.appendingPathComponent(
                                "nuxie-manifest.sig.json"
                            )
                        )
                    )
                )
                expect(downloaded.authorizationEvidence.selectedKey).to(beNil())
            }

            it("preserves malformed authorization evidence for native diagnostics") {
                let malformedSignature = Data("{not-a-signature-envelope".utf8)
                let fixture = try writeFixtureArtifact(signManifest: { _ in
                    malformedSignature
                })
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(
                        cacheDirectory: fixture.runtimeCacheURL
                    ),
                    scriptTrustPolicy: FlowScriptTrustPolicy.ephemeral(
                        publicKeysBase64ByKeyId: [
                            "test-key-1": Curve25519.Signing.PrivateKey()
                                .publicKey.rawRepresentation.base64EncodedString()
                        ]
                    )
                )

                let downloaded = try await store.getOrDownloadArtifact(for: fixture.flow)

                expect(downloaded.scriptsEnabled).to(beFalse())
                expect(downloaded.authorizationEvidence.signatureEnvelopeBytes)
                    .to(equal(malformedSignature))
                expect(downloaded.authorizationEvidence.selectedKey).to(beNil())
            }

            it("bounds oversized authorization evidence as present malformed data") {
                let oversizedSignature = Data(
                    repeating: 0,
                    count: FlowRuntimeImportLimits.signatureEnvelopeBytes + 1
                )
                let fixture = try writeFixtureArtifact(signManifest: { _ in
                    oversizedSignature
                })
                let store = FlowArtifactStore(
                    cacheDirectory: fixture.cacheURL,
                    runtimeAssetStore: RuntimeAssetStore(
                        cacheDirectory: fixture.runtimeCacheURL
                    )
                )

                let downloaded = try await store.getOrDownloadArtifact(for: fixture.flow)

                expect(downloaded.scriptsEnabled).to(beFalse())
                expect(downloaded.authorizationEvidence.signatureEnvelopeBytes)
                    .to(equal(Data()))
                expect(downloaded.authorizationEvidence.selectedKey).to(beNil())
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
                      "maxLength": 72,
                      "responseFieldKey": "email"
                    }
                  ]
                }
                """.data(using: .utf8)!)

                expect(manifest.textInputs).to(haveCount(1))
                expect(manifest.textInputs[0].riveTextRunName).to(equal("email-input Run"))
                expect(manifest.textInputs[0].geometry.xPath).to(equal("nuxieTextInputs/input_email/x"))
                expect(manifest.textInputs[0].style.color).to(equal(0xff0f172a))
                expect(manifest.textInputs[0].style.fontAssetRiveUniqueName).to(
                    equal("font-inter-500-normal-e57198b3-0")
                )
                expect(manifest.textInputs[0].responseFieldKey).to(equal("email"))
            }

            it("decodes text inputs without a response field key as display-only") {
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
                      "inputId": "text-input/screen-1/notes-input",
                      "screenId": "screen-1",
                      "artboardId": "screen-1",
                      "viewNodeId": "notes-input",
                      "renderedNodeId": "notes-input",
                      "riveTextObjectKey": "artboard/screen-1/notes-input/text",
                      "riveTextRunObjectKey": "artboard/screen-1/notes-input/text-run",
                      "riveTextName": "notes-input",
                      "riveTextRunName": "notes-input Run",
                      "geometry": {
                        "xPath": "nuxieTextInputs/input_notes/x",
                        "yPath": "nuxieTextInputs/input_notes/y",
                        "widthPath": "nuxieTextInputs/input_notes/width",
                        "heightPath": "nuxieTextInputs/input_notes/height",
                        "rotationPath": "nuxieTextInputs/input_notes/rotation",
                        "scaleXPath": "nuxieTextInputs/input_notes/scaleX",
                        "scaleYPath": "nuxieTextInputs/input_notes/scaleY"
                      },
                      "style": {
                        "fontFamily": "Inter",
                        "fontWeight": "500",
                        "fontStyle": "normal",
                        "fontSize": 17,
                        "lineHeight": 24,
                        "letterSpacing": 0,
                        "color": 4279179050,
                        "fontAssetRiveUniqueName": "font-inter-500-normal-e57198b3-0"
                      },
                      "value": "",
                      "editable": true
                    }
                  ]
                }
                """.data(using: .utf8)!)

                expect(manifest.textInputs).to(haveCount(1))
                expect(manifest.textInputs[0].responseFieldKey).to(beNil())
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
