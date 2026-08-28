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

private final class FeatureChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var count: Int { lock.withLock { _count } }

    func record() {
        lock.withLock { _count += 1 }
    }
}

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

            it("keeps a newer profile balance when an accepted timeout is retried") {
                let createdAt = Date(timeIntervalSince1970: 1_788_000_045)
                let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
                let store = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .production
                )
                let api = MockNuxieApi()
                await api.configureTrackEventResponse(
                    status: "ok",
                    usage: .init(current: 6, limit: 10, remaining: 4)
                )
                await api.setAcceptedTrackEventTimeouts(1)
                let identity = MockIdentityService()
                identity.setDistinctId("feature-customer")
                let featureInfo = FeatureInfo()
                let date = MockDateProvider(initialDate: createdAt)
                let queue = FeatureUseCommandQueue(
                    api: api,
                    identity: identity,
                    eventLog: MockEventLog(),
                    featureInfo: featureInfo,
                    dateProvider: date,
                    store: store
                )

                await expect {
                    try await queue.use(
                        distinctId: "feature-customer",
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: "project-freshness",
                        setUsage: false,
                        metadata: nil
                    )
                }.to(throwError(NuxieNetworkError.timeout))
                let capturedIdentity = try unwrap(try store.load().first?.identity)
                expect(capturedIdentity).to(equal(IdentitySnapshot(
                    distinctId: "feature-customer",
                    userId: "feature-customer",
                    anonymousId: "test-anonymous-id",
                    isIdentified: true
                )))

                date.advance(by: -1)
                let profileAdmissionAt = date.now()
                await MainActor.run {
                    featureInfo.admitProfileSnapshot(
                        [
                            "ai_generations": .withBalance(
                                5,
                                unlimited: false,
                                type: .creditSystem
                            ),
                        ],
                        admittedAt: profileAdmissionAt
                    )
                }
                date.advance(by: -1)

                let result = try await queue.use(
                    distinctId: "feature-customer",
                    featureId: "ai_generations",
                    amount: 1,
                    entityId: "project-freshness",
                    setUsage: false,
                    metadata: nil
                )

                expect(result.success).to(beTrue())
                expect(result.usage?.remaining).to(equal(4))
                let balance = await MainActor.run {
                    featureInfo.balance("ai_generations")
                }
                expect(balance).to(equal(5))
                expect(try store.load()).to(beEmpty())
                let featureSends = await api.sentEvents.filter {
                    $0.name == SystemEventNames.featureUsed
                }
                expect(featureSends.count).to(equal(2))
                expect(Set(featureSends.map(\.id)).count).to(equal(1))
                let uniqueAcceptedCount = await api.uniqueAcceptedTrackEventCount
                expect(uniqueAcceptedCount).to(equal(1))
            }

            it("keeps a newer remote-check balance when an accepted timeout is retried") {
                let createdAt = Date(timeIntervalSince1970: 1_788_000_046)
                let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
                let store = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .production
                )
                let api = MockNuxieApi()
                await api.configureTrackEventResponse(
                    status: "ok",
                    usage: .init(current: 6, limit: 10, remaining: 4)
                )
                await api.setAcceptedTrackEventTimeouts(1)
                let identity = MockIdentityService()
                identity.setDistinctId("feature-customer")
                let featureInfo = FeatureInfo()
                let date = MockDateProvider(initialDate: createdAt)
                let queue = FeatureUseCommandQueue(
                    api: api,
                    identity: identity,
                    eventLog: MockEventLog(),
                    featureInfo: featureInfo,
                    dateProvider: date,
                    store: store
                )
                let features = FeatureService(
                    api: api,
                    identity: identity,
                    profile: MockProfileService(),
                    dateProvider: date,
                    featureInfo: featureInfo,
                    cacheTTL: 5 * 60
                )

                await expect {
                    try await queue.use(
                        distinctId: "feature-customer",
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: nil,
                        setUsage: false,
                        metadata: nil
                    )
                }.to(throwError(NuxieNetworkError.timeout))

                date.advance(by: -1)
                await api.setCheckFeatureResponse(
                    FeatureCheckResult(
                        customerId: "feature-customer",
                        featureId: "ai_generations",
                        requiredBalance: 1,
                        code: "allowed",
                        allowed: true,
                        unlimited: false,
                        balance: 8,
                        type: .creditSystem,
                        preview: nil
                    )
                )
                let checked = try await features.check(featureId: "ai_generations")
                expect(checked.balance).to(equal(8))
                date.advance(by: -1)

                let result = try await queue.use(
                    distinctId: "feature-customer",
                    featureId: "ai_generations",
                    amount: 1,
                    entityId: nil,
                    setUsage: false,
                    metadata: nil
                )

                expect(result.success).to(beTrue())
                expect(result.usage?.remaining).to(equal(4))
                let balance = await MainActor.run {
                    featureInfo.balance("ai_generations")
                }
                expect(balance).to(equal(8))
                expect(try store.load()).to(beEmpty())
            }

            it("applies a first response produced after a profile admission") {
                let createdAt = Date(timeIntervalSince1970: 1_788_000_047)
                let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
                let store = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .production
                )
                let api = MockNuxieApi()
                await api.configureTrackEventResponse(
                    status: "ok",
                    usage: .init(current: 6, limit: 10, remaining: 4)
                )
                await api.suspendNextFeatureTrackEvent()
                let identity = MockIdentityService()
                identity.setDistinctId("feature-customer")
                let featureInfo = FeatureInfo()
                let date = MockDateProvider(initialDate: createdAt)
                let queue = FeatureUseCommandQueue(
                    api: api,
                    identity: identity,
                    eventLog: MockEventLog(),
                    featureInfo: featureInfo,
                    dateProvider: date,
                    store: store
                )

                let usage = Task {
                    try await queue.use(
                        distinctId: "feature-customer",
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: "project-first-response",
                        setUsage: false,
                        metadata: nil
                    )
                }
                await api.waitForSuspendedFeatureTrackEvent()

                date.advance(by: 1)
                let profileAdmissionAt = date.now()
                await MainActor.run {
                    featureInfo.admitProfileSnapshot(
                        [
                            "ai_generations": .withBalance(
                                5,
                                unlimited: false,
                                type: .creditSystem
                            ),
                        ],
                        admittedAt: profileAdmissionAt
                    )
                }
                date.advance(by: 1)
                await api.resumeSuspendedFeatureTrackEvent()

                let result = try await usage.value

                expect(result.success).to(beTrue())
                let balance = await MainActor.run {
                    featureInfo.balance("ai_generations")
                }
                expect(balance).to(equal(4))
                expect(try store.load()).to(beEmpty())
            }

            it("linearizes balance publication before an identity change racing its final check") {
                let createdAt = Date(timeIntervalSince1970: 1_788_000_048)
                let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
                let store = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .production
                )
                let api = MockNuxieApi()
                await api.configureTrackEventResponse(
                    status: "ok",
                    usage: .init(current: 6, limit: 10, remaining: 4)
                )
                await api.suspendNextFeatureTrackEvent()
                let identity = MockIdentityService()
                identity.setDistinctId("old-customer")
                let featureInfo = FeatureInfo()
                let changes = FeatureChangeRecorder()
                await MainActor.run {
                    featureInfo.update([
                        "ai_generations": .withBalance(
                            10,
                            unlimited: false,
                            type: .creditSystem
                        ),
                    ])
                    featureInfo.onFeatureChange = { _, _, _ in changes.record() }
                }
                let queue = FeatureUseCommandQueue(
                    api: api,
                    identity: identity,
                    eventLog: MockEventLog(),
                    featureInfo: featureInfo,
                    dateProvider: MockDateProvider(initialDate: createdAt),
                    store: store
                )

                let usage = Task {
                    try await queue.use(
                        distinctId: "old-customer",
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: "project-identity-hop",
                        setUsage: false,
                        metadata: nil
                    )
                }
                await api.waitForSuspendedFeatureTrackEvent()
                identity.suspendDistinctIdReadAfterSnapshot(skipping: 1)
                await api.resumeSuspendedFeatureTrackEvent()
                await identity.waitForSuspendedDistinctIdRead()

                let identityChangeWonApplicationRace = await identity.raceDistinctIdChange(
                    "current-customer"
                )

                await expect { try await usage.value }.to(throwError { error in
                    expect(error).to(beAKindOf(CancellationError.self))
                })
                expect(identityChangeWonApplicationRace).to(beFalse())
                let balance = await MainActor.run {
                    featureInfo.balance("ai_generations")
                }
                expect(balance).to(equal(4))
                expect(changes.count).to(equal(1))
            }

            it("allows a feature change callback to identify after committing the balance") {
                let createdAt = Date(timeIntervalSince1970: 1_788_000_049)
                let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
                let store = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .production
                )
                let api = MockNuxieApi()
                await api.configureTrackEventResponse(
                    status: "ok",
                    usage: .init(current: 6, limit: 10, remaining: 4)
                )
                let identity = MockIdentityService()
                identity.setDistinctId("feature-customer")
                let featureInfo = FeatureInfo()
                let changes = FeatureChangeRecorder()
                await MainActor.run {
                    featureInfo.update([
                        "ai_generations": .withBalance(
                            10,
                            unlimited: false,
                            type: .creditSystem
                        ),
                    ])
                    featureInfo.onFeatureChange = { _, _, _ in
                        changes.record()
                        identity.setDistinctId("delegate-customer")
                    }
                }
                let queue = FeatureUseCommandQueue(
                    api: api,
                    identity: identity,
                    eventLog: MockEventLog(),
                    featureInfo: featureInfo,
                    dateProvider: MockDateProvider(initialDate: createdAt),
                    store: store
                )

                await expect {
                    try await queue.use(
                        distinctId: "feature-customer",
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: "project-delegate-identify",
                        setUsage: false,
                        metadata: nil
                    )
                }.to(throwError { error in
                    expect(error).to(beAKindOf(CancellationError.self))
                })

                expect(identity.getDistinctId()).to(equal("delegate-customer"))
                let balance = await MainActor.run {
                    featureInfo.balance("ai_generations")
                }
                expect(balance).to(equal(4))
                expect(changes.count).to(equal(1))
                expect(try store.load()).to(beEmpty())
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
                        appendSequence: 1,
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

            it("applies same-target commands in capture order") {
                let oldOperationId = UUID.v7().uuidString
                let createdAt = Date(timeIntervalSince1970: 1_788_000_055)
                let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
                let store = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .production
                )
                try store.save([
                    FeatureUseCommand(
                        operationId: oldOperationId,
                        distinctId: "feature-customer",
                        featureId: "ai_generations",
                        amount: 7,
                        entityId: "project-ordered",
                        setUsage: true,
                        metadata: nil,
                        createdAt: createdAt,
                        appendSequence: 1,
                        result: nil
                    ),
                ])

                let api = MockNuxieApi()
                await api.configureTrackEventResponse(
                    status: "ok",
                    usage: .init(current: 8, limit: 10, remaining: 2)
                )
                await api.suspendNextFeatureTrackEvent()
                let identity = MockIdentityService()
                identity.setDistinctId("feature-customer")
                let eventLog = MockEventLog()
                let queue = FeatureUseCommandQueue(
                    api: api,
                    identity: identity,
                    eventLog: eventLog,
                    featureInfo: FeatureInfo(),
                    dateProvider: MockDateProvider(initialDate: createdAt.addingTimeInterval(1)),
                    store: store
                )

                let recovery = Task { await queue.recover() }
                await api.waitForSuspendedFeatureTrackEvent()

                identity.suspendNextDistinctIdRead()
                let foreground = Task {
                    try await queue.use(
                        distinctId: "feature-customer",
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: "project-ordered",
                        setUsage: false,
                        metadata: nil
                    )
                }
                await identity.waitForSuspendedDistinctIdRead()
                identity.resumeSuspendedDistinctIdRead()

                let foregroundResult = try await foreground.value

                let pendingWhileOldIsSuspended = try await queue.pendingCount()
                expect(pendingWhileOldIsSuspended).to(equal(2))
                let sentWhileOldIsSuspended = await api.sentEvents.filter {
                    $0.name == SystemEventNames.featureUsed
                }
                let newOperationId = try unwrap(
                    sentWhileOldIsSuspended.first { $0.id != oldOperationId }?.id
                )
                let appliedWhileOldIsSuspended = await api.appliedFeatureTrackEventIds
                expect(appliedWhileOldIsSuspended).to(equal([newOperationId]))
                expect(eventLog.routedEvents).to(beEmpty())

                await api.resumeSuspendedFeatureTrackEvent()
                await recovery.value

                expect(foregroundResult.success).to(beTrue())
                let appliedOperationIds = await api.appliedFeatureTrackEventIds
                expect(appliedOperationIds)
                    .to(equal([newOperationId, oldOperationId]))
                expect(eventLog.routedEvents.map(\.id))
                    .to(equal([oldOperationId, newOperationId]))
                expect(try store.load()).to(beEmpty())
            }

            it("reconciles a completed same-target tail when an older command retires") {
                let oldOperationId = UUID.v7().uuidString
                let createdAt = Date(timeIntervalSince1970: 1_788_000_056)
                let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
                let store = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .production
                )
                try store.save([
                    FeatureUseCommand(
                        operationId: oldOperationId,
                        distinctId: "feature-customer",
                        featureId: "ai_generations",
                        amount: 7,
                        entityId: "project-retired-head",
                        setUsage: true,
                        metadata: nil,
                        createdAt: createdAt,
                        appendSequence: 1,
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
                let eventLog = MockEventLog()
                let featureInfo = FeatureInfo()
                await MainActor.run {
                    featureInfo.update([
                        "ai_generations": .withBalance(
                            10,
                            unlimited: false,
                            type: .creditSystem
                        ),
                    ])
                }
                let queue = FeatureUseCommandQueue(
                    api: api,
                    identity: identity,
                    eventLog: eventLog,
                    featureInfo: featureInfo,
                    dateProvider: MockDateProvider(initialDate: createdAt.addingTimeInterval(1)),
                    store: store
                )

                let recovery = Task { await queue.recover() }
                await api.waitForSuspendedFeatureTrackEvent()

                let youngerResult = try await queue.use(
                    distinctId: "feature-customer",
                    featureId: "ai_generations",
                    amount: 1,
                    entityId: "project-retired-head",
                    setUsage: false,
                    metadata: nil
                )
                expect(youngerResult.success).to(beTrue())
                expect(try store.load().count).to(equal(2))
                expect(eventLog.routedEvents).to(beEmpty())

                await api.configureTrackEventFailure(
                    error: NuxieNetworkError.httpError(
                        statusCode: 404,
                        message: "Feature not found"
                    )
                )
                await api.resumeSuspendedFeatureTrackEvent()
                await recovery.value

                expect(try store.load()).to(beEmpty())
                expect(eventLog.routedEvents.count).to(equal(1))
                expect(eventLog.routedEvents.first?.id).notTo(equal(oldOperationId))
                let balance = await MainActor.run {
                    featureInfo.balance("ai_generations")
                }
                expect(balance).to(equal(4))
            }

            it("reloads commands in append order when wall-clock timestamps reverse") {
                let firstOperationId = UUID.v7().uuidString
                let secondOperationId = UUID.v7().uuidString
                let laterWallClock = Date(timeIntervalSince1970: 1_788_000_059)
                let earlierWallClock = laterWallClock.addingTimeInterval(-10)
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
                        entityId: "first-capture",
                        setUsage: false,
                        metadata: nil,
                        createdAt: laterWallClock,
                        appendSequence: 1,
                        result: nil
                    ),
                    FeatureUseCommand(
                        operationId: secondOperationId,
                        distinctId: "feature-customer",
                        featureId: "video_exports",
                        amount: 1,
                        entityId: "second-capture",
                        setUsage: false,
                        metadata: nil,
                        createdAt: earlierWallClock,
                        appendSequence: 2,
                        result: nil
                    ),
                ])

                let api = MockNuxieApi()
                let identity = MockIdentityService()
                identity.setDistinctId("feature-customer")
                let queue = FeatureUseCommandQueue(
                    api: api,
                    identity: identity,
                    eventLog: MockEventLog(),
                    featureInfo: FeatureInfo(),
                    dateProvider: MockDateProvider(initialDate: laterWallClock),
                    store: store
                )

                await queue.recover()

                let featureSends = await api.sentEvents.filter {
                    $0.name == SystemEventNames.featureUsed
                }
                expect(featureSends.map(\.id))
                    .to(equal([firstOperationId, secondOperationId]))
                expect(try store.load()).to(beEmpty())
            }

            it("delivers younger same-target commands past a retryable failure") {
                let firstOperationId = UUID.v7().uuidString
                let blockedOperationId = UUID.v7().uuidString
                let independentOperationId = UUID.v7().uuidString
                let createdAt = Date(timeIntervalSince1970: 1_788_000_057)
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
                        amount: 7,
                        entityId: "project-ordered",
                        setUsage: true,
                        metadata: nil,
                        createdAt: createdAt,
                        appendSequence: 1,
                        result: nil
                    ),
                    FeatureUseCommand(
                        operationId: blockedOperationId,
                        distinctId: "feature-customer",
                        featureId: "ai_generations",
                        amount: 1,
                        entityId: "project-ordered",
                        setUsage: false,
                        metadata: nil,
                        createdAt: createdAt.addingTimeInterval(1),
                        appendSequence: 2,
                        result: nil
                    ),
                    FeatureUseCommand(
                        operationId: independentOperationId,
                        distinctId: "feature-customer",
                        featureId: "video_exports",
                        amount: 1,
                        entityId: "project-ordered",
                        setUsage: false,
                        metadata: nil,
                        createdAt: createdAt.addingTimeInterval(2),
                        appendSequence: 3,
                        result: nil
                    ),
                ])

                let api = MockNuxieApi()
                await api.configureTrackEventFailure(
                    error: NuxieNetworkError.httpError(
                        statusCode: 500,
                        message: "retry later"
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

                await queue.recover()

                let featureSends = await api.sentEvents.filter {
                    $0.name == SystemEventNames.featureUsed
                }
                expect(featureSends.map(\.id))
                    .to(equal([firstOperationId, blockedOperationId, independentOperationId]))
                expect(try store.load().map(\.operationId))
                    .to(equal([firstOperationId, blockedOperationId, independentOperationId]))
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
                    appendSequence: 1,
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
                        appendSequence: 1,
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
                        appendSequence: 2,
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

            it("retires feature-not-found without replaying it") {
                let createdAt = Date(timeIntervalSince1970: 1_788_000_095)
                let appIdentifier = Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app"
                let store = FeatureUseCommandStore(
                    customStoragePath: storageURL,
                    appIdentifier: appIdentifier,
                    environment: .production
                )
                let api = MockNuxieApi()
                await api.configureTrackEventFailure(
                    error: NuxieNetworkError.httpError(
                        statusCode: 404,
                        message: "Feature not found"
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
                        featureId: "missing_feature",
                        amount: 1,
                        entityId: nil,
                        setUsage: false,
                        metadata: nil
                    )
                }.to(throwError { error in
                    let networkError = error as? NuxieNetworkError
                    expect(networkError?.httpStatusCode).to(equal(404))
                    expect(networkError?.errorDescription).to(contain("Feature not found"))
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

                let replayedFeatureSends = await relaunchedApi.sentEvents.filter {
                    $0.name == SystemEventNames.featureUsed
                }
                expect(replayedFeatureSends).to(beEmpty())
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
