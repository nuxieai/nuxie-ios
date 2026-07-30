import Foundation

/// Canonical Experiences event contracts.
///
/// These facts use snake_case properties and travel through the decision
/// lane. Parking uses its durable queued form; ownership-changing facts use
/// the synchronous response form. Removed legacy journey lifecycle names are
/// not aliases.
public final class JourneyEvents: Sendable {

    // MARK: - Journey facts

    public static let journeyEnrolled = "$journey_enrolled"
    public static let journeyTransition = "$journey_transition"
    public static let journeyMilestone = "$journey_milestone"
    public static let journeyConverted = "$journey_converted"
    public static let journeyExited = "$journey_exited"
    public static let journeyEffectRequested = "$journey_effect_requested"
    public static let journeyEffectCompleted = "$journey_effect_completed"
    /// Device claim request for a server-owned mailbox offer.
    public static let journeyClaimed = "$journey_claimed"
    /// Ownership transfer carrying a versioned state envelope.
    public static let journeyHandoff = "$journey_handoff"
    /// Durable checkpoint emitted while this device retains ownership.
    public static let journeyParked = "$journey_parked"
    /// Authoritative cancellation of a losing journey owner.
    public static let journeySuperseded = "$journey_superseded"

    /// Successful experience presentation.
    public static let experienceShown = "$experience_shown"
    /// User-driven experience dismissal.
    public static let experienceDismissed = "$experience_dismissed"
    /// Purchase completed from an experience.
    public static let experiencePurchased = "$experience_purchased"
    /// Experience presentation exceeded its time limit.
    public static let experienceTimedOut = "$experience_timed_out"
    /// Experience execution failed.
    public static let experienceErrored = "$experience_errored"
    /// Published experience artifact loaded successfully.
    public static let experienceArtifactLoadSucceeded = "$experience_artifact_load_succeeded"
    /// Published experience artifact failed to load.
    public static let experienceArtifactLoadFailed = "$experience_artifact_load_failed"

    public static let customerUpdated = "$customer_updated"
    public static let eventSent = "$event_sent"
    public static let delegateCalled = "$delegate_called"

    /// Real exposure from a server experiment assignment. Properties are
    /// pinned by `fixtures/journeys/golden-journeys.json`.
    public static let experimentExposure = "$experiment_exposure"
    /// No server assignment existed; the first variant ran as a tagged
    /// fallback (`assignment_source: "no_assignment"`).
    public static let experimentExposureFallback = "$experiment_exposure_fallback"
    /// A server assignment named an unknown variant; no variant actions
    /// ran (`reason: "variant_not_found"`).
    public static let experimentExposureError = "$experiment_exposure_error"

    // MARK: - Properties Builders

    public static func journeyEnrolledProperties(
        journey: Journey,
        experience: Experience,
        triggerRef: String
    ) -> [String: Any] {
        let goal: Any
        if let goalSnapshot = journey.goalSnapshot,
           let data = try? JSONEncoder().encode(goalSnapshot),
           let object = try? JSONDecoder().decode([String: AnyCodable].self, from: data) {
            goal = object.mapValues(\.value)
        } else {
            goal = NSNull()
        }
        let goalWindowEndsAt: Any = journey.conversionWindow > 0
            ? iso8601(journey.conversionAnchorAt.addingTimeInterval(journey.conversionWindow))
            : NSNull()
        let endOnGoal: Bool
        switch journey.exitPolicySnapshot?.mode {
        case .onGoal, .onGoalOrStop:
            endOnGoal = true
        case .onStopMatching, .never, nil:
            endOnGoal = false
        }

        return [
            "journey_id": journey.id,
            "epoch": journey.epoch,
            "experience_id": experience.id,
            "experience_version": experience.versionId,
            "trigger_ref": triggerRef,
            "plane": "device",
            "settings_snapshot": [
                "goal": goal,
                "conversion_anchor": journey.conversionAnchor.rawValue,
                "conversion_anchor_at": iso8601(journey.conversionAnchorAt),
                "goal_window_ends_at": goalWindowEndsAt,
                "end_on_goal": endOnGoal,
            ],
        ]
    }

    public static func journeyTransitionProperties(
        journey: Journey,
        fromNode: String?,
        toNode: String,
        region: String = "device-main"
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "epoch": journey.epoch,
            "to_node": toNode,
            "region": region,
            "plane": "device",
        ]
        if let fromNode, !fromNode.isEmpty {
            properties["from_node"] = fromNode
        }
        return properties
    }

    public static func journeyMilestoneProperties(
        journey: Journey,
        milestoneId: String
    ) -> [String: Any] {
        [
            "journey_id": journey.id,
            "epoch": journey.epoch,
            "milestone_id": milestoneId,
        ]
    }

    public static func journeyConvertedProperties(
        journey: Journey,
        at: Date,
        sourceFactRef: String
    ) -> [String: Any] {
        [
            "journey_id": journey.id,
            "epoch": journey.epoch,
            "at": iso8601(at),
            "source_fact_ref": sourceFactRef,
        ]
    }

    public static func journeyExitedProperties(
        journey: Journey,
        reason: JourneyExitReason,
        at: Date
    ) -> [String: Any] {
        [
            "journey_id": journey.id,
            "epoch": journey.epoch,
            "reason": reason.executionReason,
            "at": iso8601(at),
        ]
    }

    /// Builds the canonical epoch-fenced claim payload.
    public static func journeyClaimedProperties(
        journeyId: String,
        epoch: Int,
        claimant: String
    ) -> [String: Any] {
        [
            "journey_id": journeyId,
            "epoch": epoch,
            "claimant": claimant,
        ]
    }

    /// Builds the canonical device-to-server handoff payload.
    public static func journeyHandoffProperties(
        journey: Journey,
        envelope: JourneyStateEnvelope
    ) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "epoch": journey.epoch,
            "direction": "device_to_server",
            "envelope": encodedEnvelope(envelope),
        ]
    }

    /// Builds the local-first checkpoint payload used by background and wait
    /// parking. A missing deadline is omitted rather than encoded as null.
    public static func journeyParkedProperties(
        journey: Journey,
        reason: JourneyParkingReason,
        pendingDeadlineAt: Date? = nil
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "epoch": journey.epoch,
            "checkpoint": encodedEnvelope(journey.stateEnvelope()),
            "reason": reason.rawValue,
        ]
        if let pendingDeadlineAt {
            properties["pending_deadline_at"] = iso8601(pendingDeadlineAt)
        }
        return properties
    }

    private static func encodedEnvelope(_ envelope: JourneyStateEnvelope) -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(envelope),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return [String: Any]()
        }
        return object
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Builds identity properties for a successful experience presentation.
    ///
    /// - Parameters:
    ///   - experienceVersion: Exact published version that was presented.
    ///   - journey: Journey that owns the presentation.
    /// - Returns: Canonical event properties.
    public static func experienceShownProperties(
        experienceVersion: String,
        journey: Journey
    ) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "experience_id": journey.experienceId,
            "experience_version": experienceVersion
        ]
    }

    /// Builds identity properties for an experience dismissal.
    ///
    /// - Parameters:
    ///   - experienceVersion: Exact published version that was dismissed.
    ///   - journey: Journey that owns the presentation.
    /// - Returns: Canonical event properties.
    public static func experienceDismissedProperties(
        experienceVersion: String,
        journey: Journey
    ) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "experience_id": journey.experienceId,
            "experience_version": experienceVersion
        ]
    }

    /// Builds identity and optional product properties for a purchase.
    ///
    /// - Parameters:
    ///   - experienceVersion: Exact published version that initiated the purchase.
    ///   - journey: Journey that owns the presentation.
    ///   - productId: Purchased product identifier, when known.
    /// - Returns: Canonical event properties.
    public static func experiencePurchasedProperties(
        experienceVersion: String,
        journey: Journey,
        productId: String?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "experience_id": journey.experienceId,
            "experience_version": experienceVersion
        ]
        if let productId {
            properties["product_id"] = productId
        }
        return properties
    }

    /// Builds identity properties for an experience timeout.
    ///
    /// - Parameters:
    ///   - experienceVersion: Exact published version that timed out.
    ///   - journey: Journey that owns the presentation.
    /// - Returns: Canonical event properties.
    public static func experienceTimedOutProperties(
        experienceVersion: String,
        journey: Journey
    ) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "experience_id": journey.experienceId,
            "experience_version": experienceVersion
        ]
    }

    /// Builds identity and optional error properties for an execution failure.
    ///
    /// - Parameters:
    ///   - experienceVersion: Exact published version that failed.
    ///   - journey: Journey that owns the presentation.
    ///   - errorMessage: Diagnostic message, when available.
    /// - Returns: Canonical event properties.
    public static func experienceErroredProperties(
        experienceVersion: String,
        journey: Journey,
        errorMessage: String?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "experience_id": journey.experienceId,
            "experience_version": experienceVersion
        ]
        if let errorMessage {
            properties["error_message"] = errorMessage
        }
        return properties
    }

    /// Builds version and artifact identity properties for a successful load.
    ///
    /// - Parameters:
    ///   - experienceVersion: Exact published version that loaded.
    ///   - artifactBuildId: Content build identifier.
    ///   - artifactSource: Cache or network source used for the load.
    ///   - artifactContentHash: Verified artifact content hash.
    /// - Returns: Canonical event properties.
    public static func experienceArtifactLoadSucceededProperties(
        experienceVersion: String,
        artifactBuildId: String,
        artifactSource: String,
        artifactContentHash: String
    ) -> [String: Any] {
        return experienceArtifactLoadBaseProperties(
            experienceVersion: experienceVersion,
            artifactBuildId: artifactBuildId,
            artifactSource: artifactSource,
            artifactContentHash: artifactContentHash
        )
    }

    /// Builds version, artifact identity, and optional error properties for a failed load.
    ///
    /// - Parameters:
    ///   - experienceVersion: Exact published version that failed to load.
    ///   - artifactBuildId: Content build identifier.
    ///   - artifactSource: Cache or network source used for the load.
    ///   - artifactContentHash: Expected artifact content hash.
    ///   - errorMessage: Diagnostic message, when available.
    /// - Returns: Canonical event properties.
    public static func experienceArtifactLoadFailedProperties(
        experienceVersion: String,
        artifactBuildId: String,
        artifactSource: String,
        artifactContentHash: String,
        errorMessage: String?
    ) -> [String: Any] {
        var properties = experienceArtifactLoadBaseProperties(
            experienceVersion: experienceVersion,
            artifactBuildId: artifactBuildId,
            artifactSource: artifactSource,
            artifactContentHash: artifactContentHash
        )
        if let errorMessage {
            properties["error_message"] = errorMessage
        }
        return properties
    }

    private static func experienceArtifactLoadBaseProperties(
        experienceVersion: String,
        artifactBuildId: String,
        artifactSource: String,
        artifactContentHash: String
    ) -> [String: Any] {
        return [
            "experience_version": experienceVersion,
            "artifact_build_id": artifactBuildId,
            "artifact_source": artifactSource,
            "artifact_content_hash": artifactContentHash,
        ]
    }

    /// Builds journey and experience context for a customer update rider.
    ///
    /// - Parameters:
    ///   - journey: Journey that initiated the update.
    ///   - screenId: Originating screen identifier, when available.
    ///   - attributesUpdated: Names of customer attributes that changed.
    /// - Returns: Canonical rider properties.
    public static func customerUpdatedProperties(
        journey: Journey,
        screenId: String?,
        attributesUpdated: [String]
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "experience_id": journey.experienceId,
            "attributes_updated": attributesUpdated
        ]
        if let screenId {
            properties["screen_id"] = screenId
        }
        return properties
    }

    /// Builds journey and experience context for an event-send rider.
    ///
    /// - Parameters:
    ///   - journey: Journey that initiated the event.
    ///   - screenId: Originating screen identifier, when available.
    ///   - eventName: Name of the user event sent by the experience.
    ///   - eventProperties: Properties supplied with that user event.
    /// - Returns: Canonical rider properties.
    public static func eventSentProperties(
        journey: Journey,
        screenId: String?,
        eventName: String,
        eventProperties: [String: Any]
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "experience_id": journey.experienceId,
            "event_name": eventName,
            "event_properties": eventProperties
        ]
        if let screenId {
            properties["screen_id"] = screenId
        }
        return properties
    }

    /// Builds journey and experience context for a delegate-call rider.
    ///
    /// - Parameters:
    ///   - journey: Journey that initiated the delegate call.
    ///   - screenId: Originating screen identifier, when available.
    ///   - message: Authored delegate message.
    ///   - payload: Authored delegate payload, when supplied.
    /// - Returns: Canonical rider properties.
    public static func delegateCalledProperties(
        journey: Journey,
        screenId: String?,
        message: String,
        payload: Any?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "experience_id": journey.experienceId,
            "message": message
        ]
        if let screenId {
            properties["screen_id"] = screenId
        }
        if let payload {
            properties["payload"] = payload
        }
        return properties
    }

    /// Builds journey, experience, and assignment context for an exposure rider.
    ///
    /// - Parameters:
    ///   - journey: Journey that evaluated the experiment.
    ///   - experimentKey: Stable experiment identifier.
    ///   - variantKey: Selected variant identifier.
    ///   - experienceVersion: Exact published version, when available.
    ///   - isHoldout: Whether the selected assignment is a holdout.
    ///   - assignmentSource: Assignment source, when it is not implicit.
    /// - Returns: Canonical rider properties.
    public static func experimentExposureProperties(
        journey: Journey,
        experimentKey: String,
        variantKey: String,
        experienceVersion: String?,
        isHoldout: Bool,
        assignmentSource: String? = nil
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "experience_id": journey.experienceId,
            "experience_version": experienceVersion as Any,
            "experiment_key": experimentKey,
            "variant_key": variantKey,
            "is_holdout": isHoldout
        ]
        if let assignmentSource {
            properties["assignment_source"] = assignmentSource
        }
        return properties
    }
}

/// Why a device retained ownership while publishing a durable checkpoint.
public enum JourneyParkingReason: String, Sendable {
    /// The app entered the background.
    case background
    /// Journey execution paused on a pending action.
    case wait
}
