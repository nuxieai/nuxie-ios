#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie

enum TestExperienceRuntimeFixture {
    static func purchase(navigation: Bool) async throws -> (Experience, LoadedExperienceArtifact) {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(navigation ? "fixtures/journeys/rendered-purchase-navigation" : "fixtures/journeys/rendered-purchase-scopes")
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: fixture.appendingPathComponent("release-entry.json"))) as? [String: Any])
        let locator = try XCTUnwrap(entry["locator"] as? [String: Any])
        let envelope = try XCTUnwrap(entry["envelope"] as? [String: Any])
        let descriptorBytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["descriptorBytesBase64"] as? String)))
        try JourneyReleaseSchemaValidator.validate(try XCTUnwrap(JSONSerialization.jsonObject(with: descriptorBytes) as? [String: Any]))
        let profile: [String: Any] = [
            "schemaVersion": "nuxie.journey-plane-profile.v2", "status": "ok",
            "delivery": ["renderBaseUrl": "https://purchase.sdk-fixtures.nuxie.test/",
                         "assetBaseUrl": "https://purchase.sdk-fixtures.nuxie.test/"],
            "features": [], "facts": ["properties": [:], "memberships": [:], "assignments": [:]],
            "armedLegs": [[
                "reference": [
                    "experienceId": try XCTUnwrap(locator["experienceId"]),
                    "versionId": try XCTUnwrap(locator["experienceVersionId"]),
                    "legId": try XCTUnwrap(locator["legId"]),
                    "descriptorSha256": try XCTUnwrap(envelope["descriptorSha256"]),
                ],
                "binding": ["type": "new"],
                "entryCondition": ["type": "app_foregrounded"],
                "context": ["event": [:], "responses": [:]],
            ]], "releases": [entry],
        ]
        return try await artifact(at: fixture,
            profileBytes: JSONSerialization.data(withJSONObject: profile))
    }

    static func artifact(
        at fixture: URL,
        profileBytes suppliedProfileBytes: Data? = nil
    ) async throws -> (Experience, LoadedExperienceArtifact) {
        StubURLProtocol.reset()
        let profileBytes = try suppliedProfileBytes ?? Data(
            contentsOf: fixture.appendingPathComponent("profile.json")
        )
        let profile = try JourneyPlaneProfile.decode(profileBytes)
        let host = try XCTUnwrap(URL(string: profile.delivery.renderBaseUrl)?.host)
        StubURLProtocol.register(matcher: { $0.url?.host == host }) { request in
            let file = fixture.appendingPathComponent(String(request.url!.path.dropFirst()))
            let bytes = try Data(contentsOf: file)
            let contentType: String
            switch file.pathExtension {
            case "nux": contentType = "application/vnd.nuxie.scene"
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
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
            "authenticated-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: cache,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = JourneyReleaseAcquisitionStore(
            cacheDirectory: cache,
            urlSession: TestURLSessionProvider.createTestSession()
        )
        let catalog = JourneyProfileCatalog(
            authorizationKeys: try JourneyTrustRoots.keys(for: .development),
            supportedRuntime: JourneyReleaseRuntime.current,
            highWaterStore: InMemoryJourneyReleaseHighWaterStore()
        )
        let firstEntry = try XCTUnwrap(profile.releases.first)
        let authenticated = try await catalog.prepare(
            profile,
            authority: ProfileDeliveryAuthority(
                appId: firstEntry.locator.appId,
                environment: firstEntry.locator.environment
            )
        ).snapshot
        let release = try XCTUnwrap(authenticated.releasesByDigest.values.first)
        let screenID = try XCTUnwrap(release.descriptor.leg.screens.first?.id)
        let presentation = try await store.preparePresentation(
            release: release,
            delivery: profile.delivery,
            pinnedArtifacts: nil,
            productResolver: { _ in [] }
        )
        return (presentation.experience, LoadedExperienceArtifact(acquired: try await presentation.artifactLoader(
            presentation.experience,
            nil,
            screenID
        )))
    }
}
#endif
