#if canImport(UIKit)
import UIKit
import XCTest
import NuxieRuntime
@testable import Nuxie

@MainActor
final class PublishedRuntimeFixtureLoadTests: XCTestCase {
    func testFixtureIndexNamesEveryReadableSignedPackage() throws {
        let root = try Self.fixturesRootURL()
        let index = try JSONDecoder().decode(
            SDKFixtureIndex.self,
            from: Data(contentsOf: root.appendingPathComponent("fixture-index.json"))
        )
        XCTAssertEqual(index.schemaVersion, "nuxie-sdk-fixtures.v1")
        XCTAssertEqual(
            index.fixtures.map(\.id),
            [
                "animation-event",
                "external-image",
                "font-converter",
                "multi-screen",
                "scripted-resources",
            ]
        )
        XCTAssertTrue(index.fixtures.allSatisfy { !$0.capabilities.isEmpty })

        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let packageURLs = directories
            .map { $0.appendingPathComponent("experience.nux") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        XCTAssertEqual(
            Set(packageURLs.map { $0.deletingLastPathComponent().lastPathComponent }),
            Set(index.fixtures.map(\.id))
        )
        for fixture in index.fixtures {
            let url = root
                .appendingPathComponent(fixture.id, isDirectory: true)
                .appendingPathComponent("experience.nux")
            let package = try NuxPackageReader.read(Data(contentsOf: url))
            XCTAssertEqual(
                package.manifest.identity.experienceId,
                fixture.experienceId,
                url.path
            )
            XCTAssertEqual(package.manifest.identity.appId, "nuxie-sdk-fixture-host")
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

    func testMountedFixtureHostCanBeReleasedSynchronously() throws {
        let root = try Self.fixturesRootURL()
            .appendingPathComponent("animation-event", isDirectory: true)
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nux-package-host-release-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        var viewController: UIViewController? = try ExperienceRuntimeFixtureHost.makeViewController(
            fixtureBaseURL: root,
            cacheRootURL: cacheRoot
        )
        weak var releasedViewController = viewController
        viewController?.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        viewController?.loadViewIfNeeded()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              viewController.flatMap({
                  Self.findSubview(identifier: "nuxie-experience-surface", in: $0.view)
              }) == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertNotNil(viewController.flatMap {
            Self.findSubview(identifier: "nuxie-experience-surface", in: $0.view)
        })
        viewController = nil
        XCTAssertNil(releasedViewController)
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
                atPath: $0.appendingPathComponent("fixture-index.json").path
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

private struct SDKFixtureIndex: Decodable {
    struct Fixture: Decodable {
        let id: String
        let experienceId: String
        let capabilities: [String]
    }

    let schemaVersion: String
    let fixtures: [Fixture]
}
#endif
