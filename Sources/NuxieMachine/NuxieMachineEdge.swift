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
    /// The store's outcome for a call, delivered to the session when the
    /// call is awaited.
    case answer(NuxieMachineCallID, outcome: String)
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
/// `scene` write to its cell; perform each `call` through the store; record
/// `present`, `pop`, `dismiss`, `end`, `wake at` and `note`. A write shows on
/// the next step. An awaited call's answer goes to the session after the
/// next frame's step, as a store's answer arrives after the frame that
/// asked: that frame draws what the call's own writes show (a busy button)
/// before the answer's writes replace it.
///
/// Nothing is ignored silently. A reported event the session refuses, a row
/// this edge cannot perform, a cell the Screen does not have and a call the
/// store cannot perform are faults, and every fault takes one path
/// ([`fail`]): the edge stops, records the code, and tells its owner to
/// dismiss. A stopped edge does nothing more.
package actor NuxieMachineEdge {
    /// The engine's Screen, for its owner to draw.
    package nonisolated let runtime: NuxieNativeRuntime
    private let session: NuxieMachineSession
    private let route: String
    private let store: any NuxieMachineStore
    private let root: NuxieNativeViewModelReference
    /// The Screen's cells, by name, with the kind of value each holds.
    private let cells: [String: CellKind]
    private let dismiss: @Sendable (NuxieMachineEdgeDismissal) -> Void

    /// The presented instance of the route, while it is presented.
    package private(set) var instance: UInt64?
    /// Everything the edge did, in order.
    package private(set) var log: [NuxieMachineEdgeEntry] = []
    /// What stopped the edge, once something has.
    package private(set) var fault: NuxieMachineEdgeFault?
    /// The store's answers to awaited calls, for the next frame.
    private var answers: [(call: NuxieMachineCallID, outcome: String)] = []

    private enum CellKind: Equatable {
        case bool, number, text
    }

    /// Compile the plan into a session, and open the Screen on the engine
    /// with its root view model bound and its System fonts supplied by this
    /// device. `onDismiss` hears every dismissal: the machine's and a fault's.
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
        self.dismiss = onDismiss
    }

    /// The host saw the event `event` at `now` (milliseconds since the Unix
    /// epoch), and the machine's rows for it are applied.
    package func start(event: String, now: Int64) async {
        guard fault == nil else { return }
        let rows: [NuxieMachineRow]
        do {
            rows = try session.start(event: event, now: now)
        } catch {
            await refused(error, doing: "start on \(event)", now: now)
            return
        }
        await apply(rows, now: now)
    }

    /// One frame. `now` is the clock the machine reads, and `elapsedSeconds`
    /// the time the engine advances by.
    @discardableResult
    package func frame(
        pointers: [NuxieNativePointerEvent] = [],
        elapsedSeconds: Float,
        now: Int64
    ) async -> NuxieMachineFrame {
        guard fault == nil else { return NuxieMachineFrame(reported: [], keepGoing: false) }
        // Answers the store gave before this frame; ones it gives during
        // this frame wait for the next.
        let waiting = answers
        answers = []
        let step: NuxieNativePlayerStepResult
        do {
            step = try await runtime.step(pointers: pointers, elapsedSeconds: elapsedSeconds)
        } catch {
            fail(NuxieMachineEdgeFault(code: "engine.step", detail: "\(error)"))
            return NuxieMachineFrame(reported: [], keepGoing: false)
        }
        var reported: [String] = []
        for event in step.events {
            reported.append(event.name)
            guard fault == nil else { continue }
            // A reserved (`$`) event is the engine's own, and an unnamed
            // one with no link is a bare notification: a phone drops both,
            // as the SDK's Screen does for every Screen it shows. The
            // Screen's named events are the ones the machine hears. Both
            // still appear in the frame's `reported`.
            if event.name.hasPrefix("$") || (event.name.isEmpty && event.url.isEmpty) { continue }
            guard event.url.isEmpty else {
                fail(NuxieMachineEdgeFault(code: "edge.unhandled-event",
                    detail: "the Screen reported a link to \(event.url), which this edge cannot open"))
                continue
            }
            await handleReported(event.name, now: now)
        }
        for answer in waiting {
            guard fault == nil else { break }
            log.append(.answer(answer.call, outcome: answer.outcome))
            let rows: [NuxieMachineRow]
            do {
                rows = try session.answer(answer.call, outcome: answer.outcome, now: now)
            } catch {
                await refused(error, doing: "answer \(answer.outcome)", now: now)
                break
            }
            await apply(rows, now: now)
        }
        return NuxieMachineFrame(reported: reported, keepGoing: step.keepGoing)
    }

    /// An engine event the Screen reported, handed to the session by the name
    /// the engine gave it. Package-visible so a check can hand the edge an
    /// event the published Screen never reports.
    package func handleReported(_ name: String, now: Int64) async {
        guard fault == nil else { return }
        guard let instance else {
            fail(NuxieMachineEdgeFault(code: "edge.unhandled-event",
                detail: "the Screen reported \(name) while nothing is presented"))
            return
        }
        log.append(.reported(name))
        let rows: [NuxieMachineRow]
        do {
            rows = try session.engineEvent(instance: instance, name: name, now: now)
        } catch {
            await refused(error, doing: "the engine event \(name)", now: now)
            return
        }
        await apply(rows, now: now)
    }

    /// The person closed the presented Screen with a system gesture.
    package func closed(now: Int64) async {
        guard fault == nil else { return }
        guard let instance else {
            fail(NuxieMachineEdgeFault(code: "edge.unhandled-event", detail: "closed while nothing is presented"))
            return
        }
        let rows: [NuxieMachineRow]
        do {
            rows = try session.closed(instance: instance, now: now)
        } catch {
            await refused(error, doing: "closed", now: now)
            return
        }
        await apply(rows, now: now)
    }

    /// Whether the session's record is open.
    package func recordOpen() throws -> Bool { try session.recordOpen() }

    /// The value of the root slot named `name` in the session's record.
    package func slot(_ name: String) throws -> NuxieMachineValue { try session.slot(name) }

    /// The route the session presents on top, and its instance.
    package func topRoute() throws -> (route: String, instance: UInt64)? { try session.topRoute() }

    /// Close the Screen on the engine. The session is freed with the edge.
    package func close() async throws {
        try await runtime.close()
    }

    // MARK: Rows

    private func apply(_ rows: [NuxieMachineRow], now: Int64) async {
        for row in rows {
            guard fault == nil else { return }
            switch row {
            case .present(let route, let instance, let presentation):
                guard route == self.route, self.instance == nil else {
                    fail(NuxieMachineEdgeFault(code: "edge.no-artwork",
                        detail: "present \(route) as \(instance); this edge draws \(self.route) once"))
                    return
                }
                self.instance = instance
                log.append(.present(route: route, instance: instance, presentation: presentation))
            case .pop(let instance):
                guard instance == self.instance else {
                    fail(NuxieMachineEdgeFault(code: "edge.unhandled-row", detail: "pop \(instance), which is not presented"))
                    return
                }
                self.instance = nil
                log.append(.pop(instance: instance))
            case .dismiss(let reason):
                instance = nil
                log.append(.dismiss(reason: reason))
                dismiss(.machine(reason: reason))
            case .sceneSet(let instance, let object, let key, let value):
                await write(instance: instance, cell: nuxieMachineCellName(object: object, key: key), value: value)
            case .call(let call):
                await perform(call)
            case .wakeAt(let moment):
                log.append(.wakeAt(moment))
            case .end(let reason, let code):
                log.append(.end(reason: reason, fault: code))
                if reason != .finished && reason != .exited {
                    fail(NuxieMachineEdgeFault(code: code ?? "machine.fault", detail: "the record ended in a fault"))
                }
            case .note(let note):
                log.append(.note(note))
            case .handOver, .unknown:
                fail(NuxieMachineEdgeFault(code: "edge.unhandled-row", detail: "\(row)"))
            }
        }
    }

    /// A `scene` write: the value lands in the Screen's cell
    /// `state/<cell>` and shows on the next step.
    private func write(instance: UInt64, cell: String, value: NuxieMachineValue) async {
        guard instance == self.instance else {
            fail(NuxieMachineEdgeFault(code: "edge.unhandled-row",
                detail: "a write to \(cell) of instance \(instance), which is not presented"))
            return
        }
        let path = "state/\(cell)"
        let mutation: NuxieNativeViewModelMutation
        switch (cells[cell], value) {
        case (.bool, .bool(let yes)): mutation = .setBool(instance: root, path: path, value: yes)
        case (.number, .number(let number)): mutation = .setNumber(instance: root, path: path, value: Float(number))
        case (.text, .text(let text)): mutation = .setString(instance: root, path: path, value: Data(text.utf8))
        case (nil, _):
            fail(NuxieMachineEdgeFault(code: "edge.unknown-cell", detail: "the Screen has no cell \(cell) for \(value)"))
            return
        default:
            fail(NuxieMachineEdgeFault(code: "edge.unknown-cell",
                detail: "the Screen's cell \(cell) does not hold a value like \(value)"))
            return
        }
        do {
            _ = try await runtime.mutateViewModel([mutation])
        } catch {
            fail(NuxieMachineEdgeFault(code: "engine.write", detail: "\(cell): \(error)"))
            return
        }
        log.append(.write(cell: cell, value: value))
    }

    /// A `call` row, through the store. An awaited call's outcome waits for
    /// the next frame.
    private func perform(_ call: NuxieMachineCall) async {
        log.append(.call(call))
        guard call.place == .client else {
            fail(NuxieMachineEdgeFault(code: "edge.unhandled-row",
                detail: "\(call.externName) runs on the server, which this edge cannot reach"))
            return
        }
        let outcome: String
        do {
            outcome = try await store.perform(call)
        } catch NuxieMachineStoreFault.unknownExtern(let name) {
            fail(NuxieMachineEdgeFault(code: "store.unknown-extern", detail: "the store cannot perform \(name)"))
            return
        } catch {
            fail(NuxieMachineEdgeFault(code: "store.failed", detail: "\(call.externName): \(error)"))
            return
        }
        guard fault == nil else { return }
        if call.awaited {
            answers.append((call.id, outcome))
        } else {
            log.append(.answer(call.id, outcome: outcome))
        }
    }

    /// A call the session refused. A call that ended the session still
    /// left rows, which end in its fault, and they are applied first.
    private func refused(_ error: Error, doing what: String, now: Int64) async {
        if case NuxieMachineError.faulted(let rows) = error {
            await apply(rows, now: now)
        }
        let code = (error as? NuxieMachineError)?.code ?? "unknown"
        fail(NuxieMachineEdgeFault(code: "machine.\(code)", detail: "the session refused \(what): \(error)"))
    }

    /// The one path for faults: the edge stops, records the code, and tells
    /// its owner to dismiss. The first fault is the one kept.
    private func fail(_ fault: NuxieMachineEdgeFault) {
        guard self.fault == nil else { return }
        self.fault = fault
        answers = []
        dismiss(.fault(fault))
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
