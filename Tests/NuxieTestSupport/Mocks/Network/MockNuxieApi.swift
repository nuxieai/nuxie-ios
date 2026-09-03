import Foundation
@_spi(Testing) @testable import Nuxie

/// Mock implementation of NuxieApi for testing
public actor MockNuxieApi: NuxieApiProtocol {
    // Response configuration
    public var shouldFailProfile = false
    public var shouldFailBatch = false
    public var batchError: Error?
    public var shouldFailTrackEvent = false
    public var trackEventError: Error?
    public var trackEventDelay: TimeInterval = 0
    public var acceptedTrackEventTimeouts = 0

    public var profileDelay: TimeInterval = 0
    var profileResponse: ProfileResponse?
    public var batchResponse: BatchResponse = BatchResponse(
        status: "success",
        processed: 0,
        failed: 0,
        total: 0,
        errors: nil
    )
    public var checkFeatureResponse: FeatureCheckResult?
    public var trackEventResponse: EventResponse?

    // Call tracking
    public var fetchProfileCallCount = 0
    public var fetchProfileWithTimeoutCallCount = 0
    public var sendBatchCallCount = 0
    public var trackEventCallCount = 0
    public var checkFeatureCallCount = 0
    private var acceptedTrackEventIds: Set<String> = []
    private var shouldSuspendNextProfileFetch = false
    private var suspendedProfileFetch: (
        id: UUID,
        continuation: CheckedContinuation<Void, Never>
    )?
    private var profileFetchSuspensionWaiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var appliedFeatureTrackEventIds: [String] = []
    private var shouldSuspendNextFeatureTrackEvent = false
    private var suspendedFeatureTrackEvent: (
        id: UUID,
        continuation: CheckedContinuation<Void, Never>
    )?
    private var featureTrackSuspensionWaiters: [CheckedContinuation<Void, Never>] = []

    public var uniqueAcceptedTrackEventCount: Int {
        acceptedTrackEventIds.count
    }

    public var lastTimeoutUsed: TimeInterval?
    public private(set) var lastProfileLocale: String?

    // Track sent events for test assertions
    public private(set) var sentEvents: [NuxieEvent] = []

    /// Immutable snapshot of a recorded trackEvent call.
    // @unchecked Sendable: write-once snapshot; the payload is never mutated.
    public struct TrackEventCall: @unchecked Sendable {
        public let event: String
        public let distinctId: String
        public let properties: [String: Any]?
        public let value: Double?
        public let entityId: String?
    }

    /// Every recorded trackEvent call, oldest first. Prefer filtering this by
    /// event name over asserting on trackEventCallCount: unrelated background
    /// captures (lifecycle, identity) can race a test's window and make the
    /// aggregate count flaky.
    public private(set) var trackEventCalls: [TrackEventCall] = []

    // Track last trackEvent call details
    public private(set) var lastTrackEventCall: TrackEventCall?
    
    public init() {
        // The nonisolated init cannot call the actor-isolated setup method;
        // assign the default response directly.
        self.profileResponse = Self.makeDefaultProfileResponse()
    }

    private func setupDefaultProfileResponse() {
        self.profileResponse = Self.makeDefaultProfileResponse()
    }

    private static func makeDefaultProfileResponse() -> ProfileResponse {
        TestJourneyProfile.response()
    }
    
    // Configuration methods
    func setProfileResponse(_ response: ProfileResponse) {
        self.profileResponse = response
    }

    public func setProfileDelay(_ delay: TimeInterval) {
        self.profileDelay = delay
    }

    func suspendNextProfileFetch() {
        shouldSuspendNextProfileFetch = true
    }

    func waitForSuspendedProfileFetch() async {
        if suspendedProfileFetch != nil { return }
        await withCheckedContinuation { continuation in
            profileFetchSuspensionWaiters.append(continuation)
        }
    }

    func resumeSuspendedProfileFetch() {
        suspendedProfileFetch?.continuation.resume()
        suspendedProfileFetch = nil
    }

    private func cancelSuspendedProfileFetch(id: UUID) {
        guard suspendedProfileFetch?.id == id else { return }
        resumeSuspendedProfileFetch()
    }
    
    public func setShouldFailBatch(_ shouldFail: Bool) {
        shouldFailBatch = shouldFail
    }

    public func setBatchError(_ error: Error?) {
        batchError = error
    }

    public func setShouldFailProfile(_ shouldFail: Bool) {
        self.shouldFailProfile = shouldFail
    }

    public func setTrackEventDelay(_ delay: TimeInterval) {
        trackEventDelay = delay
    }

    public func setAcceptedTrackEventTimeouts(_ count: Int) {
        acceptedTrackEventTimeouts = max(0, count)
    }

    public func suspendNextFeatureTrackEvent() {
        shouldSuspendNextFeatureTrackEvent = true
    }

    public func waitForSuspendedFeatureTrackEvent() async {
        if suspendedFeatureTrackEvent != nil { return }
        await withCheckedContinuation { continuation in
            featureTrackSuspensionWaiters.append(continuation)
        }
    }

    public func resumeSuspendedFeatureTrackEvent() {
        suspendedFeatureTrackEvent?.continuation.resume()
        suspendedFeatureTrackEvent = nil
    }

    private func cancelSuspendedFeatureTrackEvent(id: UUID) {
        guard suspendedFeatureTrackEvent?.id == id else { return }
        resumeSuspendedFeatureTrackEvent()
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
                id: item.idempotencyKey ?? UUID.v7().uuidString,
                name: item.event,
                distinctId: item.distinctId,
                properties: props,
                timestamp: Date()
            )
            sentEvents.append(nuxieEvent)
        }
        
        if shouldFailBatch || batchError != nil {
            throw batchError
                ?? NuxieNetworkError.httpError(statusCode: 500, message: "Mock batch error")
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
        lastProfileLocale = locale

        let response = profileResponse!
        let failure = shouldFailProfile
        if shouldSuspendNextProfileFetch {
            shouldSuspendNextProfileFetch = false
            let suspensionId = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    suspendedProfileFetch = (suspensionId, continuation)
                    let waiters = profileFetchSuspensionWaiters
                    profileFetchSuspensionWaiters.removeAll()
                    waiters.forEach { $0.resume() }
                }
            } onCancel: {
                Task { await self.cancelSuspendedProfileFetch(id: suspensionId) }
            }
            try Task.checkCancellation()
        }

        if profileDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(profileDelay * 1_000_000_000))
        }

        if failure {
            throw NuxieNetworkError.httpError(statusCode: 500, message: "Mock server error")
        }

        return response
    }

    public func fetchProfile(
        for distinctId: String,
        locale: String?,
        revalidating validator: ProfileCacheValidator?
    ) async throws -> ProfileFetchResult {
        let response = try await fetchProfile(for: distinctId, locale: locale)
        return .modified(
            response,
            validator: ProfileCacheValidator(
                rawValue: "\"mock-profile\"",
                resourceScope: "https://mock.nuxie.test/profile",
                authority: ProfileDeliveryAuthority(
                    appId: "mock-app",
                    environment: "live"
                )
            )
        )
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
    
    public func trackEvent(
        event: String,
        distinctId: String,
        properties: [String: Any]?,
        value: Double?,
        entityId: String?
    ) async throws -> EventResponse {
        trackEventCallCount += 1
        let call = TrackEventCall(
            event: event, distinctId: distinctId, properties: properties,
            value: value, entityId: entityId)
        lastTrackEventCall = call
        trackEventCalls.append(call)
        sentEvents.append(NuxieEvent(
            name: event,
            distinctId: distinctId,
            properties: properties ?? [:],
            timestamp: Date()
        ))

        if trackEventDelay > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(trackEventDelay * 1_000_000_000)
            )
        }

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
            usage: nil
        )
    }

    public func trackEvent(_ event: NuxieEvent) async throws -> EventResponse {
        trackEventCallCount += 1
        let call = TrackEventCall(
            event: event.name,
            distinctId: event.distinctId,
            properties: event.properties,
            value: (event.properties["value"] as? NSNumber)?.doubleValue,
            entityId: event.properties["entityId"] as? String
        )
        lastTrackEventCall = call
        trackEventCalls.append(call)
        sentEvents.append(event)

        if event.name == SystemEventNames.featureUsed,
           shouldSuspendNextFeatureTrackEvent {
            shouldSuspendNextFeatureTrackEvent = false
            let suspensionId = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    suspendedFeatureTrackEvent = (suspensionId, continuation)
                    let waiters = featureTrackSuspensionWaiters
                    featureTrackSuspensionWaiters.removeAll()
                    waiters.forEach { $0.resume() }
                }
            } onCancel: {
                Task { await self.cancelSuspendedFeatureTrackEvent(id: suspensionId) }
            }
            try Task.checkCancellation()
        }

        if trackEventDelay > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(trackEventDelay * 1_000_000_000)
            )
        }

        if shouldFailTrackEvent {
            if let error = trackEventError {
                throw error
            }
            throw NuxieNetworkError.httpError(
                statusCode: 500,
                message: "Mock tracking error"
            )
        }

        if event.name == SystemEventNames.featureUsed,
           acceptedTrackEventTimeouts > 0 {
            acceptedTrackEventTimeouts -= 1
            if acceptedTrackEventIds.insert(event.id).inserted {
                appliedFeatureTrackEventIds.append(event.id)
            }
            throw NuxieNetworkError.timeout
        }

        let response = trackEventResponse ?? EventResponse(status: "success")
        if event.name == SystemEventNames.featureUsed,
           response.status == "ok" || response.status == "success" {
            if acceptedTrackEventIds.insert(event.id).inserted {
                appliedFeatureTrackEventIds.append(event.id)
            }
        }
        return response
    }

    public func checkFeature(
        customerId: String,
        featureId: String,
        requiredBalance: Double?,
        entityId: String?
    ) async throws -> FeatureCheckResult {
        checkFeatureCallCount += 1
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

    /// Lets tests hold receipt submissions unacknowledged (the committer
    /// schedules sync at commit time, so an always-accepting mock would
    /// acknowledge evidence before the unsynced window can be observed).
    public var syncTransactionShouldSucceed = true

    /// Configures whether mocked transaction sync requests report success.
    /// - Parameter succeeds: `true` to return a successful purchase response;
    ///   otherwise, the mock returns a rejected response without throwing.
    public func setSyncTransactionShouldSucceed(_ succeeds: Bool) {
        syncTransactionShouldSucceed = succeeds
    }

    public func syncTransaction(
        transactionJwt: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
        guard syncTransactionShouldSucceed else {
            return PurchaseResponse(
                success: false,
                customerId: distinctId,
                features: nil,
                error: "mock sync unavailable"
            )
        }
        return PurchaseResponse(
            success: true,
            customerId: distinctId,
            features: nil,
            error: nil
        )
    }

    // Test helpers
    public func reset() {
        shouldFailProfile = false
        shouldFailBatch = false
        batchError = nil
        shouldFailTrackEvent = false
        trackEventError = nil
        trackEventDelay = 0
        acceptedTrackEventTimeouts = 0
        shouldSuspendNextProfileFetch = false
        resumeSuspendedProfileFetch()
        let profileSuspensionWaiters = profileFetchSuspensionWaiters
        profileFetchSuspensionWaiters.removeAll()
        profileSuspensionWaiters.forEach { $0.resume() }
        shouldSuspendNextFeatureTrackEvent = false
        resumeSuspendedFeatureTrackEvent()
        let suspensionWaiters = featureTrackSuspensionWaiters
        featureTrackSuspensionWaiters.removeAll()
        suspensionWaiters.forEach { $0.resume() }
        trackEventResponse = nil
        profileDelay = 0
        fetchProfileCallCount = 0
        fetchProfileWithTimeoutCallCount = 0
        sendBatchCallCount = 0
        trackEventCallCount = 0
        checkFeatureCallCount = 0
        acceptedTrackEventIds.removeAll()
        appliedFeatureTrackEventIds.removeAll()
        trackEventCalls = []
        lastTimeoutUsed = nil
        lastProfileLocale = nil
        sentEvents.removeAll()
        lastTrackEventCall = nil
        checkFeatureResponse = nil

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
            usage: usage
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
