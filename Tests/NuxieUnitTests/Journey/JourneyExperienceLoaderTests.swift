import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class JourneyExperienceLoaderTests: JourneyTestCase {
    func testRenderedProductBoundScreenResolvesItsAuthenticatedStoreKitPlacements() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = replacing(
            try await authenticatedRenderedSnapshot(fixture),
            viewModelValues: [[
                "viewModelName": .string("WelcomeModel"),
                "instanceId": .string("welcome"),
                "path": .string("products"),
                "value": .array([
                    .object(["placementId": .string("golden:monthly")]),
                    .object(["placementId": .string("golden:yearly")]),
                ]),
            ]]
        )
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let productService = MockProductService()
        productService.mockProducts = [
            MockStoreProduct(
                id: "monthly",
                displayName: "Monthly",
                price: 9.99,
                displayPrice: "$9.99",
                productType: .autoRenewable
            ),
            MockStoreProduct(
                id: "yearly",
                displayName: "Yearly",
                price: 79.99,
                displayPrice: "$79.99",
                productType: .autoRenewable
            ),
        ]
        let releaseStore = JourneyReleaseAcquisitionStore(
            cacheDirectory: directory
        )
        let loader = JourneyReleaseCatalog(
            productService: productService,
            releaseStore: releaseStore
        )

        let products = try await loader.productsForJourneyPresentation(
            release: release,
            screenID: "screen_welcome"
        )

        XCTAssertEqual(productService.requestedProductIds, ["monthly", "yearly"])
        XCTAssertEqual(Set(products.map(\.productId)), ["monthly", "yearly"])
        XCTAssertEqual(
            Set(products.map(\.placementId)),
            ["golden:monthly", "golden:yearly"]
        )
    }

    func testCanonicalProfileRegistersJourneyProductsForRecovery() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let snapshot = try replacingWithHeadlessArtifacts(
            try await authenticatedRenderedSnapshot(fixture)
        )
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let loader = JourneyReleaseCatalog(
            productService: ProductService(),
            releaseStore: JourneyReleaseAcquisitionStore(
                cacheDirectory: directory
            )
        )

        let preparedProfile = try await loader.prepareJourneyProfile(snapshot)
        let admitted = await loader.commitJourneyProfile(
            preparedProfile,
            generation: 1
        )
        XCTAssertTrue(admitted)
        let activeAuthority = await loader.purchaseEvidenceAuthority(
            storeProductId: "monthly"
        )
        XCTAssertEqual(
            activeAuthority,
            .nativeStoreKit
        )
        let exactAllowances = await loader.optimisticEntitlementAllowances(
            releaseDescriptorSHA256: release.descriptorSHA256,
            productId: "monthly",
            storeProductId: "monthly"
        )
        XCTAssertEqual(
            exactAllowances,
            []
        )

        _ = await loader.commitJourneyProfile(
            PreparedJourneyProfileArtifacts(snapshot: nil),
            generation: 2
        )
        let clearedAuthority = await loader.purchaseEvidenceAuthority(
            storeProductId: "monthly"
        )
        XCTAssertEqual(
            clearedAuthority,
            .unavailable
        )
        let clearedAllowances = await loader.optimisticEntitlementAllowances(
            releaseDescriptorSHA256: release.descriptorSHA256,
            productId: "monthly",
            storeProductId: "monthly"
        )
        XCTAssertNil(clearedAllowances)
    }

    func testSupersededProfileDoesNotPublishJourneyProductAuthority() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let snapshot = try replacingWithHeadlessArtifacts(
            try await authenticatedRenderedSnapshot(fixture)
        )
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let loader = JourneyReleaseCatalog(
            productService: ProductService(),
            releaseStore: JourneyReleaseAcquisitionStore(
                cacheDirectory: directory
            )
        )
        let admission = SupersedingProfileAdmission()

        let preparedProfile = try await loader.prepareJourneyProfile(snapshot)
        let committed = await loader.commitJourneyProfile(
            preparedProfile,
            generation: 1,
            admission: ProfileSideEffectAdmission {
                admission.isCurrent()
            }
        )

        XCTAssertFalse(committed)
        XCTAssertEqual(admission.readCount, 2)
        let authority = await loader.purchaseEvidenceAuthority(
            storeProductId: "monthly"
        )
        XCTAssertEqual(authority, .unavailable)
        let allowances = await loader.optimisticEntitlementAllowances(
            releaseDescriptorSHA256: release.descriptorSHA256,
            productId: "monthly",
            storeProductId: "monthly"
        )
        XCTAssertNil(allowances)
    }

    func testRenderedScreenDoesNotLoadPurchasesReachableOnlyFromAnotherScreen() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = replacing(
            base,
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "buy_monthly",
                    action: [
                        "type": .string("purchase"),
                        "placementId": .object([
                            "literal": .string("golden:monthly")
                        ]),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "buy_yearly",
                    action: [
                        "type": .string("purchase"),
                        "placementId": .object([
                            "literal": .string("golden:yearly")
                        ]),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
            ],
            routes: [
                .init(
                    host: .init(kind: .screen, screenId: "screen_welcome"),
                    eventName: "buy",
                    entryStepId: "buy_monthly"
                ),
                .init(
                    host: .init(kind: .screen, screenId: "screen_details"),
                    eventName: "buy",
                    entryStepId: "buy_yearly"
                ),
            ],
            screens: [
                .init(
                    id: "screen_welcome",
                    defaultViewModelName: "WelcomeModel",
                    defaultInstanceId: "welcome",
                    responseCaptures: []
                ),
                .init(
                    id: "screen_details",
                    defaultViewModelName: "DetailsModel",
                    defaultInstanceId: "details",
                    responseCaptures: []
                ),
            ],
            viewModelValues: [[
                "viewModelName": .string("WelcomeModel"),
                "instanceId": .string("welcome"),
                "path": .string("product"),
                "value": .object([
                    "placementId": .string("golden:monthly")
                ]),
            ]]
        )
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let productService = MockProductService()
        productService.mockProducts = [MockStoreProduct(
            id: "monthly",
            displayName: "Monthly",
            price: 9.99,
            displayPrice: "$9.99",
            productType: .autoRenewable
        )]
        let loader = JourneyReleaseCatalog(
            productService: productService,
            releaseStore: JourneyReleaseAcquisitionStore(
                cacheDirectory: directory
            )
        )

        let products = try await loader.productsForJourneyPresentation(
            release: release,
            screenID: "screen_welcome"
        )

        XCTAssertEqual(productService.requestedProductIds, ["monthly"])
        XCTAssertEqual(products.map(\.productId), ["monthly"])
        XCTAssertEqual(products.map(\.placementId), ["golden:monthly"])
    }

    func testNuxVideoAcquisitionVerifiesOnceAndReusesOfflineFile() async throws {
        let directory = temporaryDirectory()
        defer { StubURLProtocol.reset(); removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let sceneBytes = Data("nux-scene".utf8)
        let videoBytes = Data(repeating: 7, count: 200_000)
        let digest = SHA256Provider.hexDigest(videoBytes)
        let video: JourneyReleaseJSONValue = .object([
            "kind": .string("video"), "key": .string("assets/sha256/\(digest).mp4"),
            "sha256": .string(digest), "sizeBytes": .number(Double(videoBytes.count)),
            "contentType": .string("video/mp4"), "required": .bool(true),
            "sourceAssetKey": .string("asset:greeting"), "riveAssetId": .number(1),
            "riveUniqueName": .string("video-greeting-1"), "width": .number(64), "height": .number(32),
            "durationMs": .number(2000), "videoCodec": .string("avc1.42e01e"), "audioCodec": .null,
            "captionTracks": .array([]),
        ])
        let snapshot = try replacingRenderedArtifact(try await authenticatedRenderedSnapshot(fixture),
            sceneBytes: sceneBytes, renderer: "nux", assets: [video], videoElements: [.object([
                "artboardId": .string("welcome"), "viewNodeId": .string("greeting"),
                "renderedNodeId": .string("greeting-instance"), "componentId": .number(7),
                "readinessTimeoutSeconds": .number(2.5), "optional": .bool(false),
            ])])
        let release = try XCTUnwrap(snapshot.releasesByDigest.values.first)
        let requests = JourneyArtifactRequestCounter()
        StubURLProtocol.register(matcher: { _ in true }) { request in
            requests.increment()
            let isVideo = request.url?.pathExtension == "mp4"
            let bytes = isVideo ? videoBytes : sceneBytes
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Length": String(bytes.count), "Content-Type": isVideo ? "video/mp4" : "application/vnd.nuxie.scene"])!, bytes)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let store = JourneyReleaseAcquisitionStore(cacheDirectory: directory, urlSession: session)
        let prepared = try await store.preparePresentation(release: release, delivery: snapshot.profile.delivery, productResolver: { _ in [] })
        let artifact = try await prepared.artifactLoader(prepared.experience, nil, "screen_welcome")
        XCTAssertEqual(requests.value, 2)
        XCTAssertEqual(artifact.sceneBytes, sceneBytes)
        let retained = try XCTUnwrap(artifact.payload.assets.first { $0.kind == .video })
        XCTAssertNil(retained.bytes)
        XCTAssertEqual(retained.fileURL, directory.appendingPathComponent(digest))
        XCTAssertEqual(artifact.payload.renderPlan.videos.first?.sourceAssetKey, "asset:greeting")
        XCTAssertEqual(artifact.payload.renderPlan.videoElements, [.init(
            artboardId: "welcome", viewNodeId: "greeting", renderedNodeId: "greeting-instance",
            componentId: 7, readinessTimeoutSeconds: 2.5, optional: false
        )])
        XCTAssertNotNil(artifact.payload.videoFileLease)
        XCTAssertEqual(artifact.resourceMetrics.hashedBytes, videoBytes.count + sceneBytes.count * 2)
        XCTAssertEqual(artifact.resourceMetrics.duplicateHashBytes, sceneBytes.count)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(digest)), videoBytes)
        StubURLProtocol.reset()
        StubURLProtocol.register(matcher: { _ in true }) { _ in
            requests.increment()
            throw URLError(.notConnectedToInternet)
        }
        let coldStore = JourneyReleaseAcquisitionStore(cacheDirectory: directory, urlSession: session)
        _ = try await coldStore.preparePresentation(release: release, delivery: snapshot.profile.delivery, productResolver: { _ in [] })
        XCTAssertEqual(requests.value, 2)
        let evictionStore = JourneyReleaseAcquisitionStore(cacheDirectory: directory, maximumCacheBytes: 0, urlSession: session)
        try await evictionStore.enforceCacheBudget(protecting: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(retained.fileURL).path))
        XCTAssertNotNil(artifact.payload.videoFileLease)
    }

    func testCanonicalProfileAcquiresRenderedArtifactsBeforePublishingAuthority() async throws {
        let directory = temporaryDirectory()
        defer {
            StubURLProtocol.reset()
            removeTemporaryDirectoryIfPresent(directory)
        }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let sceneBytes = Data("offline-ready-journey-scene".utf8)
        let snapshot = try replacingRenderedArtifact(
            try await authenticatedRenderedSnapshot(fixture),
            sceneBytes: sceneBytes
        )
        let release = try XCTUnwrap(snapshot.releasesByDigest.values.first)
        let requests = JourneyArtifactRequestCounter()
        StubURLProtocol.register(matcher: { _ in true }) { request in
            requests.increment()
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Length": String(sceneBytes.count),
                        "Content-Type": "application/vnd.rive",
                    ]
                )!,
                sceneBytes
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let store = JourneyReleaseAcquisitionStore(
            cacheDirectory: directory,
            urlSession: URLSession(configuration: configuration)
        )
        let loader = JourneyReleaseCatalog(
            productService: ProductService(),
            releaseStore: store
        )

        let preparedProfile = try await loader.prepareJourneyProfile(snapshot)
        XCTAssertEqual(requests.value, 1)
        let committed = await loader.commitJourneyProfile(
            preparedProfile,
            generation: 1
        )
        XCTAssertTrue(committed)

        StubURLProtocol.reset()
        StubURLProtocol.register(matcher: { _ in true }) { _ in
            requests.increment()
            throw URLError(.notConnectedToInternet)
        }
        let preparedPresentation = try await store.preparePresentation(
            release: release,
            delivery: snapshot.profile.delivery,
            productResolver: { _ in [] }
        )
        let artifact = try await preparedPresentation.artifactLoader(
            preparedPresentation.experience,
            nil,
            "screen_welcome"
        )

        XCTAssertEqual(requests.value, 1)
        XCTAssertEqual(artifact.sceneBytes, sceneBytes)
    }

    func testLiveRunRetainsRenderedArtifactsAcrossProfileReplacementAndRelaunch() async throws {
        let root = temporaryDirectory()
        let cacheDirectory = root.appendingPathComponent("cache")
        let journalDirectory = root.appendingPathComponent("journal")
        defer {
            StubURLProtocol.reset()
            removeTemporaryDirectoryIfPresent(root)
        }
        let fixture = try JourneyPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let sceneBytes = Data("durably-pinned-journey-scene".utf8)
        let snapshot = try replacingRenderedArtifact(
            try await authenticatedRenderedSnapshot(fixture),
            sceneBytes: sceneBytes
        )
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let requests = JourneyArtifactRequestCounter()
        StubURLProtocol.register(matcher: { _ in true }) { request in
            requests.increment()
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Length": String(sceneBytes.count),
                        "Content-Type": "application/vnd.rive",
                    ]
                )!,
                sceneBytes
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let store = JourneyReleaseAcquisitionStore(
            cacheDirectory: cacheDirectory,
            urlSession: URLSession(configuration: configuration)
        )
        let loader = JourneyReleaseCatalog(
            productService: ProductService(),
            releaseStore: store
        )
        var preparedProfile: PreparedJourneyProfileArtifacts? =
            try await loader.prepareJourneyProfile(snapshot)
        let artifactSource = try XCTUnwrap(
            preparedProfile?.artifacts?.source(
                for: release.descriptorSHA256
            )
        )
        let originalPin = try XCTUnwrap(snapshot.profile.releases.first)
        let releasePin = JourneyReleaseProfileEntry(
            locator: originalPin.locator,
            envelope: .init(
                mediaType: originalPin.envelope.mediaType,
                encoding: originalPin.envelope.encoding,
                descriptorSha256: release.descriptorSHA256,
                descriptorSizeBytes: release.exactDescriptorBytes.count,
                descriptorBytesBase64:
                    release.exactDescriptorBytes.base64EncodedString(),
                signature: originalPin.envelope.signature
            )
        )
        let journal = try JourneyRunJournal(
            directory: journalDirectory,
            distinctId: "customer"
        )
        let admitted = try await journal.admit(
            arm: arm,
            release: releasePin,
            artifactSource: artifactSource,
            executionSnapshot: .init(
                delivery: snapshot.profile.delivery,
                assignments: snapshot.profile.facts.assignments
            ),
            reentry: release.descriptor.leg.reentry,
            entryStepId: release.descriptor.leg.entryStepId,
            at: Date(timeIntervalSince1970: 1_000)
        )
        let run = try XCTUnwrap(admitted)
        preparedProfile = nil
        for object in artifactSource.objects {
            let cached = cacheDirectory.appendingPathComponent(object.sha256)
            if FileManager.default.fileExists(atPath: cached.path) {
                try FileManager.default.removeItem(at: cached)
            }
        }

        StubURLProtocol.reset()
        StubURLProtocol.register(matcher: { _ in true }) { _ in
            requests.increment()
            throw URLError(.notConnectedToInternet)
        }
        let relaunched = try JourneyRunJournal(
            directory: journalDirectory,
            distinctId: "customer"
        )
        let retainedArtifacts = try await relaunched.pinnedArtifacts(
            forRunId: run.id
        )
        let pinnedArtifacts = try XCTUnwrap(retainedArtifacts)
        let preparedPresentation = try await store.preparePresentation(
            release: release,
            delivery: snapshot.profile.delivery,
            pinnedArtifacts: pinnedArtifacts,
            productResolver: { _ in [] }
        )
        let artifact = try await preparedPresentation.artifactLoader(
            preparedPresentation.experience,
            nil,
            "screen_welcome"
        )

        XCTAssertEqual(requests.value, 1)
        XCTAssertEqual(artifact.sceneBytes, sceneBytes)
    }
}
