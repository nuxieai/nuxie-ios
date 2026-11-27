import XCTest

/// A page whose picture never comes, shown as a native sheet in the runtime
/// host app, driven by the Nux machine, with no person. The host launches
/// with `--nuxie-machine-gallery --nuxie-machine-files-never-come`;
/// "Open the gallery" starts a record with `opened`, and the machine opens
/// the `views-picture` page as a sheet, which waits for its picture.
///
/// The oracle is the SDK's experience screen, which shows the same views
/// in the same order (`ExperienceShellPresentationChromeTests`): the
/// loading screen at once with no close; after five seconds with nothing
/// in, the recovery screen in its neutral words, with the close; and a
/// close that gives up on the page. The close's fault is the one
/// `nux_machine_host_fault`'s header text gives, read from the host's
/// record line. The sheet going is UIKit's own: the Screen's element goes
/// and the host's button is reachable again. Screenshots are kept.
final class GalleryWaitSheetUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAPageWhosePictureNeverComesShowsRecoveryAndTheCloseTakesTheSheetDown() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--nuxie-machine-gallery", "--nuxie-machine-files-never-come"]
        app.launch()
        let open = app.buttons["nuxie-machine-open-gallery"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), app.debugDescription)
        open.tap()

        // The sheet is up at once, on the loading screen, with no close.
        let screen = app.descendants(matching: .any)["nuxie-machine-screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 30), app.debugDescription)
        let loading = app.descendants(matching: .any)["nuxie-experience-loading-shell"]
        XCTAssertTrue(loading.waitForExistence(timeout: 5), app.debugDescription)
        let shownAt = Date()
        XCTAssertEqual(loading.label, "Experience loading")
        let close = app.buttons["nuxie-experience-close"]
        XCTAssertFalse(close.exists, "the close shows while the page is loading: \(app.debugDescription)")
        keep("1-loading", app)

        // After the delay, the recovery screen and the close.
        let recovery = app.descendants(matching: .any)["nuxie-experience-recovery-shell"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(shownAt), 4,
                                    "the recovery screen showed before the delay")
        XCTAssertTrue(app.staticTexts["Something Went Wrong"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["There was a problem loading this content."].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["nuxie-experience-retry"].exists, app.debugDescription)
        XCTAssertTrue(close.waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertFalse(loading.exists, "the loading screen shows under the recovery screen")
        keep("2-recovery", app)

        // The close takes the sheet down: the app is back on its own screen,
        // and its record ended in the host's fault.
        close.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: screen)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed,
                       "the sheet is still up: \(app.debugDescription)")
        let record = app.staticTexts["nuxie-machine-record"]
        let ended = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Record: fault first_frame.deadline"), object: record)
        XCTAssertEqual(XCTWaiter.wait(for: [ended], timeout: 10), .completed, "the record reads \(record.label)")
        XCTAssertTrue(open.isHittable, "the app's own screen is not back: \(app.debugDescription)")
        keep("3-closed", app)
    }

    /// A screenshot of the app, kept as `name`.
    private func keep(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
