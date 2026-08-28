import Foundation
import Quick
import Nimble
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private actor FeatureCommandForwardingRecorder {
    private var events: [NuxieEvent] = []

    func record(_ event: DurableForwardingEvent) {
        events.append(event.event)
    }

    func snapshot() -> [String] { events.map(\.id) }

    func eventSnapshot() -> [NuxieEvent] { events }
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

            it("retries an accepted timeout without overwriting a newer profile balance") {
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
                        distinctId: "feature-customer",
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
                date.advance(by: 1)

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
                expect(balance).to(equal(5))
                let pendingCount = try await stack.core.featureUseCommands.pendingCount()
                expect(pendingCount).to(equal(0))

                await stack.core.featureUseCommands.recover()
                let mirroredAfterSecondRecovery = await stack.eventLog
                    .getRecentEvents(limit: 20)
                    .filter { $0.name == SystemEventNames.featureUsed }
                expect(mirroredAfterSecondRecovery.map(\.id)).to(equal([operationId]))
                let forwardedAfterSecondRecovery = await forwarding.snapshot()
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
                let stack = try unwrap(relaunched)

                let pendingCount = try await stack.core.featureUseCommands.pendingCount()
                expect(pendingCount).to(equal(0))
                let mirroredIds = await stack.eventLog.getRecentEvents(limit: 20)
                    .filter { $0.name == SystemEventNames.featureUsed }
                    .map(\.id)
                expect(mirroredIds.count).to(equal(2))
                expect(Set(mirroredIds)).to(equal(Set([oldOperationId, currentOperationId])))
                let oldMirrorCandidate = await stack.eventLog.getRecentEvents(limit: 20)
                    .first { $0.id == oldOperationId }
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
                let forwardedIds = await forwarding.snapshot()
                expect(forwardedIds.count).to(equal(2))
                expect(Set(forwardedIds)).to(equal(Set([oldOperationId, currentOperationId])))
                let oldForwardedCandidate = await forwarding.eventSnapshot()
                    .first { $0.id == oldOperationId }
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
                let balance = await MainActor.run {
                    stack.core.featureInfo.balance("ai_generations")
                }
                // Both responses predate this process. The newly admitted
                // profile balance has newer authority and must win.
                expect(balance).to(equal(5))
                let featureSends = await api.sentEvents.filter {
                    $0.name == SystemEventNames.featureUsed
                }
                expect(featureSends).to(beEmpty())
            }
        }
    }
}
