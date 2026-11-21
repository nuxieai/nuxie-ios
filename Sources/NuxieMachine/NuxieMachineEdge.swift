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

/// A System font a published Screen requires, as the publisher's report
/// names it. The device supplies its own face for the weight and style.
package struct NuxieMachineSystemFont: Equatable, Sendable {
    package let authoredAssetID: UInt32
    package let assetUniqueName: String
    package let weight: String
    package let style: String

    package init(authoredAssetID: UInt32, assetUniqueName: String, weight: String, style: String) {
        self.authoredAssetID = authoredAssetID
        self.assetUniqueName = assetUniqueName
        self.weight = weight
        self.style = style
    }
}

/// The published Screen the edge draws for one route.
package struct NuxieMachineScreenSource: Equatable, Sendable {
    /// The published file.
    package let bytes: Data
    /// The Screen's artboard in the file.
    package let artboard: String
    /// The plan's route this Screen is the artwork for.
    package let route: String
    package let pixelWidth: UInt32
    package let pixelHeight: UInt32
    package let systemFonts: [NuxieMachineSystemFont]

    package init(bytes: Data, artboard: String, route: String, pixelWidth: UInt32, pixelHeight: UInt32,
                 systemFonts: [NuxieMachineSystemFont]) {
        self.bytes = bytes
        self.artboard = artboard
        self.route = route
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.systemFonts = systemFonts
    }
}

/// Why the edge tells its owner to dismiss.
package enum NuxieMachineEdgeDismissal: Equatable, Sendable {
    /// The machine's `dismiss` row, with its reason or none.
    case machine(reason: String?)
    /// The edge stopped on a fault.
    case fault(NuxieMachineEdgeFault)
}

/// A row the edge's owner performs with its window, as the edge applied it.
package enum NuxieMachineHostRow: Equatable, Sendable {
    /// Show `shown` with `presentation`.
    case present(NuxieMachineShown, presentation: NuxieMachinePresentation)
    /// The machine popped `shown`: it is no longer shown.
    case pop(NuxieMachineShown)
    /// The machine's `dismiss`, with its reason or none.
    case dismiss(reason: String?)
    /// The record asks for a `wake` at this moment, or at none.
    case wakeAt(Int64?)
    /// The record ended normally: finished or exited.
    case end(NuxieMachineEnding)
}

/// What one delivery tells the edge's owner, once, when it is over: the
/// rows the owner performs, in order, or the fault that stopped the edge.
/// A fault replaces the delivery's rows, since nothing the owner would do
/// for them survives it.
package enum NuxieMachineEdgeReport: Equatable, Sendable {
    /// The delivery's rows for the owner, never empty. At most one is a
    /// `dismiss`: the machine's first in the delivery.
    case rows([NuxieMachineHostRow])
    /// The edge stopped on this fault in the delivery.
    case fault(NuxieMachineEdgeFault)

    /// The one dismissal this report tells, if any: the fault's, or the
    /// machine's `dismiss`.
    package var dismissal: NuxieMachineEdgeDismissal? {
        switch self {
        case .fault(let fault):
            return .fault(fault)
        case .rows(let rows):
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
    /// An engine event the Screen reported, handed to the session.
    case reported(String)
    case present(route: String, instance: UInt64, presentation: NuxieMachinePresentation)
    case pop(instance: UInt64)
    case dismiss(reason: String?)
    /// A write landed in the Screen's cell.
    case write(cell: String, value: NuxieMachineValue)
    /// A call went to the store.
    case call(NuxieMachineCall)
    /// The store's outcome for a call, delivered in its own delivery after
    /// the frame that took it (an awaited call's to the session).
    case answer(NuxieMachineCallID, outcome: String)
    /// The store answered a retired call: the record that issued it has
    /// ended, and the machine dropped the call with it, so the answer is
    /// dropped too, whatever record is open by then. `outcome` is none when
    /// the store failed.
    case dropped(NuxieMachineCallID, outcome: String?)
    /// An engine event the Screen reported in a frame for a showing that a
    /// row earlier in the same frame ended. It belongs to that showing, so
    /// it goes to no one.
    case droppedReport(String)
    /// The person closed a showing that had already ended. The close
    /// belongs to it, so it goes to no one.
    case droppedClose(NuxieMachineShown)
    /// The record asks for a `wake` at this moment, or at none. The host's
    /// timer delivers it ([`wake`]).
    case wakeAt(Int64?)
    case end(reason: NuxieMachineEnding, fault: String?)
    case note(NuxieMachineNote)
}

/// One instance the edge shows: the machine's instance number, and which of
/// the edge's showings it is (1 for the first `present` row the edge
/// applied, one more for each after). The machine numbers instances afresh
/// in each record, so two records can show the same instance number; the
/// showing tells them apart.
package struct NuxieMachineShown: Equatable, Sendable {
    package let showing: UInt64
    package let instance: UInt64

    package init(showing: UInt64, instance: UInt64) {
        self.showing = showing
        self.instance = instance
    }
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
/// window. What it is handed decides how the machine's writes reach the
/// engine, for the whole session:
///
/// - **The plan's own views** ([`init(plan:store:onReport:)`]). The session
///   is put on the driver path before it starts. A `present` row opens a
///   player on the compiled records, at the presented instance's artboard,
///   with the platform's own font loaded into the records' font asset, and
///   sets the session's driver for that presentation on it once. From then
///   on the step itself carries the machine: the engine's reports go to the
///   driver and its writes land inside the same step, so the frame drawn
///   after a step shows them. Swift carries no scene write and no tap. A
///   `pop` or `dismiss` of the instance frees its player.
/// - **Hand-written artwork** ([`init(plan:screen:store:onReport:)`]). The
///   session stays on the row path: the published Screen is opened once,
///   each `scene` write lands in one of its cells by the name rule and shows
///   on the next step, and each event the Screen reports is handed to the
///   session by name. This path exists for the artwork alone and goes with
///   it.
///
/// One frame: step the engine with the pointers that arrived; on the row
/// path hand each reported event to the session and apply each `scene`
/// write to its cell; start each `call` at the store; record `present`,
/// `pop`, `dismiss`, `end`, `wake at` and `note`. The edge has no window and
/// no clock: its owner draws [`screen`], schedules frames, performs the rows
/// each delivery reports and delivers `wake` when the moment comes. The log
/// is the record of what the edge did, for checks; an owner acts only on
/// what it is told.
///
/// Two rules make a delivery (a start, a frame, a reported event, a close,
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
/// What arrives later belongs to what it was for, never to whatever is open
/// by then:
///
/// - An answer belongs to the record that issued its call. The edge keeps
///   the open record's calls it has started and not yet answered
///   ([`unanswered`]); the record's `end` row retires them all, as the
///   machine drops them. An answer to a retired call is recorded as
///   [`dropped`](NuxieMachineEdgeEntry.dropped): nothing applied, no one
///   told, no fault.
/// - An engine event belongs to the showing the frame stepped, and a close
///   to the showing the host names ([`NuxieMachineShown`]). Once a row has
///   ended that showing, both are recorded as dropped and go to no one.
///
/// A host may rest between frames, so one rule says when it must not: only a
/// frame consumes some of the edge's work, and the edge asks for a frame
/// ([`frameAsks`]) wherever it leaves such work waiting ([`waitsForFrame`]:
/// at the end of each delivery and when a store's answer arrives). A host
/// keeps no record of what the edge has waiting; it runs a frame for each
/// ask, and otherwise only for its own reasons (a touch, the engine's
/// `keepGoing`, a new size).
///
/// Nothing is ignored silently. A reported event the session refuses, a row
/// this edge cannot perform, a cell the Screen does not have and a call the
/// store cannot perform are faults, and every fault takes one path
/// ([`fail`]): the edge stops and records the code. A stopped edge, or a
/// closed one, delivers nothing more.
///
/// The owner hears one report per delivery that did something for it, told
/// once when the delivery is over ([`deliver`], the only place the owner is
/// called): the rows it performs (`present`, `pop`, `dismiss`, `wake at`,
/// a normal `end`), in order, or the fault. Rows and faults decide it as
/// they apply ([`Delivery`]): a fault in the delivery, from the machine, the
/// store, the engine or this edge, makes the report the fault, whatever rows
/// came before it, so every fault reaches the owner and as the fault.
/// Otherwise the owner hears at most one dismissal: the machine's first
/// `dismiss`. The log keeps every row either way.
package actor NuxieMachineEdge {
    private let session: NuxieMachineSession
    /// What draws the presented route.
    private var drawing: Drawing
    private let store: any NuxieMachineStore
    /// The owner, told only by [`deliver`].
    private let owner: @Sendable (NuxieMachineEdgeReport) -> Void

    /// Where this edge asks its host for a frame ([`waitsForFrame`]).
    package nonisolated let frameAsks = NuxieMachineFrameAsks()

    /// The presented instance of the route, while it is presented, with its
    /// showing. A host names it when the person closes it ([`closed`]).
    package private(set) var shown: NuxieMachineShown?
    /// How many `present` rows the edge has applied.
    private var showings: UInt64 = 0
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
    /// Whether the presented Screen owes a step: something it has not drawn
    /// waits for one.
    ///
    /// - On the row path, a write landed in a cell since the last step.
    /// - On the driver path, the session holds a scene write until the
    ///   presented instance's next round, which runs only inside a step, and
    ///   it cannot say whether it holds one. So every delivery that enters a
    ///   driven session while a player is presented leaves a step owed
    ///   ([`deliver`]), and so does opening a player, whose first writes are
    ///   held for its first step.
    ///
    /// A step clears it, and so does freeing the player: nothing is drawn
    /// then.
    private var stepOwed = false

    /// Whether work only a frame consumes is waiting for one, the one rule
    /// a host's frames follow. A frame consumes two things:
    ///
    /// - a step owed ([`stepOwed`]), which only a frame's step pays;
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
    /// to be owed, and when an answer arrives, the only place the mailbox
    /// fills. So a host that runs a frame for each ask never rests while it
    /// holds, and keeps no state of its own about it.
    private var waitsForFrame: Bool {
        fault == nil && !closedScreen && (stepOwed || !mailbox.isEmpty)
    }

    private enum CellKind: Equatable {
        case bool, number, text
    }

    /// What draws the presented route, chosen once by what the edge was
    /// handed.
    private enum Drawing {
        /// Hand-written artwork for one route, on the row path.
        case artwork(Artwork)
        /// The plan's compiled views, on the driver path: the player of the
        /// presented instance while one is presented.
        case compiled(NuxieNativeRuntime?)
    }

    /// One published Screen, opened once, with its root view model bound.
    private struct Artwork {
        let runtime: NuxieNativeRuntime
        /// The plan's route this Screen is the artwork for.
        let route: String
        let root: NuxieNativeViewModelReference
        /// The Screen's cells, by name, with the kind of value each holds.
        let cells: [String: CellKind]
    }

    /// The store's answer to one call: its outcome's name, or why it could
    /// not perform the call.
    private struct Answer {
        let call: NuxieMachineCall
        let outcome: Result<String, any Error>
    }

    /// Proof that the holder is inside a turn. Only [`inTurn`] makes one,
    /// and [`deliver`] takes one.
    private struct Turn {
        fileprivate init() {}
    }

    /// What one delivery tells the owner, decided as its rows and faults
    /// apply and told once when it is over.
    private struct Delivery {
        private var rows: [NuxieMachineHostRow] = []
        private var fault: NuxieMachineEdgeFault?

        /// Only [`deliver`] makes one.
        fileprivate init(_ turn: Turn) {}

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

        /// What the owner hears: the fault, the rows, or nothing.
        var report: NuxieMachineEdgeReport? {
            if let fault { return .fault(fault) }
            return rows.isEmpty ? nil : .rows(rows)
        }
    }

    /// Compile the plan into a session that draws its own views: the
    /// session goes on the driver path, and each presented instance is
    /// drawn from the compiled records by a player the session drives.
    /// `onReport` hears one report per delivery that did something for it:
    /// the fault when the delivery ended in one, otherwise the rows it
    /// performs, in order. It is called inside the edge's turn, so it must
    /// not wait on the edge.
    package init(
        plan: NuxieMachinePlanSource,
        store: any NuxieMachineStore,
        onReport: @escaping @Sendable (NuxieMachineEdgeReport) -> Void
    ) throws {
        let session = try NuxieMachineSession(
            files: plan.files.map { ($0.path, $0.text) }, root: plan.root,
            app: plan.app, experience: plan.experience, version: plan.version)
        try session.driveScene()
        self.session = session
        self.drawing = .compiled(nil)
        self.store = store
        self.owner = onReport
    }

    /// Compile the plan into a session on the row path, and open its
    /// hand-written artwork, the published Screen, on the engine with its
    /// root view model bound and its System fonts supplied by this device.
    /// `onReport` is as above.
    package init(
        plan: NuxieMachinePlanSource,
        screen: NuxieMachineScreenSource,
        store: any NuxieMachineStore,
        onReport: @escaping @Sendable (NuxieMachineEdgeReport) -> Void
    ) async throws {
        let session = try NuxieMachineSession(
            files: plan.files.map { ($0.path, $0.text) }, root: plan.root,
            app: plan.app, experience: plan.experience, version: plan.version)
        let runtime = try await Self.openScreen(screen)
        do {
            let root = try await runtime.rootViewModelReference()
            let snapshot = try await runtime.snapshot(root)
            self.drawing = .artwork(Artwork(runtime: runtime, route: screen.route, root: root,
                                            cells: Self.cells(of: snapshot)))
        } catch {
            try? await runtime.close()
            throw error
        }
        self.session = session
        self.store = store
        self.owner = onReport
    }

    /// What the owner draws now, between deliveries: the published Screen,
    /// or the player of the presented instance's compiled view while one is
    /// presented. None when nothing is presented on the driver path, or
    /// once the edge has closed.
    package func screen() async -> NuxieNativeRuntime? {
        await inTurn { _ in
            guard !closedScreen else { return nil }
            switch drawing {
            case .artwork(let artwork): return artwork.runtime
            case .compiled(let player): return player
            }
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
    @discardableResult
    package func frame(
        pointers: [NuxieNativePointerEvent] = [],
        elapsedSeconds: Float,
        now: Int64
    ) async -> NuxieMachineFrame {
        await inTurn { turn in
            // Answers that arrive during this turn wait for the next frame.
            let answers = mailbox
            mailbox = []
            let stepped = await deliver(turn, stopped: (reported: [String](), keepGoing: false)) { delivery in
                await step(pointers: pointers, elapsedSeconds: elapsedSeconds, now: now, &delivery)
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

    /// An engine event the Screen reported, handed to the session by the name
    /// the engine gave it. Package-visible so a check can hand the edge an
    /// event the published Screen never reports. On the driver path the
    /// engine's reports reach the session only through its driver, so one
    /// handed in here is a fault.
    package func handleReported(_ name: String, now: Int64) async {
        await inTurn { turn in
            await deliver(turn, stopped: ()) { delivery in
                guard case .artwork = drawing else {
                    fail(NuxieMachineEdgeFault(code: "edge.unhandled-event",
                        detail: "\(name) handed in by hand; a compiled view's reports go to its driver"), &delivery)
                    return
                }
                await hear(name, on: shown, now: now, &delivery)
            }
        }
    }

    /// The person closed the showing `closing` with a system gesture. A
    /// showing that has already ended (the machine dismissed or popped it
    /// first) takes no close: it is recorded as dropped. A showing this edge
    /// never made is a fault.
    package func closed(_ closing: NuxieMachineShown, now: Int64) async {
        await inTurn { turn in
            await deliver(turn, stopped: ()) { delivery in
                guard closing == shown else {
                    if closing.showing >= 1 && closing.showing <= showings {
                        log.append(.droppedClose(closing))
                    } else {
                        fail(NuxieMachineEdgeFault(code: "edge.unhandled-event",
                            detail: "closed showing \(closing.showing), which this edge never made"), &delivery)
                    }
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
    /// delivered. A presented instance's player is freed here, before the
    /// session, which is freed with the edge.
    package func close() async throws {
        try await inTurn { _ in
            closedScreen = true
            mailbox = []
            switch drawing {
            case .artwork(let artwork):
                try await artwork.runtime.close()
            case .compiled(let player):
                drawing = .compiled(nil)
                try await player?.close()
            }
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

    /// One delivery, inside a turn, unless the edge has stopped or closed;
    /// then the owner is told the report it decided, if any. The one place
    /// the owner is called, and the one place a [`Delivery`] is made.
    private func deliver<Value>(
        _ turn: Turn,
        stopped: Value,
        _ body: (inout Delivery) async -> Value
    ) async -> Value {
        guard fault == nil, !closedScreen else { return stopped }
        // A delivery into a driven session may leave writes held for the
        // presented instance's next round; only a step runs one ([`stepOwed`]).
        if case .compiled(.some) = drawing { stepOwed = true }
        var delivery = Delivery(turn)
        let result = await body(&delivery)
        if let report = delivery.report {
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

    /// A frame's delivery: step what draws the presented route.
    private func step(
        pointers: [NuxieNativePointerEvent],
        elapsedSeconds: Float,
        now: Int64,
        _ delivery: inout Delivery
    ) async -> (reported: [String], keepGoing: Bool) {
        switch drawing {
        case .artwork(let artwork):
            return await step(artwork, pointers: pointers, elapsedSeconds: elapsedSeconds, now: now, &delivery)
        case .compiled(let player?):
            return await step(player, pointers: pointers, elapsedSeconds: elapsedSeconds, now: now, &delivery)
        case .compiled(nil):
            // Nothing is presented, so nothing is drawn and nothing reports.
            stepOwed = false
            return ([], false)
        }
    }

    /// A frame on the driver path: tell the session the moment, and step
    /// the player. The step carries the machine: the session's driver hears
    /// the engine's reports and its writes land in the same step, before it
    /// returns. Then the rows the step left are applied. A step that failed
    /// because a round failed has ended the session by its one fault path,
    /// and its rows end in that fault; they are applied, which frees the
    /// player and stops the edge.
    private func step(
        _ player: NuxieNativeRuntime,
        pointers: [NuxieNativePointerEvent],
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
        let step: NuxieNativePlayerStepResult
        do {
            step = try await player.step(pointers: pointers, elapsedSeconds: elapsedSeconds)
        } catch {
            if let rows = try? session.rows(), case .end(.fault, _)? = rows.last {
                await apply(rows, now: now, &delivery)
            }
            fail(NuxieMachineEdgeFault(code: "engine.step", detail: "\(error)"), &delivery)
            return ([], false)
        }
        // The step's first round applied everything held for the instance,
        // and its later rounds applied their own writes.
        stepOwed = false
        let rows: [NuxieMachineRow]
        do {
            rows = try session.rows()
        } catch {
            await refused(error, doing: "the step's rows", now: now, &delivery)
            return ([], false)
        }
        await apply(rows, now: now, &delivery)
        return (step.events.map(\.name), step.keepGoing)
    }

    /// A frame on the row path: step the Screen and hand its events to the
    /// session, each for the showing the step drew.
    private func step(
        _ artwork: Artwork,
        pointers: [NuxieNativePointerEvent],
        elapsedSeconds: Float,
        now: Int64,
        _ delivery: inout Delivery
    ) async -> (reported: [String], keepGoing: Bool) {
        let stepped = shown
        // This step lays out every cell written before it; a write the
        // events below make shows on the next.
        stepOwed = false
        let step: NuxieNativePlayerStepResult
        do {
            step = try await artwork.runtime.step(pointers: pointers, elapsedSeconds: elapsedSeconds)
        } catch {
            fail(NuxieMachineEdgeFault(code: "engine.step", detail: "\(error)"), &delivery)
            return ([], false)
        }
        var reported: [String] = []
        for event in step.events {
            reported.append(event.name)
            guard fault == nil else { continue }
            // A reserved (`$`) event is the engine's own, and an unnamed one
            // with no link is a bare notification: a phone drops both, as the
            // SDK's Screen does for every Screen it shows. The Screen's named
            // events are the ones the machine hears. Both still appear in the
            // frame's `reported`.
            if event.name.hasPrefix("$") || (event.name.isEmpty && event.url.isEmpty) { continue }
            guard event.url.isEmpty else {
                fail(NuxieMachineEdgeFault(code: "edge.unhandled-event",
                    detail: "the Screen reported a link to \(event.url), which this edge cannot open"), &delivery)
                continue
            }
            await hear(event.name, on: stepped, now: now, &delivery)
        }
        return (reported, step.keepGoing)
    }

    /// An engine event the Screen reported for the showing `on`, handed to
    /// the session. One reported while nothing was shown is a fault; one
    /// whose showing a row has ended since is dropped.
    private func hear(_ name: String, on reportedFor: NuxieMachineShown?, now: Int64,
                      _ delivery: inout Delivery) async {
        guard fault == nil else { return }
        guard let reportedFor else {
            fail(NuxieMachineEdgeFault(code: "edge.unhandled-event",
                detail: "the Screen reported \(name) while nothing is presented"), &delivery)
            return
        }
        guard reportedFor == shown else {
            log.append(.droppedReport(name))
            return
        }
        log.append(.reported(name))
        let rows: [NuxieMachineRow]
        do {
            rows = try session.engineEvent(instance: reportedFor.instance, name: name, now: now)
        } catch {
            await refused(error, doing: "the engine event \(name)", now: now, &delivery)
            return
        }
        await apply(rows, now: now, &delivery)
    }

    /// A store's answer, as its own delivery. An answer to a retired call
    /// is dropped: the record that issued it has ended, the machine dropped
    /// the call with it, and a store that failed for it has nothing left to
    /// fail. Otherwise the call is the open record's own and unanswered: a
    /// store that could not perform it is a fault, an unawaited call's
    /// outcome is recorded, and an awaited call's goes to the session, whose
    /// refusal (`unknown_call` included) is a fault.
    private func answer(_ answer: Answer, now: Int64, _ delivery: inout Delivery) async {
        let call = answer.call
        guard unanswered.remove(call.id) != nil else {
            log.append(.dropped(call.id, outcome: try? answer.outcome.get()))
            return
        }
        let outcome: String
        switch answer.outcome {
        case .success(let named):
            outcome = named
        case .failure(NuxieMachineStoreFault.unknownExtern(let name)):
            fail(NuxieMachineEdgeFault(code: "store.unknown-extern",
                detail: "the store cannot perform \(name)"), &delivery)
            return
        case .failure(let error):
            fail(NuxieMachineEdgeFault(code: "store.failed", detail: "\(call.externName): \(error)"), &delivery)
            return
        }
        log.append(.answer(call.id, outcome: outcome))
        guard call.awaited else { return }
        let rows: [NuxieMachineRow]
        do {
            rows = try session.answer(call.id, outcome: outcome, now: now)
        } catch {
            await refused(error, doing: "answer \(outcome)", now: now, &delivery)
            return
        }
        await apply(rows, now: now, &delivery)
    }

    /// The store answered `call`: the answer waits for the next frame's
    /// turn, and the host is asked for that frame. It applies nothing and
    /// tells the owner nothing, so it needs no turn. An answer for a stopped
    /// or closed edge is not kept.
    private func arrived(_ call: NuxieMachineCall, _ outcome: Result<String, any Error>) {
        working[call.id] = nil
        guard fault == nil, !closedScreen else { return }
        mailbox.append(Answer(call: call, outcome: outcome))
        askIfWaiting()
    }

    // MARK: Rows

    private func apply(_ rows: [NuxieMachineRow], now: Int64, _ delivery: inout Delivery) async {
        for row in rows {
            guard fault == nil else { return }
            switch row {
            case .present(let route, let instance, let presentation):
                switch drawing {
                case .artwork(let artwork):
                    guard route == artwork.route, shown == nil else {
                        fail(NuxieMachineEdgeFault(code: "edge.no-artwork",
                            detail: "present \(route) as \(instance); this edge draws \(artwork.route) once"), &delivery)
                        return
                    }
                case .compiled:
                    guard let shown else { break }
                    fail(NuxieMachineEdgeFault(code: "edge.no-host",
                        detail: "present \(route) as \(instance) while \(shown.instance) is presented"), &delivery)
                    return
                }
                if case .compiled = drawing {
                    guard await openPlayer(for: instance, route: route, &delivery) else { return }
                }
                showings += 1
                let presented = NuxieMachineShown(showing: showings, instance: instance)
                shown = presented
                log.append(.present(route: route, instance: instance, presentation: presentation))
                delivery.told(.present(presented, presentation: presentation))
            case .pop(let instance):
                guard let popped = shown, instance == popped.instance else {
                    fail(NuxieMachineEdgeFault(code: "edge.unhandled-row",
                        detail: "pop \(instance), which is not presented"), &delivery)
                    return
                }
                shown = nil
                log.append(.pop(instance: instance))
                await closePlayer(&delivery)
                delivery.told(.pop(popped))
            case .dismiss(let reason):
                shown = nil
                log.append(.dismiss(reason: reason))
                await closePlayer(&delivery)
                delivery.told(.dismiss(reason: reason))
            case .sceneSet(let instance, let object, let key, let value):
                guard case .artwork(let artwork) = drawing else {
                    fail(NuxieMachineEdgeFault(code: "edge.unhandled-row",
                        detail: "a write to \(object).\(key) as a row; a compiled view is written by its driver"),
                        &delivery)
                    return
                }
                await write(artwork, instance: instance, cell: nuxieMachineCellName(object: object, key: key),
                            value: value, &delivery)
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
                    fail(NuxieMachineEdgeFault(code: code ?? "machine.fault",
                        detail: "the record ended in a fault"), &delivery)
                    return
                }
                delivery.told(.end(reason))
            case .note(let note):
                log.append(.note(note))
            case .handOver, .unknown:
                fail(NuxieMachineEdgeFault(code: "edge.unhandled-row", detail: "\(row)"), &delivery)
            }
        }
    }

    /// A `scene` write: the value lands in the Screen's cell
    /// `state/<cell>` and shows on the next step.
    private func write(_ artwork: Artwork, instance: UInt64, cell: String, value: NuxieMachineValue,
                       _ delivery: inout Delivery) async {
        guard instance == shown?.instance else {
            fail(NuxieMachineEdgeFault(code: "edge.unhandled-row",
                detail: "a write to \(cell) of instance \(instance), which is not presented"), &delivery)
            return
        }
        let path = "state/\(cell)"
        let root = artwork.root
        let mutation: NuxieNativeViewModelMutation
        switch (artwork.cells[cell], value) {
        case (.bool, .bool(let yes)): mutation = .setBool(instance: root, path: path, value: yes)
        case (.number, .number(let number)): mutation = .setNumber(instance: root, path: path, value: Float(number))
        case (.text, .text(let text)): mutation = .setString(instance: root, path: path, value: Data(text.utf8))
        case (nil, _):
            fail(NuxieMachineEdgeFault(code: "edge.unknown-cell",
                detail: "the Screen has no cell \(cell) for \(value)"), &delivery)
            return
        default:
            fail(NuxieMachineEdgeFault(code: "edge.unknown-cell",
                detail: "the Screen's cell \(cell) does not hold a value like \(value)"), &delivery)
            return
        }
        do {
            _ = try await artwork.runtime.mutateViewModel([mutation])
        } catch {
            fail(NuxieMachineEdgeFault(code: "engine.write", detail: "\(cell): \(error)"), &delivery)
            return
        }
        stepOwed = true
        log.append(.write(cell: cell, value: value))
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
            let outcome: Result<String, any Error>
            do {
                outcome = .success(try await store.perform(call))
            } catch {
                outcome = .failure(error)
            }
            await self?.arrived(call, outcome)
        }
    }

    /// A call the session refused. A call that ended the session still
    /// left rows, which end in its fault, and they are applied first.
    private func refused(_ error: Error, doing what: String, now: Int64, _ delivery: inout Delivery) async {
        if case NuxieMachineError.faulted(let rows) = error {
            await apply(rows, now: now, &delivery)
        }
        let code = (error as? NuxieMachineError)?.code ?? "unknown"
        fail(NuxieMachineEdgeFault(code: "machine.\(code)", detail: "the session refused \(what): \(error)"), &delivery)
    }

    /// The one path for faults: the edge stops, records the code, and the
    /// delivery's report becomes the fault. The first fault is the one
    /// kept; a later one in the same delivery changes nothing, and a stopped
    /// edge delivers nothing more. Answers waiting for a frame go with it.
    private func fail(_ fault: NuxieMachineEdgeFault, _ delivery: inout Delivery) {
        guard self.fault == nil else { return }
        self.fault = fault
        mailbox = []
        delivery.faulted(fault)
    }

    // MARK: Compiled views

    /// A `present` row on the driver path: a player for `instance` on the
    /// compiled records, at the artboard its component is drawn in, with the
    /// session's driver for this presentation set on it once. The writes the
    /// presenting step made are held for that driver and land in the
    /// player's first step. False, with the edge stopped, when any of it
    /// fails.
    private func openPlayer(for instance: UInt64, route: String, _ delivery: inout Delivery) async -> Bool {
        let player: NuxieNativeRuntime
        do {
            let records = try session.sceneRecords()
            let artboard = try session.sceneArtboard(instance: instance)
            let font = try session.scenePlatformFont()
            player = try await Self.openRecords(records, artboard: artboard, platformFont: font)
        } catch NuxieMachineError.noArtboard {
            fail(NuxieMachineEdgeFault(code: "edge.no-artwork",
                detail: "present \(route) as \(instance); its component has no view"), &delivery)
            return false
        } catch {
            fail(Self.openFault(error, doing: "open \(route)"), &delivery)
            return false
        }
        do {
            let driver = try session.sceneDriver(instance: instance, writers: .engine)
            try await player.setDriver(driver)
        } catch {
            try? await player.close()
            fail(Self.openFault(error, doing: "drive \(route)"), &delivery)
            return false
        }
        drawing = .compiled(player)
        stepOwed = true
        return true
    }

    /// The presented instance's player, freed when its presentation ends:
    /// freeing it releases its driver, and the session outlives it.
    private func closePlayer(_ delivery: inout Delivery) async {
        guard case .compiled(let player?) = drawing else { return }
        drawing = .compiled(nil)
        stepOwed = false
        do {
            try await player.close()
        } catch {
            fail(NuxieMachineEdgeFault(code: "engine.close", detail: "\(error)"), &delivery)
        }
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

    // MARK: Opening

    /// The Screen's own state: the values under the root's `state`, by name.
    private static func cells(of snapshot: NuxieNativeViewModelSnapshot) -> [String: CellKind] {
        guard case .referencedInstance(let state)? = snapshot.values.first(where: {
            $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "state"
        })?.value else { return [:] }
        var cells: [String: CellKind] = [:]
        for value in snapshot.values where value.ownerInstanceID == state {
            switch value.value {
            case .bool: cells[value.name] = .bool
            case .number: cells[value.name] = .number
            case .bytes: cells[value.name] = .text
            default: break
            }
        }
        return cells
    }

    /// The published Screen opened on the engine, its root view model bound,
    /// each required System font supplied from this device as the SDK
    /// supplies it for a published Screen.
    private static func openScreen(_ screen: NuxieMachineScreenSource) async throws -> NuxieNativeRuntime {
        let assets = try await NuxieNativeRuntime.inspectAssets(bytes: screen.bytes)
        var leases: [ExperienceRuntimeSystemFontCache.Lease] = []
        var external: [Int: Data] = [:]
        var supplied = Set<String>()
        for asset in assets where !asset.isEmbedded {
            // A published asset's unique name is its name and its authored
            // id, as the SDK's Screen keys it.
            guard asset.kind == .font, let authoredID = asset.authoredID, let font = screen.systemFonts.first(where: {
                $0.authoredAssetID == authoredID && $0.assetUniqueName == "\(asset.name)-\(authoredID)"
            }) else {
                throw NuxieMachineEdgeFault(code: "edge.unsupplied-asset",
                    detail: "the Screen needs \(asset.name), which is not a System font it names")
            }
            let lease = try ExperienceRuntimeSystemFontCache.shared.prepare(weight: font.weight, style: font.style)
            leases.append(lease)
            external[asset.ordinal] = lease.candidate.bytes
            supplied.insert(font.assetUniqueName)
        }
        if let missing = screen.systemFonts.first(where: { !supplied.contains($0.assetUniqueName) }) {
            throw NuxieMachineEdgeFault(code: "edge.unsupplied-asset",
                detail: "the Screen has no font asset \(missing.assetUniqueName)")
        }
        do {
            let runtime = try await NuxieNativeRuntime.open(
                bytes: screen.bytes, artboardName: screen.artboard, player: .defaultScene,
                pixelWidth: screen.pixelWidth, pixelHeight: screen.pixelHeight, bindDefaultViewModel: true,
                importMode: .configured(moduleName: "nuxie", expectedAssets: assets, externalAssets: external))
            ExperienceRuntimeSystemFontCache.shared.didImport(leases)
            return runtime
        } catch {
            ExperienceRuntimeSystemFontCache.shared.didFailImport(leases)
            throw error
        }
    }
}

// PROVISIONAL: the Screen's state cell that holds the property `key` of the
// object named `object` is `<object>_<key>`. This is the name rule of the
// stand-in artwork, and its one owner is `cell_name` in the machine's C
// interface crate (`nux-machine-capi`, `src/session.rs`). The C interface
// hands over the object and the key apart, so the edge joins them here and
// nowhere else. Object numbers and engine property keys in the scene pool
// replace it.
func nuxieMachineCellName(object: String, key: String) -> String {
    "\(object)_\(key)"
}
#endif
