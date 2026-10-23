import Foundation
import Nimble
import Quick
import XCTest
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private struct FeatureCommandWaitTimedOut: Error, CustomStringConvertible, LocalizedError {
    let operation: String
    var description: String { "Timed out waiting for \(operation)" }
    var errorDescription: String? { description }
}

/// Resume the test even if the operation ignores task cancellation. A task
/// group would join that blocked operation after its timeout child finished.
@MainActor
private final class FeatureCommandWait<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    var operationTask: Task<Void, Never>?
    var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        operationTask?.cancel()
        timeoutTask?.cancel()
        operationTask = nil
        timeoutTask = nil
        continuation.resume(with: result)
    }
}

@MainActor
private func featureCommandAwait<Value: Sendable>(
    _ operationName: String,
    timeoutNanoseconds: UInt64 = 10_000_000_000,
    operation: @escaping @MainActor () async throws -> Value
) async throws -> Value {
    try Task.checkCancellation()
    return try await withCheckedThrowingContinuation { continuation in
        let wait = FeatureCommandWait<Value>(continuation)
        wait.operationTask = Task { @MainActor in
            do {
                try Task.checkCancellation()
                let value = try await operation()
                try Task.checkCancellation()
                wait.finish(.success(value))
            } catch {
                wait.finish(.failure(error))
            }
        }
        wait.timeoutTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
            catch { return }
            wait.finish(.failure(FeatureCommandWaitTimedOut(operation: operationName)))
        }
    }
}

private actor FeatureCommandForwardingRecorder {
    private var events: [NuxieEvent] = []

    func record(_ event: DurableForwardingEvent) {
        events.append(event.event)
    }

    func snapshot() -> [String] { events.map(\.id) }

    func eventSnapshot() -> [NuxieEvent] { events }
}

private actor OrchestrationLocalDeliveryGate {
    private var accepting = false
    private(set) var refusals = 0
    private(set) var delivered: [String] = []

    func handle(_ event: NuxieEvent) -> Bool {
        guard ["retry_head", "retry_follower"].contains(event.name) else { return true }
        guard accepting else { refusals += 1; return false }
        delivered.append(event.name)
        return true
    }

    func accept() { accepting = true }
}

/// Durable Feature-command coverage over the production composition root and
/// stores. The transport is mocked, but its accepted-then-timeout behavior
/// models the ambiguity that requires server and client idempotency.
final class FeatureCommandOrchestrationTests: AsyncSpec {
    override class func spec() {
        describe("feature command orchestration") {
            var storageURL: URL!
            var first: OrchestrationStack?
            var relaunched: OrchestrationStack?

            beforeEach {
                storageURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("nuxie-feature-command-\(UUID().uuidString)")
            }

            afterEach {
                let stacks = [first, relaunched].compactMap { $0 }
                first = nil
                relaunched = nil
                var cleaned = true
                for (index, stack) in stacks.enumerated() {
                    do {
                        try await featureCommandAwait("stack \(index) teardown") {
                            await stack.shutdownForCleanup()
                        }
                    } catch {
                        cleaned = false
                        XCTFail(String(describing: error))
                    }
                }
                if cleaned, let storageURL {
                    try? FileManager.default.removeItem(at: storageURL)
                }
            }

            it("bounds a drain behind an explicit hold and releases its suspended barrier") {
                first = try await featureCommandAwait("boot held-drain stack") {
                    try await OrchestrationStack.boot(
                        storageURL: storageURL,
                        api: MockNuxieApi(),
                        dateProvider: MockDateProvider(),
                        sleepProvider: MockSleepProvider(),
                        distinctId: "held-drain-customer",
                        configure: { $0.testingOverrides.suppressBackgroundWork = true }
                    )
                }
                let stack = try unwrap(first)
                let hold = try await featureCommandAwait("hold routing") {
                    await stack.eventLog.deferCommittedRouting()
                }
                var drainStarted = false
                do {
                    try await featureCommandAwait("intentionally held drain", timeoutNanoseconds: 100_000_000) {
                        drainStarted = true
                        await stack.eventLog.drain()
                    }
                    XCTFail("The explicit hold must retain the drain barrier")
                } catch let error as FeatureCommandWaitTimedOut {
                    expect(error.operation).to(equal("intentionally held drain"))
                }
                expect(drainStarted).to(beTrue())
                // The timeout cancels its task, but that task is still waiting
                // on a continuation. Releasing the hold must settle it safely.
                let released = try await featureCommandAwait("release held drain") {
                    await stack.eventLog.releaseCommittedRouting(ifGeneration: hold)
                }
                expect(released).to(beTrue())
                try await featureCommandAwait("drain after releasing hold") {
                    await stack.eventLog.drain()
                }
            }

            it("automatically retries a refused local head and releases later captures without a deadline") {
                let gate = OrchestrationLocalDeliveryGate()
                let date = MockDateProvider()
                let originalDate = date.now()
                let sleep = MockSleepProvider()
                first = try await featureCommandAwait("boot orchestration stack") {
                    try await OrchestrationStack.boot(
                        storageURL: storageURL,
                        api: MockNuxieApi(),
                        dateProvider: date,
                        sleepProvider: sleep,
                        distinctId: "local-retry-customer",
                        localDeliveryHandler: { event, _ in await gate.handle(event) },
                        configure: { $0.testingOverrides.suppressBackgroundWork = true }
                    )
                }
                let stack = try unwrap(first)
                stack.eventLog.track("retry_head", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                stack.eventLog.track("retry_follower", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                try await featureCommandAwait("drain with a refused local head") {
                    await stack.eventLog.drain()
                }
                let refusedDrain = try await featureCommandAwait("inspect the refused local head") {
                    await stack.eventLog.drainCommittedRouting()
                }
                expect(refusedDrain).to(beFalse())
                // No replay, clock advance, mock sleep completion, or new
                // capture drives this retry: the production route timer does.
                try await featureCommandAwait("automatic retry of the refused local head") {
                    while await gate.refusals < 2 {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
                let refusals = try await featureCommandAwait("read local delivery refusals") {
                    await gate.refusals
                }
                let blocked = try await featureCommandAwait("read local deliveries") {
                    await gate.delivered
                }
                expect(refusals).to(beGreaterThanOrEqualTo(2))
                expect(blocked).to(beEmpty())
                try await featureCommandAwait("accept local deliveries") {
                    await gate.accept()
                }
                try await featureCommandAwait("automatic release of the follower") {
                    while await gate.delivered.count < 2 {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
                try await featureCommandAwait("drain local event delivery") {
                    await stack.eventLog.drain()
                }
                let delivered = try await featureCommandAwait("read local deliveries") {
                    await gate.delivered
                }
                expect(delivered).to(equal(["retry_head", "retry_follower"]))
                let drained = try await featureCommandAwait("drain committed routing") {
                    await stack.eventLog.drainCommittedRouting()
                }
                expect(drained).to(beTrue())
                let history = try await featureCommandAwait("read local retry history") {
                    await stack.eventLog.getEventsForUser("local-retry-customer", limit: 20)
                }
                expect(history.filter { $0.name.hasPrefix("retry_") }.count).to(equal(2))
                expect(date.now()).to(equal(originalDate))
                expect(sleep.pendingSleepDurations).to(beEmpty())
            }

            it("retries an accepted timeout without overwriting a newer profile balance") {
                let api = MockNuxieApi()
                try await featureCommandAwait("configure feature response") {
                    await api.configureTrackEventResponse(
                        status: "ok",
                        usage: .init(current: 6, limit: 10, remaining: 4)
                    )
                }
                try await featureCommandAwait("configure accepted timeout") {
                    await api.setAcceptedTrackEventTimeouts(1)
                }
                let date = MockDateProvider(
                    initialDate: Date(timeIntervalSince1970: 1_788_000_000)
                )
                let sleep = MockSleepProvider()
                let forwarding = FeatureCommandForwardingRecorder()
                first = try await featureCommandAwait("boot orchestration stack") {
                    try await OrchestrationStack.boot(
                        storageURL: storageURL,
                        api: api,
                        dateProvider: date,
                        sleepProvider: sleep,
                        distinctId: "feature-customer",
                        initialFeatureAccess: [
                            "ai_generations": .withBalance(
                                5,
                                unlimited: false,
                                type: .creditSystem
                            )
                        ],
                        forwardingHandler: { event in
                            await forwarding.record(event)
                        }
                    )
                }
                let firstStack = try unwrap(first)

                do {
                    _ = try await featureCommandAwait("consume feature with accepted timeout") {
                        try await firstStack.core.featureUseCommands.use(
                            distinctId: "feature-customer",
                            featureId: "ai_generations",
                            amount: 1,
                            entityId: "project-7",
                            setUsage: false,
                            metadata: ["model": "study-review"]
                        )
                    }
                    XCTFail("Expected the accepted request to time out")
                } catch NuxieNetworkError.timeout {}

                let firstSentEvents = try await featureCommandAwait("read API sent events") {
                    await api.sentEvents
                }
                let firstWire = try unwrap(firstSentEvents.last {
                    $0.name == SystemEventNames.featureUsed
                })
                let firstPendingCount = try await featureCommandAwait("read initial pending commands") {
                    try await firstStack.core.featureUseCommands.pendingCount()
                }
                expect(firstPendingCount).to(equal(1))
                try await featureCommandAwait("close initial event log") {
                    await firstStack.kill()
                }
                first = nil
                date.advance(by: 1)

                relaunched = try await featureCommandAwait("boot orchestration stack") {
                    try await OrchestrationStack.boot(
                        storageURL: storageURL,
                        api: api,
                        dateProvider: date,
                        sleepProvider: sleep,
                        distinctId: "feature-customer",
                        initialFeatureAccess: [
                            "ai_generations": .withBalance(
                                5,
                                unlimited: false,
                                type: .creditSystem
                            )
                        ],
                        forwardingHandler: { event in
                            await forwarding.record(event)
                        }
                    )
                }
                let relaunchedStack = try unwrap(relaunched)

                let featureSends = try await featureCommandAwait("read API sent events") {
                    await api.sentEvents
                        .filter { $0.name == SystemEventNames.featureUsed }
                }
                expect(featureSends.map(\.id)).to(equal([firstWire.id, firstWire.id]))
                let uniqueAcceptedCount = try await featureCommandAwait("read unique accepted commands") {
                    await api.uniqueAcceptedTrackEventCount
                }
                expect(uniqueAcceptedCount).to(equal(1))
                let relaunchedPendingCount = try await featureCommandAwait("read relaunched pending commands") {
                    try await relaunchedStack.core.featureUseCommands.pendingCount()
                }
                expect(relaunchedPendingCount).to(equal(0))

                let mirrored = try await featureCommandAwait("read relaunched mirrored events") {
                    await relaunchedStack.eventLog.getRecentEvents(limit: 20)
                        .filter { $0.name == SystemEventNames.featureUsed }
                }
                expect(mirrored.map(\.id)).to(equal([firstWire.id]))
                let forwardedIds = try await featureCommandAwait("read forwarded event ids") {
                    await forwarding.snapshot()
                }
                expect(forwardedIds).to(equal([firstWire.id]))
                let balance = try await featureCommandAwait("read feature balance") {
                    relaunchedStack.core.featureInfo.balance("ai_generations")
                }
                expect(balance).to(equal(5))
            }

            it("keeps a newer profile balance while reconciling a durable response once") {
                let operationId = UUID.v7().uuidString
                let createdAt = Date(timeIntervalSince1970: 1_788_000_100)
                let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
                let store = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .production
                )
                try store.save([
                    FeatureUseCommand(
                        operationId: operationId,
                        distinctId: "feature-customer",
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: "project-8",
                        setUsage: false,
                        metadata: ["model": AnyCodable("study-review")],
                        createdAt: createdAt,
                        appendSequence: 1,
                        result: .init(
                            response: EventResponse(
                                status: "ok",
                                usage: .init(current: 6, limit: 10, remaining: 4)
                            ),
                            reconciliation: nil,
                            balanceAuthority: FeatureBalanceAuthority(
                                epoch: UUID(),
                                generation: 0
                            ),
                            persistedAt: createdAt
                        )
                    )
                ])

                let api = MockNuxieApi()
                let date = MockDateProvider(initialDate: createdAt)
                date.advance(by: 1)
                let forwarding = FeatureCommandForwardingRecorder()
                relaunched = try await featureCommandAwait("boot orchestration stack") {
                    try await OrchestrationStack.boot(
                        storageURL: storageURL,
                        api: api,
                        dateProvider: date,
                        sleepProvider: MockSleepProvider(),
                        distinctId: "feature-customer",
                        initialFeatureAccess: [
                            "ai_generations": .withBalance(
                                5,
                                unlimited: false,
                                type: .creditSystem
                            )
                        ],
                        forwardingHandler: { event in
                            await forwarding.record(event)
                        }
                    )
                }
                let stack = try unwrap(relaunched)

                let featureSends = try await featureCommandAwait("read API sent events") {
                    await api.sentEvents
                        .filter { $0.name == SystemEventNames.featureUsed }
                }
                expect(featureSends).to(beEmpty())
                let mirrored = try await featureCommandAwait("read mirrored events") {
                    await stack.eventLog.getRecentEvents(limit: 20)
                        .filter { $0.name == SystemEventNames.featureUsed }
                }
                expect(mirrored.map(\.id)).to(equal([operationId]))
                let forwardedIds = try await featureCommandAwait("read forwarded event ids") {
                    await forwarding.snapshot()
                }
                expect(forwardedIds).to(equal([operationId]))
                let balance = try await featureCommandAwait("read feature balance") {
                    stack.core.featureInfo.balance("ai_generations")
                }
                expect(balance).to(equal(5))
                let pendingCount = try await featureCommandAwait("read pending commands") {
                    try await stack.core.featureUseCommands.pendingCount()
                }
                expect(pendingCount).to(equal(0))

                try await featureCommandAwait("recover feature commands") {
                    await stack.core.featureUseCommands.recover()
                }
                let mirroredAfterSecondRecovery = try await featureCommandAwait("read mirrored events after recovery") {
                    await stack.eventLog.getRecentEvents(limit: 20)
                        .filter { $0.name == SystemEventNames.featureUsed }
                }
                expect(mirroredAfterSecondRecovery.map(\.id)).to(equal([operationId]))
                let forwardedAfterSecondRecovery = try await featureCommandAwait("read forwarded event ids") {
                    await forwarding.snapshot()
                }
                expect(forwardedAfterSecondRecovery).to(equal([operationId]))
            }

            it("isolates command journals by host app and environment") {
                let command = FeatureUseCommand(
                    operationId: UUID.v7().uuidString,
                    distinctId: "feature-customer",
                    featureId: "ai_generations",
                    amount: 1,
                    entityId: nil,
                    setUsage: false,
                    metadata: nil,
                    createdAt: Date(timeIntervalSince1970: 1_788_000_200),
                    appendSequence: 1,
                    result: nil
                )
                let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
                let production = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .production
                )
                try production.save([command])

                let development = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .development
                )
                let otherApp = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: "com.example.other-app",
                    environment: .production
                )

                expect(try production.load().map(\.operationId)).to(equal([command.operationId]))
                expect(try development.load()).to(beEmpty())
                expect(try otherApp.load()).to(beEmpty())
            }

            it("continues recovery after retiring an old-identity command") {
                let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
                let store = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .production
                )
                let oldOperationId = UUID.v7().uuidString
                let currentOperationId = UUID.v7().uuidString
                let response = EventResponse(
                    status: "ok",
                    usage: .init(current: 7, limit: 10, remaining: 3)
                )
                try store.save([
                    FeatureUseCommand(
                        operationId: oldOperationId,
                        distinctId: "old-customer",
                        identity: IdentitySnapshot(
                            distinctId: "old-customer",
                            userId: "old-customer",
                            anonymousId: "old-anonymous",
                            isIdentified: true
                        ),
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: nil,
                        setUsage: false,
                        metadata: nil,
                        createdAt: Date(timeIntervalSince1970: 1_788_000_300),
                        appendSequence: 1,
                        result: .init(
                            response: response,
                            reconciliation: nil,
                            balanceAuthority: FeatureBalanceAuthority(
                                epoch: UUID(),
                                generation: 0
                            ),
                            persistedAt: Date(timeIntervalSince1970: 1_788_000_300)
                        )
                    ),
                    FeatureUseCommand(
                        operationId: currentOperationId,
                        distinctId: "current-customer",
                        identity: IdentitySnapshot(
                            distinctId: "current-customer",
                            userId: "current-customer",
                            anonymousId: "current-anonymous",
                            isIdentified: true
                        ),
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: nil,
                        setUsage: false,
                        metadata: nil,
                        createdAt: Date(timeIntervalSince1970: 1_788_000_301),
                        appendSequence: 2,
                        result: .init(
                            response: response,
                            reconciliation: nil,
                            balanceAuthority: FeatureBalanceAuthority(
                                epoch: UUID(),
                                generation: 0
                            ),
                            persistedAt: Date(timeIntervalSince1970: 1_788_000_301)
                        )
                    ),
                ])

                let api = MockNuxieApi()
                let forwarding = FeatureCommandForwardingRecorder()
                relaunched = try await featureCommandAwait("boot orchestration stack") {
                    try await OrchestrationStack.boot(
                        storageURL: storageURL,
                        api: api,
                        dateProvider: MockDateProvider(),
                        sleepProvider: MockSleepProvider(),
                        distinctId: "current-customer",
                        initialFeatureAccess: [
                            "ai_generations": .withBalance(
                                5,
                                unlimited: false,
                                type: .creditSystem
                            )
                        ],
                        forwardingHandler: { event in
                            await forwarding.record(event)
                        },
                        configure: { configuration in
                            configuration.beforeSend = { event in
                                var properties = event.properties
                                properties["before_send_distinct_id"] =
                                    event.properties["$distinct_id"]
                                properties["before_send_user_id"] = event.properties["$user_id"]
                                properties["before_send_anonymous_id"] =
                                    event.properties["$anonymous_id"]
                                properties["before_send_is_identified"] =
                                    event.properties["$is_identified"]
                                return NuxieEvent(
                                    id: event.id,
                                    name: event.name,
                                    distinctId: event.distinctId,
                                    properties: properties,
                                    timestamp: event.timestamp
                                )
                            }
                        }
                    )
                }
                let stack = try unwrap(relaunched)

                let pendingCount = try await featureCommandAwait("read pending commands") {
                    try await stack.core.featureUseCommands.pendingCount()
                }
                expect(pendingCount).to(equal(0))
                let mirroredIds = try await featureCommandAwait("read mirrored events") {
                    await stack.eventLog.getRecentEvents(limit: 20)
                        .filter { $0.name == SystemEventNames.featureUsed }
                        .map(\.id)
                }
                expect(mirroredIds.count).to(equal(2))
                expect(Set(mirroredIds)).to(equal(Set([oldOperationId, currentOperationId])))
                let oldMirrorCandidate = try await featureCommandAwait("read mirrored events") {
                    await stack.eventLog.getRecentEvents(limit: 20)
                        .first { $0.id == oldOperationId }
                }
                let oldMirror = try unwrap(oldMirrorCandidate)
                expect(oldMirror.distinctId).to(equal("old-customer"))
                let oldMirrorProperties = oldMirror.getPropertiesDict()
                expect(oldMirrorProperties["$distinct_id"] as? String).to(equal("old-customer"))
                expect(oldMirrorProperties["$user_id"] as? String).to(equal("old-customer"))
                expect(oldMirrorProperties["$anonymous_id"] as? String).to(equal("old-anonymous"))
                expect(oldMirrorProperties["$is_identified"] as? Bool).to(beTrue())
                expect(oldMirrorProperties["before_send_distinct_id"] as? String)
                    .to(equal("old-customer"))
                expect(oldMirrorProperties["before_send_user_id"] as? String)
                    .to(equal("old-customer"))
                expect(oldMirrorProperties["before_send_anonymous_id"] as? String)
                    .to(equal("old-anonymous"))
                expect(oldMirrorProperties["before_send_is_identified"] as? Bool).to(beTrue())
                let forwardedIds = try await featureCommandAwait("read forwarded event ids") {
                    await forwarding.snapshot()
                }
                expect(forwardedIds.count).to(equal(2))
                expect(Set(forwardedIds)).to(equal(Set([oldOperationId, currentOperationId])))
                let oldForwardedCandidate = try await featureCommandAwait("read forwarded events") {
                    await forwarding.eventSnapshot()
                        .first { $0.id == oldOperationId }
                }
                let oldForwarded = try unwrap(oldForwardedCandidate)
                expect(oldForwarded.distinctId).to(equal("old-customer"))
                expect(oldForwarded.properties["$distinct_id"] as? String)
                    .to(equal("old-customer"))
                expect(oldForwarded.properties["$user_id"] as? String).to(equal("old-customer"))
                expect(oldForwarded.properties["$anonymous_id"] as? String)
                    .to(equal("old-anonymous"))
                expect(oldForwarded.properties["$is_identified"] as? Bool).to(beTrue())
                expect(oldForwarded.properties["before_send_distinct_id"] as? String)
                    .to(equal("old-customer"))
                expect(oldForwarded.properties["before_send_user_id"] as? String)
                    .to(equal("old-customer"))
                expect(oldForwarded.properties["before_send_anonymous_id"] as? String)
                    .to(equal("old-anonymous"))
                expect(oldForwarded.properties["before_send_is_identified"] as? Bool).to(beTrue())
                let balance = try await featureCommandAwait("read feature balance") {
                    stack.core.featureInfo.balance("ai_generations")
                }
                // Both responses predate this process. The newly admitted
                // profile balance has newer authority and must win.
                expect(balance).to(equal(5))
                let featureSends = try await featureCommandAwait("read API sent events") {
                    await api.sentEvents
                        .filter { $0.name == SystemEventNames.featureUsed }
                }
                expect(featureSends).to(beEmpty())
            }
        }
    }
}
