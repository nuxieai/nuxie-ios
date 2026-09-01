import Foundation
import Nimble
import Quick
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class HostDismissalOrchestrationTests: AsyncSpec {
    override class func spec() {
        describe("host-dismissal orchestration") {
            var storageURL: URL!
            var stack: OrchestrationStack?

            beforeEach {
                storageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "nuxie-host-dismissal-\(UUID().uuidString)",
                    isDirectory: true
                )
            }

            afterEach {
                await stack?.shutdownForCleanup()
                stack = nil
                try? FileManager.default.removeItem(at: storageURL)
            }

            it("returns at screen gone while durable exit capture continues") { @MainActor in
                let triggerName = "host-dismissal-trigger"
                let experienceId = "host-dismissal-experience"
                let flowId = "host-dismissal-flow"
                let distinctId = "host-dismissal-user"
                let api = MockNuxieApi()
                let dateProvider = MockDateProvider()
                let sleepProvider = MockSleepProvider()
                sleepProvider.shouldCompleteImmediately = true
                let exitCaptureGate = HostExitCaptureGate()
                let experience = OrchestrationFixtures.experience(
                    id: experienceId,
                    flowId: flowId,
                    eventName: triggerName,
                    reentry: .everyTime
                )
                let flow = try OrchestrationFixtures.exitFlow(
                    id: flowId,
                    trigger: triggerName,
                    effect: "unused-after-host-dismissal"
                )
                let booted = try await OrchestrationStack.boot(
                    storageURL: storageURL,
                    api: api,
                    dateProvider: dateProvider,
                    sleepProvider: sleepProvider,
                    distinctId: distinctId,
                    configure: { configuration in
                        configuration.beforeSend = { event in
                            exitCaptureGate.capture(event)
                        }
                    }
                )
                stack = booted
                try await booted.installProfile(
                    experiences: [experience],
                    journeys: [flow]
                )

                let updates = await booted.trigger(triggerName)
                let journey = try XCTUnwrap(booted.presentation.lastPresentedJourney)
                let enrolled = await journey.snapshot()
                expect(enrolled.status.isLive).to(beTrue())
                expect(booted.journeyStoreOnDisk().loadJourney(id: journey.id)).toNot(beNil())

                await booted.eventLog.drain()
                _ = await booted.eventLog.flushEvents()
                let queuedAfterSetup = await booted.eventLog.getQueuedEventCount()
                expect(queuedAfterSetup).to(equal(0))
                let directTrackCallsBeforeDismissal = await api.trackEventCallCount

                let dismissalCompletion = HostDismissalCompletionProbe()
                let dismissal = Task { @MainActor in
                    await booted.presentation.dismissCurrentExperienceFromHost()
                    dismissalCompletion.finish()
                }
                defer { exitCaptureGate.release() }

                try await waitForHostExitCapture(in: exitCaptureGate)

                let returnedAtScreenGone = await waitForHostDismissalCompletion(
                    in: dismissalCompletion
                )
                expect(returnedAtScreenGone).to(beTrue())
                expect(updates.updates.compactMap(\.journeyUpdate)).to(beEmpty())

                // The in-memory terminal transition and screen close have
                // returned. The write-behind lane has committed its tombstone
                // and is now blocked in EventLog capture.
                let durableTerminal = try XCTUnwrap(
                    booted.journeyStoreOnDisk().loadJourney(id: journey.id)
                )
                expect(durableTerminal.status).to(equal(.completed))
                expect(durableTerminal.exitReason).to(equal(.dismissed))

                exitCaptureGate.release()
                await dismissal.value
                await booted.eventLog.drain()

                expect(dismissalCompletion.isFinished).to(beTrue())
                let tombstoneRemoved = await waitForHostTombstoneRemoval(
                    in: booted,
                    journeyId: journey.id
                )
                expect(tombstoneRemoved).to(beTrue())
                let directTrackCallsAfterDismissal = await api.trackEventCallCount
                expect(directTrackCallsAfterDismissal)
                    .to(equal(directTrackCallsBeforeDismissal))

                let exits = await booted.storedEvents(named: JourneyEvents.journeyExited)
                expect(exits).to(haveCount(1))
                let exit = try XCTUnwrap(exits.first)
                expect(exit.id).to(equal(
                    "journey-exited:\(journey.id):\(durableTerminal.epoch)"
                ))
                expect(exit.distinctId).to(equal(distinctId))
                let properties = try exit.getProperties().mapValues(\.value)
                let hostPropertyKeys = [
                    "journey_id", "epoch", "reason", "at", "dismissed_by",
                ]
                let hostProperties = hostPropertyKeys.reduce(into: [String: Any]()) {
                    result, key in
                    result[key] = properties[key]
                }
                let completedAt = try XCTUnwrap(durableTerminal.completedAt)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                expect(hostProperties as NSDictionary).to(equal([
                    "journey_id": journey.id,
                    "epoch": durableTerminal.epoch,
                    "reason": "dismissed",
                    "at": formatter.string(from: completedAt),
                    "dismissed_by": "host",
                ] as NSDictionary))

                let terminalUpdates = updates.updates.compactMap(\.journeyUpdate)
                expect(terminalUpdates).to(haveCount(1))
                expect(terminalUpdates.first?.journeyId).to(equal(journey.id))
                expect(terminalUpdates.first?.experienceId).to(equal(experienceId))
                expect(terminalUpdates.first?.experienceVersion).to(equal(flowId))
                expect(terminalUpdates.first?.exitReason).to(equal(.dismissed))
                expect(terminalUpdates.first?.goalMet).to(beFalse())

                // The host-facing call has returned without a network round
                // trip, while the stable capture remains pending for durable
                // delivery. A failed attempt must retain it; the next flush
                // retries and drains the same single stored event.
                let queuedBeforeFailure = await booted.eventLog.getQueuedEventCount()
                expect(queuedBeforeFailure).to(beGreaterThan(0))
                let exitAttemptsBeforeFlush = await api.sentEvents.filter {
                    $0.name == JourneyEvents.journeyExited
                }
                expect(exitAttemptsBeforeFlush).to(beEmpty())

                await api.configureTrackEventFailure()
                let failedFlush = await booted.eventLog.flushEvents()
                expect(failedFlush).to(beFalse())
                let queuedAfterFailure = await booted.eventLog.getQueuedEventCount()
                // Other queued rows may resolve terminally in the same flush;
                // the failed host exit itself must remain pending.
                expect(queuedAfterFailure).to(beGreaterThan(0))
                let failedExitAttempts = await api.sentEvents.filter {
                    $0.name == JourneyEvents.journeyExited
                }.count
                expect(failedExitAttempts).to(beGreaterThan(0))
                let exitsAfterFailure = await booted.storedEvents(
                    named: JourneyEvents.journeyExited
                )
                expect(exitsAfterFailure).to(haveCount(1))

                await api.reset()
                let successfulFlush = await booted.eventLog.flushEvents()
                expect(successfulFlush).to(beTrue())
                let queuedAfterSuccess = await booted.eventLog.getQueuedEventCount()
                expect(queuedAfterSuccess).to(equal(0))
                let successfulExitDeliveries = await api.sentEvents.filter {
                    $0.name == JourneyEvents.journeyExited
                }
                expect(successfulExitDeliveries).to(haveCount(1))
                expect(successfulExitDeliveries.first?.id).to(equal(exit.id))
                let exitsAfterSuccess = await booted.storedEvents(
                    named: JourneyEvents.journeyExited
                )
                expect(exitsAfterSuccess).to(haveCount(1))
            }

            it("recovers interrupted host exit captures") { @MainActor in
                let triggerName = "host-dismissal-recovery-trigger"
                let experienceId = "host-dismissal-recovery-experience"
                let flowId = "host-dismissal-recovery-flow"
                let distinctId = "host-dismissal-recovery-user"
                let api = MockNuxieApi()
                let dateProvider = MockDateProvider()
                let sleepProvider = MockSleepProvider()
                sleepProvider.shouldCompleteImmediately = true
                let experience = OrchestrationFixtures.experience(
                    id: experienceId,
                    flowId: flowId,
                    eventName: triggerName,
                    reentry: .oneTime
                )
                let flow = try OrchestrationFixtures.exitFlow(
                    id: flowId,
                    trigger: triggerName,
                    effect: "unused-after-host-dismissal-recovery"
                )
                let booted = try await OrchestrationStack.boot(
                    storageURL: storageURL,
                    api: api,
                    dateProvider: dateProvider,
                    sleepProvider: sleepProvider,
                    distinctId: distinctId
                )
                stack = booted
                try await booted.installProfile(
                    experiences: [experience],
                    journeys: [flow]
                )

                _ = await booted.trigger(triggerName)
                let journey = try XCTUnwrap(booted.presentation.lastPresentedJourney)
                await booted.eventLog.drain()
                _ = await booted.eventLog.flushEvents()

                await booted.kill()
                // A killed process cannot run its in-memory retry task. Keep
                // this process-shaped harness from advancing that old lane
                // while the replacement stack recovers the tombstone.
                sleepProvider.shouldCompleteImmediately = false
                await booted.presentation.dismissCurrentExperienceFromHost()

                let interrupted = try XCTUnwrap(
                    booted.journeyStoreOnDisk().loadJourney(id: journey.id)
                )
                expect(interrupted.status).to(equal(.completed))
                expect(interrupted.exitReason).to(equal(.dismissed))
                expect(interrupted.pendingHostExitCapture).to(beTrue())
                let exitsBeforeRecovery = await booted.storedEvents(
                    named: JourneyEvents.journeyExited
                )
                expect(exitsBeforeRecovery).to(beEmpty())

                // Terminal persistence suppresses reentry immediately even
                // when EventLog is unavailable. Exit capture remains a
                // separate recoverable obligation.
                expect(
                    booted.journeyStoreOnDisk().hasCompletedExperience(
                        distinctId: distinctId,
                        experienceId: experienceId
                    )
                ).to(beTrue())

                let recovered = try await OrchestrationStack.boot(
                    storageURL: storageURL,
                    api: api,
                    dateProvider: dateProvider,
                    sleepProvider: sleepProvider,
                    distinctId: distinctId
                )
                stack = recovered

                expect(recovered.journeyStoreOnDisk().loadJourney(id: journey.id))
                    .to(beNil())
                let recoveredStore = recovered.journeyStoreOnDisk()
                expect(
                    recoveredStore.hasCompletedExperience(
                        distinctId: distinctId,
                        experienceId: experienceId
                    )
                ).to(beTrue())
                expect(
                    recoveredStore.lastCompletionTime(
                        distinctId: distinctId,
                        experienceId: experienceId
                    )
                ).to(equal(interrupted.completedAt))
                let exits = await recovered.storedEvents(
                    named: JourneyEvents.journeyExited
                )
                expect(exits).to(haveCount(1))
                let exit = try XCTUnwrap(exits.first)
                expect(exit.id).to(equal(
                    "journey-exited:\(journey.id):\(interrupted.epoch)"
                ))
                expect(exit.distinctId).to(equal(distinctId))
                let properties = try exit.getProperties().mapValues(\.value)
                expect(properties["journey_id"] as? String).to(equal(journey.id))
                expect(properties["epoch"] as? Int).to(equal(interrupted.epoch))
                expect(properties["reason"] as? String).to(equal("dismissed"))
                expect(properties["dismissed_by"] as? String).to(equal("host"))
                let completedAt = try XCTUnwrap(interrupted.completedAt)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                expect(properties["at"] as? String)
                    .to(equal(formatter.string(from: completedAt)))
            }
        }
    }
}

private func waitForHostTombstoneRemoval(
    in stack: OrchestrationStack,
    journeyId: String
) async -> Bool {
    for _ in 0..<200 {
        if stack.journeyStoreOnDisk().loadJourney(id: journeyId) == nil {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

private func waitForHostDismissalCompletion(
    in probe: HostDismissalCompletionProbe
) async -> Bool {
    for _ in 0..<200 {
        if probe.isFinished {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

private final class HostDismissalCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.withLock { finished }
    }

    func finish() {
        lock.withLock { finished = true }
    }
}

private final class HostExitCaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var entered = false
    private var released = false

    var isWaiting: Bool {
        lock.withLock { entered && !released }
    }

    func capture(_ event: NuxieEvent) -> NuxieEvent? {
        guard event.name == JourneyEvents.journeyExited else { return event }
        let shouldWait = lock.withLock {
            entered = true
            return !released
        }
        if shouldWait {
            releaseSignal.wait()
        }
        return event
    }

    func release() {
        let shouldSignal = lock.withLock {
            guard !released else { return false }
            released = true
            return entered
        }
        if shouldSignal {
            releaseSignal.signal()
        }
    }
}

private func waitForHostExitCapture(in gate: HostExitCaptureGate) async throws {
    for _ in 0..<200 {
        if gate.isWaiting {
            return
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw OrchestrationHarnessError.timedOut("host $journey_exited durable capture")
}

private extension TriggerUpdate {
    var journeyUpdate: JourneyUpdate? {
        guard case .journey(let update) = self else { return nil }
        return update
    }
}
