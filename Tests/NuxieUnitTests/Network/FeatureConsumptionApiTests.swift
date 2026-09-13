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
            let requestData = try JSONSerialization.data(withJSONObject: XCTUnwrap(vector["request"]))
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
            let result = try await api.consumeFeature(command)
            XCTAssertEqual(result.status == "ok", expected.accepted)
            XCTAssertEqual(result.consumption?.active, expected.active)
            XCTAssertEqual(result.consumption?.balance, expected.balance)
            XCTAssertEqual(result.consumption?.idempotentReplay, expected.idempotentReplay)
            session.invalidateAndCancel()
        }
    }
}
