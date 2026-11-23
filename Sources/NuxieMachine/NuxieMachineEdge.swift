#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieRuntime

/// One `.nux` source file of a plan.
package struct NuxieMachineSourceFile: Equatable, Sendable {
    /// The path a `use` names, with `.nux`.
    package let path: String
    package let text: String

    package init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

/// What a session compiles: the files, the root file's path without `.nux`,
/// and the header's app, Experience and version.
package struct NuxieMachinePlanSource: Equatable, Sendable {
    package let files: [NuxieMachineSourceFile]
    package let root: String
    package let app: String
    package let experience: String
    package let version: UInt32

    package init(files: [NuxieMachineSourceFile], root: String, app: String, experience: String, version: UInt32) {
        self.files = files
        self.root = root
        self.app = app
        self.experience = experience
        self.version = version
    }
}

/// Why the edge tells its owner a dismissal.
package enum NuxieMachineEdgeDismissal: Equatable, Sendable {
    /// The machine's `dismiss` row, with its reason or none.
    case machine(reason: String?)
    /// The edge stopped on a fault.
    case fault(NuxieMachineEdgeFault)
}

/// One presentation's identity, which the session never gives again: the
/// Journey that presented it (the session's count of Journeys started) and
/// its instance (which the record numbers afresh and never reuses). Two
/// Journeys can present the same instance number; the Journey tells them
/// apart.
package struct NuxieMachineShown: Hashable, Sendable {
    package let journey: UInt64
    package let instance: UInt64

    package init(journey: UInt64, instance: UInt64) {
        self.journey = journey
        self.instance = instance
    }
}

/// One presentation of what is shown: its identity, its route, and how the
/// route is presented.
package struct NuxieMachinePresented: Equatable, Sendable {
    package let shown: NuxieMachineShown
    package let route: String
    package let presentation: NuxieMachinePresentation

    package init(shown: NuxieMachineShown, route: String, presentation: NuxieMachinePresentation) {
        self.shown = shown
        self.route = route
        self.presentation = presentation
    }
}

/// A row the edge tells its owner, as the edge applied it.
package enum NuxieMachineHostRow: Equatable, Sendable {
    /// The machine's `dismiss`, with its reason or none, told when the
    /// delivery closed a presentation the owner was shown. What is shown is
    /// the report's stack; this row says why it changed.
    case dismiss(reason: String?)
    /// The record asks for a `wake` at this moment, or at none.
    case wakeAt(Int64?)
    /// The record ended normally: finished or exited.
    case end(NuxieMachineEnding)
}

/// What one delivery tells the edge's owner, once, when it is over: what is
/// shown and the rows the owner performs, or the fault that stopped the
/// edge. A fault replaces the rest, since nothing survives it: nothing is
/// shown once the edge has stopped.
package enum NuxieMachineEdgeReport: Equatable, Sendable {
    /// What the edge shows now that the delivery is over, bottom first, and
    /// the delivery's rows for the owner, in order. At most one row is a
    /// `dismiss`: the machine's first in the delivery.
    case delivered(shown: [NuxieMachinePresented], rows: [NuxieMachineHostRow])
    /// The edge stopped on this fault in the delivery.
    case fault(NuxieMachineEdgeFault)

    /// The one dismissal this report tells, if any: the fault's, or the
    /// machine's `dismiss`.
    package var dismissal: NuxieMachineEdgeDismissal? {
        switch self {
        case .fault(let fault):
            return .fault(fault)
        case .delivered(_, let rows):
            for case .dismiss(let reason) in rows { return .machine(reason: reason) }
            return nil
        }
    }
}

/// What stopped the edge: a code, and what the edge was doing.
package struct NuxieMachineEdgeFault: Error, Equatable, Sendable {
    /// `machine.<status>` for a call the session refused, the row's own code
    /// for a record that ended in a fault, `store.<why>` for a call the store
    /// could not perform, `engine.<why>` for the engine, and `edge.<why>` for
    /// a row or an event this edge cannot perform.
    package let code: String
    package let detail: String

    package init(code: String, detail: String) {
        self.code = code
        self.detail = detail
    }
}

/// One thing the edge did, in order.
package enum NuxieMachineEdgeEntry: Equatable, Sendable {
    /// The machine's `present` row: it presented `route` as `instance`.
    /// The row is recorded and not acted on; what is opened is what the
    /// session shows when the delivery is over ([`opened`]).
    case present(route: String, instance: UInt64, presentation: NuxieMachinePresentation)
    /// The machine's `pop` row, recorded and not acted on.
    case pop(instance: UInt64)
    /// The machine's `dismiss` row, recorded; its reason is told to the
    /// owner when the delivery closed something.
    case dismiss(reason: String?)
    /// The sync opened this presentation: the session shows it and the edge
    /// did not hold it.
    case opened(NuxieMachineShown)
    /// The sync closed this presentation: the edge held it and the session
    /// no longer shows it, or a fault closed everything.
    case gone(NuxieMachineShown)
    /// A call went to the store.
    case call(NuxieMachineCall)
    /// The store's reply to a call (the answer's fields or a failure),
    /// delivered in its own delivery after the frame that took it (an
    /// awaited call's to the session).
    case reply(NuxieMachineCallID, NuxieMachineReply)
    /// The store answered a call whose send is no longer out: the record
    /// that issued it has ended, and the machine dropped the call with it,
    /// or a newer send into the same mutation (or `none` assigned to it)
    /// let it go. The reply is dropped, whatever record is open by then.
    /// `reply` is none when the store could not perform a retired call.
    case dropped(NuxieMachineCallID, reply: NuxieMachineReply?)
    /// The person closed a presentation the edge no longer holds. The close
    /// belongs to it, so it goes to no one.
    case droppedClose(NuxieMachineShown)
    /// Pointers that touched the presentation named (none when nothing was
    /// shown) arrived in a frame where the edge does not hold it. They
    /// belong to the Screen the person touched, so they go to no one; the
    /// frame still runs.
    case droppedTouches(NuxieMachineShown?)
    /// The record asks for a `wake` at this moment, or at none. The host's
    /// timer delivers it ([`wake`]).
    case wakeAt(Int64?)
    case end(reason: NuxieMachineEnding, fault: String?)
    case note(NuxieMachineNote)
}

/// What one frame did.
package struct NuxieMachineFrame: Equatable, Sendable {
    /// The engine events the Screen reported in this frame, in order,
    /// reserved ones included.
    package let reported: [String]
    /// The engine's step: whether the engine itself needs another frame (an
    /// animation still running). Whatever the edge has waiting for a frame
    /// it asks for on its own ([`NuxieMachineEdge.frameAsks`]).
    package let keepGoing: Bool
}

/// Where an edge asks its host for a frame. The edge asks whenever it leaves
/// work that only a frame consumes ([`NuxieMachineEdge`]'s rule for frames);
/// the host runs a frame for each ask, on its own schedule. An ask made
/// before a host listens is heard when it starts to, so none is lost to the
/// order the two are made in.
package final class NuxieMachineFrameAsks: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: (@Sendable () -> Void)?
    private var unheard = false

    package init() {}

    /// Hear every ask from now on, on whatever thread the edge asks on, in
    /// place of any listener before.
    package func listen(_ listener: @escaping @Sendable () -> Void) {
        let missed = lock.withLock { () -> Bool in
            self.listener = listener
            defer { unheard = false }
            return unheard
        }
        if missed { listener() }
    }

    fileprivate func ask() {
        let listener = lock.withLock { () -> (@Sendable () -> Void)? in
            if self.listener == nil { unheard = true }
            return self.listener
        }
        listener?()
    }
}

/// The edge between one session of the Nux machine and the engine, with no
/// window. Each presentation the session shows is drawn from the plan's own
/// compiled views: a player of its own on the compiled records, at the
/// presentation's artboard, with the platform's own font loaded into the
/// records' font asset and the session's driver for that presentation set
/// on it once, when the sync opens it. From then on the step itself carries
/// the machine: the engine's reports go to the driver and its writes land
/// inside the same step, so the frame drawn after a step shows them. Swift
/// carries no scene write and no tap. The sync frees a presentation's
/// player when the session no longer shows it.
///
/// One frame: step each presentation's player with the pointers that
/// arrived; start each `call` at the store; record `wake at`, `end` and
/// `note`. The edge has no window and no clock: its owner draws
/// [`screen(for:)`] for each presentation it shows, schedules frames,
/// performs the rows each delivery reports and delivers `wake` when the
/// moment comes. The log is the record of what the edge did, for checks; an
/// owner acts only on what it is told.
///
/// Two rules make a delivery (a start, a frame, a wake, a close,
/// a store's answer) one whole thing:
///
/// 1. Deliveries never overlap. Every entry point runs inside one turn
///    ([`inTurn`], the edge's only serial mechanism), and a [`Delivery`] is
///    made only by [`deliver`], which takes the turn's token. A delivery
///    runs from its first row to its last, its owner told, before the next
///    turn begins; requests that arrive meanwhile wait in arrival order.
///    The session reads and [`close`] take a turn too, so they never see a
///    delivery half applied.
/// 2. A delivery never waits on the store. A `call` row starts the store's
///    work in a task of its own and the delivery goes on. When the store
///    answers, the answer waits in the edge's mailbox
///    ([`arrived`], which applies nothing, tells the owner nothing and asks
///    the host for the frame that will deliver it). Each frame's
///    turn takes the answers that arrived before it began, delivers the
///    frame, then delivers each answer as its own delivery, in arrival
///    order. So an answer is applied right after the step of the first frame
///    that begins after it arrived: that step draws what the call's own
///    writes show (a busy button) before the answer's writes replace it, on
///    the step after.
///
/// A third says what is shown: what the session's record presents, never
/// what the rows say one by one. A delivery's rows are a log of what the
/// machine did during it, and the record's presented stack is where they
/// left it. So the rows are applied in order, `present`, `pop` and
/// `dismiss` only recorded, and when the delivery is over one sync
/// ([`sync`]) compares that stack with the presentations the edge holds, by
/// identity ([`NuxieMachineShown`]): it closes the ones that are gone, from
/// the top, and opens the ones that are missing, bottom first. The edge
/// keeps nothing about a presentation that the sync did not open. So a
/// presentation begun and ended in one delivery is never opened; one shown
/// again is a new presentation, opened from nothing; and a fault, which
/// leaves nothing shown, closes everything once.
///
/// What arrives later belongs to what it was for, never to whatever is open
/// by then:
///
/// - An answer belongs to the record that issued its call. The edge keeps
///   the open record's calls it has started and not yet answered
///   ([`unanswered`]); the record's `end` row retires them all, as the
///   machine drops them. An answer to a retired call is recorded as
///   [`dropped`](NuxieMachineEdgeEntry.dropped): nothing applied, no one
///   told, no fault. So is one the session no longer has out (a newer send
///   into the same mutation let it go), which only the session can tell.
/// - A touch belongs to the presentation the person touched, and a close to
///   the one the host names. Once the session no longer shows that
///   presentation, each is recorded as dropped and goes to no one.
///
/// A host may rest between frames, so one rule says when it must not: only a
/// frame consumes some of the edge's work, and the edge asks for a frame
/// ([`frameAsks`]) wherever it leaves such work waiting ([`waitsForFrame`]:
/// at the end of each delivery and when a store's answer arrives). A host
/// keeps no record of what the edge has waiting; it runs a frame for each
/// ask, and otherwise only for its own reasons (a touch, the engine's
/// `keepGoing`, a new size).
///
/// Nothing is ignored silently. A call the session refuses, a row this edge
/// cannot perform and a call the store cannot perform are faults, and every fault takes one path
/// ([`fail`]): the edge stops and records the code. A stopped edge, or a
/// closed one, delivers nothing more.
///
/// The owner hears one report per delivery that did something for it, told
/// once when the delivery is over ([`deliver`], the only place the owner is
/// called): what is shown and the rows it performs (`wake at`, a normal
/// `end`, and the machine's first `dismiss`, for its reason), or the fault.
/// A fault in the delivery, from the machine, the store, the engine or this
/// edge, makes the report the fault, whatever rows came before it, so every
/// fault reaches the owner and as the fault. The log keeps every row either
/// way.
package actor NuxieMachineEdge {
    private let session: NuxieMachineSession
    private let store: any NuxieMachineStore
    /// The owner, told only by [`deliver`].
    private let owner: @Sendable (NuxieMachineEdgeReport) -> Void

    /// Where this edge asks its host for a frame ([`waitsForFrame`]).
    package nonisolated let frameAsks = NuxieMachineFrameAsks()

    /// Everything that belongs to one presentation, in one value: made
    /// whole by the sync that opens it and dropped whole by the sync that
    /// closes it ([`sync`]). What outlives a presentation (the session, the
    /// record's calls, the mailbox, the log) is kept outside it.
    private struct Screen {
        let presented: NuxieMachinePresented
        /// The presentation's player, with the session's driver for this
        /// presentation set on it.
        let player: NuxieNativeRuntime
        /// Whether the player has not stepped since it opened, so it has
        /// drawn nothing yet. A step clears it. The writes the session holds
        /// for the presentation are not here: the session is asked for them
        /// ([`owesStep`]).
        var undrawn: Bool
    }

    /// The presentations the edge holds, bottom first: after every
    /// delivery, what the session shows.
    private var screens: [Screen] = []

    /// The presentation on top, while one is shown. A host names a
    /// presentation when the person closes it ([`closed`]).
    package var shown: NuxieMachineShown? { screens.last?.presented.shown }
    /// What the edge shows, bottom first.
    package var stack: [NuxieMachinePresented] { screens.map(\.presented) }
    /// The open record's calls the edge has started at the store and not
    /// yet delivered an answer for. The record's `end` row retires them all.
    private var unanswered: Set<NuxieMachineCallID> = []
    /// Everything the edge did, in order.
    package private(set) var log: [NuxieMachineEdgeEntry] = []
    /// What stopped the edge, once something has.
    package private(set) var fault: NuxieMachineEdgeFault?
    /// Whether [`close`] has run.
    private var closedScreen = false

    /// Whether a turn is held, and the turns waiting for it in arrival
    /// order.
    private var turnHeld = false
    private var waitingTurns: [CheckedContinuation<Void, Never>] = []

    /// The store's answers that arrived and wait for the next frame's turn,
    /// in arrival order.
    private var mailbox: [Answer] = []
    /// The store's work in flight, by call, until its answer arrives.
    private var working: [NuxieMachineCallID: Task<Void, Never>] = [:]
    /// Whether work only a frame consumes is waiting for one, the one rule
    /// a host's frames follow. A frame consumes two things:
    ///
    /// - a step owed ([`owesStep`]), which only a frame's step pays;
    /// - a store's answer in the mailbox, which only a frame's turn
    ///   delivers.
    ///
    /// Everything else a frame does is asked for by its host: the pointers
    /// it carries, the engine's own `keepGoing`, a new size. A call still in
    /// flight is not on the list: it waits on the store, not on a frame, and
    /// its answer asks when it arrives. A stopped or closed edge delivers
    /// nothing, so nothing of it waits.
    ///
    /// The edge asks for a frame ([`askIfWaiting`]) wherever it can leave
    /// this true: at the end of each delivery, the only place a step comes
    /// to be owed (a frame's rounds included), and when an answer arrives,
    /// the only place the mailbox fills. So a host that runs a frame for
    /// each ask never rests while it holds, and keeps no state of its own
    /// about it.
    private var waitsForFrame: Bool {
        fault == nil && !closedScreen && (!mailbox.isEmpty || screens.contains(where: owesStep))
    }

    /// Whether the presentation `screen` owes a step: something it has not
    /// drawn waits for one. That is what the edge knows of
    /// ([`Screen.undrawn`]), and whether the session
    /// holds writes for the presentation that only its player's next round
    /// applies (`nux_machine.h`, THE DRIVER PATH, step 8). Any delivery can
    /// leave such writes, a round of another presentation's player
    /// included, so the session is asked each time and the edge keeps no
    /// account of them.
    ///
    /// A read that fails for another reason than the two that mean nothing
    /// is held counts as owed: the frame it asks for meets the failure in
    /// its step, as a fault ([`stepPlayers`]).
    private func owesStep(_ screen: Screen) -> Bool {
        if screen.undrawn { return true }
        return (try? holdsWrites(screen.presented.shown)) ?? true
    }

    /// Whether the session holds writes for the presentation `shown`
    /// that no round has applied. A session that has ended, or no longer
    /// shows the presentation, holds none for it.
    private func holdsWrites(_ shown: NuxieMachineShown) throws -> Bool {
        do {
            return try session.holdsWrites(for: shown)
        } catch NuxieMachineError.ended, NuxieMachineError.unknownInstance {
            return false
        }
    }

    /// The store's answer to one call: its reply, or why it could not
    /// perform the call.
    private struct Answer {
        let call: NuxieMachineCall
        let reply: Result<NuxieMachineReply, any Error>
    }

    /// Proof that the holder is inside a turn. Only [`inTurn`] makes one,
    /// and [`deliver`] takes one.
    private struct Turn {
        fileprivate init() {}
    }

    /// What one delivery tells the owner, decided as its rows and faults
    /// apply and told once when it is over.
    private struct Delivery {
        /// What the edge showed when the delivery began.
        let before: [NuxieMachineShown]
        private var rows: [NuxieMachineHostRow] = []
        private var fault: NuxieMachineEdgeFault?

        /// Only [`deliver`] makes one.
        fileprivate init(_ turn: Turn, before: [NuxieMachineShown]) {
            self.before = before
        }

        /// A row the owner performs. The machine's first `dismiss` stands:
        /// a later one in the same delivery is not told again.
        mutating func told(_ row: NuxieMachineHostRow) {
            if case .dismiss = row, rows.contains(where: { if case .dismiss = $0 { true } else { false } }) {
                return
            }
            rows.append(row)
        }

        /// The fault that stopped the edge in this delivery, over every row
        /// before it.
        mutating func faulted(_ fault: NuxieMachineEdgeFault) {
            if self.fault == nil { self.fault = fault }
        }

        /// What the owner hears once the sync has run and the edge shows
        /// `shown`: the fault; or what is shown and the rows, when either
        /// changed anything; or nothing. A dismissal is told only when the
        /// delivery closed a presentation the owner was shown: one begun and
        /// dismissed in the same delivery never reached it.
        func report(showing shown: [NuxieMachinePresented]) -> NuxieMachineEdgeReport? {
            if let fault { return .fault(fault) }
            let after = shown.map(\.shown)
            let closed = before.contains { !after.contains($0) }
            let told = rows.filter { row in
                if case .dismiss = row { return closed }
                return true
            }
            guard !told.isEmpty || after != before else { return nil }
            return .delivered(shown: shown, rows: told)
        }
    }

    /// Compile the plan into a session that draws its own views: each
    /// presentation is drawn from the compiled records by a player the
    /// session drives. `onReport`
    /// hears one report per delivery that did something for it: the fault
    /// when the delivery ended in one, otherwise what is shown and the rows
    /// it performs, in order. It is called inside the edge's turn, so it
    /// must not wait on the edge.
    package init(
        plan: NuxieMachinePlanSource,
        store: any NuxieMachineStore,
        onReport: @escaping @Sendable (NuxieMachineEdgeReport) -> Void
    ) throws {
        let session = try NuxieMachineSession(
            files: plan.files.map { ($0.path, $0.text) }, root: plan.root,
            app: plan.app, experience: plan.experience, version: plan.version)
        self.session = session
        self.store = store
        self.owner = onReport
    }

    /// What the owner draws for the presentation on top, between
    /// deliveries: the player of its compiled view while one is shown. None
    /// when nothing is shown, or once the edge has closed.
    package func screen() async -> NuxieNativeRuntime? {
        await inTurn { _ in closedScreen ? nil : screens.last?.player }
    }

    /// What the owner draws for the presentation `shown`: its player while
    /// the edge holds it, and none once the sync has closed it. A Screen on
    /// its way off screen draws nothing more, so a presentation that
    /// replaced it never shows in it.
    package func screen(for shown: NuxieMachineShown) async -> NuxieNativeRuntime? {
        await inTurn { _ in
            guard !closedScreen else { return nil }
            return screens.first(where: { $0.presented.shown == shown })?.player
        }
    }

    /// The host saw the event `event` at `now` (milliseconds since the Unix
    /// epoch), and the machine's rows for it are applied.
    package func start(event: String, now: Int64) async {
        await inTurn { turn in
            await deliver(turn, stopped: ()) { delivery in
                let rows: [NuxieMachineRow]
                do {
                    rows = try session.start(event: event, now: now)
                } catch {
                    await refused(error, doing: "start on \(event)", now: now, &delivery)
                    return
                }
                await apply(rows, now: now, &delivery)
            }
        }
    }

    /// One frame. `now` is the clock the machine reads, and `elapsedSeconds`
    /// the time the engine advances by. The frame's turn delivers the frame,
    /// then each store answer that arrived before the turn began, each as
    /// its own delivery.
    ///
    /// `pointers` touched the Screen of the presentation `touched`: the one
    /// the person's view showed when they arrived. They reach the engine
    /// only while the edge holds that presentation when the frame steps it;
    /// a delivery since (a wake that ended it, or replaced it with another)
    /// leaves them going to no one, recorded as dropped, and the frame runs
    /// without them. Pointers that touched no presentation go to no one
    /// either.
    @discardableResult
    package func frame(
        pointers: [NuxieNativePointerEvent] = [],
        on touched: NuxieMachineShown? = nil,
        elapsedSeconds: Float,
        now: Int64
    ) async -> NuxieMachineFrame {
        await inTurn { turn in
            // Answers that arrive during this turn wait for the next frame.
            let answers = mailbox
            mailbox = []
            let stepped = await deliver(turn, stopped: (reported: [String](), keepGoing: false)) { delivery in
                var forwarded = pointers
                if !pointers.isEmpty, touched == nil || !holds(touched) {
                    log.append(.droppedTouches(touched))
                    forwarded = []
                }
                return await step(pointers: forwarded, on: touched, elapsedSeconds: elapsedSeconds, now: now,
                                  &delivery)
            }
            for arrived in answers {
                await deliver(turn, stopped: ()) { delivery in
                    await answer(arrived, now: now, &delivery)
                }
            }
            return NuxieMachineFrame(reported: stepped.reported, keepGoing: stepped.keepGoing)
        }
    }

    /// The moment the record asked for with its last `wake at` has come:
    /// the machine's rows for it are applied. A host's timer delivers it;
    /// the edge keeps no clock of its own.
    ///
    /// `now` must be that moment. The machine takes a wake only at the
    /// moment it last asked for, and no event earlier than its last step; a
    /// wake at any other moment changes nothing. So a host delivers a wake
    /// before any frame or close whose `now` has passed its moment, and one
    /// that comes back late delivers each wake at its own moment, in order.
    package func wake(now: Int64) async {
        await inTurn { turn in
            await deliver(turn, stopped: ()) { delivery in
                let rows: [NuxieMachineRow]
                do {
                    rows = try session.wake(now: now)
                } catch {
                    await refused(error, doing: "wake", now: now, &delivery)
                    return
                }
                await apply(rows, now: now, &delivery)
            }
        }
    }

    /// The person closed the presentation `closing` with a system gesture.
    /// One the edge no longer holds (the machine closed it first, or its
    /// Journey is over) takes no close: it is recorded as dropped.
    package func closed(_ closing: NuxieMachineShown, now: Int64) async {
        await inTurn { turn in
            await deliver(turn, stopped: ()) { delivery in
                guard holds(closing) else {
                    log.append(.droppedClose(closing))
                    return
                }
                let rows: [NuxieMachineRow]
                do {
                    rows = try session.closed(instance: closing.instance, now: now)
                } catch {
                    await refused(error, doing: "closed", now: now, &delivery)
                    return
                }
                await apply(rows, now: now, &delivery)
            }
        }
    }

    /// Whether work only a frame consumes waits for one ([`waitsForFrame`]),
    /// between deliveries. For checks: a host runs frames by the edge's asks
    /// ([`frameAsks`]) and never needs to read this.
    package func waitingForFrame() async -> Bool {
        await inTurn { _ in waitsForFrame }
    }

    /// Whether the session's record is open, between deliveries. For checks:
    /// the edge decides nothing by it, since it does not say which record.
    package func recordOpen() async throws -> Bool {
        try await inTurn { _ in try session.recordOpen() }
    }

    /// The value of the root slot named `name` in the session's record,
    /// between deliveries.
    package func slot(_ name: String) async throws -> NuxieMachineValue {
        try await inTurn { _ in try session.slot(name) }
    }

    /// The route the session presents on top, and its instance, between
    /// deliveries.
    package func topRoute() async throws -> (route: String, instance: UInt64)? {
        try await inTurn { _ in try session.topRoute() }
    }

    /// Returns once every call the edge started at the store has been
    /// answered and its answer waits for a frame (or has been delivered). It
    /// takes no turn: the answers arrive without one. For a check that needs
    /// to know which frame delivers an answer.
    package func storeAnswered() async {
        while let work = working.values.first {
            await work.value
        }
    }

    /// Close the Screen on the engine, after the delivery in progress. The
    /// edge delivers nothing more, and answers that arrive later are not
    /// delivered. Each presentation's player is freed here, from the top,
    /// before the session, which is freed with the edge.
    package func close() async throws {
        try await inTurn { _ in
            closedScreen = true
            mailbox = []
            let players = screens.reversed().map(\.player)
            screens = []
            for player in players { try await player.close() }
        }
    }

    // MARK: Turns and deliveries

    /// The edge's one serial mechanism. Runs `body` holding the turn, after
    /// every turn asked for before it; a turn asked for meanwhile waits, and
    /// is handed the turn in arrival order when this one is over. Every
    /// entry point runs inside one, so nothing the edge does overlaps a
    /// delivery, however the actor interleaves its suspensions.
    private func inTurn<Value>(_ body: (Turn) async throws -> Value) async rethrows -> Value {
        if turnHeld {
            await withCheckedContinuation { waitingTurns.append($0) }
        } else {
            turnHeld = true
        }
        defer {
            // The next waiting turn takes it over still held, so no turn
            // asked for later can start in between.
            if waitingTurns.isEmpty {
                turnHeld = false
            } else {
                waitingTurns.removeFirst().resume()
            }
        }
        return try await body(Turn())
    }

    /// One delivery, inside a turn, unless the edge has stopped or closed:
    /// its rows are applied, then the sync shows what the session shows
    /// ([`sync`]), then the owner is told the report it decided, if any.
    /// The one place the owner is called, and the one place a [`Delivery`]
    /// is made.
    private func deliver<Value>(
        _ turn: Turn,
        stopped: Value,
        _ body: (inout Delivery) async -> Value
    ) async -> Value {
        guard fault == nil, !closedScreen else { return stopped }
        var delivery = Delivery(turn, before: screens.map(\.presented.shown))
        let result = await body(&delivery)
        await sync(&delivery)
        if let report = delivery.report(showing: stack) {
            owner(report)
        }
        askIfWaiting()
        return result
    }

    /// Ask the host for a frame when work only a frame consumes waits for
    /// one ([`waitsForFrame`]). Called where such work is left: at the end
    /// of each delivery ([`deliver`]) and when an answer arrives
    /// ([`arrived`]).
    private func askIfWaiting() {
        if waitsForFrame { frameAsks.ask() }
    }

    /// Whether the edge holds the presentation `shown`.
    private func holds(_ shown: NuxieMachineShown?) -> Bool {
        screens.contains { $0.presented.shown == shown }
    }

    /// What the session shows now, bottom first: empty once a fault has
    /// stopped the edge, since nothing outlives a fault.
    private func showing() -> [NuxieMachinePresented] {
        guard fault == nil else { return [] }
        return (try? session.presented()) ?? []
    }

    // MARK: The sync

    /// Show what the session shows, once a delivery's rows are applied:
    /// compare the record's presented stack with the presentations the edge
    /// holds, by identity, keep what both have from the bottom up, close the
    /// rest the edge holds from the top, and open the rest the session
    /// shows, bottom first. A fault leaves the session showing nothing, so
    /// it closes everything, once. Opening that fails is a fault, which then
    /// closes everything too.
    private func sync(_ delivery: inout Delivery) async {
        let wanted = showing()
        let keep = held(of: wanted)
        await closeScreens(keeping: keep, &delivery)
        guard fault == nil else {
            await closeScreens(keeping: 0, &delivery)
            return
        }
        for presented in wanted.dropFirst(keep) {
            await open(presented, &delivery)
            guard fault == nil else {
                await closeScreens(keeping: 0, &delivery)
                return
            }
        }
    }

    /// How many of `wanted`, from the bottom, the edge already holds, by
    /// identity.
    private func held(of wanted: [NuxieMachinePresented]) -> Int {
        var keep = 0
        while keep < screens.count, keep < wanted.count, screens[keep].presented.shown == wanted[keep].shown {
            keep += 1
        }
        return keep
    }

    /// Open one presentation the session shows and the edge does not hold,
    /// over those below it, with a player of its own.
    private func open(_ presented: NuxieMachinePresented, _ delivery: inout Delivery) async {
        guard let player = await openPlayer(for: presented, &delivery) else { return }
        screens.append(Screen(presented: presented, player: player, undrawn: true))
        log.append(.opened(presented.shown))
    }

    /// Close every presentation the edge holds above the first `keep`, from
    /// the top: each goes whole, its player freed, which releases its
    /// driver; the session outlives them.
    private func closeScreens(keeping keep: Int, _ delivery: inout Delivery) async {
        while screens.count > keep {
            let gone = screens.removeLast()
            log.append(.gone(gone.presented.shown))
            do {
                try await gone.player.close()
            } catch {
                fail(NuxieMachineEdgeFault(code: "engine.close", detail: "\(error)"), &delivery)
            }
        }
    }

    // MARK: Frames

    /// A frame's delivery: step the players of the presentations the edge
    /// holds. With nothing presented, nothing is drawn and nothing reports.
    private func step(
        pointers: [NuxieNativePointerEvent],
        on touched: NuxieMachineShown?,
        elapsedSeconds: Float,
        now: Int64,
        _ delivery: inout Delivery
    ) async -> (reported: [String], keepGoing: Bool) {
        guard !screens.isEmpty else { return ([], false) }
        return await stepPlayers(pointers: pointers, on: touched, elapsedSeconds: elapsedSeconds, now: now,
                                 &delivery)
    }

    /// The most settling passes one frame runs ([`stepPlayers`]). The
    /// engine bounds a step's driver rounds the same way. A frame that
    /// still owes steps after the last pass ends there: the writes stay
    /// held, the edge asks for another frame, and that frame's steps apply
    /// them.
    private static let settlingPasses = 8

    /// A frame: tell the session the moment, and step
    /// each presentation's player, bottom first. Each step carries the
    /// machine: the session's driver hears the engine's reports and its
    /// writes land in the same step, before it returns. Then the rows the
    /// step left are applied. A player whose presentation the session no
    /// longer shows (an earlier step of this frame ended it) is not stepped:
    /// its rounds would do nothing, and the sync closes it. The pointers go
    /// to the step of the presentation they touched.
    ///
    /// A round of one presentation can hold writes for another, one already
    /// stepped in this frame among them (a tap on a sheet that changes what
    /// the cover under it shows). So the frame settles before it is drawn:
    /// it asks the session which presentations hold writes and steps those
    /// players again, bottom first, with no time and no touches, until none
    /// does, at most [`settlingPasses`] times. The frame drawn shows what the
    /// machine wrote in it, on every Screen.
    ///
    /// A step that failed because a round failed has ended the session by
    /// its one fault path, and its rows end in that fault; they are applied,
    /// which stops the edge, and the sync then frees every player.
    private func stepPlayers(
        pointers: [NuxieNativePointerEvent],
        on touched: NuxieMachineShown?,
        elapsedSeconds: Float,
        now: Int64,
        _ delivery: inout Delivery
    ) async -> (reported: [String], keepGoing: Bool) {
        do {
            try session.setNow(now)
        } catch {
            await refused(error, doing: "the moment \(now)", now: now, &delivery)
            return ([], false)
        }
        var reported: [String] = []
        var keepGoing = false
        var waiting = pointers
        let players = screens.map { (shown: $0.presented.shown, player: $0.player) }
        for (shown, player) in players {
            guard fault == nil else { break }
            var forwarded: [NuxieNativePointerEvent] = []
            if shown == touched {
                forwarded = waiting
                waiting = []
            }
            guard let step = await stepPlayer(player, of: shown, pointers: forwarded, elapsedSeconds: elapsedSeconds,
                                              now: now, &delivery) else { continue }
            reported += step.events.map(\.name)
            keepGoing = keepGoing || step.keepGoing
        }
        if !waiting.isEmpty, fault == nil {
            // The presentation they touched ended earlier in this frame.
            log.append(.droppedTouches(touched))
        }
        for _ in 0..<Self.settlingPasses {
            guard fault == nil else { break }
            let owing: [(shown: NuxieMachineShown, player: NuxieNativeRuntime)]
            do {
                owing = try players.filter { try holdsWrites($0.shown) }
            } catch {
                await refused(error, doing: "which presentations hold writes", now: now, &delivery)
                break
            }
            guard !owing.isEmpty else { break }
            for (shown, player) in owing {
                guard fault == nil else { break }
                guard let step = await stepPlayer(player, of: shown, pointers: [], elapsedSeconds: 0, now: now,
                                                  &delivery) else { continue }
                reported += step.events.map(\.name)
                keepGoing = keepGoing || step.keepGoing
            }
        }
        return fault == nil ? (reported, keepGoing) : ([], false)
    }

    /// One step of the player of the presentation `shown`, then the rows it
    /// left applied. None when the session no longer shows the
    /// presentation (it is not stepped) or the step faulted.
    private func stepPlayer(
        _ player: NuxieNativeRuntime,
        of shown: NuxieMachineShown,
        pointers: [NuxieNativePointerEvent],
        elapsedSeconds: Float,
        now: Int64,
        _ delivery: inout Delivery
    ) async -> NuxieNativePlayerStepResult? {
        guard showing().contains(where: { $0.shown == shown }) else { return nil }
        let step: NuxieNativePlayerStepResult
        do {
            step = try await player.step(pointers: pointers, elapsedSeconds: elapsedSeconds)
        } catch {
            let failed = NuxieMachineEdgeFault(code: "engine.step", detail: "\(error)")
            if let rows = try? session.rows(), case .end(.fault, _)? = rows.last {
                await apply(rows, now: now, &delivery, then: failed)
            } else {
                fail(failed, &delivery)
            }
            return nil
        }
        // The step's first round applied everything held for the
        // presentation, and its later rounds applied their own writes.
        if let index = screens.firstIndex(where: { $0.presented.shown == shown }) {
            screens[index].undrawn = false
        }
        let rows: [NuxieMachineRow]
        do {
            rows = try session.rows()
        } catch {
            await refused(error, doing: "the step's rows", now: now, &delivery)
            return nil
        }
        await apply(rows, now: now, &delivery)
        return step
    }

    /// A store's answer, as its own delivery. An answer to a retired call
    /// is dropped: the record that issued it has ended, the machine dropped
    /// the call with it, and a store that failed for it has nothing left to
    /// fail. Otherwise the call is the open record's own and unanswered: a
    /// store that could not perform it is a fault, an unawaited call's
    /// reply is recorded, and an awaited call's goes to the session as it
    /// came, the answer's fields or the store's failure.
    ///
    /// The session may no longer have that send out: a newer send into the
    /// same mutation let it go, or `none` was assigned to it. The call was
    /// still performed, and its reply is a late one, not a refusal: the
    /// session answers `unknown_call`, and the reply is dropped as one to a
    /// retired call is, nothing applied and no fault. Only the session can
    /// tell, so the edge asks it first and logs the reply after: `.reply`
    /// for one it took or refused, `.dropped` for one it did not have out.
    /// Any other refusal (`reply_does_not_fit` included) is a fault.
    private func answer(_ answer: Answer, now: Int64, _ delivery: inout Delivery) async {
        let call = answer.call
        guard unanswered.remove(call.id) != nil else {
            log.append(.dropped(call.id, reply: try? answer.reply.get()))
            return
        }
        let reply: NuxieMachineReply
        switch answer.reply {
        case .success(let given):
            reply = given
        case .failure(NuxieMachineStoreFault.unknownExtern(let name)):
            fail(NuxieMachineEdgeFault(code: "store.unknown-extern",
                detail: "the store cannot perform \(name)"), &delivery)
            return
        case .failure(let error):
            fail(NuxieMachineEdgeFault(code: "store.failed", detail: "\(call.externName): \(error)"), &delivery)
            return
        }
        guard call.awaited else {
            log.append(.reply(call.id, reply))
            return
        }
        let rows: [NuxieMachineRow]
        do {
            rows = try session.reply(call.id, reply, now: now)
        } catch NuxieMachineError.unknownCall {
            log.append(.dropped(call.id, reply: reply))
            return
        } catch {
            log.append(.reply(call.id, reply))
            await refused(error, doing: "the reply \(reply)", now: now, &delivery)
            return
        }
        log.append(.reply(call.id, reply))
        await apply(rows, now: now, &delivery)
    }

    /// The store answered `call`: the answer waits for the next frame's
    /// turn, and the host is asked for that frame. It applies nothing and
    /// tells the owner nothing, so it needs no turn. An answer for a stopped
    /// or closed edge is not kept.
    private func arrived(_ call: NuxieMachineCall, _ reply: Result<NuxieMachineReply, any Error>) {
        working[call.id] = nil
        guard fault == nil, !closedScreen else { return }
        mailbox.append(Answer(call: call, reply: reply))
        askIfWaiting()
    }

    // MARK: Rows

    /// Apply one call's rows, in order, up to the first that faults, which
    /// stops the edge. `after` is a fault that follows the rows, if one does.
    ///
    /// - `present`, `pop` and `dismiss` are recorded and not acted on: what
    ///   is shown is the session's, and the sync shows it when the delivery
    ///   is over. A `dismiss` gives the owner its reason ([`Delivery`]).
    /// - `call`, `wake at`, `end` and `note` are performed in order.
    ///
    /// The log takes every row applied. A record that ended in a fault logs
    /// its `end` too: it is the record's own last row.
    private func apply(_ rows: [NuxieMachineRow], now: Int64, _ delivery: inout Delivery,
                       then after: NuxieMachineEdgeFault? = nil) async {
        for row in rows {
            guard fault == nil else { return }
            switch row {
            case .present(let route, let instance, let presentation):
                log.append(.present(route: route, instance: instance, presentation: presentation))
            case .pop(let instance):
                log.append(.pop(instance: instance))
            case .dismiss(let reason):
                log.append(.dismiss(reason: reason))
                delivery.told(.dismiss(reason: reason))
            case .call(let call):
                perform(call, &delivery)
            case .wakeAt(let moment):
                log.append(.wakeAt(moment))
                delivery.told(.wakeAt(moment))
            case .end(let reason, let code):
                // The record's unanswered calls are retired with it: the
                // machine drops them, and their answers are dropped here.
                unanswered.removeAll()
                log.append(.end(reason: reason, fault: code))
                guard reason == .finished || reason == .exited else {
                    fail(NuxieMachineEdgeFault(code: code ?? "machine.fault", detail: "the record ended in a fault"),
                         &delivery)
                    return
                }
                delivery.told(.end(reason))
            case .note(let note):
                log.append(.note(note))
            case .handOver, .unknown:
                fail(NuxieMachineEdgeFault(code: "edge.unhandled-row", detail: "\(row)"), &delivery)
                return
            }
        }
        if let after { fail(after, &delivery) }
    }

    /// A `call` row: the store's work starts in a task of its own, and the
    /// delivery goes on. Its answer arrives later ([`arrived`]) and is
    /// delivered at a frame's turn.
    private func perform(_ call: NuxieMachineCall, _ delivery: inout Delivery) {
        log.append(.call(call))
        guard call.place == .client else {
            fail(NuxieMachineEdgeFault(code: "edge.unhandled-row",
                detail: "\(call.externName) runs on the server, which this edge cannot reach"), &delivery)
            return
        }
        unanswered.insert(call.id)
        let store = store
        // The task holds the edge weakly: an edge let go of takes no answer.
        // It is recorded before this method returns, and its answer needs
        // the actor, so the answer cannot arrive before it is recorded.
        working[call.id] = Task { [weak self] in
            let reply: Result<NuxieMachineReply, any Error>
            do {
                reply = .success(try await store.perform(call))
            } catch {
                reply = .failure(error)
            }
            await self?.arrived(call, reply)
        }
    }

    /// A call the session refused, after the rows `earlier` that calls of
    /// the same delivery made. A call that ended the session still left
    /// rows, which end in its fault; they follow `earlier`, and all of them
    /// are applied as one delivery that ends in the fault ([`apply`]).
    private func refused(_ error: Error, doing what: String, now: Int64, after earlier: [NuxieMachineRow] = [],
                         _ delivery: inout Delivery) async {
        var rows = earlier
        if case NuxieMachineError.faulted(let left) = error { rows += left }
        let code = (error as? NuxieMachineError)?.code ?? "unknown"
        await apply(rows, now: now, &delivery, then: NuxieMachineEdgeFault(code: "machine.\(code)",
            detail: "the session refused \(what): \(error)"))
    }

    /// The one path for faults: the edge stops, records the code, and the
    /// delivery's report becomes the fault. The first fault is the one
    /// kept; a later one in the same delivery changes nothing, and a stopped
    /// edge delivers nothing more. Answers waiting for a frame go with it.
    /// The delivery's sync then closes everything.
    private func fail(_ fault: NuxieMachineEdgeFault, _ delivery: inout Delivery) {
        guard self.fault == nil else { return }
        self.fault = fault
        mailbox = []
        delivery.faulted(fault)
    }

    // MARK: Compiled views

    /// A presentation the session shows, opened by the sync: a player on the compiled records, at the artboard its
    /// component is drawn in, with the session's driver for this
    /// presentation set on it once. The writes the presenting step made are
    /// held for that driver and land in the player's first step. None, with
    /// the edge stopped, when any of it fails.
    private func openPlayer(for presented: NuxieMachinePresented,
                            _ delivery: inout Delivery) async -> NuxieNativeRuntime? {
        let route = presented.route
        let player: NuxieNativeRuntime
        do {
            let records = try session.sceneRecords()
            let artboard = try session.sceneArtboard(for: presented.shown)
            let font = try session.scenePlatformFont()
            player = try await Self.openRecords(records, artboard: artboard, platformFont: font)
        } catch NuxieMachineError.noArtboard {
            fail(NuxieMachineEdgeFault(code: "edge.no-view",
                detail: "present \(route) as \(presented.shown.instance); its component has no view"), &delivery)
            return nil
        } catch {
            fail(Self.openFault(error, doing: "open \(route)"), &delivery)
            return nil
        }
        do {
            let driver = try session.sceneDriver(for: presented.shown, writers: .engine)
            try await player.setDriver(driver)
        } catch {
            try? await player.close()
            fail(Self.openFault(error, doing: "drive \(route)"), &delivery)
            return nil
        }
        do {
            // Before the first step, as the engine asks: the tree follows
            // every step from the first.
            try await player.enableSemantics()
        } catch {
            try? await player.close()
            fail(Self.openFault(error, doing: "read \(route) aloud"), &delivery)
            return nil
        }
        return player
    }

    private static func openFault(_ error: any Error, doing what: String) -> NuxieMachineEdgeFault {
        if let fault = error as? NuxieMachineEdgeFault { return fault }
        if let refused = error as? NuxieMachineError {
            return NuxieMachineEdgeFault(code: "machine.\(refused.code)", detail: "the session refused to \(what)")
        }
        return NuxieMachineEdgeFault(code: "engine.open", detail: "\(what): \(error)")
    }

    /// The compiled records opened on the engine at `artboard`, on its state
    /// machine, with no view model. Text in a compiled view names no font,
    /// so it is drawn in the platform's own: this device's system face,
    /// supplied as the SDK supplies a published Screen's System font, into
    /// the one asset the session names. The records hold no other asset.
    private static func openRecords(_ records: Data, artboard: Int, platformFont: Int?) async throws
        -> NuxieNativeRuntime
    {
        let assets = try await NuxieNativeRuntime.inspectAssets(bytes: records)
        var leases: [ExperienceRuntimeSystemFontCache.Lease] = []
        var external: [Int: Data] = [:]
        for asset in assets where !asset.isEmbedded {
            guard asset.kind == .font, asset.ordinal == platformFont else {
                throw NuxieMachineEdgeFault(code: "edge.unsupplied-asset",
                    detail: "the compiled records need \(asset.name), which is not the platform's font")
            }
            // The regular face: a compiled view names no weight yet.
            let lease = try ExperienceRuntimeSystemFontCache.shared.prepare(weight: "400", style: "normal")
            leases.append(lease)
            external[asset.ordinal] = lease.candidate.bytes
        }
        if let platformFont, external[platformFont] == nil {
            throw NuxieMachineEdgeFault(code: "edge.unsupplied-asset",
                detail: "the compiled records have no font asset at \(platformFont)")
        }
        do {
            // A phone's size in points until the owner lays it out at its
            // view's size, before the first step.
            let player = try await NuxieNativeRuntime.open(
                bytes: records, artboardIndex: artboard, player: .defaultScene, pixelWidth: 390, pixelHeight: 844,
                importMode: .configured(moduleName: "nuxie", expectedAssets: assets, externalAssets: external))
            ExperienceRuntimeSystemFontCache.shared.didImport(leases)
            return player
        } catch {
            ExperienceRuntimeSystemFontCache.shared.didFailImport(leases)
            throw error
        }
    }
}
#endif
