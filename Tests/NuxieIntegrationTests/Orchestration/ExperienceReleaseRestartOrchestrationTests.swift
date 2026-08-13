import Foundation
import Nimble
import Quick
@testable import Nuxie
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
                    experiences: [],
                    segments: [],
                    pinnedVersions: [],
                    assetBaseUrl: fixture.delivery.assetBaseUrl,
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
                expect(first?.artifact).to(beNil())
                expect(first?.journey.screens.map(\.id)).to(equal(["screen_welcome"]))
                expect(requests.count).to(equal(3))

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
                expect(cached?.experiences).to(beEmpty())
                let restored = await core?.profile.getEffectiveExperienceReferences(
                    distinctId: "release-restart-user"
                )
                expect(restored?.map(\.experienceId)).to(equal(["release-only-experience"]))
                let second = try await core?.experiences.fetchExperience(
                    experienceId: fixture.entry.locator.experienceId,
                    versionId: fixture.entry.locator.experienceVersionId
                )
                expect(second?.artifact).to(beNil())
                expect(requests.count).to(equal(6))

                expect(FileManager.default.fileExists(atPath: ledger.path)).to(beTrue())
            }
        }
    }

    private static func makeCore(storageURL: URL, api: MockNuxieApi) -> NuxieCore {
        let configuration = NuxieConfiguration(apiKey: "release-restart-key")
        configuration.environment = .development
        configuration.customStoragePath = storageURL
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        configuration.urlSession = URLSession(configuration: sessionConfiguration)
        var overrides = NuxieCoreOverrides()
        overrides.api = api
        overrides.dateProvider = MockDateProvider()
        overrides.sleepProvider = MockSleepProvider()
        overrides.experiencePresentation = MockExperiencePresentationService()
        return NuxieCore(configuration: configuration, overrides: overrides)
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
