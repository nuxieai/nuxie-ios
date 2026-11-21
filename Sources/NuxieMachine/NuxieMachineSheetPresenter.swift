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
///   sheet at the large detent, from the host's view controller, and with
///   the cover presentation as a native cover over the whole screen, which
///   has no swipe. Any other presentation is a fault: push and the rest are
///   not built.
/// - `dismiss` dismisses the sheet; a `pop` of the presented showing does
///   too.
/// - A swipe down by the person is the native dismissal: the presenter tells
///   the edge `closed` for the showing the swipe took, and logs what the
///   machine answers.
/// - `wake at` sets a timer that delivers `wake` if the app is still running
///   at that moment. A later `wake at` replaces it, and the record's end
///   cancels it. The machine takes a wake only at the moment it asked for,
///   and no event earlier than its last, so a due wake is delivered at its
///   own moment before any frame or close that comes after it, and a timer
///   that fires late (the app was suspended) catches up one wake at a time.
///   Waits that outlive the app are not built.
/// - `end` stops the loop, cancels the timer and closes the edge.
/// - Every fault takes one path: the sheet is dismissed, the code is logged,
///   and everything stops.
///
/// What the presenter owns has one end of life. The Screen with its edge
/// and session, the wake timer and the display loop are let go of exactly
/// once, when the state says `release`: the record is ended or faulted and
/// no sheet is on screen or in a transition. An open record keeps them all,
/// with no sheet too (waiting for its wake after "Not now"). The presenter
/// lets go at once, and work already in the Screen's lane (the edge's
/// close among it) holds what it uses until it is over, so they are freed
/// when the lane drains. A presenter freed while its record is still open
/// leaves nothing scheduled behind: its wake timer is cancelled and its
/// Screen's loop stopped ([`NuxieMachineSheetSchedule`]). Events that
/// arrive after the release (a UIKit completion, a late report) find a
/// final state and change nothing, and the status keeps the record's end
/// and the last plan read.
///
/// Where the presenter is lives in one [`NuxieMachineSheetState`]; every
/// event (an edge report, a UIKit transition's start or end, the timer, a
/// failure) goes through [`send`], and the effects it returns are the only
/// UIKit, timer and edge work the presenter does. What the host shows is
/// derived from that state.
///
/// The presenter learns what the machine did only from the edge's reports,
/// which the edge's owner callback posts to an inbox and the presenter takes
/// right after the call that made them. Every call the presenter or the
/// Screen makes to the edge runs in the Screen's lane, one at a time, so a
/// wake, a frame and a close reach the edge in the order of their moments.
/// Rows can arrive after the sheet is gone (a purchase answered after a
/// swipe down): they have nothing to draw into and are no fault.
@MainActor
package final class NuxieMachineSheetPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
    /// What the host shows: the plan last read from the record, and the
    /// record's state as the presenter's state has it.
    package var status: NuxieMachineSheetStatus {
        NuxieMachineSheetStatus(plan: plan, record: Self.record(state.record))
    }

    private weak var host: UIViewController?
    private let onStatus: @MainActor (NuxieMachineSheetStatus) -> Void
    private var state = NuxieMachineSheetState()
    /// The root slot `plan` as last read from the edge, for the host to show.
    private var plan: String?
    /// The status the host was last told, so it hears only changes.
    private var told = NuxieMachineSheetStatus(plan: nil, record: .notStarted)
    private var controller: NuxieMachineScreenViewController?
    private let reports = NuxieMachineReportInbox()
    /// Events waiting for [`send`], which handles one at a time.
    private var events: [NuxieMachineSheetState.Event] = []
    private var sending = false
    /// The wake timer and the Screen's loop, which outlive nothing of the
    /// presenter's.
    private let scheduled = NuxieMachineSheetSchedule()
    private var started = false
    private let logger = Logger(subsystem: "io.nuxie.sdk", category: "NuxieMachine")

    /// The wake timer while one is set, for checks.
    package var scheduledWake: (any DispatchSourceTimer)? { scheduled.wake }

    /// A presenter that presents from `host` and tells `onStatus` what the
    /// host can show.
    package init(host: UIViewController, onStatus: @escaping @MainActor (NuxieMachineSheetStatus) -> Void) {
        self.host = host
        self.onStatus = onStatus
        super.init()
    }

    /// Compile the plan, open its hand-written artwork, and start a record
    /// on `event`. What the machine says to present opens as a sheet. A
    /// presenter starts once.
    package func start(
        plan: NuxieMachinePlanSource,
        screen: NuxieMachineScreenSource,
        store: any NuxieMachineStore,
        event: String
    ) async {
        await start(event: event) { inbox in
            try await NuxieMachineEdge(plan: plan, screen: screen, store: store, onReport: { inbox.post($0) })
        }
    }

    /// Compile the plan and start a record on `event`; each instance the
    /// machine presents is drawn from the plan's own views. A presenter
    /// starts once.
    package func start(plan: NuxieMachinePlanSource, store: any NuxieMachineStore, event: String) async {
        await start(event: event) { inbox in
            try NuxieMachineEdge(plan: plan, store: store, onReport: { inbox.post($0) })
        }
    }

    private func start(
        event: String,
        opening: (NuxieMachineReportInbox) async throws -> NuxieMachineEdge
    ) async {
        guard !started else { return }
        started = true
        let edge: NuxieMachineEdge
        do {
            edge = try await opening(reports)
        } catch {
            send(.hostFault(error as? NuxieMachineEdgeFault
                ?? NuxieMachineEdgeFault(code: "edge.open", detail: "\(error)")))
            return
        }
        let controller = NuxieMachineScreenViewController(edge: edge)
        controller.beforeFrame = { [weak self] now in await self?.catchUp(to: now) }
        controller.onFrame = { [weak self] _ in
            self?.takeReports()
            await self?.readPlan()
        }
        controller.onFault = { [weak self] fault in
            self?.takeReports()
            self?.send(.hostFault(fault))
        }
        controller.statusText = Self.describe(status)
        self.controller = controller
        logger.info("machine.start \(event, privacy: .public)")
        send(.started)
        await controller.inLane {
            await edge.start(event: event, now: nuxieMachineNow())
            takeReports()
            await readPlan()
        }
        guard case .open = state.record else { return }
        scheduled.screen = controller
        controller.start()
    }

    // MARK: Events

    /// Move the state for `event` and perform its effects, then for every
    /// event those effects raised, in order. The one way the presenter
    /// changes.
    private func send(_ event: NuxieMachineSheetState.Event) {
        events.append(event)
        guard !sending else { return }
        sending = true
        while !events.isEmpty {
            let next = events.removeFirst()
            for effect in state.handle(next) {
                perform(effect)
            }
        }
        sending = false
        publish()
    }

    private func perform(_ effect: NuxieMachineSheetState.Effect) {
        switch effect {
        case .present(let shown, let presentation):
            presentSheet(shown, as: presentation)
        case .dismiss:
            logger.info("machine.dismiss-sheet")
            controller?.dismiss(animated: true) { [weak self] in self?.send(.dismissed) }
        case .close(let shown):
            close(shown)
        case .schedule(let moment):
            schedule(moment)
        case .stop(let fault):
            if let fault {
                logger.error("machine.fault \(fault.code, privacy: .public): \(fault.detail, privacy: .public)")
            }
            guard let controller else { return }
            controller.stop()
            let edge = controller.edge
            Task { await controller.inLane { try? await edge.close() } }
        case .release:
            // The lane's own work keeps what it uses until it is over; the
            // presenter keeps nothing.
            logger.info("machine.release")
            scheduled.cancelWake()
            scheduled.screen = nil
            controller = nil
        }
    }

    /// Hand the state every report the edge has made since the last take,
    /// in order. Called right after each call to the edge.
    private func takeReports() {
        for report in reports.take() {
            logger.info("machine.report \(String(describing: report), privacy: .public)")
            send(.report(report))
        }
    }

    /// Read the record's plan for the host while the record is open.
    private func readPlan() async {
        guard case .open = state.record, let edge = controller?.edge,
              let value = try? await edge.slot("plan") else { return }
        plan = Self.name(value)
        publish()
    }

    /// Tell the host and the Screen's accessibility value the status, if it
    /// changed since they were last told.
    private func publish() {
        let now = status
        guard now != told else { return }
        told = now
        controller?.statusText = Self.describe(now)
        onStatus(now)
    }

    // MARK: The sheet

    private func presentSheet(_ shown: NuxieMachineShown, as presentation: NuxieMachinePresentation) {
        guard let controller, let host, host.viewIfLoaded?.window != nil, host.presentedViewController == nil else {
            send(.presentFailed(NuxieMachineEdgeFault(code: "edge.no-host",
                detail: "nothing can present the sheet: the host is gone, off screen or already presenting")))
            return
        }
        logger.info("machine.present-sheet \(shown.showing)")
        if presentation == .cover {
            controller.modalPresentationStyle = .fullScreen
            controller.fillsSafeAreaOnly = true
        } else {
            controller.modalPresentationStyle = .pageSheet
            if let sheet = controller.sheetPresentationController {
                sheet.detents = [.large()]
                sheet.prefersGrabberVisible = false
            }
        }
        controller.presentationController?.delegate = self
        host.present(controller, animated: true) { [weak self] in self?.send(.presented) }
        controller.requestFrame()
    }

    /// The person began swiping the sheet down. The swipe is followed to
    /// its end through the transition's coordinator: it takes the sheet, or
    /// it is cancelled and the sheet stays.
    package func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        send(.swipeBegan)
        _ = presentationController.presentedViewController.transitionCoordinator?.animate(alongsideTransition: nil) {
            [weak self] context in
            let completed = !context.isCancelled
            MainActor.assumeIsolated { self?.send(.swipeEnded(completed: completed)) }
        }
    }

    /// The person's swipe took the sheet. The coordinator says so too; the
    /// state takes whichever comes first.
    package func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        send(.swipeEnded(completed: true))
    }

    /// The machine hears `closed` for the showing the swipe took, after
    /// every wake due by then, and its answer is taken.
    private func close(_ shown: NuxieMachineShown) {
        guard let controller else { return }
        logger.info("machine.closed \(shown.showing)")
        let edge = controller.edge
        Task { @MainActor [weak self] in
            await controller.inLane {
                let now = nuxieMachineNow()
                await self?.catchUp(to: now)
                await edge.closed(shown, now: now)
                self?.takeReports()
                await self?.readPlan()
            }
            controller.requestFrame()
        }
    }

    // MARK: Waking

    private func schedule(_ moment: Int64?) {
        guard let moment else {
            scheduled.cancelWake()
            return
        }
        logger.info("machine.wake-at \(moment)")
        scheduled.setWake(at: moment) { [weak self] in
            Task { @MainActor in await self?.wakeNow() }
        }
    }

    /// The timer fired: deliver what is due, in the Screen's lane.
    private func wakeNow() async {
        guard let controller else { return }
        await controller.inLane { await catchUp(to: nuxieMachineNow()) }
        controller.requestFrame()
    }

    /// Deliver every wake the record asks for at or before `now`, each at
    /// its own moment, oldest first. Runs inside the Screen's lane.
    private func catchUp(to now: Int64) async {
        while let moment = state.dueWake(at: now), let edge = controller?.edge {
            logger.info("machine.wake \(moment)")
            send(.wakeTaken(moment))
            await edge.wake(now: moment)
            takeReports()
        }
    }

    // MARK: Words

    private static func record(_ record: NuxieMachineSheetState.Record) -> NuxieMachineSheetStatus.Record {
        switch record {
        case .notStarted: .notStarted
        case .open(let moment): .open(wakeAt: moment)
        case .ended: .ended
        case .faulted(let fault): .fault(fault.code)
        }
    }

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

/// What a presenter scheduled that something else keeps running: the wake
/// timer, which the main queue keeps until its moment, and the Screen's
/// display loop, which runs while UIKit or a frame keeps the Screen. The
/// presenter cancels the timer when the record moves it and when it lets
/// go of what it owns. Freed with the presenter, whatever the record's
/// state, this cancels the timer and stops the loop, so neither outlives
/// the presenter that scheduled it.
private final class NuxieMachineSheetSchedule {
    /// The wake timer, while one is set.
    private(set) var wake: (any DispatchSourceTimer)?
    /// The Screen whose loop the presenter started.
    weak var screen: NuxieMachineScreenViewController?

    /// Call `fire` on the main queue at `moment` (milliseconds since the
    /// Unix epoch) on the wall clock, in place of any wake set before. A
    /// moment already past fires at once, and one passed while the app was
    /// suspended fires when it runs again.
    func setWake(at moment: Int64, _ fire: @escaping @Sendable () -> Void) {
        cancelWake()
        let at = max(0, moment)
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.setEventHandler { fire() }
        source.schedule(wallDeadline: DispatchWallTime(
            timespec: timespec(tv_sec: Int(at / 1000), tv_nsec: Int(at % 1000) * 1_000_000)))
        source.resume()
        wake = source
    }

    func cancelWake() {
        wake?.cancel()
        wake = nil
    }

    deinit {
        // Cancelling a dispatch timer is safe from any thread; the loop is
        // stopped on the main actor, where the Screen lives.
        wake?.cancel()
        if let screen {
            Task { @MainActor in screen.stop() }
        }
    }
}

/// Where the edge's owner callback leaves its reports, from inside the
/// edge's turn, for the presenter to take on the main actor in order.
private final class NuxieMachineReportInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [NuxieMachineEdgeReport] = []

    func post(_ report: NuxieMachineEdgeReport) {
        lock.withLock { reports.append(report) }
    }

    func take() -> [NuxieMachineEdgeReport] {
        lock.withLock {
            defer { reports = [] }
            return reports
        }
    }
}
#endif
