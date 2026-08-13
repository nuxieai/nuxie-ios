import Foundation
@testable import Nuxie

/// Helper methods for creating common API responses in tests
struct ResponseBuilders {
    
    // MARK: - Profile Response
    
    static func buildProfileResponse(
        experiences: [Experience] = [],
        segments: [Segment] = [],
        userProperties: [String: AnyCodable]? = nil,
        experiments: [String: ExperimentAssignment]? = nil,
        features: [Feature]? = nil
    ) -> ProfileResponse {
        _ = experiences
        return ProfileResponse(
            segments: segments,
            userProperties: userProperties,
            experiments: experiments,
            features: features
        )
    }
    
    static func buildExperience(
        id: String = "experience-1",
        name: String = "Test Experience",
        flowId: String = "flow-1",
        triggerType: String = "event",
        eventName: String = "app_open"
    ) -> Experience {
        return Experience(
            id: id,
            versionId: flowId,
            name: name,
            reentry: .oneTime,
            publishedAt: Date().ISO8601Format(),
            trigger: .event(EventTriggerConfig(
                eventName: eventName,
                condition: nil
            )),
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            experienceType: nil
        )
    }
    
    // MARK: - Batch Response
    
    static func buildBatchResponse(
        processed: Int,
        failed: Int = 0,
        errors: [BatchError]? = nil
    ) -> BatchResponse {
        return BatchResponse(
            status: failed > 0 ? "partial" : "success",
            processed: processed,
            failed: failed,
            total: processed + failed,
            errors: errors
        )
    }
    
    static func buildBatchError(
        index: Int,
        event: String,
        error: String
    ) -> BatchError {
        return BatchError(
            index: index,
            event: event,
            error: error
        )
    }
    
    // MARK: - Event Response

    static func buildEventResponse(
        status: String = "success"
    ) -> EventResponse {
        return EventResponse(
            status: status,
            payload: nil,
            customer: nil,
            eventId: nil,
            message: nil,
            featuresMatched: nil,
            usage: nil,
            journey: nil,
        )
    }

    static func buildFeatureUsedResponse(
        status: String = "ok",
        message: String? = "Feature usage tracked successfully",
        current: Double = 5,
        limit: Double? = 100,
        remaining: Double? = 95
    ) -> EventResponse {
        return EventResponse(
            status: status,
            payload: nil,
            customer: nil,
            eventId: nil,
            message: message,
            featuresMatched: nil,
            usage: EventResponse.Usage(
                current: current,
                limit: limit,
                remaining: remaining
            ),
            journey: nil,
        )
    }
    
    // MARK: - Experience Response

    static func buildJourneyDocument(
        id: String = "flow-1",
        url: String = "https://example.com/builds/flow-1"
    ) -> JourneyDocument {
        return JourneyDocument(
            screens: [
                JourneyScreen(
                    id: "screen-1",
                    defaultViewModelName: nil,
                    defaultInstanceId: nil
                )
            ],
            viewModelValues: nil
        )
    }
    
    // MARK: - Error Response
    
    static func buildErrorResponse(
        message: String = "Test error",
        code: String? = nil,
        details: [String: AnyCodable]? = nil
    ) -> APIErrorResponse {
        return APIErrorResponse(
            message: message,
            code: code,
            details: details
        )
    }
    
    // MARK: - JSON Data Helpers
    
    /// Convert any Encodable to JSON data
    static func toJSON<T: Encodable>(_ object: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(object)
    }
    
    /// Create a simple JSON error response
    static func errorJSON(message: String, statusCode: Int = 400) -> Data {
        let json = """
        {
            "message": "\(message)",
            "statusCode": \(statusCode)
        }
        """
        return json.data(using: .utf8)!
    }
}
