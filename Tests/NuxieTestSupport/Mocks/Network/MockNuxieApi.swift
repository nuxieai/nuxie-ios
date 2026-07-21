import Foundation
@testable import Nuxie

/// Mock implementation of NuxieApi for testing
public actor MockNuxieApi: NuxieApiProtocol {
    // Response configuration
    public var shouldFailProfile = false
    public var shouldFailBatch = false
    public var shouldFailFlow = false
    public var shouldFailTrackEvent = false
    public var trackEventError: Error?

    public var profileDelay: TimeInterval = 0
    public var profileResponse: ProfileResponse?
    public var batchResponse: BatchResponse = BatchResponse(
        status: "success",
        processed: 0,
        failed: 0,
        total: 0,
        errors: nil
    )
    public var checkFeatureResponse: FeatureCheckResult?
    public var trackEventResponse: EventResponse?
    public var responseWriteResponse = ResponseWriteResponse(
        status: "ok",
        response: nil,
        version: nil
    )
    public var responseSubmitResponse = ResponseSubmitResponse(
        status: "ok",
        response: nil
    )
    public var responseAbandonResponse = ResponseAbandonResponse(
        status: "ok",
        responses: []
    )

    // Call tracking
    public var fetchProfileCallCount = 0
    public var fetchProfileWithTimeoutCallCount = 0
    public var sendBatchCallCount = 0
    public var fetchFlowCallCount = 0
    public var trackEventCallCount = 0

    public var lastTimeoutUsed: TimeInterval?

    // Track sent events for test assertions
    public private(set) var sentEvents: [NuxieEvent] = []

    // Track last trackEvent call details
    public private(set) var lastTrackEventCall: (
        event: String,
        distinctId: String,
        properties: [String: Any]?,
        value: Double?,
        entityId: String?
    )?
    public private(set) var lastResponseFieldCall: (
        distinctId: String,
        journeySessionId: String,
        responseSchemaId: String,
        schemaVersion: Int?,
        key: String,
        value: Any
    )?
    public private(set) var lastResponseSubmitCall: (
        distinctId: String,
        journeySessionId: String,
        responseSchemaId: String,
        schemaVersion: Int?
    )?
    public private(set) var lastResponseAbandonCall: (
        distinctId: String,
        journeySessionId: String
    )?
    
    public init() {
        setupDefaultProfileResponse()
    }
    
    private func setupDefaultProfileResponse() {
        // Create default profile response
        let campaign = Campaign(
            id: "campaign-1",
            name: "Test Campaign",
            flowId: "flow-1",
            flowNumber: 1,
            flowName: nil,
            reentry: .everyTime,
            publishedAt: "2024-01-01T00:00:00Z",
            trigger: .event(EventTriggerConfig(
                eventName: "test_event",
                condition: IREnvelope(
                    ir_version: 1,
                    engine_min: nil,
                    compiled_at: nil,
                    expr: .bool(true)
                )
            )),
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            campaignType: nil
        )
        
        let segment = Segment(
            id: "segment-1",
            name: "Test Segment",
            condition: IREnvelope(
                ir_version: 1,
                engine_min: nil,
                compiled_at: nil,
                expr: .bool(true)  // Simple test expression
            )
        )
        
        self.profileResponse = ProfileResponse(
            campaigns: [campaign],
            segments: [segment],
            flows: [ResponseBuilders.buildRemoteFlow()],
            userProperties: nil,
            experiments: nil,
            features: nil,
            journeys: nil
        )
    }
    
    // Configuration methods
    public func setProfileResponse(_ response: ProfileResponse) {
        self.profileResponse = response
    }
    
    public func setProfileDelay(_ delay: TimeInterval) {
        self.profileDelay = delay
    }
    
    public func setShouldFailBatch(_ shouldFail: Bool) {
        shouldFailBatch = shouldFail
    }

    public func setShouldFailProfile(_ shouldFail: Bool) {
        self.shouldFailProfile = shouldFail
    }

    public func setCheckFeatureResponse(_ response: FeatureCheckResult?) {
        self.checkFeatureResponse = response
    }
    
    // MARK: - NuxieApiProtocol Implementation
    
    public func sendBatch(events: [BatchEventItem]) async throws -> BatchResponse {
        sendBatchCallCount += 1
        
        // Track the events as NuxieEvents for test assertions
        for item in events {
            // Convert AnyCodable properties back to [String: Any]
            var props: [String: Any] = [:]
            if let properties = item.properties {
                for (key, value) in properties {
                    props[key] = value.value
                }
            }
            
            let nuxieEvent = NuxieEvent(
                name: item.event,
                distinctId: item.distinctId,
                properties: props,
                timestamp: Date()
            )
            sentEvents.append(nuxieEvent)
        }
        
        if shouldFailBatch {
            throw NuxieNetworkError.httpError(statusCode: 500, message: "Mock batch error")
        }
        
        return BatchResponse(
            status: batchResponse.status,
            processed: events.count,
            failed: 0,
            total: events.count,
            errors: nil
        )
    }
    
    public func fetchProfile(for distinctId: String, locale: String?) async throws -> ProfileResponse {
        fetchProfileCallCount += 1

        if profileDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(profileDelay * 1_000_000_000))
        }

        if shouldFailProfile {
            throw NuxieNetworkError.httpError(statusCode: 500, message: "Mock server error")
        }

        return profileResponse!
    }

    public func fetchProfileWithTimeout(for distinctId: String, locale: String?, timeout: TimeInterval) async throws -> ProfileResponse {
        fetchProfileWithTimeoutCallCount += 1
        lastTimeoutUsed = timeout

        // Simulate timeout if delay is longer than requested timeout
        if profileDelay > timeout {
            throw NuxieNetworkError.timeout
        }

        return try await fetchProfile(for: distinctId, locale: locale)
    }
    
    public func fetchExperience(flowId: String) async throws -> RemoteFlow {
        fetchFlowCallCount += 1
        
        if shouldFailFlow {
            throw NuxieNetworkError.httpError(statusCode: 404, message: "Experience not found")
        }
        
        return RemoteFlow(
            id: flowId,
            flowArtifact: FlowArtifact(
                url: "https://example.com/flow",
                manifest: BuildManifest(
                    totalFiles: 5,
                    totalSize: 1024,
                    contentHash: "hash123",
                    files: []
                )
            ),
            screens: [
                RemoteFlowScreen(
                    id: "screen-1",
                    defaultViewModelName: nil,
                    defaultInstanceId: nil
                )
            ],
            viewModelValues: nil
        )
    }
    
    public func trackEvent(
        event: String,
        distinctId: String,
        properties: [String: Any]?,
        value: Double?,
        entityId: String?
    ) async throws -> EventResponse {
        trackEventCallCount += 1
        lastTrackEventCall = (event, distinctId, properties, value, entityId)
        sentEvents.append(NuxieEvent(
            name: event,
            distinctId: distinctId,
            properties: properties ?? [:],
            timestamp: Date()
        ))

        if shouldFailTrackEvent {
            if let error = trackEventError {
                throw error
            }
            throw NuxieNetworkError.httpError(statusCode: 500, message: "Mock tracking error")
        }

        return trackEventResponse ?? EventResponse(
            status: "success",
            payload: nil,
            customer: nil,
            eventId: nil,
            message: nil,
            featuresMatched: nil,
            usage: nil,
            journey: nil,
            execution: nil
        )
    }

    public func checkFeature(
        customerId: String,
        featureId: String,
        requiredBalance: Int?,
        entityId: String?
    ) async throws -> FeatureCheckResult {
        if let checkFeatureResponse {
            return checkFeatureResponse
        }

        return FeatureCheckResult(
            customerId: customerId,
            featureId: featureId,
            requiredBalance: requiredBalance ?? 1,
            code: "allowed",
            allowed: true,
            unlimited: false,
            balance: 100,
            type: .boolean,
            preview: nil
        )
    }

    public func syncTransaction(
        transactionJwt: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
        return PurchaseResponse(
            success: true,
            customerId: distinctId,
            features: nil,
            error: nil
        )
    }

    public func setResponseField(
        distinctId: String,
        journeySessionId: String,
        responseSchemaId: String,
        schemaVersion: Int?,
        key: String,
        value: Any
    ) async throws -> ResponseWriteResponse {
        lastResponseFieldCall = (
            distinctId: distinctId,
            journeySessionId: journeySessionId,
            responseSchemaId: responseSchemaId,
            schemaVersion: schemaVersion,
            key: key,
            value: value
        )
        return responseWriteResponse
    }

    public func submitResponse(
        distinctId: String,
        journeySessionId: String,
        responseSchemaId: String,
        schemaVersion: Int?
    ) async throws -> ResponseSubmitResponse {
        lastResponseSubmitCall = (
            distinctId: distinctId,
            journeySessionId: journeySessionId,
            responseSchemaId: responseSchemaId,
            schemaVersion: schemaVersion
        )
        return responseSubmitResponse
    }

    public func abandonResponses(
        distinctId: String,
        journeySessionId: String
    ) async throws -> ResponseAbandonResponse {
        lastResponseAbandonCall = (
            distinctId: distinctId,
            journeySessionId: journeySessionId
        )
        return responseAbandonResponse
    }

    // Test helpers
    public func reset() {
        shouldFailProfile = false
        shouldFailBatch = false
        shouldFailFlow = false
        shouldFailTrackEvent = false
        trackEventError = nil
        trackEventResponse = nil
        profileDelay = 0
        fetchProfileCallCount = 0
        fetchProfileWithTimeoutCallCount = 0
        sendBatchCallCount = 0
        fetchFlowCallCount = 0
        trackEventCallCount = 0
        lastTimeoutUsed = nil
        sentEvents.removeAll()
        lastTrackEventCall = nil
        lastResponseFieldCall = nil
        lastResponseSubmitCall = nil
        lastResponseAbandonCall = nil
        checkFeatureResponse = nil
        responseWriteResponse = ResponseWriteResponse(status: "ok", response: nil, version: nil)
        responseSubmitResponse = ResponseSubmitResponse(status: "ok", response: nil)
        responseAbandonResponse = ResponseAbandonResponse(status: "ok", responses: [])

        // Reset profileResponse to default
        setupDefaultProfileResponse()
    }

    // Configuration helpers for tests
    public func configureTrackEventResponse(
        status: String = "ok",
        message: String? = nil,
        usage: EventResponse.Usage? = nil
    ) {
        trackEventResponse = EventResponse(
            status: status,
            payload: nil,
            customer: nil,
            eventId: nil,
            message: message,
            featuresMatched: nil,
            usage: usage,
            journey: nil,
            execution: nil
        )
    }

    public func configureTrackEventFailure(error: Error? = nil) {
        shouldFailTrackEvent = true
        trackEventError = error
    }

    // Direct setter for trackEventResponse (for tests that need to set custom EventResponse)
    public func setTrackEventResponse(_ response: EventResponse?) {
        trackEventResponse = response
    }
}
