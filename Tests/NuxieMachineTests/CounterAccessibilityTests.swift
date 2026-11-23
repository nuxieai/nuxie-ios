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
/// leaves its pointers for the next frame, which the test hands to the edge
/// as the loop would.
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

    /// 2. Activating a button is a tap: a press and release at its center,
    ///    through the pointer path a touch takes, so the engine reports the
    ///    same `tap` and the machine counts. The count line is the same
    ///    element read anew, the note appears below it, and "Hide the note"
    ///    takes it away again.
    @MainActor
    func testActivatingAButtonIsATapAndTheCountLineFollows() async throws {
        let reader = try await Reader.open(Counter.counterPlan(), name: "counter")
        do {
            _ = try await reader.frame(name: "1-first")
            let line = try reader.element("Tapped 0 times")
            let count = try reader.element("Count")
            XCTAssertTrue(count.accessibilityActivate(), "Count activates")
            let pointers = reader.controller.takePointers()
            XCTAssertEqual(pointers.map(\.kind), [.down, .up])
            let center = CGPoint(x: reader.onScreen(count).midX - reader.origin.x,
                                 y: reader.onScreen(count).midY - reader.origin.y)
            for pointer in pointers {
                XCTAssertEqual(CGFloat(pointer.x), center.x, accuracy: 0.5)
                XCTAssertEqual(CGFloat(pointer.y), center.y, accuracy: 0.5)
            }
            XCTAssertEqual(Set(pointers.map(\.pointerID)).count, 1, "one pointer presses and lets go")

            let tapped = try await reader.frame(pointers: pointers, name: "2-count-activated")
            XCTAssertTrue(tapped.reported.contains("tap"), "the engine reported the tap: \(tapped.reported)")
            XCTAssertEqual(Array(reader.read.prefix(4)), [
                .text("Tapped 1 times"), .text("You have counted at least once."),
                .text("This line sits below the note."), .button("Count"),
            ])
            XCTAssertTrue(try reader.element("Tapped 1 times") === line, "the count line is the same element")
            XCTAssertTrue(try reader.element("Count") === count, "the button is the same element")

            XCTAssertTrue(try reader.element("Hide the note").accessibilityActivate())
            _ = try await reader.frame(pointers: reader.controller.takePointers(), name: "3-hide-activated")
            XCTAssertEqual(Array(reader.read.prefix(3)), [
                .text("Tapped 1 times"), .text("This line sits below the note."), .button("Count"),
            ])
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// 3. A button the machine disables is read as not enabled in the step
    ///    that disables it, and activating it does nothing: no pointer goes
    ///    out. A real press on it is held back by the engine.
    @MainActor
    func testADisabledButtonIsNotEnabledAndItsActivationDoesNothing() async throws {
        let reader = try await Reader.open(Self.holdPlan, name: "hold")
        do {
            _ = try await reader.frame(name: "1-first")
            let hold = try reader.element("Hold")
            XCTAssertFalse(hold.accessibilityTraits.contains(.notEnabled))
            XCTAssertTrue(hold.accessibilityActivate())
            let held = try await reader.frame(pointers: reader.controller.takePointers(), name: "2-held")
            XCTAssertTrue(held.reported.contains("tap"), "the engine reported the tap: \(held.reported)")
            XCTAssertEqual(reader.read, [.text("Held 1 times"), .button("Hold"), .button("Close")])
            XCTAssertTrue(hold.accessibilityTraits.contains(.notEnabled), "disabled in the step that held it")

            XCTAssertFalse(hold.accessibilityActivate(), "a disabled button does not activate")
            XCTAssertEqual(reader.controller.takePointers(), [], "nothing went out")
            let frame = reader.onScreen(hold)
            let center = CGPoint(x: frame.midX - reader.origin.x, y: frame.midY - reader.origin.y)
            let pressed = try await reader.frame(pointers: [.down, .up].map {
                NuxieNativePointerEvent(kind: $0, x: Float(center.x), y: Float(center.y), pointerID: 1)
            }, name: "3-pressed")
            XCTAssertFalse(pressed.reported.contains("tap"), "the engine held the press back: \(pressed.reported)")
            XCTAssertEqual(reader.read.first, .text("Held 1 times"))
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    /// 4. A Screen under another presentation takes no activation. The
    ///    cover's "Count" element, kept from before, is activated once a
    ///    sheet has started to arrive over it and again while the sheet is
    ///    up: nothing is sent and the count stays. Once the sheet starts to
    ///    leave, the same element counts again. Reach follows the
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
            XCTAssertEqual(reader.controller.takePointers(), [], "nothing went out as the sheet arrives")
            _ = state.handle(.presented(sheet.shown))
            reader.reach(state)
            XCTAssertFalse(count.accessibilityActivate(), "a button under a sheet does not activate")
            XCTAssertEqual(reader.controller.takePointers(), [], "nothing went out under the sheet")
            _ = try await reader.frame(name: "2-covered")
            XCTAssertEqual(reader.read.first, .text("Tapped 0 times"), "the count did not change")

            XCTAssertEqual(state.handle(.report(.delivered(shown: [cover], rows: []))), [.dismiss(sheet.shown)])
            reader.reach(state)
            XCTAssertTrue(reader.controller.reachable, "the cover is in reach again as the sheet leaves")
            XCTAssertTrue(count.accessibilityActivate(), "the same button activates again")
            let tapped = try await reader.frame(pointers: reader.controller.takePointers(), name: "3-uncovered")
            XCTAssertTrue(tapped.reported.contains("tap"), "the engine reported the tap: \(tapped.reported)")
            XCTAssertEqual(reader.read.first, .text("Tapped 1 times"))
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
        root: "main", app: "app", experience: "holding", version: 1)
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

    static func open(_ plan: NuxieMachinePlanSource, name: String) async throws -> Reader {
        let run = try Counter(plan: plan)
        await run.edge.start(event: "opened", now: run.now)
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

    /// One frame with `pointers` on the top presentation, drawn, and its
    /// semantic snapshot shown by the controller.
    func frame(pointers: [NuxieNativePointerEvent] = [], name step: String) async throws -> DrawnFrame {
        let touched = await run.edge.shown
        let stepped = await run.edge.frame(pointers: pointers, on: touched,
                                           elapsedSeconds: CounterDriverEdgeTests.tick, now: run.advance())
        let fault = await run.edge.fault
        XCTAssertNil(fault, "the frame faulted")
        let screen = await run.edge.screen()
        let runtime = try XCTUnwrap(screen, "nothing is presented")
        drawn += 1
        let frame = try await DrawnFrame.read(runtime, reported: stepped.reported, name: "\(name)-\(drawn)-\(step)",
                                              size: surface.bounds.size, capturesSemantics: true)
        controller.show(try XCTUnwrap(frame.semantics, "the frame has no semantic snapshot"))
        return frame
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

    func close() async throws {
        loop.stop()
        try await run.edge.close()
        withExtendedLifetime(window) {}
    }
}
#endif
