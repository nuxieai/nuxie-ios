import Foundation
import Nimble
import Quick
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

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

            it("joins an identical foreground retry to recovery already in flight") {
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
                let foreground = Task {
                    try await queue.use(
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
                await api.resumeSuspendedFeatureTrackEvent()

                await recovery.value
                let foregroundResult = try await foreground.value
                expect(foregroundResult.success).to(beTrue())
                expect(foregroundResult.featureId).to(equal("ai_generations"))
                expect(foregroundResult.usage?.remaining).to(equal(4))

                let featureSends = await api.sentEvents.filter {
                    $0.name == SystemEventNames.featureUsed
                }
                expect(featureSends.map(\.id)).to(equal([operationId]))
                let uniqueAcceptedCount = await api.uniqueAcceptedTrackEventCount
                expect(uniqueAcceptedCount).to(equal(1))
                let completedPendingCount = try await queue.pendingCount()
                expect(completedPendingCount).to(equal(0))
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
        }
    }
}
