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

/// One file of the Experience's folder that is not a source file, as the
/// host found it: facts about it, never its bytes. A view lays a picture
/// out from its size in pixels before any bytes exist; the bytes of a
/// picture or a face come from a byte source when a presentation that
/// shows the file opens ([`NuxieMachineByteSource`]).
package struct NuxieMachineAsset: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        /// A PNG, JPEG or WebP file whose header gives its size in pixels.
        case picture(width: UInt32, height: UInt32)
        /// A TTF file: a face a `font` line names.
        case font
        /// Any other file, a file named as a picture whose header gives no
        /// size among them.
        case other
    }

    /// Its path from the folder, `/` between its parts, as an `image`
    /// names it (`assets/hero.png`).
    package let path: String
    package let kind: Kind
    /// How many bytes it holds.
    package let byteCount: UInt64

    package init(path: String, kind: Kind, byteCount: UInt64) {
        self.path = path
        self.kind = kind
        self.byteCount = byteCount
    }
}

/// What a session compiles: the files, the folder's other files beside
/// them, the root file's path without `.nux`, and the header's app,
/// Experience and version.
package struct NuxieMachinePlanSource: Equatable, Sendable {
    package let files: [NuxieMachineSourceFile]
    package let assets: [NuxieMachineAsset]
    package let root: String
    package let app: String
    package let experience: String
    package let version: UInt32

    package init(files: [NuxieMachineSourceFile], assets: [NuxieMachineAsset], root: String, app: String,
                 experience: String, version: UInt32) {
        self.files = files
        self.assets = assets
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

/// One presentation of what is shown: its identity, its route, how the
/// route is presented, the heights a sheet may rest at, and what a swipe
/// down on a sheet does now.
package struct NuxieMachinePresented: Equatable, Sendable {
    package let shown: NuxieMachineShown
    package let route: String
    package let presentation: NuxieMachinePresentation
    /// The heights the presentation may rest at, in the order its row of
    /// the router's table writes them. None when the row writes none, and
    /// for every presentation of a plan with `routes`.
    package let detents: [NuxieMachineDetent]
    /// What a swipe down on the sheet does now, as the machine answers it
    /// (`nux_machine_swipe_would`), read with what is shown after every
    /// delivery and every round. `nil` for anything that is not a sheet.
    package let swipeDown: NuxieMachineSwipeWould?

    package init(shown: NuxieMachineShown, route: String, presentation: NuxieMachinePresentation,
                 detents: [NuxieMachineDetent] = [], swipeDown: NuxieMachineSwipeWould? = nil) {
        self.shown = shown
        self.route = route
        self.presentation = presentation
        self.detents = detents
        self.swipeDown = swipeDown
    }
}

/// What came of a swipe the edge was asked to deliver.
package enum NuxieMachineSwipeDid: Equatable, Sendable {
    /// It was delivered, and this is what the machine did with it, which
    /// can differ from what the presentation's `swipeDown` last said.
    case delivered(NuxieMachineSwipeWould)
    /// The edge no longer holds the presentation: nothing was delivered.
    case dropped
    /// Nothing was delivered: the edge had stopped or closed, or the
    /// session refused the swipe, which stopped it.
    case stopped
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
    /// Where the files the shown pages need stand, told when it changes
    /// ([`NuxieMachineAssets`]).
    case assets(NuxieMachineAssets)
}

/// Where the folder's files that the shown pages draw stand, by path: what
/// the loading and recovery screens show.
package enum NuxieMachineAssets: Equatable, Sendable {
    /// A page is held for these paths, whose bytes have not arrived.
    case waiting([String])
    /// Every file is in, and no page is held.
    case ready
    /// A page is held, and these paths failed; the rest are kept or still
    /// coming.
    case failed([NuxieMachineAssetFailure])
}

/// One file the byte source could not give, and why.
package struct NuxieMachineAssetFailure: Equatable, Sendable {
    /// Its path in the folder (`assets/hero.png`).
    package let path: String
    package let reason: ExperienceShellRecoveryReason

    package init(path: String, reason: ExperienceShellRecoveryReason) {
        self.path = path
        self.reason = reason
    }
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
    /// did not hold it. A presentation held for its files is opened when
    /// they are in.
    case opened(NuxieMachineShown)
    /// The sync took this presentation with no player: a file its page
    /// draws has no bytes yet.
    case held(NuxieMachineShown)
    /// The owner was told where the files stand.
    case assets(NuxieMachineAssets)
    /// The host reported its own fault with no presentation held for its
    /// files: every page had opened, so there was nothing to give up on.
    case droppedExit
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
    /// A swipe on this presentation was delivered, and the machine did
    /// this with it.
    case swipe(NuxieMachineShown, NuxieMachineSwipeGesture, did: NuxieMachineSwipeWould)
    /// A swipe on a presentation the edge no longer holds. It belongs to
    /// that presentation, so it goes to no one.
    case droppedSwipe(NuxieMachineShown)
    /// Pointers or a screen reader's taps that touched the presentation
    /// named (none when nothing was shown) arrived in a frame where the edge
    /// does not hold it. They belong to the Screen the person touched, so
    /// they go to no one; the frame still runs.
    case droppedTouches(NuxieMachineShown?)
    /// The engine refused a screen reader's tap on node `node` of the
    /// presentation named: the snapshot it was asked of is no longer the
    /// player's, or the node is gone or no longer offers a tap. The tap is
    /// dropped and never sent again as a touch; the frame still runs.
    case refusedSemanticTap(NuxieMachineShown, node: UInt32)
    /// The engine refused a screen reader's move of a `scroll` of the
    /// presentation named ([`NuxieMachineScrollRequest`]): its snapshot is
    /// no longer the player's, or the node or region is gone. The frame
    /// still runs, and the outcome goes back to the component that asked
    /// ([`NuxieMachineFrame.scrolled`]).
    case refusedScroll(NuxieMachineShown, NuxieMachineScrollRequest)
    /// The session took the client's environment ([`environment`]): before
    /// a start, kept for its first frame; with a record open, delivered to
    /// it.
    case environment(NuxieMachineEnvironment)
    /// The session took where the person is, in the app or away
    /// ([`presence`]): before a start, kept for it; with a record open,
    /// delivered to it.
    case presence(here: Bool)
    /// The session took where the presentation is shown ([`place`]),
    /// delivered to the record.
    case place(NuxieMachineShown, NuxieMachineScreenPlace)
    /// A place for a presentation the edge no longer holds. It belongs to
    /// that presentation, so it goes to no one.
    case droppedPlace(NuxieMachineShown)
    /// The record asks for a `wake` at this moment, or at none. The host's
    /// timer delivers it ([`wake`]).
    case wakeAt(Int64?)
    case end(reason: NuxieMachineEnding, fault: String?)
    case note(NuxieMachineNote)
    /// The machine's `hand over` row: this copy's part on this device is
    /// over (it shows nothing, owes nothing and awaits nothing), and the
    /// record has not ended. There is no server to carry it to, so this
    /// host keeps the record: the row is recorded, and the record stays
    /// open with its wake. The server's part arrives with the SDK's server
    /// work.
    case handOver
}

/// A screen reader's tap on one node of a presentation's semantic snapshot:
/// the snapshot it was asked of and the node. A frame queues it on that
/// presentation's player before the step ([`NuxieMachineEdge.frame`]), so
/// the node's own listener hears it, never what is drawn at its place.
package struct NuxieMachineSemanticTap: Equatable, Sendable {
    package let captureID: UUID
    package let nodeID: UInt32

    package init(captureID: UUID, nodeID: UInt32) {
        self.captureID = captureID
        self.nodeID = nodeID
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
    /// What came of each screen reader's move of a `scroll` the frame
    /// carried, in order; a frame that dropped them answers each refused.
    package let scrolled: [NuxieMachineScrolled]
    /// The presentations whose last step in this frame reported itself
    /// settled: nothing in its player, a settling scroller included, needs
    /// another step.
    package let settled: Set<NuxieMachineShown>

    package init(reported: [String], keepGoing: Bool, scrolled: [NuxieMachineScrolled] = [],
                 settled: Set<NuxieMachineShown> = []) {
        self.reported = reported
        self.keepGoing = keepGoing
        self.scrolled = scrolled
        self.settled = settled
    }
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
///    The byte source is waited on the same way. The start asks it for every
///    file the views draw, each in a task of its own ([`ask`]), and goes on.
///    A presentation the session shows before every file is in is held with
///    no player ([`Screen.player`]), and the owner is told where the files
///    stand ([`NuxieMachineAssets`]). Each answer is kept as it arrives
///    ([`assetArrived`], which applies nothing and asks for a frame), and the
///    next frame's turn opens the held players once every file is in
///    ([`settleAssets`]). A file the source could not give is a failed path,
///    told by path; [`refreshAssets`] asks again for those, and only those.
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
    /// Where the bytes of the folder's files a view shows come from.
    private let bytes: any NuxieMachineByteSource
    /// The owner, told only by [`deliver`].
    private let owner: @Sendable (NuxieMachineEdgeReport) -> Void

    /// Where this edge asks its host for a frame ([`waitsForFrame`]).
    package nonisolated let frameAsks = NuxieMachineFrameAsks()

    /// Everything that belongs to one presentation, in one value: made
    /// whole by the sync that opens it and dropped whole by the sync that
    /// closes it ([`sync`]). What outlives a presentation (the session, the
    /// record's calls, the mailbox, the log) is kept outside it.
    private struct Screen {
        /// What the session last showed of it: its identity never changes,
        /// and the sync takes its `swipeDown` afresh after every delivery.
        var presented: NuxieMachinePresented
        /// The presentation's player, with the session's driver for this
        /// presentation set on it. None while the presentation is held for
        /// its files: nothing is stepped or drawn for it until they are in.
        var player: NuxieNativeRuntime?
        /// The color the presentation's surface is cleared to before each
        /// draw, read with its artboard when its player opened, and set with
        /// it. 0 while it is held for its files, when nothing is drawn.
        var canvas: UInt32
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

    /// The folder paths of the files the views draw, faces and pictures,
    /// in the scene's order. Read at the start.
    private var paths: [String] = []
    /// The bytes the source gave, by path.
    private var supplied: [String: Data] = [:]
    /// The paths the source could not give, and why.
    private var failed: [String: ExperienceShellRecoveryReason] = [:]
    /// The asks in flight, by path, until their answer arrives.
    private var fetching: [String: Task<Void, Never>] = [:]
    /// Whether an answer arrived that no frame's turn has looked at yet.
    private var assetNews = false
    /// Where the files stand, as the owner was last told.
    private var assetsTold: NuxieMachineAssets = .ready

    /// Whether work only a frame consumes is waiting for one, the one rule
    /// a host's frames follow. A frame consumes three things:
    ///
    /// - a step owed ([`owesStep`]), which only a frame's step pays;
    /// - a store's answer in the mailbox, which only a frame's turn
    ///   delivers;
    /// - a byte source's answer ([`assetNews`]), which only a frame's turn
    ///   acts on.
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
    /// the only place the mailbox fills and the byte source's answers are
    /// kept. So a host that runs a frame for each ask never rests while it
    /// holds, and keeps no state of its own about it.
    private var waitsForFrame: Bool {
        fault == nil && !closedScreen && (!mailbox.isEmpty || assetNews || screens.contains(where: owesStep))
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
    /// its step, as a fault ([`stepPlayers`]). A presentation held for its
    /// files owes nothing: it has no player to step, and the writes held for
    /// it land in its player's first step.
    private func owesStep(_ screen: Screen) -> Bool {
        guard screen.player != nil else { return false }
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
        let before: [NuxieMachinePresented]
        private var rows: [NuxieMachineHostRow] = []
        private var fault: NuxieMachineEdgeFault?

        /// Only [`deliver`] makes one.
        fileprivate init(_ turn: Turn, before: [NuxieMachinePresented]) {
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
        /// changed anything (what a swipe down on a sheet would do among
        /// it); or nothing. A dismissal is told only when the delivery
        /// closed a presentation the owner was shown: one begun and
        /// dismissed in the same delivery never reached it.
        func report(showing shown: [NuxieMachinePresented]) -> NuxieMachineEdgeReport? {
            if let fault { return .fault(fault) }
            let after = shown.map(\.shown)
            let closed = before.contains { !after.contains($0.shown) }
            let told = rows.filter { row in
                if case .dismiss = row { return closed }
                return true
            }
            guard !told.isEmpty || shown != before else { return nil }
            return .delivered(shown: shown, rows: told)
        }
    }

    /// Compile the plan, with the rows of its folder's other files, into a
    /// session that draws its own views: each presentation is drawn from
    /// the compiled records by a player the session drives, with the bytes
    /// of each file it shows from `bytes`, asked for at the start. A program
    /// that shows a file no row names is refused (`asset.missing`), as any
    /// refusal is: this throws the compiler's text. `onReport`
    /// hears one report per delivery that did something for it: the fault
    /// when the delivery ended in one, otherwise what is shown and the rows
    /// it performs, in order. It is called inside the edge's turn, so it
    /// must not wait on the edge.
    package init(
        plan: NuxieMachinePlanSource,
        store: any NuxieMachineStore,
        bytes: any NuxieMachineByteSource,
        onReport: @escaping @Sendable (NuxieMachineEdgeReport) -> Void
    ) throws {
        let session = try NuxieMachineSession(
            files: plan.files.map { ($0.path, $0.text) }, assets: plan.assets, root: plan.root,
            app: plan.app, experience: plan.experience, version: plan.version)
        self.session = session
        self.store = store
        self.bytes = bytes
        self.owner = onReport
    }

    /// What the owner draws for the presentation on top, between
    /// deliveries: the player of its compiled view while one is shown. None
    /// when nothing is shown, while it is held for its files, or once the
    /// edge has closed.
    package func screen() async -> NuxieNativeRuntime? {
        await inTurn { _ in closedScreen ? nil : screens.last?.player }
    }

    /// What the owner draws for the presentation `shown`: its player while
    /// the edge holds it, and none while it is held for its files or once
    /// the sync has closed it. A Screen on its way off screen draws nothing
    /// more, so a presentation that replaced it never shows in it.
    package func screen(for shown: NuxieMachineShown) async -> NuxieNativeRuntime? {
        await inTurn { _ in
            guard !closedScreen else { return nil }
            return screens.first(where: { $0.presented.shown == shown })?.player
        }
    }

    /// What the owner draws for the presentation `shown` and the color it
    /// clears its surface to first, in one turn: its player and canvas while
    /// the edge holds it, and none while it is held for its files or once
    /// the sync has closed it, as [`screen(for:)`] gives the player.
    package func drawing(for shown: NuxieMachineShown) async -> (player: NuxieNativeRuntime, canvas: UInt32)? {
        await inTurn { _ in
            guard !closedScreen, let screen = screens.first(where: { $0.presented.shown == shown }),
                  let player = screen.player else { return nil }
            return (player, screen.canvas)
        }
    }

    /// The host saw the event `event` at `now` (milliseconds since the Unix
    /// epoch), and the machine's rows for it are applied. The byte source is
    /// asked first for each file the views draw that it has not given yet,
    /// and the start does not wait for its answers.
    package func start(event: String, now: Int64) async {
        await inTurn { turn in
            await deliver(turn, stopped: ()) { delivery in
                do {
                    paths = try session.sceneAssets().compactMap { asset -> String? in
                        switch asset {
                        case .platformFont: return nil
                        case .font(let path), .picture(let path): return path
                        }
                    }
                } catch {
                    await refused(error, doing: "the scene's assets", now: now, &delivery)
                    return
                }
                for path in paths where supplied[path] == nil && failed[path] == nil && fetching[path] == nil {
                    ask(path)
                }
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
    /// the time the engine advances by. The frame's turn delivers the frame;
    /// then, when the byte source answered before the turn began, one
    /// delivery that acts on its answers ([`settleAssets`]); then each store
    /// answer that arrived before the turn began, each as its own delivery.
    /// A player that the byte source's answers open is stepped by the next
    /// frame, so its host can size it first.
    ///
    /// `pointers` touched the Screen of the presentation `touched`: the one
    /// the person's view showed when they arrived. They reach the engine
    /// only while the edge holds that presentation when the frame steps it;
    /// a delivery since (a wake that ended it, or replaced it with another)
    /// leaves them going to no one, recorded as dropped, and the frame runs
    /// without them. Pointers that touched no presentation go to no one
    /// either.
    ///
    /// `semanticTaps` are a screen reader's taps on that same presentation,
    /// each on one node of the snapshot it was asked of, and go where its
    /// pointers go. Each is queued on the presentation's player before the
    /// step that carries the pointers, so the node's own listener hears it
    /// in that step. One the engine refuses (the snapshot is no longer the
    /// player's, or the node is gone or offers no tap) is recorded as
    /// [`refusedSemanticTap`](NuxieMachineEdgeEntry.refusedSemanticTap) and
    /// dropped, never sent as a touch.
    ///
    /// `scrolls` are a screen reader's moves of that presentation's
    /// `scroll`s, a reveal or a page, each asked of a snapshot, and go where
    /// its pointers go. Each is sent to the player after the taps and before
    /// the step; what came of each is in the frame's
    /// [`scrolled`](NuxieMachineFrame.scrolled), and one the engine refuses
    /// is also recorded as
    /// [`refusedScroll`](NuxieMachineEdgeEntry.refusedScroll).
    @discardableResult
    package func frame(
        pointers: [NuxieNativePointerEvent] = [],
        semanticTaps: [NuxieMachineSemanticTap] = [],
        scrolls: [NuxieMachineScrollRequest] = [],
        on touched: NuxieMachineShown? = nil,
        elapsedSeconds: Float,
        now: Int64
    ) async -> NuxieMachineFrame {
        await inTurn { turn in
            // Answers that arrive during this turn wait for the next frame.
            let answers = mailbox
            mailbox = []
            let news = assetNews
            assetNews = false
            let stopped = Stepped(reported: [], keepGoing: false,
                                  scrolled: scrolls.map { NuxieMachineScrolled($0, .refused) })
            let stepped = await deliver(turn, stopped: stopped) { delivery in
                var forwarded = Input(pointers: pointers, semanticTaps: semanticTaps, scrolls: scrolls)
                var dropped: [NuxieMachineScrolled] = []
                if !forwarded.isEmpty, touched == nil || !holds(touched) {
                    log.append(.droppedTouches(touched))
                    dropped = scrolls.map { NuxieMachineScrolled($0, .refused) }
                    forwarded = Input()
                }
                var result = await step(forwarded, on: touched, elapsedSeconds: elapsedSeconds, now: now, &delivery)
                result.scrolled = dropped + result.scrolled
                return result
            }
            if news {
                await deliver(turn, stopped: ()) { delivery in
                    await settleAssets(&delivery)
                }
            }
            for arrived in answers {
                await deliver(turn, stopped: ()) { delivery in
                    await answer(arrived, now: now, &delivery)
                }
            }
            return NuxieMachineFrame(reported: stepped.reported, keepGoing: stepped.keepGoing,
                                     scrolled: stepped.scrolled, settled: stepped.settled)
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

    /// The person is in the app (`here` true) or has left it, at `now`: a
    /// delivery like a wake. Leaving tells an open record she is away. Coming
    /// back delivers, inside this one call, each wake the record asked for at
    /// or before `now`, at its own moment and with her still away, and then
    /// tells the record she is here; their rows arrive together, in order,
    /// and are applied as a wake's are, so the last `wake at` among them is
    /// the one the record waits for. The same value again changes nothing.
    ///
    /// `now` follows the same rule as a wake's. A host tells it before
    /// delivering any wake of its own at that moment, so the missed wakes
    /// are judged with her away.
    package func presence(here: Bool, now: Int64) async {
        await inTurn { turn in
            await deliver(turn, stopped: ()) { delivery in
                let rows: [NuxieMachineRow]
                do {
                    rows = try session.presence(here: here, now: now)
                } catch {
                    await refused(error, doing: "presence", now: now, &delivery)
                    return
                }
                log.append(.presence(here: here))
                await apply(rows, now: now, &delivery)
            }
        }
    }

    /// The client's environment is now `environment`, at `now`: a delivery
    /// like a wake. Before the first start the session keeps it and the
    /// start's first frame is drawn in it; with a record open, what follows
    /// it is written in each presentation's next round, and the edge asks
    /// for the frame that draws it ([`waitsForFrame`]). The same environment
    /// again writes nothing. One environment holds for the whole session:
    /// every presentation of it, sheets and covers alike, is drawn in it.
    ///
    /// `now` follows the same rule as a wake's: no earlier than the last
    /// call that handed in a moment.
    package func environment(_ environment: NuxieMachineEnvironment, now: Int64) async {
        await inTurn { turn in
            await deliver(turn, stopped: ()) { delivery in
                let rows: [NuxieMachineRow]
                do {
                    rows = try session.environment(environment, now: now)
                } catch {
                    await refused(error, doing: "the environment", now: now, &delivery)
                    return
                }
                log.append(.environment(environment))
                await apply(rows, now: now, &delivery)
            }
        }
    }

    /// The presentation `shown` is now shown in `place`, at `now`: a
    /// delivery like a close. Each presentation is told its own, before its
    /// first frame is drawn and again whenever its insets or its size
    /// change; what follows it is written in that presentation's next round,
    /// and the edge asks for the frame that draws it ([`waitsForFrame`]). The
    /// same place again writes nothing, and a place writes nothing on
    /// another presentation. The edge holds no rule about which insets a
    /// presentation gets: its owner says.
    ///
    /// A presentation the edge no longer holds takes no place: the place
    /// leaves with its presentation, and a late one is recorded as dropped.
    /// `now` follows the same rule as a wake's.
    package func place(_ place: NuxieMachineScreenPlace, for shown: NuxieMachineShown, now: Int64) async {
        await inTurn { turn in
            await deliver(turn, stopped: ()) { delivery in
                guard holds(shown) else {
                    log.append(.droppedPlace(shown))
                    return
                }
                let rows: [NuxieMachineRow]
                do {
                    rows = try session.place(place, for: shown.instance, now: now)
                } catch {
                    await refused(error, doing: "the place of \(shown.instance)", now: now, &delivery)
                    return
                }
                log.append(.place(shown, place))
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

    /// The person asked to try again: a delivery that asks the byte source
    /// again for each path that failed, and only those. The answers kept
    /// stay kept, and asks still in flight are not made twice. The owner is
    /// told the files are being waited for again.
    package func refreshAssets() async {
        await inTurn { turn in
            await deliver(turn, stopped: ()) { _ in
                for path in paths where failed[path] != nil {
                    failed[path] = nil
                    ask(path)
                }
            }
        }
    }

    /// The host cannot go on with the open record, for the reason `fault`,
    /// at `now`: the person closed the loading screen of a presentation held
    /// for its files. A delivery like a close: the session's rows (a dismiss,
    /// then an end in the fault) are applied, so the edge stops on the
    /// record's own fault and the sync closes everything. The session reads
    /// no clock for it; `now` is the moment the delivery is made at, as for
    /// a close.
    ///
    /// With no presentation held for its files, every page has opened and
    /// there is nothing to give up on: it is recorded as dropped and goes to
    /// no one.
    package func hostFault(_ fault: NuxieMachineHostFault, now: Int64) async {
        await inTurn { turn in
            await deliver(turn, stopped: ()) { delivery in
                guard screens.contains(where: { $0.player == nil }) else {
                    log.append(.droppedExit)
                    return
                }
                let rows: [NuxieMachineRow]
                do {
                    rows = try session.hostFault(fault)
                } catch {
                    await refused(error, doing: "the host's fault \(fault)", now: now, &delivery)
                    return
                }
                await apply(rows, now: now, &delivery)
            }
        }
    }

    /// The person swiped the presentation `swiped` with `gesture`: a
    /// delivery like a close. The swipe goes to the presentation at its
    /// place in what the session shows now, found by its identity, and the
    /// machine decides what it does: a press of the control its row's
    /// `swipe=` names, a close, or nothing. What it did is given back, as
    /// the machine says it; the next sync shows the rest. A host calls this
    /// once for a gesture: at the gesture when the native dismissal was
    /// held, or at its completion when it ran, and never `closed` beside
    /// it. One the edge no longer holds takes no swipe: it is recorded as
    /// dropped.
    @discardableResult
    package func swipe(_ gesture: NuxieMachineSwipeGesture, on swiped: NuxieMachineShown,
                       now: Int64) async -> NuxieMachineSwipeDid {
        await inTurn { turn in
            await deliver(turn, stopped: .stopped) { delivery in
                guard holds(swiped), let index = showing().firstIndex(where: { $0.shown == swiped }) else {
                    log.append(.droppedSwipe(swiped))
                    return .dropped
                }
                let did: NuxieMachineSwipeWould
                let rows: [NuxieMachineRow]
                do {
                    (did, rows) = try session.swipe(at: index, gesture, now: now)
                } catch {
                    await refused(error, doing: "the swipe \(gesture) on \(swiped.instance)", now: now, &delivery)
                    return .stopped
                }
                log.append(.swipe(swiped, gesture, did: did))
                await apply(rows, now: now, &delivery)
                return .delivered(did)
            }
        }
    }

    /// Returns once the byte source has answered every ask the edge made
    /// and each answer has been kept. It takes no turn: the answers arrive
    /// without one. For a check that needs to know which frame acts on
    /// them.
    package func assetsAnswered() async {
        while let work = fetching.values.first {
            await work.value
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

    /// Run `body` holding the edge's turn, as a delivery in flight holds
    /// it. For checks: a check can make a delivery wait for it.
    package func holdingTurn(_ body: @Sendable () async -> Void) async {
        await inTurn { _ in await body() }
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
    /// before the session, which is freed with the edge. Asks of the byte
    /// source still in flight are cancelled, and their answers not kept.
    package func close() async throws {
        try await inTurn { _ in
            closedScreen = true
            mailbox = []
            stopFetching()
            let players = screens.reversed().compactMap(\.player)
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
        var delivery = Delivery(turn, before: stack)
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
        // What a swipe down would do is read again with what is shown: a
        // kept presentation takes the session's answer as it is now.
        for index in 0..<keep { screens[index].presented = wanted[index] }
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
        tellAssets(&delivery)
    }

    /// Tell the owner where the files stand, when that changed since it was
    /// last told: what the edge holds after the sync, never what the
    /// answers said one by one ([`assetsNow`]).
    private func tellAssets(_ delivery: inout Delivery) {
        guard let now = assetsNow(), now != assetsTold else { return }
        assetsTold = now
        log.append(.assets(now))
        delivery.told(.assets(now))
    }

    /// Where the files stand for what the edge holds: ready when no
    /// presentation is held for them; otherwise the paths that failed, in
    /// the scene's order, while any has; otherwise the paths still coming.
    /// Nothing while every file is in and the presentations held for them
    /// have not opened yet: the frame's next delivery opens them
    /// ([`settleAssets`]) and says ready, and until then nothing the owner
    /// shows would change.
    private func assetsNow() -> NuxieMachineAssets? {
        guard screens.contains(where: { $0.player == nil }) else { return .ready }
        let failures = paths.compactMap { path in
            failed[path].map { NuxieMachineAssetFailure(path: path, reason: $0) }
        }
        guard failures.isEmpty else { return .failed(failures) }
        let coming = paths.filter { supplied[$0] == nil }
        return coming.isEmpty ? nil : .waiting(coming)
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
    /// over those below it, with a player of its own. While a file its views
    /// draw has no bytes, it is held with no player instead: the session
    /// shows it all the same, and it opens once the files are in
    /// ([`settleAssets`]).
    private func open(_ presented: NuxieMachinePresented, _ delivery: inout Delivery) async {
        guard paths.allSatisfy({ supplied[$0] != nil }) else {
            screens.append(Screen(presented: presented, player: nil, canvas: 0, undrawn: true))
            log.append(.held(presented.shown))
            return
        }
        guard let opened = await openPlayer(for: presented, &delivery) else { return }
        screens.append(Screen(presented: presented, player: opened.player, canvas: opened.canvas, undrawn: true))
        log.append(.opened(presented.shown))
    }

    /// A frame's delivery for the byte source's answers: once every file is
    /// in, each presentation held for them opens its player, bottom first.
    /// Opening that fails is a fault, as in the sync. The sync after it
    /// tells the owner where the files stand: ready, still coming, or the
    /// paths that failed.
    private func settleAssets(_ delivery: inout Delivery) async {
        guard paths.allSatisfy({ supplied[$0] != nil }) else { return }
        for index in screens.indices where screens[index].player == nil {
            let presented = screens[index].presented
            guard let opened = await openPlayer(for: presented, &delivery) else { return }
            screens[index].player = opened.player
            screens[index].canvas = opened.canvas
            log.append(.opened(presented.shown))
        }
    }

    /// Close every presentation the edge holds above the first `keep`, from
    /// the top: each goes whole, its player freed, which releases its
    /// driver; the session outlives them.
    private func closeScreens(keeping keep: Int, _ delivery: inout Delivery) async {
        while screens.count > keep {
            let gone = screens.removeLast()
            log.append(.gone(gone.presented.shown))
            do {
                try await gone.player?.close()
            } catch {
                fail(NuxieMachineEdgeFault(code: "engine.close", detail: "\(error)"), &delivery)
            }
        }
    }

    // MARK: Frames

    /// What a frame carries to the presentation it touched: the pointers,
    /// the screen reader's taps and its moves of a `scroll` that arrived for
    /// it.
    private struct Input {
        var pointers: [NuxieNativePointerEvent] = []
        var semanticTaps: [NuxieMachineSemanticTap] = []
        var scrolls: [NuxieMachineScrollRequest] = []

        var isEmpty: Bool { pointers.isEmpty && semanticTaps.isEmpty && scrolls.isEmpty }
    }

    /// What a frame's steps did: the events reported, whether the engine
    /// keeps going, what came of the screen reader's moves, and which
    /// presentations settled.
    private struct Stepped {
        var reported: [String]
        var keepGoing: Bool
        var scrolled: [NuxieMachineScrolled] = []
        var settled: Set<NuxieMachineShown> = []
    }

    /// A frame's delivery: step the players of the presentations the edge
    /// holds. With nothing presented, nothing is drawn and nothing reports.
    private func step(
        _ input: Input,
        on touched: NuxieMachineShown?,
        elapsedSeconds: Float,
        now: Int64,
        _ delivery: inout Delivery
    ) async -> Stepped {
        guard !screens.isEmpty else {
            return Stepped(reported: [], keepGoing: false,
                           scrolled: input.scrolls.map { NuxieMachineScrolled($0, .refused) })
        }
        return await stepPlayers(input, on: touched, elapsedSeconds: elapsedSeconds, now: now, &delivery)
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
    /// its rounds would do nothing, and the sync closes it. The pointers and
    /// the screen reader's taps go to the step of the presentation they
    /// touched.
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
        _ input: Input,
        on touched: NuxieMachineShown?,
        elapsedSeconds: Float,
        now: Int64,
        _ delivery: inout Delivery
    ) async -> Stepped {
        let unsent = input.scrolls.map { NuxieMachineScrolled($0, .refused) }
        do {
            try session.setNow(now)
        } catch {
            await refused(error, doing: "the moment \(now)", now: now, &delivery)
            return Stepped(reported: [], keepGoing: false, scrolled: unsent)
        }
        var reported: [String] = []
        var keepGoing = false
        var scrolled: [NuxieMachineScrolled] = []
        var settled: [NuxieMachineShown: Bool] = [:]
        var waiting = input
        // A presentation held for its files has no player and is not stepped.
        let players = screens.compactMap { screen in
            screen.player.map { (shown: screen.presented.shown, player: $0) }
        }
        for (shown, player) in players {
            guard fault == nil else { break }
            var forwarded = Input()
            if shown == touched {
                forwarded = waiting
                waiting = Input()
            }
            guard let step = await stepPlayer(player, of: shown, forwarded, elapsedSeconds: elapsedSeconds,
                                              now: now, scrolled: &scrolled, &delivery) else { continue }
            reported += step.events.map(\.name)
            keepGoing = keepGoing || step.keepGoing
            settled[shown] = step.settled
        }
        if !waiting.isEmpty, fault == nil {
            // The presentation they touched ended earlier in this frame.
            log.append(.droppedTouches(touched))
        }
        scrolled += waiting.scrolls.map { NuxieMachineScrolled($0, .refused) }
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
                guard let step = await stepPlayer(player, of: shown, Input(), elapsedSeconds: 0, now: now,
                                                  scrolled: &scrolled, &delivery) else { continue }
                reported += step.events.map(\.name)
                keepGoing = keepGoing || step.keepGoing
                settled[shown] = step.settled
            }
        }
        guard fault == nil else { return Stepped(reported: [], keepGoing: false, scrolled: scrolled) }
        return Stepped(reported: reported, keepGoing: keepGoing, scrolled: scrolled,
                       settled: Set(settled.filter(\.value).keys))
    }

    /// One step of the player of the presentation `shown`, then the rows it
    /// left applied. None when the session no longer shows the
    /// presentation (it is not stepped) or the step faulted.
    ///
    /// The screen reader's taps in `input` are queued on the player first,
    /// so the step hears them with its pointers. A tap the engine refuses is
    /// recorded and dropped; the step runs without it. Its moves of a
    /// `scroll` are sent next, each answered in `scrolled`; one asked of a
    /// snapshot an earlier call spent is answered stale, for the component
    /// to ask again of the next.
    private func stepPlayer(
        _ player: NuxieNativeRuntime,
        of shown: NuxieMachineShown,
        _ input: Input,
        elapsedSeconds: Float,
        now: Int64,
        scrolled: inout [NuxieMachineScrolled],
        _ delivery: inout Delivery
    ) async -> NuxieNativePlayerStepResult? {
        guard showing().contains(where: { $0.shown == shown }) else {
            scrolled += input.scrolls.map { NuxieMachineScrolled($0, .refused) }
            return nil
        }
        for tap in input.semanticTaps {
            do {
                try await player.queueSemanticAction(captureID: tap.captureID, nodeID: tap.nodeID, action: .tap)
            } catch {
                log.append(.refusedSemanticTap(shown, node: tap.nodeID))
            }
        }
        for request in input.scrolls {
            let moved: Bool
            do {
                switch request {
                case .reveal(let captureID, let nodeID):
                    moved = try await player.revealSemanticNode(captureID: captureID, nodeID: nodeID)
                case .page(let captureID, let region, let dx, let dy):
                    moved = try await player.scrollRegion(captureID: captureID, region: region, dx: dx, dy: dy)
                }
            } catch NuxieNativeRuntimeError.callFailed(let diagnostic) where diagnostic.status == .handleMismatch {
                scrolled.append(NuxieMachineScrolled(request, .stale))
                continue
            } catch {
                log.append(.refusedScroll(shown, request))
                scrolled.append(NuxieMachineScrolled(request, .refused))
                continue
            }
            scrolled.append(NuxieMachineScrolled(request, moved ? .moved : .stayed))
        }
        let step: NuxieNativePlayerStepResult
        do {
            step = try await player.step(pointers: input.pointers, elapsedSeconds: elapsedSeconds)
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

    // MARK: The byte source

    /// Ask the byte source for the file at `path`: the work starts in a task
    /// of its own, as a store's call does ([`perform`]), and whatever asked
    /// goes on. Its answer arrives later ([`assetArrived`]).
    private func ask(_ path: String) {
        let source = bytes
        // The task holds the edge weakly: an edge let go of takes no answer.
        // It is recorded before this method returns, and its answer needs
        // the actor, so the answer cannot arrive before it is recorded.
        fetching[path] = Task { [weak self] in
            let answer: Result<Data, any Error>
            do {
                answer = .success(try await source.bytes(for: path))
            } catch {
                answer = .failure(error)
            }
            await self?.assetArrived(path, answer)
        }
    }

    /// The byte source answered for `path`: its bytes are kept, or, when it
    /// had none, why ([`ExperienceShellRecoveryReason`]). It opens nothing,
    /// tells the owner nothing and takes no turn; it asks the host for the
    /// frame whose turn acts on it ([`settleAssets`]). An answer for a
    /// stopped or closed edge is not kept.
    private func assetArrived(_ path: String, _ answer: Result<Data, any Error>) {
        fetching[path] = nil
        guard fault == nil, !closedScreen else { return }
        switch answer {
        case .success(let given) where !given.isEmpty:
            supplied[path] = given
        case .success:
            failed[path] = .unavailable
        case .failure(let error):
            failed[path] = ExperienceShellRecoveryReason(error: error)
        }
        assetNews = true
        askIfWaiting()
    }

    /// Cancel every ask in flight: the edge has stopped or closed, and
    /// keeps no answer.
    private func stopFetching() {
        for work in fetching.values { work.cancel() }
        fetching = [:]
        assetNews = false
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
            case .handOver:
                // This host keeps the record (see the entry): nothing is
                // faulted and nothing new is told to the owner.
                log.append(.handOver)
            case .unknown:
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
    /// edge delivers nothing more. Answers waiting for a frame go with it,
    /// and asks of the byte source in flight are cancelled. The delivery's
    /// sync then closes everything.
    private func fail(_ fault: NuxieMachineEdgeFault, _ delivery: inout Delivery) {
        guard self.fault == nil else { return }
        self.fault = fault
        mailbox = []
        stopFetching()
        delivery.faulted(fault)
    }

    // MARK: Compiled views

    /// A presentation the session shows, opened by the sync or, once its
    /// files are in, by [`settleAssets`]: a player on the compiled records,
    /// at the artboard its component is drawn in, with every asset of the
    /// records filled ([`openRecords`]) and the session's driver for this
    /// presentation set on it once, with the canvas its surface is cleared
    /// to. The writes the presenting step made, and any made while it was
    /// held, are held for that driver and land in the player's first step.
    /// None, with the edge stopped, when any of it fails.
    private func openPlayer(for presented: NuxieMachinePresented,
                            _ delivery: inout Delivery) async -> (player: NuxieNativeRuntime, canvas: UInt32)? {
        let route = presented.route
        let player: NuxieNativeRuntime
        let canvas: UInt32
        do {
            let records = try session.sceneRecords()
            let artboard = try session.sceneArtboard(for: presented.shown)
            canvas = session.sceneCanvas(for: presented)
            let assets = try session.sceneAssets()
            player = try await Self.openRecords(records, artboard: artboard, assets: assets, supplied: supplied)
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
        return (player, canvas)
    }

    private static func openFault(_ error: any Error, doing what: String) -> NuxieMachineEdgeFault {
        if let fault = error as? NuxieMachineEdgeFault { return fault }
        if let refused = error as? NuxieMachineError {
            return NuxieMachineEdgeFault(code: "machine.\(refused.code)", detail: "the session refused to \(what)")
        }
        return NuxieMachineEdgeFault(code: "engine.open", detail: "\(what): \(error)")
    }

    /// The compiled records opened on the engine at `artboard`, on its state
    /// machine, with no view model, and every asset the records hold filled
    /// before the import, as the session lists them by position
    /// (`assets`): nothing is drawn with a face or a picture missing, and
    /// nothing arrives later. The platform font, the face of a text with no
    /// `font-family`, is this device's system face, supplied as the SDK
    /// supplies a published Screen's System font; a scene with no such
    /// text has no platform font and takes no lease of it. Each face and
    /// each picture is the bytes the byte source gave for its path in the
    /// folder (`supplied`); nothing is asked here, and the edge calls this
    /// only once every path has its bytes. The positions stay here: they
    /// become the import's asset ordinals and nothing else sees them. The
    /// records' own catalog ([`NuxieNativeRuntime.inspectAssets`]) is read
    /// to give the import what it expects. Records that hold an asset the
    /// session's list does not name, or a path with no bytes, stop the edge
    /// with `edge.unsupplied-asset`, naming it.
    private static func openRecords(_ records: Data, artboard: Int, assets: [NuxieMachineSceneAsset],
                                    supplied: [String: Data]) async throws -> NuxieNativeRuntime {
        var external: [Int: Data] = [:]
        var platformFont: [Int] = []
        for (position, asset) in assets.enumerated() {
            switch asset {
            case .platformFont:
                platformFont.append(position)
            case .font(let path), .picture(let path):
                guard let given = supplied[path] else {
                    throw NuxieMachineEdgeFault(code: "edge.unsupplied-asset",
                        detail: "no bytes for \(path), which a view shows")
                }
                external[position] = given
            }
        }
        let expected = try await NuxieNativeRuntime.inspectAssets(bytes: records)
        if let unnamed = expected.first(where: { $0.ordinal >= assets.count }) {
            throw NuxieMachineEdgeFault(code: "edge.unsupplied-asset",
                detail: "the records hold asset \(unnamed.ordinal) (\(unnamed.name)), which the session's list "
                    + "does not name")
        }
        var leases: [ExperienceRuntimeSystemFontCache.Lease] = []
        do {
            for position in platformFont {
                // The regular face: a compiled view names no weight.
                let lease = try ExperienceRuntimeSystemFontCache.shared.prepare(weight: "400", style: "normal")
                leases.append(lease)
                external[position] = lease.candidate.bytes
            }
        } catch {
            ExperienceRuntimeSystemFontCache.shared.didFailImport(leases)
            throw error
        }
        do {
            // A phone's size in points until the owner lays it out at its
            // view's size, before the first step.
            let player = try await NuxieNativeRuntime.open(
                bytes: records, artboardIndex: artboard, player: .defaultScene, pixelWidth: 390, pixelHeight: 844,
                importMode: .configured(moduleName: "nuxie", expectedAssets: expected, externalAssets: external))
            ExperienceRuntimeSystemFontCache.shared.didImport(leases)
            return player
        } catch {
            ExperienceRuntimeSystemFontCache.shared.didFailImport(leases)
            throw error
        }
    }
}
#endif
