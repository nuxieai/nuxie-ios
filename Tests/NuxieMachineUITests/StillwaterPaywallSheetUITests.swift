import UIKit
import XCTest

/// Stillwater's paywall as a native sheet in the runtime host app, driven by
/// the Nux machine, with no person. The host launches with
/// `--nuxie-machine-paywall`; "Finish onboarding" starts a record with
/// `onboarding_completed`, and the machine's `present` row opens the
/// paywall as a sheet, drawn from `paywall.nux` and its `plan-card.nux`
/// alone. The host's store answers a purchase with status `failed` after a
/// few seconds, so the paywall is seen while it buys.
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
/// The paywall follows the person's text size: its text, and the heights of
/// what holds it, are in `rem`, one `rem` being the body size the session is
/// told. The host starts at a size with `--nuxie-machine-text-size` and
/// changes it while the sheet is open by a Darwin notification, both on its
/// window, standing in for the person's setting. Sizes read from text are
/// compared with a tolerance, and nothing that depends on the screen's size
/// is assumed.
///
/// Every place check reads UIKit's own values (the screen's insets, the
/// frames, the view's insets), so the tests hold on any iPhone, one with a
/// home button among them, where the bottom inset is 0. Stillwater's page is
/// a `scroll`. Where it is taller than what it is presented in, its content
/// runs past the bottom edge until it is scrolled: the footer and the bottom
/// edge's ground are then noted, not checked ([`expectFooter`]). At the
/// largest standard text size a drag up brings the footer into view
/// ([`testAtTheLargestStandardTextSizeADragUpBringsTheFooterIntoView`]).
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

    /// For a screen reader the plan cards sit inside the "Plan" radio
    /// group: the group is read by its label, then the two cards, Yearly
    /// then Monthly, the order of the `plans` list the record hands the
    /// page, and each card's frame lies inside the group's. Stillwater draws
    /// the cards as rows of that list (`for choice in plans key=choice.plan`),
    /// so a row read outside its group, or in the order it was mounted,
    /// fails here. A tap on Monthly's row then reaches the record as
    /// Monthly's own plan, and the rows stay where they were, in the group
    /// and in order, with Monthly now read as selected: a row redrawn as a
    /// new one, or its press carrying another row's plan, fails the second
    /// half. Kept as `plan-group` and `plan-group-monthly`.
    func testThePlanCardsAreReadInsideThePlanGroupInOrder() throws {
        let app = launch(.light)
        let screen = try openPaywall(app)
        let yearly = button(app, beginningWith: "Yearly")
        let monthly = button(app, beginningWith: "Monthly")
        XCTAssertTrue(yearly.waitForExistence(timeout: 15), app.debugDescription)
        let group = app.otherElements["Plan"]
        XCTAssertTrue(group.waitForExistence(timeout: 10), "the plans' group is not read: \(app.debugDescription)")
        keep("plan-group", app, screen)
        try expectCardsInGroup(app, screen, group, yearly, monthly, "opened")
        XCTAssertTrue(yearly.isSelected, "the chosen plan, yearly, is not read as selected")
        XCTAssertFalse(monthly.isSelected, "monthly is read as selected while yearly is chosen")

        monthly.tap()
        waitFor(screen, valueContaining: "Selected plan: monthly.")
        waitFor(monthly, "selected == true", "monthly is not read as selected after its row's tap")
        keep("plan-group-monthly", app, screen)
        XCTAssertFalse(yearly.isSelected, "yearly is still read as selected after monthly's row was tapped")
        try expectCardsInGroup(app, screen, group, yearly, monthly, "after monthly's tap")
    }

    /// The reading right after the "Plan" group is its two cards, Yearly then
    /// Monthly, each inside the group's frame and Yearly above Monthly.
    private func expectCardsInGroup(_ app: XCUIApplication, _ screen: XCUIElement, _ group: XCUIElement,
                                    _ yearly: XCUIElement, _ monthly: XCUIElement, _ when: String) throws {
        let read = reading(app, on: screen.frame)
        let at = try XCTUnwrap(read.firstIndex(of: "group \"Plan\""), "\(when): the plans' group is not read: \(read)")
        let next = Array(read.dropFirst(at + 1).prefix(2))
        XCTAssertEqual(next.count, 2, "\(when): nothing is read after the plans' group: \(read)")
        XCTAssertTrue(next.first?.hasPrefix("button \"Yearly") ?? false,
                      "\(when): Yearly is not read first in the group: \(read)")
        XCTAssertTrue(next.last?.hasPrefix("button \"Monthly") ?? false,
                      "\(when): Monthly is not read second: \(read)")

        let inside = group.frame.insetBy(dx: -0.5, dy: -0.5)
        for card in [yearly, monthly] {
            XCTAssertTrue(inside.contains(card.frame),
                          "\(when): \(card.label) at \(card.frame) is outside the group's \(group.frame)")
        }
        XCTAssertLessThan(yearly.frame.minY, monthly.frame.minY, "\(when): Yearly is not above Monthly")
    }

    /// The evening offer as a film, on the host's film clock
    /// (`--nuxie-machine-clock 17:59,18:00,20:00`). The paywall opens at
    /// 17:59 with Yearly chosen and "Continue". At 18:00 "Tonight only"
    /// joins at the top of the plans, chosen, and the buy button reads
    /// "Claim the offer". A tap on Monthly chooses it, and the button reads
    /// "Continue" again. At 20:00 the offer leaves, and Monthly stays
    /// chosen. The cards in the "Plan" group are checked at each stop, and
    /// each stop is held about two seconds so a recording shows it. Kept as
    /// `evening-1-1759`, `evening-2-1800`, `evening-3-monthly` and
    /// `evening-4-2000`, each with its reading.
    func testTheEveningOfferJoinsAndLeavesThePlans() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("the evening film is kept on iOS 17 and later") }
        let app = launch(.light, clock: "17:59,18:00,20:00")
        let screen = try openPaywall(app)
        XCTAssertTrue(button(app, beginningWith: "Yearly").waitForExistence(timeout: 15), app.debugDescription)
        let group = app.otherElements["Plan"]
        XCTAssertTrue(group.waitForExistence(timeout: 10), "the plans' group is not read: \(app.debugDescription)")

        // 1. 17:59: the paywall as it opens on any day.
        waitFor(screen, valueContaining: "Selected plan: annual.")
        expectPlans(app, screen, group, ["Yearly", "Monthly"], chosen: "Yearly", "at 17:59")
        XCTAssertTrue(app.buttons["Continue"].exists, "the buy button does not read Continue at 17:59")
        hold("evening-1-1759", app, screen)

        // 2. 18:00: the offer joins first and is chosen.
        moveTheClock(to: "18:00")
        waitFor(screen, valueContaining: "Selected plan: annual_offer.")
        let offer = button(app, beginningWith: "Tonight only")
        XCTAssertTrue(offer.waitForExistence(timeout: 10), "the offer did not join at 18:00: \(app.debugDescription)")
        waitFor(offer, "selected == true", "the offer is not read as chosen at 18:00")
        XCTAssertTrue(app.buttons["Claim the offer"].waitForExistence(timeout: 10),
                      "the buy button does not read Claim the offer at 18:00")
        expectPlans(app, screen, group, ["Tonight only", "Yearly", "Monthly"], chosen: "Tonight only", "at 18:00")
        hold("evening-2-1800", app, screen)

        // 3. A tap on Monthly chooses it.
        button(app, beginningWith: "Monthly").tap()
        waitFor(screen, valueContaining: "Selected plan: monthly.")
        waitFor(button(app, beginningWith: "Monthly"), "selected == true",
                "Monthly is not read as chosen after its tap")
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 10),
                      "the buy button does not read Continue with Monthly chosen")
        expectPlans(app, screen, group, ["Tonight only", "Yearly", "Monthly"], chosen: "Monthly", "after Monthly's tap")
        hold("evening-3-monthly", app, screen)

        // 4. 20:00: the offer leaves; Monthly stays chosen.
        moveTheClock(to: "20:00")
        waitFor(offer, "exists == false", "the offer did not leave at 20:00")
        expectPlans(app, screen, group, ["Yearly", "Monthly"], chosen: "Monthly", "at 20:00")
        waitFor(screen, valueContaining: "Selected plan: monthly.")
        XCTAssertTrue(app.buttons["Continue"].exists, "the buy button does not read Continue at 20:00")
        hold("evening-4-2000", app, screen)
    }

    /// The cards a screen reader reads right after the "Plan" group are
    /// `names`, in that order and no more, each inside the group's frame,
    /// and only `chosen` is read as selected.
    private func expectPlans(_ app: XCUIApplication, _ screen: XCUIElement, _ group: XCUIElement,
                             _ names: [String], chosen: String, _ when: String) {
        let read = reading(app, on: screen.frame)
        guard let at = read.firstIndex(of: "group \"Plan\"") else {
            return XCTFail("\(when): the plans' group is not read: \(read)")
        }
        let after = Array(read.dropFirst(at + 1))
        let cards = Array(after.prefix { line in names.contains { line.hasPrefix("button \"\($0)") } })
        XCTAssertEqual(cards.count, names.count, "\(when): the group's cards are not \(names): \(read)")
        for (line, name) in zip(cards, names) {
            XCTAssertTrue(line.hasPrefix("button \"\(name)"), "\(when): \(name) is not read in its place: \(read)")
            XCTAssertEqual(line.hasSuffix(", selected"), name == chosen,
                           "\(when): \(name) is \(name == chosen ? "not " : "")read as chosen: \(read)")
        }
        let inside = group.frame.insetBy(dx: -0.5, dy: -0.5)
        var above = -CGFloat.infinity
        for name in names {
            let card = button(app, beginningWith: name)
            XCTAssertTrue(inside.contains(card.frame),
                          "\(when): \(name) at \(card.frame) is outside the group's \(group.frame)")
            XCTAssertGreaterThan(card.frame.minY, above, "\(when): \(name) is not below the card before it")
            above = card.frame.minY
        }
    }

    /// Post the Darwin notification that moves the host's film clock to
    /// `time`, one of the times it was launched with.
    private func moveTheClock(to time: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("dev.nuxie.machine.clock.\(time)" as CFString), nil, nil, true)
    }

    /// Keep the sheet as `name`, then hold it about two seconds, so a film
    /// of the run shows each stop.
    private func hold(_ name: String, _ app: XCUIApplication, _ screen: XCUIElement) {
        keep(name, app, screen)
        Thread.sleep(forTimeInterval: 2)
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

    // MARK: The text size

    /// UIKit's size categories, by the raw values the host takes: the
    /// default (body 17), the largest standard size (body 23) and the
    /// largest accessibility size (body 53).
    private static let defaultSize = "UICTContentSizeCategoryL"
    private static let largestStandardSize = "UICTContentSizeCategoryXXXL"
    private static let largestAccessibilitySize = "UICTContentSizeCategoryAccessibilityXXXL"

    /// The paywall at the largest standard text size, body 23, against the
    /// default, body 17: opened at 17 and changed to 23 while it is open,
    /// then opened at 23. At 23 the headline's text is taller than at 17,
    /// opened at 23 as tall as changed to 23; the headline, the plans and
    /// the buy button keep their order without running into one another;
    /// the buy button can be tapped; and the session is told each size
    /// once. Nothing is assumed about whether the page fits at 23: on a
    /// small phone it runs past the sheet's bottom edge. Kept as
    /// `text-size-17-light`, `text-size-change-17-to-23-light` and
    /// `text-size-23-light`, the stills for a film.
    func testThePaywallAtTheLargestStandardTextSize() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("the host sets a text size with trait overrides, which need iOS 17") }
        let app = launch(.light, textSize: Self.defaultSize)
        let screen = try openPaywall(app)
        let title = text(app, beginningWith: "Ten quiet minutes,")
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        let at17 = try settledTitle(app, title, told: 17)
        keep("text-size-17-light", app, screen)
        expectInOrder(app, title, "at 17")
        XCTAssertTrue(app.buttons["Continue"].isHittable, "at 17 the buy button cannot be tapped")

        changeTextSize(to: Self.largestStandardSize)
        let changed = try settledTitle(app, title, told: 23)
        keep("text-size-change-17-to-23-light", app, screen)
        XCTAssertGreaterThan(changed.height, at17.height * 1.2,
                             "changed to 23 the headline is \(changed.height) tall, at 17 \(at17.height)")
        expectInOrder(app, title, "changed to 23")
        XCTAssertTrue(app.buttons["Continue"].isHittable, "changed to 23 the buy button cannot be tapped")
        expectTold(app, [17, 23], "opened at 17 and changed to 23")
        app.terminate()

        let large = launch(.light, textSize: Self.largestStandardSize)
        let largeScreen = try openPaywall(large)
        let largeTitle = text(large, beginningWith: "Ten quiet minutes,")
        XCTAssertTrue(largeTitle.waitForExistence(timeout: 15), large.debugDescription)
        let at23 = try settledTitle(large, largeTitle, told: 23)
        keep("text-size-23-light", large, largeScreen)
        XCTAssertGreaterThan(at23.height, at17.height * 1.2,
                             "opened at 23 the headline is \(at23.height) tall, at 17 \(at17.height)")
        XCTAssertEqual(at23.height, changed.height, accuracy: 1,
                       "opened at 23 the headline is not as tall as changed to 23")
        expectInOrder(large, largeTitle, "opened at 23")
        XCTAssertTrue(large.buttons["Continue"].isHittable, "opened at 23 the buy button cannot be tapped")
        expectTold(large, [23], "opened at 23")
    }

    /// The paywall at the largest accessibility text size, body 53: opened
    /// at 23 and changed to 53 while it is open, its headline is taller
    /// still, and the session is told 53. Kept as `text-size-53-light`.
    /// Only that is checked: at 53 the page is far taller than the sheet, so
    /// where the buy button and the footer are with nothing scrolled is left
    /// out; that the page scrolls to its footer is checked at 23. The host's
    /// own screen is opened at
    /// 23, where its button to start the record is on screen on every
    /// iPhone.
    func testThePaywallAtTheLargestAccessibilityTextSize() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("the host sets a text size with trait overrides, which need iOS 17") }
        let app = launch(.light, textSize: Self.largestStandardSize)
        let screen = try openPaywall(app)
        let title = text(app, beginningWith: "Ten quiet minutes,")
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        let at23 = try settledTitle(app, title, told: 23)

        changeTextSize(to: Self.largestAccessibilitySize)
        let at53 = try settledTitle(app, title, told: 53)
        keep("text-size-53-light", app, screen)
        XCTAssertGreaterThan(at53.height, at23.height * 1.2,
                             "at 53 the headline is \(at53.height) tall, at 23 \(at23.height)")
        expectTold(app, [23, 53], "opened at 23 and changed to 53")
    }

    /// At the default text size, body 17, where Stillwater's page fits the
    /// sheet: its footer, "Not now" and "Restore purchases", is on screen
    /// with nothing scrolled, inside the sheet and above the home indicator,
    /// and can be tapped where it is, and a drag up over the page moves
    /// nothing, since there is nothing to scroll. Where the sheet is shorter
    /// than the page needs ([`pageHeight`] and the home indicator's inset,
    /// which a large sheet is told), the page scrolls on a drag up: that is
    /// kept as the note `footer-17-fit` and neither part is checked. On every
    /// phone the drag leaves the sheet in place and a plan picked after it
    /// is the record's. Kept as `footer-17-light`, `footer-17-after-drag-up`
    /// and `footer-17-monthly-chosen`. The path of the film
    /// `stillwater-paywall-default`.
    func testAtTheDefaultTextSizeTheFooterIsOnScreenWithoutScrolling() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("the host sets a text size with trait overrides, which need iOS 17") }
        let app = launch(.light, textSize: Self.defaultSize)
        let screen = try openPaywall(app)
        let title = text(app, beginningWith: "Ten quiet minutes,")
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        let top = try settledTitle(app, title, told: 17)
        let sheet = screen.frame
        let screenInsets = try insets(app)
        let bottom = sheet.maxY - screenInsets.bottom
        let restore = app.buttons["Restore purchases"]
        let needed = Self.pageHeight + screenInsets.bottom
        let fits = sheet.height + 0.5 >= needed
        if fits {
            for element in [app.buttons["Not now"], restore] {
                XCTAssertTrue(element.exists, "\(element) is not read: \(app.debugDescription)")
                XCTAssertGreaterThanOrEqual(element.frame.minY, sheet.minY, "\(element) starts above the sheet \(sheet)")
                XCTAssertLessThanOrEqual(element.frame.maxY, bottom + 0.5,
                                         "\(element) runs past \(bottom), where the home indicator starts")
                XCTAssertTrue(element.isHittable, "\(element) cannot be tapped where it is")
            }
        } else {
            note("The page needs \(needed) points and the sheet has \(sheet.height): the page scrolls at 17, so "
                     + "whether the footer is on screen unscrolled and still after a drag up is not checked.",
                 kept: "footer-17-fit")
        }
        keep("footer-17-light", app, screen)

        let footer = restore.exists ? restore.frame : nil
        dragUp(app, over: sheet)
        let after = try settled(title)
        keep("footer-17-after-drag-up", app, screen)
        XCTAssertEqual(screen.frame, sheet, "the drag moved the sheet")
        if fits, let footer {
            XCTAssertEqual(after.minY, top.minY, accuracy: 1, "the page scrolled with nothing to scroll")
            XCTAssertEqual(restore.frame.minY, footer.minY, accuracy: 1, "the footer moved with nothing to scroll")
        }
        waitFor(screen, valueContaining: "Record: open")

        let monthly = button(app, beginningWith: "Monthly")
        monthly.tap()
        waitFor(screen, valueContaining: "Selected plan: monthly.")
        waitFor(monthly, "selected == true", "monthly is not read as selected after its tap")
        keep("footer-17-monthly-chosen", app, screen)
        XCTAssertEqual(screen.frame, sheet, "the tap moved the sheet")
    }

    /// At the largest standard text size, body 23 (UIKit's
    /// extra-extra-extra-large), Stillwater's page is taller than the sheet
    /// and scrolls. A drag up over the page scrolls it, so "Restore
    /// purchases" ends inside the sheet and above the home indicator, and
    /// the sheet stays. A tap on it then starts a restore: the record's
    /// purchase is pending, read as the buy button not enabled, and the
    /// sheet still stays. (The host's stand-in store does not answer
    /// `restore`: its refusal, four seconds later, faults the record and
    /// closes the sheet, as `testAStoreAskedForAnUnknownExternFaults` pins.
    /// This test ends before then.) Where the footer is before the drag is
    /// kept as the note `footer-23-before`, not checked: on a taller phone it
    /// may be in view already, and on a shorter one it starts wholly below
    /// the sheet and is not read at all until the page scrolls. Kept as
    /// `footer-23-before-drag`, `footer-23-after-drag` and
    /// `footer-23-restoring`.
    func testAtTheLargestStandardTextSizeADragUpBringsTheFooterIntoView() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("the host sets a text size with trait overrides, which need iOS 17") }
        let app = launch(.light, textSize: Self.largestStandardSize)
        let screen = try openPaywall(app)
        let title = text(app, beginningWith: "Ten quiet minutes,")
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        _ = try settledTitle(app, title, told: 23)
        let sheet = screen.frame
        let screenInsets = try insets(app)
        let bottom = sheet.maxY - screenInsets.bottom
        let restore = app.buttons["Restore purchases"]
        let before = restore.exists ? restore.frame : nil
        note("Before the drag \"Restore purchases\" is "
                 + (before.map { "at \($0)" } ?? "not read, wholly below the sheet")
                 + "; the sheet is \(sheet) and the home indicator starts at \(bottom).", kept: "footer-23-before")
        keep("footer-23-before-drag", app, screen)

        dragUp(app, over: sheet)
        XCTAssertTrue(restore.waitForExistence(timeout: 10),
                      "after the drag up the footer's links are not read: \(app.debugDescription)")
        let after = try settled(restore)
        keep("footer-23-after-drag", app, screen)
        XCTAssertEqual(screen.frame, sheet, "the drag moved the sheet")
        if let before {
            XCTAssertLessThan(after.minY, before.minY - 20,
                              "the page did not scroll: \"Restore purchases\" was at \(before), and is at \(after)")
        }
        XCTAssertGreaterThanOrEqual(after.minY, sheet.minY, "\"Restore purchases\" is above the sheet \(sheet)")
        XCTAssertLessThanOrEqual(after.maxY, bottom + 0.5,
                                 "\"Restore purchases\" at \(after) runs past \(bottom), where the home indicator starts")
        XCTAssertTrue(restore.isHittable, "\"Restore purchases\" cannot be tapped where it is")

        let buy = app.buttons["Continue"]
        XCTAssertTrue(buy.isEnabled, "the buy button is not enabled before the restore")
        restore.tap()
        waitFor(buy, "enabled == false", "the tap on \"Restore purchases\" did not start a restore")
        keep("footer-23-restoring", app, screen)
        XCTAssertEqual(screen.frame, sheet, "the tap moved the sheet")
        waitFor(screen, valueContaining: "Record: open")
    }

    /// At body 23, the page scrolled and back: a drag up brings the footer
    /// into view, and a tap on "About the trial" there shows the terms line
    /// with the sheet in place. A drag down over the page, which went down
    /// while the page was scrolled, brings the page back to its top and the
    /// sheet stays; a drag down from the top of the page at its top then
    /// takes the sheet, and the record stays open. Kept as
    /// `scrolled-23-details-open`, `scrolled-23-back-at-top` and
    /// `scrolled-23-after-swipe`. The path of the film
    /// `stillwater-paywall-text-23`.
    func testAtTheLargestStandardTextSizeThePageScrollsBackAndASwipeFromItsTopTakesTheSheet() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("the host sets a text size with trait overrides, which need iOS 17") }
        let app = launch(.light, textSize: Self.largestStandardSize)
        let screen = try openPaywall(app)
        let title = text(app, beginningWith: "Ten quiet minutes,")
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        let top = try settledTitle(app, title, told: 23)
        let sheet = screen.frame
        let screenInsets = try insets(app)
        let bottom = sheet.maxY - screenInsets.bottom

        dragUp(app, over: sheet)
        let details = app.buttons["About the trial"]
        XCTAssertTrue(details.waitForExistence(timeout: 10),
                      "after the drag up the footer's links are not read: \(app.debugDescription)")
        let shown = try settled(details)
        XCTAssertEqual(screen.frame, sheet, "the drag up moved the sheet")
        XCTAssertLessThanOrEqual(shown.maxY, bottom + 0.5,
                                 "\"About the trial\" at \(shown) runs past \(bottom), where the home indicator starts")
        XCTAssertTrue(details.isHittable, "\"About the trial\" cannot be tapped where it is")
        details.tap()
        XCTAssertTrue(app.staticTexts[Self.termsLine].waitForExistence(timeout: 10), app.debugDescription)
        keep("scrolled-23-details-open", app, screen)
        XCTAssertEqual(screen.frame, sheet, "the tap moved the sheet")

        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = CGPoint(x: sheet.minX + 12, y: sheet.minY + sheet.height * 0.3)
        origin.withOffset(CGVector(dx: from.x, dy: from.y))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: from.x, dy: from.y + 250)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the headline is not read after the drag back down")
        let back = try settled(title)
        keep("scrolled-23-back-at-top", app, screen)
        XCTAssertTrue(screen.exists, "the drag down over the scrolled page took the sheet")
        XCTAssertEqual(screen.frame, sheet, "the drag down over the scrolled page moved the sheet")
        XCTAssertEqual(back.minY, top.minY, accuracy: 1, "the page did not come back to its top")

        let swipe = try swipeStart(app, sheet)
        let end = CGPoint(x: swipe.x, y: min(app.frame.maxY - screenInsets.bottom - 8, swipe.y + sheet.height * 0.8))
        origin.withOffset(CGVector(dx: swipe.x, dy: swipe.y))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: end.x, dy: end.y)))
        waitUntilGone(screen, "the drag down from the top of the page at its top did not take the sheet")
        waitFor(app.staticTexts["nuxie-machine-record"], labelContaining: "Record: open")
        keep("scrolled-23-after-swipe", app, nil)
    }

    /// A slow drag up most of the way across `sheet`, starting in the page's
    /// left padding three quarters of the way down, clear of every button.
    private func dragUp(_ app: XCUIApplication, over sheet: CGRect) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = CGPoint(x: sheet.minX + 12, y: sheet.minY + sheet.height * 0.75)
        let to = CGPoint(x: from.x, y: from.y - 250)
        origin.withOffset(CGVector(dx: from.x, dy: from.y))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: to.x, dy: to.y)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// `element`'s frame once it has stood still twice running.
    private func settled(_ element: XCUIElement) throws -> CGRect {
        let deadline = Date().addingTimeInterval(10)
        var last = CGRect.null
        while Date() < deadline {
            let now = element.frame
            if now == last, now.height > 0 { return now }
            last = now
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTFail("\(element) did not stand still: \(element.frame)")
        throw NotRead()
    }

    /// Post the Darwin notification the host changes its window's text size
    /// with, to the size category `raw`.
    private func changeTextSize(to raw: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("dev.nuxie.machine.text-size.\(raw)" as CFString), nil, nil, true)
    }

    /// The text size of every environment the session took so far, as the
    /// host shows them (`nuxie-machine-environments`).
    private func toldTextSizes(_ app: XCUIApplication) -> [Double] {
        let shown = app.descendants(matching: .any)["nuxie-machine-environments"]
        guard shown.waitForExistence(timeout: 10), shown.label != "none" else { return [] }
        return shown.label.components(separatedBy: "; ").compactMap { told in
            told.split(separator: " ").last.flatMap { Double($0) }
        }
    }

    /// The headline's frame once the last text size the session was told is
    /// `points` and the headline has stood still twice running: the frame
    /// that draws the size is up.
    private func settledTitle(_ app: XCUIApplication, _ title: XCUIElement, told points: Double) throws -> CGRect {
        let deadline = Date().addingTimeInterval(15)
        var last = CGRect.null
        while Date() < deadline {
            let told = toldTextSizes(app).last
            let now = title.frame
            if let told, abs(told - points) < 0.5, now == last, now.height > 0 { return now }
            last = now
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTFail("the headline did not settle at \(points): told \(toldTextSizes(app)), headline \(title.frame)")
        throw NotRead()
    }

    /// The text sizes told are `want`, one for one, each within half a
    /// point: each size told once. Kept as the note `text-size-told`.
    private func expectTold(_ app: XCUIApplication, _ want: [Double], _ what: String) {
        let told = toldTextSizes(app)
        note(told.map { "\($0)" }.joined(separator: "\n"), kept: "text-size-told")
        XCTAssertTrue(told.count == want.count && zip(told, want).allSatisfy { abs($0 - $1) < 0.5 },
                      "\(what): the session was told \(told), not \(want)")
    }

    /// The headline, the two plans and the buy button, top to bottom, each
    /// below the one before it without running into it.
    private func expectInOrder(_ app: XCUIApplication, _ title: XCUIElement, _ what: String) {
        let boxes = [title, button(app, beginningWith: "Yearly"), button(app, beginningWith: "Monthly"),
                     app.buttons["Continue"]]
        for box in boxes {
            XCTAssertTrue(box.exists, "\(what): \(box) is not read")
        }
        for (above, below) in zip(boxes, boxes.dropFirst()) {
            XCTAssertLessThanOrEqual(above.frame.maxY, below.frame.minY + 0.5,
                                     "\(what): \(above.frame) runs into \(below.frame)")
        }
    }

    /// Post the Darwin notification the host turns its window with.
    private func turnThePhone(_ appearance: Ground) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("dev.nuxie.machine.appearance.\(appearance.rawValue)" as CFString), nil, nil, true)
    }

    /// The story runs at 19:00, after the evening offer's start: the open
    /// paywall waits for 20:00 today, when tonight's offer is skipped, and
    /// "Not now" leaves a wake for 18:00 tomorrow, the offer it owes.
    private func playTheStory(in appearance: Ground) throws {
        let app = launch(appearance, clock: "19:00")
        let screen = try openPaywall(app)
        waitFor(screen, valueContaining: "Record: open, " + wake(at: 20))

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
        waitFor(app.staticTexts["nuxie-machine-record"], labelContaining: "Record: open, " + wake(at: 18, days: 1))
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
    /// On iOS 27 a medium sheet floats: it stands off the screen's sides and
    /// bottom and is drawn smaller than its view (a transform), so its frame
    /// on screen is not its view's size. It settles when its frame stops
    /// changing.
    ///
    /// Checked, as the rule holds for any sheet: the surface fills the
    /// sheet's view (the surface's bounds are the view's), it is told the
    /// insets UIKit gives that view, and each place is told once. Kept, not
    /// checked, as the note `place-sheet-medium-record`: the screen's frame,
    /// the sheet's frame on screen and its view's size, the scale it is
    /// drawn at, how far it stands off each edge of the screen, the
    /// screen's insets, the view's, how far the screen's safe area reaches
    /// into the sheet's frame and whether the view's insets are that, how
    /// the bottom inset compares with the stand-off, the place told, and the
    /// colors at the sheet's bottom edge and below it. The still is
    /// `place-sheet-medium-light`. The page is taller than a medium sheet,
    /// so its content runs past the sheet's bottom edge.
    func testAMediumSheetIsRecordedAsUIKitGivesIt() throws {
        let app = launch(.light, mediumSheet: true)
        let screen = try openPaywall(app, large: false)
        let sheet = try settled(app, screen, "the medium sheet", fillingFrame: false) {
            screen.frame.minY > app.frame.height / 3
        }
        let shot = app.screenshot()
        keep("place-sheet-medium-light", app, screen, shot: shot)
        let facts = try surface(app, kept: "place-sheet-medium-light-surface")
        let place = try expectPlace(facts, of: sheet, in: app, reaching: false, filling: false, "the medium sheet")
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
        let view = facts.viewSize
        let drawnAt = view.width > 0 ? sheet.width / view.width : 0
        let bottom = place.view.bottom
        let comparison = abs(bottom - gap) < 0.5 ? "the same as" : bottom > gap ? "larger than" : "smaller than"
        var lines = [
            "screen \(app.frame)",
            "sheet on screen \(sheet)",
            "sheet's view \(view.width) x \(view.height)",
            "drawn at \(drawnAt) of its view's width and \(view.height > 0 ? sheet.height / view.height : 0) of its height",
            reaches ? "the sheet reaches the screen's bottom edge" : "the sheet floats \(gap) above the screen's bottom edge",
            "it stands off the screen's left by \(sheet.minX - app.frame.minX), the right by \(app.frame.maxX - sheet.maxX), "
                + "the bottom by \(gap)",
            "UIKit gives the sheet's view a bottom inset of \(bottom); the sheet stands \(gap) off the screen's "
                + "bottom edge; the bottom inset is \(comparison) the stand-off (on screen, at the sheet's scale, "
                + "the inset is \(bottom * drawnAt))",
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

    /// A swipe down takes the sheet, and the record stays open: the evening
    /// offer's tasks, armed when the paywall opened at 09:00, are still owed
    /// (a swipe down runs no `close`), so it waits for 18:00. With the clock
    /// moved to 21:00, both of the offer's moments are delivered, its start
    /// and its end, and the record ends.
    func testASwipeDownTakesTheSheetAndTheRecordEndsOnceTheOfferHasPassed() throws {
        let app = launch(clock: "09:00,21:00")
        let screen = try openPaywall(app)
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 15), app.debugDescription)

        // A swipe down has no action behind it: the machine hears `closed`,
        // and pops the paywall. It runs down most of the sheet and stops
        // short of the screen's bottom inset.
        let sheet = screen.frame
        let screenInsets = try insets(app)
        let from = try swipeStart(app, sheet)
        let to = CGPoint(x: from.x, y: min(app.frame.maxY - screenInsets.bottom - 8, from.y + sheet.height * 0.8))
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: from.x, dy: from.y))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: to.x, dy: to.y)))
        waitUntilGone(screen, "the swipe from \(from) to \(to) on the sheet \(sheet), with the screen's insets "
                          + "\(screenInsets), did not take the sheet; the Screen is \(screen.exists ? "\(screen.frame)" : "gone")")
        waitFor(app.staticTexts["nuxie-machine-record"], labelContaining: "Record: open, " + wake(at: 18))
        keep("1-after-swipe", app, nil)

        // 21:00: the offer's start and end are delivered in turn, nothing is
        // owed, and the record ends.
        moveTheClock(to: "21:00")
        waitFor(app.staticTexts["nuxie-machine-record"], labelContaining: "Record: ended")
        keep("2-after-the-offer-passed", app, nil)
    }

    /// At 19:00, so the open paywall's wake (20:00 today, tonight's offer
    /// skipped) differs from the one "Not now" leaves (18:00 tomorrow).
    func testASwipeThePersonLetsGoOfKeepsTheSheet() throws {
        let app = launch(clock: "19:00")
        let screen = try openPaywall(app)
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 15), app.debugDescription)
        let resting = screen.frame

        // A short, slow pull that the person lets go of: UIKit cancels the
        // dismissal and the sheet settles back. The machine hears nothing.
        let from = try swipeStart(app, resting)
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: from.x, dy: from.y))
        let short = start.withOffset(CGVector(dx: 0, dy: 90))
        start.press(forDuration: 0.1, thenDragTo: short, withVelocity: .slow, thenHoldForDuration: 0.4)
        let deadline = Date().addingTimeInterval(10)
        while screen.exists, screen.frame != resting, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(screen.exists, "the swipe took the sheet")
        XCTAssertEqual(screen.frame, resting, "the sheet did not settle back")
        // Open, and still waiting for 20:00, when tonight's offer is skipped.
        waitFor(screen, valueContaining: "Record: open, " + wake(at: 20))
        XCTAssertTrue(app.buttons["Continue"].exists, app.debugDescription)
        keep("1-after-cancelled-swipe", app, screen)

        // The machine's own dismissal still takes the sheet.
        app.buttons["Not now"].tap()
        waitUntilGone(screen)
        waitFor(app.staticTexts["nuxie-machine-record"], labelContaining: "Record: open, " + wake(at: 18, days: 1))
    }

    /// Midnight UTC of the day `launch` started the host on, in seconds
    /// since 1970. The film clock reads its times on that day, however long
    /// the test then runs.
    private var launchDay: TimeInterval = 0

    /// The host's words for a wake at `hour`:00 UTC, `days` after the day
    /// the app was launched on, as the record line shows it.
    private func wake(at hour: Int, days: Int = 0) -> String {
        let day: TimeInterval = 86_400
        let midnight = launchDay
        let moment = Date(timeIntervalSince1970: midnight + Double(days) * day + Double(hour) * 3_600)
        return "wakes at " + moment.ISO8601Format()
    }

    // MARK: Driving the host

    /// The host, on the phone as it is, or started in `appearance`; with
    /// `asCover`, presenting the paywall as a cover; with `mediumSheet`,
    /// turning the presented sheet to the medium detent once it is up; with
    /// `textSize`, started at that size category, by its raw value. The
    /// session is always on the host's film clock, at `clock`'s times of day
    /// (UTC): 09:00 unless a test names others, so the real clock crossing
    /// the evening offer's 18:00 or 20:00 cannot change a test.
    private func launch(_ appearance: Ground? = nil, asCover: Bool = false,
                        mediumSheet: Bool = false, textSize: String? = nil,
                        clock: String = "09:00") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--nuxie-machine-paywall", "--nuxie-machine-clock", clock]
        if asCover {
            app.launchArguments += ["--nuxie-machine-paywall-cover"]
        }
        if mediumSheet {
            app.launchArguments += ["--nuxie-machine-sheet-detent", "medium"]
        }
        if let appearance {
            app.launchArguments += ["--nuxie-machine-appearance", appearance.rawValue]
        }
        if let textSize {
            app.launchArguments += ["--nuxie-machine-text-size", textSize]
        }
        launchDay = (Date().timeIntervalSince1970 / 86_400).rounded(.down) * 86_400
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
    /// insets UIKit gives the Screen's view and its size; and the place the session is
    /// told, its insets and size (none before it has one).
    private struct SurfaceFacts {
        let bounds: CGSize
        let drawable: CGSize
        let scale: CGFloat
        let drawn: CGSize
        let viewInsets: UIEdgeInsets
        let viewSize: CGSize
        let placeInsets: UIEdgeInsets?
        let placeSize: CGSize?
        /// The place as the host writes it, `T R B L W H`.
        let placeNumbers: [Double]?

        init?(_ numbers: [Double]) {
            guard numbers.count == 13 || numbers.count == 19 else { return nil }
            bounds = CGSize(width: numbers[0], height: numbers[1])
            drawable = CGSize(width: numbers[2], height: numbers[3])
            scale = numbers[4]
            drawn = CGSize(width: numbers[5], height: numbers[6])
            viewInsets = UIEdgeInsets(top: numbers[7], left: numbers[10], bottom: numbers[9], right: numbers[8])
            viewSize = CGSize(width: numbers[11], height: numbers[12])
            guard numbers.count == 19 else {
                placeInsets = nil
                placeSize = nil
                placeNumbers = nil
                return
            }
            placeInsets = UIEdgeInsets(top: numbers[13], left: numbers[16], bottom: numbers[15], right: numbers[14])
            placeSize = CGSize(width: numbers[17], height: numbers[18])
            placeNumbers = Array(numbers[13...])
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
    /// `frame`, or with `filling` false its view, for a sheet drawn smaller
    /// than its view (bounds that size, the drawable that size at its
    /// scale, the last frame drawn at it); the place's size is the
    /// surface's; the told insets are the ones UIKit gives the Screen's
    /// view; and, with `reaching`, they are how far the screen's safe area
    /// (the host's `nuxie-machine-safe-area`) reaches into `frame`.
    @discardableResult
    private func expectPlace(_ facts: SurfaceFacts, of frame: CGRect, in app: XCUIApplication,
                             reaching: Bool = true, filling: Bool = true, _ what: String) throws -> Place {
        expect(facts, coversA: filling ? frame.size : facts.viewSize, what)
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

    /// Stillwater's page, all of it, at the default text size, one `rem`
    /// being 17: its top padding (64), the mark and the headline's margin
    /// (40 and 28), the headline's two lines (2 x 2.24rem, 76.16), the
    /// plans' margin and the two plans with the gap between (40, 4.24rem
    /// 72.08, 12, 72.08), the buy button and its margin (28 and 3.29rem
    /// 55.93), the error line's box (2.36rem + 12, 52.12), the footer ("Not
    /// now" 2.82rem 47.94, the links 4 and 2.59rem 44.03, the terms' box 8
    /// and 2.36rem 40.12), and its bottom padding (34). Its insets come on
    /// top. The checks that use it run at the default size.
    private static let pageHeight: CGFloat = 718.46

    /// Below the links, at the default text size: the terms' box (8 and
    /// 2.36rem, 40.12) and the page's own bottom padding (34).
    private static let belowTheLinks: CGFloat = 8 + 2.36 * 17 + 34

    /// Whether Stillwater's page fits what it is presented in, `frame`, told
    /// `told`. When it fits, its content keeps clear of the home indicator:
    /// below the links ("Restore purchases"), the terms' box (8 and 40.12)
    /// and the page's own bottom padding (34), then the told bottom inset. When
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
        XCTAssertEqual(frame.maxY - told.bottom - restore.frame.maxY, Self.belowTheLinks, accuracy: 1,
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
    /// running and `until` holding, and the surface that frame's size (with
    /// `fillingFrame` false, its view's: a sheet drawn smaller than its view
    /// never has a frame its view's size), with a place, its last frame
    /// drawn at its drawable. Its frame.
    private func settled(_ app: XCUIApplication, _ screen: XCUIElement, _ what: String, fillingFrame: Bool = true,
                         until done: () -> Bool = { true }) throws -> CGRect {
        let deadline = Date().addingTimeInterval(20)
        var last = CGRect.null
        var seen = "nothing"
        while Date() < deadline {
            let frame = screen.frame
            if let read = surfaceNow(app) {
                let (facts, text) = read
                seen = text
                // The two sizes are read from text, so a third of a point
                // can differ in its last digit.
                let fills = fillingFrame ? frame.size : facts.viewSize
                if done(), frame == last,
                   abs(facts.bounds.width - fills.width) < 0.01, abs(facts.bounds.height - fills.height) < 0.01,
                   facts.drawn == facts.drawable,
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
        XCTAssertEqual(facts.bounds.width, size.width, accuracy: 0.01,
                       "\(what): the surface is \(facts.bounds), not the \(size) it fills")
        XCTAssertEqual(facts.bounds.height, size.height, accuracy: 0.01,
                       "\(what): the surface is \(facts.bounds), not the \(size) it fills")
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

    private func waitUntilGone(_ element: XCUIElement, _ message: @autoclosure () -> String = "the sheet is still up") {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed, message())
    }

    /// Where a swipe down the sheet starts: in the middle, 24 into the
    /// page's top padding, below both the sheet's top and the screen's top
    /// inset. A drag that starts in the status bar's band pulls down the
    /// system's own panel instead, and on a phone with a home button the
    /// large sheet's top sits close to that band.
    private func swipeStart(_ app: XCUIApplication, _ sheet: CGRect) throws -> CGPoint {
        let top = try insets(app).top
        return CGPoint(x: sheet.midX, y: max(sheet.minY, top) + 24)
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
