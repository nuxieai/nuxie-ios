import CryptoKit
import Foundation
import XCTest
@testable import Nuxie
@testable import NuxieRuntime
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ExperienceReleaseAcquisitionTests: XCTestCase {
    private let signingKey = try! Curve25519.Signing.PrivateKey(
        rawRepresentation: Data(repeating: 0x42, count: 32)
    )
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        StubURLProtocol.reset()
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testAuthenticatesAcquiresCachesAndBuildsNativeRuntimePayload() async throws {
        let riv = Data("RIVE descriptor fixture".utf8)
        let image = Data([1, 2, 3, 4])
        let script = Data("compiled luau".utf8)
        let (entry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script
        )
        let cache = temporaryDirectory()
        var requests: [String] = []
        let requestLock = NSLock()
        StubURLProtocol.register(
            matcher: { $0.url?.host == "cdn.nuxie.test" },
            handler: { request in
                requestLock.lock()
                requests.append(request.url!.path)
                requestLock.unlock()
                let bytes = request.url!.path.contains("/renders/")
                    ? riv
                    : (request.url!.path.hasSuffix(".bin") ? script : image)
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "Content-Length": "\(bytes.count)",
                            "Content-Type": request.url!.path.hasSuffix(".riv")
                                ? "application/vnd.rive"
                                : (request.url!.path.hasSuffix(".bin")
                                    ? "application/octet-stream" : "image/jpeg")
                        ]
                    )!,
                    bytes
                )
            }
        )
        let store = makeStore(cache: cache)

        let acquired = try await store.acquire(
            entry: entry,
            delivery: delivery,
            mode: .active,
            initialScreenID: "screen_welcome"
        )

        XCTAssertEqual(acquired.payload.sceneBytes, riv)
        XCTAssertEqual(acquired.payload.journey.screens.map(\.id), ["screen_welcome"])
        XCTAssertEqual(acquired.payload.renderPlan.entry.screenId, "screen_welcome")
        XCTAssertEqual(acquired.payload.assets.count, 1)
        XCTAssertEqual(acquired.payload.assets.first?.bytes, image)
        XCTAssertEqual(acquired.source, .download)
        let totalObjectBytes = riv.count + image.count + script.count
        XCTAssertEqual(
            acquired.resourceMetrics,
            ExperienceReleaseResourceMetrics(
                readBytes: totalObjectBytes * 2,
                hashedBytes: totalObjectBytes * 2,
                parsedBytes: 0,
                duplicateReadBytes: totalObjectBytes,
                duplicateHashBytes: totalObjectBytes,
                duplicateParseBytes: 0,
                preloadBytes: 0,
                unusedPreloadBytes: 0
            )
        )
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.contains { $0.hasSuffix(".bin") })

        StubURLProtocol.reset()
        let cached = try await store.acquire(
            entry: entry,
            delivery: delivery,
            mode: .active,
            initialScreenID: "screen_welcome"
        )
        XCTAssertEqual(cached.source, .cache)
        XCTAssertEqual(cached.payload.sceneBytes, riv)
        XCTAssertEqual(
            cached.resourceMetrics,
            ExperienceReleaseResourceMetrics(
                readBytes: totalObjectBytes,
                hashedBytes: totalObjectBytes,
                parsedBytes: 0,
                duplicateReadBytes: 0,
                duplicateHashBytes: 0,
                duplicateParseBytes: 0,
                preloadBytes: 0,
                unusedPreloadBytes: 0
            )
        )
        XCTAssertEqual(requests.count, 3)
    }

    func testResourceMetricsIncludeRejectedCacheReadBeforeReplacementDownload() async throws {
        let riv = Data("RIVE replacement metrics".utf8)
        let image = Data([1, 2, 3, 4])
        let script = Data("replacement script".utf8)
        let (entry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script
        )
        let cache = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: cache,
            withIntermediateDirectories: true
        )
        let corruptRIV = Data(repeating: 0x7f, count: riv.count)
        try corruptRIV.write(
            to: cache.appendingPathComponent(SHA256Provider.hexDigest(riv))
        )
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) {
            request in
            let bytes = request.url!.path.hasSuffix(".riv")
                ? riv
                : (request.url!.path.hasSuffix(".bin") ? script : image)
            let contentType = request.url!.path.hasSuffix(".riv")
                ? "application/vnd.rive"
                : (request.url!.path.hasSuffix(".bin")
                    ? "application/octet-stream" : "image/jpeg")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": contentType]
                )!,
                bytes
            )
        }

        let acquired = try await makeStore(cache: cache).acquire(
            entry: entry,
            delivery: delivery,
            mode: .active,
            initialScreenID: "screen_welcome"
        )

        let objectBytes = riv.count + image.count + script.count
        XCTAssertEqual(
            acquired.resourceMetrics.readBytes,
            objectBytes * 2 + corruptRIV.count
        )
        XCTAssertEqual(
            acquired.resourceMetrics.hashedBytes,
            objectBytes * 2 + corruptRIV.count
        )
        XCTAssertEqual(
            acquired.resourceMetrics.duplicateReadBytes,
            objectBytes + corruptRIV.count
        )
        XCTAssertEqual(
            acquired.resourceMetrics.duplicateHashBytes,
            objectBytes + corruptRIV.count
        )
    }

    func testDiskBudgetEvictsOldestReleaseWithoutDeletingCurrentObjects() async throws {
        let firstRIV = Data("RIVE first cache generation".utf8)
        let firstImage = Data("first image".utf8)
        let firstScript = Data("first script".utf8)
        let secondRIV = Data("RIVE second cache generation".utf8)
        let secondImage = Data("second image".utf8)
        let secondScript = Data("second script".utf8)
        let (firstEntry, delivery) = try releaseEntry(
            riv: firstRIV,
            image: firstImage,
            script: firstScript
        )
        let (secondBase, _) = try releaseEntry(
            riv: secondRIV,
            image: secondImage,
            script: secondScript
        )
        let secondEntry = try resign(entry: secondBase) { root in
            var identity = try XCTUnwrap(root["identity"] as? [String: Any])
            identity["experienceId"] = "experience-second-cache"
            identity["experienceVersionId"] = "version-second-cache"
            identity["buildId"] = "build-second-cache"
            identity["publishedAtSeq"] = 2
            root["identity"] = identity
        }
        let bytesByDigest = [
            SHA256Provider.hexDigest(firstRIV): firstRIV,
            SHA256Provider.hexDigest(firstImage): firstImage,
            SHA256Provider.hexDigest(firstScript): firstScript,
            SHA256Provider.hexDigest(secondRIV): secondRIV,
            SHA256Provider.hexDigest(secondImage): secondImage,
            SHA256Provider.hexDigest(secondScript): secondScript,
        ]
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) {
            request in
            let digest = try XCTUnwrap(
                request.url?.deletingPathExtension().lastPathComponent
            )
            let bytes = try XCTUnwrap(bytesByDigest[digest])
            let contentType = request.url!.path.hasSuffix(".riv")
                ? "application/vnd.rive"
                : (request.url!.path.hasSuffix(".bin")
                    ? "application/octet-stream" : "image/jpeg")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": contentType]
                )!,
                bytes
            )
        }
        let cache = temporaryDirectory()
        let secondFootprint = secondRIV.count + secondImage.count + secondScript.count
        let store = makeStore(
            cache: cache,
            maximumCacheBytes: secondFootprint
        )

        _ = try await store.acquire(
            entry: firstEntry,
            delivery: delivery,
            mode: .active,
            initialScreenID: "screen_welcome"
        )
        _ = try await store.acquire(
            entry: secondEntry,
            delivery: delivery,
            mode: .active,
            initialScreenID: "screen_welcome"
        )

        for bytes in [firstRIV, firstImage, firstScript] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: cache.appendingPathComponent(
                    SHA256Provider.hexDigest(bytes)
                ).path
            ))
        }
        for bytes in [secondRIV, secondImage, secondScript] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: cache.appendingPathComponent(
                    SHA256Provider.hexDigest(bytes)
                ).path
            ))
        }
    }

    func testConcurrentPruningProtectsEveryInFlightRelease() async throws {
        let firstScript = Data("first inflight script".utf8)
        let secondRIV = Data("RIVE inflight second".utf8)
        let secondImage = Data([13, 21, 34])
        let secondScript = Data("second inflight script".utf8)
        let (secondBase, delivery) = try releaseEntry(
            riv: secondRIV, image: secondImage, script: secondScript
        )
        let secondEntry = try resign(entry: secondBase) { root in
            var identity = try XCTUnwrap(root["identity"] as? [String: Any])
            identity["experienceId"] = "experience-inflight-second"
            identity["experienceVersionId"] = "version-inflight-second"
            identity["buildId"] = "build-inflight-second"
            identity["publishedAtSeq"] = 2
            root["identity"] = identity
        }
        let bytesByDigest = Dictionary(uniqueKeysWithValues: [
            secondRIV, secondImage, secondScript,
        ].map { (SHA256Provider.hexDigest($0), $0) })
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) {
            request in
            let digest = try XCTUnwrap(
                request.url?.deletingPathExtension().lastPathComponent
            )
            let bytes = try XCTUnwrap(bytesByDigest[digest])
            let contentType = request.url!.path.hasSuffix(".riv")
                ? "application/vnd.rive"
                : (request.url!.path.hasSuffix(".bin")
                    ? "application/octet-stream" : "image/jpeg")
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": contentType]
                )!, bytes
            )
        }
        let cache = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: cache,
            withIntermediateDirectories: true
        )
        let protectedDigest = SHA256Provider.hexDigest(firstScript)
        try firstScript.write(to: cache.appendingPathComponent(protectedDigest))
        let protectingRegistry = ExperienceReleaseCacheProtectionRegistry()
        let pruningRegistry = ExperienceReleaseCacheProtectionRegistry()
        let protectionID = try protectingRegistry.register(
            [protectedDigest],
            root: cache
        )
        defer {
            protectingRegistry.unregister(
                protectionID,
                root: cache
            )
        }
        XCTAssertEqual(
            try pruningRegistry.protectedDigests(root: cache),
            [protectedDigest],
            "independent processes must observe the same in-flight eviction fence"
        )
        let budget = secondRIV.count + secondImage.count + secondScript.count
        let secondStore = makeStore(cache: cache, maximumCacheBytes: budget)

        _ = try await secondStore.acquire(
            entry: secondEntry, delivery: delivery, mode: .active,
            initialScreenID: "screen_welcome"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cache.appendingPathComponent(
                protectedDigest
            ).path
        ))
    }

    func testPruningReadsCrossProcessProtectionsAfterAcquiringRootLock() async throws {
        let cache = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: cache,
            withIntermediateDirectories: true
        )
        let protectedBytes = Data("protected while pruning waits".utf8)
        let evictableBytes = Data("evictable after marker read".utf8)
        let protectedDigest = SHA256Provider.hexDigest(protectedBytes)
        let evictableDigest = SHA256Provider.hexDigest(evictableBytes)
        let protectedURL = cache.appendingPathComponent(protectedDigest)
        let evictableURL = cache.appendingPathComponent(evictableDigest)
        try protectedBytes.write(to: protectedURL)
        try evictableBytes.write(to: evictableURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: protectedURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2)],
            ofItemAtPath: evictableURL.path
        )

        let scope = CacheFilesystemLockScope(cacheRootURL: cache)
        let blockerGate = PreloadPreparationGate()
        let blocker = Task {
            try await CacheFilesystemLock.withTargetTransaction(
                scope: scope,
                targetURL: cache.appendingPathComponent("blocker")
            ) {
                await blockerGate.enterAndWait()
            }
        }
        await blockerGate.waitUntilEntered()

        let store = makeStore(
            cache: cache,
            maximumCacheBytes: evictableBytes.count
        )
        let pruning = Task {
            try await store.enforceCacheBudget(protecting: [])
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let registry = ExperienceReleaseCacheProtectionRegistry()
        let protectionID = try registry.register([protectedDigest], root: cache)
        defer { registry.unregister(protectionID, root: cache) }
        await blockerGate.release()
        try await blocker.value
        try await pruning.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: evictableURL.path))
    }

    func testMalformedCrossProcessProtectionMarkerIsRemovedAsStale() throws {
        let cache = temporaryDirectory()
        let markerDirectory = CacheFilesystemLockScope(
            cacheRootURL: cache
        ).protectionDirectoryURL
        try FileManager.default.createDirectory(
            at: markerDirectory,
            withIntermediateDirectories: true
        )
        let markerURL = markerDirectory.appendingPathComponent("malformed.json")
        try Data("not-json".utf8).write(to: markerURL)

        XCTAssertEqual(
            try ExperienceReleaseCacheProtectionRegistry().protectedDigests(
                root: cache
            ),
            []
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testProtectionMarkerFromReusedLivePIDIsRemovedAsStale() throws {
        let cache = temporaryDirectory()
        let markerDirectory = CacheFilesystemLockScope(
            cacheRootURL: cache
        ).protectionDirectoryURL
        try FileManager.default.createDirectory(
            at: markerDirectory,
            withIntermediateDirectories: true
        )
        let protectedDigest = SHA256Provider.hexDigest(Data("stale".utf8))
        let markerURL = markerDirectory.appendingPathComponent("reused-pid.json")
        let marker = try JSONSerialization.data(withJSONObject: [
            "processID": ProcessInfo.processInfo.processIdentifier,
            "processStartTimeMicroseconds": 0,
            "digests": [protectedDigest],
        ])
        try marker.write(to: markerURL)

        XCTAssertEqual(
            try ExperienceReleaseCacheProtectionRegistry().protectedDigests(
                root: cache
            ),
            []
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testMissingOptionalRenderAssetSucceedsWithoutPublishingItsBytes() async throws {
        let riv = Data("RIVE optional asset".utf8)
        let image = Data([1, 2, 3, 4])
        let script = Data("compiled luau".utf8)
        let (entry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script,
            imageRequired: false
        )
        StubURLProtocol.register(
            matcher: { $0.url?.host == "cdn.nuxie.test" },
            handler: { request in
                if request.url!.path.hasSuffix(".jpg") {
                    return (
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 404,
                            httpVersion: nil,
                            headerFields: nil
                        )!,
                        nil
                    )
                }
                let bytes = request.url!.path.hasSuffix(".riv") ? riv : script
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "Content-Type": request.url!.path.hasSuffix(".riv")
                                ? "application/vnd.rive"
                                : "application/octet-stream"
                        ]
                    )!,
                    bytes
                )
            }
        )

        let acquired = try await makeStore(cache: temporaryDirectory()).acquire(
            entry: entry,
            delivery: delivery,
            mode: .active,
            initialScreenID: "screen_welcome"
        )

        let asset = try XCTUnwrap(acquired.payload.assets.first)
        XCTAssertFalse(asset.required)
        XCTAssertNil(asset.bytes)
        XCTAssertNil(acquired.objectURLsByKey[asset.sourceKey])
        XCTAssertEqual(acquired.payload.sceneBytes, riv)
    }

    func testRejectedOptionalAssetDigestWorkIsReportedWithoutPublishingItsBytes() async throws {
        let riv = Data("RIVE optional digest metrics".utf8)
        let image = Data([1, 2, 3, 4])
        let rejectedImage = Data([4, 3, 2, 1])
        let script = Data("optional digest script".utf8)
        let (entry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script,
            imageRequired: false
        )
        StubURLProtocol.register(
            matcher: { $0.url?.host == "cdn.nuxie.test" },
            handler: { request in
                let bytes = request.url!.path.hasSuffix(".riv")
                    ? riv
                    : (request.url!.path.hasSuffix(".bin")
                        ? script : rejectedImage)
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "Content-Type": request.url!.path.hasSuffix(".riv")
                                ? "application/vnd.rive"
                                : (request.url!.path.hasSuffix(".bin")
                                    ? "application/octet-stream" : "image/jpeg")
                        ]
                    )!,
                    bytes
                )
            }
        )

        let acquired = try await makeStore(cache: temporaryDirectory()).acquire(
            entry: entry,
            delivery: delivery,
            mode: .active,
            initialScreenID: "screen_welcome"
        )

        let asset = try XCTUnwrap(acquired.payload.assets.first)
        XCTAssertNil(asset.bytes)
        XCTAssertNil(acquired.objectURLsByKey[asset.sourceKey])
        let successfulObjectBytes = riv.count + script.count
        XCTAssertEqual(
            acquired.resourceMetrics.readBytes,
            successfulObjectBytes * 2 + rejectedImage.count
        )
        XCTAssertEqual(
            acquired.resourceMetrics.hashedBytes,
            successfulObjectBytes * 2 + rejectedImage.count
        )
        XCTAssertEqual(
            acquired.resourceMetrics.duplicateReadBytes,
            successfulObjectBytes
        )
        XCTAssertEqual(
            acquired.resourceMetrics.duplicateHashBytes,
            successfulObjectBytes
        )
    }

    func testMissingRequiredRenderAssetFailsClosed() async throws {
        let riv = Data("RIVE required asset".utf8)
        let image = Data([1, 2, 3, 4])
        let script = Data("compiled luau".utf8)
        let (entry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script,
            imageRequired: true
        )
        StubURLProtocol.register(
            matcher: { $0.url?.host == "cdn.nuxie.test" },
            handler: { request in
                if request.url!.path.hasSuffix(".jpg") {
                    return (
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 404,
                            httpVersion: nil,
                            headerFields: nil
                        )!,
                        nil
                    )
                }
                let bytes = request.url!.path.hasSuffix(".riv") ? riv : script
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "Content-Type": request.url!.path.hasSuffix(".riv")
                                ? "application/vnd.rive"
                                : "application/octet-stream"
                        ]
                    )!,
                    bytes
                )
            }
        )

        do {
            _ = try await makeStore(cache: temporaryDirectory()).acquire(
                entry: entry,
                delivery: delivery,
                mode: .active,
                initialScreenID: "screen_welcome"
            )
            XCTFail("expected required asset acquisition to fail")
        } catch let error as ExperienceReleaseAcquisitionError {
            XCTAssertEqual(
                error.contractCode,
                "experience_release.artifact.content_type_mismatch"
            )
        }
    }

    func testOptionalRenderAssetCannotEscapeItsSignedOrigin() async throws {
        let riv = Data("RIVE optional redirect".utf8)
        let image = Data([4, 3, 2, 1])
        let script = Data("redirect script".utf8)
        let (entry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script,
            imageRequired: false
        )
        StubURLProtocol.register(
            matcher: { $0.url?.host == "cdn.nuxie.test" },
            handler: { request in
                if request.url!.path.hasSuffix(".jpg") {
                    return (
                        HTTPURLResponse(
                            url: URL(string: "https://evil.example/optional.jpg")!,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: ["Content-Type": "image/jpeg"]
                        )!,
                        image
                    )
                }
                let bytes = request.url!.path.hasSuffix(".riv") ? riv : script
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "Content-Type": request.url!.path.hasSuffix(".riv")
                                ? "application/vnd.rive"
                                : "application/octet-stream"
                        ]
                    )!,
                    bytes
                )
            }
        )

        do {
            _ = try await makeStore(cache: temporaryDirectory()).acquire(
                entry: entry,
                delivery: delivery,
                mode: .active,
                initialScreenID: "screen_welcome"
            )
            XCTFail("expected optional redirect confinement failure")
        } catch let error as ExperienceReleaseAcquisitionError {
            XCTAssertEqual(
                error.contractCode,
                "experience_release.delivery.redirect_origin"
            )
        }
    }

    func testCancellationIsNotSwallowedByMissingOptionalRenderAsset() async throws {
        let riv = Data("RIVE cached during cancellation".utf8)
        let image = Data([5, 5, 5])
        let script = Data("cached cancellation script".utf8)
        let (entry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script,
            imageRequired: false
        )
        let cache = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: cache,
            withIntermediateDirectories: true
        )
        try riv.write(to: cache.appendingPathComponent(SHA256Provider.hexDigest(riv)))
        try script.write(to: cache.appendingPathComponent(SHA256Provider.hexDigest(script)))
        let optionalRequestStarted = DispatchSemaphore(value: 0)
        let releaseOptionalRequest = DispatchSemaphore(value: 0)
        var requests = 0
        StubURLProtocol.register(matcher: { _ in true }) { request in
            requests += 1
            optionalRequestStarted.signal()
            _ = releaseOptionalRequest.wait(timeout: .now() + 3)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                nil
            )
        }
        let store = makeStore(cache: cache)
        let task = Task {
            return try await store.acquire(
                entry: entry,
                delivery: delivery,
                mode: .active,
                initialScreenID: "screen_welcome"
            )
        }

        XCTAssertEqual(optionalRequestStarted.wait(timeout: .now() + 2), .success)
        task.cancel()
        releaseOptionalRequest.signal()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(requests, 1)
    }

    func testRequiredReferenceWinsOptionalReferenceForSameArtifact() async throws {
        let riv = Data("RIVE shared requirement".utf8)
        let image = Data([6, 6, 6])
        let script = Data("shared exact artifact".utf8)
        var (entry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script,
            imageRequired: false
        )
        entry = try resign(entry: entry) { root in
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            var assets = try XCTUnwrap(render["assets"] as? [[String: Any]])
            let journey = try XCTUnwrap(root["journey"] as? [String: Any])
            let scripts = try XCTUnwrap(
                journey["scripts"] as? [String: [[String: Any]]]
            )
            let refs = try XCTUnwrap(scripts["screen_welcome"])
            var optionalAlias = try XCTUnwrap(
                refs.first?["artifact"] as? [String: Any]
            )
            optionalAlias["kind"] = "script"
            optionalAlias["required"] = false
            assets.append(optionalAlias)
            assets.sort {
                ($0["key"] as? String ?? "") < ($1["key"] as? String ?? "")
            }
            render["assets"] = assets
            root["render"] = render
        }
        StubURLProtocol.register(
            matcher: { $0.url?.host == "cdn.nuxie.test" },
            handler: { request in
                if request.url!.path.hasSuffix(".bin") {
                    return (
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 404,
                            httpVersion: nil,
                            headerFields: nil
                        )!,
                        nil
                    )
                }
                let bytes = request.url!.path.hasSuffix(".riv") ? riv : script
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "Content-Type": request.url!.path.hasSuffix(".riv")
                                ? "application/vnd.rive"
                                : "application/octet-stream"
                        ]
                    )!,
                    bytes
                )
            }
        )

        do {
            _ = try await makeStore(cache: temporaryDirectory()).acquire(
                entry: entry,
                delivery: delivery,
                mode: .active,
                initialScreenID: "screen_welcome"
            )
            XCTFail("expected shared required journey artifact to fail")
        } catch let error as ExperienceReleaseAcquisitionError {
            XCTAssertEqual(
                error.contractCode,
                "experience_release.artifact.content_type_mismatch"
            )
        }
    }

    func testRejectsLocatorIdentityBeforeObjectRequests() async throws {
        let riv = Data("RIVE descriptor fixture".utf8)
        let image = Data([1, 2, 3, 4])
        var (entry, delivery) = try releaseEntry(riv: riv, image: image)
        entry = ExperienceReleaseProfileEntryV2(
            locator: ExperienceReleaseIdentityV2(
                appId: entry.locator.appId,
                environment: entry.locator.environment,
                experienceId: "different",
                experienceVersionId: entry.locator.experienceVersionId,
                buildId: entry.locator.buildId,
                versionNumber: entry.locator.versionNumber,
                publishedAt: entry.locator.publishedAt,
                publishedAtSeq: entry.locator.publishedAtSeq
            ),
            descriptorSha256: entry.descriptorSha256,
            envelopeBytesBase64: entry.envelopeBytesBase64
        )
        var didRequest = false
        StubURLProtocol.register(matcher: { _ in true }) { request in
            didRequest = true
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, nil)
        }

        do {
            _ = try await makeStore(cache: temporaryDirectory()).acquire(
                entry: entry,
                delivery: delivery,
                mode: .active,
                initialScreenID: "screen_welcome"
            )
            XCTFail("expected identity mismatch")
        } catch {
            XCTAssertEqual(
                (error as? ExperienceReleaseDescriptorAuthenticationError)?.contractCode,
                "experience_release.identity.mismatch"
            )
        }
        XCTAssertFalse(didRequest)
    }

    func testRejectsArtifactDigestMismatchWithoutPublishingCacheEntry() async throws {
        let riv = Data("RIVE expected".utf8)
        let tamperedRIV = Data(repeating: 0x54, count: riv.count)
        let image = Data([1, 2, 3, 4])
        let script = Data("compiled luau".utf8)
        let (entry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script
        )
        let cache = temporaryDirectory()
        StubURLProtocol.register(
            matcher: { $0.url?.host == "cdn.nuxie.test" },
            handler: { request in
                let bytes = request.url!.path.contains("/renders/")
                    ? tamperedRIV
                    : (request.url!.path.hasSuffix(".bin") ? script : image)
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "Content-Type": request.url!.path.hasSuffix(".riv")
                                ? "application/vnd.rive"
                                : (request.url!.path.hasSuffix(".bin")
                                    ? "application/octet-stream" : "image/jpeg")
                        ]
                    )!,
                    bytes
                )
            }
        )

        let store = makeStore(cache: cache)
        do {
            _ = try await store.acquire(
                entry: entry,
                delivery: delivery,
                mode: .active,
                initialScreenID: "screen_welcome"
            )
            XCTFail("expected object rejection")
        } catch let error as ExperienceReleaseAcquisitionError {
            switch error {
            case .objectSizeMismatch, .objectDigestMismatch: break
            default: XCTFail("unexpected error \(error)")
            }
        }
        let cachedNames = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        XCTAssertFalse(cachedNames.contains(SHA256Provider.hexDigest(riv)))

        let catalog = try await store.authenticateProfile(.init(
            delivery: delivery,
            active: [entry],
            pinned: []
        ))
        let definition = try XCTUnwrap(catalog.definitions.first)
        do {
            _ = try await store.prepare(definition: definition)
            XCTFail("expected measured preparation failure")
        } catch let failure as ExperienceReleaseResourceFailure {
            XCTAssertEqual(
                (failure.underlying as? ExperienceReleaseAcquisitionError)?
                    .contractCode,
                "experience_release.artifact.digest_mismatch"
            )
            let successfulBytes = image.count + script.count
            XCTAssertEqual(
                failure.resourceMetrics.readBytes,
                successfulBytes + tamperedRIV.count
            )
            XCTAssertEqual(
                failure.resourceMetrics.hashedBytes,
                successfulBytes + tamperedRIV.count
            )
        }
    }

    func testConcurrentStoresPublishOneVerifiedCopyPerDigest() async throws {
        let riv = Data("RIVE concurrent atomic publication".utf8)
        let image = Data([9, 8, 7, 6])
        let script = Data("concurrent script".utf8)
        let (entry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script
        )
        let cache = temporaryDirectory()
        let requests = LockedRequestCounter()
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) {
            request in
            requests.increment()
            Thread.sleep(forTimeInterval: 0.02)
            let bytes = request.url!.path.hasSuffix(".riv")
                ? riv
                : (request.url!.path.hasSuffix(".bin") ? script : image)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Length": "\(bytes.count)",
                        "Content-Type": request.url!.path.hasSuffix(".riv")
                            ? "application/vnd.rive"
                            : (request.url!.path.hasSuffix(".bin")
                                ? "application/octet-stream" : "image/jpeg")
                    ]
                )!,
                bytes
            )
        }

        let firstStore = makeStore(cache: cache)
        let secondStore = makeStore(cache: cache)
        async let first = firstStore.acquire(
            entry: entry,
            delivery: delivery,
            mode: .active,
            initialScreenID: "screen_welcome"
        )
        async let second = secondStore.acquire(
            entry: entry,
            delivery: delivery,
            mode: .active,
            initialScreenID: "screen_welcome"
        )
        let results = try await [first, second]

        XCTAssertEqual(results.map(\.payload.sceneBytes), [riv, riv])
        XCTAssertEqual(requests.value, 3, "each content digest should download once")
        XCTAssertEqual(
            try Data(contentsOf: cache.appendingPathComponent(SHA256Provider.hexDigest(riv))),
            riv
        )
        let names = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })
    }

    func testInterruptedObjectLeavesNoPublishedBytesAndRetrySucceeds() async throws {
        let riv = Data("RIVE retry after interrupted transfer".utf8)
        let image = Data([1, 3, 5, 7])
        let script = Data("retry script".utf8)
        let (entry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script
        )
        let cache = temporaryDirectory()
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) {
            request in
            if request.url!.path.hasSuffix(".riv") {
                throw URLError(.networkConnectionLost)
            }
            let bytes = request.url!.path.hasSuffix(".bin") ? script : image
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Length": "\(bytes.count)",
                        "Content-Type": request.url!.path.hasSuffix(".bin")
                            ? "application/octet-stream" : "image/jpeg"
                    ]
                )!,
                bytes
            )
        }
        let store = makeStore(cache: cache)

        do {
            _ = try await store.acquire(
                entry: entry,
                delivery: delivery,
                mode: .active,
                initialScreenID: "screen_welcome"
            )
            XCTFail("expected interrupted RIV request")
        } catch {}

        let rivURL = cache.appendingPathComponent(SHA256Provider.hexDigest(riv))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rivURL.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: cache.path)
                .contains { $0.hasSuffix(".tmp") }
        )

        StubURLProtocol.reset()
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) {
            request in
            XCTAssertTrue(request.url!.path.hasSuffix(".riv"))
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Length": "\(riv.count)",
                        "Content-Type": "application/vnd.rive"
                    ]
                )!,
                riv
            )
        }
        let retried = try await store.acquire(
            entry: entry,
            delivery: delivery,
            mode: .active,
            initialScreenID: "screen_welcome"
        )

        XCTAssertEqual(retried.payload.sceneBytes, riv)
        XCTAssertEqual(try Data(contentsOf: rivURL), riv)
    }

    func testRejectsWrongSignedArtifactContentType() async throws {
        let riv = Data("RIVE expected".utf8)
        let image = Data([1, 2, 3, 4])
        let (entry, delivery) = try releaseEntry(riv: riv, image: image)
        var requests = 0
        StubURLProtocol.register(
            matcher: { $0.url?.host == "cdn.nuxie.test" },
            handler: { request in
                requests += 1
                let bytes = request.url!.path.hasSuffix(".riv") ? riv : image
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/octet-stream"]
                    )!,
                    bytes
                )
            }
        )

        do {
            _ = try await makeStore(cache: temporaryDirectory()).acquire(
                entry: entry,
                delivery: delivery,
                mode: .active,
                initialScreenID: "screen_welcome"
            )
            XCTFail("expected content type rejection")
        } catch let error as ExperienceReleaseAcquisitionError {
            XCTAssertEqual(error.contractCode, "experience_release.artifact.content_type_mismatch")
        }
        XCTAssertEqual(requests, 1)
    }

    func testUnavailableReplayAuthorityRejectsBeforeObjectRequests() async throws {
        let riv = Data("RIVE expected".utf8)
        let image = Data([1, 2, 3, 4])
        let (entry, delivery) = try releaseEntry(riv: riv, image: image)
        var requests = 0
        StubURLProtocol.register(matcher: { _ in true }) { request in
            requests += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, nil)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let store = ExperienceReleaseAcquisitionStore(
            cacheDirectory: temporaryDirectory(),
            urlSession: URLSession(configuration: config),
            authorizationKeys: [
                ExperiencePackageAuthorizationKey(
                    keyID: "TEST_ONLY_DEV_KEYPAIR",
                    ed25519PublicKeyBytes: signingKey.publicKey.rawRepresentation
                )
            ],
            supportedCompatibility: ExperienceReleaseRuntimeCompatibility.current,
            admission: ExperienceReleaseAdmission(store: UnavailableExperienceReleaseHighWaterStore())
        )

        do {
            _ = try await store.acquire(
                entry: entry,
                delivery: delivery,
                mode: .active,
                initialScreenID: "screen_welcome"
            )
            XCTFail("expected replay authority rejection")
        } catch {
            XCTAssertEqual(
                (error as? ExperienceReleaseDescriptorAuthenticationError)?.contractCode,
                "experience_release.replay.rejected"
            )
        }
        XCTAssertEqual(requests, 0)
    }

    func testRejectsUnsafeOriginAndUndeclaredInitialScreenBeforeFetch() async throws {
        let riv = Data("RIVE expected".utf8)
        let image = Data([1, 2, 3, 4])
        let (entry, delivery) = try releaseEntry(riv: riv, image: image)
        let store = makeStore(cache: temporaryDirectory())

        await assertAsyncThrows {
            _ = try await store.acquire(
                entry: entry,
                delivery: .init(
                    renderBaseUrl: "http://cdn.nuxie.test/renders/",
                    assetBaseUrl: delivery.assetBaseUrl
                ),
                mode: .active,
                initialScreenID: "screen_welcome"
            )
        } code: { ($0 as? ExperienceReleaseAcquisitionError)?.contractCode }

        await assertAsyncThrows {
            _ = try await store.acquire(
                entry: entry,
                delivery: delivery,
                mode: .active,
                initialScreenID: "screen_missing"
            )
        } code: { ($0 as? ExperienceReleaseAcquisitionError)?.contractCode }
    }

    func testActiveMembershipWinsPinnedOverlapAndPromotesHighWater() async throws {
        let riv = Data("RIVE overlap".utf8)
        let image = Data([1, 2, 3, 4])
        let script = Data("compiled luau".utf8)
        let (entry, delivery) = try releaseEntry(riv: riv, image: image, script: script)
        StubURLProtocol.register(
            matcher: { $0.url?.host == "cdn.nuxie.test" },
            handler: { request in
                let bytes = request.url!.path.hasSuffix(".riv")
                    ? riv
                    : (request.url!.path.hasSuffix(".bin") ? script : image)
                let type = request.url!.path.hasSuffix(".riv")
                    ? "application/vnd.rive"
                    : (request.url!.path.hasSuffix(".bin") ? "application/octet-stream" : "image/jpeg")
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": type]
                    )!,
                    bytes
                )
            }
        )
        let highWater = InMemoryExperienceReleaseHighWaterStore()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let releaseStore = ExperienceReleaseAcquisitionStore(
            cacheDirectory: temporaryDirectory(),
            urlSession: URLSession(configuration: config),
            authorizationKeys: [
                ExperiencePackageAuthorizationKey(
                    keyID: "TEST_ONLY_DEV_KEYPAIR",
                    ed25519PublicKeyBytes: signingKey.publicKey.rawRepresentation
                )
            ],
            supportedCompatibility: ExperienceReleaseRuntimeCompatibility.current,
            admission: ExperienceReleaseAdmission(store: highWater)
        )
        let store = ExperienceLoader(
            productService: ProductService(),
            releaseStore: releaseStore
        )
        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [entry],
            pinned: [entry]
        ))

        _ = try await store.experience(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId
        )

        let admitted = await highWater.highWater(for: .init(
            appId: entry.locator.appId,
            environment: entry.locator.environment,
            experienceId: entry.locator.experienceId
        ))
        XCTAssertEqual(admitted?.publishedAtSeq, entry.locator.publishedAtSeq)
    }

    func testExactPinnedDuplicatesDeduplicateAfterAuthentication() async throws {
        let (entry, delivery) = try releaseEntry(
            riv: Data("RIVE duplicate".utf8),
            image: Data([1, 2, 3])
        )
        let catalog = try await makeStore(cache: temporaryDirectory()).authenticateProfile(
            .init(delivery: delivery, active: [], pinned: [entry, entry])
        )
        XCTAssertEqual(catalog.definitions.count, 1)
        XCTAssertEqual(catalog.definitions.first?.mode, .pinned(
            experienceVersionId: entry.locator.experienceVersionId,
            buildId: entry.locator.buildId,
            descriptorSHA256: entry.descriptorSha256
        ))
    }

    func testInvalidReleaseIsReportedWithoutDiscardingUnrelatedRelease() async throws {
        let (valid, delivery) = try releaseEntry(
            riv: Data("RIVE isolated rejection".utf8),
            image: Data([8, 6, 4])
        )
        let invalidSource = try resign(entry: valid) { root in
            var identity = try XCTUnwrap(root["identity"] as? [String: Any])
            identity["experienceId"] = "experience-invalid-signature"
            identity["experienceVersionId"] = "version-invalid-signature"
            identity["buildId"] = "build-invalid-signature"
            root["identity"] = identity
        }
        let envelope = try JSONDecoder().decode(
            ExperienceReleaseDescriptorEnvelopeV2.self,
            from: invalidSource.exactEnvelopeBytes()
        )
        let invalidEnvelope = ExperienceReleaseDescriptorEnvelopeV2(
            mediaType: envelope.mediaType,
            encoding: envelope.encoding,
            descriptorSha256: envelope.descriptorSha256,
            descriptorSizeBytes: envelope.descriptorSizeBytes,
            descriptorBytesBase64: envelope.descriptorBytesBase64,
            signature: .init(
                version: envelope.signature.version,
                algorithm: envelope.signature.algorithm,
                keyId: envelope.signature.keyId,
                signatureBase64: Data(repeating: 0, count: 64).base64EncodedString()
            )
        )
        let invalid = ExperienceReleaseProfileEntryV2(
            locator: invalidSource.locator,
            descriptorSha256: invalidSource.descriptorSha256,
            envelopeBytes: try invalidEnvelope.canonicalBytes()
        )

        let catalog = try await makeStore(cache: temporaryDirectory()).authenticateProfile(
            .init(delivery: delivery, active: [valid, invalid], pinned: [])
        )

        XCTAssertEqual(catalog.definitions.map(\.reference), [ExperienceReference(
            experienceId: valid.locator.experienceId,
            versionId: valid.locator.experienceVersionId
        )])
        XCTAssertEqual(catalog.rejections.count, 1)
        XCTAssertEqual(
            catalog.rejections.first?.locator.experienceId,
            invalid.locator.experienceId
        )
        XCTAssertEqual(
            catalog.rejections.first?.contractCode,
            "experience_release.signature.bad_signature"
        )
    }

    func testActiveCatalogRetainsOnlyHighestAuthenticatedSequencePerReplayStream() async throws {
        let (entry, delivery) = try releaseEntry(
            riv: Data("RIVE active stream".utf8),
            image: Data([1, 2, 3])
        )
        let older = try resign(entry: entry) { root in
            var identity = try XCTUnwrap(root["identity"] as? [String: Any])
            identity["experienceVersionId"] = "version-older"
            identity["buildId"] = "build-older"
            identity["publishedAtSeq"] = 20
            root["identity"] = identity
        }
        let newer = try resign(entry: entry) { root in
            var identity = try XCTUnwrap(root["identity"] as? [String: Any])
            identity["experienceVersionId"] = "version-newer"
            identity["buildId"] = "build-newer"
            identity["publishedAtSeq"] = 21
            root["identity"] = identity
        }

        let catalog = try await makeStore(cache: temporaryDirectory()).authenticateProfile(
            .init(delivery: delivery, active: [older, newer], pinned: [])
        )

        XCTAssertEqual(catalog.definitions.map(\.reference.versionId), ["version-newer"])
    }

    func testActiveCatalogRejectsHighestSequenceTieWithDifferentRelease() async throws {
        let (entry, delivery) = try releaseEntry(
            riv: Data("RIVE tied stream".utf8),
            image: Data([2])
        )
        let conflicting = try resign(entry: entry) { root in
            var identity = try XCTUnwrap(root["identity"] as? [String: Any])
            identity["experienceVersionId"] = "different-version"
            identity["buildId"] = "different-build"
            root["identity"] = identity
        }

        do {
            _ = try await makeStore(cache: temporaryDirectory()).authenticateProfile(
                .init(delivery: delivery, active: [entry, conflicting], pinned: [])
            )
            XCTFail("expected tied active stream conflict")
        } catch {
            XCTAssertEqual(
                (error as? ExperienceReleaseDescriptorAuthenticationError)?.contractCode,
                "experience_release.replay.rejected"
            )
        }
    }

    func testAuthenticatedCatalogPreservesFullSignedReleaseIdentityAndDigest() async throws {
        let (entry, delivery) = try releaseEntry(
            riv: Data("RIVE release identity".utf8),
            image: Data([4, 5, 6])
        )

        let catalog = try await makeStore(cache: temporaryDirectory()).authenticateProfile(
            .init(delivery: delivery, active: [entry], pinned: [])
        )

        XCTAssertEqual(catalog.definitions.first?.releaseID.identity, entry.locator)
        XCTAssertEqual(
            catalog.definitions.first?.releaseID.descriptorSHA256,
            entry.descriptorSha256
        )
    }

    func testInstallRejectsDifferentFullSignedIdentitiesSharingLocalRoute() async throws {
        let (entry, delivery) = try releaseEntry(
            riv: Data("RIVE route collision".utf8),
            image: Data([3])
        )
        let otherApp = try resign(entry: entry) { root in
            var identity = try XCTUnwrap(root["identity"] as? [String: Any])
            identity["appId"] = "other-app"
            root["identity"] = identity
        }
        let highWater = InMemoryExperienceReleaseHighWaterStore()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let releaseStore = ExperienceReleaseAcquisitionStore(
            cacheDirectory: temporaryDirectory(),
            urlSession: URLSession(configuration: config),
            authorizationKeys: [
                ExperiencePackageAuthorizationKey(
                    keyID: "TEST_ONLY_DEV_KEYPAIR",
                    ed25519PublicKeyBytes: signingKey.publicKey.rawRepresentation
                )
            ],
            supportedCompatibility: ExperienceReleaseRuntimeCompatibility.current,
            admission: ExperienceReleaseAdmission(store: highWater)
        )
        let store = ExperienceLoader(
            productService: ProductService(),
            releaseStore: releaseStore
        )

        do {
            _ = try await store.replaceReleaseProfile(.init(
                delivery: delivery,
                active: [entry, otherApp],
                pinned: []
            ))
            XCTFail("expected local route collision to fail closed")
        } catch let error as ExperienceReleaseAcquisitionError {
            XCTAssertEqual(error, .invalidProfileEntry)
        }
        for appID in [entry.locator.appId, otherApp.locator.appId] {
            let promoted = await highWater.highWater(for: .init(
                appId: appID,
                environment: entry.locator.environment,
                experienceId: entry.locator.experienceId
            ))
            XCTAssertNil(promoted, "invalid catalog must not partially promote replay state")
        }
    }

    func testCanonicalEnvelopeMatchesJSONStringifyForLineSeparators() throws {
        let envelope = ExperienceReleaseDescriptorEnvelopeV2(
            mediaType: ExperienceReleaseDescriptorLimits.mediaType,
            encoding: "base64",
            descriptorSha256: String(repeating: "a", count: 64),
            descriptorSizeBytes: 1,
            descriptorBytesBase64: "eA==",
            signature: .init(
                version: 1,
                algorithm: "ed25519",
                keyId: "key\u{2028}line\u{2029}paragraph",
                signatureBase64: Data(repeating: 0, count: 64).base64EncodedString()
            )
        )
        let bytes = try envelope.canonicalBytes()
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))

        XCTAssertTrue(json.contains("\u{2028}"))
        XCTAssertTrue(json.contains("\u{2029}"))
        XCTAssertFalse(json.contains("\\u2028"))
        XCTAssertFalse(json.contains("\\u2029"))
    }

    func testCanonicalEnvelopePreservesLiteralLineSeparatorEscapeText() throws {
        let literalKeyID = #"key\u2028line\u2029paragraph"#
        let envelope = ExperienceReleaseDescriptorEnvelopeV2(
            mediaType: ExperienceReleaseDescriptorLimits.mediaType,
            encoding: "base64",
            descriptorSha256: String(repeating: "a", count: 64),
            descriptorSizeBytes: 1,
            descriptorBytesBase64: "eA==",
            signature: .init(
                version: 1,
                algorithm: "ed25519",
                keyId: literalKeyID,
                signatureBase64: Data(repeating: 0, count: 64).base64EncodedString()
            )
        )

        let bytes = try envelope.canonicalBytes()
        let decoded = try JSONDecoder().decode(
            ExperienceReleaseDescriptorEnvelopeV2.self,
            from: bytes
        )

        XCTAssertEqual(decoded.signature.keyId, literalKeyID)
    }

    func testProfileEntryRejectsReformattedEnvelopeBytes() throws {
        let (entry, _) = try releaseEntry(
            riv: Data("RIVE canonical".utf8),
            image: Data([9])
        )
        let object = try JSONSerialization.jsonObject(with: entry.exactEnvelopeBytes())
        let reformatted = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted]
        )
        let noncanonical = ExperienceReleaseProfileEntryV2(
            locator: entry.locator,
            descriptorSha256: entry.descriptorSha256,
            envelopeBytes: reformatted
        )

        XCTAssertThrowsError(try noncanonical.exactEnvelopeBytes())
    }

    func testProfileDescriptorBudgetDeduplicatesRepeatedDigestSize() throws {
        let (source, delivery) = try releaseEntry(
            riv: Data("RIVE budget".utf8),
            image: Data([8])
        )
        let entry = try budgetEntry(locator: source.locator, seed: 8)
        let profile = ExperienceReleaseProfileV2(
            delivery: delivery,
            active: Array(repeating: entry, count: 9),
            pinned: []
        )

        let decoded = try JSONDecoder().decode(
            ExperienceReleaseProfileV2.self,
            from: JSONEncoder().encode(profile)
        )
        XCTAssertEqual(decoded.active.count, 9)
    }

    func testProfileDescriptorBudgetRejectsUniqueDecodedDescriptorsOverLimit() throws {
        let (source, delivery) = try releaseEntry(
            riv: Data("RIVE unique budget".utf8),
            image: Data([8])
        )
        let entries = try (0..<9).map {
            try budgetEntry(locator: source.locator, seed: UInt8($0))
        }
        let profile = ExperienceReleaseProfileV2(
            delivery: delivery,
            active: entries,
            pinned: []
        )

        XCTAssertThrowsError(try JSONDecoder().decode(
            ExperienceReleaseProfileV2.self,
            from: JSONEncoder().encode(profile)
        ))
    }

    func testAdmissionKeepsServerOwnedSignedTriggersOutOfClientEnrollment() async throws {
        let (entry, delivery) = try releaseEntry(
            riv: Data("RIVE unsupported semantics".utf8),
            image: Data([6])
        )
        let triggerDocuments: [[String: Any]] = [
            [
                "type": "segment",
                "condition": [
                    "ir_version": 1,
                    "expr": [
                        "type": "Segment",
                        "op": "not_member",
                        "id": "segment_1",
                    ],
                ],
            ],
            ["type": "api"],
            [
                "type": "server_event",
                "connectorKey": "connector_1",
                "triggerKey": "trigger_1",
            ],
        ]
        let serverOwnedTriggers = try triggerDocuments.map { trigger in
            try resign(entry: entry) { root in
                var enrollment = try XCTUnwrap(root["enrollment"] as? [String: Any])
                enrollment["trigger"] = trigger
                root["enrollment"] = enrollment
            }
        }
        for serverOwned in serverOwnedTriggers {
            let catalog = try await makeStore(cache: temporaryDirectory()).authenticateProfile(.init(
                delivery: delivery,
                active: [serverOwned],
                pinned: []
            ))
            XCTAssertEqual(catalog.definitions.count, 1)
            XCTAssertNil(catalog.definitions.first?.behavior.trigger)
        }
    }

    func testAdmissionPreservesSignedPresentationStyleSemantics() async throws {
        let (entry, delivery) = try releaseEntry(
            riv: Data("RIVE unsupported presentation".utf8),
            image: Data([6])
        )
        let presentations = try ["sheet", "drawer"].map { style in
            try resign(entry: entry) { root in
                var presentation = try XCTUnwrap(root["presentation"] as? [String: Any])
                presentation["style"] = style
                if style == "sheet" {
                    presentation["sheet"] = [
                        "detent": "large",
                        "dismissible": true,
                    ]
                } else {
                    presentation["drawer"] = [
                        "edge": "bottom",
                        "extentRatio": 0.5,
                        "cornerRadius": 12,
                        "dismissible": true,
                    ]
                }
                root["presentation"] = presentation
            }
        }
        for (style, presentation) in zip(["sheet", "drawer"], presentations) {
            let catalog = try await makeStore(
                cache: temporaryDirectory()
            ).authenticateProfile(.init(
                delivery: delivery,
                active: [presentation],
                pinned: []
            ))
            XCTAssertEqual(catalog.definitions.count, 1)
            let admitted = try XCTUnwrap(catalog.definitions.first?.behavior.presentation)
            XCTAssertEqual(admitted.style.rawValue, style)
            XCTAssertEqual(admitted.orientation, .portrait)
            XCTAssertEqual(admitted.backgroundColor, "#0A0A0AFF")
            XCTAssertEqual(
                catalog.definitions.first?.behavior.presentationScreens["screen_welcome"],
                .init(width: 390, height: 844)
            )
            if style == "sheet" {
                XCTAssertEqual(admitted.sheet?.detent, .large)
                XCTAssertEqual(admitted.sheet?.dismissible, true)
                XCTAssertNil(admitted.drawer)
            } else {
                XCTAssertEqual(admitted.drawer?.edge, .bottom)
                XCTAssertEqual(admitted.drawer?.extentRatio, 0.5)
                XCTAssertEqual(admitted.drawer?.cornerRadius, 12)
                XCTAssertEqual(admitted.drawer?.dismissible, true)
                XCTAssertNil(admitted.sheet)
            }
        }
    }

    func testAdmissionUsesEnrollmentEventAsEntryRootAndStopsAtNavigateCommit() async throws {
        let (entry, delivery) = try releaseEntry(
            riv: Data("RIVE enrollment entry".utf8),
            image: Data([6, 5])
        )
        let admitted = try resign(entry: entry) { root in
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            journey["handlers"] = [
                JourneyDocument.journeyEventHostKey: [[
                    "id": "handler-enrollment",
                    "eventName": "launch_offer",
                    "actions": [
                        [
                            "type": "navigate",
                            "screenId": "screen_welcome",
                            "nodeId": "node-entry",
                        ],
                        [
                            "type": "send_event",
                            "eventName": "post_attach",
                            "nodeId": "node-post-attach",
                        ],
                    ],
                ]],
            ]
            root["journey"] = journey
            var enrollment = try XCTUnwrap(root["enrollment"] as? [String: Any])
            var trigger = try XCTUnwrap(enrollment["trigger"] as? [String: Any])
            trigger["eventName"] = "launch_offer"
            enrollment["trigger"] = trigger
            root["enrollment"] = enrollment
        }

        let catalog = try await makeStore(cache: temporaryDirectory()).authenticateProfile(
            .init(delivery: delivery, active: [admitted], pinned: [])
        )
        XCTAssertEqual(catalog.definitions.count, 1)

        let rejected = try resign(entry: admitted) { root in
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            journey["handlers"] = [
                JourneyDocument.journeyEventHostKey: [[
                    "id": "handler-enrollment",
                    "eventName": "launch_offer",
                    "actions": [
                        [
                            "type": "send_event",
                            "eventName": "pre_attach_side_effect",
                            "nodeId": "node-side-effect",
                        ],
                        [
                            "type": "navigate",
                            "screenId": "screen_welcome",
                            "nodeId": "node-entry",
                        ],
                    ],
                ]],
            ]
            root["journey"] = journey
        }
        do {
            _ = try await makeStore(cache: temporaryDirectory()).authenticateProfile(
                .init(delivery: delivery, active: [rejected], pinned: [])
            )
            XCTFail("expected a side effect before the presentation commit to fail closed")
        } catch let error as ExperienceReleaseAcquisitionError {
            XCTAssertEqual(error, .invalidProfileEntry)
        }
    }

    func testAdmissionSortsSameEventHandlersAndRejectsExperimentBeforeCommit() async throws {
        let (entry, delivery) = try releaseEntry(
            riv: Data("RIVE classifier ordering".utf8),
            image: Data([4, 2])
        )
        let orderedCommit = try resign(entry: entry) { root in
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            journey["handlers"] = [
                JourneyDocument.journeyEventHostKey: [
                    [
                        "id": "handler-post-attach",
                        "eventName": SystemEventNames.journeyStarted,
                        "order": 20,
                        "actions": [[
                            "type": "start_animation",
                            "animationId": "post_attach_animation",
                            "nodeId": "node-animation",
                        ]],
                    ],
                    [
                        "id": "handler-commit",
                        "eventName": SystemEventNames.journeyStarted,
                        "order": 10,
                        "actions": [[
                            "type": "navigate",
                            "screenId": "screen_welcome",
                            "nodeId": "node-navigate",
                        ]],
                    ],
                ],
            ]
            root["journey"] = journey
        }
        let catalog = try await makeStore(cache: temporaryDirectory()).authenticateProfile(
            .init(delivery: delivery, active: [orderedCommit], pinned: [])
        )
        XCTAssertEqual(catalog.definitions.count, 1)

        let experimentFirst = try resign(entry: entry) { root in
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            journey["handlers"] = [
                JourneyDocument.journeyEventHostKey: [[
                    "id": "handler-experiment",
                    "eventName": SystemEventNames.journeyStarted,
                    "actions": [
                        [
                            "type": "experiment",
                            "experimentId": "experiment-entry",
                            "variants": [[
                                "id": "control",
                                "percentage": 50,
                                "actions": [[
                                    "type": "navigate",
                                    "screenId": "screen_welcome",
                                ]],
                            ], [
                                "id": "variant",
                                "percentage": 50,
                                "actions": [[
                                    "type": "navigate",
                                    "screenId": "screen_welcome",
                                ]],
                            ]],
                        ],
                    ],
                ]],
            ]
            root["journey"] = journey
        }
        do {
            _ = try await makeStore(cache: temporaryDirectory()).authenticateProfile(
                .init(delivery: delivery, active: [experimentFirst], pinned: [])
            )
            XCTFail("expected experiment before commit to fail closed")
        } catch let error as ExperienceReleaseAcquisitionError {
            XCTAssertEqual(error, .invalidProfileEntry)
        }
    }

    func testInvalidReplacementDoesNotClearAuthenticatedCatalog() async throws {
        let (entry, delivery) = try releaseEntry(
            riv: Data("RIVE atomic".utf8),
            image: Data([4, 5, 6])
        )
        let releaseStore = makeStore(cache: temporaryDirectory())
        let store = ExperienceLoader(
            productService: ProductService(),
            releaseStore: releaseStore
        )
        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery, active: [entry], pinned: []
        ))
        let invalid = ExperienceReleaseProfileEntryV2(
            locator: entry.locator,
            descriptorSha256: String(repeating: "f", count: 64),
            envelopeBytes: try entry.exactEnvelopeBytes()
        )
        do {
            _ = try await store.replaceReleaseProfile(.init(
                delivery: delivery, active: [invalid], pinned: []
            ))
            XCTFail("expected invalid replacement")
        } catch {}

        let retained = try await store.experience(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId
        )
        XCTAssertEqual(retained.versionId, entry.locator.experienceVersionId)
    }

    func testReplacementDuringSignedLoadCannotCommitStaleAuthenticatedRelease() async throws {
        let riv = Data("RIVE stale load".utf8)
        let image = Data([7, 7, 7])
        let script = Data("stale script".utf8)
        let (baseEntry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script
        )
        let entry = try resign(entry: baseEntry) { root in
            root["products"] = [[
                "id": "com.nuxie.stale.monthly",
                "type": "subscription",
                "store": [
                    "platform": "apple_app_store",
                    "productId": "com.nuxie.stale.monthly",
                    "productType": "autoRenewable",
                ],
                "entitlements": [],
            ]]
            root["placements"] = [[
                "id": "paywall:monthly",
                "productId": "com.nuxie.stale.monthly",
            ]]
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            var screens = try XCTUnwrap(journey["screens"] as? [[String: Any]])
            var screen = try XCTUnwrap(screens.first)
            screen["defaultViewModelName"] = "vm.nuxie.paywall"
            screen["defaultInstanceId"] = "paywall"
            screens[0] = screen
            journey["screens"] = screens
            journey["viewModelValues"] = [[
                "viewModelName": "vm.nuxie.paywall",
                "instanceId": "paywall",
                "path": "products",
                "value": [[
                    "placementId": "paywall:monthly",
                    "productId": "com.nuxie.stale.monthly",
                ]],
            ]]
            root["journey"] = journey
        }
        let replacement = try resign(entry: entry) { root in
            var identity = try XCTUnwrap(root["identity"] as? [String: Any])
            identity["publishedAtSeq"] = entry.locator.publishedAtSeq + 1
            root["identity"] = identity
            var metadata = try XCTUnwrap(root["metadata"] as? [String: Any])
            metadata["name"] = "Replacement behavior"
            root["metadata"] = metadata
        }
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) { request in
            let bytes = request.url!.path.hasSuffix(".riv")
                ? riv
                : (request.url!.path.hasSuffix(".bin") ? script : image)
            let contentType = request.url!.path.hasSuffix(".riv")
                ? "application/vnd.rive"
                : (request.url!.path.hasSuffix(".bin")
                    ? "application/octet-stream" : "image/jpeg")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": contentType]
                )!,
                bytes
            )
        }
        let products = SuspendedExperienceReleaseProductService()
        let store = ExperienceLoader(
            productService: products,
            releaseStore: makeStore(cache: temporaryDirectory())
        )
        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery, active: [entry], pinned: []
        ))
        let loading = Task {
            try await store.experienceForPresentation(
                experienceId: entry.locator.experienceId,
                versionId: entry.locator.experienceVersionId,
                initialScreenID: "screen_welcome"
            )
        }
        await products.waitUntilRequested()

        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery, active: [replacement], pinned: []
        ))
        await products.resume()

        do {
            _ = try await loading.value
            XCTFail("expected stale signed load to be cancelled")
        } catch {}
        let retained = try await store.experience(
            experienceId: replacement.locator.experienceId,
            versionId: replacement.locator.experienceVersionId
        )
        XCTAssertEqual(retained.authenticatedReleaseID?.identity, replacement.locator)
        XCTAssertEqual(retained.name, "Replacement behavior")
    }

    func testSignedProductFailureBlocksPresentationWhenSelectedScreenRequiresProduct() async throws {
        let (base, delivery) = try releaseEntry(
            riv: Data("RIVE selected product gating".utf8),
            image: Data([3, 1, 4])
        )
        let entry = try resign(entry: base) { root in
            root["products"] = [[
                "id": "com.nuxie.pro.monthly",
                "type": "subscription",
                "store": [
                    "platform": "apple_app_store",
                    "productId": "com.nuxie.pro.monthly",
                    "productType": "autoRenewable",
                ],
                "entitlements": [],
            ]]
            root["placements"] = [[
                "id": "paywall:monthly",
                "productId": "com.nuxie.pro.monthly",
            ]]
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            var renderScreens = try XCTUnwrap(render["screens"] as? [[String: Any]])
            var paywallRender = try XCTUnwrap(renderScreens.first)
            paywallRender["id"] = "screen_paywall"
            paywallRender["artboardId"] = "artboard_paywall"
            paywallRender["artboardName"] = "Paywall"
            renderScreens.append(paywallRender)
            render["screens"] = renderScreens
            root["render"] = render

            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            var journeyScreens = try XCTUnwrap(journey["screens"] as? [[String: Any]])
            journeyScreens.append([
                "id": "screen_paywall",
                "defaultViewModelName": "vm.nuxie.paywall",
                "defaultInstanceId": "paywall",
            ])
            journey["screens"] = journeyScreens
            journey["viewModelValues"] = [[
                "viewModelName": "vm.nuxie.paywall",
                "instanceId": "paywall",
                "path": "products",
                "value": [[
                    "placementId": "paywall:monthly",
                    "productId": "com.nuxie.pro.monthly",
                    "name": "Stale name",
                    "price": "$0.00",
                    "period": "month",
                ]],
            ]]
            root["journey"] = journey
        }
        let productService = FailingExperienceReleaseProductService()
        let store = ExperienceLoader(
            productService: productService,
            releaseStore: makeStore(cache: temporaryDirectory()),
            warmLoadsInitiallySuspended: true
        )
        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [entry],
            pinned: []
        ))

        do {
            _ = try await store.experienceForPresentation(
                experienceId: entry.locator.experienceId,
                versionId: entry.locator.experienceVersionId,
                initialScreenID: "screen_paywall"
            )
            XCTFail("expected the selected product-bound screen to require StoreKit")
        } catch let error as ExperienceError {
            guard case .productsUnavailable = error else {
                return XCTFail("expected productsUnavailable, got \(error)")
            }
        }
        XCTAssertEqual(productService.requestCount, 1)

        let unsupportedOnIOS = try resign(entry: entry) { root in
            var products = try XCTUnwrap(root["products"] as? [[String: Any]])
            var storeProduct = try XCTUnwrap(products.first)
            storeProduct["store"] = [
                "platform": "google_play",
                "productId": "premium_monthly",
                "productType": "subscription",
            ]
            products[0] = storeProduct
            root["products"] = products
        }
        let unsupportedStore = ExperienceLoader(
            productService: productService,
            releaseStore: makeStore(cache: temporaryDirectory()),
            warmLoadsInitiallySuspended: true
        )
        _ = try await unsupportedStore.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [unsupportedOnIOS],
            pinned: []
        ))

        do {
            _ = try await unsupportedStore.experienceForPresentation(
                experienceId: unsupportedOnIOS.locator.experienceId,
                versionId: unsupportedOnIOS.locator.experienceVersionId,
                initialScreenID: "screen_paywall"
            )
            XCTFail("expected a product-bound screen without an Apple binding to fail closed")
        } catch let error as ExperienceError {
            guard case .productsUnavailable = error else {
                return XCTFail("expected productsUnavailable, got \(error)")
            }
        }
        XCTAssertEqual(
            productService.requestCount,
            1,
            "unsupported bindings must fail before showing preview values or calling StoreKit"
        )

        let danglingPlacement = try resign(entry: entry) { root in
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            journey["viewModelValues"] = [[
                "viewModelName": "vm.nuxie.paywall",
                "instanceId": "paywall",
                "path": "placementId",
                "value": "paywall:missing",
            ]]
            root["journey"] = journey
        }
        let danglingStore = ExperienceLoader(
            productService: productService,
            releaseStore: makeStore(cache: temporaryDirectory()),
            warmLoadsInitiallySuspended: true
        )
        _ = try await danglingStore.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [danglingPlacement],
            pinned: []
        ))

        do {
            _ = try await danglingStore.experienceForPresentation(
                experienceId: danglingPlacement.locator.experienceId,
                versionId: danglingPlacement.locator.experienceVersionId,
                initialScreenID: "screen_paywall"
            )
            XCTFail("expected an undeclared Placement reference to fail closed")
        } catch let error as ExperienceError {
            guard case .productsUnavailable = error else {
                return XCTFail("expected productsUnavailable, got \(error)")
            }
        }
        XCTAssertEqual(
            productService.requestCount,
            1,
            "dangling Placement references must fail before StoreKit or preview reveal"
        )

        let noDeclaredPlacements = try resign(entry: danglingPlacement) { root in
            root["placements"] = []
        }
        let emptyPlacementStore = ExperienceLoader(
            productService: productService,
            releaseStore: makeStore(cache: temporaryDirectory()),
            warmLoadsInitiallySuspended: true
        )
        _ = try await emptyPlacementStore.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [noDeclaredPlacements],
            pinned: []
        ))

        do {
            _ = try await emptyPlacementStore.experienceForPresentation(
                experienceId: noDeclaredPlacements.locator.experienceId,
                versionId: noDeclaredPlacements.locator.experienceVersionId,
                initialScreenID: "screen_paywall"
            )
            XCTFail("expected a dangling Placement with no declarations to fail closed")
        } catch let error as ExperienceError {
            guard case .productsUnavailable = error else {
                return XCTFail("expected productsUnavailable, got \(error)")
            }
        }
        XCTAssertEqual(
            productService.requestCount,
            1,
            "an empty Placement catalog must not turn preview commerce into a product-free screen"
        )
    }

    func testProfileCachesSignedProductAndDeviceRegionPlacementLoadsBeforeReveal() async throws {
        let (base, delivery) = try releaseEntry(
            riv: Data("RIVE purchase-only product".utf8),
            image: Data([5, 8, 13])
        )
        let productID = "com.nuxie.purchase.only"
        let placementID = "paywall:purchase-only"
        let entry = try resign(entry: base) { root in
            root["products"] = [[
                "id": "product_purchase_only",
                "type": "subscription",
                "store": [
                    "platform": "apple_app_store",
                    "productId": productID,
                    "productType": "autoRenewable",
                ],
                "entitlements": [[
                    "id": "entitlement_pro",
                    "featureId": "feature_pro",
                    "featureExternalId": "pro",
                    "allowanceType": "unlimited",
                    "allowance": NSNull(),
                    "interval": NSNull(),
                ]],
            ]]
            root["placements"] = [[
                "id": placementID,
                "productId": "product_purchase_only",
            ]]
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            journey["deviceRegions"] = [[
                "id": "device_checkout",
                "entryNodeId": "navigate_node",
                "actions": [
                    [
                        "type": "navigate",
                        "nodeId": "navigate_node",
                        "screenId": "screen_welcome",
                    ],
                    [
                        "type": "purchase",
                        "nodeId": "purchase_node",
                        "placementId": placementID,
                    ],
                ],
            ]]
            journey["viewModelValues"] = []
            root["journey"] = journey
        }
        let productService = MockProductService()
        productService.mockProducts = [
            MockStoreProduct(
                id: productID,
                displayName: "Purchase only",
                price: 9.99,
                displayPrice: "$9.99",
                productType: .autoRenewable
            ),
        ]
        let releaseCache = temporaryDirectory()
        let store = ExperienceLoader(
            productService: productService,
            releaseStore: makeStore(cache: releaseCache),
            warmLoadsInitiallySuspended: true
        )

        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [entry],
            pinned: []
        ))

        let cachedByProduct = await store.cachedProductMapping(
            releaseDescriptorSHA256: entry.descriptorSha256,
            productID: "product_purchase_only"
        )
        let cachedByStore = await store.cachedProductMapping(
            releaseDescriptorSHA256: entry.descriptorSha256,
            platform: "apple_app_store",
            storeProductID: productID
        )
        XCTAssertEqual(cachedByProduct?.entitlements.map(\.id), ["entitlement_pro"])
        XCTAssertEqual(cachedByStore?.id, "product_purchase_only")
        XCTAssertFalse(productService.fetchProductsCalled)

        let updatedEntry = try resign(entry: entry) { root in
            var identity = try XCTUnwrap(root["identity"] as? [String: Any])
            identity["buildId"] = "build-product-mapping-v2"
            identity["publishedAtSeq"] = entry.locator.publishedAtSeq + 1
            root["identity"] = identity
            var products = try XCTUnwrap(root["products"] as? [[String: Any]])
            products[0]["entitlements"] = [[
                "id": "entitlement_pro_v2",
                "featureId": "feature_pro_v2",
                "featureExternalId": "pro_v2",
                "allowanceType": "unlimited",
                "allowance": NSNull(),
                "interval": NSNull(),
            ]]
            root["products"] = products
        }
        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [updatedEntry],
            pinned: []
        ))
        let historicalMapping = await store.cachedProductMapping(
            releaseDescriptorSHA256: entry.descriptorSha256,
            productID: "product_purchase_only"
        )
        let updatedMapping = await store.cachedProductMapping(
            releaseDescriptorSHA256: updatedEntry.descriptorSha256,
            productID: "product_purchase_only"
        )
        XCTAssertEqual(historicalMapping?.entitlements.map(\.id), ["entitlement_pro"])
        XCTAssertEqual(updatedMapping?.entitlements.map(\.id), ["entitlement_pro_v2"])

        let restartedStore = ExperienceLoader(
            productService: productService,
            releaseStore: makeStore(cache: releaseCache),
            warmLoadsInitiallySuspended: true
        )
        _ = try await restartedStore.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [updatedEntry],
            pinned: []
        ))
        let restartedHistoricalMapping = await restartedStore.cachedProductMapping(
            releaseDescriptorSHA256: entry.descriptorSha256,
            productID: "product_purchase_only"
        )
        XCTAssertEqual(
            restartedHistoricalMapping?.entitlements.map(\.id),
            ["entitlement_pro"],
            "purchase-time mappings must survive an app process restart"
        )

        let experience = try await store.experienceForPresentation(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId,
            initialScreenID: "screen_welcome"
        )

        XCTAssertEqual(productService.requestedProductIds, Set([productID]))
        XCTAssertEqual(experience.products.map(\.placementId), [placementID])
    }

    func testProfileRejectsPurchaseWhoseLiteralPlacementIsNotSigned() async throws {
        let (base, delivery) = try releaseEntry(
            riv: Data("RIVE missing placement".utf8),
            image: Data([1, 2, 3])
        )
        let invalid = try resign(entry: base) { root in
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            var handlers = try XCTUnwrap(
                journey["handlers"] as? [String: [[String: Any]]]
            )
            handlers["screen_welcome"] = [[
                "id": "purchase_handler",
                "eventName": "buy",
                "actions": [[
                    "type": "purchase",
                    "placementId": "missing:placement",
                ]],
            ]]
            journey["handlers"] = handlers
            root["journey"] = journey
        }

        do {
            _ = try await makeStore(cache: temporaryDirectory()).authenticateProfile(
                .init(delivery: delivery, active: [invalid], pinned: [])
            )
            XCTFail("expected an undeclared literal Placement to fail closed")
        } catch let error as ExperienceReleaseAcquisitionError {
            XCTAssertEqual(error, .invalidRuntimeBinding("release"))
        }
    }

    func testProfileRejectsPurchaseReferenceToNonPlacementField() async throws {
        let (base, delivery) = try releaseEntry(
            riv: Data("RIVE invalid placement reference".utf8),
            image: Data([1, 2, 3])
        )
        let invalid = try resign(entry: base) { root in
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            var handlers = try XCTUnwrap(
                journey["handlers"] as? [String: [[String: Any]]]
            )
            handlers["screen_welcome"] = [[
                "id": "purchase_handler",
                "eventName": "buy",
                "actions": [[
                    "type": "purchase",
                    "placementId": [
                        "ref": [
                            "kind": "path",
                            "viewModelName": "Paywall",
                            "path": "paywall.selectedProductId",
                        ],
                    ],
                ]],
            ]]
            journey["handlers"] = handlers
            root["journey"] = journey
        }

        do {
            _ = try await makeStore(cache: temporaryDirectory()).authenticateProfile(
                .init(delivery: delivery, active: [invalid], pinned: [])
            )
            XCTFail("expected a non-Placement field reference to fail closed")
        } catch let error as ExperienceReleaseAcquisitionError {
            XCTAssertEqual(error, .invalidRuntimeBinding("release"))
        }
    }

    func testProfileRejectsUndeclaredPurchasePlacementInDeviceRegion() async throws {
        let (base, delivery) = try releaseEntry(
            riv: Data("RIVE invalid device-region placement".utf8),
            image: Data([1, 2, 3])
        )
        let invalid = try resign(entry: base) { root in
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            journey["deviceRegions"] = [[
                "id": "device_checkout",
                "entryNodeId": "navigate_node",
                "actions": [
                    [
                        "type": "navigate",
                        "nodeId": "navigate_node",
                        "screenId": "screen_welcome",
                    ],
                    [
                        "type": "purchase",
                        "nodeId": "purchase_node",
                        "placementId": "missing:placement",
                    ],
                ],
            ]]
            root["journey"] = journey
        }

        do {
            _ = try await makeStore(cache: temporaryDirectory()).authenticateProfile(
                .init(delivery: delivery, active: [invalid], pinned: [])
            )
            XCTFail("expected an undeclared device-region Placement to fail closed")
        } catch let error as ExperienceReleaseAcquisitionError {
            XCTAssertEqual(error, .invalidRuntimeBinding("release"))
        }
    }

    func testPresentationRequestsOnlyProductsRequiredBySelectedScreen() async throws {
        let riv = Data("RIVE selected root products".utf8)
        let image = Data([2, 7, 1, 8])
        let script = Data("selected root script".utf8)
        let (base, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script
        )
        let selectedID = "com.nuxie.selected.monthly"
        let unrelatedID = "com.nuxie.unrelated.annual"
        let entry = try resign(entry: base) { root in
            root["products"] = [selectedID, unrelatedID].map { id in
                [
                    "id": id,
                    "type": "subscription",
                    "store": [
                        "platform": "apple_app_store",
                        "productId": id,
                        "productType": "autoRenewable",
                    ],
                    "entitlements": [],
                ]
            }
            root["placements"] = [
                ["id": "paywall:annual", "productId": unrelatedID],
                ["id": "paywall:monthly", "productId": selectedID],
            ]
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            var screens = try XCTUnwrap(journey["screens"] as? [[String: Any]])
            var screen = try XCTUnwrap(screens.first)
            screen["defaultViewModelName"] = "vm.nuxie.paywall"
            screen["defaultInstanceId"] = "root-instance"
            screens[0] = screen
            screens.append([
                "id": "screen_annual",
                "defaultViewModelName": "vm.nuxie.annual",
                "defaultInstanceId": "annual-root",
            ])
            journey["screens"] = screens
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            var renderScreens = try XCTUnwrap(render["screens"] as? [[String: Any]])
            var annualRenderScreen = try XCTUnwrap(renderScreens.first)
            annualRenderScreen["id"] = "screen_annual"
            renderScreens.append(annualRenderScreen)
            render["screens"] = renderScreens
            root["render"] = render
            journey["viewModelValues"] = [
                [
                    "viewModelName": "vm.nuxie.paywall",
                    "path": "child",
                    "value": [
                        "viewModelId": "vm.nuxie.child",
                        "vmInstanceId": "selected-child",
                    ],
                ],
                [
                    "viewModelName": "vm.nuxie.child",
                    "instanceId": "selected-child",
                    "path": "nestedProduct",
                    "value": [
                        "placementId": "paywall:monthly",
                        "productId": selectedID,
                    ],
                ],
                [
                    "viewModelName": "vm.nuxie.paywall",
                    "instanceId": "remote-instance",
                    "path": "products",
                    "value": [[
                        "placementId": "paywall:annual",
                        "productId": unrelatedID,
                    ]],
                ],
                [
                    "viewModelName": "vm.nuxie.annual",
                    "path": "product",
                    "value": [
                        "placementId": "paywall:annual",
                        "productId": unrelatedID,
                    ],
                ],
            ]
            root["journey"] = journey
        }
        let productService = MockProductService()
        productService.mockProducts = [
            MockStoreProduct(
                id: selectedID,
                displayName: "Selected",
                price: 4.99,
                displayPrice: "$4.99",
                productType: .autoRenewable
            ),
            MockStoreProduct(
                id: unrelatedID,
                displayName: "Annual",
                price: 39.99,
                displayPrice: "$39.99",
                productType: .autoRenewable
            ),
        ]
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) {
            request in
            let bytes = request.url!.path.hasSuffix(".riv")
                ? riv : (request.url!.path.hasSuffix(".bin") ? script : image)
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: [
                        "Content-Type": request.url!.path.hasSuffix(".riv")
                            ? "application/vnd.rive"
                            : (request.url!.path.hasSuffix(".bin")
                                ? "application/octet-stream" : "image/jpeg")
                    ]
                )!, bytes
            )
        }
        let store = ExperienceLoader(
            productService: productService,
            releaseStore: makeStore(cache: temporaryDirectory()),
            warmLoadsInitiallySuspended: true
        )
        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [entry],
            pinned: []
        ))

        let experience = try await store.experienceForPresentation(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId,
            initialScreenID: "screen_welcome"
        )

        XCTAssertEqual(Set(productService.requestedProductIds), [selectedID])
        XCTAssertEqual(Set(experience.products.map(\.id)), [selectedID])

        let initiallyResolvedArtifact = try await store.presentationArtifact(
            for: experience,
            initialScreenID: "screen_welcome"
        )
        let mountedInitialArtifact = try await LoadedExperienceArtifact(
            acquired: initiallyResolvedArtifact
        ).resolvingProducts(for: "screen_welcome")
        XCTAssertEqual(
            Set(productService.requestedProductIds),
            [selectedID],
            "mounting the selected screen must reuse its completed StoreKit lookup"
        )
        XCTAssertEqual(
            Set(mountedInitialArtifact.acquired.products.map(\.id)),
            [selectedID]
        )
        productService.requestedProductIds = []
        let annualArtifact = try await mountedInitialArtifact.resolvingProducts(
            for: "screen_annual"
        )
        XCTAssertEqual(Set(productService.requestedProductIds), [unrelatedID])
        XCTAssertEqual(
            Set(annualArtifact.acquired.products.map(\.id)),
            [selectedID, unrelatedID],
            "navigation must retain previously presented products as purchase authority"
        )

        productService.requestedProductIds = []
        let behavior = try await store.experienceForJourneyControl(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId
        )
        let directArtifact = try await store.presentationArtifact(
            for: behavior,
            initialScreenID: "screen_welcome"
        )
        let screenArtifact = try await LoadedExperienceArtifact(
            acquired: directArtifact
        ).resolvingProducts(for: "screen_welcome")
        XCTAssertEqual(Set(productService.requestedProductIds), [selectedID])
        XCTAssertEqual(
            Set(screenArtifact.acquired.products.map(\.id)),
            [selectedID]
        )
    }

    func testReplacementBeforeArtifactRecordCannotRepopulateStaleArtifact() async throws {
        let riv = Data("RIVE stale artifact".utf8)
        let image = Data([8, 8, 8])
        let script = Data("stale artifact script".utf8)
        let (entry, delivery) = try releaseEntry(riv: riv, image: image, script: script)
        let replacementBuildID = "build-replacement-artifact"
        let replacement = try resign(entry: entry) { root in
            var identity = try XCTUnwrap(root["identity"] as? [String: Any])
            identity["buildId"] = replacementBuildID
            identity["publishedAtSeq"] = entry.locator.publishedAtSeq + 1
            root["identity"] = identity
        }
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) { request in
            let bytes = request.url!.path.hasSuffix(".riv")
                ? riv
                : (request.url!.path.hasSuffix(".bin") ? script : image)
            let contentType = request.url!.path.hasSuffix(".riv")
                ? "application/vnd.rive"
                : (request.url!.path.hasSuffix(".bin")
                    ? "application/octet-stream" : "image/jpeg")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": contentType]
                )!,
                bytes
            )
        }
        let releaseStore = SuspendedPresentationPackageReleaseStore(
            underlying: makeStore(cache: temporaryDirectory())
        )
        let store = ExperienceLoader(
            productService: ProductService(),
            releaseStore: releaseStore
        )
        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [entry],
            pinned: []
        ))
        let staleExperience = try await store.experience(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId
        )
        let staleLoad = Task {
            try await store.presentationArtifact(
                for: staleExperience,
                initialScreenID: "screen_welcome"
            )
        }
        await releaseStore.waitUntilFirstPackageAcquired()

        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [replacement],
            pinned: []
        ))
        await releaseStore.resumeFirstPackage()

        do {
            _ = try await staleLoad.value
            XCTFail("expected stale artifact handoff to fail closed")
        } catch is CancellationError {}
        do {
            _ = try await store.presentationArtifact(
                for: staleExperience,
                initialScreenID: "screen_welcome"
            )
            XCTFail("expected the old authenticated behavior to stay fenced")
        } catch is CancellationError {}
        let currentExperience = try await store.experience(
            experienceId: replacement.locator.experienceId,
            versionId: replacement.locator.experienceVersionId
        )
        let current = try await store.presentationArtifact(
            for: currentExperience,
            initialScreenID: "screen_welcome"
        )
        let requestCount = await releaseStore.presentationRequestCount()
        XCTAssertEqual(current.identity.buildId, replacementBuildID)
        XCTAssertEqual(requestCount, 2)
    }

    func testIdenticalProfileRefreshKeepsPendingPresentationArtifact() async throws {
        let riv = Data("RIVE identical profile refresh".utf8)
        let image = Data([4, 2, 4, 2])
        let script = Data("identical refresh script".utf8)
        let (entry, delivery) = try releaseEntry(riv: riv, image: image, script: script)
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) { request in
            let bytes = request.url!.path.hasSuffix(".riv")
                ? riv
                : (request.url!.path.hasSuffix(".bin") ? script : image)
            let contentType = request.url!.path.hasSuffix(".riv")
                ? "application/vnd.rive"
                : (request.url!.path.hasSuffix(".bin")
                    ? "application/octet-stream" : "image/jpeg")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": contentType]
                )!,
                bytes
            )
        }
        let releaseStore = SuspendedPresentationPackageReleaseStore(
            underlying: makeStore(cache: temporaryDirectory())
        )
        let store = ExperienceLoader(
            productService: ProductService(),
            releaseStore: releaseStore,
            warmLoadsInitiallySuspended: true
        )
        let profile = ExperienceReleaseProfileV2(
            delivery: delivery,
            active: [entry],
            pinned: []
        )
        _ = try await store.replaceReleaseProfile(profile)
        let experience = try await store.experienceForJourneyControl(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId
        )
        let pending = Task {
            try await store.presentationArtifact(
                for: experience,
                initialScreenID: "screen_welcome"
            )
        }
        await releaseStore.waitUntilFirstPackageAcquired()

        _ = try await store.replaceReleaseProfile(profile)
        await releaseStore.resumeFirstPackage()

        let artifact = try await pending.value
        XCTAssertEqual(artifact.identity.buildId, entry.locator.buildId)
        let presentationRequestCount = await releaseStore.presentationRequestCount()
        XCTAssertEqual(presentationRequestCount, 1)
    }

    func testForegroundArtifactLoadJoinsBackgroundWarm() async throws {
        let riv = Data("RIVE joined warm".utf8)
        let image = Data([6, 4, 2])
        let script = Data("joined warm script".utf8)
        let (entry, delivery) = try releaseEntry(riv: riv, image: image, script: script)
        let multiScreenEntry = try resign(entry: entry) { root in
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            var screens = try XCTUnwrap(render["screens"] as? [[String: Any]])
            var second = try XCTUnwrap(screens.first)
            second["id"] = "screen_offer"
            second["artboardId"] = "artboard_offer"
            second["artboardName"] = "Offer"
            screens.append(second)
            render["screens"] = screens
            root["render"] = render

            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            var journeyScreens = try XCTUnwrap(journey["screens"] as? [[String: Any]])
            var journeySecond = try XCTUnwrap(journeyScreens.first)
            journeySecond["id"] = "screen_offer"
            journeyScreens.append(journeySecond)
            journey["screens"] = journeyScreens
            root["journey"] = journey
        }
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) { request in
            let bytes = request.url!.path.hasSuffix(".riv")
                ? riv
                : (request.url!.path.hasSuffix(".bin") ? script : image)
            let contentType = request.url!.path.hasSuffix(".riv")
                ? "application/vnd.rive"
                : (request.url!.path.hasSuffix(".bin")
                    ? "application/octet-stream" : "image/jpeg")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": contentType]
                )!,
                bytes
            )
        }
        let releaseStore = SuspendedPresentationPackageReleaseStore(
            underlying: makeStore(cache: temporaryDirectory())
        )
        let store = ExperienceLoader(
            productService: MockProductService(),
            releaseStore: releaseStore
        )

        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [multiScreenEntry],
            pinned: []
        ))
        await releaseStore.waitUntilFirstPackageAcquired()
        let behavior = try await store.experienceForJourneyControl(
            experienceId: multiScreenEntry.locator.experienceId,
            versionId: multiScreenEntry.locator.experienceVersionId
        )
        let recorder = InMemoryExperiencePresentationTrace()
        let traceContext = ExperiencePresentationTraceContext(
            attempt: .make(triggerEvent: "joined_warm", startedAt: Date()),
            recorder: recorder
        )
        let foreground = Task {
            try await store.presentationArtifact(
                for: behavior,
                initialScreenID: "screen_offer",
                presentationTraceContext: traceContext
            )
        }
        await Task.yield()
        await Task.yield()

        let requestCount = await releaseStore.presentationRequestCount()
        XCTAssertEqual(requestCount, 1)

        await releaseStore.resumeFirstPackage()
        let artifact = try await foreground.value
        await store.waitForWarmLoadsToSettle()
        XCTAssertEqual(artifact.payload.renderPlan.entry.screenId, "screen_offer")
        XCTAssertEqual(artifact.resourceMetrics, .zero)
        let preloadAttributes = recorder.events().compactMap {
            event -> [String: String]? in
            guard case .workCompleted(_, .externalAssetPreparation, _, let attributes) =
                event.stage,
                attributes["phase"] == "profile_preload" else { return nil }
            return attributes
        }
        XCTAssertEqual(preloadAttributes.count, 1)
        XCTAssertGreaterThan(
            Int(preloadAttributes[0]["read_bytes"] ?? "0") ?? 0,
            0
        )
    }

    func testForegroundPresentationSupersedesConstrainedPreloadFailure() async throws {
        let riv = Data("RIVE low data foreground retry".utf8)
        let image = Data([4, 8, 15, 16, 23, 42])
        let script = Data("low data foreground script".utf8)
        let (entry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script
        )
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) {
            request in
            let bytes = request.url!.path.hasSuffix(".riv")
                ? riv
                : (request.url!.path.hasSuffix(".bin") ? script : image)
            let contentType = request.url!.path.hasSuffix(".riv")
                ? "application/vnd.rive"
                : (request.url!.path.hasSuffix(".bin")
                    ? "application/octet-stream" : "image/jpeg")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": contentType]
                )!,
                bytes
            )
        }
        let releaseStore = ConstrainedPreloadFailureReleaseStore(
            underlying: makeStore(cache: temporaryDirectory())
        )
        let store = ExperienceLoader(
            productService: MockProductService(),
            releaseStore: releaseStore
        )
        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [entry],
            pinned: []
        ))
        await releaseStore.waitUntilPreloadStarted()
        let behavior = try await store.experienceForJourneyControl(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId
        )

        let foreground = Task {
            try await store.presentationArtifact(
                for: behavior,
                initialScreenID: "screen_welcome"
            )
        }
        await Task.yield()
        await releaseStore.failPreload()

        let artifact = try await foreground.value
        XCTAssertEqual(artifact.payload.sceneBytes, riv)
        let intents = await releaseStore.intents()
        XCTAssertEqual(intents, [.preload, .presentation])
    }

    func testInitiallySuspendedWarmLoadsDeferAcquisitionUntilPresentation()
        async throws
    {
        let riv = Data("RIVE deliberately cold".utf8)
        let image = Data([1, 2, 4, 8])
        let script = Data("cold listener script".utf8)
        let (entry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script
        )
        let requests = LockedRequestCounter()
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) {
            request in
            requests.increment()
            let bytes = request.url!.path.hasSuffix(".riv")
                ? riv
                : (request.url!.path.hasSuffix(".bin") ? script : image)
            let contentType = request.url!.path.hasSuffix(".riv")
                ? "application/vnd.rive"
                : (request.url!.path.hasSuffix(".bin")
                    ? "application/octet-stream" : "image/jpeg")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": contentType]
                )!,
                bytes
            )
        }
        let store = ExperienceLoader(
            productService: MockProductService(),
            releaseStore: makeStore(cache: temporaryDirectory()),
            warmLoadsInitiallySuspended: true
        )

        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [entry],
            pinned: []
        ))
        await store.waitForWarmLoadsToSettle()
        XCTAssertEqual(requests.value, 0)

        let behavior = try await store.experienceForJourneyControl(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId
        )
        _ = try await store.presentationArtifact(
            for: behavior,
            initialScreenID: "screen_welcome"
        )
        XCTAssertGreaterThan(requests.value, 0)
    }

    func testPresentationWarmthRequiresTheExactAuthenticatedPreparedRelease()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureRoot = root.appendingPathComponent(
            "Tests/ExperienceRuntimeHostApp/Fixtures/animation-event"
        )
        let profile = try JSONDecoder().decode(
            ExperienceReleaseProfileV2.self,
            from: Data(contentsOf: fixtureRoot.appendingPathComponent("profile.json"))
        )
        let entry = try XCTUnwrap(profile.active.first)
        let riv = try Data(contentsOf: fixtureRoot.appendingPathComponent(
            "renders/sha256/6dd5a11e2e04fa4e7ed1dd0e3fe56295934b93ed45f8bf3a19291a6d38fd8214.riv"
        ))
        StubURLProtocol.register(
            matcher: { $0.url?.host == "animation-event.fixture.nuxie.test" }
        ) { request in
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/vnd.rive"]
                )!,
                riv
            )
        }
        let preparationCache = ExperienceInteractivePreparationCache(
            maximumRetainedPreparations: 1
        )
        let store = ExperienceLoader(
            productService: MockProductService(),
            releaseStore: makeStore(cache: temporaryDirectory()),
            warmLoadsInitiallySuspended: true,
            interactivePreparationCache: preparationCache
        )
        _ = try await store.replaceReleaseProfile(.init(
            delivery: profile.delivery,
            active: [entry],
            pinned: []
        ))
        let behavior = try await store.experienceForJourneyControl(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId
        )
        let releaseID = try XCTUnwrap(behavior.authenticatedReleaseID)
        let presentationStyle = try XCTUnwrap(
            behavior.behaviorPresentationStyle
        )
        let commit = JourneyPendingPresentation(
            experienceId: behavior.id,
            experienceVersionId: behavior.versionId,
            releaseID: releaseID,
            presentationStyle: presentationStyle,
            shell: behavior.shellContract(screenId: "screen"),
            screenId: "screen",
            transition: nil,
            continuation: []
        )

        let cold = await store.isPresentationMemoryWarm(commit)
        XCTAssertFalse(cold)
        let artifact = try await store.presentationArtifact(
            for: behavior,
            initialScreenID: "screen"
        )
        _ = try await artifact.interactivePreparation.preparation()
        let warm = await store.isPresentationMemoryWarm(commit)
        XCTAssertTrue(warm)

        _ = try await preparationCache.preparation(
            provenance: "another-release",
            payload: artifact.payload
        )
        let evictedIsWarm = await store.isPresentationMemoryWarm(commit)
        XCTAssertFalse(evictedIsWarm)

        let staleCommit = JourneyPendingPresentation(
            experienceId: commit.experienceId,
            experienceVersionId: commit.experienceVersionId,
            releaseID: .init(
                identity: releaseID.identity,
                descriptorSHA256: String(repeating: "f", count: 64)
            ),
            presentationStyle: commit.presentationStyle,
            shell: commit.shell,
            screenId: commit.screenId,
            transition: nil,
            continuation: []
        )
        let staleIsWarm = await store.isPresentationMemoryWarm(staleCommit)
        XCTAssertFalse(staleIsWarm)
    }

    func testSuspendingWarmLoadsCancelsPreparationAlreadyStartedByProfileAdmission()
        async throws
    {
        let riv = Data("RIVE suspended warm preparation".utf8)
        let image = Data([2, 7, 1, 8])
        let script = Data("suspended warm listener script".utf8)
        let (entry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script
        )
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) {
            request in
            let bytes = request.url!.path.hasSuffix(".riv")
                ? riv
                : (request.url!.path.hasSuffix(".bin") ? script : image)
            let contentType = request.url!.path.hasSuffix(".riv")
                ? "application/vnd.rive"
                : (request.url!.path.hasSuffix(".bin")
                    ? "application/octet-stream" : "image/jpeg")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": contentType]
                )!,
                bytes
            )
        }
        let releaseStore = SuspendedPresentationPackageReleaseStore(
            underlying: makeStore(cache: temporaryDirectory())
        )
        let store = ExperienceLoader(
            productService: MockProductService(),
            releaseStore: releaseStore
        )
        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [entry],
            pinned: []
        ))
        await releaseStore.waitUntilFirstPackageAcquired()

        await store.suspendWarmLoads()
        await releaseStore.resumeFirstPackage()
        await releaseStore.waitUntilFirstPackageReturned()
        for _ in 0..<10 { await Task.yield() }

        let behavior = try await store.experienceForJourneyControl(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId
        )
        _ = try await store.presentationArtifact(
            for: behavior,
            initialScreenID: "screen_welcome"
        )
        let preparationRequestCount = await releaseStore.presentationRequestCount()
        XCTAssertEqual(preparationRequestCount, 2)
    }

    func testPreloadWorkIsAttributedOnceAndUnusedReleaseWorkIsExposed() async throws {
        let riv = Data("RIVE preload accounting".utf8)
        let image = Data([3, 1, 4, 1, 5])
        let script = Data("preload accounting script".utf8)
        let (entry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script
        )
        let unusedEntry = try resign(entry: entry) { root in
            var identity = try XCTUnwrap(root["identity"] as? [String: Any])
            identity["experienceId"] = "experience-unused-preload"
            identity["experienceVersionId"] = "version-unused-preload"
            identity["buildId"] = "build-unused-preload"
            root["identity"] = identity
        }
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) {
            request in
            let bytes = request.url!.path.hasSuffix(".riv")
                ? riv
                : (request.url!.path.hasSuffix(".bin") ? script : image)
            let contentType = request.url!.path.hasSuffix(".riv")
                ? "application/vnd.rive"
                : (request.url!.path.hasSuffix(".bin")
                    ? "application/octet-stream" : "image/jpeg")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": contentType]
                )!,
                bytes
            )
        }
        let store = ExperienceLoader(
            productService: MockProductService(),
            releaseStore: makeStore(cache: temporaryDirectory())
        )
        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [entry, unusedEntry],
            pinned: []
        ))
        await store.waitForWarmLoadsToSettle()
        let behavior = try await store.experienceForJourneyControl(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId
        )

        let firstRecorder = InMemoryExperiencePresentationTrace()
        let firstContext = ExperiencePresentationTraceContext(
            attempt: .make(triggerEvent: "first_attempt", startedAt: Date()),
            recorder: firstRecorder
        )
        let first = try await store.presentationArtifact(
            for: behavior,
            initialScreenID: "screen_welcome",
            presentationTraceContext: firstContext
        )
        XCTAssertEqual(first.resourceMetrics, .zero)
        let firstPreload = firstRecorder.events().compactMap { event -> [String: String]? in
            guard case .workCompleted(_, .externalAssetPreparation, _, let attributes) =
                event.stage,
                attributes["phase"] == "profile_preload" else { return nil }
            return attributes
        }
        let firstPreloadAttributes = try XCTUnwrap(firstPreload.first)
        XCTAssertEqual(firstPreload.count, 1)
        XCTAssertGreaterThan(
            Int(firstPreloadAttributes["preload_bytes"] ?? "0") ?? 0,
            0
        )
        XCTAssertGreaterThan(
            Int(firstPreloadAttributes["unused_preload_bytes"] ?? "0") ?? 0,
            0
        )
        XCTAssertGreaterThan(
            Int(firstPreloadAttributes["read_bytes"] ?? "0") ?? 0,
            0
        )

        let secondRecorder = InMemoryExperiencePresentationTrace()
        let secondContext = ExperiencePresentationTraceContext(
            attempt: .make(triggerEvent: "second_attempt", startedAt: Date()),
            recorder: secondRecorder
        )
        let second = try await store.presentationArtifact(
            for: behavior,
            initialScreenID: "screen_welcome",
            presentationTraceContext: secondContext
        )
        XCTAssertEqual(second.resourceMetrics, .zero)
        let secondPreload = secondRecorder.events().compactMap {
            event -> [String: String]? in
            guard case .workCompleted(_, .externalAssetPreparation, _, let attributes) =
                event.stage,
                attributes["phase"] == "profile_preload" else { return nil }
            return attributes
        }
        let secondPreloadAttributes = try XCTUnwrap(secondPreload.first)
        XCTAssertEqual(secondPreload.count, 1)
        XCTAssertEqual(secondPreloadAttributes["read_bytes"], "0")
        XCTAssertEqual(secondPreloadAttributes["parsed_bytes"], "0")
        XCTAssertEqual(secondPreloadAttributes["unused_preload_bytes"], "0")
    }

    func testCancellingWarmLoadFlushesAcquiredWorkBeforeClosingPreloadSpan() async throws {
        let riv = Data("RIVE cancelled preload accounting".utf8)
        let image = Data([8, 6, 7, 5, 3, 0, 9])
        let script = Data("cancelled preload script".utf8)
        let (entry, delivery) = try releaseEntry(
            riv: riv,
            image: image,
            script: script
        )
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) {
            request in
            let bytes = request.url!.path.hasSuffix(".riv")
                ? riv
                : (request.url!.path.hasSuffix(".bin") ? script : image)
            let contentType = request.url!.path.hasSuffix(".riv")
                ? "application/vnd.rive"
                : (request.url!.path.hasSuffix(".bin")
                    ? "application/octet-stream" : "image/jpeg")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": contentType]
                )!,
                bytes
            )
        }
        let gate = PreloadPreparationGate()
        let preparationCache = ExperienceInteractivePreparationCache(
            inspectAssets: { _ in [] },
            preparePayload: { _, _ in
                await gate.enterAndWait()
                throw PreloadPreparationProbeError.expectedFailure
            }
        )
        let store = ExperienceLoader(
            productService: MockProductService(),
            releaseStore: makeStore(cache: temporaryDirectory()),
            interactivePreparationCache: preparationCache
        )
        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [entry],
            pinned: []
        ))
        await gate.waitUntilEntered()
        let behavior = try await store.experienceForJourneyControl(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId
        )
        let recorder = InMemoryExperiencePresentationTrace()
        let context = ExperiencePresentationTraceContext(
            attempt: .make(triggerEvent: "cancel_preload", startedAt: Date()),
            recorder: recorder
        )
        let artifact = try await store.presentationArtifact(
            for: behavior,
            initialScreenID: "screen_welcome",
            presentationTraceContext: context
        )
        XCTAssertEqual(artifact.resourceMetrics, .zero)

        let clearing = Task { await store.clearCache() }
        await Task.yield()
        await gate.release()
        await clearing.value

        let preloadAttributes = recorder.events().compactMap {
            event -> [String: String]? in
            guard case .workCompleted(_, .externalAssetPreparation, _, let attributes) =
                event.stage,
                attributes["phase"] == "profile_preload" else { return nil }
            return attributes
        }
        XCTAssertEqual(preloadAttributes.count, 1)
        XCTAssertEqual(preloadAttributes[0]["cancelled"], "true")
        XCTAssertGreaterThan(
            Int(preloadAttributes[0]["read_bytes"] ?? "0") ?? 0,
            0
        )
    }

    func testBackgroundWarmBoundsConcurrentReleases() async throws {
        let riv = Data("RIVE bounded warm".utf8)
        let image = Data([1, 3, 5])
        let script = Data("bounded warm script".utf8)
        let (entry, delivery) = try releaseEntry(riv: riv, image: image, script: script)
        let requests = LockedRequestCounter()
        var constrainedNetworkPermissions: [Bool] = []
        let constrainedNetworkLock = NSLock()
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) { request in
            requests.increment()
            constrainedNetworkLock.withLock {
                constrainedNetworkPermissions.append(
                    request.allowsConstrainedNetworkAccess
                )
            }
            let bytes = request.url!.path.hasSuffix(".riv")
                ? riv
                : (request.url!.path.hasSuffix(".bin") ? script : image)
            let contentType = request.url!.path.hasSuffix(".riv")
                ? "application/vnd.rive"
                : (request.url!.path.hasSuffix(".bin")
                    ? "application/octet-stream" : "image/jpeg")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": contentType]
                )!,
                bytes
            )
        }
        let entries = try (0..<6).map { index in
            try resign(entry: entry) { root in
                var identity = try XCTUnwrap(root["identity"] as? [String: Any])
                identity["experienceId"] = "experience-bounded-\(index)"
                identity["experienceVersionId"] = "version-bounded-\(index)"
                identity["buildId"] = "build-bounded-\(index)"
                root["identity"] = identity
            }
        }
        let releaseStore = BoundedWarmProbeReleaseStore(
            underlying: makeStore(cache: temporaryDirectory())
        )
        let store = ExperienceLoader(
            productService: MockProductService(),
            releaseStore: releaseStore,
            maximumConcurrentWarmLoads: 2
        )

        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery,
            active: entries,
            pinned: []
        ))
        await releaseStore.waitUntilStarted(2)
        await Task.yield()
        await Task.yield()

        let beforeResume = await releaseStore.snapshot()
        XCTAssertEqual(beforeResume.started, 2)
        XCTAssertEqual(beforeResume.maximumActive, 2)

        await releaseStore.resumeAll()
        await releaseStore.waitUntilStarted(entries.count)
        await releaseStore.waitUntilCompleted(entries.count)
        let completed = await releaseStore.snapshot()
        XCTAssertEqual(completed.maximumActive, 2)
        XCTAssertEqual(requests.value, 3)
        XCTAssertEqual(
            constrainedNetworkLock.withLock { Set(constrainedNetworkPermissions) },
            [false],
            "speculative profile warming must defer under Low Data Mode"
        )
    }

    func testMemoryPressureReleasesPreparedBytesWithoutDroppingAuthority() async throws {
        let riv = Data("RIVE memory pressure".utf8)
        let image = Data([2, 4, 6])
        let (entry, delivery) = try releaseEntry(riv: riv, image: image)
        StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) { request in
            let bytes = request.url!.path.hasSuffix(".riv")
                ? riv
                : (request.url!.path.hasSuffix(".bin")
                    ? Data("compiled luau".utf8) : image)
            let contentType = request.url!.path.hasSuffix(".riv")
                ? "application/vnd.rive"
                : (request.url!.path.hasSuffix(".bin")
                    ? "application/octet-stream" : "image/jpeg")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": contentType]
                )!,
                bytes
            )
        }
        let releaseStore = SuspendedPresentationPackageReleaseStore(
            underlying: makeStore(cache: temporaryDirectory())
        )
        let store = ExperienceLoader(
            productService: MockProductService(),
            releaseStore: releaseStore
        )
        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [entry],
            pinned: []
        ))
        await releaseStore.waitUntilFirstPackageAcquired()
        await releaseStore.resumeFirstPackage()
        let behavior = try await store.experienceForJourneyControl(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId
        )
        let downloaded = try await store.presentationArtifact(
            for: behavior,
            initialScreenID: "screen_welcome"
        )
        XCTAssertEqual(downloaded.source, .download)
        let initialPreparationCount = await releaseStore.presentationRequestCount()
        XCTAssertEqual(initialPreparationCount, 1)

        await store.handleMemoryPressure()

        let retainedBehavior = try await store.experienceForJourneyControl(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId
        )
        let cached = try await store.presentationArtifact(
            for: retainedBehavior,
            initialScreenID: "screen_welcome"
        )
        XCTAssertEqual(cached.source, .cache)
        let reloadedPreparationCount = await releaseStore.presentationRequestCount()
        XCTAssertEqual(reloadedPreparationCount, 2)
    }

    func testMultiScreenReleaseWithoutResolvedEntryFailsClosed() async throws {
        let riv = Data("RIVE multi".utf8)
        let image = Data([7, 8, 9])
        let (entry, delivery) = try releaseEntry(riv: riv, image: image)
        let multi = try resign(entry: entry) { root in
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            var screens = try XCTUnwrap(render["screens"] as? [[String: Any]])
            var second = try XCTUnwrap(screens.first)
            second["id"] = "screen_second"
            second["artboardId"] = "artboard_second"
            second["artboardName"] = "Second"
            screens.append(second)
            render["screens"] = screens
            root["render"] = render

            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            var journeyScreens = try XCTUnwrap(journey["screens"] as? [[String: Any]])
            var journeySecond = try XCTUnwrap(journeyScreens.first)
            journeySecond["id"] = "screen_second"
            journeyScreens.append(journeySecond)
            journey["screens"] = journeyScreens
            root["journey"] = journey
        }

        do {
            _ = try await makeStore(cache: temporaryDirectory()).acquire(
                entry: multi,
                delivery: delivery,
                mode: .active
            )
            XCTFail("expected unresolved entry failure")
        } catch let error as ExperienceReleaseAcquisitionError {
            XCTAssertEqual(error, .selectedScreenNotDeclared("ambiguous"))
        }
    }

    func testPreviewEntryResolverExecutesSignedConditionalProgram() async throws {
        let fixture = try ExperienceReleaseTestFixture.make(selectSecondScreen: true)
        let cache = temporaryDirectory()
        let catalog = try await makeStore(cache: cache).authenticateProfile(.init(
            delivery: fixture.delivery,
            active: [fixture.entry],
            pinned: []
        ))
        let definition = try XCTUnwrap(catalog.definitions.first)

        let selectedScreenID = try await ExperienceReleaseInitialPresentationResolver.resolve(
            definition: definition,
            cacheRootURL: cache,
            environment: .development
        )

        XCTAssertEqual(selectedScreenID, "screen_offer")
    }

    func testPreviewEntryResolverOpensEventHistoryBeforeEvaluation() async throws {
        let fixture = try ExperienceReleaseTestFixture.make(
            entryCondition: .eventsExists(
                name: "never-recorded",
                since: nil,
                until: nil,
                within: nil,
                where_: nil
            )
        )
        let cache = temporaryDirectory()
        let catalog = try await makeStore(cache: cache).authenticateProfile(.init(
            delivery: fixture.delivery,
            active: [fixture.entry],
            pinned: []
        ))
        let definition = try XCTUnwrap(catalog.definitions.first)

        let selectedScreenID = try await ExperienceReleaseInitialPresentationResolver.resolve(
            definition: definition,
            cacheRootURL: cache,
            environment: .development
        )

        XCTAssertEqual(selectedScreenID, "screen_welcome")
    }

    func testPreviewEntryResolverAwaitsCachedSegmentMembership() async throws {
        let segmentID = "preview-segment"
        let fixture = try ExperienceReleaseTestFixture.make(
            entryCondition: .segment(op: "is_member", id: segmentID, within: nil)
        )
        let cache = temporaryDirectory()
        let identity = IdentityService(customStoragePath: cache)
        let profileCache = try DiskCache<CachedProfile>(options: .init(
            baseDirectory: cache.appendingPathComponent("nuxie", isDirectory: true),
            subdirectory: "profiles",
            defaultTTL: 24 * 60 * 60,
            maxTotalBytes: 10 * 1_024 * 1_024,
            excludeFromBackup: true,
            fileProtection: .completeUntilFirstUserAuthentication
        ))
        let now = Date()
        try await profileCache.store(
            CachedProfile(
                response: ProfileResponse(
                    segments: [Segment(
                        id: segmentID,
                        name: "Preview segment",
                        condition: IREnvelope(
                            ir_version: 1,
                            engine_min: "1.0.0",
                            compiled_at: 0,
                            expr: .bool(true)
                        )
                    )],
                    segmentMemberships: SegmentMembershipSeed(
                        evaluatedAt: now,
                        memberships: [SeededSegmentMembership(
                            segmentId: segmentID,
                            enteredAt: now
                        )]
                    )
                ),
                distinctId: identity.getDistinctId(),
                cachedAt: now
            ),
            forKey: identity.getDistinctId()
        )
        let catalog = try await makeStore(cache: cache).authenticateProfile(.init(
            delivery: fixture.delivery,
            active: [fixture.entry],
            pinned: []
        ))
        let definition = try XCTUnwrap(catalog.definitions.first)

        let selectedScreenID = try await ExperienceReleaseInitialPresentationResolver.resolve(
            definition: definition,
            cacheRootURL: cache,
            environment: .development
        )

        XCTAssertEqual(selectedScreenID, "screen_offer")
    }

    private func releaseEntry(
        riv: Data,
        image: Data,
        script: Data = Data("compiled luau".utf8),
        imageRequired: Bool = true
    ) throws -> (ExperienceReleaseProfileEntryV2, ExperienceReleaseDeliveryV2) {
        var root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: goldenDescriptorBytes()) as? [String: Any]
        )
        var render = try XCTUnwrap(root["render"] as? [String: Any])
        var rivArtifact = try XCTUnwrap(render["riv"] as? [String: Any])
        let rivDigest = SHA256Provider.hexDigest(riv)
        rivArtifact["key"] = "renders/sha256/\(rivDigest).riv"
        rivArtifact["sha256"] = rivDigest
        rivArtifact["sizeBytes"] = riv.count
        render["riv"] = rivArtifact
        var asset = try XCTUnwrap((render["assets"] as? [[String: Any]])?.first)
        let imageDigest = SHA256Provider.hexDigest(image)
        asset["key"] = "assets/sha256/\(imageDigest).jpg"
        asset["sha256"] = imageDigest
        asset["sizeBytes"] = image.count
        asset["contentType"] = "image/jpeg"
        asset["required"] = imageRequired
        render["assets"] = [asset]
        root["render"] = render

        var journey = try XCTUnwrap(root["journey"] as? [String: Any])
        journey["handlers"] = [
            JourneyDocument.journeyEventHostKey: [[
                "id": "handler_journey_started",
                "eventName": SystemEventNames.journeyStarted,
                "actions": [[
                    "type": "navigate",
                    "screenId": "screen_welcome",
                    "nodeId": "node_entry"
                ]]
            ]]
        ]
        var scripts = try XCTUnwrap(journey["scripts"] as? [String: [[String: Any]]])
        var refs = try XCTUnwrap(scripts["screen_welcome"])
        var ref = try XCTUnwrap(refs.first)
        var scriptArtifact = try XCTUnwrap(ref["artifact"] as? [String: Any])
        let scriptDigest = SHA256Provider.hexDigest(script)
        scriptArtifact["key"] = "assets/sha256/\(scriptDigest).bin"
        scriptArtifact["sha256"] = scriptDigest
        scriptArtifact["sizeBytes"] = script.count
        ref["artifact"] = scriptArtifact
        refs[0] = ref
        scripts["screen_welcome"] = refs
        journey["scripts"] = scripts
        root["journey"] = journey

        root["compatibility"] = [
            "minimumSdkVersion": SDKVersion.current,
            "runtimeRevision": NuxieEmbeddedRuntimeCompatibility.sourceRevision,
            "luau": [
                "revision": NuxieEmbeddedRuntimeCompatibility.luauRevision,
                "bytecodeVersions": NuxieEmbeddedRuntimeCompatibility.luauBytecodeVersions.sorted()
            ],
            "sceneFormat": [
                "major": NuxieEmbeddedRuntimeCompatibility.sceneFormatMajor,
                "minor": NuxieEmbeddedRuntimeCompatibility.sceneFormatMinor
            ],
            "requiredCapabilities": NuxieEmbeddedRuntimeCompatibility.capabilities.sorted()
        ]
        let descriptor = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let signature = try signingKey.signature(
            for: Data(ExperienceReleaseDescriptorLimits.signatureDomain.utf8) + descriptor
        )
        let digest = SHA256Provider.hexDigest(descriptor)
        let envelope = ExperienceReleaseDescriptorEnvelopeV2(
            mediaType: ExperienceReleaseDescriptorLimits.mediaType,
            encoding: "base64",
            descriptorSha256: digest,
            descriptorSizeBytes: descriptor.count,
            descriptorBytesBase64: descriptor.base64EncodedString(),
            signature: .init(
                version: 1,
                algorithm: "ed25519",
                keyId: "TEST_ONLY_DEV_KEYPAIR",
                signatureBase64: signature.base64EncodedString()
            )
        )
        let identity = try JSONDecoder().decode(
            ExperienceReleaseDescriptorV2.self,
            from: descriptor
        ).identity
        return (
            ExperienceReleaseProfileEntryV2(
                locator: identity,
                descriptorSha256: digest,
                envelopeBytes: try envelope.canonicalBytes()
            ),
            ExperienceReleaseDeliveryV2(
                renderBaseUrl: "https://cdn.nuxie.test/renders/",
                assetBaseUrl: "https://cdn.nuxie.test/assets/"
            )
        )
    }

    private func resign(
        entry: ExperienceReleaseProfileEntryV2,
        mutate: (inout [String: Any]) throws -> Void
    ) throws -> ExperienceReleaseProfileEntryV2 {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try validDescriptorBytes(entry)) as? [String: Any]
        )
        try mutate(&root)
        let descriptor = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let signature = try signingKey.signature(
            for: Data(ExperienceReleaseDescriptorLimits.signatureDomain.utf8) + descriptor
        )
        let digest = SHA256Provider.hexDigest(descriptor)
        let envelope = ExperienceReleaseDescriptorEnvelopeV2(
            mediaType: ExperienceReleaseDescriptorLimits.mediaType,
            encoding: "base64",
            descriptorSha256: digest,
            descriptorSizeBytes: descriptor.count,
            descriptorBytesBase64: descriptor.base64EncodedString(),
            signature: .init(
                version: 1,
                algorithm: "ed25519",
                keyId: "TEST_ONLY_DEV_KEYPAIR",
                signatureBase64: signature.base64EncodedString()
            )
        )
        let identity = try JSONDecoder().decode(
            ExperienceReleaseDescriptorV2.self,
            from: descriptor
        ).identity
        return .init(
            locator: identity,
            descriptorSha256: digest,
            envelopeBytes: try envelope.canonicalBytes()
        )
    }

    private func budgetEntry(
        locator: ExperienceReleaseIdentityV2,
        seed: UInt8
    ) throws -> ExperienceReleaseProfileEntryV2 {
        let descriptor = Data(
            repeating: seed,
            count: ExperienceReleaseDescriptorLimits.descriptorBytes
        )
        let digest = SHA256Provider.hexDigest(descriptor)
        let envelope = ExperienceReleaseDescriptorEnvelopeV2(
            mediaType: ExperienceReleaseDescriptorLimits.mediaType,
            encoding: "base64",
            descriptorSha256: digest,
            descriptorSizeBytes: descriptor.count,
            descriptorBytesBase64: descriptor.base64EncodedString(),
            signature: .init(
                version: 1,
                algorithm: "ed25519",
                keyId: "TEST_ONLY_DEV_KEYPAIR",
                signatureBase64: Data(repeating: 0, count: 64).base64EncodedString()
            )
        )
        return .init(
            locator: locator,
            descriptorSha256: digest,
            envelopeBytes: try envelope.canonicalBytes()
        )
    }

    private func makeStore(
        cache: URL,
        maximumCacheBytes: Int = 256 * 1_024 * 1_024
    ) -> ExperienceReleaseAcquisitionStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ExperienceReleaseAcquisitionStore(
            cacheDirectory: cache,
            maximumCacheBytes: maximumCacheBytes,
            urlSession: URLSession(configuration: config),
            authorizationKeys: [
                ExperiencePackageAuthorizationKey(
                    keyID: "TEST_ONLY_DEV_KEYPAIR",
                    ed25519PublicKeyBytes: signingKey.publicKey.rawRepresentation
                )
            ],
            supportedCompatibility: ExperienceReleaseRuntimeCompatibility.current,
            admission: ExperienceReleaseAdmission(
                store: InMemoryExperienceReleaseHighWaterStore()
            )
        )
    }

    private func goldenDescriptorBytes() throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let envelope = try JSONDecoder().decode(
            ExperienceReleaseDescriptorEnvelopeV2.self,
            from: Data(contentsOf: root
                .appendingPathComponent("fixtures/experience-release-descriptor-v2/envelope.json"))
        )
        return try XCTUnwrap(Data(base64Encoded: envelope.descriptorBytesBase64))
    }

    private func validDescriptorBytes(
        _ entry: ExperienceReleaseProfileEntryV2
    ) throws -> Data {
        let envelope = try JSONDecoder().decode(
            ExperienceReleaseDescriptorEnvelopeV2.self,
            from: entry.exactEnvelopeBytes()
        )
        return try XCTUnwrap(Data(base64Encoded: envelope.descriptorBytesBase64))
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuxie-release-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func assertAsyncThrows(
        _ operation: () async throws -> Void,
        code: (Error) -> String?
    ) async {
        do {
            try await operation()
            XCTFail("expected error")
        } catch {
            XCTAssertNotNil(code(error))
        }
    }
}

private final class SuspendedExperienceReleaseProductService: ProductService,
    @unchecked Sendable
{
    private let state = SuspendedExperienceReleaseProductState()

    override func fetchProducts(
        for identifiers: Set<String>
    ) async throws -> [any StoreProductProtocol] {
        _ = identifiers
        await state.suspend()
        return []
    }

    func waitUntilRequested() async { await state.waitUntilRequested() }
    func resume() async { await state.resume() }
}

private final class FailingExperienceReleaseProductService: ProductService,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var count = 0

    var requestCount: Int { lock.withLock { count } }

    override func fetchProducts(
        for identifiers: Set<String>
    ) async throws -> [any StoreProductProtocol] {
        _ = identifiers
        lock.withLock { count += 1 }
        throw StoreKitError.networkUnavailable
    }
}

private actor SuspendedExperienceReleaseProductState {
    private var requested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        requested = true
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
        await withCheckedContinuation { resumeWaiters.append($0) }
    }

    func waitUntilRequested() async {
        guard !requested else { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func resume() {
        resumeWaiters.forEach { $0.resume() }
        resumeWaiters.removeAll()
    }
}

private actor SuspendedPresentationPackageReleaseStore: ExperienceReleaseAcquiring {
    private let underlying: ExperienceReleaseAcquisitionStore
    private var didAcquireFirstPackage = false
    private var firstPackageWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstPackageResume: CheckedContinuation<Void, Never>?
    private var didReturnFirstPackage = false
    private var firstPackageReturnWaiters: [CheckedContinuation<Void, Never>] = []
    private var requestCount = 0

    init(underlying: ExperienceReleaseAcquisitionStore) {
        self.underlying = underlying
    }

    func authenticateProfile(
        _ profile: ExperienceReleaseProfileV2
    ) async throws -> AuthenticatedExperienceReleaseCatalog {
        try await underlying.authenticateProfile(profile)
    }

    func prepare(
        definition: AuthenticatedExperienceReleaseDefinition,
        intent: ExperienceReleasePreparationIntent
    ) async throws -> PreparedExperienceRelease {
        requestCount += 1
        let package = try await underlying.prepare(
            definition: definition,
            intent: intent
        )
        if !didAcquireFirstPackage {
            didAcquireFirstPackage = true
            firstPackageWaiters.forEach { $0.resume() }
            firstPackageWaiters.removeAll()
            await withCheckedContinuation { firstPackageResume = $0 }
            didReturnFirstPackage = true
            firstPackageReturnWaiters.forEach { $0.resume() }
            firstPackageReturnWaiters.removeAll()
        }
        return package
    }

    func waitUntilFirstPackageAcquired() async {
        guard !didAcquireFirstPackage else { return }
        await withCheckedContinuation { firstPackageWaiters.append($0) }
    }

    func resumeFirstPackage() {
        firstPackageResume?.resume()
        firstPackageResume = nil
    }

    func waitUntilFirstPackageReturned() async {
        guard !didReturnFirstPackage else { return }
        await withCheckedContinuation { firstPackageReturnWaiters.append($0) }
    }

    func presentationRequestCount() -> Int { requestCount }
}

private actor BoundedWarmProbeReleaseStore: ExperienceReleaseAcquiring {
    private let underlying: ExperienceReleaseAcquisitionStore
    private var started = 0
    private var active = 0
    private var maximumActive = 0
    private var completed = 0
    private var isResumed = false
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var completionWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    init(underlying: ExperienceReleaseAcquisitionStore) {
        self.underlying = underlying
    }

    func authenticateProfile(
        _ profile: ExperienceReleaseProfileV2
    ) async throws -> AuthenticatedExperienceReleaseCatalog {
        try await underlying.authenticateProfile(profile)
    }

    func prepare(
        definition: AuthenticatedExperienceReleaseDefinition,
        intent: ExperienceReleasePreparationIntent
    ) async throws -> PreparedExperienceRelease {
        started += 1
        active += 1
        maximumActive = max(maximumActive, active)
        let ready = startWaiters.filter { started >= $0.count }
        startWaiters.removeAll { started >= $0.count }
        ready.forEach { $0.continuation.resume() }
        if !isResumed {
            await withCheckedContinuation { resumeWaiters.append($0) }
        }
        defer {
            active -= 1
            completed += 1
            let ready = completionWaiters.filter { completed >= $0.count }
            completionWaiters.removeAll { completed >= $0.count }
            ready.forEach { $0.continuation.resume() }
        }
        return try await underlying.prepare(
            definition: definition,
            intent: intent
        )
    }

    func waitUntilStarted(_ count: Int) async {
        if started >= count { return }
        await withCheckedContinuation {
            startWaiters.append((count: count, continuation: $0))
        }
    }

    func waitUntilCompleted(_ count: Int) async {
        if completed >= count { return }
        await withCheckedContinuation {
            completionWaiters.append((count: count, continuation: $0))
        }
    }

    func resumeAll() {
        isResumed = true
        resumeWaiters.forEach { $0.resume() }
        resumeWaiters.removeAll()
    }

    func snapshot() -> (started: Int, maximumActive: Int) {
        (started, maximumActive)
    }
}

private actor ConstrainedPreloadFailureReleaseStore: ExperienceReleaseAcquiring {
    private let underlying: ExperienceReleaseAcquisitionStore
    private var observedIntents: [ExperienceReleasePreparationIntent] = []
    private var preloadStarted = false
    private var shouldFailPreload = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(underlying: ExperienceReleaseAcquisitionStore) {
        self.underlying = underlying
    }

    func authenticateProfile(
        _ profile: ExperienceReleaseProfileV2
    ) async throws -> AuthenticatedExperienceReleaseCatalog {
        try await underlying.authenticateProfile(profile)
    }

    func prepare(
        definition: AuthenticatedExperienceReleaseDefinition,
        intent: ExperienceReleasePreparationIntent
    ) async throws -> PreparedExperienceRelease {
        observedIntents.append(intent)
        if intent == .preload {
            preloadStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            while !shouldFailPreload {
                try Task.checkCancellation()
                await Task.yield()
            }
            throw URLError(.dataNotAllowed)
        }
        return try await underlying.prepare(definition: definition, intent: intent)
    }

    func waitUntilPreloadStarted() async {
        guard !preloadStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func failPreload() { shouldFailPreload = true }

    func intents() -> [ExperienceReleasePreparationIntent] { observedIntents }
}

private final class LockedRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private enum PreloadPreparationProbeError: Error {
    case expectedFailure
}

private actor PreloadPreparationGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
