#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieRuntime
@_implementationOnly import NuxMachineC

// FOR TESTS ONLY. The Nux machine's library carries the `.nux` compiler and a
// fixed stand-in world, so this module exists only when that library is
// staged at `.artifacts/NuxMachine.xcframework`, and nothing in the `Nuxie`
// product depends on it.

/// One session of the Nux machine, over the C interface in `nux_machine.h`:
/// a plan compiled from `.nux` source, the record of one Journey through it,
/// and the effects of the last call as rows. Every session is driven: its
/// scene writes are never rows, and each presented instance's are held for
/// that instance's driver (`nux_machine.h`, THE DRIVER PATH).
///
/// Confined, not an actor: the header lets one thread at a time use a
/// session, and this class is not `Sendable`, so the compiler keeps each
/// session in the one isolation domain that made it (the edge's actor, or a
/// test's). Every call reads what it gives back before it returns, because
/// the strings the interface lends stay valid only until the next call.
package final class NuxieMachineSession {
    private let handle: OpaquePointer
    /// The plan's name, as the compiler gave it.
    package let planName: UInt64

    /// Compile `files` with `root` (the root file's path without `.nux`) under
    /// the app, Experience and version given, with `assets`, the rows of
    /// the folder's other files, beside them; admit the plan, and hold it
    /// with no record yet. A file a view shows that no row names is refused
    /// (`asset.missing`).
    package init(
        files: [(path: String, text: String)],
        assets: [NuxieMachineAsset],
        root: String,
        app: String,
        experience: String,
        version: UInt32
    ) throws {
        var session: OpaquePointer?
        var name: UInt64 = 0
        var refusalsLength = 0
        let borrowed = files.flatMap { [$0.path, $0.text] } + assets.map(\.path) + [root, app, experience]
        let status: UInt32 = try NuxieMachineStrings.lend(borrowed) { views in
            var given: [NuxMachineFile] = []
            for at in files.indices {
                given.append(NuxMachineFile(path: views[2 * at], text: views[2 * at + 1]))
            }
            let rows = assets.enumerated().map { at, asset in asset.carried(path: views[2 * files.count + at]) }
            let tail = views.count - 3
            var refusals = [UInt8](repeating: 0, count: 64 * 1024)
            let capacity = refusals.count
            let status = given.withUnsafeBufferPointer { files in
                rows.withUnsafeBufferPointer { assets in
                    refusals.withUnsafeMutableBufferPointer { buffer in
                        nux_machine_session_new(
                            files.baseAddress, files.count, assets.baseAddress, assets.count,
                            views[tail], views[tail + 1], views[tail + 2], version,
                            &session, &name, buffer.baseAddress, capacity, &refusalsLength)
                    }
                }
            }
            if status == NuxieMachineStatus.refused {
                let length = min(refusalsLength, capacity)
                throw NuxieMachineError.refused(String(decoding: refusals[0..<length], as: UTF8.self))
            }
            return status
        }
        try NuxieMachineError.check(status)
        guard let session else { throw NuxieMachineError.nullArgument }
        handle = session
        planName = name
    }

    deinit {
        _ = nux_machine_session_free(handle)
    }

    // MARK: Calls that deliver something

    /// The host saw the event `event` at `now` (milliseconds since the Unix
    /// epoch): the first entry that starts on it makes the record. When none
    /// starts, the machine's reason says which of two things happened. A
    /// reason below `NUX_MACHINE_DECLINED_WRONG` means the start did not
    /// happen and nothing is wrong (`notStarted`); one at or above it, or a
    /// reason that cannot be read, means something is wrong (`declined`).
    /// Either carries the reason's text.
    package func start(event: String, now: Int64) throws -> [NuxieMachineRow] {
        var declined = NuxMachineStr(ptr: nil, len: 0)
        let status = NuxieMachineStrings.lend([event]) { views in
            nux_machine_start(handle, views[0], now, &declined)
        }
        if status == NuxieMachineStatus.declined {
            // The reason is a static string: it does not expire.
            let text = NuxieMachineStrings.copy(declined)
            var reason: UInt32 = 0
            let read = nux_machine_declined_reason(handle, &reason)
            // 0 is no reason: the header writes it only when there is none to
            // read. A reason that cannot be read stays on the safe side.
            if read == NuxieMachineStatus.ok, reason != 0, reason < UInt32(NUX_MACHINE_DECLINED_WRONG) {
                throw NuxieMachineError.notStarted(text)
            }
            throw NuxieMachineError.declined(text)
        }
        return try delivered(status)
    }

    /// The person closed the presented instance `instance` with a system
    /// gesture.
    package func closed(instance: UInt64, now: Int64) throws -> [NuxieMachineRow] {
        try delivered(nux_machine_closed(handle, instance, now))
    }

    /// The host cannot go on with the open record, for the reason `fault`.
    /// The rows end the session: a dismiss with no reason, then an end in
    /// that fault. With no record open this throws `noRecord`.
    package func hostFault(_ fault: NuxieMachineHostFault) throws -> [NuxieMachineRow] {
        try delivered(nux_machine_host_fault(handle, fault.code))
    }

    /// Deliver `gesture` on the presentation at `index` of what is shown,
    /// bottom first, at `now`: what it did, and the rows it left. The
    /// machine works the answer out again here, so it may differ from what
    /// [`swipeWould`] last said; a host acts on what it did. A press or a
    /// close replaces the rows; a swipe that stays delivers nothing, and
    /// gives none (the session's rows are still the last call's).
    package func swipe(at index: Int, _ gesture: NuxieMachineSwipeGesture, now: Int64) throws
        -> (did: NuxieMachineSwipeWould, rows: [NuxieMachineRow])
    {
        var did: UInt32 = 0
        let rows = try delivered(nux_machine_swipe(handle, index, gesture.carried, now, &did))
        let answer = try NuxieMachineSwipeWould(did)
        return (answer, answer == .stays ? [] : rows)
    }

    /// The reply to the send `call` into a mutation: the fields of its
    /// declaration's answer type, or the failure that kept it from one.
    package func reply(_ call: NuxieMachineCallID, _ reply: NuxieMachineReply, now: Int64) throws
        -> [NuxieMachineRow]
    {
        let id = NuxMachineCallId(record: call.record, generation: call.generation, counter: call.counter)
        let status: UInt32
        switch reply {
        case .answer(let fields):
            status = NuxieMachineStrings.lend(fields.map(\.lentText)) { views in
                let values = zip(fields, views).map { field, text in field.carried(text) }
                return values.withUnsafeBufferPointer { values in
                    nux_machine_reply(handle, id, values.baseAddress, values.count, nil, now)
                }
            }
        case .failure(let failure):
            status = NuxieMachineStrings.lend([failure.reason, failure.message]) { views in
                var carried = NuxMachineFailure(code: failure.code.carried, reason: views[0], message: views[1])
                return nux_machine_reply(handle, id, nil, 0, &carried, now)
            }
        }
        return try delivered(status)
    }

    /// The moment the record asked for (its last `wake at`) has come.
    package func wake(now: Int64) throws -> [NuxieMachineRow] {
        try delivered(nux_machine_wake(handle, now))
    }

    /// The person is in the app (`here` true) or has left it, at `now`. A
    /// session starts with her here, and the same value again does nothing.
    /// Leaving tells an open record she is away. Coming back first delivers
    /// each wake the record asked for at or before `now`, at its own moment
    /// and with her still away, then tells the record she is here; the rows
    /// are every step's, in order. With no record open the session keeps the
    /// value for the next start.
    package func presence(here: Bool, now: Int64) throws -> [NuxieMachineRow] {
        try delivered(nux_machine_presence(handle, here, now))
    }

    /// The client's environment is now `environment`. Told once before the
    /// first start, so the first frame is drawn in it, and again whenever it
    /// changes. With a record open it is delivered to the record, as a wake
    /// is, and what follows it is written in each presentation's next
    /// round; the same environment again writes nothing. With none open the
    /// session keeps it and leaves no rows.
    package func environment(_ environment: NuxieMachineEnvironment, now: Int64) throws -> [NuxieMachineRow] {
        var carried = environment.carried
        return try delivered(nux_machine_environment(handle, &carried, now))
    }

    /// The presented instance `instance` is now shown in `place`: told for
    /// each presentation before its first frame, and again whenever its
    /// insets or its size change. It is delivered to the record, as a close
    /// is, and what follows it is written in that presentation's next
    /// round; the same place again writes nothing, and a place writes
    /// nothing on another presentation. A presentation told none has no
    /// insets and no size. The place leaves with its presentation: one told
    /// for an instance the record no longer presents is `unknownInstance`.
    package func place(_ place: NuxieMachineScreenPlace, for instance: UInt64, now: Int64) throws -> [NuxieMachineRow] {
        var carried = place.carried
        return try delivered(nux_machine_place(handle, instance, &carried, now))
    }

    // MARK: Reads

    /// The rows the last call that delivered something left.
    package func rows() throws -> [NuxieMachineRow] {
        var count = 0
        try NuxieMachineError.check(nux_machine_effect_count(handle, &count))
        return try (0..<count).map(row)
    }

    /// Whether a record is open: one has started, it has not ended, and no
    /// fault has ended the session.
    package func recordOpen() throws -> Bool {
        var open = false
        try NuxieMachineError.check(nux_machine_record_open(handle, &open))
        return open
    }

    /// What is shown: the record's presented stack, bottom first, each
    /// with its identity, its route and how it is presented. Empty before
    /// the first start, once the record has ended, and once a fault has
    /// ended the session.
    package func presented() throws -> [NuxieMachinePresented] {
        var count = 0
        try NuxieMachineError.check(nux_machine_presented_count(handle, &count))
        return try (0..<count).map { index in
            var journey: UInt64 = 0
            var instance: UInt64 = 0
            var route = NuxMachineStr(ptr: nil, len: 0)
            var presentation: UInt32 = 0
            try NuxieMachineError.check(
                nux_machine_presented(handle, index, &journey, &instance, &route, &presentation))
            // The route is copied before the next call lends anything else.
            let name = NuxieMachineStrings.copy(route) ?? ""
            let how = NuxieMachinePresentation(rawValue: presentation) ?? .unknown
            return NuxieMachinePresented(
                shown: NuxieMachineShown(journey: journey, instance: instance),
                route: name,
                presentation: how,
                detents: try detents(at: index),
                swipeDown: how == .sheet ? try swipeWould(at: index, .down) : nil)
        }
    }

    /// The heights the presentation at `index` of what is shown may rest
    /// at, in the order its row of the router's table writes them: none
    /// when the row writes none, and for every presentation of a plan with
    /// `routes`.
    package func detents(at index: Int) throws -> [NuxieMachineDetent] {
        var count = 0
        try NuxieMachineError.check(nux_machine_presented_detent_count(handle, index, &count))
        return try (0..<count).map { nth in
            var kind: UInt32 = 0
            var value: Double = 0
            try NuxieMachineError.check(nux_machine_presented_detent(handle, index, nth, &kind, &value))
            return try NuxieMachineDetent(kind: kind, value: value)
        }
    }

    /// What `gesture` on the presentation at `index` of what is shown,
    /// bottom first, would do now. For a swipe down, `index` is the sheet
    /// dragged, and the machine reads the page on top of it. Reads only:
    /// it delivers nothing and leaves the rows as they are.
    package func swipeWould(at index: Int, _ gesture: NuxieMachineSwipeGesture) throws -> NuxieMachineSwipeWould {
        var does: UInt32 = 0
        try NuxieMachineError.check(nux_machine_swipe_would(handle, index, gesture.carried, &does))
        return try NuxieMachineSwipeWould(does)
    }

    /// The route presented on top and its instance, or none.
    package func topRoute() throws -> (route: String, instance: UInt64)? {
        var has = false
        var route = NuxMachineStr(ptr: nil, len: 0)
        var instance: UInt64 = 0
        try NuxieMachineError.check(nux_machine_top_route(handle, &has, &route, &instance))
        return has ? (NuxieMachineStrings.copy(route) ?? "", instance) : nil
    }

    /// The value of the root slot named `name` in the record.
    package func slot(_ name: String) throws -> NuxieMachineValue {
        var value = NuxMachineValue(kind: 0, boolean: false, number: 0, text: NuxMachineStr(ptr: nil, len: 0))
        let status = NuxieMachineStrings.lend([name]) { views in
            nux_machine_slot(handle, views[0], &value)
        }
        try NuxieMachineError.check(status)
        return try NuxieMachineValue(value)
    }

    // MARK: The driver path

    /// The engine's records of the plan's views, copied.
    package func sceneRecords() throws -> Data {
        var bytes: UnsafePointer<UInt8>?
        var length = 0
        try NuxieMachineError.check(nux_machine_scene_records(handle, &bytes, &length))
        guard let bytes else { return Data() }
        return Data(bytes: bytes, count: length)
    }

    /// The artboard the presentation `shown` is drawn in, by its position
    /// among the records' artboards.
    package func sceneArtboard(for shown: NuxieMachineShown) throws -> Int {
        var artboard = 0
        try NuxieMachineError.check(nux_machine_scene_artboard(handle, shown.journey, shown.instance, &artboard))
        return artboard
    }

    /// The color the presented surface is cleared to before each draw: its
    /// component's canvas. 0, a clear surface, when the plan gives none.
    package func sceneCanvas(for presented: NuxieMachinePresented) -> UInt32 {
        var argb: UInt32 = 0
        let status = nux_machine_scene_canvas(handle, presented.shown.journey, presented.shown.instance, &argb)
        return status == NuxieMachineStatus.ok ? argb : 0
    }

    /// The records' assets, in the order the records hold them (an asset's
    /// index here is its position, the ordinal the engine's import takes),
    /// and what the host fills each with: the platform font, first when
    /// some text has no face of its own; then each face a text draws in,
    /// once, by its file's path in the folder; then each picture once, by
    /// its path. Empty when no view shows text or a picture.
    package func sceneAssets() throws -> [NuxieMachineSceneAsset] {
        var count = 0
        try NuxieMachineError.check(nux_machine_scene_asset_count(handle, &count))
        return try (0..<count).map { position -> NuxieMachineSceneAsset in
            var kind: UInt32 = 0
            var path = NuxMachineStr(ptr: nil, len: 0)
            try NuxieMachineError.check(nux_machine_scene_asset(handle, position, &kind, &path))
            switch kind {
            case NuxieMachineStatus.assetPlatformFont:
                return .platformFont
            case NuxieMachineStatus.assetFont:
                guard let path = NuxieMachineStrings.copy(path) else { throw NuxieMachineError.assetDoesNotFit }
                return .font(path: path)
            case NuxieMachineStatus.assetPicture:
                guard let path = NuxieMachineStrings.copy(path) else { throw NuxieMachineError.assetDoesNotFit }
                return .picture(path: path)
            default:
                throw NuxieMachineError.assetDoesNotFit
            }
        }
    }

    /// Whether the session holds scene writes for the presentation `shown`
    /// that no round of its driver has applied yet, written by any delivery,
    /// a round of another presentation's driver included. Such a
    /// presentation's player owes a step (`nux_machine.h`, THE DRIVER PATH,
    /// step 8). Throws `ended` once the session has ended and
    /// `unknownInstance` for a presentation it does not show.
    package func holdsWrites(for shown: NuxieMachineShown) throws -> Bool {
        var holds = false
        try NuxieMachineError.check(nux_machine_scene_holds_writes(handle, shown.journey, shown.instance, &holds))
        return holds
    }

    /// The moment a driver's later rounds step the machine at, until a call
    /// hands in another. Delivers nothing; the rows stay as they are.
    package func setNow(_ now: Int64) throws {
        try NuxieMachineError.check(nux_machine_set_now(handle, now))
    }

    /// A driver for the presentation `shown`, whose rounds write through
    /// the engine's functions `writers`. One per player, and a new one for
    /// each presentation.
    package func sceneDriver(for shown: NuxieMachineShown, writers: NuxieNativeSceneWriterFunctions) throws
        -> NuxieNativePlayerDriver
    {
        // Each field takes the engine function with the layout the header
        // gives it.
        var calls = NuxMachineSceneWriterCalls()
        calls.set_number = unsafeBitCast(writers.setNumber, to: type(of: calls.set_number))
        calls.set_unsigned = unsafeBitCast(writers.setUnsigned, to: type(of: calls.set_unsigned))
        calls.set_bool = unsafeBitCast(writers.setBool, to: type(of: calls.set_bool))
        calls.set_color = unsafeBitCast(writers.setColor, to: type(of: calls.set_color))
        calls.set_text = unsafeBitCast(writers.setText, to: type(of: calls.set_text))
        calls.reset = unsafeBitCast(writers.reset, to: type(of: calls.reset))
        calls.mount_row = unsafeBitCast(writers.mountRow, to: type(of: calls.mount_row))
        calls.remove_row = unsafeBitCast(writers.removeRow, to: type(of: calls.remove_row))
        calls.move_row = unsafeBitCast(writers.moveRow, to: type(of: calls.move_row))
        var driver = NuxMachinePlayerDriver()
        try NuxieMachineError.check(nux_machine_scene_driver(handle, shown.journey, shown.instance, &calls, &driver))
        guard let drive = unsafeBitCast(driver.drive, to: UnsafeRawPointer?.self) else {
            throw NuxieMachineError.nullArgument
        }
        return NuxieNativePlayerDriver(context: driver.context, drive: drive,
                                       release: unsafeBitCast(driver.release, to: UnsafeRawPointer?.self))
    }

    // MARK: Rows

    /// The rows of a call that delivered something. A call that ended the
    /// session still leaves its rows (the effects up to what it could not
    /// carry, then a dismiss and an end); they travel in the error.
    private func delivered(_ status: UInt32) throws -> [NuxieMachineRow] {
        if status == NuxieMachineStatus.faulted {
            throw NuxieMachineError.faulted(rows: try rows())
        }
        try NuxieMachineError.check(status)
        return try rows()
    }

    private func row(_ index: Int) throws -> NuxieMachineRow {
        var kind: UInt32 = 0
        try NuxieMachineError.check(nux_machine_effect_kind(handle, index, &kind))
        switch kind {
        case NuxieMachineStatus.rowPresent:
            var route = NuxMachineStr(ptr: nil, len: 0)
            var instance: UInt64 = 0
            var presentation: UInt32 = 0
            try NuxieMachineError.check(nux_machine_effect_present(handle, index, &route, &instance, &presentation))
            return .present(route: NuxieMachineStrings.copy(route) ?? "", instance: instance,
                            presentation: NuxieMachinePresentation(rawValue: presentation) ?? .unknown)
        case NuxieMachineStatus.rowPop:
            var instance: UInt64 = 0
            try NuxieMachineError.check(nux_machine_effect_pop(handle, index, &instance))
            return .pop(instance: instance)
        case NuxieMachineStatus.rowDismiss:
            var has = false
            var reason = NuxMachineStr(ptr: nil, len: 0)
            try NuxieMachineError.check(nux_machine_effect_dismiss(handle, index, &has, &reason))
            return .dismiss(reason: has ? NuxieMachineStrings.copy(reason) ?? "" : nil)
        case NuxieMachineStatus.rowCall:
            var id = NuxMachineCallId(record: 0, generation: 0, counter: 0)
            var name = NuxMachineStr(ptr: nil, len: 0)
            var awaited = false
            var place: UInt32 = 0
            try NuxieMachineError.check(nux_machine_effect_call(handle, index, &id, &name, &awaited, &place))
            return .call(NuxieMachineCall(
                id: NuxieMachineCallID(record: id.record, generation: id.generation, counter: id.counter),
                externName: NuxieMachineStrings.copy(name) ?? "", awaited: awaited,
                place: NuxieMachinePlace(rawValue: place) ?? .unknown))
        case NuxieMachineStatus.rowWakeAt:
            var has = false
            var moment: Int64 = 0
            try NuxieMachineError.check(nux_machine_effect_wake_at(handle, index, &has, &moment))
            return .wakeAt(has ? moment : nil)
        case NuxieMachineStatus.rowEnd:
            var reason: UInt32 = 0
            var has = false
            var fault = NuxMachineStr(ptr: nil, len: 0)
            try NuxieMachineError.check(nux_machine_effect_end(handle, index, &reason, &has, &fault))
            return .end(reason: NuxieMachineEnding(rawValue: reason) ?? .unknown,
                        fault: has ? NuxieMachineStrings.copy(fault) ?? "" : nil)
        case NuxieMachineStatus.rowNote:
            var note: UInt32 = 0
            try NuxieMachineError.check(nux_machine_effect_note(handle, index, &note))
            return .note(NuxieMachineNote(rawValue: note) ?? .unknown)
        case NuxieMachineStatus.rowHandOver:
            return .handOver
        default:
            return .unknown(kind: kind)
        }
    }
}

/// One row of a call's effects, copied out of the session.
package enum NuxieMachineRow: Equatable, Sendable {
    /// The machine presented this route as this instance. What is shown
    /// is read from the record ([`presented`]), not from this row.
    case present(route: String, instance: UInt64, presentation: NuxieMachinePresentation)
    /// The machine popped this instance.
    case pop(instance: UInt64)
    /// The machine dismissed what was presented, with a reason or none.
    case dismiss(reason: String?)
    /// Perform an extern.
    case call(NuxieMachineCall)
    /// Deliver a wake at this moment (milliseconds since the Unix epoch), or
    /// at none.
    case wakeAt(Int64?)
    /// The record has ended, for this reason, with the fault's code when the
    /// reason is a fault.
    case end(reason: NuxieMachineEnding, fault: String?)
    /// A line for the person's log.
    case note(NuxieMachineNote)
    /// This host cannot carry the record further.
    case handOver
    /// A row kind this module does not know: the header grew.
    case unknown(kind: UInt32)
}

/// An extern call's id: the record's number, its generation, and a number
/// from its counter. A reply names its call by it.
package struct NuxieMachineCallID: Hashable, Sendable {
    package let record: UInt64
    package let generation: UInt32
    package let counter: UInt64

    package init(record: UInt64, generation: UInt32, counter: UInt64) {
        self.record = record
        self.generation = generation
        self.counter = counter
    }
}

/// A `call` row: perform the extern named `externName` under `id`, where it
/// runs; an awaited call waits for its reply. Its arguments are not carried
/// yet.
package struct NuxieMachineCall: Equatable, Sendable {
    package let id: NuxieMachineCallID
    package let externName: String
    package let awaited: Bool
    package let place: NuxieMachinePlace

    package init(id: NuxieMachineCallID, externName: String, awaited: Bool, place: NuxieMachinePlace) {
        self.id = id
        self.externName = externName
        self.awaited = awaited
        self.place = place
    }
}

/// A value read out of the session.
package enum NuxieMachineValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case text(String)
    /// An enum value, by its name.
    case enumeration(String)

    fileprivate init(_ value: NuxMachineValue) throws {
        switch value.kind {
        case NuxieMachineStatus.valueBoolean: self = .bool(value.boolean)
        case NuxieMachineStatus.valueNumber: self = .number(value.number)
        case NuxieMachineStatus.valueText: self = .text(NuxieMachineStrings.copy(value.text) ?? "")
        case NuxieMachineStatus.valueEnum: self = .enumeration(NuxieMachineStrings.copy(value.text) ?? "")
        default: throw NuxieMachineError.valueNotCarried
        }
    }

    /// The text a reply lends the interface for this value: its own for a
    /// text or an enum value, none otherwise.
    fileprivate var lentText: String {
        switch self {
        case .text(let text), .enumeration(let text): text
        case .bool, .number: ""
        }
    }

    /// This value as a reply's field, with `text` the string lent for it.
    fileprivate func carried(_ text: NuxMachineStr) -> NuxMachineValue {
        let none = NuxMachineStr(ptr: nil, len: 0)
        return switch self {
        case .bool(let value):
            NuxMachineValue(kind: NuxieMachineStatus.valueBoolean, boolean: value, number: 0, text: none)
        case .number(let value):
            NuxMachineValue(kind: NuxieMachineStatus.valueNumber, boolean: false, number: value, text: none)
        case .text:
            NuxMachineValue(kind: NuxieMachineStatus.valueText, boolean: false, number: 0, text: text)
        case .enumeration:
            NuxMachineValue(kind: NuxieMachineStatus.valueEnum, boolean: false, number: 0, text: text)
        }
    }
}

/// The reply to a send into a mutation, as a store gives it.
package enum NuxieMachineReply: Equatable, Sendable {
    /// The answer: the fields of the declaration's answer type, in its
    /// order, each as a slot is read out (an enum's by its value's name).
    case answer([NuxieMachineValue])
    /// No answer, and why: what the store met before it could answer.
    case failure(NuxieMachineFailure)
}

/// Why a send into a mutation got no answer: a code, a short reason for the
/// program and a message for the person.
package struct NuxieMachineFailure: Equatable, Sendable {
    package let code: NuxieMachineFailureCode
    package let reason: String
    package let message: String

    package init(code: NuxieMachineFailureCode, reason: String, message: String) {
        self.code = code
        self.reason = reason
        self.message = message
    }
}

/// The failure codes of `nux_machine.h`, by the names a program reads.
package enum NuxieMachineFailureCode: String, Sendable {
    /// The store could not be reached.
    case offline
    /// The store did not answer in time.
    case timeout
    /// The store turned the call away.
    case refused
    /// The store's answer did not have the declared shape.
    case shape
    /// Any other error.
    case error

    fileprivate var carried: UInt32 {
        switch self {
        case .offline: UInt32(NUX_MACHINE_FAILURE_OFFLINE)
        case .timeout: UInt32(NUX_MACHINE_FAILURE_TIMEOUT)
        case .refused: UInt32(NUX_MACHINE_FAILURE_REFUSED)
        case .shape: UInt32(NUX_MACHINE_FAILURE_SHAPE)
        case .error: UInt32(NUX_MACHINE_FAILURE_ERROR)
        }
    }
}

package enum NuxieMachinePresentation: UInt32, Sendable {
    case push = 0, sheet = 1, cover = 2, fade = 3, none = 4, move = 5
    case unknown = 0xFFFF_FFFF
}

/// A height a sheet may rest at, as its row of the router's table writes
/// it: the system's medium and large, a height in points, a percent of the
/// height available, or the height of its content.
package enum NuxieMachineDetent: Equatable, Sendable {
    case medium
    case large
    /// A height in points, finite and above zero.
    case points(Double)
    /// A percent of the height available, above zero and at most 100.
    case percent(Double)
    case fitContent

    fileprivate init(kind: UInt32, value: Double) throws {
        switch kind {
        case UInt32(NUX_MACHINE_DETENT_MEDIUM): self = .medium
        case UInt32(NUX_MACHINE_DETENT_LARGE): self = .large
        case UInt32(NUX_MACHINE_DETENT_POINTS): self = .points(value)
        case UInt32(NUX_MACHINE_DETENT_PERCENT): self = .percent(value)
        case UInt32(NUX_MACHINE_DETENT_FIT_CONTENT): self = .fitContent
        default: throw NuxieMachineError.unknownAnswer(kind)
        }
    }
}

/// A swipe a host lets a person make on a presentation: down on a sheet,
/// or back from the edge on a pushed page.
package enum NuxieMachineSwipeGesture: Equatable, Sendable {
    case down
    case back

    fileprivate var carried: UInt32 {
        switch self {
        case .down: UInt32(NUX_MACHINE_GESTURE_DOWN.rawValue)
        case .back: UInt32(NUX_MACHINE_GESTURE_BACK.rawValue)
        }
    }
}

/// What a swipe does, as the machine works it out: the presentation stays
/// and nothing is delivered, the control its row's `swipe=` names is
/// pressed, or the presentation closes. The rule is the machine's; a host
/// only asks it and acts on the answer.
package enum NuxieMachineSwipeWould: Equatable, Sendable {
    case stays
    case presses
    case closes

    fileprivate init(_ answer: UInt32) throws {
        switch answer {
        case UInt32(NUX_MACHINE_SWIPE_STAYS.rawValue): self = .stays
        case UInt32(NUX_MACHINE_SWIPE_PRESSES.rawValue): self = .presses
        case UInt32(NUX_MACHINE_SWIPE_CLOSES.rawValue): self = .closes
        default: throw NuxieMachineError.unknownAnswer(answer)
        }
    }
}

package enum NuxieMachinePlace: UInt32, Sendable {
    case client = 0, server = 1
    case unknown = 0xFFFF_FFFF
}

package enum NuxieMachineEnding: UInt32, Sendable {
    case finished = 0, exited = 1, fault = 2
    case unknown = 0xFFFF_FFFF
}

package enum NuxieMachineNote: UInt32, Sendable {
    case started = 0, shown = 1, ended = 2
    case unknown = 0xFFFF_FFFF
}

/// The client's environment, as a session is told it: what is the same for
/// every presentation of the session, the scheme and the person's text
/// size. Where each presentation is shown is its own
/// ([`NuxieMachineScreenPlace`]).
package struct NuxieMachineEnvironment: Equatable, Sendable {
    /// Whether the client shows in the dark scheme.
    package var dark: Bool
    /// The person's body text size, in points: one `rem` of the session's
    /// pages. 17 at an iPhone's default size, and larger or smaller as the
    /// person sets it.
    package var textSize: Double

    package init(dark: Bool, textSize: Double) {
        self.dark = dark
        self.textSize = textSize
    }

    /// The environment as the header lays it out: the one place the struct
    /// is made.
    fileprivate var carried: NuxMachineEnvironment {
        NuxMachineEnvironment(
            struct_size: UInt32(MemoryLayout<NuxMachineEnvironment>.size),
            dark: dark,
            text_size: textSize)
    }
}

/// Where one presentation is shown, as a session is told it: its safe
/// area's four insets, and the size available to it, all in points. A
/// presentation's page reads its own (`env(safe-area-inset-top)` and the
/// rest), so a cover and a sheet over it can read different ones.
package struct NuxieMachineScreenPlace: Equatable, Sendable {
    package var top: Double
    package var right: Double
    package var bottom: Double
    package var left: Double
    package var width: Double
    package var height: Double

    package init(top: Double, right: Double, bottom: Double, left: Double, width: Double, height: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
        self.width = width
        self.height = height
    }

    /// The place as the header lays it out: the one place the struct is
    /// made.
    fileprivate var carried: NuxMachinePlace {
        NuxMachinePlace(
            struct_size: UInt32(MemoryLayout<NuxMachinePlace>.size),
            inset_top: top,
            inset_right: right,
            inset_bottom: bottom,
            inset_left: left,
            width: width,
            height: height)
    }
}

/// A fault the host reports itself ([`NuxieMachineSession.hostFault`]).
package enum NuxieMachineHostFault: Equatable, Sendable {
    /// The first frame of what the record presents did not come: its files
    /// never arrived, and the person closed the loading screen.
    case firstFrameDeadline

    fileprivate var code: UInt32 {
        switch self {
        case .firstFrameDeadline: UInt32(NUX_MACHINE_HOST_FAULT_FIRST_FRAME_DEADLINE)
        }
    }
}

/// What the host fills one asset of the compiled records with, as the
/// session lists them ([`NuxieMachineSession.sceneAssets`]).
package enum NuxieMachineSceneAsset: Equatable, Sendable {
    /// The face a text with no font of its own is drawn in: the
    /// platform's own.
    case platformFont
    /// A face a text draws in: the bytes of the folder's TTF file at
    /// `path`.
    case font(path: String)
    /// A picture: the bytes of the folder's file at `path`.
    case picture(path: String)
}

extension NuxieMachineAsset {
    /// The row as the header lays it out, its path lent for the call: the
    /// one place the struct is made.
    fileprivate func carried(path lent: NuxMachineStr) -> NuxMachineAsset {
        switch kind {
        case .picture(let width, let height):
            NuxMachineAsset(path: lent, kind: NuxieMachineStatus.assetPicture, bytes: byteCount,
                            width: width, height: height)
        case .font:
            NuxMachineAsset(path: lent, kind: NuxieMachineStatus.assetFont, bytes: byteCount, width: 0, height: 0)
        case .other:
            NuxMachineAsset(path: lent, kind: NuxieMachineStatus.assetOther, bytes: byteCount, width: 0, height: 0)
        }
    }
}

/// Every status but `NUX_MACHINE_OK`, with the header's meaning.
package enum NuxieMachineError: Error, Equatable, Sendable {
    /// A pointer the interface needed was NULL.
    case nullArgument
    /// The handle is not a live session.
    case notASession
    /// Another call on the same session is running.
    case busy
    /// A panic inside the machine; every later call on the session says so.
    case panicked
    /// A string handed in was not UTF-8.
    case notUTF8
    /// The source did not compile, or the compiled plan was not admitted:
    /// the refusals, one per line.
    case refused(String)
    /// `begin` started nothing for the event, with the last entry's reason.
    case declined(String?)
    /// The start did not happen and nothing is wrong: the machine declined
    /// it for a reason below `NUX_MACHINE_DECLINED_WRONG` (`once`, `if`,
    /// `unstarted` and the rest), whose text this carries. Only
    /// [`NuxieMachineSession.start`] throws it.
    case notStarted(String?)
    /// A fault ended the session earlier.
    case ended
    /// This call met something the session cannot carry and ended the
    /// session: its rows, ending in a dismiss and an `engine.failed` end.
    case faulted(rows: [NuxieMachineRow])
    /// No record has started yet.
    case noRecord
    /// No entry starts on an event of this name.
    case unknownEvent
    /// No presentation the record shows has this identity.
    case unknownInstance
    /// No send into a mutation that is still out has this id.
    case unknownCall
    /// The plan has no root slot of this name.
    case unknownSlot
    /// The slot holds a value of a kind the interface does not carry.
    case valueNotCarried
    /// No row has this index.
    case outOfRange
    /// The row at this index is of another kind.
    case wrongKind
    /// The instance's component has no view, so no artboard.
    case noArtboard
    /// The reply's fields are not the fields of the declaration's answer
    /// type, or its failure's code is not one the header knows.
    case replyDoesNotFit
    /// The environment could not be read: its size is smaller than the
    /// header's, or a number in it is not finite.
    case environmentDoesNotFit
    /// The place could not be read: its size is smaller than the header's,
    /// or a number in it is not finite.
    case placeDoesNotFit
    /// An asset's kind is not one a file of the folder can be, or the
    /// records named an asset of a kind this module does not fill.
    case assetDoesNotFit
    /// The host's fault is not one of the codes a host may report.
    case hostFaultDoesNotFit
    /// A status this module does not know: the header grew.
    case unknownStatus(UInt32)
    /// An answer this module does not know (a detent's kind, or what a
    /// swipe does): the header grew.
    case unknownAnswer(UInt32)

    /// The header's name for the status, as a fault code reads it.
    package var code: String {
        switch self {
        case .nullArgument: "null_argument"
        case .notASession: "not_a_session"
        case .busy: "busy"
        case .panicked: "panicked"
        case .notUTF8: "not_utf8"
        case .refused: "refused"
        case .declined: "declined"
        case .notStarted: "not_started"
        case .ended: "ended"
        case .faulted: "faulted"
        case .noRecord: "no_record"
        case .unknownEvent: "unknown_event"
        case .unknownInstance: "unknown_instance"
        case .unknownCall: "unknown_call"
        case .unknownSlot: "unknown_slot"
        case .valueNotCarried: "value_not_carried"
        case .outOfRange: "out_of_range"
        case .wrongKind: "wrong_kind"
        case .noArtboard: "no_artboard"
        case .replyDoesNotFit: "reply_does_not_fit"
        case .environmentDoesNotFit: "environment_does_not_fit"
        case .placeDoesNotFit: "place_does_not_fit"
        case .assetDoesNotFit: "asset_does_not_fit"
        case .hostFaultDoesNotFit: "host_fault_does_not_fit"
        case .unknownStatus(let status): "status_\(status)"
        case .unknownAnswer(let answer): "answer_\(answer)"
        }
    }

    fileprivate static func check(_ status: UInt32) throws {
        guard status != NuxieMachineStatus.ok else { return }
        throw byStatus[status] ?? .unknownStatus(status)
    }

    /// Each status by the header's number. `refused`, `declined` and
    /// `faulted` carry more where their calls read it.
    private static let byStatus: [UInt32: NuxieMachineError] = [
        UInt32(NUX_MACHINE_NULL_ARGUMENT): .nullArgument,
        UInt32(NUX_MACHINE_NOT_A_SESSION): .notASession,
        UInt32(NUX_MACHINE_BUSY): .busy,
        UInt32(NUX_MACHINE_PANICKED): .panicked,
        UInt32(NUX_MACHINE_NOT_UTF8): .notUTF8,
        UInt32(NUX_MACHINE_REFUSED): .refused(""),
        UInt32(NUX_MACHINE_DECLINED): .declined(nil),
        UInt32(NUX_MACHINE_ENDED): .ended,
        UInt32(NUX_MACHINE_FAULTED): .faulted(rows: []),
        UInt32(NUX_MACHINE_NO_RECORD): .noRecord,
        UInt32(NUX_MACHINE_UNKNOWN_EVENT): .unknownEvent,
        UInt32(NUX_MACHINE_UNKNOWN_INSTANCE): .unknownInstance,
        UInt32(NUX_MACHINE_UNKNOWN_CALL): .unknownCall,
        UInt32(NUX_MACHINE_UNKNOWN_SLOT): .unknownSlot,
        UInt32(NUX_MACHINE_VALUE_NOT_CARRIED): .valueNotCarried,
        UInt32(NUX_MACHINE_OUT_OF_RANGE): .outOfRange,
        UInt32(NUX_MACHINE_WRONG_KIND): .wrongKind,
        UInt32(NUX_MACHINE_NO_ARTBOARD): .noArtboard,
        UInt32(NUX_MACHINE_REPLY_DOES_NOT_FIT): .replyDoesNotFit,
        UInt32(NUX_MACHINE_ENVIRONMENT_DOES_NOT_FIT): .environmentDoesNotFit,
        UInt32(NUX_MACHINE_PLACE_DOES_NOT_FIT): .placeDoesNotFit,
        UInt32(NUX_MACHINE_ASSET_DOES_NOT_FIT): .assetDoesNotFit,
        UInt32(NUX_MACHINE_HOST_FAULT_DOES_NOT_FIT): .hostFaultDoesNotFit,
    ]
}

/// The header's constants, read once from the C module so a renumbering
/// there shows here as a compile error rather than a silent mismatch.
private enum NuxieMachineStatus {
    static let ok = UInt32(NUX_MACHINE_OK)
    static let refused = UInt32(NUX_MACHINE_REFUSED)
    static let declined = UInt32(NUX_MACHINE_DECLINED)
    static let faulted = UInt32(NUX_MACHINE_FAULTED)
    static let rowPresent = UInt32(NUX_MACHINE_ROW_PRESENT)
    static let rowPop = UInt32(NUX_MACHINE_ROW_POP)
    static let rowDismiss = UInt32(NUX_MACHINE_ROW_DISMISS)
    static let rowCall = UInt32(NUX_MACHINE_ROW_CALL)
    static let rowWakeAt = UInt32(NUX_MACHINE_ROW_WAKE_AT)
    static let rowEnd = UInt32(NUX_MACHINE_ROW_END)
    static let rowNote = UInt32(NUX_MACHINE_ROW_NOTE)
    static let rowHandOver = UInt32(NUX_MACHINE_ROW_HAND_OVER)
    static let valueBoolean = UInt32(NUX_MACHINE_VALUE_BOOLEAN)
    static let valueNumber = UInt32(NUX_MACHINE_VALUE_NUMBER)
    static let valueText = UInt32(NUX_MACHINE_VALUE_TEXT)
    static let valueEnum = UInt32(NUX_MACHINE_VALUE_ENUM)
    static let assetPicture = UInt32(NUX_MACHINE_ASSET_PICTURE)
    static let assetFont = UInt32(NUX_MACHINE_ASSET_FONT)
    static let assetOther = UInt32(NUX_MACHINE_ASSET_OTHER)
    static let assetPlatformFont = UInt32(NUX_MACHINE_ASSET_PLATFORM_FONT)
}

/// Strings across the interface: lent in for the length of one call, copied
/// out before the next.
private enum NuxieMachineStrings {
    /// Each string's UTF-8 bytes as a `NuxMachineStr`, alive while `body`
    /// runs.
    static func lend<Result>(_ strings: [String], _ body: ([NuxMachineStr]) throws -> Result) rethrows -> Result {
        let buffers = strings.map { string -> UnsafeMutableBufferPointer<UInt8> in
            let bytes = Array(string.utf8)
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(bytes.count, 1))
            _ = buffer.initialize(from: bytes)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let views = zip(strings, buffers).map { string, buffer in
            NuxMachineStr(ptr: UnsafePointer(buffer.baseAddress), len: string.utf8.count)
        }
        return try body(views)
    }

    /// A borrowed string, copied; `nil` when the interface gave none.
    static func copy(_ string: NuxMachineStr) -> String? {
        guard let pointer = string.ptr else { return nil }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: string.len), as: UTF8.self)
    }
}
#endif
