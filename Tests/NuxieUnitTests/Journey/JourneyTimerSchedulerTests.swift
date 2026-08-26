import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// Async-safe counter for asserting work-closure execution across tasks.
private final class WorkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func hit(_ key: String) {
        lock.lock()
        counts[key, default: 0] += 1
        lock.unlock()
    }

    func count(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[key] ?? 0
    }
}

private final class CancellationControlledSleepProvider: SleepProviderProtocol, @unchecked Sendable {
    private actor State {
        private var started = false
        private var cancellationObserved = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func sleep() async throws {
            started = true
            let waiters = startedWaiters
            startedWaiters.removeAll()
            waiters.forEach { $0.resume() }

            await withTaskCancellationHandler {
                await withCheckedContinuation { releaseWaiters.append($0) }
            } onCancel: {
                Task { await self.recordCancellation() }
            }
            throw CancellationError()
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { startedWaiters.append($0) }
        }

        func waitUntilCancellation() async {
            guard !cancellationObserved else { return }
            await withCheckedContinuation { cancellationWaiters.append($0) }
        }

        func release() {
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        private func recordCancellation() {
            cancellationObserved = true
            let waiters = cancellationWaiters
            cancellationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private let state = State()

    func sleep(for duration: TimeInterval) async throws {
        try await state.sleep()
    }

    func waitUntilStarted() async {
        await state.waitUntilStarted()
    }

    func waitUntilCancellation() async {
        await state.waitUntilCancellation()
    }

    func release() async {
        await state.release()
    }
}

private actor TimerWorkGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

final class JourneyTimerSchedulerTests: AsyncSpec {
    override class func spec() {
        describe("taskKey") {
            it("joins journey id, kind, and optional id") {
                expect(JourneyTimerScheduler.taskKey(journeyId: "j1", kind: "resume")) == "j1:resume"
                expect(JourneyTimerScheduler.taskKey(journeyId: "j1", kind: "resume", id: "x")) == "j1:resume:x"
            }
        }

        describe("schedule") {
            it("runs the work after the sleep completes") {
                let sleep = MockSleepProvider()
                sleep.shouldCompleteImmediately = true
                let scheduler = JourneyTimerScheduler(
                    dateProvider: SystemDateProvider(),
                    sleepProvider: sleep
                )
                let counter = WorkCounter()

                scheduler.schedule(key: "j1:resume", at: Date()) {
                    counter.hit("j1")
                }

                await expect(counter.count("j1")).toEventually(equal(1))
            }

            it("replaces a pending task scheduled under the same key") {
                let sleep = MockSleepProvider()
                let scheduler = JourneyTimerScheduler(
                    dateProvider: SystemDateProvider(),
                    sleepProvider: sleep
                )
                let counter = WorkCounter()

                scheduler.schedule(key: "j1:resume", at: Date().addingTimeInterval(60)) {
                    counter.hit("old")
                }
                scheduler.schedule(key: "j1:resume", at: Date().addingTimeInterval(60)) {
                    counter.hit("new")
                }

                await expect(sleep.sleepCalls.count).toEventually(beGreaterThanOrEqualTo(2))

                // Poll: keep releasing pending sleeps until the surviving task runs
                // (a sleep may register after an earlier completeAllSleeps call).
                await expect {
                    sleep.completeAllSleeps()
                    return counter.count("new")
                }.toEventually(equal(1))
                expect(counter.count("old")) == 0
            }

            it("keeps a replacement registered after the cancelled task cleans up") {
                let sleep = MockSleepProvider()
                let scheduler = JourneyTimerScheduler(
                    dateProvider: SystemDateProvider(),
                    sleepProvider: sleep
                )
                let counter = WorkCounter()

                let oldTask = scheduler.schedule(
                    key: "j1:resume",
                    at: Date().addingTimeInterval(60)
                ) {
                    counter.hit("old")
                }
                await expect(sleep.pendingSleepCount).toEventually(equal(1))

                scheduler.schedule(key: "j1:resume", at: Date().addingTimeInterval(60)) {
                    counter.hit("replacement")
                }
                await expect(sleep.sleepCalls.count).toEventually(equal(2))
                await expect(sleep.pendingSleepCount).toEventually(equal(1))

                // Task completion includes the scheduler's defer cleanup, so
                // the replacement is definitely resident when cancelAll runs.
                await oldTask.value

                await scheduler.cancelAll()
                sleep.completeAllSleeps()

                expect(counter.count("old")) == 0
                expect(counter.count("replacement")) == 0
            }

            it("cancelTasks stops every task for the journey and leaves others") {
                let sleep = MockSleepProvider()
                let scheduler = JourneyTimerScheduler(
                    dateProvider: SystemDateProvider(),
                    sleepProvider: sleep
                )
                let counter = WorkCounter()

                scheduler.schedule(key: "j1:resume", at: Date().addingTimeInterval(60)) {
                    counter.hit("j1")
                }
                scheduler.schedule(key: "j2:resume", at: Date().addingTimeInterval(60)) {
                    counter.hit("j2")
                }
                await expect(sleep.sleepCalls.count).toEventually(beGreaterThanOrEqualTo(2))

                scheduler.cancelTasks(journeyId: "j1")

                await expect {
                    sleep.completeAllSleeps()
                    return counter.count("j2")
                }.toEventually(equal(1))
                expect(counter.count("j1")) == 0
            }

            it("cancelAll stops everything") {
                let sleep = MockSleepProvider()
                let scheduler = JourneyTimerScheduler(
                    dateProvider: SystemDateProvider(),
                    sleepProvider: sleep
                )
                let counter = WorkCounter()

                scheduler.schedule(key: "j1:resume", at: Date().addingTimeInterval(60)) {
                    counter.hit("j1")
                }
                scheduler.schedule(key: "j2:resume", at: Date().addingTimeInterval(60)) {
                    counter.hit("j2")
                }
                await expect(sleep.sleepCalls.count).toEventually(beGreaterThanOrEqualTo(2))

                await scheduler.cancelAll()
                sleep.completeAllSleeps()

                // Give any stray continuations a beat, then assert nothing ran.
                try? await Task.sleep(nanoseconds: 50_000_000)
                expect(counter.count("j1")) == 0
                expect(counter.count("j2")) == 0
            }

            it("cancelAll waits for cancelled scheduler work to finish") {
                let sleep = CancellationControlledSleepProvider()
                let scheduler = JourneyTimerScheduler(
                    dateProvider: SystemDateProvider(),
                    sleepProvider: sleep
                )
                let counter = WorkCounter()

                scheduler.schedule(key: "j1:resume", at: Date().addingTimeInterval(60)) {}
                await sleep.waitUntilStarted()

                let cancellation = Task {
                    await scheduler.cancelAll()
                    counter.hit("completed")
                }
                await sleep.waitUntilCancellation()

                expect(counter.count("completed")) == 0
                await sleep.release()
                await cancellation.value
                expect(counter.count("completed")) == 1
            }

            it("cancelAll rejects a replacement scheduled by firing work during the drain") {
                let sleep = MockSleepProvider()
                let scheduler = JourneyTimerScheduler(
                    dateProvider: SystemDateProvider(),
                    sleepProvider: sleep
                )
                let gate = TimerWorkGate()
                let counter = WorkCounter()

                let firingTask = scheduler.schedule(key: "j1:resume", at: Date()) {
                    await gate.pause()
                    scheduler.schedule(key: "j1:resume", at: Date()) {
                        counter.hit("replacement")
                    }
                }
                await expect(sleep.pendingSleepCount).toEventually(equal(1))
                sleep.completeAllSleeps()
                await gate.waitUntilEntered()

                let cancellation = Task {
                    await scheduler.cancelAll()
                }
                await expect(firingTask.isCancelled).toEventually(beTrue())
                await gate.release()
                await cancellation.value

                expect(scheduler.activeTaskCount) == 0
                sleep.completeAllSleeps()
                try? await Task.sleep(nanoseconds: 50_000_000)
                expect(counter.count("replacement")) == 0
            }
        }
    }
}
