#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreGraphics
import Foundation
import Metal
import QuartzCore
import Vision
import XCTest
import NuxieMachine
import NuxieRuntime

/// The counter of `Fixtures/views-slice-1` on a simulator, with no window:
/// the edge draws the plan's own compiled view on the engine, and the
/// session's driver carries the machine inside each engine step. Real
/// pointers go in, frames are drawn with Metal and read back, and what they
/// show is read with text recognition, since compiled text has no other
/// reading yet. Frames are kept as attachments.
///
/// The view is a column: the count line, the line under `if noted`, a line
/// below it, then the buttons "Count", "Hide the note" and "Close".
final class CounterDriverEdgeTests: XCTestCase {
    fileprivate static let width = 390
    fileprivate static let height = 844
    fileprivate static let tick: Float = 1.0 / 60.0

    /// 1. The writes the presenting step made reach the engine in the
    ///    player's first step: the first frame drawn shows the starting
    ///    count, and the line under `if` is hidden. No write and no tap
    ///    crosses Swift.
    func testTheFirstFramesWritesLandInTheFirstStep() async throws {
        let run = try Counter(plan: Counter.counterPlan())
        do {
            await run.edge.start(event: "opened", now: run.now)
            let presented = await run.edge.log.compactMap { entry -> String? in
                if case .present(let route, _, .cover) = entry { return route }
                return nil
            }
            XCTAssertEqual(presented, ["counter"], "the start presents the counter as a cover")
            XCTAssertEqual(run.owner.reports.count, 1, "\(run.owner.reports)")
            try await run.layOut()

            let first = try await run.frame(after: [], name: "1-first-step")
            XCTAssertTrue(first.text.contains("Tapped 0 times"), "Recognized: \(first.text)")
            XCTAssertFalse(first.text.contains("You have counted"), "the line under if shows: \(first.text)")
            XCTAssertTrue(first.text.contains("This line sits below the note."), "Recognized: \(first.text)")
            try await run.expectNothingCrossedSwift()
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// 2. A tap on "Count" round-trips in one step: the engine reports it to
    ///    the driver, the machine steps, and its writes are drawn in the
    ///    frame of that same step: the count line changes, the line under
    ///    `if` shows and the line below it moves down. With nothing
    ///    happening after, the engine asks for no frame.
    func testATapRoundTripsInOneStep() async throws {
        let run = try Counter(plan: Counter.counterPlan())
        do {
            await run.edge.start(event: "opened", now: run.now)
            try await run.layOut()
            let first = try await run.frame(after: [], name: "1-first-step")
            let count = try first.center(of: "Count")
            let below = try first.box(of: "This line sits below the note.")

            let tapped = try await run.frame(after: run.tap(at: count), name: "2-tap-step")
            XCTAssertTrue(tapped.reported.contains("tap"), "the engine reported the tap: \(tapped.reported)")
            XCTAssertTrue(tapped.text.contains("Tapped 1 times"), "Recognized: \(tapped.text)")
            XCTAssertTrue(tapped.text.contains("You have counted at least once."), "Recognized: \(tapped.text)")
            let moved = try tapped.box(of: "This line sits below the note.")
            XCTAssertGreaterThan(moved.minY - below.minY, 16, "the line below moved down: \(below) to \(moved)")

            // With no input, the step's writes laid out, nothing asks for
            // another frame.
            var keepGoing = true
            for _ in 0..<4 {
                keepGoing = await run.edge.frame(elapsedSeconds: Self.tick, now: run.advance()).keepGoing
            }
            XCTAssertFalse(keepGoing, "the counter keeps asking for frames")

            // "Hide the note" takes it away, and the line below comes back.
            let settled = try await run.frame(after: [], name: "3-settled")
            let hidden = try await run.frame(after: run.tap(at: settled.center(of: "Hide the note")),
                                             name: "4-hide-step")
            XCTAssertFalse(hidden.text.contains("You have counted"), "Recognized: \(hidden.text)")
            let back = try hidden.box(of: "This line sits below the note.")
            XCTAssertEqual(back.minY, below.minY, accuracy: 1, "the line below came back")
            try await run.expectNothingCrossedSwift()
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// 3. A round that fails ends the session by its one fault path: a tap
    ///    whose write the records cannot carry (a color that is no color)
    ///    fails the step; the session's rows end in the dismissal and the
    ///    end in `engine.failed`; the edge stops with that fault, tells its
    ///    owner once, and closes the Screen.
    func testAFailedRoundEndsTheSessionByItsOneFaultPathAndTheEdgeClosesTheScreen() async throws {
        let run = try Counter(plan: Counter.spoilingPlan())
        do {
            await run.edge.start(event: "opened", now: run.now)
            try await run.layOut()
            let first = try await run.frame(after: [], name: "1-first-step")
            let spoil = try first.center(of: "Spoil the color")
            let written = await run.edge.log.count

            let stepped = await run.edge.frame(pointers: run.tap(at: spoil), elapsedSeconds: Self.tick,
                                               now: run.advance())
            let recorded = await run.edge.fault
            let fault = try XCTUnwrap(recorded, "the failed round stopped nothing")
            XCTAssertEqual(fault.code, "engine.failed")
            XCTAssertFalse(stepped.keepGoing)
            let ending = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(ending.filter { entry in
                if case .dismiss = entry { return true }
                if case .end = entry { return true }
                return false
            }, [.dismiss(reason: nil), .end(reason: .fault, fault: "engine.failed")])
            XCTAssertEqual(run.owner.reports.last, .fault(fault))
            XCTAssertEqual(run.owner.dismissals, [.fault(fault)], "the owner hears one dismissal, the fault")
            let screen = await run.edge.screen()
            XCTAssertNil(screen, "the edge closed the Screen")

            // A stopped edge steps nothing more.
            let after = await run.edge.frame(elapsedSeconds: Self.tick, now: run.advance())
            XCTAssertEqual(after.reported, [])
            XCTAssertEqual(run.owner.reports.count, 2, "\(run.owner.reports)")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }
}

// MARK: - A delivery outside a step

/// On the driver path the session holds a scene write until the presented
/// instance's next round, which runs inside a step, and only a frame
/// delivers a store's answer. So whatever leaves such work outside a frame
/// (a store's answer, a wake) must have the edge ask for one more frame,
/// and a Screen at rest has nothing waiting for one. Each check here runs
/// frames the way the Screen's view does: when the edge asks, and while the
/// engine's step keeps going; nothing else.
final class DriverStepOwedEdgeTests: XCTestCase {
    /// A purchase the stand-in store fails, answered after the view has
    /// settled: the error line shows with no touch.
    func testAStoreAnswerThatChangesASettledViewIsDrawnWithNoTouch() async throws {
        let run = try Counter(plan: Counter.answeredPlan())
        do {
            await run.edge.start(event: "opened", now: run.now)
            try await run.layOut()
            let first = try await run.frame(after: [], name: "1-first-step")
            XCTAssertFalse(first.text.contains("did not go through"), "Recognized: \(first.text)")

            // "Buy" starts the purchase; the host steps while the edge asks.
            let buy = run.tap(at: try first.center(of: "Buy"))
            let bought = await run.edge.frame(pointers: buy, elapsedSeconds: CounterDriverEdgeTests.tick,
                                              now: run.advance())
            let called = await run.edge.log.contains { if case .call = $0 { return true }; return false }
            XCTAssertTrue(called, "the purchase was not started")
            try await run.settle(another: bought.keepGoing)

            let settled = try await run.look(name: "2-settled-after-the-answer")
            XCTAssertTrue(settled.text.contains("The purchase did not go through."), "Recognized: \(settled.text)")
            try await run.expectAtRest()
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A wake that changes the view's text after it has settled: the new
    /// text shows with no touch.
    func testAWakeThatChangesASettledViewIsDrawnWithNoTouch() async throws {
        let run = try Counter(plan: Counter.eveningPlan())
        do {
            await run.edge.start(event: "opened", now: run.now)
            try await run.layOut()
            let first = try await run.frame(after: [], name: "1-first-step")
            XCTAssertTrue(first.text.contains("Not evening yet."), "Recognized: \(first.text)")
            try await run.settle(another: true)
            try await run.expectAtRest()

            let log = await run.edge.log
            let asked = log.compactMap { entry -> Int64? in
                if case .wakeAt(let moment?) = entry { return moment }
                return nil
            }
            let moment = try XCTUnwrap(asked.last, "the record asked for no wake: \(log)")
            run.jump(to: moment)
            await run.edge.wake(now: moment)
            try await run.afterDelivery()

            let woken = try await run.look(name: "2-settled-after-the-wake")
            XCTAssertTrue(woken.text.contains("It is evening."), "Recognized: \(woken.text)")
            try await run.expectAtRest()
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A wake on a settled view starts a purchase. The store answers with
    /// no frame running, and only a frame delivers an answer: the record
    /// takes it and the view shows the failure, with no touch.
    func testAWakeThatStartsAPurchaseOnAPresentedViewMovesTheRecordOnWithNoTouch() async throws {
        let run = try Counter(plan: Counter.wakePurchasePlan(presentsFirst: true))
        do {
            await run.edge.start(event: "opened", now: run.now)
            try await run.layOut()
            let first = try await run.frame(after: [], name: "1-first-step")
            XCTAssertTrue(first.text.contains("Not evening yet."), "Recognized: \(first.text)")
            try await run.afterDelivery()
            try await run.expectAtRest()

            let moment = try await run.wakeAsked()
            run.jump(to: moment)
            await run.edge.wake(now: moment)
            try await run.afterDelivery()

            let failed = try await run.edge.slot("failed")
            XCTAssertEqual(failed, .bool(true), "the store's answer never reached the record")
            let shown = try await run.look(name: "2-settled-after-the-answer")
            XCTAssertTrue(shown.text.contains("The purchase did not go through."), "Recognized: \(shown.text)")
            try await run.expectAtRest()
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// The same with nothing presented: the record waits with no view, the
    /// wake starts a purchase, and the answer, delivered at a frame no
    /// touch asked for, presents the view with the failure.
    func testAWakeThatStartsAPurchaseWithNothingPresentedMovesTheRecordOnWithNoTouch() async throws {
        let run = try Counter(plan: Counter.wakePurchasePlan(presentsFirst: false))
        do {
            await run.edge.start(event: "opened", now: run.now)
            try await run.afterDelivery()
            let nothing = await run.edge.screen()
            XCTAssertNil(nothing, "the start presents nothing")
            try await run.expectAtRest()

            let moment = try await run.wakeAsked()
            run.jump(to: moment)
            await run.edge.wake(now: moment)
            try await run.afterDelivery()

            let failed = try await run.edge.slot("failed")
            XCTAssertEqual(failed, .bool(true), "the store's answer never reached the record")
            let route = try await run.edge.topRoute()
            XCTAssertEqual(route?.route, "clock", "the answer presented the view")
            try await run.expectAtRest()
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }
}

// MARK: - One run

/// A fresh session on the driver path, its clock, and what its owner heard.
private final class Counter {
    let edge: NuxieMachineEdge
    let owner = CounterOwner()
    private(set) var now: Int64 = 9 * 3_600_000
    private var drawn = 0

    /// The edge's asks for a frame, as a Screen's view hears them.
    let asks: FrameAskCount

    init(plan: NuxieMachinePlanSource) throws {
        let owner = self.owner
        edge = try NuxieMachineEdge(plan: plan, store: NuxieMachineStandInStore(), onReport: { owner.heard($0) })
        asks = FrameAskCount(edge)
    }

    func advance() -> Int64 {
        now += 1000
        return now
    }

    /// Lay the presented Screen out at a phone's size in points and size
    /// its renderer for a frame drawn at twice that, as a Screen's view
    /// does before its first step.
    func layOut() async throws {
        let screen = try await presented()
        try await screen.setLayoutSize(width: Float(CounterDriverEdgeTests.width),
                                       height: Float(CounterDriverEdgeTests.height))
        _ = try await screen.resize(pixelWidth: UInt32(2 * CounterDriverEdgeTests.width),
                                    pixelHeight: UInt32(2 * CounterDriverEdgeTests.height))
    }

    /// A press and release at `point`, in one step.
    func tap(at point: CGPoint) -> [NuxieNativePointerEvent] {
        [.down, .up].map { NuxieNativePointerEvent(kind: $0, x: Float(point.x), y: Float(point.y)) }
    }

    /// One frame with `pointers`, then the Screen drawn as that step left
    /// it, read back and read with text recognition.
    func frame(after pointers: [NuxieNativePointerEvent], name: String) async throws -> DrawnFrame {
        let stepped = await edge.frame(pointers: pointers, elapsedSeconds: CounterDriverEdgeTests.tick, now: advance())
        let fault = await edge.fault
        XCTAssertNil(fault, "the frame faulted")
        drawn += 1
        return try await DrawnFrame.read(presented(), reported: stepped.reported, name: "counter-\(drawn)-\(name)")
    }

    /// No write landed in a cell and no event was handed to the session by
    /// Swift: the engine and the session met only inside the step.
    func expectNothingCrossedSwift() async throws {
        let log = await edge.log
        let crossed = log.filter { entry in
            if case .write = entry { return true }
            if case .reported = entry { return true }
            return false
        }
        XCTAssertEqual(crossed, [], "Swift carried \(crossed)")
    }

    func close() async throws {
        try await edge.close()
    }

    /// Move the clock to `moment`, as a host does before delivering a wake.
    func jump(to moment: Int64) {
        now = max(now, moment)
    }

    /// Frames with no touch, run the way the Screen's view runs them: for
    /// each ask the edge made, and while the engine's step keeps going.
    /// `another` is whether the engine's last step asked to keep going.
    func settle(another first: Bool) async throws {
        try await settleAsAView(edge, asks: asks, keepGoing: first, onScreen: true,
                                now: { self.advance() }, elapsedSeconds: CounterDriverEdgeTests.tick)
    }

    /// What a Screen's view does after a delivery of its own (a start, a
    /// wake): nothing, unless the edge asks.
    func afterDelivery() async throws {
        try await settle(another: false)
    }

    /// The moment the record last asked to be woken at.
    func wakeAsked() async throws -> Int64 {
        let log = await edge.log
        let asked = log.compactMap { entry -> Int64? in
            if case .wakeAt(let moment?) = entry { return moment }
            return nil
        }
        return try XCTUnwrap(asked.last, "the record asked for no wake: \(log)")
    }

    /// The presented Screen drawn as it is, with no step.
    func look(name: String) async throws -> DrawnFrame {
        drawn += 1
        return try await DrawnFrame.read(presented(), reported: [], name: "counter-\(drawn)-\(name)")
    }

    /// At rest: nothing only a frame consumes waits (no step owed, no answer
    /// to deliver), and no ask is left unanswered.
    func expectAtRest() async throws {
        let waiting = await edge.waitingForFrame()
        XCTAssertFalse(waiting, "the Screen is at rest with work waiting for a frame")
        XCTAssertFalse(asks.take(), "the Screen is at rest with an ask unanswered")
    }

    private func presented() async throws -> NuxieNativeRuntime {
        let screen = await edge.screen()
        return try XCTUnwrap(screen, "nothing is presented")
    }

    /// The counter's two files, as the host app bundles them.
    static func counterPlan() throws -> NuxieMachinePlanSource {
        func text(_ name: String) throws -> String {
            let url = try XCTUnwrap(Bundle(for: Counter.self).url(
                forResource: name, withExtension: "nux", subdirectory: "views-slice-1"),
                "the test bundle carries views-slice-1/\(name).nux")
            return try String(contentsOf: url, encoding: .utf8)
        }
        return NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: try text("main")),
                    NuxieMachineSourceFile(path: "counter.nux", text: try text("counter"))],
            root: "main", app: "app", experience: "tally", version: 1)
    }

    /// A paywall whose "Buy" starts a purchase; the stand-in store fails it,
    /// and the failure shows a line under `if`.
    static func answeredPlan() -> NuxieMachinePlanSource {
        let main = """
        use products, purchase, store from "nuxie/store"
        use Paywall from "paywall"

        enum Plan annual

        component Upgrade
          platforms ios android

          derive catalog = products(Plan,
            annual = store(ios="app.pro.yearly", android="pro:yearly"))

          state failed = false

          entry
            on event "opened"
            do start

          routes
            paywall  Paywall(failed=failed, buy=buy, close=close)  cover

          action start
            go(paywall)

          action buy
            failed = false
            purchase(catalog[annual], completed=close, failed=mark_failed)

          action mark_failed
            failed = true

          action close
            dismiss("closed")
            exit
        """
        let paywall = """
        component Paywall
          props
            failed: boolean
            buy: action
            close: action

          view
            column padding=24 gap=12 background-color=#0d1214
              text "Go further" color=#eef3f1 font-size=24 id="title"
              if failed
                text "The purchase did not go through." color=#e8a598 font-size=16 id="error"
              button padding=12 background-color=#232c30 press=buy id="buy"
                text "Buy" color=#eef3f1 font-size=16
              button padding=12 press=close id="close"
                text "Close" color=#8a9794 font-size=16
        """
        return NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: main + "\n"),
                    NuxieMachineSourceFile(path: "paywall.nux", text: paywall + "\n")],
            root: "main", app: "app", experience: "upgrade", version: 1)
    }

    /// A line of text the record changes when its evening wait comes due.
    static func eveningPlan() -> NuxieMachinePlanSource {
        let main = """
        use Clock from "clock"

        component Evening
          platforms ios android

          state armed = false
          state line = "Not evening yet."

          entry
            on event "opened"
            do start

          routes
            clock  Clock(line=line, close=close)  cover

          action start
            armed = true
            go(clock)

          wait evening
            while armed
            until next 18:00
            then ring within 6h
            else give_up

          action ring
            armed = false
            line = "It is evening."

          action give_up
            armed = false
            exit

          action close
            dismiss("closed")
            exit
        """
        let clock = """
        component Clock
          props
            line: string
            close: action

          view
            column padding=24 gap=12 background-color=#0d1214
              text line color=#eef3f1 font-size=24 id="line"
              button padding=12 press=close id="close"
                text "Close" color=#8a9794 font-size=16
        """
        return NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: main + "\n"),
                    NuxieMachineSourceFile(path: "clock.nux", text: clock + "\n")],
            root: "main", app: "app", experience: "evening", version: 1)
    }

    /// A record that waits for the evening, then starts a purchase there;
    /// the stand-in store fails it, and the failure changes the line. With
    /// `presentsFirst` the start presents the view; without it the record
    /// waits with nothing presented and the failure presents it.
    static func wakePurchasePlan(presentsFirst: Bool) -> NuxieMachinePlanSource {
        let main = """
        use products, purchase, store from "nuxie/store"
        use Clock from "clock"

        enum Plan annual

        component Evening
          platforms ios android

          derive catalog = products(Plan,
            annual = store(ios="app.pro.yearly", android="pro:yearly"))

          state armed = false
          state failed = false
          state line = "Not evening yet."

          entry
            on event "opened"
            do start

          routes
            clock  Clock(line=line, close=close)  cover

          action start
            armed = true
        \(presentsFirst ? "    go(clock)\n" : "")
          wait evening
            while armed
            until next 18:00
            then ring within 6h
            else give_up

          action ring
            armed = false
            purchase(catalog[annual], completed=close, failed=mark_failed)

          action mark_failed
            failed = true
            line = "The purchase did not go through."
        \(presentsFirst ? "" : "    go(clock)\n")
          action give_up
            armed = false
            exit

          action close
            dismiss("closed")
            exit
        """
        let clock = """
        component Clock
          props
            line: string
            close: action

          view
            column padding=24 gap=12 background-color=#0d1214
              text line color=#eef3f1 font-size=24 id="line"
              button padding=12 press=close id="close"
                text "Close" color=#8a9794 font-size=16
        """
        return NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: main + "\n"),
                    NuxieMachineSourceFile(path: "clock.nux", text: clock + "\n")],
            root: "main", app: "app", experience: "evening", version: 1)
    }

    /// A component whose button writes a color the records cannot carry.
    static func spoilingPlan() -> NuxieMachinePlanSource {
        let main = """
        use Paint from "paint"

        component Spoiled
          platforms ios android

          entry
            on event "opened"
            do open

          routes
            paint  Paint(close=close)  cover

          action open
            go(paint)

          action close
            dismiss("closed")
            exit
        """
        let paint = """
        component Paint
          props
            close: action

          state shade = "#232c30"

          action spoil
            shade = "not a color"

          view
            column padding=24 gap=12 background-color=#0d1214
              button padding=12 background-color=shade press=spoil id="spoil"
                text "Spoil the color" color=#eef3f1 font-size=16
              button padding=12 press=close id="close"
                text "Close" color=#8a9794 font-size=16
        """
        return NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: main + "\n"),
                    NuxieMachineSourceFile(path: "paint.nux", text: paint + "\n")],
            root: "main", app: "app", experience: "spoiled", version: 1)
    }
}

/// The edge's owner: the reports it was told, one per delivery that did
/// something for it.
private final class CounterOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var heardReports: [NuxieMachineEdgeReport] = []

    var reports: [NuxieMachineEdgeReport] {
        lock.withLock { heardReports }
    }

    var dismissals: [NuxieMachineEdgeDismissal] {
        reports.compactMap(\.dismissal)
    }

    func heard(_ report: NuxieMachineEdgeReport) {
        lock.withLock { heardReports.append(report) }
    }
}

// MARK: - Reading a frame

/// One frame drawn at twice the layout size, and the lines text recognition
/// found in it, with their boxes in layout points.
private struct DrawnFrame {
    let reported: [String]
    let lines: [(text: String, box: CGRect)]

    var text: String { lines.map(\.text).joined(separator: " ") }

    struct Missing: Error, CustomStringConvertible {
        let line: String
        let found: [String]
        var description: String { "no line \"\(line)\" among \(found)" }
    }

    func box(of line: String) throws -> CGRect {
        guard let found = lines.first(where: { $0.text == line }) else {
            throw Missing(line: line, found: lines.map(\.text))
        }
        return found.box
    }

    func center(of line: String) throws -> CGPoint {
        let found = try box(of: line)
        return CGPoint(x: found.midX, y: found.midY)
    }

    static func read(_ runtime: NuxieNativeRuntime, reported: [String], name: String) async throws -> DrawnFrame {
        let scale = 2
        let width = CounterDriverEdgeTests.width * scale
        let height = CounterDriverEdgeTests.height * scale
        let pixels = try await render(runtime, width: width, height: height, scale: Float(scale))
        try await Pixels.attach(pixels, width: width, height: height, name: name)
        let image = try XCTUnwrap(image(pixels, width: width, height: height))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            // Vision's box is normalized with its origin at the bottom left.
            let box = observation.boundingBox
            return (text, CGRect(x: box.minX * CGFloat(CounterDriverEdgeTests.width),
                                 y: (1 - box.maxY) * CGFloat(CounterDriverEdgeTests.height),
                                 width: box.width * CGFloat(CounterDriverEdgeTests.width),
                                 height: box.height * CGFloat(CounterDriverEdgeTests.height)))
        }
        return DrawnFrame(reported: reported, lines: lines)
    }

    private static func render(_ runtime: NuxieNativeRuntime, width: Int, height: Int, scale: Float) async throws
        -> Data
    {
        let device = try await runtime.metalDevice().value
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: width, height: height)
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        guard let drawable = layer.nextDrawable() else {
            throw XCTSkip("This host cannot vend a CAMetalDrawable")
        }
        let bytesPerRow = (width * 4 + 255) & ~255
        let buffer = try XCTUnwrap(device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared))
        let drawn = Signal()
        let outcome = try await runtime.render(layoutScaleFactor: scale,
            drawable: .available(NuxieNativeDrawable(drawable)), clearColor: 0xFF00_0000,
            readback: NuxieNativeFrameReadback(buffer: buffer, bytesPerRow: bytesPerRow),
            completion: { drawn.fire() })
        try await drawn.wait(seconds: 2)
        XCTAssertEqual(outcome.disposition, .presented)
        let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var pixels = Data(capacity: width * height * 4)
        for row in 0..<height {
            pixels.append(source + row * bytesPerRow, count: width * 4)
        }
        return pixels
    }

    private static func image(_ pixels: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
#endif
