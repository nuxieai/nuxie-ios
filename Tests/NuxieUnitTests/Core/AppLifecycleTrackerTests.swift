import Foundation
import XCTest
@testable import Nuxie

/// Tests the automatic lifecycle event logic ($app_installed / $app_updated /
/// $app_opened / $app_backgrounded), formerly AppLifecyclePlugin.
final class AppLifecycleTrackerTests: XCTestCase {

    private final class EventSink: SystemEventSink, @unchecked Sendable {
        private(set) var emitted: [(name: String, properties: [String: Any])] = []

        func emit(_ name: String, properties: [String: Any]?) {
            emitted.append((name, properties ?? [:]))
        }
    }

    private var userDefaults: UserDefaults!
    private var suiteName: String!
    private var eventSink: EventSink!

    override func setUp() {
        super.setUp()
        suiteName = "com.nuxie.test.lifecycle.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        eventSink = EventSink()
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
            eventSink: eventSink
        )
    }

    func testFirstLaunchTracksInstalledAndOpened() {
        makeTracker(version: "1.0.0").trackAppLaunchEvents()

        XCTAssertEqual(eventSink.emitted.map(\.name), ["$app_installed", "$app_opened"])
        XCTAssertEqual(eventSink.emitted[0].properties["install_date"] as? Double, 1_000)
        XCTAssertTrue(userDefaults.bool(forKey: "nuxie_has_launched_before"))
        XCTAssertEqual(userDefaults.string(forKey: "nuxie_last_version"), "1.0.0")
    }

    func testSameVersionRelaunchTracksOnlyOpened() {
        makeTracker(version: "1.0.0").trackAppLaunchEvents()
        eventSink = EventSink()

        makeTracker(version: "1.0.0").trackAppLaunchEvents()

        XCTAssertEqual(eventSink.emitted.map(\.name), ["$app_opened"])
    }

    func testVersionChangeTracksUpdatedAndOpened() {
        makeTracker(version: "1.0.0").trackAppLaunchEvents()
        eventSink = EventSink()

        makeTracker(version: "2.0.0").trackAppLaunchEvents()

        XCTAssertEqual(eventSink.emitted.map(\.name), ["$app_updated", "$app_opened"])
        XCTAssertEqual(eventSink.emitted[0].properties["previous_version"] as? String, "1.0.0")
        XCTAssertEqual(userDefaults.string(forKey: "nuxie_last_version"), "2.0.0")
    }

    func testBackgroundAndForegroundEvents() {
        let tracker = makeTracker(version: "1.0.0")

        tracker.trackAppBackgrounded()
        tracker.trackAppForegrounded()

        XCTAssertEqual(eventSink.emitted.map(\.name), ["$app_backgrounded", "$app_opened"])
        XCTAssertEqual(eventSink.emitted[1].properties["app_version"] as? String, "1.0.0")
    }
}
