import Foundation

/// Canonical Experience Execution E1 event contracts.
///
/// These facts use snake_case properties and travel through the synchronous
/// decision lane. Removed pre-E1 journey lifecycle names are not aliases.
public final class JourneyEvents: Sendable {

    // MARK: - E1 journey facts

    public static let journeyEnrolled = "$journey_enrolled"
    public static let journeyTransition = "$journey_transition"
    public static let journeyMilestone = "$journey_milestone"
    public static let journeyConverted = "$journey_converted"
    public static let journeyExited = "$journey_exited"

    public static let flowShown = "$flow_shown"
    public static let flowDismissed = "$flow_dismissed"
    public static let flowPurchased = "$flow_purchased"
    public static let flowTimedOut = "$flow_timed_out"
    public static let flowErrored = "$flow_errored"
    public static let flowArtifactLoadSucceeded = "$flow_artifact_load_succeeded"
    public static let flowArtifactLoadFailed = "$flow_artifact_load_failed"

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
        campaign: Campaign,
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
            "experience_id": campaign.id,
            "experience_version": campaign.flowId,
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
            "epoch": journey.nextTransitionEpoch(),
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
            "reason": reason.executionReason,
            "at": iso8601(at),
        ]
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func flowShownProperties(flowId: String, journey: Journey) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId
        ]
    }

    public static func flowDismissedProperties(flowId: String, journey: Journey) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId
        ]
    }

    public static func flowPurchasedProperties(flowId: String, journey: Journey, productId: String?) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId
        ]
        if let productId {
            properties["product_id"] = productId
        }
        return properties
    }

    public static func flowTimedOutProperties(flowId: String, journey: Journey) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId
        ]
    }

    public static func flowErroredProperties(flowId: String, journey: Journey, errorMessage: String?) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId
        ]
        if let errorMessage {
            properties["error_message"] = errorMessage
        }
        return properties
    }

    public static func flowArtifactLoadSucceededProperties(
        flowId: String,
        artifactBuildId: String,
        artifactSource: String,
        artifactContentHash: String
    ) -> [String: Any] {
        return flowArtifactLoadBaseProperties(
            flowId: flowId,
            artifactBuildId: artifactBuildId,
            artifactSource: artifactSource,
            artifactContentHash: artifactContentHash
        )
    }

    public static func flowArtifactLoadFailedProperties(
        flowId: String,
        artifactBuildId: String,
        artifactSource: String,
        artifactContentHash: String,
        errorMessage: String?
    ) -> [String: Any] {
        var properties = flowArtifactLoadBaseProperties(
            flowId: flowId,
            artifactBuildId: artifactBuildId,
            artifactSource: artifactSource,
            artifactContentHash: artifactContentHash
        )
        if let errorMessage {
            properties["error_message"] = errorMessage
        }
        return properties
    }

    private static func flowArtifactLoadBaseProperties(
        flowId: String,
        artifactBuildId: String,
        artifactSource: String,
        artifactContentHash: String
    ) -> [String: Any] {
        return [
            "flow_id": flowId,
            "artifact_build_id": artifactBuildId,
            "artifact_source": artifactSource,
            "artifact_content_hash": artifactContentHash,
        ]
    }

    public static func customerUpdatedProperties(
        journey: Journey,
        screenId: String?,
        attributesUpdated: [String]
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "attributes_updated": attributesUpdated
        ]
        if let screenId {
            properties["screen_id"] = screenId
        }
        return properties
    }

    public static func eventSentProperties(
        journey: Journey,
        screenId: String?,
        eventName: String,
        eventProperties: [String: Any]
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "event_name": eventName,
            "event_properties": eventProperties
        ]
        if let screenId {
            properties["screen_id"] = screenId
        }
        return properties
    }

    public static func delegateCalledProperties(
        journey: Journey,
        screenId: String?,
        message: String,
        payload: Any?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
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

    public static func experimentExposureProperties(
        journey: Journey,
        experimentKey: String,
        variantKey: String,
        flowId: String?,
        isHoldout: Bool,
        assignmentSource: String? = nil
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId as Any,
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
