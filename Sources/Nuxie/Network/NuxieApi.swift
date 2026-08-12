import Foundation

/// Main API client for Nuxie SDK - fully async/await
public actor NuxieApi: NuxieApiProtocol {

    // MARK: - Configuration
    
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let useGzipCompression: Bool
    
    // MARK: - Initialization
    
    init(apiKey: String, baseURL: URL = URL(string: "https://i.nuxie.ai")!, useGzipCompression: Bool = false, urlSession: URLSession? = nil) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.useGzipCompression = useGzipCompression
        
        // Use provided URLSession or create default one
        if let urlSession = urlSession {
            self.session = urlSession
        } else {
            // Configure URLSession
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            var headers: [String: String] = [
                "Content-Type": "application/json",
                "Accept-Encoding": "gzip",
                "User-Agent": "Nuxie-iOS-SDK/\(SDKVersion.current)"
            ]
            if useGzipCompression {
                headers["Content-Encoding"] = "gzip"
            }
            config.httpAdditionalHeaders = headers
            self.session = URLSession(configuration: config)
        }
        
        // Configure JSON handling
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }
    
    // MARK: - Request execution

    private struct RequestOptions {
        var timeout: TimeInterval?
        var compressBody: Bool

        static func standard(compressBody: Bool) -> Self {
            Self(timeout: nil, compressBody: compressBody)
        }
    }

    private func transport(
        _ request: URLRequest,
        overallTimeout: TimeInterval?
    ) async throws -> (Data, URLResponse) {
        guard let overallTimeout else {
            return try await session.data(for: request)
        }
        guard overallTimeout.isFinite, overallTimeout > 0 else {
            throw NuxieNetworkError.timeout
        }

        let maximumTimeout = TimeInterval(UInt64.max / 1_000_000_000)
        guard overallTimeout <= maximumTimeout else {
            throw NuxieNetworkError.timeout
        }
        let nanoseconds = UInt64(overallTimeout * 1_000_000_000)

        return try await withThrowingTaskGroup(
            of: UncheckedSendable<(Data, URLResponse)>.self
        ) { group in
            group.addTask { [session] in
                UncheckedSendable(try await session.data(for: request))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw NuxieNetworkError.timeout
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw NuxieNetworkError.invalidResponse
            }
            return result.value
        }
    }
    
    private func request<T: Codable>(
        endpoint: APIEndpoint,
        body: Encodable? = nil,
        responseType: T.Type,
        options: RequestOptions? = nil
    ) async throws -> T {
        let options = options ?? .standard(compressBody: useGzipCompression)
        let url = baseURL.appendingPathComponent(endpoint.path)
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.timeoutInterval = options.timeout ?? session.configuration.timeoutIntervalForRequest
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("Nuxie-iOS-SDK/\(SDKVersion.current)", forHTTPHeaderField: "User-Agent")
        
        // Auth handling
        switch endpoint.authMethod {
        case .apiKeyInBody:
            // apiKey added in body later
            break
        case .apiKeyInQuery:
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var items = comps?.queryItems ?? []
            items.append(URLQueryItem(name: "apiKey", value: apiKey))
            comps?.queryItems = items
            if let composed = comps?.url { 
                request.url = composed 
            }
        }
        
        // Handle request body
        if let body = body {
            var payloadData = try encoder.encode(body)
            
            // If API key must be in body, merge it
            if endpoint.authMethod == .apiKeyInBody {
                if var json = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                    json["apiKey"] = apiKey
                    payloadData = try JSONSerialization.data(withJSONObject: json)
                }
            }
            
            if options.compressBody {
                request.httpBody = try payloadData.gzipped()
                request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            } else {
                request.httpBody = payloadData
            }
        } else if endpoint.authMethod == .apiKeyInBody {
            // Body-less POST that still needs apiKey in body
            let body = try JSONSerialization.data(withJSONObject: ["apiKey": apiKey], options: [])
            if options.compressBody {
                request.httpBody = try body.gzipped()
                request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            } else {
                request.httpBody = body
            }
        }
        
        // Perform request
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(
                request,
                overallTimeout: options.timeout
            )
        } catch let error as URLError where error.code == .timedOut {
            throw NuxieNetworkError.timeout
        } catch {
            throw error
        }
        
        // Check HTTP response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NuxieNetworkError.invalidResponse
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            // Log the raw response for debugging
            if let responseString = String(data: data, encoding: .utf8) {
                LogError("HTTP \(httpResponse.statusCode) response body: \(responseString)")
            }
            
            let errorResponse = try? decoder.decode(APIErrorResponse.self, from: data)
            throw NuxieNetworkError.httpError(
                statusCode: httpResponse.statusCode,
                message: errorResponse?.message ?? "Unknown error"
            )
        }
        
        // Decode response
        do {
            return try decoder.decode(responseType, from: data)
        } catch {
            throw NuxieNetworkError.decodingError(error)
        }
    }

}

// MARK: - Public API Methods (All Async)

extension NuxieApi {
    
    // MARK: - Profile

    /// Fetch user profile with locale for server-side content resolution
    public func fetchProfile(for distinctId: String, locale: String? = nil) async throws -> ProfileResponse {
        let request = ProfileRequest(distinctId: distinctId, locale: locale)
        return try await self.request(
            endpoint: .profile(request),
            body: request,
            responseType: ProfileResponse.self
        )
    }

    /// Fetch user profile with custom timeout (for fast cache checks)
    public func fetchProfileWithTimeout(for distinctId: String, locale: String? = nil, timeout: TimeInterval) async throws -> ProfileResponse {
        let request = ProfileRequest(distinctId: distinctId, locale: locale)
        return try await self.request(
            endpoint: .profile(request),
            body: request,
            responseType: ProfileResponse.self,
            options: RequestOptions(timeout: timeout, compressBody: useGzipCompression)
        )
    }
    
    // MARK: - Batch Events
    
    /// Send batch of events (protocol conformance)
    public func sendBatch(events: [BatchEventItem]) async throws -> BatchResponse {
        return try await sendBatch(events: events, historicalMigration: false)
    }
    
    /// Send batch of events with historical migration option
    public func sendBatch(
        events: [BatchEventItem],
        historicalMigration: Bool
    ) async throws -> BatchResponse {
        let request = BatchRequest(events: events, historicalMigration: historicalMigration)
        LogDebug("[sendBatch] Sending batch of \(events.count) events (gzipped)")
        let result: BatchResponse = try await self.request(
            endpoint: .batch(request),
            body: request,
            responseType: BatchResponse.self,
            options: RequestOptions(timeout: nil, compressBody: true)
        )
        LogInfo("Batch sent successfully: \(result.processed) processed, \(result.failed) failed")
        return result
    }
    
    // MARK: - Experience
    
    /// Fetch one published experience version pointer.
    public func fetchExperience(
        experienceId: String,
        versionId: String
    ) async throws -> RemoteExperience {
        return try await self.request(
            endpoint: .experienceVersion(
                experienceId: experienceId,
                versionId: versionId
            ),
            body: nil,
            responseType: RemoteExperience.self
        )
    }
    
    // MARK: - Event Tracking

    /// Track a single event
    public func trackEvent(
        event: String,
        distinctId: String,
        properties: sending [String: Any]? = nil,
        value: Double? = nil,
        entityId: String? = nil
    ) async throws -> EventResponse {
        let request = EventRequest(
            event: event,
            distinctId: distinctId,
            timestamp: Date(),
            properties: properties,
            idempotencyKey: UUID.v7().uuidString,
            value: value,
            entityId: entityId
        )

        return try await self.request(
            endpoint: .event(request),
            body: request,
            responseType: EventResponse.self
        )
    }

    public func trackEvent(_ event: NuxieEvent) async throws -> EventResponse {
        let request = EventRequest(
            event: event.name,
            distinctId: event.distinctId,
            timestamp: event.timestamp,
            properties: event.properties,
            idempotencyKey: event.id,
            value: (event.properties["value"] as? NSNumber)?.doubleValue,
            entityId: event.properties["entityId"] as? String
        )

        return try await self.request(
            endpoint: .event(request),
            body: request,
            responseType: EventResponse.self
        )
    }

    // MARK: - Feature Check

    /// Check if a customer has access to a feature (real-time server check)
    public func checkFeature(
        customerId: String,
        featureId: String,
        requiredBalance: Int? = nil,
        entityId: String? = nil
    ) async throws -> FeatureCheckResult {
        let request = FeatureCheckRequest(
            customerId: customerId,
            featureId: featureId,
            requiredBalance: requiredBalance,
            entityId: entityId
        )

        return try await self.request(
            endpoint: .checkFeature(request),
            body: request,
            responseType: FeatureCheckResult.self
        )
    }

    // MARK: - Transaction Sync

    /// Sync an App Store transaction with the backend
    /// Called after StoreKit 2 purchase completes to provision entitlements
    public func syncTransaction(
        transactionJwt: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
        let request = PurchaseRequest(
            transactionJwt: transactionJwt,
            distinctId: distinctId
        )

        return try await self.request(
            endpoint: .purchase(request),
            body: request,
            responseType: PurchaseResponse.self
        )
    }

    public func setResponseField(
        distinctId: String,
        journeyId: String,
        responseSchemaId: String,
        schemaVersion: Int?,
        key: String,
        value: sending Any
    ) async throws -> ResponseWriteResponse {
        let request = ResponseFieldRequest(
            distinctId: distinctId,
            journeyId: journeyId,
            responseSchemaId: responseSchemaId,
            schemaVersion: schemaVersion,
            key: key,
            value: AnyCodable(value)
        )

        return try await self.request(
            endpoint: .responseField(request),
            body: request,
            responseType: ResponseWriteResponse.self
        )
    }

    public func submitResponse(
        distinctId: String,
        journeyId: String,
        responseSchemaId: String,
        schemaVersion: Int?
    ) async throws -> ResponseSubmitResponse {
        let request = ResponseSubmitRequest(
            distinctId: distinctId,
            journeyId: journeyId,
            responseSchemaId: responseSchemaId,
            schemaVersion: schemaVersion
        )

        return try await self.request(
            endpoint: .responseSubmit(request),
            body: request,
            responseType: ResponseSubmitResponse.self
        )
    }

    public func abandonResponses(
        distinctId: String,
        journeyId: String
    ) async throws -> ResponseAbandonResponse {
        let request = ResponseAbandonRequest(
            distinctId: distinctId,
            journeyId: journeyId
        )

        return try await self.request(
            endpoint: .responseAbandon(request),
            body: request,
            responseType: ResponseAbandonResponse.self
        )
    }
}
