import Foundation
import Nimble
import Quick
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private actor SuspendedFeatureRecoveryTaskGate {
    private var isEntered = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRecoveryTaskAdmission() async {
        isEntered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            gateWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !isEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = gateWaiters
        gateWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

extension SuspendedFeatureRecoveryTaskGate: FeatureRecoveryTaskGating {}

final class FeatureUseCommandQueueTests: AsyncSpec {
    override class func spec() {
        describe("feature use command queue") {
            var storageURL: URL!

            beforeEach {
                storageURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("nuxie-feature-command-unit-\(UUID().uuidString)")
            }

            afterEach {
                if let storageURL {
                    try? FileManager.default.removeItem(at: storageURL)
                }
            }

            it("rejects a pinned feature use when identity changes before journaling") {
                let createdAt = Date(timeIntervalSince1970: 1_788_000_040)
                let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
                let store = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .production
                )
                let api = MockNuxieApi()
                let identity = MockIdentityService()
                identity.setDistinctId("feature-customer-a")
                let eventLog = MockEventLog()
                let queue = FeatureUseCommandQueue(
                    api: api,
                    identity: identity,
                    eventLog: eventLog,
                    featureInfo: FeatureInfo(),
                    dateProvider: MockDateProvider(initialDate: createdAt),
                    store: store
                )

                identity.suspendNextDistinctIdRead()
                let usage = Task {
                    try await queue.use(
                        distinctId: "feature-customer-a",
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: "project-identity-race",
                        setUsage: false,
                        metadata: nil
                    )
                }
                await identity.waitForSuspendedDistinctIdRead()
                identity.setDistinctId("feature-customer-b")
                identity.resumeSuspendedDistinctIdRead()

                await expect { try await usage.value }.to(throwError { error in
                    expect(error).to(beAKindOf(CancellationError.self))
                })
                expect(try store.load()).to(beEmpty())
                let featureSends = await api.sentEvents.filter {
                    $0.name == SystemEventNames.featureUsed
                }
                expect(featureSends).to(beEmpty())
                let history = await eventLog.getRecentEvents(limit: 10)
                expect(history).to(beEmpty())
            }

            it("allows exactly one identical foreground call to join recovery") {
                let operationId = UUID.v7().uuidString
                let createdAt = Date(timeIntervalSince1970: 1_788_000_050)
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
                        entityId: "project-recovery-race",
                        setUsage: false,
                        metadata: ["model": AnyCodable("study-review")],
                        createdAt: createdAt,
                        result: nil
                    )
                ])

                let api = MockNuxieApi()
                await api.configureTrackEventResponse(
                    status: "ok",
                    usage: .init(current: 6, limit: 10, remaining: 4)
                )
                await api.suspendNextFeatureTrackEvent()
                let identity = MockIdentityService()
                identity.setDistinctId("feature-customer")
                let queue = FeatureUseCommandQueue(
                    api: api,
                    identity: identity,
                    eventLog: MockEventLog(),
                    featureInfo: FeatureInfo(),
                    dateProvider: MockDateProvider(initialDate: createdAt),
                    store: store
                )

                let recovery = Task { await queue.recover() }
                await api.waitForSuspendedFeatureTrackEvent()

                identity.suspendNextDistinctIdRead()
                let joinedForeground = Task {
                    try await queue.use(
                        distinctId: "feature-customer",
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: "project-recovery-race",
                        setUsage: false,
                        metadata: ["model": "study-review"]
                    )
                }
                await identity.waitForSuspendedDistinctIdRead()
                identity.resumeSuspendedDistinctIdRead()

                // Actor barrier: the foreground call has now either joined
                // recovery or persisted a second command before this returns.
                let joinedPendingCount = try await queue.pendingCount()
                expect(joinedPendingCount).to(equal(1))

                identity.suspendNextDistinctIdRead()
                let newForeground = Task {
                    try await queue.use(
                        distinctId: "feature-customer",
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: "project-recovery-race",
                        setUsage: false,
                        metadata: ["model": "study-review"]
                    )
                }
                await identity.waitForSuspendedDistinctIdRead()
                identity.resumeSuspendedDistinctIdRead()

                await api.resumeSuspendedFeatureTrackEvent()

                await recovery.value
                let joinedResult = try await joinedForeground.value
                let newResult = try await newForeground.value
                expect(joinedResult.success).to(beTrue())
                expect(newResult.success).to(beTrue())
                expect(joinedResult.featureId).to(equal("ai_generations"))
                expect(newResult.featureId).to(equal("ai_generations"))
                expect(joinedResult.usage?.remaining).to(equal(4))
                expect(newResult.usage?.remaining).to(equal(4))

                let featureSends = await api.sentEvents.filter {
                    $0.name == SystemEventNames.featureUsed
                }
                expect(featureSends.count).to(equal(2))
                expect(Set(featureSends.map(\.id)).count).to(equal(2))
                expect(featureSends.map(\.id)).to(contain(operationId))
                let uniqueAcceptedCount = await api.uniqueAcceptedTrackEventCount
                expect(uniqueAcceptedCount).to(equal(2))
                let completedPendingCount = try await queue.pendingCount()
                expect(completedPendingCount).to(equal(0))
            }

            it("does not admit recovery side effects when cancellation wins before task start") {
                let operationId = UUID.v7().uuidString
                let createdAt = Date(timeIntervalSince1970: 1_788_000_060)
                let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
                let store = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .production
                )
                let command = FeatureUseCommand(
                    operationId: operationId,
                    distinctId: "feature-customer",
                    featureId: "ai_generations",
                    amount: 1,
                    entityId: "project-cancel-admission",
                    setUsage: false,
                    metadata: nil,
                    createdAt: createdAt,
                    result: nil
                )
                try store.save([command])

                let gate = SuspendedFeatureRecoveryTaskGate()
                let api = MockNuxieApi()
                let identity = MockIdentityService()
                identity.setDistinctId("feature-customer")
                let queue = FeatureUseCommandQueue(
                    api: api,
                    identity: identity,
                    eventLog: MockEventLog(),
                    featureInfo: FeatureInfo(),
                    dateProvider: MockDateProvider(initialDate: createdAt),
                    store: store,
                    recoveryTaskGate: gate
                )

                let recovery = Task { await queue.recover() }
                await gate.waitUntilEntered()
                recovery.cancel()
                await gate.open()
                await recovery.value

                let featureSends = await api.sentEvents.filter {
                    $0.name == SystemEventNames.featureUsed
                }
                expect(featureSends).to(beEmpty())
                expect(try store.load().map(\.operationId)).to(equal([operationId]))
                expect(try store.load().first?.result).to(beNil())
                let pendingCount = try await queue.pendingCount()
                expect(pendingCount).to(equal(1))
            }

            it("stops recovery admission when cancellation races a successful response") {
                let firstOperationId = UUID.v7().uuidString
                let secondOperationId = UUID.v7().uuidString
                let createdAt = Date(timeIntervalSince1970: 1_788_000_075)
                let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
                let store = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .production
                )
                try store.save([
                    FeatureUseCommand(
                        operationId: firstOperationId,
                        distinctId: "feature-customer",
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: "project-cancel-first",
                        setUsage: false,
                        metadata: nil,
                        createdAt: createdAt,
                        result: nil
                    ),
                    FeatureUseCommand(
                        operationId: secondOperationId,
                        distinctId: "feature-customer",
                        featureId: "ai_generations",
                        amount: 2,
                        entityId: "project-cancel-tail",
                        setUsage: false,
                        metadata: nil,
                        createdAt: createdAt.addingTimeInterval(1),
                        result: nil
                    ),
                ])

                let api = MockNuxieApi()
                await api.configureTrackEventResponse(
                    status: "ok",
                    usage: .init(current: 6, limit: 10, remaining: 4)
                )
                await api.suspendNextFeatureTrackEvent()
                let identity = MockIdentityService()
                identity.setDistinctId("feature-customer")
                let queue = FeatureUseCommandQueue(
                    api: api,
                    identity: identity,
                    eventLog: MockEventLog(),
                    featureInfo: FeatureInfo(),
                    dateProvider: MockDateProvider(initialDate: createdAt),
                    store: store
                )

                let recovery = Task { await queue.recover() }
                await api.waitForSuspendedFeatureTrackEvent()
                recovery.cancel()
                await api.resumeSuspendedFeatureTrackEvent()
                await recovery.value

                let featureSends = await api.sentEvents.filter {
                    $0.name == SystemEventNames.featureUsed
                }
                expect(featureSends.map(\.id)).to(equal([firstOperationId]))
                expect(try store.load().map(\.operationId))
                    .to(equal([firstOperationId, secondOperationId]))
                let pendingCount = try await queue.pendingCount()
                expect(pendingCount).to(equal(2))
            }

            it("durably retires terminal poison without growing or replaying the journal") {
                let createdAt = Date(timeIntervalSince1970: 1_788_000_090)
                let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
                let store = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .production
                )
                let api = MockNuxieApi()
                await api.configureTrackEventFailure(
                    error: NuxieNetworkError.httpError(
                        statusCode: 422,
                        message: "invalid feature usage"
                    )
                )
                let identity = MockIdentityService()
                identity.setDistinctId("feature-customer")
                let queue = FeatureUseCommandQueue(
                    api: api,
                    identity: identity,
                    eventLog: MockEventLog(),
                    featureInfo: FeatureInfo(),
                    dateProvider: MockDateProvider(initialDate: createdAt),
                    store: store
                )

                for index in 0..<3 {
                    await expect {
                        try await queue.use(
                            distinctId: "feature-customer",
                            featureId: "ai_generations_\(index)",
                            amount: 1,
                            entityId: "project-poison-\(index)",
                            setUsage: false,
                            metadata: nil
                        )
                    }.to(throwError { error in
                        expect((error as? NuxieNetworkError)?.httpStatusCode).to(equal(422))
                    })
                    expect(try store.load()).to(beEmpty())
                }

                let relaunchedApi = MockNuxieApi()
                let relaunchedQueue = FeatureUseCommandQueue(
                    api: relaunchedApi,
                    identity: identity,
                    eventLog: MockEventLog(),
                    featureInfo: FeatureInfo(),
                    dateProvider: MockDateProvider(initialDate: createdAt),
                    store: store
                )
                await relaunchedQueue.recover()

                let featureSends = await relaunchedApi.sentEvents.filter {
                    $0.name == SystemEventNames.featureUsed
                }
                expect(featureSends).to(beEmpty())
                let pendingCount = try await relaunchedQueue.pendingCount()
                expect(pendingCount).to(equal(0))
            }

            it("durably retires an oversized singleton command and surfaces its failure") {
                let createdAt = Date(timeIntervalSince1970: 1_788_000_100)
                let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
                let store = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .production
                )
                let api = MockNuxieApi()
                await api.configureTrackEventFailure(
                    error: NuxieNetworkError.httpError(
                        statusCode: 413,
                        message: "feature command is too large"
                    )
                )
                let identity = MockIdentityService()
                identity.setDistinctId("feature-customer")
                let queue = FeatureUseCommandQueue(
                    api: api,
                    identity: identity,
                    eventLog: MockEventLog(),
                    featureInfo: FeatureInfo(),
                    dateProvider: MockDateProvider(initialDate: createdAt),
                    store: store
                )

                await expect {
                    try await queue.use(
                        distinctId: "feature-customer",
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: "project-oversized",
                        setUsage: false,
                        metadata: ["payload": "oversized"]
                    )
                }.to(throwError { error in
                    expect((error as? NuxieNetworkError)?.httpStatusCode).to(equal(413))
                })
                expect(try store.load()).to(beEmpty())

                let relaunchedApi = MockNuxieApi()
                let relaunchedQueue = FeatureUseCommandQueue(
                    api: relaunchedApi,
                    identity: identity,
                    eventLog: MockEventLog(),
                    featureInfo: FeatureInfo(),
                    dateProvider: MockDateProvider(initialDate: createdAt),
                    store: store
                )
                await relaunchedQueue.recover()

                let relaunchedFeatureSends = await relaunchedApi.sentEvents.filter {
                    $0.name == SystemEventNames.featureUsed
                }
                expect(relaunchedFeatureSends).to(beEmpty())
                let pendingCount = try await relaunchedQueue.pendingCount()
                expect(pendingCount).to(equal(0))
            }
        }
    }
}
