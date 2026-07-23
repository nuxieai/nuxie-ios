import Foundation

/// Internal journey event tracking system
/// These events flow through the standard EventLog for observability
///
/// Naming convention: `$<domain>_<past_tense_verb>` with snake_case
/// property keys (`journey_id`, `campaign_id`, `flow_id`, `screen_id`).
///
/// There are TWO deliberate journey event families — do not merge them:
///
/// 1. **Server journey mirror** (`journeyStart`, `journeyNodeExecuted`,
///    `journeyCompleted`): the backend ingests these BY NAME
///    (nuxie-ingest routes `$journey_start`/`$journey_node_executed`/
///    `$journey_completed` into the customer journey mirror) and keys
///    them by `session_id` (= the journey id on the server side). Their
///    names and property keys are a wire contract shared with the
///    backend and the Android SDK — renaming any of them requires a
///    coordinated backend change.
/// 2. **Observability lifecycle** (`journeyStarted`, `journeyPaused`,
///    `journeyResumed`, `journeyExited`, ...): richer client-side
///    analytics events keyed by `journey_id`/`campaign_id`. They are
///    not part of the server mirror protocol.
///
/// `$journey_start` vs `$journey_started` is therefore intentional, not
/// an accidental duplicate: `$journey_start` is the durable enrollment
/// record the server mirrors; `$journey_started` is the analytics event
/// carrying trigger/campaign detail.
public final class JourneyEvents: Sendable {

    // MARK: - Event Names (server journey mirror — wire contract)

    /// Durable enrollment record mirrored by the backend. Properties:
    /// `session_id` (journey id), `campaign_id`, `flow_id`,
    /// `entry_node_id`. Delivered at-least-once on the durable queue.
    public static let journeyStart = "$journey_start"
    /// Node-execution mirror record. Properties: `session_id`
    /// (journey id), `node_id`, `async`, `context` (+ `node_data`,
    /// `screen_id` for remote nodes).
    public static let journeyNodeExecuted = "$journey_node_executed"
    /// Completion mirror record. Properties: `session_id` (journey id),
    /// `exit_reason`, `goal_met`, `goal_met_at`, `duration_seconds`.
    public static let journeyCompleted = "$journey_completed"

    // MARK: - Event Names (observability lifecycle)

    public static let journeyEnrolled = "$journey_enrolled"
    public static let journeyTransition = "$journey_transition"
    public static let journeyMilestone = "$journey_milestone"
    public static let journeyConverted = "$journey_converted"
    public static let journeyExited = "$journey_exited"

    // MARK: - Resume Reasons

    /// Truthful values for the `resume_reason` property on
    /// `$journey_resumed`.
    public enum ResumeReasonValue {
        /// A pending delay/wait deadline elapsed (in-process timer fire,
        /// or the due-timer sweep at SDK initialize / app foreground).
        public static let timer = "timer"
        /// A `wait_until` pending action resumed because a matching
        /// event satisfied (or timed out past) its condition.
        public static let event = "event"
    }

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
           let object = try? JSONSerialization.jsonObject(with: data) {
            goal = object
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
