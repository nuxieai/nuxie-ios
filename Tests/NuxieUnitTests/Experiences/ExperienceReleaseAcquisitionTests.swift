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
        let (entry, delivery) = try releaseEntry(riv: riv, image: image, script: script)
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
        XCTAssertEqual(requests.count, 3)
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
        entry = ExperienceReleaseProfileEntryV1(
            locator: ExperienceReleaseIdentityV1(
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
        let image = Data([1, 2, 3, 4])
        let (entry, delivery) = try releaseEntry(riv: riv, image: image)
        let cache = temporaryDirectory()
        StubURLProtocol.register(
            matcher: { $0.url?.host == "cdn.nuxie.test" },
            handler: { request in
                let bytes = request.url!.path.contains("/renders/")
                    ? Data("RIVE tampered".utf8) : image
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

        do {
            _ = try await makeStore(cache: cache).acquire(
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

    func testRejectsRemoteIdentityMismatchBeforeObjectRequests() async throws {
        let riv = Data("RIVE expected".utf8)
        let image = Data([1, 2, 3, 4])
        let (entry, delivery) = try releaseEntry(riv: riv, image: image)
        var requests = 0
        StubURLProtocol.register(matcher: { _ in true }) { request in
            requests += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, nil)
        }
        let remote = RemoteExperience(
            experienceId: entry.locator.experienceId,
            versionId: "wrong-version",
            buildId: entry.locator.buildId,
            artifact: .init(
                url: "https://legacy.nuxie.test/unused.nux",
                sha256: String(repeating: "0", count: 64),
                sizeBytes: 1
            ),
            name: "mismatch",
            reentry: .everyTime,
            publishedAt: entry.locator.publishedAt
        )

        do {
            _ = try await makeStore(cache: temporaryDirectory()).presentationPackage(
                entry: entry,
                delivery: delivery,
                mode: .active,
                remote: remote
            )
            XCTFail("expected identity mismatch")
        } catch {
            XCTAssertEqual(
                (error as? ExperienceReleaseDescriptorAuthenticationError)?.contractCode,
                "experience_release.identity.mismatch"
            )
        }
        XCTAssertEqual(requests, 0)
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

    func testMatchingReleaseFailureNeverFallsBackToLegacyPackagePointer() async throws {
        let (valid, delivery) = try releaseEntry(
            riv: Data("RIVE".utf8),
            image: Data([1])
        )
        let badEnvelope = ExperienceReleaseDescriptorEnvelopeV1(
            mediaType: ExperienceReleaseDescriptorLimits.mediaType,
            encoding: "base64",
            descriptorSha256: valid.descriptorSha256,
            descriptorSizeBytes: try validDescriptorBytes(valid).count,
            descriptorBytesBase64: try validDescriptorBytes(valid).base64EncodedString(),
            signature: .init(
                version: 1,
                algorithm: "ed25519",
                keyId: "TEST_ONLY_DEV_KEYPAIR",
                signatureBase64: Data(repeating: 0, count: 64).base64EncodedString()
            )
        )
        let entry = ExperienceReleaseProfileEntryV1(
            locator: valid.locator,
            descriptorSha256: valid.descriptorSha256,
            envelopeBytes: try badEnvelope.canonicalBytes()
        )
        var requests = 0
        StubURLProtocol.register(matcher: { _ in true }) { request in
            requests += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data([0]))
        }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubURLProtocol.self]
        let legacyStore = ExperiencePackageStore(
            urlSession: URLSession(configuration: sessionConfig),
            authorizationKeys: []
        )
        let store = ExperienceStore(
            api: MockNuxieApi(),
            productService: ProductService(),
            packageStore: legacyStore,
            releaseStore: makeStore(cache: temporaryDirectory())
        )
        let remote = RemoteExperience(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId,
            buildId: entry.locator.buildId,
            artifact: .init(
                url: "https://legacy.nuxie.test/experience.nux",
                sha256: String(repeating: "a", count: 64),
                sizeBytes: 1
            ),
            name: "legacy",
            reentry: .everyTime,
            publishedAt: entry.locator.publishedAt
        )
        await store.registerExperiences([remote], assetBaseURL: URL(string: delivery.assetBaseUrl)!)
        do {
            _ = try await store.replaceReleaseProfile(.init(
                delivery: delivery, active: [entry], pinned: []
            ))
            XCTFail("expected signed release failure")
        } catch {
            XCTAssertEqual(
                (error as? ExperienceReleaseDescriptorAuthenticationError)?.contractCode,
                "experience_release.signature.bad_signature"
            )
        }
        XCTAssertEqual(requests, 0)
    }

    func testDeclaredReleaseWithoutAcquisitionStoreNeverFallsBackToLegacyPackage() async throws {
        let (entry, delivery) = try releaseEntry(
            riv: Data("RIVE".utf8),
            image: Data([1])
        )
        var requests = 0
        StubURLProtocol.register(matcher: { _ in true }) { request in
            requests += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data([0]))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let store = ExperienceStore(
            api: MockNuxieApi(),
            productService: ProductService(),
            packageStore: ExperiencePackageStore(
                urlSession: URLSession(configuration: config),
                authorizationKeys: []
            ),
            releaseStore: nil
        )
        do {
            _ = try await store.replaceReleaseProfile(.init(
                delivery: delivery, active: [entry], pinned: []
            ))
            XCTFail("expected unavailable release acquisition")
        } catch let error as ExperienceReleaseAcquisitionError {
            XCTAssertEqual(error.contractCode, "experience_release.artifact.required_unavailable")
        }
        XCTAssertEqual(requests, 0)
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
        let store = ExperienceStore(
            api: MockNuxieApi(),
            productService: ProductService(),
            packageStore: ExperiencePackageStore(),
            releaseStore: releaseStore
        )
        let remote = RemoteExperience(
            experienceId: entry.locator.experienceId,
            versionId: entry.locator.experienceVersionId,
            buildId: entry.locator.buildId,
            artifact: .init(
                url: "https://legacy.nuxie.test/unused.nux",
                sha256: String(repeating: "0", count: 64),
                sizeBytes: 1
            ),
            name: "overlap",
            reentry: .everyTime,
            publishedAt: entry.locator.publishedAt
        )
        await store.registerExperiences([remote], assetBaseURL: URL(string: delivery.assetBaseUrl)!)
        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery,
            active: [entry],
            pinned: [entry]
        ))

        _ = try await store.experience(
            experienceId: remote.experienceId,
            versionId: remote.versionId
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
        let store = ExperienceStore(
            api: MockNuxieApi(),
            productService: ProductService(),
            packageStore: ExperiencePackageStore(),
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
        let envelope = ExperienceReleaseDescriptorEnvelopeV1(
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
        let envelope = ExperienceReleaseDescriptorEnvelopeV1(
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
            ExperienceReleaseDescriptorEnvelopeV1.self,
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
        let noncanonical = ExperienceReleaseProfileEntryV1(
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
        let profile = ExperienceReleaseProfileV1(
            delivery: delivery,
            active: Array(repeating: entry, count: 9),
            pinned: []
        )

        let decoded = try JSONDecoder().decode(
            ExperienceReleaseProfileV1.self,
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
        let profile = ExperienceReleaseProfileV1(
            delivery: delivery,
            active: entries,
            pinned: []
        )

        XCTAssertThrowsError(try JSONDecoder().decode(
            ExperienceReleaseProfileV1.self,
            from: JSONEncoder().encode(profile)
        ))
    }

    func testAdmissionRejectsUnsupportedSignedTriggerAndPresentationSemantics() async throws {
        let (entry, delivery) = try releaseEntry(
            riv: Data("RIVE unsupported semantics".utf8),
            image: Data([6])
        )
        let triggerDocuments: [[String: Any]] = [
            ["type": "segment", "allOf": ["segment_1"]],
            ["type": "api"],
            [
                "type": "server_event",
                "connectorKey": "connector_1",
                "triggerKey": "trigger_1",
            ],
        ]
        let unsupportedTriggers = try triggerDocuments.map { trigger in
            try resign(entry: entry) { root in
                var enrollment = try XCTUnwrap(root["enrollment"] as? [String: Any])
                enrollment["trigger"] = trigger
                root["enrollment"] = enrollment
            }
        }
        let unsupportedPresentations = try ["sheet", "drawer"].map { style in
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
        let store = makeStore(cache: temporaryDirectory())

        for unsupported in unsupportedTriggers + unsupportedPresentations {
            do {
                _ = try await store.authenticateProfile(.init(
                    delivery: delivery,
                    active: [unsupported],
                    pinned: []
                ))
                XCTFail("expected unsupported signed semantics to fail closed")
            } catch let error as ExperienceReleaseAcquisitionError {
                XCTAssertEqual(error, .invalidProfileEntry)
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
        let store = ExperienceStore(
            api: MockNuxieApi(),
            productService: ProductService(),
            packageStore: ExperiencePackageStore(),
            releaseStore: releaseStore
        )
        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery, active: [entry], pinned: []
        ))
        let invalid = ExperienceReleaseProfileEntryV1(
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

        let retained = await store.authenticatedReleaseReferences()
        XCTAssertEqual(retained.map(\.versionId), [entry.locator.experienceVersionId])
    }

    func testReplacementDuringSignedLoadCannotCommitStaleAuthenticatedRelease() async throws {
        let riv = Data("RIVE stale load".utf8)
        let image = Data([7, 7, 7])
        let script = Data("stale script".utf8)
        let (entry, delivery) = try releaseEntry(riv: riv, image: image, script: script)
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
        let store = ExperienceStore(
            api: MockNuxieApi(),
            productService: products,
            packageStore: ExperiencePackageStore(),
            releaseStore: makeStore(cache: temporaryDirectory())
        )
        _ = try await store.replaceReleaseProfile(.init(
            delivery: delivery, active: [entry], pinned: []
        ))
        let loading = Task {
            try await store.experience(
                experienceId: entry.locator.experienceId,
                versionId: entry.locator.experienceVersionId
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
        let cached = await store.cachedExperience(versionId: entry.locator.experienceVersionId)
        XCTAssertNil(cached)
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
        let store = ExperienceStore(
            api: MockNuxieApi(),
            productService: ProductService(),
            packageStore: ExperiencePackageStore(),
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

    private func releaseEntry(
        riv: Data,
        image: Data,
        script: Data = Data("compiled luau".utf8),
        imageRequired: Bool = true
    ) throws -> (ExperienceReleaseProfileEntryV1, ExperienceReleaseDeliveryV1) {
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
        let envelope = ExperienceReleaseDescriptorEnvelopeV1(
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
            ExperienceReleaseDescriptorV1.self,
            from: descriptor
        ).identity
        return (
            ExperienceReleaseProfileEntryV1(
                locator: identity,
                descriptorSha256: digest,
                envelopeBytes: try envelope.canonicalBytes()
            ),
            ExperienceReleaseDeliveryV1(
                renderBaseUrl: "https://cdn.nuxie.test/renders/",
                assetBaseUrl: "https://cdn.nuxie.test/assets/"
            )
        )
    }

    private func resign(
        entry: ExperienceReleaseProfileEntryV1,
        mutate: (inout [String: Any]) throws -> Void
    ) throws -> ExperienceReleaseProfileEntryV1 {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try validDescriptorBytes(entry)) as? [String: Any]
        )
        try mutate(&root)
        let descriptor = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let signature = try signingKey.signature(
            for: Data(ExperienceReleaseDescriptorLimits.signatureDomain.utf8) + descriptor
        )
        let digest = SHA256Provider.hexDigest(descriptor)
        let envelope = ExperienceReleaseDescriptorEnvelopeV1(
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
            ExperienceReleaseDescriptorV1.self,
            from: descriptor
        ).identity
        return .init(
            locator: identity,
            descriptorSha256: digest,
            envelopeBytes: try envelope.canonicalBytes()
        )
    }

    private func budgetEntry(
        locator: ExperienceReleaseIdentityV1,
        seed: UInt8
    ) throws -> ExperienceReleaseProfileEntryV1 {
        let descriptor = Data(
            repeating: seed,
            count: ExperienceReleaseDescriptorLimits.descriptorBytes
        )
        let digest = SHA256Provider.hexDigest(descriptor)
        let envelope = ExperienceReleaseDescriptorEnvelopeV1(
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

    private func makeStore(cache: URL) -> ExperienceReleaseAcquisitionStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ExperienceReleaseAcquisitionStore(
            cacheDirectory: cache,
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
            ExperienceReleaseDescriptorEnvelopeV1.self,
            from: Data(contentsOf: root
                .appendingPathComponent("fixtures/experience-release-descriptor-v1/envelope.json"))
        )
        return try XCTUnwrap(Data(base64Encoded: envelope.descriptorBytesBase64))
    }

    private func validDescriptorBytes(
        _ entry: ExperienceReleaseProfileEntryV1
    ) throws -> Data {
        let envelope = try JSONDecoder().decode(
            ExperienceReleaseDescriptorEnvelopeV1.self,
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
    private var requestCount = 0

    init(underlying: ExperienceReleaseAcquisitionStore) {
        self.underlying = underlying
    }

    func authenticateProfile(
        _ profile: ExperienceReleaseProfileV1
    ) async throws -> AuthenticatedExperienceReleaseCatalog {
        try await underlying.authenticateProfile(profile)
    }

    func presentationPackage(
        definition: AuthenticatedExperienceReleaseDefinition,
        initialScreenID: String
    ) async throws -> AcquiredExperiencePackage {
        requestCount += 1
        let package = try await underlying.presentationPackage(
            definition: definition,
            initialScreenID: initialScreenID
        )
        if !didAcquireFirstPackage {
            didAcquireFirstPackage = true
            firstPackageWaiters.forEach { $0.resume() }
            firstPackageWaiters.removeAll()
            await withCheckedContinuation { firstPackageResume = $0 }
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

    func presentationRequestCount() -> Int { requestCount }
}
