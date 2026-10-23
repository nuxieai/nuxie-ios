import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

/// An event captured before the installed copy of the published setup is not
/// dropped: it starts from the copy it is handled under, once (UNIV-4589).
final class JourneyEarlyEventAdmissionTests: JourneyTestCase {

    func testEveryMatchNativeFailureResumesTheAdmittedCursorWithoutRepeatingItsEffect() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseEveryMatchNativeFailureResumesTheAdmittedCursorWithoutRepeatingItsEffect() }
    }

    private func exerciseEveryMatchNativeFailureResumesTheAdmittedCursorWithoutRepeatingItsEffect() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let reads = SelectedNativeFailures(failures: [1])
        let rejected = expectation(description: "Native preparation refused the admitted start")
        let gate = JourneyNthRoutedCaptureGate(eventName: "refused", suspendedCall: 1)
        addBoundedJourneyTeardown { await gate.release() }
        let steps = try JSONDecoder().decode([Journey.Step].self, from: Data(#"""
        [
          {"kind":"action","id":"effect","action":{"type":"send_event","eventName":"before_native"},"outlets":{"next":"branch"}},
          {"kind":"action","id":"branch","action":{"type":"condition","branches":[{"id":"yes","condition":{"type":"Compare","op":"==","left":{"type":"Response.Field","key":"answer"},"right":{"type":"Number","value":1}}}]},"outlets":{"yes":"wait","default":"wait"}},
          {"kind":"action","id":"wait","action":{"type":"delay","durationMs":60000},"outlets":{"next":"satisfied"}},
          {"kind":"complete","id":"satisfied","outcome":"satisfied"}
        ]
        """#.utf8))
        let live = try await liveTimedWait(directory: directory, steps: steps,
            prepareNativeValues: { _, _, _, _ in try await reads.attempt() },
            afterJourney: { event, accepted in
                if event.name == "start_waiting", !accepted {
                    rejected.fulfill()
                    await gate.intercept(event: "refused")
                }
            })
        live.events.track("start_waiting")
        await fulfillment(of: [rejected], timeout: 5)
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        let failedRuns = try await journal.runs()
        let admitted = try XCTUnwrap(failedRuns.first)
        XCTAssertEqual(admitted.stepId, "branch")
        XCTAssertNil(admitted.park)
        XCTAssertEqual(starts(in: live.store), 1)
        XCTAssertTrue(live.store.pendingCommittedRoutes.contains { $0.event.name == "start_waiting" })
        await gate.release()
        for _ in 0..<600 {
            if try await journal.runs().first?.park != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await live.events.drain()
        let resumedRuns = try await journal.runs()
        XCTAssertEqual(resumedRuns.map(\.id), [admitted.id])
        XCTAssertEqual(resumedRuns.first?.stepId, "wait")
        XCTAssertNotNil(resumedRuns.first?.park)
        XCTAssertEqual(starts(in: live.store), 1)
        XCTAssertEqual(live.store.storedEvents.filter { $0.name == "before_native" }.count, 1)
        await live.service.shutdown()
        await live.events.close()
    }

    func testPurchaseInputKeepsSettlementThroughNativeRestorationAndExecutionFailures() async throws {
        try await withBoundedJourneyWait { [self] in try await exercisePurchaseInputKeepsSettlementThroughNativeRestorationAndExecutionFailures() }
    }

    private func exercisePurchaseInputKeepsSettlementThroughNativeRestorationAndExecutionFailures() async throws {
        try await assertCommerceInputKeepsSettlement(type: "purchase", eventName: SystemEventNames.purchaseCompleted,
            outlet: "completed")
    }

    func testRestoreInputKeepsSettlementThroughNativeRestorationAndExecutionFailures() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseRestoreInputKeepsSettlementThroughNativeRestorationAndExecutionFailures() }
    }

    private func exerciseRestoreInputKeepsSettlementThroughNativeRestorationAndExecutionFailures() async throws {
        try await assertCommerceInputKeepsSettlement(type: "restore", eventName: SystemEventNames.restoreCompleted,
            outlet: "restored")
    }

    private func assertCommerceInputKeepsSettlement(type: String, eventName: String, outlet: String) async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let reads = SelectedNativeFailures(failures: [])
        let rejected = expectation(description: "Restoration refused the terminal input")
        let gate = JourneyNthRoutedCaptureGate(eventName: "refused", suspendedCall: 1)
        addBoundedJourneyTeardown { await gate.release() }
        let steps = try JSONDecoder().decode([Journey.Step].self, from: Data("""
        [
          {"kind":"action","id":"wait","action":{"type":"wait_until","trigger":{"kind":"event","eventName":"\(eventName)"},"condition":{"type":"Truthy","value":{"type":"Boolean","value":true}},"maxTimeMs":60000},"outlets":{"satisfied":"branch","timeout":"timeout"}},
          {"kind":"action","id":"branch","action":{"type":"condition","branches":[{"id":"yes","condition":{"type":"Compare","op":"==","left":{"type":"Response.Field","key":"answer"},"right":{"type":"Number","value":1}}}]},"outlets":{"yes":"after","default":"after"}},
          {"kind":"action","id":"after","action":{"type":"delay","durationMs":60000},"outlets":{"next":"timeout"}},
          {"kind":"action","id":"commerce","action":{"type":"\(type)","placementId":"placement"},"outlets":{"\(outlet)":"satisfied"}},
          {"kind":"complete","id":"satisfied","outcome":"satisfied"},
          {"kind":"complete","id":"timeout","outcome":"timeout"}
        ]
        """.utf8))
        let live = try await liveTimedWait(directory: directory, steps: steps,
            prepareNativeValues: { _, _, _, _ in try await reads.attempt() },
            afterJourney: { event, accepted in
                if event.name == eventName, !accepted {
                    if await gate.observationCount() == 0 { rejected.fulfill() }
                    await gate.intercept(event: "refused")
                }
            })
        live.events.track("start_waiting")
        await live.events.drain()
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        let initialRuns = try await journal.runs()
        let run = try XCTUnwrap(initialRuns.first)
        let park = try XCTUnwrap(run.park)
        let fence = JourneyProfileFence()
        let admission = JourneyCommitAdmission.executionOnly(identity: MockIdentityService(),
            executionFence: fence, executionFenceToken: fence.token())
        try await journal.transition(run.id, stepId: "commerce", context: run.context)
        let effectId = try await journal.claimEffect(run.id, stepId: "commerce")
        let retained = try await journal.retainPresentationCommerce(run.id, stepId: "commerce", effectId: effectId,
            placementId: "placement", admission: admission)
        XCTAssertNotNil(retained)
        try await journal.transition(run.id, stepId: "wait", context: run.context,
            checkpoint: .init(anchorAtMillis: try XCTUnwrap(park.anchorAt.flatMap(JourneyTime.milliseconds)),
                wakeAtMillis: try XCTUnwrap(park.wakeAt.flatMap(JourneyTime.milliseconds))))
        // Fail restoration first, then execution after that checkpoint has
        // resumed. Both failures belong to this same terminal input.
        await reads.reset(failures: [1, 3])
        let captured = await live.events.captureAndRouteSystemEvent(.init(name: eventName,
            properties: ["placement_id": "placement"], eventId: effectId, distinctId: "customer"))
        XCTAssertNotNil(captured)
        await fulfillment(of: [rejected], timeout: 5)
        XCTAssertEqual(completions(in: live.store), [])
        XCTAssertTrue(live.store.pendingCommittedRoutes.contains { $0.event.id == effectId })
        await gate.release()
        for _ in 0..<600 {
            if !completions(in: live.store).isEmpty { break }
            if !live.store.pendingCommittedRoutes.contains(where: { $0.event.id == effectId }) {
                XCTAssertEqual(completions(in: live.store), ["satisfied"],
                    "The terminal route cannot be acknowledged while settlement is unfinished")
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<300 {
            if !live.store.pendingCommittedRoutes.contains(where: { $0.event.id == effectId }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(completions(in: live.store), ["satisfied"])
        XCTAssertFalse(live.store.pendingCommittedRoutes.contains { $0.event.id == effectId })
        XCTAssertEqual(starts(in: live.store), 1)
        let remaining = try await journal.runs()
        XCTAssertTrue(remaining.isEmpty)
        await live.service.shutdown()
        await live.events.close()
    }

    func testUnavailableCustomerReadKeepsTheDeadlineEntryWithBackoff() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseUnavailableCustomerReadKeepsTheDeadlineEntryWithBackoff() }
    }

    private func exerciseUnavailableCustomerReadKeepsTheDeadlineEntryWithBackoff() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let reads = FailableJourneyRead()
        let live = try await liveTimedWait(directory: directory,
            step: Self.waitSteps(eventName: "go", maxTimeMillis: 60_000)[0], readJournalRuns: { store in
                try await reads.attempt()
                return try await store.runs()
            })
        live.events.track("start_waiting")
        await live.events.drain()
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        let runs = try await journal.runs()
        let run = try XCTUnwrap(runs.first)
        await reads.setFailing(true)
        let attempts = DeadlineAttempts()
        await live.events.setJourneyDeadlineHandler { [service = live.service] deadline in
            await attempts.record()
            let outcome = await service.handleJourneyDeadline(deadline)
            if case .failed = outcome {} else { await attempts.unexpected() }
            return outcome
        }
        for _ in 0..<300 {
            if live.sleeper.pendingSleepCount > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(live.sleeper.pendingSleepCount, 0)
        live.clock.advance(by: 61)
        live.sleeper.completeAllSleeps()
        for _ in 0..<200 {
            if await attempts.times.count > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let blockedAttempts = await attempts.times
        XCTAssertFalse(blockedAttempts.isEmpty)
        for (first, second) in zip(blockedAttempts, blockedAttempts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(second - first, 0.99)
        }
        XCTAssertEqual(completions(in: live.store), [])
        let blockedRuns = try await journal.runs()
        XCTAssertEqual(blockedRuns.first?.park, run.park, "An unreadable customer cannot consume the timed checkpoint")
        XCTAssertEqual(blockedRuns.first?.stepId, run.stepId)
        let unexpected = await attempts.unexpectedCount
        XCTAssertEqual(unexpected, 0, "A failed customer read retains retry ownership")
        let keys = await live.events.queuedJourneyRetryKeys()
        XCTAssertEqual(keys.filter { $0.id.hasPrefix("deadline:") }.count, 1)
        await reads.setFailing(false)
        await live.events.setJourneyDeadlineHandler { [service = live.service] deadline in
            await service.handleJourneyDeadline(deadline)
        }
        for _ in 0..<400 where completions(in: live.store).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(completions(in: live.store), ["timeout"])
        await live.service.shutdown()
        await live.events.close()
    }

    private actor SelectedNativeFailures {
        private var count = 0
        private var failures: Set<Int>
        init(failures: Set<Int>) { self.failures = failures }
        func reset(failures: Set<Int>) { count = 0; self.failures = failures }
        func attempt() throws {
            count += 1
            if failures.contains(count) { throw JourneyExecutionError.invalidState }
        }
    }

    private actor DeadlineAttempts {
        private(set) var times: [TimeInterval] = []
        private(set) var unexpectedCount = 0
        func record() { times.append(ProcessInfo.processInfo.systemUptime) }
        func unexpected() { unexpectedCount += 1 }
    }

    func testFailedEventRestorationUsesTheQueueAndGatesOnlyRenderedBackgroundRetries() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseFailedEventRestorationUsesTheQueueAndGatesOnlyRenderedBackgroundRetries() }
    }

    private func exerciseFailedEventRestorationUsesTheQueueAndGatesOnlyRenderedBackgroundRetries() async throws {
        for hasScreens in [false, true] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let reads = FailableJourneyRead()
            let refused = expectation(description: "A failed native read leaves the matching input queued")
            let live = try await liveTimedWait(directory: directory,
                step: Self.waitSteps(eventName: "go", maxTimeMillis: 60_000)[0],
                readNativeValues: { values in
                    try await reads.attempt()
                    return try await values.journeyValues()
                }, afterJourney: { event, accepted in
                    if event.name == "go", !accepted { refused.fulfill() }
                }, screens: hasScreens ? [Self.backgroundScreen] : [])
            live.events.track("start_waiting")
            await live.events.drain()
            if !hasScreens { await live.service.onAppDidEnterBackground() }
            await reads.setFailing(true)
            live.clock.advance(by: 0.1)
            live.events.track("go")
            await fulfillment(of: [refused], timeout: 5)
            if hasScreens { await live.service.onAppDidEnterBackground() }
            await live.events.drain()
            let failedAt = await reads.attempts
            let queued = await live.events.queuedJourneyRetryKeys()
            XCTAssertEqual(queued.filter { $0.id.hasPrefix("input:") }.count, 1)
            await reads.setFailing(false)
            if hasScreens {
                try await Task.sleep(nanoseconds: 1_200_000_000)
                let backgroundReads = await reads.attempts
                XCTAssertEqual(backgroundReads, failedAt, "The retry gate precedes native restoration")
                XCTAssertEqual(completions(in: live.store), [])
                await live.service.onAppBecameActive()
            }
            for _ in 0..<400 where completions(in: live.store).isEmpty {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(completions(in: live.store), ["satisfied"])
            XCTAssertEqual(live.clock.now(), Date(timeIntervalSince1970: 1000.1))
            await live.service.shutdown()
            await live.events.close()
        }
    }

    func testFailedReconciliationAfterRefetchSettlesRetriesWithoutLeavingRoutingHeld() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseFailedReconciliationAfterRefetchSettlesRetriesWithoutLeavingRoutingHeld() }
    }

    private func exerciseFailedReconciliationAfterRefetchSettlesRetriesWithoutLeavingRoutingHeld() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inspection = FailableJourneyRead()
        let delivered = JourneyDeliveryObservation()
        let live = try await liveTimedWait(directory: directory, readJournalRuns: { journal in
            try await inspection.attempt()
            return try await journal.runs()
        }, afterJourney: { event, accepted in
            if event.name == "after_refetch" { await delivered.record(accepted) }
        })
        await live.events.drain()
        await live.service.profileRefetchWillBegin(distinctId: "customer")
        await live.service.profileDidWithdraw(authority: nil, distinctId: "customer")
        await inspection.setFailing(true)
        let before = await inspection.attempts
        await live.service.profileRefetchDidSettle(distinctId: "customer")
        let failed = await inspection.attempts
        XCTAssertGreaterThan(failed, before)
        let pendingReconciliation = await live.events.queuedJourneyRetryKeys()
        XCTAssertEqual(pendingReconciliation.filter { $0.id == "reconcile" }.count, 1)
        XCTAssertTrue(live.sleeper.pendingSleepDurations.isEmpty, "No park exists and reconciliation owns no sleeper")
        await inspection.setFailing(false)
        // No event, lifecycle callback, deadline, or mock sleep drives this retry.
        for _ in 0..<400 {
            if await inspection.attempts > failed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let retried = await inspection.attempts
        XCTAssertGreaterThan(retried, failed, "The queue retries the failed reconciliation")
        live.events.track("after_refetch")
        await live.events.drain()
        let accepted = await delivered.values
        XCTAssertEqual(accepted, [true], "Settling the refetch releases its hold even when reconciliation fails")
        XCTAssertTrue(live.store.pendingCommittedRoutes.isEmpty)
        await live.service.shutdown()
        await live.events.close()
    }

    func testHeldRoutingQueuesEveryDeadlineBeforeEventsAcceptedAfterIt() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseHeldRoutingQueuesEveryDeadlineBeforeEventsAcceptedAfterIt() }
    }

    private func exerciseHeldRoutingQueuesEveryDeadlineBeforeEventsAcceptedAfterIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = replacing(try await authenticatedSnapshot(fixture), entry: Self.eventEntry("start_waiting"),
            reentry: .init(type: .everyMatch, window: nil), completionOutputs: Self.heldWaitOutcomes,
            entryStepId: "wait", steps: Self.waitSteps(eventName: "go", maxTimeMillis: 20_000), routes: [], screens: [])
        let launch = Date(timeIntervalSince1970: 1000)
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        var retainedReleases: [String: AuthenticatedJourneyRelease] = [:]
        // Both durable twenty-second waits exist before the first wake fires.
        // Their different anchors put their deadlines at t=10 and t=20.
        for seconds in [10, 20] {
            let independent = try replacingExperience(snapshot, experienceId: "deadline-\(seconds)")
            let arm = try XCTUnwrap(independent.profile.armedLegs.first)
            let pin = try XCTUnwrap(independent.profile.releases.first)
            retainedReleases.merge(independent.releasesByDigest) { first, _ in first }
            let admitted = try await journal.admit(arm: arm, release: pin,
                executionSnapshot: .init(delivery: snapshot.profile.delivery, assignments: snapshot.profile.facts.assignments),
                reentry: .init(type: .everyMatch, window: nil), entryStepId: "wait",
                at: launch.addingTimeInterval(TimeInterval(seconds - 20)))
            let run = try XCTUnwrap(admitted)

            try await journal.transition(run.id, stepId: "wait", context: run.context,
                checkpoint: .init(anchorAtMillis: 1_000_000 + Int64(seconds - 20) * 1000,
                                  wakeAtMillis: 1_000_000 + Int64(seconds) * 1000))
        }
        let clock = MockDateProvider(initialDate: launch)
        let sleeper = MockSleepProvider()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = EventLog(identity: identity, dateProvider: clock, apiClient: MockNuxieApi(), store: MockEventStore())
        let secondWakeScheduled = expectation(description: "The t=20 wake schedules again after enqueueing its deadline")
        secondWakeScheduled.assertForOverFulfill = false
        let pinned = retainedReleases
        let service = JourneyService(identity: identity, events: events, dateProvider: clock, sleepProvider: sleeper,
            journalDirectory: directory, featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            readJournalRuns: { journal in
                let runs = try await journal.runs()
                if clock.now() == launch.addingTimeInterval(20) { secondWakeScheduled.fulfill() }
                return runs
            }, pinnedReleaseAuthenticator: { _, reference in
                guard let retained = pinned[reference.descriptorSha256] else { throw JourneyExecutionError.invalidState }
                return retained
            },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed))
        let observed = JourneyTimedRouteObservation()
        await events.subscribeCommitted { event in
            if event.name == "later" { await observed.append("event25") }
            _ = await service.handleStoredEvent(event)
        }
        await service.prepareForEvents()
        let configuration = NuxieConfiguration(apiKey: "successive-deadline-wakes-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await events.configure(configuration: configuration)
        await service.initialize()
        await events.drain()
        await events.setJourneyDeadlineHandler { [weak service] deadline in
            await observed.append(deadline.wakeAt == launch.addingTimeInterval(10) ? "deadline10" : "deadline20")
            return await service?.handleJourneyDeadline(deadline) ?? .done
        }
        let hold = await events.deferCommittedRouting()
        for _ in 0..<200 where !sleeper.pendingSleepDurations.contains(10) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(sleeper.pendingSleepDurations.contains(10))
        clock.advance(by: 10)
        sleeper.completeSleeps(withDuration: 10)
        // The first deadline is still held. Its delivery cannot be required
        // to arm the next ten-second sleep for the second park.
        for _ in 0..<200 where !sleeper.pendingSleepDurations.contains(10) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(sleeper.pendingSleepDurations.contains(10), "Schedule t=20 while t=10 remains undelivered")
        clock.advance(by: 10)
        sleeper.completeSleeps(withDuration: 10)
        await fulfillment(of: [secondWakeScheduled], timeout: 3)
        clock.advance(by: 5)
        events.track("later")
        _ = await events.flushEvents()
        let held = await observed.values
        XCTAssertTrue(held.isEmpty)
        clock.advance(by: 5)
        let released = await events.releaseCommittedRouting(ifGeneration: hold)
        XCTAssertTrue(released)
        await events.drain()
        let order = await observed.values
        XCTAssertEqual(order, ["deadline10", "deadline20", "event25"])
        await service.shutdown()
        await events.close()
    }

    func testNativeRestorationRetryRunsInBackgroundOnlyForScreenlessWaits() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseNativeRestorationRetryRunsInBackgroundOnlyForScreenlessWaits() }
    }

    private func exerciseNativeRestorationRetryRunsInBackgroundOnlyForScreenlessWaits() async throws {
        for hasScreens in [false, true] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let preparation = FailableJourneyRead()
            await preparation.setFailing(true)
            let live = try await liveTimedWait(directory: directory,
                step: Self.waitSteps(eventName: "go", maxTimeMillis: 10_000)[0],
                prepareNativeValues: { _, _, _, _ in try await preparation.attempt() },
                screens: hasScreens ? [Self.backgroundScreen] : [])
            live.events.track("start_waiting")
            await live.events.drain()
            let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
            let initial = try await journal.runs()
            let park = try XCTUnwrap(initial.first?.park)
            XCTAssertEqual(park.wakeAt, Date(timeIntervalSince1970: 1010))
            XCTAssertFalse(live.sleeper.pendingSleepDurations.contains(5), "Restoration has no separate sleeper")
            let nativeRetry = await live.events.queuedJourneyRetryKeys()
            XCTAssertEqual(nativeRetry.filter { $0.id.hasPrefix("native:") }.count, 1, "One failed preparation has one queue entry and one retry owner")
            await live.service.onAppDidEnterBackground()
            let before = await preparation.attempts
            await preparation.setFailing(false)
            if hasScreens {
                // Let the queue interval elapse without driving a native timer.
                try await Task.sleep(nanoseconds: 1_200_000_000)
                let backgroundAttempts = await preparation.attempts
                XCTAssertEqual(backgroundAttempts, before, "The background gate precedes native preparation")
            } else {
                for _ in 0..<300 {
                    if await preparation.attempts > before { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                let after = await preparation.attempts
                XCTAssertGreaterThan(after, before, "The queue restores screenless work in the background")
            }
            XCTAssertEqual(completions(in: live.store), [])
            let restored = try await journal.runs()
            XCTAssertEqual(restored.first?.park, park)
            for _ in 0..<200 where !live.sleeper.pendingSleepDurations.contains(10) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(live.sleeper.pendingSleepDurations, [10], "Only the authored deadline uses the mock sleeper")
            live.clock.advance(by: 10)
            live.sleeper.completeSleeps(withDuration: 10)
            if hasScreens {
                await live.events.drain()
                XCTAssertEqual(completions(in: live.store), [])
                await live.service.onAppBecameActive()
            }
            // Screenless work gets no foreground callback or rescuing event.
            for _ in 0..<200 where completions(in: live.store).isEmpty {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(completions(in: live.store), ["timeout"])
            let finished = await preparation.attempts
            XCTAssertGreaterThan(finished, before)
            await live.service.shutdown()
            await live.events.close()
        }
    }

    func testInitiallyOverdueScreenlessWaitAndDelayCatchUpInBackgroundWhenStartedIsDropped() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseInitiallyOverdueScreenlessWaitAndDelayCatchUpInBackgroundWhenStartedIsDropped() }
    }

    private func exerciseInitiallyOverdueScreenlessWaitAndDelayCatchUpInBackgroundWhenStartedIsDropped() async throws {
        let delay = Journey.Step(kind: .action, id: "delay",
            action: ["type": .string("delay"), "durationMs": .number(500)],
            outlets: ["next": "satisfied"], outcome: nil)
        for step in [Self.waitSteps(eventName: "go", maxTimeMillis: 500)[0], delay] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let live = try await liveTimedWait(directory: directory, step: step,
                beforeJourney: { event, clock in
                    if event.name == "start_waiting" { clock.advance(by: 0.8) }
                }, dropJourneyStarted: true)
            await live.service.onAppDidEnterBackground()
            live.events.track("start_waiting")
            await live.events.drain()
            XCTAssertEqual(starts(in: live.store), 0, "beforeSend drops the otherwise rescuing started event")

            // Parking enqueues immediately, including in the background.
            await live.events.drain()
            XCTAssertEqual(completions(in: live.store), [step.id == "delay" ? "satisfied" : "timeout"])
            await live.service.shutdown()
            await live.events.close()
        }
    }

    func testAnOverdueRunWithScreensKeepsItsCatchUpClosedInBackground() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseAnOverdueRunWithScreensKeepsItsCatchUpClosedInBackground() }
    }

    private func exerciseAnOverdueRunWithScreensKeepsItsCatchUpClosedInBackground() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preparation = JourneyNthRoutedCaptureGate(eventName: "prepare", suspendedCall: 1)
        let live = try await liveTimedWait(directory: directory,
            prepareNativeValues: { _, _, _, _ in await preparation.intercept(event: "prepare") },
            beforeJourney: { event, clock in
                if event.name == "start_waiting" { clock.advance(by: 0.8) }
            }, dropJourneyStarted: true,
            screens: [.init(id: "screen", defaultViewModelName: nil, defaultInstanceId: nil, responseCaptures: [])])
        // Admit in the foreground, then background while initial native
        // preparation is suspended, before the overdue park is saved.
        live.events.track("start_waiting")
        for _ in 0..<200 {
            if await preparation.isSuspended() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let suspended = await preparation.isSuspended()
        XCTAssertTrue(suspended)
        await live.service.onAppDidEnterBackground()
        await preparation.release()
        await live.events.drain()
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        let runs = try await journal.runs()
        XCTAssertEqual(runs.first?.park?.wakeAt, Date(timeIntervalSince1970: 1000.5))
        XCTAssertFalse(live.sleeper.pendingSleepDurations.contains(0))
        XCTAssertEqual(completions(in: live.store), [])

        await live.service.onAppBecameActive()
        // The gated deadline keeps its queue entry; the queue's timer, not the
        // foreground callback, makes its next attempt.
        for _ in 0..<400 where completions(in: live.store).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await live.events.drain()
        XCTAssertEqual(completions(in: live.store), ["timeout"])
        await live.service.shutdown()
        await live.events.close()
    }

    func testFailedFirstCheckpointSaveKeepsTheTriggerPendingUntilRetry() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseFailedFirstCheckpointSaveKeepsTheTriggerPendingUntilRetry() }
    }

    private func exerciseFailedFirstCheckpointSaveKeepsTheTriggerPendingUntilRetry() async throws {
        for step in [Self.waitSteps(eventName: "go", maxTimeMillis: 60_000)[0], Self.delayStep] {
            let directory = temporaryDirectory()
            let writes = JourneyJournalPersistenceFailures()
            let armed = JourneyCompletionFlag()
            let rejected = expectation(description: "The failed \(step.id) checkpoint refuses delivery")
            let accepted = expectation(description: "The shared route timer retries the \(step.id) checkpoint")
            let rejection = JourneyNthRoutedCaptureGate(eventName: "rejection", suspendedCall: 1)
            let deliveries = JourneyDeliveryObservation()
            let live = try await liveTimedWait(directory: directory, step: step,
                prepareNativeValues: { _, _, _, _ in
                    if !armed.isCompleted {
                        writes.failNext(1)
                        armed.finish()
                    }
                }, journalBeforePersist: { try writes.beforePersist() },
                afterJourney: { event, delivered in
                    guard event.name == "start_waiting" else { return }
                    await deliveries.record(delivered)
                    if delivered { accepted.fulfill() }
                    else {
                        rejected.fulfill()
                        await rejection.intercept(event: "rejection")
                    }
                })
            addBoundedJourneyTeardown {
                await rejection.release()
                await live.service.shutdown()
                await live.events.close()
                try? FileManager.default.removeItem(at: directory)
            }
            live.events.track("start_waiting")
            // Observe the refused delivery before releasing its handler, so a
            // slow test runner cannot race the real one-second retry timer.
            await fulfillment(of: [rejected], timeout: 3)
            let firstDeliveries = await deliveries.values
            XCTAssertEqual(firstDeliveries, [false])
            let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
            let initial = try await journal.runs()
            let admitted = try XCTUnwrap(initial.first)
            XCTAssertEqual(initial.count, 1)
            XCTAssertNil(admitted.park)
            XCTAssertTrue(live.store.pendingCommittedRoutes.contains { $0.event.name == "start_waiting" })
            XCTAssertEqual(starts(in: live.store), 1)
            let checkpointRetries = await live.events.queuedJourneyRetryKeys()
            XCTAssertEqual(checkpointRetries.filter { $0.id.hasPrefix("start:") }.count, 1,
                           "The failed first park remains a continuation of the original queued start")
            XCTAssertTrue(live.sleeper.pendingSleepDurations.isEmpty,
                "The refused head must retry without a queued deadline or native-restoration timer")

            // The retry must save the original t=60 checkpoint, not evaluate
            // the wait again at this later clock time or admit another run.
            live.clock.advance(by: 7)
            await rejection.release()
            await fulfillment(of: [accepted], timeout: 5)
            await live.events.drain()
            let retried = try await journal.runs()
            let parked = try XCTUnwrap(retried.first)
            XCTAssertEqual(retried.count, 1)
            XCTAssertEqual(parked.id, admitted.id)
            XCTAssertEqual(parked.park?.anchorAt, Date(timeIntervalSince1970: 1000))
            XCTAssertEqual(parked.park?.wakeAt, Date(timeIntervalSince1970: 1060))
            XCTAssertEqual(starts(in: live.store), 1)
            XCTAssertTrue(live.store.pendingCommittedRoutes.isEmpty)
            let retriedDeliveries = await deliveries.values
            XCTAssertEqual(retriedDeliveries, [false, true])
            for _ in 0..<200 where !live.sleeper.pendingSleepDurations.contains(53) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(live.sleeper.pendingSleepDurations, [53])
            live.clock.advance(by: 53)
            live.sleeper.completeSleeps(withDuration: 53)
            for _ in 0..<200 where completions(in: live.store).isEmpty {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(completions(in: live.store), [step.id == "delay" ? "satisfied" : "timeout"])
            await live.events.drain()
            XCTAssertEqual(starts(in: live.store), 1)
            XCTAssertEqual(completions(in: live.store), [step.id == "delay" ? "satisfied" : "timeout"])
            await live.service.shutdown()
            await live.events.close()
        }
    }

    func testFailedParkAfterAnEventResumesAWaitRetriesTheSelectedCheckpoint() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseFailedParkAfterAnEventResumesAWaitRetriesTheSelectedCheckpoint() }
    }

    private func exerciseFailedParkAfterAnEventResumesAWaitRetriesTheSelectedCheckpoint() async throws {
        let directory = temporaryDirectory()
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        let writes = JourneyJournalPersistenceFailures()
        let armed = JourneyCompletionFlag()
        let rejected = expectation(description: "The event refuses delivery when its next park cannot be saved")
        let accepted = expectation(description: "The event retry saves the next park")
        let rejection = JourneyNthRoutedCaptureGate(eventName: "rejection", suspendedCall: 1)
        var steps = Self.waitSteps(eventName: "go", maxTimeMillis: 60_000)
        steps[0] = .init(kind: .action, id: "wait", action: steps[0].action,
            outlets: ["satisfied": "delay", "timeout": "timeout"], outcome: nil)
        steps.append(Self.delayStep)
        let live = try await liveTimedWait(directory: directory, steps: steps,
            readNativeValues: { values in
                let runs = try await journal.runs()
                if !armed.isCompleted, runs.first?.stepId == "delay", runs.first?.park == nil {
                    writes.failNext(1)
                    armed.finish()
                }
                return try await values.journeyValues()
            }, journalBeforePersist: { try writes.beforePersist() },
            afterJourney: { event, delivered in
                guard event.name == "go" else { return }
                if delivered { accepted.fulfill() }
                else {
                    rejected.fulfill()
                    await rejection.intercept(event: "rejection")
                }
            })
        addBoundedJourneyTeardown {
            await rejection.release()
            await live.service.shutdown()
            await live.events.close()
            try? FileManager.default.removeItem(at: directory)
        }
        live.events.track("start_waiting")
        await live.events.drain()
        let initial = try await journal.runs()
        let admitted = try XCTUnwrap(initial.first)
        XCTAssertNotNil(admitted.park)
        live.clock.advance(by: 1)
        live.events.track("go")
        await fulfillment(of: [rejected], timeout: 3)
        XCTAssertTrue(armed.isCompleted)
        let failed = try await journal.runs()
        XCTAssertEqual(failed.first?.stepId, "delay")
        XCTAssertNil(failed.first?.park)
        XCTAssertTrue(live.store.pendingCommittedRoutes.contains { $0.event.name == "go" })
        let checkpointRetries = await live.events.queuedJourneyRetryKeys()
        XCTAssertEqual(checkpointRetries.filter { $0.id.hasPrefix("input:") }.count, 1,
                       "The later park write stays in its Journey's original event-input entry")
        live.clock.advance(by: 7)
        await rejection.release()
        await fulfillment(of: [accepted], timeout: 5)
        await live.events.drain()
        let retried = try await journal.runs()
        XCTAssertEqual(retried.count, 1)
        XCTAssertEqual(retried.first?.id, admitted.id)
        XCTAssertEqual(retried.first?.park?.anchorAt, Date(timeIntervalSince1970: 1001))
        XCTAssertEqual(retried.first?.park?.wakeAt, Date(timeIntervalSince1970: 1061))
        XCTAssertEqual(starts(in: live.store), 1)
        XCTAssertTrue(live.store.pendingCommittedRoutes.isEmpty)
        for _ in 0..<200 where !live.sleeper.pendingSleepDurations.contains(53) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(live.sleeper.pendingSleepDurations, [53])
        live.clock.advance(by: 53)
        live.sleeper.completeSleeps(withDuration: 53)
        for _ in 0..<200 where completions(in: live.store).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(completions(in: live.store), ["satisfied"])
        await live.events.drain()
        XCTAssertEqual(completions(in: live.store), ["satisfied"])
        await live.service.shutdown()
        await live.events.close()
    }

    func testInitialWaitAndDelaySurviveNativePreparationFailureAndRetryBeforeTheirDeadline() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseInitialWaitAndDelaySurviveNativePreparationFailureAndRetryBeforeTheirDeadline() }
    }

    private func exerciseInitialWaitAndDelaySurviveNativePreparationFailureAndRetryBeforeTheirDeadline() async throws {
        for step in [Self.waitSteps(eventName: "go", maxTimeMillis: 60_000)[0], Self.delayStep] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let preparation = FailableJourneyRead()
            await preparation.setFailing(true)
            let live = try await liveTimedWait(directory: directory, step: step,
                prepareNativeValues: { _, _, _, _ in try await preparation.attempt() },
                beforeJourney: { event, clock in
                    if event.name == "start_waiting" { clock.advance(by: 0.8) }
                })
            live.events.track("start_waiting")
            await live.events.drain()
            let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
            let runs = try await journal.runs()
            let parked = try XCTUnwrap(runs.first)
            let park = try XCTUnwrap(parked.park, "Native failure must not lose the admitted run's recovery cursor")
            XCTAssertEqual(parked.stepId, step.id)
            XCTAssertEqual(park.anchorAt, Date(timeIntervalSince1970: 1000))
            XCTAssertEqual(park.wakeAt, Date(timeIntervalSince1970: 1060))

            XCTAssertTrue(live.store.pendingCommittedRoutes.isEmpty)
            let recovered = try await journal.recover(at: live.clock.now())
            XCTAssertEqual(recovered.first?.park, park)


            let attemptsBeforeRetry = await preparation.attempts
            XCTAssertGreaterThan(attemptsBeforeRetry, 0)
            XCTAssertFalse(live.sleeper.pendingSleepDurations.contains(5), "The queue owns restoration backoff")
            await preparation.setFailing(false)
            for _ in 0..<300 {
                if await preparation.attempts > attemptsBeforeRetry { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            for _ in 0..<200 where !live.sleeper.pendingSleepDurations.contains(where: { abs($0 - 59.2) < 0.001 }) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(live.sleeper.pendingSleepDurations.contains { abs($0 - 59.2) < 0.001 })
            let attemptsAfterRetry = await preparation.attempts
            XCTAssertGreaterThan(attemptsAfterRetry, attemptsBeforeRetry)
            let retried = try await journal.runs().first
            XCTAssertEqual(retried?.park, park)
            XCTAssertEqual(starts(in: live.store), 1)
            // Let the retried restoration's own pass finish under the old
            // clock, so the deadline cannot be queued ahead of the event.
            await live.events.drain()

            live.clock.setCurrentDate(Date(timeIntervalSince1970: 1060.8))
            if step.id == "wait" {
                await live.service.handleStoredEvent(Self.event("go", at: Date(timeIntervalSince1970: 1000.1)))
            } else {
                live.sleeper.completeAllSleeps()
            }
            for _ in 0..<300 where completions(in: live.store).isEmpty {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            await live.events.drain()
            XCTAssertEqual(completions(in: live.store), ["satisfied"])
            await live.service.shutdown()
            await live.events.close()
        }
    }

    func testSavedMatchingEventRetriesFailedForegroundResumeBeforeItsDeadline() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseSavedMatchingEventRetriesFailedForegroundResumeBeforeItsDeadline() }
    }

    private func exerciseSavedMatchingEventRetriesFailedForegroundResumeBeforeItsDeadline() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = JourneyJournalPersistenceFailures()
        let failedWrite = JourneyCompletionFlag()
        let retryRead = JourneyNthRoutedCaptureGate(eventName: "saved-resume", suspendedCall: 1)
        let completed = expectation(description: "The saved match resumes on the shared route retry timer")
        let live = try await liveTimedWait(directory: directory,
            step: Self.waitSteps(eventName: "go", maxTimeMillis: 60_000)[0],
            readNativeValues: { values in
                if failedWrite.isCompleted { await retryRead.intercept(event: "saved-resume") }
                return try await values.journeyValues()
            }, journalBeforePersist: {
                do { try writes.beforePersist() }
                catch { failedWrite.finish(); throw error }
            },
            afterJourney: { event, _ in
                if event.name == JourneyEvents.journeyCompleted { completed.fulfill() }
            }, screens: [Self.backgroundScreen])
        live.events.track("start_waiting")
        await live.events.drain()
        await live.service.onAppDidEnterBackground()
        live.clock.advance(by: 0.1)
        live.events.track("go")
        await live.events.drain()
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        let savedRuns = try await journal.runs()
        let saved = try XCTUnwrap(savedRuns.first)
        let retainedInput = try await journal.loggedInput(named: "go")
            XCTAssertEqual(retainedInput?.name, "go")
        XCTAssertTrue(live.store.pendingCommittedRoutes.isEmpty,
                      "EventLog has acknowledged the match; event delivery cannot rescue the park")
        let deadlines = JourneyDeadlineRecorder()
        let service = live.service
        await live.events.setJourneyDeadlineHandler { [weak service] deadline in
            await deadlines.append(deadline)
            return await service?.handleJourneyDeadline(deadline) ?? .done
        }
        // Wait consumption and the next cursor are one transaction. Fail that
        // command so the committed park and its log match remain retryable.
        writes.failNext(1)
        await live.service.onAppBecameActive()
        XCTAssertTrue(failedWrite.isCompleted)
        let savedInputRetries = await live.events.queuedJourneyRetryKeys()
        XCTAssertEqual(savedInputRetries.filter { $0.id.hasPrefix("resume:") }.count, 1)
        let retained = try await journal.runs()
        XCTAssertEqual(retained.first?.park, saved.park)
        XCTAssertEqual(completions(in: live.store), [])
        XCTAssertFalse(live.sleeper.pendingSleepDurations.contains { $0 <= 1 },
                       "No retry is armed through the deadline sleeper")

        // The gate keeps the failed-state assertions stable if this task is
        // descheduled for longer than the timer's interval on a busy machine.
        await retryRead.release()
        // No new capture, lifecycle callback, mock sleep completion, or clock
        // advance: the same real one-second timer used for refused heads retries.
        await fulfillment(of: [completed], timeout: 5)
        await live.events.drain()
        XCTAssertEqual(completions(in: live.store), ["satisfied"])
        XCTAssertEqual(live.clock.now(), Date(timeIntervalSince1970: 1000.1))
        XCTAssertGreaterThan(try XCTUnwrap(saved.park?.wakeAt), live.clock.now())
        let deliveredDeadlines = await deadlines.values
        XCTAssertTrue(deliveredDeadlines.isEmpty, "The original deadline must not rescue the saved match")
        live.clock.advance(by: 60)
        live.sleeper.completeAllSleeps()
        await live.events.drain()
        let lateDeadlines = await deadlines.values
        XCTAssertTrue(lateDeadlines.isEmpty, "Completing the saved match cancels its deadline")
        XCTAssertEqual(completions(in: live.store), ["satisfied"])
        await live.service.shutdown()
        await live.events.close()
    }

    func testFailedJournalInspectionRetriesWithoutAnyParkedRunOrDeadline() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseFailedJournalInspectionRetriesWithoutAnyParkedRunOrDeadline() }
    }

    private func exerciseFailedJournalInspectionRetriesWithoutAnyParkedRunOrDeadline() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inspection = FailableJourneyRead()
        let headDeliveries = JourneyDeliveryObservation()
        let laterDeliveries = JourneyDeliveryObservation()
        let retries = expectation(description: "The failed head is attempted repeatedly without a deadline")
        retries.expectedFulfillmentCount = 3
        let laterDelivered = expectation(description: "The later event routes after the head recovers")
        let live = try await liveTimedWait(directory: directory,
            readJournalRuns: { journal in
                try await inspection.attempt()
                return try await journal.runs()
            }, afterJourney: { event, accepted in
                if event.name == "ordinary" {
                    await headDeliveries.record(accepted)
                    let attempts = await headDeliveries.values.count
                    if !accepted, attempts <= 3 { retries.fulfill() }
                } else if event.name == "later" {
                    await laterDeliveries.record(accepted)
                    laterDelivered.fulfill()
                }
            })
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        let initial = try await journal.runs()
        XCTAssertTrue(initial.isEmpty)
        await inspection.setFailing(true)
        live.events.track("ordinary")
        live.events.track("later")
        await live.events.drain()
        await fulfillment(of: [retries], timeout: 5)
        let refused = await headDeliveries.values
        let blocked = await laterDeliveries.values
        XCTAssertGreaterThanOrEqual(refused.count, 3)
        XCTAssertTrue(refused.allSatisfy { !$0 })
        XCTAssertTrue(blocked.isEmpty, "Later captures must not pass the refused event")
        XCTAssertEqual(live.store.pendingCommittedRoutes.map(\.event.name), ["ordinary", "later"])

        // No replay request, new capture, foreground callback, or Journey timer
        // rescues this head. The same route timer keeps trying until it works.
        await inspection.setFailing(false)
        await fulfillment(of: [laterDelivered], timeout: 5)
        await live.events.drain()
        let recovered = await headDeliveries.values
        let followed = await laterDeliveries.values
        XCTAssertEqual(recovered.last, true)
        XCTAssertEqual(followed, [true])
        XCTAssertTrue(live.store.pendingCommittedRoutes.isEmpty)
        let remaining = try await journal.runs()
        XCTAssertTrue(remaining.isEmpty, "Neither event creates a timed run")
        await live.service.shutdown()
        await live.events.close()
    }

    func testFailedJournalInspectionKeepsAnInWindowFollowUpReplayable() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseFailedJournalInspectionKeepsAnInWindowFollowUpReplayable() }
    }

    private func exerciseFailedJournalInspectionKeepsAnInWindowFollowUpReplayable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inspection = FailableJourneyRead()
        let deliveries = JourneyDeliveryObservation()
        let live = try await liveTimedWait(directory: directory,
            readJournalRuns: { journal in
                try await inspection.attempt()
                return try await journal.runs()
            }, afterJourney: { event, accepted in
                if event.id == "replayable-follow-up" { await deliveries.record(accepted) }
            })
        live.events.track("start_waiting")
        await live.events.drain()
        live.clock.advance(by: 0.1)
        await inspection.setFailing(true)
        _ = await live.events.captureAndRouteSystemEvent(.init(name: "go", properties: nil,
            eventId: "replayable-follow-up", distinctId: "customer"))
        await live.events.drain()

        let failedDeliveries = await deliveries.values
        XCTAssertFalse(failedDeliveries.isEmpty)
        XCTAssertTrue(failedDeliveries.allSatisfy { !$0 })
        XCTAssertTrue(live.store.pendingCommittedRoutes.contains { $0.event.id == "replayable-follow-up" })
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        let parked = try await journal.runs().first
        XCTAssertNotNil(parked?.park)
        XCTAssertNotNil(parked?.park)

        await inspection.setFailing(false)
        live.clock.advance(by: 0.7)
        // The durable route is replayed after the deadline, retaining its
        // captured time inside the original wait's window.
        let replayed = await live.events.replayPendingStableRoutes(distinctId: "customer")
        XCTAssertTrue(replayed)
        for _ in 0..<500 where completions(in: live.store).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await live.events.drain()
        let recoveredDeliveries = await deliveries.values
        XCTAssertEqual(recoveredDeliveries.last, true)
        XCTAssertTrue(recoveredDeliveries.dropLast().allSatisfy { !$0 })
        XCTAssertTrue(live.store.pendingCommittedRoutes.isEmpty)
        XCTAssertFalse(live.store.pendingStableRouteIds.contains("replayable-follow-up"))
        XCTAssertEqual(completions(in: live.store), ["satisfied"])
        await live.service.shutdown()
        await live.events.close()
    }

    func testEmptyRoutingHoldRetainsDeadlineUntilRelease() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseEmptyRoutingHoldRetainsDeadlineUntilRelease() }
    }

    private func exerciseEmptyRoutingHoldRetainsDeadlineUntilRelease() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = try await liveTimedWait(directory: directory)
        live.events.track("start_waiting")
        await live.events.drain()
        let routing: any EventLogProtocol = live.events
        let generation = await routing.deferCommittedRouting()
        live.clock.advance(by: 1)
        await live.service.onAppBecameActive()
        XCTAssertEqual(completions(in: live.store), [], "The empty hold must block the expired wait")

        // Release delivers the queued deadline with no later app activity.
        let released = await routing.releaseCommittedRouting(ifGeneration: generation)
        XCTAssertTrue(released)
        await live.events.drain()
        XCTAssertEqual(completions(in: live.store), ["timeout"])
        await live.service.shutdown()
        await live.events.close()
    }

    func testExpiredScreenlessWaitAndDelayAdvanceOnTheNextBackgroundEvent() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseExpiredScreenlessWaitAndDelayAdvanceOnTheNextBackgroundEvent() }
    }

    private func exerciseExpiredScreenlessWaitAndDelayAdvanceOnTheNextBackgroundEvent() async throws {
        let delay = Journey.Step(kind: .action, id: "delay",
            action: ["type": .string("delay"), "durationMs": .number(500)],
            outlets: ["next": "satisfied"], outcome: nil)
        for step in [Self.waitSteps(eventName: "go", maxTimeMillis: 500)[0], delay] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let live = try await liveTimedWait(directory: directory, step: step)
            live.events.track("start_waiting")
            await live.events.drain()
            await live.service.onAppDidEnterBackground()
            live.clock.advance(by: 2)

            live.events.track("background_tick")
            await live.events.drain()
            await live.events.drain()

            XCTAssertEqual(completions(in: live.store), [step.id == "delay" ? "satisfied" : "timeout"],
                           "A screenless checkpoint must advance without foregrounding")
            await live.service.shutdown()
            await live.events.close()
        }
    }

    func testFutureScreenlessDeadlineEnqueuesAndRunsInBackgroundWithoutAnotherEvent() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseFutureScreenlessDeadlineEnqueuesAndRunsInBackgroundWithoutAnotherEvent() }
    }

    private func exerciseFutureScreenlessDeadlineEnqueuesAndRunsInBackgroundWithoutAnotherEvent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = try await liveTimedWait(directory: directory, dropJourneyStarted: true)
        live.events.track("start_waiting")
        await live.events.drain()
        await live.service.onAppDidEnterBackground()
        for _ in 0..<200 where !live.sleeper.pendingSleepDurations.contains(0.5) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(live.sleeper.pendingSleepDurations.contains(0.5))
        live.clock.advance(by: 0.5)
        live.sleeper.completeSleeps(withDuration: 0.5)
        for _ in 0..<200 where completions(in: live.store).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(completions(in: live.store), ["timeout"])
        await live.service.shutdown()
        await live.events.close()
    }

    func testDeadlineHandlingRetriesJournalReadAndPersistenceFailures() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseDeadlineHandlingRetriesJournalReadAndPersistenceFailures() }
    }

    private func exerciseDeadlineHandlingRetriesJournalReadAndPersistenceFailures() async throws {
        for failure in ["read", "write", "native"] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let inspection = FailableJourneyRead()
            let nativeReads = FailableJourneyRead()
            let deadlineDeliveries = JourneyDeliveryObservation()
            let armed = JourneyCompletionFlag()
            let failedWrite = JourneyCompletionFlag()
            let live = try await liveTimedWait(directory: directory, readNativeValues: { values in
                try await nativeReads.attempt()
                return try await values.journeyValues()
            }, readJournalRuns: { journal in
                try await inspection.attempt()
                return try await journal.runs()
            }, journalBeforePersist: {
                if failure == "write", armed.isCompleted, !failedWrite.isCompleted {
                    failedWrite.finish()
                    throw JourneyExecutionError.invalidState
                }
            })
            live.events.track("start_waiting")
            await live.events.drain()
            let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
            let parkedRuns = try await journal.runs()
            let run = try XCTUnwrap(parkedRuns.first)
            let deadline = try XCTUnwrap(Self.deadline(run))
            let service = live.service
            await live.events.setJourneyDeadlineHandler { [weak service] deadline in
                let accepted = await service?.handleJourneyDeadline(deadline) ?? .done
                if case .done = accepted { await deadlineDeliveries.record(true) }
                else { await deadlineDeliveries.record(false) }
                return accepted
            }
            // Queue a known checkpoint so scheduling cannot consume the injected
            // failure before the deadline handler reaches its journal boundary.
            if failure == "read" { await inspection.setFailing(true) }
            if failure == "native" { await nativeReads.setFailing(true) }
            armed.finish()
            live.clock.advance(by: 1)
            await live.events.enqueueJourneyDeadline(deadline)
            await live.events.drain()
            XCTAssertEqual(completions(in: live.store), [])
            let retained = try await journal.runs().first
            XCTAssertEqual(retained?.park, run.park)
            if failure == "write" { XCTAssertTrue(failedWrite.isCompleted) }
            let accepted = await deadlineDeliveries.values
            XCTAssertEqual(accepted, [false], "A failed deadline keeps its queue entry")
            let buffered = await live.events.bufferedCommittedRouteCount
            XCTAssertEqual(buffered, 0, "Deadline operations do not become analytics events")
            await inspection.setFailing(false)
            await nativeReads.setFailing(false)
            // No mock sleep or clock advance rescues this operation.
            for _ in 0..<400 where completions(in: live.store).isEmpty {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let retried = await deadlineDeliveries.values
            XCTAssertEqual(retried, [false, true], "The same retained deadline is retried by the queue")
            XCTAssertEqual(completions(in: live.store), ["timeout"])
            await live.service.shutdown()
            await live.events.close()
        }
    }

    func testBackgroundRenderedDeadlineSkipsFailingNativeReadsAndLetsLaterEventsThrough() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseBackgroundRenderedDeadlineSkipsFailingNativeReadsAndLetsLaterEventsThrough() }
    }

    private func exerciseBackgroundRenderedDeadlineSkipsFailingNativeReadsAndLetsLaterEventsThrough() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reads = FailableJourneyRead()
        let deliveries = JourneyDeliveryObservation()
        let live = try await liveTimedWait(directory: directory, readNativeValues: { values in
            try await reads.attempt()
            return try await values.journeyValues()
        }, beforeJourney: { event, clock in
            if event.name == "start_screenless" { clock.advance(by: 1) }
        }, afterJourney: { event, accepted in
            if event.name == "unrelated" { await deliveries.record(accepted) }
        }, screens: [Self.backgroundScreen])
        live.events.track("start_waiting")
        await live.events.drain()
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        let runs = try await journal.runs()
        let deadline = try XCTUnwrap(runs.first.flatMap(Self.deadline))
        await live.service.onAppDidEnterBackground()
        let before = await reads.attempts
        await reads.setFailing(true)
        live.clock.advance(by: 1)
        await live.events.enqueueJourneyDeadline(deadline)
        await live.events.drain()
        let after = await reads.attempts
        XCTAssertEqual(after, before, "The background deadline gate precedes native restoration")
        // Ordinary background events keep main's pending/candidate behavior.
        live.events.track("unrelated")
        await live.events.drain()
        let handled = await deliveries.values
        XCTAssertEqual(handled, [true], "A failed Journey operation holds only its own relevant inputs")
        XCTAssertTrue(live.store.pendingCommittedRoutes.isEmpty)
        await reads.setFailing(false)
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let screenless = try replacingExperience(replacing(try await authenticatedSnapshot(fixture), entry: Self.eventEntry("start_screenless"),
            reentry: .init(type: .everyMatch, window: nil), completionOutputs: Self.heldWaitOutcomes,
            entryStepId: "wait", steps: Self.waitSteps(eventName: "go", maxTimeMillis: 500), routes: [], screens: []), experienceId: "screenless-experience")
        await live.service.profileDidCommit(screenless, distinctId: "customer")
        live.events.track("start_screenless")
        await live.events.drain()
        await live.events.drain()
        XCTAssertEqual(completions(in: live.store), ["timeout"],
                       "An unrelated screenless Journey must still start and finish in the background")
        let parked = try await journal.runs().first
        XCTAssertNotNil(parked?.park)
        await live.service.onAppBecameActive()
        for _ in 0..<400 where completions(in: live.store).count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await live.events.drain()
        XCTAssertEqual(completions(in: live.store), ["timeout", "timeout"],
                       "The retained rendered operation succeeds after foreground admission opens")
        await live.service.shutdown()
        await live.events.close()
    }

    func testRecoveryFailureClearsEnqueuedDeadlinesBeforeTheJournalReopens() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseRecoveryFailureClearsEnqueuedDeadlinesBeforeTheJournalReopens() }
    }

    private func exerciseRecoveryFailureClearsEnqueuedDeadlinesBeforeTheJournalReopens() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = replacing(try await authenticatedSnapshot(fixture), entry: Self.eventEntry("start_waiting"),
            reentry: .init(type: .everyMatch, window: nil), completionOutputs: Self.heldWaitOutcomes,
            entryStepId: "wait", steps: Self.waitSteps(eventName: "go", maxTimeMillis: 500), routes: [], screens: [])
        let clock = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1000))
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let queued = JourneyDeadlineRecorder()
        let service = makeService(identity: identity, events: events, directory: directory, dateProvider: clock,
            pinnedReleaseAuthenticator: { _, reference in
                guard let retained = snapshot.releasesByDigest[reference.descriptorSha256] else { throw JourneyExecutionError.invalidState }
                return retained
            })
        let routing: any EventLogProtocol = events
        events.replayPendingRoutesHandler = {
            await routing.setJourneyDeadlineHandler { deadline in await queued.append(deadline); return .done }
            await service.handleStoredEvent(Self.event("start_waiting", at: clock.now().addingTimeInterval(-1)))
            // Let the deadline inspection queued by the park run under this journal.
            await events.drain()
            return false
        }
        await service.prepareForEvents()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await service.initialize()
        await events.drain()
        let first = await queued.values
        XCTAssertEqual(first.count, 1)
        // Reopen the same checkpoint without delivering the old queue entry.
        events.replayPendingRoutesHandler = { true }
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await events.drain()
        let reopened = await queued.values
        // Layer 3 replaces this enqueue-count observation with a durable wait question.
        XCTAssertEqual(reopened.count, 2, "The marker belongs to the dropped journal instance")
        let deadline = try XCTUnwrap(reopened.last)
        _ = await service.handleJourneyDeadline(deadline)
        XCTAssertEqual(completions(in: events), ["timeout"])
        await service.shutdown()
    }

    private static let backgroundScreen = Journey.Screen(id: "screen", defaultViewModelName: nil,
        defaultInstanceId: nil, responseCaptures: [])

    func testStaleDeadlineForMovedOnCheckpointIsDropped() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseStaleDeadlineForMovedOnCheckpointIsDropped() }
    }

    private func exerciseStaleDeadlineForMovedOnCheckpointIsDropped() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        var steps = Self.waitSteps(eventName: "go", maxTimeMillis: 500)
        steps[0] = .init(kind: .action, id: "wait", action: steps[0].action,
                         outlets: ["satisfied": "second_wait", "timeout": "timeout"], outcome: nil)
        let second = Self.waitSteps(eventName: "finish", maxTimeMillis: 2000)[0]
        steps.append(.init(kind: .action, id: "second_wait", action: second.action,
                           outlets: second.outlets, outcome: nil))
        let snapshot = replacing(try await authenticatedSnapshot(fixture), entry: Self.eventEntry("start_waiting"),
            reentry: .init(type: .everyMatch, window: nil), completionOutputs: Self.heldWaitOutcomes,
            entryStepId: "wait", steps: steps, routes: [], screens: [])
        let clock = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1000))
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        let service = makeService(identity: identity, events: events, directory: directory, dateProvider: clock)
        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await service.handleStoredEvent(Self.event("start_waiting", at: clock.now()))
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        let originalRuns = try await journal.runs()
        let original = try XCTUnwrap(originalRuns.first)
        let stale = try XCTUnwrap(Self.deadline(original))
        clock.advance(by: 0.25)
        await service.handleStoredEvent(Self.event("go", at: clock.now()))
        clock.advance(by: 0.5)
        let handled = await service.handleJourneyDeadline(stale)
        if case .done = handled {} else { XCTFail("A stale deadline is already complete") }
        let current = try await journal.runs().first
        XCTAssertEqual(current?.stepId, "second_wait")
        XCTAssertNotNil(current?.park)
        XCTAssertEqual(completions(in: events), [])
        clock.advance(by: 2)
        let next = try XCTUnwrap(current.flatMap(Self.deadline))
        let timedOut = await service.handleJourneyDeadline(next)
        if case .done = timedOut {} else { XCTFail("The next deadline completes normally") }
        XCTAssertEqual(completions(in: events), ["timeout"])
        await service.shutdown()
    }

    func testRestartRecreatesDueDeadlinesAfterRecoveryReplay() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseRestartRecreatesDueDeadlinesAfterRecoveryReplay() }
    }

    private func exerciseRestartRecreatesDueDeadlinesAfterRecoveryReplay() async throws {
        for hasFollowUp in [true, false] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = try JourneyPlaneProfileTestFixture.load()
            let snapshot = replacing(try await authenticatedSnapshot(fixture), entry: Self.eventEntry("start_waiting"),
                reentry: .init(type: .everyMatch, window: nil), completionOutputs: Self.heldWaitOutcomes,
                entryStepId: "wait", steps: Self.waitSteps(eventName: "go", maxTimeMillis: 500), routes: [], screens: [])
            let release = try XCTUnwrap(snapshot.releasesByDigest.values.first)
            let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
            let eventAt = Date(timeIntervalSince1970: 1000)
            let run = try await admitRun(snapshot, journal: journal, at: eventAt)
            var coordinator = try makeCoordinator(run, snapshot: snapshot, journal: journal, startingEventAt: eventAt)
            guard case .park(let park) = try await coordinator.command(at: eventAt) else { return XCTFail("Expected wait") }
            let identity = MockIdentityService()
            identity.setDistinctId("customer")
            let fence = JourneyProfileFence()
            let admission = JourneyCommitAdmission.executionOnly(identity: identity,
                executionFence: fence, executionFenceToken: fence.token())
            try await coordinator.commit(park, snapshot: nil, admission: admission)

            // Simulate the process exiting with a durable park and an optional
            // retained event receipt. Deadline controls themselves have no row.
            let eventDirectory = directory
            let originalStore = SQLiteEventStore()
            try await originalStore.initialize(path: eventDirectory)
            try await originalStore.bindConversionAuthority(.testFixture)
            if hasFollowUp {
                let event = try StoredEvent(id: "recovered-go", name: "go", properties: [:],
                    timestamp: eventAt.addingTimeInterval(0.1), distinctId: "customer")
                _ = try await originalStore.commitStableCaptureAndStageRoute(eventId: event.id,
                    event: event, recordedAt: event.timestamp, assigningCommitSequence: true,
                    admission: nil, routeAdmission: nil)
            }
            await originalStore.close()

            let clock = MockDateProvider(initialDate: eventAt.addingTimeInterval(1))
            let store = SQLiteEventStore()
            let events = EventLog(identity: identity, dateProvider: clock, apiClient: MockNuxieApi(), store: store)
            let service = JourneyService(identity: identity, events: events, dateProvider: clock,
                sleepProvider: MockSleepProvider(), journalDirectory: directory,
                featureAccess: { _ in nil }, dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
                pinnedReleaseAuthenticator: { _, _ in release },
                timezones: try XCTUnwrap(SignedTimezoneBundle.installed))
            let reservation = events.reserveCommittedAdmission { service.eventAdmissionGeneration() }
            await events.subscribeAcknowledgingCommitted(reservation: reservation) { event, generation in
                await service.handleStoredEvent(event, admittedProfileGeneration: generation)
            }
            await service.prepareForEvents()
            let configuration = NuxieConfiguration(apiKey: "deadline-restart-test")
            configuration.testingOverrides.customStoragePath = eventDirectory
            configuration.testingOverrides.suppressBackgroundWork = true
            try await events.configure(configuration: configuration)
            await service.initialize()
            await events.drain()
            await events.drain()
            let history = await events.getEventsForUser("customer", limit: 100)
            let outcomes = history.filter { $0.name == JourneyEvents.journeyCompleted }
                .compactMap { $0.getPropertiesDict()["outcome"] as? String }
            XCTAssertEqual(outcomes, [hasFollowUp ? "satisfied" : "timeout"])
            let remaining = try await store.queryPendingStableRoutes(distinctId: "customer", limit: 100)
            XCTAssertTrue(remaining.isEmpty)
            await service.shutdown()
            await events.close()
        }
    }

    private static func deadline(_ run: JourneyRun) -> JourneyDeadline? {
        guard let park = run.park, let wakeAt = park.wakeAt else { return nil }
        return .init(distinctId: "customer", runId: run.id, stepId: run.stepId,
                     anchorAt: park.anchorAt, wakeAt: wakeAt)
    }

    func testQueuedLiveEventTimeoutVectors() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseQueuedLiveEventTimeoutVectors() }
    }

    private func exerciseQueuedLiveEventTimeoutVectors() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/sdk/committed-event-timeout-order.json")
        let vectors = try JSONDecoder().decode(QueuedEventTimeoutVectors.self, from: Data(contentsOf: url))
        XCTAssertEqual(Double(vectors.stagingBoundMillis), CustomerInputWatermark.stagingBound * 1000)
        let livePreparation = vectors.cases.filter { $0.kind == "live_preparation" }
        XCTAssertEqual(livePreparation.count, 2)
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let base = try await authenticatedSnapshot(fixture)
        let launch = Date(timeIntervalSince1970: 1_000_000)
        for vector in livePreparation {
            let handledAtMillis = try XCTUnwrap(vector.trigger.handledAtMillis)
            let preparationFinishesAtMillis = try XCTUnwrap(vector.preparationFinishesAtMillis)
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let clock = MockDateProvider(initialDate: launch)
            let sleeper = MockSleepProvider()
            let preparation = JourneyNthRoutedCaptureGate(eventName: "prepare", suspendedCall: 1)
            let preparing = expectation(description: "\(vector.name): wait preparation started")
            let triggerHandled = expectation(description: "\(vector.name): trigger handled")
            let followUpHandled = vector.followUp.map { _ in
                expectation(description: "\(vector.name): queued follow-up handled")
            }
            let identity = MockIdentityService()
            identity.setDistinctId("customer")
            let store = MockEventStore()
            let events = EventLog(identity: identity, dateProvider: clock,
                                  apiClient: MockNuxieApi(), store: store)
            let service = JourneyService(
                identity: identity, events: events, dateProvider: clock, sleepProvider: sleeper,
                journalDirectory: directory, storageScope: .testFixture, featureAccess: { _ in nil },
                dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
                prepareNativeValues: { _, _, _, _ in
                    if await preparation.observationCount() == 0 { preparing.fulfill() }
                    await preparation.intercept(event: "prepare")
                },
                pinnedReleaseAuthenticator: { _, _ in throw JourneyExecutionError.invalidState },
                timezones: try XCTUnwrap(SignedTimezoneBundle.installed)
            )
            let reservation = events.reserveCommittedAdmission { service.eventAdmissionGeneration() }
            await events.subscribeAcknowledgingCommitted(reservation: reservation) { event, generation in
                if event.name == vector.trigger.name {
                    clock.setCurrentDate(launch.addingTimeInterval(Double(handledAtMillis) / 1000))
                }
                let acknowledged = await service.handleStoredEvent(event, admittedProfileGeneration: generation)
                if event.name == vector.trigger.name {
                    // The queued deadline cannot overtake this subscriber
                    // or the follow-up already committed behind it.
                    await service.onAppBecameActive()
                    if vector.followUp != nil {
                        XCTAssertTrue(store.storedEvents.filter {
                            $0.name == JourneyEvents.journeyCompleted
                        }.isEmpty, "\(vector.name): the in-window follow-up is still pending")
                    }
                    if acknowledged { triggerHandled.fulfill() }
                } else if event.name == vector.followUp?.name, acknowledged {
                    followUpHandled?.fulfill()
                }
                return acknowledged
            }
            await service.prepareForEvents()
            let configuration = NuxieConfiguration(apiKey: "queued-live-event-timeout-test")
            configuration.testingOverrides.suppressBackgroundWork = true
            let triggerTime = launch.addingTimeInterval(Double(vector.trigger.atMillis) / 1000)
            let eventTimes: [String: Date]
            if let followUp = vector.followUp {
                eventTimes = [vector.trigger.name: triggerTime,
                    followUp.name: launch.addingTimeInterval(Double(followUp.atMillis) / 1000)]
            } else {
                eventTimes = [vector.trigger.name: triggerTime]
            }
            configuration.beforeSend = { event in
                guard let timestamp = eventTimes[event.name] else { return event }
                return NuxieEvent(id: event.id, name: event.name, distinctId: event.distinctId,
                                  properties: event.properties, timestamp: timestamp)
            }
            try await events.configure(configuration: configuration)
            await service.initialize()
            let snapshot = replacing(base, entry: Self.eventEntry(vector.trigger.name),
                reentry: .init(type: .everyMatch, window: nil), completionOutputs: Self.heldWaitOutcomes,
                entryStepId: "wait",
                steps: Self.waitSteps(eventName: vector.waitEventName, maxTimeMillis: vector.waitMaxTimeMillis),
                routes: [])
            await service.profileDidCommit(snapshot, distinctId: "customer")

            events.track(vector.trigger.name)
            await fulfillment(of: [preparing], timeout: 3)
            if let followUp = vector.followUp {
                clock.setCurrentDate(launch.addingTimeInterval(Double(followUp.atMillis) / 1000))
                events.track(followUp.name)
                _ = await events.flushEvents()
                XCTAssertTrue(store.pendingCommittedRoutes.contains { $0.event.name == followUp.name },
                              "The follow-up is committed and queued behind the trigger")
            }
            clock.setCurrentDate(launch.addingTimeInterval(Double(preparationFinishesAtMillis) / 1000))
            await preparation.release()
            await fulfillment(of: [triggerHandled] + (followUpHandled.map { [$0] } ?? []), timeout: 3)
            // Drain the deadline accepted while the trigger was running.
            // The wall clock stays fixed, with no new app input.
            await events.drain()
            await events.drain()

            XCTAssertEqual(completions(in: store), [vector.expectedOutcome], vector.name)
            XCTAssertEqual(starts(in: store), 1, vector.name)
            await service.shutdown()
            await events.close()
        }
    }

    /// Shutdown delivers a capture it accepted before stopping Journeys, and
    /// the route is acknowledged rather than left for the next session.
    func testACaptureAcceptedJustBeforeShutdownReachesJourneys() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseACaptureAcceptedJustBeforeShutdownReachesJourneys() }
    }

    private func exerciseACaptureAcceptedJustBeforeShutdownReachesJourneys() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = try await liveTimedWait(directory: directory)
        live.events.track("start_waiting")
        await live.service.shutdown()
        XCTAssertEqual(starts(in: live.store), 1, "The accepted capture reached Journeys before shutdown")
        XCTAssertFalse(live.store.pendingCommittedRoutes.contains { $0.event.name == "start_waiting" })
        await live.events.close()
    }

    // MARK: - Input watermark

    /// Renderer tap held with routing: it happens at 900 ms, the 1000 ms
    /// deadline is queued at 1000 ms, and the tap commits at 1100 ms. The
    /// deadline lets the committed in-window tap go first.
    func testHeldRendererTapCommittedBehindTheDeadlineSatisfiesTheWait() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseHeldRendererTapCommittedBehindTheDeadlineSatisfiesTheWait() }
    }

    private func exerciseHeldRendererTapCommittedBehindTheDeadlineSatisfiesTheWait() async throws {
        let vector = try Self.watermarkVector("held_renderer_tap")
        let tap = try XCTUnwrap(vector.tap)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = try await watermarkJourney(vector, directory: directory)
        let t0 = live.launch
        live.events.track(vector.trigger.name)
        await live.events.drain()
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        let runs = try await journal.runs()
        let parked = try XCTUnwrap(runs.first)
        let deadline = try XCTUnwrap(Self.deadline(parked))
        XCTAssertEqual(deadline.wakeAt, t0.addingTimeInterval(Double(vector.waitMaxTimeMillis) / 1000))

        let hold = await live.events.deferCommittedRouting()
        live.clock.setCurrentDate(t0.addingTimeInterval(Double(tap.atMillis) / 1000))
        live.events.stageJourneyInputs([.init(eventId: "tap", distinctId: "customer",
            occurredAt: live.clock.now())])
        live.clock.setCurrentDate(t0.addingTimeInterval(Double(try XCTUnwrap(vector.deadlineQueuedAtMillis)) / 1000))
        await live.events.enqueueJourneyDeadline(deadline)
        live.clock.setCurrentDate(t0.addingTimeInterval(Double(tap.committedAtMillis) / 1000))
        live.times.set(t0.addingTimeInterval(Double(tap.atMillis) / 1000), for: "tap")
        live.events.track(tap.name, eventId: "tap")
        _ = await live.events.flushEvents()
        live.events.releaseJourneyInputs(eventIds: ["tap"])
        XCTAssertEqual(completions(in: live.store), [], "Routing still holds the deadline and the tap")

        _ = await live.events.releaseCommittedRouting(ifGeneration: hold)
        for _ in 0..<400 where completions(in: live.store).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await live.events.drain()
        XCTAssertEqual(completions(in: live.store), [vector.expectedOutcome])
        XCTAssertEqual(starts(in: live.store), 1)
        await live.service.shutdown()
        await live.events.close()
    }

    /// A tap committed after its deadline has run is late: the timeout stands.
    func testTapCommittedAfterTheDeadlineRanLeavesTheTimeout() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseTapCommittedAfterTheDeadlineRanLeavesTheTimeout() }
    }

    private func exerciseTapCommittedAfterTheDeadlineRanLeavesTheTimeout() async throws {
        let vector = try Self.watermarkVector("late_commit")
        let tap = try XCTUnwrap(vector.tap)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = try await watermarkJourney(vector, directory: directory)
        let t0 = live.launch
        live.events.track(vector.trigger.name)
        await live.events.drain()
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        let runs = try await journal.runs()
        let deadline = try XCTUnwrap(runs.first.flatMap(Self.deadline))
        live.clock.setCurrentDate(t0.addingTimeInterval(Double(try XCTUnwrap(vector.deadlineQueuedAtMillis)) / 1000))
        await live.events.enqueueJourneyDeadline(deadline)
        await live.events.drain()
        XCTAssertEqual(completions(in: live.store), ["timeout"])

        live.clock.setCurrentDate(t0.addingTimeInterval(Double(tap.committedAtMillis) / 1000))
        live.times.set(t0.addingTimeInterval(Double(tap.atMillis) / 1000), for: "tap")
        live.events.track(tap.name, eventId: "tap")
        await live.events.drain()
        XCTAssertEqual(completions(in: live.store), [vector.expectedOutcome])
        await live.service.shutdown()
        await live.events.close()
    }

    /// A tap staged longer than the staging bound stops holding the deadline
    /// and is late when it commits.
    func testTapStagedLongerThanTheBoundIsLate() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseTapStagedLongerThanTheBoundIsLate() }
    }

    private func exerciseTapStagedLongerThanTheBoundIsLate() async throws {
        let vector = try Self.watermarkVector("held_renderer_tap")
        let tap = try XCTUnwrap(vector.tap)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = try await watermarkJourney(vector, directory: directory)
        let uptime = WatermarkUptime()
        live.events.inputWatermark.setUptime { uptime.value }
        let t0 = live.launch
        live.events.track(vector.trigger.name)
        await live.events.drain()
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        let runs = try await journal.runs()
        let deadline = try XCTUnwrap(runs.first.flatMap(Self.deadline))

        live.clock.setCurrentDate(t0.addingTimeInterval(Double(tap.atMillis) / 1000))
        live.events.stageJourneyInputs([.init(eventId: "tap", distinctId: "customer",
            occurredAt: live.clock.now())])
        live.clock.setCurrentDate(t0.addingTimeInterval(Double(try XCTUnwrap(vector.deadlineQueuedAtMillis)) / 1000))
        await live.events.enqueueJourneyDeadline(deadline)
        await live.events.drain()
        XCTAssertEqual(completions(in: live.store), [], "The staged tap holds the deadline")

        // The tap stays staged past the bound on the monotonic clock. The
        // queue's retry timer asks the waiting deadline again.
        uptime.advance(by: CustomerInputWatermark.stagingBound + 0.1)
        for _ in 0..<400 where completions(in: live.store).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(completions(in: live.store), ["timeout"])

        live.clock.setCurrentDate(t0.addingTimeInterval(Double(tap.committedAtMillis) / 1000))
        live.times.set(t0.addingTimeInterval(Double(tap.atMillis) / 1000), for: "tap")
        live.events.track(tap.name, eventId: "tap")
        live.events.releaseJourneyInputs(eventIds: ["tap"])
        await live.events.drain()
        XCTAssertEqual(completions(in: live.store), ["timeout"], "The late tap does not reopen the wait")
        await live.service.shutdown()
        await live.events.close()
    }

    /// Recovery replays a trigger whose wait is already overdue, and reading
    /// the in-window follow-up fails once. The deadline waits until a later
    /// recovery reads it, and then the follow-up satisfies the wait.
    func testDeadlineWaitsForRecoveryToReadAnInWindowFollowUp() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseDeadlineWaitsForRecoveryToReadAnInWindowFollowUp() }
    }

    private func exerciseDeadlineWaitsForRecoveryToReadAnInWindowFollowUp() async throws {
        let vector = try Self.watermarkVector("recovery_read_failure")
        let followUp = try XCTUnwrap(vector.followUp)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = Date(timeIntervalSince1970: 1_000_000)
        let store = MockEventStore()
        for (id, name, atMillis) in [("recovered-trigger", vector.trigger.name, vector.trigger.atMillis),
                                     ("recovered-follow-up", followUp.name, followUp.atMillis)] {
            let event = try StoredEvent(id: id, name: name, properties: [:],
                timestamp: launch.addingTimeInterval(Double(atMillis) / 1000), distinctId: "customer")
            _ = try await store.commitStableCaptureAndStageRoute(eventId: id, event: event,
                recordedAt: event.timestamp, assigningCommitSequence: false, admission: nil)
        }
        // The first recovery delivers the trigger, whose wait is already
        // overdue, and then fails to read the in-window follow-up.
        XCTAssertEqual(vector.failedFollowUpReads, 1)
        store.failNextReceiptCheck(eventId: "recovered-follow-up")
        // The next recovery keeps its read open past a retry interval, with
        // the journal open: a deadline that ignored pending recovery would
        // time out meanwhile.
        let recoveries = WatermarkUptime()
        store.pendingStableRoutesLoaded = {
            recoveries.advance(by: 1)
            guard recoveries.value == 2 else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        let live = try await watermarkJourney(vector, directory: directory, store: store, launch: launch,
            startAtMillis: try XCTUnwrap(vector.recoveryAtMillis), commitsProfileFirst: true)
        for _ in 0..<800 where completions(in: live.store).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await live.events.drain()
        XCTAssertEqual(completions(in: live.store), [vector.expectedOutcome])
        XCTAssertEqual(starts(in: live.store), 1)
        await live.service.shutdown()
        await live.events.close()
    }

    private static func watermarkVector(_ kind: String) throws -> QueuedEventTimeoutVectors.Case {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/sdk/committed-event-timeout-order.json")
        let vectors = try JSONDecoder().decode(QueuedEventTimeoutVectors.self, from: Data(contentsOf: url))
        return try XCTUnwrap(vectors.cases.first { $0.kind == kind })
    }

    /// A Journey on the real EventLog that starts on the vector's trigger and
    /// waits for its event. Event times come from `times`, by event id, or
    /// the vector's trigger and follow-up times by name.
    private func watermarkJourney(
        _ vector: QueuedEventTimeoutVectors.Case, directory: URL, store: MockEventStore = MockEventStore(),
        launch: Date = Date(timeIntervalSince1970: 1_000_000), startAtMillis: Int = 0,
        commitsProfileFirst: Bool = false
    ) async throws -> (service: JourneyService, events: EventLog, store: MockEventStore,
                       clock: MockDateProvider, times: WatermarkEventTimes, launch: Date) {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = replacing(try await authenticatedSnapshot(fixture), entry: Self.eventEntry(vector.trigger.name),
            reentry: .init(type: .everyMatch, window: nil), completionOutputs: Self.heldWaitOutcomes,
            entryStepId: "wait",
            steps: Self.waitSteps(eventName: vector.waitEventName, maxTimeMillis: vector.waitMaxTimeMillis),
            routes: [])
        let clock = MockDateProvider(initialDate: launch.addingTimeInterval(Double(startAtMillis) / 1000))
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = EventLog(identity: identity, dateProvider: clock, apiClient: MockNuxieApi(), store: store)
        let service = JourneyService(identity: identity, events: events, dateProvider: clock,
            sleepProvider: MockSleepProvider(), journalDirectory: directory, storageScope: .testFixture,
            featureAccess: { _ in nil }, dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            pinnedReleaseAuthenticator: { _, reference in
                guard let release = snapshot.releasesByDigest[reference.descriptorSha256] else {
                    throw JourneyExecutionError.invalidState
                }
                return release
            },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed))
        let reservation = events.reserveCommittedAdmission { service.eventAdmissionGeneration() }
        await events.subscribeAcknowledgingCommitted(reservation: reservation) { event, generation in
            await service.handleStoredEvent(event, admittedProfileGeneration: generation)
        }
        await service.prepareForEvents()
        let times = WatermarkEventTimes()
        times.set(launch.addingTimeInterval(Double(vector.trigger.atMillis) / 1000), for: vector.trigger.name)
        let configuration = NuxieConfiguration(apiKey: "input-watermark-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        configuration.beforeSend = { event in
            guard let timestamp = times.time(for: event.id) ?? times.time(for: event.name) else { return event }
            return NuxieEvent(id: event.id, name: event.name, distinctId: event.distinctId,
                              properties: event.properties, timestamp: timestamp)
        }
        try await events.configure(configuration: configuration)
        // Recovered events start Journeys only from an installed copy.
        if commitsProfileFirst { await service.profileDidCommit(snapshot, distinctId: "customer") }
        await service.initialize()
        if !commitsProfileFirst { await service.profileDidCommit(snapshot, distinctId: "customer") }
        return (service, events, store, clock, times, launch)
    }

    /// Both app events travel through EventLog's first-launch hold, then
    /// replay in capture order when the first authenticated copy arrives.
    func testHeldEventTimeVectors() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseHeldEventTimeVectors() }
    }

    private func exerciseHeldEventTimeVectors() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/sdk/held-event-time.json")
        let vectors = try JSONDecoder().decode(HeldEventTimeVectors.self, from: Data(contentsOf: url))
        XCTAssertFalse(vectors.cases.isEmpty)
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let base = try await authenticatedSnapshot(fixture)
        let launch = Date(timeIntervalSince1970: 1_000_000)
        for vector in vectors.cases {
            XCTAssertEqual(vector.hold, "first-launch", vector.name)
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let clock = MockDateProvider(initialDate: launch)
            let sleeper = MockSleepProvider()
            let identity = MockIdentityService()
            identity.setDistinctId("customer")
            let store = MockEventStore()
            let events = EventLog(identity: identity, dateProvider: clock,
                                  apiClient: MockNuxieApi(), store: store)
            let service = JourneyService(
                identity: identity, events: events,
                dateProvider: clock, sleepProvider: sleeper,
                journalDirectory: directory, storageScope: nil, featureAccess: { _ in nil },
                dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
                pinnedReleaseAuthenticator: { _, _ in throw JourneyExecutionError.invalidState },
                timezones: try XCTUnwrap(SignedTimezoneBundle.installed)
            )
            let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer",
                storageScope: JourneyStorageScope(authority: fixture.deliveryAuthority))
            let observed = HeldWaitObservation()
            let reservation = events.reserveCommittedAdmission { service.eventAdmissionGeneration() }
            await events.subscribeAcknowledgingCommitted(reservation: reservation) { event, generation in
                let acknowledged = await service.handleStoredEvent(event, admittedProfileGeneration: generation)
                if event.name == vector.journey.triggerEvent {
                    await observed.record(try? await journal.runs().first)
                    if vector.expected.waitStartedAtMillis + vector.journey.wait.maxTimeMillis
                        <= vector.copyArrivesAtMillis {
                        // The queued deadline and activation must remain
                        // behind the held event prefix.
                        await service.onAppBecameActive()
                        XCTAssertTrue(store.storedEvents.filter {
                            $0.name == JourneyEvents.journeyCompleted
                        }.isEmpty, "\(vector.name): timeout must wait for the held follow-up")
                    }
                }
                return acknowledged
            }
            await service.prepareForEvents()
            let configuration = NuxieConfiguration(apiKey: "held-event-time-test")
            configuration.testingOverrides.suppressBackgroundWork = true
            let eventTimes = Dictionary(uniqueKeysWithValues: vector.events.map {
                ($0.name, launch.addingTimeInterval(Double($0.atMillis) / 1000))
            })
            // Ordinary EventLog.track uses Date(). Pin only the fixture's
            // app-event timestamps through the supported beforeSend hook.
            configuration.beforeSend = { event in
                guard let timestamp = eventTimes[event.name] else { return event }
                return NuxieEvent(id: event.id, name: event.name, distinctId: event.distinctId,
                                  properties: event.properties, timestamp: timestamp)
            }
            try await events.configure(configuration: configuration)
            await service.initialize()
            for event in vector.events {
                clock.setCurrentDate(launch.addingTimeInterval(Double(event.atMillis) / 1000))
                events.track(event.name)
                _ = await events.flushEvents()
            }
            XCTAssertEqual(starts(in: store), 0, vector.name)
            XCTAssertEqual(completions(in: store), [], vector.name)

            let copyArrivesAt = launch.addingTimeInterval(Double(vector.copyArrivesAtMillis) / 1000)
            clock.setCurrentDate(copyArrivesAt)
            let steps = Self.waitSteps(eventName: vector.journey.wait.eventName,
                                       maxTimeMillis: vector.journey.wait.maxTimeMillis)
            let snapshot = replacing(base, entry: Self.eventEntry(vector.journey.triggerEvent),
                reentry: .init(type: .everyMatch, window: nil),
                completionOutputs: Self.heldWaitOutcomes, entryStepId: "wait", steps: steps, routes: [])
            await service.profileDidCommit(snapshot, artifacts: nil,
                authority: fixture.deliveryAuthority, admissionGeneration: 1, distinctId: "customer")
            await events.drain()

            let parked = await observed.run
            XCTAssertEqual(parked?.park?.anchorAt,
                launch.addingTimeInterval(Double(vector.expected.waitStartedAtMillis) / 1000), vector.name)
            XCTAssertEqual(parked?.park?.wakeAt,
                launch.addingTimeInterval(Double(vector.expected.waitStartedAtMillis
                    + vector.journey.wait.maxTimeMillis) / 1000), vector.name)
            XCTAssertEqual(parked?.startedAt, copyArrivesAt, "Admission/reporting time stays at replay")
            XCTAssertEqual(starts(in: store), 1, vector.name)
            XCTAssertEqual(completions(in: store), [vector.expected.outcome], vector.name)
            let started = try XCTUnwrap(store.storedEvents.first { $0.name == JourneyEvents.journeyStarted })
            XCTAssertEqual(started.timestamp, copyArrivesAt)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            XCTAssertEqual(started.getPropertiesDict()["started_at"] as? String,
                           formatter.string(from: copyArrivesAt))
            XCTAssertTrue(store.pendingStableRouteIds.isEmpty)
            await service.shutdown()
            await events.close()
        }
    }

    func testInitiallyOverdueDelayCatchesUpWithoutAnotherEvent() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseInitiallyOverdueDelayCatchesUpWithoutAnotherEvent() }
    }

    private func exerciseInitiallyOverdueDelayCatchesUpWithoutAnotherEvent() async throws {
        let delay = Journey.Step(kind: .action, id: "delay",
            action: ["type": .string("delay"), "durationMs": .number(500)],
            outlets: ["next": "satisfied"], outcome: nil)
        try await assertInitiallyOverdueStepCatchesUp(delay, outcome: "satisfied")
    }

    func testInitiallyOverdueWaitTimesOutWithoutAnotherEvent() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseInitiallyOverdueWaitTimesOutWithoutAnotherEvent() }
    }

    private func exerciseInitiallyOverdueWaitTimesOutWithoutAnotherEvent() async throws {
        try await assertInitiallyOverdueStepCatchesUp(
            Self.waitSteps(eventName: "go", maxTimeMillis: 500)[0], outcome: "timeout")
    }

    func testEventStartedCoordinatorLagsItsInitialClockForWaitsAndDelays() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseEventStartedCoordinatorLagsItsInitialClockForWaitsAndDelays() }
    }

    private func exerciseEventStartedCoordinatorLagsItsInitialClockForWaitsAndDelays() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let base = try await authenticatedSnapshot(fixture)
        let now = Date(timeIntervalSince1970: 1000.8)
        for eventAt in [Date(timeIntervalSince1970: 1000), now.addingTimeInterval(1)] {
            for timedStep in [Self.waitSteps(eventName: "go", maxTimeMillis: 60_000)[0], Self.delayStep] {
                let directory = temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
                let select = Journey.Step(kind: .action, id: "select", action: [
                    "type": .string("experiment"), "experimentId": .string("experiment"),
                    "fallbackVariantId": .string("variant"),
                    "variants": .array([.object(["id": .string("variant"), "isHoldout": .bool(false)])]),
                ], outlets: ["variant": timedStep.id], outcome: nil)
                let snapshot = replacing(base, entryStepId: "select", steps: [select, timedStep])
                let run = try await admitRun(snapshot, journal: journal, at: now)
                var coordinator = try makeCoordinator(run, snapshot: snapshot, journal: journal, startingEventAt: eventAt)
                guard case .advance(let selected) = try await coordinator.command(at: now) else {
                    return XCTFail("Expected experiment before the first wait")
                }
                XCTAssertEqual(selected.experimentExposure?.selectedAt, now, "Reporting uses the real clock")
                try await coordinator.commit(selected)
                // The pass keeps the lag it took at its first evaluation, so
                // async work between initial steps still counts toward a wait.
                guard case .park(let parked) = try await coordinator.command(at: now.addingTimeInterval(0.2)) else {
                    return XCTFail("Expected the initial timed step to park")
                }
                let lag = max(0, now.timeIntervalSince(eventAt))
                let expectedAnchor = try XCTUnwrap(JourneyTime.milliseconds(now.addingTimeInterval(0.2 - lag)))
                XCTAssertEqual(parked.checkpoint.anchorAtMillis, expectedAnchor)
                XCTAssertEqual(parked.checkpoint.wakeAtMillis, expectedAnchor + 60_000)
                XCTAssertEqual(coordinator.run.startedAt, now)
            }
        }
    }

    func testRecoveredWaitKeepsItsEventAnchorAndLaterDelayUsesTheRealClock() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseRecoveredWaitKeepsItsEventAnchorAndLaterDelayUsesTheRealClock() }
    }

    private func exerciseRecoveredWaitKeepsItsEventAnchorAndLaterDelayUsesTheRealClock() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let base = try await authenticatedSnapshot(fixture)
        var steps = Self.waitSteps(eventName: "go", maxTimeMillis: 60_000)
        let wait = steps[0]
        steps[0] = .init(kind: wait.kind, id: wait.id, action: wait.action,
                         outlets: ["satisfied": "delay", "timeout": "timeout"], outcome: nil)
        steps.append(Self.delayStep)
        let snapshot = replacing(base, entryStepId: "wait", steps: steps)
        let journal = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        let eventAt = Date(timeIntervalSince1970: 1000)
        let now = eventAt.addingTimeInterval(0.8)
        let run = try await admitRun(snapshot, journal: journal, at: now)
        var initial = try makeCoordinator(run, snapshot: snapshot, journal: journal, startingEventAt: eventAt)
        guard case .park(let parked) = try await initial.command(at: now) else { return XCTFail("Expected a wait") }
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let fence = JourneyProfileFence()
        let admission = JourneyCommitAdmission.executionOnly(identity: identity,
            executionFence: fence, executionFenceToken: fence.token())
        try await initial.commit(parked, snapshot: nil, admission: admission)

        let reopened = try await CustomerJourneyStore(directory: directory, distinctId: "customer")
        let later = now.addingTimeInterval(2)
        let recovered = try await reopened.recover(at: later)
        let saved = try XCTUnwrap(recovered.first)
        let savedPark = try XCTUnwrap(saved.park)
        XCTAssertEqual(savedPark.anchorAt, eventAt)
        XCTAssertEqual(savedPark.wakeAt, eventAt.addingTimeInterval(60))
        let resumed = try await reopened.resumeParked(saved.id, expectedStepId: saved.stepId,
            expectedPark: savedPark, admission: admission)
        let checkpoint = JourneyControlExecutor.Checkpoint(
            anchorAtMillis: try XCTUnwrap(savedPark.anchorAt.flatMap(JourneyTime.milliseconds)),
            wakeAtMillis: try XCTUnwrap(savedPark.wakeAt.flatMap(JourneyTime.milliseconds)))
        var continued = try makeCoordinator(try XCTUnwrap(resumed), snapshot: snapshot, journal: reopened,
            signal: .init(event: .init(name: "go", occurredAtMillis: 1_000_100, properties: [:])),
            checkpoint: checkpoint)
        guard case .advance(let satisfied) = try await continued.command(at: later) else {
            return XCTFail("The held follow-up must satisfy the recovered wait")
        }
        XCTAssertEqual(satisfied.stepId, "delay")
        try await continued.commit(satisfied)
        guard case .park(let delayed) = try await continued.command(at: later) else { return XCTFail("Expected delay") }
        XCTAssertEqual(delayed.checkpoint.anchorAtMillis, JourneyTime.milliseconds(later))
        XCTAssertEqual(delayed.checkpoint.wakeAtMillis, JourneyTime.milliseconds(later.addingTimeInterval(60)))
    }

    /// Basis's first launch: setup, then an immediate trigger, before any
    /// copy of the published setup exists on the device.
    func testFirstLaunchTriggerStartsOnceTheFirstProfileArrives() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseFirstLaunchTriggerStartsOnceTheFirstProfileArrives() }
    }

    private func exerciseFirstLaunchTriggerStartsOnceTheFirstProfileArrives() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: Self.eventEntry("onboarding_start"),
            reentry: .init(type: .everyMatch, window: nil)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let store = MockEventStore()
        let events = EventLog(identity: identity, dateProvider: MockDateProvider(),
                              apiClient: MockNuxieApi(), store: store)
        // Production starts without a journal namespace until the profile
        // transport authenticates the app.
        let service = JourneyService(
            identity: identity, events: events,
            dateProvider: MockDateProvider(), sleepProvider: MockSleepProvider(),
            journalDirectory: directory, storageScope: nil, featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            pinnedReleaseAuthenticator: { _, _ in throw JourneyExecutionError.invalidState },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed)
        )
        let admission = events.reserveCommittedAdmission { service.eventAdmissionGeneration() }
        await events.subscribeAcknowledgingCommitted(reservation: admission) { event, generation in
            await service.handleStoredEvent(event, admittedProfileGeneration: generation)
        }
        await service.prepareForEvents()
        let configuration = NuxieConfiguration(apiKey: "first-launch-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await events.configure(configuration: configuration)
        await service.initialize()

        events.track("onboarding_start")
        _ = await events.flushEvents()
        XCTAssertEqual(starts(in: store), 0, "No Journey can start before a copy exists")

        await service.profileDidCommit(snapshot, artifacts: nil,
                                       authority: fixture.deliveryAuthority,
                                       admissionGeneration: 1, distinctId: "customer")
        await events.drain()

        XCTAssertEqual(starts(in: store), 1)
        XCTAssertTrue(store.pendingStableRouteIds.isEmpty)
        await service.shutdown()
        await events.close()
    }

    /// A Journey left waiting by the previous launch takes an event held
    /// before this launch's first copy exactly once, and that copy also
    /// starts its own Journey from the event once.
    func testAWaitingJourneyTakesAHeldEventOnceAndTheFirstCopyStartsFromIt() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseAWaitingJourneyTakesAHeldEventOnceAndTheFirstCopyStartsFromIt() }
    }

    private func exerciseAWaitingJourneyTakesAHeldEventOnceAndTheFirstCopyStartsFromIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let savedCopy = try await waitingCopy(fixture, entry: "start_waiting")
        let firstCopy = try await waitingCopy(fixture, entry: "go")
        // EventLog stamps tracked events with the wall clock; the waits open
        // on the same clock.
        let dateProvider = MockDateProvider(initialDate: Date())
        let identity = MockIdentityService()
        identity.setDistinctId("customer")

        // The previous launch leaves a Journey waiting for go.
        let previous = JourneyService(
            identity: identity, events: MockEventLog(),
            dateProvider: dateProvider, sleepProvider: MockSleepProvider(),
            journalDirectory: directory,
            storageScope: JourneyStorageScope(authority: fixture.deliveryAuthority),
            featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: MockEventLog()),
            pinnedReleaseAuthenticator: { _, reference in
                guard let retained = savedCopy.releasesByDigest[reference.descriptorSha256] else { throw JourneyExecutionError.invalidState }
                return retained
            },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed)
        )
        await previous.initialize()
        await previous.profileDidCommit(savedCopy, distinctId: "customer")
        await previous.handleStoredEvent(Self.event("start_waiting", at: dateProvider.now()))

        // This launch tracks go before its first copy arrives.
        let store = MockEventStore()
        let events = EventLog(identity: identity, dateProvider: dateProvider,
                              apiClient: MockNuxieApi(), store: store)
        let service = JourneyService(
            identity: identity, events: events,
            dateProvider: dateProvider, sleepProvider: MockSleepProvider(),
            journalDirectory: directory, storageScope: nil, featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            pinnedReleaseAuthenticator: { _, reference in
                guard let retained = savedCopy.releasesByDigest[reference.descriptorSha256] else { throw JourneyExecutionError.invalidState }
                return retained
            },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed)
        )
        let admission = events.reserveCommittedAdmission { service.eventAdmissionGeneration() }
        await events.subscribeAcknowledgingCommitted(reservation: admission) { event, generation in
            await service.handleStoredEvent(event, admittedProfileGeneration: generation)
        }
        await service.prepareForEvents()
        let configuration = NuxieConfiguration(apiKey: "held-event-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await events.configure(configuration: configuration)
        await service.initialize()
        events.track("go")
        _ = await events.flushEvents()
        XCTAssertEqual(completions(in: store), [], "go waits for the first copy")

        await service.profileDidCommit(firstCopy, artifacts: nil,
                                       authority: fixture.deliveryAuthority,
                                       admissionGeneration: 1, distinctId: "customer")
        await events.drain()

        XCTAssertEqual(starts(in: store), 1, "The first copy starts its Journey from go")
        let completed = store.storedEvents.filter { $0.name == JourneyEvents.journeyCompleted }
        XCTAssertEqual(completed.compactMap { $0.getPropertiesDict()["outcome"] as? String },
                       ["took_go", "took_go"])
        XCTAssertEqual(Set(completed.compactMap { $0.getPropertiesDict()["journey_id"] as? String }).count, 2,
                       "The waiting Journey and the new one each took go exactly once")
        await service.shutdown()
        await events.close()
    }

    /// The shared contract, replayed operation by operation.
    func testEarlyEventAdmissionVectors() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseEarlyEventAdmissionVectors() }
    }

    private func exerciseEarlyEventAdmissionVectors() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/sdk/early-event-admission.json")
        let vectors = try JSONDecoder().decode(
            EarlyEventVectors.self, from: Data(contentsOf: url)
        )
        XCTAssertFalse(vectors.cases.isEmpty)
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let armed = replacing(
            try await authenticatedSnapshot(fixture),
            entry: Self.eventEntry("trigger"),
            reentry: .init(type: .everyMatch, window: nil)
        )
        let empty = removingDeliveredReleases(from: armed)
        for vector in vectors.cases {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let identity = MockIdentityService()
            identity.setDistinctId("customer")
            let events = MockEventLog()
            events.identity = identity
            let service = makeService(identity: identity, events: events, directory: directory)
            await service.initialize()
            var captured: (event: NuxieEvent, generation: UInt64)?
            var observed: [Int] = []
            for operation in vector.operations {
                switch operation {
                case "commit-empty": await service.profileDidCommit(empty, distinctId: "customer")
                case "commit-armed": await service.profileDidCommit(armed, distinctId: "customer")
                case "capture":
                    captured = (Self.event("trigger"), service.eventAdmissionGeneration())
                case "route-captured":
                    let route = try XCTUnwrap(captured, vector.name)
                    await service.handleStoredEvent(route.event, admittedProfileGeneration: route.generation)
                default: XCTFail("\(vector.name): unknown operation \(operation)")
                }
                observed.append(starts(in: events))
            }
            XCTAssertEqual(observed, vector.expectedStarts, vector.name)
            await service.shutdown()
        }
    }

    /// The user changes while an event of the previous user is still being
    /// routed. The new user's copy must not start a Journey from it.
    func testEventNeverStartsAnotherCustomersJourney() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseEventNeverStartsAnotherCustomersJourney() }
    }

    private func exerciseEventNeverStartsAnotherCustomersJourney() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let waitingCopy = try await waitingCopy(fixture, entry: "start_waiting")
        let otherCopy = replacing(try await authenticatedSnapshot(fixture),
                                  entry: Self.eventEntry("go"),
                                  reentry: .init(type: .everyMatch, window: nil))
        let dateProvider = MockDateProvider()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(identity: identity, events: events, directory: directory,
                                  dateProvider: dateProvider)
        await service.initialize()
        await service.profileDidCommit(waitingCopy, distinctId: "customer")
        await service.handleStoredEvent(Self.event("start_waiting", at: dateProvider.now()))

        // While go is routed, the waiting Journey finishes and reports; at
        // that moment the app switches to another user whose copy arrives.
        let switched = SwitchOnce()
        events.routedCaptureHandler = { [service] name, _ in
            guard name == JourneyEvents.journeyCompleted, await switched.claim() else { return }
            identity.setDistinctId("other")
            await service.profileDidCommit(otherCopy, distinctId: "other")
        }
        await service.handleStoredEvent(Self.event("go", at: dateProvider.now()))
        events.routedCaptureHandler = nil

        let switchedOver = await switched.claimed
        XCTAssertTrue(switchedOver, "The user switch happened while go was routed")
        XCTAssertEqual(events.routedEvents.filter {
            $0.name == JourneyEvents.journeyStarted && $0.distinctId == "other"
        }.count, 0)
        await service.shutdown()
    }

    func testIdentitySwitchFromCompletionSubscriberReturns() async throws {
        try await withBoundedJourneyWait { [self] in try await exerciseIdentitySwitchFromCompletionSubscriberReturns() }
    }

    private func exerciseIdentitySwitchFromCompletionSubscriberReturns() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let waiting = try await waitingCopy(fixture, entry: "start_waiting")
        let other = replacing(try await authenticatedSnapshot(fixture),
            entry: Self.eventEntry("go"), reentry: .init(type: .everyMatch, window: nil))
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let clock = MockDateProvider()
        let service = makeService(identity: identity, events: events, directory: directory, dateProvider: clock)
        await service.initialize()
        await service.profileDidCommit(waiting, distinctId: "customer")
        await service.handleStoredEvent(Self.event("start_waiting", at: clock.now()))
        let switched = JourneyCompletionFlag()
        await events.subscribeCommitted(where: { $0.name == JourneyEvents.journeyCompleted }) { _ in
            identity.setDistinctId("other")
            await service.profileDidCommit(other, distinctId: "other")
            switched.finish()
        }
        try await withBoundedJourneyWait(timeout: 5) {
            await service.handleStoredEvent(Self.event("go", at: clock.now()))
        }
        XCTAssertTrue(switched.isCompleted, "Identity switch returned inside completion subscriber")
        XCTAssertEqual(events.routedEvents.filter {
            $0.name == JourneyEvents.journeyCompleted && $0.distinctId == "customer"
        }.count, 1)
        XCTAssertFalse(events.routedEvents.contains {
            $0.name == JourneyEvents.journeyStarted && $0.distinctId == "other"
        })
        await service.shutdown()
    }

    func testIdentitySwitchFromRecoveryCompletionSubscriberReturns() async throws {
        try await withBoundedJourneyWait(timeout: 5) { [self] in
            let directory = temporaryDirectory()
            defer { removeTemporaryDirectoryIfPresent(directory) }
            let fixture = try JourneyPlaneProfileTestFixture.load()
            let snapshot = try await waitingCopy(fixture, entry: "start_waiting")
            let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
            let release = try XCTUnwrap(snapshot.releasesByDigest[arm.reference.descriptorSha256])
            let pin = try XCTUnwrap(snapshot.profile.releases.first {
                $0.envelope.descriptorSha256 == arm.reference.descriptorSha256
            })
            let identity = MockIdentityService()
            identity.setDistinctId("customer")
            let events = MockEventLog()
            events.identity = identity
            let clock = MockDateProvider()
            let store = try await CustomerJourneyStore(directory: directory, distinctId: "customer",
                openedAt: clock.now(), events: events)
            let admitted = try await store.admit(arm: arm, release: pin,
                executionSnapshot: .init(delivery: snapshot.profile.delivery,
                    assignments: snapshot.profile.facts.assignments,
                    customer: try snapshot.profile.facts.customerValues()),
                reentry: release.descriptor.leg.policy.entry.frequency,
                entryStepId: release.descriptor.leg.entryStepId, at: clock.now())
            XCTAssertNotNil(admitted)
            let other = replacing(snapshot, entry: Self.eventEntry("go"),
                reentry: .init(type: .everyMatch, window: nil))
            let service = makeService(identity: identity, events: events, directory: directory, dateProvider: clock)
            let switched = JourneyCompletionFlag()
            await events.subscribeCommitted(where: { $0.name == JourneyEvents.journeyCompleted }) { _ in
                identity.setDistinctId("other")
                await service.profileDidCommit(other, distinctId: "other")
                switched.finish()
            }
            await service.initialize()
            XCTAssertTrue(switched.isCompleted, "Recovery releases its join before subscriber delivery")
            XCTAssertEqual(events.routedEvents.filter { $0.name == JourneyEvents.journeyCompleted }.count, 1)
            await service.shutdown()
        }
    }

    // MARK: - Helpers

    private func liveTimedWait(directory: URL, step: Journey.Step? = nil, steps authoredSteps: [Journey.Step]? = nil,
        prepareNativeValues: @escaping JourneyService.NativeValuesPreparer = { _, _, _, _ in },
        readNativeValues: @escaping JourneyService.NativeValuesReader = { try await $0.journeyValues() },
        readJournalRuns: @escaping JourneyService.JournalRunsReader = { try await $0.runs() },
        journalBeforePersist: (@Sendable () throws -> Void)? = nil,
        beforeJourney: @escaping @Sendable (NuxieEvent, MockDateProvider) -> Void = { _, _ in },
        afterJourney: @escaping @Sendable (NuxieEvent, Bool) async -> Void = { _, _ in },
        dropJourneyStarted: Bool = false,
        screens: [Journey.Screen] = []
    ) async throws -> (
        service: JourneyService, events: EventLog, store: MockEventStore,
        clock: MockDateProvider, sleeper: MockSleepProvider
    ) {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        var steps = authoredSteps ?? Self.waitSteps(eventName: "go", maxTimeMillis: 500)
        if let step { steps[0] = step }
        let snapshot = replacing(try await authenticatedSnapshot(fixture), entry: Self.eventEntry("start_waiting"),
            reentry: .init(type: .everyMatch, window: nil), completionOutputs: Self.heldWaitOutcomes,
            entryStepId: steps[0].id, steps: steps, routes: [], screens: screens)
        let clock = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1000))
        let sleeper = MockSleepProvider()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let store = MockEventStore()
        let events = EventLog(identity: identity, dateProvider: clock, apiClient: MockNuxieApi(), store: store)
        let service = JourneyService(identity: identity, events: events, dateProvider: clock, sleepProvider: sleeper,
            journalDirectory: directory, storageScope: .testFixture,
            featureAccess: { _ in nil }, dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            prepareNativeValues: prepareNativeValues, readNativeValues: readNativeValues, readJournalRuns: readJournalRuns,
            pinnedReleaseAuthenticator: { _, reference in
                guard let release = snapshot.releasesByDigest[reference.descriptorSha256] else { throw JourneyExecutionError.invalidState }
                return release
            },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed), journalBeforePersist: journalBeforePersist)
        let reservation = events.reserveCommittedAdmission { service.eventAdmissionGeneration() }
        await events.subscribeAcknowledgingCommitted(reservation: reservation) { event, generation in
            beforeJourney(event, clock)
            let accepted = await service.handleStoredEvent(event, admittedProfileGeneration: generation)
            await afterJourney(event, accepted)
            return accepted
        }
        await service.prepareForEvents()
        let configuration = NuxieConfiguration(apiKey: "pending-timeout-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        configuration.beforeSend = { event in
            if dropJourneyStarted, event.name == JourneyEvents.journeyStarted { return nil }
            return NuxieEvent(id: event.id, name: event.name, distinctId: event.distinctId,
                       properties: event.properties, timestamp: clock.now())
        }
        try await events.configure(configuration: configuration)
        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        return (service, events, store, clock, sleeper)
    }

    private func assertInitiallyOverdueStepCatchesUp(_ step: Journey.Step, outcome: String) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        var steps = Self.waitSteps(eventName: "go", maxTimeMillis: 500)
        steps[0] = step
        let snapshot = replacing(try await authenticatedSnapshot(fixture), entry: Self.eventEntry("start_waiting"),
            reentry: .init(type: .everyMatch, window: nil), completionOutputs: Self.heldWaitOutcomes,
            entryStepId: step.id, steps: steps, routes: [])
        let eventAt = Date(timeIntervalSince1970: 1000)
        let clock = MockDateProvider(initialDate: eventAt.addingTimeInterval(0.8))
        let sleeper = MockSleepProvider()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(identity: identity, events: events, directory: directory,
                                  dateProvider: clock, sleepProvider: sleeper)
        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await service.handleStoredEvent(Self.event("start_waiting", at: eventAt))

        // The overdue park itself requests a deadline; no new app input.
        for _ in 0..<200 where !events.routedEvents.contains(where: { $0.name == JourneyEvents.journeyCompleted }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(events.routedEvents.filter { $0.name == JourneyEvents.journeyCompleted }
            .compactMap { $0.properties["outcome"] as? String }, [outcome])
        await service.shutdown()
    }

    private static let heldWaitOutcomes: [String: Journey.Boundary] = [
        "satisfied": .init(eventFields: [], responseFields: []),
        "timeout": .init(eventFields: [], responseFields: []),
    ]

    private static let delayStep = Journey.Step(kind: .action, id: "delay",
        action: ["type": .string("delay"), "durationMs": .number(60_000)],
        outlets: ["next": "satisfied"], outcome: nil)

    private static func waitSteps(eventName: String, maxTimeMillis: Int) -> [Journey.Step] {
        var action = waitForGoSteps[0].action!
        action["trigger"] = .object(["kind": .string("event"), "eventName": .string(eventName)])
        action["maxTimeMs"] = .number(Double(maxTimeMillis))
        return [
            .init(kind: .action, id: "wait", action: action,
                  outlets: ["satisfied": "satisfied", "timeout": "timeout"], outcome: nil),
            .init(kind: .complete, id: "satisfied", action: nil, outlets: nil, outcome: "satisfied"),
            .init(kind: .complete, id: "timeout", action: nil, outlets: nil, outcome: "timeout"),
        ]
    }

    private func admitRun(_ snapshot: JourneyProfileCatalog.Snapshot, journal: CustomerJourneyStore,
                          at: Date) async throws -> JourneyRun {
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[arm.reference.descriptorSha256])
        let admitted = try await journal.admit(arm: arm, release: try XCTUnwrap(snapshot.profile.releases.first),
            executionSnapshot: .init(delivery: snapshot.profile.delivery, assignments: snapshot.profile.facts.assignments),
            reentry: .init(type: .everyMatch, window: nil), entryStepId: release.descriptor.leg.entryStepId, at: at)

        let runs = try await journal.runs()
        return try XCTUnwrap(runs.first)
    }

    private func makeCoordinator(_ run: JourneyRun, snapshot: JourneyProfileCatalog.Snapshot,
        journal: CustomerJourneyStore, startingEventAt: Date? = nil,
        signal: JourneyControlExecutor.Signal = .init(),
        checkpoint: JourneyControlExecutor.Checkpoint? = nil
    ) throws -> JourneyRunExecutionCoordinator {
        .init(run: run, assignments: snapshot.profile.facts.assignments,
              release: try XCTUnwrap(snapshot.releasesByDigest[run.reference.descriptorSha256]),
              signal: signal, checkpoint: checkpoint, journal: journal,
              timezones: try XCTUnwrap(SignedTimezoneBundle.installed),
              currentDeviceTimezone: TimeZone(secondsFromGMT: 0)!, startingEventAt: startingEventAt)
    }

    private actor HeldWaitObservation {
        private(set) var run: JourneyRun?
        func record(_ run: JourneyRun?) { self.run = run }
    }

    private actor FailableJourneyRead {
        private var failing = false
        private(set) var attempts = 0
        func setFailing(_ failing: Bool) { self.failing = failing }
        func attempt() throws {
            attempts += 1
            if failing { throw JourneyExecutionError.invalidState }
        }
    }

    private actor JourneyDeliveryObservation {
        private(set) var values: [Bool] = []
        func record(_ accepted: Bool) { values.append(accepted) }
    }

    private struct HeldEventTimeVectors: Decodable {
        struct Case: Decodable, Sendable {
            struct Event: Decodable, Sendable { let name: String; let atMillis: Int }
            struct Journey: Decodable, Sendable {
                struct Wait: Decodable, Sendable { let eventName: String; let maxTimeMillis: Int }
                let triggerEvent: String
                let wait: Wait
            }
            struct Expected: Decodable, Sendable { let waitStartedAtMillis: Int; let outcome: String }
            let name: String
            let hold: String
            let events: [Event]
            let copyArrivesAtMillis: Int
            let journey: Journey
            let expected: Expected
        }
        let cases: [Case]
    }

    private struct QueuedEventTimeoutVectors: Decodable {
        struct Case: Decodable, Sendable {
            struct Trigger: Decodable, Sendable {
                let name: String
                let atMillis: Int
                let handledAtMillis: Int?
            }
            struct Event: Decodable, Sendable { let name: String; let atMillis: Int }
            struct Tap: Decodable, Sendable { let name: String; let atMillis: Int; let committedAtMillis: Int }
            let kind: String
            let name: String
            let trigger: Trigger
            let followUp: Event?
            let tap: Tap?
            let waitEventName: String
            let waitMaxTimeMillis: Int
            let preparationFinishesAtMillis: Int?
            let deadlineQueuedAtMillis: Int?
            let recoveryAtMillis: Int?
            let failedFollowUpReads: Int?
            let expectedOutcome: String
        }
        let stagingBoundMillis: Int
        let cases: [Case]
    }

    private static let waitOutcomes: [String: Journey.Boundary] = [
        "took_go": .init(eventFields: [], responseFields: []),
        "timed_out": .init(eventFields: [], responseFields: []),
    ]

    /// A copy whose Journey starts on `entry` and waits a minute for go.
    private func waitingCopy(
        _ fixture: JourneyPlaneProfileTestFixture,
        entry: String
    ) async throws -> JourneyProfileCatalog.Snapshot {
        replacing(try await authenticatedSnapshot(fixture), entry: Self.eventEntry(entry),
                  reentry: .init(type: .everyMatch, window: nil),
                  completionOutputs: Self.waitOutcomes, entryStepId: "wait",
                  steps: Self.waitForGoSteps, routes: [])
    }

    private static func eventEntry(_ name: String) -> JourneyEntryCondition {
        .init(type: .event, eventName: name, segmentId: nil, member: nil, condition: nil)
    }

    private static func event(_ name: String, at timestamp: Date = Date()) -> NuxieEvent {
        NuxieEvent(name: name, distinctId: "customer", timestamp: timestamp)
    }

    private static let waitForGoSteps: [Journey.Step] = [
        .init(
            kind: .action,
            id: "wait",
            action: [
                "type": .string("wait_until"),
                "trigger": .object([
                    "kind": .string("event"),
                    "eventName": .string("go"),
                ]),
                "condition": .object([
                    "type": .string("Truthy"),
                    "value": .object([
                        "type": .string("Boolean"),
                        "value": .bool(true),
                    ]),
                ]),
                "maxTimeMs": .number(60_000),
            ],
            outlets: ["satisfied": "took_go", "timeout": "timed_out"],
            outcome: nil
        ),
        .init(kind: .complete, id: "took_go", action: nil, outlets: nil, outcome: "took_go"),
        .init(kind: .complete, id: "timed_out", action: nil, outlets: nil, outcome: "timed_out"),
    ]

    private actor SwitchOnce {
        private(set) var claimed = false
        func claim() -> Bool {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    private struct EarlyEventVectors: Decodable {
        struct Case: Decodable {
            let name: String
            let operations: [String]
            let expectedStarts: [Int]
        }
        let cases: [Case]
    }

    private func starts(in store: MockEventStore) -> Int {
        store.storedEvents.filter { $0.name == JourneyEvents.journeyStarted }.count
    }

    private func completions(in store: MockEventStore) -> [String] {
        store.storedEvents
            .filter { $0.name == JourneyEvents.journeyCompleted }
            .compactMap { $0.getPropertiesDict()["outcome"] as? String }
    }

    private func starts(in events: MockEventLog) -> Int {
        events.routedEvents.filter { $0.name == JourneyEvents.journeyStarted }.count
    }

    private func completions(in events: MockEventLog) -> [String] {
        events.routedEvents.filter { $0.name == JourneyEvents.journeyCompleted }
            .compactMap { $0.properties["outcome"] as? String }
    }
}

private actor JourneyDeadlineRecorder {
    private(set) var values: [JourneyDeadline] = []
    func append(_ deadline: JourneyDeadline) { values.append(deadline) }
}

private actor JourneyTimedRouteObservation {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private final class WatermarkEventTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [String: Date] = [:]
    func set(_ time: Date, for key: String) { lock.withLock { times[key] = time } }
    func time(for key: String) -> Date? { lock.withLock { times[key] } }
}

private final class WatermarkUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 0
    var value: TimeInterval { lock.withLock { current } }
    func advance(by interval: TimeInterval) { lock.withLock { current += interval } }
}
