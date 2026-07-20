import Foundation
import XCTest
@testable import Nuxie

/// Tests the automatic lifecycle event logic ($app_installed / $app_updated /
/// $app_opened / $app_backgrounded), formerly AppLifecyclePlugin.
final class AppLifecycleTrackerTests: XCTestCase {

    private var userDefaults: UserDefaults!
    private var suiteName: String!
    private var emitted: [(name: String, properties: [String: Any])] = []

    override func setUp() {
        super.setUp()
        suiteName = "com.nuxie.test.lifecycle.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        emitted = []
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeTracker(version: String) -> AppLifecycleTracker {
        AppLifecycleTracker(
            userDefaults: userDefaults,
            appVersionProvider: { version },
            dateProvider: { Date(timeIntervalSince1970: 1_000) },
            emit: { [self] name, properties in emitted.append((name, properties)) }
        )
    }

    func testFirstLaunchTracksInstalledAndOpened() {
        makeTracker(version: "1.0.0").trackAppLaunchEvents()

        XCTAssertEqual(emitted.map(\.name), ["$app_installed", "$app_opened"])
        XCTAssertEqual(emitted[0].properties["install_date"] as? Double, 1_000)
        XCTAssertTrue(userDefaults.bool(forKey: "nuxie_has_launched_before"))
        XCTAssertEqual(userDefaults.string(forKey: "nuxie_last_version"), "1.0.0")
    }

    func testSameVersionRelaunchTracksOnlyOpened() {
        makeTracker(version: "1.0.0").trackAppLaunchEvents()
        emitted = []

        makeTracker(version: "1.0.0").trackAppLaunchEvents()

        XCTAssertEqual(emitted.map(\.name), ["$app_opened"])
    }

    func testVersionChangeTracksUpdatedAndOpened() {
        makeTracker(version: "1.0.0").trackAppLaunchEvents()
        emitted = []

        makeTracker(version: "2.0.0").trackAppLaunchEvents()

        XCTAssertEqual(emitted.map(\.name), ["$app_updated", "$app_opened"])
        XCTAssertEqual(emitted[0].properties["previous_version"] as? String, "1.0.0")
        XCTAssertEqual(userDefaults.string(forKey: "nuxie_last_version"), "2.0.0")
    }

    func testBackgroundAndForegroundEvents() {
        let tracker = makeTracker(version: "1.0.0")

        tracker.trackAppBackgrounded()
        tracker.trackAppForegrounded()

        XCTAssertEqual(emitted.map(\.name), ["$app_backgrounded", "$app_opened"])
        XCTAssertEqual(emitted[1].properties["app_version"] as? String, "1.0.0")
    }
}
