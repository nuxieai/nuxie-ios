#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreGraphics
import Foundation
import XCTest
import NuxieMachine
import NuxieRuntime

/// A `for`'s rows on a simulator, with no window: an inline program whose
/// list of plans changes at each "Next", each plan a card that is a row of
/// the engine's keyed list. The machine mounts, removes and moves rows by
/// its key through the engine's own row functions, which the SDK hands the
/// machine library in its table of writer functions, and a tap inside a
/// row is reported with that row's key, which the machine library reads
/// itself. None of that reaches Swift, so each is checked by its effect:
/// the cards' order in the frame's semantic snapshot, the state each card
/// that stays keeps, and the root's slot after a tap in a row.
///
/// The list, at each "Next": Yearly and Monthly; Lifetime joins first
/// (mounted, then moved to the front); Yearly leaves (removed); Monthly
/// moves to the front. Monthly's own "More" is opened before the first
/// change, and it stays open through all three, while every other card
/// reads "More".
final class RowListEdgeTests: XCTestCase {
    private static let plans = ["Lifetime", "Yearly", "Monthly"]
    /// Each card's root is this tall, and holds its name, "Pick" and its
    /// own "More".
    private static let cardHeight: CGFloat = 120

    func testRowsJoinLeaveAndMoveAndEachKeepsItsOwnStateAndATapInARowReachesTheParent() async throws {
        let run = try Counter(plan: Self.plan())
        do {
            await run.edge.start(event: "opened", now: run.now)
            try await run.layOut()
            var frame = try await run.frame(after: [], name: "rows-1-open", capturesSemantics: true)
            try Self.expect(frame, order: ["Yearly", "Monthly"], open: nil, "opened")

            // Monthly's own detail opens; Yearly's stays shut.
            frame = try await step(run, tapping: Self.detail(of: "Monthly", in: frame).center, "rows-2-monthly-more")
            try Self.expect(frame, order: ["Yearly", "Monthly"], open: "Monthly", "Monthly's detail opened")

            // Lifetime joins first: a fresh row, shut, and Monthly keeps
            // its open detail.
            frame = try await step(run, tapping: Self.center(of: "Next", in: frame), "rows-3-lifetime-joins")
            try Self.expect(frame, order: ["Lifetime", "Yearly", "Monthly"], open: "Monthly", "Lifetime joined first")

            // Yearly leaves.
            frame = try await step(run, tapping: Self.center(of: "Next", in: frame), "rows-4-yearly-leaves")
            try Self.expect(frame, order: ["Lifetime", "Monthly"], open: "Monthly", "Yearly left")

            // Monthly moves to the front, still open.
            frame = try await step(run, tapping: Self.center(of: "Next", in: frame), "rows-5-monthly-moves")
            try Self.expect(frame, order: ["Monthly", "Lifetime"], open: "Monthly", "Monthly moved first")

            // A tap on Monthly's "Pick" is heard with Monthly's row key and
            // runs the parent's `pick` with Monthly's own item.
            let before = try await run.edge.slot("chosen")
            XCTAssertEqual(before, .text("none"))
            _ = try await step(run, tapping: Self.center(of: "Pick Monthly", in: frame), "rows-6-pick-monthly")
            let chosen = try await run.edge.slot("chosen")
            XCTAssertEqual(chosen, .text("Monthly"), "the tap in Monthly's row did not reach the parent as Monthly")

            let open = try await run.edge.recordOpen()
            XCTAssertTrue(open, "the record ended")
            let fault = await run.edge.fault
            XCTAssertNil(fault, "a row call failed the round")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    // MARK: Helpers

    /// A tap at `point` in one frame, then a frame with no touch, read for
    /// its semantic snapshot: the writes of the tap's step laid out.
    private func step(_ run: Counter, tapping point: CGPoint, _ name: String) async throws -> DrawnFrame {
        _ = try await run.frame(after: run.tap(at: point), name: name + "-tap")
        return try await run.frame(after: [], name: name, capturesSemantics: true)
    }

    private static func nodes(_ frame: DrawnFrame) throws -> [NuxieNativeSemanticNode] {
        try XCTUnwrap(frame.semantics, "the frame was read without its semantic snapshot").tree.visibleReadingOrder
    }

    /// The first node whose words are `label`.
    private static func node(_ label: String, in frame: DrawnFrame) throws -> NuxieNativeSemanticNode {
        let all = try nodes(frame)
        guard let found = all.first(where: { $0.label == label }) else {
            throw DrawnFrame.Missing(line: label, found: all.map(\.label))
        }
        return found
    }

    private static func center(of label: String, in frame: DrawnFrame) throws -> CGPoint {
        let bounds = try node(label, in: frame).bounds
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// The card named `name`'s own "More" or "Less": the one inside its
    /// root, which starts at its name.
    private static func detail(of name: String, in frame: DrawnFrame) throws
        -> (label: String, center: CGPoint)
    {
        let top = try node(name, in: frame).bounds.minY
        let all = try nodes(frame)
        guard let found = all.first(where: { node in
            (node.label == "More" || node.label == "Less")
                && node.bounds.midY > top && node.bounds.midY < top + cardHeight
        }) else {
            throw DrawnFrame.Missing(line: "\(name)'s More or Less", found: all.map(\.label))
        }
        return (found.label, CGPoint(x: found.bounds.midX, y: found.bounds.midY))
    }

    /// The cards read top to bottom are `order`, no other plan is read, and
    /// only the card `open` reads "Less".
    private static func expect(_ frame: DrawnFrame, order: [String], open: String?, _ what: String) throws {
        let cards = try nodes(frame).filter { plans.contains($0.label) }.sorted { $0.bounds.minY < $1.bounds.minY }
        XCTAssertEqual(cards.map(\.label), order, "\(what): the cards are read in another order")
        for name in order {
            let reads = try Self.detail(of: name, in: frame).label
            XCTAssertEqual(reads, name == open ? "Less" : "More", "\(what): \(name)'s own detail reads \(reads)")
        }
    }

    /// Three files: a root that keeps the plan last picked, a page whose
    /// list changes at each "Next", and a card with state of its own.
    private static func plan() -> NuxieMachinePlanSource {
        let main = """
        use Plans from "plans"

        component Picker
          platforms ios android

          state chosen = "none"

          entry
            on event "opened"
            do open

          routes
            plans  Plans(pick=pick)  cover

          action open
            go(plans)

          action pick(name: string)
            chosen = name
        """
        let plans = """
        use Card from "card"

        component Plans
          props
            pick: action(string)

          state stage = 0

          derive plans = (if stage == 0 then ["Yearly", "Monthly"] else (if stage == 1 then ["Lifetime", "Yearly", "Monthly"] else (if stage == 2 then ["Lifetime", "Monthly"] else ["Monthly", "Lifetime"])))

          action next
            stage = stage + 1

          view
            column gap=12 padding=24 background-color=#0d1214 id="page"
              column gap=8 id="plans"
                for name in plans key=name
                  Card(name=name, choose=pick(name))
              button press=next height=44 id="next"
                text "Next" color=#eef3f1 font-size=17
        """
        let card = """
        component Card
          props
            name: string
            choose: action

          state open = false

          action more
            open = not open

          view
            column gap=4 height=120 id="card"
              text name color=#eef3f1 font-size=17 id="name"
              button press=choose height=40 id="pick"
                text `Pick ${name}` color=#9fcdb9 font-size=16 id="pick_label"
              button press=more height=40 id="more"
                text (if open then "Less" else "More") color=#8a9794 font-size=16 id="detail"
        """
        return NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: main + "\n"),
                    NuxieMachineSourceFile(path: "plans.nux", text: plans + "\n"),
                    NuxieMachineSourceFile(path: "card.nux", text: card + "\n")],
            assets: [], root: "main", app: "app", experience: "rows", version: 1)
    }
}
#endif
