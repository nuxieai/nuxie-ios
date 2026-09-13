import Foundation
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private actor ReceiptFeatureChecks: FeatureChecking {
    private var calls = 0

    func checkFeature(customerId: String, featureId: String, requiredBalance: Double?, entityId: String?) async throws -> FeatureCheckResult {
        calls += 1
        return FeatureCheckResult(customerId: customerId, featureId: featureId, requiredBalance: requiredBalance ?? 1,
            code: "ok", allowed: calls == 1, unlimited: false, balance: calls == 1 ? 1 : 0, type: .metered, preview: nil)
    }
}

private actor SuspendedReceiptCheck: FeatureChecking {
    private var response: CheckedContinuation<FeatureCheckResult, Error>?
    private var started: [CheckedContinuation<Void, Never>] = []

    func waitUntilStarted() async {
        if response != nil { return }
        await withCheckedContinuation { started.append($0) }
    }

    func release() {
        response?.resume(returning: FeatureCheckResult(customerId: "customer", featureId: "credits", requiredBalance: 1,
            code: "ok", allowed: true, unlimited: false, balance: 1, type: .metered, preview: nil))
        response = nil
    }

    func checkFeature(customerId: String, featureId: String, requiredBalance: Double?, entityId: String?) async throws -> FeatureCheckResult {
        try await withCheckedThrowingContinuation { continuation in
            response = continuation
            started.forEach { $0.resume() }
            started.removeAll()
        }
    }
}

@MainActor
final class FeatureCommandReceiptTests: XCTestCase {
    private func registerReceipt(unlimited: Bool = false) {
        StubURLProtocol.reset()
        StubURLProtocol.register(matcher: RequestMatchers.post("/feature/consume"), handler: { request in
            var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            receipt.removeValue(forKey: "apiKey")
            receipt.merge(["accepted": true, "active": unlimited, "balance": unlimited ? NSNull() : 0, "unlimited": unlimited,
                "type": "metered", "code": "consumed", "occurredAtMs": 1234, "idempotentReplay": false]) { _, new in new }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                try JSONSerialization.data(withJSONObject: receipt))
        })
    }

    func testConflictRetiresButMergeRemainsRecoverable() async throws {
        for code in ["operation_conflict", "merge_in_progress"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = FeatureUseCommandStore(customStoragePath: directory,
                appIdentifier: "receipt-tests", environment: .production)
            let identity = MockIdentityService()
            identity.setDistinctId("customer")
            let info = FeatureInfo()
            info.admitProfileSnapshot(["credits": .withBalance(2, unlimited: false, type: .metered)], admittedAt: Date())
            let session = TestURLSessionProvider.createNuxieTestSession()
            defer { session.invalidateAndCancel() }
            let api = NuxieApi(apiKey: "test-key", baseURL: URL(string: "https://test.nuxie.ai")!, urlSession: session)
            func queue() -> FeatureUseCommandQueue {
                FeatureUseCommandQueue(api: api, identity: identity, eventLog: MockEventLog(),
                    featureInfo: info, dateProvider: MockDateProvider(), store: store)
            }
            StubURLProtocol.reset()
            StubURLProtocol.register(matcher: RequestMatchers.post("/feature/consume"), handler: { request in
                (HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!,
                    Data("{\"code\":\"\(code)\"}".utf8))
            })
            let original = queue()
            do {
                _ = try await original.use(distinctId: "customer", featureId: "credits", amount: 1,
                    entityId: nil, setUsage: false, metadata: nil, operationId: "first")
                XCTFail("A 409 is not an accepted receipt")
            } catch {
                XCTAssertEqual((error as? NuxieNetworkError)?.code, code)
            }
            XCTAssertEqual(try store.load().count, code == "operation_conflict" ? 0 : 1)
            registerReceipt()
            let reopened = queue()
            await reopened.recover()
            XCTAssertTrue(try store.load().isEmpty)
            let result = try await reopened.use(distinctId: "customer", featureId: "credits", amount: 1,
                entityId: nil, setUsage: false, metadata: nil, operationId: "next")
            XCTAssertTrue(result.success)
            XCTAssertNil(result.usage)
            XCTAssertEqual(result.authoritativeAccess?.balance, 0)
            XCTAssertEqual(info.balance("credits"), 0)
            XCTAssertTrue(try store.load().isEmpty, "A later receipt must finish reconciliation")
        }
    }

    func testCommandsInvalidateMatchingCachedAuthority() async throws {
        for entityId: String? in [nil, "project-a"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let info = FeatureInfo()
        info.admitProfileSnapshot(["credits": .withBalance(100, unlimited: false, type: .metered)], admittedAt: Date())
        let features = FeatureService(api: ReceiptFeatureChecks(), identity: identity,
            profile: MockProfileService(), dateProvider: MockDateProvider(), featureInfo: info, cacheTTL: 300)
        let initial = try await features.checkWithCache(featureId: "credits", requiredBalance: 1,
            entityId: entityId, forceRefresh: false)
        XCTAssertTrue(initial.allowed)
        let session = TestURLSessionProvider.createNuxieTestSession()
        defer { session.invalidateAndCancel() }
        let api = NuxieApi(apiKey: "test-key", baseURL: URL(string: "https://test.nuxie.ai")!, urlSession: session)
        registerReceipt()
        let queue = FeatureUseCommandQueue(api: api, identity: identity, eventLog: MockEventLog(),
            featureInfo: info, dateProvider: MockDateProvider(),
            store: FeatureUseCommandStore(customStoragePath: directory, appIdentifier: "receipt-tests", environment: .production),
            features: features)
        _ = try await queue.use(distinctId: "customer", featureId: "credits", amount: 1,
            entityId: entityId, setUsage: false, metadata: nil, operationId: "last")
        let cached = await features.getCached(featureId: "credits", entityId: entityId)
        XCTAssertNil(cached)
        let after = try await features.checkWithCache(featureId: "credits", requiredBalance: 1,
            entityId: entityId, forceRefresh: false)
        XCTAssertFalse(after.allowed)
        XCTAssertEqual(after.balance, 0)
        XCTAssertEqual(info.balance("credits"), entityId == nil ? 0 : 100)
        }
    }
    func testInvalidationRejectsInFlightCheckResults() async throws {
        for cached in [false, true] {
            let api = SuspendedReceiptCheck()
            let identity = MockIdentityService()
            identity.setDistinctId("customer")
            let service = FeatureService(api: api, identity: identity, profile: MockProfileService(),
                dateProvider: MockDateProvider(), featureInfo: FeatureInfo(), cacheTTL: 300)
            let check = Task {
                if cached {
                    _ = try await service.checkWithCache(featureId: "credits", requiredBalance: 1, entityId: "project-a", forceRefresh: false)
                } else {
                    _ = try await service.check(featureId: "credits", requiredBalance: 1, entityId: "project-a")
                }
            }
            await api.waitUntilStarted()
            await service.invalidateAccess(featureId: "credits", entityId: "project-a", distinctId: "customer")
            await api.release()
            do { try await check.value; XCTFail("The check predates consumption") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testAggregateCacheCannotRepublishAnInvalidatedProfileBalance() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let profile = MockProfileService()
        profile.setProfileResponse(TestJourneyProfile.response(features: [
            Feature(id: "credits", type: .metered, balance: 5, unlimited: false,
                nextResetAt: nil, interval: nil, entities: nil)
        ]))
        _ = try await profile.refetchProfile(distinctId: "customer")
        let info = FeatureInfo()
        let service = FeatureService(api: ReceiptFeatureChecks(), identity: identity, profile: profile,
            dateProvider: MockDateProvider(), featureInfo: info, cacheTTL: 300)
        await service.syncFeatureInfo()
        XCTAssertEqual(info.balance("credits"), 5)
        await service.invalidateAccess(featureId: "credits", entityId: nil, distinctId: "customer")
        let all = await service.getAllCached()
        XCTAssertNil(all["credits"])
        await service.syncFeatureInfo()
        XCTAssertNil(info.balance("credits"))
        _ = try await profile.refetchProfile(distinctId: "customer")
        await service.syncFeatureInfo()
        XCTAssertEqual(info.balance("credits"), 5, "A request begun after invalidation restores profile authority")
    }

    func testConsumptionInvalidatesEveryScopeOfTheFeature() async throws {
        for spentEntity: String? in [nil, "project-a"] {
            let identity = MockIdentityService()
            identity.setDistinctId("customer")
            let profile = MockProfileService()
            profile.setProfileResponse(TestJourneyProfile.response(features: [
                Feature(id: "credits", type: .metered, balance: 5, unlimited: false,
                    nextResetAt: nil, interval: nil, entities: ["project-b": EntityBalance(balance: 2)])
            ]))
            _ = try await profile.refetchProfile(distinctId: "customer")
            let service = FeatureService(api: ReceiptFeatureChecks(), identity: identity, profile: profile,
                dateProvider: MockDateProvider(), featureInfo: FeatureInfo(), cacheTTL: 300)
            _ = try await service.check(featureId: "credits", requiredBalance: 1, entityId: "project-a")
            await service.invalidateAccess(featureId: "credits", entityId: spentEntity, distinctId: "customer")
            for queriedEntity: String? in [nil, "project-a", "project-b"] {
                let cached = await service.getCached(featureId: "credits", entityId: queriedEntity)
                XCTAssertNil(cached)
            }
        }
    }

    func testUnlimitedReceiptReplacesFiniteVisibleAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let info = FeatureInfo()
        info.admitProfileSnapshot(["credits": .withBalance(2, unlimited: false, type: .metered)], admittedAt: Date())
        let session = TestURLSessionProvider.createNuxieTestSession()
        defer { session.invalidateAndCancel() }
        let api = NuxieApi(apiKey: "test-key", baseURL: URL(string: "https://test.nuxie.ai")!, urlSession: session)
        registerReceipt(unlimited: true)
        let queue = FeatureUseCommandQueue(api: api, identity: identity, eventLog: MockEventLog(), featureInfo: info,
            dateProvider: MockDateProvider(), store: FeatureUseCommandStore(customStoragePath: directory,
                appIdentifier: "receipt-tests", environment: .production))
        let result = try await queue.use(distinctId: "customer", featureId: "credits", amount: 1,
            entityId: nil, setUsage: false, metadata: nil, operationId: "unlimited")
        XCTAssertTrue(result.success)
        XCTAssertEqual(info.all["credits"]?.unlimited, true)
        XCTAssertEqual(info.all["credits"]?.allowed, true)
        XCTAssertNil(info.balance("credits"))
    }

    func testHistoryScopesCallerIdsAndKeepsOriginalReceiptTime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MockIdentityService()
        let events = MockEventLog()
        let session = TestURLSessionProvider.createNuxieTestSession()
        defer { session.invalidateAndCancel() }
        let api = NuxieApi(apiKey: "test-key", baseURL: URL(string: "https://test.nuxie.ai")!, urlSession: session)
        registerReceipt()
        let queue = FeatureUseCommandQueue(api: api, identity: identity, eventLog: events, featureInfo: FeatureInfo(),
            dateProvider: MockDateProvider(), store: FeatureUseCommandStore(customStoragePath: directory,
                appIdentifier: "receipt-tests", environment: .production), historyScope: "app-test")
        for customer in ["customer-a", "customer-b", "customer-a"] {
            identity.setDistinctId(customer)
            let result = try await queue.use(distinctId: customer, featureId: "credits", amount: 1,
                entityId: nil, setUsage: false, metadata: nil, operationId: "use-1")
            XCTAssertEqual(result.consumptionReceipt?.operationId, "use-1")
        }
        let history = events.routedEvents
        XCTAssertEqual(history.count, 3)
        XCTAssertNotEqual(history[0].id, history[1].id)
        XCTAssertEqual(history[0].id, history[2].id, "Completed command retries must reuse the history identity")
        XCTAssertTrue(history.allSatisfy { $0.timestamp == Date(timeIntervalSince1970: 1.234) })
    }

    func testPendingCustomerCannotBlockAnotherCustomersOperationId() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = FeatureUseCommandStore(customStoragePath: directory, appIdentifier: "receipt-tests", environment: .production)
        let session = TestURLSessionProvider.createNuxieTestSession()
        defer { session.invalidateAndCancel() }
        let api = NuxieApi(apiKey: "test-key", baseURL: URL(string: "https://test.nuxie.ai")!, urlSession: session)
        let queue = FeatureUseCommandQueue(api: api, identity: identity, eventLog: MockEventLog(), featureInfo: FeatureInfo(),
            dateProvider: MockDateProvider(), store: store)
        StubURLProtocol.reset()
        StubURLProtocol.register(matcher: RequestMatchers.post("/feature/consume"), handler: { request in
            (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        })
        do {
            _ = try await queue.use(distinctId: "customer-a", featureId: "credits", amount: 1,
                entityId: nil, setUsage: false, metadata: nil, operationId: "use-1")
            XCTFail("A should remain pending")
        } catch { XCTAssertEqual((error as? NuxieNetworkError)?.httpStatusCode, 503) }
        identity.setDistinctId("customer-b")
        registerReceipt()
        let result = try await queue.use(distinctId: "customer-b", featureId: "credits", amount: 2,
            entityId: nil, setUsage: false, metadata: nil, operationId: "use-1")
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.consumptionReceipt?.operationId, "use-1")
        XCTAssertEqual(try store.load().map(\.distinctId), ["customer-a"])
        identity.setDistinctId("customer-a")
        await queue.recover()
        XCTAssertTrue(try store.load().isEmpty)
    }

}
