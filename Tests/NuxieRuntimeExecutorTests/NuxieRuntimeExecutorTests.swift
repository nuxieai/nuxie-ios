#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Darwin
import Foundation
import XCTest
@testable import NuxieRuntime

final class NuxieRuntimeExecutorTests: XCTestCase {
    func testExecutorPinsEveryOperationToOneDedicatedOSThread() async throws {
        let executor = NuxieRuntimePinnedThreadExecutor()
        let caller = UInt64(pthread_mach_thread_np(pthread_self()))

        async let first = executor.call {
            UInt64(pthread_mach_thread_np(pthread_self()))
        }
        async let second = executor.call {
            UInt64(pthread_mach_thread_np(pthread_self()))
        }
        let identities = try await [first, second]

        XCTAssertEqual(Set(identities).count, 1)
        XCTAssertNotEqual(identities[0], caller)
    }

    func testExecutorShutdownIsIdempotentAndRejectsNewWork() async throws {
        let executor = NuxieRuntimePinnedThreadExecutor()
        try await executor.shutdown()
        try await executor.shutdown()

        do {
            _ = try await executor.call { 1 }
            XCTFail("Expected a closed executor error")
        } catch {
            XCTAssertEqual(error as? NuxieRuntimeExecutorError, .closed)
        }
    }

    @MainActor
    func testExecutorShutdownSuspendsCallerUntilAcceptedWorkAndContextsDrain() async throws {
        let executor = NuxieRuntimePinnedThreadExecutor()
        let entered = expectation(description: "native job entered")
        let shuttingDown = expectation(description: "shutdown task started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let events = RuntimeExecutorEvents()
        executor.enqueue {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        executor.enqueue { [probe = RuntimeExecutorReleaseProbe({ events.append("released") })] in
            withExtendedLifetime(probe) { events.append("cleanup") }
        }
        await fulfillment(of: [entered], timeout: 1)

        let shutdown = Task { @MainActor in
            shuttingDown.fulfill()
            try await executor.shutdown()
            events.append("terminated")
        }
        await fulfillment(of: [shuttingDown], timeout: 1)
        // The main actor must remain free to release a blocked native operation.
        release.signal()
        try await shutdown.value
        XCTAssertEqual(events.values, ["cleanup", "released", "terminated"])
    }

    func testNativeExecutorTerminationCallbacksOwnContextsAndRejectWorkDuringDrain() async throws {
        let executor = NuxieNativeExecutor()
        let entered = expectation(description: "native job entered")
        let delivered = expectation(description: "termination observers delivered")
        delivered.expectedFulfillmentCount = 2
        delivered.assertForOverFulfill = true
        let contextsReleased = expectation(description: "observer contexts released")
        contextsReleased.expectedFulfillmentCount = 2
        contextsReleased.assertForOverFulfill = true
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let events = RuntimeExecutorEvents()
        XCTAssertTrue(executor.submit({
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            events.append("drained")
        }, abandoned: { XCTFail("Accepted job was abandoned") }))
        await fulfillment(of: [entered], timeout: 1)

        for _ in 0..<2 {
            try executor.shutdown { [probe = RuntimeExecutorReleaseProbe({ contextsReleased.fulfill() })] in
                withExtendedLifetime(probe) {
                    XCTAssertEqual(events.values, ["drained"])
                    delivered.fulfill()
                }
            }
        }
        XCTAssertFalse(executor.submit({ XCTFail("Work accepted after close") },
            abandoned: { XCTFail("Rejected work transferred ownership") }))
        XCTAssertTrue(events.values.isEmpty)
        release.signal()
        await fulfillment(of: [delivered, contextsReleased], timeout: 1)
    }

    func testExecutorSupportsConcurrentAndLateShutdownWaiters() async throws {
        let executor = NuxieRuntimePinnedThreadExecutor()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { try await executor.shutdown() }
            }
            try await group.waitForAll()
        }
        try await executor.shutdown()
    }

    func testExecutorDeinitDoesNotBlockAndStillDrainsAcceptedCleanup() async {
        let holder = RuntimeExecutorHolder(NuxieRuntimePinnedThreadExecutor())
        let entered = expectation(description: "native job entered")
        let cleanup = expectation(description: "accepted cleanup runs after owner release")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        holder.withExecutor { executor in
            executor.enqueue {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            executor.enqueue { cleanup.fulfill() }
        }
        await fulfillment(of: [entered], timeout: 1)
        holder.clearExecutor()
        XCTAssertFalse(holder.hasExecutor)
        release.signal()
        await fulfillment(of: [cleanup], timeout: 1)
    }

    func testExecutorCanReleaseItsLastOwnerOnTheWorkerThread() async {
        let released = expectation(description: "executor released on its worker")
        let holder = RuntimeExecutorHolder(NuxieRuntimePinnedThreadExecutor())
        holder.withExecutor { executor in
            executor.enqueue {
                holder.clearExecutor()
                released.fulfill()
            }
        }

        await fulfillment(of: [released], timeout: 1)
        XCTAssertFalse(holder.hasExecutor)
    }

    func testFinalExecutorOperationReturnsItsValueAfterDrainingCleanup() async throws {
        let executor = NuxieRuntimePinnedThreadExecutor()
        let events = RuntimeExecutorEvents()
        let value = try await executor.callThenShutdown {
            executor.enqueue { events.append("cleanup") }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(events.values, ["cleanup"])
    }

    func testFinalExecutorOperationShutsDownAfterThrowing() async {
        enum Expected: Error {
            case failure
        }

        let executor = NuxieRuntimePinnedThreadExecutor()
        let events = RuntimeExecutorEvents()
        do {
            try await executor.callThenShutdown {
                executor.enqueue { events.append("cleanup") }
                throw Expected.failure
            }
            XCTFail("Expected the final operation to throw")
        } catch Expected.failure {
            // The original native destruction error remains observable after drain.
            XCTAssertEqual(events.values, ["cleanup"])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await executor.call { 1 }
            XCTFail("Expected the executor to be closed after the failure")
        } catch {
            XCTAssertEqual(error as? NuxieRuntimeExecutorError, .closed)
        }
    }
}

private final class RuntimeExecutorEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) { lock.withLock { events.append(event) } }
    var values: [String] { lock.withLock { events } }
}

private final class RuntimeExecutorReleaseProbe: Sendable {
    private let onRelease: @Sendable () -> Void

    init(_ onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}

private final class RuntimeExecutorHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var executor: NuxieRuntimePinnedThreadExecutor?

    init(_ executor: NuxieRuntimePinnedThreadExecutor) {
        self.executor = executor
    }

    var hasExecutor: Bool {
        lock.withLock { executor != nil }
    }

    func withExecutor(_ operation: (NuxieRuntimePinnedThreadExecutor) -> Void) {
        lock.withLock {
            if let executor {
                operation(executor)
            }
        }
    }

    func clearExecutor() {
        lock.withLock {
            executor = nil
        }
    }
}
#endif
