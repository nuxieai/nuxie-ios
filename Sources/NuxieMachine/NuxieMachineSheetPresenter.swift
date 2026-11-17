#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import os
import UIKit

/// What a host can show about the record a presenter runs.
package struct NuxieMachineSheetStatus: Equatable, Sendable {
    package enum Record: Equatable, Sendable {
        /// No record has started.
        case notStarted
        /// The record is open, and asks for a wake at this moment (milliseconds
        /// since the Unix epoch) or at none.
        case open(wakeAt: Int64?)
        /// The record ended normally.
        case ended
        /// A fault stopped everything, with its code.
        case fault(String)
    }

    /// The record's root slot `plan`, as last read: an enum value's name.
    package var plan: String?
    package var record: Record

    package init(plan: String?, record: Record) {
        self.plan = plan
        self.record = record
    }
}

/// Does what the machine's rows say with UIKit, for one edge and its Screen.
///
/// - `present` with the sheet presentation presents the Screen as a native
///   sheet at the large detent, from the host's view controller. Any other
///   presentation is a fault: push and the rest are not built.
/// - `dismiss` dismisses the sheet; a `pop` of the presented instance does
///   too.
/// - A swipe down by the person is the native dismissal: the presenter tells
///   the edge `closed` for the showing it presented, and logs what the
///   machine answers.
/// - `wake at` sets a timer that delivers `wake` if the app is still running
///   at that moment. A later `wake at` replaces it, and the record's end
///   cancels it. The machine takes a wake only at the moment it asked for,
///   and no event earlier than its last, so a due wake is delivered at its
///   own moment before any frame or close that comes after it, and a timer
///   that fires late (the app was suspended) catches up one wake at a time.
///   Waits that outlive the app are not built.
/// - `end` stops the loop, cancels the timer and releases the session.
/// - Every fault takes one path ([`fail`]): the sheet is dismissed, the code
///   is logged, and everything stops.
///
/// The presenter reads what the edge did from its log, in order, after each
/// delivery it asks for and after each frame. Rows can arrive after the sheet
/// is gone (a purchase answered after a swipe down): they have nothing to
/// draw into and are no fault.
@MainActor
package final class NuxieMachineSheetPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
    /// What the host shows, after every change.
    package private(set) var status = NuxieMachineSheetStatus(plan: nil, record: .notStarted) {
        didSet {
            guard status != oldValue else { return }
            controller?.statusText = Self.describe(status)
            onStatus(status)
        }
    }

    private weak var host: UIViewController?
    private let onStatus: @MainActor (NuxieMachineSheetStatus) -> Void
    private var controller: NuxieMachineScreenViewController?
    /// How many of the edge's log entries have been read.
    private var cursor = 0
    /// How many `present` rows the edge has applied: the edge numbers its
    /// showings the same way.
    private var showings: UInt64 = 0
    /// The showing whose sheet is up.
    private var presented: NuxieMachineShown?
    private var wakeAt: Int64?
    private var wakeTimer: Timer?
    private var started = false
    private var finished = false
    private let logger = Logger(subsystem: "io.nuxie.sdk", category: "NuxieMachine")

    /// A presenter that presents from `host` and tells `onStatus` what the
    /// host can show.
    package init(host: UIViewController, onStatus: @escaping @MainActor (NuxieMachineSheetStatus) -> Void) {
        self.host = host
        self.onStatus = onStatus
        super.init()
    }

    /// Compile the plan, open the Screen, and start a record on `event`.
    /// What the machine says to present opens as a sheet. A presenter starts
    /// once.
    package func start(
        plan: NuxieMachinePlanSource,
        screen: NuxieMachineScreenSource,
        store: any NuxieMachineStore,
        event: String
    ) async {
        guard !started else { return }
        started = true
        let edge: NuxieMachineEdge
        do {
            // Dismissals are read from the edge's log in order with every
            // other row; a fault is read from the edge itself.
            edge = try await NuxieMachineEdge(plan: plan, screen: screen, store: store, onDismiss: { _ in })
        } catch {
            let fault = error as? NuxieMachineEdgeFault
                ?? NuxieMachineEdgeFault(code: "edge.open", detail: "\(error)")
            fail(fault)
            return
        }
        let controller = NuxieMachineScreenViewController(edge: edge)
        controller.beforeFrame = { [weak self] now in await self?.catchUp(to: now) }
        controller.onFrame = { [weak self] _ in await self?.read() }
        controller.onFault = { [weak self] fault in self?.fail(fault) }
        controller.statusText = Self.describe(status)
        self.controller = controller
        logger.info("machine.start \(event, privacy: .public)")
        await edge.start(event: event, now: nuxieMachineNow())
        await read()
        guard !finished else { return }
        controller.start()
    }

    // MARK: Reading the edge

    /// Act on what the edge did since the last read, in order, then on a
    /// fault that stopped it.
    private func read() async {
        guard let controller, !finished else { return }
        let edge = controller.edge
        let log = await edge.log
        guard !finished, log.count > cursor else { return }
        let entries = log[cursor...]
        cursor = log.count
        for entry in entries where !finished {
            act(on: entry)
        }
        guard !finished else { return }
        if let fault = await edge.fault {
            fail(fault)
            return
        }
        if case .open = status.record, let plan = try? await edge.slot("plan") {
            status.plan = Self.name(plan)
        }
    }

    private func act(on entry: NuxieMachineEdgeEntry) {
        switch entry {
        case .present(let route, let instance, let presentation):
            showings += 1
            let shown = NuxieMachineShown(showing: showings, instance: instance)
            guard presentation == .sheet else {
                fail(NuxieMachineEdgeFault(code: "edge.unsupported-presentation",
                    detail: "present \(route) as \(presentation); only a sheet is built"))
                return
            }
            presentSheet(shown)
            status.record = .open(wakeAt: wakeAt)
        case .pop(let instance):
            logger.info("machine.pop \(instance)")
            dismissSheet()
        case .dismiss(let reason):
            logger.info("machine.dismiss \(reason ?? "", privacy: .public)")
            dismissSheet()
        case .wakeAt(let moment):
            setWake(moment)
        case .end(let reason, let fault):
            logger.info("machine.end \(String(describing: reason), privacy: .public) \(fault ?? "", privacy: .public)")
            // A record that ended in a fault takes the fault path, read from
            // the edge after the entries.
            if reason == .finished || reason == .exited { finish(.ended) }
        case .note(let note):
            logger.debug("machine.note \(String(describing: note), privacy: .public)")
        case .call(let call):
            logger.debug("machine.call \(call.externName, privacy: .public)")
        case .answer(_, let outcome):
            logger.debug("machine.answer \(outcome, privacy: .public)")
        case .dropped(_, let outcome):
            logger.debug("machine.dropped-answer \(outcome ?? "", privacy: .public)")
        case .droppedReport(let name):
            logger.debug("machine.dropped-event \(name, privacy: .public)")
        case .droppedClose(let shown):
            logger.debug("machine.dropped-close \(shown.showing)")
        case .reported, .write:
            break
        }
    }

    // MARK: The sheet

    private func presentSheet(_ shown: NuxieMachineShown) {
        guard let controller, let host, host.viewIfLoaded?.window != nil, host.presentedViewController == nil else {
            fail(NuxieMachineEdgeFault(code: "edge.no-host",
                detail: "nothing can present the sheet: the host is gone, off screen or already presenting"))
            return
        }
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false
        }
        controller.presentationController?.delegate = self
        presented = shown
        host.present(controller, animated: true)
        controller.requestFrame()
    }

    /// Dismiss the sheet if it is up. The machine's own dismissal, or a
    /// fault's: neither tells the edge `closed`.
    private func dismissSheet() {
        presented = nil
        guard let controller, controller.presentingViewController != nil, !controller.isBeingDismissed else { return }
        controller.dismiss(animated: true)
    }

    /// The person swiped the sheet down: the machine hears `closed` for the
    /// showing that was up, and its answer is read and logged.
    package func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let closing = presented, let controller else { return }
        presented = nil
        logger.info("machine.closed \(closing.showing)")
        Task { @MainActor [weak self] in
            let now = nuxieMachineNow()
            await self?.catchUp(to: now)
            await controller.edge.closed(closing, now: now)
            await self?.read()
            controller.requestFrame()
        }
    }

    // MARK: Waking

    private func setWake(_ moment: Int64?) {
        wakeTimer?.invalidate()
        wakeTimer = nil
        wakeAt = moment
        if case .open = status.record { status.record = .open(wakeAt: moment) }
        guard let moment else { return }
        logger.info("machine.wake-at \(moment)")
        let timer = Timer(fire: Date(timeIntervalSince1970: Double(moment) / 1000), interval: 0, repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                await self?.deliverWake(at: moment)
                await self?.catchUp(to: nuxieMachineNow())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        wakeTimer = timer
    }

    /// Deliver every wake the record asks for at or before `now`, each at
    /// its own moment, oldest first.
    private func catchUp(to now: Int64) async {
        while !finished, let moment = wakeAt, moment <= now {
            await deliverWake(at: moment)
        }
    }

    /// Deliver the wake at `moment` if the record still asks for it.
    private func deliverWake(at moment: Int64) async {
        guard let controller, !finished, wakeAt == moment else { return }
        wakeTimer?.invalidate()
        wakeTimer = nil
        wakeAt = nil
        if case .open = status.record { status.record = .open(wakeAt: nil) }
        logger.info("machine.wake \(moment)")
        await controller.edge.wake(now: moment)
        await read()
        controller.requestFrame()
    }

    // MARK: Ending

    /// The one path for faults: the sheet is dismissed, the code is logged,
    /// and everything stops.
    private func fail(_ fault: NuxieMachineEdgeFault) {
        guard !finished else { return }
        logger.error("machine.fault \(fault.code, privacy: .public): \(fault.detail, privacy: .public)")
        finish(.fault(fault.code))
    }

    /// Stop the loop, cancel the timer, dismiss the sheet if it is still up,
    /// and release the session.
    private func finish(_ record: NuxieMachineSheetStatus.Record) {
        guard !finished else { return }
        finished = true
        wakeTimer?.invalidate()
        wakeTimer = nil
        wakeAt = nil
        status.record = record
        dismissSheet()
        guard let controller else { return }
        controller.stop()
        self.controller = nil
        Task { try? await controller.edge.close() }
    }

    // MARK: Words

    private static func name(_ value: NuxieMachineValue) -> String {
        switch value {
        case .bool(let yes): yes ? "true" : "false"
        case .number(let number): "\(number)"
        case .text(let text), .enumeration(let text): text
        }
    }

    /// The status in two short sentences, as the Screen's accessibility value.
    package static func describe(_ status: NuxieMachineSheetStatus) -> String {
        "Selected plan: \(status.plan ?? "none"). Record: \(describe(status.record))."
    }

    /// The record's state in words: open, with its wake moment when one is
    /// set, ended, or the fault's code.
    package static func describe(_ record: NuxieMachineSheetStatus.Record) -> String {
        switch record {
        case .notStarted: "not started"
        case .open(nil): "open"
        case .open(let moment?):
            "open, wakes at " + Date(timeIntervalSince1970: Double(moment) / 1000).ISO8601Format()
        case .ended: "ended"
        case .fault(let code): "fault \(code)"
        }
    }
}
#endif
