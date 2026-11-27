#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieRuntime
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
        /// The start did not happen, and nothing is wrong: the machine
        /// started no record for the event (no entry starts on it, or one
        /// declined it, `once` say). Nothing was shown, and the host can let
        /// go of the presenter.
        case didNotStart
    }

    /// The record's root slot `plan`, as last read: an enum value's name.
    package var plan: String?
    package var record: Record

    package init(plan: String?, record: Record) {
        self.plan = plan
        self.record = record
    }
}

/// Shows what an edge shows with UIKit, and performs the rows it reports.
///
/// - What is shown is each report's stack. Each presentation in it is its
///   own native presentation, presented from the one below it (the host's
///   view controller for the bottom one): a sheet presents its Screen as a
///   native sheet at the heights its row writes (the large detent when it
///   writes none), and a cover as a native cover over the whole screen,
///   which has no swipe. Any other presentation is a fault: push and the
///   rest are not presented.
/// - When a report no longer shows a presentation, its native presentation
///   is dismissed, with every one above it, and what is missing is
///   presented, one at a time, once UIKit has finished the transition
///   before it ([`NuxieMachineSheetState`]).
/// - What a swipe down on a sheet does is the machine's answer, read with
///   what is shown after every delivery and every round, and handed to the
///   sheet with each report, since UIKit asks before a drag begins:
///   - stays: the native dismissal is held; UIKit's attempt is delivered as
///     a swipe once, and it does nothing;
///   - presses: the native dismissal is held; UIKit's attempt is delivered
///     as a swipe once: the press of the control its row's `swipe=` names,
///     then whatever that does (the machine's own pop, say);
///   - closes: the native dismissal runs, and when it completes (not when
///     the person lets go) the swipe is delivered and the machine closes
///     the entry.
///   The answer can change between the read and the delivery, so the
///   presenter acts on what the machine did, through what it then shows: a
///   held swipe that closes dismisses the sheet natively, and a completed
///   one that does not close presents the sheet again
///   (`machine.swipe.changed`). The screen reader's escape is a swipe down
///   too, read from the same answer. A cancelled swipe sends nothing, and
///   so does a swipe or an escape on a sheet whose loading screen is up.
/// - `wake at` sets a timer that delivers `wake` if the app is still running
///   at that moment. A later `wake at` replaces it, and the record's end
///   cancels it. The machine takes a wake only at the moment it asked for,
///   and no event earlier than its last, so a due wake is delivered at its
///   own moment before any frame or close that comes after it, and a timer
///   that fires late (the app was suspended) catches up one wake at a time.
///   Waits that outlive the app are not built.
/// - `end` stops the loop, cancels the timer and closes the edge.
/// - A start the machine says did not happen, with nothing wrong (no entry
///   starts on the event, or one declined it, `once` say), is no fault: the
///   host hears `didNotStart`, nothing is presented, and the presenter lets
///   go.
/// - Every fault takes one path: every native presentation is dismissed,
///   the code is logged, and everything stops.
/// - A page whose files have not arrived is presented all the same, over a
///   loading screen ([`NuxieMachineScreenViewController.assets`]). After
///   [`recoveryAffordanceDelay`], or at once when a file fails, the recovery
///   screen and a close show; each failed file is logged by path. Try Again
///   asks the edge for the failed files again. The close tells the edge the
///   host's own fault, `first_frame.deadline`, and the fault's path takes
///   everything down.
/// - The session is drawn in light or dark as the SDK's experiences are:
///   the app's fixed scheme ([`colorSchemeMode`]) is forced on each native
///   presentation, `system` following the phone, and the scheme is read
///   from what UIKit then says ([`ExperienceColorScheme.init(drawnBy:host:)`]).
///   The session is told it before its start, so the first frame is drawn
///   in it, and again before the first frame (or close, or wake) after it
///   changes. One environment holds for the session: sheets and covers
///   over one another share it.
/// - The person's body text size is told on the same path, as one more
///   field of the environment: read from the same traits as the scheme
///   ([`textSize`]), the way the SDK's experience screens read it
///   ([`bodyTextSize(in:)`]), and told with it, once per value, before the
///   start and before the first frame after it changes. One `rem` of the
///   session's pages is that size.
/// - Each native presentation is told where it is shown, its place
///   ([`NuxieMachineScreenViewController.place`]): the insets of what it
///   is presented in, which its Screen fills to every edge, a cover's the
///   screen's and a sheet's its own. Its place is told before its first
///   frame is drawn, and again before the next frame after a rotation, a
///   change of size or of the safe area; the same place is told once, and
///   it goes when its presentation does ([`NuxieMachineToldPlaces`]).
/// - Whether the person is in the app is told on the same path
///   ([`presence(here:)`]): she leaves when the app enters the background
///   and comes back when it is about to enter the foreground, as UIKit's
///   notices say, which the presenter itself observes. An inactive app
///   (the app switcher, a system alert over it) is still hers. Each notice
///   is kept as it is received, with the clock's moment then, in order
///   ([`NuxieMachinePresence`]), and nothing is merged: away and back
///   received while the loop's lane is held are two changes. Each run of
///   the lane, whatever runs it (a notice's own, a frame, a close, the
///   timer), first tells each notice received by the run's moment, in
///   turn, at its own moment: for a departure, each wake due by its moment
///   first, as here, then away; for a return, here first, so the machine
///   delivers each wake she missed with her away inside that one call. A
///   notice received after the run's moment (while the run waited on a
///   delivery) is not told early: it waits for the next run, and its own
///   run is at no earlier moment than it, so none is left behind. A value
///   the same as the one last told is not told again. A wake the timer
///   delivers while she is away and the app still runs is delivered as
///   any other, and the machine judges it with her away.
///
/// What the presenter owns has one end of life. The edge with its session,
/// the loop that runs its frames, the Screens, and the wake timer are let
/// go of exactly once, when the state says `release`: the record is ended,
/// faulted or declined and no native presentation is on screen or in a
/// transition.
/// An open record keeps them all, with nothing shown too (waiting for its
/// wake after "Not now"). The presenter lets go at once, and work already in
/// the loop's lane (the edge's close among it) holds what it uses until it
/// is over, so they are freed when the lane drains. A presenter freed while
/// its record is still open leaves nothing scheduled behind: its wake timer
/// is cancelled and its loop stopped ([`NuxieMachineSheetSchedule`]).
/// Events that arrive after the release (a UIKit completion, a late report)
/// find a final state and change nothing, and the status keeps the record's
/// end and the last plan read.
///
/// Where the presenter is lives in one [`NuxieMachineSheetState`]; every
/// event (an edge report, a UIKit transition's start or end, the timer, a
/// failure) goes through [`send`], and the effects it returns are the only
/// UIKit, timer and edge work the presenter does. The presenter keeps one
/// Screen controller for each native presentation the state holds, and
/// nothing else about them. What the host shows is derived from that state.
///
/// The presenter learns what the machine did only from the edge's reports,
/// which the edge's owner callback posts to an inbox and the presenter takes
/// right after the call that made them. Every call the presenter or the
/// loop makes to the edge runs in the loop's lane, one at a time, so a
/// wake, a frame and a close reach the edge in the order of their moments.
/// Rows can arrive after the last presentation is gone (a purchase answered
/// after a swipe down): they have nothing to draw into and are no fault.
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
    private var loop: NuxieMachineScreenLoop?
    /// The Screen controller of each native presentation the state holds.
    private var controllers: [NuxieMachineShown: NuxieMachineScreenViewController] = [:]
    private let reports = NuxieMachineReportInbox()
    /// Events waiting for [`send`], which handles one at a time.
    private var events: [NuxieMachineSheetState.Event] = []
    private var sending = false
    /// The wake timer and the loop, which outlive nothing of the
    /// presenter's.
    private let scheduled = NuxieMachineSheetSchedule()
    private var started = false
    private let logger = Logger(subsystem: "io.nuxie.sdk", category: "NuxieMachine")

    /// The wake timer while one is set, for checks.
    package var scheduledWake: (any DispatchSourceTimer)? { scheduled.wake }

    /// The moments of the wakes the presenter delivered itself (its timer's,
    /// or one due before a frame or a close), oldest first, for checks. A
    /// wake the machine delivers inside a presence call is not among them.
    package private(set) var wakesDelivered: [Int64] = []

    /// The notices that the person left or came back, as received and not
    /// yet told, oldest first ([`presence(here:)`]).
    private var received: [NuxieMachinePresence] = []

    /// The notices received and not yet told, oldest first, for checks.
    package var presencesWaiting: [NuxieMachinePresence] { received }

    /// Each presence the session was told, with the moment it was told at,
    /// oldest first, for checks.
    package private(set) var presencesTold: [NuxieMachinePresence] = []

    /// Whether the session was last told the person is in the app: the one
    /// told value. A session starts with her here.
    package private(set) var here = true

    /// A test seam, not public API.
    ///
    /// How far the clock the machine reads runs ahead of the wall clock, in
    /// milliseconds. Zero, the wall clock itself, unless a test host moves
    /// it: the SDK never sets it. Every moment the presenter and its loop
    /// hand the edge is read from that clock ([`machineNow`]), and the wake
    /// timer fires when that clock reaches the wake's moment. Moving it sets
    /// the timer again, so a wake the move made due fires at once, through
    /// the timer, as it would have at its moment.
    package var clockAhead: Int64 = 0 {
        didSet {
            guard clockAhead != oldValue, case .open(let moment?) = state.record else { return }
            schedule(moment)
        }
    }

    /// The clock the machine reads: the wall clock, [`clockAhead`] on.
    private func machineNow() -> Int64 {
        nuxieMachineNow() + clockAhead
    }

    /// A test seam, not public API.
    ///
    /// How long a page waits for its files on the loading screen before the
    /// recovery screen and the close show, in seconds. Five, as the SDK's
    /// experience screens wait; a test sets it to 0. Each Screen takes the
    /// value when it is presented.
    package var recoveryAffordanceDelay: TimeInterval = 5.0

    /// The scheme the app fixes for its experiences: `system` (the default)
    /// follows the phone, `light` or `dark` overrides it, on every native
    /// presentation, as the SDK's experience controller applies it.
    package var colorSchemeMode: ExperienceColorSchemeMode = .system {
        didSet {
            guard oldValue != colorSchemeMode else { return }
            for controller in controllers.values { applyColorSchemeMode(to: controller) }
            loop?.requestFrame()
        }
    }

    /// The environment the session was last told, for checks. None before
    /// the start.
    package private(set) var environment: NuxieMachineEnvironment?

    /// The place each presented Screen was last told: the one copy.
    private var toldPlaces = NuxieMachineToldPlaces()

    /// The place each presented Screen was last told, for checks.
    package var places: [NuxieMachineShown: NuxieMachineScreenPlace] { toldPlaces.places }

    /// The edge while the presenter holds it, for checks.
    package var edge: NuxieMachineEdge? { loop?.edge }

    /// The loop while the presenter holds it, for checks: a check can hold
    /// its lane.
    package var screenLoop: NuxieMachineScreenLoop? { loop }

    /// A presenter that presents from `host` and tells `onStatus` what the
    /// host can show.
    package init(host: UIViewController, onStatus: @escaping @MainActor (NuxieMachineSheetStatus) -> Void) {
        self.host = host
        self.onStatus = onStatus
        super.init()
    }

    /// Compile the plan and start a record on `event`; each presentation
    /// the machine shows is drawn from the plan's own views, with the bytes
    /// of the folder's files it shows from `bytes`, and presented natively.
    /// A presenter starts once.
    package func start(plan: NuxieMachinePlanSource, store: any NuxieMachineStore,
                       bytes: any NuxieMachineByteSource, event: String) async {
        guard !started else { return }
        started = true
        let edge: NuxieMachineEdge
        do {
            let inbox = reports
            edge = try NuxieMachineEdge(plan: plan, store: store, bytes: bytes, onReport: { inbox.post($0) })
        } catch {
            send(.hostFault(error as? NuxieMachineEdgeFault
                ?? NuxieMachineEdgeFault(code: "edge.open", detail: "\(error)")))
            return
        }
        let loop = NuxieMachineScreenLoop(edge: edge)
        loop.clock = { [weak self] in self?.machineNow() ?? nuxieMachineNow() }
        loop.beforeFrame = { [weak self] now in await self?.catchUp(to: now) }
        loop.onFrame = { [weak self] _ in
            self?.takeReports()
            await self?.readPlan()
        }
        loop.onFault = { [weak self] fault in
            self?.takeReports()
            self?.send(.hostFault(fault))
        }
        self.loop = loop
        observePresence()
        logger.info("machine.start \(event, privacy: .public)")
        send(.started)
        await loop.inLane {
            // The environment goes first, so the start's first frame is
            // drawn in it; then where the person is, which the session
            // keeps for the start. The start is the lane run for every
            // notice received before it, so its moment is no earlier than
            // any of theirs.
            let now = max(machineNow(), received.last?.at ?? .min)
            await tellEnvironment(at: now)
            await tellPresences(by: now)
            await edge.start(event: event, now: now)
            takeReports()
            await readPlan()
        }
        guard case .open = state.record else { return }
        scheduled.loop = loop
        loop.start()
    }

    // MARK: Events

    /// Move the state for `event` and perform its effects, then for every
    /// event those effects raised, in order. The one way the presenter
    /// changes. Once the state has settled, the presenter keeps a Screen
    /// controller for each native presentation the state holds and no
    /// other, and the loop draws those.
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
        let held = state.natives.map(\.shown)
        controllers = controllers.filter { held.contains($0.key) }
        // Each sheet holds what a swipe down on it does now, for UIKit to
        // read when a drag begins.
        for presented in state.wanted { controllers[presented.shown]?.follow(presented) }
        toldPlaces.keep(held)
        loop?.screens = held.compactMap { controllers[$0] }
        let reached = state.reachable
        for (shown, controller) in controllers { controller.reachable = shown == reached }
        publish()
    }

    private func perform(_ effect: NuxieMachineSheetState.Effect) {
        switch effect {
        case .present(let presented, let over):
            present(presented, over: over)
        case .dismiss(let shown):
            dismiss(shown)
        case .swipe(let shown):
            swipe(shown)
        case .schedule(let moment):
            schedule(moment)
        case .stop(let fault):
            if let fault {
                logger.error("machine.fault \(fault.code, privacy: .public): \(fault.detail, privacy: .public)")
            }
            guard let loop else { return }
            loop.stop()
            let edge = loop.edge
            Task { await loop.inLane { try? await edge.close() } }
        case .assets(let now):
            for controller in controllers.values { controller.assets = now }
            if case .failed(let failures) = now {
                for failure in failures {
                    let reason = failure.reason == .offline ? "offline" : "unavailable"
                    logger.error("machine.assets failed \(failure.path, privacy: .public) \(reason, privacy: .public)")
                }
            }
        case .refresh:
            refresh()
        case .hostFault(let fault):
            tellHostFault(fault)
        case .release:
            // The lane's own work keeps what it uses until it is over; the
            // presenter keeps nothing.
            logger.info("machine.release")
            scheduled.cancelWake()
            scheduled.stopObserving()
            scheduled.loop = nil
            loop = nil
            controllers = [:]
            toldPlaces = NuxieMachineToldPlaces()
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
        guard case .open = state.record, let edge = loop?.edge,
              let value = try? await edge.slot("plan") else { return }
        plan = Self.name(value)
        publish()
    }

    /// Tell the host and each Screen's accessibility value the status, if it
    /// changed since they were last told.
    private func publish() {
        let now = status
        guard now != told else { return }
        told = now
        for controller in controllers.values { controller.statusText = Self.describe(now) }
        onStatus(now)
    }

    // MARK: Native presentations

    /// Present `presented` in a Screen controller of its own, from the
    /// native presentation `over`, or from the host for the bottom one.
    private func present(_ presented: NuxieMachinePresented, over: NuxieMachineShown?) {
        let below: UIViewController? = over.map { controllers[$0] } ?? host
        guard let loop, let below, below.viewIfLoaded?.window != nil, below.presentedViewController == nil else {
            send(.presentFailed(presented.shown, NuxieMachineEdgeFault(code: "edge.no-host",
                detail: "nothing can present \(presented.route): the host is gone, off screen or already presenting")))
            return
        }
        let shown = presented.shown
        logger.info("machine.present \(presented.route, privacy: .public) \(shown.journey).\(shown.instance)")
        let controller = NuxieMachineScreenViewController(presenting: presented, loop: loop, assets: state.assets,
                                                          recoveryDelay: recoveryAffordanceDelay)
        controller.onRefresh = { [weak self] in self?.send(.refreshTapped) }
        controller.onExit = { [weak self] in self?.send(.exitTapped) }
        controller.statusText = Self.describe(status)
        applyColorSchemeMode(to: controller)
        controller.onEnvironmentChange = { [weak self] in self?.environmentChanged() }
        controller.onEscape = { [weak self] in self?.send(.swipeRefused(shown)) }
        controller.presentationController?.delegate = self
        controllers[shown] = controller
        // UIKit takes a sheet's detents shortest first. Until it resolves
        // one, the order is made for the height the window leaves a sheet;
        // then the sheet follows what UIKit resolves against.
        if let window = below.viewIfLoaded?.window {
            controller.orderDetents(estimatedMaximum: NuxieMachineScreenViewController.estimatedSheetMaximum(in: window))
        }
        below.present(controller, animated: true) { [weak self] in self?.send(.presented(shown)) }
        loop.requestFrame()
    }

    /// Dismiss the native presentation `shown`, with every one above it,
    /// from the one it was presented from.
    private func dismiss(_ shown: NuxieMachineShown) {
        logger.info("machine.dismiss \(shown.journey).\(shown.instance)")
        guard let below = controllers[shown]?.presentingViewController else {
            send(.dismissed(shown))
            return
        }
        below.dismiss(animated: true) { [weak self] in self?.send(.dismissed(shown)) }
    }

    /// The person began swiping a sheet down. The swipe is followed to its
    /// end through the transition's coordinator: it takes the sheet, or it
    /// is cancelled and the sheet stays.
    package func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        guard let screen = presentationController.presentedViewController as? NuxieMachineScreenViewController
        else { return }
        let shown = screen.shown
        send(.swipeBegan(shown))
        _ = presentationController.presentedViewController.transitionCoordinator?.animate(alongsideTransition: nil) {
            [weak self] context in
            let completed = !context.isCancelled
            MainActor.assumeIsolated { self?.send(.swipeEnded(shown, completed: completed)) }
        }
    }

    /// The person's swipe took the sheet. The coordinator says so too; the
    /// state takes whichever comes first.
    package func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let screen = presentationController.presentedViewController as? NuxieMachineScreenViewController
        else { return }
        send(.swipeEnded(screen.shown, completed: true))
    }

    /// The person swiped a sheet UIKit held, because the machine said the
    /// swipe presses a control or does nothing: the swipe is delivered. A
    /// sheet held by its loading screen takes no swipe: its close is the
    /// way out, and nothing is delivered.
    package func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        guard let screen = presentationController.presentedViewController as? NuxieMachineScreenViewController,
              !screen.modalReasons.contains(.loading)
        else { return }
        send(.swipeRefused(screen.shown))
    }

    /// The machine hears a swipe down on the presentation `shown`, after
    /// every wake due by then, and its answer is taken: what is shown says
    /// the rest. `native` says whether the native dismissal ran: when it
    /// did and the machine did not close the sheet, the sheet comes back.
    private func swipe(_ shown: NuxieMachineShown) {
        guard let loop else { return }
        let native = state.closing.contains(shown)
        let how = native ? "completed" : "held"
        logger.info("machine.swipe \(shown.journey).\(shown.instance) \(how, privacy: .public)")
        let edge = loop.edge
        Task { @MainActor [weak self] in
            await loop.inLane {
                let now = self?.machineNow() ?? nuxieMachineNow()
                await self?.catchUp(to: now)
                let did = await edge.swipe(.down, on: shown, now: now)
                self?.takeReports()
                self?.swiped(shown, did, native: native)
                await self?.readPlan()
            }
        }
    }

    /// The person tapped Try Again: the edge asks again for the files that
    /// failed, and its answer is taken.
    private func refresh() {
        guard let loop else { return }
        let edge = loop.edge
        Task { @MainActor [weak self] in
            await loop.inLane {
                await edge.refreshAssets()
                self?.takeReports()
            }
        }
    }

    /// The person closed a page that waits for its files: the edge is told
    /// the host's fault, after every wake due by then, and its answer is
    /// taken. The answer is the record's fault, which dismisses everything.
    private func tellHostFault(_ fault: NuxieMachineHostFault) {
        guard let loop else { return }
        let edge = loop.edge
        Task { @MainActor [weak self] in
            await loop.inLane {
                let now = self?.machineNow() ?? nuxieMachineNow()
                await self?.catchUp(to: now)
                await edge.hostFault(fault, now: now)
                self?.takeReports()
            }
        }
    }

    /// The edge answered the swipe on `shown`, its reports already taken.
    private func swiped(_ shown: NuxieMachineShown, _ did: NuxieMachineSwipeDid, native: Bool) {
        let said = String(describing: did)
        logger.info("machine.swipe.did \(shown.journey).\(shown.instance) \(said, privacy: .public)")
        if native, case .delivered(let what) = did, what != .closes {
            logger.info("machine.swipe.changed \(shown.journey).\(shown.instance) \(said, privacy: .public)")
        }
        send(.swipeDelivered(shown))
    }

    // MARK: Waking

    private func schedule(_ moment: Int64?) {
        guard let moment else {
            scheduled.cancelWake()
            return
        }
        logger.info("machine.wake-at \(moment)")
        // The timer runs on the wall clock: the moment is the machine's.
        scheduled.setWake(at: moment - clockAhead) { [weak self] in
            Task { @MainActor in await self?.wakeNow() }
        }
    }

    /// The timer fired: deliver what is due, in the loop's lane. A wake
    /// that leaves work for a frame (a step owed, a store's answer to come)
    /// has the edge ask for it.
    private func wakeNow() async {
        guard let loop else { return }
        await loop.inLane { await catchUp(to: machineNow()) }
    }

    /// Tell the session each notice received that the person left or came
    /// back, in order, each at its own moment, then deliver every wake the
    /// record asks for at or before `now`, each at its own moment, oldest
    /// first, then the client's environment at `now` if it changed, then
    /// each presented Screen's place that changed. Runs inside the loop's
    /// lane, before each frame, close and timer's wake, and for each notice.
    private func catchUp(to now: Int64) async {
        await tellPresences(by: now)
        await deliverWakes(dueBy: now)
        await tellEnvironment(at: now)
        await tellPlaces(at: now)
    }

    /// Deliver every wake the record asks for at or before `moment`, each
    /// at its own moment, oldest first.
    private func deliverWakes(dueBy moment: Int64) async {
        while let due = state.dueWake(at: moment), let edge = loop?.edge {
            logger.info("machine.wake \(due)")
            send(.wakeTaken(due))
            wakesDelivered.append(due)
            await edge.wake(now: due)
            takeReports()
        }
    }

    // MARK: Where the person is

    /// The person left the app (`here` false) or came back to it: what
    /// UIKit's background and foreground notices call, and a test host's
    /// stand-in for them. The notice is kept at once, with the clock's
    /// moment, after any received before it, and told in the loop's lane
    /// ([`tellPresences(by:)`]). Before the start it is kept, and told
    /// before it; once the presenter has let go of its edge it is dropped.
    package func presence(here: Bool) async {
        guard let moment = receive(here: here) else { return }
        await tellReceived(at: moment)
    }

    /// Keep a notice as it is received: its value and the clock's moment
    /// now, never earlier than the one before it. Returns that moment, or
    /// none when the notice is dropped.
    private func receive(here: Bool) -> Int64? {
        guard !started || loop != nil else { return nil }
        let moment = max(machineNow(), received.last?.at ?? .min)
        received.append(NuxieMachinePresence(here: here, at: moment))
        return moment
    }

    /// Run the lane for the notice received at `moment`, if the presenter
    /// holds a loop: the run made for it, which every notice has. Its moment
    /// is the clock's when the lane is reached and never earlier than the
    /// notice's, so the notice is told in it at the latest, even when a run
    /// before it left the notice for later or the clock was set back.
    private func tellReceived(at moment: Int64) async {
        guard let loop else { return }
        await loop.inLane { await catchUp(to: max(machineNow(), moment)) }
    }

    /// Tell the session each notice received at or before `now`, the lane
    /// run's moment, oldest first, each at its own moment. A notice
    /// received after `now` (while this run waited on a delivery) is not
    /// told early: it stays, with every one after it, for the next run of
    /// the lane, at the latest the one made for it ([`tellReceived(at:)`]).
    /// A departure first delivers each wake due by its moment, which came
    /// due while she was here; a return is told before any wake due by its
    /// moment, and the machine delivers each one she missed with her away
    /// inside that call: the wake the state holds as due is taken first, as
    /// the wake loop takes each one, and the rows, which say the record's
    /// next wake, give it its next. A value the same as the one last told
    /// is not told again. Runs inside the loop's lane.
    private func tellPresences(by now: Int64) async {
        while let next = received.first, next.at <= now {
            received.removeFirst()
            let moment = next.at
            if !next.here { await deliverWakes(dueBy: moment) }
            guard next.here != here, let edge = loop?.edge else { continue }
            here = next.here
            logger.info("machine.presence \(next.here ? "here" : "away", privacy: .public) \(moment)")
            if next.here, let due = state.dueWake(at: moment) { send(.wakeTaken(due)) }
            presencesTold.append(NuxieMachinePresence(here: next.here, at: moment))
            await edge.presence(here: next.here, now: moment)
            takeReports()
        }
    }

    /// Hear UIKit's notices that the person left the app and came back,
    /// once for the presenter, however many Screens it shows: away when
    /// the app enters the background, back when it is about to enter the
    /// foreground. Resigning active is not leaving.
    ///
    /// Each notice is kept where UIKit posts it, on the main thread, with
    /// the clock's moment then, so whatever runs the lane after it goes by
    /// it, even when a frame held the lane and the app was suspended
    /// before the lane ran again. Leaving is told in the loop's lane right
    /// away, under a background task, so the call reaches the session
    /// before the app is suspended: no frame runs in the background, and
    /// the lane's work runs on the main actor while UIKit lets the app
    /// finish it.
    private func observePresence() {
        let center = NotificationCenter.default
        scheduled.observe([
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.left() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.cameBack() }
            },
        ])
    }

    private func left() {
        guard let moment = receive(here: false) else { return }
        let held = NuxieMachineBackgroundTask(named: "nuxie.machine.presence")
        Task { @MainActor [weak self] in
            await self?.tellReceived(at: moment)
            held.end()
        }
    }

    private func cameBack() {
        guard let moment = receive(here: true) else { return }
        Task { @MainActor [weak self] in await self?.tellReceived(at: moment) }
    }

    // MARK: The environment: light and dark, and the text size

    /// The session's environment may have changed: the phone turned dark or
    /// light, or the person changed their text size. Each Screen calls this
    /// when UIKit says so; the environment is read again, and told if it
    /// changed, before the next frame.
    package func environmentChanged() {
        loop?.requestFrame()
    }

    /// Tell the session the client's environment at `now`, when it is not
    /// the one it was last told. Runs inside the loop's lane, so it reaches
    /// the edge between frames, never inside a step.
    ///
    /// The same environment is told once. It is read before every frame,
    /// and UIKit says a Screen's traits changed for each Screen of the
    /// session (a sheet over a sheet hears the change twice); the machine
    /// would write nothing for a repeat, but each would still take a turn of
    /// the edge and a call into the session. A change and its return (iOS
    /// draws both schemes for the app switcher as the app goes to the
    /// background) are two environments, and each is told.
    private func tellEnvironment(at now: Int64) async {
        guard let edge = loop?.edge else { return }
        let current = NuxieMachineEnvironment(dark: colorScheme == .dark, textSize: textSize)
        guard current != environment else { return }
        environment = current
        let scheme = current.dark ? "dark" : "light"
        logger.info("machine.environment \(scheme, privacy: .public) \(current.textSize, privacy: .public)")
        await edge.environment(current, now: now)
        takeReports()
    }

    /// The scheme the session draws in, read from one place: the bottom
    /// native presentation, as the SDK's experience screens read their own
    /// ([`ExperienceColorScheme.init(drawnBy:host:)`]); every one above it
    /// is presented over it and has the same. With none presented, the
    /// scheme one presented now would draw in: the app's fixed scheme, or
    /// with `system` the host's.
    private var colorScheme: ExperienceColorScheme {
        let hostStyle = self.host?.traitCollection.userInterfaceStyle
        if let bottom = loop?.screens.first {
            return ExperienceColorScheme(drawnBy: bottom, host: hostStyle)
        }
        let forced = colorSchemeMode.userInterfaceStyle
        return ExperienceColorScheme(own: forced, forced: forced, inWindow: false, host: hostStyle)
    }

    /// The person's body text size the session draws at, read from the
    /// traits the scheme is read from ([`colorScheme`]): the bottom native
    /// presentation's while it is in a window, as every one above it is
    /// presented over it and has the same; otherwise the host's, which a
    /// Screen not yet in its window joins. The app forces no text size, so
    /// unlike the scheme there is no forced value to prefer.
    private var textSize: Double {
        let bottom = loop?.screens.first
        let traits = bottom.flatMap { $0.viewIfLoaded?.window == nil ? nil : $0.traitCollection }
            ?? host?.traitCollection ?? bottom?.traitCollection
        return Self.bodyTextSize(in: traits)
    }

    /// The body text size UIKit gives `traits`, in points, as the SDK's
    /// experience screens read it (`ExperienceScreenViewController.fontScale(for:)`):
    /// 17 at the default size, 23 at the largest standard one and 53 at the
    /// largest accessibility one. With no traits, the app's own.
    package static func bodyTextSize(in traits: UITraitCollection?) -> Double {
        Double(UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize)
    }

    /// Force the app's fixed scheme on a native presentation, as the SDK's
    /// experience controller forces it on itself: `system` forces nothing.
    /// Its traits take the style at once, so a frame before it reaches its
    /// window already reads it.
    private func applyColorSchemeMode(to controller: NuxieMachineScreenViewController) {
        controller.overrideUserInterfaceStyle = colorSchemeMode.userInterfaceStyle
        if #available(iOS 17.0, *) { controller.updateTraitsIfNeeded() }
    }

    // MARK: Places

    /// Tell the session where each presented Screen is shown, at `now`,
    /// bottom first, when it is not where it was last told. Runs inside the
    /// loop's lane, after the environment, so it reaches the edge between
    /// frames, never inside a step. The frame that draws a Screen first runs
    /// this, so its first frame is drawn in its place; a Screen with no size
    /// yet has no place, and is told once it has one. A rotation, a change
    /// of size or of the safe area asks for a frame, and that frame's run of
    /// this tells the new place.
    private func tellPlaces(at now: Int64) async {
        guard let loop else { return }
        let edge = loop.edge
        let changed = toldPlaces.changes(loop.screens.map { (shown: $0.shown, place: $0.place) })
        for (shown, place) in changed {
            let at = "\(place.top) \(place.right) \(place.bottom) \(place.left) \(place.width)x\(place.height)"
            logger.info("machine.place \(shown.journey).\(shown.instance) \(at, privacy: .public)")
            await edge.place(place, for: shown, now: now)
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
        case .declined: .didNotStart
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
    /// set, ended, the fault's code, or that it did not start.
    package static func describe(_ record: NuxieMachineSheetStatus.Record) -> String {
        switch record {
        case .notStarted: "not started"
        case .open(nil): "open"
        case .open(let moment?):
            "open, wakes at " + Date(timeIntervalSince1970: Double(moment) / 1000).ISO8601Format()
        case .ended: "ended"
        case .fault(let code): "fault \(code)"
        case .didNotStart: "did not start"
        }
    }
}

/// One notice that the person left the app (`here` false) or came back,
/// with the moment of the presenter's clock when it was received
/// (milliseconds since the Unix epoch): the moment it is told at.
package struct NuxieMachinePresence: Equatable, Sendable {
    package let here: Bool
    package let at: Int64

    package init(here: Bool, at: Int64) {
        self.here = here
        self.at = at
    }
}

/// The place each presented Screen was last told: one entry for each
/// presentation, and the only copy of its insets the presenter keeps. A
/// place is told when it differs from the one last told for the same
/// presentation, so the same place is told once however many frames read
/// it; it goes when its presentation does, so a presentation shown again
/// (a new presentation) is told its own.
package struct NuxieMachineToldPlaces: Equatable, Sendable {
    /// The place last told for each presentation.
    package private(set) var places: [NuxieMachineShown: NuxieMachineScreenPlace] = [:]

    package init() {}

    /// The places to tell now, in the order given (bottom first): each
    /// presentation's whose place is known and is not the one last told.
    /// Each is taken as told.
    package mutating func changes(
        _ screens: [(shown: NuxieMachineShown, place: NuxieMachineScreenPlace?)]
    ) -> [(shown: NuxieMachineShown, place: NuxieMachineScreenPlace)] {
        var changed: [(shown: NuxieMachineShown, place: NuxieMachineScreenPlace)] = []
        for (shown, place) in screens {
            guard let place, places[shown] != place else { continue }
            places[shown] = place
            changed.append((shown, place))
        }
        return changed
    }

    /// Keep only the places of the presentations `held`: the others have
    /// gone, and their places with them.
    package mutating func keep(_ held: [NuxieMachineShown]) {
        places = places.filter { held.contains($0.key) }
    }
}

/// What a presenter scheduled that something else keeps running: the wake
/// timer, which the main queue keeps until its moment, and the display
/// loop, which runs while UIKit or a frame keeps it. The presenter cancels
/// the timer when the record moves it and when it lets go of what it owns.
/// Freed with the presenter, whatever the record's state, this cancels the
/// timer and stops the loop, so neither outlives the presenter that
/// scheduled it.
private final class NuxieMachineSheetSchedule {
    /// The wake timer, while one is set.
    private(set) var wake: (any DispatchSourceTimer)?
    /// The loop the presenter started.
    weak var loop: NuxieMachineScreenLoop?
    /// The presenter's observers of UIKit's background and foreground
    /// notices, which the notification center keeps.
    private var observers: [NSObjectProtocol] = []

    func observe(_ added: [NSObjectProtocol]) {
        stopObserving()
        observers = added
    }

    func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

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
        // stopped on the main actor, where it lives. Removing an observer
        // is safe from any thread.
        wake?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        if let loop {
            Task { @MainActor in loop.stop() }
        }
    }
}

/// A background task held while the presenter tells the session the person
/// left, so UIKit lets the app finish that call before it is suspended.
/// Ended once: when the call is done, or when UIKit says the time is up.
@MainActor
private final class NuxieMachineBackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(named name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
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
