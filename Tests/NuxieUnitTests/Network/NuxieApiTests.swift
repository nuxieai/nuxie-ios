import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private final class ChunkedProfileController: @unchecked Sendable {
    private let lock = NSLock()
    private var _sentBytes = 0
    private var _stopped = false
    let stopped = DispatchSemaphore(value: 0)

    var sentBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return _sentBytes
    }

    func recordSent(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !_stopped else { return false }
        _sentBytes += count
        return true
    }

    func recordStop() {
        lock.lock()
        let first = !_stopped
        _stopped = true
        lock.unlock()
        if first { stopped.signal() }
    }
}

private final class ChunkedProfileURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var controller: ChunkedProfileController?
    private let stateLock = NSLock()
    private var isStopped = false

    static func configure(_ controller: ChunkedProfileController) {
        lock.lock()
        self.controller = controller
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/profile"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let controller = Self.controller
        Self.lock.unlock()
        guard let controller, let url = request.url else { return }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async { [self] in
            let chunk = Data(repeating: 0x20, count: 64 * 1_024)
            for _ in 0..<400 {
                stateLock.lock()
                let stopped = isStopped
                stateLock.unlock()
                guard !stopped, controller.recordSent(chunk.count) else { return }
                client?.urlProtocol(self, didLoad: chunk)
                Thread.sleep(forTimeInterval: 0.001)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        isStopped = true
        stateLock.unlock()
        Self.lock.lock()
        let controller = Self.controller
        Self.lock.unlock()
        controller?.recordStop()
    }
}

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
                    expect(result.releases).to(beNil())
                }

                it("rejects a profile body over 24 MiB before decoding") {
                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/profile"),
                        handler: { request in
                            let data = Data(repeating: 0x20, count: 24 * 1_024 * 1_024 + 1)
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
                        _ = try await api.fetchProfile(for: distinctId)
                        fail("Expected oversized profile rejection")
                    } catch NuxieNetworkError.invalidResponse {
                        // The raw body is bounded before JSONDecoder.
                    } catch {
                        fail("Expected invalidResponse, got \(error)")
                    }
                }

                it("rejects duplicate keys in the exact profile response") {
                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/profile"),
                        handler: { request in
                            let data = Data(
                                """
                                {"experiences":[],"experiences":[],"pinnedVersions":[],"assetBaseUrl":"https://assets.nuxie.test/","segments":[]}
                                """.utf8
                            )
                            return (
                                HTTPURLResponse(
                                    url: request.url!, statusCode: 200,
                                    httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"]
                                )!,
                                data
                            )
                        }
                    )

                    await expect {
                        try await api.fetchProfile(for: distinctId)
                    }.to(throwError())
                }

                it("cancels a chunked profile response at the 24 MiB body limit") {
                    let controller = ChunkedProfileController()
                    ChunkedProfileURLProtocol.configure(controller)
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.protocolClasses = [ChunkedProfileURLProtocol.self]
                    let boundedAPI = NuxieApi(
                        apiKey: apiKey,
                        baseURL: baseURL,
                        useGzipCompression: false,
                        urlSession: URLSession(configuration: configuration)
                    )

                    do {
                        _ = try await boundedAPI.fetchProfile(for: distinctId)
                        fail("Expected oversized profile rejection")
                    } catch NuxieNetworkError.invalidResponse {
                        // The task is cancelled as soon as byte max + 1 arrives.
                    } catch {
                        fail("Expected invalidResponse, got \(error)")
                    }
                    expect(controller.stopped.wait(timeout: .now() + 2)).to(equal(.success))
                    expect(controller.sentBytes).to(beLessThanOrEqualTo(26 * 1_024 * 1_024))
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

                it("maps a transport timeout through the shared executor") {
                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/profile"),
                        handler: { _ in throw URLError(.timedOut) }
                    )

                    do {
                        _ = try await api.fetchProfileWithTimeout(
                            for: distinctId,
                            timeout: customTimeout
                        )
                        fail("Expected timeout")
                    } catch NuxieNetworkError.timeout {
                        // Expected shared error mapping.
                    } catch {
                        fail("Expected NuxieNetworkError.timeout but got \(error)")
                    }
                }

                it("enforces the custom timeout as an overall deadline") {
                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/profile"),
                        handler: { request in
                            Thread.sleep(forTimeInterval: 0.25)
                            let response = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            let profile = ResponseBuilders.buildProfileResponse(
                                experiences: [],
                                segments: []
                            )
                            return (response, try ResponseBuilders.toJSON(profile))
                        }
                    )
                    let startedAt = Date()

                    do {
                        _ = try await api.fetchProfileWithTimeout(
                            for: distinctId,
                            timeout: 0.05
                        )
                        fail("Expected overall timeout")
                    } catch NuxieNetworkError.timeout {
                        expect(Date().timeIntervalSince(startedAt)).to(beLessThan(0.2))
                    } catch {
                        fail("Expected NuxieNetworkError.timeout but got \(error)")
                    }
                }

                it("does not await a cancellation-uncooperative operation past the deadline") {
                    let startedAt = Date()

                    do {
                        _ = try await raceRequestAgainstDeadline(
                            nanoseconds: 20_000_000
                        ) {
                            await withCheckedContinuation { continuation in
                                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                                    continuation.resume(returning: 1)
                                }
                            }
                        }
                        fail("Expected timeout")
                    } catch NuxieNetworkError.timeout {
                        expect(Date().timeIntervalSince(startedAt)).to(beLessThan(0.15))
                    } catch {
                        fail("Expected NuxieNetworkError.timeout but got \(error)")
                    }
                }

                it("can exceed the injected session resource timeout when requested") {
                    let shortConfiguration = URLSessionConfiguration.ephemeral
                    shortConfiguration.protocolClasses = [StubURLProtocol.self]
                    shortConfiguration.timeoutIntervalForResource = 0.01
                    shortConfiguration.timeoutIntervalForRequest = 0.01
                    let shortSession = URLSession(configuration: shortConfiguration)
                    let longTimeoutApi = NuxieApi(
                        apiKey: apiKey,
                        baseURL: baseURL,
                        urlSession: shortSession
                    )
                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/profile"),
                        handler: { request in
                            Thread.sleep(forTimeInterval: 0.05)
                            let response = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            let profile = ResponseBuilders.buildProfileResponse(
                                experiences: [],
                                segments: []
                            )
                            return (response, try ResponseBuilders.toJSON(profile))
                        }
                    )

                    await expect {
                        try await longTimeoutApi.fetchProfileWithTimeout(
                            for: distinctId,
                            timeout: 1.0
                        )
                    }.toNot(throwError())
                    shortSession.invalidateAndCancel()
                }

                it("rejects zero and non-finite custom timeouts deterministically") {
                    let roundedOverflowBoundary = Double(UInt64.max) / 1_000_000_000
                    for timeout in [
                        0, -1, .infinity, .nan, Double(UInt64.max), roundedOverflowBoundary,
                    ] {
                        do {
                            _ = try await api.fetchProfileWithTimeout(
                                for: distinctId,
                                timeout: timeout
                            )
                            fail("Expected timeout for \(timeout)")
                        } catch NuxieNetworkError.timeout {
                            // Expected validation before transport starts.
                        } catch {
                            fail("Expected NuxieNetworkError.timeout but got \(error)")
                        }
                    }
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

                it("maps batch HTTP failures through the shared executor") {
                    StubURLProtocol.register(
                        matcher: RequestMatchers.post("/batch"),
                        handler: { request in
                            let response = HTTPURLResponse(
                                url: request.url!,
                                statusCode: 422,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!
                            return (response, Data(#"{"message":"invalid batch"}"#.utf8))
                        }
                    )

                    do {
                        _ = try await api.sendBatch(events: events)
                        fail("Expected HTTP error")
                    } catch NuxieNetworkError.httpError(let statusCode, let message) {
                        expect(statusCode).to(equal(422))
                        expect(message).to(equal("invalid batch"))
                    } catch {
                        fail("Expected NuxieNetworkError.httpError but got \(error)")
                    }
                }

                it("maps malformed and empty batch responses through shared decoding") {
                    for payload in [Data("not-json".utf8), Data()] {
                        StubURLProtocol.register(
                            matcher: RequestMatchers.post("/batch"),
                            handler: { request in
                                let response = HTTPURLResponse(
                                    url: request.url!,
                                    statusCode: 200,
                                    httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"]
                                )!
                                return (response, payload)
                            }
                        )

                        do {
                            _ = try await api.sendBatch(events: events)
                            fail("Expected decoding error")
                        } catch NuxieNetworkError.decodingError {
                            // Expected.
                        } catch {
                            fail("Expected NuxieNetworkError.decodingError but got \(error)")
                        }
                        StubURLProtocol.reset()
                    }
                }
            }
            
        }
    }
}
