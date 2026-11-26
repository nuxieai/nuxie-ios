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
    ///    over by something else on the surface, takes no activation. The
    ///    page is the `views-scroll` paywall shown as a cover, under a
    ///    header that is a button of its own ([`scrollBelowAHeader`]).
    ///    Scrolled to its end, the lowest card wholly above the `scroll` is
    ///    still read, over the header; its element refuses, nothing is
    ///    queued, and a tap asked of the engine for its node is refused and
    ///    dropped. Nothing is pressed: the header's action has not run and
    ///    the plan is unchanged, while a real touch at the card's middle
    ///    presses the header, which a tap at the card's place would have
    ///    done. Scrolled back so the card is partly in view, the same card
    ///    activates and reaches `choose` with its own plan.
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
            XCTAssertFalse(card.accessibilityActivate(), "a card scrolled wholly out does not activate")
            XCTAssertEqual(reader.controller.takeSemanticTaps(), [], "nothing was queued")
            XCTAssertEqual(reader.controller.takePointers(), [], "nothing went out")
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
                           [.present(sheet, over: cover.shown)])
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

    static func open(_ plan: NuxieMachinePlanSource, event: String = "opened", name: String) async throws -> Reader {
        let run = try Counter(plan: plan)
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
    /// is a fixed count, not "until the step stops asking": with the
    /// semantic tree built, the engine's step keeps asking for another
    /// frame even once the page is still. Held still before it is let go,
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
