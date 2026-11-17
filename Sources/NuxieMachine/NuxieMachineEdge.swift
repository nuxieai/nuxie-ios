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
    /// The store answered a call of a record that is no longer open: the
    /// machine dropped the call when the record ended, so the answer is
    /// dropped too. `outcome` is none when the store failed.
    case dropped(NuxieMachineCallID, outcome: String?)
    /// Recorded only: the timer that delivers `wake` comes with the view
    /// controller.
    case wakeAt(Int64?)
    case end(reason: NuxieMachineEnding, fault: String?)
    case note(NuxieMachineNote)
}

/// What one frame did.
package struct NuxieMachineFrame: Equatable, Sendable {
    /// The engine events the Screen reported in this frame, in order,
    /// reserved ones included.
    package let reported: [String]
    /// The engine's step, for a host that schedules frames by it.
    package let keepGoing: Bool
}

/// The edge between one session of the Nux machine and one published Screen
/// on the engine, with no window: the machine's writes land in the Screen's
/// cells, and the taps the Screen reports go to the machine.
///
/// One frame, in this slice: step the engine with the pointers that
/// arrived; hand each reported event to the session by name; apply each
/// `scene` write to its cell; start each `call` at the store; record
/// `present`, `pop`, `dismiss`, `end`, `wake at` and `note`. A write shows on
/// the next step.
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
///    ([`arrived`], which applies nothing and tells no one). Each frame's
///    turn takes the answers that arrived before it began, delivers the
///    frame, then delivers each answer as its own delivery, in arrival
///    order. So an answer is applied right after the step of the first frame
///    that begins after it arrived: that step draws what the call's own
///    writes show (a busy button) before the answer's writes replace it, on
///    the step after. An answer for a record that is no longer open is
///    recorded as [`dropped`](NuxieMachineEdgeEntry.dropped) and is no fault.
///
/// Nothing is ignored silently. A reported event the session refuses, a row
/// this edge cannot perform, a cell the Screen does not have and a call the
/// store cannot perform are faults, and every fault takes one path
/// ([`fail`]): the edge stops and records the code. A stopped edge, or a
/// closed one, delivers nothing more.
///
/// The owner hears at most one dismissal per delivery, told once when the
/// delivery is over ([`deliver`], the only place the owner is called). Rows
/// and faults decide it as they apply ([`Delivery`]): a fault in the
/// delivery, from the machine, the store, the engine or this edge, makes it
/// the fault's dismissal, whatever normal dismissal came before it;
/// otherwise it is the machine's first `dismiss`. The log keeps every row
/// either way.
package actor NuxieMachineEdge {
    /// The engine's Screen, for its owner to draw.
    package nonisolated let runtime: NuxieNativeRuntime
    private let session: NuxieMachineSession
    private let route: String
    private let store: any NuxieMachineStore
    private let root: NuxieNativeViewModelReference
    /// The Screen's cells, by name, with the kind of value each holds.
    private let cells: [String: CellKind]
    /// The owner, told only by [`deliver`].
    private let owner: @Sendable (NuxieMachineEdgeDismissal) -> Void

    /// The presented instance of the route, while it is presented.
    package private(set) var instance: UInt64?
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

    private enum CellKind: Equatable {
        case bool, number, text
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
        private(set) var dismissal: NuxieMachineEdgeDismissal?

        /// Only [`deliver`] makes one.
        fileprivate init(_ turn: Turn) {}

        /// The machine's `dismiss` row. The first one stands, and never
        /// over a fault.
        mutating func dismissed(reason: String?) {
            if dismissal == nil { dismissal = .machine(reason: reason) }
        }

        /// The fault that stopped the edge in this delivery, over any
        /// normal dismissal before it.
        mutating func faulted(_ fault: NuxieMachineEdgeFault) {
            if case .fault? = dismissal { return }
            dismissal = .fault(fault)
        }
    }

    /// Compile the plan into a session, and open the Screen on the engine
    /// with its root view model bound and its System fonts supplied by this
    /// device. `onDismiss` hears at most one dismissal per delivery: the
    /// fault's when the delivery ended in one, otherwise the machine's.
    package init(
        plan: NuxieMachinePlanSource,
        screen: NuxieMachineScreenSource,
        store: any NuxieMachineStore,
        onDismiss: @escaping @Sendable (NuxieMachineEdgeDismissal) -> Void
    ) async throws {
        let session = try NuxieMachineSession(
            files: plan.files.map { ($0.path, $0.text) }, root: plan.root,
            app: plan.app, experience: plan.experience, version: plan.version)
        let runtime = try await Self.openScreen(screen)
        do {
            let root = try await runtime.rootViewModelReference()
            let snapshot = try await runtime.snapshot(root)
            self.cells = Self.cells(of: snapshot)
            self.root = root
        } catch {
            try? await runtime.close()
            throw error
        }
        self.session = session
        self.runtime = runtime
        self.route = screen.route
        self.store = store
        self.owner = onDismiss
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
            let frame = await deliver(turn, stopped: NuxieMachineFrame(reported: [], keepGoing: false)) { delivery in
                await step(pointers: pointers, elapsedSeconds: elapsedSeconds, now: now, &delivery)
            }
            for arrived in answers {
                await deliver(turn, stopped: ()) { delivery in
                    await answer(arrived, now: now, &delivery)
                }
            }
            return frame
        }
    }

    /// An engine event the Screen reported, handed to the session by the name
    /// the engine gave it. Package-visible so a check can hand the edge an
    /// event the published Screen never reports.
    package func handleReported(_ name: String, now: Int64) async {
        await inTurn { turn in
            await deliver(turn, stopped: ()) { delivery in
                await hear(name, now: now, &delivery)
            }
        }
    }

    /// The person closed the presented Screen with a system gesture.
    package func closed(now: Int64) async {
        await inTurn { turn in
            await deliver(turn, stopped: ()) { delivery in
                guard let instance else {
                    fail(NuxieMachineEdgeFault(code: "edge.unhandled-event", detail: "closed while nothing is presented"),
                         &delivery)
                    return
                }
                let rows: [NuxieMachineRow]
                do {
                    rows = try session.closed(instance: instance, now: now)
                } catch {
                    await refused(error, doing: "closed", now: now, &delivery)
                    return
                }
                await apply(rows, now: now, &delivery)
            }
        }
    }

    /// Whether the session's record is open, between deliveries.
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
    /// delivered. The session is freed with the edge.
    package func close() async throws {
        try await inTurn { _ in
            closedScreen = true
            mailbox = []
            try await runtime.close()
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
    /// then the owner is told the one dismissal it decided, if any. The one
    /// place the owner is called, and the one place a [`Delivery`] is made.
    private func deliver<Value>(
        _ turn: Turn,
        stopped: Value,
        _ body: (inout Delivery) async -> Value
    ) async -> Value {
        guard fault == nil, !closedScreen else { return stopped }
        var delivery = Delivery(turn)
        let result = await body(&delivery)
        if let dismissal = delivery.dismissal {
            owner(dismissal)
        }
        return result
    }

    /// A frame's delivery: step the engine and hand the Screen's events to
    /// the session.
    private func step(
        pointers: [NuxieNativePointerEvent],
        elapsedSeconds: Float,
        now: Int64,
        _ delivery: inout Delivery
    ) async -> NuxieMachineFrame {
        let step: NuxieNativePlayerStepResult
        do {
            step = try await runtime.step(pointers: pointers, elapsedSeconds: elapsedSeconds)
        } catch {
            fail(NuxieMachineEdgeFault(code: "engine.step", detail: "\(error)"), &delivery)
            return NuxieMachineFrame(reported: [], keepGoing: false)
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
            await hear(event.name, now: now, &delivery)
        }
        return NuxieMachineFrame(reported: reported, keepGoing: step.keepGoing)
    }

    /// An engine event the Screen reported, handed to the session.
    private func hear(_ name: String, now: Int64, _ delivery: inout Delivery) async {
        guard fault == nil else { return }
        guard let instance else {
            fail(NuxieMachineEdgeFault(code: "edge.unhandled-event",
                detail: "the Screen reported \(name) while nothing is presented"), &delivery)
            return
        }
        log.append(.reported(name))
        let rows: [NuxieMachineRow]
        do {
            rows = try session.engineEvent(instance: instance, name: name, now: now)
        } catch {
            await refused(error, doing: "the engine event \(name)", now: now, &delivery)
            return
        }
        await apply(rows, now: now, &delivery)
    }

    /// A store's answer, as its own delivery. An answer for a record that
    /// is no longer open is dropped: the machine dropped the call when the
    /// record ended (it answers such a call `unknown_call`), and a store
    /// that failed for it has nothing left to fail. Otherwise a store that
    /// could not perform the call is a fault, an unawaited call's outcome is
    /// recorded, and an awaited call's goes to the session, whose refusal
    /// (`unknown_call` included: the call was answered twice) is a fault.
    private func answer(_ answer: Answer, now: Int64, _ delivery: inout Delivery) async {
        let call = answer.call
        let open: Bool
        do {
            open = try session.recordOpen()
        } catch {
            await refused(error, doing: "a read of the record for \(call.externName)'s answer", now: now, &delivery)
            return
        }
        guard open else {
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
    /// turn. It applies nothing and tells no one, so it needs no turn. An
    /// answer for a stopped or closed edge is not kept.
    private func arrived(_ call: NuxieMachineCall, _ outcome: Result<String, any Error>) {
        working[call.id] = nil
        guard fault == nil, !closedScreen else { return }
        mailbox.append(Answer(call: call, outcome: outcome))
    }

    // MARK: Rows

    private func apply(_ rows: [NuxieMachineRow], now: Int64, _ delivery: inout Delivery) async {
        for row in rows {
            guard fault == nil else { return }
            switch row {
            case .present(let route, let instance, let presentation):
                guard route == self.route, self.instance == nil else {
                    fail(NuxieMachineEdgeFault(code: "edge.no-artwork",
                        detail: "present \(route) as \(instance); this edge draws \(self.route) once"), &delivery)
                    return
                }
                self.instance = instance
                log.append(.present(route: route, instance: instance, presentation: presentation))
            case .pop(let instance):
                guard instance == self.instance else {
                    fail(NuxieMachineEdgeFault(code: "edge.unhandled-row",
                        detail: "pop \(instance), which is not presented"), &delivery)
                    return
                }
                self.instance = nil
                log.append(.pop(instance: instance))
            case .dismiss(let reason):
                instance = nil
                log.append(.dismiss(reason: reason))
                delivery.dismissed(reason: reason)
            case .sceneSet(let instance, let object, let key, let value):
                await write(instance: instance, cell: nuxieMachineCellName(object: object, key: key), value: value,
                            &delivery)
            case .call(let call):
                perform(call, &delivery)
            case .wakeAt(let moment):
                log.append(.wakeAt(moment))
            case .end(let reason, let code):
                log.append(.end(reason: reason, fault: code))
                if reason != .finished && reason != .exited {
                    fail(NuxieMachineEdgeFault(code: code ?? "machine.fault",
                        detail: "the record ended in a fault"), &delivery)
                }
            case .note(let note):
                log.append(.note(note))
            case .handOver, .unknown:
                fail(NuxieMachineEdgeFault(code: "edge.unhandled-row", detail: "\(row)"), &delivery)
            }
        }
    }

    /// A `scene` write: the value lands in the Screen's cell
    /// `state/<cell>` and shows on the next step.
    private func write(instance: UInt64, cell: String, value: NuxieMachineValue, _ delivery: inout Delivery) async {
        guard instance == self.instance else {
            fail(NuxieMachineEdgeFault(code: "edge.unhandled-row",
                detail: "a write to \(cell) of instance \(instance), which is not presented"), &delivery)
            return
        }
        let path = "state/\(cell)"
        let mutation: NuxieNativeViewModelMutation
        switch (cells[cell], value) {
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
            _ = try await runtime.mutateViewModel([mutation])
        } catch {
            fail(NuxieMachineEdgeFault(code: "engine.write", detail: "\(cell): \(error)"), &delivery)
            return
        }
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
    /// delivery's dismissal becomes the fault's. The first fault is the one
    /// kept; a later one in the same delivery changes nothing, and a stopped
    /// edge delivers nothing more. Answers waiting for a frame go with it.
    private func fail(_ fault: NuxieMachineEdgeFault, _ delivery: inout Delivery) {
        guard self.fault == nil else { return }
        self.fault = fault
        mailbox = []
        delivery.faulted(fault)
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
