import Foundation
import Nimble
import Quick
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class ExperienceReleaseRestartOrchestrationTests: AsyncSpec {
    override class func spec() {
        describe("descriptor release composition restart") {
            var storageURL: URL!
            var core: NuxieCore?

            beforeEach {
                storageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "nuxie-release-restart-\(UUID().uuidString)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: storageURL,
                    withIntermediateDirectories: true
                )
                StubURLProtocol.reset()
            }

            afterEach {
                await core?.journeys.shutdown()
                await core?.eventLog.close()
                core = nil
                StubURLProtocol.reset()
                try? FileManager.default.removeItem(at: storageURL)
            }

            it("restores a release-only signed profile, replay ledger, and object cache") {
                let fixture = try ExperienceReleaseTestFixture.make()
                let profile = ProfileResponse(
                    segments: [],
                    releases: .init(
                        delivery: fixture.delivery,
                        active: [fixture.entry],
                        pinned: []
                    ),
                    userProperties: nil,
                    experiments: nil,
                    features: nil
                )
                let api = MockNuxieApi()
                await api.setProfileResponse(profile)
                let requests = ReleaseRequestLedger()
                StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) {
                    request in
                    requests.append(request.url!.path)
                    let bytes = request.url!.path.hasSuffix(".riv")
                        ? fixture.riv
                        : (request.url!.path.hasSuffix(".bin") ? fixture.script : fixture.image)
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

                core = makeCore(storageURL: storageURL, api: api)
                core?.identity.setDistinctId("release-restart-user")
                _ = try await core?.profile.refetchProfile(
                    distinctId: "release-restart-user"
                )
                let first = try await core?.experiences.fetchExperience(
                    experienceId: fixture.entry.locator.experienceId,
                    versionId: fixture.entry.locator.experienceVersionId
                )
                expect(first?.authenticatedReleaseID).toNot(beNil())
                expect(first?.journey.screens.map(\.id)).to(equal(["screen_welcome"]))
                guard let first, let firstExperiences = core?.experiences else {
                    fail("expected authenticated first release")
                    return
                }
                _ = try await firstExperiences.presentationArtifact(
                    for: first,
                    initialScreenID: "screen_welcome"
                )
                expect(requests.count).to(equal(2))

                await core?.journeys.shutdown()
                await core?.eventLog.close()
                core = nil
                let objectCache = storageURL
                    .appendingPathComponent("nuxie_release_delivery/objects")
                let ledger = storageURL
                    .appendingPathComponent("nuxie_release_delivery/admission/high-water-v1.json")
                expect(FileManager.default.fileExists(atPath: objectCache.path)).to(beTrue())
                expect(FileManager.default.fileExists(atPath: ledger.path)).to(beTrue())
                try FileManager.default.removeItem(at: objectCache)
                expect(FileManager.default.fileExists(atPath: ledger.path)).to(beTrue())
                await api.setShouldFailProfile(true)

                core = makeCore(storageURL: storageURL, api: api)
                core?.identity.setDistinctId("release-restart-user")
                let cached = await core?.profile.getCachedProfile(
                    distinctId: "release-restart-user"
                )
                expect(cached?.releases?.active.count).to(equal(1))
                let restored = await core?.profile.getEffectiveExperienceReferences(
                    distinctId: "release-restart-user"
                )
                expect(restored?.map(\.experienceId)).to(equal(["release-only-experience"]))
                let second = try await core?.experiences.fetchExperience(
                    experienceId: fixture.entry.locator.experienceId,
                    versionId: fixture.entry.locator.experienceVersionId
                )
                expect(second?.authenticatedReleaseID).toNot(beNil())
                guard let second, let secondExperiences = core?.experiences else {
                    fail("expected authenticated restored release")
                    return
                }
                _ = try await secondExperiences.presentationArtifact(
                    for: second,
                    initialScreenID: "screen_welcome"
                )
                expect(requests.count).to(equal(4))

                expect(FileManager.default.fileExists(atPath: ledger.path)).to(beTrue())
            }

            it("prepares one signed multi-screen RIV and opens isolated screen sessions") {
                let fixture = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        "ExperienceRuntimeHostApp/Fixtures/multi-screen",
                        isDirectory: true
                    )
                let releaseProfile = try JSONDecoder().decode(
                    ExperienceReleaseProfile.self,
                    from: Data(contentsOf: fixture.appendingPathComponent("profile.json"))
                )
                let api = MockNuxieApi()
                await api.setProfileResponse(ProfileResponse(
                    segments: [],
                    releases: .init(
                        delivery: releaseProfile.delivery,
                        active: releaseProfile.active,
                        pinned: releaseProfile.pinned
                    )
                ))
                let requests = ReleaseRequestLedger()
                let deliveryHost = try XCTUnwrap(
                    URL(string: releaseProfile.delivery.renderBaseUrl)?.host
                )
                StubURLProtocol.register(matcher: { $0.url?.host == deliveryHost }) {
                    request in
                    requests.append(request.url!.path)
                    let file = fixture.appendingPathComponent(
                        String(request.url!.path.dropFirst())
                    )
                    let bytes = try Data(contentsOf: file)
                    return (
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: [
                                "Content-Type": "application/vnd.rive",
                                "Content-Length": String(bytes.count),
                            ]
                        )!,
                        bytes
                    )
                }

                core = makeCore(storageURL: storageURL, api: api)
                core?.identity.setDistinctId("prepared-riv-user")
                _ = try await core?.profile.refetchProfile(
                    distinctId: "prepared-riv-user"
                )
                let entry = try XCTUnwrap(releaseProfile.active.first)
                let experience = try await core?.experiences.fetchExperience(
                    experienceId: entry.locator.experienceId,
                    versionId: entry.locator.experienceVersionId
                )
                let resolved = try XCTUnwrap(experience)
                let screenIDs = resolved.journey.screens.map(\.id)
                expect(screenIDs.count).to(beGreaterThan(1))

                var sharedPreparation: ExperienceInteractivePreparation?
                for screenID in screenIDs {
                    let artifact = try await core?.experiences.presentationArtifact(
                        for: resolved,
                        initialScreenID: screenID
                    )
                    let acquired = try XCTUnwrap(artifact)
                    let preparation = try await acquired.interactivePreparation.preparation()
                    if let sharedPreparation {
                        expect(preparation === sharedPreparation).to(beTrue())
                    } else {
                        sharedPreparation = preparation
                    }
                    let screen = try await preparation.openScreen(
                        screenID: screenID,
                        pixelWidth: 32,
                        pixelHeight: 32
                    )
                    _ = try await screen.step(elapsedSeconds: 0)
                    try await screen.close()
                }

                let metrics = await sharedPreparation?.metrics()
                expect(metrics?.configuredFileImportCount).to(equal(1))
                expect(metrics?.openedSessionCount).to(equal(screenIDs.count))
                expect(requests.count).to(equal(1))
            }

            it("makes profile and mailbox authority usable without waiting for StoreKit") {
                let fixture = try ExperienceReleaseTestFixture.make()
                let invalidRelease = try invalidSignatureEntry(fixture.entry)
                let mailbox = JourneyMailboxEntry(
                    journeyId: "preload-mailbox-journey",
                    experienceId: fixture.entry.locator.experienceId,
                    experienceVersion: fixture.entry.locator.experienceVersionId,
                    epoch: 1,
                    stateVersion: JourneyStateEnvelope.currentVersion,
                    envelope: JourneyStateEnvelope(
                        context: ["source": AnyCodable("mailbox")],
                        executionState: JourneyExecutionState(),
                        snapshots: [:],
                        responseSession: nil
                    ),
                    expiresAt: Date().addingTimeInterval(3_600)
                )
                let profile = ProfileResponse(
                    segments: [],
                    releases: .init(
                        delivery: fixture.delivery,
                        active: [fixture.entry, invalidRelease],
                        pinned: []
                    ),
                    userProperties: nil,
                    experiments: nil,
                    features: nil,
                    mailbox: [mailbox]
                )
                let api = MockNuxieApi()
                await api.setProfileResponse(profile)
                let requests = ReleaseRequestLedger()
                StubURLProtocol.register(matcher: { $0.url?.host == "cdn.nuxie.test" }) {
                    request in
                    requests.append(request.url!.path)
                    let bytes = request.url!.path.hasSuffix(".riv")
                        ? fixture.riv
                        : (request.url!.path.hasSuffix(".bin") ? fixture.script : fixture.image)
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
                let products = RecordingPreloadProductService()
                let mailboxProbe = ReleaseMailboxProbe()

                core = makeCore(
                    storageURL: storageURL,
                    api: api,
                    productService: products
                )
                core?.identity.setDistinctId("preload-user")
                await core?.profile.setJourneyMailboxHandler { entries, distinctId in
                    mailboxProbe.record(entries: entries, distinctId: distinctId)
                }

                _ = try await core?.profile.refetchProfile(distinctId: "preload-user")

                let effective = await core?.profile.getEffectiveExperienceReferences(
                    distinctId: "preload-user"
                )
                expect(effective).to(equal([ExperienceReference(
                    experienceId: fixture.entry.locator.experienceId,
                    versionId: fixture.entry.locator.experienceVersionId
                )]))
                expect(mailboxProbe.journeyIDs).to(equal([mailbox.journeyId]))
                expect(mailboxProbe.distinctId).to(equal("preload-user"))
                await expect { requests.count }
                    .toEventually(equal(2), timeout: .seconds(2))
                expect(products.didRequest).to(beFalse())
            }
        }
    }

    private static func makeCore(
        storageURL: URL,
        api: MockNuxieApi,
        productService: ProductService? = nil
    ) -> NuxieCore {
        let configuration = NuxieConfiguration(apiKey: "release-restart-key")
        configuration.environment = .development
        configuration.testingOverrides.customStoragePath = storageURL
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        configuration.testingOverrides.urlSession = URLSession(configuration: sessionConfiguration)
        var overrides = NuxieCoreOverrides()
        overrides.api = api
        overrides.dateProvider = MockDateProvider()
        overrides.sleepProvider = MockSleepProvider()
        overrides.experiencePresentation = MockExperiencePresentationService()
        overrides.productService = productService
        return NuxieCore(configuration: configuration, overrides: overrides)
    }

    private static func invalidSignatureEntry(
        _ entry: ExperienceReleaseProfileEntry
    ) throws -> ExperienceReleaseProfileEntry {
        let envelope = try JSONDecoder().decode(
            ExperienceReleaseDescriptorEnvelope.self,
            from: entry.exactEnvelopeBytes()
        )
        let invalid = ExperienceReleaseDescriptorEnvelope(
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
        return ExperienceReleaseProfileEntry(
            locator: entry.locator,
            descriptorSha256: entry.descriptorSha256,
            envelopeBytes: try invalid.canonicalBytes()
        )
    }
}

private final class ReleaseRequestLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func append(_ path: String) {
        lock.lock()
        paths.append(path)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return paths.count
    }
}

private final class ReleaseMailboxProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedJourneyIDs: [String] = []
    private var recordedDistinctId: String?

    func record(entries: [JourneyMailboxEntry], distinctId: String) {
        lock.lock()
        recordedJourneyIDs = entries.map(\.journeyId)
        recordedDistinctId = distinctId
        lock.unlock()
    }

    var journeyIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedJourneyIDs
    }

    var distinctId: String? {
        lock.lock()
        defer { lock.unlock() }
        return recordedDistinctId
    }
}

private final class RecordingPreloadProductService: ProductService, @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    override func fetchProducts(
        for identifiers: Set<String>
    ) async throws -> [any AppStoreProduct] {
        _ = identifiers
        lock.withLock { requested = true }
        return []
    }

    var didRequest: Bool {
        lock.withLock { requested }
    }

}
