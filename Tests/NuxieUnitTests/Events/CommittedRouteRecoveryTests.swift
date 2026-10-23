import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private actor RecoveredRouteRecorder {
    private var ids: [String] = []
    func append(_ id: String) { ids.append(id) }
    func snapshot() -> [String] { ids }
}

private actor QueueAttemptRecorder {
    private(set) var attempts: [(String, TimeInterval)] = []
    private var failing = true
    func recover() { failing = false }
    func attempt(_ name: String) -> JourneyQueueResult {
        attempts.append((name, ProcessInfo.processInfo.systemUptime))
        return name == "head" && failing ? .failed : .done
    }
}

private final class RecoveryAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 1
    var value: UInt64 { lock.withLock { generation } }
    func advance() { lock.withLock { generation += 1 } }
}

private actor RecoveryPageGate {
    private let pass: Int
    private let onLoaded: @Sendable () -> Void
    private var visits = 0
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(pass: Int, onLoaded: @escaping @Sendable () -> Void) {
        self.pass = pass
        self.onLoaded = onLoaded
    }

    func pageLoaded() async {
        visits += 1
        guard visits == pass, !released else { return }
        onLoaded()
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor RecoveryResult {
    private(set) var value: Bool?
    func record(_ value: Bool) { self.value = value }
}

final class CommittedRouteRecoveryTests: XCTestCase {

    func testFailedCorrelatedCaptureKeepsItsPositionAheadOfItsJourneysLaterInput() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = MockEventStore()
        let log = EventLog(identity: identity, dateProvider: MockDateProvider(), apiClient: MockNuxieApi(), store: store)
        let sink = EventLogSystemEventSink(events: log)
        let attempts = RecoveryAdmission()
        let observed = RecoveredRouteRecorder()
        await log.registerJourneyRun(runId: "run", journeyId: "journey", distinctId: "customer-a")
        let reservation = log.reserveCommittedAdmission { 1 }
        await log.subscribeAcknowledgingCommitted(reservation: reservation) { event, _ in
            if await log.completedJourneyEventPlan() { return true }
            let run = event.name == "unrelated" ? "other-run" : "run"
            return await log.performJourneyWork(.init(key: .init(distinctId: event.distinctId, id: "input:\(event.id)"),
                runId: run, afterFailure: false, eventPlan: true, operation: {
                    await observed.append(event.name)
                    return .done
                }))
        }
        let configuration = NuxieConfiguration(apiKey: "correlated-capture-order")
        configuration.testingOverrides.suppressBackgroundWork = true
        configuration.beforeSend = { event in
            if event.name == "correlated", attempts.value == 1 {
                attempts.advance()
                store.shouldFailStore = true
            }
            return event
        }
        try await log.configure(configuration: configuration)
        let captured = await sink.capture(.init(name: "correlated", properties: ["journey_id": "journey"],
            eventId: "correlated", distinctId: "customer-a"))
        XCTAssertFalse(captured)
        store.shouldFailStore = false
        log.track("later")
        log.track("unrelated")
        await log.drain()
        let first = await observed.snapshot()
        XCTAssertFalse(first.contains("later"), "Only the failing Journey's input waits behind its capture")
        XCTAssertTrue(first.contains("unrelated"))
        for _ in 0..<500 {
            if await observed.snapshot().count == 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await log.drain()
        let delivered = await observed.snapshot()
        XCTAssertEqual(delivered, ["unrelated", "correlated", "later"], "The committed event inherits its retry entry's original position")
        await log.close()
    }

    func testStableCaptureFailureUsesTheQueueTimerAndSurvivesJourneyTeardown() async throws {
        let events = MockEventLog()
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        events.identity = identity
        events.routedCaptureFailuresRemaining = 1
        let sink = EventLogSystemEventSink(events: events)
        let request = StableSystemEventCaptureRequest(name: "correlated_outcome", properties: nil,
            eventId: "correlated-outcome", distinctId: "customer-a")
        let captured = await sink.capture(request)
        XCTAssertFalse(captured)
        let queued = await events.queuedJourneyRetryKeys()
        XCTAssertEqual(queued.map(\.id), ["stable-capture:correlated-outcome"])
        await events.cancelJourneyWork(distinctId: "customer-a")
        for _ in 0..<400 where !events.routedEvents.contains(where: { $0.id == request.eventId }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(events.routedEvents.filter { $0.id == request.eventId }.count, 1)
        await events.close()
    }

    func testJourneyWorkKeepsItsKeyPositionAndBackoffWithoutBlockingOtherJourneysOrCustomers() async throws {
        // One policy: a fixed one-second interval with no attempt limit.
        XCTAssertEqual(OrderedCustomerQueue.retryInterval, 1)
        let queue = OrderedCustomerQueue()
        let recorder = QueueAttemptRecorder()
        let key = JourneyQueueKey(distinctId: "customer-a", id: "declined")
        let operation: JourneyQueueOperation = { await recorder.attempt("head") }
        let first = await queue.submit(key: key, lane: "run:one", operation: operation)
        XCTAssertFalse(first)
        for _ in 0..<10 {
            _ = await queue.submit(key: key, lane: "run:one", waitForAttempt: false, operation: operation)
        }
        _ = await queue.submit(key: .init(distinctId: "customer-a", id: "follower"), lane: "run:one", waitForAttempt: false) {
            await recorder.attempt("follower")
        }
        _ = await queue.submit(key: .init(distinctId: "customer-a", id: "unrelated"), lane: "run:two") {
            await recorder.attempt("other-journey")
        }
        _ = await queue.submit(key: .init(distinctId: "customer-b", id: "unrelated"), lane: "run:one") {
            await recorder.attempt("other-customer")
        }
        await queue.settle()
        let initial = await recorder.attempts
        let initialHeads = initial.filter { $0.0 == "head" }
        for (previous, next) in zip(initialHeads, initialHeads.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.1 - previous.1, 0.99, "Reoffering a key never resets its backoff")
        }
        XCTAssertFalse(initial.contains { $0.0 == "follower" }, "A later input stays behind its Journey's failed work")
        for name in ["other-journey", "other-customer"] { XCTAssertTrue(initial.contains { $0.0 == name }) }
        await recorder.recover()
        for _ in 0..<400 {
            if await recorder.attempts.contains(where: { $0.0 == "follower" }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let completed = await recorder.attempts
        let heads = completed.filter { $0.0 == "head" }
        XCTAssertGreaterThanOrEqual(heads.count, 2)
        for (previous, next) in zip(heads, heads.dropFirst()) { XCTAssertGreaterThanOrEqual(next.1 - previous.1, 0.99) }
        XCTAssertEqual(completed.suffix(2).map(\.0), ["head", "follower"])
        await queue.close()
    }

    func testOnlyTheOrderedQueueArmsJourneyExecutionRetries() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let eventLog = try source("Sources/Nuxie/Events/EventLog.swift")
        let service = try source("Sources/Nuxie/Journey/JourneyService.swift")
        let presentation = try source("Sources/Nuxie/Experiences/ExperiencePresentationService.swift")
        XCTAssertEqual(presentation.components(separatedBy: "Task.sleep(").count - 1, 1,
            "Only the foreground presentation grace period sleeps; host input uses the queue")
        XCTAssertFalse(presentation.contains("250_000_000"))
        XCTAssertTrue(presentation.contains("applyHostDismissInput(id:"))
        for oldContinuation in ["continueWith", "case waiting(", "case reattempt", "let resume: @Sendable"] {
            XCTAssertFalse(eventLog.contains(oldContinuation))
            XCTAssertFalse(service.contains(oldContinuation))
        }
        for outcome in ["case done", "case failed", "case notYet"] { XCTAssertTrue(eventLog.contains(outcome)) }

        let exposure = try source("Sources/Nuxie/Journey/Execution/JourneyExperimentExposureCoordinator.swift")
        let systemEvents = try source("Sources/Nuxie/DI/RuntimeProviders.swift")
        let queue = try XCTUnwrap(eventLog.range(of: "actor OrderedCustomerQueue"))
        let end = try XCTUnwrap(eventLog.range(of: "private enum VolatileRoute"))
        let queueSource = String(eventLog[queue.lowerBound..<end.lowerBound])
        XCTAssertEqual(queueSource.components(separatedBy: "Task.sleep(").count - 1, 1)
        XCTAssertEqual(service.components(separatedBy: "sleeper.sleep(").count - 1, 1, "The only service sleeper is the authored deadline wake")
        XCTAssertTrue(service.contains("at date: Date, deadlines: [JourneyDeadline]"))
        for oldOwner in ["nativeRestoreRetryTasks", "NativeRestoreRetry", "deadlineRetryAt", "foregroundDeadlines", "commerceSettlementTasks", "eventParkRetries", "RemainingEventStarts"] {
            XCTAssertFalse(service.contains(oldOwner), "Removed retry state: \(oldOwner)")
        }
        XCTAssertFalse(service.contains("enqueueJourneyResumeRetry"))
        XCTAssertFalse(eventLog.contains("journeyResumeRetryHandler"))
        XCTAssertFalse(eventLog.contains("routeRetryTask"))
        XCTAssertFalse(eventLog.contains("acknowledgementRetryTask"))
        XCTAssertFalse(exposure.contains("CancellationAwareExponentialRetryLoop"))
        XCTAssertFalse(exposure.contains("Task.sleep("))
        XCTAssertFalse(exposure.contains("retryTasks"))
        XCTAssertFalse(systemEvents.contains("CancellationAwareExponentialRetryLoop"))
        XCTAssertFalse(systemEvents.contains("retryTask"))
        XCTAssertFalse(systemEvents.contains("Task.sleep("))
        // The other EventLog sleeper periodically flushes outbound events.
        XCTAssertEqual(eventLog.components(separatedBy: "Task.sleep(").count - 1, 2)
        // Response-save HTTP delivery has its own durable server-directed
        // transport policy; it never advances a Journey or accepts an input.
        let uploads = try source("Sources/Nuxie/Journey/Execution/JourneyResponseSaveDelivery.swift")
        XCTAssertEqual(uploads.components(separatedBy: "sleeper.sleep(").count - 1, 1)
    }

    func testFailedRecoveryReleasesRoutingAndRetriesTheHeldPrefixWithoutAnotherCapture() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = MockEventStore()
        let log = EventLog(identity: identity, dateProvider: MockDateProvider(), apiClient: MockNuxieApi(), store: store)
        let observed = RecoveredRouteRecorder()
        await log.subscribeCommitted { event in await observed.append(event.name) }
        let configuration = NuxieConfiguration(apiKey: "failed-recovery-retry")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await log.configure(configuration: configuration)
        _ = await log.deferCommittedRouting()
        _ = await log.captureAndRouteSystemEvent(.init(name: "held", properties: nil, eventId: "held", distinctId: "customer-a"))
        _ = await log.flushEvents()
        store.shouldFailQuery = true
        let recovered = await log.replayPendingStableRoutes(distinctId: "customer-a")
        XCTAssertFalse(recovered)
        store.shouldFailQuery = false
        for _ in 0..<400 {
            if await observed.snapshot() == ["held"] { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let released = await observed.snapshot()
        XCTAssertEqual(released, ["held"], "Failed recovery must release its hold; queue inspection retries its retained prefix")
        await log.close()
    }
    func testAcknowledgementDuringRecoveryPageDoesNotRedeliverAndStillDeliversPendingEntries() async throws {
        try await assertAcknowledgementDuringRecoveryPage(pass: 1)
    }

    func testAcknowledgementDuringFinalRecoveryPageDoesNotRejectAcknowledgedEntries() async throws {
        try await assertAcknowledgementDuringRecoveryPage(pass: 2)
    }

    private func assertAcknowledgementDuringRecoveryPage(pass: Int) async throws {
        let store = MockEventStore()
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let clock = MockDateProvider()
        let log = EventLog(identity: identity, dateProvider: clock, apiClient: MockNuxieApi(), store: store)
        let observed = RecoveredRouteRecorder()
        await log.subscribeCommitted { event in await observed.append(event.id) }
        let configuration = NuxieConfiguration(apiKey: "recovery-page-receipt-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await log.configure(configuration: configuration)
        store.shouldFailStableRouteAcknowledgement = true
        _ = await log.captureAndRouteSystemEvent(.init(name: "delivered", properties: nil,
            eventId: "delivered", distinctId: "customer-a"))
        await log.drain()
        let beforeRecovery = await observed.snapshot()
        XCTAssertEqual(beforeRecovery, ["delivered"])
        XCTAssertEqual(store.pendingCommittedRoutes.map(\.event.id), ["delivered"])

        // This retained entry has no current-session delivery. Revalidation
        // must still recover it once while ignoring the stale delivered entry.
        let pending = try StoredEvent(id: "pending", name: "pending", properties: [:],
            timestamp: clock.now(), distinctId: "customer-a")
        _ = try await store.commitStableCaptureAndStageRoute(eventId: pending.id, event: pending,
            recordedAt: pending.timestamp, assigningCommitSequence: false, admission: nil)
        let loaded = expectation(description: "Recovery loaded page for pass \(pass)")
        let finished = expectation(description: "Recovery finishes after receipt cleanup")
        let gate = RecoveryPageGate(pass: pass) { loaded.fulfill() }
        store.pendingStableRoutesLoaded = { await gate.pageLoaded() }
        let result = RecoveryResult()
        let recovery = Task {
            let recovered = await log.replayPendingStableRoutes(distinctId: "customer-a")
            await result.record(recovered)
            finished.fulfill()
        }
        addTeardownBlock {
            store.pendingStableRoutesLoaded = nil
            await gate.release()
            recovery.cancel()
            await log.close()
        }
        await fulfillment(of: [loaded], timeout: 3)
        store.shouldFailStableRouteAcknowledgement = false
        // Recovery owns the route worker here. Only the independent real
        // acknowledgement timer can clear these receipts while the page waits.
        for _ in 0..<500 {
            if !store.pendingStableRouteIds.contains("delivered"), store.pendingCommittedRoutes.isEmpty,
               pass == 1 || store.pendingStableRouteIds.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.pendingStableRouteIds.contains("delivered"))
        XCTAssertTrue(store.pendingCommittedRoutes.isEmpty)
        if pass == 1 {
            XCTAssertEqual(store.pendingStableRouteIds, ["pending"], "The unvisited entry is genuinely pending")
        } else {
            XCTAssertTrue(store.pendingStableRouteIds.isEmpty)
        }
        await gate.release()
        await fulfillment(of: [finished], timeout: 5)
        let recovered = await result.value
        let delivered = await observed.snapshot()
        XCTAssertEqual(recovered, true)
        XCTAssertEqual(delivered, ["delivered", "pending"])
        XCTAssertTrue(store.pendingStableRouteIds.isEmpty)
    }

    func testDeadlineSharesCaptureOrderAndRoutingHoldWithoutBecomingAnEvent() async throws {
        let store = MockEventStore()
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let clock = MockDateProvider()
        let log = EventLog(identity: identity, dateProvider: clock, apiClient: MockNuxieApi(), store: store)
        let observed = RecoveredRouteRecorder()
        let otherSubscribers = RecoveredRouteRecorder()
        let forwarded = RecoveredRouteRecorder()
        await log.subscribeCommitted { event in await otherSubscribers.append(event.name) }
        await log.subscribeForwarding { event in await forwarded.append(event.event.name) }
        await log.setJourneyDeadlineHandler { _ in
            await observed.append("deadline")
            return .done
        }
        let reservation = log.reserveCommittedAdmission { 1 }
        await log.subscribeAcknowledgingCommitted(reservation: reservation) { event, _ in
            await observed.append(event.name)
            return true
        }
        let configuration = NuxieConfiguration(apiKey: "deadline-order-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await log.configure(configuration: configuration)
        let generation = await log.deferCommittedRouting()
        // No drain between acceptance and the deadline request. The deadline
        // must follow this capture even if it has not committed yet.
        store.suspendNextInsert()
        log.track("in_window")
        for _ in 0..<200 where store.waitingInsertIds.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let waiting = try XCTUnwrap(store.waitingInsertIds.first)
        await log.enqueueJourneyDeadline(.init(distinctId: "customer-a", runId: "run", stepId: "wait",
            anchorAt: clock.now().addingTimeInterval(-1), wakeAt: clock.now()))
        log.track("later")
        store.resumeInsert(id: waiting)
        _ = await log.flushEvents()
        let held = await observed.snapshot()
        XCTAssertEqual(held, [])
        let released = await log.releaseCommittedRouting(ifGeneration: generation)
        XCTAssertTrue(released)
        await log.drain()
        let order = await observed.snapshot()
        let ordinary = await otherSubscribers.snapshot()
        let forwarding = await forwarded.snapshot()
        XCTAssertEqual(order, ["in_window", "deadline", "later"])
        XCTAssertEqual(ordinary, ["in_window", "later"])
        XCTAssertEqual(forwarding, ordinary)
        XCTAssertEqual(store.storedEvents.map(\.name), ordinary)
        await log.close()
    }

    /// A deadline waiting on its customer's watermark holds only that
    /// customer's deadlines at or after the staged input. The customer's own
    /// events and other Journeys' work, and another customer's events and
    /// deadlines, keep flowing.
    func testADeadlineWaitingOnItsWatermarkLeavesOtherWorkFlowing() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let clock = MockDateProvider()
        let log = EventLog(identity: identity, dateProvider: clock, apiClient: MockNuxieApi(), store: MockEventStore())
        let observed = RecoveredRouteRecorder()
        await log.subscribeCommitted { event in await observed.append("\(event.distinctId):\(event.name)") }
        await log.setJourneyDeadlineHandler { deadline in
            await observed.append("deadline:\(deadline.distinctId)")
            return .done
        }
        let configuration = NuxieConfiguration(apiKey: "watermark-isolation")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await log.configure(configuration: configuration)
        let wakeAt = clock.now()
        // A renderer tap of customer A at exactly the deadline is still staged.
        log.stageJourneyInputs([.init(eventId: "tap-a", distinctId: "customer-a", occurredAt: wakeAt)])
        await log.enqueueJourneyDeadline(.init(distinctId: "customer-a", runId: "run-a", stepId: "wait",
            anchorAt: wakeAt.addingTimeInterval(-1), wakeAt: wakeAt))
        log.track("a-later")
        log.track("b-event", distinctIdOverride: "customer-b")
        _ = await log.performJourneyWork(.init(key: .init(distinctId: "customer-a", id: "other-journey"),
            runId: "run-other", afterFailure: false, operation: {
                await observed.append("customer-a:other-journey")
                return .done
            }))
        await log.drain()
        for _ in 0..<200 {
            if await observed.snapshot().count >= 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let flowing = await observed.snapshot()
        XCTAssertEqual(Set(flowing), ["customer-a:a-later", "customer-b:b-event", "customer-a:other-journey"])

        identity.setDistinctId("customer-b")
        await log.enqueueJourneyDeadline(.init(distinctId: "customer-b", runId: "run-b", stepId: "wait",
            anchorAt: wakeAt.addingTimeInterval(-1), wakeAt: wakeAt))
        await log.drain()
        let afterB = await observed.snapshot()
        XCTAssertEqual(afterB.filter { $0.hasPrefix("deadline:") }, ["deadline:customer-b"],
                       "Customer A's staged input never holds customer B's deadline")
        log.releaseJourneyInputs(eventIds: ["tap-a"])
        await log.close()
    }

    func testFailedDeadlineRetainsItsPositionAndRetriesWithoutAnotherCapture() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let clock = MockDateProvider()
        let log = EventLog(identity: identity, dateProvider: clock,
                           apiClient: MockNuxieApi(), store: MockEventStore())
        let observed = RecoveredRouteRecorder()
        let attempts = RecoveredRouteRecorder()
        await log.setJourneyDeadlineHandler { _ in
            await observed.append("deadline")
            return .done
        }
        let reservation = log.reserveCommittedAdmission { 1 }
        await log.subscribeAcknowledgingCommitted(reservation: reservation) { event, _ in
            if event.name == "earlier" {
                await attempts.append("attempt")
                guard await attempts.snapshot().count > 1 else { return false }
            }
            await observed.append(event.name)
            return true
        }
        let configuration = NuxieConfiguration(apiKey: "deadline-retry-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await log.configure(configuration: configuration)
        // A refused event keeps the deadline behind it until the shared
        // route timer succeeds, without a new capture or replay request.
        log.track("earlier")
        await log.enqueueJourneyDeadline(.init(distinctId: "customer-a", runId: "run", stepId: "wait",
            anchorAt: nil, wakeAt: clock.now()))
        log.track("later")
        await log.drain()
        let blocked = await observed.snapshot()
        XCTAssertEqual(blocked, [])
        for _ in 0..<300 {
            if await observed.snapshot().count == 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let recovered = await observed.snapshot()
        XCTAssertEqual(recovered, ["earlier", "deadline", "later"])
        await log.close()
    }

    func testUnavailableDeadlineIsRetainedWithoutBlockingUnrelatedEvents() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let clock = MockDateProvider()
        let log = EventLog(identity: identity, dateProvider: clock,
                           apiClient: MockNuxieApi(), store: MockEventStore())
        let observed = RecoveredRouteRecorder()
        await log.setJourneyDeadlineHandler { _ in
            await observed.append("unavailable-deadline")
            return .failed
        }
        await log.subscribeCommitted { event in await observed.append(event.name) }
        let configuration = NuxieConfiguration(apiKey: "deadline-consumption-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        try await log.configure(configuration: configuration)
        await log.enqueueJourneyDeadline(.init(distinctId: "customer-a", runId: "run", stepId: "wait",
            anchorAt: nil, wakeAt: clock.now()))
        log.track("later")
        await log.drain()
        let order = await observed.snapshot()
        XCTAssertEqual(order, ["unavailable-deadline", "later"])
        let drained = await log.drainCommittedRouting()
        XCTAssertTrue(drained)
        await log.close()
    }

    func testDeadlinesAndLaterEventsPassDeliveredReceiptsWhoseAcknowledgementFails() async throws {
        for failStableReceipt in [true, false] {
            let identity = MockIdentityService()
            identity.setDistinctId("customer-a")
            let store = MockEventStore()
            store.shouldFailStableRouteAcknowledgement = failStableReceipt
            store.shouldFailMarkDelivered = !failStableReceipt
            let clock = MockDateProvider()
            let log = EventLog(identity: identity, dateProvider: clock, apiClient: MockNuxieApi(), store: store)
            let observed = RecoveredRouteRecorder()
            await log.subscribeCommitted { event in await observed.append(event.name) }
            await log.setJourneyDeadlineHandler { _ in
                await observed.append("deadline")
                return .done
            }
            let configuration = NuxieConfiguration(apiKey: "delivered-receipt-deadline-test")
            configuration.testingOverrides.suppressBackgroundWork = true
            try await log.configure(configuration: configuration)
            if failStableReceipt {
                _ = await log.captureAndRouteSystemEvent(.init(name: "earlier", properties: nil,
                    eventId: "earlier", distinctId: "customer-a"))
            } else {
                // An ordinary capture isolates committed-route cleanup from
                // the stable receipt failure exercised by the other case.
                log.track("earlier")
            }
            await log.enqueueJourneyDeadline(.init(distinctId: "customer-a", runId: "run", stepId: "wait",
                anchorAt: nil, wakeAt: clock.now()))
            log.track("later")
            await log.drain()
            let order = await observed.snapshot()
            XCTAssertEqual(order, ["earlier", "deadline", "later"])
            XCTAssertFalse(store.pendingCommittedRoutes.isEmpty)
            // Clearing Journey execution cannot retire EventLog's durable
            // receipt cleanup. It keeps the same queue-owned retry entry.
            await log.cancelJourneyWork(distinctId: "customer-a")
            store.shouldFailStableRouteAcknowledgement = false
            store.shouldFailMarkDelivered = false
            for _ in 0..<300 where !store.pendingCommittedRoutes.isEmpty {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(store.pendingCommittedRoutes.isEmpty,
                          "Receipt acknowledgement retries independently of local delivery")
            let afterCleanup = await observed.snapshot()
            XCTAssertEqual(afterCleanup, order, "Cleanup must not redeliver completed subscribers")
            await log.close()
        }
    }

    func testBestEffortFallbackIsBoundedAndKeepsItsPlaceBetweenDurableCaptures() async throws {
        let store = MockEventStore()
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let log = EventLog(identity: identity, dateProvider: MockDateProvider(),
            apiClient: MockNuxieApi(), store: store)
        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        configuration.testingOverrides.suppressBackgroundWork = true
        configuration.testingOverrides.maxQueueSize = 2
        let generation = RecoveryAdmission()
        let received = RecoveredRouteRecorder()
        let reservation = log.reserveCommittedAdmission { generation.value }
        await log.subscribeAcknowledgingCommitted(reservation: reservation) { event, admission in
            guard generation.value == 2, admission == 1 else { return false }
            await received.append(event.name)
            return true
        }
        try await log.configure(configuration: configuration)
        log.track("before")
        await log.drain()
        store.shouldFailStore = true
        for index in 0..<3 { log.track("undurable-\(index)") }
        await log.drain()
        store.shouldFailStore = false
        log.track("after")
        await log.drain()
        let buffered = await log.bufferedCommittedRouteCount
        XCTAssertEqual(buffered, 3, "One durable retry plus two best-effort events")
        XCTAssertEqual(store.pendingCommittedRoutes.map(\.event.name), ["before", "after"])
        generation.advance()
        let recovered = await log.replayPendingStableRoutes(distinctId: "customer-a")
        XCTAssertTrue(recovered)
        for _ in 0..<500 {
            if await received.snapshot().count == 4 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await log.drain()
        let delivered = await received.snapshot()
        XCTAssertEqual(delivered, ["before", "undurable-0", "undurable-1", "after"])
        XCTAssertTrue(store.pendingCommittedRoutes.isEmpty)
        await log.close()
    }

    /// A hold releases its retained prefix without resetting an earlier
    /// refused route's retry interval. An older hold releases nothing.
    func testReleasingAHoldReturnsOnceWhatItKeptIsDelivered() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let log = EventLog(identity: identity, dateProvider: MockDateProvider(),
            apiClient: MockNuxieApi(), store: MockEventStore())
        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        configuration.testingOverrides.suppressBackgroundWork = true
        let accepting = RecoveryAdmission()
        let received = RecoveredRouteRecorder()
        let reservation = log.reserveCommittedAdmission { 1 }
        await log.subscribeAcknowledgingCommitted(reservation: reservation) { event, _ in
            guard accepting.value == 2 else { return false }
            await received.append(event.name)
            return true
        }
        try await log.configure(configuration: configuration)
        log.track("refused")
        await log.drain()
        let older = await log.deferCommittedRouting()
        let hold = await log.deferCommittedRouting()
        log.track("held")
        _ = await log.flushEvents()
        accepting.advance()

        let releasedOlder = await log.releaseCommittedRouting(ifGeneration: older)
        XCTAssertFalse(releasedOlder)
        let beforeRelease = await received.snapshot()
        XCTAssertEqual(beforeRelease, [])

        let released = await log.releaseCommittedRouting(ifGeneration: hold)
        if !released {
            for _ in 0..<500 {
                if await received.snapshot().count == 2 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let delivered = await received.snapshot()
        XCTAssertEqual(delivered, ["refused", "held"])
        await log.close()
    }

    /// An event accepted just before the release is still being committed:
    /// the release waits for it, so it joins the prefix the hold kept.
    func testReleasingAHoldWaitsForCapturesAcceptedBeforeIt() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = MockEventStore()
        let log = EventLog(identity: identity, dateProvider: MockDateProvider(),
            apiClient: MockNuxieApi(), store: store)
        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        configuration.testingOverrides.suppressBackgroundWork = true
        let received = RecoveredRouteRecorder()
        let reservation = log.reserveCommittedAdmission { 1 }
        await log.subscribeAcknowledgingCommitted(reservation: reservation) { event, _ in
            await received.append(event.name)
            return true
        }
        try await log.configure(configuration: configuration)
        let hold = await log.deferCommittedRouting()
        store.suspendNextInsert()
        log.track("held")
        for _ in 0..<200 where store.waitingInsertIds.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let insert = try XCTUnwrap(store.waitingInsertIds.first)
        let returned = RecoveredRouteRecorder()
        let release = Task {
            let released = await log.releaseCommittedRouting(ifGeneration: hold)
            await returned.append("returned")
            return released
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let returnedEarly = await returned.snapshot()
        XCTAssertEqual(returnedEarly, [], "The release waits for the capture it was sent after")

        store.resumeInsert(id: insert)
        let released = await release.value
        XCTAssertTrue(released)
        let delivered = await received.snapshot()
        XCTAssertEqual(delivered, ["held"])
        await log.close()
    }

    func testFailedSubscriberKeepsDurableBacklogOnDiskAndReplaysInCaptureOrder() async throws {
        let stores: [any EventStoreProtocol] = [MockEventStore(), SQLiteEventStore()]
        for store in stores {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("live-backlog-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let identity = MockIdentityService()
            identity.setDistinctId("customer-a")
            let log = EventLog(identity: identity, dateProvider: MockDateProvider(),
                apiClient: MockNuxieApi(), store: store)
            let configuration = NuxieConfiguration(apiKey: "test-api-key")
            configuration.testingOverrides.suppressBackgroundWork = true
            configuration.testingOverrides.customStoragePath = directory
            let generation = RecoveryAdmission()
            let received = RecoveredRouteRecorder()
            let reservation = log.reserveCommittedAdmission { generation.value }
            await log.subscribeAcknowledgingCommitted(reservation: reservation) { event, admission in
                guard generation.value == 2, admission == 1 else { return false }
                await received.append(event.name)
                return true
            }
            try await log.configure(configuration: configuration)
            let expected = (0..<257).map { "captured-\($0)" }
            for name in expected { log.track(name) }
            await log.drain()
            let buffered = await log.bufferedCommittedRouteCount
            XCTAssertEqual(buffered, 1)
            let storedCount = try await store.getEventCount()
            XCTAssertEqual(storedCount, expected.count)
            generation.advance()
            let replayed = await log.replayPendingStableRoutes(distinctId: "customer-a")
            XCTAssertTrue(replayed)
            for _ in 0..<1000 {
                if await received.snapshot().count == expected.count { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            await log.drain()
            let delivered = await received.snapshot()
            XCTAssertEqual(delivered, expected)
            let remaining = await log.bufferedCommittedRouteCount
            XCTAssertEqual(remaining, 0)
            await log.close()
        }
    }

    func testLiveCapturePersistsOriginalAdmissionsAndAcknowledgesOnlyAfterDelivery() async throws {
        let store = MockEventStore()
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let log = EventLog(identity: identity, dateProvider: MockDateProvider(),
            apiClient: MockNuxieApi(), store: store)
        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        configuration.testingOverrides.suppressBackgroundWork = true
        let generation = RecoveryAdmission()
        let firstSubscriber = RecoveredRouteRecorder()
        let lastSubscriber = RecoveredRouteRecorder()
        await log.subscribeCommitted { event in await firstSubscriber.append(event.name) }
        let reservation = log.reserveCommittedAdmission { generation.value }
        await log.subscribeAcknowledgingCommitted(reservation: reservation) { event, admission in
            guard generation.value == 2 else { return false }
            guard admission == 1 else { return false }
            await lastSubscriber.append(event.name)
            return true
        }
        try await log.configure(configuration: configuration)
        log.track("ordinary")
        _ = await log.captureAndRouteSystemEvent(.init(name: "stable", properties: nil,
            eventId: "stable", distinctId: "customer-a"))
        await log.drain()
        let retained = store.pendingCommittedRoutes
        XCTAssertEqual(retained.map(\.event.name), ["ordinary", "stable"])
        XCTAssertEqual(retained.first?.nextSubscriber, 1)
        XCTAssertEqual(retained.last?.nextSubscriber, 0)
        XCTAssertTrue(retained.allSatisfy {
            $0.admission.subscribers[reservation.subscriberIdentifier] == 1
        })
        generation.advance()
        let recovered = await log.replayPendingStableRoutes(distinctId: "customer-a")
        XCTAssertTrue(recovered)
        for _ in 0..<500 where !store.pendingCommittedRoutes.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(store.pendingCommittedRoutes.isEmpty)
        let firstNames = await firstSubscriber.snapshot()
        let lastNames = await lastSubscriber.snapshot()
        XCTAssertEqual(firstNames, ["ordinary", "stable"])
        XCTAssertEqual(lastNames, ["ordinary", "stable"])
        await log.close()
    }

    func testStableBatchDeliveryAdmissionsAreAtomicAndNeverRefreshedOnRetry() async throws {
        for store: any EventStoreProtocol in [SQLiteEventStore(), MockEventStore()] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("stable-route-admission-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try await store.initialize(path: directory)
            let timestamp = Date()
            let events = try ["first", "second"].map {
                try StoredEvent(id: $0, name: "outcome", properties: [:],
                    timestamp: timestamp, distinctId: "customer-a")
            }
            func originalAdmission(_ id: String) -> CommittedRouteAdmission {
                .init(sessionId: "original", subscribers: [7: 1], stableRouteEventId: id)
            }
            // The first capture succeeds inside the transaction; staging the
            // second without a sequence must roll back both captures.
            let invalid = events.enumerated().map { index, event in
                StableEventCaptureRecord(eventId: event.id, event: event, recordedAt: timestamp,
                    routeAdmission: index == 0 ? nil : originalAdmission(event.id))
            }
            do {
                _ = try await store.commitStableCaptureBatchAndStageRoutes(invalid,
                    assigningCommitSequence: false, admission: nil)
                XCTFail("A batch with an unorderable local route must roll back")
            } catch {}
            let rolledBackCount = try await store.getEventCount()
            let rolledBackRoutes = try await store.queryPendingStableRoutes(distinctId: "customer-a", limit: 2)
            XCTAssertEqual(rolledBackCount, 0)
            XCTAssertTrue(rolledBackRoutes.isEmpty)
            let records = events.map {
                StableEventCaptureRecord(eventId: $0.id, event: $0, recordedAt: timestamp,
                    routeAdmission: originalAdmission($0.id))
            }
            let committed = try await store.commitStableCaptureBatchAndStageRoutes(records,
                assigningCommitSequence: true, admission: nil)
            XCTAssertEqual(committed.map(\.commitSequence), [0, 1])
            try await store.checkpointCommittedRoute(eventId: "first", sessionId: "original", nextSubscriber: 1)
            let replacement = CommittedRouteAdmission(sessionId: "replacement",
                subscribers: [7: 2], stableRouteEventId: "first")
            _ = try await store.commitStableCaptureAndStageRoute(eventId: "first", event: nil,
                recordedAt: timestamp, assigningCommitSequence: true, admission: nil,
                routeAdmission: replacement)
            let first = try await store.firstPendingCommittedRoute(sessionId: "original")
            let refreshed = try await store.firstPendingCommittedRoute(sessionId: "replacement")
            XCTAssertEqual(first?.event.id, "first")
            XCTAssertEqual(first?.admission, originalAdmission("first"))
            XCTAssertEqual(first?.nextSubscriber, 1)
            XCTAssertNil(refreshed)
            let beyondDelivered = try await store.firstPendingCommittedRoute(sessionId: "original", afterSequence: 0)
            XCTAssertEqual(beyondDelivered?.event.id, "second", "A retained delivered receipt must not fence later routes")
            let beyondAll = try await store.firstPendingCommittedRoute(sessionId: "original", afterSequence: 1)
            XCTAssertNil(beyondAll)
            try await store.markStableRouteDelivered(eventId: "first")
            try await store.acknowledgeCommittedRoute(eventId: "first", sessionId: "original")
            let replay = try await store.commitStableCaptureAndStageRoute(eventId: "first", event: nil,
                recordedAt: timestamp, assigningCommitSequence: true, admission: nil,
                routeAdmission: replacement)
            XCTAssertFalse(replay.localRoutePending)
            let second = try await store.firstPendingCommittedRoute(sessionId: "original")
            let restaged = try await store.firstPendingCommittedRoute(sessionId: "replacement")
            XCTAssertEqual(second?.event.id, "second")
            XCTAssertNil(restaged)
            await store.close()
        }
    }

    func testHistoryPruningRetainsLocalDeliveryUntilAcknowledged() async throws {
        for pruneByAge in [true, false] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("route-retention-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = SQLiteEventStore()
            try await store.initialize(path: directory)
            let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
            _ = try await store.readOrInitializeHistoryCoverage(startingAt: timestamp)
            let ordinary = try StoredEvent(id: "ordinary", name: "outcome", properties: [:],
                timestamp: timestamp, distinctId: "customer-a")
            let stable = try StoredEvent(id: "stable", name: "outcome", properties: [:],
                timestamp: timestamp, distinctId: "customer-a")
            _ = try await store.insert(ordinary, deliveryState: .pending, origin: .device,
                assigningCommitSequence: true, routeAdmission: .init(
                    sessionId: "session", subscribers: [1: 1], stableRouteEventId: nil))
            _ = try await store.commitStableCaptureAndStageRoute(eventId: stable.id,
                event: stable, recordedAt: timestamp, assigningCommitSequence: true, admission: nil)
            try await store.markDelivered(ids: [ordinary.id, stable.id])
            let cutoff = pruneByAge ? timestamp.addingTimeInterval(1) : timestamp
            let keeping = pruneByAge ? 100 : 0
            let retained = try await store.pruneHistory(keeping: keeping, olderThan: cutoff)
            XCTAssertEqual(retained.ageDeleted + retained.countDeleted, 0)
            let pendingOrdinary = try await store.firstPendingCommittedRoute(sessionId: "session")
            let pendingStable = try await store.queryPendingStableRoutes(distinctId: "customer-a", limit: 1)
            XCTAssertEqual(pendingOrdinary?.event.id, ordinary.id)
            XCTAssertEqual(pendingStable.map(\.id), [stable.id])
            try await store.acknowledgeCommittedRoute(eventId: ordinary.id, sessionId: "session")
            try await store.markStableRouteDelivered(eventId: stable.id)
            let released = try await store.pruneHistory(keeping: keeping, olderThan: cutoff)
            XCTAssertEqual(released.ageDeleted + released.countDeleted, 2)
            await store.close()
        }
    }

    func testCommittedRouteAdmissionIsAtomicAndRetainsItsOriginalRetryPosition() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("route-checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteEventStore()
        try await store.initialize(path: directory)
        let event = try StoredEvent(id: "outcome", name: "outcome", properties: [:],
            timestamp: Date(), distinctId: "customer-a")
        let originalAdmission = CommittedRouteAdmission(
            sessionId: "original-session", subscribers: [7: UInt64.max], stableRouteEventId: nil
        )
        do {
            _ = try await store.insert(event, deliveryState: .pending, origin: .device,
                assigningCommitSequence: false, routeAdmission: originalAdmission)
            XCTFail("Routing without a commit sequence must roll back the event and inbox")
        } catch {}
        let rolledBackCount = try await store.getEventCount()
        let rolledBackInbox = try await store.measurementInputs(distinctId: "customer-a")
        XCTAssertEqual(rolledBackCount, 0)
        XCTAssertTrue(rolledBackInbox.isEmpty)
        let inserted = try await store.insert(event, deliveryState: .pending, origin: .device,
            assigningCommitSequence: true, routeAdmission: originalAdmission)
        XCTAssertEqual(inserted.commitSequence, 0)
        let replacement = CommittedRouteAdmission(
            sessionId: "replacement-session", subscribers: [7: 2], stableRouteEventId: nil
        )
        let duplicate = try await store.insert(event, deliveryState: .pending, origin: .device,
            assigningCommitSequence: true, routeAdmission: replacement)
        XCTAssertFalse(duplicate.newlyDurable)
        let replacementRoute = try await store.firstPendingCommittedRoute(sessionId: replacement.sessionId)
        XCTAssertNil(replacementRoute)
        try await store.checkpointCommittedRoute(eventId: event.id,
            sessionId: originalAdmission.sessionId, nextSubscriber: 2)
        await store.close()
        let reopened = SQLiteEventStore()
        try await reopened.initialize(path: directory)
        let pending = try await reopened.firstPendingCommittedRoute(sessionId: originalAdmission.sessionId)
        XCTAssertEqual(pending?.admission, originalAdmission)
        XCTAssertEqual(pending?.nextSubscriber, 2)
        XCTAssertEqual(pending?.event.id, event.id)
        try await reopened.acknowledgeCommittedRoute(eventId: event.id, sessionId: replacement.sessionId)
        let stillPending = try await reopened.firstPendingCommittedRoute(sessionId: originalAdmission.sessionId)
        XCTAssertNotNil(stillPending)
        try await reopened.discardOtherCommittedRouteSessions(keeping: replacement.sessionId)
        let discarded = try await reopened.firstPendingCommittedRoute(sessionId: originalAdmission.sessionId)
        XCTAssertNil(discarded)
        let retainedEventCount = try await reopened.getEventCount()
        let retainedInbox = try await reopened.measurementInputs(distinctId: "customer-a")
        XCTAssertEqual(retainedEventCount, 1)
        XCTAssertEqual(retainedInbox.map(\.event.id), [event.id])
        await reopened.close()
    }

    func testPagedVisitAcknowledgesTheEntireOriginalPrefixBeforeNewCaptures() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("route-pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteEventStore()
        try await store.initialize(path: directory.appendingPathComponent("events.sqlite"))
        let expected = (0..<205).map { "retained-\($0)" }
        for id in expected {
            let event = try StoredEvent(id: id, name: "retained", properties: [:],
                timestamp: Date(), distinctId: "customer-a")
            _ = try await store.commitStableCaptureAndStageRoute(
                eventId: id, event: event, recordedAt: event.timestamp,
                assigningCommitSequence: false, admission: nil
            )
        }
        let recorder = RecoveredRouteRecorder()
        let completed = try await store.visitPendingStableRoutes(distinctId: "customer-a") { event in
            await recorder.append(event.id)
            do {
                if event.id == "retained-99" {
                    let newer = try StoredEvent(id: "newer", name: "newer", properties: [:],
                        timestamp: Date(), distinctId: "customer-a")
                    _ = try await store.commitStableCaptureAndStageRoute(
                        eventId: newer.id, event: newer, recordedAt: newer.timestamp,
                        assigningCommitSequence: false, admission: nil
                    )
                }
                try await store.markStableRouteDelivered(eventId: event.id)
                return true
            } catch { return false }
        }
        XCTAssertTrue(completed)
        let visited = await recorder.snapshot()
        XCTAssertEqual(visited, expected)
        let pending = try await store.queryPendingStableRoutes(distinctId: "customer-a", limit: 10)
        XCTAssertEqual(pending.map(\.id), ["newer"])
        let refused = try await store.visitPendingStableRoutes(distinctId: "customer-a") { _ in false }
        XCTAssertFalse(refused)
        let stillPending = try await store.queryPendingStableRoutes(distinctId: "customer-a", limit: 10)
        XCTAssertEqual(stillPending.map(\.id), ["newer"])
        await store.close()
    }

    func testRecoveryKeepsAdmissionsAndCaptureOrderAcrossPages() async throws {
        try await assertPagedRecovery(interruptWithNewGate: false)
    }

    func testRecoveryStopsBeforeCrossingANewerRecoveryGate() async throws {
        try await assertPagedRecovery(interruptWithNewGate: true)
    }

    private func assertPagedRecovery(interruptWithNewGate: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("route-admissions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = SQLiteEventStore()
        try await original.initialize(path: directory)
        let retained = (0..<205).map { "retained-\($0)" }
        for id in retained {
            let event = try StoredEvent(id: id, name: "retained", properties: [:],
                timestamp: Date(), distinctId: "customer-a")
            _ = try await original.commitStableCaptureAndStageRoute(
                eventId: id, event: event, recordedAt: event.timestamp,
                assigningCommitSequence: false, admission: nil
            )
        }
        await original.close()
        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        configuration.testingOverrides.customStoragePath = directory
        configuration.testingOverrides.suppressBackgroundWork = true
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = SQLiteEventStore()
        let log = EventLog(identity: identity, dateProvider: MockDateProvider(),
            apiClient: MockNuxieApi(), store: store)
        _ = await log.deferCommittedRouting()
        let admissions = RecoveryAdmission()
        let recorder = RecoveredRouteRecorder()
        let reservation = log.reserveCommittedAdmission { admissions.value }
        await log.subscribeAcknowledgingCommitted(reservation: reservation) { [weak log] event, admission in
            await recorder.append("\(event.id):\(admission ?? 0)")
            if event.id == "retained-99" {
                admissions.advance()
                guard let captured = await log?.captureAndRouteSystemEvent(.init(
                    name: "newer", properties: nil, eventId: "newer", distinctId: "customer-a"
                )), captured.event.id == "newer" else { return false }
                if interruptWithNewGate { _ = await log?.deferCommittedRouting() }
            }
            return true
        }
        try await log.configure(configuration: configuration)
        let firstReplay = await log.replayPendingStableRoutes(distinctId: "customer-a")
        if interruptWithNewGate {
            XCTAssertFalse(firstReplay)
            let beforeReopening = await recorder.snapshot()
            XCTAssertEqual(beforeReopening, retained.prefix(100).map { "\($0):1" })
            let resumed = await log.replayPendingStableRoutes(distinctId: "customer-a")
            XCTAssertTrue(resumed)
        }
        await log.drain()
        let visited = await recorder.snapshot()
        let expected = retained.enumerated().map { index, id in
            "\(id):\(interruptWithNewGate && index >= 100 ? 2 : 1)"
        } + ["newer:2"]
        XCTAssertEqual(visited, expected)
        let drained = await log.replayPendingStableRoutes(distinctId: "customer-a")
        XCTAssertTrue(drained)
        let afterReplay = await recorder.snapshot()
        XCTAssertEqual(afterReplay, visited)
        await log.close()
    }

    func testFailedDeliverySurvivesSQLiteReopenWithoutCrossCustomerReplay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("route-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        configuration.testingOverrides.customStoragePath = directory
        configuration.testingOverrides.flushAt = 100
        configuration.testingOverrides.suppressBackgroundWork = true
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let originalStore = SQLiteEventStore()
        let original = EventLog(identity: identity, dateProvider: MockDateProvider(),
            apiClient: MockNuxieApi(), store: originalStore)
        let reservation = original.reserveCommittedAdmission { 1 }
        await original.subscribeAcknowledgingCommitted(reservation: reservation) { _, _ in false }
        try await original.configure(configuration: configuration)
        for id in ["entry", "goal"] {
            _ = await original.captureAndRouteSystemEvent(.init(
                name: id, properties: nil, eventId: id, distinctId: "customer-a"
            ))
        }
        let drained = await original.drainCommittedRouting()
        XCTAssertFalse(drained)
        let pendingBeforeClose = try await originalStore.queryPendingStableRoutes(distinctId: "customer-a", limit: 100)
        XCTAssertEqual(pendingBeforeClose.map(\.id), ["entry", "goal"])
        let firstPending = try await originalStore.queryPendingStableRoutes(
            distinctId: "customer-a", limit: 1
        )
        XCTAssertEqual(firstPending.map(\.id), ["entry"])
        let noRows = try await originalStore.queryPendingStableRoutes(
            distinctId: "customer-a", limit: 0
        )
        XCTAssertTrue(noRows.isEmpty)
        let firstPendingId = try await original.firstPendingStableRouteEventId(distinctId: "customer-a")
        XCTAssertEqual(firstPendingId, "entry")
        await original.close()

        identity.setDistinctId("customer-b")
        let reopenedStore = SQLiteEventStore()
        let reopened = EventLog(identity: identity, dateProvider: MockDateProvider(),
            apiClient: MockNuxieApi(), store: reopenedStore)
        let recovered = RecoveredRouteRecorder()
        let replayReservation = reopened.reserveCommittedAdmission { 2 }
        await reopened.subscribeAcknowledgingCommitted(reservation: replayReservation) { event, generation in
            guard generation == 2 else { return false }
            await recovered.append(event.id)
            return true
        }
        try await reopened.configure(configuration: configuration)
        let otherCustomer = await reopened.replayPendingStableRoutes(distinctId: "customer-b")
        XCTAssertTrue(otherCustomer)
        let otherCustomerRoutes = await recovered.snapshot()
        XCTAssertEqual(otherCustomerRoutes, [])
        let retained = try await reopenedStore.queryPendingStableRoutes(distinctId: "customer-a", limit: 100)
        XCTAssertEqual(retained.map(\.id), ["entry", "goal"])

        identity.setDistinctId("customer-a")
        let replayed = await reopened.replayPendingStableRoutes(distinctId: "customer-a")
        XCTAssertTrue(replayed)
        let recoveredIds = await recovered.snapshot()
        XCTAssertEqual(recoveredIds, ["entry", "goal"])
        let remaining = try await reopenedStore.queryPendingStableRoutes(distinctId: "customer-a", limit: 100)
        XCTAssertTrue(remaining.isEmpty)
        let deliveryCount = try await reopenedStore.getPendingDeliveryCount()
        XCTAssertEqual(deliveryCount, 2)
        let measurement = try await reopenedStore.measurementInputs(distinctId: "customer-a")
        XCTAssertEqual(measurement.map(\.event.id), ["entry", "goal"])
        await reopened.close()
    }
}
