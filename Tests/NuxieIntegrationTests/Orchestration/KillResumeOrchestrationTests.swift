#if LEGACY_JOURNEY_TESTS
import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// P6 orchestration: kill-mid-delay resume.
///
/// A journey enters a delay; the whole stack is dropped WITHOUT graceful
/// shutdown (no journey shutdown, no background snapshot, no flush — see
/// `OrchestrationStack.kill()`); a fresh stack boots over the same storage;
/// the clock advances past the delay; the journey resumes and the delayed
/// action fires exactly once across both "processes".
final class KillResumeOrchestrationTests: AsyncSpec {
    override class func spec() {
        describe("kill-mid-delay journey resume (orchestration)") {
            let user = "orchestration-user"
            let experienceId = "camp-delay"
            let flowId = "flow-delay"

            var storageURL: URL!
            var api: MockNuxieApi!
            var dateProvider: MockDateProvider!
            var sleepProvider: MockSleepProvider!
            var stack: OrchestrationStack!

            func fixtureExperience() -> Experience {
                OrchestrationFixtures.experience(
                    id: experienceId,
                    flowId: flowId,
                    eventName: "delay_trigger",
                    reentry: .oneTime
                )
            }

            func fixtureFlow() throws -> JourneyDocument {
                try OrchestrationFixtures.delayFlow(
                    id: flowId,
                    trigger: "delay_trigger",
                    delayMs: 60_000,
                    effect: "delayed_effect"
                )
            }

            /// Session 1: enroll into the delay and verify the resumable
            /// state hit disk, then kill the process mid-delay.
            func enrollAndKillMidDelay() async throws {
                try await stack.installProfile(
                    experiences: [fixtureExperience()], journeys: [fixtureFlow()]
                )
                await stack.trackAndDrain("delay_trigger")

                // Paused mid-delay, with a persisted pendingAction.
                await expect {
                    guard let journey = await stack.journeys.getActiveJourneys(for: user).first else { return nil }
                    return await journey.snapshot().status
                }
                    .toEventually(equal(JourneyStatus.paused), timeout: .seconds(5))

                let persisted = stack.journeyStoreOnDisk().loadActiveJourneys()
                expect(persisted).to(haveCount(1))
                expect(persisted.first?.executionState.pendingAction?.kind).to(equal(.delay))
                expect(persisted.first?.executionState.pendingAction?.resumeAt).toNot(beNil())

                // Nothing after the delay ran yet.
                await expect { await stack.eventCount("delayed_effect") }.to(equal(0))

                await stack.kill()
                stack = nil
            }

            /// After the relaunched stack resumed the journey: the delayed
            /// action fired exactly once, the journey completed, disk state
            /// is consistent, and reentry accounting recorded the completion.
            func assertResumedExactlyOnce() async throws {
                await expect { await stack.eventCount("delayed_effect") }
                    .toEventually(equal(1), timeout: .seconds(5))
                await expect { await stack.eventCount("$journey_exited") }
                    .toEventually(equal(1), timeout: .seconds(5))
                await expect { await stack.journeys.getActiveJourneys(for: user).count }
                    .toEventually(equal(0), timeout: .seconds(5))

                let store = stack.journeyStoreOnDisk()
                expect(store.loadActiveJourneys()).to(beEmpty())
                expect(store.hasCompletedExperience(distinctId: user, experienceId: experienceId))
                    .to(beTrue())

                // A later timer sweep must not re-fire the delayed action.
                stack.dateProvider.advance(by: 3_600)
                await stack.journeys.checkExpiredTimers()
                await stack.eventLog.drain()
                await expect { await stack.eventCount("delayed_effect") }.to(equal(1))
                await expect { await stack.eventCount("$journey_exited") }.to(equal(1))
            }

            beforeEach {
                storageURL = URL(
                    fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
                ).appendingPathComponent("nuxie-orch-kill-\(UUID().uuidString)", isDirectory: true)
                api = MockNuxieApi()
                dateProvider = MockDateProvider()
                sleepProvider = MockSleepProvider()

                stack = try await OrchestrationStack.boot(
                    storageURL: storageURL,
                    api: api,
                    dateProvider: dateProvider,
                    sleepProvider: sleepProvider,
                    distinctId: user
                )
            }

            afterEach {
                await stack?.shutdownForCleanup()
                stack = nil
                sleepProvider?.reset()
                if let storageURL {
                    try? FileManager.default.removeItem(at: storageURL)
                }
            }

            it("resumes a killed mid-delay journey after relaunch and fires the delayed action exactly once") {
                try await enrollAndKillMidDelay()

                // "Process 2" over the same storage; network available.
                stack = try await OrchestrationStack.boot(
                    storageURL: storageURL,
                    api: api,
                    dateProvider: dateProvider,
                    sleepProvider: sleepProvider,
                    distinctId: user
                )
                try await stack.installProfile(
                    experiences: [fixtureExperience()], journeys: [fixtureFlow()]
                )

                // Restored, still paused, still nothing fired: the delay is
                // wall-clock anchored, not restarted-by-relaunch.
                await expect {
                    let journey = await stack.journeys.getActiveJourneys(for: user).first
                    return await journey?.snapshot().status
                }
                    .toEventually(equal(JourneyStatus.paused), timeout: .seconds(5))
                await expect { await stack.eventCount("delayed_effect") }.to(equal(0))

                // Advance past the delay and run the same due-timer sweep the
                // app lifecycle (foreground/init) uses.
                stack.dateProvider.advance(by: 61)
                await stack.journeys.checkExpiredTimers()
                await stack.eventLog.drain()

                try await assertResumedExactlyOnce()
            }

            it("resumes a delay that expired while dead during initialize itself — the resume sweep awaits the profile disk cache instead of cancelling") {
                try await enrollAndKillMidDelay()

                // The delay elapsed entirely while the process was dead, so
                // the very first checkExpiredTimers sweep inside
                // journeys.initialize() resumes it — concurrently with
                // ProfileService's disk-cache load. getCachedProfile must
                // await that load; observing nil here used to cancel the
                // journey (getExperience == nil → cancel).
                dateProvider.advance(by: 61)

                // Offline relaunch: the profile can ONLY come from the disk
                // cache, and the flow bundle from the (modeled) disk-cached
                // artifact store, so the race has no network fallback.
                await api.setShouldFailProfile(true)
                await api.setShouldFailBatch(true)
                await api.configureTrackEventFailure()

                stack = try await OrchestrationStack.boot(
                    storageURL: storageURL,
                    api: api,
                    dateProvider: dateProvider,
                    sleepProvider: sleepProvider,
                    distinctId: user,
                    preRegisteredExperiences: [
                        (fixtureExperience(), try fixtureFlow())
                    ]
                )
                await stack.eventLog.drain()

                try await assertResumedExactlyOnce()
                await expect { await stack.lastJourneyExitReason() }
                    .toEventually(equal("completed"), timeout: .seconds(5))
            }

            it("resumes a killed mid-delay journey after an OFFLINE relaunch — cached profile from disk, zero network") {
                try await enrollAndKillMidDelay()

                // Relaunch in airplane mode: profile must come from the disk
                // cache, the flow bundle from the (production: disk-cached)
                // artifact store, and every event stays queued locally.
                await api.setShouldFailProfile(true)
                await api.setShouldFailBatch(true)
                await api.configureTrackEventFailure()

                stack = try await OrchestrationStack.boot(
                    storageURL: storageURL,
                    api: api,
                    dateProvider: dateProvider,
                    sleepProvider: sleepProvider,
                    distinctId: user
                )
                // The mocked artifact edge has no disk cache of its own —
                // re-register the bundle (production reads it from disk).
                stack.registerExperiences(
                    [try fixtureFlow()],
                    metadata: [fixtureExperience()]
                )
                try await stack.waitForCachedProfile()

                await expect {
                    let journey = await stack.journeys.getActiveJourneys(for: user).first
                    return await journey?.snapshot().status
                }
                    .toEventually(equal(JourneyStatus.paused), timeout: .seconds(5))

                let batchAttemptsBefore = await api.sendBatchCallCount
                stack.dateProvider.advance(by: 61)
                await stack.journeys.checkExpiredTimers()
                await stack.eventLog.drain()

                try await assertResumedExactlyOnce()

                // Still fully offline: synchronous exit delivery may flush
                // the pending batch, but cannot acknowledge it.
                await expect { await api.sendBatchCallCount }
                    .to(beGreaterThanOrEqualTo(batchAttemptsBefore))
                let queued = await stack.eventLog.getQueuedEventCount()
                expect(queued).to(beGreaterThan(0))
            }
        }
    }
}
#endif
