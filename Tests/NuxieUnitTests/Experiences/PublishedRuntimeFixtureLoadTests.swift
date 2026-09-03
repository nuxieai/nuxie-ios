#if os(iOS)
import Foundation
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class PublishedRuntimeFixtureLoadTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        StubURLProtocol.reset()
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testEveryCommittedRuntimeFixtureAuthenticatesAndAcquiresExactObjects() async throws {
        let fixturesRoot = try fixturesRootURL()
        let index = try JSONDecoder().decode(
            FixtureIndex.self,
            from: Data(contentsOf: fixturesRoot.appendingPathComponent("fixture-index.json"))
        )
        XCTAssertEqual(index.schemaVersion, "nuxie-sdk-releases.v1")
        StubURLProtocol.register(matcher: {
            $0.url?.host?.hasSuffix(".sdk-fixtures.nuxie.test") == true
        }) {
            request in
            let fixtureID = request.url!.host!.components(separatedBy: ".").first!
            let fileURL = fixturesRoot.appendingPathComponent(fixtureID)
                .appendingPathComponent(String(request.url!.path.dropFirst()))
            let bytes = try Data(contentsOf: fileURL)
            let contentType: String
            switch fileURL.pathExtension {
            case "riv": contentType = "application/vnd.rive"
            case "png": contentType = "image/png"
            case "ttf": contentType = "font/ttf"
            default: contentType = "application/octet-stream"
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": contentType,
                        "Content-Length": String(bytes.count),
                    ]
                )!,
                bytes
            )
        }

        for fixture in index.fixtures {
            let fixtureRoot = fixturesRoot.appendingPathComponent(fixture.id)
            let profile = try JourneyPlaneProfile.decode(
                Data(contentsOf: fixtureRoot.appendingPathComponent("profile.json"))
            )
            let locator = try XCTUnwrap(profile.releases.first?.locator)
            let profileCatalog = JourneyProfileCatalog(
                authorizationKeys: try JourneyTrustRoots.keys(for: .development),
                supportedRuntime: JourneyReleaseRuntime.current,
                highWaterStore: InMemoryJourneyReleaseHighWaterStore()
            )
            let preparedProfile = try await profileCatalog.prepare(
                profile,
                authority: ProfileDeliveryAuthority(
                    appId: locator.appId,
                    environment: locator.environment
                )
            )
            let didCommitProfile = try await profileCatalog.commit(
                preparedProfile,
                distinctId: "journey-fixture"
            )
            XCTAssertTrue(didCommitProfile)
            let arm = try XCTUnwrap(profile.armedLegs.first)
            let release = try XCTUnwrap(
                preparedProfile.snapshot.releasesByDigest[
                    arm.reference.descriptorSha256
                ]
            )
            let cache = temporaryDirectory()
            let store = JourneyReleaseAcquisitionStore(
                cacheDirectory: cache,
                urlSession: TestURLSessionProvider.createTestSession()
            )
            let preparedArtifacts = try await store.prepareJourneyArtifacts(
                for: preparedProfile.snapshot
            )
            XCTAssertEqual(
                preparedArtifacts.releaseDescriptorSHA256s,
                Set(preparedProfile.snapshot.releasesByDigest.keys),
                fixture.id
            )
            let presentation = try await store.preparePresentation(
                release: release,
                delivery: profile.delivery,
                productResolver: { _ in [] }
            )
            let initialScreenID = try XCTUnwrap(
                release.descriptor.leg.screens.first?.id
            )
            let artifact = try await presentation.artifactLoader(
                presentation.experience,
                nil,
                initialScreenID
            )
            XCTAssertFalse(artifact.sceneBytes.isEmpty, fixture.id)
            XCTAssertEqual(artifact.payload.renderPlan.entry.screenId, initialScreenID, fixture.id)
            XCTAssertEqual(artifact.payload.authenticatedKeyID, "TEST_ONLY_DEV_KEYPAIR", fixture.id)
        }
    }

    private func fixturesRootURL() throws -> URL {
        let candidates = [
            Bundle(for: Self.self).resourceURL?.appendingPathComponent("Fixtures"),
            Bundle(for: Self.self).resourceURL,
        ].compactMap { $0 }
        return try XCTUnwrap(candidates.first {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("fixture-index.json").path
            )
        })
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("published-runtime-fixture-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return directory
    }
}

private struct FixtureIndex: Decodable {
    struct Fixture: Decodable { let id: String }
    let schemaVersion: String
    let fixtures: [Fixture]
}
#endif
