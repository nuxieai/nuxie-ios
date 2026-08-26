import XCTest
@testable import Nuxie

private final class LifecycleTestGraph: @unchecked Sendable {
    let id: Int

    init(id: Int) {
        self.id = id
    }
}

private actor LifecycleTeardownProbe {
    private var calls: [Int] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func tearDown(_ graph: LifecycleTestGraph) async {
        calls.append(graph.id)
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard calls.isEmpty else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func recordedCalls() -> [Int] {
        calls
    }
}

private actor LifecycleBarrier {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

final class SerializedSDKLifecycleTests: XCTestCase {
    func testConcurrentInstallBuildsAndPublishesExactlyOneGraph() async {
        let lifecycle = SerializedSDKLifecycle<LifecycleTestGraph>()
        let buildStarted = expectation(description: "first graph construction started")
        let releaseBuild = DispatchSemaphore(value: 0)
        let buildCountLock = NSLock()
        var buildCount = 0

        let firstInstall = Task.detached {
            lifecycle.install {
                buildCountLock.withLock { buildCount += 1 }
                buildStarted.fulfill()
                releaseBuild.wait()
                return LifecycleTestGraph(id: 1)
            }
        }

        await fulfillment(of: [buildStarted])

        let operationChecked = expectation(
            description: "operation admission was checked while setup was starting"
        )
        let operationDuringStart = Task.detached {
            let operation = lifecycle.beginOperation()
            operationChecked.fulfill()
            return operation
        }
        await fulfillment(of: [operationChecked], timeout: 0.25)
        let admittedOperation = await operationDuringStart.value
        XCTAssertNil(admittedOperation)

        let secondInstall = Task.detached {
            lifecycle.install {
                buildCountLock.withLock { buildCount += 1 }
                return LifecycleTestGraph(id: 2)
            }
        }

        releaseBuild.signal()

        let installed = await [firstInstall.value, secondInstall.value]
        XCTAssertEqual(installed.filter { $0 }.count, 1)
        XCTAssertEqual(buildCountLock.withLock { buildCount }, 1)
        XCTAssertEqual(lifecycle.snapshot()?.graph.id, 1)
    }

    func testConcurrentShutdownJoinsOneTeardownAndSetupCannotReplaceItsGraph() async {
        let lifecycle = SerializedSDKLifecycle<LifecycleTestGraph>()
        let probe = LifecycleTeardownProbe()
        XCTAssertTrue(lifecycle.install { LifecycleTestGraph(id: 1) })

        let firstShutdown = Task {
            await lifecycle.shutdown { graph in
                await probe.tearDown(graph)
            }
        }
        await probe.waitUntilStarted()

        let secondShutdown = Task {
            await lifecycle.shutdown { graph in
                await probe.tearDown(graph)
            }
        }

        XCTAssertFalse(lifecycle.install { LifecycleTestGraph(id: 2) })
        XCTAssertFalse(lifecycle.isRunning)

        await probe.release()
        await firstShutdown.value
        await secondShutdown.value

        let teardownCalls = await probe.recordedCalls()
        XCTAssertEqual(teardownCalls, [1])
        XCTAssertTrue(lifecycle.install { LifecycleTestGraph(id: 2) })
        XCTAssertEqual(lifecycle.snapshot()?.graph.id, 2)
    }

    func testShutdownDuringStartingWaitsForPublicationThenStopsThatGraph() async {
        let lifecycle = SerializedSDKLifecycle<LifecycleTestGraph>()
        let probe = LifecycleTeardownProbe()
        let postStartBarrier = LifecycleBarrier()
        let buildStarted = expectation(description: "graph construction started")
        let releaseBuild = DispatchSemaphore(value: 0)

        let setup = Task.detached {
            lifecycle.install {
                buildStarted.fulfill()
                releaseBuild.wait()
                return LifecycleTestGraph(id: 1)
            }
        }
        await fulfillment(of: [buildStarted])

        let shutdown = Task {
            await lifecycle.shutdown(afterWaitingForStart: {
                await postStartBarrier.pause()
            }) { graph in
                await probe.tearDown(graph)
            }
        }
        XCTAssertFalse(lifecycle.isRunning)

        releaseBuild.signal()
        await postStartBarrier.waitUntilEntered()
        XCTAssertFalse(lifecycle.isRunning)
        XCTAssertNil(
            lifecycle.beginOperation(),
            "a pending stop must close admission in the publication transition"
        )
        await postStartBarrier.release()
        await probe.waitUntilStarted()
        XCTAssertFalse(lifecycle.isRunning)

        await probe.release()
        let installed = await setup.value
        XCTAssertTrue(installed)
        await shutdown.value

        let teardownCalls = await probe.recordedCalls()
        XCTAssertEqual(teardownCalls, [1])
        XCTAssertFalse(lifecycle.isRunning)
    }

    func testShutdownRejectsNewOperationsAndWaitsForAdmittedOperation() async throws {
        let lifecycle = SerializedSDKLifecycle<LifecycleTestGraph>()
        let probe = LifecycleTeardownProbe()
        let admissionClosed = expectation(description: "operation admission closed")
        XCTAssertTrue(lifecycle.install { LifecycleTestGraph(id: 1) })
        let operation = try XCTUnwrap(lifecycle.beginOperation())

        let shutdown = Task {
            await lifecycle.shutdown(beforeDraining: { _ in
                admissionClosed.fulfill()
            }) { graph in
                await probe.tearDown(graph)
            }
        }
        await fulfillment(of: [admissionClosed])

        XCTAssertNil(lifecycle.beginOperation())
        let teardownCallsBeforeRelease = await probe.recordedCalls()
        XCTAssertTrue(teardownCallsBeforeRelease.isEmpty)

        operation.finish()
        await probe.waitUntilStarted()
        await probe.release()
        await shutdown.value

        let teardownCalls = await probe.recordedCalls()
        XCTAssertEqual(teardownCalls, [1])
    }
}
extension SerializedSDKLifecycleTests {
    func testDuplicateInstallAfterRunningReturnsFalseWithoutCrashing() throws {
        let lifecycle = SerializedSDKLifecycle<LifecycleTestGraph>()
        XCTAssertTrue(lifecycle.install { LifecycleTestGraph(id: 1) })
        // The immediate-false path must not construct a consumed semaphore
        // (libdispatch aborts on deallocation with current < original).
        for _ in 0..<3 {
            XCTAssertFalse(lifecycle.install { LifecycleTestGraph(id: 2) })
        }
        XCTAssertNotNil(lifecycle.snapshot())
    }

    func testLosingConcurrentInstallBlocksUntilPublication() throws {
        let lifecycle = SerializedSDKLifecycle<LifecycleTestGraph>()
        let buildEntered = DispatchSemaphore(value: 0)
        let releaseBuild = DispatchSemaphore(value: 0)
        let loserDone = DispatchSemaphore(value: 0)
        let winner = Thread {
            _ = lifecycle.install {
                buildEntered.signal()
                releaseBuild.wait()
                return LifecycleTestGraph(id: 1)
            }
        }
        winner.start()
        buildEntered.wait()

        var loserObservedGraph = false
        let loser = Thread {
            let owns = lifecycle.install { LifecycleTestGraph(id: 2) }
            // The losing installer returns only after the winner published.
            loserObservedGraph = !owns && lifecycle.snapshot() != nil
            loserDone.signal()
        }
        loser.start()
        // Give the loser time to reach the wait; it must NOT complete yet.
        XCTAssertEqual(
            loserDone.wait(timeout: .now() + 0.3),
            .timedOut,
            "losing install returned before the winning graph published"
        )
        releaseBuild.signal()
        XCTAssertEqual(loserDone.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(loserObservedGraph)
    }
}
