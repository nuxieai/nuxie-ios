import Foundation
@testable import Nuxie

// MARK: - EventResponse Test Helpers

extension EventResponse {
    /// Create a successful response with no additional data
    static func success() -> EventResponse {
        EventResponse(
            status: "ok",
            payload: nil,
            customer: nil,
            eventId: nil,
            message: nil,
            featuresMatched: nil,
            usage: nil,
            journey: nil
        )
    }

    /// Create a response with journey info
    static func withJourney(sessionId: String, currentNodeId: String? = nil, status: String = "active") -> EventResponse {
        EventResponse(
            status: "ok",
            payload: nil,
            customer: nil,
            eventId: nil,
            message: nil,
            featuresMatched: nil,
            usage: nil,
            journey: JourneyInfo(
                sessionId: sessionId,
                currentNodeId: currentNodeId,
                status: status
            )
        )
    }
}
