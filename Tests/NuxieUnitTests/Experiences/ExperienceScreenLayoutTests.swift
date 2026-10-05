#if canImport(UIKit)
import Foundation
import UIKit
import XCTest
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ExperienceScreenLayoutTests: XCTestCase {
    func testSessionReadsFixedPointBoundsAfterEachZeroStep() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ExperienceRuntimeHostApp/Fixtures/multi-screen")
        let artifact = try await authenticatedFixtureArtifact(at: fixture)
        let screen = try await ExperienceInteractiveScreen.open(payload: artifact.payload,
            pixelWidth: 1179, pixelHeight: 2556)
        do {
            let session = screen.presentationSession { _ in }
            XCTAssertEqual(session.artboardBounds(), CGRect(x: 0, y: 0, width: 320, height: 640))
            _ = try await session.perform(.resize(.init(pixelWidth: 1179, pixelHeight: 2556, layoutScaleFactor: 3)))
            _ = try await session.perform(.step(.init(elapsedSeconds: 0, pointers: [])))
            XCTAssertEqual(screen.artboardBounds, CGRect(x: 0, y: 0, width: 393, height: 852))
            XCTAssertEqual(session.artboardBounds(), CGRect(x: 0, y: 0, width: 393, height: 852))
            _ = try await session.perform(.resize(.init(pixelWidth: 1125, pixelHeight: 2001, layoutScaleFactor: 3)))
            _ = try await session.perform(.step(.init(elapsedSeconds: 0, pointers: [])))
            XCTAssertEqual(screen.artboardBounds, CGRect(x: 0, y: 0, width: 375, height: 667))
            XCTAssertEqual(session.artboardBounds(), CGRect(x: 0, y: 0, width: 375, height: 667))
            try await screen.close()
        } catch {
            try? await screen.close()
            throw error
        }
    }

    private func authenticatedFixtureArtifact(
        at fixture: URL
    ) async throws -> LoadedExperienceArtifact {
        StubURLProtocol.reset()
        let profileBytes = try Data(
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
        return LoadedExperienceArtifact(acquired: try await presentation.artifactLoader(
            presentation.experience,
            nil,
            screenID
        ))
    }

}
#endif
