import UIKit
import XCTest

/// Stillwater's paywall as a native sheet in the runtime host app, driven by
/// the Nux machine, with no person. The host launches with
/// `--nuxie-machine-paywall`; "Finish onboarding" starts a record with
/// `onboarding_completed`, and the machine's `present` row opens the
/// paywall as a sheet, drawn from `paywall.nux` and its `plan-card.nux`
/// alone. The host's store answers a purchase with status `failed` after a
/// second and a half, so the paywall is seen while it buys.
///
/// The paywall is found the way a screen reader finds it: each line is a
/// static text and each button a button named by the words beneath it,
/// made from the engine's semantic snapshot, with the words the Screen
/// draws and where it draws them. The plans are a radio group read by its
/// label, "Plan", before its two cards; each card is a radio, read as a
/// button that is selected while its plan is the chosen one. Every tap is a real tap where a button
/// says it is. At each of the story's five frames a screenshot is kept,
/// and what a screen reader reads on the sheet, top to bottom, is kept
/// beside it and printed to the log.
///
/// What the record holds is read from the Screen's accessibility value while
/// the sheet is up (the host's two lines are behind it), and from the host's
/// two lines once the sheet is gone.
///
/// The story is played in light and in dark: the host starts in dark with
/// `--nuxie-machine-appearance dark`, standing in for a phone set to dark,
/// and the paywall follows the phone. What a screen reader reads is the
/// same in both, word for word; only the colors differ, read from the
/// sheet's ground in each screenshot.
///
/// A sheet is filled by its Screen to every edge and told the sheet's own
/// insets, as UIKit gives them: the paywall's ground runs under the home
/// indicator to the sheet's bottom edge, and its content stays clear of it.
/// Each story keeps one still of that, `place-sheet-light` or
/// `place-sheet-dark`, beside what the app says its surface is
/// (`place-sheet-<scheme>-surface`). The same holds with the phone on its
/// side, opened there or turned while the sheet is open, and for a sheet the
/// test host turns to UIKit's medium detent, which is kept as a record of
/// what UIKit gives. With `--nuxie-machine-paywall-cover` the host presents
/// the same paywall as a cover, which is told the screen's insets and fills
/// the screen.
///
/// Every place check reads UIKit's own values (the screen's insets, the
/// frames, the view's insets), so the tests hold on any iPhone, one with a
/// home button among them, where the bottom inset is 0. Where Stillwater's
/// page is taller than what it is presented in, its content runs past the
/// bottom edge: the footer and the bottom edge's ground are then noted, not
/// checked ([`expectFooter`]).
final class StillwaterPaywallSheetUITests: XCTestCase {
    private static let errorLine = "The purchase did not go through. Try again in a moment."
    private static let termsLine = "Billed through the store after the trial. Cancel any time."

    /// What a screen reader reads on the sheet at each of the story's five
    /// frames, in light and in dark alike.
    private static let readings: [String: [String]] = {
        let open = [
            "text \"Ten quiet minutes,\nevery day.\"",
            "group \"Plan\"",
            "button \"Yearly $59.99\", selected",
            "button \"Monthly $9.99\"",
            "button \"Continue\"",
            "button \"Not now\"",
            "button \"Restore purchases\"",
            "button \"About the trial\"",
        ]
        var monthly = open
        monthly[2] = "button \"Yearly $59.99\""
        monthly[3] = "button \"Monthly $9.99\", selected"
        var buying = monthly
        buying[4] = "button \"Continue\", not enabled"
        var failed = monthly
        failed.insert("text \"\(StillwaterPaywallSheetUITests.errorLine)\"", at: 5)
        return [
            "1-open": open,
            "2-monthly-chosen": monthly,
            "3-buying": buying,
            "4-failed": failed,
            "5-details-open": failed + ["text \"\(StillwaterPaywallSheetUITests.termsLine)\""],
        ]
    }()

    /// The sheet's ground, Stillwater's `night`: #f6f8f7 in light and
    /// #0d1214 in dark.
    private enum Ground: String {
        case light, dark
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testThePaywallStoryInFiveFrames() throws {
        try playTheStory(in: .light)
    }

    func testThePaywallStoryInFiveFramesInDark() throws {
        try playTheStory(in: .dark)
    }

    /// The paywall follows the phone while it is open: the phone turns dark
    /// and the open sheet is drawn again in dark, then light again, with
    /// the same reading throughout.
    ///
    /// The phone is turned the way the story's dark start stands in for it,
    /// on the host's window, by a Darwin notification the host listens for.
    /// `XCUIDevice.shared.appearance` was tried first: on the iOS 27.0
    /// simulator it did not reach the running app at all (twelve seconds
    /// after it, UIKit's own status bar and the host behind the sheet were
    /// still light).
    func testTheOpenPaywallFollowsThePhone() throws {
        let app = launch(.light)
        let screen = try openPaywall(app)
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 15), app.debugDescription)
        waitFor(app, screen, ground: .light, "the paywall opened on a light phone is not light")
        keep("switch-1-light", app, screen, expecting: "1-open")

        turnThePhone(.dark)
        waitFor(app, screen, ground: .dark, "the open paywall did not turn dark with the phone")
        keep("switch-2-dark", app, screen, expecting: "1-open")

        turnThePhone(.light)
        waitFor(app, screen, ground: .light, "the open paywall did not turn light again with the phone")
        keep("switch-3-light-again", app, screen, expecting: "1-open")
    }

    /// Post the Darwin notification the host turns its window with.
    private func turnThePhone(_ appearance: Ground) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("dev.nuxie.machine.appearance.\(appearance.rawValue)" as CFString), nil, nil, true)
    }

    private func playTheStory(in appearance: Ground) throws {
        let app = launch(appearance)
        let screen = try openPaywall(app)

        // 1. Open: the headline, both plans with their prices, and the
        // buttons, read top to bottom; nothing under an `if` is read.
        let title = text(app, beginningWith: "Ten quiet minutes,")
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        let yearly = button(app, beginningWith: "Yearly")
        let monthly = button(app, beginningWith: "Monthly")
        let buy = app.buttons["Continue"]
        let notNow = app.buttons["Not now"]
        let restore = app.buttons["Restore purchases"]
        let details = app.buttons["About the trial"]

        // The sheet's place, checked before what the page reads, so a phone
        // the page does not fit still checks it. Everything is kept before
        // anything is checked: the still, `place-sheet-<scheme>`, and what
        // the app says its surface is. Each place is told once.
        waitFor(app, screen, ground: appearance, "the paywall does not open in \(appearance)")
        let placed = "place-sheet-\(appearance.rawValue)"
        let shot = app.screenshot()
        keep(placed, app, screen, shot: shot)
        let facts = try surface(app, kept: placed + "-surface")
        try expectSheetPlace(app, screen, facts, shot: shot, appearance, kept: placed)
        try expectToldOnce(app, endingWith: facts, kept: placed)

        for element in [yearly, monthly, buy, notNow, restore, details] {
            XCTAssertTrue(element.exists, "\(element) is not read: \(app.debugDescription)")
            XCTAssertTrue(element.isEnabled, "\(element) is not enabled")
        }
        XCTAssertTrue(yearly.label.contains("$59.99"), yearly.label)
        XCTAssertTrue(monthly.label.contains("$9.99"), monthly.label)
        XCTAssertTrue(yearly.isSelected, "the chosen plan, yearly, is not read as selected")
        XCTAssertFalse(monthly.isSelected, "monthly is read as selected while yearly is chosen")
        let opened = reading(app, on: screen.frame)
        let group = try XCTUnwrap(opened.firstIndex(of: "group \"Plan\""), "the plans' group is not read: \(opened)")
        let first = try XCTUnwrap(opened.firstIndex { $0.hasPrefix("button \"Yearly") }, "\(opened)")
        XCTAssertLessThan(group, first, "the group's label is read before its cards: \(opened)")
        XCTAssertFalse(app.staticTexts[Self.errorLine].exists, "the error line is read")
        XCTAssertFalse(app.staticTexts[Self.termsLine].exists, "the terms line is read")
        XCTAssertFalse(app.staticTexts["Continue"].exists, "a button's words are read twice")
        XCTAssertLessThan(title.frame.minY, yearly.frame.minY)
        XCTAssertLessThan(yearly.frame.minY, monthly.frame.minY)
        XCTAssertLessThan(monthly.frame.minY, buy.frame.minY)
        XCTAssertLessThan(buy.frame.minY, notNow.frame.minY)
        waitFor(app, screen, ground: appearance, "the paywall does not open in \(appearance)")
        keep("1-open", app, screen, expecting: "1-open")

        // 2. Monthly chosen: the record's plan is monthly, and the selected
        // card moves from yearly to monthly.
        monthly.tap()
        waitFor(screen, valueContaining: "Selected plan: monthly.")
        waitFor(monthly, "selected == true", "monthly is not read as selected after its tap")
        XCTAssertFalse(yearly.isSelected, "yearly is still read as selected after monthly was tapped")
        XCTAssertEqual(ground(app, screen), appearance, "the paywall left \(appearance) when monthly was chosen")
        keep("2-monthly-chosen", app, screen, expecting: "2-monthly-chosen")

        // 3. Buying: one purchase is under way, and the buy button is read
        // as not enabled until the store answers.
        buy.tap()
        waitFor(buy, "enabled == false", "the buy button stayed enabled while it bought")
        keep("3-buying", app, screen, expecting: "3-buying")

        // 4. Failed: the purchase's status is `failed`; the error line is read
        // under the button, which is enabled again.
        XCTAssertTrue(app.staticTexts[Self.errorLine].waitForExistence(timeout: 10), app.debugDescription)
        waitFor(buy, "enabled == true", "the buy button stayed disabled after the answer")
        XCTAssertLessThan(buy.frame.minY, app.staticTexts[Self.errorLine].frame.minY)
        XCTAssertTrue(monthly.isSelected, "monthly is no longer read as selected after the purchase failed")
        XCTAssertFalse(yearly.isSelected)
        keep("4-failed", app, screen, expecting: "4-failed")

        // 5. Details open: "About the trial" shows the terms line.
        details.tap()
        XCTAssertTrue(app.staticTexts[Self.termsLine].waitForExistence(timeout: 10), app.debugDescription)
        keep("5-details-open", app, screen, expecting: "5-details-open")

        // "Not now": Stillwater's `close` marks the evening offer due and
        // dismisses. The sheet goes, nothing is presented, and the record
        // stays open with its wake moment.
        notNow.tap()
        waitUntilGone(screen)
        waitFor(app.staticTexts["nuxie-machine-record"], labelContaining: "Record: open, wakes at ")
        XCTAssertEqual(app.staticTexts["nuxie-machine-plan"].label, "Selected plan: monthly")
        keep("6-after-not-now", app, nil)
    }

    /// The paywall as a cover fills the screen, under the status bar and the
    /// home indicator, and its page keeps its content clear of them by the
    /// insets UIKit gives the screen: read from the host's
    /// `nuxie-machine-safe-area`, never from the place the SDK told.
    ///
    /// Upright: the Screen's frame is the screen's; the headline is below
    /// the top inset; the footer's links end the page's own spacing (the
    /// terms' box and the bottom padding) above the bottom inset. Turned on its side: the
    /// frame is the turned screen's, and the headline moved up by exactly
    /// what the top inset lost. Kept as `place-cover-portrait-light`,
    /// `place-cover-portrait-dark` (the phone turned dark while the cover is
    /// open) and `place-cover-landscape-light`, beside what the app says
    /// its surface is and last drew (`place-cover-*-surface`). The turned
    /// still is the Screen element's own raw bitmap, kept untagged: the
    /// simulator's whole-screen and app captures do not follow the turn.
    func testThePaywallAsACoverFillsTheScreen() throws {
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let app = launch(.light, asCover: true)
        let screen = try openPaywall(app)
        let title = text(app, beginningWith: "Ten quiet minutes,")
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)

        let upright = try settledInsets(app, screen, title)
        XCTAssertEqual(screen.frame, app.frame, "the cover's Screen is not the screen's frame")
        XCTAssertGreaterThan(upright.top, 0, "UIKit gives the upright screen no top inset")
        XCTAssertGreaterThan(title.frame.minY, upright.top, "the headline is under the status bar")
        expectSides(button(app, beginningWith: "Yearly"), in: app.frame, inside: upright, "upright")
        // Below the links: the terms' box, the page's own bottom padding,
        // then the home indicator's inset (none with a home button), when
        // the page fits the screen.
        _ = expectFooter(app, in: app.frame, told: upright, kept: "place-cover-portrait")
        XCTAssertEqual(coverGround(app, below: upright), .light, "the cover does not open light")
        let uprightShot = app.screenshot()
        expectPageGround(.light, in: uprightShot, across: app.frame.size, below: upright, "the upright cover")
        let uprightTitle = title.frame.minY
        keep("place-cover-portrait-light", app, screen, expecting: "1-open", shot: uprightShot)
        expect(try surface(app, kept: "place-cover-portrait-surface"), coversA: app.frame.size, "the upright cover")

        turnThePhone(.dark)
        waitFor(ground: .dark, app, below: upright, "the open cover did not turn dark with the phone")
        keep("place-cover-portrait-dark", app, screen, expecting: "1-open")
        turnThePhone(.light)
        waitFor(ground: .light, app, below: upright, "the open cover did not turn light again")

        let drawnUpright = try framesDrawn(screen)
        XCUIDevice.shared.orientation = .landscapeLeft
        let turned = try settledInsets(app, screen, title, until: { _ in app.frame.width > app.frame.height })
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "the app did not turn")
        try waitUntilResting(screen, drawnSince: drawnUpright)

        // Everything is kept before anything is checked: what the app says
        // its surface is and drew, and the Screen's own screenshot. On the
        // simulator the whole screen's and the app's captures do not follow
        // the turn (read upright they are portrait, the page cut to a square
        // beside black). The Screen element's raw bitmap is the device's
        // own portrait buffer, holding the whole turned page a quarter turn
        // clockwise. It is turned back from the orientation this test set,
        // never from the image's orientation tag, and kept untagged.
        let raw = try XCTUnwrap(screen.screenshot().image.cgImage, "the Screen's screenshot has no bitmap")
        let still = try XCTUnwrap(uprightLandscape(raw), "the Screen's bitmap could not be turned")
        let facts = try surface(app, kept: "place-cover-landscape-surface")
        keep("place-cover-landscape-light", still, app, screen)

        // The app's own account first: a surface the turned screen's size,
        // a drawable that size at the screen's scale, and the last frame
        // drawn at it. Wrong here is the app; right here and wrong below is
        // the screenshot.
        expect(facts, coversA: app.frame.size, "the turned cover")
        XCTAssertEqual(screen.frame, app.frame, "the turned cover's Screen is not the turned screen's frame")
        XCTAssertGreaterThanOrEqual(title.frame.minY, turned.top, "the turned headline is under the status bar")
        XCTAssertEqual(uprightTitle - title.frame.minY, upright.top - turned.top, accuracy: 1,
                       "the headline did not move by what the top inset lost")
        expectSides(button(app, beginningWith: "Yearly"), in: app.frame, inside: turned, "turned")
        // The raw buffer is the device's, upright for the phone held upright:
        // the turned screen's size with width and height swapped.
        let pixels = CGSize(width: app.frame.width * facts.scale, height: app.frame.height * facts.scale)
        XCTAssertEqual(CGFloat(raw.width), pixels.height, accuracy: 1, "the raw bitmap is \(raw.width) wide")
        XCTAssertEqual(CGFloat(raw.height), pixels.width, accuracy: 1, "the raw bitmap is \(raw.height) tall")
        XCTAssertEqual(CGFloat(still.width), pixels.width, accuracy: 1, "the turned still is \(still.width) wide")
        XCTAssertEqual(CGFloat(still.height), pixels.height, accuracy: 1,
                       "the turned still is \(still.height) tall")
        expectPageGround(.light, in: still, scale: facts.scale, across: app.frame.size, below: turned,
                         "the turned still")
    }

    /// The paywall opened as a sheet with the phone on its side
    /// (`.landscapeLeft`). On an iPhone, in compact height, UIKit presents a
    /// page sheet full screen (its `prefersEdgeAttachedInCompactHeight` is
    /// false): the sheet is the screen's frame, and its insets are the
    /// screen's, the sides' among them. The test notes which UIKit did and
    /// checks either way from what UIKit gives: the surface fills the sheet,
    /// it is told its view's insets and how far the screen's safe area
    /// reaches into its frame, its content sits each side inset plus 24 in,
    /// each place is told once, and the page's ground reaches every edge
    /// with room below the content. The page is taller than a phone on its
    /// side, so its content runs past the bottom edge.
    ///
    /// The still is the Screen element's own bitmap, turned the right way up
    /// from the orientation this test set: on the simulator the whole
    /// screen's capture does not follow a turn. Kept as
    /// `place-sheet-landscape-light`, then, with the phone turned dark,
    /// `place-sheet-landscape-dark`.
    func testThePaywallSheetOpenedOnItsSide() throws {
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch(.light)
        let screen = try openPaywall(app)
        XCTAssertTrue(text(app, beginningWith: "Ten quiet minutes,").waitForExistence(timeout: 15),
                      app.debugDescription)
        let sheet = try settled(app, screen, "the sheet on its side") { app.frame.width > app.frame.height }
        let facts = try expectLandscapeSheet(app, screen, sheet, .light, kept: "place-sheet-landscape-light")
        try expectToldOnce(app, endingWith: facts, kept: "place-sheet-landscape-light")

        turnThePhone(.dark)
        try waitForLandscape(ground: .dark, app, screen, sheet, "the sheet on its side did not turn dark")
        try expectLandscapeSheet(app, screen, sheet, .dark, kept: "place-sheet-landscape-dark")
    }

    /// The open sheet follows the phone as it turns, upright to its side and
    /// back. At each, it is checked as when it opened there, from what UIKit
    /// gives ([`expectSheetPlace`], [`expectLandscapeSheet`]); each turn
    /// tells a new place, no place is told twice running, and turned back
    /// the sheet has its upright frame and is told its upright place again.
    /// Kept as `place-sheet-turn-1-upright`, `place-sheet-turn-2-landscape`
    /// and `place-sheet-turn-3-upright-again`.
    func testTheOpenSheetTurnsWithThePhone() throws {
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let app = launch(.light)
        let screen = try openPaywall(app)
        XCTAssertTrue(text(app, beginningWith: "Ten quiet minutes,").waitForExistence(timeout: 15),
                      app.debugDescription)

        let upright = try settled(app, screen, "the upright sheet") { app.frame.height > app.frame.width }
        let uprightShot = app.screenshot()
        keep("place-sheet-turn-1-upright", app, screen, shot: uprightShot)
        let uprightFacts = try surface(app, kept: "place-sheet-turn-1-upright-surface")
        try expectSheetPlace(app, screen, uprightFacts, shot: uprightShot, .light, kept: "place-sheet-turn-1-upright")
        let first = try expectToldOnce(app, endingWith: uprightFacts, kept: "place-sheet-turn-1-upright")

        let drawnUpright = try framesDrawn(screen)
        XCUIDevice.shared.orientation = .landscapeLeft
        let turned = try settled(app, screen, "the turned sheet") { app.frame.width > app.frame.height }
        try waitUntilResting(screen, drawnSince: drawnUpright)
        let turnedFacts = try expectLandscapeSheet(app, screen, turned, .light, kept: "place-sheet-turn-2-landscape")
        let second = try expectToldOnce(app, endingWith: turnedFacts, kept: "place-sheet-turn-2-landscape")
        XCTAssertGreaterThan(second.count, first.count, "turning the phone told the sheet no new place")

        let drawnTurned = try framesDrawn(screen)
        XCUIDevice.shared.orientation = .portrait
        let back = try settled(app, screen, "the sheet turned back") { app.frame.height > app.frame.width }
        try waitUntilResting(screen, drawnSince: drawnTurned)
        let backShot = app.screenshot()
        keep("place-sheet-turn-3-upright-again", app, screen, shot: backShot)
        let backFacts = try surface(app, kept: "place-sheet-turn-3-upright-again-surface")
        try expectSheetPlace(app, screen, backFacts, shot: backShot, .light, kept: "place-sheet-turn-3-upright-again")
        let third = try expectToldOnce(app, endingWith: backFacts, kept: "place-sheet-turn-3-upright-again")
        XCTAssertGreaterThan(third.count, second.count, "turning the phone back told the sheet no new place")
        XCTAssertEqual(back, upright, "turned back, the sheet's frame is not its upright one")
        XCTAssertEqual(backFacts.placeNumbers, uprightFacts.placeNumbers,
                       "turned back, the sheet is not told its upright place")
    }

    /// A sheet at UIKit's medium detent, recorded as UIKit gives it. The SDK
    /// presents a sheet at the large detent; the test host alone turns this
    /// one to medium once it is up (`--nuxie-machine-sheet-detent medium`).
    ///
    /// Checked, as the rule holds for any sheet: the surface fills the
    /// sheet's view, it is told the insets UIKit gives that view, and each
    /// place is told once. Kept, not checked, as the note
    /// `place-sheet-medium-record`: the screen's and the sheet's frames,
    /// whether the sheet reaches the screen's bottom edge or floats above
    /// it, the screen's insets, how far they reach into the sheet's frame
    /// and whether the view's insets are that, the place told, and the
    /// colors at the sheet's bottom edge and below it. The still is
    /// `place-sheet-medium-light`. The page is taller than a medium sheet,
    /// so its content runs past the sheet's bottom edge.
    func testAMediumSheetIsRecordedAsUIKitGivesIt() throws {
        let app = launch(.light, mediumSheet: true)
        let screen = try openPaywall(app, large: false)
        let sheet = try settled(app, screen, "the medium sheet") { screen.frame.minY > app.frame.height / 3 }
        let shot = app.screenshot()
        keep("place-sheet-medium-light", app, screen, shot: shot)
        let facts = try surface(app, kept: "place-sheet-medium-light-surface")
        let place = try expectPlace(facts, of: sheet, in: app, reaching: false, "the medium sheet")
        let told = try expectToldOnce(app, endingWith: facts, kept: "place-sheet-medium-light")

        let picture = upright(shot.image)
        let scale = shot.image.scale
        func color(_ point: CGPoint) -> String {
            picture.flatMap { pixel(in: $0, scale: scale, at: point) }.map { "\($0)" } ?? "none"
        }
        func edges(_ insets: UIEdgeInsets) -> String {
            "top \(insets.top) right \(insets.right) bottom \(insets.bottom) left \(insets.left)"
        }
        let gap = app.frame.maxY - sheet.maxY
        let reaches = abs(gap) < 0.5
        var lines = [
            "screen \(app.frame)",
            "sheet \(sheet)",
            reaches ? "the sheet reaches the screen's bottom edge" : "the sheet floats \(gap) above the screen's bottom edge",
            "screen insets: \(edges(place.screen))",
            "view insets: \(edges(place.view))",
            "told insets: \(edges(place.told))",
            "the screen's safe area reaches into the sheet's frame by: \(edges(place.reached))",
            "the view's insets are that reach: \(Self.same(edges: place.view, place.reached) ? "yes" : "no")",
            "place told: \(facts.placeNumbers.map { "\($0)" } ?? "none")",
            "places told in order: \(told)",
            "ground mid-page at \(sheet.minX + place.told.left + 12), \(sheet.midY): \(color(CGPoint(x: sheet.minX + place.told.left + 12, y: sheet.midY)))",
        ]
        for along in [CGFloat(0.25), 0.75] {
            let x = sheet.minX + sheet.width * along
            lines.append("3 above the sheet's bottom at \(x): \(color(CGPoint(x: x, y: sheet.maxY - 3)))")
            if !reaches {
                lines.append("below the sheet at \(x): \(color(CGPoint(x: x, y: sheet.maxY + gap / 2)))")
            }
        }
        note(lines.joined(separator: "\n"), kept: "place-sheet-medium-record")
    }

    private static func same(edges one: UIEdgeInsets, _ other: UIEdgeInsets) -> Bool {
        [one.top - other.top, one.right - other.right, one.bottom - other.bottom, one.left - other.left]
            .allSatisfy { abs($0) < 0.5 }
    }

    func testASwipeDownEndsTheRecord() throws {
        let app = launch()
        let screen = try openPaywall(app)
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 15), app.debugDescription)

        // A swipe down has no action behind it: the machine hears `closed`,
        // and the record ends.
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: screen.frame.midX, dy: screen.frame.minY + 12))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.1, thenDragTo: end)
        waitUntilGone(screen)
        waitFor(app.staticTexts["nuxie-machine-record"], labelContaining: "Record: ended")
        keep("1-after-swipe", app, nil)
    }

    func testASwipeThePersonLetsGoOfKeepsTheSheet() throws {
        let app = launch()
        let screen = try openPaywall(app)
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 15), app.debugDescription)
        let resting = screen.frame

        // A short, slow pull that the person lets go of: UIKit cancels the
        // dismissal and the sheet settles back. The machine hears nothing.
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: resting.midX, dy: resting.minY + 12))
        let short = start.withOffset(CGVector(dx: 0, dy: 90))
        start.press(forDuration: 0.1, thenDragTo: short, withVelocity: .slow, thenHoldForDuration: 0.4)
        let deadline = Date().addingTimeInterval(10)
        while screen.exists, screen.frame != resting, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(screen.exists, "the swipe took the sheet")
        XCTAssertEqual(screen.frame, resting, "the sheet did not settle back")
        waitFor(screen, valueContaining: "Record: open.")
        XCTAssertTrue(app.buttons["Continue"].exists, app.debugDescription)
        keep("1-after-cancelled-swipe", app, screen)

        // The machine's own dismissal still takes the sheet.
        app.buttons["Not now"].tap()
        waitUntilGone(screen)
        waitFor(app.staticTexts["nuxie-machine-record"], labelContaining: "Record: open, wakes at ")
    }

    // MARK: Driving the host

    /// The host, on the phone as it is, or started in `appearance`; with
    /// `asCover`, presenting the paywall as a cover; with `mediumSheet`,
    /// turning the presented sheet to the medium detent once it is up.
    private func launch(_ appearance: Ground? = nil, asCover: Bool = false,
                        mediumSheet: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--nuxie-machine-paywall"]
        if asCover {
            app.launchArguments += ["--nuxie-machine-paywall-cover"]
        }
        if mediumSheet {
            app.launchArguments += ["--nuxie-machine-sheet-detent", "medium"]
        }
        if let appearance {
            app.launchArguments += ["--nuxie-machine-appearance", appearance.rawValue]
        }
        app.launch()
        return app
    }

    /// Tap "Finish onboarding" and wait for the sheet: its Screen drawn and
    /// its frame settled, at the large detent unless `large` is false.
    private func openPaywall(_ app: XCUIApplication, large: Bool = true) throws -> XCUIElement {
        let finish = app.buttons["nuxie-machine-finish-onboarding"]
        XCTAssertTrue(finish.waitForExistence(timeout: 20), app.debugDescription)
        finish.tap()
        let screen = app.descendants(matching: .any)["nuxie-machine-screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 30), app.debugDescription)
        waitFor(screen, valueContaining: "Record: open")
        var last = screen.frame
        let deadline = Date().addingTimeInterval(10)
        repeat {
            Thread.sleep(forTimeInterval: 0.4)
            let now = screen.frame
            if now == last { break }
            last = now
        } while Date() < deadline
        if large {
            XCTAssertLessThan(last.minY, app.frame.height / 4, "the sheet is at its large detent")
        }
        return screen
    }

    private func button(_ app: XCUIApplication, beginningWith words: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
    }

    private func text(_ app: XCUIApplication, beginningWith words: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
    }

    private func waitFor(_ element: XCUIElement, _ format: String, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, message)
    }

    private func waitFor(_ element: XCUIElement, valueContaining text: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed,
                       "expected \(text) in \(String(describing: element.value))")
    }

    private func waitFor(_ element: XCUIElement, labelContaining text: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed,
                       "expected \(text) in \(element.label)")
    }

    /// Wait until the sheet's ground is `expected`: the Screen draws the
    /// frame the new colors land in after the trait change reaches it.
    private func waitFor(_ app: XCUIApplication, _ screen: XCUIElement, ground expected: Ground,
                         _ message: String) {
        let deadline = Date().addingTimeInterval(10)
        var seen = ground(app, screen)
        while seen != expected, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            seen = ground(app, screen)
        }
        guard seen != expected else { return }
        // What UIKit drew above the sheet says whether the app heard the
        // phone at all: the host behind the sheet follows it on its own.
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "not-\(expected.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let above = ground(in: shot, at: CGPoint(x: screen.frame.midX, y: max(2, screen.frame.minY / 2)),
                           lightAtLeast: 150)
        XCTAssertEqual(seen, expected,
                       "\(message); above the sheet UIKit drew \(above.map(\.rawValue) ?? "neither")")
    }

    /// Light or dark, as the sheet's ground reads in a screenshot: a point
    /// in the paywall's top padding, inside the sheet's rounded corner.
    /// Neither when it is neither (the sheet is not drawn there yet).
    private func ground(_ app: XCUIApplication, _ screen: XCUIElement) -> Ground? {
        ground(in: app.screenshot(), at: CGPoint(x: screen.frame.minX + 12, y: screen.frame.minY + 30))
    }

    /// UIKit's safe-area insets for the screen, as the host shows them,
    /// once they satisfy `until` and the cover has settled: its Screen at
    /// the screen's frame and the headline in the same place twice running.
    private func settledInsets(_ app: XCUIApplication, _ screen: XCUIElement, _ title: XCUIElement,
                               until done: (UIEdgeInsets) -> Bool = { _ in true }) throws -> UIEdgeInsets {
        let shown = app.descendants(matching: .any)["nuxie-machine-safe-area"]
        XCTAssertTrue(shown.waitForExistence(timeout: 10),
                      "the host does not show the safe area: \(app.debugDescription)")
        let deadline = Date().addingTimeInterval(15)
        var insets = UIEdgeInsets.zero
        var last = CGRect.null
        while Date() < deadline {
            let words = shown.label.split(separator: " ").compactMap { Double($0) }
            if words.count == 4 {
                insets = UIEdgeInsets(top: words[0], left: words[3], bottom: words[2], right: words[1])
                let now = title.frame
                if done(insets), screen.frame == app.frame, now == last { return insets }
                last = now
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTFail("the cover did not settle: insets \(shown.label), Screen \(screen.frame), app \(app.frame)")
        return insets
    }

    /// Light or dark, as the cover's ground reads in a screenshot: a point
    /// in the page's top padding, just below the top inset and clear of the
    /// status bar.
    private func coverGround(_ app: XCUIApplication, below insets: UIEdgeInsets) -> Ground? {
        ground(in: app.screenshot(), at: CGPoint(x: insets.left + 12, y: insets.top + 30))
    }

    private func waitFor(ground expected: Ground, _ app: XCUIApplication, below insets: UIEdgeInsets,
                         _ message: String) {
        let deadline = Date().addingTimeInterval(10)
        var seen = coverGround(app, below: insets)
        while seen != expected, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            seen = coverGround(app, below: insets)
        }
        XCTAssertEqual(seen, expected, message)
    }

    /// The Screen's count of frames drawn, from its accessibility value.
    private func framesDrawn(_ screen: XCUIElement) throws -> Int {
        let value = String(describing: screen.value ?? "")
        let marker = "Frames drawn: "
        let start = try XCTUnwrap(value.range(of: marker), "no frame count in \(value)").upperBound
        let digits = value[start...].prefix { $0.isNumber }
        return try XCTUnwrap(Int(digits), "no frame count in \(value)")
    }

    /// Wait until the Screen has drawn since `before` and then drawn
    /// nothing more for a moment: the turn is over and its frame is up.
    private func waitUntilResting(_ screen: XCUIElement, drawnSince before: Int) throws {
        let deadline = Date().addingTimeInterval(15)
        var last = -1
        while Date() < deadline {
            let drawn = try framesDrawn(screen)
            if drawn > before, drawn == last { return }
            last = drawn
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTFail("the Screen did not draw and rest after the turn: \(String(describing: screen.value))")
    }

    /// The presented Screen's surface as the app reads it now, from the
    /// host's `nuxie-machine-surface`, or none before it shows one.
    private func surfaceNow(_ app: XCUIApplication) -> (SurfaceFacts, String)? {
        let shown = app.descendants(matching: .any)["nuxie-machine-surface"]
        guard shown.exists else { return nil }
        let text = shown.label
        return SurfaceFacts(text.split(separator: " ").compactMap { Double($0) }).map { ($0, text) }
    }

    /// The presented Screen's surface as the app reads it, from the host's
    /// `nuxie-machine-surface`, kept as the text attachment `name`.
    private func surface(_ app: XCUIApplication, kept name: String) throws -> SurfaceFacts {
        let shown = app.descendants(matching: .any)["nuxie-machine-surface"]
        XCTAssertTrue(shown.waitForExistence(timeout: 10), "the host does not show the surface")
        // Read twice, a moment apart, so the label is the latest frame's.
        Thread.sleep(forTimeInterval: 0.6)
        let text = shown.label
        note(text, kept: name)
        let numbers = text.split(separator: " ").compactMap { Double($0) }
        let facts = try XCTUnwrap(SurfaceFacts(numbers), "the surface reads \(text)")
        return facts
    }

    /// `text` kept as the text attachment `name`.
    private func note(_ text: String, kept name: String) {
        let kept = XCTAttachment(string: text)
        kept.name = name
        kept.lifetime = .keepAlways
        add(kept)
    }

    /// A Screen's surface as the app reads it, in points and pixels; the
    /// insets UIKit gives the Screen's view; and the place the session is
    /// told, its insets and size (none before it has one).
    private struct SurfaceFacts {
        let bounds: CGSize
        let drawable: CGSize
        let scale: CGFloat
        let drawn: CGSize
        let viewInsets: UIEdgeInsets
        let placeInsets: UIEdgeInsets?
        let placeSize: CGSize?
        /// The place as the host writes it, `T R B L W H`.
        let placeNumbers: [Double]?

        init?(_ numbers: [Double]) {
            guard numbers.count == 11 || numbers.count == 17 else { return nil }
            bounds = CGSize(width: numbers[0], height: numbers[1])
            drawable = CGSize(width: numbers[2], height: numbers[3])
            scale = numbers[4]
            drawn = CGSize(width: numbers[5], height: numbers[6])
            viewInsets = UIEdgeInsets(top: numbers[7], left: numbers[10], bottom: numbers[9], right: numbers[8])
            guard numbers.count == 17 else {
                placeInsets = nil
                placeSize = nil
                placeNumbers = nil
                return
            }
            placeInsets = UIEdgeInsets(top: numbers[11], left: numbers[14], bottom: numbers[13], right: numbers[12])
            placeSize = CGSize(width: numbers[15], height: numbers[16])
            placeNumbers = Array(numbers[11...])
        }
    }

    /// A presentation's place as UIKit gives it: the insets it is told, the
    /// insets UIKit gives its view, the screen's insets, and how far the
    /// screen's safe area reaches into its frame.
    private struct Place {
        let told: UIEdgeInsets
        let view: UIEdgeInsets
        let screen: UIEdgeInsets
        let reached: UIEdgeInsets
    }

    /// How far a screen `screen` big with insets `insets` reaches into
    /// `frame`, as UIKit works out a view's safe area: on each edge, the
    /// screen's inset less the distance from that edge of the screen to the
    /// frame's, and none below 0.
    private static func reached(by insets: UIEdgeInsets, of screen: CGRect, into frame: CGRect) -> UIEdgeInsets {
        UIEdgeInsets(
            top: max(0, insets.top - (frame.minY - screen.minY)),
            left: max(0, insets.left - (frame.minX - screen.minX)),
            bottom: max(0, insets.bottom - (screen.maxY - frame.maxY)),
            right: max(0, insets.right - (screen.maxX - frame.maxX)))
    }

    /// The place of the Screen presented in `frame`, checked against what
    /// UIKit gives, never a number of the test's own: its surface fills
    /// `frame` (bounds that size, the drawable that size at its scale, the
    /// last frame drawn at it); the place's size is the surface's; the told
    /// insets are the ones UIKit gives the Screen's view; and, with
    /// `reaching`, they are how far the screen's safe area (the host's
    /// `nuxie-machine-safe-area`) reaches into `frame`.
    @discardableResult
    private func expectPlace(_ facts: SurfaceFacts, of frame: CGRect, in app: XCUIApplication,
                             reaching: Bool = true, _ what: String) throws -> Place {
        expect(facts, coversA: frame.size, what)
        let told = try XCTUnwrap(facts.placeInsets, "\(what): the Screen has no place")
        let size = try XCTUnwrap(facts.placeSize)
        XCTAssertEqual(size.width, facts.bounds.width, accuracy: 0.5, "\(what): the place is \(size) wide")
        XCTAssertEqual(size.height, facts.bounds.height, accuracy: 0.5, "\(what): the place is \(size) tall")
        let screen = try insets(app)
        let place = Place(told: told, view: facts.viewInsets, screen: screen,
                          reached: Self.reached(by: screen, of: app.frame, into: frame))
        for (edge, got, view, want) in [
            ("top", told.top, place.view.top, place.reached.top),
            ("right", told.right, place.view.right, place.reached.right),
            ("bottom", told.bottom, place.view.bottom, place.reached.bottom),
            ("left", told.left, place.view.left, place.reached.left),
        ] {
            XCTAssertEqual(got, view, accuracy: 0.5,
                           "\(what) is told a \(edge) inset of \(got), not its view's \(view)")
            if reaching {
                XCTAssertEqual(got, want, accuracy: 0.5,
                               "\(what) is told a \(edge) inset of \(got), not the \(want) the screen's "
                                   + "\(screen) reaches into its frame \(frame)")
            }
        }
        return place
    }

    /// Stillwater's page, all of it: its top padding (64), the mark and the
    /// headline's margin (40 and 28), the headline's two lines (76), the
    /// plans' margin and the two plans with the gap between (40, 72, 12,
    /// 72), the buy button and its margin (28 and 56), the error line's box
    /// (52), the footer ("Not now" 48, the links 4 and 44, the terms' box 8
    /// and 40), and its bottom padding (34). Its insets come on top.
    private static let pageHeight: CGFloat = 718

    /// Whether Stillwater's page fits what it is presented in, `frame`, told
    /// `told`. When it fits, its content keeps clear of the home indicator:
    /// below the links ("Restore purchases"), the terms' box (8 and 40) and
    /// the page's own bottom padding (34), then the told bottom inset. When
    /// it does not (a short screen, a phone on its side, a medium sheet),
    /// its content runs past the bottom edge, which is kept as the note
    /// `name-fit` and not checked.
    private func expectFooter(_ app: XCUIApplication, in frame: CGRect, told: UIEdgeInsets,
                              kept name: String) -> Bool {
        let needed = told.top + told.bottom + Self.pageHeight
        let restore = app.buttons["Restore purchases"]
        guard frame.height + 0.5 >= needed else {
            note("The page needs \(needed) points and has \(frame.height): its content runs past the bottom edge. "
                     + "The links end at \(restore.exists ? "\(restore.frame.maxY)" : "nothing read") "
                     + "in a frame ending at \(frame.maxY).", kept: name + "-fit")
            return false
        }
        XCTAssertTrue(restore.exists, "\(name): the footer's links are not read")
        XCTAssertEqual(frame.maxY - told.bottom - restore.frame.maxY, 82, accuracy: 1,
                       "\(name): the footer does not end the page's padding above the home indicator")
        return true
    }

    /// A large sheet's place, checked against what UIKit gives
    /// ([`expectPlace`]): the surface fills the sheet and is told its
    /// view's insets, how far the screen's safe area reaches into it. The
    /// large sheet reaches the screen's bottom edge: below the status bar it
    /// is told no top inset, and its bottom is the home indicator's (none on
    /// a phone with a home button). Its content keeps clear of the home
    /// indicator when the page fits ([`expectFooter`]), and the page's
    /// ground runs to every edge ([`expectGround`]), read in `shot`.
    private func expectSheetPlace(_ app: XCUIApplication, _ screen: XCUIElement, _ facts: SurfaceFacts,
                                  shot: XCUIScreenshot, _ appearance: Ground, kept name: String) throws {
        let sheet = screen.frame
        let place = try expectPlace(facts, of: sheet, in: app, name)
        XCTAssertEqual(sheet.maxY, app.frame.maxY, accuracy: 0.5, "\(name): the large sheet does not reach the screen's bottom")
        let fits = expectFooter(app, in: sheet, told: place.told, kept: name)
        let picture = try XCTUnwrap(upright(shot.image), "the screenshot has no bitmap")
        try expectGround(appearance, in: picture, scale: shot.image.scale, at: sheet.origin, across: sheet.size,
                         told: place.told, bottom: fits, name)
    }

    /// The page's ground at every edge of what it is presented in, `size`
    /// points big and drawn at `origin` of `picture`, a bitmap at `scale`
    /// pixels a point: each point of [`edgePoints`] is the color of the
    /// page's ground mid-page (in the side padding, inside the told left
    /// inset) in the same bitmap, within 3 a channel, and that ground reads
    /// as `appearance`. The bottom edge only with `bottom`, when the page's
    /// content ends above it. The platform's own sheet background (white, or
    /// black) is within neither scheme's 3 of Stillwater's `night`, though
    /// both read as the same light or dark.
    private func expectGround(_ appearance: Ground, in picture: CGImage, scale: CGFloat, at origin: CGPoint,
                              across size: CGSize, told: UIEdgeInsets, bottom: Bool, _ what: String) throws {
        let middle = CGPoint(x: origin.x + told.left + 12, y: origin.y + size.height / 2)
        let page = try XCTUnwrap(pixel(in: picture, scale: scale, at: middle),
                                 "\(what): no pixel at \(middle) in a \(picture.width)x\(picture.height) bitmap")
        XCTAssertEqual(ground(in: picture, scale: scale, at: middle), appearance,
                       "\(what): the page's ground mid-page is not \(appearance)")
        for point in Self.edgePoints(across: size, told: told, bottom: bottom) {
            let at = CGPoint(x: origin.x + point.x, y: origin.y + point.y)
            let seen = try XCTUnwrap(pixel(in: picture, scale: scale, at: at),
                                     "\(what): no pixel at \(at) in a \(picture.width)x\(picture.height) bitmap")
            XCTAssertTrue(zip(seen, page).allSatisfy { abs($0 - $1) <= 3 },
                          "\(what): at \(at) it shows \(seen), not the page's ground \(page) from \(middle)")
        }
    }

    /// Points along each edge of a frame `size` points big, a quarter and
    /// three quarters along it: 3 inside the edge, and in the middle of the
    /// edge's told inset where it has one at least 6 deep. The bottom edge
    /// only with `bottom`.
    private static func edgePoints(across size: CGSize, told: UIEdgeInsets, bottom: Bool) -> [CGPoint] {
        func depths(_ inset: CGFloat) -> [CGFloat] { inset >= 6 ? [3, inset / 2] : [3] }
        var points: [CGPoint] = []
        for along in [CGFloat(0.25), 0.75] {
            for depth in depths(told.top) { points.append(CGPoint(x: size.width * along, y: depth)) }
            for depth in depths(told.left) { points.append(CGPoint(x: depth, y: size.height * along)) }
            for depth in depths(told.right) { points.append(CGPoint(x: size.width - depth, y: size.height * along)) }
            if bottom {
                for depth in depths(told.bottom) {
                    points.append(CGPoint(x: size.width * along, y: size.height - depth))
                }
            }
        }
        return points
    }

    /// UIKit's safe-area insets for the screen, as the host shows them now.
    private func insets(_ app: XCUIApplication) throws -> UIEdgeInsets {
        let shown = app.descendants(matching: .any)["nuxie-machine-safe-area"]
        XCTAssertTrue(shown.waitForExistence(timeout: 10),
                      "the host does not show the safe area: \(app.debugDescription)")
        let words = shown.label.split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(words.count, 4, "the safe area reads \(shown.label)")
        guard words.count == 4 else { throw NotRead() }
        return UIEdgeInsets(top: words[0], left: words[3], bottom: words[2], right: words[1])
    }

    private struct NotRead: Error {}

    /// The sheet once it has settled: its Screen's frame the same twice
    /// running and `until` holding, and the surface that frame's size, with
    /// a place, its last frame drawn at its drawable. Its frame.
    private func settled(_ app: XCUIApplication, _ screen: XCUIElement, _ what: String,
                         until done: () -> Bool = { true }) throws -> CGRect {
        let deadline = Date().addingTimeInterval(20)
        var last = CGRect.null
        var seen = "nothing"
        while Date() < deadline {
            let frame = screen.frame
            if let read = surfaceNow(app) {
                let (facts, text) = read
                seen = text
                if done(), frame == last, facts.bounds == frame.size, facts.drawn == facts.drawable,
                   facts.placeInsets != nil {
                    return frame
                }
            }
            last = frame
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTFail("\(what) did not settle: Screen \(screen.frame), app \(app.frame), surface \(seen)")
        throw NotRead()
    }

    /// Every place the session took so far, as the host shows them, each
    /// `T R B L W H`.
    private func toldPlaces(_ app: XCUIApplication) -> [[Double]] {
        let shown = app.descendants(matching: .any)["nuxie-machine-places"]
        guard shown.waitForExistence(timeout: 10), shown.label != "none" else { return [] }
        return shown.label.components(separatedBy: "; ").map { $0.split(separator: " ").compactMap { Double($0) } }
    }

    /// The places told so far, once the last of them is the surface's place
    /// now (`facts`): no place is told twice running, so each value is told
    /// once. Kept as the note `name-places`.
    @discardableResult
    private func expectToldOnce(_ app: XCUIApplication, endingWith facts: SurfaceFacts,
                                kept name: String) throws -> [[Double]] {
        let now = try XCTUnwrap(facts.placeNumbers, "\(name): the Screen has no place")
        let deadline = Date().addingTimeInterval(5)
        var told = toldPlaces(app)
        while told.last.map({ !Self.same($0, now) }) ?? true, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            told = toldPlaces(app)
        }
        note(told.map { $0.map { "\($0)" }.joined(separator: " ") }.joined(separator: "\n"), kept: name + "-places")
        XCTAssertTrue(told.last.map { Self.same($0, now) } ?? false,
                      "\(name): the last place told is \(told.last ?? []), not the surface's \(now)")
        for (before, after) in zip(told, told.dropFirst()) {
            XCTAssertFalse(Self.same(before, after), "\(name): the place \(after) was told twice running: \(told)")
        }
        return told
    }

    private static func same(_ one: [Double], _ other: [Double]) -> Bool {
        one.count == other.count && zip(one, other).allSatisfy { abs($0 - $1) < 0.01 }
    }

    /// The Screen element's own bitmap with the phone on its side
    /// (`.landscapeLeft`), turned the right way up ([`uprightLandscape`]),
    /// and where `frame` is drawn in it: the bitmap is the whole screen's,
    /// or the frame's alone. None when it is neither.
    private func landscapeStill(_ screen: XCUIElement, _ app: XCUIApplication, frame: CGRect,
                                scale: CGFloat, _ what: String) throws -> (CGImage, CGPoint) {
        let raw = try XCTUnwrap(screen.screenshot().image.cgImage, "\(what): the Screen's screenshot has no bitmap")
        let still = try XCTUnwrap(uprightLandscape(raw), "\(what): the Screen's bitmap could not be turned")
        let size = CGSize(width: CGFloat(still.width) / scale, height: CGFloat(still.height) / scale)
        func matches(_ other: CGSize) -> Bool {
            abs(size.width - other.width) <= 1 && abs(size.height - other.height) <= 1
        }
        if matches(app.frame.size) { return (still, frame.origin) }
        if matches(frame.size) { return (still, .zero) }
        XCTFail("\(what): the turned still is \(still.width)x\(still.height), neither the screen \(app.frame.size) "
                    + "nor the frame \(frame.size) at scale \(scale)")
        throw NotRead()
    }

    /// The sheet with the phone on its side, checked as the upright one is,
    /// from what UIKit gives, with the Screen element's own bitmap for the
    /// still and the ground ([`landscapeStill`]): kept as `name`, with what
    /// the app says its surface is and the frame UIKit gave the sheet. On an
    /// iPhone UIKit presents a page sheet full screen in compact height; the
    /// test notes which it was and checks either from the facts. The page is
    /// taller than a phone on its side, so its bottom edge is content, not
    /// ground ([`expectFooter`]). The Yearly card sits each side inset plus
    /// 24 in from the sheet's sides.
    @discardableResult
    private func expectLandscapeSheet(_ app: XCUIApplication, _ screen: XCUIElement, _ sheet: CGRect,
                                      _ appearance: Ground, kept name: String) throws -> SurfaceFacts {
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "\(name): the app did not turn")
        let facts = try surface(app, kept: name + "-surface")
        let (still, origin) = try landscapeStill(screen, app, frame: sheet, scale: facts.scale, name)
        keep(name, still, app, screen)
        note("app \(app.frame), sheet \(sheet), "
                 + (sheet == app.frame ? "full screen" : "not full screen"), kept: name + "-frame")
        let place = try expectPlace(facts, of: sheet, in: app, name)
        expectSides(button(app, beginningWith: "Yearly"), in: sheet, inside: place.told, name)
        let fits = expectFooter(app, in: sheet, told: place.told, kept: name)
        try expectGround(appearance, in: still, scale: facts.scale, at: origin, across: sheet.size,
                         told: place.told, bottom: fits, name)
        return facts
    }

    /// Wait until the page's ground mid-page reads `expected` in the Screen
    /// element's own bitmap with the phone on its side.
    private func waitForLandscape(ground expected: Ground, _ app: XCUIApplication, _ screen: XCUIElement,
                                  _ sheet: CGRect, _ message: String) throws {
        let facts = try surface(app, kept: "waiting-\(expected.rawValue)-surface")
        let told = try XCTUnwrap(facts.placeInsets, "the Screen has no place")
        let deadline = Date().addingTimeInterval(10)
        var seen: Ground?
        repeat {
            let (still, origin) = try landscapeStill(screen, app, frame: sheet, scale: facts.scale, message)
            seen = ground(in: still, scale: facts.scale,
                          at: CGPoint(x: origin.x + told.left + 12, y: origin.y + sheet.height / 2))
            if seen == expected { return }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        XCTAssertEqual(seen, expected, message)
    }

    /// A cover's surface `size` points big, whose drawable is that size at
    /// its scale (rounded up, as the Screen sizes it), and whose last frame
    /// was drawn at the drawable's size.
    private func expect(_ facts: SurfaceFacts, coversA size: CGSize, _ what: String) {
        XCTAssertEqual(facts.bounds, size, "\(what): the surface is \(facts.bounds), not the screen's \(size)")
        XCTAssertGreaterThan(facts.scale, 0, "\(what): the surface has no scale")
        let pixels = CGSize(width: (facts.bounds.width * facts.scale).rounded(.up),
                            height: (facts.bounds.height * facts.scale).rounded(.up))
        XCTAssertEqual(facts.drawable, pixels,
                       "\(what): the drawable is \(facts.drawable), not the surface's \(pixels) pixels")
        XCTAssertEqual(facts.drawn, facts.drawable,
                       "\(what): the last frame was drawn at \(facts.drawn), not the drawable's \(facts.drawable)")
    }

    /// The page's ground, `expected`, all across a cover `size` points
    /// big: down both sides in the page's side padding, from just below the
    /// top inset to the bottom edge, and across the top padding. A frame
    /// drawn small, turned or cut off reads black or the wrong scheme
    /// somewhere on the grid.
    private func expectPageGround(_ expected: Ground, in shot: XCUIScreenshot, across size: CGSize,
                                  below insets: UIEdgeInsets, _ what: String) {
        let taken = shot.image.size
        XCTAssertEqual(taken.width, size.width, accuracy: 1, "\(what): read upright, the screenshot is \(taken)")
        XCTAssertEqual(taken.height, size.height, accuracy: 1, "\(what): read upright, the screenshot is \(taken)")
        for point in Self.groundPoints(across: size, below: insets) {
            XCTAssertEqual(ground(in: shot, at: point), expected,
                           "\(what): the page's ground at \(point) is not \(expected) in a \(taken) screenshot")
        }
    }

    /// The same, read from `picture`, a bitmap at `scale` pixels a point
    /// whose rows run the right way up.
    private func expectPageGround(_ expected: Ground, in picture: CGImage, scale: CGFloat, across size: CGSize,
                                  below insets: UIEdgeInsets, _ what: String) {
        for point in Self.groundPoints(across: size, below: insets) {
            XCTAssertEqual(ground(in: picture, scale: scale, at: point), expected,
                           "\(what): the page's ground at \(point) is not \(expected) in a "
                               + "\(picture.width)x\(picture.height) bitmap")
        }
    }

    /// The page's content inside the side insets by the inset plus the
    /// page's own 24: the Yearly card, a box as wide as the content, starts
    /// there on the left of `frame`, what the page is presented in, and ends
    /// there on the right.
    private func expectSides(_ card: XCUIElement, in frame: CGRect, inside insets: UIEdgeInsets,
                             _ what: String) {
        XCTAssertEqual(card.frame.minX - frame.minX, insets.left + 24, accuracy: 1,
                       "\(what): the Yearly card is not the left inset \(insets.left) plus 24 from the left")
        XCTAssertEqual(frame.maxX - card.frame.maxX, insets.right + 24, accuracy: 1,
                       "\(what): the Yearly card is not the right inset \(insets.right) plus 24 from the right")
    }

    /// Down both sides in the page's side padding, from just below the top
    /// inset to the bottom edge, and across the top padding; and in the side
    /// padding inside each side inset, which the page's content keeps clear.
    private static func groundPoints(across size: CGSize, below insets: UIEdgeInsets) -> [CGPoint] {
        let top = insets.top + 30
        return [
            CGPoint(x: insets.left + 12, y: size.height / 2),
            CGPoint(x: size.width - insets.right - 12, y: size.height / 2),
            CGPoint(x: 12, y: top), CGPoint(x: size.width / 4, y: top), CGPoint(x: size.width / 2, y: top),
            CGPoint(x: size.width * 3 / 4, y: top), CGPoint(x: size.width - 12, y: top),
            CGPoint(x: 12, y: size.height / 2), CGPoint(x: size.width - 12, y: size.height / 2),
            CGPoint(x: 12, y: size.height - 12), CGPoint(x: size.width - 12, y: size.height - 12),
        ]
    }

    /// `raw`, the device's portrait buffer with the phone turned to
    /// `.landscapeLeft` (the turn this test makes), turned a quarter
    /// counter-clockwise into the interface's landscape, the right way up:
    /// the pixel at (x, y) of the landscape still is the buffer's pixel at
    /// (raw width - 1 - y, x). Its rows run top first, as the page's points.
    private func uprightLandscape(_ raw: CGImage) -> CGImage? {
        let width = raw.width
        let height = raw.height
        var source = [UInt32](repeating: 0, count: width * height)
        let read = source.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = Self.bitmap(bytes.baseAddress, width: width, height: height) else { return false }
            context.draw(raw, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard read else { return nil }
        // Turned: as wide as the buffer is tall, as tall as it is wide.
        var turned = [UInt32](repeating: 0, count: width * height)
        for y in 0..<width {
            for x in 0..<height {
                turned[y * height + x] = source[x * width + (width - 1 - y)]
            }
        }
        return turned.withUnsafeMutableBytes { bytes in
            Self.bitmap(bytes.baseAddress, width: height, height: width)?.makeImage()
        }
    }

    private static func bitmap(_ data: UnsafeMutableRawPointer?, width: Int, height: Int) -> CGContext? {
        CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// `image`'s pixels the right way up: drawn through its orientation
    /// when it has one, so a point in the app is the same point in them.
    private func upright(_ image: UIImage) -> CGImage? {
        guard image.imageOrientation != .up else { return image.cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
        }.cgImage
    }

    /// Light or dark at `point` of `shot`: light when every channel is at
    /// least `lightAtLeast`, dark when every channel is at most 48.
    private func ground(in shot: XCUIScreenshot, at point: CGPoint, lightAtLeast: Int = 200) -> Ground? {
        let image = shot.image
        guard let picture = upright(image) else { return nil }
        return ground(in: picture, scale: image.scale, at: point, lightAtLeast: lightAtLeast)
    }

    /// Light or dark at `point` of `picture`, a bitmap at `scale` pixels a
    /// point.
    private func ground(in picture: CGImage, scale: CGFloat, at point: CGPoint,
                        lightAtLeast: Int = 200) -> Ground? {
        guard let channels = pixel(in: picture, scale: scale, at: point) else { return nil }
        if channels.allSatisfy({ $0 >= lightAtLeast }) { return .light }
        if channels.allSatisfy({ $0 <= 48 }) { return .dark }
        return nil
    }

    /// The red, green and blue of the pixel at `point` of `picture`, a
    /// bitmap at `scale` pixels a point, or none outside it.
    private func pixel(in picture: CGImage, scale: CGFloat, at point: CGPoint) -> [Int]? {
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        guard x >= 0, y >= 0, x < picture.width, y < picture.height else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // The one pixel at (x, y) from the top lands on the context's
            // only pixel.
            context.draw(picture, in: CGRect(x: -x, y: y - picture.height + 1,
                                             width: picture.width, height: picture.height))
            return true
        }
        guard drawn else { return nil }
        return rgba[0..<3].map(Int.init)
    }

    private func waitUntilGone(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed, "the sheet is still up")
    }

    // MARK: Keeping each frame

    /// A screenshot of the app, kept as `name`, and, while the sheet is up,
    /// what a screen reader reads on it, kept as `name-reading` and printed
    /// to the log one element a line. With `expecting`, the reading is the
    /// story's at that frame, word for word.
    private func keep(_ name: String, _ app: XCUIApplication, _ screen: XCUIElement?,
                      expecting frame: String? = nil, shot: XCUIScreenshot? = nil) {
        let attachment = XCTAttachment(screenshot: shot ?? app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let screen else { return }
        keepReading(name, app, screen, expecting: frame)
    }

    /// `picture` kept as `name`, a PNG of its pixels as they are, with no
    /// orientation, and what a screen reader reads on `screen` beside it.
    private func keep(_ name: String, _ picture: CGImage, _ app: XCUIApplication, _ screen: XCUIElement) {
        let png = UIImage(cgImage: picture, scale: 1, orientation: .up).pngData() ?? Data()
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        keepReading(name, app, screen, expecting: nil)
    }

    private func keepReading(_ name: String, _ app: XCUIApplication, _ screen: XCUIElement,
                             expecting frame: String?) {
        let reading = self.reading(app, on: screen.frame)
        let text = reading.joined(separator: "\n")
        let kept = XCTAttachment(string: text)
        kept.name = name + "-reading"
        kept.lifetime = .keepAlways
        add(kept)
        for line in reading { print("READING \(name): \(line)") }
        if let frame {
            XCTAssertEqual(reading, Self.readings[frame], "what a screen reader reads at \(name) changed")
        }
    }

    /// The elements on the sheet a screen reader reads, in its order: each
    /// line of text, each button, and each group read by its label (an
    /// element with no trait of its own and no children), with its words
    /// and whether it is selected and enabled. The Screen's own element,
    /// which carries the record for these checks, is left out.
    private func reading(_ app: XCUIApplication, on sheet: CGRect) -> [String] {
        guard let root = try? app.snapshot() else { return ["(no snapshot of the app)"] }
        var lines: [String] = []
        func walk(_ element: XCUIElementSnapshot) {
            let kind: String? = switch element.elementType {
            case .button: "button"
            case .staticText: "text"
            case .image: "image"
            case .link: "link"
            case .other where element.children.isEmpty && !element.label.isEmpty: "group"
            default: nil
            }
            if let kind, sheet.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)),
               !element.identifier.hasPrefix("nuxie-machine-") {
                lines.append("\(kind) \"\(element.label)\"\(element.isSelected ? ", selected" : "")"
                    + (element.isEnabled ? "" : ", not enabled"))
            }
            for child in element.children { walk(child) }
        }
        walk(root)
        return lines
    }
}
