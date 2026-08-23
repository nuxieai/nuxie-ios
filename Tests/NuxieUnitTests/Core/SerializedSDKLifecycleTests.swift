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
