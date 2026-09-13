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

@MainActor
final class FeatureCommandReceiptTests: XCTestCase {
    private func registerReceipt() {
        StubURLProtocol.reset()
        StubURLProtocol.register(matcher: RequestMatchers.post("/feature/consume"), handler: { request in
            var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            receipt.removeValue(forKey: "apiKey")
            receipt.merge(["accepted": true, "active": false, "balance": 0, "unlimited": false,
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
}
