#if canImport(UIKit)
import UIKit
import XCTest
@testable import Nuxie

@MainActor
final class PublishedRuntimeFixtureLoadTests: XCTestCase {
    func testCommittedCorpusContainsReadableSignedPackages() throws {
        let root = try Self.fixturesRootURL()
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let packageURLs = directories
            .map { $0.appendingPathComponent("experience.nux") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        XCTAssertGreaterThanOrEqual(packageURLs.count, 9)
        for url in packageURLs {
            let package = try NuxPackageReader.read(Data(contentsOf: url))
            XCTAssertFalse(package.manifest.identity.experienceId.isEmpty, url.path)
            XCTAssertFalse(package.journey.screens.isEmpty, url.path)
            XCTAssertNotNil(package.member(named: "signature"), url.path)
        }
    }

    func testSignedPackageMountsThroughFixtureHost() throws {
        let root = try Self.fixturesRootURL()
            .appendingPathComponent("animation-event", isDirectory: true)
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nux-package-host-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let viewController = try ExperienceRuntimeFixtureHost.makeViewController(
            fixtureBaseURL: root,
            cacheRootURL: cacheRoot
        )
        viewController.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        viewController.loadViewIfNeeded()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              Self.findSubview(identifier: "nuxie-experience-surface", in: viewController.view) == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertNotNil(
            Self.findSubview(identifier: "nuxie-experience-surface", in: viewController.view)
        )
    }

    private static func fixturesRootURL() throws -> URL {
        let candidates = [
            Bundle(for: Self.self).resourceURL?
                .appendingPathComponent("Fixtures", isDirectory: true),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ExperienceRuntimeHostApp/Fixtures", isDirectory: true),
        ].compactMap { $0 }
        guard let root = candidates.first(where: {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("native-corpus-manifest.json").path
            )
        }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root
    }

    private static func findSubview(identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier {
            return view
        }
        return view.subviews.lazy.compactMap {
            findSubview(identifier: identifier, in: $0)
        }.first
    }
}
#endif
