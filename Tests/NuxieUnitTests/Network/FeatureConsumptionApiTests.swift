import Foundation
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class FeatureConsumptionApiTests: XCTestCase {
    func testSharedCommandReceiptsUseTheDedicatedEndpoint() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/encodings/feature-consumption.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for vector in try XCTUnwrap(root["vectors"] as? [[String: Any]]) {
            let requestBody = try XCTUnwrap(vector["request"] as? [String: Any])
            let requestData = try JSONSerialization.data(withJSONObject: requestBody)
            let responseData = try JSONSerialization.data(withJSONObject: XCTUnwrap(vector["response"]))
            let command = try JSONDecoder().decode(FeatureConsumeRequest.self, from: requestData)
            let expected = try JSONDecoder().decode(FeatureConsumeResponse.self, from: responseData)
            StubURLProtocol.reset()
            StubURLProtocol.register(matcher: RequestMatchers.post("/feature/consume"), handler: { request in
                let body = try XCTUnwrap(request.httpBody)
                var actual = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(actual.removeValue(forKey: "apiKey") as? String, "test-key")
                let expectedBody = try JSONSerialization.jsonObject(with: requestData) as! NSDictionary
                XCTAssertEqual(actual as NSDictionary, expectedBody)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, responseData)
            })
            let session = TestURLSessionProvider.createNuxieTestSession()
            let api = NuxieApi(apiKey: "test-key", baseURL: URL(string: "https://test.nuxie.ai")!, urlSession: session)
            let result: EventResponse
            if let purchase = requestBody["purchase"] as? [String: Any] {
                let request = PurchaseBackedFeatureUseRequest(
                    customerId: command.customerId,
                    featureId: command.featureId,
                    requiredBalance: command.quantity,
                    eventData: .init(value: command.quantity, properties: nil),
                    entityId: command.entityId,
                    purchase: .init(
                        transactionJwt: try XCTUnwrap(purchase["signedTransaction"] as? String),
                        eventId: command.operationId
                    ),
                    customerKind: (requestBody["customerKind"] as? String)
                        .flatMap(PurchaseCustomerKind.init(rawValue:))
                )
                let response = try await api.useFeatureWithPurchase(request)
                result = try XCTUnwrap(response.consumptionReceipt).journalResponse
            } else {
                result = try await api.consumeFeature(command)
            }
            XCTAssertNil(result.usage, "A command quantity is not a cumulative usage counter")
            let publicReceipt = FeatureConsumptionResult(try XCTUnwrap(result.consumption))
            XCTAssertEqual(publicReceipt.customerId, expected.customerId)
            XCTAssertEqual(publicReceipt.featureId, expected.featureId)
            XCTAssertEqual(publicReceipt.occurredAtMs, expected.occurredAtMs)
            XCTAssertEqual(result.status == "ok", expected.accepted)
            XCTAssertEqual(result.consumption?.active, expected.active)
            XCTAssertEqual(result.consumption?.balance, expected.balance)
            XCTAssertEqual(result.consumption?.idempotentReplay, expected.idempotentReplay)
            session.invalidateAndCancel()
        }
    }

    func testOlderEncodedPurchaseCommandKeepsOmittingCustomerKind() async throws {
        let data = Data(#"{"customerId":"customer","featureId":"credits","requiredBalance":1,"eventData":{"value":1},"idempotencyKey":"purchase-use","purchase":{"transaction_jwt":"signed-jws","event_id":"purchase-use"}}"#.utf8)
        let command = try JSONDecoder().decode(PurchaseBackedFeatureUseRequest.self, from: data)
        XCTAssertNil(command.customerKind)
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any]
        )
        XCTAssertNil(encoded["customerKind"])
        StubURLProtocol.reset()
        StubURLProtocol.register(matcher: RequestMatchers.post("/feature/consume"), handler: { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertNil(body["customerKind"])
            XCTAssertNil(body["customer_kind"])
            XCTAssertEqual((body["purchase"] as? [String: String])?["signedTransaction"], "signed-jws")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"customerId":"customer","featureId":"credits","operationId":"purchase-use","quantity":1,"accepted":true,"code":"consumed","balance":0,"unlimited":false,"active":false,"type":"metered","idempotentReplay":true}"#.utf8))
        })
        let session = TestURLSessionProvider.createNuxieTestSession()
        defer { session.invalidateAndCancel() }
        let api = NuxieApi(apiKey: "test-key", baseURL: URL(string: "https://test.nuxie.ai")!, urlSession: session)
        _ = try await api.useFeatureWithPurchase(command)
    }
    func testPurchaseReceiptPreservesReplayStatus() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.register(matcher: RequestMatchers.post("/feature/consume"), handler: { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"customerId":"customer","featureId":"credits","operationId":"purchase-use","quantity":1,"accepted":true,"code":"consumed","balance":3,"unlimited":false,"active":true,"type":"metered","occurredAtMs":1234,"idempotentReplay":true}"#.utf8))
        })
        let session = TestURLSessionProvider.createNuxieTestSession()
        defer { session.invalidateAndCancel() }
        let api = NuxieApi(apiKey: "test-key", baseURL: URL(string: "https://test.nuxie.ai")!, urlSession: session)
        let response = try await api.useFeatureWithPurchase(.init(customerId: "customer", featureId: "credits",
            requiredBalance: 1, eventData: .init(value: 1, properties: nil), entityId: nil,
            purchase: .init(transactionJwt: "signed-jws", eventId: "purchase-use")))
        XCTAssertEqual(response.idempotentReplay, true)
        XCTAssertEqual(response.balance, 3)
        XCTAssertEqual(response.consumptionReceipt?.operationId, "purchase-use")
        XCTAssertEqual(response.consumptionReceipt?.occurredAtMs, 1234)
    }

}
