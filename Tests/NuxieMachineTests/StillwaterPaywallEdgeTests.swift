#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreGraphics
import Foundation
import ImageIO
import Metal
import QuartzCore
import XCTest
import NuxieMachine
import NuxieRuntime

/// Stillwater's paywall on a simulator, with no window: the machine compiled
/// from Stillwater's four `.nux` files drives the published Screen through
/// the engine and Metal, real pointers go in, and the frames are read back.
/// The script and what every cell holds are the parent repository's Mac
/// play test of the same Screen (`stillwater_paywall_tests`): start, a
/// pointer on Monthly, on the buy button (the store answers `failed`), on
/// "About the trial", then "Not now", or a swipe down in a second run.
///
/// Pixel checks compare a region of one frame with the same region of the
/// frame before. A region "changes" when at least `changedAtLeast` of its
/// pixels move by more than `difference` in some channel, and "holds" when
/// at most `steadyAtMost` do: a selection ring, a dot, a dim or a line of
/// text moves far more pixels than that, and antialiasing far fewer.
final class StillwaterPaywallEdgeTests: XCTestCase {
    // MARK: The Screen's known layout

    /// Boxes on the 390 by 844 Screen, `[x0, y0, x1, y1]`, worked out from
    /// its CSS alone, as the Mac play test's `BOXES` are. The error line and
    /// the terms line keep their slots shown or not, so no box moves.
    private enum Box {
        static let title: [Int] = [24, 134, 366, 210]
        static let annual: [Int] = [24, 250, 366, 322]
        static let monthly: [Int] = [24, 334, 366, 406]
        static let buy: [Int] = [24, 434, 366, 490]
        static let error: [Int] = [24, 490, 366, 542]
        static let close: [Int] = [24, 666, 366, 714]
        static let restore: [Int] = [24, 718, 189, 762]
        static let details: [Int] = [201, 718, 366, 762]
        static let terms: [Int] = [24, 770, 366, 810]
    }

    private static let width = 390
    private static let height = 844
    private static let difference = 48
    private static let changedAtLeast = 150
    private static let steadyAtMost = 24
    private static let edge = 2

    /// 09:00 on day zero, in milliseconds, as the Mac test starts.
    private static let nine: Int64 = 9 * 3_600_000
    private static let hour: Int64 = 3_600_000
    /// One frame at 60 frames a second.
    private static let tick: Float = 1.0 / 60.0

    // MARK: The script

    func testAPointerOnAPlanCardSelectsItThroughTheMachine() async throws {
        let run = try await Run()
        do {
            // 1. The start presents the paywall as a sheet, and after one
            // frame every cell holds what the machine wrote.
            await run.edge.start(event: "onboarding_completed", now: run.now)
            let presented = await run.edge.log.compactMap { entry -> String? in
                if case .present(let route, _, let presentation) = entry, presentation == .sheet { return route }
                return nil
            }
            XCTAssertEqual(presented, ["paywall"], "the start presents the paywall as a sheet")
            try await run.settle()
            let cells = try await run.cells()
            XCTAssertEqual(cells["title_text"], .bytes(Data("Ten quiet minutes,\nevery day.".utf8)))
            XCTAssertEqual(cells["annual_selected"], .bool(true))
            XCTAssertEqual(cells["annual_price"], .bytes(Data("$59.99".utf8)))
            XCTAssertEqual(cells["monthly_selected"], .bool(false))
            XCTAssertEqual(cells["monthly_price"], .bytes(Data("$9.99".utf8)))
            XCTAssertEqual(cells["buy_label"], .bytes(Data("Continue".utf8)))
            XCTAssertEqual(cells["buy_busy"], .bool(false))
            XCTAssertEqual(cells["error_visible"], .bool(false))
            XCTAssertEqual(cells["terms_visible"], .bool(false))
            let start = try await run.frame("start")

            // 2. A pointer on the Monthly card: one `tap_monthly`, the
            // record's plan is monthly, and both cards look different.
            var written = await run.edge.log.count
            let monthlyTap = try await run.tap(Box.monthly)
            XCTAssertEqual(monthlyTap, ["tap_monthly"])
            let plan = try await run.edge.slot("plan")
            XCTAssertEqual(plan, .enumeration("monthly"))
            let monthlyWrites = await run.writes(since: written)
            XCTAssertEqual(monthlyWrites.filter { $0.cell == "monthly_selected" }.map(\.value), [.bool(true)])
            XCTAssertEqual(monthlyWrites.filter { $0.cell == "annual_selected" }.map(\.value), [.bool(false)])
            let monthly = try await run.frame("monthly")
            XCTAssertTrue(Self.changes(start, monthly, Box.monthly), "the Monthly card looks the same")
            XCTAssertTrue(Self.changes(start, monthly, Box.annual), "the Yearly card looks the same")
            XCTAssertTrue(Self.holds(start, monthly, outside: [Box.annual, Box.monthly]),
                          "something outside the two cards changed")

            // 3. A pointer on the buy button: one awaited purchase reaches
            // the store, which answers `failed`; the button is busy, then not,
            // and the error line shows.
            written = await run.edge.log.count
            let buyTap = try await run.tap(Box.buy, framesAfter: 1)
            XCTAssertEqual(buyTap, ["tap_buy"])
            let buying = try await run.frame("buying")
            try await run.settle(frames: 2)
            let failed = try await run.frame("failed")
            let calls = run.store.calls
            XCTAssertEqual(calls.map(\.externName), ["purchase"])
            XCTAssertEqual(calls.map(\.awaited), [true])
            let answered = await run.edge.log.dropFirst(written).compactMap { entry -> String? in
                if case .answer(_, let outcome) = entry { return outcome }
                return nil
            }
            XCTAssertEqual(answered, ["failed"])
            let buyWrites = await run.writes(since: written)
            XCTAssertEqual(buyWrites.filter { $0.cell == "buy_busy" }.map(\.value), [.bool(true), .bool(false)])
            XCTAssertEqual(buyWrites.filter { $0.cell == "error_visible" }.map(\.value), [.bool(true)])
            XCTAssertTrue(Self.changes(monthly, failed, Box.error), "the error line does not show")
            XCTAssertTrue(Self.holds(monthly, failed, Box.buy), "the buy button stays dimmed")
            XCTAssertTrue(Self.changes(monthly, buying, Box.buy), "the buy button never looks busy")

            // 4. A pointer on "About the trial": the terms line shows.
            let detailsTap = try await run.tap(Box.details)
            XCTAssertEqual(detailsTap, ["tap_details"])
            let details = try await run.frame("details")
            XCTAssertTrue(Self.changes(failed, details, Box.terms), "the terms line does not show")

            // 5. A pointer on "Not now": the paywall is dismissed, the record
            // stays open, and the evening offer's wake is recorded.
            written = await run.edge.log.count
            let closeTap = try await run.tap(Box.close)
            XCTAssertEqual(closeTap, ["tap_close"])
            let closing = await Array(run.edge.log.dropFirst(written))
            XCTAssertTrue(closing.contains(.dismiss(reason: "paywall_closed")), "\(closing)")
            XCTAssertTrue(closing.contains(.wakeAt(18 * Self.hour)), "\(closing)")
            XCTAssertEqual(run.owner.dismissals.count, 1, "the owner hears one dismissal")
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")])
            let stillOpen = try await run.edge.recordOpen()
            XCTAssertTrue(stillOpen, "the record waits for the evening offer")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            XCTAssertEqual(run.store.calls.count, 1, "one call in the whole script")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    func testASwipeDownEndsTheRecord() async throws {
        let run = try await Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            var tapped = try await run.tap(Box.monthly)
            tapped += try await run.tap(Box.buy)
            tapped += try await run.tap(Box.details)
            XCTAssertEqual(tapped, ["tap_monthly", "tap_buy", "tap_details"])
            let written = await run.edge.log.count
            await run.edge.closed(now: run.advance())
            let closing = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(closing.filter {
                if case .pop = $0 { return true }
                if case .end = $0 { return true }
                return false
            }, [.pop(instance: 2), .end(reason: .finished, fault: nil)])
            let open = try await run.edge.recordOpen()
            XCTAssertFalse(open, "a swipe down ends the record")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            XCTAssertTrue(run.owner.dismissals.isEmpty, "a swipe down has already closed the sheet")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A reported event the plan does not handle ends in the one fault path:
    /// the edge stops, records the code, and tells its owner to dismiss. A
    /// stopped edge steps nothing more.
    func testAnEventThePlanDoesNotHandleFaults() async throws {
        let run = try await Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            await run.edge.handleReported("tap_nothing", now: run.advance())
            let recorded = await run.edge.fault
            let fault = try XCTUnwrap(recorded)
            XCTAssertEqual(fault.code, "machine.unknown_object")
            XCTAssertEqual(run.owner.dismissals.count, 1, "the owner hears one dismissal")
            XCTAssertEqual(run.owner.dismissals, [.fault(fault)])
            let afterFault = try await run.tap(Box.monthly)
            XCTAssertEqual(afterFault, [], "a stopped edge steps nothing")
            await run.edge.handleReported("tap_nothing", now: run.advance())
            XCTAssertEqual(run.owner.dismissals.count, 1, "a stopped edge tells nothing more")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A store asked for an extern it cannot perform ends in the same fault
    /// path. "Restore purchases" calls `restore`, which the stand-in store
    /// does not answer.
    func testAStoreAskedForAnUnknownExternFaults() async throws {
        let run = try await Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            let restoreTap = try await run.tap(Box.restore)
            XCTAssertEqual(restoreTap, ["tap_restore"])
            let recorded = await run.edge.fault
            let fault = try XCTUnwrap(recorded)
            XCTAssertEqual(fault.code, "store.unknown-extern")
            XCTAssertEqual(run.store.calls.map(\.externName), ["restore"])
            XCTAssertEqual(run.owner.dismissals.count, 1, "the owner hears one dismissal")
            XCTAssertEqual(run.owner.dismissals, [.fault(fault)])
            let afterFault = try await run.tap(Box.monthly)
            XCTAssertEqual(afterFault, [], "a stopped edge steps nothing")
            XCTAssertEqual(run.owner.dismissals.count, 1, "a stopped edge tells nothing more")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A Screen whose view has an `if` with an `else`: presenting it shows
    /// the `else`, a write the machine's C interface cannot carry (the
    /// interface crate's `tests/refusals.rs`, its route renamed so the
    /// Stillwater Screen is its artwork). The header documents what the
    /// call leaves: the effects up to that write, a dismiss with no reason,
    /// and an end whose fault is "engine.failed".
    private static let showsARegion = """
        component App
          routes
            paywall  Card(on=false)  sheet
          entry
            on event "go"
            do go(paywall)

        component Card
          props
            on: boolean
          view
            column
              text "Hi" id="label"
              if on
                box id="yes"
              else
                box id="no"

        """

    /// A write the machine cannot carry ends in the one fault path, and the
    /// owner hears that fault alone: not the machine's dismiss row before
    /// it. The record keeps both rows.
    func testAWriteTheMachineCannotCarryTellsOneFaultDismissal() async throws {
        let plan = NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: Self.showsARegion)],
            root: "main", app: "app", experience: "card", version: 1)
        let run = try await Run(plan: plan)
        do {
            await run.edge.start(event: "go", now: run.now)
            let log = await run.edge.log
            XCTAssertTrue(log.contains { entry in
                if case .present("paywall", _, .sheet) = entry { return true }
                return false
            }, "\(log)")
            XCTAssertEqual(Array(log.suffix(2)), [.dismiss(reason: nil), .end(reason: .fault, fault: "engine.failed")])
            let recorded = await run.edge.fault
            let fault = try XCTUnwrap(recorded)
            XCTAssertEqual(fault.code, "engine.failed")
            XCTAssertEqual(run.owner.dismissals.count, 1, "the owner hears one dismissal")
            XCTAssertEqual(run.owner.dismissals, [.fault(fault)])
            let open = try await run.edge.recordOpen()
            XCTAssertFalse(open, "the fault ended the session")

            // A stopped edge takes nothing more and tells nothing more.
            await run.edge.start(event: "go", now: run.advance())
            await run.edge.closed(now: run.advance())
            await run.edge.handleReported("tap_label", now: run.advance())
            try await run.settle()
            let after = await run.edge.log
            XCTAssertEqual(after, log, "a stopped edge records nothing more")
            XCTAssertEqual(run.owner.dismissals.count, 1, "a stopped edge tells nothing more")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    // MARK: Pixels

    /// Whether the region `box` of `after` differs from `before`.
    private static func changes(_ before: Data, _ after: Data, _ box: [Int]) -> Bool {
        moved(before, after, in: box) >= changedAtLeast
    }

    /// Whether the region `box` of `after` is the region of `before`.
    private static func holds(_ before: Data, _ after: Data, _ box: [Int]) -> Bool {
        moved(before, after, in: box) <= steadyAtMost
    }

    /// Whether everything outside the boxes `except` holds. Each box grows
    /// by `edge` on every side: a card's border draws on the box's last row
    /// and column, which the box itself leaves out.
    private static func holds(_ before: Data, _ after: Data, outside except: [[Int]]) -> Bool {
        let grown = except.map { [$0[0] - edge, $0[1] - edge, $0[2] + edge, $0[3] + edge] }
        return moved(before, after, in: [0, 0, width, height], except: grown) <= steadyAtMost
    }

    /// How many pixels in `box`, and not in `except`, move by more than
    /// `difference` in some channel.
    private static func moved(_ before: Data, _ after: Data, in box: [Int], except: [[Int]] = []) -> Int {
        precondition(before.count == after.count && before.count == width * height * 4)
        var count = 0
        before.withUnsafeBytes { first in
            after.withUnsafeBytes { second in
                for y in box[1]..<box[3] {
                    for x in box[0]..<box[2] {
                        if except.contains(where: { x >= $0[0] && x < $0[2] && y >= $0[1] && y < $0[3] }) { continue }
                        let at = (y * width + x) * 4
                        for channel in 0..<4 where abs(Int(first[at + channel]) - Int(second[at + channel])) > difference {
                            count += 1
                            break
                        }
                    }
                }
            }
        }
        return count
    }
}

// MARK: - One run of the script

/// A fresh session and Screen, its clock, and what its store and owner heard.
private final class Run {
    let edge: NuxieMachineEdge
    let store = RecordingStore()
    let owner = Owner()
    private(set) var now: Int64 = 9 * 3_600_000
    private var frames = 0

    /// Stillwater's plan over its Screen, or `plan` over the same Screen.
    init(plan: NuxieMachinePlanSource? = nil) async throws {
        let fixture = try Fixture.load()
        let owner = self.owner
        edge = try await NuxieMachineEdge(
            plan: plan ?? fixture.plan, screen: fixture.screen, store: store,
            onDismiss: { owner.heard($0) })
    }

    /// The clock a second on, as the Mac test spaces its calls.
    func advance() -> Int64 {
        now += 1000
        return now
    }

    /// Frames with no pointer, for the writes of the last frame to show.
    func settle(frames count: Int = 3) async throws {
        for _ in 0..<count {
            await edge.frame(elapsedSeconds: 1.0 / 60.0, now: now)
        }
    }

    /// A pointer down and up at the center of `box`, a second after the
    /// last call, each in its own frame, then `framesAfter` frames with no
    /// pointer. The Screen's named events reported in all of them (the
    /// engine's reserved and unnamed ones left out, as the edge leaves them).
    func tap(_ box: [Int], framesAfter: Int = 3) async throws -> [String] {
        let x = Float(box[0] + box[2]) / 2
        let y = Float(box[1] + box[3]) / 2
        let at = advance()
        var reported: [String] = []
        for kind in [NuxieNativePointerKind.down, .up] {
            reported += await edge.frame(pointers: [NuxieNativePointerEvent(kind: kind, x: x, y: y)],
                                         elapsedSeconds: 1.0 / 60.0, now: at).reported
        }
        for _ in 0..<framesAfter {
            reported += await edge.frame(elapsedSeconds: 1.0 / 60.0, now: at).reported
        }
        return reported.filter { !$0.hasPrefix("$") && !$0.isEmpty }
    }

    /// The writes the edge made after its first `count` log entries.
    func writes(since count: Int) async -> [(cell: String, value: NuxieMachineValue)] {
        await edge.log.dropFirst(count).compactMap { entry in
            if case .write(let cell, let value) = entry { return (cell, value) }
            return nil
        }
    }

    /// The Screen's cells as the engine holds them now.
    func cells() async throws -> [String: NuxieNativeViewModelValue] {
        let snapshot = try await edge.runtime.snapshot()
        guard case .referencedInstance(let state)? = snapshot.values.first(where: {
            $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "state"
        })?.value else { return [:] }
        var cells: [String: NuxieNativeViewModelValue] = [:]
        for value in snapshot.values where value.ownerInstanceID == state { cells[value.name] = value.value }
        return cells
    }

    /// The Screen drawn now with Metal, read back as BGRA, and kept as a PNG
    /// attachment named `stillwater-paywall-<name>`.
    func frame(_ name: String) async throws -> Data {
        frames += 1
        let pixels = try await Pixels.render(edge.runtime, width: 390, height: 844)
        try await Pixels.attach(pixels, width: 390, height: 844, name: "stillwater-paywall-\(frames)-\(name)")
        return pixels
    }

    func close() async throws {
        try await edge.close()
    }
}

/// A store that hands every call to the stand-in and keeps them.
private final class RecordingStore: NuxieMachineStore, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [NuxieMachineCall] = []
    private let standIn = NuxieMachineStandInStore()

    var calls: [NuxieMachineCall] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func perform(_ call: NuxieMachineCall) async throws -> String {
        lock.withLock { received.append(call) }
        return try await standIn.perform(call)
    }
}

/// The edge's owner: what it was told to dismiss.
private final class Owner: @unchecked Sendable {
    private let lock = NSLock()
    private var heardDismissals: [NuxieMachineEdgeDismissal] = []

    var dismissals: [NuxieMachineEdgeDismissal] {
        lock.lock()
        defer { lock.unlock() }
        return heardDismissals
    }

    func heard(_ dismissal: NuxieMachineEdgeDismissal) {
        lock.withLock { heardDismissals.append(dismissal) }
    }
}

// MARK: - The fixture

/// `Fixtures/stillwater-paywall`: the published Screen, Stillwater's four
/// `.nux` files, and the System fonts the publisher's report names.
private struct Fixture {
    let plan: NuxieMachinePlanSource
    let screen: NuxieMachineScreenSource

    static func load() throws -> Fixture {
        func url(_ name: String) throws -> URL {
            let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
            return try XCTUnwrap(Bundle(for: Run.self).url(
                forResource: parts[0], withExtension: parts[1], subdirectory: "stillwater-paywall"),
                "the test bundle carries stillwater-paywall/\(name)")
        }
        struct Provenance: Decodable {
            struct Font: Decodable {
                let authoredAssetId: UInt32
                let assetUniqueName: String
                let weight: String
                let style: String
            }
            let fonts: [Font]
        }
        let provenance = try JSONDecoder().decode(Provenance.self, from: Data(contentsOf: url("provenance.json")))
        let files = try ["main.nux", "paywall.nux", "screens.nux", "done.nux"].map {
            NuxieMachineSourceFile(path: $0, text: try String(contentsOf: url($0), encoding: .utf8))
        }
        return Fixture(
            plan: NuxieMachinePlanSource(files: files, root: "main", app: "app", experience: "stillwater", version: 1),
            screen: NuxieMachineScreenSource(
                bytes: try Data(contentsOf: url("screen.riv")), artboard: "paywall", route: "paywall",
                pixelWidth: 390, pixelHeight: 844,
                systemFonts: provenance.fonts.map {
                    NuxieMachineSystemFont(authoredAssetID: $0.authoredAssetId, assetUniqueName: $0.assetUniqueName,
                                           weight: $0.weight, style: $0.style)
                }))
    }
}

// MARK: - Reading frames back

private enum Pixels {
    /// One frame of the engine's Screen into a drawable, read back as BGRA
    /// rows, as the SDK's native runtime tests read theirs.
    static func render(_ runtime: NuxieNativeRuntime, width: Int, height: Int) async throws -> Data {
        let device = try await runtime.metalDevice().value
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: width, height: height)
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        guard let drawable = layer.nextDrawable() else {
            throw XCTSkip("This host cannot vend a CAMetalDrawable")
        }
        let bytesPerRow = (width * 4 + 255) & ~255
        let buffer = try XCTUnwrap(device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared))
        let readback = NuxieNativeFrameReadback(buffer: buffer, bytesPerRow: bytesPerRow)
        let drawn = Signal()
        let outcome = try await runtime.render(layoutScaleFactor: 1,
            drawable: .available(NuxieNativeDrawable(drawable)), clearColor: 0xFF00_0000,
            readback: readback, completion: { drawn.fire() })
        try await drawn.wait(seconds: 2)
        XCTAssertEqual(outcome.disposition, .presented)
        let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var pixels = Data(capacity: width * height * 4)
        for row in 0..<height {
            pixels.append(source + row * bytesPerRow, count: width * 4)
        }
        return pixels
    }

    /// The BGRA frame as a PNG attachment kept with the test's results.
    /// XCTest takes activities on the main thread.
    @MainActor
    static func attach(_ pixels: Data, width: Int, height: Int, name: String) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let attachment = XCTAttachment(data: bytes as Data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: name) { $0.add(attachment) }
    }
}

/// A completion the renderer calls once, awaited with a deadline.
private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() { lock.withLock { fired = true } }

    func wait(seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !lock.withLock({ fired }) {
            guard Date() < deadline else {
                throw NSError(domain: "StillwaterPaywallEdgeTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "the frame did not complete"])
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
#endif
