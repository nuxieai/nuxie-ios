import Foundation
@testable import Nuxie

/// Mock implementation of JourneyService for testing
public actor MockJourneyService: JourneyServiceProtocol {
    
    // MARK: - Tracking Properties
    
    /// Track all started journeys
    public var startedJourneys: [(campaign: Campaign, distinctId: String, originEventId: String?, journey: Journey?)] = []
    
    /// Track all resumed journeys
    public var resumedJourneys: [Journey] = []


    /// Track all handled events
    public var handledEvents: [NuxieEvent] = []

    /// Results to return for trigger handling
    public var triggerResults: [JourneyTriggerResult] = []
    
    /// Track segment changes
    public var segmentChanges: [(distinctId: String, segments: Set<String>)] = []
    
    /// Active journeys by user
    private var activeJourneysByUser: [String: [Journey]] = [:]
    
    /// Track timer check calls
    public var checkExpiredTimersCallCount = 0
    
    /// Track initialization calls
    public var initializeCallCount = 0
    
    /// Track shutdown calls
    public var shutdownCallCount = 0
    
    // MARK: - Configuration Properties
    
    /// Whether to return a journey when starting
    public var shouldReturnJourney = true
    
    /// Custom journey to return when starting
    public var mockJourneyToReturn: Journey?
    
    /// Whether to throw an error when starting a journey
    public var shouldThrowOnStart = false
    
    /// Error to throw when configured
    public var errorToThrow: Error?
    
    // MARK: - JourneyServiceProtocol Implementation
    
    @discardableResult
    public func startJourney(for campaign: Campaign, distinctId: String, originEventId: String?) async -> Journey? {
        // Track the call
        let journey: Journey?
        
        if shouldThrowOnStart {
            // Note: Protocol doesn't throw, so we just return nil on error
            journey = nil
        } else if let mockJourney = mockJourneyToReturn {
            journey = mockJourney
        } else if shouldReturnJourney {
            // Create a journey using the proper initializer
            let newJourney = Journey(
                campaign: campaign,
                distinctId: distinctId,
                now: Date()
            )
            // Set the status to active (simulating a started journey)
            newJourney.status = .active
            journey = newJourney
        } else {
            journey = nil
        }
        
        startedJourneys.append((
            campaign: campaign,
            distinctId: distinctId,
            originEventId: originEventId,
            journey: journey
        ))
        
        // Add to active journeys if created
        if let journey = journey {
            var userJourneys = activeJourneysByUser[distinctId] ?? []
            userJourneys.append(journey)
            activeJourneysByUser[distinctId] = userJourneys
        }
        
        return journey
    }
    
    public func resumeJourney(_ journey: Journey) async {
        resumedJourneys.append(journey)
    }


    public func handleEvent(_ event: NuxieEvent) async {
        handledEvents.append(event)
    }

    public func handleEventForTrigger(_ event: NuxieEvent) async -> [JourneyTriggerResult] {
        handledEvents.append(event)
        return triggerResults
    }

    public func setTriggerResults(_ results: [JourneyTriggerResult]) {
        triggerResults = results
    }
    
    public func handleSegmentChange(distinctId: String, segments: Set<String>) async {
        segmentChanges.append((distinctId: distinctId, segments: segments))
    }
    
    public func getActiveJourneys(for distinctId: String) async -> [Journey] {
        return activeJourneysByUser[distinctId] ?? []
    }
    
    public func checkExpiredTimers() async {
        checkExpiredTimersCallCount += 1
    }
    
    public func initialize() async {
        initializeCallCount += 1
    }
    
    public func shutdown() async {
        shutdownCallCount += 1
        // Clear all state on shutdown
        activeJourneysByUser.removeAll()
    }
    
    public func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
        // Remove old user's journeys
        activeJourneysByUser.removeValue(forKey: oldDistinctId)
        // New user starts with no journeys in mock
    }
    
    public func onAppWillEnterForeground() async {
        // Mock implementation - no-op for tests
    }
    
    public func onAppBecameActive() async {
        // Mock implementation - no-op for tests
    }
    
    public func onAppDidEnterBackground() async {
        // Mock implementation - no-op for tests
    }
    
    // MARK: - Test Helper Methods
    
    /// Reset all mock state
    public func reset() {
        startedJourneys.removeAll()
        resumedJourneys.removeAll()
        handledEvents.removeAll()
        segmentChanges.removeAll()
        activeJourneysByUser.removeAll()
        checkExpiredTimersCallCount = 0
        initializeCallCount = 0
        shutdownCallCount = 0
        shouldReturnJourney = true
        mockJourneyToReturn = nil
        shouldThrowOnStart = false
        errorToThrow = nil
        triggerResults = []
    }
    
    /// Add an active journey for a user (test helper)
    public func addActiveJourney(_ journey: Journey, for distinctId: String) {
        var userJourneys = activeJourneysByUser[distinctId] ?? []
        userJourneys.append(journey)
        activeJourneysByUser[distinctId] = userJourneys
    }
    
    /// Remove an active journey for a user (test helper)
    public func removeActiveJourney(_ journeyId: String, for distinctId: String) {
        guard var userJourneys = activeJourneysByUser[distinctId] else { return }
        userJourneys.removeAll { $0.id == journeyId }
        if userJourneys.isEmpty {
            activeJourneysByUser.removeValue(forKey: distinctId)
        } else {
            activeJourneysByUser[distinctId] = userJourneys
        }
    }
    
    /// Clear all active journeys for a user (test helper)
    public func clearActiveJourneys(for distinctId: String) {
        activeJourneysByUser.removeValue(forKey: distinctId)
    }
    
    /// Get the last started journey (test helper)
    public var lastStartedJourney: Journey? {
        return startedJourneys.last?.journey
    }
    
    /// Get the last handled event (test helper)
    public var lastHandledEvent: NuxieEvent? {
        return handledEvents.last
    }
    
    /// Check if a specific campaign was started (test helper)
    public func wasCampaignStarted(_ campaignId: String) -> Bool {
        return startedJourneys.contains { $0.campaign.id == campaignId }
    }
    
    /// Check if a specific event was handled (test helper)
    public func wasEventHandled(_ eventName: String) -> Bool {
        return handledEvents.contains { $0.name == eventName }
    }
    
    /// Get count of active journeys across all users (test helper)
    public var totalActiveJourneys: Int {
        return activeJourneysByUser.values.reduce(0) { $0 + $1.count }
    }
}
