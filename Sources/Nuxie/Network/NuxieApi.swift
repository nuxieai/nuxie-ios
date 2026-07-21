import Foundation

/// Main API client for Nuxie SDK - fully async/await
// @preconcurrency: the protocol carries [String: Any] payloads (public
// analytics-style API). Older Swift 6 compilers (current CI runners,
// Xcode 26.2) require the opt-out for the actor-isolated witnesses; newer
// compilers accept the crossing and flag this as having no effect — that
// warning is a known, benign toolchain-skew artifact until the runner
// fleet is on Xcode 26.6+.
public actor NuxieApi: @preconcurrency NuxieApiProtocol {
    
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
    
    // MARK: - Core Request Method (Async)
    
    private func request<T: Codable>(
        endpoint: APIEndpoint,
        body: Encodable? = nil,
        responseType: T.Type
    ) async throws -> T {
        let url = baseURL.appendingPathComponent(endpoint.path)
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        
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
            
            // Apply gzip compression if enabled
            if useGzipCompression {
                request.httpBody = try payloadData.gzipped()
                request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            } else {
                request.httpBody = payloadData
            }
        } else if endpoint.authMethod == .apiKeyInBody {
            // Body-less POST that still needs apiKey in body
            let body = try JSONSerialization.data(withJSONObject: ["apiKey": apiKey], options: [])
            if useGzipCompression {
                request.httpBody = try body.gzipped()
                request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            } else {
                request.httpBody = body
            }
        }
        
        // Perform request
        let (data, response) = try await session.data(for: request)
        
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
    
    // MARK: - Custom Timeout Request Method
    
    private func requestWithTimeout<T: Codable>(
        endpoint: APIEndpoint,
        body: Encodable? = nil,
        responseType: T.Type,
        timeout: TimeInterval
    ) async throws -> T {
        // Create custom session with timeout, preserving protocol classes for testing
        let config: URLSessionConfiguration
        if let protocolClasses = session.configuration.protocolClasses {
            // For testing - preserve the StubURLProtocol
            config = URLSessionConfiguration.ephemeral
            config.protocolClasses = protocolClasses
        } else {
            config = URLSessionConfiguration.default
        }
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpAdditionalHeaders = session.configuration.httpAdditionalHeaders
        let customSession = URLSession(configuration: config)
        
        let url = baseURL.appendingPathComponent(endpoint.path)
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.timeoutInterval = timeout  // Set timeout on the request itself
        
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
            
            if useGzipCompression {
                request.httpBody = try payloadData.gzipped()
                request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            } else {
                request.httpBody = payloadData
            }
        } else if endpoint.authMethod == .apiKeyInBody {
            let body = try JSONSerialization.data(withJSONObject: ["apiKey": apiKey], options: [])
            if useGzipCompression {
                request.httpBody = try body.gzipped()
                request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            } else {
                request.httpBody = body
            }
        }
        
        // Perform request with custom timeout
        let (data, response) = try await customSession.data(for: request)
        
        // Check HTTP response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NuxieNetworkError.invalidResponse
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
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
        return try await self.requestWithTimeout(
            endpoint: .profile(request),
            body: request,
            responseType: ProfileResponse.self,
            timeout: timeout
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
        LogDebug("[sendBatch] Starting batch request for \(events.count) events")
        
        let request = BatchRequest(events: events, historicalMigration: historicalMigration)
        LogDebug("[sendBatch] Created BatchRequest with historicalMigration: \(historicalMigration)")
        
        // Create request with gzip compression for batch endpoint
        let batchURL = baseURL.appendingPathComponent("/batch")
        LogDebug("[sendBatch] Batch URL: \(batchURL.absoluteString)")
        
        var urlRequest = URLRequest(url: batchURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        urlRequest.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        LogDebug("[sendBatch] Created URLRequest with headers")
        
        // Add API key to request body
        LogDebug("[sendBatch] Converting request to dictionary...")
        var bodyDict = try request.asDictionary() ?? [:]
        bodyDict["apiKey"] = apiKey
        LogDebug("[sendBatch] Added API key to body dictionary")
        
        // Log the batch request
        LogDebug("[sendBatch] Sending batch of \(events.count) events (gzipped)")
        
        // Encode and compress the body
        LogDebug("[sendBatch] Serializing JSON data...")
        let jsonData = try JSONSerialization.data(withJSONObject: bodyDict)
        LogDebug("[sendBatch] JSON data size: \(jsonData.count) bytes")
        
        LogDebug("[sendBatch] Compressing with gzip...")
        urlRequest.httpBody = try jsonData.gzipped()
        LogDebug("[sendBatch] Compressed data size: \(urlRequest.httpBody?.count ?? 0) bytes")
        
        // Send the request
        LogDebug("[sendBatch] Starting network request...")
        let (data, response) = try await session.data(for: urlRequest)
        
        LogDebug("[sendBatch] Network response received")
        
        // Handle HTTP errors
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NuxieNetworkError.invalidResponse
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            // Log the raw response for debugging
            if let responseString = String(data: data, encoding: .utf8) {
                LogError("Batch HTTP \(httpResponse.statusCode) response: \(responseString)")
            }
            
            let errorResponse = try? decoder.decode(APIErrorResponse.self, from: data)
            throw NuxieNetworkError.httpError(
                statusCode: httpResponse.statusCode,
                message: errorResponse?.message ?? "Unknown error"
            )
        }
        
        // Decode response
        let result = try decoder.decode(BatchResponse.self, from: data)
        LogInfo("Batch sent successfully: \(result.processed) processed, \(result.failed) failed")
        return result
    }
    
    // MARK: - Experience
    
    /// Fetch flow by ID
    public func fetchExperience(flowId: String) async throws -> RemoteFlow {
        return try await self.request(
            endpoint: .flow(flowId),
            body: nil,
            responseType: RemoteFlow.self
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
        journeySessionId: String,
        responseSchemaId: String,
        schemaVersion: Int?,
        key: String,
        value: sending Any
    ) async throws -> ResponseWriteResponse {
        let request = ResponseFieldRequest(
            distinctId: distinctId,
            journeySessionId: journeySessionId,
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
        journeySessionId: String,
        responseSchemaId: String,
        schemaVersion: Int?
    ) async throws -> ResponseSubmitResponse {
        let request = ResponseSubmitRequest(
            distinctId: distinctId,
            journeySessionId: journeySessionId,
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
        journeySessionId: String
    ) async throws -> ResponseAbandonResponse {
        let request = ResponseAbandonRequest(
            distinctId: distinctId,
            journeySessionId: journeySessionId
        )

        return try await self.request(
            endpoint: .responseAbandon(request),
            body: request,
            responseType: ResponseAbandonResponse.self
        )
    }
}

