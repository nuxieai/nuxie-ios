#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import NuxieRuntime
@_spi(Testing) @testable import Nuxie

/// Real native records from the throwaway exporter, not a publisher qualification.
@MainActor
final class ExperiencePageLiveMovesTests: XCTestCase {
    func testSecondT1ArrivalAfterCutBackToKeptBCompletesBeforeWatchdog() async throws {
        try await assertRepeatedArrivalAfterCutBack(keepingB: true)
    }

    func testSecondT1ArrivalAfterCutBackRemovingBCompletesBeforeWatchdog() async throws {
        try await assertRepeatedArrivalAfterCutBack(keepingB: false)
    }

    private func assertRepeatedArrivalAfterCutBack(keepingB: Bool) async throws {
        try await withLiveMovePage { page in
            let first = try await move(page, "A", "B", "t1")
            let originalB = try await page.snapshot(screenID: "B").rootInstanceID
            XCTAssertEqual(first.completionEvents.map(\.name), ["nx_enter_done:t1"], "First arrival")
            XCTAssertEqual(first.completionEvents.compactMap(\.sourceViewModelInstanceID), [originalB])
            XCTAssertEqual(first.completionWaitCount, 1)
            XCTAssertFalse(first.watchdogExpired, "The first together step must finish on B's arrival")
            XCTAssertFalse(first.endedWithoutCompletions)
            _ = try XCTUnwrap(first.completionEvents.first, "First arrival must succeed before testing the revisit")

            let cut = try await move(page, "B", "A", nil,
                reachable: keepingB ? ["A", "B"] : ["A"], isBack: true)
            XCTAssertEqual(cut.advanceCount, 1, "Route (a): the cut settles the woken row with one zero-time step")
            XCTAssertEqual(cut.completionWaitCount, 0)
            await assertRows(page, keepingB ? ["A", "B"] : ["A"], collapsed: keepingB ? ["B"] : [])
            let removed = await page.isRowRemoved(screenID: "B")
            XCTAssertEqual(removed, !keepingB)
            let retainedB = try await page.snapshot(screenID: "B")
            XCTAssertEqual(retainedB.rootInstanceID, originalB, "The cut retains B or its frozen seed")

            let second = try await move(page, "A", "B", "t1")
            let revisitedB = try await page.snapshot(screenID: "B").rootInstanceID
            if keepingB { XCTAssertEqual(revisitedB, originalB) }
            else { XCTAssertNotEqual(revisitedB, originalB, "The removed B must be rebuilt from its seed") }
            XCTAssertEqual(second.completionEvents.map(\.name), ["nx_enter_done:t1"], "Second arrival after cut")
            XCTAssertEqual(second.completionEvents.compactMap(\.sourceViewModelInstanceID), [revisitedB])
            XCTAssertEqual(second.completionWaitCount, 1)
            XCTAssertFalse(second.watchdogExpired, "The second together step must finish on B's new arrival")
            XCTAssertFalse(second.endedWithoutCompletions, "step_end must follow the second arrival event")
            await assertRows(page, ["A", "B"], collapsed: ["A"])
        }
    }

    func testForwardCutSecondForwardAndBackKeepTheInstanceAndRemoveOnlyAfterLanding() async throws {
        try await withLiveMovePage(preload: true) { page in
            let identity = try await page.snapshot(screenID: "A").rootInstanceID
            try await move(page, "A", "B", "t1")
            await assertRows(page, ["A", "B"], collapsed: ["A"])
            try await move(page, "B", "A", nil)
            await assertRows(page, ["B", "A"], collapsed: ["B"])
            let kept = try await page.snapshot(screenID: "A").rootInstanceID
            XCTAssertEqual(kept, identity)
            try await move(page, "A", "B", "t1")
            try await move(page, "B", "A", "back", reachable: ["A"])
            await assertRows(page, ["A"], collapsed: [])
            let landed = try await page.snapshot(screenID: "A").rootInstanceID
            XCTAssertEqual(landed, identity)
            _ = try await page.step(elapsedSeconds: 1 / 60)
        }
    }

    func testForwardThenBackRemovalAllowsTheNextOrdinaryStep() async throws {
        try await withLiveMovePage { page in
            try await move(page, "A", "B", "t1")
            try await move(page, "B", "A", "back", reachable: ["A"])
            await assertRows(page, ["A"], collapsed: [])
            _ = try await page.step(elapsedSeconds: 1 / 60)
            await assertRows(page, ["A"], collapsed: [])
        }
    }

    func testCancelledBackCutRebuildsRemovedSourceFromItsFrozenSnapshot() async throws {
        try await withLiveMovePage { page in
            try await move(page, "A", "B", "t1")
            // Compare two rebuilt generations: their seeded child handles are
            // intentionally retained, unlike a fresh schema-default graph.
            try await move(page, "B", "A", "back", reachable: ["A"])
            try await move(page, "A", "B", "t1")
            let before = try await page.snapshot(screenID: "B")
            let old = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: before.rootInstanceID))
            _ = try await page.runtime.mutateViewModel([.setNumber(instance: old, path: "offset", value: 42)])
            let steadyCount = try await page.runtime.retainedViewModelCount
            do {
                try await backCut(page, "B", "A", reachable: ["A"], cancelAfterRetirement: true)
                XCTFail("The cut must cancel after removing its source")
            } catch is CancellationError {}
            await assertRows(page, ["A"], collapsed: [])
            let removed = await page.isRowRemoved(screenID: "B")
            XCTAssertTrue(removed)
            let frozen = try await page.snapshot(screenID: "B")
            XCTAssertEqual(frozen.rootInstanceID, old.rawValue)
            await page.runtime.recordRowWrites()

            try await page.restoreCancelledStep(source: "B", target: "A", reachable: ["A", "B"], reduceMotion: false)
            await assertRows(page, ["B", "A"], collapsed: ["A"])
            let rebuilt = try await page.snapshot(screenID: "B")
            XCTAssertNotEqual(rebuilt.rootInstanceID, old.rawValue)
            XCTAssertEqual(rebuilt.values.first {
                $0.ownerInstanceID == rebuilt.rootInstanceID && $0.name == "offset"
            }?.value, .number(42))
            let stillRemoved = await page.isRowRemoved(screenID: "B")
            XCTAssertFalse(stillRemoved)
            let snapshotIDs = await page.runtime.removedRowSnapshotIDs
            XCTAssertTrue(snapshotIDs.isDisjoint(with: frozen.rowOwnedInstanceIDs))
            do {
                _ = try await page.runtime.mutateViewModel([.setNumber(instance: old, path: "offset", value: 999)])
                XCTFail("Rollback must not revive the removed generation's write authority")
            } catch NuxieNativeRuntimeError.invalidNativeValue(let message) {
                XCTAssertEqual(message, "R6b: removed page row")
            }
            let writes = await page.runtime.rowWriteLog
            XCTAssertTrue(Set(writes).isDisjoint(with: frozen.rowOwnedInstanceIDs))
            let restoredCount = try await page.runtime.retainedViewModelCount
            XCTAssertEqual(restoredCount, steadyCount, "Rollback must replace, not leak, the removed row's handles")
        }
    }

    func testCancelledSkippingBackKeepsMiddleSnapshotForTheNextBack() async throws {
        // page2 has only A/B. The same fixture family supplies R2 as C in page40;
        // leave its other 37 Screens unprepared and unmounted.
        try await withLiveMovePage(count: 40) { page in
            let c = liveMoveScreen(2)
            let history: Set<String> = ["A", "B", c]
            try await move(page, "A", "B", nil, reachable: history)
            let originalB = try await page.snapshot(screenID: "B")
            let b = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: originalB.rootInstanceID))
            _ = try await page.runtime.mutateViewModel([.setNumber(instance: b, path: "offset", value: 73)])
            try await move(page, "B", c, nil, reachable: history)
            let originalC = try await page.snapshot(screenID: c)
            await assertRows(page, ["A", "B", c], collapsed: ["A", "B"])
            do {
                try await backCut(page, c, "A", reachable: ["A"], cancelAfterRetirement: true)
                XCTFail("The skipping cut must cancel after retiring B and C")
            } catch is CancellationError {}
            await assertRows(page, ["A"], collapsed: [])
            let removedB = await page.isRowRemoved(screenID: "B")
            let removedC = await page.isRowRemoved(screenID: c)
            XCTAssertTrue(removedB)
            XCTAssertTrue(removedC)
            let frozenB = try await page.snapshot(screenID: "B")

            try await page.restoreCancelledStep(source: c, target: "A", reachable: history, reduceMotion: false)
            await assertRows(page, [c, "A"], collapsed: ["A"])
            let rebuiltC = try await page.snapshot(screenID: c)
            XCTAssertNotEqual(rebuiltC.rootInstanceID, originalC.rootInstanceID)
            let cStillRemoved = await page.isRowRemoved(screenID: c)
            XCTAssertFalse(cStillRemoved)
            let bStillRemoved = await page.isRowRemoved(screenID: "B")
            XCTAssertTrue(bStillRemoved)
            let retainedB = try await page.snapshot(screenID: "B")
            XCTAssertEqual(retainedB, frozenB)
            let retainedSnapshots = await page.runtime.removedRowSnapshotIDs
            XCTAssertTrue(frozenB.rowOwnedInstanceIDs.isSubset(of: retainedSnapshots))

            var inspectedIncoming = false
            try await backCut(page, c, "B", reachable: ["A", "B"], onIncoming: {
                // Inspect before retirement removes C, so R3's relative order is visible.
                await assertRows(page, ["B", c, "A"], collapsed: ["A"])
                inspectedIncoming = true
            })
            XCTAssertTrue(inspectedIncoming)
            await assertRows(page, ["B", "A"], collapsed: ["A"])
            let rebuiltB = try await page.snapshot(screenID: "B")
            XCTAssertNotEqual(rebuiltB.rootInstanceID, originalB.rootInstanceID)
            XCTAssertEqual(rebuiltB.values.first {
                $0.ownerInstanceID == rebuiltB.rootInstanceID && $0.name == "offset"
            }?.value, .number(73))
            let bRemovedAfterBack = await page.isRowRemoved(screenID: "B")
            XCTAssertFalse(bRemovedAfterBack)
        }
    }

    func testRepeatedBackRevisitsKeepNativeHandleCountBounded() async throws {
        try await withLiveMovePage { page in
            var baseline: Int?
            for _ in 0..<5 {
                try await move(page, "A", "B", "t1")
                let row = try await page.snapshot(screenID: "B")
                let children = row.rowOwnedInstanceIDs.subtracting([row.rootInstanceID])
                XCTAssertFalse(children.isEmpty, "B owns its nested ScreenLifecycle model")
                if baseline != nil {
                    for id in children {
                        let reference = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: id))
                        let retained = try await page.runtime.retainsViewModel(reference)
                        XCTAssertTrue(retained, "Seeded children must remain retained while the row can write them")
                    }
                }
                try await move(page, "B", "A", "back", reachable: ["A"])
                let count = try await page.runtime.retainedViewModelCount
                if let baseline { XCTAssertEqual(count, baseline) }
                else { baseline = count }
                // Every seeded lifecycle child must be released with this generation.
                for id in children {
                    let reference = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: id))
                    let retained = try await page.runtime.retainsViewModel(reference)
                    XCTAssertFalse(retained, "A removed generation must release its child handle")
                }
            }
        }
    }

    func testBindingAllocationIsReleasedWithItsRowRoot() async throws {
        try await withLiveMovePage { page in
            let baseline = try await page.runtime.retainedViewModelCount
            let binding = try await page.prepareRow(screenID: "B", products: [])
            let schema = try await page.runtime.defaultSchema(artboardName: "B")
            let beforeChild = try await page.runtime.retainedViewModelCount
            let allocated = try await binding.makeViewModel(schemaIndex: schema)
            let child = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: allocated.rawValue))
            let afterChild = try await page.runtime.retainedViewModelCount
            XCTAssertEqual(afterChild, beforeChild + 1)
            try await page.insert(screenID: "B", at: 1)
            _ = try await page.step(elapsedSeconds: 0)
            try await page.remove(screenID: "B")
            let retained = try await page.runtime.retainsViewModel(child)
            XCTAssertFalse(retained)
            let finalCount = try await page.runtime.retainedViewModelCount
            XCTAssertEqual(finalCount, baseline)
        }
    }

    func testRemovedRowIsFrozenAndRevisitSeedsANewAppendedInstance() async throws {
        try await withLiveMovePage { page in
            try await move(page, "A", "B", "t1")
            let binding = try await page.binding(screenID: "B")
            let before = try await page.snapshot(screenID: "B")
            let old = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: before.rootInstanceID))
            _ = try await page.runtime.mutateViewModel([.setNumber(instance: old, path: "offset", value: 42)])
            try await move(page, "B", "A", "back", reachable: ["A"])
            let frozen = try await page.snapshot(screenID: "B")
            await page.runtime.recordRowWrites()
            try await page.updateEnvironment(reduceMotion: true, fontScale: 1.5)
            // A real late continuation must drain the page without restoring or firing
            // even an invalid trigger on the removed binding.
            let late = try await binding.confirmResponseSave(trigger: "must-not-fire", kept: [.init(path: "offset", kind: NuxieNativeViewModelPropertyKind.number.rawValue, value: .number(999))])
            XCTAssertNotNil(late.pageStep)
            let stillFrozen = try await page.snapshot(screenID: "B")
            XCTAssertEqual(stillFrozen, frozen)
            try await move(page, "A", "B", "t1")
            let revisited = try await page.snapshot(screenID: "B")
            XCTAssertNotEqual(revisited.rootInstanceID, before.rootInstanceID)
            XCTAssertEqual(revisited.values.first { $0.ownerInstanceID == revisited.rootInstanceID && $0.name == "offset" }?.value, .number(42))
            await assertRows(page, ["A", "B"], collapsed: ["A"])
            // The old binding must stay frozen even after a new B exists.
            _ = try await binding.confirmResponseSave(trigger: "must-not-fire", kept: [.init(path: "offset", kind: NuxieNativeViewModelPropertyKind.number.rawValue, value: .number(999))])
            try await page.close()
            let writes = await page.runtime.rowWriteLog
            XCTAssertTrue(Set(writes).isDisjoint(with: frozen.rowOwnedInstanceIDs),
                "No value, lifecycle, environment, save, seed or teardown write may target the removed graph")
        }
    }

    func testRevisitEndsRemovedGenerationAndOldJournalIsUnattributed() async throws {
        try await withLiveMovePage { page in
            try await move(page, "A", "B", "t1")
            let before = try await page.snapshot(screenID: "B")
            let old = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: before.rootInstanceID))
            try await move(page, "B", "A", "back", reachable: ["A"])
            let retainedAfterRemoval = try await page.runtime.retainsViewModel(old)
            XCTAssertFalse(retainedAfterRemoval)
            try await move(page, "A", "B", "t1")
            let fresh = try await page.snapshot(screenID: "B")
            XCTAssertNotEqual(fresh.rootInstanceID, old.rawValue)
            let retainedAfterRevisit = try await page.runtime.retainsViewModel(old)
            XCTAssertFalse(retainedAfterRevisit)
            let snapshotIDs = await page.runtime.removedRowSnapshotIDs
            XCTAssertTrue(snapshotIDs.isDisjoint(with: before.rowOwnedInstanceIDs))
            let event = NuxieNativeEvent(localIndex: 0, coreType: 128, name: "nx_enter_done:late",
                url: "", target: "", delay: 0, properties: [], sourceViewModelInstanceID: old.rawValue)
            let native = NuxieNativePlayerStepResult(keepGoing: false, pointerHits: [], stateChanges: [],
                events: [event], hostCommands: [], viewModelChanges: [])
            let live = try await page.runtime.snapshot()
            let delivered = try await page.projectCapturedStep(native, snapshot: live)
            XCTAssertEqual(delivered.unattributedEvents, [event])
            XCTAssertFalse(delivered.rows["B"]?.effects.contains {
                if case .reportedEvent(let event) = $0.kind { return event.name == "nx_enter_done:late" }
                return false
            } ?? false)
            do {
                _ = try await page.runtime.mutateViewModel([.setNumber(instance: old, path: "offset", value: 999)])
                XCTFail("A superseded generation must remain write-protected after its snapshot is dropped")
            } catch NuxieNativeRuntimeError.invalidNativeValue(let message) {
                XCTAssertEqual(message, "R6b: removed page row")
            }
        }
    }

    func testRepeatedRevisitsKeepOnlyCurrentRowsAndRemovedSnapshots() async throws {
        try await withLiveMovePage { page in
            var previousRemovedIDs: Set<UInt64> = []
            for _ in 0..<5 {
                try await move(page, "A", "B", "t1")
                let liveSnapshotIDs = await page.runtime.removedRowSnapshotIDs
                XCTAssertTrue(liveSnapshotIDs.isEmpty)
                try await move(page, "B", "A", "back", reachable: ["A"])
                let ids = await page.retainedScreenIDs
                XCTAssertEqual(ids, ["A", "B"])
                let removed = try await page.snapshot(screenID: "B")
                let snapshotIDs = await page.runtime.removedRowSnapshotIDs
                XCTAssertEqual(snapshotIDs, removed.rowOwnedInstanceIDs)
                XCTAssertTrue(snapshotIDs.isDisjoint(with: previousRemovedIDs))
                previousRemovedIDs.formUnion(snapshotIDs)
                let old = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: removed.rootInstanceID))
                let retained = try await page.runtime.retainsViewModel(old)
                XCTAssertFalse(retained)
                let step = try await page.step(elapsedSeconds: 0)
                XCTAssertEqual(Set(step.rows.keys), ["A", "B"])
                await assertRows(page, ["A"], collapsed: [])
            }
        }
    }

    func testRemovalWithWaitersRefusesWithoutChangingMembership() async throws {
        try await withLiveMovePage { page in
            try await move(page, "A", "B", "t1")
            let before = try await page.snapshot(screenID: "B")
            let reference = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: before.rootInstanceID))
            let waiter = try await page.registerCompletion(screenID: "B", eventName: "never-arrives")
            do {
                try await page.remove(screenID: "B")
                XCTFail("Removal must refuse an outstanding completion")
            } catch ExperienceInteractiveScreenError.stateContract(let message) {
                XCTAssertEqual(message, "Screen still awaits completion")
            }
            await assertRows(page, ["A", "B"], collapsed: ["A"])
            let removed = await page.isRowRemoved(screenID: "B")
            XCTAssertFalse(removed)
            let retained = try await page.runtime.retainsViewModel(reference)
            XCTAssertTrue(retained)
            let snapshotIDs = await page.runtime.removedRowSnapshotIDs
            XCTAssertTrue(snapshotIDs.isEmpty)
            let after = try await page.snapshot(screenID: "B")
            XCTAssertEqual(after, before)
            await page.removeCompletion(screenID: "B", id: waiter.id)
            try await page.remove(screenID: "B")
            let released = try await page.runtime.retainsViewModel(reference)
            XCTAssertFalse(released)
        }
    }

    func testNativeListRemovalAfterLandingAllowsTheNextOrdinaryStep() async throws {
        try await withLiveMovePage { page in
            try await move(page, "A", "B", "t1")
            try await move(page, "B", "A", "back", retire: false)
            await assertRows(page, ["A", "B"], collapsed: [])
            let root = try await page.runtime.rootViewModelReference()
            _ = try await page.runtime.mutateViewModel([.listRemove(instance: root, path: "screens", index: 1)])
            _ = try await page.runtime.step(elapsedSeconds: 1 / 60)
        }
    }

    func testFreshlyAppendedIncomingRowBeginsAfterMountStepWithoutDrawingBetween() async throws {
        try await withLiveMovePage { page in
            _ = try await page.prepareRow(screenID: "B", products: [])
            try await page.apply([.take, .position(isBack: false), .expand,
                .phases([("A", .exiting), ("B", .entering)], "t1"), .begin("t1"), .end("t1")],
                source: "A", target: "B", reachable: ["A", "B"], reduceMotion: false)
            await assertRows(page, ["A", "B"], collapsed: [])
        }
    }

    func testFortyRowsWithThirtyNineCollapsedStepWithoutError() async throws {
        try await withLiveMovePage(count: 40, preload: true) { page in
            let ids = (0..<40).map(liveMoveScreen)
            await assertRows(page, ids, collapsed: Set(ids.dropFirst()))
            for _ in 0..<60 { _ = try await page.step(elapsedSeconds: 1 / 60) }
            try await move(page, "A", "B", "t1", reachable: Set(ids))
            await assertRows(page, ids, collapsed: Set(ids).subtracting(["B"]))
        }
    }

    func testKeptARisesAboveBThenBackMovesItBelowWithoutChangingInstance() async throws {
        try await withLiveMovePage { page in
            let identity = try await page.snapshot(screenID: "A").rootInstanceID
            try await move(page, "A", "B", "t1")
            try await move(page, "B", "A", nil)
            await assertRows(page, ["B", "A"], collapsed: ["B"])
            let expanded = try await page.snapshot(screenID: "A").rootInstanceID
            XCTAssertEqual(expanded, identity)
            // Reveal B as the outgoing history entry while retained A still sits above it.
            try await page.insert(screenID: "B", at: 0)
            try await page.setPhases([("A", .hidden), ("B", .active)])
            try await page.apply([.retire], source: "A", target: "B", reachable: ["A", "B"], reduceMotion: false)
            try await page.apply([.take, .position(isBack: true), .expand,
                .phases([("B", .exiting), ("A", .entering)], "back"), .begin("back"), .end("back"), .retire],
                source: "B", target: "A", reachable: ["A", "B"], reduceMotion: false)
            await assertRows(page, ["A", "B"], collapsed: ["B"])
            let returned = try await page.snapshot(screenID: "A").rootInstanceID
            XCTAssertEqual(returned, identity)
        }
    }
}

func liveMoveScreen(_ index: Int) -> String { index == 0 ? "A" : (index == 1 ? "B" : "R\(index)") }

private func liveMoveFixture(_ name: String) throws -> Data {
    let bundle = Bundle(for: ExperiencePageLiveMovesTests.self)
    for directory in ["runtime/page-host-live-moves", "page-host-live-moves"] {
        if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: directory) {
            return try Data(contentsOf: url)
        }
    }
    return try Data(contentsOf: experiencePreparationRepositoryRoot()
        .appendingPathComponent("fixtures/runtime/page-host-live-moves/\(name)"))
}

@MainActor
func withLiveMovePage(count: Int = 2, preload: Bool = false, initialA: Bool = true,
                      _ body: (ExperienceInteractivePage) async throws -> Void) async throws {
    let bytes = try liveMoveFixture("page\(count).riv")
    let names = (0..<count).map(liveMoveScreen)
    let plan = NativeExperienceRenderPlan(identity: .init(experienceId: "live", buildId: "live", appId: "test", environment: "test"),
        scene: .init(key: "scene.nux", sha256: SHA256Provider.hexDigest(bytes), sizeBytes: bytes.count),
        entry: .init(screenId: "A"), pageHost: .init(artboardName: "Page", listPath: "screens",
            machineName: "run", modelName: "Page", hasLiveMoves: true, initialRows: .clearBeforePlayer),
        screens: names.map { .init(screenId: $0, artboardId: $0, artboardName: $0, width: 800, height: 600, exit: nil) },
        transitions: [], textInputs: [], images: [], fonts: [])
    let payload = AuthenticatedRuntimePayload(authenticatedKeyID: "test", renderPlan: plan,
        journey: JourneyDocument(screens: names.map { .init(id: $0) }), sceneBytes: bytes, assets: [])
    let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: bytes)
    let prepared = try await NuxieNativePreparedFile.prepare(bytes: bytes,
        importMode: .configured(moduleName: "nuxie", expectedAssets: catalog, externalAssets: [:], videoEnabled: true))
    let page = try await ExperienceInteractivePage.open(payload: payload, preparedFile: prepared,
        runValues: nil, imageIDsByName: [:], pixelWidth: 800, pixelHeight: 600, reduceMotion: false,
        safeArea: nil, colorScheme: nil)
    do {
        let empty = await page.mountedScreenIDs
        XCTAssertTrue(empty.isEmpty)
        if initialA {
            try await page.insertIncoming(screenID: "A", style: .none, isBack: false)
            try await page.setPhases([("A", .entering)])
            if preload {
                for name in names.dropFirst() { try await page.insertIncoming(screenID: name, style: .none, isBack: false) }
            }
            _ = try await page.step(elapsedSeconds: 0)
            if preload { try await page.apply([.retire], source: "A", target: "A", reachable: Set(names), reduceMotion: false) }
            try await page.setPhases([("A", .active)])
        }
        try await body(page)
        try await page.close()
    } catch { try? await page.close(); throw error }
}

@MainActor
private func assertRows(_ page: ExperienceInteractivePage, _ expected: [String], collapsed: Set<String>,
                        file: StaticString = #filePath, line: UInt = #line) async {
    let order = await page.mountedScreenIDs
    let sleeping = await page.collapsedScreenIDs
    XCTAssertEqual(order, expected, file: file, line: line)
    XCTAssertEqual(sleeping, collapsed, file: file, line: line)
    do {
        let snapshot = try await page.runtime.snapshot()
        var identities: [UInt64] = []
        for id in expected { identities.append(try await page.snapshot(screenID: id).rootInstanceID) }
        let list = snapshot.values.first { $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "screens" }
        XCTAssertEqual(list?.value, .list(identities), "Native list must match actor order", file: file, line: line)
    } catch { XCTFail("Cannot inspect native row order: \(error)", file: file, line: line) }
}

/// Exercise the ordinary unnamed Back cut, with an optional failure at the
/// same post-retirement boundary that the controller's catch must roll back.
@MainActor
private func backCut(_ page: ExperienceInteractivePage, _ source: String, _ target: String,
                     reachable: Set<String>, cancelAfterRetirement: Bool = false,
                     onIncoming: (() async throws -> Void)? = nil) async throws {
    try await ExperiencePageStep.perform(source: source, target: target, style: .none,
        isBack: true, plan: nil, exit: .init(declaration: nil, reduceMotion: false), reduceMotion: false,
        operations: .init(setInputEnabled: { _ in }, prepare: {
            _ = try await page.prepareRow(screenID: target, products: [])
        }, register: { _, _ in
            XCTFail("An unnamed cut without exit metadata must not register completions")
            return AsyncStream { $0.finish() }
        }, batch: { changes in
            for change in changes {
                _ = try await page.apply([change], source: source, target: target,
                    reachable: reachable, reduceMotion: false)
                if change == .expand { try await onIncoming?() }
                if change == .retire && cancelAfterRetirement { throw CancellationError() }
            }
        }, present: { _ = try await page.step(elapsedSeconds: 0) }, wait: { _, _ in },
        release: {}, hidden: {}, active: { try await page.selectActiveRow(target) },
        drain: { _ = try await page.step(elapsedSeconds: 0) }))
}

private struct LiveMoveObservation {
    let completionEvents: [NuxieNativeEvent]
    let completionWaitCount: Int
    let watchdogExpired: Bool
    let endedWithoutCompletions: Bool
    let advanceCount: Int
}

@discardableResult
@MainActor
private func move(_ page: ExperienceInteractivePage, _ source: String, _ target: String, _ transition: String?,
                  reachable: Set<String> = ["A", "B"], retire: Bool = true,
                  isBack: Bool = false) async throws -> LiveMoveObservation {
    struct Lifecycle: Decodable {
        struct Step: Decodable {
            struct Side: Decodable { let completeEventName: String? }
            let durationMs: UInt64
            let incoming: Side
            let outgoing: Side
        }
        let steps: [String: Step]
    }
    let lifecycle = try JSONDecoder().decode(Lifecycle.self, from: liveMoveFixture("lifecycle2.json"))
    let plan: ExperienceScreenCustomTransitionPlan?
    if let transition {
        let step = try XCTUnwrap(lifecycle.steps[transition])
        plan = .init(transitionId: transition, durationMilliseconds: step.durationMs, incomingOnTop: true,
            outgoingCompletionEventName: step.outgoing.completeEventName ?? "",
            incomingCompletionEventName: try XCTUnwrap(step.incoming.completeEventName))
    } else { plan = nil }
    var inputEnabled = true
    var waiters: [(String, UUID)] = []
    var required: Set<String> = []
    var seen: Set<String> = []
    var eventOwners: [String: UInt64] = [:]
    var completionEvents: [NuxieNativeEvent] = []
    var completionWaitCount = 0
    var watchdogExpired = false
    var endedWithoutCompletions = false
    var advanceCount = 0
    func observe(_ frame: ExperienceInteractivePage.Step) {
        advanceCount += 1
        for event in frame.native.events where eventOwners[event.name] == event.sourceViewModelInstanceID {
            if required.contains(event.name) {
                completionEvents.append(event)
                seen.insert(event.name)
            }
        }
    }
    var waitError: Error?
    do {
        try await ExperiencePageStep.perform(source: source, target: target, style: transition == nil ? .none : .magicMove,
            isBack: isBack || transition == "back", plan: plan, exit: .init(declaration: nil, reduceMotion: false), reduceMotion: false,
            operations: .init(setInputEnabled: { inputEnabled = $0 }, prepare: {
                _ = try await page.prepareRow(screenID: target, products: [])
            }, register: { id, event in
                if event.isEmpty { return AsyncStream { $0.yield(()); $0.finish() } }
                required.insert(event)
                eventOwners[event] = try await page.snapshot(screenID: id).rootInstanceID
                let waiter = try await page.registerCompletion(screenID: id, eventName: event)
                waiters.append((id, waiter.id))
                return waiter.events
            }, batch: { changes in
                for change in changes {
                    if case .end = change {
                        endedWithoutCompletions = !required.isSubset(of: seen)
                        if transition != nil {
                            let mounted = await page.mountedScreenIDs
                            XCTAssertTrue(mounted.contains(source), "Together steps retain the outgoing row until landing")
                        }
                    }
                    if change == .retire && !retire { continue }
                    let frame = try await page.apply([change], source: source, target: target,
                        reachable: reachable, reduceMotion: false)
                    if let frame { observe(frame) }
                }
            }, present: {
                let frame = try await page.step(elapsedSeconds: 0)
                observe(frame)
            }, wait: { _, milliseconds in
                completionWaitCount += 1
                do {
                    for _ in 0..<Int(milliseconds * 60 / 1000) {
                        XCTAssertFalse(inputEnabled)
                        let frame = try await page.step(elapsedSeconds: 1 / 60)
                        observe(frame)
                        if required.isSubset(of: seen) { return }
                    }
                    watchdogExpired = true
                    XCTFail("Published completion event did not arrive for \(transition ?? "cut")")
                } catch { waitError = error }
            }, release: {
                for (id, token) in waiters { await page.removeCompletion(screenID: id, id: token) }
                waiters.removeAll()
            }, hidden: {}, active: { try await page.selectActiveRow(target) }))
        if let waitError { throw waitError }
        XCTAssertTrue(inputEnabled)
        for (id, token) in waiters { await page.removeCompletion(screenID: id, id: token) }
        return LiveMoveObservation(completionEvents: completionEvents, completionWaitCount: completionWaitCount,
            watchdogExpired: watchdogExpired, endedWithoutCompletions: endedWithoutCompletions,
            advanceCount: advanceCount)
    } catch {
        for (id, token) in waiters { await page.removeCompletion(screenID: id, id: token) }
        throw error
    }
}
#endif
