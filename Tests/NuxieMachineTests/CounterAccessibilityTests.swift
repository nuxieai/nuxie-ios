#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest
import NuxieMachine
import NuxieRuntime

/// A machine Screen as a screen reader meets it, on a simulator with no
/// app. The cover is a Screen controller in a window at a phone's size, its
/// surface under a status bar's and a home indicator's safe areas. Each
/// frame the engine draws is read for its semantic snapshot, and the
/// controller shows that snapshot as its surface's accessibility elements,
/// as the display loop does after every frame it draws. An activation
/// leaves the node's semantic tap for the next frame, which the test hands
/// to the edge as the loop would; no pointer goes out for it.
///
/// Where each line is drawn is read from the frame itself, with text
/// recognition, as the check on where each element says it is.
final class CounterAccessibilityTests: XCTestCase {
    /// 1. The counter's first frame is read top to bottom, once each: every
    ///    line as text, and every button as one button named by the words
    ///    beneath it, which are not read again. Each element is where its
    ///    words are drawn, in screen points.
    @MainActor
    func testTheCounterIsReadOnceInReadingOrderWhereItIsDrawn() async throws {
        let reader = try await Reader.open(Counter.counterPlan(), name: "counter")
        do {
            let first = try await reader.frame(name: "1-first")
            XCTAssertEqual(reader.read, [
                .text("Tapped 0 times"), .text("This line sits below the note."),
                .button("Count"), .button("Hide the note"), .button("Close"),
                .text("Total: 1"), .text("Doubled: 42"), .text("42"),
                .text("Padded"), .text("Twice"), .text("Literal"),
            ])
            for line in ["Tapped 0 times", "This line sits below the note.", "Count", "Hide the note", "Close"] {
                let drawn = try first.box(of: line)
                let center = CGPoint(x: drawn.midX + reader.origin.x, y: drawn.midY + reader.origin.y)
                let frame = reader.onScreen(try reader.element(line))
                XCTAssertTrue(frame.contains(center), "\(line) is said to be at \(frame), drawn around \(center)")
            }
            let tops = reader.elements.map { reader.onScreen($0).minY }
            XCTAssertEqual(tops, tops.sorted(), "read top to bottom")
            XCTAssertGreaterThanOrEqual(tops.first ?? 0, reader.origin.y, "nothing is read above the surface")
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// 2. Activating a button is its node's semantic tap: no pointer goes
    ///    out, one tap waits for the next frame, and that frame's step hears
    ///    it once, so the engine reports one `tap` and the machine counts. A
    ///    second activation of the same snapshot before the frame is
    ///    refused, since the snapshot takes one tap. The count line is the
    ///    same element read anew, the note appears below it, and "Hide the
    ///    note" takes it away again.
    @MainActor
    func testActivatingAButtonIsItsSemanticTapAndTheCountLineFollows() async throws {
        let reader = try await Reader.open(Counter.counterPlan(), name: "counter")
        do {
            let first = try await reader.frame(name: "1-first")
            let line = try reader.element("Tapped 0 times")
            let count = try reader.element("Count")
            XCTAssertTrue(count.accessibilityActivate(), "Count activates")
            XCTAssertFalse(count.accessibilityActivate(), "the same snapshot takes one tap")
            XCTAssertEqual(reader.controller.takePointers(), [], "no pointer went out")
            let taps = reader.controller.takeSemanticTaps()
            let capture = try XCTUnwrap(first.semantics)
            let node = try XCTUnwrap(capture.tree.nodes.first { $0.label == "Count" })
            XCTAssertEqual(taps, [NuxieMachineSemanticTap(captureID: capture.id, nodeID: node.id)])

            let tapped = try await reader.frame(semanticTaps: taps, name: "2-count-activated")
            XCTAssertEqual(tapped.reported.filter { $0 == "tap" }, ["tap"], "one tap: \(tapped.reported)")
            let refused = await reader.refusedTaps()
            XCTAssertEqual(refused, [], "the engine took the tap")
            XCTAssertEqual(Array(reader.read.prefix(4)), [
                .text("Tapped 1 times"), .text("You have counted at least once."),
                .text("This line sits below the note."), .button("Count"),
            ])
            XCTAssertTrue(try reader.element("Tapped 1 times") === line, "the count line is the same element")
            XCTAssertTrue(try reader.element("Count") === count, "the button is the same element")

            XCTAssertTrue(try reader.element("Hide the note").accessibilityActivate())
            XCTAssertEqual(reader.controller.takePointers(), [])
            _ = try await reader.frame(semanticTaps: reader.controller.takeSemanticTaps(), name: "3-hide-activated")
            XCTAssertEqual(Array(reader.read.prefix(3)), [
                .text("Tapped 1 times"), .text("This line sits below the note."), .button("Count"),
            ])
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// 2b. Stillwater's buttons activate the same way: "About the trial"
    ///     opens the terms line with one tap and no pointer going out.
    @MainActor
    func testAStillwaterButtonActivatesThroughItsSemanticTap() async throws {
        let reader = try await Reader.open(Fixture.load(), event: "onboarding_completed", name: "stillwater")
        do {
            _ = try await reader.frame(name: "1-open")
            XCTAssertFalse(reader.labels.contains(StillwaterPaywallEdgeTests.termsLine))
            XCTAssertTrue(try reader.element("About the trial").accessibilityActivate())
            XCTAssertEqual(reader.controller.takePointers(), [], "no pointer went out")
            let taps = reader.controller.takeSemanticTaps()
            XCTAssertEqual(taps.count, 1)
            let opened = try await reader.frame(semanticTaps: taps, name: "2-details-activated")
            XCTAssertEqual(opened.reported.filter { $0 == "tap" }, ["tap"], "one tap: \(opened.reported)")
            XCTAssertTrue(reader.labels.contains(StillwaterPaywallEdgeTests.termsLine), "\(reader.read)")
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// 3. A button the machine disables is read as not enabled in the step
    ///    that disables it, and activating it does nothing: its node offers
    ///    no tap, so nothing is queued and no pointer goes out. A real press
    ///    on it is held back by the engine.
    @MainActor
    func testADisabledButtonIsNotEnabledAndItsActivationDoesNothing() async throws {
        let reader = try await Reader.open(Self.holdPlan, name: "hold")
        do {
            _ = try await reader.frame(name: "1-first")
            let hold = try reader.element("Hold")
            XCTAssertFalse(hold.accessibilityTraits.contains(.notEnabled))
            XCTAssertTrue(hold.accessibilityActivate())
            let held = try await reader.frame(semanticTaps: reader.controller.takeSemanticTaps(), name: "2-held")
            XCTAssertEqual(held.reported.filter { $0 == "tap" }, ["tap"], "one tap: \(held.reported)")
            XCTAssertEqual(reader.read, [.text("Held 1 times"), .button("Hold"), .button("Close")])
            XCTAssertTrue(hold.accessibilityTraits.contains(.notEnabled), "disabled in the step that held it")

            XCTAssertFalse(hold.accessibilityActivate(), "a disabled button does not activate")
            XCTAssertEqual(reader.controller.takeSemanticTaps(), [], "nothing was queued")
            XCTAssertEqual(reader.controller.takePointers(), [], "nothing went out")
            let frame = reader.onScreen(hold)
            let center = CGPoint(x: frame.midX - reader.origin.x, y: frame.midY - reader.origin.y)
            let pressed = try await reader.frame(pointers: Reader.press(at: center), name: "3-pressed")
            XCTAssertFalse(pressed.reported.contains("tap"), "the engine held the press back: \(pressed.reported)")
            XCTAssertEqual(reader.read.first, .text("Held 1 times"))
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// 4. A button scrolled wholly out of its `scroll`, though still drawn
    ///    over by something else on the surface, takes no tap from the
    ///    engine. The page is the `views-scroll` paywall shown as a cover,
    ///    under a header that is a button of its own
    ///    ([`scrollBelowAHeader`]). Scrolled to its end, the lowest card
    ///    wholly above the `scroll` is still read, over the header, where
    ///    its own box is; a tap asked of the engine for its node is refused
    ///    and dropped. Nothing is pressed: the header's action has not run
    ///    and the plan is unchanged, while a real touch at the card's middle
    ///    presses the header, which a tap at the card's place would have
    ///    done. Scrolled back so the card is partly in view, the same card
    ///    activates and reaches `choose` with its own plan. (Activating the
    ///    card while it is wholly out waits behind its reveal:
    ///    [`ScreenReaderScrollingTests`].)
    @MainActor
    func testAButtonScrolledOutOfItsScrollTakesNoActivationAndPartlyBackInItDoes() async throws {
        let reader = try await Reader.open(Self.scrollBelowAHeader(), event: "onboarding_completed",
                                           name: "scroll")
        do {
            _ = try await reader.frame(name: "1-open")
            var picked = try await reader.run.edge.slot("picked")
            XCTAssertEqual(picked, .text("Yearly"))
            // Up past the end; the page settles at its end.
            try await reader.drag(from: CGPoint(x: 195, y: 820), by: -1400)
            var frame = try await reader.frame(name: "2-at-the-end")
            let header = try reader.node(Self.headerLabel, in: frame)
            let top = header.bounds.maxY
            let out = try XCTUnwrap(
                reader.nodes(in: frame).filter {
                    Self.cards.contains($0.label) && $0.bounds.maxY <= top && $0.bounds.minY >= 0
                }.max { $0.bounds.maxY < $1.bounds.maxY },
                "no card is wholly above the scroll at its end: \(reader.nodes(in: frame).map { ($0.label, $0.bounds) })")
            XCTAssertNotEqual(out.label, "Yearly", "the card scrolled out must not be the one already picked: "
                + "\(reader.nodes(in: frame).filter { Self.cards.contains($0.label) }.map { ($0.label, $0.bounds) }), "
                + "the scroll's top \(top)")
            let middle = CGPoint(x: out.bounds.midX, y: out.bounds.midY)
            XCTAssertTrue(header.bounds.contains(middle), "the header is drawn at \(out.label)'s middle")

            let card = try reader.element(out.label)
            XCTAssertTrue(card.accessibilityTraits.contains(.button), "\(out.label) is still read as a button")
            XCTAssertEqual(card.accessibilityFrameInContainerSpace, out.bounds,
                           "\(out.label) is read where its own box is, over the header")
            let capture = try XCTUnwrap(frame.semantics)
            let asked = try await reader.frame(
                semanticTaps: [NuxieMachineSemanticTap(captureID: capture.id, nodeID: out.id)], name: "3-refused")
            var refused = await reader.refusedTaps()
            XCTAssertEqual(refused, [out.id], "the engine refused the tap on a card scrolled out")
            XCTAssertFalse(asked.reported.contains("tap"), "nothing was pressed: \(asked.reported)")
            let reminded = try await reader.run.edge.slot("reminded")
            XCTAssertEqual(reminded, .bool(false), "the header drawn at the card's place was not pressed")
            picked = try await reader.run.edge.slot("picked")
            XCTAssertEqual(picked, .text("Yearly"), "the card's own action did not run")

            let touched = try await reader.frame(pointers: Reader.press(at: middle), name: "4-touched")
            XCTAssertEqual(touched.reported.filter { $0 == "tap" }, ["tap"], "\(touched.reported)")
            let pressed = try await reader.run.edge.slot("reminded")
            XCTAssertEqual(pressed, .bool(true), "a touch at the card's middle presses the header")
            picked = try await reader.run.edge.slot("picked")
            XCTAssertEqual(picked, .text("Yearly"), "and not the card")

            // Down until the card's middle is at the top of the scroll.
            try await reader.drag(from: CGPoint(x: 195, y: 600), by: top - middle.y)
            frame = try await reader.frame(name: "5-partly-in")
            let back = try reader.node(out.label, in: frame)
            XCTAssertTrue(back.bounds.minY < top && back.bounds.maxY > top,
                          "\(out.label) at \(back.bounds) is partly in the scroll below \(top)")
            XCTAssertTrue(try reader.element(out.label) === card, "the card is the same element")
            XCTAssertTrue(card.accessibilityActivate(), "a card partly in view activates")
            XCTAssertEqual(reader.controller.takePointers(), [], "no pointer went out")
            let taps = reader.controller.takeSemanticTaps()
            XCTAssertEqual(taps.map(\.nodeID), [back.id])
            let chosen = try await reader.frame(semanticTaps: taps, name: "6-partly-in-activated")
            XCTAssertEqual(chosen.reported.filter { $0 == "tap" }, ["tap"], "one tap: \(chosen.reported)")
            refused = await reader.refusedTaps()
            XCTAssertEqual(refused, [out.id], "the engine took the second tap")
            picked = try await reader.run.edge.slot("picked")
            XCTAssertEqual(picked, .text(out.label), "the card reached `choose` with its own plan")
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// 5. A Screen under another presentation takes no activation. The
    ///    cover's "Count" element, kept from before, is activated once a
    ///    sheet has started to arrive over it and again while the sheet is
    ///    up: nothing is queued and the count stays. Once the sheet starts
    ///    to leave, the same element counts again. Reach follows the
    ///    presenter's state, set on the controller as the presenter sets it
    ///    after every event; a sheet cannot be presented in this suite,
    ///    which has no app.
    @MainActor
    func testACoveredScreenTakesNoActivationUntilTheSheetOverItLeaves() async throws {
        let reader = try await Reader.open(Counter.counterPlan(), name: "counter")
        do {
            _ = try await reader.frame(name: "1-first")
            let count = try reader.element("Count")
            let cover = reader.controller.presented
            let sheet = NuxieMachinePresented(
                shown: NuxieMachineShown(journey: cover.shown.journey, instance: cover.shown.instance + 100),
                route: "sheet", presentation: .sheet)
            var state = NuxieMachineSheetState()
            _ = state.handle(.started)
            _ = state.handle(.report(.delivered(shown: [cover], rows: [])))
            _ = state.handle(.presented(cover.shown))
            reader.reach(state)
            XCTAssertTrue(reader.controller.reachable, "the cover is in reach while it is on top")

            XCTAssertEqual(state.handle(.report(.delivered(shown: [cover, sheet], rows: []))),
                           [.present([sheet], over: cover.shown)])
            reader.reach(state)
            XCTAssertFalse(count.accessibilityActivate(), "a button under an arriving sheet does not activate")
            XCTAssertEqual(reader.controller.takeSemanticTaps(), [], "nothing was queued as the sheet arrives")
            _ = state.handle(.presented(sheet.shown))
            reader.reach(state)
            XCTAssertFalse(count.accessibilityActivate(), "a button under a sheet does not activate")
            XCTAssertEqual(reader.controller.takeSemanticTaps(), [], "nothing was queued under the sheet")
            XCTAssertEqual(reader.controller.takePointers(), [], "nothing went out")
            _ = try await reader.frame(name: "2-covered")
            XCTAssertEqual(reader.read.first, .text("Tapped 0 times"), "the count did not change")

            XCTAssertEqual(state.handle(.report(.delivered(shown: [cover], rows: []))), [.dismiss(sheet.shown)])
            reader.reach(state)
            XCTAssertTrue(reader.controller.reachable, "the cover is in reach again as the sheet leaves")
            XCTAssertTrue(count.accessibilityActivate(), "the same button activates again")
            let tapped = try await reader.frame(semanticTaps: reader.controller.takeSemanticTaps(), name: "3-uncovered")
            XCTAssertEqual(tapped.reported.filter { $0 == "tap" }, ["tap"], "one tap: \(tapped.reported)")
            XCTAssertEqual(reader.read.first, .text("Tapped 1 times"))
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// 6. An activation asked of a snapshot that has since been replaced
    ///    does nothing. "Count" is activated, and before its tap reaches a
    ///    frame a touch on "Count" counts once, so the next snapshot reads
    ///    differently and replaces the one the tap was asked of. (A snapshot
    ///    whose tree reads the same keeps its id, and a tap asked of it still
    ///    stands.) The engine refuses the waiting tap, the frame drops it
    ///    and sends no pointer in its place, and the count stays. The
    ///    element, read anew from the new snapshot, then counts.
    @MainActor
    func testAnActivationOfAReplacedSnapshotDoesNothing() async throws {
        let reader = try await Reader.open(Counter.counterPlan(), name: "counter")
        do {
            let first = try await reader.frame(name: "1-first")
            let count = try reader.element("Count")
            XCTAssertTrue(count.accessibilityActivate())
            let stale = reader.controller.takeSemanticTaps()
            XCTAssertEqual(stale.map(\.captureID), [try XCTUnwrap(first.semantics).id])

            let frame = reader.onScreen(count)
            let center = CGPoint(x: frame.midX - reader.origin.x, y: frame.midY - reader.origin.y)
            let touched = try await reader.frame(pointers: Reader.press(at: center), name: "2-touched")
            XCTAssertEqual(touched.reported.filter { $0 == "tap" }, ["tap"], "\(touched.reported)")
            XCTAssertEqual(reader.read.first, .text("Tapped 1 times"))
            XCTAssertNotEqual(touched.semantics?.id, first.semantics?.id, "a new snapshot")

            let dropped = try await reader.frame(semanticTaps: stale, name: "3-stale-tap")
            let refused = await reader.refusedTaps()
            XCTAssertEqual(refused, stale.map(\.nodeID), "the engine refused the old snapshot's tap")
            XCTAssertFalse(dropped.reported.contains("tap"), "nothing was pressed: \(dropped.reported)")
            XCTAssertEqual(reader.read.first, .text("Tapped 1 times"), "the count did not change")

            XCTAssertTrue(try reader.element("Count") === count, "the button is the same element")
            XCTAssertTrue(count.accessibilityActivate())
            let tapped = try await reader.frame(semanticTaps: reader.controller.takeSemanticTaps(), name: "4-tapped")
            XCTAssertEqual(tapped.reported.filter { $0 == "tap" }, ["tap"], "one tap: \(tapped.reported)")
            XCTAssertEqual(reader.read.first, .text("Tapped 2 times"))
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// 7. A button in a `for` row, activated, reaches the parent's action
    ///    with that row's item. Stillwater's plan cards are rows of
    ///    `for choice in plans key=choice.plan`: Monthly's card makes the
    ///    record's plan monthly and is read as selected, then Yearly's makes
    ///    it annual again.
    @MainActor
    func testACardInAForRowActivatesWithItsOwnItem() async throws {
        let reader = try await Reader.open(Fixture.load(), event: "onboarding_completed", name: "stillwater")
        do {
            _ = try await reader.frame(name: "1-open")
            var plan = try await reader.run.edge.slot("plan")
            XCTAssertEqual(plan, .enumeration("annual"))
            for (card, item) in [("Monthly", "monthly"), ("Yearly", "annual")] {
                let element = try reader.element(startingWith: card)
                XCTAssertTrue(element.accessibilityActivate(), "\(card) activates")
                XCTAssertEqual(reader.controller.takePointers(), [], "no pointer went out")
                let chosen = try await reader.frame(semanticTaps: reader.controller.takeSemanticTaps(),
                                                    name: "2-\(card)-activated")
                XCTAssertEqual(chosen.reported.filter { $0 == "tap" }, ["tap"], "\(card): \(chosen.reported)")
                plan = try await reader.run.edge.slot("plan")
                XCTAssertEqual(plan, .enumeration(item), "the tap in \(card)'s row reached `choose` with its plan")
                XCTAssertTrue(try reader.element(startingWith: card).accessibilityTraits.contains(.selected),
                              "\(card) is read as selected")
            }
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// A button that disables itself once pressed.
    static let holdPlan = NuxieMachinePlanSource(
        files: [
            NuxieMachineSourceFile(path: "main.nux", text: """
                use Hold from "hold"

                component Holding
                  platforms ios android

                  entry
                    on event "opened"
                    do open

                  routes
                    hold  Hold(close=close)  cover

                  action open
                    go(hold)

                  action close
                    dismiss("closed")
                    exit

                """),
            NuxieMachineSourceFile(path: "hold.nux", text: """
                component Hold
                  props
                    close: action

                  state busy = false
                  state held = 0

                  action press
                    busy = true
                    held = held + 1

                  view
                    column padding=24 gap=12 background-color=#0d1214
                      text `Held ${held} times` color=#eef3f1 font-size=24 id="count"
                      button padding=12 background-color=#232c30 disabled=busy press=press id="hold"
                        text "Hold" color=#eef3f1 font-size=16
                      button padding=12 press=close id="close"
                        text "Close" color=#8a9794 font-size=16

                """),
        ],
        assets: [], root: "main", app: "app", experience: "holding", version: 1)

    /// The plan cards of the `views-scroll` paywall.
    static let cards = ["Yearly", "Monthly", "Weekly"]
    static let headerLabel = "Remind me from the header"

    /// The `views-scroll` paywall, copied from the compiler's fixture, with
    /// its page's `scroll` moved under a header. As copied, the `scroll`
    /// fills the whole surface, so a card scrolled out of it is off the
    /// surface too and no element stands for it. Here the page is a
    /// `column` that holds a header 480 points tall, a button for the
    /// paywall's `remind`, and the same `scroll` below it, taking the rest
    /// (`flex=1`). Everything inside the `scroll` is as copied, indented one
    /// step. A card scrolled up out of the `scroll` is then still on the
    /// surface, under the header. At the page's end its foot is at the
    /// surface's foot whatever the header's height, and 480 points puts
    /// Monthly, not only Yearly, wholly above the `scroll` there.
    static func scrollBelowAHeader() throws -> NuxieMachinePlanSource {
        func text(_ name: String) throws -> String {
            let url = try XCTUnwrap(Bundle(for: Counter.self).url(
                forResource: name, withExtension: "nux", subdirectory: "views-scroll"),
                "the test bundle carries views-scroll/\(name).nux")
            return try String(contentsOf: url, encoding: .utf8)
        }
        var lines = try text("paywall").components(separatedBy: "\n")
        let page = "    scroll width=100% height=100% background-color=night id=\"page\""
        let at = try XCTUnwrap(lines.firstIndex(of: page), "the paywall's page is a scroll")
        let end = try XCTUnwrap(lines.firstIndex(of: "component Reminder"), "the paywall's Reminder follows it")
        for index in (at + 1)..<end where !lines[index].isEmpty {
            lines[index] = "  " + lines[index]
        }
        lines.replaceSubrange(at...at, with: [
            "    column width=100% height=100% background-color=night id=\"frame\"",
            "      button height=480 align-items=center justify-content=center press=remind id=\"header\"",
            "        text \"\(headerLabel)\" class=RemindLabel",
            "      scroll width=100% flex=1 id=\"page\"",
        ])
        return NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: try text("main")),
                    NuxieMachineSourceFile(path: "paywall.nux", text: lines.joined(separator: "\n")),
                    NuxieMachineSourceFile(path: "plan-card.nux", text: try text("plan-card"))],
            assets: [], root: "main", app: "app", experience: "quietly", version: 1)
    }
}

/// A screen reader in a machine component's `scroll`, on the engine:
/// Stillwater's paywall at body 30, where its footer starts wholly below
/// the surface, and the `views-scroll` paywall under a header. Frames run
/// as the display loop runs them ([`Reader.screenReaderFrame`]): the
/// controller's reveals, pages and taps go to the edge, and the controller
/// hears what came of them and whether the step settled.
///
/// No test here turns VoiceOver on. Focus, an activation and a scroll
/// gesture are the calls VoiceOver makes on an element
/// (`accessibilityElementDidBecomeFocused`, `accessibilityActivate`,
/// `accessibilityScroll`), made by the test; what VoiceOver then says, where
/// its cursor goes and which gesture sends which direction are not seen.
final class ScreenReaderScrollingTests: XCTestCase {
    /// A body size at which Stillwater's footer is wholly below a phone's
    /// surface with nothing scrolled.
    static let footerSize = 30.0

    /// The footer's "Restore purchases", wholly below the surface, has an
    /// element at its own box there, and the engine offers it no tap. Focus
    /// on it sends one reveal once the Screen is settled; the reveal moves
    /// and animates (frames go unsettled until it rests), and once settled
    /// the link is whole inside its `scroll` and on the surface, where its
    /// element now is, and offers its tap. Activated then, it is pressed
    /// once, and the record calls `restore` (the stand-in store's refusal
    /// of it is left undelivered).
    @MainActor
    func testFocusOnALinkOutOfViewBringsItIntoViewAndItsActivationPressesIt() async throws {
        let reader = try await Reader.open(Fixture.load(), event: "onboarding_completed",
                                           textSize: Self.footerSize, name: "stillwater-30-focus")
        do {
            _ = try await reader.frame(name: "1-open")
            let opened = try await reader.screenReaderFrames(kept: "2-at-rest")
            let capture = try XCTUnwrap(opened.last.semantics)
            let link = try XCTUnwrap(capture.tree.nodes.first { $0.label == "Restore purchases" })
            let region = try XCTUnwrap(link.scrollRegion, "the link is inside the page's scroll")
            let port = capture.scrollRegions[region].bounds
            XCTAssertGreaterThanOrEqual(link.bounds.minY, port.maxY, "\(link.bounds) is wholly below \(port)")
            XCTAssertGreaterThanOrEqual(link.bounds.minY, reader.surface.bounds.maxY, "and below the surface")
            XCTAssertEqual(link.actions, 0, "the engine offers no tap on a link scrolled out")
            let element = try reader.element("Restore purchases")
            XCTAssertEqual(element.accessibilityFrameInContainerSpace, link.bounds, "its element is at its own box")
            let start = try XCTUnwrap(capture.scrollRegions[region].scroll, "the runtime reads the page's scroll")
            XCTAssertEqual(start.y, 0, accuracy: 0.5)

            element.accessibilityElementDidBecomeFocused()
            XCTAssertEqual(reader.controller.screenReaderScrolling.target, link.id)
            let revealed = try await reader.screenReaderFrames(kept: "3-revealed")
            let reveals = revealed.scrolled.filter { if case .reveal = $0.request { true } else { false } }
            XCTAssertEqual(reveals.map(\.outcome), [.moved], "one reveal, which moved: \(revealed.scrolled)")
            XCTAssertTrue(revealed.settled.contains(false), "the reveal animates: \(revealed.settled)")
            let after = try XCTUnwrap(revealed.last.semantics)
            let shown = try XCTUnwrap(after.tree.nodes.first { $0.label == "Restore purchases" })
            XCTAssertTrue(NuxieMachineScreenReaderScroll.isShown(shown, in: after.scrollRegions),
                          "\(shown.bounds) is whole inside its scroll \(after.scrollRegions.map(\.bounds))")
            XCTAssertTrue(reader.surface.bounds.contains(shown.bounds), "\(shown.bounds) is on the surface")
            XCTAssertNotEqual(shown.actions & 1, 0, "in view it offers its tap")
            XCTAssertTrue(try reader.element("Restore purchases") === element, "the same element")
            XCTAssertEqual(element.accessibilityFrameInContainerSpace, shown.bounds, "where it is drawn now")
            let moved = try XCTUnwrap(after.scrollRegions[try XCTUnwrap(shown.scrollRegion)].scroll)
            XCTAssertGreaterThan(moved.y, 0, "the page's scroll moved")

            XCTAssertTrue(element.accessibilityActivate(), "the link activates in view")
            // One frame: the stand-in store refuses `restore`, and the next
            // frame would deliver that refusal as the record's fault.
            let pressed = try await reader.screenReaderFrame(kept: "4-pressed").frame
            XCTAssertEqual(pressed.reported.filter { $0 == "tap" }, ["tap"], "pressed once: \(pressed.reported)")
            let refused = await reader.refusedTaps()
            XCTAssertEqual(refused, [])
            let calls = await reader.run.edge.log.compactMap { entry -> String? in
                if case .call(let call) = entry { return call.externName }
                return nil
            }
            XCTAssertEqual(calls, ["restore"], "the record called restore once")
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// A tap that arrives while its link's reveal is still moving waits
    /// behind it: the activation answers true and queues no tap; the tap
    /// goes in the first frame after the reveal settles, asked of that
    /// frame's snapshot, and "About the trial" is pressed once and shows
    /// the terms line. Nothing is refused on the way.
    @MainActor
    func testATapWhileTheRevealMovesWaitsBehindItAndPressesTheLinkOnce() async throws {
        let reader = try await Reader.open(Fixture.load(), event: "onboarding_completed",
                                           textSize: Self.footerSize, name: "stillwater-30-held")
        do {
            _ = try await reader.frame(name: "1-open")
            _ = try await reader.screenReaderFrames(kept: "2-at-rest")
            let element = try reader.element("About the trial")
            element.accessibilityElementDidBecomeFocused()
            let first = try await reader.screenReaderFrame()
            XCTAssertEqual(first.frame.scrolled.map(\.outcome), [.moved], "the reveal went: \(first.frame.scrolled)")
            XCTAssertFalse(first.frame.settled.contains(reader.controller.shown), "and is moving")

            XCTAssertTrue(element.accessibilityActivate(), "a tap during the reveal is taken")
            XCTAssertEqual(reader.controller.takeSemanticTaps(), [], "and waits: nothing is queued for the engine")
            let id = try XCTUnwrap(reader.nodes(in: try XCTUnwrap(first.drawn)).first { $0.label == "About the trial" }?.id)
            XCTAssertEqual(reader.controller.screenReaderScrolling.heldTap, id)
            XCTAssertFalse(element.accessibilityActivate(), "one tap waits at a time")

            let rest = try await reader.screenReaderFrames(kept: "3-pressed")
            XCTAssertEqual(rest.reported.filter { $0 == "tap" }, ["tap"], "pressed once: \(rest.reported)")
            let refused = await reader.refusedTaps()
            XCTAssertEqual(refused, [], "the tap went once the link offered one")
            XCTAssertTrue(reader.labels.contains(StillwaterPaywallEdgeTests.termsLine), "\(reader.read)")
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// The newest activation wins. A tap held behind its reveal ("Restore
    /// purchases", below the fold) is dropped when a button in view is
    /// activated, whose tap goes at once; and a tap held after a tap in view
    /// not yet sent replaces it.
    @MainActor
    func testTheNewestActivationWins() async throws {
        let reader = try await Reader.open(Fixture.load(), event: "onboarding_completed",
                                           textSize: Self.footerSize, name: "stillwater-30-newest")
        do {
            _ = try await reader.frame(name: "1-open")
            let opened = try await reader.screenReaderFrames(kept: "2-at-rest")
            let capture = try XCTUnwrap(opened.last.semantics)
            let inView = try XCTUnwrap(capture.tree.nodes.first {
                $0.actions & 1 != 0 && !$0.label.isEmpty
                    && NuxieMachineScreenReaderScroll.isShown($0, in: capture.scrollRegions)
                    && reader.surface.bounds.contains($0.bounds)
            }, "a button in view")
            let link = try XCTUnwrap(capture.tree.nodes.first { $0.label == "Restore purchases" })
            let held = try reader.element("Restore purchases")
            let pressed = try reader.element(inView.label)

            XCTAssertTrue(held.accessibilityActivate(), "the link below the fold takes a tap, which waits")
            XCTAssertEqual(reader.controller.screenReaderScrolling.heldTap, link.id)
            XCTAssertTrue(pressed.accessibilityActivate(), "\(inView.label), in view, activates")
            XCTAssertNil(reader.controller.screenReaderScrolling.heldTap, "the held tap is dropped")
            XCTAssertEqual(reader.controller.takeSemanticTaps().map(\.nodeID), [inView.id], "the newest goes at once")

            XCTAssertTrue(pressed.accessibilityActivate())
            XCTAssertTrue(held.accessibilityActivate(), "a held tap after it")
            XCTAssertEqual(reader.controller.takeSemanticTaps(), [], "replaces the tap not yet sent")
            XCTAssertEqual(reader.controller.screenReaderScrolling.heldTap, link.id)
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// A scroll gesture on an element of the page moves the page one page
    /// in the next frame, and once it moved the reader is told which page
    /// shows ("Page n of m"); at an end it answers false, tells nothing and
    /// queues nothing. At its top
    /// the page shows nothing above. `.down`, which UIKit sends for a
    /// three-finger swipe up (it names the way the scroll indicator moves),
    /// shows what is below: one page, `max(h - 48, h / 2, 1)` points of the
    /// page's box, which here is more than the page's range, so it stops at
    /// its end. `.up` brings it back to its top. Yearly, the page's first
    /// plan, scrolled out of the page keeps its element at its own box. The
    /// page is the `scroll` below Stillwater's header, found by Yearly's
    /// region; the header, which holds the headline, does not move.
    @MainActor
    func testAScrollGestureMovesThePageOnePageAndAtAnEndAnswersFalse() async throws {
        let reader = try await Reader.open(Fixture.load(), event: "onboarding_completed",
                                           textSize: Self.footerSize, name: "stillwater-30-page")
        do {
            _ = try await reader.frame(name: "1-open")
            let opened = try await reader.screenReaderFrames(kept: "2-at-rest")
            var posted: [Any?] = []
            reader.controller.pageScrolled = { posted.append($0) }
            let plan = try reader.element(startingWith: "Yearly")
            let capture = try XCTUnwrap(opened.last.semantics)
            let index = try Self.pageRegion(capture)
            let headline = try XCTUnwrap(capture.tree.nodes.first { $0.label.hasPrefix("Ten quiet minutes,") })
            let page = capture.scrollRegions[index]
            let range = try XCTUnwrap(page.range, "the runtime reads the page's range").height
            XCTAssertGreaterThan(range, 0, "the page scrolls at \(Self.footerSize)")
            let step = NuxieMachineScreenReaderScroll.pageStep(page.bounds.height)

            XCTAssertFalse(plan.accessibilityScroll(.up), "at its top the page shows nothing above")
            XCTAssertTrue(posted.isEmpty, "nothing is told at an end")
            XCTAssertFalse(reader.controller.screenReaderScrolling.wantsFrames, "nothing is queued at an end")

            XCTAssertTrue(plan.accessibilityScroll(.down), "down shows what is below")
            XCTAssertTrue(posted.isEmpty, "nothing is told before the page moved")
            let pages = 1 + Int(((range - 0.5) / step).rounded(.up))
            XCTAssertGreaterThan(pages, 1)
            let down = try await reader.screenReaderFrames(kept: "3-paged-down")
            XCTAssertEqual(posted.map { $0 as? String }, ["Page \(pages) of \(pages)"],
                           "told once, with the last page: the step passes the range")
            XCTAssertEqual(down.scrolled.count, 1, "\(down.scrolled)")
            guard case .page(_, let region, let dx, let dy) = down.scrolled.first?.request else {
                return XCTFail("no page went: \(down.scrolled)")
            }
            XCTAssertEqual(region, index)
            XCTAssertEqual([dx, dy], [0, -Float(step)], "one page of the page's box")
            XCTAssertEqual(down.scrolled.first?.outcome, .moved)
            let end = try XCTUnwrap(down.last.semantics)
            XCTAssertEqual(try XCTUnwrap(end.scrollRegions[index].scroll).y, min(step, range), accuracy: 0.5)
            XCTAssertEqual(end.scrollRegions[index].canScroll & NuxieNativeScrollRegion.towardBottom, 0, "at its end")
            let card = try XCTUnwrap(end.tree.nodes.first { $0.label.hasPrefix("Yearly") })
            XCTAssertTrue(try reader.element(startingWith: "Yearly") === plan, "the same element")
            if card.bounds.maxY <= page.bounds.minY {
                XCTAssertEqual(plan.accessibilityFrameInContainerSpace, card.bounds,
                               "Yearly out of the page is at its own box")
            }
            let still = try XCTUnwrap(end.tree.nodes.first { $0.label.hasPrefix("Ten quiet minutes,") })
            XCTAssertEqual(still.bounds, headline.bounds, "the headline, in the header, did not move")

            XCTAssertFalse(plan.accessibilityScroll(.down), "at its end the page shows nothing more below")
            XCTAssertEqual(posted.count, 1, "nothing is told at an end")
            XCTAssertFalse(reader.controller.screenReaderScrolling.wantsFrames)

            XCTAssertTrue(plan.accessibilityScroll(.up), "up shows what is above")
            let back = try await reader.screenReaderFrames(kept: "4-paged-up")
            XCTAssertEqual(back.scrolled.map(\.outcome), [.moved])
            XCTAssertEqual(posted.map { $0 as? String }, ["Page \(pages) of \(pages)", "Page 1 of \(pages)"],
                           "back at its top")
            let top = try XCTUnwrap(back.last.semantics)
            XCTAssertEqual(try XCTUnwrap(top.scrollRegions[index].scroll).y, 0, accuracy: 0.5)
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// On the `views-scroll` paywall under a header ([`scrollBelowAHeader`])
    /// scrolled to its end, a card wholly above the `scroll`, read over the
    /// header at its own box, is activated: the tap waits behind the card's
    /// reveal, the page moves back until the card is whole inside the
    /// `scroll`, and the tap then presses the card, not the header drawn
    /// where it was: the record's plan is the card's, and the header's
    /// action has not run.
    @MainActor
    func testACardScrolledOutUnderAHeaderIsRevealedThenPressed() async throws {
        let reader = try await Reader.open(CounterAccessibilityTests.scrollBelowAHeader(),
                                           event: "onboarding_completed", name: "scroll-held")
        do {
            _ = try await reader.frame(name: "1-open")
            try await reader.drag(from: CGPoint(x: 195, y: 820), by: -1400)
            let frame = try await reader.frame(name: "2-at-the-end")
            let header = try reader.node(CounterAccessibilityTests.headerLabel, in: frame)
            let out = try XCTUnwrap(
                reader.nodes(in: frame).filter {
                    CounterAccessibilityTests.cards.contains($0.label) && $0.bounds.maxY <= header.bounds.maxY
                        && $0.bounds.minY >= 0 && $0.label != "Yearly"
                }.max { $0.bounds.maxY < $1.bounds.maxY },
                "no card other than Yearly is wholly above the scroll at its end")
            let card = try reader.element(out.label)
            XCTAssertEqual(card.accessibilityFrameInContainerSpace, out.bounds, "read at its own box, over the header")

            XCTAssertTrue(card.accessibilityActivate(), "a card scrolled out takes an activation")
            XCTAssertEqual(reader.controller.takeSemanticTaps(), [], "which waits behind its reveal")
            let pressed = try await reader.screenReaderFrames(kept: "3-revealed-and-pressed")
            let reveals = pressed.scrolled.filter { if case .reveal = $0.request { true } else { false } }
            XCTAssertEqual(reveals.first?.outcome, .moved, "\(pressed.scrolled)")
            XCTAssertEqual(pressed.reported.filter { $0 == "tap" }, ["tap"], "pressed once: \(pressed.reported)")
            let shown = try reader.node(out.label, in: pressed.last)
            XCTAssertGreaterThanOrEqual(shown.bounds.minY, header.bounds.maxY - 0.5,
                                        "\(shown.bounds) is below the header, inside the scroll")
            let picked = try await reader.run.edge.slot("picked")
            XCTAssertEqual(picked, .text(out.label), "the card reached `choose` with its own plan")
            let reminded = try await reader.run.edge.slot("reminded")
            XCTAssertEqual(reminded, .bool(false), "the header was not pressed")
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// The largest accessibility text size, body 53, at which Stillwater's
    /// header holds more than its 40% of the surface and scrolls.
    static let largestSize = 53.0

    /// At body 53 Stillwater's paywall is two `scroll`s: the header, 40% of
    /// the surface, holding the headline, which starts inside it and runs
    /// past its bottom, and the page below it, from the header's bottom edge
    /// to the surface's, holding the plans. Focus on the headline sends one
    /// reveal, which moves the header until the headline's top is on the
    /// header's top (the headline is taller than the header, so it cannot
    /// show whole), and the page stays. A scroll gesture on Yearly then moves
    /// the page one page down, which leaves Yearly wholly above the page, and
    /// the header stays. Focus on Yearly sends one reveal, which moves the
    /// page back until Yearly is whole inside it, its top on the page's top,
    /// and the header stays where the headline's reveal left it.
    @MainActor
    func testAtTheLargestSizeFocusBringsTheHeadlineIntoTheHeaderAndThePlanIntoThePage() async throws {
        let reader = try await Reader.open(Fixture.load(), event: "onboarding_completed",
                                           textSize: Self.largestSize, name: "stillwater-53-two-scrolls")
        do {
            _ = try await reader.frame(name: "1-open")
            let opened = try await reader.screenReaderFrames(kept: "2-at-rest")
            let capture = try XCTUnwrap(opened.last.semantics)
            func node(_ words: String, in capture: NuxieNativeSemanticCapture) throws -> NuxieNativeSemanticNode {
                try XCTUnwrap(capture.tree.nodes.first { $0.label.hasPrefix(words) }, "\(words) is not read")
            }
            func scroll(_ region: Int, in capture: NuxieNativeSemanticCapture) throws -> CGFloat {
                CGFloat(try XCTUnwrap(capture.scrollRegions[region].scroll, "the runtime reads the scroll").y)
            }
            let headline = try node("Ten quiet minutes,", in: capture)
            let plan = try node("Yearly", in: capture)
            let header = try XCTUnwrap(headline.scrollRegion, "the headline is inside the header's scroll")
            let page = try XCTUnwrap(plan.scrollRegion, "Yearly is inside the page's scroll")
            XCTAssertNotEqual(header, page, "the headline and the plans are in two scrolls")
            let headerBox = capture.scrollRegions[header].bounds
            let pageBox = capture.scrollRegions[page].bounds
            XCTAssertEqual(headerBox.height, reader.surface.bounds.height * 0.4, accuracy: 0.5,
                           "the header is 40% of the surface: \(headerBox)")
            XCTAssertEqual(pageBox.minY, headerBox.maxY, accuracy: 0.5, "the page starts where the header ends")
            XCTAssertEqual(pageBox.maxY, reader.surface.bounds.maxY, accuracy: 0.5, "and ends with the surface")
            XCTAssertGreaterThan(try XCTUnwrap(capture.scrollRegions[header].range).height, 0, "the header scrolls")
            XCTAssertGreaterThan(headline.bounds.minY, headerBox.minY, "\(headline.bounds) starts inside the header")
            XCTAssertGreaterThan(headline.bounds.maxY, headerBox.maxY, "and runs past its bottom \(headerBox)")
            XCTAssertTrue(NuxieMachineScreenReaderScroll.isShown(plan, in: capture.scrollRegions),
                          "Yearly is whole inside the page at its top: \(plan.bounds) in \(pageBox)")
            XCTAssertEqual(try scroll(header, in: capture), 0, accuracy: 0.5)
            XCTAssertEqual(try scroll(page, in: capture), 0, accuracy: 0.5)

            let title = try reader.element(startingWith: "Ten quiet minutes,")
            title.accessibilityElementDidBecomeFocused()
            let read = try await reader.screenReaderFrames(kept: "3-headline-revealed")
            let reveals = read.scrolled.filter { if case .reveal = $0.request { true } else { false } }
            XCTAssertEqual(reveals.map(\.outcome), [.moved], "one reveal, which moved: \(read.scrolled)")
            let revealed = try XCTUnwrap(read.last.semantics)
            let shown = try node("Ten quiet minutes,", in: revealed)
            XCTAssertEqual(shown.bounds.minY, headerBox.minY, accuracy: 0.5,
                           "the headline's top is on the header's top: \(shown.bounds) in \(headerBox)")
            let moved = try scroll(header, in: revealed)
            XCTAssertEqual(moved, headline.bounds.minY - headerBox.minY, accuracy: 0.5,
                           "the header moved by where the headline started in it")
            XCTAssertEqual(try scroll(page, in: revealed), 0, accuracy: 0.5, "the page stayed")
            XCTAssertEqual(title.accessibilityFrameInContainerSpace, shown.bounds, "its element is where it is drawn")

            let card = try reader.element(startingWith: "Yearly")
            XCTAssertTrue(card.accessibilityScroll(.down), "the page shows what is below")
            let down = try await reader.screenReaderFrames(kept: "4-page-down")
            guard case .page(_, let region, _, _) = down.scrolled.first?.request else {
                return XCTFail("no page went: \(down.scrolled)")
            }
            XCTAssertEqual(region, page, "the page of the plans moved, not the header")
            XCTAssertEqual(down.scrolled.map(\.outcome), [.moved])
            let paged = try XCTUnwrap(down.last.semantics)
            let above = try node("Yearly", in: paged)
            XCTAssertLessThanOrEqual(above.bounds.maxY, pageBox.minY + 0.5,
                                     "Yearly at \(above.bounds) is wholly above the page \(pageBox)")
            XCTAssertEqual(try scroll(header, in: paged), moved, accuracy: 0.5, "the header stayed")

            card.accessibilityElementDidBecomeFocused()
            let back = try await reader.screenReaderFrames(kept: "5-plan-revealed")
            let planReveals = back.scrolled.filter { if case .reveal = $0.request { true } else { false } }
            XCTAssertEqual(planReveals.map(\.outcome), [.moved], "one reveal, which moved: \(back.scrolled)")
            let end = try XCTUnwrap(back.last.semantics)
            let inView = try node("Yearly", in: end)
            XCTAssertTrue(NuxieMachineScreenReaderScroll.isShown(inView, in: end.scrollRegions),
                          "\(inView.bounds) is whole inside the page \(pageBox)")
            XCTAssertEqual(inView.bounds.minY, pageBox.minY, accuracy: 0.5, "its top is on the page's top")
            XCTAssertEqual(try scroll(header, in: end), moved, accuracy: 0.5, "the header stayed")
            XCTAssertNotEqual(inView.actions & 1, 0, "in view it offers its tap")
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    // MARK: A page that never settles

    // No machine fixture has both a `scroll` and an animation that never
    // stops, so these run Stillwater's paywall with every step told to the
    // controller as not settled, the way such a page reports it: the
    // engine, the reveal, its animation and the captures are real; only the
    // settle the controller hears is withheld, so rest can come from the
    // still-frames rule alone.

    /// On a page that never reports itself settled, focus on "About the
    /// trial", below the fold, reveals it once a whole run of frames shows
    /// the link still, and a tap that arrives while the reveal moves waits
    /// behind it and presses the link once it is still again: the terms
    /// line shows.
    @MainActor
    func testOnAPageThatNeverSettlesFocusRevealsALinkAndAHeldTapPressesIt() async throws {
        let reader = try await Reader.open(Fixture.load(), event: "onboarding_completed",
                                           textSize: Self.footerSize, name: "stillwater-30-unsettled-held")
        do {
            _ = try await reader.frame(name: "1-open")
            _ = try await reader.screenReaderFrames(kept: "2-at-rest")
            var still: DrawnFrame?
            for _ in 0..<NuxieMachineScreenReaderScroll.stillFrames + 1 {
                still = try await reader.screenReaderFrame(unsettled: true).drawn
            }
            XCTAssertFalse(reader.controller.screenReaderScrolling.atRest,
                           "still frames with nothing waited on are not rest")
            let element = try reader.element("About the trial")
            let capture = try XCTUnwrap(still?.semantics)
            let before = try XCTUnwrap(capture.tree.nodes.first { $0.label == "About the trial" })
            XCTAssertFalse(NuxieMachineScreenReaderScroll.isShown(before, in: capture.scrollRegions),
                           "\(before.bounds) is below the fold")
            element.accessibilityElementDidBecomeFocused()
            var waited = 0
            var first = try await reader.screenReaderFrame(unsettled: true)
            while first.frame.scrolled.isEmpty, waited < 30 {
                waited += 1
                first = try await reader.screenReaderFrame(unsettled: true)
            }
            XCTAssertEqual(waited, NuxieMachineScreenReaderScroll.stillFrames + 1,
                           "the reveal waits a whole run of still frames of the link")
            XCTAssertEqual(first.frame.scrolled.map(\.outcome), [.moved], "the reveal went: \(first.frame.scrolled)")
            XCTAssertTrue(element.accessibilityActivate(), "a tap during the reveal is taken")
            XCTAssertEqual(reader.controller.takeSemanticTaps(), [], "and waits")

            let rest = try await reader.screenReaderFrames(kept: "3-pressed", unsettled: true)
            let reveals = rest.scrolled.filter { if case .reveal = $0.request { true } else { false } }
            XCTAssertEqual(reveals, [], "no second reveal: \(rest.scrolled)")
            XCTAssertEqual(rest.reported.filter { $0 == "tap" }, ["tap"], "pressed once: \(rest.reported)")
            let refused = await reader.refusedTaps()
            XCTAssertEqual(refused, [], "the tap went once the link offered one")
            XCTAssertTrue(reader.labels.contains(StillwaterPaywallEdgeTests.termsLine), "\(reader.read)")
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// On a page that never reports itself settled, while a reveal's
    /// animation moves "Restore purchases" up the page the rule never
    /// reports rest until the link is within half a point of where it
    /// stops, so a second reveal sent then could not overshoot by more
    /// (UNIV-7080); no frame that moved it half a point or more is at rest.
    /// At rest, the link shows whole and offers its tap. One reveal in all.
    @MainActor
    func testOnAPageThatNeverSettlesNoRestIsSeenWhileARevealMoves() async throws {
        let reader = try await Reader.open(Fixture.load(), event: "onboarding_completed",
                                           textSize: Self.footerSize, name: "stillwater-30-unsettled-move")
        do {
            _ = try await reader.frame(name: "1-open")
            _ = try await reader.screenReaderFrames(kept: "2-at-rest")
            for _ in 0..<NuxieMachineScreenReaderScroll.stillFrames + 1 {
                try await reader.screenReaderFrame(unsettled: true)
            }
            try reader.element("Restore purchases").accessibilityElementDidBecomeFocused()
            var boxes: [CGRect] = []
            var rests: [Bool] = []
            var revealedAt: Int?
            func link(_ drawn: DrawnFrame?) throws -> NuxieNativeSemanticNode {
                try XCTUnwrap(drawn?.semantics?.tree.nodes.first { $0.label == "Restore purchases" })
            }
            let revealed = try await reader.screenReaderFrames(kept: "3-revealed", unsettled: true) { frame, drawn in
                if revealedAt == nil,
                   frame.scrolled.contains(where: { if case .reveal = $0.request { true } else { false } }) {
                    revealedAt = boxes.count
                }
                boxes.append(try link(drawn).bounds)
                rests.append(reader.controller.screenReaderScrolling.atRest)
            }
            // Where the link stops: two seconds more of frames, nothing asked.
            var stop = try link(revealed.last).bounds
            for _ in 0..<120 {
                stop = try link(try await reader.screenReaderFrame(unsettled: true).drawn).bounds
            }
            let reveals = revealed.scrolled.filter { if case .reveal = $0.request { true } else { false } }
            XCTAssertEqual(reveals.map(\.outcome), [.moved], "one reveal, which moved: \(revealed.scrolled)")
            var moving = 0
            for index in boxes.indices.dropFirst() where abs(boxes[index].minY - boxes[index - 1].minY) >= 0.5 {
                moving += 1
                XCTAssertFalse(rests[index], "frame \(index) moved the link \(boxes[index - 1]) to \(boxes[index]) "
                                   + "and was seen at rest")
            }
            XCTAssertGreaterThan(moving, NuxieMachineScreenReaderScroll.stillFrames,
                                 "the reveal animates over several frames: \(boxes.map(\.minY))")
            let sent = try XCTUnwrap(revealedAt, "a reveal went")
            XCTAssertTrue(rests[sent...].contains(true), "it comes to rest after the reveal: \(rests)")
            // Before the reveal the link was still where it was: that rest
            // is what let the reveal go. From the reveal on, rest comes only
            // near where it stops.
            for (index, box) in boxes.enumerated() where index >= sent && rests[index] {
                XCTAssertLessThan(abs(box.minY - stop.minY), NuxieMachineScreenReaderScroll.stillDistance,
                                  "frame \(index) was at rest with the link at \(box.minY), short of \(stop.minY)")
            }
            let after = try XCTUnwrap(revealed.last.semantics)
            let shown = try link(revealed.last)
            XCTAssertTrue(NuxieMachineScreenReaderScroll.isShown(shown, in: after.scrollRegions),
                          "\(shown.bounds) is whole inside its scroll")
            XCTAssertNotEqual(shown.actions & 1, 0, "in view it offers its tap")
            print("unsettled reveal: link minY per frame \(boxes.map { ($0.minY * 100).rounded() / 100 }), "
                  + "at rest \(rests.map { $0 ? 1 : 0 }), stops at \(stop.minY)")
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// On a page that never reports itself settled, a page scroll and then
    /// at once a focus on "Restore purchases", which the page leaves below
    /// the fold: the reveal waits until a whole run of frames shows the
    /// link still after the page's move, so exactly one reveal goes, and the
    /// link ends whole in view.
    @MainActor
    func testOnAPageThatNeverSettlesAFocusRightAfterAPageWaitsForTheLinkToBeStill() async throws {
        let reader = try await Reader.open(Fixture.load(), event: "onboarding_completed",
                                           textSize: Self.footerSize, name: "stillwater-30-unsettled-page-focus")
        do {
            _ = try await reader.frame(name: "1-open")
            _ = try await reader.screenReaderFrames(kept: "2-at-rest")
            let plan = try reader.element(startingWith: "Yearly")
            XCTAssertTrue(plan.accessibilityScroll(.down))
            _ = try await reader.screenReaderFrames(kept: "3-at-the-end")
            func link(_ drawn: DrawnFrame?) throws -> NuxieNativeSemanticNode {
                try XCTUnwrap(drawn?.semantics?.tree.nodes.first { $0.label == "Restore purchases" })
            }

            XCTAssertTrue(plan.accessibilityScroll(.up), "back up the page")
            try reader.element("Restore purchases").accessibilityElementDidBecomeFocused()
            var boxes: [CGRect] = []
            var revealedAt: [Int] = []
            let run = try await reader.screenReaderFrames(kept: "4-revealed", unsettled: true) { frame, drawn in
                if frame.scrolled.contains(where: { if case .reveal = $0.request { true } else { false } }) {
                    revealedAt.append(boxes.count)
                }
                boxes.append(try link(drawn).bounds)
            }
            let reveals = run.scrolled.filter { if case .reveal = $0.request { true } else { false } }
            XCTAssertEqual(reveals.map(\.outcome), [.moved], "exactly one reveal: \(run.scrolled)")
            let at = try XCTUnwrap(revealedAt.first)
            XCTAssertGreaterThan(at, NuxieMachineScreenReaderScroll.stillFrames, "not before a whole run")
            for index in (at - NuxieMachineScreenReaderScroll.stillFrames)..<at {
                XCTAssertLessThan(abs(boxes[index].minY - boxes[index - 1].minY),
                                  NuxieMachineScreenReaderScroll.stillDistance,
                                  "frame \(index), before the reveal, moved the link: \(boxes.map(\.minY))")
            }
            let after = try XCTUnwrap(run.last.semantics)
            XCTAssertTrue(NuxieMachineScreenReaderScroll.isShown(try link(run.last), in: after.scrollRegions))
            print("page then focus: link minY per frame \(boxes.map { ($0.minY * 100).rounded() / 100 }), "
                  + "reveal sent in frame \(at)")
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    // MARK: Frames not drawn, and the surface going away

    /// A page that moved in a frame not drawn is not told yet: the snapshot
    /// on screen is from before the move and would read the page it left.
    /// The next drawn frame tells it, read from that frame's snapshot.
    @MainActor
    func testAPageLineWaitsForADrawnFrame() async throws {
        let reader = try await Reader.open(Fixture.load(), event: "onboarding_completed",
                                           textSize: Self.footerSize, name: "stillwater-30-page-undrawn")
        do {
            _ = try await reader.frame(name: "1-open")
            let opened = try await reader.screenReaderFrames(kept: "2-at-rest")
            var posted: [Any?] = []
            reader.controller.pageScrolled = { posted.append($0) }
            let capture = try XCTUnwrap(opened.last.semantics)
            let index = try Self.pageRegion(capture)
            let page = capture.scrollRegions[index]
            let range = try XCTUnwrap(page.range).height
            let step = NuxieMachineScreenReaderScroll.pageStep(page.bounds.height)
            let pages = 1 + Int(((range - 0.5) / step).rounded(.up))
            XCTAssertGreaterThan(pages, 1)

            XCTAssertTrue(try reader.element(startingWith: "Yearly").accessibilityScroll(.down))
            let undrawn = try await reader.screenReaderFrame(drawn: false)
            XCTAssertEqual(undrawn.frame.scrolled.map(\.outcome), [.moved], "the page moved")
            XCTAssertTrue(posted.isEmpty, "a frame not drawn tells nothing: \(posted)")
            XCTAssertFalse(reader.controller.screenReaderScrolling.atRest, "nor is it at rest")
            XCTAssertTrue(reader.controller.screenReaderScrolling.wantsFrames, "it asks for a frame to tell it")
            let drawn = try await reader.screenReaderFrame()
            XCTAssertEqual(posted.map { $0 as? String }, ["Page \(pages) of \(pages)"],
                           "told after the drawn frame, from its snapshot")
            let shown = try XCTUnwrap(drawn.drawn?.semantics).scrollRegions[index]
            XCTAssertEqual(try XCTUnwrap(shown.scroll).y, min(step, range), accuracy: 0.5)
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// When the loop stops (the surface goes away), what the reader asked
    /// and is not done goes with it: a reveal, a tap held behind it and the
    /// page asked.
    @MainActor
    func testTheSurfaceGoingAwayDropsEverything() async throws {
        let reader = try await Reader.open(Fixture.load(), event: "onboarding_completed",
                                           textSize: Self.footerSize, name: "stillwater-30-stop")
        do {
            _ = try await reader.frame(name: "1-open")
            _ = try await reader.screenReaderFrames(kept: "2-at-rest")
            let link = try reader.element("About the trial")
            link.accessibilityElementDidBecomeFocused()
            XCTAssertTrue(link.accessibilityActivate())
            XCTAssertTrue(try reader.element(startingWith: "Yearly").accessibilityScroll(.down))
            XCTAssertTrue(reader.controller.screenReaderScrolling.wantsFrames)
            reader.loop.screens = [reader.controller]
            reader.loop.stop()
            XCTAssertEqual(reader.controller.screenReaderScrolling, NuxieMachineScreenReaderScrolling(),
                           "everything asked is dropped")
            XCTAssertFalse(link.accessibilityActivate(), "and nothing more is taken")
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// Whatever the reader asked, in whatever order, a Screen whose surface
    /// leaves its window has no input waiting and the loop may rest, and the
    /// answers to what a frame took before still come and change nothing:
    /// 200 random sequences of focus, focus lost, activations (held taps
    /// and queued ones), scroll gestures, frames taking what is asked,
    /// answers to what they took, and the Screen covered and uncovered, each
    /// ending with the surface leaving its window.
    @MainActor
    func testAnySequenceEndingInADetachLetsTheLoopRest() async throws {
        let reader = try await Reader.open(Fixture.load(), event: "onboarding_completed",
                                           textSize: Self.footerSize, name: "stillwater-30-detach")
        do {
            _ = try await reader.frame(name: "1-open")
            let opened = try await reader.screenReaderFrames(kept: "2-at-rest")
            let controller = reader.controller
            let elements = [try reader.element("Restore purchases"), try reader.element("About the trial"),
                            try reader.element(try Self.buttonInView(opened.last, on: reader).label),
                            try reader.element(startingWith: "Ten quiet minutes,")]
            reader.loop.screens = [controller]
            let view = try XCTUnwrap(controller.view)
            let directions: [UIAccessibilityScrollDirection] = [.up, .down, .left, .right, .next, .previous]
            var seed: UInt64 = 0x2545_F491_4F6C_DD1D
            func next(_ bound: Int) -> Int {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int((seed >> 33) % UInt64(bound))
            }
            var queued = 0
            for round in 0..<200 {
                if view.window == nil {
                    reader.window.addSubview(view)
                    view.frame = reader.window.bounds
                    view.layoutIfNeeded()
                }
                var taken: [NuxieMachineScrollRequest] = []
                for _ in 0..<next(14) {
                    let element = elements[next(elements.count)]
                    switch next(8) {
                    case 0: element.accessibilityElementDidBecomeFocused()
                    case 1: element.accessibilityElementDidLoseFocus()
                    case 2, 3: _ = element.accessibilityActivate()
                    case 4: _ = element.accessibilityScroll(directions[next(directions.count)])
                    case 5: taken = reader.loop.takeInput().scrolls
                    case 6:
                        let outcome: NuxieMachineScrollOutcome = [.moved, .stayed, .stale, .refused][next(4)]
                        controller.frameEnded(taken.map { NuxieMachineScrolled($0, outcome) }, settled: next(2) == 0)
                        taken = []
                    default:
                        controller.reachable = false
                        controller.reachable = true
                    }
                }
                if controller.queuedTap != nil { queued += 1 }
                view.removeFromSuperview()
                XCTAssertEqual(controller.screenReaderScrolling, NuxieMachineScreenReaderScrolling(), "round \(round)")
                XCTAssertNil(controller.queuedTap, "round \(round): the queued tap goes")
                XCTAssertFalse(controller.hasInput, "round \(round): no input waits")
                XCTAssertFalse(reader.loop.inputWaits, "round \(round): the loop may rest")
                let outcome: NuxieMachineScrollOutcome = [.moved, .stayed, .stale, .refused][next(4)]
                controller.frameEnded(taken.map { NuxieMachineScrolled($0, outcome) }, settled: next(2) == 0)
                XCTAssertFalse(controller.screenReaderScrolling.wantsFrames, "round \(round): \(outcome) after it")
                XCTAssertFalse(reader.loop.inputWaits, "round \(round): the loop may still rest")
            }
            XCTAssertGreaterThan(queued, 10, "queued taps were among what the detach dropped")
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// A tap queued for a Screen that then loses its size, still in its
    /// window, is dropped by the next frame's take, not kept, so the loop
    /// may rest. A reveal the reader asked for is kept and asks for no frame
    /// until the size is back.
    @MainActor
    func testATapQueuedForAScreenWithNoSizeIsDropped() async throws {
        let reader = try await Reader.open(Fixture.load(), event: "onboarding_completed",
                                           textSize: Self.footerSize, name: "stillwater-30-no-size")
        do {
            _ = try await reader.frame(name: "1-open")
            let opened = try await reader.screenReaderFrames(kept: "2-at-rest")
            let controller = reader.controller
            let button = try Self.buttonInView(opened.last, on: reader)
            reader.loop.screens = [controller]
            try reader.element("Restore purchases").accessibilityElementDidBecomeFocused()
            XCTAssertTrue(try reader.element(button.label).accessibilityActivate())
            XCTAssertEqual(controller.queuedTap?.nodeID, button.id, "\(button.label)'s tap is queued")

            let view = try XCTUnwrap(controller.view)
            view.frame = CGRect(x: 0, y: 0, width: 0, height: 0)
            view.layoutIfNeeded()
            XCTAssertNotNil(view.window, "still in its window")
            XCTAssertTrue(reader.loop.inputWaits, "the queued tap waits for the next frame")
            let input = reader.loop.takeInput()
            XCTAssertTrue(input.touching === controller)
            XCTAssertEqual(input.semanticTaps, [], "a Screen that cannot be stepped is sent no tap")
            XCTAssertEqual(input.scrolls, [], "nor a move")
            XCTAssertNil(controller.queuedTap, "the tap is dropped")
            XCTAssertFalse(reader.loop.inputWaits, "the loop may rest")
            XCTAssertTrue(controller.screenReaderScrolling.wantsFrames, "the reveal is kept")

            view.frame = reader.window.bounds
            view.layoutIfNeeded()
            XCTAssertTrue(reader.loop.inputWaits, "with its size back the reveal asks for frames again")
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// The page's `scroll` in `capture`: the region holding Yearly, the
    /// first plan, below the header's.
    private static func pageRegion(_ capture: NuxieNativeSemanticCapture) throws -> Int {
        let plan = try XCTUnwrap(capture.tree.nodes.first { $0.label.hasPrefix("Yearly") }, "Yearly is not read")
        return try XCTUnwrap(plan.scrollRegion, "Yearly is inside the page's scroll")
    }

    /// A button wholly on the surface and offering a tap in `frame`.
    @MainActor
    private static func buttonInView(_ frame: DrawnFrame, on reader: Reader) throws -> NuxieNativeSemanticNode {
        let capture = try XCTUnwrap(frame.semantics)
        return try XCTUnwrap(capture.tree.nodes.first {
            $0.actions & 1 != 0 && !$0.label.isEmpty
                && NuxieMachineScreenReaderScroll.isShown($0, in: capture.scrollRegions)
                && reader.surface.bounds.contains($0.bounds)
        }, "a button in view")
    }
}

/// What a screen reader reads for one element.
private enum Spoken: Equatable, CustomStringConvertible {
    case text(String)
    case button(String)
    case other(String, UIAccessibilityTraits.RawValue)

    var description: String {
        switch self {
        case .text(let label): "text \"\(label)\""
        case .button(let label): "button \"\(label)\""
        case .other(let label, let traits): "\"\(label)\" (traits \(traits))"
        }
    }
}

/// One record's top presentation shown by a Screen controller in a window,
/// with the counter's run under it.
@MainActor
private final class Reader {
    let run: Counter
    let loop: NuxieMachineScreenLoop
    let controller: NuxieMachineScreenViewController
    let window: UIWindow
    let surface: UIView
    /// Where the surface starts on screen.
    let origin: CGPoint
    private let name: String
    private var drawn = 0
    /// The pointer clock a drag's pointers read, in seconds.
    private var clock: Float = 1

    private init(run: Counter, loop: NuxieMachineScreenLoop, controller: NuxieMachineScreenViewController,
                 window: UIWindow, surface: UIView, name: String) {
        self.run = run
        self.loop = loop
        self.controller = controller
        self.window = window
        self.surface = surface
        self.origin = surface.convert(CGPoint.zero, to: nil)
        self.name = name
    }

    static func open(_ plan: NuxieMachinePlanSource, event: String = "opened", textSize: Double? = nil,
                     name: String) async throws -> Reader {
        let run = try Counter(plan: plan)
        if let textSize {
            await run.edge.environment(NuxieMachineEnvironment(dark: false, textSize: textSize), now: run.now)
        }
        await run.edge.start(event: event, now: run.now)
        let stack = await run.edge.stack
        let presented = try XCTUnwrap(stack.last, "the start presents a Screen")
        let loop = NuxieMachineScreenLoop(edge: run.edge)
        let controller = NuxieMachineScreenViewController(presenting: presented, loop: loop)
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: CounterDriverEdgeTests.width,
                                            height: CounterDriverEdgeTests.height))
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        let surface = try XCTUnwrap(controller.view.subviews.first, "the Screen's surface")
        try await run.layOut(at: surface.bounds.size)
        return Reader(run: run, loop: loop, controller: controller, window: window, surface: surface, name: name)
    }

    /// One frame with `pointers` and `semanticTaps` on the top
    /// presentation, drawn, and its semantic snapshot shown by the
    /// controller.
    func frame(pointers: [NuxieNativePointerEvent] = [], semanticTaps: [NuxieMachineSemanticTap] = [],
               name step: String) async throws -> DrawnFrame {
        let touched = await run.edge.shown
        let stepped = await run.edge.frame(pointers: pointers, semanticTaps: semanticTaps, on: touched,
                                           elapsedSeconds: CounterDriverEdgeTests.tick, now: run.advance())
        let fault = await run.edge.fault
        XCTAssertNil(fault, "the frame faulted")
        return try await draw(reported: stepped.reported, name: step)
    }

    /// One frame as the display loop runs it for a screen reader: the
    /// controller's pointers, its moves of a `scroll` and its taps go to the
    /// edge, the frame is drawn with its snapshot (read back without text
    /// recognition or a kept image, unless `kept` names it), the controller
    /// shows the snapshot and hears what came of its moves and whether the
    /// step settled. `unsettled` tells the controller the step did not
    /// settle whatever it reported, as on a page whose animation never
    /// stops; a frame not `drawn` steps and draws nothing, as when the
    /// surface has no drawable, so the controller keeps the snapshot from
    /// before the step.
    @discardableResult
    func screenReaderFrame(kept: String? = nil, unsettled: Bool = false, drawn shows: Bool = true) async throws
        -> (frame: NuxieMachineFrame, drawn: DrawnFrame?) {
        let touched = await run.edge.shown
        let pointers = controller.takePointers()
        let scrolls = controller.takeScrolls()
        let taps = controller.takeSemanticTaps()
        let stepped = await run.edge.frame(pointers: pointers, semanticTaps: taps, scrolls: scrolls, on: touched,
                                           elapsedSeconds: CounterDriverEdgeTests.tick, now: run.advance())
        let fault = await run.edge.fault
        XCTAssertNil(fault, "the frame faulted")
        var drawn: DrawnFrame?
        if let kept {
            drawn = try await draw(reported: stepped.reported, name: kept)
        } else if shows {
            let screen = await run.edge.screen()
            let runtime = try XCTUnwrap(screen, "nothing is presented")
            let size = surface.bounds.size
            let (_, semantics) = try await Pixels.render(runtime, width: Int(size.width) * 2,
                                                         height: Int(size.height) * 2, scale: 2,
                                                         capturesSemantics: true)
            let capture = try XCTUnwrap(semantics, "the frame has no semantic snapshot")
            controller.show(capture)
            drawn = DrawnFrame(reported: stepped.reported, lines: [], semantics: capture)
        }
        let settled = !unsettled && (touched.map { stepped.settled.contains($0) } ?? false)
        controller.frameEnded(touched.map { _ in stepped.scrolled } ?? [], settled: settled)
        return (stepped, drawn)
    }

    /// What frames run for a screen reader did, until the controller asks
    /// for no more and a frame's step reports itself settled (or, with
    /// `unsettled`, as on a page that never settles, until the controller
    /// asks for no more), at most `limit`, then one more drawn and kept as
    /// `kept`: each frame's moves and what came of them, whether each
    /// settled, the events reported, and the last frame drawn. `each` hears
    /// every frame before the kept one, after the controller heard it.
    func screenReaderFrames(limit: Int = 900, kept: String, unsettled: Bool = false,
                            each: ((NuxieMachineFrame, DrawnFrame) throws -> Void)? = nil) async throws
        -> (scrolled: [NuxieMachineScrolled], settled: [Bool], reported: [String], last: DrawnFrame) {
        var scrolled: [NuxieMachineScrolled] = []
        var settled: [Bool] = []
        var reported: [String] = []
        func heard(_ frame: NuxieMachineFrame) {
            scrolled += frame.scrolled
            settled.append(frame.settled.contains(controller.shown))
            reported += frame.reported
        }
        var rested = false
        for _ in 0..<limit {
            let result = try await screenReaderFrame(unsettled: unsettled)
            heard(result.frame)
            try each?(result.frame, try XCTUnwrap(result.drawn))
            if !controller.screenReaderScrolling.wantsFrames, unsettled || settled.last == true {
                rested = true
                break
            }
        }
        XCTAssertTrue(rested, "after \(limit) frames the Screen has not settled, or the controller still asks "
                          + "for frames: \(controller.screenReaderScrolling)")
        let last = try await screenReaderFrame(kept: kept, unsettled: unsettled)
        heard(last.frame)
        return (scrolled, settled, reported, try XCTUnwrap(last.drawn))
    }

    private func draw(reported: [String], name step: String) async throws -> DrawnFrame {
        let screen = await run.edge.screen()
        let runtime = try XCTUnwrap(screen, "nothing is presented")
        drawn += 1
        let frame = try await DrawnFrame.read(runtime, reported: reported, name: "\(name)-\(drawn)-\(step)",
                                              size: surface.bounds.size, capturesSemantics: true)
        controller.show(try XCTUnwrap(frame.semantics, "the frame has no semantic snapshot"))
        return frame
    }

    /// A drag by one pointer from `start`, `by` points down (up when
    /// negative), in 30 frames, held still for 10 more, then let go and
    /// left to settle for four seconds of frames. None is drawn. The settle
    /// is a fixed count, enough for the spring back, not "until the step
    /// reports itself settled". Held still before it is let go,
    /// the drag carries no flick, and four seconds outlast the spring back
    /// from past the end.
    func drag(from start: CGPoint, by distance: CGFloat) async throws {
        let moves = 30
        func pointer(_ kind: NuxieNativePointerKind, _ y: CGFloat) -> NuxieNativePointerEvent {
            NuxieNativePointerEvent(kind: kind, x: Float(start.x), y: Float(y), pointerID: 1, timestamp: clock)
        }
        await step([pointer(.down, start.y)])
        for index in 1...moves {
            clock += CounterDriverEdgeTests.tick
            await step([pointer(.move, start.y + distance * CGFloat(index) / CGFloat(moves))])
        }
        for _ in 0..<10 {
            clock += CounterDriverEdgeTests.tick
            await step([pointer(.move, start.y + distance)])
        }
        clock += CounterDriverEdgeTests.tick
        await step([pointer(.up, start.y + distance)])
        for _ in 0..<240 {
            clock += CounterDriverEdgeTests.tick
            await step([])
        }
    }

    private func step(_ pointers: [NuxieNativePointerEvent]) async {
        let touched = await run.edge.shown
        await run.edge.frame(pointers: pointers, on: touched, elapsedSeconds: CounterDriverEdgeTests.tick,
                             now: run.advance())
        let fault = await run.edge.fault
        XCTAssertNil(fault, "a frame of the drag faulted")
    }

    /// A press and release at `point` on the surface, in one frame.
    static func press(at point: CGPoint) -> [NuxieNativePointerEvent] {
        [.down, .up].map { NuxieNativePointerEvent(kind: $0, x: Float(point.x), y: Float(point.y), pointerID: 1) }
    }

    /// The nodes whose taps the engine has refused so far, in order.
    func refusedTaps() async -> [UInt32] {
        await run.edge.log.compactMap { entry in
            if case .refusedSemanticTap(_, let node) = entry { return node }
            return nil
        }
    }

    var elements: [UIAccessibilityElement] {
        (surface.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
            .filter(\.isAccessibilityElement)
    }

    var read: [Spoken] {
        elements.map { element in
            let label = element.accessibilityLabel ?? ""
            if element.accessibilityTraits.contains(.button) { return .button(label) }
            if element.accessibilityTraits.contains(.staticText) { return .text(label) }
            return .other(label, element.accessibilityTraits.rawValue)
        }
    }

    var labels: [String] { elements.compactMap(\.accessibilityLabel) }

    /// Where `element` is on screen: its frame in the surface, which the
    /// controller sets, taken through the views to the window. The window
    /// is at the screen's origin, so its points are the screen's. This
    /// suite has no app and so no scene, and UIKit gives an element in a
    /// window with no scene a zero screen frame; the UI test reads the
    /// screen frames UIKit gives in the host app.
    func onScreen(_ element: UIAccessibilityElement) -> CGRect {
        surface.convert(element.accessibilityFrameInContainerSpace, to: nil)
    }

    /// Set whether the controller is in reach as the presenter does after
    /// every event: in reach when it shows the state's top presentation.
    func reach(_ state: NuxieMachineSheetState) {
        controller.reachable = state.reachable == controller.shown
    }

    func element(_ label: String) throws -> UIAccessibilityElement {
        try XCTUnwrap(elements.first { $0.accessibilityLabel == label }, "no element \"\(label)\" among \(read)")
    }

    func element(startingWith words: String) throws -> UIAccessibilityElement {
        try XCTUnwrap(elements.first { $0.accessibilityLabel?.hasPrefix(words) == true },
                      "no element starting \"\(words)\" among \(read)")
    }

    /// Every node of `frame`'s snapshot, those a `scroll` clips included,
    /// with its bounds in the surface's points.
    func nodes(in frame: DrawnFrame) -> [NuxieNativeSemanticNode] {
        frame.semantics?.tree.nodes ?? []
    }

    func node(_ label: String, in frame: DrawnFrame) throws -> NuxieNativeSemanticNode {
        try XCTUnwrap(nodes(in: frame).first { $0.label == label },
                      "no node \"\(label)\" among \(nodes(in: frame).map(\.label))")
    }

    func close() async throws {
        loop.stop()
        try await run.edge.close()
        withExtendedLifetime(window) {}
    }
}
#endif
