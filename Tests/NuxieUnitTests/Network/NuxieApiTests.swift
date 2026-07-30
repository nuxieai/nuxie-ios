import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class NuxieApiTests: AsyncSpec {
    override class func spec() {
        describe("NuxieApi") {
            var api: NuxieApi!
            var session: URLSession!
            let apiKey = "test-api-key"
            let baseURL = URL(string: "https://test.nuxie.ai")!
            
            beforeEach {
                // Reset protocol handlers
                
                // Create test session
                session = TestURLSessionProvider.createNuxieTestSession()
                
                // Initialize API with test session
                api = NuxieApi(
                    apiKey: apiKey,
                    baseURL: baseURL,
                    useGzipCompression: false,
                    urlSession: session
                )
            }
            
            afterEach {
                api = nil
                session = nil
            }
            
            describe("fetchProfile") {
                let distinctId = "test-user-123"
                
                it("should successfully fetch profile") {
                    // Setup stub response
                    let profileResponse = ResponseBuilders.buildProfileResponse(
                        experiences: [ResponseBuilders.buildExperience()],
                        segments: []
                    )
                    
                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/profile"),
                        handler: { request in
                            let data = try ResponseBuilders.toJSON(profileResponse)
                            let response = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (response, data)
                        }
                    )
                    
                    let result = try await api.fetchProfile(for: distinctId)
                    expect(result.experiences).to(haveCount(1))
                }
                
                it("should handle network errors") {
                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/profile"),
                        handler: { _ in throw URLError(.networkConnectionLost) }
                    )
                    
                    do {
                        _ = try await api.fetchProfile(for: distinctId)
                        fail("Expected to throw URLError")
                    } catch let error as URLError {
                        expect(error.code).to(equal(.networkConnectionLost))
                    } catch {
                        fail("Expected URLError but got \(error)")
                    }
                }
                
                it("should handle HTTP errors") {
                    let errorResponse = ResponseBuilders.buildErrorResponse(
                        message: "Invalid API key"
                    )
                    
                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/profile"),
                        handler: { request in
                            let data = try ResponseBuilders.toJSON(errorResponse)
                            let response = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 401,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (response, data)
                        }
                    )
                    
                    await expect {
                        try await api.fetchProfile(for: distinctId)
                    }.to(throwError())
                }
                
                it("should send correct request body") {
                    var capturedRequest: URLRequest?
                    
                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/profile"),
                        handler: { request in
                            capturedRequest = request
                            
                            let response = ResponseBuilders.buildProfileResponse(
                                experiences: [],
                                segments: []
                            )
                            
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )
                    
                    _ = try? await api.fetchProfile(for: distinctId)
                    
                    expect(capturedRequest).toNot(beNil())
                    
                    if let body = capturedRequest?.httpBody,
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                        expect(json["distinct_id"] as? String).to(equal(distinctId))
                        expect(json["apiKey"] as? String).to(equal(apiKey))
                    } else {
                        fail("Request body not found or invalid")
                    }
                }
            }
            
            describe("fetchProfileWithTimeout") {
                let distinctId = "test-user-123"
                let customTimeout: TimeInterval = 5.0
                
                it("should use custom timeout") {
                    var capturedRequest: URLRequest?
                    
                    StubURLProtocol.register(
                        matcher: { request in
                            return request.httpMethod == "POST" && request.url?.path == "/profile"
                        },
                        handler: { request in
                            capturedRequest = request
                            
                            let response = ResponseBuilders.buildProfileResponse(
                                experiences: [],
                                segments: []
                            )
                            
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )
                    
                    do {
                        _ = try await api.fetchProfileWithTimeout(
                            for: distinctId,
                            timeout: customTimeout
                        )
                    } catch {
                        fail("fetchProfileWithTimeout threw error: \(error)")
                    }
                    
                    expect(capturedRequest).toNot(beNil())
                    expect(capturedRequest?.timeoutInterval).to(equal(customTimeout))
                }
            }
            
            describe("trackEvent") {
                let event = "test_event"
                let distinctId = "user-123"
                let properties = ["key": "value"]
                let value = 99.99
                
                it("should successfully track event") {
                    let eventResponse = ResponseBuilders.buildEventResponse()
                    
                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/event"),
                        handler: { request in
                            let data = try ResponseBuilders.toJSON(eventResponse)
                            let response = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (response, data)
                        }
                    )
                    
                    let result = try await api.trackEvent(
                        event: event,
                        distinctId: distinctId,
                        properties: properties,
                        value: value
                    )
                    
                    expect(result.status).to(equal("success"))
                }
                
                it("should send correct event data") {
                    var capturedRequest: URLRequest?
                    
                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/event"),
                        handler: { request in
                            capturedRequest = request
                            
                            let response = ResponseBuilders.buildEventResponse()
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )
                    
                    _ = try? await api.trackEvent(
                        event: event,
                        distinctId: distinctId,
                        properties: properties,
                        value: value
                    )
                    
                    expect(capturedRequest).toNot(beNil())
                    
                    if let body = capturedRequest?.httpBody,
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                        expect(json["event"] as? String).to(equal(event))
                        expect(json["distinct_id"] as? String).to(equal(distinctId))
                        expect(json["value"] as? Double).to(equal(value))
                        expect(json["apiKey"] as? String).to(equal(apiKey))
                    } else {
                        fail("Request body not found or invalid")
                    }
                }

                it("preserves a captured event's identity and timestamp") {
                    var capturedRequest: URLRequest?
                    let timestamp = Date(timeIntervalSince1970: 1_753_459_200.789)
                    let capturedEvent = NuxieEvent(
                        id: "journey-handoff-1",
                        name: "$journey_handoff",
                        distinctId: distinctId,
                        properties: [
                            "journey_id": "journey-1",
                            // Event sanitization bridges integer properties
                            // through NSNumber before the request is encoded.
                            "enabled": NSNumber(value: true),
                            "zero": NSNumber(value: 0),
                            "epoch": NSNumber(value: 1),
                            "signed": NSNumber(value: -4),
                            "unsigned_max": NSNumber(value: UInt64.max),
                            "float": NSNumber(value: Float(0.1)),
                            "double": NSNumber(value: Double(0.1)),
                        ],
                        timestamp: timestamp
                    )

                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/event"),
                        handler: { request in
                            capturedRequest = request
                            let response = ResponseBuilders.buildEventResponse()
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )

                    _ = try await api.trackEvent(capturedEvent)

                    guard let body = capturedRequest?.httpBody,
                          let json = try JSONSerialization.jsonObject(with: body)
                            as? [String: Any] else {
                        fail("Request body not found or invalid")
                        return
                    }

                    expect(json["event"] as? String).to(equal("$journey_handoff"))
                    expect(json["distinct_id"] as? String).to(equal(distinctId))
                    expect(json["idempotency_key"] as? String)
                        .to(equal("journey-handoff-1"))
                    expect(json["timestamp"] as? String)
                        .to(equal("2025-07-25T16:00:00.789Z"))
                    guard let properties = json["properties"] as? [String: Any],
                          let epoch = properties["epoch"] as? NSNumber else {
                        fail("Expected numeric epoch property")
                        return
                    }
                    expect(epoch.intValue).to(equal(1))
                    expect(CFGetTypeID(epoch)).toNot(equal(CFBooleanGetTypeID()))
                    let enabled = properties["enabled"] as? NSNumber
                    expect(enabled?.boolValue).to(beTrue())
                    expect(enabled.map(CFGetTypeID)).to(equal(CFBooleanGetTypeID()))
                    let zero = properties["zero"] as? NSNumber
                    expect(zero?.intValue).to(equal(0))
                    expect(zero.map(CFGetTypeID)).toNot(equal(CFBooleanGetTypeID()))
                    expect((properties["signed"] as? NSNumber)?.intValue).to(equal(-4))
                    expect((properties["unsigned_max"] as? NSNumber)?.stringValue)
                        .to(equal(String(UInt64.max)))
                    expect((properties["float"] as? NSNumber)?.stringValue)
                        .to(equal("0.1"))
                    expect((properties["double"] as? NSNumber)?.doubleValue)
                        .to(equal(0.1))
                }
            }
            
            describe("sendBatch") {
                let events = [
                    BatchEventItem(
                        event: "event1",
                        distinctId: "user1",
                        timestamp: Date(),
                        properties: ["key": "value1"]
                    ),
                    BatchEventItem(
                        event: "event2",
                        distinctId: "user2",
                        timestamp: Date(),
                        properties: ["key": "value2"]
                    )
                ]

                it("preserves fractional seconds in queued event timestamps") {
                    let item = BatchEventItem(
                        event: "precise_event",
                        distinctId: "user1",
                        timestamp: Date(timeIntervalSince1970: 1_753_459_200.789)
                    )

                    expect(item.timestamp).to(equal("2025-07-25T16:00:00.789Z"))
                }
                
                it("should successfully send batch") {
                    let batchResponse = ResponseBuilders.buildBatchResponse(
                        processed: 2,
                        failed: 0
                    )
                    
                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/batch"),
                        handler: { request in
                            let data = try ResponseBuilders.toJSON(batchResponse)
                            let response = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (response, data)
                        }
                    )
                    
                    let result = try await api.sendBatch(events: events)
                    
                    expect(result.processed).to(equal(2))
                    expect(result.failed).to(equal(0))
                }
                
                it("should send batch data correctly") {
                    var capturedRequest: URLRequest?
                    
                    StubURLProtocol.register(
                        matcher: { request in
                            return request.httpMethod == "POST" && request.url?.path == "/batch"
                        },
                        handler: { request in
                            capturedRequest = request
                            
                            let response = ResponseBuilders.buildBatchResponse(
                                processed: events.count,
                                failed: 0
                            )
                            let data = try ResponseBuilders.toJSON(response)
                            let httpResponse = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (httpResponse, data)
                        }
                    )
                    
                    do {
                        _ = try await api.sendBatch(events: events)
                    } catch {
                        fail("sendBatch threw error: \(error)")
                    }
                    
                    expect(capturedRequest).toNot(beNil())
                    
                    // The body is gzipped, so we need to decompress it first
                    if let compressedBody = capturedRequest?.httpBody {
                        let decompressedData = try? compressedBody.gunzipped()
                        if let decompressedData = decompressedData,
                           let json = try? JSONSerialization.jsonObject(with: decompressedData) as? [String: Any] {
                            expect(json["apiKey"] as? String).to(equal(apiKey))
                            if let batch = json["batch"] as? [[String: Any]] {
                                expect(batch).to(haveCount(2))
                                expect(batch[0]["event"] as? String).to(equal("event1"))
                                expect(batch[1]["event"] as? String).to(equal("event2"))
                            } else {
                                fail("Batch array not found in request body")
                            }
                        } else {
                            fail("Request body could not be decompressed or parsed")
                        }
                    } else {
                        fail("Request body not found")
                    }
                }
            }
            
            describe("fetchExperience") {
                let experienceId = "experience-123"
                let versionId = "version-123"

                func response() -> RemoteExperience {
                    RemoteExperience(
                        experienceId: experienceId,
                        versionId: versionId,
                        buildId: "build-123",
                        artifact: RemoteExperienceArtifact(
                            url: "https://cdn.example/experience.nux",
                            sha256: String(repeating: "a", count: 64),
                            sizeBytes: 123
                        ),
                        name: "Test",
                        reentry: .everyTime,
                        publishedAt: "2026-07-29T00:00:00Z"
                    )
                }
                
                it("fetches an exact experience version pointer") {
                    StubURLProtocol.register(
                        matcher: RequestMatchers.get(
                            "/experiences/\(experienceId)/versions/\(versionId)"
                        ),
                        handler: { request in
                            let data = try ResponseBuilders.toJSON(response())
                            let response = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (response, data)
                        }
                    )
                    
                    let result = try await api.fetchExperience(
                        experienceId: experienceId,
                        versionId: versionId
                    )
                    
                    expect(result.experienceId).to(equal(experienceId))
                    expect(result.versionId).to(equal(versionId))
                    expect(result.artifact.url).toNot(beEmpty())
                }
                
                it("handles an exact version not found") {
                    StubURLProtocol.register(
                        matcher: RequestMatchers.get(
                            "/experiences/\(experienceId)/versions/\(versionId)"
                        ),
                        handler: { request in
                            let response = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 404,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            let data = "{}".data(using: .utf8)!
                            return (response, data)
                        }
                    )
                    
                    await expect {
                        try await api.fetchExperience(
                            experienceId: experienceId,
                            versionId: versionId
                        )
                    }.to(throwError())
                }
                
                it("includes API key in an exact version request") {
                    var capturedRequest: URLRequest?
                    
                    StubURLProtocol.register(
                        matcher: RequestMatchers.get(
                            "/experiences/\(experienceId)/versions/\(versionId)"
                        ),
                        handler: { request in
                            capturedRequest = request
                            let data = try ResponseBuilders.toJSON(response())
                            let response = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (response, data)
                        }
                    )
                    
                    do {
                        _ = try await api.fetchExperience(
                            experienceId: experienceId,
                            versionId: versionId
                        )
                    } catch {
                        fail("fetchExperience threw error: \(error)")
                    }
                    
                    expect(capturedRequest).toNot(beNil())
                    
                    // Check for API key in URL parameters or headers
                    if let url = capturedRequest?.url,
                       let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                       let queryItems = components.queryItems {
                        let apiKeyItem = queryItems.first { $0.name == "apiKey" }
                        expect(apiKeyItem?.value).to(equal(apiKey))
                    }
                }
            }
        }
    }
}
