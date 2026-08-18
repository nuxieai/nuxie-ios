import Foundation
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class AppStoreIntroEligibilityApiTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testRequestsSignedEligibilityForExactProductAndAppTransaction() async throws {
        let expectation = expectation(description: "eligibility request")
        StubURLProtocol.register(
            matcher: RequestMatchers.post("/app-store/intro-eligibility"),
            handler: { request in
                let body = try XCTUnwrap(request.httpBody)
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                XCTAssertEqual(json["apiKey"] as? String, "test-api-key")
                XCTAssertEqual(json["distinctId"] as? String, "customer-1")
                XCTAssertEqual(json["journeyId"] as? String, "journey-1")
                XCTAssertEqual(
                    json["experienceVersionId"] as? String,
                    "version_123"
                )
                XCTAssertEqual(json["placementId"] as? String, "paywall:0")
                XCTAssertEqual(
                    json["transactionId"] as? String,
                    "app-transaction-123"
                )
                XCTAssertNil(json["allowIntroductoryOffer"])
                expectation.fulfill()
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"token":"e30.e30.c2ln"}"#.utf8)
                )
            }
        )
        let api = NuxieApi(
            apiKey: "test-api-key",
            baseURL: URL(string: "https://api.nuxie.test")!,
            useGzipCompression: false,
            urlSession: TestURLSessionProvider.createNuxieTestSession()
        )

        let token = try await api.appStoreIntroEligibilityToken(
            distinctId: "customer-1",
            journeyId: "journey-1",
            experienceVersionId: "version_123",
            placementId: "paywall:0",
            transactionId: "app-transaction-123"
        )

        XCTAssertEqual(token, "e30.e30.c2ln")
        await fulfillment(of: [expectation], timeout: 1)
    }
}
