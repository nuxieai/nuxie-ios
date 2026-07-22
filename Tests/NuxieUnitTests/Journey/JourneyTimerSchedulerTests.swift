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

                scheduler.cancelAll()
                sleep.completeAllSleeps()

                // Give any stray continuations a beat, then assert nothing ran.
                try? await Task.sleep(nanoseconds: 50_000_000)
                expect(counter.count("j1")) == 0
                expect(counter.count("j2")) == 0
            }
        }
    }
}
