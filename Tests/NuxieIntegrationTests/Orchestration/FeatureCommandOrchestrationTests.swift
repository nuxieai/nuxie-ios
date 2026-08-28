import Foundation
import Quick
import Nimble
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private actor FeatureCommandForwardingRecorder {
    private var ids: [String] = []

    func record(_ event: DurableForwardingEvent) {
        ids.append(event.event.id)
    }

    func snapshot() -> [String] { ids }
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
                await first?.shutdownForCleanup()
                await relaunched?.shutdownForCleanup()
                if let storageURL {
                    try? FileManager.default.removeItem(at: storageURL)
                }
            }

            it("retries an accepted-but-timed-out command after relaunch with one operation id") {
                let api = MockNuxieApi()
                await api.configureTrackEventResponse(
                    status: "ok",
                    usage: .init(current: 6, limit: 10, remaining: 4)
                )
                await api.setAcceptedTrackEventTimeouts(1)
                let date = MockDateProvider(
                    initialDate: Date(timeIntervalSince1970: 1_788_000_000)
                )
                let sleep = MockSleepProvider()
                let forwarding = FeatureCommandForwardingRecorder()
                first = try await OrchestrationStack.boot(
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
                let firstStack = try unwrap(first)

                await expect {
                    try await firstStack.core.featureUseCommands.use(
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: "project-7",
                        setUsage: false,
                        metadata: ["model": "study-review"]
                    )
                }.to(throwError(NuxieNetworkError.timeout))

                let firstSentEvents = await api.sentEvents
                let firstWire = try unwrap(firstSentEvents.last {
                    $0.name == SystemEventNames.featureUsed
                })
                let firstPendingCount = try await firstStack.core.featureUseCommands.pendingCount()
                expect(firstPendingCount).to(equal(1))
                await firstStack.kill()
                first = nil

                relaunched = try await OrchestrationStack.boot(
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
                let relaunchedStack = try unwrap(relaunched)

                let featureSends = await api.sentEvents.filter {
                    $0.name == SystemEventNames.featureUsed
                }
                expect(featureSends.map(\.id)).to(equal([firstWire.id, firstWire.id]))
                let uniqueAcceptedCount = await api.uniqueAcceptedTrackEventCount
                expect(uniqueAcceptedCount).to(equal(1))
                let relaunchedPendingCount = try await relaunchedStack.core.featureUseCommands
                    .pendingCount()
                expect(relaunchedPendingCount).to(equal(0))

                let mirrored = await relaunchedStack.eventLog.getRecentEvents(limit: 20)
                    .filter { $0.name == SystemEventNames.featureUsed }
                expect(mirrored.map(\.id)).to(equal([firstWire.id]))
                let forwardedIds = await forwarding.snapshot()
                expect(forwardedIds).to(equal([firstWire.id]))
                let balance = await MainActor.run {
                    relaunchedStack.core.featureInfo.balance("ai_generations")
                }
                expect(balance).to(equal(4))
            }

            it("reconciles a durable response after relaunch without resending") {
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
                        result: .init(
                            response: EventResponse(
                                status: "ok",
                                usage: .init(current: 6, limit: 10, remaining: 4)
                            ),
                            reconciliation: nil
                        )
                    )
                ])

                let api = MockNuxieApi()
                let date = MockDateProvider(initialDate: createdAt)
                let forwarding = FeatureCommandForwardingRecorder()
                relaunched = try await OrchestrationStack.boot(
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
                let stack = try unwrap(relaunched)

                let featureSends = await api.sentEvents.filter {
                    $0.name == SystemEventNames.featureUsed
                }
                expect(featureSends).to(beEmpty())
                let mirrored = await stack.eventLog.getRecentEvents(limit: 20)
                    .filter { $0.name == SystemEventNames.featureUsed }
                expect(mirrored.map(\.id)).to(equal([operationId]))
                let forwardedIds = await forwarding.snapshot()
                expect(forwardedIds).to(equal([operationId]))
                let balance = await MainActor.run {
                    stack.core.featureInfo.balance("ai_generations")
                }
                expect(balance).to(equal(4))
                let pendingCount = try await stack.core.featureUseCommands.pendingCount()
                expect(pendingCount).to(equal(0))
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
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: nil,
                        setUsage: false,
                        metadata: nil,
                        createdAt: Date(timeIntervalSince1970: 1_788_000_300),
                        result: .init(response: response, reconciliation: nil)
                    ),
                    FeatureUseCommand(
                        operationId: currentOperationId,
                        distinctId: "current-customer",
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: nil,
                        setUsage: false,
                        metadata: nil,
                        createdAt: Date(timeIntervalSince1970: 1_788_000_301),
                        result: .init(response: response, reconciliation: nil)
                    ),
                ])

                let api = MockNuxieApi()
                let forwarding = FeatureCommandForwardingRecorder()
                relaunched = try await OrchestrationStack.boot(
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
                    }
                )
                let stack = try unwrap(relaunched)

                let pendingCount = try await stack.core.featureUseCommands.pendingCount()
                expect(pendingCount).to(equal(0))
                let mirroredIds = Set(
                    await stack.eventLog.getRecentEvents(limit: 20)
                        .filter { $0.name == SystemEventNames.featureUsed }
                        .map(\.id)
                )
                expect(mirroredIds).to(equal(Set([oldOperationId, currentOperationId])))
                let forwardedIds = Set(await forwarding.snapshot())
                expect(forwardedIds).to(equal(Set([oldOperationId, currentOperationId])))
                let balance = await MainActor.run {
                    stack.core.featureInfo.balance("ai_generations")
                }
                expect(balance).to(equal(3))
                let featureSends = await api.sentEvents.filter {
                    $0.name == SystemEventNames.featureUsed
                }
                expect(featureSends).to(beEmpty())
            }
        }
    }
}
