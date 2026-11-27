#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreGraphics
import Foundation
import XCTest
import NuxieMachine
import NuxieRuntime

/// An edge whose page draws files of the Experience's folder waits for them
/// on a simulator, with no window: the start asks the byte source and does
/// not wait for it, the page is presented and held with no player, each
/// answer is kept as it comes, and a frame after the last opens the page.
/// A file the source cannot give is a failed path, told by path, and
/// trying again asks for those paths only. Closing a page that waits is the
/// host's own fault, `first_frame.deadline`.
///
/// The pages are `Fixtures/views-picture` (`assets/hero.png`, drawn in four
/// colored quadrants), and for two files that page's picture on the title
/// page of `Fixtures/views-font` (`assets/brand.ttf`). Each test's oracle
/// is named in its comment; none is the edge's own code.
final class AssetWaitEdgeTests: XCTestCase {
    static let tick: Float = 1.0 / 60.0
    static let hero = "assets/hero.png"
    static let brand = "assets/brand.ttf"

    /// A late answer. The start presents the page at once, held with no
    /// player: the owner is told the page and that it waits for its
    /// picture, nothing is drawn and no frame is asked for. The answer asks
    /// for a frame; that frame's report says the files are in and the page
    /// opens; the frame after it steps the page, and it draws the picture
    /// in its colors.
    ///
    /// The oracle is what she sees (the sheet up at once, the page in place
    /// of the shimmer once its bytes are in) and the picture's own colors.
    func testALateAnswerHoldsThePageAndTheFrameAfterItOpensIt() async throws {
        let bytes = AskedBytes(folder: try PictureFolder.url())
        let run = try PictureRun(bytes: bytes)
        do {
            await run.edge.start(event: "opened", now: run.now)
            let stack = await run.edge.stack
            let shown = try XCTUnwrap(stack.last?.shown, "the start presented nothing")
            XCTAssertEqual(stack.map(\.route), ["fits"])
            guard case .delivered(let told, _)? = run.owner.reports.last else {
                return XCTFail("the start told no presentation: \(run.owner.reports)")
            }
            XCTAssertEqual(told, stack, "the owner was not shown the page while it waits")
            XCTAssertEqual(run.owner.assetsTold, [.waiting([Self.hero])])
            let held = await run.edge.screen(for: shown)
            XCTAssertNil(held, "the page has a player before its picture arrived")
            let asking = await run.edge.waitingForFrame()
            XCTAssertFalse(asking, "a page held for its picture waits for a frame")
            XCTAssertFalse(run.asks.take(), "a frame was asked for before the picture arrived")
            let log = await run.edge.log
            XCTAssertTrue(log.contains(.held(shown)), "\(log)")
            XCTAssertFalse(log.contains(.opened(shown)), "\(log)")

            try await bytes.untilAsked(Self.hero)
            try await bytes.answer(Self.hero)
            await run.edge.assetsAnswered()
            XCTAssertTrue(run.asks.take(), "the answer asked for no frame")
            let before = run.owner.reports.count
            await run.edge.frame(elapsedSeconds: Self.tick, now: run.now)
            XCTAssertEqual(Array(run.owner.reports.dropFirst(before)),
                           [.delivered(shown: stack, rows: [.assets(.ready)])])
            let opened = await run.edge.log
            XCTAssertTrue(opened.contains(.opened(shown)), "\(opened)")
            let player = await run.edge.screen(for: shown)
            XCTAssertNotNil(player, "the page did not open once its picture arrived")
            let owed = await run.edge.waitingForFrame()
            XCTAssertTrue(owed, "the opened page owes no step")
            await run.edge.frame(elapsedSeconds: Self.tick, now: run.now)
            let stepped = await run.edge.waitingForFrame()
            XCTAssertFalse(stepped, "the frame after the answer did not step the page")

            let look = try await run.look("late-answer")
            look.expect([("top left", PictureEdgeTests.point(PictureEdgeTests.fill, 50, 50), PictureEdgeTests.red),
                         ("bottom right", PictureEdgeTests.point(PictureEdgeTests.fill, 150, 150),
                          PictureEdgeTests.yellow)], in: "fill")
            try await run.close()
        } catch {
            bytes.dropAll()
            try? await run.close()
            throw error
        }
    }

    /// Two files, the face and the picture. The picture fails offline while
    /// the face is still coming: the next frame tells the failure, by path,
    /// at once. The face's answer, when it comes, is kept and tells nothing
    /// new. Trying again asks the source for the picture only, once more,
    /// and tells the page waits for it alone; its answer opens the page.
    ///
    /// The oracle is the recovery reason's own rule (a `URLError` that says
    /// the device has no connection reads as offline) and the source's own
    /// record of what it was asked.
    func testAFailedFileShowsAtOnceWhileAnotherComesAndTryAgainAsksOnlyForIt() async throws {
        let bytes = AskedBytes(read: { try await Self.readEitherFolder($0) })
        let run = try PictureRun(plan: Self.bothFiles(), bytes: bytes)
        do {
            await run.edge.start(event: "opened", now: run.now)
            try await bytes.untilAsked(Self.brand)
            try await bytes.untilAsked(Self.hero)
            XCTAssertEqual(bytes.asked.sorted(), [Self.brand, Self.hero])
            XCTAssertEqual(run.owner.assetsTold, [.waiting([Self.brand, Self.hero])])
            _ = run.asks.take()

            bytes.fail(Self.hero, with: offlineError)
            try await waitForAsk(run.asks)
            await run.edge.frame(elapsedSeconds: Self.tick, now: run.now)
            let failed = NuxieMachineAssets.failed([NuxieMachineAssetFailure(path: Self.hero, reason: .offline)])
            XCTAssertEqual(run.owner.assetsTold.last, failed, "the failure was not told at once")
            let log = await run.edge.log
            XCTAssertTrue(log.contains(.assets(failed)), "the log does not keep the failure by path")

            try await bytes.answer(Self.brand)
            try await waitForAsk(run.asks)
            let told = run.owner.assetsTold.count
            await run.edge.frame(elapsedSeconds: Self.tick, now: run.now)
            XCTAssertEqual(run.owner.assetsTold.count, told, "the face's answer changed what is told")
            let stillHeld = await run.edge.screen()
            XCTAssertNil(stillHeld, "the page opened with its picture failed")

            await run.edge.refreshAssets()
            XCTAssertEqual(run.owner.assetsTold.last, .waiting([Self.hero]),
                           "trying again waits for more than the picture")
            try await bytes.untilAsked(Self.hero, times: 2)
            XCTAssertEqual(bytes.asked.filter { $0 == Self.brand }.count, 1,
                           "the face that arrived was asked for again")
            XCTAssertEqual(bytes.asked.filter { $0 == Self.hero }.count, 2)

            try await bytes.answer(Self.hero)
            await run.edge.assetsAnswered()
            await run.edge.frame(elapsedSeconds: Self.tick, now: run.now)
            XCTAssertEqual(run.owner.assetsTold.last, .ready)
            let opened = await run.edge.screen()
            XCTAssertNotNil(opened, "the page did not open once both files were in")
            try await run.close()
        } catch {
            bytes.dropAll()
            try? await run.close()
            throw error
        }
    }

    /// The picture fails while the page waits, and before the frame that
    /// would tell it, a start on an event no entry starts on is delivered.
    /// That start did not happen: the owner hears only that, and the page
    /// stays as it was. The failure is not lost: the next frame tells it,
    /// by path.
    ///
    /// The oracle is what she sees: the recovery screen once the picture
    /// cannot come, whatever else the app asked meanwhile.
    func testAFailureIsStillToldAfterAStartThatDidNotHappen() async throws {
        let bytes = AskedBytes(folder: try PictureFolder.url())
        let run = try PictureRun(bytes: bytes)
        do {
            await run.edge.start(event: "opened", now: run.now)
            let stack = await run.edge.stack
            XCTAssertEqual(stack.map(\.route), ["fits"])
            XCTAssertEqual(run.owner.assetsTold, [.waiting([Self.hero])])
            try await bytes.untilAsked(Self.hero)
            _ = run.asks.take()

            bytes.fail(Self.hero, with: offlineError)
            try await waitForAsk(run.asks)
            let heard = run.owner.reports.count
            await run.edge.start(event: "nope", now: run.now)
            XCTAssertEqual(Array(run.owner.reports.dropFirst(heard)), [.notStarted(reason: nil)],
                           "the start that did not happen told more than that")
            let still = await run.edge.stack
            XCTAssertEqual(still, stack, "the start that did not happen moved the page")

            await run.edge.frame(elapsedSeconds: Self.tick, now: run.now)
            let failed = NuxieMachineAssets.failed([NuxieMachineAssetFailure(path: Self.hero, reason: .offline)])
            XCTAssertEqual(run.owner.assetsTold, [.waiting([Self.hero]), failed], "the failure was lost")
            let fault = await run.edge.fault
            XCTAssertNil(fault, "\(String(describing: fault))")
            try await run.close()
        } catch {
            bytes.dropAll()
            try? await run.close()
            throw error
        }
    }

    /// Closing a page that waits: the session's rows are exactly a dismiss
    /// with no reason and an end in the fault `first_frame.deadline`, the
    /// owner hears that fault, and nothing is shown after it.
    ///
    /// The oracle is the header's text for `nux_machine_host_fault`.
    func testExitWhileWaitingEndsTheRecordInTheHostsFault() async throws {
        let run = try PictureRun(bytes: NoFolderFiles())
        await run.edge.start(event: "opened", now: run.now)
        await run.edge.assetsAnswered()
        await run.edge.frame(elapsedSeconds: Self.tick, now: run.now)
        let stack = await run.edge.stack
        let shown = try XCTUnwrap(stack.last?.shown, "the start presented nothing")

        await run.edge.hostFault(.firstFrameDeadline, now: run.now)
        let fault = await run.edge.fault
        XCTAssertEqual(fault?.code, "first_frame.deadline", "\(String(describing: fault))")
        XCTAssertEqual(run.owner.reports.last, fault.map { NuxieMachineEdgeReport.fault($0) },
                       "the owner was not told the fault")
        let log = await run.edge.log
        XCTAssertEqual(Array(log.suffix(3)),
                       [.dismiss(reason: nil), .end(reason: .fault, fault: "first_frame.deadline"), .gone(shown)])
        let after = await run.edge.stack
        XCTAssertEqual(after, [], "something is shown after the fault")
        try await run.close()
    }

    /// Closing once every page has opened: there is nothing to give up on.
    /// The close is recorded as dropped, the record stays open, the page
    /// keeps its player, and the owner hears nothing.
    ///
    /// The oracle is the approved rule that the close shows only while a
    /// page waits for its files; one that reaches the edge later is late.
    func testExitAfterTheFilesAreInIsDropped() async throws {
        let run = try PictureRun(bytes: NuxieMachineFolderByteSource(folder: PictureFolder.url()))
        await run.edge.start(event: "opened", now: run.now)
        await run.edge.assetsAnswered()
        await run.edge.frame(elapsedSeconds: Self.tick, now: run.now)
        let stack = await run.edge.stack
        let shown = try XCTUnwrap(stack.last?.shown, "the start presented nothing")
        let opened = await run.edge.screen(for: shown)
        XCTAssertNotNil(opened, "the page did not open")
        let heard = run.owner.reports.count

        await run.edge.hostFault(.firstFrameDeadline, now: run.now)
        let log = await run.edge.log
        XCTAssertEqual(log.last, .droppedExit)
        let fault = await run.edge.fault
        XCTAssertNil(fault)
        let stillOpen = try await run.edge.recordOpen()
        XCTAssertTrue(stillOpen, "the late close ended the record")
        let still = await run.edge.screen(for: shown)
        XCTAssertNotNil(still, "the late close took the page's player")
        XCTAssertEqual(run.owner.reports.count, heard, "the owner heard of a late close")
        try await run.close()
    }

    /// Two edges, two sources: one has no bytes for the picture, the other
    /// has them. The failure stays with its own edge: the other opens its
    /// page and draws the picture in its colors, and the failing one is
    /// still waiting, with no fault.
    ///
    /// The oracle is the picture's own colors, and that each Experience is
    /// its own session.
    func testAFailureStaysWithItsExperienceAndAnotherDraws() async throws {
        let failing = try PictureRun(bytes: NoFolderFiles())
        let drawing = try PictureRun(bytes: NuxieMachineFolderByteSource(folder: PictureFolder.url()))
        do {
            await failing.edge.start(event: "opened", now: failing.now)
            await drawing.edge.start(event: "opened", now: drawing.now)
            await failing.edge.assetsAnswered()
            await failing.edge.frame(elapsedSeconds: Self.tick, now: failing.now)
            XCTAssertEqual(failing.owner.assetsTold.last,
                           .failed([NuxieMachineAssetFailure(path: Self.hero, reason: .unavailable)]))

            let look = try await drawing.look("beside-a-failure")
            XCTAssertEqual(drawing.owner.assetsTold.last ?? .ready, .ready)
            look.expect([("top left", PictureEdgeTests.point(PictureEdgeTests.fill, 50, 50), PictureEdgeTests.red),
                         ("bottom right", PictureEdgeTests.point(PictureEdgeTests.fill, 150, 150),
                          PictureEdgeTests.yellow)], in: "the other Experience's fill")

            let fault = await failing.edge.fault
            XCTAssertNil(fault, "the failing edge stopped")
            let held = await failing.edge.screen()
            XCTAssertNil(held, "the failing edge opened its page")
            try await failing.close()
            try await drawing.close()
        } catch {
            try? await failing.close()
            try? await drawing.close()
            throw error
        }
    }

    /// A place told while the page waits is taken: it is logged for the
    /// page, not dropped, and the first frames after the answer draw the
    /// page in it. The page pads its top by its place's top inset; told an
    /// inset of 100, the first picture's box starts 100 points lower, and
    /// the page shows where the box would be with no inset.
    ///
    /// The oracle is CSS padding: `env(safe-area-inset-top)` is the top
    /// inset of the place told, and the picture's own colors.
    func testAPlaceToldWhileWaitingIsDrawnOnceThePageOpens() async throws {
        let bytes = AskedBytes(folder: try PictureFolder.url())
        let run = try PictureRun(plan: PictureFolder.plan(main: PictureFolder.paddedBySafeArea()), bytes: bytes)
        do {
            await run.edge.start(event: "opened", now: run.now)
            let stack = await run.edge.stack
            let shown = try XCTUnwrap(stack.last?.shown, "the start presented nothing")
            let place = NuxieMachineScreenPlace(top: 100, right: 0, bottom: 0, left: 0, width: 390, height: 844)
            await run.edge.place(place, for: shown, now: run.now)
            let log = await run.edge.log
            XCTAssertTrue(log.contains(.place(shown, place)), "\(log)")
            XCTAssertFalse(log.contains(.droppedPlace(shown)), "a place for a page that waits was dropped")
            let fault = await run.edge.fault
            XCTAssertNil(fault, "\(String(describing: fault))")

            try await bytes.untilAsked(Self.hero)
            try await bytes.answer(Self.hero)
            let look = try await run.look("place-while-waiting")
            let fill = PictureEdgeTests.fill
            let moved = fill.offsetBy(dx: 0, dy: 100)
            look.expect([
                ("top left", PictureEdgeTests.point(moved, 50, 50), PictureEdgeTests.red),
                ("bottom right", PictureEdgeTests.point(moved, 150, 150), PictureEdgeTests.yellow),
                ("where the box is told no inset", PictureEdgeTests.point(fill, 50, 50), PictureEdgeTests.page),
            ], in: "fill, told a top inset of 100")
            try await run.close()
        } catch {
            bytes.dropAll()
            try? await run.close()
            throw error
        }
    }

    // MARK: Two files

    /// The title page of `views-font` with the picture of `views-picture`
    /// under its two titles: a face and a picture to wait for.
    static func bothFiles() throws -> NuxieMachinePlanSource {
        let main = try FontFolder.main()
        let line = FontFolder.phonesLine
        guard main.components(separatedBy: line).count == 2 else { throw FontFolder.NoPhoneLine() }
        let picture = "      image \"assets/hero.png\" width=200 height=200 fit=fill\n"
        return try FontFolder.plan(main: main.replacingOccurrences(of: line, with: line + picture),
                                   assets: FontFolder.rows() + PictureFolder.rows())
    }

    /// The bytes of the picture from its folder, and of the face from its.
    static func readEitherFolder(_ path: String) async throws -> Data {
        let folder = path == hero ? try PictureFolder.url() : try FontFolder.url()
        return try await NuxieMachineFolderByteSource(folder: folder).bytes(for: path)
    }
}

extension CounterOwner {
    /// Each `assets` row the owner was told, in order.
    var assetsTold: [NuxieMachineAssets] {
        reports.flatMap { report -> [NuxieMachineAssets] in
            guard case .delivered(_, let rows) = report else { return [] }
            return rows.compactMap { row -> NuxieMachineAssets? in
                guard case .assets(let now) = row else { return nil }
                return now
            }
        }
    }
}

/// Returns once the edge has asked for a frame since the last take, or
/// fails the test after ten seconds.
func waitForAsk(_ asks: FrameAskCount, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !asks.take() {
        guard Date() < deadline else { return XCTFail("the edge asked for no frame", file: file, line: line) }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
#endif
