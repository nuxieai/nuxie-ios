import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class UseFeatureIntegrationTests: AsyncSpec {
    override class func spec() {
        describe("NuxieSDK.useFeatureAndWait integration") {
            var mocks: MockFactory!
            var mockApi: MockNuxieApi!

            beforeEach {

                mocks = MockFactory.shared

                // Get reference to mock API for assertions
                mockApi = mocks.nuxieApi

                // Setup SDK with test configuration and mock overrides
                let config = NuxieConfiguration(apiKey: "test-api-key")
                try? NuxieSDK.shared.setup(with: config, overrides: mocks.unitTestOverrides())

                // Set a known distinct ID for tests
                mocks.identityService.setDistinctId("test-user-123")
            }

            // MARK: - Basic Usage Tests

            describe("basic usage") {
                it("should call API with correct $feature_used event") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    let result = try await NuxieSDK.shared.useFeatureAndWait("ai_generations")

                    expect(result.success).to(beTrue())
                    expect(result.featureId).to(equal("ai_generations"))
                    expect(result.amountUsed).to(equal(1.0))

                    let lastCall = await mockApi.lastTrackEventCall
                    expect(lastCall?.event).to(equal("$feature_used"))
                    expect(lastCall?.distinctId).to(equal("test-user-123"))
                    expect(lastCall?.value).to(equal(1.0))
                }

                it("should include feature_extId in properties") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    _ = try await NuxieSDK.shared.useFeatureAndWait("premium_export")

                    let lastCall = await mockApi.lastTrackEventCall
                    let props = lastCall?.properties
                    expect(props?["feature_extId"] as? String).to(equal("premium_export"))
                }

                it("should use identity service distinctId") {
                    mocks.identityService.setDistinctId("custom-user-456")
                    await mockApi.configureTrackEventResponse(status: "ok")

                    _ = try await NuxieSDK.shared.useFeatureAndWait("test_feature")

                    let lastCall = await mockApi.lastTrackEventCall
                    expect(lastCall?.distinctId).to(equal("custom-user-456"))
                }
            }

            // MARK: - Custom Amount Tests

            describe("custom amount") {
                it("should send custom amount as value") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    let result = try await NuxieSDK.shared.useFeatureAndWait("credits", amount: 10.0)

                    expect(result.amountUsed).to(equal(10.0))

                    let lastCall = await mockApi.lastTrackEventCall
                    expect(lastCall?.value).to(equal(10.0))
                }

                it("should handle fractional amounts") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    let result = try await NuxieSDK.shared.useFeatureAndWait("tokens", amount: 2.5)

                    expect(result.amountUsed).to(equal(2.5))

                    let lastCall = await mockApi.lastTrackEventCall
                    expect(lastCall?.value).to(equal(2.5))
                }
            }

            // MARK: - Entity ID Tests

            describe("entityId") {
                it("should send entityId when provided") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    _ = try await NuxieSDK.shared.useFeatureAndWait(
                        "api_calls",
                        entityId: "project-123"
                    )

                    let lastCall = await mockApi.lastTrackEventCall
                    expect(lastCall?.entityId).to(equal("project-123"))
                }

                it("should not include entityId when nil") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    _ = try await NuxieSDK.shared.useFeatureAndWait("api_calls")

                    let lastCall = await mockApi.lastTrackEventCall
                    expect(lastCall?.entityId).to(beNil())
                }
            }

            // MARK: - setUsage Mode Tests

            describe("setUsage mode") {
                it("should include setUsage property when true") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    _ = try await NuxieSDK.shared.useFeatureAndWait(
                        "credits",
                        amount: 50,
                        setUsage: true
                    )

                    let lastCall = await mockApi.lastTrackEventCall
                    let props = lastCall?.properties
                    expect(props?["setUsage"] as? Bool).to(beTrue())
                }

                it("should not include setUsage when false (default)") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    _ = try await NuxieSDK.shared.useFeatureAndWait("credits")

                    let lastCall = await mockApi.lastTrackEventCall
                    let props = lastCall?.properties
                    expect(props?["setUsage"]).to(beNil())
                }
            }

            // MARK: - Metadata Tests

            describe("metadata") {
                it("should include metadata when provided") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    _ = try await NuxieSDK.shared.useFeatureAndWait(
                        "exports",
                        metadata: [
                            "format": "pdf",
                            "pages": 10
                        ]
                    )

                    let lastCall = await mockApi.lastTrackEventCall
                    let props = lastCall?.properties
                    let metadata = props?["metadata"] as? [String: Any]
                    expect(metadata?["format"] as? String).to(equal("pdf"))
                    expect(metadata?["pages"] as? Int).to(equal(10))
                }

                it("should not include metadata when nil") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    _ = try await NuxieSDK.shared.useFeatureAndWait("exports")

                    let lastCall = await mockApi.lastTrackEventCall
                    let props = lastCall?.properties
                    expect(props?["metadata"]).to(beNil())
                }
            }

            // MARK: - Response Handling Tests

            describe("response handling") {
                it("should parse usage info from response") {
                    let usage = EventResponse.Usage(current: 15, limit: 100, remaining: 85)
                    await mockApi.configureTrackEventResponse(
                        status: "ok",
                        message: "Usage tracked",
                        usage: usage
                    )

                    let result = try await NuxieSDK.shared.useFeatureAndWait("credits")

                    expect(result.success).to(beTrue())
                    expect(result.message).to(equal("Usage tracked"))
                    expect(result.usage).toNot(beNil())
                    expect(result.usage?.current).to(equal(15))
                    expect(result.usage?.limit).to(equal(100))
                    expect(result.usage?.remaining).to(equal(85))
                }

                it("should handle response without usage info") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    let result = try await NuxieSDK.shared.useFeatureAndWait("credits")

                    expect(result.success).to(beTrue())
                    expect(result.usage).to(beNil())
                }

                it("should recognize 'ok' status as success") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    let result = try await NuxieSDK.shared.useFeatureAndWait("feature")

                    expect(result.success).to(beTrue())
                }

                it("should recognize 'success' status as success") {
                    await mockApi.configureTrackEventResponse(status: "success")

                    let result = try await NuxieSDK.shared.useFeatureAndWait("feature")

                    expect(result.success).to(beTrue())
                }

                it("should recognize other statuses as failure") {
                    await mockApi.configureTrackEventResponse(status: "error")

                    let result = try await NuxieSDK.shared.useFeatureAndWait("feature")

                    expect(result.success).to(beFalse())
                }
            }

            // MARK: - Error Handling Tests

            describe("error handling") {
                it("should throw when SDK is not configured") {
                    await NuxieSDK.shared.shutdown()

                    await expect {
                        try await NuxieSDK.shared.useFeatureAndWait("feature")
                    }.to(throwError(NuxieError.notConfigured))
                }

                it("should propagate API errors") {
                    await mockApi.configureTrackEventFailure(
                        error: NuxieNetworkError.httpError(statusCode: 500, message: "Server error")
                    )

                    await expect {
                        try await NuxieSDK.shared.useFeatureAndWait("feature")
                    }.to(throwError())
                }

                it("should propagate network errors") {
                    await mockApi.configureTrackEventFailure(
                        error: URLError(.networkConnectionLost)
                    )

                    await expect {
                        try await NuxieSDK.shared.useFeatureAndWait("feature")
                    }.to(throwError())
                }
            }

            // MARK: - Call Count Tests

            describe("API call tracking") {
                it("should make exactly one API call per useFeatureAndWait") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    _ = try await NuxieSDK.shared.useFeatureAndWait("feature1")
                    _ = try await NuxieSDK.shared.useFeatureAndWait("feature2")
                    _ = try await NuxieSDK.shared.useFeatureAndWait("feature3")

                    let callCount = await mockApi.trackEventCallCount
                    expect(callCount).to(equal(3))
                }
            }

            // MARK: - Combined Parameters Tests

            describe("combined parameters") {
                it("should handle all parameters together") {
                    let usage = EventResponse.Usage(current: 50, limit: 100, remaining: 50)
                    await mockApi.configureTrackEventResponse(
                        status: "ok",
                        message: "All params test",
                        usage: usage
                    )

                    let result = try await NuxieSDK.shared.useFeatureAndWait(
                        "premium_feature",
                        amount: 5.0,
                        entityId: "org:123/project:456",
                        setUsage: false,
                        metadata: ["reason": "test", "count": 42]
                    )

                    expect(result.success).to(beTrue())
                    expect(result.featureId).to(equal("premium_feature"))
                    expect(result.amountUsed).to(equal(5.0))
                    expect(result.message).to(equal("All params test"))
                    expect(result.usage?.current).to(equal(50))

                    let lastCall = await mockApi.lastTrackEventCall
                    expect(lastCall?.event).to(equal("$feature_used"))
                    expect(lastCall?.value).to(equal(5.0))
                    expect(lastCall?.entityId).to(equal("org:123/project:456"))

                    let props = lastCall?.properties
                    expect(props?["feature_extId"] as? String).to(equal("premium_feature"))

                    let metadata = props?["metadata"] as? [String: Any]
                    expect(metadata?["reason"] as? String).to(equal("test"))
                    expect(metadata?["count"] as? Int).to(equal(42))
                }
            }

            // MARK: - Edge Cases

            describe("edge cases") {
                it("should handle empty feature ID") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    let result = try await NuxieSDK.shared.useFeatureAndWait("")

                    expect(result.featureId).to(equal(""))

                    let lastCall = await mockApi.lastTrackEventCall
                    let props = lastCall?.properties
                    expect(props?["feature_extId"] as? String).to(equal(""))
                }

                it("should handle zero amount") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    let result = try await NuxieSDK.shared.useFeatureAndWait("feature", amount: 0)

                    expect(result.amountUsed).to(equal(0))

                    let lastCall = await mockApi.lastTrackEventCall
                    expect(lastCall?.value).to(equal(0))
                }

                it("should handle very large amounts") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    let largeAmount = 999999999.99
                    let result = try await NuxieSDK.shared.useFeatureAndWait("feature", amount: largeAmount)

                    expect(result.amountUsed).to(beCloseTo(largeAmount, within: 0.01))

                    let lastCall = await mockApi.lastTrackEventCall
                    expect(lastCall?.value).to(beCloseTo(largeAmount, within: 0.01))
                }

                it("should handle special characters in all string fields") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    _ = try await NuxieSDK.shared.useFeatureAndWait(
                        "feature-with_special.chars:v2",
                        entityId: "org:123/project:456",
                        metadata: ["key with spaces": "value/with/slashes"]
                    )

                    let lastCall = await mockApi.lastTrackEventCall
                    let props = lastCall?.properties
                    expect(props?["feature_extId"] as? String).to(equal("feature-with_special.chars:v2"))
                    expect(lastCall?.entityId).to(equal("org:123/project:456"))

                    let metadata = props?["metadata"] as? [String: Any]
                    expect(metadata?["key with spaces"] as? String).to(equal("value/with/slashes"))
                }
            }

            // MARK: - Discardable Result

            describe("discardable result") {
                it("should allow ignoring the result") {
                    await mockApi.configureTrackEventResponse(status: "ok")

                    // This should compile without warnings due to @discardableResult
                    try await NuxieSDK.shared.useFeatureAndWait("feature")

                    let callCount = await mockApi.trackEventCallCount
                    expect(callCount).to(equal(1))
                }
            }
        }
    }
}
