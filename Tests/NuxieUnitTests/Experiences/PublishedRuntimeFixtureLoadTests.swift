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
        StubURLProtocol.register(matcher: { $0.url?.host?.hasSuffix(".fixture.nuxie.test") == true }) {
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
            let profile = try JSONDecoder().decode(
                ExperienceReleaseProfileV2.self,
                from: Data(contentsOf: fixtureRoot.appendingPathComponent("profile.json"))
            )
            let cache = temporaryDirectory()
            let store = ExperienceReleaseAcquisitionStore(
                cacheDirectory: cache,
                urlSession: TestURLSessionProvider.createTestSession(),
                authorizationKeys: try ExperienceTrustRoots.keys(for: .development),
                supportedCompatibility: ExperienceReleaseRuntimeCompatibility.current,
                admission: ExperienceReleaseAdmission(
                    store: InMemoryExperienceReleaseHighWaterStore()
                )
            )
            let catalog = try await store.authenticateProfile(profile)
            let definition = try XCTUnwrap(catalog.definitions.first)
            XCTAssertEqual(catalog.definitions.count, 1, fixture.id)
            let initialScreenID = try XCTUnwrap(definition.journey.screens.first?.id)
            let artifact = try await store.presentationArtifact(
                definition: definition,
                initialScreenID: initialScreenID
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
